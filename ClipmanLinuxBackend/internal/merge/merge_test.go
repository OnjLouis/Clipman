package merge

import (
	"encoding/json"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
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

func TestRichTextUsesIndependentTimestampAndSupportsClear(t *testing.T) {
	now := int64(2_000_000_000_000)
	target := model.NewDatabase(now)
	target.Entries = []model.Entry{{
		ID: "rich", Text: "same", LastUsedUnixMs: 500,
		Extra: map[string]json.RawMessage{
			"RichText":              json.RawMessage(`{"Version":1,"HtmlFragment":"<b>same</b>"}`),
			"RichTextUpdatedUnixMs": json.RawMessage(`100`),
		},
	}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{
		ID: "rich", Text: "same", LastUsedUnixMs: 200,
		Extra: map[string]json.RawMessage{
			"RichTextUpdatedUnixMs": json.RawMessage(`300`),
		},
	}}

	Merge(&target, source, now)
	entry := target.Entries[0]
	if _, exists := entry.Extra["RichText"]; exists {
		t.Fatal("newer explicit rich-text clear was ignored")
	}
	if string(entry.Extra["RichTextUpdatedUnixMs"]) != "300" {
		t.Fatalf("rich-text timestamp=%s", entry.Extra["RichTextUpdatedUnixMs"])
	}
}

func TestNewerModificationReplacesEditableEntryState(t *testing.T) {
	now := int64(2_000_000_000_000)
	target := model.NewDatabase(now)
	target.Entries = []model.Entry{{ID: "edited", Text: "old text", Name: "Old", Group: "Old", Pinned: true, IsTemplate: true, ModifiedUnixMs: 100}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "edited", Text: "new text", Name: "New", Group: "New", Pinned: false, IsTemplate: false, ModifiedUnixMs: 200}}

	Merge(&target, source, now)
	entry := target.Entries[0]
	if entry.Text != "new text" || entry.Name != "New" || entry.Group != "New" || entry.Pinned || entry.IsTemplate || entry.ModifiedUnixMs != 200 {
		t.Fatalf("newer modification did not win: %+v", entry)
	}
}

func TestOlderModificationCannotOverwriteNewerEdit(t *testing.T) {
	now := int64(2_000_000_000_000)
	target := model.NewDatabase(now)
	target.Entries = []model.Entry{{ID: "edited", Text: "new text", ModifiedUnixMs: 200}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "edited", Text: "old text", ModifiedUnixMs: 100}}

	Merge(&target, source, now)
	if target.Entries[0].Text != "new text" || target.Entries[0].ModifiedUnixMs != 200 {
		t.Fatalf("older modification won: %+v", target.Entries[0])
	}
}

func TestEmptyTextHashTombstoneMatchesOnlyById(t *testing.T) {
	now := int64(2_000_000_000_000)
	database := model.NewDatabase(now)
	database.Deleted = []model.DeletedEntry{{ID: "a", TextHash: "", DeletedUnixMs: now, SourceMachine: "desktop"}}
	entryA := model.Entry{ID: "a", Text: "anything", CreatedUnixMs: now, LastUsedUnixMs: now}
	entryB := model.Entry{ID: "b", Text: "anything", CreatedUnixMs: now, LastUsedUnixMs: now}
	if !IsDeleted(database, entryA) {
		t.Fatal("relocation tombstone did not delete the entry with its own id")
	}
	if IsDeleted(database, entryB) {
		t.Fatal("relocation tombstone with empty TextHash must not match a different id by text")
	}
}

func TestNewerEntrySurvivesStaleRelocationMarkerWithSameIdentity(t *testing.T) {
	now := int64(2_000_000_000_000)
	target := model.NewDatabase(now)
	target.Deleted = []model.DeletedEntry{{ID: "a", TextHash: "", DeletedUnixMs: now - 1, SourceMachine: "desktop"}}
	entry := model.Entry{ID: "a", Text: "restored", CreatedUnixMs: now, LastUsedUnixMs: now, ModifiedUnixMs: now}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{entry}
	Merge(&target, source, now)
	if len(target.Entries) != 1 || target.Entries[0].ID != "a" {
		t.Fatal("a stale relocation marker deleted a newer entry with the same id")
	}
	if len(target.Deleted) != 0 {
		t.Fatal("a superseded relocation marker remained after the newer entry won")
	}
}

func TestDuplicateTextConvergesOnStableIdentity(t *testing.T) {
	now := int64(2_000_000_000_000)
	first := model.NewDatabase(now)
	first.Entries = []model.Entry{{ID: "b-id", Text: "same text", CreatedUnixMs: 100, LastUsedUnixMs: 200, ModifiedUnixMs: 300}}
	second := model.NewDatabase(now)
	second.Entries = []model.Entry{{ID: "a-id", Text: "same text", CreatedUnixMs: 100, LastUsedUnixMs: 200, ModifiedUnixMs: 300}}
	leftFirst, rightFirst := first, second
	Merge(&leftFirst, second, now)
	Merge(&rightFirst, first, now)
	if len(leftFirst.Entries) != 1 || len(rightFirst.Entries) != 1 || leftFirst.Entries[0].ID != "a-id" || rightFirst.Entries[0].ID != "a-id" {
		t.Fatalf("duplicate text did not converge: left=%+v right=%+v", leftFirst.Entries, rightFirst.Entries)
	}
}

func TestNormalizeKeepsEmptyTextHashTombstones(t *testing.T) {
	now := int64(2_000_000_000_000)

	t.Run("newer relocation marker after older hashed duplicate", func(t *testing.T) {
		database := model.NewDatabase(now)
		database.Deleted = []model.DeletedEntry{
			{ID: "moved", TextHash: TextHash("old text"), DeletedUnixMs: now - 100, SourceMachine: "phone"},
			{ID: "moved", TextHash: "", DeletedUnixMs: now, SourceMachine: "desktop"},
		}
		Normalize(&database, now)
		if len(database.Deleted) != 1 {
			t.Fatalf("expected single deduped tombstone, got %+v", database.Deleted)
		}
		if database.Deleted[0].TextHash != "" {
			t.Fatalf("relocation tombstone lost its empty TextHash: %+v", database.Deleted[0])
		}
	})

	t.Run("older relocation marker stays blank despite newer hashed duplicate", func(t *testing.T) {
		database := model.NewDatabase(now)
		database.Deleted = []model.DeletedEntry{
			{ID: "moved", TextHash: "", DeletedUnixMs: now - 100, SourceMachine: "desktop"},
			{ID: "moved", TextHash: TextHash("old text"), DeletedUnixMs: now, SourceMachine: "phone"},
		}
		Normalize(&database, now)
		if len(database.Deleted) != 1 {
			t.Fatalf("expected single deduped tombstone, got %+v", database.Deleted)
		}
		if database.Deleted[0].TextHash != TextHash("old text") {
			t.Fatalf("expected the newer, hashed marker to win: %+v", database.Deleted[0])
		}
	})
}

func TestLegacySameIdentityRepairsTextFromSource(t *testing.T) {
	now := int64(2_000_000_000_000)
	target := model.NewDatabase(now)
	target.Entries = []model.Entry{{ID: "legacy", Text: "stale text"}}
	source := model.NewDatabase(now)
	source.Entries = []model.Entry{{ID: "legacy", Text: "edited text"}}

	Merge(&target, source, now)
	if target.Entries[0].Text != "edited text" {
		t.Fatalf("legacy text was not repaired: %+v", target.Entries[0])
	}
}
