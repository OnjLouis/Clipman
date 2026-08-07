package tui

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gdamore/tcell/v2"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/handoff"
)

var fixedNow = time.Date(2026, 8, 6, 12, 0, 0, 0, time.UTC)

func minutesAgo(count int) int64 {
	return fixedNow.Add(-time.Duration(count) * time.Minute).UnixMilli()
}

type fakeStore struct {
	entries []model.Entry
	kind    operation.Kind
	loads   int
	deleted []string
	loadErr error
}

func (s *fakeStore) SetKind(kind operation.Kind) { s.kind = kind }

func (s *fakeStore) Load(context.Context) ([]model.Entry, error) {
	s.loads++
	if s.loadErr != nil {
		return nil, s.loadErr
	}
	filtered := make([]model.Entry, 0, len(s.entries))
	for _, entry := range s.entries {
		switch s.kind {
		case operation.Templates:
			if !entry.IsTemplate {
				continue
			}
		case operation.All:
		default:
			if entry.IsTemplate {
				continue
			}
		}
		filtered = append(filtered, entry)
	}
	return filtered, nil
}

func (s *fakeStore) Delete(_ context.Context, id string) error {
	s.deleted = append(s.deleted, id)
	remaining := s.entries[:0]
	for _, entry := range s.entries {
		if entry.ID != id {
			remaining = append(remaining, entry)
		}
	}
	s.entries = remaining
	return nil
}

func (s *fakeStore) Create(_ context.Context, text, name string) (model.Entry, error) {
	entry := model.Entry{ID: "new", Text: text, Name: name, LastUsedUnixMs: fixedNow.UnixMilli()}
	s.entries = append([]model.Entry{entry}, s.entries...)
	return entry, nil
}

func sampleEntries(count int) []model.Entry {
	entries := make([]model.Entry, 0, count)
	for i := 0; i < count; i++ {
		entries = append(entries, model.Entry{
			ID:             fmt.Sprintf("id%02d", i),
			Text:           fmt.Sprintf("clip number %d", i),
			SourceMachine:  "workstation",
			LastUsedUnixMs: minutesAgo(i + 1),
		})
	}
	return entries
}

func key(k tcell.Key) tcell.Event { return tcell.NewEventKey(k, 0, tcell.ModNone) }
func runeKey(r rune) tcell.Event  { return tcell.NewEventKey(tcell.KeyRune, r, tcell.ModNone) }

// recordingScreen counts Fini calls so terminal restoration can be asserted
// directly, rather than inferred from a finalized screen's reported size.
type recordingScreen struct {
	tcell.SimulationScreen
	finis int
}

func (s *recordingScreen) Fini() {
	s.finis++
	s.SimulationScreen.Fini()
}

// newTestBrowser wires a browser to an initialized simulation screen and
// queues the keys to replay. Every test ends with a key that leaves, so
// PollEvent never blocks.
//
// The screen is initialized here and deliberately left live, because tests
// drive loop rather than Run: Run finalizes the screen on the way out, which
// clears its contents and its size, so anything asserted afterwards would be
// reading a corpse. Run's own lifecycle is covered separately.
func newTestBrowser(store *fakeStore, stdout *strings.Builder, events ...tcell.Event) (*Browser, tcell.SimulationScreen) {
	screen := tcell.NewSimulationScreen("UTF-8")
	if err := screen.Init(); err != nil {
		panic(err)
	}
	screen.SetSize(100, 24)
	browser := &Browser{
		Store: store, Screen: screen, Stdout: stdout,
		Kind: operation.History, Now: func() time.Time { return fixedNow },
	}
	go func() {
		for _, event := range events {
			screen.PostEvent(event)
		}
	}()
	return browser, screen
}

// loopUntil runs the same sequence as loop but stops after handling a fixed
// number of events and draws once more, so a test can inspect the interface
// mid-interaction — while a filter is being typed, for instance, rather than
// only after it has been dismissed.
func (b *Browser) loopUntil(ctx context.Context, events int) error {
	entries, err := b.Store.Load(ctx)
	if err != nil {
		return err
	}
	b.entries = entries
	b.applyArrival()
	b.setInitialStatus()
	for handled := 0; handled < events && !b.quit; handled++ {
		b.draw()
		event := b.Screen.PollEvent()
		if event == nil {
			break
		}
		if _, err := b.handle(ctx, event); err != nil {
			return err
		}
	}
	b.draw()
	return nil
}

// screenRows renders the simulation screen back into text lines.
func screenRows(t *testing.T, screen tcell.SimulationScreen) []string {
	t.Helper()
	cells, width, height := screen.GetContents()
	rows := make([]string, 0, height)
	for y := 0; y < height; y++ {
		var row strings.Builder
		for x := 0; x < width; x++ {
			cell := cells[y*width+x]
			if len(cell.Runes) > 0 {
				row.WriteRune(cell.Runes[0])
			} else {
				row.WriteRune(' ')
			}
		}
		rows = append(rows, strings.TrimRight(row.String(), " "))
	}
	return rows
}

func rowsContain(rows []string, want string) bool {
	for _, row := range rows {
		if strings.Contains(row, want) {
			return true
		}
	}
	return false
}

// TestCursorFollowsTheSelectedRow is the central accessibility assertion. A
// screen reader reads what is at the physical cursor, so a selection that only
// changed colors would be invisible to it.
func TestCursorFollowsTheSelectedRow(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(5)}
	var stdout strings.Builder
	// Two moves down, then a third, then quit. The cursor must land on the
	// matching row each time, at column zero.
	browser, screen := newTestBrowser(store, &stdout,
		key(tcell.KeyDown), key(tcell.KeyDown), key(tcell.KeyDown), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	x, y, visible := screen.GetCursor()
	if !visible {
		t.Fatal("the cursor must stay visible; a screen reader follows it")
	}
	if x != browser.caretColumn() {
		t.Fatalf("the cursor must sit on the space after the entry number, column %d, got %d", browser.caretColumn(), x)
	}
	wantRow := firstListRow + 3
	if y != wantRow {
		t.Fatalf("cursor row = %d, want %d for the fourth entry", y, wantRow)
	}
}

// TestCursorStartsInTheList covers real-terminal feedback: an earlier version
// parked the cursor on the status line before any key was pressed, which reads
// as the cursor being stuck outside the list you are trying to arrow through.
func TestCursorStartsInTheList(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	x, y, visible := screen.GetCursor()
	if !visible || x != browser.caretColumn() || y != firstListRow {
		t.Fatalf("the cursor must start on the first entry: got (%d,%d) visible %v, want (%d,%d)", x, y, visible, browser.caretColumn(), firstListRow)
	}
}

func TestCursorReturnsToTheListAfterAMessage(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	_, y, _ := screen.GetCursor()
	if y != firstListRow+1 {
		t.Fatalf("after navigating, the cursor belongs on the row: got %d, want %d", y, firstListRow+1)
	}
}

