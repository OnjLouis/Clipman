package rules

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestChannelKeyGrammar(t *testing.T) {
	if got := ChannelKey("Work "); got != "work" {
		t.Fatalf("ChannelKey(%q) = %q, want %q", "Work ", got, "work")
	}
	if got := ChannelKey("Desktop Only"); got != "desktop only" {
		t.Fatalf("ChannelKey(%q) = %q, want %q", "Desktop Only", got, "desktop only")
	}
	if got := ChannelKey("-bad"); got != "" {
		t.Fatalf("ChannelKey(%q) = %q, want empty", "-bad", got)
	}
	if got := ChannelKey(strings.Repeat("a", 33)); got != "" {
		t.Fatalf("ChannelKey(33-char name) = %q, want empty", got)
	}
	if got := ChannelKey("café"); got != "" {
		t.Fatalf("ChannelKey(non-ASCII name) = %q, want empty", got)
	}

	for _, reserved := range []string{"core", "all", "pinned", "sync-rules"} {
		doc := &Document{
			Clipman: "sync-rules",
			Enabled: true,
			Channels: []Channel{
				{Name: reserved, Route: Route{Groups: []string{"Work"}}},
			},
		}
		if err := Validate(doc); err == nil {
			t.Errorf("Validate must reject a channel named %q as reserved", reserved)
		}
	}
}

func TestValidateRejectsInvalidDocuments(t *testing.T) {
	base := func() *Document {
		return &Document{
			Clipman: "sync-rules",
			Enabled: true,
			Channels: []Channel{
				{Name: "Work", Route: Route{Groups: []string{"Work"}}},
			},
		}
	}

	tests := map[string]*Document{
		"nil document":        nil,
		"wrong Clipman field": {Clipman: "not-sync-rules"},
	}
	for name, doc := range tests {
		if err := Validate(doc); err == nil {
			t.Errorf("%s: Validate must return an error", name)
		}
	}

	invalidName := base()
	invalidName.Channels[0].Name = "-bad"
	if err := Validate(invalidName); err == nil {
		t.Error("invalid channel name: Validate must return an error")
	}

	duplicate := base()
	duplicate.Channels = append(duplicate.Channels, Channel{Name: "WORK", Route: Route{Groups: []string{"Other"}}})
	if err := Validate(duplicate); err == nil {
		t.Error("duplicate channel key: Validate must return an error")
	}

	noCondition := base()
	noCondition.Channels[0].Route = Route{}
	if err := Validate(noCondition); err == nil {
		t.Error("route with no conditions: Validate must return an error")
	}

	badKind := base()
	badKind.Channels[0].Route = Route{Kind: "Bogus"}
	if err := Validate(badKind); err == nil {
		t.Error("unsupported Kind: Validate must return an error")
	}

	unknownDeviceChannel := base()
	unknownDeviceChannel.Devices = []Device{{Name: "Desktop", Channels: []string{"nonexistent"}}}
	if err := Validate(unknownDeviceChannel); err == nil {
		t.Error("device referencing an unknown channel: Validate must return an error")
	}

	mixedWildcard := base()
	mixedWildcard.Devices = []Device{{Name: "Desktop", Channels: []string{"*", "work"}}}
	if err := Validate(mixedWildcard); err == nil {
		t.Error("device Channels mixing \"*\" with named keys: Validate must return an error")
	}
}

func TestValidateRejectsMixedWildcardDeviceChannels(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Work", Route: Route{Groups: []string{"Work"}}},
		},
		Devices: []Device{
			{Name: "Desktop", Channels: []string{"*", "work"}},
		},
	}
	if err := Validate(doc); err == nil {
		t.Fatal("Validate must reject a device Channels list that mixes \"*\" with named keys")
	}

	data, err := Serialize(doc)
	if err != nil {
		t.Fatalf("Serialize error: %v", err)
	}
	if _, err := Parse(data); err == nil {
		t.Fatal("Parse must reject a device Channels list that mixes \"*\" with named keys")
	}
}

func TestValidateAcceptsWellFormedDocument(t *testing.T) {
	doc := &Document{
		Clipman:       "sync-rules",
		Version:       1,
		Enabled:       true,
		UpdatedUnixMs: 1757200000000,
		UpdatedBy:     "Desktop",
		Channels: []Channel{
			{Name: "Images", Route: Route{Kind: "RichTextImages"}},
			{Name: "Work", Route: Route{Groups: []string{"Work", "Standup"}}},
			{Name: "Desktop only", Route: Route{SourceDevices: []string{"Desktop", "Work-PC"}}},
		},
		Devices: []Device{
			{Name: "Desktop", Channels: []string{"*"}},
			{Name: "Jeff-iPhone", Channels: []string{"work"}},
			{Name: "Work-PC", Channels: []string{"work", "desktop only"}},
		},
	}
	if err := Validate(doc); err != nil {
		t.Fatalf("Validate rejected a well-formed document: %v", err)
	}
}

func richTextEntry(html string) *model.Entry {
	raw, _ := json.Marshal(map[string]string{"HtmlFragment": html})
	return &model.Entry{Extra: map[string]json.RawMessage{"RichText": json.RawMessage(raw)}}
}

func TestRouteFirstMatchWins(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Images", Route: Route{Kind: "RichTextImages"}},
			{Name: "Work", Route: Route{Groups: []string{"Work"}}},
		},
	}
	entry := richTextEntry(`<img src="data:image/png;base64,AAAA">`)
	entry.Group = "Work"
	if got := RouteEntry(doc, entry); got != "images" {
		t.Fatalf("RouteEntry = %q, want %q", got, "images")
	}
}

