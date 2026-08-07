// Package line implements the accessible line-oriented history browser used by
// `clipman-cli menu` and `clipman-cli pick`.
//
// Three rules shape everything here.
//
// First, the terminal and the payload are different destinations. Prompts,
// rows, confirmations, and errors go to the controlling terminal through
// Console. Only a deliberately chosen clip's text goes to Stdout, so
// `clipman-cli pick | ssh host 'cat > file'` transfers the clip and nothing
// else.
//
// Second, a row heard on its own has no column headers to explain it, so every
// row is a complete labeled sentence and every state change is announced
// rather than merely drawn.
//
// Third, the view is loaded once and reused. A screen-reader user moves
// through a list one command at a time, and a network round trip on every
// command turns that into a stall on every keystroke. Refresh is explicit.
package line

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/template"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/handoff"
)

// ErrCancelled reports that the user deliberately abandoned a selection. The
// caller maps it to the usage exit code, because nothing failed.
var ErrCancelled = errors.New("selection cancelled")

// ErrNoEntries reports that the requested view holds nothing to choose from.
var ErrNoEntries = errors.New("no matching entries")

// Store is the history the browser works against. Load returns the canonical
// view for the selected kind and pinned preference; Delete and Create commit
// through the ordinary optimistic upload path.
type Store interface {
	Load(ctx context.Context) ([]model.Entry, error)
	Delete(ctx context.Context, id string) error
	Create(ctx context.Context, text, name string) (model.Entry, error)
}

// Console is the controlling terminal. Say announces a line; ReadLine prompts
// and reads one. Both are separate from the payload stream on purpose.
type Console interface {
	Say(text string)
	ReadLine(prompt string) (string, error)
}

// Browser renders and drives the line UI.
type Browser struct {
	Store   Store
	Console Console
	// Stdout receives selected clip text and nothing else.
	Stdout io.Writer
	// PageSize bounds how many rows are announced at once. Zero means the
	// default; a negative value disables paging.
	PageSize int
	// PinnedFirst mirrors the view order so a locally changed entry can be
	// re-sorted without another download.
	PinnedFirst bool
	// Now supplies the clock, injected so transcripts are deterministic.
	Now func() time.Time
	// Kind is the view this session was launched with. The line interface has
	// no way to change it; it is held only so a switch to the other interface
	// can carry it, which the other interface can change with Tab.
	Kind operation.Kind
	// Arrival, when set, is the place the user held in the interface they just
	// left, applied before the first announcement.
	Arrival *handoff.Request

	entries []model.Entry
	query   string
	page    int
	loaded  bool
}

const defaultPageSize = 20

func (b *Browser) now() time.Time {
	if b.Now != nil {
		return b.Now()
	}
	return time.Now()
}

func (b *Browser) pageSize() int {
	if b.PageSize == 0 {
		return defaultPageSize
	}
	return b.PageSize
}

// load fetches the view once. Subsequent commands work from memory until the
// user asks to refresh or a mutation changes the list.
func (b *Browser) load(ctx context.Context) error {
	entries, err := b.Store.Load(ctx)
	if err != nil {
		return err
	}
	b.entries = entries
	b.loaded = true
	return nil
}

// visible applies the active search to the loaded view. Indices announced to
// the user are positions in this slice, so they stay valid across paging and
// mean the same thing on every page.
func (b *Browser) visible() []model.Entry {
	if b.query == "" {
		return b.entries
	}
	needle := strings.ToLower(b.query)
	matches := make([]model.Entry, 0, len(b.entries))
	for _, entry := range b.entries {
		if strings.Contains(strings.ToLower(entry.Name+"\n"+entry.Text), needle) {
			matches = append(matches, entry)
		}
	}
	return matches
}

func (b *Browser) pageCount(total int) int {
	size := b.pageSize()
	if size < 0 || total == 0 {
		return 1
	}
	return (total + size - 1) / size
}

// window returns the half-open range of the current page, clamping the page
// number if the list shrank underneath it.
func (b *Browser) window(total int) (int, int) {
	size := b.pageSize()
	if size < 0 {
		b.page = 0
		return 0, total
	}
	pages := b.pageCount(total)
	if b.page >= pages {
		b.page = pages - 1
	}
	if b.page < 0 {
		b.page = 0
	}
	start := b.page * size
	end := start + size
	if end > total {
		end = total
	}
	return start, end
}