// TestCursorStaysInTheListAfterEveryAction walks the actions that used to hand
// the cursor to the status line. Losing your place in a list after each one is
// what made the cursor feel stuck.
func TestCursorStaysInTheListAfterEveryAction(t *testing.T) {
	cases := map[string][]tcell.Event{
		"after a delete":          {runeKey('d'), runeKey('y'), runeKey('z')},
		"after a reload":          {runeKey('r')},
		"after a kind switch":     {key(tcell.KeyTab)},
		"after clearing a filter": {runeKey('/'), runeKey('c'), key(tcell.KeyEnter), key(tcell.KeyEscape)},
		"after closing help":      {runeKey('?'), runeKey('q')},
		"after a rejected key":    {runeKey('z')},
	}
	for name, events := range cases {
		t.Run(name, func(t *testing.T) {
			store := &fakeStore{entries: sampleEntries(4)}
			var stdout strings.Builder
			browser, screen := newTestBrowser(store, &stdout, append(events, runeKey('q'))...)
			if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
				t.Fatalf("loop: %v", err)
			}
			listRows := browser.layout()
			x, y, visible := screen.GetCursor()
			if !visible {
				t.Fatal("the cursor must stay visible")
			}
			if y == statusRow {
				t.Fatalf("the cursor was left on the status line at row %d", y)
			}
			if x != browser.caretColumn() || y < firstListRow || y >= firstListRow+listRows {
				t.Fatalf("the cursor left the list: got (%d,%d), want column %d within rows %d to %d",
					x, y, browser.caretColumn(), firstListRow, firstListRow+listRows-1)
			}
		})
	}
}

// assertPromptHoldsCaret checks the shared prompt rule: the question and the
// answer typed so far are on one line, and the caret sits at the end of that
// answer, so reading the caret's line gives both.
func assertPromptHoldsCaret(t *testing.T, browser *Browser, screen tcell.SimulationScreen, wantTyped string) {
	t.Helper()
	label, typed, _, asking := browser.promptParts()
	if !asking {
		t.Fatal("expected the interface to be asking something")
	}
	if typed != wantTyped {
		t.Fatalf("typed answer = %q, want %q", typed, wantTyped)
	}
	x, y, visible := screen.GetCursor()
	wantX := len([]rune(label)) + len([]rune(typed))
	if !visible || y != statusRow || x != wantX {
		t.Fatalf("caret should follow the typed answer: got (%d,%d), want (%d,%d)", x, y, wantX, statusRow)
	}
	if !rowsContain(screenRows(t, screen), label+typed) {
		t.Fatalf("the question and the answer must share one line; screen has no %q", label+typed)
	}
}

// TestCursorEntersTheFilterBoxWhileTyping is the deliberate exception to the
// caret living in the list: while a filter is being typed, that box is what the
// user is working in.
func TestCursorEntersTheFilterBoxWhileTyping(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('/'), runeKey('c'), runeKey('l'), key(tcell.KeyEnter), runeKey('q'))
	// Stop after the two typed characters to inspect the caret mid-filter.
	if err := browser.loopUntil(context.Background(), 3); err != nil {
		t.Fatalf("loop: %v", err)
	}
	assertPromptHoldsCaret(t, browser, screen, "cl")
}

// TestGoToEntryPromptHoldsTheCaret covers jumping by number, which is the only
// practical way to reach entry 140 in a long list.
func TestGoToEntryPromptHoldsTheCaret(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(200)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout,
		runeKey('g'), runeKey('1'), runeKey('4'), runeKey('0'), key(tcell.KeyEnter), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 4); err != nil {
		t.Fatalf("loop: %v", err)
	}
	assertPromptHoldsCaret(t, browser, screen, "140")
}

func TestGoToEntryJumpsAndReturnsTheCaretToTheList(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(200)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout,
		runeKey('g'), runeKey('1'), runeKey('4'), runeKey('0'), key(tcell.KeyEnter), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	if browser.selected != 140 {
		t.Fatalf("selection = %d, want 140", browser.selected)
	}
	listRows := browser.layout()
	x, y, visible := screen.GetCursor()
	if !visible || x != browser.caretColumn() || y == statusRow || y < firstListRow || y >= firstListRow+listRows {
		t.Fatalf("after jumping the caret belongs on the list row: got (%d,%d)", x, y)
	}
	if !rowsContain(screenRows(t, screen), selectedMarker+"140. clip number 140") {
		t.Fatal("entry 140 was not scrolled into view and marked as selected")
	}
}

func TestGoToEntryRejectsBadInput(t *testing.T) {
	cases := map[string]struct {
		typed string
		want  string
	}{
		"out of range": {"99", "Entry 99 does not exist. Numbers run from 0 to 2."},
		"not a number": {"xy", `"xy" is not a number.`},
	}
	for name, item := range cases {
		t.Run(name, func(t *testing.T) {
			store := &fakeStore{entries: sampleEntries(3)}
			var stdout strings.Builder
			events := []tcell.Event{runeKey('g')}
			for _, r := range item.typed {
				events = append(events, runeKey(r))
			}
			events = append(events, key(tcell.KeyEnter), runeKey('q'))
			browser, screen := newTestBrowser(store, &stdout, events...)
			if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
				t.Fatalf("loop: %v", err)
			}
			if browser.selected != 0 {
				t.Fatalf("a rejected jump must not move the selection, got %d", browser.selected)
			}
			if !rowsContain(screenRows(t, screen), item.want) {
				t.Fatalf("expected %q on screen:\n%s", item.want, strings.Join(screenRows(t, screen), "\n"))
			}
		})
	}
}

func TestGoToEntryCanBeCancelled(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(5)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout,
		key(tcell.KeyDown), runeKey('g'), runeKey('4'), key(tcell.KeyEscape), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	if browser.selected != 1 {
		t.Fatalf("cancelling must leave the selection alone, got %d", browser.selected)
	}
}

// TestSelectedRowIsMarkedInText checks selection survives without color. A
// screen reader is told nothing by reverse video.
func TestSelectedRowIsMarkedInText(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	rows := screenRows(t, screen)
	if !rowsContain(rows, selectedMarker+"1. clip number 1") {
		t.Fatalf("the selected row carries no marker:\n%s", strings.Join(rows, "\n"))
	}
	for _, unselected := range []string{"0. clip number 0", "2. clip number 2"} {
		if !rowsContain(rows, unselectedMarker+unselected) {
			t.Fatalf("unselected row %q should be indented to match:\n%s", unselected, strings.Join(rows, "\n"))
		}
		if rowsContain(rows, selectedMarker+unselected) {
			t.Fatalf("row %q must not be marked selected", unselected)
		}
	}
}

// TestConfirmationTakesTheCursor is the other exception: a question the user
// must answer is what they are working in.
func TestConfirmationTakesTheCursor(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('d'), runeKey('n'), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loop: %v", err)
	}
	_, y, visible := screen.GetCursor()
	if !visible || y != statusRow {
		t.Fatalf("the confirmation must hold the cursor: got row %d, want %d", y, statusRow)
	}
}

// TestInitialResizeDoesNotDisturbTheCursor covers a real-terminal detail the
// simulation screen never produced on its own: tcell delivers a resize event
// when a real terminal starts.
func TestInitialResizeDoesNotDisturbTheCursor(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout,
		tcell.NewEventResize(100, 24), key(tcell.KeyDown), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	x, y, visible := screen.GetCursor()
	if !visible || x != browser.caretColumn() || y != firstListRow+1 {
		t.Fatalf("a resize must not move the cursor off the selected row: got (%d,%d) visible %v", x, y, visible)
	}
}

// TestRowsAreCompleteSentences checks the drawn row says the same words the
// line renderer announces, rather than relying on a visual-only highlight.
func TestRowsAreCompleteSentences(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{{
		ID: "a", Text: "kubectl get pods", Name: "pods", Group: "ops",
		SourceMachine: "workstation", Pinned: true, LastUsedUnixMs: minutesAgo(5),
	}}}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	rows := screenRows(t, screen)
	if !rowsContain(rows, "0. pods; pinned; group ops; from workstation; used 5m ago") {
		t.Fatalf("row is not a complete sentence:\n%s", strings.Join(rows, "\n"))
	}
}

