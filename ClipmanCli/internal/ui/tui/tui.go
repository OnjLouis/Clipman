// Package tui implements the full-screen history browser used by
// `clipman-cli menu --renderer tui` and `pick --renderer tui`.
//
// It is a second renderer over the same model as the line browser, not a
// separate program. Rows come from output.Describe, so a row says exactly the
// same words in both renderers, and both drive the same Store.
//
// A full-screen interface is not automatically the accessible one.
//
// One rule governs the interface: the caret goes in whatever the user is
// currently moving through or typing into, because a screen reader reads the
// line the caret is on. Everything else follows from it.
//
//   - Moving vertically through the list puts the caret on the selected row, in
//     the space just after the entry number, so each arrow key reads out the
//     entry now selected. The caret never rests on the status line while
//     browsing.
//   - Asking a question puts the caret at the end of the typed answer, on the
//     same line as the question, so the line reads "Go to entry number: 12" —
//     the user hears what was asked and what they have typed so far.
//   - The heading, status line, and preview sit above the list, so the entry
//     rows are the last text written on every frame. See the layout constants.
//   - As little as possible is redrawn. Everything rewritten is resent to the
//     terminal and so to a screen reader, so an arrow key changes two markers
//     and the preview and nothing else. Paging and scrolling must repaint the
//     list; what matters then is that the caret ends up on the selected row.
//   - Selection is carried in the row text as an arrow marker, not in reverse
//     video alone, which says nothing to a screen reader.
//   - Every row is a complete labeled sentence, never a visual-only marker.
//   - The terminal is restored on the way out, including through a panic.
//
// This package makes no attempt to detect a screen reader — no portable way to
// do that exists, and guessing wrong silently changes how the program behaves.
// The line renderer stays the default and is chosen explicitly.
package tui

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/uniseg"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/template"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/handoff"
)

// ErrCancelled reports that the user deliberately left without choosing.
var ErrCancelled = errors.New("selection cancelled")

// ErrNoEntries reports that the requested view holds nothing to choose from.
var ErrNoEntries = errors.New("no matching entries")

// Store is the history the browser works against. It is declared here rather
// than imported so this package does not depend on the line renderer; the same
// concrete value satisfies both.
type Store interface {
	Load(ctx context.Context) ([]model.Entry, error)
	Delete(ctx context.Context, id string) error
	Create(ctx context.Context, text, name string) (model.Entry, error)
}

// Mode is what the interface is currently doing, which decides how a keystroke
// is read and where the cursor belongs.
type mode int

const (
	modeList mode = iota
	modeFilter
	modeGoto
	modeConfirmDelete
	modeConfirmSwitch
	modeView
	modeSavePath
	modeConfirmOverwrite
	modeNotice
	modeRunCommand
	modeRunning
)

// selectedMarker and unselectedMarker prefix every row. Reverse video alone
// says nothing to a screen reader and nothing to review-mode navigation, so
// selection is carried in the text itself. Both markers are the same width so
// the columns after them stay aligned.
const (
	selectedMarker   = "-> "
	unselectedMarker = "   "
)

// Browser renders the full-screen history browser.
type Browser struct {
	Store  Store
	Screen tcell.Screen
	// Stdout receives a chosen clip's text and nothing else.
	Stdout io.Writer
	// PinnedFirst mirrors the view order for local re-sorting.
	PinnedFirst bool
	// Kind is announced in the heading and switched with Tab.
	Kind operation.Kind
	// Now supplies the clock, injected so tests are deterministic.
	Now func() time.Time
	// PickOnly disables mutation, for `pick`.
	PickOnly bool
	// DebugPath, when set, is a file to trace caret placement into.
	DebugPath string
	// Arrival, when set, is the place the user held in the interface they just
	// left. Applied before the first frame so the caret's first landing is the
	// row they were already on.
	Arrival *handoff.Request

	entries []model.Entry
	filter  string
	// prompt is whatever question is currently open, and where the caret sits
	// inside the answer. One editor rather than one per prompt: only one
	// question is ever open at a time.
	prompt   promptEditor
	gotoText string
	selected int
	top      int
	mode     mode
	status   string
	chosen   string
	quit     bool
	// The viewer holds its own position. Reusing selected and top would mean
	// scrolling a 220-line clip moves the list selection underneath it, so
	// closing the viewer would leave the user somewhere they never navigated to.
	viewText   string
	viewRows   []viewRow
	viewWidth  int
	viewCursor int
	viewTop    int
	// viewIsClip separates reading a clip from reading the key list or a
	// command's output. Enter and w act on a clip; the others are documents.
	// viewTitle names those documents in the heading.
	viewIsClip bool
	viewTitle  string

	// saveLabel is the question w is asking, savePath the file an overwrite
	// confirmation is about, and returnMode where a prompt or notice goes back
	// to, so w behaves the same from the list and from the viewer.
	saveLabel  string
	savePath   string
	returnMode mode

	// The run in progress: its question, the program's name for messages, when
	// it started, and how to stop it. runRefused keeps a rejected command line on
	// screen so it can be corrected rather than retyped.
	runLabel   string
	runProgram string
	runStarted time.Time
	runCancel  func()
	runRefused bool

	// switching records that the user left for the other interface rather than
	// leaving altogether, so the caller starts the other one instead of exiting.
	switching bool

	// caret records where the last draw asked the terminal to put the cursor,
	// and what was written on that row, for the caret trace.
	caretX, caretY int
	caretRow       string
	draws          int
	debugFile      *os.File
}

