package syncengine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/rules"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/server"
)

// The cross-client test vectors from sync-rules-spec.md section 2 are used as
// the token and password so the derived bucket ids in these tests are the
// published ones.
const channelTestToken = "example-token"
const channelTestPassword = "example-password"

func coreBucketID() string { return identity.DatabaseID(channelTestToken, channelTestPassword) }
func rulesBucketID() string {
	return identity.SyncRulesDatabaseID(channelTestToken, channelTestPassword)
}
func channelBucketID(key string) string {
	return identity.ChannelDatabaseID(channelTestToken, channelTestPassword, key)
}

type channelBucket struct {
	blob     []byte
	revision string
}

// channelServer is a multi-bucket stand-in for Clipman Server: it serves
// GET/PUT /api/v1/database/{id} for any number of database ids, enforces the
// If-Match/If-None-Match preconditions the engine relies on, records every
// request so tests can assert which buckets were touched, and can inject a
// one-shot conflict on a chosen bucket.
type channelServer struct {
	lock         sync.Mutex
	buckets      map[string]*channelBucket
	requests     []string
	created      map[string]bool
	conflicts    map[string]int
	replacements map[string][]byte
	broken       map[string]bool
	sequence     int
}

func newChannelServer() *channelServer {
	return &channelServer{
		buckets:      map[string]*channelBucket{},
		created:      map[string]bool{},
		conflicts:    map[string]int{},
		replacements: map[string][]byte{},
		broken:       map[string]bool{},
	}
}

// breakBucket makes every PUT to one bucket fail with a server error, which is
// how the tests model a bucket that cannot be written right now.
func (s *channelServer) breakBucket(identifier string) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.broken[identifier] = true
}

// salt returns the container salt of a stored blob, which is what proves that
// channel buckets share the core database's PBKDF2 derivation.
func (s *channelServer) salt(t *testing.T, identifier string) []byte {
	t.Helper()
	blob := s.blob(identifier)
	if blob == nil {
		t.Fatalf("bucket %q does not exist", identifier)
	}
	_, salt, err := clipdb.DecodeRaw(blob, channelTestPassword)
	if err != nil {
		t.Fatal(err)
	}
	if len(salt) != 16 {
		t.Fatalf("bucket %q has no container salt", identifier)
	}
	return salt
}

func (s *channelServer) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	identifier, err := url.PathUnescape(strings.TrimPrefix(request.URL.Path, "/api/v1/database/"))
	if err != nil {
		writer.WriteHeader(http.StatusBadRequest)
		return
	}
	s.lock.Lock()
	defer s.lock.Unlock()
	s.requests = append(s.requests, request.Method+" "+identifier)
	switch request.Method {
	case http.MethodGet:
		bucket := s.buckets[identifier]
		if bucket == nil {
			http.NotFound(writer, request)
			return
		}
		writer.Header().Set("X-Clipman-Revision", bucket.revision)
		_, _ = writer.Write(bucket.blob)
	case http.MethodPut:
		data, readErr := io.ReadAll(request.Body)
		if readErr != nil {
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		if s.broken[identifier] {
			writer.WriteHeader(http.StatusInternalServerError)
			return
		}
		if s.conflicts[identifier] > 0 {
			s.conflicts[identifier]--
			if replacement, ok := s.replacements[identifier]; ok {
				s.sequence++
				s.buckets[identifier] = &channelBucket{blob: replacement, revision: fmt.Sprintf("revision-%d", s.sequence)}
				delete(s.replacements, identifier)
			}
			writer.WriteHeader(http.StatusPreconditionFailed)
			return
		}
		existing := s.buckets[identifier]
		if request.Header.Get("If-None-Match") == "*" {
			if existing != nil {
				writer.WriteHeader(http.StatusPreconditionFailed)
				return
			}
			s.created[identifier] = true
		} else if existing != nil {
			if strings.Trim(request.Header.Get("If-Match"), "\"") != existing.revision {
				writer.WriteHeader(http.StatusPreconditionFailed)
				return
			}
		}
		s.sequence++
		revision := fmt.Sprintf("revision-%d", s.sequence)
		s.buckets[identifier] = &channelBucket{blob: data, revision: revision}
		writer.Header().Set("X-Clipman-Revision", revision)
		writer.WriteHeader(http.StatusOK)
	default:
		writer.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *channelServer) storeBlob(identifier string, blob []byte) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.sequence++
	s.buckets[identifier] = &channelBucket{blob: blob, revision: fmt.Sprintf("revision-%d", s.sequence)}
}