func TestEnterWritesOnlyTheClipToStdout(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, key(tcell.KeyDown), key(tcell.KeyEnter))
	if err := browser.loop(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if stdout.String() != "clip number 1" {
		t.Fatalf("stdout must hold the clip and nothing else, got %q", stdout.String())
	}
}

func TestQuitWritesNothing(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("expected ErrCancelled, got %v", err)
	}
	if stdout.String() != "" {
		t.Fatalf("quitting must write nothing, got %q", stdout.String())
	}
}

func TestFilterNarrowsTheListLive(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{
		{ID: "a", Text: "aws s3 ls", LastUsedUnixMs: minutesAgo(1)},
		{ID: "b", Text: "kubectl get pods", LastUsedUnixMs: minutesAgo(2)},
		{ID: "c", Text: "aws ec2 describe", LastUsedUnixMs: minutesAgo(3)},
	}}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout,
		runeKey('/'), runeKey('a'), runeKey('w'), runeKey('s'), key(tcell.KeyEnter), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	rows := screenRows(t, screen)
	if !rowsContain(rows, "2 matches of 3 entries") {
		t.Fatalf("filter counts not announced:\n%s", strings.Join(rows, "\n"))
	}
	if rowsContain(rows, "kubectl") {
		t.Fatalf("filtered-out entry still shown:\n%s", strings.Join(rows, "\n"))
	}
}

func TestEscapeClearsTheFilterBeforeQuitting(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	// Filter, confirm, then Escape once to clear it and once to leave.
	browser, screen := newTestBrowser(store, &stdout,
		runeKey('/'), runeKey('2'), key(tcell.KeyEnter), key(tcell.KeyEscape), key(tcell.KeyEscape))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	rows := screenRows(t, screen)
	if !rowsContain(rows, "Filter cleared") {
		t.Fatalf("clearing the filter was not announced:\n%s", strings.Join(rows, "\n"))
	}
}

func TestTabSwitchesKindAndReloads(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{
		{ID: "a", Text: "ordinary", LastUsedUnixMs: minutesAgo(1)},
		{ID: "b", Text: "{{year_full}}", IsTemplate: true, Name: "today", LastUsedUnixMs: minutesAgo(2)},
	}}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyTab), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	if store.kind != operation.Templates {
		t.Fatalf("the store was not told about the new kind, got %q", store.kind)
	}
	rows := screenRows(t, screen)
	if !rowsContain(rows, "Clipman templates: 1 entry") {
		t.Fatalf("kind switch not announced:\n%s", strings.Join(rows, "\n"))
	}
}

func TestDeleteAsksBeforeActing(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('d'), runeKey('n'), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	if len(store.deleted) != 0 {
		t.Fatalf("nothing should have been deleted, got %v", store.deleted)
	}
	if !rowsContain(screenRows(t, screen), "Deletion cancelled") {
		t.Fatal("cancelling a delete was not announced")
	}
}

func TestDeleteRemovesTheEntryWithoutReloading(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('d'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	feedKeys(t, browser, runeKey('y'))

	if len(store.deleted) != 1 || store.deleted[0] != "id00" {
		t.Fatalf("expected id00 deleted, got %v", store.deleted)
	}
	if store.loads != 1 {
		t.Fatalf("a delete must not trigger a reload, got %d loads", store.loads)
	}
	// The deletion is announced as a notice rather than as a passing status
	// line, because the caret returns to the row being read and a status line
	// written on the way past is very likely never spoken.
	if browser.mode != modeNotice {
		t.Fatalf("mode = %v, want a notice the user has to acknowledge", browser.mode)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "Deleted clip number 0") {
		t.Fatalf("status = %q, want the deletion announced", row)
	}
	if _, y, _ := screen.GetCursor(); y != statusRow {
		t.Fatalf("caret at row %d, want it on the notice at row %d", y, statusRow)
	}

	feedKeys(t, browser, runeKey('z'))
	if browser.mode != modeList {
		t.Fatalf("mode = %v, want the list back", browser.mode)
	}
}

func TestPickRefusesToDelete(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('d'), runeKey('q'))
	browser.PickOnly = true
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	if len(store.deleted) != 0 {
		t.Fatalf("pick must not change history, got %v", store.deleted)
	}
	if !rowsContain(screenRows(t, screen), "pick cannot change history") {
		t.Fatal("the refusal was not explained")
	}
}

func TestPickReportsAnEmptyView(t *testing.T) {
	store := &fakeStore{}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, runeKey('q'))
	browser.PickOnly = true
	if err := browser.loop(context.Background()); !errors.Is(err, ErrNoEntries) {
		t.Fatalf("expected ErrNoEntries, got %v", err)
	}
}

func TestHelpListsEveryKey(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('?'), runeKey('q'), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	// Help is closed before the final draw, so assert on what the key list
	// itself contains rather than on the screen after it closed.
	for _, want := range []string{"Enter", "Tab", "filter", "delete", "reload", "quit"} {
		found := false
		for _, help := range helpLines {
			if strings.Contains(help, want) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("help does not mention %q", want)
		}
	}
	_ = screen
}

func TestTemplateIsResolvedOnOutput(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{
		{ID: "t", Text: "{{year_full}}", IsTemplate: true, LastUsedUnixMs: minutesAgo(1)},
	}}
	store.kind = operation.All
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, key(tcell.KeyEnter))
	browser.Kind = operation.All
	if err := browser.loop(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if stdout.String() != "2026" {
		t.Fatalf("template was not resolved, got %q", stdout.String())
	}
}

func TestNavigationStopsAtBothEnds(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout,
		key(tcell.KeyUp), key(tcell.KeyEnd), key(tcell.KeyDown), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	_, y, _ := screen.GetCursor()
	if y != firstListRow+2 {
		t.Fatalf("End then Down should rest on the last entry, cursor row %d", y)
	}
}

func TestLongListScrollsAndKeepsTheCursorOnScreen(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(200)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyEnd), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	// The list now runs to the bottom row, so the last row is a valid resting
	// place for the caret.
	listRows := browser.layout()
	_, y, visible := screen.GetCursor()
	if !visible || y < firstListRow || y >= firstListRow+listRows {
		t.Fatalf("the cursor left the visible list: row %d, list rows %d to %d", y, firstListRow, firstListRow+listRows-1)
	}
	if !rowsContain(screenRows(t, screen), selectedMarker+"199. clip number 199") {
		t.Fatal("the last entry was not scrolled into view")
	}
}

// newLifecycleBrowser builds a browser over a screen that counts Fini calls,
// and leaves Init to Run so the whole lifecycle is under test.
func newLifecycleBrowser(store *fakeStore, stdout *strings.Builder, events ...tcell.Event) (*Browser, *recordingScreen) {
	screen := &recordingScreen{SimulationScreen: tcell.NewSimulationScreen("UTF-8")}
	browser := &Browser{
		Store: store, Screen: screen, Stdout: stdout,
		Kind: operation.History, Now: func() time.Time { return fixedNow },
	}
	go func() {
		for _, event := range events {
			screen.PostEvent(event)
		}
	}()
	return browser, screen
}

