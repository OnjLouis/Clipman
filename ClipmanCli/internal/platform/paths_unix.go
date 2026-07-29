//go:build !windows

package platform

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func defaultConfigDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".clipman"), nil
}
func hardenDirectory(path string) error {
	if err := validateOwner(path, true); err != nil {
		return err
	}
	return os.Chmod(path, 0700)
}
func hardenFile(path string) error               { return os.Chmod(path, 0600) }
func validatePrivateDirectory(path string) error { return validateOwner(path, true) }
func validatePrivate(path string) error {
	if err := validateOwner(filepath.Dir(path), true); err != nil {
		return err
	}
	if err := validateOwner(path, false); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing symlinked protected file %s", path)
	}
	if info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("protected file %s is accessible by other users; run chmod 600", path)
	}
	return nil
}

func validateOwner(path string, directory bool) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	if err := rejectUnsafeSymlinkComponents(abs); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing symlinked protected path %s", path)
	}
	if directory && !info.IsDir() {
		return fmt.Errorf("protected directory path is not a directory: %s", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("protected path is not owned by the current user: %s", path)
	}
	return nil
}

func rejectUnsafeSymlinkComponents(path string) error {
	volume := filepath.VolumeName(path)
	current := volume + string(os.PathSeparator)
	relative := strings.TrimPrefix(path, current)
	parts := strings.Split(relative, string(os.PathSeparator))
	for index, part := range parts {
		if part == "" {
			continue
		}
		parent := current
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink == 0 {
			continue
		}
		if index == len(parts)-1 || !trustedSystemSymlinkParent(parent) {
			return fmt.Errorf("refusing protected path containing an untrusted symlink: %s", path)
		}
	}
	return nil
}

func trustedSystemSymlinkParent(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0022 != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == 0
}
func replaceFile(temp, path string) error    { return os.Rename(temp, path) }
func Protect(value []byte) (string, error)   { return string(value), nil }
func Unprotect(value string) ([]byte, error) { return []byte(value), nil }
