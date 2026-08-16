package tui

import (
	"context"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gdamore/tcell/v2"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipexec"
)

func openRun(t *testing.T, clip string) (*Browser, tcell.SimulationScreen) {
	t.Helper()
	entries := sampleEntries(3)
	entries[0].Text = clip
	store := &fakeStore{entries: entries}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('x'))
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	return browser, screen
}

// waitForRun turns the event loop until the command finishes, which is how the
// interface stays answerable while a program runs.
func waitForRun(t *testing.T, browser *Browser, screen tcell.SimulationScreen) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for browser.mode == modeRunning {
		if time.Now().After(deadline) {
			t.Fatal("the command never reported back")
		}
		event := screen.PollEvent()
		if event == nil {
			t.Fatal("the screen stopped delivering events")
		}
		if _, err := browser.handle(context.Background(), event); err != nil {
			t.Fatalf("handle: %v", err)
		}
		browser.draw()
	}
}

// TestRunPromptExplainsTheRulesInTheHeading. Every other program that takes a
// command line hands it to a shell, and this one does not. Saying so once where
// it is read when the screen changes costs one announcement; saying it after
// each rejected attempt costs one per mistake.
func TestRunPromptExplainsTheRulesInTheHeading(t *testing.T) {
	browser, screen := openRun(t, "some clip")
	if browser.mode != modeRunCommand {
		t.Fatalf("x must open the run prompt, mode = %v", browser.mode)
	}
	heading := screenRows(t, screen)[headingRow]
	for _, want := range []string{"No shell", clipexec.Placeholder, "piped in"} {
		if !strings.Contains(heading, want) {
			t.Errorf("heading = %q, want it to mention %q", heading, want)
		}
	}
	label, _, _, asking := browser.promptParts()
	if !asking || !strings.Contains(label, "entry 0") {
		t.Fatalf("prompt = %q, want it to name the entry", label)
	}
}

// TestRunRefusesAShellOperatorAndKeepsTheLine. The refusal is the feature: a
// pipe handed to sort as a literal argument would do something the user did not
// ask for and would look like Clipman being broken.
func TestRunRefusesAShellOperatorAndKeepsTheLine(t *testing.T) {
	browser, screen := openRun(t, "some clip")
	typeInto(t, browser, "sort | head")
	feedKeys(t, browser, key(tcell.KeyEnter))

	if browser.mode != modeRunCommand {
		t.Fatalf("mode = %v, want to stay in the prompt so it can be corrected", browser.mode)
	}
	row := screenRows(t, screen)[statusRow]
	if !strings.Contains(row, "No shell") || !strings.Contains(row, "|") {
		t.Fatalf("refusal = %q, want it to name the operator and why", row)
	}
	// The typed line survives, or correcting it would mean retyping all of it.
	if browser.prompt.String() != "sort | head" {
		t.Fatalf("prompt = %q, want the typed line kept", browser.prompt.String())
	}
	// The next keystroke puts the question back.
	feedKeys(t, browser, key(tcell.KeyBackspace))
	label, _, _, _ := browser.promptParts()
	if !strings.Contains(label, "Run on entry") {
		t.Fatalf("label = %q, want the question back after the refusal was heard", label)
	}
}

// TestRunPipesTheClipAndShowsOutput is the end-to-end path with no placeholder.
func TestRunPipesTheClipAndShowsOutput(t *testing.T) {
	t.Setenv("CLIPMAN_TUI_HELPER", "1")
	t.Setenv("CLIPMAN_TUI_HELPER_MODE", "copy-stdin")
	browser, screen := openRun(t, "piped clip text")
	typeInto(t, browser, os.Args[0]+" -test.run=TestHelperProcess --")
	feedKeys(t, browser, key(tcell.KeyEnter))
	waitForRun(t, browser, screen)

	if browser.mode != modeView {
		t.Fatalf("mode = %v, want the output in the viewer", browser.mode)
	}
	if !strings.Contains(browser.viewText, "piped clip text") {
		t.Fatalf("output document = %q, want the piped clip echoed back", browser.viewText)
	}
	if !strings.Contains(browser.viewText, "finished successfully") {
		t.Errorf("output document = %q, want the outcome stated", browser.viewText)
	}
	// It is a document, not a clip: Enter must not emit it.
	if browser.viewIsClip {
		t.Error("command output must not be treated as a clip")
	}
}

// TestRunSubstitutesTheClipAsOneArgument is the security property, checked
// through the interface rather than only in the package below it.
func TestRunSubstitutesTheClipAsOneArgument(t *testing.T) {
	t.Setenv("CLIPMAN_TUI_HELPER", "1")
	t.Setenv("CLIPMAN_TUI_HELPER_MODE", "echo-args")
	browser, screen := openRun(t, "; rm -rf ~")
	typeInto(t, browser, os.Args[0]+" -test.run=TestHelperProcess -- "+clipexec.Placeholder)
	feedKeys(t, browser, key(tcell.KeyEnter))
	waitForRun(t, browser, screen)

	if !strings.Contains(browser.viewText, "; rm -rf ~") {
		t.Fatalf("output = %q, want the clip echoed back as one argument", browser.viewText)
	}
	// One argument means one line from the helper, so the dangerous text never
	// became a second argument or a program name.
	if strings.Count(browser.viewText, "rm -rf") != 1 {
		t.Errorf("output = %q, want the clip to appear exactly once", browser.viewText)
	}
}