// TestTerminalIsRestoredAfterAPanic proves the deferred Fini runs. Leaving a
// user in a raw-mode terminal with no echo is a worse failure than the panic
// that caused it.
func TestTerminalIsRestoredAfterAPanic(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	var stdout strings.Builder
	browser, screen := newLifecycleBrowser(store, &stdout, runeKey('q'))
	browser.Now = func() time.Time { panic("drawing blew up") }
	err := browser.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "stopped unexpectedly") {
		t.Fatalf("a panic should surface as an error, got %v", err)
	}
	if screen.finis != 1 {
		t.Fatalf("the terminal must be restored exactly once after a panic, got %d Fini calls", screen.finis)
	}
}

func TestTerminalIsRestoredOnNormalExit(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	var stdout strings.Builder
	browser, screen := newLifecycleBrowser(store, &stdout, runeKey('q'))
	if err := browser.Run(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}
	if screen.finis != 1 {
		t.Fatalf("the terminal must be restored exactly once, got %d Fini calls", screen.finis)
	}
}

// TestRunInitializesTheScreen checks Run does the setup loop tests skip, so the
// split between the two does not hide a missing Init.
func TestRunInitializesTheScreen(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	var stdout strings.Builder
	browser, screen := newLifecycleBrowser(store, &stdout, key(tcell.KeyEnter))
	if err := browser.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if stdout.String() != "clip number 0" {
		t.Fatalf("Run did not drive the loop, stdout = %q", stdout.String())
	}
	if screen.finis != 1 {
		t.Fatalf("expected one Fini, got %d", screen.finis)
	}
}

func TestLoadFailureIsReturned(t *testing.T) {
	store := &fakeStore{loadErr: errors.New("server is unavailable")}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loop(context.Background()); err == nil {
		t.Fatal("expected the load failure to surface")
	}
}

func TestMissingScreenIsReported(t *testing.T) {
	browser := &Browser{Store: &fakeStore{}}
	if err := browser.Run(context.Background()); err == nil {
		t.Fatal("expected a missing screen to be reported")
	}
}

// TestCaretSitsInTheSpaceAfterTheEntryNumber pins the agreed position: in
// "-> 1. test clip" the caret is on the space between "1." and the text.
func TestCaretSitsInTheSpaceAfterTheEntryNumber(t *testing.T) {
	for _, row := range []string{
		selectedMarker + "1. test clip; from box; used 1m ago",
		selectedMarker + "0. a; from box; used 1m ago",
		selectedMarker + "199. a longer one; from box; used 1m ago",
	} {
		column := spaceAfterNumber(row)
		runes := []rune(row)
		if runes[column] != ' ' {
			t.Errorf("row %q: column %d holds %q, want a space", row, column, string(runes[column]))
		}
		if runes[column-1] != '.' {
			t.Errorf("row %q: column %d does not follow the entry number", row, column)
		}
	}
}

// TestCaretColumnTracksTheNumberWidth checks the column is derived rather than
// fixed, so it stays correct as the list grows past nine entries.
func TestCaretColumnTracksTheNumberWidth(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(200)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('g'), runeKey('9'), runeKey('9'), key(tcell.KeyEnter), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	x, _, _ := screen.GetCursor()
	// "-> 99. " puts the space at index 6, one column further than "-> 9. ".
	if want := len(selectedMarker) + len("99."); x != want {
		t.Fatalf("caret column = %d, want %d for a two-digit entry number", x, want)
	}
}

// TestChromeIsAboveTheList is the ordering fix, stated as a property rather
// than as a screenshot.
//
// tcell emits only changed cells and scans top to bottom, so where a line sits
// decides when its text reaches the terminal, not the order draw calls are
// made. With the status line at the bottom, every full redraw finished by
// writing it, which is very likely why a screen reader kept reading it out.
// Keeping the heading, status, and preview above the list means the entry rows
// are written last.
func TestChromeIsAboveTheList(t *testing.T) {
	if statusRow >= firstListRow {
		t.Fatalf("the status line must be above the list: status row %d, first list row %d", statusRow, firstListRow)
	}
	if headingRow >= statusRow {
		t.Fatalf("the heading must be above the status line: %d, %d", headingRow, statusRow)
	}
	if previewRow >= firstListRow {
		t.Fatalf("the preview must be above the list: preview row %d, first list row %d", previewRow, firstListRow)
	}
}

// TestListRunsToTheBottomOfTheWindow follows from the layout: with nothing
// below the list, the rows are the last thing written on every frame.
func TestListRunsToTheBottomOfTheWindow(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(100)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	_, height := screen.Size()
	if want := height - firstListRow; browser.layout() != want {
		t.Fatalf("list rows = %d, want %d so the list reaches the last row", browser.layout(), want)
	}
	rows := screenRows(t, screen)
	if rows[height-1] == "" {
		t.Fatalf("the bottom row should hold an entry, not chrome:\n%s", strings.Join(rows, "\n"))
	}
}

// TestStatusLineNeverHoldsTheCaretWhileBrowsing states the default plainly.
func TestStatusLineNeverHoldsTheCaretWhileBrowsing(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(6)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout,
		key(tcell.KeyDown), key(tcell.KeyDown), key(tcell.KeyUp), key(tcell.KeyEnd), key(tcell.KeyHome), runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	_, y, visible := screen.GetCursor()
	if !visible || y == statusRow || y == headingRow || y == previewRow {
		t.Fatalf("the caret must rest in the list while browsing, got row %d", y)
	}
}

// changedRows reports which screen rows differ between two captures.
func changedRows(before, after []string) []int {
	var changed []int
	for index := range before {
		if index < len(after) && before[index] != after[index] {
			changed = append(changed, index)
		}
	}
	return changed
}

// changedCells counts differing characters between two captures.
func changedCells(before, after []string) int {
	count := 0
	for index := range before {
		if index >= len(after) {
			break
		}
		left, right := []rune(before[index]), []rune(after[index])
		longest := len(left)
		if len(right) > longest {
			longest = len(right)
		}
		for column := 0; column < longest; column++ {
			var leftRune, rightRune rune = ' ', ' '
			if column < len(left) {
				leftRune = left[column]
			}
			if column < len(right) {
				rightRune = right[column]
			}
			if leftRune != rightRune {
				count++
			}
		}
	}
	return count
}

// step draws, delivers one event, and draws again, returning the screen before
// and after. It exercises the real draw path rather than a simulation of it.
func step(t *testing.T, browser *Browser, screen tcell.SimulationScreen, event tcell.Event) (before, after []string) {
	t.Helper()
	entries, err := browser.Store.Load(context.Background())
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	browser.entries = entries
	browser.setInitialStatus()
	browser.draw()
	before = screenRows(t, screen)
	if _, err := browser.handle(context.Background(), event); err != nil {
		t.Fatalf("handle: %v", err)
	}
	browser.draw()
	return before, screenRows(t, screen)
}

