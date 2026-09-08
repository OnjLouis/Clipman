package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/rules"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
)

// The cross-client test vectors from sync-rules-spec.md section 2 keep the
// derived bucket ids in these tests aligned with the published ones.
const rulesCliToken = "example-token"
const rulesCliPassword = "example-password"
const rulesCliMachine = "Laptop"

func rulesCoreBucketID() string { return identity.DatabaseID(rulesCliToken, rulesCliPassword) }
func rulesBucketIDForTest() string {
	return identity.SyncRulesDatabaseID(rulesCliToken, rulesCliPassword)
}
func rulesChannelBucketID(key string) string {
	return identity.ChannelDatabaseID(rulesCliToken, rulesCliPassword, key)
}

type fakeBucket struct {
	blob     []byte
	revision string
}

// swapSpec is a one-shot content swap armed on a bucket: after `remaining`
// more GETs are served from its current content, it is replaced with blob
// under a fresh revision. This is how tests simulate another device
// concurrently editing a document between two reads of it.
type swapSpec struct {
	remaining int
	blob      []byte
}

// fakeMultiServer is a multi-bucket stand-in for Clipman Server: GET/PUT
// /api/v1/database/{id} for any number of database ids, enforcing the
// If-Match/If-None-Match preconditions the engine and the rules commands
// both rely on.
type fakeMultiServer struct {
	lock     sync.Mutex
	buckets  map[string]*fakeBucket
	requests []string
	created  map[string]bool
	broken   map[string]bool
	swaps    map[string]*swapSpec
	sequence int
}

func newFakeMultiServer() *fakeMultiServer {
	return &fakeMultiServer{
		buckets: map[string]*fakeBucket{},
		created: map[string]bool{},
		broken:  map[string]bool{},
		swaps:   map[string]*swapSpec{},
	}
}

// swapAfterGets arms a one-shot content swap on bucket id: the `count`-th GET
// still returns whatever is currently stored, and the swap happens right
// after, so the very next GET (and every one after) sees blob instead.
func (s *fakeMultiServer) swapAfterGets(id string, count int, blob []byte) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.swaps[id] = &swapSpec{remaining: count, blob: blob}
}

func (s *fakeMultiServer) breakBucket(id string) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.broken[id] = true
}

func (s *fakeMultiServer) unbreakBucket(id string) {
	s.lock.Lock()
	defer s.lock.Unlock()
	delete(s.broken, id)
}