// debugging reports whether to record caret diagnostics. Screen readers cannot
// be observed from a test, so when a report says the cursor is somewhere it
// should not be, this is how to find out what the program actually asked for
// rather than inferring it.
//
// It is driven by a field rather than by an environment variable, because
// setting one of those differs between cmd and PowerShell and a mistyped
// incantation looks exactly like a feature that does not work.
func (b *Browser) debugging() bool { return b.DebugPath != "" }

// DefaultDebugPath returns where a trace should go when the caller has no
// preference: beside the executable, which is somewhere the user can already
// find, rather than the working directory, which they may not know.
func DefaultDebugPath() string {
	const name = "clipman-tui-debug.txt"
	executable, err := os.Executable()
	if err != nil {
		return name
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return filepath.Join(filepath.Dir(executable), name)
}

func (b *Browser) openDebugLog() {
	if !b.debugging() {
		return
	}
	file, err := os.Create(b.DebugPath)
	if err != nil {
		// A read-only install directory should not cost us the trace.
		file, err = os.Create("clipman-tui-debug.txt")
		if err != nil {
			return
		}
		if absolute, err := filepath.Abs("clipman-tui-debug.txt"); err == nil {
			b.DebugPath = absolute
		}
	}
	b.debugFile = file
	fmt.Fprintf(file, "Clipman CLI full-screen interface caret trace, %s\n",
		b.now().Format("2006-01-02 15:04:05"))
	fmt.Fprintf(file, "layout rows: heading=%d status=%d previewLabel=%d preview=%d firstList=%d\n\n",
		headingRow, statusRow, previewLabelRow, previewRow, firstListRow)
}

func (b *Browser) writeDebug(text string) {
	if b.debugFile == nil {
		return
	}
	fmt.Fprintln(b.debugFile, text)
}

func (b *Browser) closeDebugLog() {
	if b.debugFile == nil {
		return
	}
	fmt.Fprintf(b.debugFile, "\nfinal: %s\n", b.caretReport())
	b.debugFile.Close()
	b.debugFile = nil
}

// applyArrival restores the place the user held in the interface they left.
//
// It runs before the first draw, so clampSelection bounds it and the caret's
// very first landing is the row they were already on. Arriving at the top of an
// unfiltered list is how a person loses their place.
func (b *Browser) applyArrival() {
	if b.Arrival == nil {
		return
	}
	b.filter = b.Arrival.Filter
	b.selected = b.Arrival.Selected
}

// setInitialStatus writes the line the interface opens with.
//
// The interface names itself on the first frame for the same reason the line
// interface does: a user who is never told which of the two they are in has no
// reason to look for the other. It costs nothing during navigation, because the
// status row is only read when the whole screen is new.
//
// It lives in one place because the tests drive this same opening state, and a
// status string spelled out at three call sites drifts.
func (b *Browser) setInitialStatus() {
	b.setStatus("Full-screen interface. %s. Press ? for keys.", b.heading())
}

// modeName names the current mode for diagnostics.
func (b *Browser) modeName() string {
	switch b.mode {
	case modeFilter:
		return "filter prompt"
	case modeGoto:
		return "go-to prompt"
	case modeConfirmDelete:
		return "delete confirmation"
	case modeConfirmSwitch:
		return "interface switch confirmation"
	case modeSavePath:
		return "save prompt"
	case modeConfirmOverwrite:
		return "overwrite confirmation"
	case modeNotice:
		return "notice"
	case modeRunCommand:
		return "run prompt"
	case modeRunning:
		return "running a command"
	case modeView:
		return "clip viewer"
	}
	return "list"
}

// caretReport describes the last caret placement in one line.
func (b *Browser) caretReport() string {
	where := b.modeName()
	width, height := 0, 0
	if b.Screen != nil {
		width, height = b.Screen.Size()
	}
	return fmt.Sprintf(
		"caret row=%d column=%d mode=%s selected=%d top=%d screen=%dx%d rows: heading=%d status=%d preview=%d list=%d\nrow under caret: %q",
		b.caretY, b.caretX, where, b.selected, b.top, width, height,
		headingRow, statusRow, previewRow, firstListRow, b.caretRow)
}

// promptParts returns the question and the text typed so far for whatever the
// interface is currently asking, and whether it is asking anything.
//
// Question and answer are deliberately one line. A screen reader reads the
// line the caret is on, so keeping them together means the user hears both
// what was asked and what they have typed so far; splitting them across two
// lines would leave the question unread while typing the answer.
// It also reports where the caret sits within the typed text. A question that
// can only be corrected with Backspace forces the user to destroy everything
// after a mistake to reach it; the caret offset is what lets them move to it
// instead. A confirmation has nothing typed, so its caret rests at the end of
// the question.
func (b *Browser) promptParts() (label, typed string, cursor int, asking bool) {
	switch b.mode {
	case modeFilter:
		return "Filter by text: ", b.prompt.String(), b.prompt.at(), true
	case modeGoto:
		return "Go to entry number: ", b.prompt.String(), b.prompt.at(), true
	case modeSavePath:
		return b.saveLabel, b.prompt.String(), b.prompt.at(), true
	case modeRunCommand:
		// A refusal is shown in place of the question until the next keystroke,
		// so the reason is on the line the caret is on.
		if b.runRefused {
			return b.status, "", 0, true
		}
		return b.runLabel, b.prompt.String(), b.prompt.at(), true
	case modeRunning:
		return b.status, "", 0, true
	case modeConfirmDelete, modeConfirmSwitch, modeConfirmOverwrite, modeNotice:
		return b.status, "", 0, true
	}
	return "", "", 0, false
}

func (b *Browser) now() time.Time {
	if b.Now != nil {
		return b.Now()
	}
	return time.Now()
}

// visible applies the active filter. Indices used everywhere else are
// positions in this slice.
func (b *Browser) visible() []model.Entry {
	if b.filter == "" {
		return b.entries
	}
	needle := strings.ToLower(b.filter)
	matches := make([]model.Entry, 0, len(b.entries))
	for _, entry := range b.entries {
		if strings.Contains(strings.ToLower(entry.Name+"\n"+entry.Text), needle) {
			matches = append(matches, entry)
		}
	}
	return matches
}

func (b *Browser) setStatus(format string, args ...any) {
	b.status = fmt.Sprintf(format, args...)
}

// Run owns the terminal lifecycle: it initializes the screen, drives the loop,
// and restores the terminal on the way out whatever happens. The behavior
// itself lives in loop, which runs against an already-initialized screen so it
// can be exercised while the screen is still readable.
func (b *Browser) Run(ctx context.Context) (err error) {
	if b.Screen == nil {
		return errors.New("no terminal screen was supplied")
	}
	if initErr := b.Screen.Init(); initErr != nil {
		return fmt.Errorf("this terminal cannot run the full-screen interface: %w", initErr)
	}
	// The terminal is restored even if drawing panics. Without this a crash
	// leaves the user in a raw-mode terminal with no echo, which is a
	// considerably worse failure than the original panic.
	b.openDebugLog()
	defer func() {
		// The trace is closed before the screen is restored, so a panic on the
		// way out still leaves a readable file.
		b.closeDebugLog()
		b.Screen.Fini()
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("the full-screen interface stopped unexpectedly: %v", recovered)
		}
	}()
	return b.loop(ctx)
}