func (s *channelServer) storeDatabase(t *testing.T, identifier string, database model.Database) {
	t.Helper()
	blob, err := clipdb.Encode(database, channelTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.storeBlob(identifier, blob)
}

func (s *channelServer) storeRules(t *testing.T, document *rules.Document) {
	t.Helper()
	payload, err := rules.Serialize(document)
	if err != nil {
		t.Fatal(err)
	}
	blob, err := clipdb.EncodeRaw(payload, channelTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.storeBlob(rulesBucketID(), blob)
}

func (s *channelServer) blob(identifier string) []byte {
	s.lock.Lock()
	defer s.lock.Unlock()
	bucket := s.buckets[identifier]
	if bucket == nil {
		return nil
	}
	return append([]byte(nil), bucket.blob...)
}

func (s *channelServer) database(t *testing.T, identifier string) model.Database {
	t.Helper()
	blob := s.blob(identifier)
	if blob == nil {
		t.Fatalf("bucket %q does not exist", identifier)
	}
	database, err := clipdb.Decode(blob, channelTestPassword, clipdb.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	return database
}

func (s *channelServer) count(method, identifier string) int {
	s.lock.Lock()
	defer s.lock.Unlock()
	total := 0
	for _, entry := range s.requests {
		if entry == method+" "+identifier {
			total++
		}
	}
	return total
}

func (s *channelServer) createdOnly(identifier string) bool {
	s.lock.Lock()
	defer s.lock.Unlock()
	return s.created[identifier]
}

func newChannelEngine(t *testing.T) (*channelServer, *Engine) {
	t.Helper()
	fake := newChannelServer()
	testServer := httptest.NewServer(fake)
	t.Cleanup(testServer.Close)
	client, err := server.New(testServer.URL, channelTestToken, coreBucketID(), "test")
	if err != nil {
		t.Fatal(err)
	}
	client.HTTP = testServer.Client()
	engine := &Engine{
		Client:   client,
		Password: channelTestPassword,
		Limits:   clipdb.DefaultLimits(),
		Retries:  2,
		Token:    channelTestToken,
	}
	return fake, engine
}

// recentUnixMs is a timestamp inside the 90-day tombstone retention window, so
// markers built by tests survive normalization.
func recentUnixMs() int64 { return time.Now().UnixMilli() - 60000 }

func testEntry(id, text, group string, stamp int64) model.Entry {
	return model.Entry{
		ID:             id,
		Text:           text,
		Group:          group,
		CreatedUnixMs:  stamp,
		LastUsedUnixMs: stamp,
		ModifiedUnixMs: stamp,
		Extra:          map[string]json.RawMessage{},
	}
}

func databaseWith(entries ...model.Entry) model.Database {
	database := model.NewDatabase(1000)
	database.Entries = append(database.Entries, entries...)
	return database
}

func enabledRules(devices ...rules.Device) *rules.Document {
	return &rules.Document{
		Clipman:       "sync-rules",
		Version:       1,
		Enabled:       true,
		UpdatedUnixMs: 2000,
		UpdatedBy:     "Desktop",
		Channels: []rules.Channel{
			{Name: "Work", Route: rules.Route{Groups: []string{"Work"}}},
			{Name: "Images", Route: rules.Route{Kind: "RichTextImages"}},
		},
		Devices: devices,
	}
}

func entryIDs(database *model.Database) []string {
	ids := make([]string, 0, len(database.Entries))
	for _, entry := range database.Entries {
		ids = append(ids, entry.ID)
	}
	return ids
}

func hasEntry(database model.Database, id string) bool {
	for _, entry := range database.Entries {
		if entry.ID == id {
			return true
		}
	}
	return false
}

func TestReadViewDisabledRulesMatchesLegacyRead(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(
		testEntry("a", "alpha", "", 1000),
		testEntry("b", "beta", "Work", 2000),
	))
	document := enabledRules()
	document.Enabled = false
	fake.storeRules(t, document)
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("w", "work text", "Work", 1500)))

	view, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := engine.Read(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	merge.Normalize(&legacy.Database, view.View.UpdatedUnixMs)
	if !reflect.DeepEqual(legacy.Database, *view.View) {
		t.Fatalf("view = %#v, legacy read = %#v", *view.View, legacy.Database)
	}
	if len(view.Channels) != 1 || view.Channels[0].Key != "" {
		t.Fatalf("channels = %#v, want the core channel only", view.Channels)
	}
	if view.Rules == nil || view.Rules.Enabled {
		t.Fatalf("rules = %#v, want the disabled document", view.Rules)
	}
	for id, key := range view.Residence {
		if key != "" {
			t.Fatalf("residence[%q] = %q, want core", id, key)
		}
	}
	if fake.count("GET", channelBucketID("work")) != 0 {
		t.Fatal("a channel bucket was fetched while rules are disabled")
	}
}

func TestReadViewMergesSubscribedChannelsOnly(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("a", "alpha", "", 1000)))
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("b", "beta", "Work", 1000)))
	fake.storeDatabase(t, channelBucketID("images"), databaseWith(testEntry("c", "gamma", "", 1000)))
	fake.storeRules(t, enabledRules(rules.Device{Name: "Laptop", Channels: []string{"work"}}))

	view, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	if ids := entryIDs(view.View); len(ids) != 2 || !hasEntry(*view.View, "a") || !hasEntry(*view.View, "b") {
		t.Fatalf("view entries = %v, want a and b", ids)
	}
	if view.Residence["a"] != "" || view.Residence["b"] != "work" {
		t.Fatalf("residence = %#v", view.Residence)
	}
	if fake.count("GET", channelBucketID("images")) != 0 {
		t.Fatal("the unsubscribed images channel was fetched")
	}
	if len(view.Channels) != 2 {
		t.Fatalf("channels = %#v, want core and work", view.Channels)
	}
}