// TestArrowKeyRedrawsAlmostNothing is the redraw budget. Everything redrawn is
// resent to the terminal and therefore to a screen reader, so moving the
// selection must touch the two affected rows and the preview of the selected
// clip, and nothing else — never the whole screen.
//
// Redrawing those two rows in full is accepted, so that the selected row can
// carry a visible highlight for sighted users. This check compares characters
// rather than styles, so a restyled row registers only through its marker;
// what it really pins down is that no other row is rewritten.
func TestArrowKeyRedrawsAlmostNothing(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(20)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout)
	before, after := step(t, browser, screen, key(tcell.KeyDown))

	changed := changedRows(before, after)
	want := map[int]string{
		previewRow:       "the preview of the selected clip",
		firstListRow:     "the row losing the marker",
		firstListRow + 1: "the row gaining the marker",
	}
	for _, row := range changed {
		if _, expected := want[row]; !expected {
			t.Errorf("row %d should not have changed on an arrow key: %q -> %q", row, before[row], after[row])
		}
	}
	// Guard against the whole check passing because nothing moved at all.
	seen := map[int]bool{}
	for _, row := range changed {
		seen[row] = true
	}
	for row, description := range want {
		if !seen[row] {
			t.Errorf("row %d (%s) did not change; the arrow key did nothing", row, description)
		}
	}
	// The entry text on both rows is unchanged; only the marker moves.
	for _, row := range []int{firstListRow, firstListRow + 1} {
		if strings.TrimLeft(before[row], "- >") != strings.TrimLeft(after[row], "- >") {
			t.Errorf("row %d resent its entry text, not just the marker:\n before %q\n after  %q", row, before[row], after[row])
		}
	}
	if cells := changedCells(before[firstListRow:firstListRow+2], after[firstListRow:firstListRow+2]); cells > 2*len(selectedMarker) {
		t.Errorf("an arrow key changed %d characters across the two rows, want at most %d", cells, 2*len(selectedMarker))
	}
	// Nothing outside the list and the preview is touched, which is the part
	// that matters: the screen is never wholesale repainted.
	for row := range before {
		if row == previewRow || row == firstListRow || row == firstListRow+1 {
			continue
		}
		if before[row] != after[row] {
			t.Errorf("row %d was repainted needlessly: %q -> %q", row, before[row], after[row])
		}
	}
}

// TestHeadingAndStatusSurviveNavigationUntouched keeps the chrome out of the
// per-keystroke redraw. Rewriting it would resend it on every arrow key.
func TestHeadingAndStatusSurviveNavigationUntouched(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(20)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout)
	before, after := step(t, browser, screen, key(tcell.KeyDown))
	for _, row := range []int{headingRow, statusRow, previewLabelRow} {
		if before[row] != after[row] {
			t.Errorf("row %d changed on an arrow key: %q -> %q", row, before[row], after[row])
		}
	}
}

// TestCaretRestsOnTheSelectedRowAfterAFullRedraw covers the case that has to
// repaint everything. Paging cannot avoid rewriting the list, so what matters
// is where the caret ends up once it has.
func TestCaretRestsOnTheSelectedRowAfterAFullRedraw(t *testing.T) {
	for name, event := range map[string]tcell.Event{
		"page down": key(tcell.KeyPgDn),
		"end":       key(tcell.KeyEnd),
		"reload":    runeKey('r'),
	} {
		t.Run(name, func(t *testing.T) {
			store := &fakeStore{entries: sampleEntries(200)}
			var stdout strings.Builder
			browser, screen := newTestBrowser(store, &stdout)
			_, after := step(t, browser, screen, event)

			listRows := browser.layout()
			x, y, visible := screen.GetCursor()
			if !visible {
				t.Fatal("the caret must stay visible after a full redraw")
			}
			if y < firstListRow || y >= firstListRow+listRows {
				t.Fatalf("the caret left the list after a full redraw: row %d", y)
			}
			if x != browser.caretColumn() {
				t.Fatalf("caret column = %d, want %d", x, browser.caretColumn())
			}
			// The row under the caret is the selected one.
			if !strings.HasPrefix(after[y], selectedMarker) {
				t.Fatalf("the caret is not on the marked row: %q", after[y])
			}
		})
	}
}

// TestCaretPositionIsTheListWhileBrowsing checks the placement decision
// directly, with no screen involved, so a report of the caret being on the
// status line can be traced to either this decision or to what happens after
// it reaches the terminal.
func TestCaretPositionIsTheListWhileBrowsing(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(10)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout)
	entries, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	browser.entries = entries

	for _, selected := range []int{0, 1, 5, 9} {
		browser.selected = selected
		column, row := browser.caretPosition()
		if row == statusRow {
			t.Fatalf("selection %d put the caret on the status line", selected)
		}
		if want := firstListRow + selected - browser.top; row != want {
			t.Fatalf("selection %d gave caret row %d, want %d", selected, row, want)
		}
		if column <= 0 {
			t.Fatalf("selection %d gave caret column %d", selected, column)
		}
	}
}

// TestCaretPositionFollowsAPromptOnlyWhileItIsOpen makes the one exception
// explicit: a prompt takes the caret to the status line, and closing it hands
// the caret straight back to the list.
func TestCaretPositionFollowsAPromptOnlyWhileItIsOpen(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(5)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout)
	entries, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	browser.entries = entries

	for _, open := range []mode{modeFilter, modeGoto, modeConfirmDelete} {
		browser.mode = open
		if _, row := browser.caretPosition(); row != statusRow {
			t.Errorf("mode %v should hold the caret on the prompt row, got %d", open, row)
		}
		browser.mode = modeList
		if _, row := browser.caretPosition(); row == statusRow {
			t.Errorf("closing mode %v left the caret on the status line", open)
		}
	}
}

// TestDebugReportNamesTheRowUnderTheCaret keeps the diagnostic trustworthy: it
// reads the row back off the screen rather than repeating what the code meant
// to draw.
func TestDebugReportNamesTheRowUnderTheCaret(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(4)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown), runeKey('q'))
	browser.DebugPath = filepath.Join(t.TempDir(), "trace.txt")
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	report := browser.caretReport()
	if !strings.Contains(report, "mode=list") {
		t.Errorf("report should say the caret was in the list: %s", report)
	}
	if !strings.Contains(report, selectedMarker+"1. clip number 1") {
		t.Errorf("report should quote the selected row: %s", report)
	}
	_, y, _ := screen.GetCursor()
	if !strings.Contains(report, fmt.Sprintf("row=%d", y)) {
		t.Errorf("report row disagrees with the screen cursor at %d: %s", y, report)
	}
}

