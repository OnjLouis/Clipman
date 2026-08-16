package tui

import "testing"

func editorWith(value string, cursor int) *promptEditor {
	editor := &promptEditor{}
	editor.set(value)
	editor.cursor = cursor
	return editor
}

// TestTypingInsertsAtTheCaret, not at the end. The whole point of a caret
// position is that text arrives where the user put it.
func TestTypingInsertsAtTheCaret(t *testing.T) {
	editor := editorWith("ac", 1)
	editor.insert('b')
	if got := editor.String(); got != "abc" {
		t.Fatalf("String() = %q, want %q", got, "abc")
	}
	if editor.at() != 2 {
		t.Errorf("caret = %d, want 2, just after what was typed", editor.at())
	}
}

func TestSetPutsTheCaretAtTheEnd(t *testing.T) {
	editor := &promptEditor{}
	editor.set("existing filter")
	if editor.at() != len([]rune("existing filter")) {
		t.Fatalf("caret = %d, want the end of the line", editor.at())
	}
}

// TestBackspaceRemovesWhatIsBehind, which is the character just typed.
func TestBackspaceRemovesWhatIsBehind(t *testing.T) {
	editor := editorWith("abc", 2)
	editor.backspace()
	if got, want := editor.String(), "ac"; got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}
	if editor.at() != 1 {
		t.Errorf("caret = %d, want 1", editor.at())
	}
}

func TestBackspaceAtTheStartDoesNothing(t *testing.T) {
	editor := editorWith("abc", 0)
	editor.backspace()
	if got := editor.String(); got != "abc" {
		t.Fatalf("String() = %q, want the line unchanged", got)
	}
	if editor.at() != 0 {
		t.Errorf("caret = %d, want 0", editor.at())
	}
}

// TestDeleteRemovesWhatIsUnderTheCaret. Reaching a mistake from the right is as
// natural as reaching it from the left, and requiring one direction doubles the
// keystrokes for the other.
func TestDeleteRemovesWhatIsUnderTheCaret(t *testing.T) {
	editor := editorWith("abc", 1)
	editor.deleteForward()
	if got, want := editor.String(), "ac"; got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}
	if editor.at() != 1 {
		t.Errorf("caret = %d, want it to stay at 1", editor.at())
	}
}

func TestDeleteAtTheEndDoesNothing(t *testing.T) {
	editor := editorWith("abc", 3)
	editor.deleteForward()
	if got := editor.String(); got != "abc" {
		t.Fatalf("String() = %q, want the line unchanged", got)
	}
}

func TestMovementStopsAtBothEnds(t *testing.T) {
	editor := editorWith("abc", 0)
	editor.left()
	if editor.at() != 0 {
		t.Errorf("left at the start moved to %d", editor.at())
	}
	editor.end()
	if editor.at() != 3 {
		t.Errorf("end() = %d, want 3", editor.at())
	}
	editor.right()
	if editor.at() != 3 {
		t.Errorf("right at the end moved to %d", editor.at())
	}
	editor.home()
	if editor.at() != 0 {
		t.Errorf("home() = %d, want 0", editor.at())
	}
}

func TestClearEmptiesTheWholeLine(t *testing.T) {
	editor := editorWith("a long mistaken command line", 5)
	editor.clear()
	if !editor.empty() || editor.String() != "" {
		t.Fatalf("String() = %q, want empty", editor.String())
	}
	if editor.at() != 0 {
		t.Errorf("caret = %d, want 0", editor.at())
	}
}

// TestCaretCountsRunesNotBytes. A prompt holds whatever the user types, and
// moving left over a multi-byte character has to land between characters rather
// than inside one.
func TestCaretCountsRunesNotBytes(t *testing.T) {
	editor := &promptEditor{}
	editor.set("日本語")
	if editor.at() != 3 {
		t.Fatalf("caret = %d, want 3 runes rather than 9 bytes", editor.at())
	}
	editor.left()
	editor.insert('x')
	if got, want := editor.String(), "日本x語"; got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}
}

// TestEditingAMistakeInTheMiddle is the case this exists for, end to end.
func TestEditingAMistakeInTheMiddle(t *testing.T) {
	editor := &promptEditor{}
	editor.set("curl --data-raww @clip https://example.test")
	// Reach the doubled w without destroying everything after it.
	for i := 0; i < len([]rune(" @clip https://example.test")); i++ {
		editor.left()
	}
	editor.backspace()
	want := "curl --data-raw @clip https://example.test"
	if got := editor.String(); got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}
}

// TestCursorSurvivesAShorterLine guards the clamp. Nothing may leave the caret
// pointing past the end of the text.
func TestCursorSurvivesAShorterLine(t *testing.T) {
	editor := editorWith("abc", 3)
	editor.text = editor.text[:1]
	editor.backspace()
	if editor.at() != 0 || editor.String() != "" {
		t.Fatalf("editor = %q at %d, want an empty line at 0", editor.String(), editor.at())
	}
}
