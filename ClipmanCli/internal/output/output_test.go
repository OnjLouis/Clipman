package output

import (
	"strings"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

var now = time.Date(2026, 8, 6, 12, 0, 0, 0, time.UTC)

func minutesAgo(count int) int64 { return now.Add(-time.Duration(count) * time.Minute).UnixMilli() }

func TestOneLineCollapsesEveryLineEnding(t *testing.T) {
	got := OneLine("first\r\nsecond\nthird\rfourth")
	if got != "first second third fourth" {
		t.Fatalf("got %q", got)
	}
}

func TestOneLineNeverSplitsARune(t *testing.T) {
	// Each of these is multi-byte, so a byte-based truncation would emit a
	// replacement character and the preview would be announced as garbage.
	got := OneLine(strings.Repeat("é", 200))
	if !strings.HasSuffix(got, "...") {
		t.Fatalf("long text should be shortened, got %q", got)
	}
	if strings.ContainsRune(got, '�') {
		t.Fatalf("truncation split a rune: %q", got)
	}
	if runes := []rune(got); len(runes) != previewRunes {
		t.Fatalf("expected %d runes, got %d", previewRunes, len(runes))
	}
}

func TestPreviewPrefersTheName(t *testing.T) {
	entry := model.Entry{Name: "deploy runbook", Text: "a long command"}
	if got := Preview(entry); got != "deploy runbook" {
		t.Fatalf("got %q", got)
	}
	if got := Preview(model.Entry{Text: "a long command"}); got != "a long command" {
		t.Fatalf("got %q", got)
	}
}

func TestEmptyDashKeepsFieldsAudible(t *testing.T) {
	if got := EmptyDash(""); got != "-" {
		t.Fatalf("a blank field must not be silent, got %q", got)
	}
}

func TestAgeBuckets(t *testing.T) {
	cases := []struct {
		minutes int
		want    string
	}{{0, "now"}, {5, "5m"}, {90, "1h"}, {60 * 30, "1d"}}
	for _, item := range cases {
		if got := Age(minutesAgo(item.minutes), now); got != item.want {
			t.Fatalf("%d minutes ago: got %q, want %q", item.minutes, got, item.want)
		}
	}
}

func TestEscapeKeepsOneEntryOnOneLine(t *testing.T) {
	got := Escape("a\tb\nc\rd\\e")
	if got != `a\tb\nc\rd\\e` {
		t.Fatalf("got %q", got)
	}
	if strings.ContainsAny(got, "\t\n\r") {
		t.Fatalf("escaped output still holds a control byte: %q", got)
	}
}

func TestFlagsAreFixedWidth(t *testing.T) {
	cases := map[string]model.Entry{
		"--": {},
		"P-": {Pinned: true},
		"-T": {IsTemplate: true},
		"PT": {Pinned: true, IsTemplate: true},
	}
	for want, entry := range cases {
		if got := Flags(entry); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
}

func TestDescribeLabelsEveryField(t *testing.T) {
	entry := model.Entry{
		Name: "pods", Group: "ops", SourceMachine: "workstation",
		Pinned: true, IsTemplate: true, LastUsedUnixMs: minutesAgo(5),
	}
	want := "3. pods; pinned; template; group ops; from workstation; used 5m ago"
	if got := Describe(3, entry, now); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDescribeOmitsAnEmptyGroup(t *testing.T) {
	entry := model.Entry{Text: "hello", SourceMachine: "box", LastUsedUnixMs: minutesAgo(1)}
	if got := Describe(0, entry, now); strings.Contains(got, "group") {
		t.Fatalf("an empty group should not be announced: %q", got)
	}
}

func TestCountAgreesWithItsNoun(t *testing.T) {
	if got := Count(1, "entry", "entries"); got != "1 entry" {
		t.Fatalf("got %q", got)
	}
	if got := Count(0, "entry", "entries"); got != "0 entries" {
		t.Fatalf("got %q", got)
	}
}

func TestPorcelainRowIsTabSeparated(t *testing.T) {
	entry := model.Entry{ID: "abc", Name: "n", SourceMachine: "m", Text: "one\ttwo", LastUsedUnixMs: minutesAgo(1)}
	fields := strings.Split(PorcelainRow(0, entry, now), "\t")
	if len(fields) != 6 {
		t.Fatalf("expected 6 columns, got %d: %q", len(fields), fields)
	}
	if fields[5] != `one\ttwo` {
		t.Fatalf("the preview column was not escaped: %q", fields[5])
	}
}