func TestMutateViewUploadsOnlyDirtyChannels(t *testing.T) {
	fake, engine := newChannelEngine(t)
	// Interleaved creation times across the two channels: the merged view
	// renumbers ManualOrder globally, so the work channel only stays clean if
	// rebuilding it reproduces its own 1..n numbering exactly.
	fake.storeDatabase(t, coreBucketID(), databaseWith(
		testEntry("a1", "alpha one", "", 1000),
		testEntry("a2", "alpha two", "", 3000),
		testEntry("a3", "alpha three", "", 5000),
	))
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(
		testEntry("b1", "beta one", "Work", 2000),
		testEntry("b2", "beta two", "Work", 4000),
		testEntry("b3", "beta three", "Work", 6000),
	))
	fake.storeRules(t, enabledRules())

	view, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		database.Entries = append(database.Entries, testEntry("c", "gamma", "", 7000))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.count("PUT", coreBucketID()) != 1 {
		t.Fatalf("core PUT count = %d, want 1", fake.count("PUT", coreBucketID()))
	}
	if fake.count("PUT", channelBucketID("work")) != 0 {
		t.Fatal("the untouched work channel was uploaded")
	}
	if !hasEntry(fake.database(t, coreBucketID()), "c") {
		t.Fatal("the new entry was not committed to core")
	}
	for _, id := range []string{"b1", "b2", "b3"} {
		if !hasEntry(*view.View, id) || view.Residence[id] != "work" {
			t.Fatalf("returned view lost the work channel: %v", entryIDs(view.View))
		}
	}
	// A second mutation that changes nothing must upload nothing at all.
	before := len(fake.requests)
	if _, err := engine.MutateView(context.Background(), "Laptop", func(*model.Database) error { return nil }); err != nil {
		t.Fatal(err)
	}
	for _, request := range fake.requests[before:] {
		if strings.HasPrefix(request, "PUT ") {
			t.Fatalf("an unchanged mutation uploaded %q", request)
		}
	}
}

func TestReadViewPlainHashIsStableAcrossReads(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("a", "alpha", "", 1000)))
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("b", "beta", "Work", 1000)))
	fake.storeRules(t, enabledRules())

	first, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	second, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	if first.View.UpdatedUnixMs == second.View.UpdatedUnixMs {
		t.Fatal("both reads used the same clock reading; the test proves nothing")
	}
	if len(first.Channels) != len(second.Channels) {
		t.Fatalf("channel counts differ: %d and %d", len(first.Channels), len(second.Channels))
	}
	for index := range first.Channels {
		if first.Channels[index].PlainHash != second.Channels[index].PlainHash {
			t.Fatalf("channel %q hashed differently on two reads of unchanged data", first.Channels[index].Key)
		}
	}
}

