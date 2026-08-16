package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var ErrNotFound = errors.New("database not found")
var ErrConflict = errors.New("database revision conflict")
var ErrUnauthorized = errors.New("server authentication failed")

type Client struct {
	BaseURL, Token, DatabaseID, Version string
	MaxBlobBytes                        int64
	HTTP                                *http.Client
}
type Download struct {
	Data     []byte
	Revision string
}
type Metadata struct {
	Revision string
	Length   int64
}

// Option customizes the TLS trust behavior of a Client. By default the
// system trust store is used, matching Go's standard certificate verification.
type Option func(*tlsSettings)
type tlsSettings struct {
	insecureSkipVerify bool
	caCertPEM          []byte
	exclusiveCACertPEM []byte
}

// WithInsecureSkipVerify disables TLS certificate verification entirely.
// Only safe on a trusted private network; prefer WithCACertPEM instead.
func WithInsecureSkipVerify() Option {
	return func(s *tlsSettings) { s.insecureSkipVerify = true }
}

// WithCACertPEM trusts the given PEM-encoded certificate(s) in addition to
// verifying the standard chain of trust, allowing a self-signed server
// certificate to be used without disabling verification altogether.
func WithCACertPEM(pem []byte) Option {
	return func(s *tlsSettings) { s.caCertPEM = pem }
}

// WithExclusiveCACertPEM trusts only the supplied private authority for the
// configured server host. It is used for CA-bearing Clipman connection files.
func WithExclusiveCACertPEM(pem []byte) Option {
	return func(s *tlsSettings) { s.exclusiveCACertPEM = append([]byte(nil), pem...) }
}

type AuthorityDetails struct {
	PEM, Host, Subject, Fingerprint string
	Expires                         time.Time
}

func ParsePrivateAuthority(value []byte, rawURL string) (AuthorityDetails, error) {
	if len(bytes.TrimSpace(value)) == 0 {
		return AuthorityDetails{}, nil
	}
	if len(value) > 32*1024 {
		return AuthorityDetails{}, errors.New("private certificate authority exceeds the 32 KiB limit")
	}
	if bytes.Contains(bytes.ToUpper(value), []byte("PRIVATE KEY")) {
		return AuthorityDetails{}, errors.New("private certificate authority must not contain private key material")
	}
	block, rest := pem.Decode(value)
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return AuthorityDetails{}, errors.New("private certificate authority must contain exactly one PEM CERTIFICATE block")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return AuthorityDetails{}, fmt.Errorf("invalid private certificate authority: %w", err)
	}
	if !certificate.IsCA {
		return AuthorityDetails{}, errors.New("configured certificate is not marked as a certificate authority")
	}
	if certificate.KeyUsage != 0 && certificate.KeyUsage&x509.KeyUsageCertSign == 0 {
		return AuthorityDetails{}, errors.New("configured certificate authority cannot sign certificates")
	}
	now := time.Now()
	if now.Before(certificate.NotBefore) {
		return AuthorityDetails{}, errors.New("configured certificate authority is not valid yet")
	}
	if now.After(certificate.NotAfter) {
		return AuthorityDetails{}, errors.New("configured certificate authority has expired")
	}
	normalized, err := NormalizeURL(rawURL)
	if err != nil {
		return AuthorityDetails{}, err
	}
	parsed, _ := url.Parse(normalized)
	if parsed == nil || parsed.Scheme != "https" || parsed.Hostname() == "" {
		return AuthorityDetails{}, errors.New("a private certificate authority can be used only with an HTTPS server address")
	}
	digest := sha256.Sum256(certificate.Raw)
	parts := make([]string, len(digest))
	for index, item := range digest {
		parts[index] = fmt.Sprintf("%02X", item)
	}
	return AuthorityDetails{
		PEM:  string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw})),
		Host: parsed.Hostname(), Subject: certificate.Subject.String(), Expires: certificate.NotAfter,
		Fingerprint: strings.Join(parts, ":"),
	}, nil
}

func certPoolWithAdditionalPEM(data []byte) (*x509.CertPool, error) {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if !pool.AppendCertsFromPEM(data) {
		return nil, errors.New("no valid certificates found in CA certificate data")
	}
	return pool, nil
}