func TestRouteConditionsAreAnded(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Desktop only", Route: Route{Groups: []string{"Work"}, SourceDevices: []string{"Desktop"}}},
		},
	}
	entry := &model.Entry{Group: "Work", SourceMachine: "Phone"}
	if got := RouteEntry(doc, entry); got != "" {
		t.Fatalf("RouteEntry = %q, want empty when only one of two ANDed conditions matches", got)
	}
}

func TestRouteUnmatchedGoesToCore(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Work", Route: Route{Groups: []string{"Work"}}},
		},
	}
	entry := &model.Entry{Group: "Personal"}
	if got := RouteEntry(doc, entry); got != "" {
		t.Fatalf("RouteEntry = %q, want empty (core)", got)
	}
}

func TestRouteDisabledDocRoutesEverythingToCore(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: false,
		Channels: []Channel{
			{Name: "Work", Route: Route{Groups: []string{"Work"}}},
		},
	}
	entry := &model.Entry{Group: "Work"}
	if got := RouteEntry(doc, entry); got != "" {
		t.Fatalf("RouteEntry = %q, want empty when doc disabled", got)
	}
	if got := RouteEntry(nil, entry); got != "" {
		t.Fatalf("RouteEntry(nil doc) = %q, want empty", got)
	}
}

func TestRouteKindRichTextImages(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Images", Route: Route{Kind: "RichTextImages"}},
		},
	}
	if got := RouteEntry(doc, richTextEntry(`<img src="data:image/png;base64,AAAA">`)); got != "images" {
		t.Fatalf("RouteEntry(with embedded image) = %q, want %q", got, "images")
	}
	if got := RouteEntry(doc, richTextEntry("<b>plain</b>")); got != "" {
		t.Fatalf("RouteEntry(rich text without image) = %q, want empty", got)
	}
	malformed := &model.Entry{Extra: map[string]json.RawMessage{"RichText": json.RawMessage("{not json")}}
	if got := RouteEntry(doc, malformed); got != "" {
		t.Fatalf("RouteEntry(malformed RichText payload) = %q, want empty", got)
	}
	if got := RouteEntry(doc, &model.Entry{}); got != "" {
		t.Fatalf("RouteEntry(no rich text at all) = %q, want empty", got)
	}
}

func TestSubscribedUnknownDeviceGetsAll(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Work", Route: Route{Groups: []string{"Work"}}},
		},
		Devices: []Device{
			{Name: "Desktop", Channels: []string{"work"}},
		},
	}
	if got := SubscribedChannels(doc, "Unknown-Device"); got != nil {
		t.Fatalf("SubscribedChannels(unlisted device) = %v, want nil", got)
	}
}

func TestSubscribedStarExpandsToAllChannels(t *testing.T) {
	doc := &Document{
		Clipman: "sync-rules",
		Enabled: true,
		Channels: []Channel{
			{Name: "Images", Route: Route{Kind: "RichTextImages"}},
			{Name: "Work", Route: Route{Groups: []string{"Work"}}},
		},
		Devices: []Device{
			{Name: "Desktop", Channels: []string{"*"}},
		},
	}
	got := SubscribedChannels(doc, "desktop")
	want := []string{"images", "work"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("SubscribedChannels(star) = %v, want %v", got, want)
	}
}

func TestMergeDocumentsLastWriterWins(t *testing.T) {
	older := &Document{Clipman: "sync-rules", UpdatedUnixMs: 100, UpdatedBy: "Alpha"}
	newer := &Document{Clipman: "sync-rules", UpdatedUnixMs: 200, UpdatedBy: "Beta"}
	if got := MergeDocuments(older, newer); got != newer {
		t.Fatal("MergeDocuments must pick the document with the newer UpdatedUnixMs")
	}
	if got := MergeDocuments(newer, older); got != newer {
		t.Fatal("MergeDocuments must pick the newer document regardless of argument order")
	}

	tieLow := &Document{Clipman: "sync-rules", UpdatedUnixMs: 100, UpdatedBy: "Alpha"}
	tieHigh := &Document{Clipman: "sync-rules", UpdatedUnixMs: 100, UpdatedBy: "Beta"}
	if got := MergeDocuments(tieLow, tieHigh); got != tieHigh {
		t.Fatal("MergeDocuments must break a timestamp tie toward the greater UpdatedBy string")
	}
	if got := MergeDocuments(tieHigh, tieLow); got != tieHigh {
		t.Fatal("MergeDocuments must break a timestamp tie toward the greater UpdatedBy string regardless of order")
	}

	if got := MergeDocuments(nil, newer); got != newer {
		t.Fatal("MergeDocuments(nil, x) must return x")
	}
	if got := MergeDocuments(newer, nil); got != newer {
		t.Fatal("MergeDocuments(x, nil) must return x")
	}
}

func TestSerializeParseRoundTrip(t *testing.T) {
	doc := &Document{
		Clipman:       "sync-rules",
		Version:       1,
		Enabled:       true,
		UpdatedUnixMs: 1757200000000,
		UpdatedBy:     "Desktop",
		Channels: []Channel{
			{Name: "Images", Route: Route{Kind: "RichTextImages"}},
			{Name: "Work", Route: Route{Groups: []string{"Work", "Standup"}}},
		},
		Devices: []Device{
			{Name: "Desktop", Channels: []string{"*"}},
			{Name: "Jeff-iPhone", Channels: []string{"work"}},
		},
	}
	data, err := Serialize(doc)
	if err != nil {
		t.Fatalf("Serialize error: %v", err)
	}
	got, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	if !reflect.DeepEqual(doc, got) {
		t.Fatalf("round trip mismatch\n want %+v\n got  %+v", doc, got)
	}

	if _, err := Parse([]byte(`{"Clipman":"not-sync-rules"}`)); err == nil {
		t.Fatal("Parse must reject a document whose Clipman field is not \"sync-rules\"")
	}
}