func (s *fakeMultiServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	id, err := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/api/v1/database/"))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	s.lock.Lock()
	defer s.lock.Unlock()
	s.requests = append(s.requests, r.Method+" "+id)
	switch r.Method {
	case http.MethodGet:
		bucket := s.buckets[id]
		if bucket == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("X-Clipman-Revision", bucket.revision)
		_, _ = w.Write(bucket.blob)
		if spec, ok := s.swaps[id]; ok {
			spec.remaining--
			if spec.remaining <= 0 {
				s.sequence++
				s.buckets[id] = &fakeBucket{blob: spec.blob, revision: fmt.Sprintf("revision-%d", s.sequence)}
				delete(s.swaps, id)
			}
		}
	case http.MethodPut:
		data, readErr := io.ReadAll(r.Body)
		if readErr != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if s.broken[id] {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		existing := s.buckets[id]
		if r.Header.Get("If-None-Match") == "*" {
			if existing != nil {
				w.WriteHeader(http.StatusPreconditionFailed)
				return
			}
			s.created[id] = true
		} else if existing != nil {
			if strings.Trim(r.Header.Get("If-Match"), "\"") != existing.revision {
				w.WriteHeader(http.StatusPreconditionFailed)
				return
			}
		}
		s.sequence++
		revision := fmt.Sprintf("revision-%d", s.sequence)
		s.buckets[id] = &fakeBucket{blob: data, revision: revision}
		w.Header().Set("X-Clipman-Revision", revision)
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *fakeMultiServer) storeBlob(id string, blob []byte) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.sequence++
	s.buckets[id] = &fakeBucket{blob: blob, revision: fmt.Sprintf("revision-%d", s.sequence)}
}

func (s *fakeMultiServer) storeDatabase(t *testing.T, id string, database model.Database) {
	t.Helper()
	blob, err := clipdb.Encode(database, rulesCliPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.storeBlob(id, blob)
}

func (s *fakeMultiServer) storeRules(t *testing.T, doc *rules.Document) {
	t.Helper()
	payload, err := rules.Serialize(doc)
	if err != nil {
		t.Fatal(err)
	}
	blob, err := clipdb.EncodeRaw(payload, rulesCliPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.storeBlob(rulesBucketIDForTest(), blob)
}

func (s *fakeMultiServer) blob(id string) []byte {
	s.lock.Lock()
	defer s.lock.Unlock()
	bucket := s.buckets[id]
	if bucket == nil {
		return nil
	}
	return append([]byte(nil), bucket.blob...)
}

func (s *fakeMultiServer) database(t *testing.T, id string) model.Database {
	t.Helper()
	blob := s.blob(id)
	if blob == nil {
		t.Fatalf("bucket %q does not exist", id)
	}
	database, err := clipdb.Decode(blob, rulesCliPassword, clipdb.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	return database
}

func (s *fakeMultiServer) rulesDoc(t *testing.T) *rules.Document {
	t.Helper()
	blob := s.blob(rulesBucketIDForTest())
	if blob == nil {
		t.Fatal("rules bucket does not exist")
	}
	payload, _, err := clipdb.DecodeRaw(blob, rulesCliPassword)
	if err != nil {
		t.Fatal(err)
	}
	doc, err := rules.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	return doc
}

func (s *fakeMultiServer) count(method, id string) int {
	s.lock.Lock()
	defer s.lock.Unlock()
	total := 0
	for _, entry := range s.requests {
		if entry == method+" "+id {
			total++
		}
	}
	return total
}

func (s *fakeMultiServer) exists(id string) bool {
	s.lock.Lock()
	defer s.lock.Unlock()
	return s.buckets[id] != nil
}

// newRulesTestContext builds an appContext wired to a fresh fakeMultiServer,
// with its configPath pointed at a temp directory so the rules cache and
// pending-writes store land somewhere real but disposable.
func newRulesTestContext(t *testing.T) (*fakeMultiServer, *appContext) {
	t.Helper()
	fake := newFakeMultiServer()
	testServer := httptest.NewServer(fake)
	t.Cleanup(testServer.Close)
	client, err := server.New(testServer.URL, rulesCliToken, rulesCoreBucketID(), "test")
	if err != nil {
		t.Fatal(err)
	}
	client.HTTP = testServer.Client()

	dir := t.TempDir()
	cfg := config.Default()
	cfg.Machine = rulesCliMachine

	engine := &syncengine.Engine{
		Client:   client,
		Password: rulesCliPassword,
		Limits:   clipdb.DefaultLimits(),
		Retries:  2,
		Token:    rulesCliToken,
	}
	ctx := &appContext{
		globals:    globals{quiet: true},
		configPath: filepath.Join(dir, "config.toml"),
		config:     cfg,
		token:      rulesCliToken,
		password:   rulesCliPassword,
		databaseID: rulesCoreBucketID(),
		client:     client,
		engine:     engine,
	}
	return fake, ctx
}

func testHistoryEntry(id, text, group string, stamp int64) model.Entry {
	return model.Entry{
		ID: id, Text: text, Group: group,
		CreatedUnixMs: stamp, LastUsedUnixMs: stamp, ModifiedUnixMs: stamp,
		Extra: map[string]json.RawMessage{},
	}
}

// imageEntryForTest carries the rich text the RichTextImages route matches.
func imageEntryForTest(id, text string, stamp int64) model.Entry {
	entry := testHistoryEntry(id, text, "", stamp)
	entry.Extra["RichText"] = json.RawMessage(`{"HtmlFragment":"<img src=\"data:image/png;base64,AAAA\">"}`)
	return entry
}

func historyDatabaseWith(entries ...model.Entry) model.Database {
	database := model.NewDatabase(1000)
	database.Entries = append(database.Entries, entries...)
	return database
}

func rulesHasEntry(database model.Database, id string) bool {
	for _, entry := range database.Entries {
		if entry.ID == id {
			return true
		}
	}
	return false
}

func TestRulesShowDisabled(t *testing.T) {
	_, ctx := newRulesTestContext(t)
	output := captureStdout(t, func() {
		if err := runRules(ctx, []string{"show"}); err != nil {
			t.Fatalf("rules show: %v", err)
		}
	})
	if !strings.Contains(output, "Sync rules are not enabled.") {
		t.Fatalf("output = %q", output)
	}
}

func TestRulesShowDocument(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: "Desktop", Channels: []string{"*"}}},
	})

	output := captureStdout(t, func() {
		if err := runRules(ctx, []string{"show"}); err != nil {
			t.Fatalf("rules show: %v", err)
		}
	})
	if !strings.Contains(output, "Work") || !strings.Contains(output, "Desktop") {
		t.Fatalf("human output missing channel/device summary: %q", output)
	}

	ctx.globals.json = true
	jsonOutput := captureStdout(t, func() {
		if err := runRules(ctx, []string{"show"}); err != nil {
			t.Fatalf("rules show --json: %v", err)
		}
	})
	var doc rules.Document
	if err := json.Unmarshal([]byte(jsonOutput), &doc); err != nil {
		t.Fatalf("json output = %q: %v", jsonOutput, err)
	}
	if doc.Clipman != "sync-rules" || len(doc.Channels) != 1 || doc.Channels[0].Name != "Work" {
		t.Fatalf("decoded doc = %#v", doc)
	}
}

