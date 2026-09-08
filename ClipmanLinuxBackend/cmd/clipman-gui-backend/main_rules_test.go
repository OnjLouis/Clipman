package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/platform"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/rules"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/syncengine"
)

// The cross-client test vectors from sync-rules-spec.md section 2 are used as
// the token and password so the derived bucket ids in these tests match the
// published fixtures, mirroring internal/syncengine's channel tests.
const rulesTestToken = "example-token"
const rulesTestPassword = "example-password"

func rulesTestCoreID() string { return identity.DatabaseID(rulesTestToken, rulesTestPassword) }
func rulesTestRulesID() string {
	return identity.SyncRulesDatabaseID(rulesTestToken, rulesTestPassword)
}
func rulesTestChannelID(key string) string {
	return identity.ChannelDatabaseID(rulesTestToken, rulesTestPassword, key)
}

type rulesBucket struct {
	blob     []byte
	revision string
}

// rulesFakeServer is a multi-bucket stand-in for Clipman Server: it serves
// HEAD/GET/PUT /api/v1/database/{id} for any number of database ids plus
// /api/v1/health, enforces If-Match/If-None-Match, and records every request
// so tests can assert which buckets were HEAD-ed, GET-ed, or PUT.
type rulesFakeServer struct {
	lock     sync.Mutex
	buckets  map[string]*rulesBucket
	requests []string
	sequence int
	broken   map[string]bool
}

func newRulesFakeServer() *rulesFakeServer {
	return &rulesFakeServer{buckets: map[string]*rulesBucket{}, broken: map[string]bool{}}
}

// breakBucket makes every PUT to one bucket fail with a server error, which
// is how tests model a channel bucket that cannot be written right now.
func (s *rulesFakeServer) breakBucket(identifier string) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.broken[identifier] = true
}

func (s *rulesFakeServer) fixBucket(identifier string) {
	s.lock.Lock()
	defer s.lock.Unlock()
	delete(s.broken, identifier)
}

func (s *rulesFakeServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/api/v1/health" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
		return
	}
	identifier, err := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/api/v1/database/"))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	s.lock.Lock()
	defer s.lock.Unlock()
	s.requests = append(s.requests, r.Method+" "+identifier)
	switch r.Method {
	case http.MethodHead:
		bucket := s.buckets[identifier]
		if bucket == nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("X-Clipman-Revision", bucket.revision)
		w.WriteHeader(http.StatusOK)
	case http.MethodGet:
		bucket := s.buckets[identifier]
		if bucket == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("X-Clipman-Revision", bucket.revision)
		_, _ = w.Write(bucket.blob)
	case http.MethodPut:
		data, readErr := io.ReadAll(r.Body)
		if readErr != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if s.broken[identifier] {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		existing := s.buckets[identifier]
		if r.Header.Get("If-None-Match") == "*" {
			if existing != nil {
				w.WriteHeader(http.StatusPreconditionFailed)
				return
			}
		} else if existing != nil {
			if strings.Trim(r.Header.Get("If-Match"), "\"") != existing.revision {
				w.WriteHeader(http.StatusPreconditionFailed)
				return
			}
		}
		s.sequence++
		revision := fmt.Sprintf("revision-%d", s.sequence)
		s.buckets[identifier] = &rulesBucket{blob: data, revision: revision}
		w.Header().Set("X-Clipman-Revision", revision)
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *rulesFakeServer) storeBlob(identifier string, blob []byte) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.sequence++
	s.buckets[identifier] = &rulesBucket{blob: blob, revision: fmt.Sprintf("revision-%d", s.sequence)}
}

