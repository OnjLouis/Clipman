// Package webpreview provides a loopback-only encrypted transport relay.
package webpreview

import (
	"bytes"
	"crypto/subtle"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const MaxBlobBytes = 64 << 20

var bucketPath = regexp.MustCompile(`^/relay/api/v1/database/[A-Za-z0-9_-]{43}$`)

type Gateway struct {
	upstream, origin, host, key string
	client                      *http.Client
}

func New(upstream, origin, key string, transport http.RoundTripper) (*Gateway, error) {
	u, err := url.Parse(upstream)
	if err != nil {
		return nil, err
	}
	local, err := url.Parse(origin)
	if err != nil {
		return nil, err
	}
	if transport == nil {
		transport = http.DefaultTransport
	}
	return &Gateway{upstream: strings.TrimRight(u.String(), "/"), origin: origin, host: local.Host, key: key,
		client: &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(r *http.Request, via []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func Headers(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; connect-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
}

func (g *Gateway) Allowed(r *http.Request) bool {
	return r.Host == g.host && (r.Header.Get("Origin") == "" || r.Header.Get("Origin") == g.origin) && r.Header.Get("Sec-Fetch-Site") != "cross-site"
}

func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	Headers(w)
	if !g.Allowed(r) || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Clipman-Preview")), []byte(g.key)) != 1 {
		http.Error(w, "request not allowed", http.StatusForbidden)
		return
	}
	if r.Method != "GET" && r.Method != "HEAD" && r.Method != "PUT" {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !bucketPath.MatchString(r.URL.Path) || r.URL.RawQuery != "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var body io.Reader
	if r.Method == "PUT" {
		if r.Header.Get("Origin") != g.origin || (r.Header.Get("If-Match") == "" && r.Header.Get("If-None-Match") != "*") {
			http.Error(w, "conditional encrypted upload required", 400)
			return
		}
		data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBlobBytes))
		if err != nil || !bytes.HasPrefix(data, []byte("CLIPDB2")) {
			http.Error(w, "invalid encrypted upload", 400)
			return
		}
		body = bytes.NewReader(data)
	}
	request, err := http.NewRequestWithContext(r.Context(), r.Method, g.upstream+strings.TrimPrefix(r.URL.Path, "/relay"), body)
	if err != nil {
		http.Error(w, "request failed", 502)
		return
	}
	for _, name := range []string{"Authorization", "If-Match", "If-None-Match"} {
		request.Header.Set(name, r.Header.Get(name))
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	request.Header.Set("User-Agent", "clipman-web-preview")
	response, err := g.client.Do(request)
	if err != nil {
		http.Error(w, "server connection failed", 502)
		return
	}
	defer response.Body.Close()
	if response.StatusCode >= 300 && response.StatusCode < 400 {
		http.Error(w, "server redirect refused", 502)
		return
	}
	for _, name := range []string{"ETag", "X-Clipman-Revision"} {
		if value := response.Header.Get(name); value != "" {
			w.Header().Set(name, value)
		}
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	if response.StatusCode != 200 {
		w.WriteHeader(response.StatusCode)
		return
	}
	if r.Method == "HEAD" {
		w.WriteHeader(200)
		return
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, MaxBlobBytes+1))
	if err != nil || len(data) > MaxBlobBytes {
		http.Error(w, "server response exceeds preview limit", 502)
		return
	}
	w.WriteHeader(200)
	_, _ = w.Write(data)
}