func TestRulesEnableCreatesDocumentWithSelfDevice(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	if err := runRules(ctx, []string{"enable"}); err != nil {
		t.Fatalf("rules enable: %v", err)
	}
	doc := fake.rulesDoc(t)
	if !doc.Enabled || doc.Version != 1 {
		t.Fatalf("doc = %#v", doc)
	}
	if len(doc.Channels) != 0 {
		t.Fatalf("channels = %#v, want none", doc.Channels)
	}
	if len(doc.Devices) != 1 || doc.Devices[0].Name != rulesCliMachine || len(doc.Devices[0].Channels) != 1 || doc.Devices[0].Channels[0] != "*" {
		t.Fatalf("devices = %#v, want this device with wildcard subscription", doc.Devices)
	}
	if !fake.created[rulesBucketIDForTest()] {
		t.Fatal("rules bucket was not created with If-None-Match")
	}
}

func TestRulesChannelAddValidatesAndUploads(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	if err := runRules(ctx, []string{"enable"}); err != nil {
		t.Fatalf("rules enable: %v", err)
	}

	if err := runRules(ctx, []string{"channel", "add"}); err == nil {
		t.Fatal("channel add with no name should fail")
	}
	if err := runRules(ctx, []string{"channel", "add", "Work"}); err == nil {
		t.Fatal("channel add with no condition should fail")
	}
	if err := runRules(ctx, []string{"channel", "add", "core", "--group", "Work"}); err == nil {
		t.Fatal("channel add with a reserved name should fail")
	}

	if err := runRules(ctx, []string{"channel", "add", "Work", "--group", "Work", "--group", "Standup"}); err != nil {
		t.Fatalf("channel add: %v", err)
	}
	doc := fake.rulesDoc(t)
	if len(doc.Channels) != 1 || doc.Channels[0].Name != "Work" {
		t.Fatalf("channels = %#v", doc.Channels)
	}
	if len(doc.Channels[0].Route.Groups) != 2 {
		t.Fatalf("route groups = %#v", doc.Channels[0].Route.Groups)
	}
}

func TestRulesChannelRemoveReroutesEntries(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{"*"}}},
	})
	fake.storeDatabase(t, rulesChannelBucketID("work"), historyDatabaseWith(testHistoryEntry("w1", "hello", "Work", 1000)))

	if err := runRules(ctx, []string{"channel", "remove", "Work"}); err != nil {
		t.Fatalf("channel remove: %v", err)
	}

	core := fake.database(t, rulesCoreBucketID())
	if !rulesHasEntry(core, "w1") {
		t.Fatalf("core entries = %v, want the rerouted entry", core.Entries)
	}
	work := fake.database(t, rulesChannelBucketID("work"))
	if len(work.Entries) != 0 {
		t.Fatalf("work channel entries = %v, want none left", work.Entries)
	}
	doc := fake.rulesDoc(t)
	for _, channel := range doc.Channels {
		if rules.ChannelKey(channel.Name) == "work" {
			t.Fatal("the work channel is still listed in the rules document")
		}
	}
}

func TestRulesChannelRemoveRefusesWhenNotSubscribed(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{}}},
	})
	fake.storeDatabase(t, rulesChannelBucketID("work"), historyDatabaseWith(testHistoryEntry("w1", "hello", "Work", 1000)))

	err := runRules(ctx, []string{"channel", "remove", "Work"})
	if err == nil || !strings.Contains(err.Error(), "not subscribed") {
		t.Fatalf("error = %v, want a not-subscribed refusal", err)
	}
}

