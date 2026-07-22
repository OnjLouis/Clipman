package operation

import (
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestPutDuplicateModes(t *testing.T) {
	database := model.NewDatabase(1)
	first, outcome := Put(&database, "same", "", "", "machine", "movetotop", "first", false, false, 10)
	if outcome != "created" || first.ID != "first" {
		t.Fatal(outcome)
	}
	moved, outcome := Put(&database, "same", "ignored", "ignored", "other", "movetotop", "second", true, false, 20)
	if outcome != "moved" || moved.ID != "first" || moved.Name != "" || moved.Pinned {
		t.Fatalf("moved=%+v outcome=%s", moved, outcome)
	}
	kept, outcome := Put(&database, "same", "", "", "machine", "keep", "second", false, false, 30)
	if outcome != "created" || kept.ID != "second" || len(database.Entries) != 2 {
		t.Fatalf("kept=%+v outcome=%s", kept, outcome)
	}
}

func TestPutAfterDeleteClearsMatchingTextTombstone(t *testing.T) {
	database := model.NewDatabase(100)
	database.Deleted = []model.DeletedEntry{{ID: "old-id", TextHash: merge.TextHash("same text"), DeletedUnixMs: 100}}
	entry, outcome := Put(&database, "same text", "", "", "test", "keep", "new-id", false, false, 200)
	if outcome != "created" || entry.ID != "new-id" {
		t.Fatalf("outcome=%q entry=%+v", outcome, entry)
	}
	merge.Normalize(&database, 200)
	if len(database.Entries) != 1 || database.Entries[0].ID != "new-id" {
		t.Fatalf("explicit re-add was removed: %+v", database)
	}
	if len(database.Deleted) != 0 {
		t.Fatalf("matching tombstone remains: %+v", database.Deleted)
	}
}

func TestViewIndexesAfterKindFilter(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "history", Text: "h", LastUsedUnixMs: 10}, {ID: "template", Text: "t", IsTemplate: true, LastUsedUnixMs: 20}}
	history := View(database, History, false)
	templates := View(database, Templates, false)
	if len(history) != 1 || history[0].ID != "history" || len(templates) != 1 || templates[0].ID != "template" {
		t.Fatal("kind filter failed")
	}
}
