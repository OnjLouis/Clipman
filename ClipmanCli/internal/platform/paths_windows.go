//go:build windows

package platform

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

type dataBlob struct {
	cbData uint32
	pbData *byte
}

var crypt32 = syscall.NewLazyDLL("crypt32.dll")
var kernel32 = syscall.NewLazyDLL("kernel32.dll")
var cryptProtectData = crypt32.NewProc("CryptProtectData")
var cryptUnprotectData = crypt32.NewProc("CryptUnprotectData")
var localFree = kernel32.NewProc("LocalFree")
var moveFileEx = kernel32.NewProc("MoveFileExW")

const moveFileReplaceExisting = 0x1
const moveFileWriteThrough = 0x8

func defaultConfigDir() (string, error) {
	root := os.Getenv("LOCALAPPDATA")
	if root == "" {
		return "", errors.New("LOCALAPPDATA is unavailable")
	}
	return filepath.Join(root, "Clipman CLI"), nil
}
func hardenDirectory(path string) error          { return nil }
func hardenFile(path string) error               { return nil }
func validatePrivateDirectory(path string) error { return validatePrivate(path) }
func validatePrivate(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return errors.New("refusing reparse-point protected file")
	}
	return nil
}
func replaceFile(temp, path string) error {
	from, err := syscall.UTF16PtrFromString(temp)
	if err != nil {
		return err
	}
	to, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	result, _, callErr := moveFileEx.Call(uintptr(unsafe.Pointer(from)), uintptr(unsafe.Pointer(to)), moveFileReplaceExisting|moveFileWriteThrough)
	if result == 0 {
		return callErr
	}
	return nil
}
func Protect(value []byte) (string, error) {
	input := blob(value)
	var output dataBlob
	result, _, callErr := cryptProtectData.Call(uintptr(unsafe.Pointer(&input)), 0, 0, 0, 0, 1, uintptr(unsafe.Pointer(&output)))
	if result == 0 {
		return "", callErr
	}
	defer localFree.Call(uintptr(unsafe.Pointer(output.pbData)))
	protected := unsafe.Slice(output.pbData, output.cbData)
	return base64.StdEncoding.EncodeToString(protected), nil
}
func Unprotect(value string) ([]byte, error) {
	encoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return nil, err
	}
	input := blob(encoded)
	var output dataBlob
	result, _, callErr := cryptUnprotectData.Call(uintptr(unsafe.Pointer(&input)), 0, 0, 0, 0, 1, uintptr(unsafe.Pointer(&output)))
	if result == 0 {
		return nil, callErr
	}
	defer localFree.Call(uintptr(unsafe.Pointer(output.pbData)))
	return append([]byte(nil), unsafe.Slice(output.pbData, output.cbData)...), nil
}
func blob(value []byte) dataBlob {
	if len(value) == 0 {
		return dataBlob{}
	}
	return dataBlob{cbData: uint32(len(value)), pbData: &value[0]}
}
