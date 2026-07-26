package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
)

func TestSecretsStayEncryptedAndRequireHistoryPasswordForListing(t *testing.T) {
	directory := t.TempDir()
	s := &session{
		configPath: filepath.Join(directory, "settings.json"),
		cfg:        config.Config{Machine: "Fedora Test"},
		password:   "history-secret",
	}
	put, _ := json.Marshal(map[string]string{"name": "Router", "value": "not-for-history"})
	value, err := s.putSecret(put)
	if err != nil {
		t.Fatal(err)
	}
	id := value.(map[string]any)["id"].(string)
	blob, err := os.ReadFile(s.secretPath())
	if err != nil || !bytes.HasPrefix(blob, []byte("CLIPDB2")) || bytes.Contains(blob, []byte("not-for-history")) {
		t.Fatalf("secret file was not encrypted safely: %v", err)
	}
	wrong, _ := json.Marshal(map[string]string{"password": "wrong"})
	if _, err := s.listSecrets(wrong); err == nil {
		t.Fatal("secret names were listed with the wrong history password")
	}
	correct, _ := json.Marshal(map[string]string{"password": "history-secret"})
	listed, err := s.listSecrets(correct)
	if err != nil || len(listed.(map[string]any)["secrets"].([]secretJSON)) != 1 {
		t.Fatalf("secret list failed: %v %#v", err, listed)
	}
	get, _ := json.Marshal(map[string]string{"id": id})
	secret, err := s.getSecret(get)
	if err != nil || secret.(map[string]string)["value"] != "not-for-history" {
		t.Fatalf("secret retrieval failed: %v %#v", err, secret)
	}
}