// TestDebugTraceIsWrittenToDisk covers the diagnostic path end to end. Standard
// error is discarded when the terminal is restored, so the trace has to reach a
// file to be readable at all.
func TestDebugTraceIsWrittenToDisk(t *testing.T) {
	directory := t.TempDir()

	store := &fakeStore{entries: sampleEntries(4)}
	var stdout strings.Builder
	browser, _ := newLifecycleBrowser(store, &stdout, key(tcell.KeyDown), key(tcell.KeyDown), runeKey('q'))
	browser.DebugPath = filepath.Join(directory, "output.txt")
	if err := browser.Run(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("Run: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(directory, "output.txt"))
	if err != nil {
		t.Fatalf("the trace was not written: %v", err)
	}
	trace := string(data)
	for _, want := range []string{"caret trace", "layout rows:", "draw 1:", "final:", "mode=list"} {
		if !strings.Contains(trace, want) {
			t.Errorf("trace does not contain %q:\n%s", want, trace)
		}
	}
	// The trace records movement, not just a single frame.
	if strings.Count(trace, "draw ") < 3 {
		t.Errorf("expected a line per draw:\n%s", trace)
	}
	if !strings.Contains(trace, selectedMarker+"2. clip number 2") {
		t.Errorf("the trace should quote the row under the caret after two moves:\n%s", trace)
	}
}

// TestDefaultDebugPathIsBesideTheProgram puts the trace somewhere the user can
// already find, rather than in a working directory they may not know.
func TestDefaultDebugPathIsBesideTheProgram(t *testing.T) {
	path := DefaultDebugPath()
	if !filepath.IsAbs(path) {
		t.Fatalf("the default trace path should be absolute, got %q", path)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Skipf("the executable path is unavailable here: %v", err)
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	if filepath.Dir(path) != filepath.Dir(executable) {
		t.Fatalf("trace path %q is not beside the program %q", path, executable)
	}
}

// TestDebugRowIsBlankWhenNotDebugging keeps the diagnostic out of ordinary use.
func TestDebugRowIsBlankWhenNotDebugging(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	if row := screenRows(t, screen)[debugRow]; row != "" {
		t.Fatalf("the debug row should be blank in normal use, got %q", row)
	}
}

// TestDebugRowNamesTheCaretPosition checks the on-screen line, for when the
// file is inconvenient to reach.
func TestDebugRowNamesTheCaretPosition(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown), runeKey('q'))
	browser.DebugPath = filepath.Join(t.TempDir(), "trace.txt")
	if err := browser.loop(context.Background()); !errors.Is(err, ErrCancelled) {
		t.Fatalf("loop: %v", err)
	}
	row := screenRows(t, screen)[debugRow]
	if !strings.HasPrefix(row, "DEBUG caret row ") {
		t.Fatalf("debug row = %q", row)
	}
	if !strings.Contains(row, fmt.Sprintf("row %d", firstListRow+1)) {
		t.Errorf("debug row should name the selected entry's row: %q", row)
	}
	if !strings.Contains(row, "mode list") {
		t.Errorf("debug row should name the mode: %q", row)
	}
}

// TestTheInterfaceNamesItselfOnTheFirstFrame is the tui half of the
// discoverability guard. Two interchangeable interfaces ship; a user dropped
// into one of them with nothing naming it has no reason to look for the other.
// The status row is the right place: it is written on the first frame, when the
// whole screen is new, and skipped during navigation by design.
func TestTheInterfaceNamesItselfOnTheFirstFrame(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	status := screenRows(t, screen)[statusRow]
	if !strings.Contains(status, "Full-screen interface") {
		t.Fatalf("the status row must name the interface on entry, got %q", status)
	}
	// The entry count still has to survive; naming the interface must not cost
	// the information that was already there.
	if !strings.Contains(status, "entries") {
		t.Fatalf("the opening status must still report the entry count, got %q", status)
	}
}

// TestHelpNamesTheOtherInterface checks the escape hatch is documented where a
// user would look for it.
func TestHelpNamesTheOtherInterface(t *testing.T) {
	help := strings.Join(helpLines, "\n")
	for _, want := range []string{"line interface", "u  "} {
		if !strings.Contains(help, want) {
			t.Fatalf("the key list must mention %q so the other interface is reachable\n%s", want, help)
		}
	}
}

// TestSwitchingAsksFirst covers the deliberate cost of one extra keystroke. In
// this interface u is a bare key with no Enter behind it, and the consequence is
// the entire screen vanishing, so a stray press must not be able to do it.
func TestSwitchingAsksFirst(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(4)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('u'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.switching {
		t.Fatal("u alone must not switch; it must ask first")
	}
	rows := screenRows(t, screen)
	if !strings.Contains(rows[statusRow], "Press y to confirm") {
		t.Fatalf("the question must be on the status row, got %q", rows[statusRow])
	}
	// The caret belongs on the question, exactly as it does for the delete
	// confirmation. A question the user has to answer is the one place the
	// caret leaves the list.
	x, y, visible := screen.GetCursor()
	if !visible || y != statusRow {
		t.Fatalf("the confirmation must hold the caret: got (%d,%d) visible %v, want row %d", x, y, visible, statusRow)
	}
}

// TestCancellingASwitchReturnsTheCaretToTheRow is the other half: answering
// anything but y must put the user back exactly where they were.
func TestCancellingASwitchReturnsTheCaretToTheRow(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(4)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, key(tcell.KeyDown), runeKey('u'), runeKey('n'))
	if err := browser.loopUntil(context.Background(), 3); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.switching {
		t.Fatal("only y may confirm a switch")
	}
	if browser.mode != modeList {
		t.Fatalf("cancelling must return to the list, mode = %v", browser.mode)
	}
	_, y, _ := screen.GetCursor()
	if want := firstListRow + 1; y != want {
		t.Fatalf("the caret must return to the row it left, got %d want %d", y, want)
	}
}

// TestConfirmedSwitchCarriesThePlace is the accessibility assertion for the
// switch itself. The whole screen changes under someone who cannot see it, so
// arriving at the top of an unfiltered list is how a person loses their place.
func TestConfirmedSwitchCarriesThePlace(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(8)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout,
		runeKey('/'), runeKey('c'), key(tcell.KeyEnter),
		key(tcell.KeyDown), key(tcell.KeyDown),
		runeKey('u'), runeKey('y'))
	browser.Kind = operation.Templates

	err := browser.loop(context.Background())

	var request *handoff.Request
	if !errors.As(err, &request) {
		t.Fatalf("a confirmed switch must report a handoff, got %v", err)
	}
	if request.Selected != 2 {
		t.Errorf("the selected row must travel: got %d, want 2", request.Selected)
	}
	if request.Filter != "c" {
		t.Errorf("the active filter must travel: got %q, want %q", request.Filter, "c")
	}
	// Tab changes the kind here and the line interface cannot, so losing it
	// would land the user in a view they never asked for.
	if request.Kind != operation.Templates {
		t.Errorf("the kind must travel: got %v, want %v", request.Kind, operation.Templates)
	}
}

// TestArrivalLandsTheCaretWhereTheUserLeftOff is the receiving half.
func TestArrivalLandsTheCaretWhereTheUserLeftOff(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(8)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('q'))
	browser.Arrival = &handoff.Request{Selected: 3, Kind: operation.History}
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	_, y, visible := screen.GetCursor()
	if want := firstListRow + 3; !visible || y != want {
		t.Fatalf("arrival must land the caret on the carried row: got %d visible %v, want %d", y, visible, want)
	}
}

// TestPickRefusesToSwitch guards the trap: line.Pick has no u, so a picker that
// let you leave would be one you could not get back to.
func TestPickRefusesToSwitch(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('u'))
	browser.PickOnly = true
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.switching || browser.mode != modeList {
		t.Fatal("pick must not switch interface")
	}
	if status := screenRows(t, screen)[statusRow]; !strings.Contains(status, "pick cannot change interface") {
		t.Fatalf("pick must say why it refused, got %q", status)
	}
}

func viewerBrowser(t *testing.T, text string, events ...tcell.Event) (*Browser, tcell.SimulationScreen) {
	t.Helper()
	entries := sampleEntries(3)
	entries[1].Text = text
	store := &fakeStore{entries: entries}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, events...)
	browser.selected = 1
	return browser, screen
}

