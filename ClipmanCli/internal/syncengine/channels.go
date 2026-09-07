package syncengine

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/rules"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
)

// ChannelState is one channel bucket as it stood at the last transfer. Key is
// "" for the core channel, which keeps using the engine's configured database
// id. PlainHash is the SHA-256 of the deterministic plaintext JSON of Database
// and is what dirty detection compares against, because ciphertext differs on
// every encode (spec section 5, upload step 4).
type ChannelState struct {
	Key       string
	Revision  string
	PlainHash [32]byte
	Database  *model.Database

	// blob is the encoded container the state was loaded from (or last wrote),
	// kept so re-encodes reuse the bucket's PBKDF2 salt. exists reports whether
	// the bucket is present on the server, which selects If-None-Match versus
	// If-Match. databaseID is the derived bucket id for this channel.
	blob       []byte
	exists     bool
	databaseID string
}

// ViewState is the result of a channel-aware read or mutation: the rules
// document that was in effect, the per-channel states it produced, the merged
// view shown to the user, and the residence map from entry id to channel key
// ("" for core).
type ViewState struct {
	Rules         *rules.Document
	RulesRevision string
	Channels      []ChannelState
	View          *model.Database
	Residence     map[string]string
}

// ReadView performs the download half of spec section 5: it reads the rules
// document, fetches core plus every channel deviceName subscribes to, and
// merges them into a single view. With rules absent or disabled it produces
// exactly what the single-bucket Read produces, normalized.
func (e *Engine) ReadView(ctx context.Context, deviceName string) (*ViewState, error) {
	return e.readView(ctx, deviceName, time.Now().UnixMilli())
}

// WriteThroughError reports that entries bound for channels this device does
// not subscribe to could not be committed (spec section 6: the writer keeps
// them in a small local pending store and retries after the next successful
// poll). Pending holds them per channel key. The mutation itself is not rolled
// back: MutateView still returns the committed ViewState alongside this error,
// and channels the failed entries did not belong to were uploaded normally.
type WriteThroughError struct {
	Pending map[string][]model.Entry
	Err     error
}

