package line

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/handoff"
)

// fakeConsole records everything the user would hear and replays scripted
// answers. Prompts are recorded alongside announcements, because a prompt is
// spoken too and its wording is part of the interface.
type fakeConsole struct {
	answers    []string
	transcript []string
	prompts    []string
}

func (c *fakeConsole) Say(text string) {
	c.transcript = append(c.transcript, strings.Split(text, "\n")...)
}

func (c *fakeConsole) ReadLine(prompt string) (string, error) {
	c.prompts = append(c.prompts, prompt)
	c.transcript = append(c.transcript, "PROMPT "+prompt)
	if len(c.answers) == 0 {
		return "", errors.New("the test ran out of scripted input")
	}
	answer := c.answers[0]
	c.answers = c.answers[1:]
	c.transcript = append(c.transcript, "TYPED "+answer)
	return answer, nil
}

func (c *fakeConsole) heard(t *testing.T, want string) {
	t.Helper()
	for _, line := range c.transcript {
		if line == want {
			return
		}
	}
	t.Fatalf("transcript does not contain %q\n%s", want, strings.Join(c.transcript, "\n"))
}

func (c *fakeConsole) neverHeard(t *testing.T, unwanted string) {
	t.Helper()
	for _, line := range c.transcript {
		if strings.Contains(line, unwanted) {
			t.Fatalf("transcript should not mention %q but said %q", unwanted, line)
		}
	}
}

// neverHeardAfter checks only what was announced after the last line
// containing marker. State changes such as a search are announced in place, so
// what matters is that the filtered listing excludes an entry, not that the
// entry was never mentioned earlier in the session.
func (c *fakeConsole) neverHeardAfter(t *testing.T, marker, unwanted string) {
	t.Helper()
	start := -1
	for index, line := range c.transcript {
		if strings.Contains(line, marker) {
			start = index
		}
	}
	if start < 0 {
		t.Fatalf("transcript never contained the marker %q\n%s", marker, strings.Join(c.transcript, "\n"))
	}
	for _, line := range c.transcript[start:] {
		if strings.Contains(line, unwanted) {
			t.Fatalf("after %q the transcript should not mention %q but said %q", marker, unwanted, line)
		}
	}
}

// fakeStore counts loads so a test can prove that browsing does not re-read
// the database, and records mutations.
type fakeStore struct {
	entries []model.Entry
	loads   int
	deleted []string
	created []string
	loadErr error
}

func (s *fakeStore) Load(context.Context) ([]model.Entry, error) {
	s.loads++
	if s.loadErr != nil {
		return nil, s.loadErr
	}
	return append([]model.Entry(nil), s.entries...), nil
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
	s.created = append(s.created, text)
	entry := model.Entry{ID: "new", Text: text, Name: name, SourceMachine: "test", LastUsedUnixMs: fixedNow.UnixMilli()}
	s.entries = append([]model.Entry{entry}, s.entries...)
	return entry, nil
}

var fixedNow = time.Date(2026, 8, 6, 12, 0, 0, 0, time.UTC)

func minutesAgo(count int) int64 {
	return fixedNow.Add(-time.Duration(count) * time.Minute).UnixMilli()
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

func newBrowser(store *fakeStore, console *fakeConsole, stdout *strings.Builder, pageSize int) *Browser {
	return &Browser{
		Store: store, Console: console, Stdout: stdout,
		PageSize: pageSize, Now: func() time.Time { return fixedNow },
	}
}

func TestMenuLoadsOnceForManyCommands(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"0", "1", "2", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	// Viewing three entries must not cost three downloads. This is the
	// regression guard for the per-command network stall.
	if store.loads != 1 {
		t.Fatalf("expected exactly 1 load for a browse-only session, got %d", store.loads)
	}
	if stdout.String() != "" {
		t.Fatalf("browsing must not write to stdout, got %q", stdout.String())
	}
}

func TestRefreshReloadsAndSaysSo(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"r", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if store.loads != 2 {
		t.Fatalf("refresh should reload exactly once more, got %d loads", store.loads)
	}
	console.heard(t, "Reloaded from the server.")
}

func TestEveryRowIsACompleteSentence(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{{
		ID: "a", Text: "kubectl get pods", Name: "pods", Group: "ops",
		SourceMachine: "workstation", Pinned: true, LastUsedUnixMs: minutesAgo(5),
	}}}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "0. pods; pinned; group ops; from workstation; used 5m ago")
}

