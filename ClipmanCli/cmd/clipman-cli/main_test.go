package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
)

func testServerWithCertificateChain(t *testing.T) (*httptest.Server, *x509.Certificate, *x509.Certificate) {
	t.Helper()
	now := time.Now()
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Clipman Test Authority"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}

	leafKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatal(err)
	}

	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{leafDER, caDER}, PrivateKey: leafKey}}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server, leaf, ca
}

func TestGlobalParsingStopsAtCommand(t *testing.T) {
	g, remaining, err := parseGlobals([]string{"--server", "clipman://host:60000", "put", "--text", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	if g.server != "clipman://host:60000" {
		t.Fatalf("server = %q", g.server)
	}
	if len(remaining) != 3 || remaining[0] != "put" || remaining[1] != "--text" || remaining[2] != "--json" {
		t.Fatalf("remaining = %#v", remaining)
	}
}

func TestSourceVersionMatchesVersionFile(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "VERSION"))
	if err != nil {
		t.Fatal(err)
	}
	if want := strings.TrimSpace(string(data)); version != want {
		t.Fatalf("source version = %q, VERSION = %q", version, want)
	}
}

func TestCommandHelpDoesNotStealOptionValues(t *testing.T) {
	if hasHelpOption([]string{"--text", "--help"}) {
		t.Fatal("--help used as an option value must not trigger command help")
	}
	if !hasHelpOption([]string{"--help"}) {
		t.Fatal("leading --help should trigger command help")
	}
}

func TestUnknownGlobalOptionFails(t *testing.T) {
	if _, _, err := parseGlobals([]string{"--unknown", "list"}); err == nil {
		t.Fatal("expected unknown global option error")
	}
}

func TestHelpAndUnknownCommandDoNotNeedConfiguration(t *testing.T) {
	if code := run([]string{"help"}); code != 0 {
		t.Fatalf("help exit code = %d", code)
	}
	if code := run([]string{"help", "get"}); code != 0 {
		t.Fatalf("help get exit code = %d", code)
	}
	if code := run([]string{"not-a-command"}); code != 2 {
		t.Fatalf("unknown command exit code = %d", code)
	}
}

func TestResolvePasswordRequiresNonblankValue(t *testing.T) {
	if _, err := resolvePassword(globals{password: optionalString{set: true}}, config.Default(), false); err == nil || !strings.Contains(err.Error(), "nonblank history password") {
		t.Fatalf("blank history password error = %v", err)
	}
	password, err := resolvePassword(globals{password: optionalString{set: true, value: "test-password"}}, config.Default(), false)
	if err != nil || password != "test-password" {
		t.Fatalf("nonblank history password = %q, %v", password, err)
	}
}

func TestCertificateTrustPromptOnlyHandlesUnknownAuthority(t *testing.T) {
	unknown := x509.UnknownAuthorityError{}
	if !isCertificateTrustError(unknown) {
		t.Fatal("unknown authority should offer the trust prompt")
	}
	wrapped := &tls.CertificateVerificationError{Err: unknown}
	if !isCertificateTrustError(wrapped) {
		t.Fatal("wrapped unknown authority should offer the trust prompt")
	}
	if isCertificateTrustError(x509.HostnameError{}) {
		t.Fatal("hostname mismatch must not offer a trust prompt")
	}
	if isCertificateTrustError(x509.CertificateInvalidError{}) {
		t.Fatal("expired or otherwise invalid certificate must not offer a trust prompt")
	}
}

func TestFetchServerCertificatesUsesAuthorityFingerprint(t *testing.T) {
	server, wantLeaf, wantAuthority := testServerWithCertificateChain(t)
	leaf, authority, err := fetchServerCertificates(context.Background(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	if !leaf.Equal(wantLeaf) {
		t.Fatalf("leaf certificate = %q, want %q", leaf.Subject, wantLeaf.Subject)
	}
	if !authority.Equal(wantAuthority) {
		t.Fatalf("authority certificate = %q, want %q", authority.Subject, wantAuthority.Subject)
	}
	if certificateFingerprintSHA256(authority) == certificateFingerprintSHA256(leaf) {
		t.Fatal("authority and leaf fingerprints unexpectedly match")
	}
}
