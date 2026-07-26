package main

import (
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestPlaceAfterRespectsPinnedSeparator(t *testing.T) {
	db := model.Database{Entries: []model.Entry{
		{ID: "pin", Text: "pin", Pinned: true, ManualOrder: 1},
		{ID: "first", Text: "first", ManualOrder: 2},
		{ID: "new", Text: "new", ManualOrder: 4},
		{ID: "last", Text: "last", ManualOrder: 3},
	}}
	placeAfter(&db, "new", "first")
	if got := []string{db.Entries[0].ID, db.Entries[1].ID, db.Entries[2].ID, db.Entries[3].ID}; got[0] != "pin" || got[1] != "first" || got[2] != "new" || got[3] != "last" {
		t.Fatalf("unexpected order: %v", got)
	}
	placeAfter(&db, "new", "pin")
	if db.Entries[0].ID != "pin" || db.Entries[1].ID != "new" {
		t.Fatalf("pinned separator was crossed: %#v", db.Entries)
	}
}
