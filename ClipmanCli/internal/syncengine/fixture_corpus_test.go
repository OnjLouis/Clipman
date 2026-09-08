package syncengine

// The sync-rules interoperability corpus (Task 6.1 of the sync rules plan):
// this file both regenerates the go-reference fixture set under
// testdata/fixtures/go/ and verifies, on every ordinary test run, that the
// engine assembles the corpus blobs into exactly the view the manifest
// promises. Other clients decode the same blobs with their own ports and
// assert the same expected-view.json, so a port that stops agreeing with the
// reference fails loudly instead of silently splitting devices.
//
// Regenerate with:
//
//	go test ./internal/syncengine -run TestRegenerateSyncRulesFixtures -regenerate-sync-rules-fixtures
//
// The blobs use a fresh IV per encode, so regenerated files differ in bytes
// while carrying identical content; commit them only when the content
// deliberately changed. All timestamps in the fixture data are fixed so the
// decoded content never depends on the wall clock. The set deliberately
// carries no tombstones: the 90-day tombstone retention window would make any
// fixed-timestamp tombstone age out of the view and turn the expectation
// time-dependent.

import (
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/fixture"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/rules"
)

var regenerateSyncRulesFixtures = flag.Bool(
	"regenerate-sync-rules-fixtures",
	false,
	"rewrite testdata/fixtures/go/ from the Go reference implementation",
)

// The published cross-client vectors from sync-rules-spec.md section 2. The
// generator asserts its own derivations against these constants, so a drift
// in the identity code cannot be silently baked into a regenerated corpus.
const (
	fixtureSpecDatabaseID       = "l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU"
	fixtureSpecSyncRulesID      = "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ"
	fixtureSpecWorkChannelID    = "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
	fixtureSpecImagesChannelID  = "K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ"
	fixtureSpecDesktopChannelID = "02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o"
)

const fixtureBaseUnixMs = int64(1757200000000)

// syncRulesFixtureDocument is the exact example document of
// sync-rules-spec.md section 4.
func syncRulesFixtureDocument() *rules.Document {
	return &rules.Document{
		Clipman:       "sync-rules",
		Version:       1,
		Enabled:       true,
		UpdatedUnixMs: fixtureBaseUnixMs,
		UpdatedBy:     "Desktop",
		Channels: []rules.Channel{
			{Name: "Images", Route: rules.Route{Kind: "RichTextImages"}},
			{Name: "Work", Route: rules.Route{Groups: []string{"Work", "Standup"}}},
			{Name: "Desktop only", Route: rules.Route{SourceDevices: []string{"Desktop", "Work-PC"}}},
		},
		Devices: []rules.Device{
			{Name: "Desktop", Channels: []string{"*"}},
			{Name: "Jeff-iPhone", Channels: []string{"work"}},
			{Name: "Work-PC", Channels: []string{"work", "desktop only"}},
		},
	}
}

func fixtureEntry(id, text, group, source string, stamp, order int64) model.Entry {
	return model.Entry{
		ID:             id,
		Text:           text,
		Group:          group,
		SourceMachine:  source,
		CreatedUnixMs:  stamp,
		LastUsedUnixMs: stamp,
		ModifiedUnixMs: stamp,
		ManualOrder:    order,
		Extra:          map[string]json.RawMessage{},
	}
}

// syncRulesFixtureDatabases builds the channel contents. Every entry is
// resident exactly where the document's routes place it, so no client sees a
// misrouted entry to migrate. Manual orders are dense per channel - what any
// client's own normalization would have persisted - and the view expectation
// below carries the renumbering that assembly then applies.
func syncRulesFixtureDatabases() (core, work, images model.Database) {
	core = model.NewDatabase(fixtureBaseUnixMs)
	core.Entries = []model.Entry{
		fixtureEntry("core-plain", "Core grocery list", "Personal", "Jeff-iPhone", fixtureBaseUnixMs+100, 1),
		fixtureEntry("core-unmatched", "Loose note", "", "Jeff-iPhone", fixtureBaseUnixMs+200, 2),
	}

	work = model.NewDatabase(fixtureBaseUnixMs)
	work.Entries = []model.Entry{
		fixtureEntry("work-standup", "Standup notes", "Standup", "Jeff-iPhone", fixtureBaseUnixMs+300, 1),
		fixtureEntry("work-plan", "Quarterly plan", "Work", "Desktop", fixtureBaseUnixMs+400, 2),
	}

	images = model.NewDatabase(fixtureBaseUnixMs)
	screenshot := fixtureEntry("images-screenshot", "Screenshot", "", "Desktop", fixtureBaseUnixMs+500, 1)
	screenshot.Extra["RichText"] = json.RawMessage(`{"Version":1,"HtmlFragment":"<img src=\"data:image/png;base64,AAAA\">"}`)
	images.Entries = []model.Entry{screenshot}
	return core, work, images
}

