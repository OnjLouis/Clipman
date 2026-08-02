package clipdb

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
)

var windowsFixtures = map[string]string{
	"windows-compressed.clipdb": "Q0xJUERCMR+LCAAAAAAABAB9UUtOwzAQ3VfqHaysu0j4FdjyrUQAqQ0sKAsTT4QlZxyNbRGp6oE4AwtuwFW4Ap6ET0QRlixr3mfGevP+8roaj4RIboCctpgcimzSAUWjpAdVoG5zx/A07U8Wby85QU8amLzjWohV/0RqpiKapNnW9s7u3nT/QD6UCqrfdTL5Niyg9Ww5B2OsqMjW4lajsk9OvD0vaYlzKC0qYTTCwHYpa2BbpVsfaMickQ0NUx6cdwNibgOVkMvykVtFweec040WRwR/R5B+RdDJLqTzhfs3qk53rRGBc/EU4AeeuQXUjYmTIlVJ4wZcLjFIc0UKiPv2+Jqf+34Fx2AgfnFjE51kPFp/AN3aX47gAQAA",
	"windows-encrypted.clipdb":  "Q0xJUERCMgEdKYFI3cYzY08n2tjBA9z2r+pqdN6aI06BdVJy2bsHUzg2GRp3XK3t4kknl7FIqL8iy+bFjWh+g+NRO4U4NSeLlnwMo6HuxmTUxcWrHEYoUSja+h6dYITdrhDEw5cWmxN8TSC4C764HdIGxcseikMTVLe02faqiUvMjzLApV9rPJlfI28Yew5z7LaFJVMXJ9ctAfvdOVwZA4t9Of9LS0ITuRe5/NuUXiw53GHN6yHw5AWr6R3CJFSwn+9ZzWXUgkFGbt+rjYw5ieqd4CT7unfoqsWEHgjHmZGH+o/M8Lw/8mGkRIISWn+tVpfq3GcurDMFN+A7BzLBGlE290P8d8/oO+rvnpo3ljtqNJixPH5pZ5HunHv/NFkqNKeWqI8AKvfE7gr3R1QRpCK6Yn9OwWzTXXorx8k41r9jQbus4q3aweoCEON2Kt3tRsLsdt7YCsU=",
}

func windowsFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := base64.StdEncoding.DecodeString(windowsFixtures[name])
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestDecodeWindowsFixtures(t *testing.T) {
	for _, test := range []struct{ name, password string }{{"windows-compressed.clipdb", ""}, {"windows-encrypted.clipdb", "pässphrase"}} {
		data := windowsFixture(t, test.name)
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
	data := windowsFixture(t, "windows-encrypted.clipdb")
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

func TestFileHistoryRoundTripPreservesContractAndUnknownFields(t *testing.T) {
	raw := []byte(`{"Version":1,"UpdatedUnixMs":7,"FutureRoot":"keep","Events":[{"Id":"event1","CapturedUnixMs":6,"Source":"Files","Operation":"Copy","SourceMachine":"Fedora","ContainsText":true,"FileCount":2,"Files":["/tmp/one.txt","/tmp/two.txt"],"Formats":["text/uri-list"],"Pinned":true,"ManualOrder":3,"FutureEvent":42}]}`)
	var database model.FileDatabase
	if err := json.Unmarshal(raw, &database); err != nil {
		t.Fatal(err)
	}
	blob, err := EncodeFileHistory(database, "secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeFileHistory(blob, "secret", DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Events) != 1 || decoded.Events[0].Files[1] != "/tmp/two.txt" || !decoded.Events[0].Pinned {
		t.Fatalf("unexpected file history: %+v", decoded)
	}
	encoded, err := json.Marshal(decoded)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"FutureRoot":"keep"`)) || !bytes.Contains(encoded, []byte(`"FutureEvent":42`)) {
		t.Fatalf("unknown file-history fields lost: %s", encoded)
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

func TestEncodeRejectsJSONThatWouldExceedReadLimit(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "1", Text: string(bytes.Repeat([]byte("x"), 512))}}
	limits := DefaultLimits()
	limits.MaxJSONBytes = 128
	if _, err := encodeJSONWithLimits(database, "", nil, limits); err == nil {
		t.Fatal("encoder saved JSON larger than its read limit")
	}
}

func TestCodecBlobLimitCountsEntireCompressedBlob(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "1", Text: "one"}}
	blob, err := Encode(database, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	limits := DefaultLimits()
	limits.MaxBlobBytes = int64(len(blob))
	if _, err := encodeJSONWithLimits(database, "", nil, limits); err != nil {
		t.Fatalf("encoder rejected a blob exactly at the total limit: %v", err)
	}
	if _, err := Decode(blob, "", limits); err != nil {
		t.Fatalf("decoder rejected a blob exactly at the total limit: %v", err)
	}
	limits.MaxBlobBytes--
	if _, err := encodeJSONWithLimits(database, "", nil, limits); err == nil {
		t.Fatal("encoder ignored the magic header when enforcing the total blob limit")
	}
	if _, err := Decode(blob, "", limits); err == nil {
		t.Fatal("decoder ignored the magic header when enforcing the total blob limit")
	}
}

func TestEncodeRejectsEncryptedBlobLargerThanReadLimit(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "1", Text: "one"}}
	limits := DefaultLimits()
	limits.MaxBlobBytes = 64
	if _, err := encodeJSONWithLimits(database, "secret", nil, limits); err == nil {
		t.Fatal("encoder saved an encrypted blob larger than its read limit")
	}
}

func TestCodecHardLimitsCannotBeRaised(t *testing.T) {
	if DefaultMaxBlobBytes != 272<<20 || DefaultMaxJSONBytes != 256<<20 {
		t.Fatalf("unexpected client compatibility limits: blob=%d JSON=%d", DefaultMaxBlobBytes, DefaultMaxJSONBytes)
	}
	limits := normalizedLimits(Limits{
		MaxBlobBytes: DefaultMaxBlobBytes + 1,
		MaxJSONBytes: DefaultMaxJSONBytes + 1,
	})
	if limits.MaxBlobBytes != DefaultMaxBlobBytes || limits.MaxJSONBytes != DefaultMaxJSONBytes {
		t.Fatalf("hard codec limits were raised: %+v", limits)
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
