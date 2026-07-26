package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestApplyImportMergesAndReplaces(t *testing.T) {
	base := model.NewDatabase(100)
	base.Entries = []model.Entry{{ID: "old", Text: "old", ManualOrder: 1, CreatedUnixMs: 50, LastUsedUnixMs: 50}}
	imported := model.NewDatabase(200)
	imported.Entries = []model.Entry{
		{ID: "ignored", Text: "first", Name: "Named", Group: "Work", SourceMachine: "Mac", ManualOrder: 2, CreatedUnixMs: 20, LastUsedUnixMs: 30, Pinned: true},
		{ID: "ignored-too", Text: "second", ManualOrder: 1, CreatedUnixMs: 10, LastUsedUnixMs: 11},
	}
	if count := applyImport(&base, imported, false, "Linux", 300); count != 2 {
		t.Fatalf("merge count = %d", count)
	}
	if len(base.Entries) != 3 {
		t.Fatalf("merge entries = %d", len(base.Entries))
	}
	if count := applyImport(&base, imported, true, "Linux", 400); count != 2 {
		t.Fatalf("replace count = %d", count)
	}
	if len(base.Entries) != 2 {
		t.Fatalf("replace entries = %d", len(base.Entries))
	}
	if base.Entries[0].Text != "second" || base.Entries[1].Text != "first" {
		t.Fatalf("manual order was not preserved: %#v", base.Entries)
	}
	if !base.Entries[1].Pinned || base.Entries[1].Group != "Work" || base.Entries[1].SourceMachine != "Mac" {
		t.Fatalf("metadata was not preserved: %#v", base.Entries[1])
	}
}

func TestPasswordMatches(t *testing.T) {
	if !passwordMatches("correct horse", "correct horse") {
		t.Fatal("equal passwords did not match")
	}
	if passwordMatches("correct horse", "wrong horse") {
		t.Fatal("different passwords matched")
	}
}

func TestExportHistoryRequiresCurrentPasswordAndAppliesChosenProtection(t *testing.T) {
	directory := t.TempDir()
	s := &session{password: "current-secret", database: model.NewDatabase(100)}
	s.database.Entries = []model.Entry{{ID: "one", Text: "private text", CreatedUnixMs: 100, LastUsedUnixMs: 100, ManualOrder: 1}}

	wrong, _ := json.Marshal(map[string]any{"path": filepath.Join(directory, "wrong"), "current_password": "wrong", "mode": "none"})
	if _, err := s.exportHistory(wrong); err == nil {
		t.Fatal("export accepted the wrong current password")
	}

	for _, test := range []struct {
		name, mode, newPassword, decodePassword string
	}{
		{"current", "current", "", "current-secret"},
		{"new", "new", "replacement-secret", "replacement-secret"},
		{"none", "none", "", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(directory, test.name)
			raw, _ := json.Marshal(map[string]any{
				"path": path, "current_password": "current-secret", "mode": test.mode, "export_password": test.newPassword,
			})
			if _, err := s.exportHistory(raw); err != nil {
				t.Fatalf("export failed: %v", err)
			}
			blob, err := os.ReadFile(path + ".clipdb")
			if err != nil {
				t.Fatal(err)
			}
			database, err := clipdb.Decode(blob, test.decodePassword, clipdb.DefaultLimits())
			if err != nil || len(database.Entries) != 1 || database.Entries[0].Text != "private text" {
				t.Fatalf("export decode failed: %v %#v", err, database.Entries)
			}
		})
	}
}
