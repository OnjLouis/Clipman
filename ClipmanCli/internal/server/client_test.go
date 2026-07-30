package server

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestConnectionDetailsText(t *testing.T) {
	input := "Clipman Server connection details\n\nServer address: clipman://server.example:54321\nPort: 54321\nToken: secret-token,\n"
	serverURL, token := ConnectionDetails(input)
	if serverURL != "clipman://server.example:54321" || token != "secret-token" {
		t.Fatalf("details = %q, %q", serverURL, token)
	}
	if CleanToken(input) != "secret-token" {
		t.Fatalf("CleanToken did not extract connection token")
	}
}

func TestConnectionDetailsJSON(t *testing.T) {
	serverURL, token := ConnectionDetails(`{"ServerUrl":"https://example.test/clipman","AuthToken":" token "}`)
	if serverURL != "https://example.test/clipman" || token != "token" {
		t.Fatalf("details = %q, %q", serverURL, token)
	}
}

func TestConnectionDetailsServerSettingsJSON(t *testing.T) {
	serverURL, token := ConnectionDetails(`{"AdvertiseHost":"192.0.2.10","Port":54321,"AuthToken":"token","CertFile":"","KeyFile":""}`)
	if serverURL != "clipman://192.0.2.10:54321" || token != "token" {
		t.Fatalf("details = %q, %q", serverURL, token)
	}
}

func TestConnectionDetailsPortableConfig(t *testing.T) {
	serverURL, token := ConnectionDetails(`{"clipman":"server-connection","version":1,"address":"clipman://server.example:54321","host":"server.example","port":54321,"token":"test-token"}`)
	if serverURL != "clipman://server.example:54321" || token != "test-token" {
		t.Fatalf("details = %q, %q", serverURL, token)
	}
}

func TestConnectionDetailsRejectsUnsupportedPortableConfig(t *testing.T) {
	serverURL, token := ConnectionDetails(`{"clipman":"server-connection","version":2,"address":"clipman://server.example:54321","token":"test-token"}`)
	if serverURL != "" || token != "" {
		t.Fatalf("unsupported details = %q, %q", serverURL, token)
	}
}

func TestNormalizeURLRejectsEmbeddedCredentials(t *testing.T) {
	if _, err := NormalizeURL("https://user:password@example.test"); err == nil {
		t.Fatal("expected embedded-credential rejection")
	}
}

func TestInsecureRemoteURL(t *testing.T) {
	for _, value := range []string{"http://example.test:60000", "http://8.8.8.8:60000"} {
		if !IsInsecureRemoteURL(value) {
			t.Fatalf("expected warning for %s", value)
		}
	}
	for _, value := range []string{"https://example.test:60000", "http://127.0.0.1:60000", "http://192.168.1.2:60000", "http://100.100.1.2:60000"} {
		if IsInsecureRemoteURL(value) {
			t.Fatalf("unexpected warning for %s", value)
		}
	}
}

func TestPutUsesConditionalCreate(t *testing.T) {
	var header string
	testServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header = r.Header.Get("If-None-Match")
		w.Header().Set("X-Clipman-Revision", "one")
		w.WriteHeader(200)
	}))
	defer testServer.Close()
	client, err := New(testServer.URL, "token", "database", "test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = client.Put(context.Background(), []byte("data"), "", true); err != nil {
		t.Fatal(err)
	}
	if header != "*" {
		t.Fatalf("If-None-Match=%q", header)
	}
}

func TestRedirectDoesNotForwardCredentials(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Fatal("redirect target should not receive request") }))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, http.StatusFound) }))
	defer source.Close()
	client, err := New(source.URL, "token", "database", "test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = client.Health(context.Background()); err == nil {
		t.Fatal("expected cross-origin redirect refusal")
	}
}

func TestAdditionalCertificateTrust(t *testing.T) {
	testServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer testServer.Close()
	certificate := testServer.Certificate()
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw})

	client, err := New(testServer.URL, "token", "database", "test", WithCACertPEM(certificatePEM))
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.HTTP.Get(testServer.URL)
	if err != nil {
		t.Fatalf("custom certificate was not trusted: %v", err)
	}
	response.Body.Close()

	pool, err := certPoolWithAdditionalPEM(certificatePEM)
	if err != nil {
		t.Fatal(err)
	}
	systemPool, systemErr := x509.SystemCertPool()
	if systemErr == nil && systemPool != nil && len(pool.Subjects()) < len(systemPool.Subjects()) {
		t.Fatal("additional certificate replaced the system trust store")
	}
}

func TestAdditionalCertificateTrustRejectsInvalidPEM(t *testing.T) {
	if _, err := New("https://example.test", "token", "database", "test", WithCACertPEM([]byte("not a certificate"))); err == nil {
		t.Fatal("expected invalid CA certificate data to be rejected")
	}
}

func TestExclusivePrivateAuthorityTrust(t *testing.T) {
	testServer, authorityPEM := privateAuthorityServer(t)
	defer testServer.Close()
	client, err := New(testServer.URL, "token", "database", "test", WithExclusiveCACertPEM(authorityPEM))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = client.Health(context.Background()); err != nil {
		t.Fatalf("private authority was not trusted: %v", err)
	}
	defaultClient, err := New(testServer.URL, "token", "database", "test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = defaultClient.Health(context.Background()); err == nil {
		t.Fatal("private server unexpectedly passed normal system trust")
	}
}

func privateAuthorityServer(t *testing.T) (*httptest.Server, []byte) {
	t.Helper()
	now := time.Now()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Clipman Test Authority"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true,
		BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leafKeyDER, err := x509.MarshalPKCS8PrivateKey(leafKey)
	if err != nil {
		t.Fatal(err)
	}
	certificateChain := append(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}),
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})...,
	)
	serverCertificate, err := tls.X509KeyPair(
		certificateChain,
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: leafKeyDER}),
	)
	if err != nil {
		t.Fatal(err)
	}
	testServer := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	testServer.TLS = &tls.Config{Certificates: []tls.Certificate{serverCertificate}, MinVersion: tls.VersionTLS12}
	testServer.StartTLS()
	return testServer, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
}