// syncRulesFixtureExpectedView is what device Jeff-iPhone, subscribed to the
// work channel only, must see: the core and work entries and nothing from
// images. It is authored here from the spec's semantics rather than captured
// from engine output, so the verifier below compares the engine against the
// contract, not against itself. Entries are listed sorted by id, matching how
// every consumer sorts before comparing. Manual orders are the view
// renumbering: same-order entries across channels interleave by
// CreatedUnixMs, so the sequence is core-plain, work-standup, core-unmatched,
// work-plan.
func syncRulesFixtureExpectedView() fixture.Expected {
	return fixture.Expected{
		Version:       1,
		UpdatedUnixMs: fixtureBaseUnixMs,
		Entries: []fixture.Entry{
			{ID: "core-plain", Text: "Core grocery list", Group: "Personal", SourceMachine: "Jeff-iPhone", CreatedUnixMs: fixtureBaseUnixMs + 100, LastUsedUnixMs: fixtureBaseUnixMs + 100, ManualOrder: 1},
			{ID: "core-unmatched", Text: "Loose note", SourceMachine: "Jeff-iPhone", CreatedUnixMs: fixtureBaseUnixMs + 200, LastUsedUnixMs: fixtureBaseUnixMs + 200, ManualOrder: 3},
			{ID: "work-plan", Text: "Quarterly plan", Group: "Work", SourceMachine: "Desktop", CreatedUnixMs: fixtureBaseUnixMs + 400, LastUsedUnixMs: fixtureBaseUnixMs + 400, ManualOrder: 4},
			{ID: "work-standup", Text: "Standup notes", Group: "Standup", SourceMachine: "Jeff-iPhone", CreatedUnixMs: fixtureBaseUnixMs + 300, LastUsedUnixMs: fixtureBaseUnixMs + 300, ManualOrder: 2},
		},
		Deleted: []fixture.Deleted{},
	}
}

// perChannelExpected records what each stored blob decodes to on its own, so
// the ordinary TestDecodeEveryClientBlob corpus sweep covers these blobs too.
func perChannelExpected(database model.Database) fixture.Expected {
	entries := append([]model.Entry(nil), database.Entries...)
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	expected := fixture.Expected{
		Version:       database.Version,
		UpdatedUnixMs: database.UpdatedUnixMs,
		Entries:       []fixture.Entry{},
		Deleted:       []fixture.Deleted{},
	}
	for _, entry := range entries {
		_, hasRichText := entry.Extra["RichText"]
		expected.Entries = append(expected.Entries, fixture.Entry{
			ID:             entry.ID,
			Text:           entry.Text,
			Name:           entry.Name,
			Group:          entry.Group,
			SourceMachine:  entry.SourceMachine,
			CreatedUnixMs:  entry.CreatedUnixMs,
			LastUsedUnixMs: entry.LastUsedUnixMs,
			Pinned:         entry.Pinned,
			IsTemplate:     entry.IsTemplate,
			ManualOrder:    entry.ManualOrder,
			HasRichText:    hasRichText,
		})
	}
	return expected
}

func writeFixtureJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestRegenerateSyncRulesFixtures rewrites testdata/fixtures/go/ using the Go
// reference implementation's own codec and identity code. Without the flag it
// does nothing, so ordinary test runs never touch the corpus.
func TestRegenerateSyncRulesFixtures(t *testing.T) {
	if !*regenerateSyncRulesFixtures {
		t.Skip("pass -regenerate-sync-rules-fixtures to rewrite testdata/fixtures/go/")
	}

	derivations := map[string]string{
		fixtureSpecDatabaseID:       identity.DatabaseID(channelTestToken, channelTestPassword),
		fixtureSpecSyncRulesID:      identity.SyncRulesDatabaseID(channelTestToken, channelTestPassword),
		fixtureSpecWorkChannelID:    identity.ChannelDatabaseID(channelTestToken, channelTestPassword, "work"),
		fixtureSpecImagesChannelID:  identity.ChannelDatabaseID(channelTestToken, channelTestPassword, "images"),
		fixtureSpecDesktopChannelID: identity.ChannelDatabaseID(channelTestToken, channelTestPassword, "desktop only"),
	}
	for want, got := range derivations {
		if got != want {
			t.Fatalf("identity derivation drifted from sync-rules-spec.md: got %q, want %q", got, want)
		}
	}

	root, err := fixture.Root()
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "go")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}

	core, work, images := syncRulesFixtureDatabases()

	// The core blob is written first and every other blob copies its salt,
	// exactly as production channel creation does (spec section 5, salt
	// sharing), so one PBKDF2 derivation opens the whole set.
	coreBlob, err := clipdb.Encode(core, channelTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, salt, err := clipdb.DecodeRaw(coreBlob, channelTestPassword)
	if err != nil {
		t.Fatal(err)
	}
	saltedEncode := func(database model.Database) []byte {
		blob, encodeErr := clipdb.Encode(database, channelTestPassword, coreBlob)
		if encodeErr != nil {
			t.Fatal(encodeErr)
		}
		return blob
	}
	workBlob := saltedEncode(work)
	imagesBlob := saltedEncode(images)

	payload, err := rules.Serialize(syncRulesFixtureDocument())
	if err != nil {
		t.Fatal(err)
	}
	rulesBlob, err := clipdb.EncodeRaw(payload, channelTestPassword, salt)
	if err != nil {
		t.Fatal(err)
	}

	files := map[string][]byte{
		"core.clipdb":           coreBlob,
		"channel-work.clipdb":   workBlob,
		"channel-images.clipdb": imagesBlob,
		"sync-rules.clipdb":     rulesBlob,
	}
	for name, blob := range files {
		if err := os.WriteFile(filepath.Join(dir, name), blob, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	writeFixtureJSON(t, filepath.Join(dir, "expected-view.json"), syncRulesFixtureExpectedView())
	writeFixtureJSON(t, filepath.Join(dir, "core.expected.json"), perChannelExpected(core))
	writeFixtureJSON(t, filepath.Join(dir, "channel-work.expected.json"), perChannelExpected(work))
	writeFixtureJSON(t, filepath.Join(dir, "channel-images.expected.json"), perChannelExpected(images))

	manifest := fixture.Manifest{
		Version:   1,
		Generator: "go-reference",
		Note: "Generated by TestRegenerateSyncRulesFixtures in ClipmanCli/internal/syncengine/fixture_corpus_test.go " +
			"against the Go reference implementation of sync-rules-spec.md. Do not hand-edit; regenerate with " +
			"go test ./internal/syncengine -run TestRegenerateSyncRulesFixtures -regenerate-sync-rules-fixtures",
		Identity: []fixture.Identity{
			{Name: "spec-example-database", Token: channelTestToken, Password: channelTestPassword, DatabaseID: fixtureSpecDatabaseID},
			{Name: "spec-example-sync-rules", Token: channelTestToken, Password: channelTestPassword, Kind: "sync-rules", DatabaseID: fixtureSpecSyncRulesID},
			{Name: "spec-example-channel-work", Token: channelTestToken, Password: channelTestPassword, Kind: "channel", ChannelKey: "work", DatabaseID: fixtureSpecWorkChannelID},
			{Name: "spec-example-channel-images", Token: channelTestToken, Password: channelTestPassword, Kind: "channel", ChannelKey: "images", DatabaseID: fixtureSpecImagesChannelID},
			{Name: "spec-example-channel-desktop-only", Token: channelTestToken, Password: channelTestPassword, Kind: "channel", ChannelKey: "desktop only", DatabaseID: fixtureSpecDesktopChannelID},
		},
		Databases: []fixture.Database{
			{Name: "sync-rules-core", File: "core.clipdb", Expected: "core.expected.json", Password: channelTestPassword, Container: "CLIPDB2"},
			{Name: "sync-rules-channel-work", File: "channel-work.clipdb", Expected: "channel-work.expected.json", Password: channelTestPassword, Container: "CLIPDB2"},
			{Name: "sync-rules-channel-images", File: "channel-images.clipdb", Expected: "channel-images.expected.json", Password: channelTestPassword, Container: "CLIPDB2"},
		},
		SyncRules: &fixture.SyncRules{
			Token:           channelTestToken,
			Password:        channelTestPassword,
			Device:          "Jeff-iPhone",
			RulesFile:       "sync-rules.clipdb",
			RulesDatabaseID: fixtureSpecSyncRulesID,
			Channels: []fixture.SyncRulesChannel{
				{Key: "", File: "core.clipdb", DatabaseID: fixtureSpecDatabaseID},
				{Key: "work", File: "channel-work.clipdb", DatabaseID: fixtureSpecWorkChannelID},
				{Key: "images", File: "channel-images.clipdb", DatabaseID: fixtureSpecImagesChannelID},
			},
			ExpectedView: "expected-view.json",
		},
	}
	writeFixtureJSON(t, filepath.Join(dir, "manifest.json"), manifest)
	t.Logf("wrote the go-reference sync-rules fixture set to %s", dir)
}

// TestSyncRulesFixtureViewMatchesTheContract loads every corpus that carries
// a sync-rules set into the fake server, runs the real engine as the set's
// device, and compares the assembled view to expected-view.json. It also
// proves the unsubscribed channel's bucket is never downloaded.
func TestSyncRulesFixtureViewMatchesTheContract(t *testing.T) {
	manifests, err := fixture.All()
	if err != nil {
		t.Fatalf("loading the fixture corpus: %v", err)
	}
	found := false
	for _, manifest := range manifests {
		set := manifest.SyncRules
		if set == nil {
			continue
		}
		found = true
		t.Run(manifest.Generator, func(t *testing.T) {
			if set.Token != channelTestToken || set.Password != channelTestPassword {
				t.Fatalf("the sync-rules set uses credentials %q/%q; this harness serves the spec example credentials only",
					set.Token, set.Password)
			}
			fake, engine := newChannelEngine(t)

			rulesBlob, err := manifest.ReadFile(set.RulesFile)
			if err != nil {
				t.Fatalf("reading rules blob: %v", err)
			}
			if got := identity.SyncRulesDatabaseID(set.Token, set.Password); got != set.RulesDatabaseID {
				t.Fatalf("rules bucket id mismatch: derived %q, manifest %q", got, set.RulesDatabaseID)
			}
			fake.storeBlob(set.RulesDatabaseID, rulesBlob)

			for _, channel := range set.Channels {
				blob, err := manifest.ReadFile(channel.File)
				if err != nil {
					t.Fatalf("reading channel %q blob: %v", channel.Key, err)
				}
				derived := identity.DatabaseID(set.Token, set.Password)
				if channel.Key != "" {
					derived = identity.ChannelDatabaseID(set.Token, set.Password, channel.Key)
				}
				if derived != channel.DatabaseID {
					t.Fatalf("channel %q bucket id mismatch: derived %q, manifest %q", channel.Key, derived, channel.DatabaseID)
				}
				fake.storeBlob(channel.DatabaseID, blob)
			}

			view, err := engine.ReadView(context.Background(), set.Device)
			if err != nil {
				t.Fatalf("ReadView: %v", err)
			}
			expected, err := manifest.SyncRulesExpectedView()
			if err != nil {
				t.Fatalf("reading expected view: %v", err)
			}

			entries := append([]model.Entry(nil), view.View.Entries...)
			sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
			if len(entries) != len(expected.Entries) {
				got := make([]string, 0, len(entries))
				for _, entry := range entries {
					got = append(got, entry.ID)
				}
				t.Fatalf("view entry count: got %d %v, want %d", len(entries), got, len(expected.Entries))
			}
			for index, want := range expected.Entries {
				got := entries[index]
				_, hasRichText := got.Extra["RichText"]
				if got.ID != want.ID || got.Text != want.Text || got.Name != want.Name ||
					got.Group != want.Group || got.SourceMachine != want.SourceMachine ||
					got.CreatedUnixMs != want.CreatedUnixMs || got.LastUsedUnixMs != want.LastUsedUnixMs ||
					got.Pinned != want.Pinned || got.IsTemplate != want.IsTemplate ||
					got.ManualOrder != want.ManualOrder || hasRichText != want.HasRichText {
					t.Errorf("view entry %s: got %+v (hasRichText %v), want %+v", want.ID, got, hasRichText, want)
				}
			}
			if len(view.View.Deleted) != len(expected.Deleted) {
				t.Errorf("view tombstone count: got %d, want %d", len(view.View.Deleted), len(expected.Deleted))
			}

			// The device subscribes to a subset; a channel outside it must
			// never be fetched (spec section 5, download step 2).
			subscribed := map[string]bool{"": true}
			for _, key := range rules.SubscribedChannels(view.Rules, set.Device) {
				subscribed[key] = true
			}
			for _, channel := range set.Channels {
				if subscribed[channel.Key] {
					continue
				}
				if fake.count("GET", channel.DatabaseID) != 0 {
					t.Errorf("unsubscribed channel %q was downloaded", channel.Key)
				}
			}
		})
	}
	if !found {
		t.Skip("no sync-rules fixture set is present; see testdata/fixtures/README.md")
	}
}