func New(rawURL, token, databaseID, version string, opts ...Option) (*Client, error) {
	normalized, err := NormalizeURL(rawURL)
	if err != nil {
		return nil, err
	}
	var settings tlsSettings
	for _, opt := range opts {
		opt(&settings)
	}
	if len(settings.caCertPEM) > 0 && len(settings.exclusiveCACertPEM) > 0 {
		return nil, errors.New("additional and exclusive certificate authority options cannot be combined")
	}
	transport := &http.Transport{DialContext: (&net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}).DialContext, ResponseHeaderTimeout: 8 * time.Second, TLSHandshakeTimeout: 8 * time.Second}
	if settings.insecureSkipVerify {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}
	} else if len(settings.caCertPEM) > 0 {
		pool, poolErr := certPoolWithAdditionalPEM(settings.caCertPEM)
		if poolErr != nil {
			return nil, poolErr
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	} else if len(settings.exclusiveCACertPEM) > 0 {
		authority, parseErr := ParsePrivateAuthority(settings.exclusiveCACertPEM, normalized)
		if parseErr != nil {
			return nil, parseErr
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM([]byte(authority.PEM)) {
			return nil, errors.New("could not load private certificate authority")
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second}
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) > 0 && (req.URL.Host != via[0].URL.Host || req.URL.Scheme != via[0].URL.Scheme) {
			return errors.New("refusing to forward Clipman credentials to another server")
		}
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		return nil
	}
	return &Client{BaseURL: normalized, Token: CleanToken(token), DatabaseID: databaseID, Version: version, MaxBlobBytes: 64 << 20, HTTP: client}, nil
}
func NormalizeURL(value string) (string, error) {
	value = strings.TrimSpace(value)
	if extracted, _ := ConnectionDetails(value); extracted != "" {
		value = extracted
	}
	if value == "" {
		return "", errors.New("server address is required")
	}
	if !strings.Contains(value, "://") {
		value = "clipman://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "", err
	}
	if parsed.Scheme == "clipman" {
		parsed.Scheme = "http"
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("unsupported server scheme %q", parsed.Scheme)
	}
	if parsed.Host == "" {
		return "", errors.New("server host is required")
	}
	if parsed.User != nil {
		return "", errors.New("server addresses cannot contain embedded credentials")
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return parsed.String(), nil
}
func CleanToken(value string) string {
	value = strings.TrimSpace(value)
	if _, extracted := ConnectionDetails(value); extracted != "" {
		return extracted
	}
	value = strings.Trim(value, "\"'")
	value = strings.TrimRight(value, ",;")
	return strings.TrimSpace(value)
}

func ConnectionDetails(value string) (serverURL, token string) {
	serverURL, token, _, _ = ConnectionProfile(value)
	return serverURL, token
}

func ConnectionProfile(value string) (serverURL, token, caCertPEM string, err error) {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "{") {
		var raw map[string]any
		if json.Unmarshal([]byte(value), &raw) == nil {
			if marker, present := raw["clipman"]; present {
				if marker != "server-connection" || jsonNumber(raw, "version") != "1" {
					return "", "", "", errors.New("unsupported Clipman Server connection-file version")
				}
			}
			if item, ok := raw["ca_cert_pem"].(string); ok {
				caCertPEM = strings.TrimSpace(item)
			}
			for _, key := range []string{"address", "ServerAddress", "serverAddress", "ServerUrl", "serverUrl", "ServerURL", "serverURL", "ListenPrefix", "listenPrefix"} {
				if item, ok := raw[key].(string); ok && strings.TrimSpace(item) != "" {
					serverURL = strings.TrimSpace(item)
					break
				}
			}
			for _, key := range []string{"AuthToken", "authToken", "token", "Token"} {
				if item, ok := raw[key].(string); ok && strings.TrimSpace(item) != "" {
					token = canonicalToken(item)
					break
				}
			}
			if serverURL == "" {
				host := jsonString(raw, "AdvertiseHost", "advertiseHost", "Host", "host")
				port := jsonNumber(raw, "Port", "port")
				if host != "" && port != "" {
					scheme := "clipman"
					if jsonString(raw, "CertFile", "certFile") != "" && jsonString(raw, "KeyFile", "keyFile") != "" {
						scheme = "https"
					}
					serverURL = scheme + "://" + host + ":" + port
				}
			}
		}
	}
	for _, line := range strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(parts[0]))
		item := strings.TrimSpace(parts[1])
		switch key {
		case "server address", "server", "server url":
			if item != "" {
				serverURL = item
			}
		case "token", "auth token", "authtoken":
			if item != "" {
				token = canonicalToken(item)
			}
		}
	}
	if caCertPEM != "" {
		authority, parseErr := ParsePrivateAuthority([]byte(caCertPEM), serverURL)
		if parseErr != nil {
			return "", "", "", parseErr
		}
		caCertPEM = authority.PEM
	}
	return serverURL, token, caCertPEM, nil
}