// TestSilentSuccessStillSaysSomething. A command that prints nothing must not
// read as never having run.
func TestSilentSuccessStillSaysSomething(t *testing.T) {
	t.Setenv("CLIPMAN_TUI_HELPER", "1")
	t.Setenv("CLIPMAN_TUI_HELPER_MODE", "silent")
	browser, screen := openRun(t, "clip")
	typeInto(t, browser, os.Args[0]+" -test.run=TestHelperProcess --")
	feedKeys(t, browser, key(tcell.KeyEnter))
	waitForRun(t, browser, screen)

	if !strings.Contains(browser.viewText, "None.") {
		t.Fatalf("output document = %q, want it to say there was no output", browser.viewText)
	}
}

// TestFailureReportsTheExitStatusAndErrors rather than looking like success.
func TestFailureReportsTheExitStatusAndErrors(t *testing.T) {
	t.Setenv("CLIPMAN_TUI_HELPER", "1")
	t.Setenv("CLIPMAN_TUI_HELPER_MODE", "fail")
	browser, screen := openRun(t, "clip")
	typeInto(t, browser, os.Args[0]+" -test.run=TestHelperProcess --")
	feedKeys(t, browser, key(tcell.KeyEnter))
	waitForRun(t, browser, screen)

	for _, want := range []string{"exit status 3", "Errors", "something went wrong"} {
		if !strings.Contains(browser.viewText, want) {
			t.Errorf("output document = %q, want it to mention %q", browser.viewText, want)
		}
	}
}

// TestMissingProgramIsNamedPlainly, not with Go's PATH message.
func TestMissingProgramIsNamedPlainly(t *testing.T) {
	browser, screen := openRun(t, "clip")
	typeInto(t, browser, "clipman-no-such-program-exists")
	feedKeys(t, browser, key(tcell.KeyEnter))
	waitForRun(t, browser, screen)

	if browser.mode != modeNotice {
		t.Fatalf("mode = %v, want a notice", browser.mode)
	}
	row := screenRows(t, screen)[statusRow]
	if !strings.Contains(row, "was not found on the PATH") {
		t.Fatalf("notice = %q, want a plain sentence", row)
	}
	if strings.Contains(row, "executable file not found") {
		t.Errorf("notice = %q, want Go's message kept out of it", row)
	}
}

// TestEscapeAbandonsTheRunPrompt without running anything.
func TestEscapeAbandonsTheRunPrompt(t *testing.T) {
	browser, _ := openRun(t, "clip")
	typeInto(t, browser, "somecommand")
	feedKeys(t, browser, key(tcell.KeyEscape))
	if browser.mode != modeList {
		t.Fatalf("mode = %v, want the list back", browser.mode)
	}
}

// TestRunningStateHoldsTheCaretOnItsMessage, so "this is still going" is heard
// rather than written past.
func TestRunningStateHoldsTheCaret(t *testing.T) {
	t.Setenv("CLIPMAN_TUI_HELPER", "1")
	t.Setenv("CLIPMAN_TUI_HELPER_MODE", "sleep")
	browser, screen := openRun(t, "clip")
	typeInto(t, browser, os.Args[0]+" -test.run=TestHelperProcess --")
	feedKeys(t, browser, key(tcell.KeyEnter))

	if browser.mode != modeRunning {
		t.Fatalf("mode = %v, want the running state", browser.mode)
	}
	if _, y, _ := screen.GetCursor(); y != statusRow {
		t.Fatalf("caret at row %d, want it on the running message at %d", y, statusRow)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "Press Escape to stop it") {
		t.Fatalf("status = %q, want the way out stated", row)
	}

	// Escape is the only way out of a program that will not finish.
	feedKeys(t, browser, key(tcell.KeyEscape))
	waitForRun(t, browser, screen)
	if !strings.Contains(browser.viewText, "stopped before it finished") {
		t.Fatalf("output document = %q, want it to say the command was stopped", browser.viewText)
	}
}

// TestPickRefusesToRunCommands. pick is the form that appears inside pipelines
// and scripts, so an arbitrary-program affordance reachable from one is a wider
// surface than the same key in an interactive menu.
func TestPickRefusesToRunCommands(t *testing.T) {
	store := &fakeStore{entries: sampleEntries(3)}
	var stdout strings.Builder
	browser, screen := newTestBrowser(store, &stdout, runeKey('x'))
	browser.PickOnly = true
	if err := browser.loopUntil(context.Background(), 1); err != nil {
		t.Fatalf("loopUntil: %v", err)
	}
	if browser.mode != modeList {
		t.Fatalf("pick must not open the run prompt, mode = %v", browser.mode)
	}
	if row := screenRows(t, screen)[statusRow]; !strings.Contains(row, "pick cannot run commands") {
		t.Fatalf("status = %q, want pick to say why it refused", row)
	}
}

// TestHelperProcess is not a test. It is the program the run tests execute, so
// they need no assumption about what exists on the machine.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("CLIPMAN_TUI_HELPER") != "1" {
		return
	}
	defer os.Exit(0)
	switch os.Getenv("CLIPMAN_TUI_HELPER_MODE") {
	case "echo-args":
		for _, arg := range os.Args[helperArgsStart():] {
			os.Stdout.WriteString(arg + "\n")
		}
	case "copy-stdin":
		io.Copy(os.Stdout, os.Stdin)
	case "fail":
		os.Stderr.WriteString("something went wrong\n")
		os.Exit(3)
	case "sleep":
		time.Sleep(30 * time.Second)
	case "silent":
	}
}

func helperArgsStart() int {
	for index, arg := range os.Args {
		if arg == "--" {
			return index + 1
		}
	}
	return len(os.Args)
}
