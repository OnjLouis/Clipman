package main

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestWebsiteTitleURLSafety(t *testing.T) {
	prefix := "https://example.com/"
	exactLimit := prefix + strings.Repeat("a", websiteTitleURLLimit-utf8.RuneCountInString(prefix))
	allowed := []string{
		"https://example.com/articles/useful-page",
		"https://example.com/login",
		"https://example.com/reset-password#instructions",
		"https://www.youtube.com/watch?v=6-fvja4UXJk&pp=ygUbU29uaWNjb3V0dXJlIEJhbGluZXNlIGZsdXRl",
		"http://example.com:80/path",
		"https://example.com:443/path?language=en",
		exactLimit,
	}
	for _, value := range allowed {
		if _, err := validateWebsiteTitleURL(value); err != nil {
			t.Errorf("safe URL %q was rejected: %v", value, err)
		}
	}
	blocked := []string{
		"file:///tmp/example", "clipman://example:1234", "https://user@example.com/",
		"https://localhost/page", "https://printer.local/page", "https://example.com:8443/page",
		"https://example.com/page?token=secret",
		"https://example.com/page?X-Amz-Signature=value",
		"https://example.com/download/aB91kLm302PQrsTUvWxyZ678abcdEFGH",
		"https://[::ffff:8.8.8.8]/",
		exactLimit + "a",
		string([]byte("https://example.com/bad\xffpath")),
	}
	for _, value := range blocked {
		if _, err := validateWebsiteTitleURL(value); err == nil {
			t.Errorf("unsafe URL %q was accepted", value)
		}
	}
	for _, value := range []string{
		"127.0.0.1", "10.0.0.1", "169.254.1.2", "100.64.0.1", "192.0.2.1",
		"192.31.196.1", "192.52.193.1", "192.175.48.1",
		"::1", "fc00::1", "2001:db8::1", "::ffff:10.0.0.1", "64:ff9b::a00:1",
		"2002:0a00:0001::", "fec0::1",
		"100::1", "100:0:0:1::1", "2001:1::1",
		"2620:4f:8000::1", "3fff::1", "5f00::1",
	} {
		if publicAddress(net.ParseIP(value)) {
			t.Errorf("non-global IP %s was accepted", value)
		}
	}
	for _, value := range []string{
		"2606:4700:4700::a00:1", "2606:4700:4700::6440:1",
		"2606:4700:4700::7f00:1", "2606:4700:4700::a9fe:1",
		"2606:4700:4700::ac10:1", "2606:4700:4700::c0a8:1",
	} {
		if publicAddress(net.ParseIP(value)) {
			t.Errorf("global IPv6 address with sensitive IPv4 tail %s was accepted", value)
		}
	}
	if !publicAddress(net.ParseIP("8.8.8.8")) ||
		!publicAddress(net.ParseIP("2606:4700:4700::1111")) ||
		!publicAddress(net.ParseIP("2606:4700:4700::1")) ||
		!publicAddress(net.ParseIP("2606:4700:4700::808:808")) {
		t.Fatal("public IP address was rejected")
	}
}

func TestWebsiteTitleRedirectPolicy(t *testing.T) {
	previous, _ := validateWebsiteTitleURL("https://example.com/previous")
	request, err := resolveWebsiteTitleRedirect(previous, "/final", 2)
	if err != nil {
		t.Fatalf("third redirect was rejected: %v", err)
	}
	if request.String() != "https://example.com/final" {
		t.Fatalf("relative redirect resolved to %q", request)
	}
	if _, err := resolveWebsiteTitleRedirect(previous, "/fourth", 3); err == nil {
		t.Fatal("fourth redirect was accepted")
	}
	if _, err := resolveWebsiteTitleRedirect(previous, "http://example.com/final", 0); err == nil {
		t.Fatal("HTTPS-to-HTTP redirect was accepted")
	}
	if _, err := resolveWebsiteTitleRedirect(previous, "https://127.0.0.1/private", 0); err == nil {
		t.Fatal("redirect to a private literal address was accepted")
	}
	if _, err := resolveWebsiteTitleRedirect(previous, "https://example.com/"+strings.Repeat("b", websiteTitleURLLimit), 0); err == nil {
		t.Fatal("overlong redirect was accepted")
	}
}