func TestMutateViewFailedRelocationTargetKeepsSourceIntact(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("x", "hello", "", 1000)))
	fake.storeRules(t, enabledRules())
	fake.breakBucket(channelBucketID("work"))

	_, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		for index := range database.Entries {
			if database.Entries[index].ID == "x" {
				database.Entries[index].Group = "Work"
				database.Entries[index].ModifiedUnixMs = 5000
			}
		}
		return nil
	})
	if err == nil {
		t.Fatal("a failed relocation target was reported as success")
	}
	if fake.count("PUT", coreBucketID()) != 0 {
		t.Fatal("core was rewritten although the entry never reached the work channel")
	}
	if !hasEntry(fake.database(t, coreBucketID()), "x") {
		t.Fatal("the entry was lost: it is neither in core nor in work")
	}
}

func TestMutateViewWriteThroughFailureReportsPendingEntries(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("a", "alpha", "", 1000)))
	fake.storeRules(t, enabledRules(rules.Device{Name: "Phone", Channels: []string{}}))
	fake.breakBucket(channelBucketID("work"))

	view, err := engine.MutateView(context.Background(), "Phone", func(database *model.Database) error {
		database.Entries = append(database.Entries, testEntry("x", "hello", "Work", 4000))
		database.Entries = append(database.Entries, testEntry("c", "gamma", "", 4000))
		return nil
	})
	var pendingErr *WriteThroughError
	if !errors.As(err, &pendingErr) {
		t.Fatalf("error = %v, want a *WriteThroughError", err)
	}
	if len(pendingErr.Pending["work"]) != 1 || pendingErr.Pending["work"][0].ID != "x" {
		t.Fatalf("pending entries = %#v, want the undelivered x", pendingErr.Pending)
	}
	if pendingErr.Unwrap() == nil {
		t.Fatal("the write-through error does not wrap its cause")
	}
	if view == nil {
		t.Fatal("no ViewState was returned alongside the write-through error")
	}
	core := fake.database(t, coreBucketID())
	if !hasEntry(core, "c") || !hasEntry(core, "a") {
		t.Fatalf("core entries = %v, want the unrelated change committed", entryIDs(&core))
	}
	if hasEntry(core, "x") {
		t.Fatal("an entry routed to another channel was parked in core")
	}
	if !hasEntry(*view.View, "c") || hasEntry(*view.View, "x") {
		t.Fatalf("returned view = %v, want the committed core state", entryIDs(view.View))
	}
}

func TestMutateViewFreshInstallSharesCoreSalt(t *testing.T) {
	fake, engine := newChannelEngine(t)
	// A new device joining a fleet that already uses rules: the rules bucket
	// exists, no history bucket does.
	fake.storeRules(t, enabledRules())

	if _, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		database.Entries = append(database.Entries, testEntry("a", "alpha", "", 4000))
		database.Entries = append(database.Entries, testEntry("b", "beta", "Work", 4000))
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	core := fake.salt(t, coreBucketID())
	work := fake.salt(t, channelBucketID("work"))
	if !bytes.Equal(core, work) {
		t.Fatalf("work channel salt = %x, core salt = %x; a fresh channel must copy core's salt", work, core)
	}
	if fake.count("PUT", coreBucketID()) != 1 {
		t.Fatalf("core PUT count = %d, want a single create", fake.count("PUT", coreBucketID()))
	}
	if !hasEntry(fake.database(t, coreBucketID()), "a") || !hasEntry(fake.database(t, channelBucketID("work")), "b") {
		t.Fatal("the fresh install did not commit both entries to their channels")
	}
}

