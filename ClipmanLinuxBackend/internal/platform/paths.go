package platform

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func ConfigDir() (string, error) {
	if value := os.Getenv("CLIPMAN_HOME"); value != "" {
		return filepath.Abs(value)
	}
	return defaultConfigDir()
}

func ConfigPath(explicit string) (string, error) {
	if explicit != "" {
		return filepath.Abs(explicit)
	}
	if value := os.Getenv("CLIPMAN_CONFIG"); value != "" {
		return filepath.Abs(value)
	}
	dir, err := ConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.toml"), nil
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

func ReadPrivateBounded(path string, maximumBytes int64) ([]byte, error) {
	if err := validatePrivate(path); err != nil {
		return nil, err
	}
	return ReadFileBounded(path, maximumBytes)
}

func ReadFileBounded(path string, maximumBytes int64) ([]byte, error) {
	if maximumBytes < 0 {
		return nil, errors.New("maximum file size cannot be negative")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() > maximumBytes {
		return nil, fmt.Errorf("file exceeds %d-byte limit", maximumBytes)
	}
	data, err := io.ReadAll(io.LimitReader(file, maximumBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maximumBytes {
		return nil, fmt.Errorf("file exceeds %d-byte limit", maximumBytes)
	}
	return data, nil
}
func ErrNotSupported(feature string) error {
	return errors.New(feature + " is not supported on this platform")
}