// announceList speaks the heading, the page position, and the rows.
func (b *Browser) announceList() {
	entries := b.visible()
	total := len(entries)
	now := b.now()
	if b.query == "" {
		b.Console.Say(fmt.Sprintf("Clipman history: %s.", output.Count(total, "entry", "entries")))
	} else {
		b.Console.Say(fmt.Sprintf("Search %q: %s of %s.", b.query, output.Count(total, "match", "matches"), output.Count(len(b.entries), "entry", "entries")))
	}
	if total == 0 {
		if b.query != "" {
			b.Console.Say("Type / on its own to clear the search.")
		}
		return
	}
	start, end := b.window(total)
	if pages := b.pageCount(total); pages > 1 {
		b.Console.Say(fmt.Sprintf("Page %d of %d, entries %d to %d.", b.page+1, pages, start, end-1))
	}
	for index := start; index < end; index++ {
		b.Console.Say(output.Describe(index, entries[index], now))
	}
}

const helpText = `Commands:
  NUMBER      view an entry
  o NUMBER    write an entry to standard output and exit
  d NUMBER    delete an entry after confirmation
  /TEXT       show only entries matching TEXT
  /           clear the search
  n           next page
  p           previous page
  a           add a new clip
  r           reload from the server
  u           switch to the full-screen interface
  ?           repeat this list
  q           quit

This is the line interface, which asks for a command and answers in whole
sentences. The full-screen interface moves through the list with the arrow
keys instead. Type u to switch to it; the choice is remembered as your
default.`

// Run drives the interactive manager until the user quits or emits a clip.
func (b *Browser) Run(ctx context.Context) error {
	if err := b.load(ctx); err != nil {
		return err
	}
	// A short hint rather than the whole command list: the full help is one
	// keystroke away, and hearing twelve lines of it on every launch is a
	// worse default than hearing one.
	//
	// The interface is named here rather than only in help. Two interchangeable
	// interfaces ship, and a user who is never told which one they are in has no
	// reason to look for the other; naming it costs one word per launch and is
	// what makes the choice discoverable at all.
	b.Console.Say("Clipman line interface. Type ? for commands.")
	b.applyArrival()
	b.announceList()
	b.announceArrival()
	for {
		answer, err := b.ReadCommand()
		if err != nil {
			return err
		}
		done, err := b.dispatch(ctx, answer)
		if err != nil {
			return err
		}
		if done {
			return nil
		}
	}
}

// switchInterface asks before leaving. The other interface takes over the whole
// window, which is a large change to make on one unconfirmed keystroke, and the
// question is also where the user is told the choice will stick.
//
// The confirmation is not only a safety net. tcell clears whatever this
// interface printed the moment it initialises, so a message announced on the way
// out cannot be relied on to be heard; a question that must be answered is the
// one thing that is certain to have been read.
func (b *Browser) switchInterface() (bool, error) {
	answer, err := b.Console.ReadLine("Switch to the full-screen interface? It uses the arrow keys and takes over the whole window. Press u inside it to come back here. This also becomes your default. Type yes to confirm: ")
	if err != nil {
		return false, err
	}
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true, &handoff.Request{Selected: b.firstOnPage(), Filter: b.query, Kind: b.Kind}
	}
	b.Console.Say("Staying in the line interface.")
	return false, nil
}

// firstOnPage is this interface's answer to "where was I". It has no selected
// row, so the first entry of the page being read is the closest true equivalent.
func (b *Browser) firstOnPage() int {
	entries := b.visible()
	if len(entries) == 0 {
		return 0
	}
	start, _ := b.window(len(entries))
	return start
}

// applyArrival restores the search and page the user held in the interface they
// just left. It runs before the first announcement so the list they hear is the
// list they were already looking at.
func (b *Browser) applyArrival() {
	if b.Arrival == nil {
		return
	}
	b.query = b.Arrival.Filter
	size := b.pageSize()
	if size > 0 && b.Arrival.Selected > 0 {
		b.page = b.Arrival.Selected / size
	}
}

