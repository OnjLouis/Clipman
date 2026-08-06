package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	xhtml "golang.org/x/net/html"
)

const (
	websiteTitleMetadataLimit = 128 * 1024
	websiteTitleDecodedLimit  = 2 * 1024 * 1024
	websiteTitleTimeout       = 8 * time.Second
	websiteTitleURLLimit      = 8192
)

var capabilityUUIDPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var readableArticleIDPattern = regexp.MustCompile(`(?i)^[a-z]?[0-9]{4,12}$`)

var sensitiveQueryNames = map[string]bool{
	"access_token": true, "apikey": true, "api_key": true, "auth": true,
	"authorization": true, "challenge": true, "code": true, "confirmation": true, "credential": true, "hmac": true, "id_token": true,
	"invite": true, "jwt": true, "key": true, "nonce": true, "one_time": true, "otp": true,
	"passcode": true, "password": true, "reset": true, "secret": true, "session": true,
	"sig": true, "signature": true, "signed": true, "sso": true, "state": true, "ticket": true, "verification": true,
	"token": true, "awsaccesskeyid": true, "googleaccessid": true, "key-pair-id": true,
}

var nonMetadataElements = map[string]bool{
	"script": true, "style": true, "template": true, "noscript": true, "svg": true, "iframe": true,
}

var exactJunkTitles = map[string]bool{
	"just a moment": true, "attention required": true, "access denied": true,
	"access to this page has been denied": true, "are you a robot": true, "are you a human": true,
	"please wait": true, "javascript is disabled": true, "javascript is required": true,
	"enable javascript": true, "security check": true, "checking your browser": true,
	"verify you are human": true, "human verification": true, "bot verification": true,
	"one moment please": true, "loading": true, "redirecting": true, "error": true,
	"page not found": true, "not found": true, "404": true, "403 forbidden": true,
	"forbidden": true, "site maintenance": true, "under construction": true, "untitled": true,
	"untitled document": true, "log in": true, "login": true, "sign in": true, "signin": true,
	"log in or sign up": true, "robot check": true, "captcha": true, "request blocked": true, "blocked": true,
	"reddit - dive into anything": true,
}

var junkTitleFragments = []string{
	"please wait for verification", "checking if the site connection is secure",
	"enable javascript and cookies to continue", "verify you are a human",
	"your request has been blocked", "unusual traffic",
}

var nonGlobalNetworks = mustPrefixes(
	"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24",
	"192.31.196.0/24", "192.52.193.0/24", "192.88.99.0/24", "192.175.48.0/24",
	"198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
	"64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "100:0:0:1::/64",
	"2001::/23", "2001:db8::/32", "2002::/16", "2620:4f:8000::/48", "3fff::/20",
	"5f00::/16", "fc00::/7", "fe80::/10", "fec0::/10", "ff00::/8",
)

var sensitiveIPv4TailNetworks = mustPrefixes(
	"10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
	"172.16.0.0/12", "192.168.0.0/16",
)

var lookupWebsiteTitleAddresses = net.DefaultResolver.LookupIPAddr
var dialWebsiteTitleAddress = func(ctx context.Context, network, address string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 4 * time.Second, KeepAlive: -1}
	return dialer.DialContext(ctx, network, address)
}

func mustPrefixes(values ...string) []*net.IPNet {
	result := make([]*net.IPNet, 0, len(values))
	for _, value := range values {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			panic(err)
		}
		result = append(result, network)
	}
	return result
}