// loop drives the browser until the user leaves or emits a clip. The screen is
// already initialized and is left initialized.
func (b *Browser) loop(ctx context.Context) error {
	entries, loadErr := b.Store.Load(ctx)
	if loadErr != nil {
		return loadErr
	}
	b.entries = entries
	if b.PickOnly && len(b.entries) == 0 {
		return ErrNoEntries
	}
	b.applyArrival()
	b.setInitialStatus()

	// Drawn once up front, then only when an event actually changed something.
	// Redrawing on every event that arrives means redrawing on events the
	// interface ignores, and a terminal can deliver a steady trickle of those.
	// Each needless redraw is more text resent to a screen reader.
	b.draw()
	for !b.quit {
		event := b.Screen.PollEvent()
		if event == nil {
			return ErrCancelled
		}
		changed, handleErr := b.handle(ctx, event)
		if handleErr != nil {
			return handleErr
		}
		if changed && !b.quit {
			b.draw()
		}
	}
	// Checked before chosen, because switching never selects a clip and must not
	// be mistaken for one.
	if b.switching {
		return &handoff.Request{Selected: b.selected, Filter: b.filter, Kind: b.Kind}
	}
	if b.chosen != "" {
		_, writeErr := io.WriteString(b.Stdout, b.chosen)
		return writeErr
	}
	return ErrCancelled
}

