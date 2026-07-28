package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
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
