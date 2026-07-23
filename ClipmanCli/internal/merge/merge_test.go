package merge

import (
	"encoding/json"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestMergeTombstoneWinsAndMetadataConverges(t *testing.T) {
	now := int64(2_000_000_000_000)
	target := model.NewDatabase(now)
	target.Entries = []model.Entry{{ID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Text: "deleted", LastUsedUnixMs: 100, CreatedUnixMs: 90}, {ID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", Text: "shared", Name: "old", LastUsedUnixMs: 100, CreatedUnixMs: 80, Pinned: false, Extra: map[string]json.RawMessage{"Future": json.RawMessage(`"old"`)}}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", Text: "shared", Name: "new", Group: "group", SourceMachine: "remote", LastUsedUnixMs: 200, CreatedUnixMs: 80, Pinned: true, Extra: map[string]json.RawMessage{"Future": json.RawMessage(`"new"`)}}}
	source.Deleted = []model.DeletedEntry{{ID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", TextHash: TextHash("deleted"), DeletedUnixMs: now, SourceMachine: "remote"}}
	Merge(&target, source, now)
	if len(target.Entries) != 1 {
		t.Fatalf("entries=%d", len(target.Entries))
	}
	entry := target.Entries[0]
	if entry.Name != "new" || entry.Group != "group" || entry.SourceMachine != "remote" || !entry.Pinned || string(entry.Extra["Future"]) != `"new"` {
		t.Fatalf("bad merge: %+v", entry)
	}
}

func TestNormalizeRepairsZeroTombstoneAndIDs(t *testing.T) {
	now := int64(2_000_000_000_000)
	database := model.NewDatabase(now)
	database.Entries = []model.Entry{{Text: "one"}, {ID: "same", Text: "two"}, {ID: "same", Text: "three"}}
	database.Deleted = []model.DeletedEntry{{ID: "old", DeletedUnixMs: 0}}
	Normalize(&database, now)
	if len(database.Entries) != 3 {
		t.Fatal("entries lost")
	}
	if database.Entries[0].ID == "" || database.Entries[1].ID == database.Entries[2].ID {
		t.Fatal("IDs not repaired")
	}
	if len(database.Deleted) != 1 || database.Deleted[0].DeletedUnixMs != now {
		t.Fatalf("tombstone=%+v", database.Deleted)
	}
}

func TestSameTextEntryRecreatedAfterDeletionSurvives(t *testing.T) {
	now := int64(2_000_000_000_000)
	text := "https://example.com/recreated"
	target := model.NewDatabase(now)
	target.Deleted = []model.DeletedEntry{{ID: "deleted-original", TextHash: TextHash(text), DeletedUnixMs: now - 100}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "new-copy", Text: text, CreatedUnixMs: now, LastUsedUnixMs: now}}
	Merge(&target, source, now)
	if len(target.Entries) != 1 || target.Entries[0].ID != "new-copy" {
		t.Fatalf("recreated entry was removed: %+v", target.Entries)
	}
}

func TestSameTextEntryOlderThanDeletionStaysDeleted(t *testing.T) {
	now := int64(2_000_000_000_000)
	text := "https://example.com/stale"
	target := model.NewDatabase(now)
	target.Deleted = []model.DeletedEntry{{ID: "deleted-original", TextHash: TextHash(text), DeletedUnixMs: now - 100}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "stale-copy", Text: text, CreatedUnixMs: now - 200, LastUsedUnixMs: now - 200}}
	Merge(&target, source, now)
	if len(target.Entries) != 0 {
		t.Fatalf("stale entry survived: %+v", target.Entries)
	}
}

func TestExactDeletedIdentityCannotBeRecreated(t *testing.T) {
	now := int64(2_000_000_000_000)
	text := "https://example.com/deleted-id"
	target := model.NewDatabase(now)
	target.Deleted = []model.DeletedEntry{{ID: "same-id", TextHash: TextHash(text), DeletedUnixMs: now - 100}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "same-id", Text: text, CreatedUnixMs: now, LastUsedUnixMs: now}}
	Merge(&target, source, now)
	if len(target.Entries) != 0 {
		t.Fatalf("deleted identity survived: %+v", target.Entries)
	}
}
