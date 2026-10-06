package webclient

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
)

func TestHistoryAreasAndPageBounds(t *testing.T) {
	db := model.NewDatabase(1)
	for i := 0; i < 205; i++ {
		db.Entries = append(db.Entries, model.Entry{ID: fmt.Sprint(i), Text: "ordinary note", CreatedUnixMs: int64(i + 1), Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`null`)}})
	}
	db.Entries = append(db.Entries,
		model.Entry{ID: "link", Text: "https://example.com/path", Name: "Named link"},
		model.Entry{ID: "role-link", Text: "https://example.com/other  Link"},
		model.Entry{ID: "image", Text: "image", Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`{"HtmlFragment":"image"}`)}},
		model.Entry{ID: "template", Text: "template", IsTemplate: true},
	)
	s := &Session{state: &syncengine.ViewState{View: &db}}
	if p := s.PageForArea("", 0, "text"); p.Total != 205 || len(p.Rows) != PageSize {
		t.Fatalf("text area: total %d, rows %d", p.Total, len(p.Rows))
	}
	if p := s.PageForArea("Named", 0, "links"); p.Total != 1 || p.Rows[0].ID != "link" {
		t.Fatal("named link missing from links search")
	}
	if p := s.PageForArea("", 20000, "links"); p.Total != 2 || p.Offset != 0 {
		t.Fatal("switching areas left an invalid page")
	}
	if p := s.PageForArea("", 20000, "text"); p.Offset != 200 || len(p.Rows) != 5 {
		t.Fatal("shrinking history did not clamp to the last page")
	}
	if p := s.Page("", 0); p.Total != 207 {
		t.Fatalf("combined count: %d", p.Total)
	}
	if p := s.PageForArea("missing", 100, "links"); p.Offset != 0 || p.Total != 0 || len(p.Rows) != 0 {
		t.Fatal("empty search retained an invalid offset")
	}
}

func TestLinkClassificationMatchesDesktop(t *testing.T) {
	for _, tc := range []struct {
		text string
		want bool
	}{
		{"https://example.com/path", true},
		{" HTTP://example.com ", true},
		{"clipman://example.com:123", true},
		{"https://example.com  link", true},
		{"https://example.com  LINK", true},
		{"A note containing https://example.com", false},
		{"https://example.com\nlink", false},
		{"https://", false},
		{"file:///private/file.txt", false},
		{"javascript:alert(1)", false},
	} {
		if isLinkOnlyText(tc.text) != tc.want {
			t.Errorf("classification for %q", tc.text)
		}
	}
}