// announceArrival names the entry the user was resting on. The full-screen
// interface says this with the cursor, by landing it on the row; the line
// interface has no cursor to land, so it says it in words. Without this a
// switch reads as twenty sentences with no indication of where you were.
func (b *Browser) announceArrival() {
	if b.Arrival == nil {
		return
	}
	entries := b.visible()
	if b.Arrival.Selected < 0 || b.Arrival.Selected >= len(entries) {
		return
	}
	b.Console.Say(fmt.Sprintf("You were on entry %d.", b.Arrival.Selected))
}

// ReadCommand prompts for the next command.
func (b *Browser) ReadCommand() (string, error) {
	answer, err := b.Console.ReadLine("Command (? for help): ")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(answer), nil
}

// dispatch runs one command and reports whether the session should end.
func (b *Browser) dispatch(ctx context.Context, answer string) (bool, error) {
	if answer == "" {
		b.Console.Say("Type a command, or ? for the list of commands.")
		return false, nil
	}
	// A search is handled before the word split so the text may contain
	// spaces, which an ordinary two-word command form would swallow.
	if strings.HasPrefix(answer, "/") {
		b.setQuery(strings.TrimSpace(strings.TrimPrefix(answer, "/")))
		return false, nil
	}
	action := answer
	argument := ""
	if first, rest, found := strings.Cut(answer, " "); found {
		action = first
		argument = strings.TrimSpace(rest)
	}
	switch strings.ToLower(action) {
	case "q", "quit":
		b.Console.Say("Leaving Clipman history.")
		return true, nil
	case "?", "h", "help":
		b.Console.Say(helpText)
		return false, nil
	case "u", "ui", "renderer":
		// Three spellings for the same thing, matching this interface's habit of
		// accepting r/refresh and p/prev/previous. "renderer" is included
		// because that is the word the flag and the configuration key use.
		return b.switchInterface()
	case "r", "refresh":
		if err := b.load(ctx); err != nil {
			return false, err
		}
		b.Console.Say("Reloaded from the server.")
		b.announceList()
		return false, nil
	case "n", "next":
		b.turnPage(1)
		return false, nil
	case "p", "prev", "previous":
		b.turnPage(-1)
		return false, nil
	case "a", "add", "new":
		return false, b.addEntry(ctx)
	case "o", "out", "output":
		entry, ok := b.resolveIndex(argument)
		if !ok {
			return false, nil
		}
		if _, err := io.WriteString(b.Stdout, b.text(entry)); err != nil {
			return false, fmt.Errorf("cannot write clip text: %w", err)
		}
		return true, nil
	case "d", "delete", "rm":
		entry, ok := b.resolveIndex(argument)
		if !ok {
			return false, nil
		}
		return false, b.deleteEntry(ctx, entry)
	default:
		entry, ok := b.resolveIndex(answer)
		if !ok {
			return false, nil
		}
		b.Console.Say(b.text(entry))
		return false, nil
	}
}

// text returns what the user asked to see or emit, resolving a template's
// variables the way get and pick do.
func (b *Browser) text(entry model.Entry) string {
	if entry.IsTemplate {
		return template.Resolve(entry.Text, b.now())
	}
	return entry.Text
}

func (b *Browser) setQuery(query string) {
	b.query = query
	b.page = 0
	if query == "" {
		b.Console.Say("Search cleared.")
	}
	b.announceList()
}

func (b *Browser) turnPage(delta int) {
	total := len(b.visible())
	pages := b.pageCount(total)
	if pages <= 1 {
		b.Console.Say("There is only one page.")
		return
	}
	target := b.page + delta
	if target < 0 {
		b.Console.Say("This is the first page.")
		return
	}
	if target >= pages {
		b.Console.Say("This is the last page.")
		return
	}
	b.page = target
	b.announceList()
}

// resolveIndex turns a typed index into an entry, announcing why it failed
// rather than leaving the user to guess.
func (b *Browser) resolveIndex(value string) (model.Entry, bool) {
	entries := b.visible()
	if value == "" {
		b.Console.Say("That command needs an entry number.")
		return model.Entry{}, false
	}
	index, err := strconv.Atoi(value)
	if err != nil {
		b.Console.Say(fmt.Sprintf("%q is not a command or an entry number. Type ? for the list of commands.", value))
		return model.Entry{}, false
	}
	if len(entries) == 0 {
		b.Console.Say("There are no entries to choose from.")
		return model.Entry{}, false
	}
	if index < 0 || index >= len(entries) {
		b.Console.Say(fmt.Sprintf("Entry %d does not exist. Numbers run from 0 to %d.", index, len(entries)-1))
		return model.Entry{}, false
	}
	return entries[index], true
}

