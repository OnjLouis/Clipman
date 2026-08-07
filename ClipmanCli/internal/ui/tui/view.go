package tui

import (
	"fmt"
	"strings"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/uniseg"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
)

// A clip is arbitrary text the user copied from somewhere else, which makes it
// the least trustworthy thing this program draws. The list only ever shows a
// short preview of it; the viewer shows all of it, so everything a clip can
// contain that a terminal handles badly has to be dealt with here.
//
// Three things are handled, in this order: control characters that would render
// as garbage, lines longer than the window that drawLine would silently
// truncate, and characters wider than one column that would corrupt every
// column calculation after them.

// tabWidth is how far a tab is expanded. Tabs are expanded rather than passed
// through because a terminal's own tab handling moves the cursor without the
// program knowing, which puts the caret somewhere other than where the caret
// model believes it is.
const tabWidth = 4

// viewRow is one row of the viewer: a physical row on screen, carrying the
// logical line it belongs to.
//
// The distinction matters on a resize. Positions are held as a logical line and
// an offset within it, never as a physical row index, so re-wrapping at a new
// width leaves the reader on the same text rather than moving them somewhere
// they were not.
type viewRow struct {
	// line is the 1-based logical line number, as a text editor would count.
	line int
	// continued marks a row produced by wrapping rather than by a line break.
	continued bool
	text      string
}

// label renders the row's number the way the list renders an entry's: the
// number first, so it is the first thing spoken when the caret lands. Position
// therefore costs no extra announcement, which is what makes it affordable to
// have on every row rather than only at page boundaries.
//
// A continued row uses "+" instead of "." to say it is still the same line.
func (r viewRow) label() string {
	if r.continued {
		return fmt.Sprintf("%d+ ", r.line)
	}
	return fmt.Sprintf("%d. ", r.line)
}

// sanitize makes one logical line safe to draw.
//
// Control characters are shown in caret notation rather than dropped. Dropping
// them would mean the viewer quietly disagrees with what w writes and what Enter
// emits; showing them means a clip with a stray NUL is legible as one.
func sanitize(line string) string {
	var out strings.Builder
	column := 0
	for _, r := range line {
		switch {
		case r == '\t':
			width := tabWidth - (column % tabWidth)
			out.WriteString(strings.Repeat(" ", width))
			column += width
		case r == 0x7f:
			out.WriteString("^?")
			column += 2
		case r < 0x20:
			out.WriteByte('^')
			out.WriteRune(r + '@')
			column += 2
		default:
			out.WriteRune(r)
			column += runeWidth(r)
		}
	}
	return out.String()
}

// runeWidth is the number of terminal columns a rune occupies. tcell writes a
// wide rune into two cells, so anything that counts columns has to agree with it
// or every position after the first wide character is wrong.
func runeWidth(r rune) int {
	width := uniseg.StringWidth(string(r))
	if width < 1 {
		// Combining marks report zero and are drawn into the preceding cell;
		// treating them as zero here keeps the arithmetic honest.
		return 0
	}
	return width
}

// displayWidth is how many columns text occupies.
func displayWidth(text string) int { return uniseg.StringWidth(text) }