func (b *Browser) heading() string {
	entries := b.visible()
	kind := "history"
	switch b.Kind {
	case operation.Templates:
		kind = "templates"
	case operation.All:
		kind = "history and templates"
	}
	if b.filter != "" {
		return fmt.Sprintf("Clipman %s, filter %q: %s of %s",
			kind, b.filter, output.Count(len(entries), "match", "matches"),
			output.Count(len(b.entries), "entry", "entries"))
	}
	return fmt.Sprintf("Clipman %s: %s", kind, output.Count(len(entries), "entry", "entries"))
}

// The chrome sits above the list and the list runs to the bottom of the
// window. That ordering is deliberate rather than decorative.
//
// tcell buffers a frame and emits only the cells that changed, scanning top to
// bottom. The order in which draw calls are made therefore does not decide the
// order text reaches the terminal — its position on screen does. Putting the
// heading, status line, and preview above the list means they are written
// first and the entry rows last, so a screen reader that announces newly
// written console text finishes on the row the user navigated to rather than
// on the status line.
//
// With the status line at the bottom, as it was, every full redraw ended by
// writing that line, which is very likely why it kept being read out.
const (
	headingRow      = 0
	statusRow       = 1
	previewLabelRow = 2
	previewRow      = 3
	firstListRow    = 4
)

// layout returns how many rows the list may use for the current window size.
func (b *Browser) layout() (listRows int) {
	_, height := b.Screen.Size()
	listRows = height - firstListRow
	if listRows < 1 {
		listRows = 1
	}
	return listRows
}

// clampSelection keeps the selection inside the list and scrolls the window so
// the selected row is on screen.
func (b *Browser) clampSelection() {
	entries := b.visible()
	if b.selected >= len(entries) {
		b.selected = len(entries) - 1
	}
	if b.selected < 0 {
		b.selected = 0
	}
	listRows := b.layout()
	if b.selected < b.top {
		b.top = b.selected
	}
	if b.selected >= b.top+listRows {
		b.top = b.selected - listRows + 1
	}
	if b.top < 0 {
		b.top = 0
	}
}

// drawText writes text starting at x, advancing by how many columns each
// character actually occupies.
//
// Advancing one column per rune, as this used to, is wrong for any text a user
// might have copied. A wide character occupies two cells, so the next write
// lands inside it and corrupts both; a combining mark occupies none and belongs
// in the cell it modifies rather than in one of its own. The list hid this
// because previews are short and mostly ASCII. The viewer, which draws arbitrary
// clip text, does not.
func (b *Browser) drawText(x, y int, style tcell.Style, text string) {
	width, _ := b.Screen.Size()
	column := x
	graphemes := uniseg.NewGraphemes(text)
	for graphemes.Next() {
		if column >= width {
			return
		}
		runes := graphemes.Runes()
		b.Screen.SetContent(column, y, runes[0], runes[1:], style)
		column += displayWidth(graphemes.Str())
	}
}

// drawLine writes one whole line: the text, then spaces to the right edge so
// anything longer that was there before is cleared.
//
// Every line is drawn this way instead of clearing the screen and redrawing.
// tcell sends only the cells whose content or style actually changed, so
// rewriting a line with identical text costs nothing, while a screen-wide
// clear risks resending the lot. What reaches the terminal is what a screen
// reader has to work through, so the less that changes per keystroke the
// better.
func (b *Browser) drawLine(y int, style tcell.Style, text string) {
	width, _ := b.Screen.Size()
	column := 0
	graphemes := uniseg.NewGraphemes(text)
	for graphemes.Next() {
		if column >= width {
			break
		}
		runes := graphemes.Runes()
		b.Screen.SetContent(column, y, runes[0], runes[1:], style)
		column += displayWidth(graphemes.Str())
	}
	for ; column < width; column++ {
		b.Screen.SetContent(column, y, ' ', nil, tcell.StyleDefault)
	}
}

