package line

import (
	"context"
	"fmt"
	"strings"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipexec"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipfile"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
)

// viewEntry reads a clip out a page at a time.
//
// Viewing used to be one Console.Say of the whole text. For a two-line clip that
// is right; for a five-thousand-line one it is a single unstoppable
// announcement with no way to slow down, go back, or leave — the listening
// equivalent of a wall of text with no scrollbar.
//
// Paging here follows the same shape as the list: numbered lines, a page at a
// time, and a prompt that names what can be done next.
func (b *Browser) viewEntry(ctx context.Context, entry model.Entry) error {
	lines := output.PlainLines(b.text(entry))
	page := 0
	for {
		size := b.pageSize()
		if size < 0 {
			size = len(lines)
		}
		if size < 1 {
			size = 1
		}
		pages := (len(lines) + size - 1) / size
		if pages < 1 {
			pages = 1
		}
		if page >= pages {
			page = pages - 1
		}
		if page < 0 {
			page = 0
		}

		start := page * size
		end := start + size
		if end > len(lines) {
			end = len(lines)
		}

		b.Console.Say(fmt.Sprintf("%s: %s.", output.Preview(entry), output.Count(len(lines), "line", "lines")))
		if pages > 1 {
			b.Console.Say(fmt.Sprintf("Page %d of %d, lines %d to %d.", page+1, pages, start+1, end))
		}
		for index := start; index < end; index++ {
			// Numbered for the same reason list rows are: the number is the
			// first thing heard, so knowing where you are costs no extra words.
			b.Console.Say(fmt.Sprintf("%d. %s", index+1, lines[index]))
		}

		answer, err := b.Console.ReadLine("View (n next, p previous, w save, x run, q close): ")
		if err != nil {
			return err
		}
		switch strings.ToLower(strings.TrimSpace(answer)) {
		case "", "q", "quit", "close":
			return nil
		case "n", "next":
			if page+1 >= pages {
				b.Console.Say("This is the last page.")
				continue
			}
			page++
		case "p", "prev", "previous":
			if page == 0 {
				b.Console.Say("This is the first page.")
				continue
			}
			page--
		case "w", "save":
			if err := b.saveEntry(entry); err != nil {
				return err
			}
		case "x", "run":
			if err := b.runOnEntry(ctx, entry); err != nil {
				return err
			}
		default:
			b.Console.Say("Type n, p, w, x, or q.")
		}
	}
}

// saveEntry writes a clip to a file the user names.
func (b *Browser) saveEntry(entry model.Entry) error {
	typed, err := b.Console.ReadLine(fmt.Sprintf("Save %s to file: ", output.Preview(entry)))
	if err != nil {
		return err
	}
	if strings.TrimSpace(typed) == "" {
		b.Console.Say("Not saved.")
		return nil
	}
	path, resolveErr := clipfile.Resolve(typed)
	if resolveErr != nil {
		b.Console.Say(resolveErr.Error())
		return nil
	}
	if clipfile.IsDirectory(path) {
		b.Console.Say(fmt.Sprintf("%s is a directory, not a file.", path))
		return nil
	}
	if clipfile.Exists(path) {
		// The one branch that destroys something the user did not name.
		confirm, confirmErr := b.Console.ReadLine(fmt.Sprintf("%s already exists. Overwrite it? Type yes to confirm: ", path))
		if confirmErr != nil {
			return confirmErr
		}
		switch strings.ToLower(strings.TrimSpace(confirm)) {
		case "y", "yes":
		default:
			b.Console.Say("Not saved.")
			return nil
		}
	}
	text := b.text(entry)
	if writeErr := clipfile.Write(path, text); writeErr != nil {
		b.Console.Say(fmt.Sprintf("Could not save: %v", writeErr))
		return nil
	}
	b.Console.Say(fmt.Sprintf("Saved %s to %s.", output.Count(clipfile.LineCount(text), "line", "lines"), path))
	return nil
}

// runOnEntry runs a program against a clip.
//
// The rules are announced before the question rather than after a mistake:
// every other program that takes a command line hands it to a shell and this one
// does not, so saying it once costs less than a refusal per attempt.
func (b *Browser) runOnEntry(ctx context.Context, entry model.Entry) error {
	b.Console.Say("One program, run directly. No shell. " + clipexec.Placeholder +
		" stands for the clip text; without it the clip is piped in.")
	typed, err := b.Console.ReadLine("Run: ")
	if err != nil {
		return err
	}
	if strings.TrimSpace(typed) == "" {
		b.Console.Say("Nothing was run.")
		return nil
	}
	plan, buildErr := clipexec.Build(typed, b.text(entry))
	if buildErr != nil {
		// A refusal is a sentence explaining what was found and how to get what
		// was meant, so it is announced as it stands.
		b.Console.Say(buildErr.Error())
		return nil
	}

	b.Console.Say(fmt.Sprintf("Running %s.", plan.Args[0]))
	result, runErr := clipexec.Run(ctx, plan)
	if runErr != nil {
		b.Console.Say(fmt.Sprintf("%s could not be run: %v", plan.Args[0], runErr))
		return nil
	}
	b.announceResult(result)
	return nil
}

// announceResult reports what a command did.
//
// The outcome is stated even when nothing was printed. A command that produces
// no output and says nothing about itself is indistinguishable from one that
// never ran.
func (b *Browser) announceResult(result clipexec.Result) {
	switch {
	case result.Stopped:
		b.Console.Say(fmt.Sprintf("%s was stopped before it finished.", result.Program))
	case result.Succeeded():
		b.Console.Say(fmt.Sprintf("%s finished successfully.", result.Program))
	default:
		b.Console.Say(fmt.Sprintf("%s failed with exit status %d.", result.Program, result.ExitCode))
	}
	if result.Truncated {
		b.Console.Say("Output was longer than 1 MB and was cut off.")
	}
	b.announceBlock("Output", result.Stdout)
	if strings.TrimSpace(result.Stderr) != "" {
		b.announceBlock("Errors", result.Stderr)
	}
}

// announceBlock reads a labelled block of program output, a page at a time so a
// chatty command cannot produce one unstoppable announcement.
func (b *Browser) announceBlock(label, text string) {
	if strings.TrimSpace(text) == "" {
		b.Console.Say(label + ": none.")
		return
	}
	b.Console.Say(label + ":")
	lines := output.PlainLines(strings.TrimRight(text, "\n"))
	size := b.pageSize()
	if size < 1 {
		size = len(lines)
	}
	for start := 0; start < len(lines); start += size {
		end := start + size
		if end > len(lines) {
			end = len(lines)
		}
		for index := start; index < end; index++ {
			b.Console.Say(fmt.Sprintf("%d. %s", index+1, lines[index]))
		}
		if end >= len(lines) {
			return
		}
		answer, err := b.Console.ReadLine("More output (Enter continues, q stops): ")
		if err != nil {
			return
		}
		if strings.EqualFold(strings.TrimSpace(answer), "q") {
			b.Console.Say(fmt.Sprintf("Stopped after %d of %s.", end, output.Count(len(lines), "line", "lines")))
			return
		}
	}
}
