package tui

import (
	"context"
	"strings"
	"testing"

	"github.com/gdamore/tcell/v2"
)

// TestTheListFillsWhateverWindowItIsGiven. The row count is derived from the
// terminal on every draw rather than fixed, so the same session uses a short
// window and a tall one without being told which it has.
func TestTheListFillsWhateverWindowItIsGiven(t *testing.T) {
	for _, height := range []int{10, 24, 50} {
		store := &fakeStore{entries: sampleEntries(60)}
		var stdout strings.Builder
		browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
		screen.SetSize(100, height)
		if err := browser.loopUntil(context.Background(), 1); err != nil {
			t.Fatalf("loopUntil: %v", err)
		}
		want := height - firstListRow
		if got := browser.layout(); got != want {
			t.Fatalf("height %d gave %d list rows, want %d", height, got, want)
		}
		rows := screenRows(t, screen)
		filled := 0
		for _, row := range rows[firstListRow:] {
			if strings.TrimSpace(row) != "" {
				filled++
			}
		}
		if filled != want {
			t.Errorf("height %d drew %d entry rows, want %d", height, filled, want)
		}
	}
}

// TestResizingMidSessionKeepsTheCaretOnTheSelectedRow. A window resized while
// the user is reading must not move them.
func TestResizingMidSessionKeepsTheCaretOnTheSelectedRow(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(40)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown), key(tcell.KeyDown))
	screen.SetSize(100, 30)
	if err := browser.loopUntil(context.Background(), 2); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.selected != 2 {
		t.Fatalf("selected = %d, want 2", browser.selected)
	}

	screen.SetSize(60, 12)
	if _, err := browser.handle(context.Background(), tcell.NewEventResize(60, 12)); err != nil {
		t.Fatalf("handle resize: %v", err)
	}
	browser.draw()

	if browser.selected != 2 {
		t.Fatalf("a resize moved the selection to %d", browser.selected)
	}
	x, y, visible := screen.GetCursor()
	if !visible || y != firstListRow+2 {
		t.Fatalf("caret at (%d,%d) visible %v, want row %d", x, y, visible, firstListRow+2)
	}
	if want := browser.caretColumn(); x != want {
		t.Errorf("caret column = %d, want %d", x, want)
	}
}

// TestAVeryShortWindowStillDrawsARow. firstListRow reserves five rows of
// chrome, so a window shorter than that must not produce a negative row count.
func TestAVeryShortWindowStillDrawsARow(t *testing.T) {
	for _, height := range []int{1, 3, 5, 6} {
		store := &fakeStore{entries: sampleEntries(5)}
		var stdout strings.Builder
		browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
		screen.SetSize(40, height)
		if err := browser.loopUntil(context.Background(), 1); err != nil {
			t.Fatalf("height %d: %v", height, err)
		}
		if got := browser.layout(); got < 1 {
			t.Fatalf("height %d gave %d list rows, want at least 1", height, got)
		}
	}
}
