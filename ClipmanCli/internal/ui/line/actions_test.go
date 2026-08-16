package line

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestViewingPagesRatherThanAnnouncingEverything is the defect this fixes. A
// clip used to be read out in one Console.Say: a five-thousand-line clip was a
// single unstoppable announcement with no way to slow down, go back, or leave.
func TestViewingPagesRatherThanAnnouncingEverything(t *testing.T) {
	long := make([]string, 60)
	for i := range long {
		long[i] = "line of clip text"
	}
	entries := sampleEntries(1)
	entries[0].Text = strings.Join(long, "\n")
	store := &fakeStore{entries: entries}
	console := &fakeConsole{answers: []string{"0", "q", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Page 1 of 3, lines 1 to 20.")
	// Only the first page is read before the user is asked what to do next.
	// Counted by the numbered-line form, since the list row and the entry
	// preview quote the same text.
	numbered := 0
	for _, spoken := range console.transcript {
		if regexp.MustCompile(`^\d+\. line of clip text$`).MatchString(spoken) {
			numbered++
		}
	}
	if numbered != 20 {
		t.Fatalf("read %d clip lines, want exactly one page of 20, transcript:\n%s",
			numbered, strings.Join(console.transcript, "\n"))
	}
}

// TestViewingNumbersItsLines so position is heard as part of the line rather
// than announced separately.
func TestViewingNumbersItsLines(t *testing.T) {
	entries := sampleEntries(1)
	entries[0].Text = "alpha\nbravo"
	store := &fakeStore{entries: entries}
	console := &fakeConsole{answers: []string{"0", "q", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "1. alpha")
	console.heard(t, "2. bravo")
}

func TestViewingPagesForwardAndBack(t *testing.T) {
	long := make([]string, 12)
	for i := range long {
		long[i] = "row"
	}
	entries := sampleEntries(1)
	entries[0].Text = strings.Join(long, "\n")
	store := &fakeStore{entries: entries}
	console := &fakeConsole{answers: []string{"0", "n", "p", "q", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 5).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "Page 2 of 3, lines 6 to 10.")
	console.heard(t, "Page 1 of 3, lines 1 to 5.")
}

// TestSaveFromTheLineInterface writes the clip verbatim.
func TestSaveFromTheLineInterface(t *testing.T) {
	entries := sampleEntries(1)
	entries[0].Text = "one\ntwo"
	store := &fakeStore{entries: entries}
	path := filepath.Join(t.TempDir(), "clip.txt")
	console := &fakeConsole{answers: []string{"w 0", path, "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(data) != "one\ntwo" {
		t.Fatalf("wrote %q, want the clip byte for byte", data)
	}
	console.heard(t, "Saved 2 lines to "+path+".")
}

// TestSaveConfirmsBeforeOverwriting, the one branch that destroys something the
// user did not name.
func TestSaveConfirmsBeforeOverwriting(t *testing.T) {
	path := filepath.Join(t.TempDir(), "taken.txt")
	if err := os.WriteFile(path, []byte("do not lose me"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"w 0", path, "no", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "do not lose me" {
		t.Fatalf("file = %q; declining must not overwrite", data)
	}
	console.heard(t, "Not saved.")
}

// TestRunRefusesAShellOperator. Handing a pipe to sort as a literal argument
// would do something the user did not ask for.
func TestRunRefusesAShellOperator(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"x 0", "sort | head", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	transcript := strings.Join(console.transcript, "\n")
	if !strings.Contains(transcript, "No shell is used") {
		t.Fatalf("transcript should refuse the operator and say why:\n%s", transcript)
	}
}

// TestRunExplainsTheRulesBeforeAsking, rather than after each mistake.
func TestRunExplainsTheRulesBeforeAsking(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"x 0", "", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	transcript := strings.Join(console.transcript, "\n")
	for _, want := range []string{"No shell", "@clip", "piped in"} {
		if !strings.Contains(transcript, want) {
			t.Errorf("transcript should mention %q:\n%s", want, transcript)
		}
	}
	console.heard(t, "Nothing was run.")
}

// TestMissingProgramIsNamedPlainly keeps Go's PATH message out of a sentence
// that is read aloud.
func TestMissingProgramIsNamedPlainly(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(1)}
	console := &fakeConsole{answers: []string{"x 0", "clipman-no-such-program-exists", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	transcript := strings.Join(console.transcript, "\n")
	if !strings.Contains(transcript, "clipman-no-such-program-exists") {
		t.Fatalf("the program must be named:\n%s", transcript)
	}
	if strings.Contains(transcript, "executable file not found") {
		t.Errorf("Go's message should be kept out of it:\n%s", transcript)
	}
}

// TestViewingSanitisesControlCharacters so a clip containing them is legible
// rather than moving the terminal's cursor around mid-announcement.
func TestViewingSanitisesControlCharacters(t *testing.T) {
	entries := sampleEntries(1)
	entries[0].Text = "before\x00after"
	store := &fakeStore{entries: entries}
	console := &fakeConsole{answers: []string{"0", "q", "q"}}
	var stdout strings.Builder
	if err := newBrowser(store, console, &stdout, 20).Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	console.heard(t, "1. before^@after")
}

// TestPickReadsButDoesNotWriteOrRun. pick has exactly one output and its caller
// chose it, but confirming which clip is about to go down the pipe is what it
// most needs.
func TestPickReadsButDoesNotWriteOrRun(t *testing.T) {
	entries := sampleEntries(2)
	entries[1].Text = "the clip to check"
	store := &fakeStore{entries: entries}
	console := &fakeConsole{answers: []string{"v 1", "q", "w 1", "x 1", "q"}}
	var stdout strings.Builder
	err := newBrowser(store, console, &stdout, 20).Pick(context.Background())
	if !errors.Is(err, ErrCancelled) {
		t.Fatalf("Pick: %v", err)
	}
	console.heard(t, "1. the clip to check")
	console.heard(t, "pick cannot write files. Use menu to save a clip to a file.")
	console.heard(t, "pick cannot run commands. Use menu to run a command on a clip.")
	if stdout.String() != "" {
		t.Fatalf("reading in pick must not emit, got %q", stdout.String())
	}
}
