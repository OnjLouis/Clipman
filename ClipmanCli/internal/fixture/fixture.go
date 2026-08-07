// Package fixture loads the cross-client interoperability corpus under
// ClipmanCli/testdata/fixtures.
//
// Each subdirectory there holds the output of one client's generator — the
// blobs that client actually writes, plus what that client reads back out of
// them. A test that fails against this corpus is reporting a real cross-device
// sync break, not a style disagreement.
//
// Generators are discovered rather than listed, so adding a macOS, Android, or
// iOS directory brings it into every test without touching Go code.
package fixture

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// Identity is one token/password to bucket-ID vector.
type Identity struct {
	Name       string `json:"name"`
	Token      string `json:"token"`
	Password   string `json:"password"`
	DatabaseID string `json:"databaseId"`
}

// Database names one stored blob and the reading of it that its generator
// recorded.
type Database struct {
	Name      string `json:"name"`
	File      string `json:"file"`
	Expected  string `json:"expected"`
	Password  string `json:"password"`
	Container string `json:"container"`
}

// Manifest is one generator's corpus.
type Manifest struct {
	Version   int        `json:"version"`
	Generator string     `json:"generator"`
	Note      string     `json:"note"`
	Identity  []Identity `json:"identity"`
	Databases []Database `json:"databases"`

	// Dir is the directory the manifest was read from.
	Dir string `json:"-"`
}

// Entry is one entry as its generating client read it back.
type Entry struct {
	ID             string `json:"id"`
	Text           string `json:"text"`
	Name           string `json:"name"`
	Group          string `json:"group"`
	SourceMachine  string `json:"sourceMachine"`
	CreatedUnixMs  int64  `json:"createdUnixMs"`
	LastUsedUnixMs int64  `json:"lastUsedUnixMs"`
	Pinned         bool   `json:"pinned"`
	IsTemplate     bool   `json:"isTemplate"`
	ManualOrder    int64  `json:"manualOrder"`
	// HasRichText records whether the generating client saw a rich-text
	// payload. Clients without that field must preserve it regardless.
	HasRichText bool `json:"hasRichText"`
}

// Deleted is one tombstone as its generating client read it back.
type Deleted struct {
	ID            string `json:"id"`
	TextHash      string `json:"textHash"`
	DeletedUnixMs int64  `json:"deletedUnixMs"`
	SourceMachine string `json:"sourceMachine"`
}

// Expected is the reduced view a generator recorded for one blob. It is an
// assertion target rather than the wire format, so a client adding a field
// does not invalidate the corpus.
type Expected struct {
	Version       int       `json:"version"`
	UpdatedUnixMs int64     `json:"updatedUnixMs"`
	Entries       []Entry   `json:"entries"`
	Deleted       []Deleted `json:"deleted"`
}

// Root returns the fixtures directory, found by walking up to the module root.
func Root() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return filepath.Join(dir, "testdata", "fixtures"), nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("no go.mod found above the working directory")
		}
		dir = parent
	}
}

// All returns every generator's manifest, sorted by directory name. It is not
// an error for the corpus to be missing a client: the returned slice simply
// holds fewer manifests, and a test that needs a specific one asks for it by
// name with Load.
func All() ([]Manifest, error) {
	root, err := Root()
	if err != nil {
		return nil, err
	}
	items, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	names := make([]string, 0, len(items))
	for _, item := range items {
		if !item.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(root, item.Name(), "manifest.json")); err != nil {
			continue
		}
		names = append(names, item.Name())
	}
	sort.Strings(names)
	manifests := make([]Manifest, 0, len(names))
	for _, name := range names {
		manifest, err := Load(name)
		if err != nil {
			return nil, err
		}
		manifests = append(manifests, manifest)
	}
	return manifests, nil
}

// Load reads one generator's manifest by directory name, for example "windows".
func Load(generator string) (Manifest, error) {
	root, err := Root()
	if err != nil {
		return Manifest{}, err
	}
	dir := filepath.Join(root, generator)
	data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("%s manifest: %w", generator, err)
	}
	if manifest.Version != 1 {
		return Manifest{}, fmt.Errorf("%s manifest: unsupported version %d", generator, manifest.Version)
	}
	manifest.Dir = dir
	return manifest, nil
}

// Blob reads the stored bytes for one database.
func (m Manifest) Blob(database Database) ([]byte, error) {
	return os.ReadFile(filepath.Join(m.Dir, database.File))
}

// Expected reads the recorded reading for one database.
func (m Manifest) Expected(database Database) (Expected, error) {
	data, err := os.ReadFile(filepath.Join(m.Dir, database.Expected))
	if err != nil {
		return Expected{}, err
	}
	var expected Expected
	if err := json.Unmarshal(data, &expected); err != nil {
		return Expected{}, fmt.Errorf("%s: %w", database.Expected, err)
	}
	return expected, nil
}