func validateWebsiteTitleURL(raw string) (*url.URL, error) {
	if !utf8.ValidString(raw) {
		return nil, errors.New("the selected entry does not contain a valid website URL")
	}
	value := strings.TrimSpace(raw)
	if !websiteTitleURLWithinLimit(value) {
		return nil, errors.New("the selected website URL is too long")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Hostname() == "" {
		return nil, errors.New("the selected entry does not contain a valid website URL")
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil, errors.New("website titles can only be requested for HTTP or HTTPS links")
	}
	if parsed.User != nil {
		return nil, errors.New("website titles cannot be requested for URLs containing user information")
	}
	if port := parsed.Port(); port != "" && !((scheme == "http" && port == "80") || (scheme == "https" && port == "443")) {
		return nil, errors.New("website titles can only be requested from the default HTTP or HTTPS port")
	}
	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") {
		return nil, errors.New("website titles cannot be requested from a local address")
	}
	if literal := net.ParseIP(host); literal != nil {
		if (strings.Contains(host, ":") && literal.To4() != nil) || !publicAddress(literal) {
			return nil, errors.New("website titles cannot be requested from local, private, or non-global addresses")
		}
	}
	decodedPath := repeatedlyUnescapeURLComponent(parsed.EscapedPath())
	for _, segment := range strings.Split(decodedPath, "/") {
		if looksLikeCapabilityValue(segment) {
			return nil, errors.New("this link appears to contain a private capability value")
		}
	}
	for name := range parsed.Query() {
		key := strings.ToLower(strings.TrimSpace(repeatedlyUnescapeURLComponent(name)))
		if sensitiveQueryName(key) {
			return nil, errors.New("this link appears to contain a token, signature, or other private capability")
		}
	}
	parsed.Fragment = ""
	return parsed, nil
}

func websiteTitleURLWithinLimit(value string) bool {
	count := 0
	for range value {
		count++
		if count > websiteTitleURLLimit {
			return false
		}
	}
	return true
}

func repeatedlyUnescapeURLComponent(value string) string {
	for attempts := 0; attempts < 3; attempts++ {
		decoded, err := url.PathUnescape(value)
		if err != nil || decoded == value {
			break
		}
		value = decoded
	}
	return value
}

func looksLikeCapabilityValue(value string) bool {
	value = strings.TrimSpace(value)
	if utf8.RuneCountInString(value) < 32 || strings.IndexFunc(value, unicode.IsSpace) >= 0 {
		return false
	}
	if capabilityUUIDPattern.MatchString(value) {
		return true
	}
	slug := value
	lowerSlug := strings.ToLower(slug)
	for _, suffix := range []string{".html", ".htm", ".shtml"} {
		if strings.HasSuffix(lowerSlug, suffix) {
			slug = slug[:len(slug)-len(suffix)]
			break
		}
	}
	parts := strings.FieldsFunc(slug, func(character rune) bool { return character == '-' || character == '_' })
	readableWords := 0
	allPartsBounded := len(parts) >= 5
	for _, part := range parts {
		length := utf8.RuneCountInString(part)
		isLetters := strings.IndexFunc(part, func(character rune) bool { return !unicode.IsLetter(character) }) < 0
		isArticleID := readableArticleIDPattern.MatchString(part)
		if length > 24 || (!isLetters && !isArticleID) {
			allPartsBounded = false
		}
		if length >= 3 && length <= 24 && isLetters {
			readableWords++
		}
	}
	if allPartsBounded && readableWords >= 4 {
		return false
	}
	letters, digits := 0, 0
	for _, character := range value {
		if unicode.IsLetter(character) {
			letters++
		}
		if unicode.IsDigit(character) {
			digits++
		}
	}
	return letters >= 8 && digits >= 4
}

func sensitiveQueryName(value string) bool {
	key := strings.ToLower(strings.TrimSpace(value))
	if strings.HasPrefix(key, "x-amz-") || strings.HasPrefix(key, "x-goog-") {
		return true
	}
	for name := range sensitiveQueryNames {
		if key == name || strings.HasSuffix(key, "_"+name) || strings.HasSuffix(key, "-"+name) || strings.HasSuffix(key, "."+name) {
			return true
		}
	}
	return false
}

func publicAddress(ip net.IP) bool {
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() {
		return false
	}
	for _, network := range nonGlobalNetworks {
		if network.Contains(ip) {
			return false
		}
	}
	if sensitiveIPv4Tail(ip) {
		return false
	}
	return true
}

func sensitiveIPv4Tail(ip net.IP) bool {
	if ip == nil || ip.To4() != nil {
		return false
	}
	value := ip.To16()
	if value == nil {
		return false
	}
	tail := net.IPv4(value[12], value[13], value[14], value[15])
	for _, network := range sensitiveIPv4TailNetworks {
		if network.Contains(tail) {
			return true
		}
	}
	return false
}

func publicDialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, errors.New("the website address is invalid")
	}
	addresses, err := lookupWebsiteTitleAddresses(ctx, host)
	if err != nil || len(addresses) == 0 {
		return nil, errors.New("the website address could not be resolved")
	}
	for _, address := range addresses {
		if !publicAddress(address.IP) {
			return nil, errors.New("website titles cannot be requested from local, private, or non-global addresses")
		}
	}
	var lastErr error
	for _, candidate := range addresses {
		connection, dialErr := dialWebsiteTitleAddress(ctx, network, net.JoinHostPort(candidate.IP.String(), port))
		if dialErr == nil {
			return connection, nil
		}
		lastErr = dialErr
	}
	return nil, lastErr
}

func fetchWebsiteTitle(raw string) (string, error) {
	current, err := validateWebsiteTitleURL(raw)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), websiteTitleTimeout)
	defer cancel()
	transport := &http.Transport{
		Proxy:                  nil,
		DialContext:            publicDialContext,
		DisableKeepAlives:      true,
		MaxResponseHeaderBytes: 64 * 1024,
		TLSHandshakeTimeout:    4 * time.Second,
		ResponseHeaderTimeout:  5 * time.Second,
	}
	defer transport.CloseIdleConnections()
	for redirectCount := 0; ; redirectCount++ {
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, current.String(), nil)
		if requestErr != nil {
			return "", errors.New("the website request could not be created")
		}
		request.Header.Set("Accept", "text/html, application/xhtml+xml;q=0.9")
		request.Header.Set("User-Agent", "Clipman/WebsiteTitle")
		response, requestErr := transport.RoundTrip(request)
		if requestErr != nil {
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return "", errors.New("the website did not respond within eight seconds")
			}
			return "", fmt.Errorf("the website title could not be requested: %w", requestErr)
		}

		if response.StatusCode >= 300 && response.StatusCode < 400 {
			location := response.Header.Get("Location")
			response.Body.Close()
			current, err = resolveWebsiteTitleRedirect(current, location, redirectCount)
			if err != nil {
				return "", err
			}
			continue
		}
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			response.Body.Close()
			return "", fmt.Errorf("the website returned HTTP %d", response.StatusCode)
		}
		mediaType, _, mediaErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
		if mediaErr != nil || (mediaType != "text/html" && mediaType != "application/xhtml+xml") {
			response.Body.Close()
			return "", errors.New("the website response was not HTML")
		}
		body, readErr := io.ReadAll(io.LimitReader(response.Body, websiteTitleDecodedLimit+1))
		response.Body.Close()
		if readErr != nil {
			return "", errors.New("the website title could not be read")
		}
		if len(body) > websiteTitleDecodedLimit {
			body = body[:websiteTitleDecodedLimit]
		}
		title := extractWebsiteTitle(body, current.Hostname())
		if title == "" {
			return "", errors.New("the website did not provide a usable title")
		}
		return title, nil
	}
}

func resolveWebsiteTitleRedirect(current *url.URL, rawLocation string, redirectCount int) (*url.URL, error) {
	if redirectCount >= 3 {
		return nil, errors.New("the website redirected more than three times")
	}
	if !utf8.ValidString(rawLocation) || !websiteTitleURLWithinLimit(rawLocation) {
		return nil, errors.New("the website redirected to an invalid or overlong address")
	}
	destination, err := current.Parse(rawLocation)
	if err != nil {
		return nil, errors.New("the website redirected to an invalid address")
	}
	validated, err := validateWebsiteTitleURL(destination.String())
	if err != nil {
		return nil, err
	}
	if strings.EqualFold(current.Scheme, "https") && strings.EqualFold(validated.Scheme, "http") {
		return nil, errors.New("the website attempted to redirect from HTTPS to HTTP")
	}
	return validated, nil
}