func TestRulesDeviceSetSubscriptions(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
	})

	if err := runRules(ctx, []string{"device", "set", "Phone", "--channels", "work"}); err != nil {
		t.Fatalf("device set: %v", err)
	}
	doc := fake.rulesDoc(t)
	if len(doc.Devices) != 1 || doc.Devices[0].Name != "Phone" || len(doc.Devices[0].Channels) != 1 || doc.Devices[0].Channels[0] != "work" {
		t.Fatalf("devices = %#v", doc.Devices)
	}

	if err := runRules(ctx, []string{"device", "set", "Phone", "--channels", "*"}); err != nil {
		t.Fatalf("device set wildcard: %v", err)
	}
	doc = fake.rulesDoc(t)
	if len(doc.Devices) != 1 || doc.Devices[0].Channels[0] != "*" {
		t.Fatalf("devices after wildcard update = %#v", doc.Devices)
	}

	if err := runRules(ctx, []string{"device", "set", "Phone", "--channels", "nonexistent"}); err == nil {
		t.Fatal("device set referencing an unknown channel should fail")
	}
}

func TestListUsesSubscribedViewOnly(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeDatabase(t, rulesCoreBucketID(), historyDatabaseWith(testHistoryEntry("a", "alpha", "", 1000)))
	fake.storeDatabase(t, rulesChannelBucketID("work"), historyDatabaseWith(testHistoryEntry("b", "beta", "Work", 1000)))
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{}}},
	})

	ctx.globals.json = true
	output := captureStdout(t, func() {
		if err := runList(ctx, []string{}); err != nil {
			t.Fatalf("list: %v", err)
		}
	})
	if !strings.Contains(output, "alpha") {
		t.Fatalf("list output missing the subscribed core entry: %q", output)
	}
	if strings.Contains(output, "beta") {
		t.Fatalf("list output includes an unsubscribed channel's entry: %q", output)
	}
	if fake.count("GET", rulesChannelBucketID("work")) != 0 {
		t.Fatal("the unsubscribed work channel bucket was fetched")
	}
}

func TestSyncSelfRegistersMissingDevice(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
	})

	if err := runSync(ctx, []string{}); err != nil {
		t.Fatalf("sync: %v", err)
	}
	doc := fake.rulesDoc(t)
	found := false
	for _, device := range doc.Devices {
		if device.Name == rulesCliMachine {
			found = true
			if len(device.Channels) != 1 || device.Channels[0] != "*" {
				t.Fatalf("self-registered channels = %#v, want [\"*\"]", device.Channels)
			}
		}
	}
	if !found {
		t.Fatalf("devices = %#v, want this device registered", doc.Devices)
	}
}

func TestSyncSelfRegistrationFailureDoesNotFailSync(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
	})
	fake.breakBucket(rulesBucketIDForTest())

	if err := runSync(ctx, []string{}); err != nil {
		t.Fatalf("sync must succeed even when self-registration fails: %v", err)
	}
}

func TestWriteThroughPendingRetry(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{}}},
	})
	fake.breakBucket(rulesChannelBucketID("work"))

	if err := runPut(ctx, []string{"--text", "hello", "--group", "Work"}); err != nil {
		t.Fatalf("put must succeed locally even when write-through fails: %v", err)
	}
	pendingPath := pendingWritesPath(ctx.configPath)
	if _, err := os.Stat(pendingPath); err != nil {
		t.Fatalf("pending-writes.json was not created: %v", err)
	}
	pending := loadPendingWrites(ctx.configPath)
	if len(pending["work"]) != 1 {
		t.Fatalf("pending = %#v, want one entry parked for work", pending)
	}

	fake.unbreakBucket(rulesChannelBucketID("work"))
	if err := runSync(ctx, []string{}); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if _, err := os.Stat(pendingPath); !os.IsNotExist(err) {
		t.Fatalf("pending-writes.json should be cleared after a successful retry, stat err = %v", err)
	}
	work := fake.database(t, rulesChannelBucketID("work"))
	if len(work.Entries) != 1 || work.Entries[0].Text != "hello" {
		t.Fatalf("work channel entries = %#v, want the retried entry delivered", work.Entries)
	}
}

