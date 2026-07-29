package config

import (
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadRejectsMalformedQuotedString(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, []byte("server = not-quoted\n"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), "strings must be quoted") {
		t.Fatalf("Load error = %v", err)
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	want := Default()
	want.Server = "clipman://example.test:54321"
	want.Token = "token-value"
	want.Machine = "Terminal"
	want.PinnedFirst = true
	want.PasswordMode = "prompt"
	if err := Save(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Server != want.Server || got.Token != want.Token || got.Machine != want.Machine || !got.PinnedFirst {
		t.Fatalf("round trip mismatch: %#v", got)
	}
}

func TestLoadRejectsUnsafeLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	content := "renderer = \"line\"\ndefault_kind = \"history\"\npassword_mode = \"prompt\"\n[limits]\nmax_blob_bytes = -1\n"
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), "max_blob_bytes") {
		t.Fatalf("Load error = %v", err)
	}
}

func TestLoadRejectsUnknownKeyAndSection(t *testing.T) {
	for name, content := range map[string]string{
		"key":     "renderer = \"line\"\ndefault_kind = \"history\"\npassword_mode = \"prompt\"\nunknown = \"value\"\n",
		"section": "renderer = \"line\"\ndefault_kind = \"history\"\npassword_mode = \"prompt\"\n[future]\nvalue = 1\n",
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.toml")
			if err := os.WriteFile(path, []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path); err == nil {
				t.Fatal("expected unknown configuration data to be rejected")
			}
		})
	}
}

func TestValidateRejectsPasswordlessServerProfile(t *testing.T) {
	value := Default()
	value.PasswordMode = "passwordless"
	if err := Validate(value); err == nil || !strings.Contains(err.Error(), "no longer supported") {
		t.Fatalf("passwordless profile error = %v", err)
	}
}

func TestValidateRejectsUnimplementedModesAndAmbiguousPassword(t *testing.T) {
	for name, mutate := range map[string]func(*Config){
		"tui":     func(value *Config) { value.Renderer = "tui" },
		"keyring": func(value *Config) { value.PasswordMode = "keyring" },
		"ambiguous password": func(value *Config) {
			value.PasswordMode = "config"
			value.Password = "one"
			value.PasswordProtected = "two"
		},
	} {
		t.Run(name, func(t *testing.T) {
			value := Default()
			mutate(&value)
			if err := Validate(value); err == nil {
				t.Fatal("expected invalid configuration to be rejected")
			}
		})
	}
}

func TestSaveOmitsUnusedTLSOptions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := Save(path, Default()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "tls_insecure") || strings.Contains(string(data), "ca_cert_pem") {
		t.Fatalf("default config contains unused TLS options:\n%s", data)
	}
}

func TestSaveLoadCertificateTrustRoundTrip(t *testing.T) {
	testServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer testServer.Close()
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: testServer.Certificate().Raw})

	path := filepath.Join(t.TempDir(), "config.toml")
	want := Default()
	want.CACertPEM = string(certificatePEM)
	if err := Save(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.CACertPEM != want.CACertPEM || got.TLSInsecure {
		t.Fatalf("TLS trust round trip mismatch: %#v", got)
	}
}

func TestValidateRejectsConflictingTLSOptions(t *testing.T) {
	value := Default()
	value.TLSInsecure = true
	value.CACertPEM = "certificate"
	if err := Validate(value); err == nil || !strings.Contains(err.Error(), "both") {
		t.Fatalf("conflicting TLS options error = %v", err)
	}
}
