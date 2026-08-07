package clipdb_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/fixture"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func manifests(t *testing.T) []fixture.Manifest {
	t.Helper()
	loaded, err := fixture.All()
	if err != nil {
		t.Fatalf("loading the fixture corpus: %v", err)
	}
	if len(loaded) == 0 {
		t.Skip("no interoperability fixtures are present; see testdata/fixtures/README.md")
	}
	return loaded
}

// sameJSON compares two raw JSON values by meaning rather than by bytes.
// Preserving an unknown field does not oblige a client to reproduce another
// client's whitespace or key order; it obliges it not to lose or alter the
// value.
func sameJSON(t *testing.T, left, right []byte) bool {
	t.Helper()
	var leftValue, rightValue any
	if err := json.Unmarshal(left, &leftValue); err != nil {
		t.Fatalf("parsing the original value: %v", err)
	}
	if err := json.Unmarshal(right, &rightValue); err != nil {
		t.Fatalf("parsing the round-tripped value: %v", err)
	}
	return reflect.DeepEqual(leftValue, rightValue)
}

func sortedEntries(database model.Database) []model.Entry {
	entries := append([]model.Entry(nil), database.Entries...)
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	return entries
}

// TestDecodeEveryClientBlob is the core interoperability check: the CLI must
// read what every other client writes, byte for byte, including the text
// shapes most likely to be mangled by an encoding or line-ending bug.
func TestDecodeEveryClientBlob(t *testing.T) {
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			t.Run(manifest.Generator+"/"+database.Name, func(t *testing.T) {
				blob, err := manifest.Blob(database)
				if err != nil {
					t.Fatalf("reading blob: %v", err)
				}
				expected, err := manifest.Expected(database)
				if err != nil {
					t.Fatalf("reading expectation: %v", err)
				}
				decoded, err := clipdb.Decode(blob, database.Password, clipdb.DefaultLimits())
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				if decoded.Version != expected.Version {
					t.Errorf("version: got %d, want %d", decoded.Version, expected.Version)
				}
				if decoded.UpdatedUnixMs != expected.UpdatedUnixMs {
					t.Errorf("updatedUnixMs: got %d, want %d", decoded.UpdatedUnixMs, expected.UpdatedUnixMs)
				}
				entries := sortedEntries(decoded)
				if len(entries) != len(expected.Entries) {
					t.Fatalf("entry count: got %d, want %d", len(entries), len(expected.Entries))
				}
				for index, want := range expected.Entries {
					got := entries[index]
					if got.ID != want.ID {
						t.Errorf("entry %d id: got %q, want %q", index, got.ID, want.ID)
						continue
					}
					// Text is compared exactly. Every awkward case in the
					// corpus lives or dies on this one line.
					if got.Text != want.Text {
						t.Errorf("entry %s text: got %q, want %q", want.ID, got.Text, want.Text)
					}
					if got.Name != want.Name {
						t.Errorf("entry %s name: got %q, want %q", want.ID, got.Name, want.Name)
					}
					if got.Group != want.Group {
						t.Errorf("entry %s group: got %q, want %q", want.ID, got.Group, want.Group)
					}
					if got.SourceMachine != want.SourceMachine {
						t.Errorf("entry %s sourceMachine: got %q, want %q", want.ID, got.SourceMachine, want.SourceMachine)
					}
					if got.CreatedUnixMs != want.CreatedUnixMs {
						t.Errorf("entry %s createdUnixMs: got %d, want %d", want.ID, got.CreatedUnixMs, want.CreatedUnixMs)
					}
					if got.LastUsedUnixMs != want.LastUsedUnixMs {
						t.Errorf("entry %s lastUsedUnixMs: got %d, want %d", want.ID, got.LastUsedUnixMs, want.LastUsedUnixMs)
					}
					if got.Pinned != want.Pinned {
						t.Errorf("entry %s pinned: got %v, want %v", want.ID, got.Pinned, want.Pinned)
					}
					if got.IsTemplate != want.IsTemplate {
						t.Errorf("entry %s isTemplate: got %v, want %v", want.ID, got.IsTemplate, want.IsTemplate)
					}
					if got.ManualOrder != want.ManualOrder {
						t.Errorf("entry %s manualOrder: got %d, want %d", want.ID, got.ManualOrder, want.ManualOrder)
					}
				}
				deleted := append([]model.DeletedEntry(nil), decoded.Deleted...)
				sort.Slice(deleted, func(i, j int) bool { return deleted[i].ID < deleted[j].ID })
				if len(deleted) != len(expected.Deleted) {
					t.Fatalf("tombstone count: got %d, want %d", len(deleted), len(expected.Deleted))
				}
				for index, want := range expected.Deleted {
					got := deleted[index]
					if got.ID != want.ID || got.TextHash != want.TextHash ||
						got.DeletedUnixMs != want.DeletedUnixMs || got.SourceMachine != want.SourceMachine {
						t.Errorf("tombstone %d: got %+v, want %+v", index, got, want)
					}
				}
			})
		}
	}
}

