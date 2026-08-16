package clipfile

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestTildeIsExpanded is the one that stops a directory literally named "~"
// appearing in the working directory. There is no shell here to do it.
func TestTildeIsExpanded(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("no home directory available: %v", err)
	}
	got, err := Resolve("~/notes.txt")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if want := filepath.Join(home, "notes.txt"); got != want {
		t.Fatalf("Resolve(~/notes.txt) = %q, want %q", got, want)
	}
	if strings.Contains(got, "~") {
		t.Errorf("a tilde survived expansion: %q", got)
	}
}

// TestAnotherUsersHomeIsRefused rather than guessed at. Writing to the wrong
// place is worse than declining.
func TestAnotherUsersHomeIsRefused(t *testing.T) {
	_, err := Resolve("~someone/notes.txt")
	if err == nil {
		t.Fatal("~user must be refused, not resolved to something else")
	}
	if !strings.Contains(err.Error(), "full path") {
		t.Errorf("the refusal must say what to do instead: %v", err)
	}
}

func TestRelativePathBecomesAbsolute(t *testing.T) {
	got, err := Resolve("notes.txt")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !filepath.IsAbs(got) {
		t.Fatalf("Resolve returned %q, which is not absolute", got)
	}
}

func TestEmptyPathIsRefused(t *testing.T) {
	for _, typed := range []string{"", "   ", "\t"} {
		if _, err := Resolve(typed); err == nil {
			t.Errorf("Resolve(%q) must be refused", typed)
		}
	}
}

// TestWriteIsVerbatim is what keeps w and Enter from disagreeing about what the
// clip is. Nothing may be added on the way out.
func TestWriteIsVerbatim(t *testing.T) {
	for _, text := range []string{
		"no trailing newline",
		"trailing newline\n",
		"windows\r\nline endings\r\n",
		"",
		"trailing spaces   ",
	} {
		path := filepath.Join(t.TempDir(), "clip.txt")
		if err := Write(path, text); err != nil {
			t.Fatalf("Write(%q): %v", text, err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile: %v", err)
		}
		if string(data) != text {
			t.Errorf("wrote %q, want %q byte for byte", data, text)
		}
	}
}

// TestNewFilesAreOwnerOnly because a clip may be a credential and the file may
// be on a shared machine.
func TestNewFilesAreOwnerOnly(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix permission bits are not meaningful on Windows")
	}
	path := filepath.Join(t.TempDir(), "secret.txt")
	if err := Write(path, "a token, for all we know"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != Mode {
		t.Fatalf("mode = %o, want %o", perm, Mode)
	}
}

func TestExistsAndDirectory(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "present.txt")
	if err := Write(file, "here"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if !Exists(file) {
		t.Error("an existing file must be reported as existing")
	}
	if IsDirectory(file) {
		t.Error("a file is not a directory")
	}
	if !Exists(dir) || !IsDirectory(dir) {
		t.Error("a directory must be reported as an existing directory")
	}
	if Exists(filepath.Join(dir, "absent.txt")) {
		t.Error("a missing file must not be reported as existing")
	}
}

// TestWritingToADirectoryIsRefusedClearly, because "notes" and "notes/" is an
// easy slip and the operating system's message for it is not a sentence.
func TestWritingToADirectoryIsRefusedClearly(t *testing.T) {
	dir := t.TempDir()
	err := Write(dir, "text")
	if err == nil {
		t.Fatal("writing to a directory must fail")
	}
	if !strings.Contains(err.Error(), "is a directory") {
		t.Errorf("the message must say what is wrong: %v", err)
	}
}

// TestOverwriteReplacesRatherThanAppends guards the truncate flag. Leaving a
// longer previous clip's tail behind would be silent corruption.
func TestOverwriteReplacesRatherThanAppends(t *testing.T) {
	path := filepath.Join(t.TempDir(), "clip.txt")
	if err := Write(path, "a much longer first clip"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if err := Write(path, "short"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "short" {
		t.Fatalf("overwrote to %q, want %q with no tail left behind", data, "short")
	}
}

func TestLineCount(t *testing.T) {
	for _, item := range []struct {
		text string
		want int
	}{
		{"", 0},
		{"one", 1},
		{"one\n", 1},
		{"one\ntwo", 2},
		{"one\ntwo\n", 2},
		{"\n", 1},
	} {
		if got := LineCount(item.text); got != item.want {
			t.Errorf("LineCount(%q) = %d, want %d", item.text, got, item.want)
		}
	}
}