func (b *Browser) draw() {
	entries := b.visible()
	b.clampSelection()
	listRows := b.layout()

	plain := tcell.StyleDefault

	// The viewer replaces the list but keeps the chrome above it, so the entry
	// rows are still the last thing written on every frame.
	if b.mode == modeView {
		b.ensureViewRows()
		b.drawLine(headingRow, plain.Bold(true), b.viewerHeading())
		b.drawLine(statusRow, plain, b.status)
		b.drawLine(previewLabelRow, plain.Bold(true), "Clip text")
		b.drawLine(previewRow, plain, "")
		b.drawViewer(listRows)
		b.placeCursor()
		b.Screen.Show()
		return
	}

	// The run prompt explains its rules in the heading, for as long as it is
	// open. Every other program that takes a command line hands it to a shell
	// and this one does not, which is worth saying once where it is read when
	// the screen changes rather than after each rejected attempt.
	heading := b.heading()
	if b.mode == modeRunCommand {
		heading = b.runHeading()
	}
	b.drawLine(headingRow, plain.Bold(true), heading)

	// The question and the answer typed so far share one line, so the caret's
	// line carries both.
	if label, typed, _, asking := b.promptParts(); asking {
		b.drawLine(statusRow, plain, label+typed)
	} else {
		b.drawLine(statusRow, plain, b.status)
	}

	if b.selected < len(entries) {
		b.drawLine(previewLabelRow, plain.Bold(true), "Selected clip")
		b.drawLine(previewRow, plain, output.OneLine(b.text(entries[b.selected])))
	} else {
		b.drawLine(previewLabelRow, plain, "")
		b.drawLine(previewRow, plain, "")
	}

	// The debug row shows where the previous draw put the caret, on a line of
	// its own so it can be found by review navigation.

	now := b.now()
	for offset := 0; offset < listRows; offset++ {
		row := firstListRow + offset
		index := b.top + offset
		if index >= len(entries) {
			b.drawLine(row, plain, "")
			continue
		}
		marker := unselectedMarker
		style := plain
		if index == b.selected {
			marker = selectedMarker
			// Redrawing the two affected rows is acceptable; redrawing the
			// whole screen is not. A visible highlight is worth two rows.
			style = plain.Reverse(true)
		}
		// The row text after the marker is identical to what the line renderer
		// announces, so the two interfaces describe an entry the same way.
		b.drawLine(row, style, marker+output.Describe(index, entries[index], now))
	}

	if len(entries) == 0 {
		b.drawLine(firstListRow, plain, "No entries match. Press Escape to clear the filter.")
	}

	b.placeCursor()
	b.Screen.Show()
}

// placeCursor puts the real terminal cursor where a screen reader should be
// reading. One rule decides it: the caret goes in whatever the user is
// currently moving through or typing into.
//
//   - Moving vertically through the list: the caret is on the selected row, so
//     each arrow key reads out the entry that is now selected.
//   - Answering a question: the caret is at the end of the typed answer, on the
//     same line as the question, so the line reads as "Go to entry number: 12".
//
// An earlier version broke the first half of that rule by handing the caret to
// the status line for one draw after any message, to get the message announced.
// On a real terminal that read as the caret being stuck outside the list. A
// message is worth far less than knowing where you are in the list.
func (b *Browser) placeCursor() {
	column, row := b.caretPosition()
	b.caretX, b.caretY = column, row
	b.Screen.ShowCursor(column, row)
	if !b.debugging() {
		return
	}
	// Read back after asking, so the trace records what the screen holds
	// rather than what this code meant to put there.
	b.caretRow = b.rowText(row)
	b.draws++
	b.writeDebug(fmt.Sprintf("draw %d: %s", b.draws, b.caretReport()))
}

// caretPosition is the placement decision on its own, so a test can check it
// without a screen and the debug report can describe it.
func (b *Browser) caretPosition() (column, row int) {
	if label, typed, cursor, asking := b.promptParts(); asking {
		// The caret lands on the character being edited, not at the end of the
		// line, so moving through what you typed reads it back to you.
		//
		// The column is the width of what precedes the caret on screen, not the
		// number of characters. A question is ASCII, but the answer is whatever
		// the user typed: a filter containing CJK occupies two columns per
		// character, and counting runes would leave the caret short by one
		// column for every one of them.
		return displayWidth(label) + displayWidth(runesBefore(typed, cursor)), statusRow
	}
	if b.mode == modeView {
		return b.caretColumn(), firstListRow + (b.viewCursor - b.viewTop)
	}
	if len(b.visible()) == 0 {
		return b.caretColumn(), firstListRow
	}
	return b.caretColumn(), firstListRow + (b.selected - b.top)
}

// rowText reads back what is actually on a screen row, so the diagnostic
// reports what the terminal holds rather than what this code believes it drew.
func (b *Browser) rowText(row int) string {
	width, height := b.Screen.Size()
	if row < 0 || row >= height {
		return ""
	}
	runes := make([]rune, 0, width)
	for column := 0; column < width; column++ {
		primary, _, _, _ := b.Screen.GetContent(column, row)
		runes = append(runes, primary)
	}
	return strings.TrimRight(string(runes), " ")
}

// caretColumn is the column the caret rests on within the selected row: the
// space just after the entry number, so in "-> 1. test clip" it sits between
// "1." and the text.
//
// The column is derived from the row rather than fixed, so it stays correct as
// the number widens from 1 to 199.
func (b *Browser) caretColumn() int {
	return spaceAfterNumber(b.currentRowText())
}

