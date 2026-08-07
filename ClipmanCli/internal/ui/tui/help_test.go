package tui

import (
	"context"
	"strings"
	"testing"

	"github.com/gdamore/tcell/v2"
)

func openHelpAt(t *testing.T, width, height int) (*Browser, tcell.SimulationScreen) {
	t.Helper()
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('?'))
	screen.SetSize(width, height)
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	return browser, screen
}

// TestHelpIsReachableOnAShortTerminal is why help moved into the viewer. It was
// a flat slice clipped to the window: on anything shorter than the key list, the
// end was unreachable and nothing said so. The list has since grown past a
// standard terminal, so this was live.
func TestHelpIsReachableOnAShortTerminal(t *testing.T) {
	browser, _ := openHelpAt(t, 80, 12)
	if browser.mode != modeView {
		t.Fatalf("? must open help in the viewer, mode = %v", browser.mode)
	}
	rows := browser.layout()
	if len(browser.viewRows) <= rows {
		t.Fatalf("this test needs help to be longer than the %d visible rows, got %d",
			rows, len(browser.viewRows))
	}
	// The last line must be reachable, which is the whole point.
	feedKeys(t, browser, key(tcell.KeyEnd))
	if browser.viewCursor != len(browser.viewRows)-1 {
		t.Fatalf("End left the caret at row %d of %d", browser.viewCursor, len(browser.viewRows))
	}
	// Compare against the key list itself rather than against a remembered
	// phrase, so this keeps working as the wording changes.
	wantLast := helpLines[len(helpLines)-1]
	if last := browser.viewRows[browser.viewCursor]; !strings.HasSuffix(wantLast, last.text) {
		t.Errorf("last reachable row = %q, want the end of %q", last.text, wantLast)
	}
}

// TestHelpScrollsWithTheCaretOnTheLine, the same rule as everywhere else.
func TestHelpScrollsWithTheCaretOnTheLine(t *testing.T) {
	browser, screen := openHelpAt(t, 80, 12)
	feedKeys(t, browser, key(tcell.KeyDown), key(tcell.KeyDown))
	x, y, visible := screen.GetCursor()
	if !visible || y < firstListRow {
		t.Fatalf("caret at (%d,%d) visible %v, want it on a help row", x, y, visible)
	}
	if want := browser.caretColumn(); x != want {
		t.Errorf("caret column = %d, want %d", x, want)
	}
	if browser.viewCursor != 2 {
		t.Errorf("caret is on help row %d, want 2", browser.viewCursor)
	}
}

// TestHelpHeadingSaysItIsHelp, not "Viewing entry 0", which would be a lie and
// the heading is what a reader hears first.
func TestHelpHeadingSaysItIsHelp(t *testing.T) {
	browser, screen := openHelpAt(t, 80, 24)
	heading := screenRows(t, screen)[headingRow]
	if !strings.Contains(heading, "Clipman keys") {
		t.Fatalf("heading = %q, want it to name the key list", heading)
	}
	if strings.Contains(heading, "Viewing entry") {
		t.Fatalf("heading = %q, want help not described as a clip", heading)
	}
	_ = browser
}

// TestHelpDoesNotEmitOnEnter. Enter writes the clip to standard output and
// exits; the key list is not a clip, and sending it down a pipeline is never
// what anyone meant.
func TestHelpDoesNotEmitOnEnter(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, runeKey('?'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	feedKeys(t, browser, key(tcell.KeyEnter))
	if browser.quit {
		t.Fatal("Enter in help must not exit")
	}
	if stdout.String() != "" {
		t.Fatalf("stdout = %q, want nothing; help is not a clip", stdout.String())
	}
}

// TestHelpDoesNotOfferToSaveItself, for the same reason.
func TestHelpDoesNotOfferToSaveItself(t *testing.T) {
	browser, _ := openHelpAt(t, 80, 24)
	feedKeys(t, browser, runeKey('w'))
	if browser.mode != modeView {
		t.Fatalf("w in help must do nothing, mode = %v", browser.mode)
	}
}

// TestClosingHelpReturnsToTheList, with the caret back on a row.
func TestClosingHelpReturnsToTheList(t *testing.T) {
	browser, screen := openHelpAt(t, 80, 24)
	feedKeys(t, browser, runeKey('q'))
	if browser.mode != modeList {
		t.Fatalf("q must close help, mode = %v", browser.mode)
	}
	_, y, _ := screen.GetCursor()
	if y != firstListRow {
		t.Fatalf("caret row = %d, want the list back at %d", y, firstListRow)
	}
}

// TestHelpWrapsRatherThanTruncating on a narrow window, so a long line of the
// key list is still readable to its end.
func TestHelpWrapsRatherThanTruncating(t *testing.T) {
	browser, _ := openHelpAt(t, 32, 24)
	continued := 0
	for _, row := range browser.viewRows {
		if row.continued {
			continued++
		}
	}
	if continued == 0 {
		t.Fatal("a 32-column window must wrap the key list rather than clip it")
	}
	var rebuilt strings.Builder
	for index, row := range browser.viewRows {
		if index > 0 && !row.continued {
			rebuilt.WriteString("\n")
		}
		rebuilt.WriteString(row.text)
	}
	if rebuilt.String() != strings.Join(helpLines, "\n") {
		t.Error("wrapping the key list lost or changed text")
	}
}
