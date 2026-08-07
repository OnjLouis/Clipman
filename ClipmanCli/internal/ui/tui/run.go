package tui

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/gdamore/tcell/v2"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipexec"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
)

// runFinished and runProgress are posted from the goroutine running a command,
// so the event loop keeps turning while it works.
//
// Running a command inline would block PollEvent, which means no redraw, no
// Escape, and no way out of a program that never returns. Posting events instead
// keeps the interface answering keys throughout.
type runFinished struct {
	at     time.Time
	result clipexec.Result
	err    error
}

func (e *runFinished) When() time.Time { return e.at }

type runProgress struct {
	at      time.Time
	seconds int
}

func (e *runProgress) When() time.Time { return e.at }

// runTickInterval is how often a still-running command says so. The number in
// the message changes each time, which is what makes the line differ and so be
// resent to the terminal; an identical line would be redrawn into identical
// cells and never spoken again.
const runTickInterval = 10 * time.Second

// beginRun asks for a command to run against the selected clip.
func (b *Browser) beginRun() {
	entry, ok := b.target()
	if !ok {
		b.setStatus("There is nothing to run a command on.")
		return
	}
	b.runLabel = fmt.Sprintf("Run on entry %d, %s: ", b.selected, output.Preview(entry))
	b.prompt.set("")
	b.returnMode = b.mode
	b.mode = modeRunCommand
}

// runHeading explains the rules once, above the question, for as long as the
// question is open.
//
// It lives in the heading rather than in a message after a mistake: the heading
// is read when the screen changes and is not re-read while typing, so it costs
// one announcement rather than one per attempt. The rules are surprising enough
// to be worth stating, because every other program that takes a command line
// runs it through a shell and this one does not.
func (b *Browser) runHeading() string {
	return "One program, run directly. No shell. " + clipexec.Placeholder +
		" stands for the clip text; without it the clip is piped in."
}

func (b *Browser) handleRunKey(event *tcell.EventKey) {
	switch event.Key() {
	case tcell.KeyEscape:
		b.prompt.clear()
		b.mode = b.returnMode
		b.setStatus("Nothing was run. %s", b.heading())
		return
	case tcell.KeyEnter:
		b.startRun()
		return
	}
	b.editPrompt(event)
}

// startRun turns the typed line into a program and starts it.
//
// A refusal keeps the typed text, because the fix is usually one character and
// retyping the whole line to change it would be the punishment this interface
// spent an item removing.
func (b *Browser) startRun() {
	entry, ok := b.target()
	if !ok {
		b.notice("There is nothing to run a command on.")
		return
	}
	plan, err := clipexec.Build(b.prompt.String(), b.text(entry))
	if err != nil {
		var refusal *clipexec.RefusalError
		if errors.As(err, &refusal) {
			b.setStatus("%s", refusal.Message)
		} else {
			b.setStatus("%v", err)
		}
		// Stay in the prompt with the text intact so it can be corrected.
		b.mode = modeRunCommand
		b.runRefused = true
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	b.runCancel = cancel
	// The base name, not the whole path. A message is one row wide, and a
	// program invoked by absolute path would push "Press Escape to stop it" past
	// the edge — hiding the only way out of a command that will not finish.
	b.runProgram = filepath.Base(plan.Args[0])
	b.runStarted = b.now()
	b.runRefused = false
	b.mode = modeRunning
	b.setStatus("Running %s. Press Escape to stop it.", b.runProgram)

	screen := b.Screen
	go func() {
		result, runErr := clipexec.Run(ctx, plan)
		cancel()
		screen.PostEvent(&runFinished{at: time.Now(), result: result, err: runErr})
	}()
	go func() {
		ticker := time.NewTicker(runTickInterval)
		defer ticker.Stop()
		seconds := 0
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				seconds += int(runTickInterval / time.Second)
				screen.PostEvent(&runProgress{at: time.Now(), seconds: seconds})
			}
		}
	}()
}

// handleRunningKey is the only way out of a command that will not finish.
func (b *Browser) handleRunningKey(event *tcell.EventKey) {
	if event.Key() == tcell.KeyEscape || event.Key() == tcell.KeyCtrlC {
		if b.runCancel != nil {
			b.runCancel()
		}
		b.setStatus("Stopping %s.", b.runProgram)
	}
}

func (b *Browser) handleRunProgress(event *runProgress) {
	if b.mode != modeRunning {
		return
	}
	b.setStatus("Still running %s, %d seconds. Press Escape to stop it.", b.runProgram, event.seconds)
}

// handleRunFinished presents what the command did.
func (b *Browser) handleRunFinished(event *runFinished) {
	if b.runCancel != nil {
		b.runCancel()
		b.runCancel = nil
	}
	if event.err != nil {
		if errors.Is(event.err, clipexec.ErrProgramNotFound) {
			b.notice("%s was not found on the PATH. Press any key to continue.", b.runProgram)
			return
		}
		b.notice("%s could not be run: %v. Press any key to continue.", b.runProgram, event.err)
		return
	}
	b.openRunResult(event.result)
}

// openRunResult shows the output in the viewer.
//
// Captured and shown here rather than written to the terminal. The screen is on
// tcell's alternate buffer, so anything a command printed would be wiped by the
// next repaint: one unrepeatable pass at output, produced at whatever rate the
// program produced it, with no way to scroll back. In the viewer it is
// navigable and re-readable.
//
// A silent success still says something. "Exit status 0, nothing printed" is a
// result; showing nothing would read as the command never having run.
func (b *Browser) openRunResult(result clipexec.Result) {
	name := filepath.Base(result.Program)
	var body strings.Builder
	switch {
	case result.Stopped:
		body.WriteString(fmt.Sprintf("%s was stopped before it finished.", name))
	case result.Succeeded():
		body.WriteString(fmt.Sprintf("%s finished successfully.", name))
	default:
		body.WriteString(fmt.Sprintf("%s failed with exit status %d.", name, result.ExitCode))
	}
	if result.Truncated {
		body.WriteString("\nOutput was longer than 1 MB and was cut off.")
	}

	body.WriteString("\n\nOutput\n")
	if strings.TrimSpace(result.Stdout) == "" {
		body.WriteString("None.\n")
	} else {
		body.WriteString(strings.TrimRight(result.Stdout, "\n") + "\n")
	}
	if strings.TrimSpace(result.Stderr) != "" {
		body.WriteString("\nErrors\n" + strings.TrimRight(result.Stderr, "\n") + "\n")
	}

	b.viewText = strings.TrimRight(body.String(), "\n")
	b.viewIsClip = false
	b.viewTitle = name
	b.viewRows = nil
	b.viewWidth = 0
	b.viewCursor = 0
	b.viewTop = 0
	b.mode = modeView
	b.setStatus("Command output. Press q to close.")
}