// TestContainerMagicMatchesTheManifest checks the blobs really are the
// container the manifest claims, so a generator that quietly stopped
// encrypting would be caught rather than silently reducing coverage.
func TestContainerMagicMatchesTheManifest(t *testing.T) {
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			t.Run(manifest.Generator+"/"+database.Name, func(t *testing.T) {
				blob, err := manifest.Blob(database)
				if err != nil {
					t.Fatalf("reading blob: %v", err)
				}
				if !bytes.HasPrefix(blob, []byte(database.Container)) {
					t.Fatalf("blob does not begin with %s", database.Container)
				}
				if database.Container == "CLIPDB2" {
					if database.Password == "" {
						t.Fatal("an encrypted fixture must carry its password")
					}
					// Version byte, 16-byte salt, 16-byte IV, at least one AES
					// block, and a 32-byte MAC.
					if len(blob) < 88 {
						t.Fatalf("encrypted blob is too short: %d bytes", len(blob))
					}
					if blob[7] != 1 {
						t.Fatalf("unexpected container version byte %d", blob[7])
					}
				}
			})
		}
	}
}

// TestWrongPasswordIsRejected proves authentication happens before anything
// else, and that the failure does not distinguish a wrong password from
// damaged data.
func TestWrongPasswordIsRejected(t *testing.T) {
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			if database.Container != "CLIPDB2" {
				continue
			}
			t.Run(manifest.Generator+"/"+database.Name, func(t *testing.T) {
				blob, err := manifest.Blob(database)
				if err != nil {
					t.Fatalf("reading blob: %v", err)
				}
				if _, err := clipdb.Decode(blob, database.Password+"-wrong", clipdb.DefaultLimits()); err == nil {
					t.Fatal("a wrong password must not decode the database")
				}
				if _, err := clipdb.Decode(blob, "", clipdb.DefaultLimits()); err == nil {
					t.Fatal("an empty password must not decode an encrypted database")
				}
			})
		}
	}
}

// TestTamperedBlobIsRejected flips one byte of ciphertext and requires the MAC
// to catch it, so unauthenticated bytes never reach AES or gzip.
func TestTamperedBlobIsRejected(t *testing.T) {
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			if database.Container != "CLIPDB2" {
				continue
			}
			t.Run(manifest.Generator+"/"+database.Name, func(t *testing.T) {
				blob, err := manifest.Blob(database)
				if err != nil {
					t.Fatalf("reading blob: %v", err)
				}
				tampered := append([]byte(nil), blob...)
				// One byte inside the ciphertext, past the header, salt and IV.
				tampered[45] ^= 0x01
				if _, err := clipdb.Decode(tampered, database.Password, clipdb.DefaultLimits()); err == nil {
					t.Fatal("a modified ciphertext must not decode")
				}
			})
		}
	}
}