// currentRowText is the row the caret is resting on, whichever mode drew it.
//
// The column is derived from the row's own text rather than from a constant, so
// it stays right as an entry number widens from 1 to 199 or a viewer line
// number from 9 to 1000. Every mode answers here, so there is one place that
// knows what the caret is sitting on — the same shape as promptParts.
func (b *Browser) currentRowText() string {
	if b.mode == modeView {
		if b.viewCursor >= 0 && b.viewCursor < len(b.viewRows) {
			row := b.viewRows[b.viewCursor]
			return selectedMarker + row.label() + row.text
		}
		return selectedMarker
	}
	entries := b.visible()
	if b.selected < 0 || b.selected >= len(entries) {
		return selectedMarker
	}
	return selectedMarker + output.Describe(b.selected, entries[b.selected], b.now())
}

// spaceAfterNumber finds the space following the leading number of a row. The
// number is always first, so the first ". " or "+ " in the row is that boundary.
//
// Both separators are matched because the viewer marks a wrapped line's
// continuation rows with "+" instead of ".". Without "+" here the caret would
// jump three columns left the moment a line wrapped, which reads as the caret
// slipping off the text rather than as a different kind of row.
// The result is a column, so it is measured in display width rather than in
// runes. Those agree for every prefix this program draws today, since markers
// and numbers are ASCII, but returning a rune count as a column is the bug that
// only shows up once something upstream changes.
func spaceAfterNumber(row string) int {
	runes := []rune(row)
	for index := 0; index+1 < len(runes); index++ {
		if (runes[index] == '.' || runes[index] == '+') && runes[index+1] == ' ' {
			return displayWidth(string(runes[:index+1]))
		}
	}
	return displayWidth(selectedMarker)
}

var helpLines = []string{
	"Keys:",
	"  Up, Down, Page Up, Page Down, Home, End   move through the list",
	"  g            go to an entry by number",
	"  Enter        write the selected clip to standard output and exit",
	"  v            read the whole clip; q closes it",
	"  w            save the selected clip to a file",
	"  x            run a program on the selected clip",
	"  /            filter the list; Escape clears it",
	"  Tab          switch between history, templates, and both",
	"  d            delete the selected entry after confirmation",
	"  r            reload from the server",
	"  u            switch to the line interface",
	"  ?            show these keys",
	"  q or Escape  quit without writing anything",
	"",
	"While answering a question: Left and Right move through what you typed,",
	"Home and End jump to its ends, Delete removes forward, and Ctrl+U clears",
	"the line.",
	"",
	"This is the full-screen interface. The line interface asks for a command",
	"and answers in whole sentences instead. Press u to switch to it; the choice",
	"is remembered as your default.",
}

func (b *Browser) text(entry model.Entry) string {
	if entry.IsTemplate {
		return template.Resolve(entry.Text, b.now())
	}
	return entry.Text
}

// handle processes one event and reports whether the screen needs redrawing.
// Anything the interface does not act on returns false, so an ignored event
// costs nothing.
func (b *Browser) handle(ctx context.Context, event tcell.Event) (bool, error) {
	switch typed := event.(type) {
	case *tcell.EventResize:
		resizeWidth, resizeHeight := typed.Size()
		b.writeDebug(fmt.Sprintf("event: resize to %dx%d", resizeWidth, resizeHeight))
		b.Screen.Sync()
		return true, nil
	case *tcell.EventKey:
		b.writeDebug(fmt.Sprintf("event: key %v rune %q", typed.Key(), typed.Rune()))
		return true, b.handleKey(ctx, typed)
	case *runFinished:
		b.writeDebug("event: command finished")
		b.handleRunFinished(typed)
		return true, nil
	case *runProgress:
		b.writeDebug(fmt.Sprintf("event: command still running, %ds", typed.seconds))
		b.handleRunProgress(typed)
		return true, nil
	default:
		// Recorded rather than acted on, so a terminal that emits something
		// unexpected shows up in the trace instead of quietly causing redraws.
		b.writeDebug(fmt.Sprintf("event: ignored %T", event))
		return false, nil
	}
}

func (b *Browser) handleKey(ctx context.Context, event *tcell.EventKey) error {
	switch b.mode {
	case modeFilter:
		b.handleFilterKey(event)
		return nil
	case modeGoto:
		b.handleGotoKey(event)
		return nil
	case modeConfirmDelete:
		return b.handleConfirmKey(ctx, event)
	case modeConfirmSwitch:
		b.handleSwitchKey(event)
		return nil
	case modeSavePath:
		b.handleSaveKey(event)
		return nil
	case modeConfirmOverwrite:
		b.handleOverwriteKey(event)
		return nil
	case modeNotice:
		b.dismissNotice()
		return nil
	case modeRunCommand:
		// The next keystroke after a refusal puts the question back, so the
		// reason is heard once and then the line is editable again.
		b.runRefused = false
		b.handleRunKey(event)
		return nil
	case modeRunning:
		b.handleRunningKey(event)
		return nil
	case modeView:
		// Routed here rather than falling through to the list, which would mean
		// d in the viewer deletes the entry being read. Silent and destructive.
		b.handleViewKey(event)
		return nil
	}
	return b.handleListKey(ctx, event)
}