func extractWebsiteTitle(body []byte, host string) string {
	if !utf8.Valid(body) {
		body = []byte(strings.ToValidUTF8(string(body), ""))
	}
	tokenizer := xhtml.NewTokenizer(strings.NewReader(string(body)))
	var openGraph, twitter, document, heading strings.Builder
	inTitle, inHeading := false, false
	skipName, skipDepth, retainedBytes := "", 0, 0
	for {
		switch tokenType := tokenizer.Next(); tokenType {
		case xhtml.ErrorToken:
			if tokenizer.Err() != nil && tokenizer.Err() != io.EOF {
				return ""
			}
			return selectWebsiteTitle(host, openGraph.String(), twitter.String(), document.String(), heading.String())
		case xhtml.StartTagToken, xhtml.SelfClosingTagToken:
			token := tokenizer.Token()
			if skipName != "" {
				if tokenType == xhtml.StartTagToken && token.Data == skipName {
					skipDepth++
				}
				continue
			}
			if nonMetadataElements[token.Data] && tokenType == xhtml.StartTagToken {
				skipName, skipDepth = token.Data, 1
				continue
			}
			retainedBytes += len(tokenizer.Raw())
			if retainedBytes > websiteTitleMetadataLimit {
				return selectWebsiteTitle(host, openGraph.String(), twitter.String(), document.String(), heading.String())
			}
			if token.Data == "title" {
				inTitle = document.Len() == 0
				continue
			}
			if token.Data == "h1" {
				inHeading = heading.Len() == 0
				continue
			}
			if token.Data != "meta" {
				continue
			}
			attributes := map[string]string{}
			for _, attribute := range token.Attr {
				attributes[strings.ToLower(attribute.Key)] = attribute.Val
			}
			kind := strings.ToLower(strings.TrimSpace(attributes["property"]))
			if kind == "" {
				kind = strings.ToLower(strings.TrimSpace(attributes["name"]))
			}
			if kind == "" {
				kind = strings.ToLower(strings.TrimSpace(attributes["itemprop"]))
			}
			content := attributes["content"]
			if strings.TrimSpace(content) != "" && kind == "og:title" && openGraph.Len() == 0 {
				openGraph.WriteString(content)
			} else if strings.TrimSpace(content) != "" && kind == "twitter:title" && twitter.Len() == 0 {
				twitter.WriteString(content)
			}
		case xhtml.EndTagToken:
			token := tokenizer.Token()
			if skipName != "" {
				if token.Data == skipName {
					skipDepth--
					if skipDepth == 0 {
						skipName = ""
					}
				}
				continue
			}
			retainedBytes += len(tokenizer.Raw())
			if retainedBytes > websiteTitleMetadataLimit {
				return selectWebsiteTitle(host, openGraph.String(), twitter.String(), document.String(), heading.String())
			}
			if token.Data == "title" {
				inTitle = false
			}
			if token.Data == "h1" {
				inHeading = false
			}
			if token.Data == "head" && openGraph.Len() > 0 && document.Len() > 0 {
				return selectWebsiteTitle(host, openGraph.String(), twitter.String(), document.String(), heading.String())
			}
		case xhtml.TextToken:
			if skipName != "" {
				continue
			}
			retainedBytes += len(tokenizer.Raw())
			if retainedBytes > websiteTitleMetadataLimit {
				return selectWebsiteTitle(host, openGraph.String(), twitter.String(), document.String(), heading.String())
			}
			if inTitle {
				document.Write(tokenizer.Text())
			}
			if inHeading {
				heading.Write(tokenizer.Text())
			}
		}
	}
}

func selectWebsiteTitle(host string, candidates ...string) string {
	for _, candidate := range candidates {
		title := sanitizeWebsiteTitle(candidate)
		if title != "" && !junkWebsiteTitle(title) && !strings.EqualFold(title, host) {
			return title
		}
	}
	return ""
}

func junkWebsiteTitle(title string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(title), " "))
	normalized = strings.TrimSpace(strings.Trim(normalized, ".!|-\u2013\u2014"))
	if exactJunkTitles[normalized] {
		return true
	}
	for _, fragment := range junkTitleFragments {
		if strings.Contains(normalized, fragment) {
			return true
		}
	}
	return false
}

func sanitizeWebsiteTitle(value string) string {
	cleaned := strings.Map(func(character rune) rune {
		if character == utf8.RuneError || unicode.IsControl(character) ||
			unicode.In(character, unicode.Cf, unicode.Cs, unicode.Zl, unicode.Zp) {
			return -1
		}
		return character
	}, value)
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	cleaned = strings.TrimFunc(cleaned, func(character rune) bool {
		return unicode.IsSpace(character) || strings.ContainsRune("|-\u2013\u2014\u00b7\u00bb<", character)
	})
	runes := []rune(cleaned)
	if len(runes) > 200 {
		cleaned = strings.TrimSpace(string(runes[:200]))
	}
	return cleaned
}