func TestWebsiteTitleDNSMustRemainPublicAndDialIsPinned(t *testing.T) {
	originalLookup, originalDial := lookupWebsiteTitleAddresses, dialWebsiteTitleAddress
	defer func() {
		lookupWebsiteTitleAddresses, dialWebsiteTitleAddress = originalLookup, originalDial
	}()
	lookupWebsiteTitleAddresses = func(context.Context, string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("8.8.8.8")}, {IP: net.ParseIP("10.0.0.1")}}, nil
	}
	dialWebsiteTitleAddress = func(context.Context, string, string) (net.Conn, error) {
		t.Fatal("dial attempted after DNS returned a private address")
		return nil, errors.New("unexpected dial")
	}
	if _, err := publicDialContext(context.Background(), "tcp", "example.com:443"); err == nil {
		t.Fatal("mixed public/private DNS result was accepted")
	}

	lookupWebsiteTitleAddresses = func(context.Context, string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("8.8.8.8")}}, nil
	}
	dialed := ""
	dialWebsiteTitleAddress = func(_ context.Context, _ string, address string) (net.Conn, error) {
		dialed = address
		return nil, errors.New("test dial stopped")
	}
	_, _ = publicDialContext(context.Background(), "tcp", "example.com:443")
	if dialed != "8.8.8.8:443" {
		t.Fatalf("dial was not pinned to the validated numeric address: %q", dialed)
	}
}

func TestOverlongWebsiteTitleURLDoesNotResolveOrDial(t *testing.T) {
	originalLookup, originalDial := lookupWebsiteTitleAddresses, dialWebsiteTitleAddress
	defer func() {
		lookupWebsiteTitleAddresses, dialWebsiteTitleAddress = originalLookup, originalDial
	}()
	lookupWebsiteTitleAddresses = func(context.Context, string) ([]net.IPAddr, error) {
		t.Fatal("DNS resolution was attempted for an overlong URL")
		return nil, errors.New("unexpected resolution")
	}
	dialWebsiteTitleAddress = func(context.Context, string, string) (net.Conn, error) {
		t.Fatal("network access was attempted for an overlong URL")
		return nil, errors.New("unexpected dial")
	}
	prefix := "https://example.com/"
	overlong := prefix + strings.Repeat("a", websiteTitleURLLimit-utf8.RuneCountInString(prefix)+1)
	if _, err := fetchWebsiteTitle(overlong); err == nil {
		t.Fatal("overlong URL was accepted")
	}
}

func TestWebsiteTitlePrecedenceAndSanitization(t *testing.T) {
	body := []byte(`<html><head>
		<title>Document &amp; Title</title>
		<meta name="twitter:title" content="Twitter Title">
		<meta content="  Preferred&#10; Open Graph ‮Title  " property="og:title">
	</head></html>`)
	if got := extractWebsiteTitle(body, "example.com"); got != "Preferred Open Graph Title" {
		t.Fatalf("title = %q", got)
	}
	if got := extractWebsiteTitle([]byte(`<title>Document &amp; Title</title>`), "example.com"); got != "Document & Title" {
		t.Fatalf("document title = %q", got)
	}
	unsafe := "Alpha\nBeta\u200dGamma\ufffdDelta\u2028Epsilon\u2029Zeta\u00a0 Eta"
	if got := sanitizeWebsiteTitle(unsafe); got != "AlphaBetaGammaDeltaEpsilonZeta Eta" {
		t.Fatalf("unsafe Unicode was not removed consistently: %q", got)
	}
	if got := sanitizeWebsiteTitle(string([]byte("Good\xffTitle"))); got != "GoodTitle" {
		t.Fatalf("invalid UTF-8 replacement was retained: %q", got)
	}
	long := sanitizeWebsiteTitle(strings.Repeat("x", 250))
	if len([]rune(long)) != 200 {
		t.Fatalf("sanitized title length = %d", len([]rune(long)))
	}
}

func TestWebsiteTitleRetainsMetadataAfterLargeScripts(t *testing.T) {
	body := []byte(`<html><head><script>` + strings.Repeat("x", 180*1024) +
		`</script><meta property="og:title" content="Useful video title"></head></html>`)
	if got := extractWebsiteTitle(body, "youtube.com"); got != "Useful video title" {
		t.Fatalf("script-heavy title = %q", got)
	}
}

func TestWebsiteTitleRejectsMisleadingCandidatesAndUsesSafeH1Fallback(t *testing.T) {
	if got := extractWebsiteTitle([]byte(`<svg><title>Decorative icon</title></svg><h1>Article heading</h1>`), "example.com"); got != "Article heading" {
		t.Fatalf("SVG title was not ignored: %q", got)
	}
	if got := extractWebsiteTitle([]byte(`<title>Reddit - Dive into anything</title>`), "reddit.com"); got != "" {
		t.Fatalf("challenge title was accepted: %q", got)
	}
	if got := extractWebsiteTitle([]byte(`<title>example.com</title>`), "example.com"); got != "" {
		t.Fatalf("host-only title was accepted: %q", got)
	}
}