func TestRulesCommandsRefuseReadOnlyFutureDocument(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 2, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Weird", Route: rules.Route{Kind: "SomeFutureKind"}}},
	})

	for _, args := range [][]string{
		{"enable"},
		{"disable"},
		{"channel", "add", "Work", "--group", "Work"},
		{"channel", "remove", "Weird"},
		{"device", "set", "Phone", "--channels", "*"},
	} {
		if err := runRules(ctx, args); err == nil {
			t.Fatalf("rules %v: expected a refusal for a read-only future document", args)
		}
	}
}

// --- fixes from code review ------------------------------------------------

// CRITICAL 1: absorbWriteThrough must not report success when a subscribed
// channel upload also failed (WriteThroughError.Committed == false) - it must
// still park the pending entries (they are real), but return the error so the
// caller reports a nonzero exit.
func TestAbsorbWriteThroughReportsFailureWhenChannelUploadAlsoFails(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{
			{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}},
			{Name: "Images", Route: rules.Route{Kind: "RichTextImages"}},
		},
		// Subscribed to "work" (a normal uploaded channel) but not "images"
		// (which only ever reaches the server through write-through).
		Devices: []rules.Device{{Name: rulesCliMachine, Channels: []string{"work"}}},
	})
	fake.breakBucket(rulesChannelBucketID("work"))
	fake.breakBucket(rulesChannelBucketID("images"))

	_, mutateErr := ctx.engine.MutateView(context.Background(), rulesCliMachine, func(database *model.Database) error {
		database.Entries = append(database.Entries, testHistoryEntry("w", "work entry", "Work", 1000))
		database.Entries = append(database.Entries, imageEntryForTest("i", "image entry", 1000))
		return nil
	})
	if mutateErr == nil {
		t.Fatal("expected an error: a subscribed channel upload failed alongside a write-through failure")
	}

	if err := absorbWriteThrough(ctx, mutateErr); err == nil {
		t.Fatal("absorbWriteThrough must report failure (nonzero exit) when Committed is false")
	}
	pending := loadPendingWrites(ctx.configPath)
	if len(pending["images"]) != 1 {
		t.Fatalf("pending = %#v, want the undelivered image entry parked despite the reported failure", pending)
	}
}

// CRITICAL 2: rules channel remove must never touch the rules document when
// step 1 (relocating the channel's entries) did not actually succeed.
func TestRulesChannelRemoveAbortsWhenChannelUploadFails(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{"*"}}},
	})
	fake.storeDatabase(t, rulesChannelBucketID("work"), historyDatabaseWith(testHistoryEntry("w1", "hello", "Work", 1000)))
	fake.breakBucket(rulesChannelBucketID("work"))

	before := fake.rulesDoc(t)

	if err := runRules(ctx, []string{"channel", "remove", "Work"}); err == nil {
		t.Fatal("channel remove must fail when the channel's own bucket upload fails")
	}

	after := fake.rulesDoc(t)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("rules document changed despite the failed relocation:\n before %#v\n after  %#v", before, after)
	}
	if fake.count("PUT", rulesBucketIDForTest()) != 0 {
		t.Fatal("the rules bucket must not be written when step 1 fails")
	}
	work := fake.database(t, rulesChannelBucketID("work"))
	if !rulesHasEntry(work, "w1") {
		t.Fatal("the entry must still be in the channel: it was never actually relocated")
	}
}

// IMPORTANT 3: a genuinely newer remote rules edit, arriving between the
// initial read and the mutation, must abort the command rather than silently
// skip the reroute while still deleting the channel from the document.
func TestRulesChannelRemoveAbortsOnConcurrentRulesEdit(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	original := &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{"*"}}},
	}
	fake.storeRules(t, original)
	fake.storeDatabase(t, rulesChannelBucketID("work"), historyDatabaseWith(testHistoryEntry("w1", "hello", "Work", 1000)))

	// A concurrent edit from another device, timestamped far enough in the
	// future to always win the last-writer-wins merge against this command's
	// transitional document.
	concurrent := &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 99999999999999, UpdatedBy: "Other-Device",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{"*"}}},
	}
	payload, err := rules.Serialize(concurrent)
	if err != nil {
		t.Fatal(err)
	}
	concurrentBlob, err := clipdb.EncodeRaw(payload, rulesCliPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	// The 1st GET (this command's initial ReadView) still sees `original`;
	// every GET after that (starting with MutateView's own internal read)
	// sees the concurrent edit instead.
	fake.swapAfterGets(rulesBucketIDForTest(), 1, concurrentBlob)

	err = runRules(ctx, []string{"channel", "remove", "Work"})
	if err == nil || !strings.Contains(err.Error(), "changed on another device") {
		t.Fatalf("error = %v, want a concurrent-edit refusal", err)
	}

	work := fake.database(t, rulesChannelBucketID("work"))
	if !rulesHasEntry(work, "w1") {
		t.Fatal("the entry must not be relocated out of the channel under the wrong document")
	}
	after := fake.rulesDoc(t)
	if after.UpdatedUnixMs != concurrent.UpdatedUnixMs || after.UpdatedBy != concurrent.UpdatedBy {
		t.Fatalf("rules document changed unexpectedly: %#v", after)
	}
}

