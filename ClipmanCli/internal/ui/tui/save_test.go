package tui

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gdamore/tcell/v2"
)

func typeInto(t *testing.T, browser *Browser, text string) {
	t.Helper()
	for _, r := range text {
		feedKeys(t, browser, runeKey(r))
	}
}

func openSave(t *testing.T) (*Browser, tcell.SimulationScreen) {
	t.Helper()
	entries := sampleEntries(3)
	entries[1].Text = "line one\nline two\nline three"
	store := &fakeStore{entries: entries}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	feedKeys(t, browser, runeKey('w'))
	return browser, screen
}

// TestSavePromptNamesTheEntry. The viewer draws no selection marker, so a bare
// "save to file" would leave the user guessing which clip is about to be
// written.
func TestSavePromptNamesTheEntry(t *testing.T) {
	browser, screen := openSave(t)
	if browser.mode != modeSavePath {
		t.Fatalf("w must open the save prompt, mode = %v", browser.mode)
	}
	label, _, _, asking := browser.promptParts()
	if !asking || !strings.Contains(label, "entry 1") {
		t.Fatalf("prompt = %q, want it to name the entry", label)
	}
	_, y, visible := screen.GetCursor()
	if !visible || y != statusRow {
		t.Fatalf("caret at row %d visible %v, want the question row", y, visible)
	}
}

// TestSaveWritesTheClipVerbatim, and says so in a way that must be heard.
func TestSaveWritesTheClipVerbatim(t *testing.T) {
	browser, screen := openSave(t)
	path := filepath.Join(t.TempDir(), "clip.txt")
	typeInto(t, browser, path)
	feedKeys(t, browser, key(tcell.KeyEnter))

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(data) != "line one\nline two\nline three" {
		t.Fatalf("wrote %q, want the clip byte for byte", data)
	}
	if browser.mode != modeNotice {
		t.Fatalf("mode = %v, want a notice the user has to dismiss", browser.mode)
	}
	// The caret must be on the message. It returns to the content row by design,
	// so a status line written on the way past is very likely never spoken, and
	// whether a file was written is the one thing the user cannot find out any
	// other way.
	_, y, _ := screen.GetCursor()
	if y != statusRow {
		t.Fatalf("caret at row %d, want the notice on row %d", y, statusRow)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "Saved 3 lines to") {
		t.Fatalf("notice = %q, want it to report what was written", row)
	}
}

func TestNoticeIsDismissedByAnyKey(t *testing.T) {
	browser, _ := openSave(t)
	typeInto(t, browser, filepath.Join(t.TempDir(), "clip.txt"))
	feedKeys(t, browser, key(tcell.KeyEnter), runeKey('z'))
	if browser.mode != modeList {
		t.Fatalf("mode = %v, want the list back", browser.mode)
	}
}

// TestOverwriteIsConfirmed. This is the one branch that destroys something the
// user did not name.
func TestOverwriteIsConfirmed(t *testing.T) {
	existing := filepath.Join(t.TempDir(), "taken.txt")
	if err := os.WriteFile(existing, []byte("do not lose me"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	browser, screen := openSave(t)
	typeInto(t, browser, existing)
	feedKeys(t, browser, key(tcell.KeyEnter))

	if browser.mode != modeConfirmOverwrite {
		t.Fatalf("mode = %v, want an overwrite confirmation", browser.mode)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "already exists") {
		t.Fatalf("status = %q, want it to say the file exists", row)
	}
	feedKeys(t, browser, runeKey('n'))
	data, _ := os.ReadFile(existing)
	if string(data) != "do not lose me" {
		t.Fatalf("file = %q; cancelling must not overwrite", data)
	}
	if browser.mode != modeList {
		t.Fatalf("mode = %v, want the list back after cancelling", browser.mode)
	}
}

func TestOverwriteProceedsOnY(t *testing.T) {
	existing := filepath.Join(t.TempDir(), "taken.txt")
	if err := os.WriteFile(existing, []byte("old and much longer"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	browser, _ := openSave(t)
	typeInto(t, browser, existing)
	feedKeys(t, browser, key(tcell.KeyEnter), runeKey('y'))
	data, _ := os.ReadFile(existing)
	if string(data) != "line one\nline two\nline three" {
		t.Fatalf("file = %q, want the clip with no tail left behind", data)
	}
}

// TestSaveCanBeCorrectedBeforeCommitting is what the prompt editor bought: a
// mistyped path is fixable without retyping all of it.
func TestSaveCanBeCorrectedBeforeCommitting(t *testing.T) {
	dir := t.TempDir()
	browser, _ := openSave(t)
	typeInto(t, browser, filepath.Join(dir, "clipp.txt"))
	for i := 0; i < 4; i++ {
		feedKeys(t, browser, key(tcell.KeyLeft))
	}
	feedKeys(t, browser, key(tcell.KeyBackspace), key(tcell.KeyEnter))
	if _, err := os.Stat(filepath.Join(dir, "clip.txt")); err != nil {
		t.Fatalf("corrected path was not written: %v", err)
	}
}

// TestSaveRefusesADirectoryClearly, because "notes" and "notes/" is an easy slip
// and the operating system's message for it is not a sentence.
func TestSaveRefusesADirectoryClearly(t *testing.T) {
	dir := t.TempDir()
	browser, screen := openSave(t)
	typeInto(t, browser, dir)
	feedKeys(t, browser, key(tcell.KeyEnter))
	if browser.mode != modeNotice {
		t.Fatalf("mode = %v, want a notice", browser.mode)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "is a directory") {
		t.Fatalf("notice = %q, want it to say what is wrong", row)
	}
}

func TestEscapeAbandonsTheSave(t *testing.T) {
	browser, _ := openSave(t)
	typeInto(t, browser, "somewhere.txt")
	feedKeys(t, browser, key(tcell.KeyEscape))
	if browser.mode != modeList {
		t.Fatalf("mode = %v, want the list back", browser.mode)
	}
	if _, err := os.Stat("somewhere.txt"); err == nil {
		os.Remove("somewhere.txt")
		t.Fatal("escaping the prompt must not write anything")
	}
}

// TestSaveWorksFromTheViewer, on the entry being read, without closing it.
func TestSaveWorksFromTheViewer(t *testing.T) {
	browser, _ := viewerBrowser(t, "viewed clip text", runeKey('v'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	feedKeys(t, browser, runeKey('w'))
	if browser.mode != modeSavePath {
		t.Fatalf("w in the viewer must open the save prompt, mode = %v", browser.mode)
	}
	path := filepath.Join(t.TempDir(), "fromviewer.txt")
	typeInto(t, browser, path)
	feedKeys(t, browser, key(tcell.KeyEnter))
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(data) != "viewed clip text" {
		t.Fatalf("wrote %q, want the clip being viewed", data)
	}
	// Dismissing the notice must return to the viewer, not to the list.
	feedKeys(t, browser, runeKey('z'))
	if browser.mode != modeView {
		t.Fatalf("mode = %v, want the viewer back", browser.mode)
	}
}

// TestPickRefusesToWriteFiles. pick has exactly one output and its caller chose
// it; a file the pipeline knows nothing about is not that output.
func TestPickRefusesToWriteFiles(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('w'))
	browser.PickOnly = true
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.mode != modeList {
		t.Fatalf("pick must not open the save prompt, mode = %v", browser.mode)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "pick cannot write files") {
		t.Fatalf("status = %q, want pick to say why it refused", row)
	}
}
