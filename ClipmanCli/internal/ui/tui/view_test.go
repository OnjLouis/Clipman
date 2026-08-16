package tui

import (
	"strings"
	"testing"
)

// TestNothingIsLostToWrapping is the property that matters most. The list shows
// a preview and truncating it is honest; the viewer is how a user reads the
// whole clip, so a character that goes missing is content they cannot reach.
func TestNothingIsLostToWrapping(t *testing.T) {
	for _, text := range []string{
		strings.Repeat("abcdefghij", 40),
		"https://example.test/" + strings.Repeat("path-segment/", 30),
		"short",
		"one\ntwo\nthree",
		strings.Repeat("日本語テキスト", 20),
	} {
		rows := wrapClip(text, 40)
		var rebuilt strings.Builder
		for index, row := range rows {
			if index > 0 && !row.continued {
				rebuilt.WriteString("\n")
			}
			rebuilt.WriteString(row.text)
		}
		if rebuilt.String() != text {
			t.Errorf("wrapping lost or changed text\n got: %q\nwant: %q", rebuilt.String(), text)
		}
	}
}

// TestWrappedRowsFitTheWindow, measured in display columns rather than runes,
// because tcell writes a wide rune into two cells and a row that overflows
// corrupts the one below it.
func TestWrappedRowsFitTheWindow(t *testing.T) {
	const width = 30
	for _, text := range []string{
		strings.Repeat("abcdefghij", 20),
		strings.Repeat("日本語", 30),
		strings.Repeat("é", 40), // combining acute, zero width each
	} {
		for _, row := range wrapClip(text, width) {
			full := unselectedMarker + row.label() + row.text
			if got := displayWidth(full); got > width {
				t.Fatalf("row %q occupies %d columns, window is %d", full, got, width)
			}
		}
	}
}

// TestLineNumbersFollowTheText covers the thing the numbers exist for: they are
// the position announcement, so they have to mean the logical line rather than
// the physical row.
func TestLineNumbersFollowTheText(t *testing.T) {
	rows := wrapClip("first\n"+strings.Repeat("x", 200)+"\nthird", 40)
	if rows[0].line != 1 || rows[0].continued {
		t.Fatalf("first row = %+v, want line 1 uncontinued", rows[0])
	}
	continuations := 0
	for _, row := range rows {
		if row.line == 2 && row.continued {
			continuations++
		}
	}
	if continuations == 0 {
		t.Fatal("a 200-character line in a 40-column window must produce continuation rows")
	}
	last := rows[len(rows)-1]
	if last.line != 3 || last.continued {
		t.Fatalf("last row = %+v, want line 3 uncontinued", last)
	}
}

// TestContinuationRowsAreMarkedDifferently so a listener can tell "still line
// twelve" from "line thirteen" without the viewer announcing anything extra.
func TestContinuationRowsAreMarkedDifferently(t *testing.T) {
	if got := (viewRow{line: 12}).label(); got != "12. " {
		t.Errorf("label = %q, want %q", got, "12. ")
	}
	if got := (viewRow{line: 12, continued: true}).label(); got != "12+ " {
		t.Errorf("continuation label = %q, want %q", got, "12+ ")
	}
}

// TestCaretColumnWorksOnBothRowKinds. The caret sits after the number on every
// row; if a continuation row moved it, the caret would jump left mid-line and
// read as a bug.
func TestCaretColumnWorksOnBothRowKinds(t *testing.T) {
	plain := selectedMarker + (viewRow{line: 12}).label() + "export PATH"
	continued := selectedMarker + (viewRow{line: 12, continued: true}).label() + "/usr/bin"
	if got, want := spaceAfterNumber(plain), len(selectedMarker)+len("12."); got != want {
		t.Errorf("caret column on a numbered row = %d, want %d", got, want)
	}
	if got, want := spaceAfterNumber(continued), len(selectedMarker)+len("12+"); got != want {
		t.Errorf("caret column on a continuation row = %d, want %d", got, want)
	}
}

