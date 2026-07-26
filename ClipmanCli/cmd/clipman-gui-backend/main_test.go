package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestSectionClassification(t *testing.T) {
	tests := map[string]string{
		"https://example.com/a-b":        "links",
		"clipman://server.example:54321": "links",
		"www.example.com":                "links",
		"example.org/path":               "links",
		"See https://example.com":        "text",
		"two words":                      "text",
	}
	for input, want := range tests {
		if got := section(input); got != want {
			t.Errorf("section(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestExportEntryUsesNameThenFirstLine(t *testing.T) {
	named := exportEntry(model.Entry{Name: "Useful", Text: "ignored"})
	if named.Display != "Useful" {
		t.Fatalf("display = %q", named.Display)
	}
	unnamed := exportEntry(model.Entry{Text: "first\nsecond"})
	if unnamed.Display != "first" {
		t.Fatalf("display = %q", unnamed.Display)
	}
}

func TestConfiguredSessionMutationRoundTrip(t *testing.T) {
	var blob []byte
	revision := ""
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.URL.Path == "/api/v1/health" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"status":"ok"}`))
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/api/v1/database/") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		switch r.Method {
		case http.MethodGet:
			if blob == nil {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("X-Clipman-Revision", revision)
			_, _ = w.Write(blob)
		case http.MethodHead:
			if blob == nil {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("X-Clipman-Revision", revision)
			w.WriteHeader(http.StatusOK)
		case http.MethodPut:
			blob, _ = io.ReadAll(r.Body)
			revision = "r1"
			w.Header().Set("X-Clipman-Revision", revision)
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
	testServer := httptest.NewServer(handler)
	defer testServer.Close()
	dir := t.TempDir()
	s := &session{configPath: filepath.Join(dir, "config.toml"), cachePath: filepath.Join(dir, "cache.clipdb")}

	configured, err := s.configure(json.RawMessage(`{"Server":"` + testServer.URL + `","Token":"test-token","Password":"history-pass","Machine":"Linux test","Remember":true}`))
	if err != nil {
		t.Fatalf("configure: %v", err)
	}
	if configured == nil || s.engine == nil {
		t.Fatal("configured session was not activated")
	}
	reconfigured, err := s.configure(json.RawMessage(`{"Server":"` + testServer.URL + `","Token":"","Password":"","Machine":"Saved Linux device","Remember":true}`))
	if err != nil {
		t.Fatalf("reconfigure with protected credentials: %v", err)
	}
	if reconfigured == nil || s.cfg.Machine != "Saved Linux device" {
		t.Fatalf("saved device name was not retained: %#v", reconfigured)
	}
	if token, tokenErr := s.cfg.ResolvedToken(); tokenErr != nil || token != "test-token" {
		t.Fatalf("saved token was not retained: token=%q err=%v", token, tokenErr)
	}
	if password, ok, passwordErr := s.cfg.ResolvedPassword(); passwordErr != nil || !ok || password != "history-pass" {
		t.Fatalf("saved password was not retained: password=%q ok=%v err=%v", password, ok, passwordErr)
	}

	created, err := s.put(json.RawMessage(`{"text":"private text","name":"Example","group":"Tests","pinned":false,"is_template":true,"duplicate":"move"}`))
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	if bytes.Contains(blob, []byte("private text")) {
		t.Fatal("encrypted server blob contains plaintext")
	}
	if len(s.database.Entries) != 1 || !s.database.Entries[0].IsTemplate {
		t.Fatalf("entry was not stored as template: %#v", created)
	}
	s.offline = true
	refreshed, err := s.refresh(false)
	if err != nil {
		t.Fatalf("refresh unchanged revision: %v", err)
	}
	if s.offline || refreshed.(map[string]any)["offline"].(bool) {
		t.Fatal("successful unchanged-revision poll did not leave offline mode")
	}
	id := s.database.Entries[0].ID

	_, err = s.update(json.RawMessage(`{"id":"` + id + `","text":"changed","name":"Renamed","group":"Tests","pinned":true,"is_template":false}`))
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if s.database.Entries[0].Name != "Renamed" || !s.database.Entries[0].Pinned {
		t.Fatal("entry update did not persist")
	}
	if _, err = s.delete(json.RawMessage(`{"id":"` + id + `"}`)); err == nil {
		t.Fatal("pinned deletion was allowed")
	}
	if _, err = s.pin(json.RawMessage(`{"id":"` + id + `","pinned":false}`)); err != nil {
		t.Fatalf("unpin: %v", err)
	}
	if _, err = s.delete(json.RawMessage(`{"id":"` + id + `"}`)); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(s.database.Entries) != 0 || len(s.database.Deleted) != 1 {
		t.Fatal("deletion tombstone was not persisted")
	}

	if _, err = s.put(json.RawMessage(`{"text":"bulk one","name":"One","group":"","pinned":false,"is_template":false,"duplicate":"move"}`)); err != nil {
		t.Fatalf("put first bulk entry: %v", err)
	}
	if _, err = s.put(json.RawMessage(`{"text":"bulk two","name":"Two","group":"","pinned":false,"is_template":false,"duplicate":"move"}`)); err != nil {
		t.Fatalf("put second bulk entry: %v", err)
	}
	if len(s.database.Entries) != 2 {
		t.Fatalf("bulk entries = %d", len(s.database.Entries))
	}
	firstID, secondID := s.database.Entries[0].ID, s.database.Entries[1].ID
	updates, _ := json.Marshal(map[string]any{"entries": []map[string]any{
		{"id": firstID, "text": "bulk one changed", "name": "One", "group": "Bulk", "pinned": false, "is_template": false},
		{"id": secondID, "text": "bulk two changed", "name": "Two", "group": "Bulk", "pinned": false, "is_template": true},
	}})
	if _, err = s.updateMany(updates); err != nil {
		t.Fatalf("update many: %v", err)
	}
	if s.database.Entries[0].Group != "Bulk" || s.database.Entries[1].Group != "Bulk" || !s.database.Entries[1].IsTemplate {
		t.Fatalf("bulk update did not persist: %#v", s.database.Entries)
	}
	ids, _ := json.Marshal(map[string]any{"ids": []string{firstID, secondID}, "pinned": true})
	if _, err = s.pinMany(ids); err != nil {
		t.Fatalf("pin many: %v", err)
	}
	deleteIDs, _ := json.Marshal(map[string]any{"ids": []string{firstID, secondID}})
	if _, err = s.deleteMany(deleteIDs); err == nil {
		t.Fatal("bulk deletion allowed pinned entries")
	}
	unpinIDs, _ := json.Marshal(map[string]any{"ids": []string{firstID, secondID}, "pinned": false})
	if _, err = s.pinMany(unpinIDs); err != nil {
		t.Fatalf("unpin many: %v", err)
	}
	if _, err = s.touchMany(deleteIDs); err != nil {
		t.Fatalf("touch many: %v", err)
	}
	if _, err = s.deleteMany(deleteIDs); err != nil {
		t.Fatalf("delete many: %v", err)
	}
	if len(s.database.Entries) != 0 || len(s.database.Deleted) != 3 {
		t.Fatalf("bulk deletion result: entries=%d tombstones=%d", len(s.database.Entries), len(s.database.Deleted))
	}
}
