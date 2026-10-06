package webclient

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"strings"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/agent"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
)

func TestRichAreaDoesNotExpandAgentScope(t *testing.T) {
	db := model.NewDatabase(1)
	raw := json.RawMessage(`{"Version":1,"HtmlFragment":"<h1>Title</h1><b>Bold</b>","RtfBase64":"","PreferredFormat":"Html"}`)
	db.Entries = []model.Entry{
		{ID: "rich", Text: "Title Bold", Extra: map[string]json.RawMessage{"RichText": raw}},
		{ID: "rtf", Text: "RTF text", Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`{"RtfBase64":"e1xydGYxIHRleHR9"}`)}},
		{ID: "template", Text: "hidden", IsTemplate: true, Extra: map[string]json.RawMessage{"RichText": raw}},
		{ID: "plain", Text: "plain", Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`null`)}},
	}
	s := &Session{state: &syncengine.ViewState{View: &db}}
	if p := s.PageForArea("", 0, "rich"); p.Total != 2 {
		t.Fatalf("rich count %d", p.Total)
	}
	if p := s.Page("", 0); p.Total != 1 {
		t.Fatal("rich leaked into Text and Links")
	}
	if agent.Eligible(db.Entries[0]) {
		t.Fatal("agent rich access broadened")
	}
	if _, err := s.Copy("rich"); err == nil {
		t.Fatal("plain-copy path broadened")
	}
	doc, err := s.Rich("rich")
	if err != nil || !strings.Contains(doc.HTML, "<b>Bold</b>") || doc.Text != "Title Bold" {
		t.Fatalf("document %v, %v", doc, err)
	}
	if doc, err := s.Rich("rtf"); err != nil || !doc.RTFOnly || doc.HTML != "" {
		t.Fatal("RTF fallback not explicit")
	}
	if _, err := s.Rich("template"); err == nil {
		t.Fatal("template exposed")
	}
	if string(db.Entries[0].Extra["RichText"]) != string(raw) {
		t.Fatal("stored payload mutated")
	}
}

func TestRichImagesAreBoundedWithoutPixelDecode(t *testing.T) {
	var pngBytes bytes.Buffer
	if err := png.Encode(&pngBytes, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	uri := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngBytes.Bytes())
	clean, err := boundedRichHTML(`<img src="` + uri + `" alt="Test image"><img src="https://example.com/tracker"><img src="data:image/svg+xml;base64,PHN2Zz4=">`)
	if err != nil || !strings.Contains(clean, uri) || strings.Contains(clean, "tracker") || strings.Contains(clean, "PHN2Zz4=") {
		t.Fatalf("unsafe image survived: %v", err)
	}
	var large bytes.Buffer
	_ = png.Encode(&large, image.NewGray(image.Rect(0, 0, 2049, 1)))
	clean, err = boundedRichHTML(`<img src="data:image/png;base64,` + base64.StdEncoding.EncodeToString(large.Bytes()) + `">`)
	if err != nil || strings.Contains(clean, "src=") {
		t.Fatal("oversized image accepted")
	}
	if _, err := boundedRichHTML(strings.Repeat("x", MaxRichHTMLBytes+1)); err == nil {
		t.Fatal("oversized HTML accepted")
	}
}