func jsonString(raw map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := raw[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func jsonNumber(raw map[string]any, keys ...string) string {
	for _, key := range keys {
		switch value := raw[key].(type) {
		case float64:
			if value > 0 && value <= 65535 && value == float64(int(value)) {
				return fmt.Sprintf("%d", int(value))
			}
		case string:
			if strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
	}
	return ""
}

func canonicalToken(value string) string {
	value = strings.TrimSpace(value)
	value = strings.Trim(value, "\"'")
	value = strings.TrimRight(value, ",;")
	return strings.TrimSpace(value)
}

func IsInsecureRemoteURL(value string) bool {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "http" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".local") {
		return false
	}
	address := net.ParseIP(host)
	if address == nil {
		return true
	}
	if address.IsLoopback() || address.IsPrivate() || address.IsLinkLocalUnicast() {
		return false
	}
	if ipv4 := address.To4(); ipv4 != nil && ipv4[0] == 100 && ipv4[1] >= 64 && ipv4[1] <= 127 {
		return false
	}
	return true
}
func (c *Client) Health(ctx context.Context) (map[string]any, error) {
	request, err := c.request(ctx, http.MethodGet, "/api/v1/health", nil)
	if err != nil {
		return nil, err
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return nil, statusError(response)
	}
	var result map[string]any
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&result); err != nil {
		return nil, err
	}
	return result, nil
}
func (c *Client) Head(ctx context.Context) (Metadata, error) {
	request, err := c.request(ctx, http.MethodHead, c.databasePath(), nil)
	if err != nil {
		return Metadata{}, err
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return Metadata{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return Metadata{}, statusError(response)
	}
	return Metadata{Revision: revision(response), Length: response.ContentLength}, nil
}
func (c *Client) Get(ctx context.Context) (Download, error) {
	request, err := c.request(ctx, http.MethodGet, c.databasePath(), nil)
	if err != nil {
		return Download{}, err
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return Download{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return Download{}, statusError(response)
	}
	limit := c.MaxBlobBytes
	if limit <= 0 {
		limit = 64 << 20
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return Download{}, err
	}
	if int64(len(data)) > limit {
		return Download{}, fmt.Errorf("server database exceeds %d-byte limit", limit)
	}
	return Download{Data: data, Revision: revision(response)}, nil
}
func (c *Client) Put(ctx context.Context, data []byte, expected string, createOnly bool) (Metadata, error) {
	request, err := c.request(ctx, http.MethodPut, c.databasePath(), bytes.NewReader(data))
	if err != nil {
		return Metadata{}, err
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	if createOnly {
		request.Header.Set("If-None-Match", "*")
	} else if strings.TrimSpace(expected) != "" {
		request.Header.Set("If-Match", fmt.Sprintf("%q", strings.Trim(expected, "\"")))
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return Metadata{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return Metadata{}, statusError(response)
	}
	return Metadata{Revision: revision(response), Length: int64(len(data))}, nil
}
func (c *Client) request(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+c.Token)
	request.Header.Set("User-Agent", "clipman-cli/"+c.Version)
	return request, nil
}
func (c *Client) databasePath() string { return "/api/v1/database/" + url.PathEscape(c.DatabaseID) }
func revision(response *http.Response) string {
	return strings.Trim(strings.TrimSpace(first(response.Header.Get("X-Clipman-Revision"), response.Header.Get("ETag"))), "\"")
}
func first(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

// StatusError is a response the client could not turn into a result and has no
// sentinel for. The status code is kept rather than only formatted into a
// message, because the caller has to tell a server fault from a local one to
// choose an exit code, and parsing that back out of a string would be worse.
type StatusError struct {
	StatusCode int
	Body       string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("Clipman Server returned HTTP %d: %s", e.StatusCode, e.Body)
}

// Remote reports whether the status is the server's fault rather than the
// request's. 413 and 5xx are the server declining or failing, which is the same
// class of problem as an unreachable server: nothing the caller sent is wrong,
// and retrying later may work.
func (e *StatusError) Remote() bool {
	return e.StatusCode == http.StatusRequestEntityTooLarge || e.StatusCode >= 500
}

func statusError(response *http.Response) error {
	switch response.StatusCode {
	case 401, 403:
		return ErrUnauthorized
	case 404:
		return ErrNotFound
	case 409, 412:
		return ErrConflict
	}
	body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	return &StatusError{StatusCode: response.StatusCode, Body: strings.TrimSpace(string(body))}
}