func (w *WriteThroughError) Error() string {
	keys := make([]string, 0, len(w.Pending))
	for key := range w.Pending {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return fmt.Sprintf("entries for the %s channel could not be delivered: %v", strings.Join(keys, ", "), w.Err)
}

func (w *WriteThroughError) Unwrap() error { return w.Err }

// MutateView applies mutate to the merged view and commits the result: it
// re-routes every entry, rebuilds one database per channel, writes entries
// bound for unsubscribed channels straight through, and uploads only the
// channels whose plaintext actually changed. The returned ViewState is the
// committed state, so callers need no second download.
//
// Uploads follow the add-then-remove two-phase order of spec section 5, upload
// step 5. Phase 1 uploads every channel while still including the entries that
// are leaving it and withholding its new relocation markers, so targets gain
// before sources lose. Phase 2 then rewrites only the losing channels without
// their departures. That ordering is safe for channels that gain and lose in
// the same save, and for relocation chains and cycles, without any dependency
// analysis: a failure in either phase can leave an entry in two channels, which
// view assembly resolves, but never removes it from the only channel it was in.
//
// MutateView can return a non-nil ViewState together with a non-nil error: a
// *WriteThroughError means the local channels were committed and only entries
// bound for unsubscribed channels are outstanding.
func (e *Engine) MutateView(ctx context.Context, deviceName string, mutate func(database *model.Database) error) (*ViewState, error) {
	now := time.Now().UnixMilli()
	view, err := e.readView(ctx, deviceName, now)
	if err != nil {
		return nil, err
	}
	previousMarkers := markersByID(view.View.Deleted)
	if mutate != nil {
		if err := mutate(view.View); err != nil {
			return nil, err
		}
	}
	merge.Normalize(view.View, now)

	subscribed := make(map[string]int, len(view.Channels))
	for index := range view.Channels {
		subscribed[view.Channels[index].Key] = index
	}
	// Routing pass (spec section 5, upload steps 1-3): every entry is assigned
	// to the channel its route names, and leaving a channel leaves a relocation
	// marker behind in the channel the entry came from. departures records what
	// each channel loses, which is what the two upload phases differ over.
	routed := make(map[string][]model.Entry, len(view.Channels))
	departures := make(map[string][]model.Entry)
	pending := make(map[string][]model.Entry)
	pendingKeys := make([]string, 0)
	relocations := make(map[string][]model.DeletedEntry)
	for index := range view.View.Entries {
		entry := view.View.Entries[index]
		target := rules.RouteEntry(view.Rules, &entry)
		source, resident := view.Residence[entry.ID]
		if resident && source != target {
			departures[source] = append(departures[source], entry)
			relocations[source] = append(relocations[source], model.DeletedEntry{
				ID:            entry.ID,
				TextHash:      "",
				DeletedUnixMs: now,
				SourceMachine: deviceName,
				Extra:         map[string]json.RawMessage{},
			})
		}
		if _, ok := subscribed[target]; ok {
			routed[target] = append(routed[target], entry)
			continue
		}
		if _, ok := pending[target]; !ok {
			pendingKeys = append(pendingKeys, target)
		}
		pending[target] = append(pending[target], entry)
	}

	coreBlob := view.Channels[0].blob

	// First sync: create the core bucket before anything else so every other
	// bucket, channels and rules alike, copies its salt and one PBKDF2
	// derivation serves them all. A save that writes nothing anywhere still
	// creates no bucket.
	if !view.Channels[0].exists {
		databases := buildChannelDatabases(view, withDepartures(routed, departures), assembleMarkers(view, previousMarkers, subscribed, nil), now)
		writes := len(pendingKeys) > 0
		for index := range databases {
			if plainHash(&databases[index]) != view.Channels[index].PlainHash {
				writes = true
			}
		}
		if writes {
			if err := e.putChannel(ctx, &view.Channels[0], databases[0], coreBlob, now); err != nil {
				return nil, err
			}
			coreBlob = view.Channels[0].blob
		}
	}

	// Write-through (spec section 6) is the first thing committed after that:
	// its targets gain entries that their source channels are about to lose.
	// When one fails, the entry is not taken away from where it already lives -
	// a resident entry stays in its source channel and its relocation marker is
	// cancelled - and the caller is handed the entries that have nowhere to
	// live yet so it can retry them.
	sort.Strings(pendingKeys)
	failures := make(map[string][]model.Entry)
	var writeThroughErr error
	for _, key := range pendingKeys {
		if err := e.writeThrough(ctx, key, pending[key], coreBlob, now); err != nil {
			if writeThroughErr == nil {
				writeThroughErr = err
			}
			failures[key] = pending[key]
			for _, entry := range pending[key] {
				source, resident := view.Residence[entry.ID]
				if !resident {
					continue
				}
				routed[source] = append(routed[source], entry)
				departures[source] = removeEntry(departures[source], entry.ID)
				relocations[source] = removeMarkerFor(relocations[source], entry.ID)
			}
		}
	}

	// The result an error is reported with. Entries that could not be written
	// through must reach the caller even when a later upload fails, or the only
	// record of them is gone.
	finish := func(cause error) (*ViewState, error) {
		committed, residence := buildView(view.Channels, now)
		state := &ViewState{
			Rules:         view.Rules,
			RulesRevision: view.RulesRevision,
			Channels:      view.Channels,
			View:          committed,
			Residence:     residence,
		}
		if len(failures) > 0 {
			return state, &WriteThroughError{Pending: failures, Err: errors.Join(writeThroughErr, cause)}
		}
		if cause != nil {
			return nil, cause
		}
		return state, nil
	}

	// Phase 1: every channel keeps the entries it is about to lose and withholds
	// its new relocation markers, so this pass only ever adds.
	phaseOne := buildChannelDatabases(view, withDepartures(routed, departures), assembleMarkers(view, previousMarkers, subscribed, nil), now)
	for index := range view.Channels {
		channel := &view.Channels[index]
		if plainHash(&phaseOne[index]) == channel.PlainHash {
			continue
		}
		if err := e.putChannel(ctx, channel, phaseOne[index], coreBlob, now); err != nil {
			return finish(err)
		}
		if index == 0 {
			coreBlob = channel.blob
		}
	}

	// Phase 2: with every addition committed, the losing channels drop their
	// departures and gain their relocation markers. Their PlainHash ends up on
	// this final content.
	phaseTwo := buildChannelDatabases(view, routed, assembleMarkers(view, previousMarkers, subscribed, relocations), now)
	for index := range view.Channels {
		channel := &view.Channels[index]
		if len(departures[channel.Key]) == 0 {
			continue
		}
		if plainHash(&phaseTwo[index]) == channel.PlainHash {
			continue
		}
		if err := e.putChannel(ctx, channel, phaseTwo[index], coreBlob, now); err != nil {
			return finish(err)
		}
		if index == 0 {
			coreBlob = channel.blob
		}
	}

	return finish(nil)
}

// assembleMarkers files tombstones per channel. Tombstones are channel-local:
// each channel keeps the markers it already carried, and only markers the
// mutation created or refreshed are filed against the channel the entry lived
// in. Relocation markers are added last, for the channels their entries left.
func assembleMarkers(view *ViewState, previous map[string]model.DeletedEntry, subscribed map[string]int, relocations map[string][]model.DeletedEntry) map[string][]model.DeletedEntry {
	markers := make(map[string][]model.DeletedEntry, len(view.Channels))
	for index := range view.Channels {
		channel := &view.Channels[index]
		markers[channel.Key] = append([]model.DeletedEntry{}, channel.Database.Deleted...)
	}
	for _, marker := range view.View.Deleted {
		if before, ok := previous[comparableID(marker.ID)]; ok &&
			before.DeletedUnixMs == marker.DeletedUnixMs && before.TextHash == marker.TextHash {
			continue
		}
		home := view.Residence[marker.ID]
		if _, ok := subscribed[home]; !ok {
			home = ""
		}
		markers[home] = append(markers[home], marker)
	}
	for key, relocated := range relocations {
		if _, ok := subscribed[key]; ok {
			markers[key] = append(markers[key], relocated...)
		}
	}
	return markers
}

// buildChannelDatabases rebuilds one database per subscribed channel from the
// routed entries and the markers filed against it, in view.Channels order.
func buildChannelDatabases(view *ViewState, routed map[string][]model.Entry, markers map[string][]model.DeletedEntry, now int64) []model.Database {
	databases := make([]model.Database, len(view.Channels))
	for index := range view.Channels {
		channel := &view.Channels[index]
		database := model.Database{
			Version:       channel.Database.Version,
			UpdatedUnixMs: now,
			Entries:       routed[channel.Key],
			Deleted:       dropMarkersForEntries(markers[channel.Key], routed[channel.Key]),
			Extra:         cloneExtra(channel.Database.Extra),
		}
		if channel.Key == "" {
			database.Extra = cloneExtra(view.View.Extra)
		}
		if database.Version < 1 {
			database.Version = 1
		}
		merge.Normalize(&database, now)
		databases[index] = database
	}
	return databases
}

// withDepartures is the phase-1 entry assignment: what each channel keeps plus
// what it is about to lose, so the first upload of a save only ever adds.
func withDepartures(routed, departures map[string][]model.Entry) map[string][]model.Entry {
	if len(departures) == 0 {
		return routed
	}
	combined := make(map[string][]model.Entry, len(routed)+len(departures))
	for key, entries := range routed {
		combined[key] = entries
	}
	for key, leaving := range departures {
		if len(leaving) == 0 {
			continue
		}
		combined[key] = append(append([]model.Entry{}, combined[key]...), leaving...)
	}
	return combined
}

func removeEntry(entries []model.Entry, id string) []model.Entry {
	kept := entries[:0]
	for _, entry := range entries {
		if comparableID(entry.ID) == comparableID(id) {
			continue
		}
		kept = append(kept, entry)
	}
	return kept
}

func removeMarkerFor(markers []model.DeletedEntry, id string) []model.DeletedEntry {
	kept := markers[:0]
	for _, marker := range markers {
		if comparableID(marker.ID) == comparableID(id) {
			continue
		}
		kept = append(kept, marker)
	}
	return kept
}

// readView is ReadView with the timestamp supplied by the caller, so that a
// mutation normalizes what it reads and what it uploads at the same instant.
// Dirty detection depends on that: model.Database carries UpdatedUnixMs, so a
// rebuild stamped with a different clock reading would never match the hash
// recorded at the last transfer.
func (e *Engine) readView(ctx context.Context, deviceName string, now int64) (*ViewState, error) {
	if e.Client == nil {
		return nil, errors.New("no Clipman Server is configured")
	}
	core, err := e.readChannel(ctx, "", e.Client.DatabaseID, now)
	if err != nil {
		return nil, err
	}
	document, rulesRevision, err := e.readRules(ctx, core.blob)
	if err != nil {
		return nil, err
	}
	channels := []ChannelState{core}
	for _, key := range subscribedKeys(document, deviceName) {
		databaseID := identity.ChannelDatabaseID(e.syncToken(), e.Password, key)
		if databaseID == "" {
			continue
		}
		state, channelErr := e.readChannel(ctx, key, databaseID, now)
		if channelErr != nil {
			return nil, channelErr
		}
		channels = append(channels, state)
	}
	view, residence := buildView(channels, now)
	return &ViewState{
		Rules:         document,
		RulesRevision: rulesRevision,
		Channels:      channels,
		View:          view,
		Residence:     residence,
	}, nil
}

// readRules fetches and decodes the rules document. A missing bucket falls back
// to the caller-supplied cache and re-uploads it create-only (spec section 4,
// Caching); a blob that cannot be decoded or parsed degrades to no rules at
// all, because a damaged rules document must not stop history from syncing.
// coreBlob supplies the salt the re-upload shares with the history database.
func (e *Engine) readRules(ctx context.Context, coreBlob []byte) (*rules.Document, string, error) {
	rulesID := identity.SyncRulesDatabaseID(e.syncToken(), e.Password)
	if rulesID == "" {
		return nil, "", nil
	}
	client := e.bucketClient(rulesID)
	download, err := client.Get(ctx)
	if errors.Is(err, server.ErrNotFound) {
		if e.CachedRules == nil {
			return nil, "", nil
		}
		return e.CachedRules, e.uploadCachedRules(ctx, client, coreBlob), nil
	}
	if err != nil {
		return nil, "", err
	}
	payload, _, err := clipdb.DecodeRaw(download.Data, e.Password)
	if err != nil {
		return nil, "", nil
	}
	document, err := rules.Parse(payload)
	if err != nil {
		return nil, "", nil
	}
	// When the cache wins the last-writer-wins merge, the effective document is
	// not the one the server holds, so no revision is reported: an If-Match
	// against it would claim an edit was based on a document it never saw.
	merged := rules.MergeDocuments(e.CachedRules, document)
	if merged != document {
		return merged, "", nil
	}
	return merged, download.Revision, nil
}

// uploadCachedRules restores a rules bucket that disappeared from the server
// from the local cache, with If-None-Match so a document another device wrote
// in the meantime always wins. It is best effort: a failure leaves the cached
// document in effect for this read and is retried on the next one.
func (e *Engine) uploadCachedRules(ctx context.Context, client *server.Client, coreBlob []byte) string {
	payload, err := rules.Serialize(e.CachedRules)
	if err != nil {
		return ""
	}
	var salt []byte
	if len(coreBlob) > 0 {
		if _, coreSalt, decodeErr := clipdb.DecodeRaw(coreBlob, e.Password); decodeErr == nil {
			salt = coreSalt
		}
	}
	blob, err := clipdb.EncodeRaw(payload, e.Password, salt)
	if err != nil {
		return ""
	}
	metadata, err := client.Put(ctx, blob, "", true)
	if err != nil {
		return ""
	}
	return metadata.Revision
}

// readChannel downloads one channel bucket. A missing bucket is an empty
// database, not an error, so a channel that nobody has written to yet behaves
// like an empty one.
func (e *Engine) readChannel(ctx context.Context, key, databaseID string, now int64) (ChannelState, error) {
	state := ChannelState{Key: key, databaseID: databaseID}
	client := e.Client
	if key != "" {
		client = e.bucketClient(databaseID)
	}
	download, err := client.Get(ctx)
	switch {
	case errors.Is(err, server.ErrNotFound):
		database := model.NewDatabase(now)
		state.Database = &database
	case err != nil:
		return ChannelState{}, err
	default:
		database, decodeErr := clipdb.Decode(download.Data, e.Password, e.Limits)
		if decodeErr != nil {
			return ChannelState{}, decodeErr
		}
		state.Database = &database
		state.blob = download.Data
		state.Revision = download.Revision
		state.exists = true
	}
	merge.Normalize(state.Database, now)
	state.PlainHash = plainHash(state.Database)
	return state, nil
}

// putChannel uploads one channel with the conditional header its state calls
// for, and on a conflict re-reads that channel, merges the local build into the
// server copy and retries (spec section 5, upload step 5). state is updated to
// the committed revision, blob and hash.
func (e *Engine) putChannel(ctx context.Context, state *ChannelState, database model.Database, coreBlob []byte, now int64) error {
	retries := e.Retries
	if retries <= 0 {
		retries = 3
	}
	client := e.Client
	if state.Key != "" {
		client = e.bucketClient(state.databaseID)
	}
	var last error
	for attempt := 0; attempt <= retries; attempt++ {
		// A channel blob created for the first time copies the core database's
		// salt so one PBKDF2 derivation serves every channel.
		existing := state.blob
		if len(existing) == 0 {
			existing = coreBlob
		}
		encoded, err := clipdb.Encode(database, e.Password, existing)
		if err != nil {
			return err
		}
		metadata, err := client.Put(ctx, encoded, state.Revision, !state.exists)
		if err == nil {
			committed := database
			state.Database = &committed
			state.PlainHash = plainHash(&committed)
			state.Revision = metadata.Revision
			state.blob = encoded
			state.exists = true
			return nil
		}
		if !errors.Is(err, server.ErrConflict) {
			return err
		}
		last = err
		time.Sleep(time.Duration(30+attempt*40) * time.Millisecond)
		fresh, readErr := e.readChannel(ctx, state.Key, state.databaseID, now)
		if readErr != nil {
			return readErr
		}
		merged := *fresh.Database
		merge.Merge(&merged, database, now)
		state.Revision = fresh.Revision
		state.blob = fresh.blob
		state.exists = fresh.exists
		database = merged
	}
	return fmt.Errorf("channel %q changed repeatedly; the change was not committed: %w", channelName(state.Key), last)
}

// writeThrough performs the one-shot fetch-merge-put of spec section 6 for a
// channel this device does not subscribe to. The channel is discarded again
// afterwards, so its contents never reach the local view.
func (e *Engine) writeThrough(ctx context.Context, key string, entries []model.Entry, coreBlob []byte, now int64) error {
	databaseID := identity.ChannelDatabaseID(e.syncToken(), e.Password, key)
	if databaseID == "" {
		return fmt.Errorf("cannot address the %q channel without a server token and history password", key)
	}
	state, err := e.readChannel(ctx, key, databaseID, now)
	if err != nil {
		return err
	}
	database := *state.Database
	database.Deleted = dropMarkersForEntries(database.Deleted, entries)
	source := model.NewDatabase(now)
	source.Entries = append(source.Entries, entries...)
	merge.Merge(&database, source, now)
	return e.putChannel(ctx, &state, database, coreBlob, now)
}

// buildView merges the per-channel databases into the single view of spec
// section 5, download steps 3 and 4, and records which channel each surviving
// entry came from.
func buildView(channels []ChannelState, now int64) (*model.Database, map[string]string) {
	merged := model.NewDatabase(now)
	view := &merged
	owners := make([]string, 0)
	indexByID := make(map[string]int)
	for _, channel := range channels {
		if channel.Database == nil {
			continue
		}
		if channel.Database.Version > view.Version {
			view.Version = channel.Database.Version
		}
		if channel.Key == "" {
			view.Extra = cloneExtra(channel.Database.Extra)
		}
		for _, entry := range channel.Database.Entries {
			identifier := comparableID(entry.ID)
			if index, ok := indexByID[identifier]; ok && identifier != "" {
				// The same id in two channels is a move race: the copy with the
				// higher ModifiedUnixMs wins and the loser is dropped.
				if entry.ModifiedUnixMs > view.Entries[index].ModifiedUnixMs {
					view.Entries[index] = entry
					owners[index] = channel.Key
				}
				continue
			}
			view.Entries = append(view.Entries, entry)
			owners = append(owners, channel.Key)
			if identifier != "" {
				indexByID[identifier] = len(view.Entries) - 1
			}
		}
	}

	// Tombstones apply within their own channel only, with one exception: a
	// marker with a non-empty TextHash also suppresses matching-text entries in
	// other channels.
	suppressed := make([]bool, len(view.Entries))
	for _, channel := range channels {
		if channel.Database == nil {
			continue
		}
		for _, marker := range channel.Database.Deleted {
			if marker.TextHash == "" {
				continue
			}
			for index := range view.Entries {
				if suppressed[index] || owners[index] == channel.Key {
					continue
				}
				if textMarkerSuppresses(marker, view.Entries[index]) {
					suppressed[index] = true
				}
			}
		}
	}
	entries := make([]model.Entry, 0, len(view.Entries))
	residence := make(map[string]string, len(view.Entries))
	live := make(map[string]bool, len(view.Entries))
	for index, entry := range view.Entries {
		if suppressed[index] {
			continue
		}
		entries = append(entries, entry)
		residence[entry.ID] = owners[index]
		live[comparableID(entry.ID)] = true
	}
	view.Entries = entries

	// The view carries every channel's markers so callers see the same deleted
	// history a single-bucket client would, except for markers contradicted by
	// a live entry elsewhere: a relocation marker names an id that now lives in
	// another channel, and applying it to the view would delete the entry it
	// only meant to move.
	for _, channel := range channels {
		if channel.Database == nil {
			continue
		}
		for _, marker := range channel.Database.Deleted {
			if live[comparableID(marker.ID)] {
				continue
			}
			view.Deleted = append(view.Deleted, marker)
		}
	}
	merge.Normalize(view, now)

	final := make(map[string]string, len(view.Entries))
	for _, entry := range view.Entries {
		if key, ok := residence[entry.ID]; ok {
			final[entry.ID] = key
		}
	}
	return view, final
}

// textMarkerSuppresses applies the text-hash half of merge.IsDeleted, which is
// the only tombstone rule that reaches across channel boundaries.
func textMarkerSuppresses(marker model.DeletedEntry, entry model.Entry) bool {
	if marker.TextHash == "" || !strings.EqualFold(marker.TextHash, merge.TextHash(entry.Text)) {
		return false
	}
	changed := entry.CreatedUnixMs
	if entry.LastUsedUnixMs > changed {
		changed = entry.LastUsedUnixMs
	}
	return marker.DeletedUnixMs <= 0 || changed <= marker.DeletedUnixMs
}

// dropMarkersForEntries removes markers naming an entry that is being written
// into the same channel. Without this a relocation marker left behind by an
// earlier move would delete the entry again when a rule change moves it back.
func dropMarkersForEntries(markers []model.DeletedEntry, entries []model.Entry) []model.DeletedEntry {
	if len(markers) == 0 || len(entries) == 0 {
		return markers
	}
	resident := make(map[string]bool, len(entries))
	for _, entry := range entries {
		resident[comparableID(entry.ID)] = true
	}
	kept := make([]model.DeletedEntry, 0, len(markers))
	for _, marker := range markers {
		if resident[comparableID(marker.ID)] {
			continue
		}
		kept = append(kept, marker)
	}
	return kept
}

// subscribedKeys lists the channels deviceName downloads besides core, in
// document order. A device that is not listed subscribes to everything.
func subscribedKeys(document *rules.Document, deviceName string) []string {
	if document == nil || !document.Enabled {
		return nil
	}
	subscribed := rules.SubscribedChannels(document, deviceName)
	wanted := make(map[string]bool, len(subscribed))
	for _, key := range subscribed {
		wanted[key] = true
	}
	keys := make([]string, 0, len(document.Channels))
	seen := make(map[string]bool, len(document.Channels))
	for _, channel := range document.Channels {
		key := rules.ChannelKey(channel.Name)
		if key == "" || seen[key] {
			continue
		}
		if subscribed != nil && !wanted[key] {
			continue
		}
		seen[key] = true
		keys = append(keys, key)
	}
	return keys
}

// markersByID indexes tombstones by their comparison key so a mutation can be
// told from an unchanged marker it merely read.
func markersByID(markers []model.DeletedEntry) map[string]model.DeletedEntry {
	byID := make(map[string]model.DeletedEntry, len(markers))
	for _, marker := range markers {
		byID[comparableID(marker.ID)] = marker
	}
	return byID
}

// plainHash is the dirty-detection hash of spec section 5, upload step 4: the
// SHA-256 of the deterministic plaintext JSON with the database-level
// UpdatedUnixMs zeroed. Zeroing it is what makes the hash durable, because
// normalization restamps that field on every pass, so two reads of an
// unchanged bucket at different times still hash alike.
//
// One case stays clock-dependent by design: merge.Normalize back-fills a zero
// CreatedUnixMs or LastUsedUnixMs from the current time, so a channel holding
// legacy entries written without timestamps hashes differently on every read
// and is treated as dirty until the first save rewrites it with real ones.
// That is self-healing and costs one extra upload.
func plainHash(database *model.Database) [32]byte {
	durable := *database
	durable.UpdatedUnixMs = 0
	encoded, err := json.Marshal(durable)
	if err != nil {
		return [32]byte{}
	}
	return sha256.Sum256(encoded)
}

func cloneExtra(source map[string]json.RawMessage) map[string]json.RawMessage {
	clone := make(map[string]json.RawMessage, len(source))
	for key, value := range source {
		clone[key] = append(json.RawMessage(nil), value...)
	}
	return clone
}

// comparableID is the case-insensitive comparison form merge uses for entry and
// tombstone ids.
func comparableID(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func channelName(key string) string {
	if key == "" {
		return "core"
	}
	return key
}

// bucketClient addresses another bucket on the same server with the same
// credentials and transport as the configured client.
func (e *Engine) bucketClient(databaseID string) *server.Client {
	clone := *e.Client
	clone.DatabaseID = databaseID
	return &clone
}

// syncToken is the token channel and rules bucket ids are derived from. It
// falls back to the token the client authenticates with, which is the same
// value for every caller that derives its database id from the same input.
func (e *Engine) syncToken() string {
	if strings.TrimSpace(e.Token) != "" {
		return e.Token
	}
	if e.Client != nil {
		return e.Client.Token
	}
	return ""
}
