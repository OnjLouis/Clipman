package platform

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestBoundedFileReadersAcceptLimitAndRejectLimitPlusOne(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.clipdb")
	data := bytes.Repeat([]byte("x"), 32)
	if err := SavePrivate(path, data); err != nil {
		t.Fatal(err)
	}
	if got, err := ReadPrivateBounded(path, 32); err != nil || !bytes.Equal(got, data) {
		t.Fatalf("exact-limit private read failed: bytes=%d err=%v", len(got), err)
	}
	if _, err := ReadPrivateBounded(path, 31); err == nil {
		t.Fatal("limit-plus-one private read was accepted")
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if got, err := ReadFileBounded(path, 32); err != nil || !bytes.Equal(got, data) {
		t.Fatalf("exact-limit import read failed: bytes=%d err=%v", len(got), err)
	}
	if _, err := ReadFileBounded(path, 31); err == nil {
		t.Fatal("limit-plus-one import read was accepted")
	}
}
