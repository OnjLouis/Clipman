package tui

// promptEditor is one line of text being typed and where the caret sits inside
// it.
//
// Until this existed, a prompt accepted only Backspace. That is survivable for
// the filter, which is a word you retype in a second, and punishing for anything
// longer: correcting a typo in the middle of
//
//	curl --data-raw @clip https://example.test/endpoint
//
// meant destroying forty characters to reach it and typing them again. A user
// who cannot see the line is the one this costs most, because they cannot glance
// at what survived — they have to listen to the whole line back after every
// attempt.
//
// The caret is a position in runes, not bytes. A prompt holds whatever the user
// types, and moving left over a multi-byte character has to land between
// characters rather than inside one.
type promptEditor struct {
	text   []rune
	cursor int
}

// set replaces the line and puts the caret at the end, which is where someone
// resuming an existing filter expects to continue from.
func (p *promptEditor) set(value string) {
	p.text = []rune(value)
	p.cursor = len(p.text)
}

func (p *promptEditor) String() string { return string(p.text) }

// at reports where the caret is, in runes from the start of the typed text. The
// caret model adds this to the width of the question, so the caret lands on the
// character being edited rather than always at the end of the line.
func (p *promptEditor) at() int { return p.cursor }

func (p *promptEditor) insert(r rune) {
	p.clampCursor()
	p.text = append(p.text, 0)
	copy(p.text[p.cursor+1:], p.text[p.cursor:])
	p.text[p.cursor] = r
	p.cursor++
}

// backspace removes the character before the caret, which is the one just typed.
func (p *promptEditor) backspace() {
	p.clampCursor()
	if p.cursor == 0 {
		return
	}
	p.text = append(p.text[:p.cursor-1], p.text[p.cursor:]...)
	p.cursor--
}

// deleteForward removes the character the caret is on. It is separate from
// backspace because reaching a mistake from the left and from the right are both
// natural, and requiring one direction doubles the keystrokes for the other.
func (p *promptEditor) deleteForward() {
	p.clampCursor()
	if p.cursor >= len(p.text) {
		return
	}
	p.text = append(p.text[:p.cursor], p.text[p.cursor+1:]...)
}

func (p *promptEditor) left() {
	p.clampCursor()
	if p.cursor > 0 {
		p.cursor--
	}
}

func (p *promptEditor) right() {
	p.clampCursor()
	if p.cursor < len(p.text) {
		p.cursor++
	}
}

func (p *promptEditor) home() { p.cursor = 0 }
func (p *promptEditor) end()  { p.cursor = len(p.text) }

// clear empties the line.
//
// This is Ctrl+U, and it clears the whole line rather than only the part before
// the caret as a shell would. Starting over is the thing people actually want
// from that key, and a version that sometimes leaves text behind is one whose
// result has to be listened to before it can be trusted.
func (p *promptEditor) clear() {
	p.text = p.text[:0]
	p.cursor = 0
}

func (p *promptEditor) empty() bool { return len(p.text) == 0 }

// clampCursor keeps the caret inside the text after anything that could have
// shortened it.
func (p *promptEditor) clampCursor() {
	if p.cursor > len(p.text) {
		p.cursor = len(p.text)
	}
	if p.cursor < 0 {
		p.cursor = 0
	}
}
