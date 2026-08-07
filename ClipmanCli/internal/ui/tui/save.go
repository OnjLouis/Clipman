package tui

import (
	"fmt"
	"path/filepath"

	"github.com/gdamore/tcell/v2"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipfile"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
)

// target is the entry the clip commands act on: the selected one, in the list
// and in the viewer alike. The viewer shows no selection marker, so anything
// prompting about it has to name it instead.
func (b *Browser) target() (model.Entry, bool) {
	entries := b.visible()
	if b.selected < 0 || b.selected >= len(entries) {
		return model.Entry{}, false
	}
	return entries[b.selected], true
}

// beginSave asks where to write the selected clip.
//
// There is no confirmation before the question. The path is typed, and typing is
// deliberation: a confirm on top of it is the third y-prompt in this interface
// and the one that teaches people to dismiss the other two without listening.
func (b *Browser) beginSave() {
	entry, ok := b.target()
	if !ok {
		b.setStatus("There is nothing to save.")
		return
	}
	// The question names its target because the viewer draws no marker, so
	// "save to file" alone would leave the user guessing which clip.
	b.saveLabel = fmt.Sprintf("Save entry %d, %s, to file: ", b.selected, output.Preview(entry))
	b.prompt.set("")
	b.returnMode = b.mode
	b.mode = modeSavePath
}

func (b *Browser) handleSaveKey(event *tcell.EventKey) {
	switch event.Key() {
	case tcell.KeyEscape:
		b.prompt.clear()
		b.mode = b.returnMode
		b.setStatus("Not saved. %s", b.heading())
		return
	case tcell.KeyEnter:
		b.attemptSave()
		return
	}
	b.editPrompt(event)
}

// attemptSave resolves what was typed and either writes or asks first.
func (b *Browser) attemptSave() {
	path, err := clipfile.Resolve(b.prompt.String())
	if err != nil {
		b.notice("%v", err)
		return
	}
	if clipfile.IsDirectory(path) {
		b.notice("%s is a directory, not a file.", path)
		return
	}
	if clipfile.Exists(path) {
		// The one branch that destroys something the user did not name. Shaped
		// exactly like the delete confirmation so it reads the same way.
		b.savePath = path
		b.mode = modeConfirmOverwrite
		b.setStatus("%s already exists. Overwrite it? Press y to confirm, any other key to cancel.",
			filepath.Base(path))
		return
	}
	b.writeClip(path)
}

func (b *Browser) handleOverwriteKey(event *tcell.EventKey) {
	if event.Key() == tcell.KeyRune && (event.Rune() == 'y' || event.Rune() == 'Y') {
		b.writeClip(b.savePath)
		return
	}
	b.savePath = ""
	b.mode = b.returnMode
	b.setStatus("Not saved. %s", b.heading())
}

func (b *Browser) writeClip(path string) {
	b.savePath = ""
	entry, ok := b.target()
	if !ok {
		b.notice("There is nothing to save.")
		return
	}
	// The same text Enter would emit, so the two ways of getting a clip out of
	// Clipman cannot disagree about what the clip is. Templates resolve here for
	// the same reason.
	text := b.text(entry)
	if err := clipfile.Write(path, text); err != nil {
		b.notice("Could not save: %v", err)
		return
	}
	b.notice("Saved %s to %s. Press any key to continue.",
		output.Count(clipfile.LineCount(text), "line", "lines"), path)
}

// notice holds a message until a key is pressed.
//
// It exists because this interface has no reliable way to announce that
// something finished. The caret returns to the row being read, by design, so a
// status line written on the way past is very likely never spoken. That is
// tolerable for "reloaded" and not tolerable for "was my file written", which is
// the one thing the user cannot find out any other way. A mode whose prompt is
// the message puts the caret on it, which makes it certain to be read, and costs
// one keypress on the branch that matters.
func (b *Browser) notice(format string, args ...any) {
	b.setStatus(format, args...)
	b.mode = modeNotice
}

func (b *Browser) dismissNotice() {
	b.mode = b.returnMode
	if b.mode == modeView {
		b.setStatus("Clip viewer. Press q to close, Enter to write it to standard output.")
		return
	}
	b.setStatus("%s", b.heading())
}
