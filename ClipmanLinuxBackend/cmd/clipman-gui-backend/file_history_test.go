package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/syncengine"
)

func TestFileHistoryRekeysWhenHistoryPasswordChanges(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "Fedora-file-history.clipdb")
	database := model.NewFileDatabase(1)
	database.Events = []model.FileEvent{{ID: "kept", Files: []string{"/tmp/kept.txt"}, FileCount: 1}}
	blob, err := clipdb.EncodeFileHistory(database, "previous password", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, blob, 0600); err != nil {
		t.Fatal(err)
	}

	s := &session{
		configPath: filepath.Join(directory, "settings.json"),
		cfg:        config.Config{Machine: "Fedora"},
		password:   "new password",
		engine:     &syncengine.Engine{Limits: clipdb.DefaultLimits()},
	}
	if err := s.loadFileHistory("previous password"); err != nil {
		t.Fatal(err)
	}
	if !s.fileLoaded || len(s.fileDB.Events) != 1 || s.fileDB.Events[0].ID != "kept" {
		t.Fatalf("file history was not retained: %+v", s.fileDB)
	}
	rekeyed, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := clipdb.DecodeFileHistory(rekeyed, "new password", clipdb.DefaultLimits()); err != nil {
		t.Fatalf("new password did not open rekeyed file history: %v", err)
	}
	if _, err := clipdb.DecodeFileHistory(rekeyed, "previous password", clipdb.DefaultLimits()); err == nil {
		t.Fatal("previous password still opened rekeyed file history")
	}
}

