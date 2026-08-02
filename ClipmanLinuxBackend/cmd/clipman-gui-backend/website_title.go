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
	websiteTitleBodyLimit = 128 * 1024
	websiteTitleTimeout   = 8 * time.Second
	websiteTitleURLLimit  = 8192
)

var capabilityWord = regexp.MustCompile(`(?i)(?:^|[-_.~/])(auth|confirm|confirmation|invite|login|magic|oauth|password(?:[-_]?reset)?|recover|recovery|reset|secret|sign[-_]?in|signed|token|verify|verification)(?:$|[-_.~/])`)
var capabilityValueCharacters = regexp.MustCompile(`^[A-Za-z0-9_~.=-]+$`)

var sensitiveQueryNames = map[string]bool{
	"access_token": true, "auth": true, "authorization": true, "code": true,
	"credential": true, "expires": true, "key": true, "magic": true,
	"hmac": true, "jwt": true, "password": true, "policy": true, "reset": true,
	"secret": true, "session": true, "sig": true, "signature": true,
	"signed": true, "ticket": true, "token": true, "awsaccesskeyid": true,
	"googleaccessid": true, "key-pair-id": true,
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
	if capabilityWord.MatchString(strings.ToLower(decodedPath)) {
		return nil, errors.New("this link appears to contain a login, reset, invitation, or other private capability")
	}
	for _, segment := range strings.Split(decodedPath, "/") {
		if looksLikeCapabilityValue(segment) {
			return nil, errors.New("this link appears to contain a private capability value")
		}
	}
	for name, values := range parsed.Query() {
		key := strings.ToLower(strings.TrimSpace(repeatedlyUnescapeURLComponent(name)))
		if sensitiveQueryNames[key] || strings.HasPrefix(key, "x-amz-") || strings.HasPrefix(key, "x-goog-") || capabilityWord.MatchString(key) {
			return nil, errors.New("this link appears to contain a token, signature, or other private capability")
		}
		for _, value := range values {
			value = repeatedlyUnescapeURLComponent(value)
			if looksLikeCapabilityValue(value) {
				return nil, errors.New("this link appears to contain a private capability value")
			}
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
	if len(value) < 32 || !capabilityValueCharacters.MatchString(value) {
		return false
	}
	classes := 0
	if strings.IndexFunc(value, func(character rune) bool { return character >= 'a' && character <= 'z' }) >= 0 {
		classes++
	}
	if strings.IndexFunc(value, func(character rune) bool { return character >= 'A' && character <= 'Z' }) >= 0 {
		classes++
	}
	if strings.IndexFunc(value, func(character rune) bool { return character >= '0' && character <= '9' }) >= 0 {
		classes++
	}
	if strings.ContainsAny(value, "_~.=-") {
		classes++
	}
	unique := map[rune]bool{}
	for _, character := range value {
		unique[character] = true
	}
	return classes >= 3 && len(unique)*100/len([]rune(value)) >= 25
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
		body, readErr := io.ReadAll(io.LimitReader(response.Body, websiteTitleBodyLimit))
		response.Body.Close()
		if readErr != nil {
			return "", errors.New("the website title could not be read")
		}
		title := extractWebsiteTitle(body)
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

func extractWebsiteTitle(body []byte) string {
	if !utf8.Valid(body) {
		body = []byte(strings.ToValidUTF8(string(body), ""))
	}
	tokenizer := xhtml.NewTokenizer(strings.NewReader(string(body)))
	var openGraph, twitter, document strings.Builder
	inTitle := false
	for {
		switch tokenType := tokenizer.Next(); tokenType {
		case xhtml.ErrorToken:
			if tokenizer.Err() != nil && tokenizer.Err() != io.EOF {
				return ""
			}
			for _, candidate := range []string{openGraph.String(), twitter.String(), document.String()} {
				if title := sanitizeWebsiteTitle(candidate); title != "" {
					return title
				}
			}
			return ""
		case xhtml.StartTagToken, xhtml.SelfClosingTagToken:
			token := tokenizer.Token()
			if token.Data == "title" {
				inTitle = true
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
			content := attributes["content"]
			if kind == "og:title" && openGraph.Len() == 0 {
				openGraph.WriteString(content)
			} else if kind == "twitter:title" && twitter.Len() == 0 {
				twitter.WriteString(content)
			}
		case xhtml.EndTagToken:
			if tokenizer.Token().Data == "title" {
				inTitle = false
			}
		case xhtml.TextToken:
			if inTitle {
				document.Write(tokenizer.Text())
			}
		}
	}
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
	runes := []rune(cleaned)
	if len(runes) > 200 {
		cleaned = strings.TrimSpace(string(runes[:200]))
	}
	return cleaned
}