func TestOutputWritesOnlyClipTextToStdout(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"o 1"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if stdout.String() != "clip number 1" {
		t.Fatalf("stdout must hold the clip and nothing else, got %q", stdout.String())
	}
}

func TestViewingAnEntryStaysOnTheTerminal(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"1", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "clip number 1")
	if stdout.String() != "" {
		t.Fatalf("viewing must not reach stdout, got %q", stdout.String())
	}
}

func TestSearchFiltersAndReportsCounts(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{
		{ID: "a", Text: "aws s3 ls", LastUsedUnixMs: minutesAgo(1)},
		{ID: "b", Text: "kubectl get pods", LastUsedUnixMs: minutesAgo(2)},
		{ID: "c", Text: "aws ec2 describe-instances", LastUsedUnixMs: minutesAgo(3)},
	}}
	console := &fakeConsole{answers: []string{"/aws", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, `Search "aws": 2 matches of 3 entries.`)
	console.neverHeardAfter(t, `Search "aws"`, "kubectl")
}

func TestSearchIsClearedBySlashAlone(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"/number 1", "/", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Search cleared.")
	console.heard(t, "Clipman history: 3 entries.")
}

func TestSearchTextMayContainSpaces(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{
		{ID: "a", Text: "deploy to staging", LastUsedUnixMs: minutesAgo(1)},
		{ID: "b", Text: "deploy to production", LastUsedUnixMs: minutesAgo(2)},
	}}
	console := &fakeConsole{answers: []string{"/to staging", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, `Search "to staging": 1 match of 2 entries.`)
}

func TestPagingKeepsIndicesAbsolute(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(5)}
	console := &fakeConsole{answers: []string{"n", "o 3"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 2).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Page 2 of 3, entries 2 to 3.")
	// Index 3 must still mean the fourth entry of the filtered view while the
	// second page is displayed, so a number heard once stays usable.
	if stdout.String() != "clip number 3" {
		t.Fatalf("paged index resolved to %q", stdout.String())
	}
}

func TestPagingStopsAtTheEnds(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"p", "n", "n", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 2).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "This is the first page.")
	console.heard(t, "This is the last page.")
}

func TestSinglePageSaysSoRatherThanFailingSilently(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"n", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "There is only one page.")
}

func TestDeleteConfirmsAndDropsTheEntryLocally(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"d 1", "yes", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(store.deleted) != 1 || store.deleted[0] != "id01" {
		t.Fatalf("expected id01 deleted, got %v", store.deleted)
	}
	console.heard(t, "Deleted clip number 1.")
	console.heard(t, "Clipman history: 2 entries.")
	// The delete already uploaded, so the list must not be downloaded again.
	if store.loads != 1 {
		t.Fatalf("delete should not trigger a reload, got %d loads", store.loads)
	}
}

func TestDeleteCancelsOnAnythingButYes(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"d 0", "n", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(store.deleted) != 0 {
		t.Fatalf("nothing should have been deleted, got %v", store.deleted)
	}
	console.heard(t, "Deletion cancelled.")
}

func TestAddCollectsMultilineTextAndName(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"a", "first line", "second line", ".", "my note", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(store.created) != 1 || store.created[0] != "first line\nsecond line" {
		t.Fatalf("multiline text was not assembled, got %q", store.created)
	}
	console.heard(t, "Added my note.")
}