func (b *Browser) handleFilterKey(event *tcell.EventKey) {
	switch event.Key() {
	case tcell.KeyEscape:
		b.filter = ""
		b.prompt.clear()
		b.mode = modeList
		b.selected, b.top = 0, 0
		b.setStatus("Filter cleared. %s", b.heading())
		return
	case tcell.KeyEnter:
		b.mode = modeList
		b.setStatus("%s", b.heading())
		return
	}
	if !b.editPrompt(event) {
		return
	}
	// The filter narrows the list as it is typed, so the edited line has to
	// reach the field the list reads on every keystroke.
	b.filter = b.prompt.String()
	b.selected, b.top = 0, 0
}

// editPrompt applies one editing keystroke to the open prompt and reports
// whether the text changed.
//
// It is shared by every prompt because they are all the same problem: a line
// being typed by someone who cannot see it. Left and Right so a mistake can be
// reached, Home and End so a long line can be crossed in one key, Delete so it
// can be reached from either side, and Ctrl+U to start over. Ctrl+A and Ctrl+E
// are here because terminals send them and fingers expect them.
func (b *Browser) editPrompt(event *tcell.EventKey) bool {
	switch event.Key() {
	case tcell.KeyLeft:
		b.prompt.left()
	case tcell.KeyRight:
		b.prompt.right()
	case tcell.KeyHome, tcell.KeyCtrlA:
		b.prompt.home()
	case tcell.KeyEnd, tcell.KeyCtrlE:
		b.prompt.end()
	case tcell.KeyBackspace, tcell.KeyBackspace2:
		b.prompt.backspace()
	case tcell.KeyDelete:
		b.prompt.deleteForward()
	case tcell.KeyCtrlU:
		b.prompt.clear()
	case tcell.KeyRune:
		b.prompt.insert(event.Rune())
	default:
		return false
	}
	return true
}

// handleGotoKey collects an entry number. Jumping by number matters most in a
// long list, where arrowing to entry 140 is not a reasonable request.
func (b *Browser) handleGotoKey(event *tcell.EventKey) {
	switch event.Key() {
	case tcell.KeyEscape:
		b.gotoText = ""
		b.prompt.clear()
		b.mode = modeList
		b.setStatus("Cancelled. %s", b.heading())
		return
	case tcell.KeyEnter:
		target, err := strconv.Atoi(strings.TrimSpace(b.gotoText))
		entries := b.visible()
		switch {
		case b.gotoText == "":
			b.setStatus("No number was typed. %s", b.heading())
		case err != nil:
			b.setStatus("%q is not a number.", b.gotoText)
		case len(entries) == 0:
			b.setStatus("There are no entries to go to.")
		case target < 0 || target >= len(entries):
			b.setStatus("Entry %d does not exist. Numbers run from 0 to %d.", target, len(entries)-1)
		default:
			b.selected = target
			b.clampSelection()
			b.setStatus("%s", b.heading())
		}
		b.gotoText = ""
		b.prompt.clear()
		b.mode = modeList
		return
	}
	if b.editPrompt(event) {
		b.gotoText = b.prompt.String()
	}
}

func (b *Browser) handleConfirmKey(ctx context.Context, event *tcell.EventKey) error {
	if event.Key() != tcell.KeyRune || (event.Rune() != 'y' && event.Rune() != 'Y') {
		b.mode = modeList
		b.setStatus("Deletion cancelled.")
		return nil
	}
	entries := b.visible()
	if b.selected >= len(entries) {
		b.mode = modeList
		return nil
	}
	entry := entries[b.selected]
	if err := b.Store.Delete(ctx, entry.ID); err != nil {
		return err
	}
	remaining := make([]model.Entry, 0, len(b.entries))
	for _, candidate := range b.entries {
		if !strings.EqualFold(candidate.ID, entry.ID) {
			remaining = append(remaining, candidate)
		}
	}
	b.entries = remaining
	// Held until acknowledged, for the same reason a save is. The caret returns
	// to the row being read, so a status line written on the way past is very
	// likely never spoken — and a deletion is the last thing that should
	// complete silently.
	b.returnMode = modeList
	b.notice("Deleted %s. Press any key to continue.", output.Preview(entry))
	return nil
}

