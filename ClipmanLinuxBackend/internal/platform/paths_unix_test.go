//go:build !windows

package platform

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSavePrivateRejectsSymlinkedDirectory(t *testing.T) {
	root := t.TempDir()
	realDirectory := filepath.Join(root, "real")
	if err := os.Mkdir(realDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	linkedDirectory := filepath.Join(root, "linked")
	if err := os.Symlink(realDirectory, linkedDirectory); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := SavePrivate(filepath.Join(linkedDirectory, "config.toml"), []byte("secret")); err == nil {
		t.Fatal("expected symlinked directory rejection")
	}
}
