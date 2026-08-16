package platform

import (
	"errors"
	"os"
	"path/filepath"
)

// ConfigFileName is the name looked for in every candidate directory.
const ConfigFileName = "config.toml"

func ConfigDir() (string, error) {
	if value := os.Getenv("CLIPMAN_HOME"); value != "" {
		return filepath.Abs(value)
	}
	return defaultConfigDir()
}

// PortableConfigPath returns the configuration file that sits beside the
// running executable, whether or not it exists.
//
// This is the directory holding the binary, not the working directory. Two
// copies of Clipman CLI can then keep separate profiles that travel with them,
// which is the point: the profile belongs to the build, not to wherever the
// shell happens to be standing. Honoring the working directory instead would
// let any unrelated config.toml take over a session, and this file names a
// server and carries a token.
func PortableConfigPath() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	// A symlinked binary resolves to its real location, so the profile stays
	// with the installation rather than with the link.
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return filepath.Join(filepath.Dir(executable), ConfigFileName), nil
}

// ConfigPath resolves which configuration file to use. In order:
//
//  1. an explicit --config path;
//  2. CLIPMAN_CONFIG;
//  3. CLIPMAN_HOME plus the standard filename;
//  4. a config.toml sitting beside the executable, if one exists;
//  5. the per-user location for the platform.
//
// Step 4 applies only when the file is already there, so an ordinary
// installation is unaffected and the per-user profile stays the default.
func ConfigPath(explicit string) (string, error) {
	if explicit != "" {
		return filepath.Abs(explicit)
	}
	if value := os.Getenv("CLIPMAN_CONFIG"); value != "" {
		return filepath.Abs(value)
	}
	if value := os.Getenv("CLIPMAN_HOME"); value != "" {
		dir, err := filepath.Abs(value)
		if err != nil {
			return "", err
		}
		return filepath.Join(dir, ConfigFileName), nil
	}
	if portable, err := PortableConfigPath(); err == nil {
		if info, statErr := os.Stat(portable); statErr == nil && !info.IsDir() {
			return portable, nil
		}
	}
	dir, err := defaultConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, ConfigFileName), nil
}

func SavePrivate(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if err := hardenDirectory(dir); err != nil {
		return err
	}
	if err := validatePrivateDirectory(dir); err != nil {
		return err
	}
	temp, err := os.CreateTemp(dir, ".clipman-*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := replaceFile(tempName, path); err != nil {
		return err
	}
	return hardenFile(path)
}

func ReadPrivate(path string) ([]byte, error) {
	if err := validatePrivate(path); err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}
func ErrNotSupported(feature string) error {
	return errors.New(feature + " is not supported on this platform")
}