// TestUnknownFieldsSurviveARoundTrip is the forward-compatibility guarantee.
// The CLI has no rich-text field, so decoding and re-encoding a Windows blob
// must not destroy one.
func TestUnknownFieldsSurviveARoundTrip(t *testing.T) {
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			expected, err := manifest.Expected(database)
			if err != nil {
				t.Fatalf("reading expectation: %v", err)
			}
			carriesRichText := false
			for _, entry := range expected.Entries {
				if entry.HasRichText {
					carriesRichText = true
					break
				}
			}
			if !carriesRichText {
				continue
			}
			t.Run(manifest.Generator+"/"+database.Name, func(t *testing.T) {
				blob, err := manifest.Blob(database)
				if err != nil {
					t.Fatalf("reading blob: %v", err)
				}
				decoded, err := clipdb.Decode(blob, database.Password, clipdb.DefaultLimits())
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				found := false
				for _, entry := range decoded.Entries {
					if _, ok := entry.Extra["RichText"]; ok {
						found = true
					}
				}
				if !found {
					t.Fatal("the rich-text field was dropped on decode")
				}
				reencoded, err := clipdb.Encode(decoded, database.Password, blob)
				if err != nil {
					t.Fatalf("encode: %v", err)
				}
				again, err := clipdb.Decode(reencoded, database.Password, clipdb.DefaultLimits())
				if err != nil {
					t.Fatalf("decoding our own output: %v", err)
				}
				for _, want := range decoded.Entries {
					var got *model.Entry
					for index := range again.Entries {
						if again.Entries[index].ID == want.ID {
							got = &again.Entries[index]
							break
						}
					}
					if got == nil {
						t.Fatalf("entry %s vanished across a round trip", want.ID)
					}
					wantRich, hadRich := want.Extra["RichText"]
					gotRich, keptRich := got.Extra["RichText"]
					if hadRich != keptRich {
						t.Fatalf("entry %s: rich text present=%v before, %v after", want.ID, hadRich, keptRich)
					}
					if hadRich && !sameJSON(t, wantRich, gotRich) {
						t.Fatalf("entry %s: rich text changed\n before %s\n after  %s", want.ID, wantRich, gotRich)
					}
				}
			})
		}
	}
}

// TestOurOwnOutputIsReadableAgain round-trips every fixture through the CLI
// encoder. It cannot prove another client reads our output — the C# verifier
// in tools/ClipmanFixtures does that — but it catches an encoder that only
// produces blobs its own decoder tolerates.
func TestOurOwnOutputIsReadableAgain(t *testing.T) {
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			t.Run(manifest.Generator+"/"+database.Name, func(t *testing.T) {
				blob, err := manifest.Blob(database)
				if err != nil {
					t.Fatalf("reading blob: %v", err)
				}
				decoded, err := clipdb.Decode(blob, database.Password, clipdb.DefaultLimits())
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				reencoded, err := clipdb.Encode(decoded, database.Password, blob)
				if err != nil {
					t.Fatalf("encode: %v", err)
				}
				again, err := clipdb.Decode(reencoded, database.Password, clipdb.DefaultLimits())
				if err != nil {
					t.Fatalf("decoding our own output: %v", err)
				}
				before, after := sortedEntries(decoded), sortedEntries(again)
				if len(before) != len(after) {
					t.Fatalf("entry count changed: %d then %d", len(before), len(after))
				}
				for index := range before {
					if before[index].ID != after[index].ID || before[index].Text != after[index].Text {
						t.Fatalf("entry %d changed across a round trip", index)
					}
				}
			})
		}
	}
}

// TestExportOurBlobsForCrossClientVerification writes the CLI's own encoding of
// every fixture so the C# verifier can read them back:
//
//	go test ./internal/clipdb/ -run TestExport -clipman-export=<dir>
//	.\tools\ClipmanFixtures\Build-Fixtures.ps1 -Verify <dir>
//
// Without the flag it does nothing, so an ordinary test run is unaffected.
func TestExportOurBlobsForCrossClientVerification(t *testing.T) {
	if exportDir == "" {
		t.Skip("pass -clipman-export=<dir> to write blobs for the C# verifier")
	}
	if err := os.MkdirAll(exportDir, 0o700); err != nil {
		t.Fatalf("creating the export directory: %v", err)
	}
	for _, manifest := range manifests(t) {
		for _, database := range manifest.Databases {
			blob, err := manifest.Blob(database)
			if err != nil {
				t.Fatalf("reading blob: %v", err)
			}
			decoded, err := clipdb.Decode(blob, database.Password, clipdb.DefaultLimits())
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			// A fresh salt rather than the source blob's, so the exported file
			// exercises the encoder's own key derivation.
			reencoded, err := clipdb.Encode(decoded, database.Password, nil)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			name := strings.ReplaceAll(manifest.Generator, "/", "-") + "-" + database.Name
			if err := os.WriteFile(filepath.Join(exportDir, name+".clipdb"), reencoded, 0o600); err != nil {
				t.Fatalf("writing blob: %v", err)
			}
			if database.Password != "" {
				if err := os.WriteFile(filepath.Join(exportDir, name+".password"), []byte(database.Password), 0o600); err != nil {
					t.Fatalf("writing password: %v", err)
				}
			}
		}
	}
	t.Logf("wrote CLI-encoded blobs to %s; verify with tools\\ClipmanFixtures\\Build-Fixtures.ps1 -Verify", exportDir)
}