// TestViewerOpensOnTheFirstLineWithTheCaretOnIt. Opening a viewer that leaves
// the caret somewhere other than the text is a viewer that reads as empty.
func TestViewerOpensOnTheFirstLineWithTheCaretOnIt(t *testing.T) {
	browser, screen := viewerBrowser(t, "first line\nsecond line\nthird line", runeKey('v'), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.mode != modeView {
		t.Fatalf("v must open the viewer, mode = %v", browser.mode)
	}
	rows := screenRows(t, screen)
	if !strings.Contains(rows[firstListRow], "1. first line") {
		t.Fatalf("first viewer row = %q, want line 1", rows[firstListRow])
	}
	x, y, visible := screen.GetCursor()
	if !visible || y != firstListRow {
		t.Fatalf("caret at (%d,%d) visible %v, want row %d", x, y, visible, firstListRow)
	}
	if want := browser.caretColumn(); x != want {
		t.Errorf("caret column = %d, want %d, the space after the line number", x, want)
	}
}

// TestViewerCaretFollowsTheLine is the viewer's version of the central
// accessibility assertion: a screen reader reads what is at the caret.
func TestViewerCaretFollowsTheLine(t *testing.T) {
	browser, screen := viewerBrowser(t, "alpha\nbravo\ncharlie\ndelta",
		runeKey('v'), key(tcell.KeyDown), key(tcell.KeyDown), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 3); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	_, y, _ := screen.GetCursor()
	if want := firstListRow + 2; y != want {
		t.Fatalf("caret row = %d, want %d", y, want)
	}
	if row := screenRows(t, screen)[y]; !strings.Contains(row, "3. charlie") {
		t.Fatalf("row under the caret = %q, want line 3", row)
	}
}

// TestViewerNeverLetsTheStatusLineHoldTheCaret while reading, same rule as the
// list. Events are stepped by hand rather than through the loop, so each motion
// can be checked on its own.
func TestViewerNeverLetsTheStatusLineHoldTheCaret(t *testing.T) {
	browser, screen := viewerBrowser(t, strings.Repeat("a line of text\n", 40), runeKey('v'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	for _, event := range []tcell.Event{
		key(tcell.KeyDown), key(tcell.KeyPgDn), runeKey(' '),
		runeKey('b'), key(tcell.KeyEnd), key(tcell.KeyHome), key(tcell.KeyUp),
	} {
		if _, err := browser.handle(context.Background(), event); err != nil {
			t.Fatalf("handle: %v", err)
		}
		browser.draw()
		x, y, visible := screen.GetCursor()
		if !visible {
			t.Fatal("the caret must stay visible while reading")
		}
		if y == statusRow {
			t.Fatalf("the caret was left on the status line after %v", event)
		}
		if y < firstListRow {
			t.Fatalf("the caret left the clip: row %d", y)
		}
		if want := browser.caretColumn(); x != want {
			t.Errorf("caret column = %d, want %d", x, want)
		}
	}
}

// TestDeleteInTheViewerDoesNothing is the blocker. Falling through to the list
// handler would make d delete the entry being read, silently.
func TestDeleteInTheViewerDoesNothing(t *testing.T) {
	browser, _ := viewerBrowser(t, "some text", runeKey('v'), runeKey('d'), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 2); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.mode != modeView {
		t.Fatalf("d in the viewer must not leave it, mode = %v", browser.mode)
	}
	store := browser.Store.(*fakeStore)
	if len(store.deleted) != 0 {
		t.Fatalf("d in the viewer deleted %v", store.deleted)
	}
}

// TestClosingTheViewerRestoresTheList, at the entry it was opened from. The
// viewer must not have moved the list underneath it.
func TestClosingTheViewerRestoresTheList(t *testing.T) {
	browser, screen := viewerBrowser(t, strings.Repeat("line\n", 60),
		runeKey('v'), key(tcell.KeyEnd), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 3); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.mode != modeList {
		t.Fatalf("q must close the viewer, mode = %v", browser.mode)
	}
	if browser.selected != 1 {
		t.Fatalf("selection moved to %d; scrolling a clip must not move the list", browser.selected)
	}
	_, y, _ := screen.GetCursor()
	if want := firstListRow + 1; y != want {
		t.Fatalf("caret row after closing = %d, want %d", y, want)
	}
}

// TestEnterInTheViewerStillEmits. Enter means one thing everywhere, and a
// pipeline depends on it.
func TestEnterInTheViewerStillEmits(t *testing.T) {
	entries := sampleEntries(3)
	entries[1].Text = "the whole clip\nsecond line"
	store := &fakeStore{entries: entries}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, runeKey('v'), key(tcell.KeyEnter))
	browser.selected = 1
	if err := browser.loop(context.Background()); err != nil {
		t.Fatalf("loop: %v", err)
	}
	if stdout.String() != "the whole clip\nsecond line" {
		t.Fatalf("stdout = %q, want the whole clip", stdout.String())
	}
}

// TestViewerWrapsRatherThanTruncates. A viewer that drops the end of a long
// line is a viewer that cannot show the clip.
func TestViewerWrapsRatherThanTruncates(t *testing.T) {
	long := strings.Repeat("0123456789", 30)
	browser, screen := viewerBrowser(t, long, runeKey('v'), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	var seen strings.Builder
	for _, row := range screenRows(t, screen)[firstListRow:] {
		if trimmed := strings.TrimSpace(row); trimmed != "" {
			_, text, _ := strings.Cut(trimmed, " ")
			seen.WriteString(text)
		}
	}
	if !strings.Contains(seen.String(), long[:200]) {
		t.Errorf("the viewer truncated a long line instead of wrapping it")
	}
	if len(browser.viewRows) < 2 {
		t.Errorf("a 300-character line produced %d rows, want several", len(browser.viewRows))
	}
}

// TestArrowInTheViewerRedrawsAlmostNothing holds the viewer to the same budget
// as the list: everything rewritten is resent to the screen reader.
func TestArrowInTheViewerRedrawsAlmostNothing(t *testing.T) {
	browser, screen := viewerBrowser(t, strings.Repeat("a line\n", 40), runeKey('v'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	before := screenRows(t, screen)
	if _, err := browser.handle(context.Background(), key(tcell.KeyDown)); err != nil {
		t.Fatalf("handle: %v", err)
	}
	browser.draw()
	after := screenRows(t, screen)
	changed := 0
	for index := range before {
		if before[index] != after[index] {
			changed++
		}
	}
	if changed > 3 {
		t.Fatalf("one arrow key rewrote %d rows; only the two markers should change", changed)
	}
}

// feedKeys drives events through the real handler and redraws, which is how
// these assertions stay about the interface rather than about the editor.
func feedKeys(t *testing.T, browser *Browser, events ...tcell.Event) {
	t.Helper()
	for _, event := range events {
		if _, err := browser.handle(context.Background(), event); err != nil {
			t.Fatalf("handle: %v", err)
		}
		browser.draw()
	}
}

func openFilter(t *testing.T, text string) (*Browser, tcell.SimulationScreen) {
	t.Helper()
	store := &fakeStore{entries: sampleEntries(4)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('/'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	for _, r := range text {
		feedKeys(t, browser, runeKey(r))
	}
	return browser, screen
}

// TestTheCaretFollowsTheEditingPosition is the whole point of item 5. Until
// this, the caret sat at the end of the line no matter where the user was
// working, so moving back to a mistake read as nothing happening.
func TestTheCaretFollowsTheEditingPosition(t *testing.T) {
	browser, screen := openFilter(t, "clip")
	endX, _, _ := screen.GetCursor()

	feedKeys(t, browser, key(tcell.KeyLeft), key(tcell.KeyLeft))

	x, y, visible := screen.GetCursor()
	if !visible || y != statusRow {
		t.Fatalf("the caret must stay on the question: (%d,%d) visible %v", x, y, visible)
	}
	if x != endX-2 {
		t.Fatalf("caret column = %d, want %d after moving left twice", x, endX-2)
	}
}

// TestTypingInsertsWhereTheCaretIs, end to end through the key handler, and the
// live filter must see the edited line rather than the old one.
func TestTypingInsertsWhereTheCaretIs(t *testing.T) {
	browser, _ := openFilter(t, "cip")
	feedKeys(t, browser, key(tcell.KeyLeft), key(tcell.KeyLeft), runeKey('l'))
	if browser.filter != "clip" {
		t.Fatalf("filter = %q, want %q; the live filter must see the edit", browser.filter, "clip")
	}
	_, typed, cursor, asking := browser.promptParts()
	if !asking || typed != "clip" {
		t.Fatalf("prompt shows %q, want %q", typed, "clip")
	}
	if cursor != 2 {
		t.Errorf("caret offset = %d, want 2, just after what was typed", cursor)
	}
}

// TestBackspaceReachesAMistakeInTheMiddle without destroying what follows it.
func TestBackspaceReachesAMistakeInTheMiddle(t *testing.T) {
	browser, _ := openFilter(t, "cllip")
	feedKeys(t, browser, key(tcell.KeyLeft), key(tcell.KeyLeft), key(tcell.KeyBackspace))
	if browser.filter != "clip" {
		t.Fatalf("filter = %q, want %q", browser.filter, "clip")
	}
}

// TestDeleteRemovesForward so a mistake can be reached from either side.
func TestDeleteRemovesForward(t *testing.T) {
	browser, _ := openFilter(t, "cllip")
	feedKeys(t, browser, key(tcell.KeyHome), key(tcell.KeyRight), key(tcell.KeyDelete))
	if browser.filter != "clip" {
		t.Fatalf("filter = %q, want %q", browser.filter, "clip")
	}
}

// TestControlUStartsOver. Correcting a long command line one character at a
// time is the thing this key exists to avoid.
func TestControlUStartsOver(t *testing.T) {
	browser, screen := openFilter(t, "a long mistaken line")
	feedKeys(t, browser, key(tcell.KeyCtrlU))
	if browser.filter != "" {
		t.Fatalf("filter = %q, want it cleared", browser.filter)
	}
	label, _, _, _ := browser.promptParts()
	x, y, _ := screen.GetCursor()
	if y != statusRow || x != len([]rune(label)) {
		t.Fatalf("caret at (%d,%d), want it just after the question at column %d", x, y, len([]rune(label)))
	}
	// The question must still be on the row, or clearing reads as the prompt
	// vanishing rather than emptying.
	if row := screenRows(t, screen)[statusRow]; !strings.HasPrefix(row, "Filter by text:") {
		t.Fatalf("status row = %q, want the question still there", row)
	}
}

func TestHomeAndEndCrossTheLineInOneKey(t *testing.T) {
	browser, _ := openFilter(t, "clip")
	feedKeys(t, browser, key(tcell.KeyHome))
	if _, _, cursor, _ := browser.promptParts(); cursor != 0 {
		t.Fatalf("caret offset after Home = %d, want 0", cursor)
	}
	feedKeys(t, browser, key(tcell.KeyEnd))
	if _, _, cursor, _ := browser.promptParts(); cursor != 4 {
		t.Fatalf("caret offset after End = %d, want 4", cursor)
	}
}

// TestGoToPromptEditsToo, because the same editing applies to every question.
func TestGoToPromptEditsToo(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(30)}
	var stdout strings.Builder
	browser, _ := newTestBrowser(store, &stdout, runeKey('g'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	feedKeys(t, browser, runeKey('1'), runeKey('3'), key(tcell.KeyLeft), runeKey('2'))
	if browser.gotoText != "123" {
		t.Fatalf("gotoText = %q, want %q", browser.gotoText, "123")
	}
	feedKeys(t, browser, key(tcell.KeyCtrlU), runeKey('7'), key(tcell.KeyEnter))
	if browser.selected != 7 {
		t.Fatalf("selected = %d, want 7 after correcting the number", browser.selected)
	}
}

// TestResumingAFilterPutsTheCaretAtTheEnd, which is where someone continuing an
// existing filter expects to carry on from.
func TestResumingAFilterPutsTheCaretAtTheEnd(t *testing.T) {
	browser, _ := openFilter(t, "clip")
	feedKeys(t, browser, key(tcell.KeyEnter))
	feedKeys(t, browser, runeKey('/'))
	_, typed, cursor, asking := browser.promptParts()
	if !asking || typed != "clip" {
		t.Fatalf("reopened filter shows %q, want the existing filter", typed)
	}
	if cursor != 4 {
		t.Errorf("caret offset = %d, want 4, the end of the existing text", cursor)
	}
}

// TestCaretColumnIsMeasuredInColumnsNotCharacters. A wide character occupies
// two cells, so a caret placed by counting characters lands short by one column
// for every one of them — and the screen reader is then reading a different
// place than the user is editing.
func TestCaretColumnIsMeasuredInColumnsNotCharacters(t *testing.T) {
	browser, screen := openFilter(t, "日本語")

	label, typed, cursor, asking := browser.promptParts()
	if !asking || typed != "日本語" {
		t.Fatalf("prompt shows %q, want the typed text", typed)
	}
	if cursor != 3 {
		t.Fatalf("caret offset = %d, want 3 characters", cursor)
	}

	x, y, visible := screen.GetCursor()
	if !visible || y != statusRow {
		t.Fatalf("caret at (%d,%d) visible %v, want the question row", x, y, visible)
	}
	// Three double-width characters occupy six columns, not three.
	want := displayWidth(label) + 6
	if x != want {
		t.Fatalf("caret column = %d, want %d; a rune count is not a column", x, want)
	}
}

// TestCaretColumnTracksAWideCharacterAsItMoves, so moving left over one steps
// back two columns rather than one.
func TestCaretColumnTracksAWideCharacterAsItMoves(t *testing.T) {
	browser, screen := openFilter(t, "日本")
	before, _, _ := screen.GetCursor()
	feedKeys(t, browser, key(tcell.KeyLeft))
	after, _, _ := screen.GetCursor()
	if before-after != 2 {
		t.Fatalf("moving left over a wide character moved %d columns, want 2", before-after)
	}
}

// TestMixedWidthTextPlacesTheCaretCorrectly covers the realistic case: a filter
// that is part ASCII and part not.
func TestMixedWidthTextPlacesTheCaretCorrectly(t *testing.T) {
	browser, screen := openFilter(t, "ab日c")
	label, _, _, _ := browser.promptParts()
	x, _, _ := screen.GetCursor()
	// a, b, c are one column each and 日 is two.
	if want := displayWidth(label) + 5; x != want {
		t.Fatalf("caret column = %d, want %d", x, want)
	}
}

// TestSpaceAfterNumberReportsAColumn, not a character count. Everything before
// the caret on a row is ASCII today, so this is a guard against that changing
// silently rather than a live bug.
func TestSpaceAfterNumberReportsAColumn(t *testing.T) {
	if got, want := spaceAfterNumber("-> 12. anything"), 6; got != want {
		t.Errorf("spaceAfterNumber = %d, want %d", got, want)
	}
	// A wide character before the separator would make the two disagree.
	if got, want := spaceAfterNumber("日. text"), 3; got != want {
		t.Errorf("spaceAfterNumber with a wide prefix = %d, want %d columns", got, want)
	}
}

// TestViewerCaretOnAWideLine checks the row path as well as the prompt path.
func TestViewerCaretOnAWideLine(t *testing.T) {
	browser, screen := viewerBrowser(t, "日本語のテキスト\nsecond", runeKey('v'), runeKey('q'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	x, y, visible := screen.GetCursor()
	if !visible || y != firstListRow {
		t.Fatalf("caret at (%d,%d) visible %v", x, y, visible)
	}
	if want := browser.caretColumn(); x != want {
		t.Fatalf("caret column = %d, want %d", x, want)
	}
	// The row's own text must not overflow the window either.
	row := screenRows(t, screen)[firstListRow]
	width, _ := screen.Size()
	if displayWidth(row) > width {
		t.Fatalf("row occupies %d columns, window is %d", displayWidth(row), width)
	}
}