func TestAddEscapesALoneperiodLine(t *testing.T) {
	store := &fakeStore{entries: nil}
	console := &fakeConsole{answers: []string{"a", "before", "..", "after", ".", "", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if store.created[0] != "before\n.\nafter" {
		t.Fatalf("dot escaping failed, got %q", store.created[0])
	}
}

func TestAddCanBeCancelled(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"a", "typed something", "!cancel", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(store.created) != 0 {
		t.Fatalf("cancelled input must not be stored, got %v", store.created)
	}
	console.heard(t, "New clip abandoned.")
}

func TestAddRefusesEmptyText(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"a", "   ", ".", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(store.created) != 0 {
		t.Fatalf("blank text must not be stored, got %v", store.created)
	}
	console.heard(t, "Nothing was typed, so no clip was added.")
}

func TestUnknownCommandExplainsItself(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"zz", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, `"zz" is not a command or an entry number. Type ? for the list of commands.`)
}

func TestOutOfRangeIndexNamesTheValidRange(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"9", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Entry 9 does not exist. Numbers run from 0 to 2.")
}

func TestHelpListsEveryCommand(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"?", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	for _, command := range []string{"o NUMBER", "d NUMBER", "/TEXT", "n ", "p ", "a ", "r ", "q "} {
		found := false
		for _, line := range console.transcript {
			if strings.Contains(line, command) {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("help does not mention %q", command)
		}
	}
}

func TestEmptyHistoryStillOffersCommands(t *testing.T) {
	store := &fakeStore{entries: nil}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Clipman history: 0 entries.")
}

func TestTemplateIsResolvedOnOutput(t *testing.T) {
	store := &fakeStore{entries: []model.Entry{{
		ID: "t", Text: "{{year_full}}", IsTemplate: true, LastUsedUnixMs: minutesAgo(1),
	}}}
	console := &fakeConsole{answers: []string{"o 0"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if stdout.String() != "2026" {
		t.Fatalf("template was not resolved, got %q", stdout.String())
	}
}

func TestPickWritesTheChosenClipAndNothingElse(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"2"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Pick(context.Background()); err != nil {
		t.Fatalf("Pick: %v", err)
	}
	if stdout.String() != "clip number 2" {
		t.Fatalf("pick wrote %q", stdout.String())
	}
}

func TestPickCancels(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	err := newBrowser(store, console, &stdout, 20).Pick(context.Background())
	if !errors.Is(err, ErrCancelled) {
		t.Fatalf("expected ErrCancelled, got %v", err)
	}
	if stdout.String() != "" {
		t.Fatalf("a cancelled pick must write nothing, got %q", stdout.String())
	}
}

func TestPickReportsAnEmptyView(t *testing.T) {
	store := &fakeStore{entries: nil}
	console := &fakeConsole{}
	var stdout strings.Builder
	err := newBrowser(store, console, &stdout, 20).Pick(context.Background())
	if !errors.Is(err, ErrNoEntries) {
		t.Fatalf("expected ErrNoEntries, got %v", err)
	}
}

func TestPickRetriesAfterAnInvalidChoice(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"7", "1"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Pick(context.Background()); err != nil {
		t.Fatalf("Pick: %v", err)
	}
	console.heard(t, "Entry 7 does not exist. Numbers run from 0 to 1.")
	if stdout.String() != "clip number 1" {
		t.Fatalf("pick wrote %q", stdout.String())
	}
}

func TestLoadFailureIsReturned(t *testing.T) {
	store := &fakeStore{loadErr: errors.New("server is unavailable")}
	console := &fakeConsole{}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err == nil {
		t.Fatal("expected the load failure to surface")
	}
}

func TestAllEntriesModeDisablesPaging(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(50)}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, -1).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "49. clip number 49; from workstation; used 50m ago")
	console.neverHeard(t, "Page ")
}

// TestTheInterfaceNamesItselfOnEntry is the regression guard for the bug that
// cost a debugging session: two interchangeable interfaces ship, and this one
// announced itself only as "Clipman history browser", so a user had no reason
// to suspect the other existed. The greeting has to name which one is running.
func TestTheInterfaceNamesItselfOnEntry(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Clipman line interface. Type ? for commands.")
}

// TestHelpNamesTheOtherInterface checks the escape hatch is reachable. Knowing
// you are in "the line interface" is only useful if something tells you what
// the other one is and how to reach it.
func TestHelpNamesTheOtherInterface(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(2)}
	console := &fakeConsole{answers: []string{"?", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	transcript := strings.Join(console.transcript, "\n")
	for _, want := range []string{"full-screen interface", "u  "} {
		if !strings.Contains(transcript, want) {
			t.Fatalf("help must mention %q so the other interface is reachable\n%s", want, transcript)
		}
	}
}

// TestSwitchingAsksFirst covers the confirmation. tcell clears whatever this
// interface printed the moment it initialises, so a message announced on the way
// out cannot be relied on to be heard; a question that must be answered is the
// one thing certain to have been read.
func TestSwitchingAsksFirst(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"u", "no", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("declining a switch must not end the session: %v", err)
	}
	console.heard(t, "Staying in the line interface.")
	joined := strings.Join(console.prompts, "\n")
	for _, want := range []string{"arrow keys", "becomes your default"} {
		if !strings.Contains(joined, want) {
			t.Errorf("the question must say %q so the consequence is known before it happens\n%s", want, joined)
		}
	}
}

// TestConfirmedSwitchCarriesThePlace checks the search survives. Both interfaces
// apply the identical predicate, so losing it would be a choice rather than a
// limitation.
func TestConfirmedSwitchCarriesThePlace(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(6)}
	console := &fakeConsole{answers: []string{"/clip number 4", "u", "yes"}}
	var stdout strings.Builder
	browser := newBrowser(store, console, &stdout, 20)
	browser.Kind = operation.Templates

	err := browser.Run(context.Background())

	var request *handoff.Request
	if !errors.As(err, &request) {
		t.Fatalf("a confirmed switch must report a handoff, got %v", err)
	}
	if request.Filter != "clip number 4" {
		t.Errorf("the search must travel: got %q", request.Filter)
	}
	if request.Kind != operation.Templates {
		t.Errorf("the kind must travel: got %v", request.Kind)
	}
}

