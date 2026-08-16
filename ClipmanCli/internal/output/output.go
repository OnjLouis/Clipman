// Package output formats history entries for human reading, for porcelain
// consumers, and for JSON. Every function here is pure: it takes the values it
// needs, including the current time, and returns a string. Nothing in this
// package writes to a stream or reads a clock, so the exact bytes a user hears
// from a screen reader can be asserted in a test.
package output

import (
	"fmt"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

// previewRunes bounds a one-line preview. The limit counts runes rather than
// bytes so a multi-byte character is never split, which would produce a
// replacement character in the middle of spoken output.
const previewRunes = 80

// OneLine collapses value to a single line and shortens it to a preview
// length. Line breaks become spaces because a preview is announced as one
// item, and a stray newline would split it into two.
func OneLine(value string) string {
	value = strings.ReplaceAll(value, "\r\n", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) > previewRunes {
		return string(runes[:previewRunes-3]) + "..."
	}
	return value
}

// Preview returns the label to identify an entry by. A name is used when the
// user gave one, because a chosen name is a better spoken identifier than the
// opening characters of the text.
func Preview(entry model.Entry) string {
	if entry.Name != "" {
		return entry.Name
	}
	return OneLine(entry.Text)
}

// EmptyDash renders a blank field as a dash so a column is never silently
// empty. A screen reader announces nothing at all for an empty string, which
// makes the following field sound like it belongs to this one.
func EmptyDash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

// Age renders how long ago unixMs was, relative to now.
func Age(unixMs int64, now time.Time) string {
	duration := now.Sub(time.UnixMilli(unixMs))
	switch {
	case duration < time.Minute:
		return "now"
	case duration < time.Hour:
		return fmt.Sprintf("%dm", int(duration.Minutes()))
	case duration < 24*time.Hour:
		return fmt.Sprintf("%dh", int(duration.Hours()))
	default:
		return fmt.Sprintf("%dd", int(duration.Hours()/24))
	}
}

// Escape applies C-style escapes so one entry always occupies one physical
// line of porcelain output.
func Escape(value string) string {
	replacer := strings.NewReplacer("\\", "\\\\", "\t", "\\t", "\n", "\\n", "\r", "\\r")
	return replacer.Replace(value)
}

// Flags renders the pinned and template markers for the compact list. The
// field is fixed width so the columns after it stay aligned.
func Flags(entry model.Entry) string {
	flags := []byte("--")
	if entry.Pinned {
		flags[0] = 'P'
	}
	if entry.IsTemplate {
		flags[1] = 'T'
	}
	return string(flags)
}

// ListRow renders one row of `list` output.
func ListRow(index int, entry model.Entry, now time.Time) string {
	return fmt.Sprintf("%d  %s  %s  %s  %s", index, Flags(entry), Age(entry.LastUsedUnixMs, now), EmptyDash(entry.SourceMachine), Preview(entry))
}

// PorcelainRow renders one tab-separated row for scripts.
func PorcelainRow(index int, entry model.Entry, now time.Time) string {
	return fmt.Sprintf("%d\t%s\t%d\t%s\t%s\t%s", index, entry.ID, now.UnixMilli()-entry.LastUsedUnixMs, Escape(entry.SourceMachine), Escape(entry.Name), Escape(OneLine(entry.Text)))
}

// Describe renders one entry as a complete spoken sentence for the interactive
// line UI. Every field is labeled, because a row heard on its own carries no
// column headers to explain what its values mean.
func Describe(index int, entry model.Entry, now time.Time) string {
	var builder strings.Builder
	fmt.Fprintf(&builder, "%d. %s", index, Preview(entry))
	if entry.Pinned {
		builder.WriteString("; pinned")
	}
	if entry.IsTemplate {
		builder.WriteString("; template")
	}
	if entry.Group != "" {
		fmt.Fprintf(&builder, "; group %s", entry.Group)
	}
	fmt.Fprintf(&builder, "; from %s; used %s ago", EmptyDash(entry.SourceMachine), Age(entry.LastUsedUnixMs, now))
	return builder.String()
}

// EntryJSON renders an entry in the shared wire shape plus its index in the
// view it was selected from.
func EntryJSON(index int, entry model.Entry) map[string]any {
	return map[string]any{
		"Index": index, "Id": entry.ID, "Text": entry.Text, "Name": entry.Name,
		"Group": entry.Group, "SourceMachine": entry.SourceMachine,
		"CreatedUnixMs": entry.CreatedUnixMs, "LastUsedUnixMs": entry.LastUsedUnixMs,
		"Pinned": entry.Pinned, "IsTemplate": entry.IsTemplate, "ManualOrder": entry.ManualOrder,
	}
}

// Count renders a noun with its number, so announcements read naturally
// instead of saying "1 entries".
func Count(number int, singular, plural string) string {
	if number == 1 {
		return fmt.Sprintf("%d %s", number, singular)
	}
	return fmt.Sprintf("%d %s", number, plural)
}

// PlainLines turns arbitrary clip text into lines that are safe to announce.
//
// Clip text is whatever the user copied, which makes it the least trustworthy
// thing either interface handles. Line endings are normalised so a lone carriage
// return cannot move the terminal's cursor mid-announcement, tabs are expanded
// because a terminal's own tab handling moves the cursor without the program
// knowing, and remaining control characters are shown in caret notation rather
// than dropped — dropping them would make what is displayed disagree with what
// is written to a file or emitted to standard output.
//
// Both renderers use this, so a clip reads the same way in each.
func PlainLines(text string) []string {
	normalized := strings.ReplaceAll(text, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	lines := strings.Split(normalized, "\n")
	for index, line := range lines {
		lines[index] = PlainLine(line)
	}
	return lines
}

// TabWidth is how far a tab is expanded when clip text is displayed.
const TabWidth = 4

// PlainLine makes one line safe to display.
func PlainLine(line string) string {
	var out strings.Builder
	column := 0
	for _, r := range line {
		switch {
		case r == '\t':
			width := TabWidth - (column % TabWidth)
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
			column++
		}
	}
	return out.String()
}
