package main

import (
	"bytes"
	"encoding/base64"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
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

func TestPutAfterImagePreservesBytesAndHonorsImageBudget(t *testing.T) {
	raw := testPNG(t, 4, 3)
	prepared, err := prepareEmbeddedImage("image/png", "Copied photo.png", base64.StdEncoding.EncodeToString(raw))
	if err != nil {
		t.Fatal(err)
	}
	db := model.Database{Entries: []model.Entry{{ID: "selected", Text: "selected", ManualOrder: 1}}}
	changed, _, err := applyPutAfter(&db, putAfterParams{
		AfterID: "selected", Text: prepared.Text, RichText: prepared.RichText,
	}, "Linux test", 100)
	if err != nil || !changed {
		t.Fatalf("put after image failed: changed=%v err=%v", changed, err)
	}
	if len(db.Entries) != 2 || db.Entries[0].ID != "selected" {
		t.Fatalf("image was not inserted after the selected entry: %#v", db.Entries)
	}
	rich, _ := richTextFromEntry(db.Entries[1])
	image, err := parseEmbeddedImageWrapper(rich.HTMLFragment)
	if err != nil || !bytes.Equal(image.Data, raw) || image.Filename != "Copied photo.png" {
		t.Fatalf("stored image changed: image=%#v err=%v", image, err)
	}

	jpegData := testJPEG(t)
	padded := append(append([]byte(nil), jpegData...), bytes.Repeat([]byte{0}, maxStoredImageBytes-len(jpegData))...)
	full := model.Database{}
	for index := 0; index < maxEmbeddedImageBudgetBytes/maxStoredImageBytes; index++ {
		entry := model.Entry{ID: string(rune('a' + index)), Text: "existing " + string(rune('a'+index)), ManualOrder: int64(index + 1)}
		setRichText(&entry, &richTextJSON{
			HTMLFragment:    buildEmbeddedImageWrapper("budget.jpg", "Image: budget.jpg", "image/jpeg", padded),
			PreferredFormat: "Html",
		}, 1)
		full.Entries = append(full.Entries, entry)
	}
	before := len(full.Entries)
	changed, _, err = applyPutAfter(&full, putAfterParams{
		AfterID: full.Entries[0].ID, Text: prepared.Text, RichText: prepared.RichText,
	}, "Linux test", 200)
	if err == nil || changed || len(full.Entries) != before {
		t.Fatalf("over-budget put-after mutated history: changed=%v entries=%d err=%v", changed, len(full.Entries), err)
	}
}