func (s *rulesFakeServer) storeDatabase(t *testing.T, identifier string, database model.Database) {
	t.Helper()
	blob, err := clipdb.Encode(database, rulesTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.storeBlob(identifier, blob)
}

func (s *rulesFakeServer) storeRules(t *testing.T, doc *rules.Document) {
	t.Helper()
	payload, err := rules.Serialize(doc)
	if err != nil {
		t.Fatal(err)
	}
	blob, err := clipdb.EncodeRaw(payload, rulesTestPassword, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.storeBlob(rulesTestRulesID(), blob)
}

func (s *rulesFakeServer) database(t *testing.T, identifier string) model.Database {
	t.Helper()
	s.lock.Lock()
	bucket := s.buckets[identifier]
	s.lock.Unlock()
	if bucket == nil {
		t.Fatalf("bucket %q does not exist", identifier)
	}
	database, err := clipdb.Decode(bucket.blob, rulesTestPassword, clipdb.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	return database
}

func (s *rulesFakeServer) rulesDocument(t *testing.T) *rules.Document {
	t.Helper()
	s.lock.Lock()
	bucket := s.buckets[rulesTestRulesID()]
	s.lock.Unlock()
	if bucket == nil {
		t.Fatalf("rules bucket does not exist")
	}
	payload, _, err := clipdb.DecodeRaw(bucket.blob, rulesTestPassword)
	if err != nil {
		t.Fatal(err)
	}
	doc, err := rules.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	return doc
}

func (s *rulesFakeServer) count(method, identifier string) int {
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

func (s *rulesFakeServer) resetRequests() {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.requests = nil
}

// newRulesSession builds a session already activated against a fresh
// rulesFakeServer, with device name "Linux test".
func newRulesSession(t *testing.T) (*rulesFakeServer, *session) {
	t.Helper()
	fake := newRulesFakeServer()
	testServer := httptest.NewServer(fake)
	t.Cleanup(testServer.Close)
	dir := t.TempDir()
	s := &session{configPath: filepath.Join(dir, "config.toml"), cachePath: filepath.Join(dir, "cache.clipdb")}
	body, _ := json.Marshal(map[string]any{
		"Server": testServer.URL, "Token": rulesTestToken, "Password": rulesTestPassword,
		"Machine": "Linux test", "Remember": true,
	})
	if _, err := s.configure(json.RawMessage(body)); err != nil {
		t.Fatalf("configure: %v", err)
	}
	return fake, s
}

func enabledTestRules(devices ...rules.Device) *rules.Document {
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

func TestRulesRoundTripThroughSession(t *testing.T) {
	_, s := newRulesSession(t)

	doc := map[string]any{
		"Clipman": "sync-rules", "Version": 1, "Enabled": true,
		"UpdatedUnixMs": 1000, "UpdatedBy": "Linux test",
		"Channels": []map[string]any{
			{"Name": "Work", "Route": map[string]any{"Groups": []string{"Work"}}},
		},
		"Devices": []map[string]any{
			{"Name": "Linux test", "Channels": []string{"*"}},
		},
	}
	setRequest, _ := json.Marshal(map[string]any{"rules": doc})
	result, err := s.rulesSet(setRequest)
	if err != nil {
		t.Fatalf("rules-set: %v", err)
	}
	setResult, ok := result.(map[string]any)
	if !ok || setResult["revision"] == "" {
		t.Fatalf("rules-set result = %#v", result)
	}

	getResult, err := s.rulesGet()
	if err != nil {
		t.Fatalf("rules-get: %v", err)
	}
	got, ok := getResult.(map[string]any)
	if !ok {
		t.Fatalf("rules-get result = %#v", getResult)
	}
	storedDoc, ok := got["rules"].(*rules.Document)
	if !ok || storedDoc == nil {
		t.Fatalf("rules-get did not return a document: %#v", got)
	}
	if !storedDoc.Enabled || len(storedDoc.Channels) != 1 || storedDoc.Channels[0].Name != "Work" {
		t.Fatalf("stored rules document = %#v", storedDoc)
	}
	if got["readOnly"] != false {
		t.Fatalf("readOnly = %v, want false", got["readOnly"])
	}
	if got["revision"] == "" {
		t.Fatal("rules-get returned a blank revision for an existing document")
	}

	// Validation rejection path: a channel using a reserved name.
	badDoc := map[string]any{
		"Clipman": "sync-rules", "Version": 1, "Enabled": true,
		"UpdatedUnixMs": 2000, "UpdatedBy": "Linux test",
		"Channels": []map[string]any{
			{"Name": "core", "Route": map[string]any{"Groups": []string{"Work"}}},
		},
	}
	badRequest, _ := json.Marshal(map[string]any{"rules": badDoc, "revision": setResult["revision"]})
	if _, err := s.rulesSet(badRequest); err == nil {
		t.Fatal("rules-set accepted a document with a reserved channel name")
	}
}

func TestRefreshSkipsUnsubscribedChannels(t *testing.T) {
	fake, s := newRulesSession(t)
	fake.storeRules(t, enabledTestRules(rules.Device{Name: "Linux test", Channels: []string{"work"}}))

	if _, err := s.refresh(true); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if fake.count("GET", rulesTestChannelID("images")) != 0 {
		t.Fatal("refresh fetched a channel this device does not subscribe to")
	}
	if fake.count("GET", rulesTestChannelID("work")) == 0 {
		t.Fatal("refresh did not fetch the subscribed channel")
	}
	if s.view == nil {
		t.Fatal("session did not record a view state")
	}
	found := false
	for _, channel := range s.view.Channels {
		if channel.Key == "work" {
			found = true
		}
		if channel.Key == "images" {
			t.Fatal("view includes an unsubscribed channel")
		}
	}
	if !found {
		t.Fatal("view is missing the subscribed channel")
	}
}

func TestRefreshShortCircuitsOnUnchangedRevisions(t *testing.T) {
	fake, s := newRulesSession(t)
	fake.storeRules(t, enabledTestRules(rules.Device{Name: "Linux test", Channels: []string{"work"}}))

	if _, err := s.refresh(true); err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	fake.resetRequests()

	result, err := s.refresh(false)
	if err != nil {
		t.Fatalf("second refresh: %v", err)
	}
	if fake.count("GET", rulesTestCoreID()) != 0 || fake.count("GET", rulesTestChannelID("work")) != 0 || fake.count("GET", rulesTestRulesID()) != 0 {
		t.Fatalf("unchanged refresh performed a GET instead of short-circuiting; requests=%v", fake.requests)
	}
	if fake.count("HEAD", rulesTestCoreID()) == 0 {
		t.Fatal("unchanged refresh did not HEAD the core bucket")
	}
	history, ok := result.(map[string]any)
	if !ok || history["offline"].(bool) {
		t.Fatalf("short-circuited refresh reported an unexpected result: %#v", result)
	}
}

func TestActivateSelfRegistersDevice(t *testing.T) {
	fake := newRulesFakeServer()
	testServer := httptest.NewServer(fake)
	defer testServer.Close()
	fake.storeRules(t, enabledTestRules(rules.Device{Name: "Other device", Channels: []string{"*"}}))

	dir := t.TempDir()
	s := &session{configPath: filepath.Join(dir, "config.toml"), cachePath: filepath.Join(dir, "cache.clipdb")}
	body, _ := json.Marshal(map[string]any{
		"Server": testServer.URL, "Token": rulesTestToken, "Password": rulesTestPassword,
		"Machine": "Linux test", "Remember": true,
	})
	if _, err := s.configure(json.RawMessage(body)); err != nil {
		t.Fatalf("configure: %v", err)
	}

	doc := fake.rulesDocument(t)
	found := false
	for _, device := range doc.Devices {
		if strings.EqualFold(device.Name, "Linux test") {
			found = true
			if len(device.Channels) != 1 || device.Channels[0] != "*" {
				t.Fatalf("self-registered device channels = %#v", device.Channels)
			}
		}
	}
	if !found {
		t.Fatalf("device did not self-register: %#v", doc.Devices)
	}
	// The pre-existing device must be left untouched.
	otherFound := false
	for _, device := range doc.Devices {
		if device.Name == "Other device" {
			otherFound = true
		}
	}
	if !otherFound {
		t.Fatal("self-registration clobbered the existing device list")
	}
}

func TestMutatePendingWriteThroughRetry(t *testing.T) {
	fake, s := newRulesSession(t)
	// "Linux test" explicitly subscribes to zero channels (core only), so an
	// entry whose route matches "images" must be written through rather than
	// delivered locally.
	fake.storeRules(t, enabledTestRules(rules.Device{Name: "Linux test", Channels: []string{}}))
	if _, err := s.refresh(true); err != nil {
		t.Fatalf("refresh: %v", err)
	}

	fake.breakBucket(rulesTestChannelID("images"))
	putRequest := json.RawMessage(`{"text":"picture","name":"","group":"","pinned":false,"is_template":false,"duplicate":"move",` +
		`"rich_text":{"html_fragment":"<img src=\"data:image/png;base64,AAAA\">","preferred_format":"Html"}}`)
	result, err := s.put(putRequest)
	if err != nil {
		t.Fatalf("put with a broken images bucket unexpectedly failed the whole save: %v", err)
	}
	putResult, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("put result = %#v", result)
	}
	pendingChannels, ok := putResult["pendingChannels"].([]string)
	if !ok || len(pendingChannels) != 1 || pendingChannels[0] != "images" {
		t.Fatalf("put result pendingChannels = %#v, want [images]", putResult["pendingChannels"])
	}
	if data, err := platform.ReadPrivate(s.pendingWritesFile()); err != nil || len(data) == 0 {
		t.Fatalf("pending write was not persisted to disk: data=%q err=%v", data, err)
	}
	if fake.count("PUT", rulesTestChannelID("images")) == 0 {
		t.Fatal("the write-through attempt never reached the broken images bucket")
	}
	// Nothing should have reached the images bucket's stored content, since
	// every PUT to it failed.
	fake.fixBucket(rulesTestChannelID("images"))

	if _, err := s.refresh(true); err != nil {
		t.Fatalf("refresh after fixing the images bucket: %v", err)
	}
	if _, err := platform.ReadPrivate(s.pendingWritesFile()); err == nil {
		t.Fatal("pending write-through was not cleared after a successful retry")
	}
	imagesDB := fake.database(t, rulesTestChannelID("images"))
	if len(imagesDB.Entries) != 1 {
		t.Fatalf("images channel entries after retry = %#v", imagesDB.Entries)
	}
}

// TestRulesSetConflictPreservesLocalEditOnLWW guards against a regression
// where rulesSet only stamped UpdatedUnixMs when it was blank, leaving a
// client-submitted document pinned at the stale timestamp it was fetched
// with. On a 409 that stale timestamp always loses spec section 4's
// whole-document LWW merge against whatever the server already holds (which
// is, by definition, newer than what this client last saw), silently
// discarding the user's edit while rules-set still reported success.
func TestRulesSetConflictPreservesLocalEditOnLWW(t *testing.T) {
	fake, s := newRulesSession(t)
	original := &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 1000, UpdatedBy: "Desktop",
		Channels: []rules.Channel{{Name: "Original", Route: rules.Route{Groups: []string{"A"}}}},
		Devices:  []rules.Device{},
	}
	fake.storeRules(t, original)

	getResult, err := s.rulesGet()
	if err != nil {
		t.Fatalf("rules-get: %v", err)
	}
	got, ok := getResult.(map[string]any)
	if !ok {
		t.Fatalf("rules-get result = %#v", getResult)
	}
	staleRevision, _ := got["revision"].(string)
	if staleRevision == "" {
		t.Fatal("rules-get returned a blank revision for an existing document")
	}

	// A concurrent edit from another device lands after the local fetch,
	// advancing the bucket to a revision the stale local fetch does not
	// know, but its UpdatedUnixMs (2000) is nowhere close to "now": the
	// local edit below is the actual most-recent action in wall-clock time,
	// even though it is based on a stale fetch.
	concurrent := &rules.Document{
		Clipman: "sync-rules", Version: 1, Enabled: true,
		UpdatedUnixMs: 2000, UpdatedBy: "Other device",
		Channels: []rules.Channel{{Name: "Original", Route: rules.Route{Groups: []string{"A"}}}},
		Devices:  []rules.Device{},
	}
	fake.storeRules(t, concurrent)

	// A naive client echoes back exactly what rules-get returned, plus the
	// user's change, and submits it against the now-superseded revision.
	localEdit := map[string]any{
		"Clipman": "sync-rules", "Version": 1, "Enabled": true,
		"UpdatedUnixMs": 1000, "UpdatedBy": "Desktop",
		"Channels": []map[string]any{
			{"Name": "Original", "Route": map[string]any{"Groups": []string{"A"}}},
			{"Name": "Local Edit", "Route": map[string]any{"Groups": []string{"B"}}},
		},
		"Devices": []map[string]any{},
	}
	setRequest, _ := json.Marshal(map[string]any{"rules": localEdit, "revision": staleRevision})
	result, err := s.rulesSet(setRequest)
	if err != nil {
		t.Fatalf("rules-set: %v", err)
	}
	setResult, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("rules-set result = %#v", result)
	}
	stored, ok := setResult["rules"].(rules.Document)
	if !ok {
		t.Fatalf("rules-set did not return the stored document: %#v", setResult["rules"])
	}
	found := false
	for _, channel := range stored.Channels {
		if channel.Name == "Local Edit" {
			found = true
		}
	}
	if !found {
		t.Fatalf("local edit was discarded by the LWW merge; stored channels = %#v", stored.Channels)
	}
	if stored.UpdatedUnixMs <= concurrent.UpdatedUnixMs {
		t.Fatalf("local edit's timestamp (%d) was not advanced past the concurrent edit (%d)", stored.UpdatedUnixMs, concurrent.UpdatedUnixMs)
	}

	final := fake.rulesDocument(t)
	onServer := false
	for _, channel := range final.Channels {
		if channel.Name == "Local Edit" {
			onServer = true
		}
	}
	if !onServer {
		t.Fatal("local edit was not persisted to the server")
	}
}

// TestMutateFailsWhenSubscribedChannelUploadFails guards the distinction
// WriteThroughError.Committed draws (see its doc comment in
// internal/syncengine/channels.go): when a SUBSCRIBED channel's own upload
// fails in the same save as an unsubscribed-channel write-through, the save
// must be reported as failed - not as a success carrying pendingChannels -
// even though the write-through entries are still parked for later retry.
func TestMutateFailsWhenSubscribedChannelUploadFails(t *testing.T) {
	fake, s := newRulesSession(t)
	// "Linux test" subscribes to "work" only; "images" stays unsubscribed so
	// an image entry created in the same save requires a write-through.
	fake.storeRules(t, enabledTestRules(rules.Device{Name: "Linux test", Channels: []string{"work"}}))
	if _, err := s.refresh(true); err != nil {
		t.Fatalf("refresh: %v", err)
	}

	fake.breakBucket(rulesTestChannelID("work"))
	fake.breakBucket(rulesTestChannelID("images"))

	result, err := s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		db.Entries = append(db.Entries,
			model.Entry{
				ID: merge.NewID(), Text: "work note", Group: "Work",
				CreatedUnixMs: now, LastUsedUnixMs: now, ModifiedUnixMs: now,
				Extra: map[string]json.RawMessage{},
			},
			model.Entry{
				ID: merge.NewID(), Text: "picture",
				CreatedUnixMs: now, LastUsedUnixMs: now, ModifiedUnixMs: now,
				Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`{"HtmlFragment":"<img src=\"data:image/png;base64,AAAA\">"}`)},
			},
		)
		db.UpdatedUnixMs = now
		return true, nil, nil
	})
	if err == nil {
		t.Fatalf("mutate succeeded despite a broken subscribed channel: result=%#v", result)
	}
	if result != nil {
		t.Fatalf("mutate returned a non-nil result on failure: %#v", result)
	}
	var pending *syncengine.WriteThroughError
	if !errors.As(err, &pending) {
		t.Fatalf("error was not a WriteThroughError: %v", err)
	}
	if pending.Committed {
		t.Fatal("WriteThroughError reported Committed=true despite the subscribed work channel upload failing")
	}
	if _, ok := pending.Pending["images"]; !ok {
		t.Fatalf("pending entries did not include the images channel: %#v", pending.Pending)
	}
	if data, readErr := platform.ReadPrivate(s.pendingWritesFile()); readErr != nil || len(data) == 0 {
		t.Fatalf("pending write was not parked to disk despite Committed=false: data=%q err=%v", data, readErr)
	}
}