func TestMutateViewRelocationRoundTripKeepsEntry(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("x", "hello", "", 1000)))
	fake.storeRules(t, enabledRules())

	if _, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		for index := range database.Entries {
			if database.Entries[index].ID == "x" {
				database.Entries[index].Group = "Work"
				database.Entries[index].ModifiedUnixMs = 5000
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	view, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		for index := range database.Entries {
			if database.Entries[index].ID == "x" {
				database.Entries[index].Group = ""
				database.Entries[index].ModifiedUnixMs = 6000
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	core := fake.database(t, coreBucketID())
	if !hasEntry(core, "x") {
		t.Fatal("the entry did not survive the round trip back to core: a stale relocation marker deleted it")
	}
	work := fake.database(t, channelBucketID("work"))
	if hasEntry(work, "x") {
		t.Fatal("the work channel kept the entry after it moved back")
	}
	if !hasEntry(*view.View, "x") || view.Residence["x"] != "" {
		t.Fatalf("residence = %#v, want x back in core", view.Residence)
	}
}

func TestMutateViewRelocatesEntryOnGroupChange(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("x", "hello", "", 1000)))
	fake.storeRules(t, enabledRules())

	view, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		for index := range database.Entries {
			if database.Entries[index].ID == "x" {
				database.Entries[index].Group = "Work"
				database.Entries[index].ModifiedUnixMs = 5000
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	work := fake.database(t, channelBucketID("work"))
	if !hasEntry(work, "x") {
		t.Fatalf("work channel entries = %v, want x", entryIDs(&work))
	}
	core := fake.database(t, coreBucketID())
	if hasEntry(core, "x") {
		t.Fatal("core kept the relocated entry")
	}
	if len(core.Deleted) != 1 || core.Deleted[0].ID != "x" || core.Deleted[0].TextHash != "" {
		t.Fatalf("core tombstones = %#v, want one empty-hash relocation marker for x", core.Deleted)
	}
	if core.Deleted[0].SourceMachine != "Laptop" || core.Deleted[0].DeletedUnixMs <= 0 {
		t.Fatalf("relocation marker = %#v", core.Deleted[0])
	}
	if view.Residence["x"] != "work" {
		t.Fatalf("residence = %#v, want x in work", view.Residence)
	}
	if !hasEntry(*view.View, "x") {
		t.Fatal("the relocated entry left the view")
	}
}

func TestMutateViewWriteThroughUnsubscribedChannel(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeRules(t, enabledRules(rules.Device{Name: "Phone", Channels: []string{}}))

	view, err := engine.MutateView(context.Background(), "Phone", func(database *model.Database) error {
		database.Entries = append(database.Entries, testEntry("x", "hello", "Work", 4000))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.count("PUT", channelBucketID("work")) != 1 {
		t.Fatalf("work PUT count = %d, want 1", fake.count("PUT", channelBucketID("work")))
	}
	if !hasEntry(fake.database(t, channelBucketID("work")), "x") {
		t.Fatal("the entry was not written through to the work channel")
	}
	if !fake.createdOnly(channelBucketID("work")) {
		t.Fatal("the new work bucket was not created with If-None-Match")
	}
	if len(view.View.Entries) != 0 {
		t.Fatalf("view entries = %v, want none", entryIDs(view.View))
	}
	if _, ok := view.Residence["x"]; ok {
		t.Fatal("an unsubscribed channel appeared in residence")
	}
	// On this first sync core is created once as the salt anchor every other
	// bucket copies, and stays empty because nothing routed to it.
	if fake.count("PUT", coreBucketID()) != 1 {
		t.Fatalf("core PUT count = %d, want the single salt-anchor create", fake.count("PUT", coreBucketID()))
	}
	if len(fake.database(t, coreBucketID()).Entries) != 0 {
		t.Fatal("an entry routed to another channel was parked in core")
	}
	if !bytes.Equal(fake.salt(t, channelBucketID("work")), fake.salt(t, coreBucketID())) {
		t.Fatal("the write-through bucket does not share the core database's salt")
	}
}

func TestReadViewDuplicateIdResolvedByModified(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("x", "old text", "", 1000)))
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("x", "new text", "Work", 2000)))
	fake.storeRules(t, enabledRules())

	view, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	if len(view.View.Entries) != 1 {
		t.Fatalf("view entries = %v, want a single copy of x", entryIDs(view.View))
	}
	if view.View.Entries[0].Text != "new text" {
		t.Fatalf("winning entry = %#v, want the higher ModifiedUnixMs copy", view.View.Entries[0])
	}
	if view.Residence["x"] != "work" {
		t.Fatalf("residence = %#v, want x in work", view.Residence)
	}
}

func TestReadViewCrossChannelTextHashTombstone(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(
		testEntry("c1", "secret", "", 1000),
		testEntry("c2", "keep", "", 1000),
	))
	work := databaseWith(testEntry("w1", "other", "Work", 1000))
	work.Deleted = append(work.Deleted, model.DeletedEntry{
		ID:            "gone",
		TextHash:      merge.TextHash("secret"),
		DeletedUnixMs: recentUnixMs(),
		SourceMachine: "Desktop",
		Extra:         map[string]json.RawMessage{},
	})
	fake.storeDatabase(t, channelBucketID("work"), work)
	fake.storeRules(t, enabledRules())

	view, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	if hasEntry(*view.View, "c1") {
		t.Fatal("a non-empty TextHash marker did not suppress the matching entry in another channel")
	}
	if !hasEntry(*view.View, "c2") || !hasEntry(*view.View, "w1") {
		t.Fatalf("view entries = %v, want c2 and w1", entryIDs(view.View))
	}
}