// TestControlCharactersAreShownNotDropped. Dropping them would make the viewer
// disagree with what w writes and what Enter emits.
func TestControlCharactersAreShownNotDropped(t *testing.T) {
	rows := wrapClip("before\x00after\x1bhere\x7fend", 200)
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	for _, want := range []string{"^@", "^[", "^?"} {
		if !strings.Contains(rows[0].text, want) {
			t.Errorf("row %q should render a control character as %q", rows[0].text, want)
		}
	}
	if strings.ContainsAny(rows[0].text, "\x00\x1b\x7f") {
		t.Errorf("raw control characters reached the screen: %q", rows[0].text)
	}
}

// TestTabsAreExpanded because a terminal's own tab handling moves the cursor
// without the program knowing, which puts the caret somewhere the caret model
// does not believe it is.
func TestTabsAreExpanded(t *testing.T) {
	rows := wrapClip("a\tb", 200)
	if strings.Contains(rows[0].text, "\t") {
		t.Fatalf("a tab survived: %q", rows[0].text)
	}
	if got, want := rows[0].text, "a   b"; got != want {
		t.Errorf("tab expanded to %q, want %q", got, want)
	}
}

// TestCarriageReturnsCannotReachTheScreen. A lone CR would move the terminal
// cursor to the start of the row in the middle of a draw.
func TestCarriageReturnsCannotReachTheScreen(t *testing.T) {
	rows := wrapClip("windows\r\nline\rmac", 200)
	for _, row := range rows {
		if strings.ContainsAny(row.text, "\r\n") {
			t.Fatalf("a line ending reached a row: %q", row.text)
		}
	}
	if len(rows) != 3 {
		t.Fatalf("got %d rows, want 3 logical lines from CRLF and a lone CR", len(rows))
	}
}

// TestEmptyLinesAreStillRows, so an empty line is somewhere the caret can land
// and be told about rather than a gap that reads as the clip ending.
func TestEmptyLinesAreStillRows(t *testing.T) {
	rows := wrapClip("one\n\nthree", 40)
	if len(rows) != 3 {
		t.Fatalf("got %d rows, want 3", len(rows))
	}
	if rows[1].text != "" || rows[1].line != 2 {
		t.Fatalf("middle row = %+v, want an empty line 2", rows[1])
	}
}

func TestEmptyClipProducesOneRow(t *testing.T) {
	rows := wrapClip("", 40)
	if len(rows) != 1 || rows[0].text != "" || rows[0].line != 1 {
		t.Fatalf("rows = %+v, want a single empty line 1", rows)
	}
}

// TestPositionSurvivesResize is why rows carry a logical line rather than the
// reader carrying a row index. Re-wrapping at a new width must leave them on the
// same text.
func TestPositionSurvivesResize(t *testing.T) {
	text := "one\n" + strings.Repeat("y", 300) + "\nthree\nfour"
	wide := wrapClip(text, 100)
	narrow := wrapClip(text, 30)

	line := wide[rowIndexForLine(wide, 3)].line
	if line != 3 {
		t.Fatalf("looked up line 3 and found %d", line)
	}
	if got := narrow[rowIndexForLine(narrow, 3)].line; got != 3 {
		t.Fatalf("after re-wrapping, line 3 resolved to line %d", got)
	}
	// The row index must actually differ, or the test is not exercising the
	// case it claims to.
	if rowIndexForLine(wide, 3) == rowIndexForLine(narrow, 3) {
		t.Skip("widths did not change the row index; the assertion above is still valid")
	}
}

func TestVeryNarrowWindowStillProducesRows(t *testing.T) {
	for _, width := range []int{0, 1, 2, 5} {
		rows := wrapClip("some text that cannot fit", width)
		if len(rows) == 0 {
			t.Fatalf("width %d produced no rows", width)
		}
		for _, row := range rows {
			if row.text == "" && len(rows) > 1 {
				t.Fatalf("width %d produced an empty row, which would loop forever", width)
			}
		}
	}
}
