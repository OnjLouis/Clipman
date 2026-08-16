// Package clipfile writes a clip to a file the user named.
//
// It is deliberately not platform.SavePrivate. That function hardens the
// containing directory to owner-only and refuses a directory that is not already
// private, which is correct for a configuration file Clipman owns and wrong for
// a path the user chose: saving into ~/Documents should not change the
// permissions of ~/Documents, nor fail because other people can read it.
//
// The file itself is still created owner-only. A clip may be a password, a
// token, or a private key, and the cost of that mode is nothing.
package clipfile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Mode is the permission new files are created with. A clip is untrusted in the
// other direction too: it may be a credential, and a world-readable copy of one
// on a shared machine is a real cost for no benefit.
const Mode = 0o600

// Resolve turns what the user typed into an absolute path.
//
// A leading ~/ is expanded here because there is no shell to do it. Without
// this, typing ~/notes.txt creates a directory literally named "~" in the
// working directory — a mistake nobody notices for weeks and cannot easily
// undo once several files are in it.
func Resolve(typed string) (string, error) {
	path := strings.TrimSpace(typed)
	if path == "" {
		return "", errors.New("no file name was given")
	}
	switch {
	case path == "~":
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = home
	case strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`):
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = filepath.Join(home, path[2:])
	case strings.HasPrefix(path, "~"):
		// ~otheruser is not resolvable without a user database this program has
		// no business consulting, and guessing would write to the wrong place.
		return "", fmt.Errorf("%q names another user's home directory, which Clipman cannot resolve; type the full path instead", path)
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return absolute, nil
}

// Exists reports whether something is already at path, so the caller can ask
// before destroying it. A directory counts: writing to one fails, and saying so
// before the attempt is a better message than the operating system's.
func Exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// IsDirectory reports whether path is a directory, which is worth its own
// message because "notes" and "notes/" are an easy slip.
func IsDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// Write saves text to path exactly as it is.
//
// Nothing is added: no trailing newline, no line-ending translation. What is
// written is byte for byte what Enter would emit, so the two ways of getting a
// clip out of Clipman cannot disagree about its contents.
func Write(path, text string) error {
	if IsDirectory(path) {
		return fmt.Errorf("%s is a directory", path)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, Mode)
	if err != nil {
		return err
	}
	if _, err := file.WriteString(text); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// LineCount reports how many lines text will occupy, which is what a save
// confirmation announces. A clip with no trailing newline still ends a line, and
// an empty clip is zero lines rather than one empty one.
func LineCount(text string) int {
	if text == "" {
		return 0
	}
	return strings.Count(strings.TrimSuffix(text, "\n"), "\n") + 1
}