func (b *Browser) deleteEntry(ctx context.Context, entry model.Entry) error {
	confirmation, err := b.Console.ReadLine(fmt.Sprintf("Delete %s? Type yes to confirm: ", output.Preview(entry)))
	if err != nil {
		return err
	}
	if !strings.EqualFold(strings.TrimSpace(confirmation), "yes") {
		b.Console.Say("Deletion cancelled.")
		return nil
	}
	if err := b.Store.Delete(ctx, entry.ID); err != nil {
		return err
	}
	// The upload already succeeded, so drop the entry locally instead of
	// downloading the database again to observe a change we just made.
	remaining := make([]model.Entry, 0, len(b.entries))
	for _, candidate := range b.entries {
		if !strings.EqualFold(candidate.ID, entry.ID) {
			remaining = append(remaining, candidate)
		}
	}
	b.entries = remaining
	b.Console.Say(fmt.Sprintf("Deleted %s.", output.Preview(entry)))
	b.announceList()
	return nil
}

// addEntry collects a multiline clip from the terminal. The terminator is a
// line holding a single period, and a line of two periods stores one, so any
// text remains expressible.
func (b *Browser) addEntry(ctx context.Context) error {
	b.Console.Say("Type the new clip. Finish with a single period on a line by itself.")
	b.Console.Say("A line of two periods stores one period. Type !cancel on a line by itself to abandon it.")
	var lines []string
	for {
		input, err := b.Console.ReadLine("clip> ")
		if err != nil {
			return err
		}
		switch {
		case input == ".":
			return b.commitEntry(ctx, strings.Join(lines, "\n"))
		case input == "!cancel":
			b.Console.Say("New clip abandoned.")
			return nil
		case input == "..":
			lines = append(lines, ".")
		default:
			lines = append(lines, input)
		}
	}
}

func (b *Browser) commitEntry(ctx context.Context, text string) error {
	if strings.TrimSpace(text) == "" {
		b.Console.Say("Nothing was typed, so no clip was added.")
		return nil
	}
	name, err := b.Console.ReadLine("Name for this clip, or press Enter to skip: ")
	if err != nil {
		return err
	}
	entry, err := b.Store.Create(ctx, text, strings.TrimSpace(name))
	if err != nil {
		return err
	}
	// Replace an existing copy rather than listing it twice: a duplicate put
	// moves the original to the top instead of creating a second entry.
	updated := make([]model.Entry, 0, len(b.entries)+1)
	updated = append(updated, entry)
	for _, candidate := range b.entries {
		if !strings.EqualFold(candidate.ID, entry.ID) {
			updated = append(updated, candidate)
		}
	}
	b.entries = updated
	operation.SortView(b.entries, b.PinnedFirst)
	b.query = ""
	b.page = 0
	b.Console.Say(fmt.Sprintf("Added %s.", output.Preview(entry)))
	b.announceList()
	return nil
}

// Pick announces the view once, takes a single choice, and writes that clip's
// text to Stdout. It never mutates history.
func (b *Browser) Pick(ctx context.Context) error {
	if err := b.load(ctx); err != nil {
		return err
	}
	if len(b.entries) == 0 {
		return ErrNoEntries
	}
	b.announceList()
	for {
		answer, err := b.Console.ReadLine("Select an entry number, n or p to page, or q to cancel: ")
		if err != nil {
			return err
		}
		answer = strings.TrimSpace(answer)
		switch strings.ToLower(answer) {
		case "q", "quit":
			return ErrCancelled
		case "n", "next":
			b.turnPage(1)
			continue
		case "p", "prev", "previous":
			b.turnPage(-1)
			continue
		case "u", "ui", "renderer":
			// Refused here rather than offered: pick writes one clip and exits,
			// and switching out of it would strand the user in a picker they
			// cannot switch back from. Saving a preference as a side effect of
			// `pick | ssh host` would also be a surprise write to a file that
			// holds a credential.
			b.Console.Say("pick cannot change interface. Use menu to switch.")
			continue
		}
		entry, ok := b.resolveIndex(answer)
		if !ok {
			continue
		}
		_, err = io.WriteString(b.Stdout, b.text(entry))
		return err
	}
}