func TestMissingRulesBucketFallsBackToCache(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("a", "alpha", "", 1000)))
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("b", "beta", "Work", 1000)))
	engine.CachedRules = enabledRules()

	view, err := engine.ReadView(context.Background(), "Laptop")
	if err != nil {
		t.Fatal(err)
	}
	if view.Rules == nil || !view.Rules.Enabled {
		t.Fatalf("rules = %#v, want the cached document", view.Rules)
	}
	if !hasEntry(*view.View, "b") || view.Residence["b"] != "work" {
		t.Fatalf("view entries = %v, want the cached rules to be in effect", entryIDs(view.View))
	}
	if fake.count("PUT", rulesBucketID()) != 1 || !fake.createdOnly(rulesBucketID()) {
		t.Fatal("the cached rules document was not re-uploaded with If-None-Match")
	}
	payload, _, err := clipdb.DecodeRaw(fake.blob(rulesBucketID()), channelTestPassword)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := rules.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(restored, engine.CachedRules) {
		t.Fatalf("re-uploaded rules = %#v", restored)
	}
	if !bytes.Equal(fake.salt(t, rulesBucketID()), fake.salt(t, coreBucketID())) {
		t.Fatal("the restored rules blob does not share the core database's salt")
	}
}

func TestUndecodableRulesBlobDegradesToDisabled(t *testing.T) {
	corrupt, err := clipdb.EncodeRaw([]byte(`{"Clipman":"not-sync-rules"}`), channelTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	for name, blob := range map[string][]byte{
		"not a container": []byte("this is not a Clipman container"),
		"wrong document":  corrupt,
	} {
		fake, engine := newChannelEngine(t)
		fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("a", "alpha", "", 1000)))
		fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("b", "beta", "Work", 1000)))
		fake.storeBlob(rulesBucketID(), blob)

		view, err := engine.ReadView(context.Background(), "Laptop")
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if view.Rules != nil || view.RulesRevision != "" {
			t.Fatalf("%s: rules = %#v, want none recorded", name, view.Rules)
		}
		if len(view.Channels) != 1 || hasEntry(*view.View, "b") {
			t.Fatalf("%s: view entries = %v, want core only", name, entryIDs(view.View))
		}
		if fake.count("GET", channelBucketID("work")) != 0 {
			t.Fatalf("%s: a channel bucket was fetched with unusable rules", name)
		}
	}
}

func TestMutateViewChannelConflictRetries(t *testing.T) {
	fake, engine := newChannelEngine(t)
	fake.storeDatabase(t, coreBucketID(), databaseWith(testEntry("a", "alpha", "", 1000)))
	fake.storeDatabase(t, channelBucketID("work"), databaseWith(testEntry("b", "beta", "Work", 1000)))
	fake.storeRules(t, enabledRules())

	remote := databaseWith(
		testEntry("b", "beta", "Work", 1000),
		testEntry("r", "remote", "Work", 3000),
	)
	remoteBlob, err := clipdb.Encode(remote, channelTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	fake.lock.Lock()
	fake.conflicts[channelBucketID("work")] = 1
	fake.replacements[channelBucketID("work")] = remoteBlob
	fake.lock.Unlock()

	view, err := engine.MutateView(context.Background(), "Laptop", func(database *model.Database) error {
		database.Entries = append(database.Entries, testEntry("x", "local", "Work", 4000))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.count("PUT", channelBucketID("work")) != 2 {
		t.Fatalf("work PUT count = %d, want 2", fake.count("PUT", channelBucketID("work")))
	}
	committed := fake.database(t, channelBucketID("work"))
	if !hasEntry(committed, "b") || !hasEntry(committed, "r") || !hasEntry(committed, "x") {
		t.Fatalf("committed work entries = %v, want b, r and x", entryIDs(&committed))
	}
	if !hasEntry(*view.View, "r") || !hasEntry(*view.View, "x") {
		t.Fatalf("returned view entries = %v, want the merged result", entryIDs(view.View))
	}
}