// splitLines breaks clip text into logical lines, normalising line endings.
//
// A clip copied from Windows carries CRLF and one copied from a terminal does
// not. A lone carriage return left in a row would move the terminal's cursor to
// the start of the line mid-draw, so the distinction is removed here rather than
// being allowed to reach the screen.
func splitLines(text string) []string {
	normalized := strings.ReplaceAll(text, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	return strings.Split(normalized, "\n")
}

// wrapClip turns clip text into the rows the viewer draws.
//
// Wrapping is not optional. drawLine truncates at the window edge, which is
// acceptable for a list row that is a preview by contract and not acceptable for
// a viewer, where silently dropping the end of a line means the user cannot read
// what they asked to read. Long single-line clips are the common case here: a
// URL is one logical line and forty rows.
func wrapClip(text string, width int) []viewRow {
	if width < 1 {
		width = 1
	}
	var rows []viewRow
	for index, line := range splitLines(text) {
		number := index + 1
		clean := sanitize(line)
		// The label is part of the row, so the text has to fit in what is left
		// after it. It is measured per line because a five-digit line number is
		// wider than a one-digit one.
		available := width - displayWidth(unselectedMarker) - displayWidth(viewRow{line: number}.label())
		if available < 1 {
			available = 1
		}
		chunks := wrapText(clean, available)
		for chunkIndex, chunk := range chunks {
			rows = append(rows, viewRow{line: number, continued: chunkIndex > 0, text: chunk})
		}
	}
	return rows
}

// wrapText breaks one sanitised line into pieces no wider than width.
//
// It breaks on grapheme cluster boundaries, not on runes: splitting between a
// base character and its combining mark would put half a character on each row,
// and splitting inside an emoji sequence produces something no screen reader can
// name. Words are not preserved — a clip is data, and breaking it at a word
// boundary would misrepresent where the text actually divides.
func wrapText(line string, width int) []string {
	if line == "" {
		return []string{""}
	}
	var chunks []string
	var current strings.Builder
	used := 0
	graphemes := uniseg.NewGraphemes(line)
	for graphemes.Next() {
		cluster := graphemes.Str()
		clusterWidth := displayWidth(cluster)
		if clusterWidth < 1 {
			clusterWidth = 0
		}
		if used+clusterWidth > width && used > 0 {
			chunks = append(chunks, current.String())
			current.Reset()
			used = 0
		}
		current.WriteString(cluster)
		used += clusterWidth
	}
	chunks = append(chunks, current.String())
	return chunks
}

// rowIndexForLine finds the first row belonging to a logical line, which is how
// a position survives re-wrapping when the window changes size.
func rowIndexForLine(rows []viewRow, line int) int {
	for index, row := range rows {
		if row.line >= line {
			return index
		}
	}
	if len(rows) == 0 {
		return 0
	}
	return len(rows) - 1
}

// openViewer shows the whole of an entry's text.
//
// A one-line clip opens the viewer too. Behaviour that branches on how big the
// content is is behaviour the user cannot predict, and "one line" is not even a
// useful test: a URL is one logical line and forty rows, which is exactly when
// being able to move through it matters.
func (b *Browser) openViewer(entry model.Entry) {
	b.viewText = b.text(entry)
	b.viewRows = nil
	b.viewWidth = 0
	b.viewCursor = 0
	b.viewTop = 0
	b.mode = modeView
	b.setStatus("Clip viewer. Press q to close, Enter to write it to standard output.")
}

func (b *Browser) closeViewer() {
	b.mode = modeList
	b.viewText = ""
	b.viewRows = nil
	b.viewWidth = 0
	b.setStatus("%s", b.heading())
}

// ensureViewRows rebuilds the wrapped rows when the window width changes.
//
// The reader's position is carried across as a logical line rather than as a row
// index. Re-wrapping moves every row, so keeping the index would silently move
// the user to different text on a resize — while they were reading it.
func (b *Browser) ensureViewRows() {
	width, _ := b.Screen.Size()
	if width < 1 {
		width = 1
	}
	if b.viewRows != nil && b.viewWidth == width {
		return
	}
	line := 1
	if b.viewCursor >= 0 && b.viewCursor < len(b.viewRows) {
		line = b.viewRows[b.viewCursor].line
	}
	b.viewRows = wrapClip(b.viewText, width)
	b.viewWidth = width
	b.viewCursor = rowIndexForLine(b.viewRows, line)
	b.clampView()
}

// clampView keeps the reader inside the clip and scrolls so their row is on
// screen. It is the viewer's twin of clampSelection, kept separate because the
// two positions must not share state.
func (b *Browser) clampView() {
	if b.viewCursor >= len(b.viewRows) {
		b.viewCursor = len(b.viewRows) - 1
	}
	if b.viewCursor < 0 {
		b.viewCursor = 0
	}
	rows := b.layout()
	if b.viewCursor < b.viewTop {
		b.viewTop = b.viewCursor
	}
	if b.viewCursor >= b.viewTop+rows {
		b.viewTop = b.viewCursor - rows + 1
	}
	if b.viewTop < 0 {
		b.viewTop = 0
	}
}

func (b *Browser) moveView(delta int) {
	b.viewCursor += delta
	b.clampView()
}

// viewerHeading names what is being read and how much of it there is.
//
// The total goes here rather than beside the caret because the heading is read
// once when the screen is new, while the row number is spoken on every move. A
// running "line 40 of 220" on each keypress would say the same second half
// hundreds of times.
func (b *Browser) viewerHeading() string {
	lines := 0
	if len(b.viewRows) > 0 {
		lines = b.viewRows[len(b.viewRows)-1].line
	}
	entries := b.visible()
	if b.selected < 0 || b.selected >= len(entries) {
		return fmt.Sprintf("Clip viewer: %s.", output.Count(lines, "line", "lines"))
	}
	return fmt.Sprintf("Viewing entry %d, %s: %s.",
		b.selected, output.Preview(entries[b.selected]), output.Count(lines, "line", "lines"))
}

// drawViewer writes the clip rows. Every row carries its line number and the
// selected one carries the marker, for the same reason the list does: without
// text that changes, moving the caret down one row dirties no cells at all, and
// the whole viewer would be betting on the screen reader announcing a bare
// cursor move in a terminal.
func (b *Browser) drawViewer(listRows int) {
	plain := tcell.StyleDefault
	for offset := 0; offset < listRows; offset++ {
		screenRow := firstListRow + offset
		index := b.viewTop + offset
		if index < 0 || index >= len(b.viewRows) {
			b.drawLine(screenRow, plain, "")
			continue
		}
		marker := unselectedMarker
		style := plain
		if index == b.viewCursor {
			marker = selectedMarker
			style = plain.Reverse(true)
		}
		item := b.viewRows[index]
		b.drawLine(screenRow, style, marker+item.label()+item.text)
	}
	if b.viewText == "" {
		b.drawLine(firstListRow, plain, selectedMarker+"1. This clip is empty.")
	}
}

// handleViewKey moves through the clip.
//
// Line motion is the primary movement even though paging is offered: a page key
// repaints the whole content area, which resends a screenful of text to the
// screen reader, while an arrow rewrites two markers. Space and b are here
// because they are what more taught everyone, and Page Up and Page Down because
// they are what the list already uses.
func (b *Browser) handleViewKey(event *tcell.EventKey) {
	page := b.layout()
	switch event.Key() {
	case tcell.KeyUp:
		b.moveView(-1)
		return
	case tcell.KeyDown:
		b.moveView(1)
		return
	case tcell.KeyPgUp:
		b.moveView(-page)
		return
	case tcell.KeyPgDn:
		b.moveView(page)
		return
	case tcell.KeyHome:
		b.moveView(-len(b.viewRows))
		return
	case tcell.KeyEnd:
		b.moveView(len(b.viewRows))
		return
	case tcell.KeyEnter:
		// Enter means the same thing in every mode: write this clip to standard
		// output and leave. The viewer is showing exactly the text that would be
		// written, so making it mean something else here would be the one
		// inconsistency the user cannot afford to discover in a pipeline.
		b.chosen = b.viewText
		b.quit = true
		return
	case tcell.KeyEscape:
		b.closeViewer()
		return
	case tcell.KeyCtrlC:
		b.quit = true
		return
	}
	if event.Key() != tcell.KeyRune {
		return
	}
	switch event.Rune() {
	case 'q':
		b.closeViewer()
	case ' ':
		b.moveView(page)
	case 'b':
		b.moveView(-page)
	case 'w':
		// Bound here as well as in the list, because being told to close the
		// clip you are reading in order to save it is two steps for a one-step
		// task. The prompt names the entry, since the viewer draws no marker.
		if b.PickOnly {
			b.setStatus("pick cannot write files. Use menu to save a clip to a file.")
			return
		}
		b.beginSave()
	}
}

// runesBefore returns the first count runes of text.
//
// It exists so a caret offset, which is counted in characters, can be turned
// into the text those characters occupy and measured in columns. Slicing the
// string directly would cut it at a byte and produce a broken rune.
func runesBefore(text string, count int) string {
	runes := []rune(text)
	if count < 0 {
		count = 0
	}
	if count > len(runes) {
		count = len(runes)
	}
	return string(runes[:count])
}