func (b *Browser) handleListKey(ctx context.Context, event *tcell.EventKey) error {
	entries := b.visible()
	listRows := b.layout()

	switch event.Key() {
	case tcell.KeyUp:
		b.move(-1)
		return nil
	case tcell.KeyDown:
		b.move(1)
		return nil
	case tcell.KeyPgUp:
		b.move(-listRows)
		return nil
	case tcell.KeyPgDn:
		b.move(listRows)
		return nil
	case tcell.KeyHome:
		b.move(-len(entries))
		return nil
	case tcell.KeyEnd:
		b.move(len(entries))
		return nil
	case tcell.KeyTab:
		b.cycleKind(ctx)
		return nil
	case tcell.KeyEnter:
		if b.selected < len(entries) {
			b.chosen = b.text(entries[b.selected])
			b.quit = true
		}
		return nil
	case tcell.KeyEscape:
		if b.filter != "" {
			b.filter = ""
			b.selected, b.top = 0, 0
			b.setStatus("Filter cleared. %s", b.heading())
			return nil
		}
		b.quit = true
		return nil
	case tcell.KeyCtrlC:
		b.quit = true
		return nil
	}

	if event.Key() != tcell.KeyRune {
		return nil
	}
	switch event.Rune() {
	case 'q':
		b.quit = true
	case '/':
		b.prompt.set(b.filter)
		b.mode = modeFilter
	case 'g':
		b.gotoText = ""
		b.prompt.set("")
		b.mode = modeGoto
	case '?':
		b.openHelp()
	case 'r':
		entries, err := b.Store.Load(ctx)
		if err != nil {
			return err
		}
		b.entries = entries
		b.setStatus("Reloaded. %s", b.heading())
	case 'v':
		if b.selected < len(entries) {
			b.openViewer(entries[b.selected])
		}
	case 'w':
		// pick has exactly one output and its caller chose it. Writing a file a
		// pipeline knows nothing about is not that output.
		if b.PickOnly {
			b.setStatus("pick cannot write files. Use menu to save a clip to a file.")
			return nil
		}
		b.beginSave()
	case 'x':
		// Same principle, and a larger blast radius: pick is the form that
		// appears inside pipelines and scripts, so an arbitrary-program
		// affordance reachable from one is a wider surface than the same key in
		// an interactive menu.
		if b.PickOnly {
			b.setStatus("pick cannot run commands. Use menu to run a command on a clip.")
			return nil
		}
		b.beginRun()
	case 'u':
		// pick writes one clip and exits. Switching out of it would land the
		// user in the line interface's picker, and saving an interface
		// preference as a side effect of `pick | ssh host` would be a surprise
		// write to a file holding a credential. Refuse, and say why.
		if b.PickOnly {
			b.setStatus("pick cannot change interface. Use menu to switch.")
			return nil
		}
		// Confirmed rather than immediate: this is one keystroke with no Enter
		// behind it, and the consequence is the whole screen vanishing.
		b.mode = modeConfirmSwitch
		b.setStatus("Switch to the line interface? Press y to confirm, any other key to cancel.")
	case 'd':
		if b.PickOnly {
			b.setStatus("pick cannot change history. Use menu to delete.")
			return nil
		}
		if b.selected < len(entries) {
			b.mode = modeConfirmDelete
			b.setStatus("Delete %s? Press y to confirm, any other key to cancel.", output.Preview(entries[b.selected]))
		}
	}
	return nil
}

// handleSwitchKey answers the interface-switch question. It mirrors the delete
// confirmation exactly: y commits, anything else cancels, and the caret stays on
// the question until it is answered.
func (b *Browser) handleSwitchKey(event *tcell.EventKey) {
	if event.Key() == tcell.KeyRune && (event.Rune() == 'y' || event.Rune() == 'Y') {
		b.switching = true
		b.quit = true
		return
	}
	b.mode = modeList
	b.setStatus("Staying in the full-screen interface. %s", b.heading())
}

func (b *Browser) cycleKind(ctx context.Context) {
	next := operation.History
	switch b.Kind {
	case operation.History:
		next = operation.Templates
	case operation.Templates:
		next = operation.All
	}
	previous := b.Kind
	// The kind filter lives in the store's view, so the store has to learn the
	// new kind before the reload or it would return the old one.
	b.SetKind(next)
	entries, err := b.Store.Load(ctx)
	if err != nil {
		b.SetKind(previous)
		b.setStatus("Could not switch view: %v", err)
		return
	}
	b.entries = entries
	b.selected, b.top = 0, 0
	b.setStatus("%s", b.heading())
}

// move changes the selection. It sets no status message: navigation announces
// itself by the cursor landing on the row, and a message would only add noise
// to something the user just did deliberately.
func (b *Browser) move(delta int) {
	b.selected += delta
	b.clampSelection()
}

// KindSetter lets the caller keep the store's kind in step with Tab switching.
type KindSetter interface{ SetKind(operation.Kind) }

// SetKind updates both the browser and, when the store supports it, the view
// the store loads.
func (b *Browser) SetKind(kind operation.Kind) {
	b.Kind = kind
	if setter, ok := b.Store.(KindSetter); ok {
		setter.SetKind(kind)
	}
}