// TestArrivalSaysWhereYouWere is this interface's answer to the caret. The
// full-screen interface says where you are by landing the cursor on the row;
// this one has no cursor to land, so it has to say it in words or the switch
// reads as twenty sentences with no indication of your place.
func TestArrivalSaysWhereYouWere(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(6)}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	browser := newBrowser(store, console, &stdout, 20)
	browser.Arrival = &handoff.Request{Selected: 3}
	if err := browser.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "You were on entry 3.")
}

// TestArrivalRestoresTheSearch checks the filter is applied before the first
// announcement, so the list heard on arrival is the list left behind.
func TestArrivalRestoresTheSearch(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(6)}
	console := &fakeConsole{answers: []string{"q"}}
	var stdout strings.Builder
	browser := newBrowser(store, console, &stdout, 20)
	browser.Arrival = &handoff.Request{Filter: "clip number 2"}
	if err := browser.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, `Search "clip number 2": 1 match of 6 entries.`)
}

// TestPickRefusesToSwitch guards the trap from the other side.
func TestPickRefusesToSwitch(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	console := &fakeConsole{answers: []string{"u", "q"}}
	var stdout strings.Builder
	err := newBrowser(store, console, &stdout, 20).Pick(context.Background())
	if !errors.Is(err, ErrCancelled) {
		t.Fatalf("u must not switch out of pick, got %v", err)
	}
	console.heard(t, "pick cannot change interface. Use menu to switch.")
}