func TestFileHistoryPersistsDeduplicatesAndProtectsPinnedEvents(t *testing.T) {
	directory := t.TempDir()
	first := filepath.Join(directory, "one.txt")
	second := filepath.Join(directory, "two.txt")
	if err := os.WriteFile(first, []byte("one"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte("two"), 0600); err != nil {
		t.Fatal(err)
	}
	s := &session{
		cfg: config.Config{Machine: "Fedora Test"}, password: "secret",
		filePath: filepath.Join(directory, "Fedora_Test-file-history.clipdb"),
		fileDB:   model.NewFileDatabase(1), fileLoaded: true,
	}
	add := func(files ...string) {
		raw, _ := json.Marshal(map[string]any{"files": files, "formats": []string{"text/uri-list"}, "operation": "Copy"})
		if _, err := s.addFileEvent(raw); err != nil {
			t.Fatal(err)
		}
	}
	add(first, second)
	if len(s.fileDB.Events) != 1 {
		t.Fatalf("events=%d", len(s.fileDB.Events))
	}
	id := s.fileDB.Events[0].ID
	add(second, first)
	if len(s.fileDB.Events) != 1 || s.fileDB.Events[0].ID == id {
		t.Fatalf("duplicate was not replaced cleanly: %+v", s.fileDB.Events)
	}
	id = s.fileDB.Events[0].ID
	raw, _ := json.Marshal(map[string]string{"id": id})
	if _, err := s.pinFileEvent(raw); err != nil {
		t.Fatal(err)
	}
	if _, err := s.deleteFileEvent(raw); err == nil {
		t.Fatal("pinned event was deleted")
	}
	blob, err := os.ReadFile(s.filePath)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := clipdb.DecodeFileHistory(blob, "secret", clipdb.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Events) != 1 || !decoded.Events[0].Pinned || decoded.Events[0].SourceMachine != "Fedora Test" {
		t.Fatalf("unexpected persisted file history: %+v", decoded)
	}
}

func TestFileHistoryRemovesUnavailableNormalEventsOnly(t *testing.T) {
	directory := t.TempDir()
	s := &session{
		cfg: config.Config{Machine: "Fedora"}, password: "secret",
		filePath: filepath.Join(directory, "files.clipdb"), fileLoaded: true,
		fileDB: model.FileDatabase{Version: 1, Events: []model.FileEvent{
			{ID: "normal", Files: []string{filepath.Join(directory, "missing")}, FileCount: 1},
			{ID: "pinned", Files: []string{filepath.Join(directory, "also-missing")}, FileCount: 1, Pinned: true},
		}},
	}
	value, err := s.removeUnavailableFileEvents()
	if err != nil {
		t.Fatal(err)
	}
	result := value.(map[string]any)
	if result["removed"] != 1 || len(s.fileDB.Events) != 1 || s.fileDB.Events[0].ID != "pinned" {
		t.Fatalf("unexpected cleanup: result=%v events=%+v", result, s.fileDB.Events)
	}
}

func TestFileHistoryBulkPinAndDelete(t *testing.T) {
	directory := t.TempDir()
	s := &session{
		cfg: config.Config{Machine: "Fedora"}, password: "secret",
		filePath: filepath.Join(directory, "files.clipdb"), fileLoaded: true,
		fileDB: model.FileDatabase{Version: 1, Events: []model.FileEvent{
			{ID: "one", Files: []string{"/tmp/one"}, FileCount: 1},
			{ID: "two", Files: []string{"/tmp/two"}, FileCount: 1},
		}},
	}
	pin, _ := json.Marshal(map[string]any{"ids": []string{"one", "two"}, "pinned": true})
	if _, err := s.pinFileEvents(pin); err != nil || !s.fileDB.Events[0].Pinned || !s.fileDB.Events[1].Pinned {
		t.Fatalf("bulk pin failed: %v %#v", err, s.fileDB.Events)
	}
	deletePinned, _ := json.Marshal(map[string]any{"ids": []string{"one", "two"}})
	if _, err := s.deleteFileEvents(deletePinned); err == nil {
		t.Fatal("bulk delete removed pinned events")
	}
	unpin, _ := json.Marshal(map[string]any{"ids": []string{"one", "two"}, "pinned": false})
	if _, err := s.pinFileEvents(unpin); err != nil {
		t.Fatal(err)
	}
	if _, err := s.deleteFileEvents(deletePinned); err != nil || len(s.fileDB.Events) != 0 {
		t.Fatalf("bulk delete failed: %v %#v", err, s.fileDB.Events)
	}
}

func TestFileHistoryMergeFallsBackToPayloadAndPreservesPinnedBase(t *testing.T) {
	directory := t.TempDir()
	basePath := filepath.Join(directory, "base.txt")
	partialPath := filepath.Join(directory, "partial.txt")
	for path, content := range map[string]string{basePath: "base", partialPath: "partial"} {
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	s := &session{
		cfg: config.Config{Machine: "Fedora"}, password: "secret",
		filePath: filepath.Join(directory, "files.clipdb"), fileLoaded: true,
		fileDB: model.FileDatabase{Version: 1, Events: []model.FileEvent{
			{ID: "base", CapturedUnixMs: 10, Operation: "Copy", Files: []string{basePath}, FileCount: 1, Pinned: true},
			{ID: "partial", CapturedUnixMs: 20, Operation: "Copy", Files: []string{partialPath}, FileCount: 1},
		}},
	}
	raw, _ := json.Marshal(map[string]any{
		"base_files": []string{basePath}, "first_files": []string{partialPath},
		"files": []string{basePath, partialPath}, "formats": []string{"text/uri-list"},
		"operation": "Copy", "source": "Files", "contains_text": true,
	})
	if _, err := s.mergeFileCapture(raw); err != nil {
		t.Fatal(err)
	}
	if len(s.fileDB.Events) != 2 {
		t.Fatalf("unexpected event count after merge: %d", len(s.fileDB.Events))
	}
	var pinned, merged *model.FileEvent
	for index := range s.fileDB.Events {
		event := &s.fileDB.Events[index]
		if event.ID == "base" {
			pinned = event
		}
		if event.ID == "partial" {
			merged = event
		}
	}
	if pinned == nil || !pinned.Pinned || len(pinned.Files) != 1 || pinned.Files[0] != basePath {
		t.Fatalf("pinned base changed: %+v", pinned)
	}
	if merged == nil || merged.Pinned || !sameFileSet(merged.Files, []string{basePath, partialPath}) {
		t.Fatalf("partial event was not replaced safely: %+v", merged)
	}
}
