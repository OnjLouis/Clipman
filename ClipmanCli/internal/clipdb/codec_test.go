package clipdb

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestDecodeWindowsFixtures(t *testing.T) {
	for _, test := range []struct{ name, password string }{{"windows-compressed.clipdb", ""}, {"windows-encrypted.clipdb", "pässphrase"}} {
		data, err := os.ReadFile(filepath.Join("..", "..", "testdata", test.name))
		if err != nil {
			t.Fatal(err)
		}
		database, err := Decode(data, test.password, DefaultLimits())
		if err != nil {
			t.Fatalf("Decode(%s): %v", test.name, err)
		}
		if len(database.Entries) != 1 {
			t.Fatalf("entries=%d", len(database.Entries))
		}
		entry := database.Entries[0]
		if entry.ID != "0123456789abcdef0123456789abcdef" || entry.Text != "Hello from Windows Ω\r\nSecond line" || entry.SourceMachine != "WindowsFixture" || !entry.Pinned {
			t.Fatalf("unexpected fixture entry: %+v", entry)
		}
	}
}

func TestEncryptedAuthenticationBeforeDecrypt(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "windows-encrypted.clipdb"))
	if err != nil {
		t.Fatal(err)
	}
	data[len(data)-1] ^= 1
	if _, err := Decode(data, "pässphrase", DefaultLimits()); err != ErrPasswordOrData {
		t.Fatalf("error=%v", err)
	}
}

func TestRoundTripPreservesUnknownFields(t *testing.T) {
	raw := []byte(`{"Version":2,"UpdatedUnixMs":7,"FutureRoot":{"enabled":true},"Entries":[{"Id":"0123456789abcdef0123456789abcdef","Text":"value","FutureEntry":"keep"}],"DeletedEntries":[]}`)
	var database model.Database
	if err := json.Unmarshal(raw, &database); err != nil {
		t.Fatal(err)
	}
	blob, err := Encode(database, "secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(blob, "secret", DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(decoded)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"FutureRoot":{"enabled":true}`)) || !bytes.Contains(encoded, []byte(`"FutureEntry":"keep"`)) {
		t.Fatalf("unknown fields lost: %s", encoded)
	}
}

func TestDecodeLimitsDecompression(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "1", Text: string(bytes.Repeat([]byte("x"), 2048))}}
	blob, err := Encode(database, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(blob, "", Limits{MaxBlobBytes: 1 << 20, MaxJSONBytes: 128}); err == nil {
		t.Fatal("expected decompression limit failure")
	}
}

func TestDecodeRejectsTooManyEntries(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "1", Text: "one"}, {ID: "2", Text: "two"}}
	blob, err := Encode(database, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	limits := DefaultLimits()
	limits.MaxEntries = 1
	if _, err := Decode(blob, "", limits); err == nil {
		t.Fatal("expected entry count limit failure")
	}
}

func TestDecodeRejectsDeepJSON(t *testing.T) {
	raw := append([]byte(`{"Version":1,"Entries":[],"DeletedEntries":[],"Future":`), bytes.Repeat([]byte("["), 101)...)
	raw = append(raw, '0')
	raw = append(raw, bytes.Repeat([]byte("]"), 101)...)
	raw = append(raw, '}')
	compressed, err := gzipBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	blob := append(append([]byte(nil), compressedMagic...), compressed...)
	if _, err := Decode(blob, "", DefaultLimits()); err == nil {
		t.Fatal("expected JSON depth failure")
	}
}

func TestDecodeRejectsInvalidUTF8(t *testing.T) {
	raw := []byte{'{', '"', 'x', '"', ':', '"', 0xff, '"', '}'}
	compressed, err := gzipBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	blob := append(append([]byte(nil), compressedMagic...), compressed...)
	if _, err := Decode(blob, "", DefaultLimits()); err == nil {
		t.Fatal("expected UTF-8 failure")
	}
}

func TestDecodeRejectsWrongKnownFieldType(t *testing.T) {
	raw := []byte(`{"Version":1,"Entries":[{"Id":"id","Text":42}],"DeletedEntries":[]}`)
	compressed, err := gzipBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	blob := append(append([]byte(nil), compressedMagic...), compressed...)
	if _, err := Decode(blob, "", DefaultLimits()); err == nil {
		t.Fatal("expected known-field type failure")
	}
}