// IMPORTANT 4: a read-only (future-version) cached document must never arm
// the engine's 404 re-upload fallback, since this client is not allowed to
// rewrite a document it only partly understands.
func TestReadOnlyRulesCacheNeverArmsReupload(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	future := &rules.Document{
		Clipman: "sync-rules", Version: 2, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Weird", Route: rules.Route{Kind: "SomeFutureKind"}}},
	}
	data, err := rules.Serialize(future)
	if err != nil {
		t.Fatal(err)
	}
	if err := platform.SavePrivate(rulesCachePath(ctx.configPath), data); err != nil {
		t.Fatal(err)
	}
	// Mirrors what loadContext does at process startup.
	ctx.engine.CachedRules = initialCachedRules(ctx.configPath)
	if ctx.engine.CachedRules != nil {
		t.Fatal("a read-only cached document must not arm the engine's CachedRules")
	}

	// The rules bucket 404s (nothing stored server-side). A command that
	// reads rules must not restore the cached document by PUTting it back.
	captureStdout(t, func() {
		if err := runRules(ctx, []string{"show"}); err != nil {
			t.Fatalf("rules show: %v", err)
		}
	})
	if fake.count("PUT", rulesBucketIDForTest()) != 0 {
		t.Fatal("a read-only cached document must never be re-uploaded on a 404")
	}
}

// MINOR 5: putRulesDocument must reuse the salt from the rules bucket's own
// just-downloaded blob instead of fetching core, whenever that blob exists.
func TestPutRulesDocumentReusesRulesBlobSaltWithoutFetchingCore(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
	})
	// No core bucket exists at all; a fallback fetch for salt would be a GET
	// against a bucket that has never been created.
	if err := runRules(ctx, []string{"enable"}); err != nil {
		t.Fatalf("rules enable: %v", err)
	}
	if fake.count("GET", rulesCoreBucketID()) != 0 {
		t.Fatal("putRulesDocument fetched core for salt despite already holding the rules blob's own salt")
	}
}

// MINOR 6: a pending write-through entry must be re-routed against the
// CURRENT rules document at retry time, not resent to the channel key it was
// originally parked under - that channel may have been removed since.
func TestPendingRetryRegroupsToCurrentRulesAfterChannelRemoval(t *testing.T) {
	fake, ctx := newRulesTestContext(t)
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}}},
		Devices:  []rules.Device{{Name: rulesCliMachine, Channels: []string{}}},
	})
	fake.breakBucket(rulesChannelBucketID("work"))

	if err := runPut(ctx, []string{"--text", "hello", "--group", "Work"}); err != nil {
		t.Fatalf("put must succeed locally even when write-through fails: %v", err)
	}
	pending := loadPendingWrites(ctx.configPath)
	if len(pending["work"]) != 1 {
		t.Fatalf("pending = %#v, want one entry parked for work", pending)
	}

	// Another device removes the "work" channel entirely while the entry is
	// still parked for it.
	fake.storeRules(t, &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 2000, UpdatedBy: "Desktop",
		Devices: []rules.Device{{Name: rulesCliMachine, Channels: []string{}}},
	})

	if err := runSync(ctx, []string{}); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if fake.exists(rulesChannelBucketID("work")) {
		t.Fatal("the removed channel's bucket must not be recreated by the pending retry")
	}
	if pending := loadPendingWrites(ctx.configPath); len(pending) != 0 {
		t.Fatalf("pending writes were not cleared: %#v", pending)
	}
	core := fake.database(t, rulesCoreBucketID())
	if len(core.Entries) != 1 || core.Entries[0].Text != "hello" {
		t.Fatalf("core entries = %#v, want the re-routed pending entry delivered to core", core.Entries)
	}
}
