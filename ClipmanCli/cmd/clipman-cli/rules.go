package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/rules"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
)

// stringListFlag collects repeated occurrences of a flag, such as --group
// used more than once, into an ordered list.
type stringListFlag []string

func (s *stringListFlag) String() string { return strings.Join(*s, ",") }
func (s *stringListFlag) Set(value string) error {
	*s = append(*s, value)
	return nil
}

// rulesCachePath and pendingWritesPath live beside the configuration file,
// matching how init already resolves where a profile's data lives. Neither
// file carries a secret: the rules document names channels and devices, and
// a pending write is clip text already destined for the server.
func rulesCachePath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "rules-cache.json")
}
func pendingWritesPath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "pending-writes.json")
}

// loadRulesCache reads the last-seen rules document from disk, or returns nil
// when no cache exists or it cannot be parsed. rules.Parse's lenient handling
// of a future Version means a cached forward-compatible document survives
// this round trip unchanged.
func loadRulesCache(configPath string) *rules.Document {
	data, err := platform.ReadPrivate(rulesCachePath(configPath))
	if err != nil {
		return nil
	}
	doc, err := rules.Parse(data)
	if err != nil {
		return nil
	}
	return doc
}

// cacheRulesFromView updates the on-disk rules cache after a ReadView or
// MutateView call that observed a document, per spec section 4 (every client
// caches the last-seen rules document locally).
func cacheRulesFromView(ctx *appContext, view *syncengine.ViewState) {
	if view == nil {
		return
	}
	cacheRulesDocument(ctx, view.Rules)
}

func cacheRulesDocument(ctx *appContext, doc *rules.Document) {
	if doc == nil {
		return
	}
	// A read-only (future-version) document must never arm the engine's 404
	// fallback: readRules re-uploads Engine.CachedRules with If-None-Match
	// when the bucket disappears, and this client is not allowed to rewrite a
	// document it only partly understands. The on-disk copy is still written,
	// beside it, purely for display on the next process start.
	if rules.ReadOnly(doc) {
		ctx.engine.CachedRules = nil
	} else {
		ctx.engine.CachedRules = doc
	}
	data, err := rules.Serialize(doc)
	if err != nil {
		return
	}
	_ = platform.SavePrivate(rulesCachePath(ctx.configPath), data)
}

// initialCachedRules loads the on-disk rules cache for seeding a fresh
// Engine.CachedRules at startup, withholding a read-only document for the
// same reason cacheRulesDocument does.
func initialCachedRules(configPath string) *rules.Document {
	doc := loadRulesCache(configPath)
	if rules.ReadOnly(doc) {
		return nil
	}
	return doc
}

// --- pending write-through store (spec section 6) ---------------------------

func loadPendingWrites(configPath string) map[string][]model.Entry {
	data, err := platform.ReadPrivate(pendingWritesPath(configPath))
	if err != nil {
		return nil
	}
	var pending map[string][]model.Entry
	if err := json.Unmarshal(data, &pending); err != nil {
		return nil
	}
	return pending
}

func savePendingWrites(configPath string, pending map[string][]model.Entry) error {
	nonEmpty := false
	for _, entries := range pending {
		if len(entries) > 0 {
			nonEmpty = true
			break
		}
	}
	if !nonEmpty {
		_ = os.Remove(pendingWritesPath(configPath))
		return nil
	}
	data, err := json.Marshal(pending)
	if err != nil {
		return err
	}
	return platform.SavePrivate(pendingWritesPath(configPath), data)
}

// recordPendingWrites merges newly failed write-through entries into whatever
// is already parked on disk, keyed by entry id so a repeated failure does not
// duplicate an entry already waiting for the same channel.
func recordPendingWrites(ctx *appContext, newPending map[string][]model.Entry) {
	if len(newPending) == 0 {
		return
	}
	existing := loadPendingWrites(ctx.configPath)
	if existing == nil {
		existing = map[string][]model.Entry{}
	}
	for key, entries := range newPending {
		existing[key] = mergeEntriesByID(existing[key], entries)
	}
	_ = savePendingWrites(ctx.configPath, existing)
}

func mergeEntriesByID(existing, incoming []model.Entry) []model.Entry {
	byID := make(map[string]model.Entry, len(existing)+len(incoming))
	order := make([]string, 0, len(existing)+len(incoming))
	add := func(e model.Entry) {
		if _, ok := byID[e.ID]; !ok {
			order = append(order, e.ID)
		}
		byID[e.ID] = e
	}
	for _, e := range existing {
		add(e)
	}
	for _, e := range incoming {
		add(e)
	}
	result := make([]model.Entry, 0, len(order))
	for _, id := range order {
		result = append(result, byID[id])
	}
	return result
}

// absorbWriteThrough handles the *syncengine.WriteThroughError shape MutateView
// can return alongside a ViewState: the undelivered entries are always parked
// (they are real, regardless of what else happened), and a one-line notice is
// printed per affected channel. Whether the caller may treat this as success
// depends entirely on Committed (see the WriteThroughError doc comment in
// internal/syncengine/channels.go): only Committed == true means every
// subscribed channel upload also succeeded, in which case this returns nil.
// Committed == false means part of the mutation itself was not saved, and the
// original error is returned unchanged so the caller reports a failure. Any
// error that is not a *WriteThroughError is also returned unchanged.
func absorbWriteThrough(ctx *appContext, err error) error {
	if err == nil {
		return nil
	}
	var pending *syncengine.WriteThroughError
	if !errors.As(err, &pending) {
		return err
	}
	recordPendingWrites(ctx, pending.Pending)
	keys := make([]string, 0, len(pending.Pending))
	for key := range pending.Pending {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if !ctx.globals.quiet {
		for _, key := range keys {
			fmt.Fprintf(os.Stderr, "Added entry could not reach channel %s yet; will retry on next sync.\n", key)
		}
	}
	if !pending.Committed {
		return err
	}
	return nil
}

// retryPendingWrites is called at the start of sync and list: any entry left
// over from a failed write-through is retried, and cleared from the pending
// store on success. It is entirely best effort; a channel that still cannot
// be reached simply stays pending for the next attempt.
//
// Every parked entry is re-routed against the CURRENT rules document before
// retrying, rather than resent to the channel key it was originally parked
// under: that channel may since have been removed (spec section 5, channel
// deletion), and delivering it there regardless would resurrect a bucket that
// no longer belongs in the document. An entry that no longer routes anywhere
// (core) is delivered through a normal mutation instead of a channel
// write-through, so it lands in the local view like any other capture.
func retryPendingWrites(ctx *appContext) {
	pending := loadPendingWrites(ctx.configPath)
	if len(pending) == 0 {
		return
	}
	currentDoc, _, _, _, err := fetchRulesDocument(ctx)
	if err != nil {
		verbosef(ctx.globals, "could not check sync rules before retrying pending writes: %v", err)
		return
	}

	regrouped := map[string][]model.Entry{}
	for _, entries := range pending {
		for _, entry := range entries {
			target := rules.RouteEntry(currentDoc, &entry)
			regrouped[target] = append(regrouped[target], entry)
		}
	}

	remaining := map[string][]model.Entry{}
	for target, entries := range regrouped {
		if len(entries) == 0 {
			continue
		}
		if target == "" {
			if failed := retryToCore(ctx, entries); len(failed) > 0 {
				remaining[""] = append(remaining[""], failed...)
			}
			continue
		}
		if err := writeThroughToChannel(ctx, target, entries); err != nil {
			remaining[target] = append(remaining[target], entries...)
			verbosef(ctx.globals, "retrying pending writes for channel %s failed: %v", target, err)
			continue
		}
		if !ctx.globals.quiet {
			fmt.Fprintf(os.Stderr, "Delivered %d pending entr%s to channel %s.\n", len(entries), pluralIES(len(entries)), target)
		}
	}
	_ = savePendingWrites(ctx.configPath, remaining)
}

// retryToCore delivers pending entries that now route to core (their channel
// was removed, or never routed anywhere in the first place) through a normal
// mutation, so they land in the local view instead of a channel bucket. It
// returns the entries that still could not be delivered.
func retryToCore(ctx *appContext, entries []model.Entry) []model.Entry {
	view, err := ctx.engine.MutateView(context.Background(), ctx.config.Machine, func(database *model.Database) error {
		existing := make(map[string]bool, len(database.Entries))
		for _, e := range database.Entries {
			existing[strings.ToLower(strings.TrimSpace(e.ID))] = true
		}
		for _, entry := range entries {
			if existing[strings.ToLower(strings.TrimSpace(entry.ID))] {
				continue
			}
			database.Entries = append(database.Entries, entry)
		}
		return nil
	})
	if absorbed := absorbWriteThrough(ctx, err); absorbed != nil {
		verbosef(ctx.globals, "retrying pending writes to core failed: %v", err)
		return entries
	}
	cacheRulesFromView(ctx, view)
	if !ctx.globals.quiet {
		fmt.Fprintf(os.Stderr, "Delivered %d pending entr%s to core.\n", len(entries), pluralIES(len(entries)))
	}
	return nil
}

func pluralIES(n int) string {
	if n == 1 {
		return "y"
	}
	return "ies"
}

// writeThroughToChannel performs the one-shot fetch-merge-put of spec section
// 6 against a channel bucket directly, mirroring the engine's unexported
// writeThrough using only the engine's public surface (Client, Password,
// Limits) since that method is not exported for reuse here.
func writeThroughToChannel(ctx *appContext, key string, entries []model.Entry) error {
	databaseID := identity.ChannelDatabaseID(ctx.token, ctx.password, key)
	if databaseID == "" {
		return fmt.Errorf("cannot address the %q channel without a server token and history password", key)
	}
	client := bucketClientFor(ctx, databaseID)
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	download, err := client.Get(callCtx)
	now := time.Now().UnixMilli()
	var database model.Database
	var revision string
	var existingBlob []byte
	createOnly := false
	switch {
	case errors.Is(err, server.ErrNotFound):
		database = model.NewDatabase(now)
		createOnly = true
	case err != nil:
		return err
	default:
		decoded, decodeErr := clipdb.Decode(download.Data, ctx.password, ctx.engine.Limits)
		if decodeErr != nil {
			return decodeErr
		}
		database = decoded
		revision = download.Revision
		existingBlob = download.Data
	}
	merge.Normalize(&database, now)
	database.Deleted = dropMarkersForResident(database.Deleted, entries)
	source := model.NewDatabase(now)
	source.Entries = append(source.Entries, entries...)
	merge.Merge(&database, source, now)
	if len(existingBlob) == 0 {
		existingBlob = fetchCoreBlob(ctx)
	}
	encoded, err := clipdb.Encode(database, ctx.password, existingBlob)
	if err != nil {
		return err
	}
	_, err = client.Put(callCtx, encoded, revision, createOnly)
	return err
}

// dropMarkersForResident removes a tombstone naming an entry that is about to
// be written back into the same channel, mirroring the engine's own
// dropMarkersForEntries so a stale relocation marker cannot immediately
// delete the entry it names again.
func dropMarkersForResident(markers []model.DeletedEntry, entries []model.Entry) []model.DeletedEntry {
	if len(markers) == 0 || len(entries) == 0 {
		return markers
	}
	resident := make(map[string]bool, len(entries))
	for _, e := range entries {
		resident[strings.ToLower(strings.TrimSpace(e.ID))] = true
	}
	kept := make([]model.DeletedEntry, 0, len(markers))
	for _, m := range markers {
		if resident[strings.ToLower(strings.TrimSpace(m.ID))] {
			continue
		}
		kept = append(kept, m)
	}
	return kept
}

// bucketClientFor addresses another bucket on the same server with the same
// credentials and transport as the configured client.
func bucketClientFor(ctx *appContext, databaseID string) *server.Client {
	clone := *ctx.client
	clone.DatabaseID = databaseID
	return &clone
}

// fetchCoreBlob best-effort downloads the raw core blob, purely so a
// newly-created bucket (rules or channel) can share its PBKDF2 salt. A
// failure here is not fatal: the caller falls back to a fresh salt.
func fetchCoreBlob(ctx *appContext) []byte {
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	download, err := ctx.client.Get(callCtx)
	if err != nil {
		return nil
	}
	return download.Data
}

// fetchRulesDocument downloads and decodes the rules document directly,
// without touching history at all, for the administrative commands that only
// need to fetch-modify-put it. The raw blob is returned alongside the decoded
// document purely so a subsequent putRulesDocument can reuse its PBKDF2 salt
// instead of fetching core for one.
func fetchRulesDocument(ctx *appContext) (doc *rules.Document, revision string, blob []byte, exists bool, err error) {
	rulesID := identity.SyncRulesDatabaseID(ctx.token, ctx.password)
	if rulesID == "" {
		return nil, "", nil, false, errors.New("cannot address the sync rules bucket without a server token and history password")
	}
	client := bucketClientFor(ctx, rulesID)
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	download, err := client.Get(callCtx)
	if errors.Is(err, server.ErrNotFound) {
		return nil, "", nil, false, nil
	}
	if err != nil {
		return nil, "", nil, false, err
	}
	payload, _, err := clipdb.DecodeRaw(download.Data, ctx.password)
	if err != nil {
		return nil, "", nil, false, err
	}
	parsed, err := rules.Parse(payload)
	if err != nil {
		return nil, "", nil, false, err
	}
	return parsed, download.Revision, download.Data, true, nil
}

// putRulesDocument uploads doc to the rules bucket. existingBlob is the raw
// container the rules bucket was last fetched as (nil when creating it for
// the first time); its PBKDF2 salt is reused when present, so a document
// being edited never needs an extra request just to keep the salt stable.
// Only a brand-new rules bucket falls back to the core database's salt, per
// spec section 5 (a channel or rules blob created for the first time copies
// core's salt so one PBKDF2 derivation serves everything).
func putRulesDocument(ctx *appContext, doc *rules.Document, revision string, existingBlob []byte, createOnly bool) error {
	rulesID := identity.SyncRulesDatabaseID(ctx.token, ctx.password)
	if rulesID == "" {
		return errors.New("cannot address the sync rules bucket without a server token and history password")
	}
	payload, err := rules.Serialize(doc)
	if err != nil {
		return err
	}
	var salt []byte
	if len(existingBlob) > 0 {
		if _, existingSalt, decodeErr := clipdb.DecodeRaw(existingBlob, ctx.password); decodeErr == nil {
			salt = existingSalt
		}
	}
	if len(salt) == 0 {
		if coreBlob := fetchCoreBlob(ctx); len(coreBlob) > 0 {
			if _, coreSalt, decodeErr := clipdb.DecodeRaw(coreBlob, ctx.password); decodeErr == nil {
				salt = coreSalt
			}
		}
	}
	blob, err := clipdb.EncodeRaw(payload, ctx.password, salt)
	if err != nil {
		return err
	}
	client := bucketClientFor(ctx, rulesID)
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, err = client.Put(callCtx, blob, revision, createOnly)
	return err
}

// --- document editing helpers ------------------------------------------------

func cloneDoc(doc *rules.Document) *rules.Document {
	clone := *doc
	clone.Channels = append([]rules.Channel{}, doc.Channels...)
	for i := range clone.Channels {
		clone.Channels[i].Route.Groups = append([]string{}, doc.Channels[i].Route.Groups...)
		clone.Channels[i].Route.SourceDevices = append([]string{}, doc.Channels[i].Route.SourceDevices...)
	}
	clone.Devices = append([]rules.Device{}, doc.Devices...)
	for i := range clone.Devices {
		clone.Devices[i].Channels = append([]string{}, doc.Devices[i].Channels...)
	}
	return &clone
}

func removeChannelByKey(channels []rules.Channel, key string) []rules.Channel {
	kept := make([]rules.Channel, 0, len(channels))
	for _, channel := range channels {
		if rules.ChannelKey(channel.Name) == key {
			continue
		}
		kept = append(kept, channel)
	}
	return kept
}

func removeChannelRef(refs []string, key string) []string {
	kept := make([]string, 0, len(refs))
	for _, ref := range refs {
		if ref == "*" {
			kept = append(kept, ref)
			continue
		}
		if strings.EqualFold(strings.TrimSpace(ref), key) {
			continue
		}
		kept = append(kept, ref)
	}
	return kept
}

func containsFold(list []string, key string) bool {
	for _, item := range list {
		if strings.EqualFold(strings.TrimSpace(item), key) {
			return true
		}
	}
	return false
}

// nextTimestamp returns a millisecond timestamp guaranteed to be greater than
// prev, so an edit's UpdatedUnixMs strictly advances even when the wall clock
// has not visibly moved since the document was last written.
func nextTimestamp(prev int64) int64 {
	now := time.Now().UnixMilli()
	if now <= prev {
		return prev + 1
	}
	return now
}

func describeRoute(route rules.Route) string {
	var parts []string
	if len(route.Groups) > 0 {
		parts = append(parts, "group is one of: "+strings.Join(route.Groups, ", "))
	}
	if len(route.SourceDevices) > 0 {
		parts = append(parts, "source device is one of: "+strings.Join(route.SourceDevices, ", "))
	}
	if route.Kind != "" {
		parts = append(parts, "kind is "+route.Kind)
	}
	if len(parts) == 0 {
		return "matches nothing"
	}
	return strings.Join(parts, " and ")
}

func refuseIfReadOnly(doc *rules.Document) error {
	if rules.ReadOnly(doc) {
		return fail(2, "the sync rules document uses a newer format understood only partially by this version; it cannot be modified here")
	}
	return nil
}

// --- self-registration (spec section 4, registry behavior) ------------------

// selfRegisterDevice runs after a successful sync: an updated client whose
// device name is missing from Devices adds itself with Channels ["*"] via one
// best-effort compare-and-swap. Failure here must never fail the sync.
//
// It re-fetches the rules document directly rather than reusing view.Rules:
// that avoids the case where view.RulesRevision is blank (the local cache won
// the last-writer-wins merge, so it is not what the server holds and an
// If-Match against it would be meaningless), and it gets the rules bucket's
// own raw blob for putRulesDocument to reuse its PBKDF2 salt from.
func selfRegisterDevice(ctx *appContext, view *syncengine.ViewState) {
	if view == nil || view.Rules == nil || !view.Rules.Enabled {
		return
	}
	if rules.ReadOnly(view.Rules) {
		return
	}
	machine := strings.TrimSpace(ctx.config.Machine)
	for _, device := range view.Rules.Devices {
		if strings.EqualFold(strings.TrimSpace(device.Name), machine) {
			return
		}
	}
	doc, revision, blob, exists, err := fetchRulesDocument(ctx)
	if err != nil || !exists || doc == nil || !doc.Enabled || rules.ReadOnly(doc) {
		if err != nil {
			verbosef(ctx.globals, "could not self-register this device in sync rules: %v", err)
		}
		return
	}
	for _, device := range doc.Devices {
		if strings.EqualFold(strings.TrimSpace(device.Name), machine) {
			return // already registered by a racing writer
		}
	}
	candidate := cloneDoc(doc)
	candidate.Devices = append(candidate.Devices, rules.Device{Name: ctx.config.Machine, Channels: []string{"*"}})
	candidate.UpdatedUnixMs = nextTimestamp(doc.UpdatedUnixMs)
	candidate.UpdatedBy = ctx.config.Machine
	if err := putRulesDocument(ctx, candidate, revision, blob, false); err != nil {
		verbosef(ctx.globals, "could not self-register this device in sync rules: %v", err)
		return
	}
	cacheRulesDocument(ctx, candidate)
}

// --- commands -----------------------------------------------------------------

func runRules(ctx *appContext, args []string) error {
	if len(args) == 0 {
		return fail(2, "usage: clipman-cli rules <show|enable|disable|channel|device> ...")
	}
	switch args[0] {
	case "show":
		return runRulesShow(ctx, args[1:])
	case "enable":
		return runRulesEnable(ctx, args[1:])
	case "disable":
		return runRulesDisable(ctx, args[1:])
	case "channel":
		if len(args) < 2 {
			return fail(2, "usage: clipman-cli rules channel <add|remove> ...")
		}
		switch args[1] {
		case "add":
			return runRulesChannelAdd(ctx, args[2:])
		case "remove":
			return runRulesChannelRemove(ctx, args[2:])
		default:
			return fail(2, "unknown rules channel subcommand %q", args[1])
		}
	case "device":
		if len(args) < 2 {
			return fail(2, "usage: clipman-cli rules device set <device> --channels <k1,k2|*>")
		}
		switch args[1] {
		case "set":
			return runRulesDeviceSet(ctx, args[2:])
		default:
			return fail(2, "unknown rules device subcommand %q", args[1])
		}
	default:
		return fail(2, "unknown rules subcommand %q", args[0])
	}
}

func runRulesShow(ctx *appContext, args []string) error {
	fs := newFlagSet("rules show")
	addOutputFlags(fs, &ctx.globals)
	if err := parseCommandFlags(fs, "rules show", args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fail(2, "rules show takes no positional arguments")
	}
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	view, err := ctx.engine.ReadView(callCtx, ctx.config.Machine)
	if err != nil {
		return mapRuntimeError("rules show failed", err)
	}
	cacheRulesFromView(ctx, view)
	if ctx.globals.json {
		return writeJSON(view.Rules)
	}
	if view.Rules == nil || !view.Rules.Enabled {
		fmt.Println("Sync rules are not enabled.")
		return nil
	}
	fmt.Println("Sync rules are enabled.")
	if len(view.Rules.Channels) == 0 {
		fmt.Println("No channels are defined.")
	} else {
		fmt.Println("Channels:")
		for _, channel := range view.Rules.Channels {
			fmt.Printf("  %s: %s\n", channel.Name, describeRoute(channel.Route))
		}
	}
	if len(view.Rules.Devices) == 0 {
		fmt.Println("No devices are registered.")
	} else {
		fmt.Println("Devices:")
		for _, device := range view.Rules.Devices {
			fmt.Printf("  %s: %s\n", device.Name, strings.Join(device.Channels, ", "))
		}
	}
	if rules.ReadOnly(view.Rules) {
		fmt.Println("Note: this document uses a newer format; only what this version understands is applied, and it will not be rewritten.")
	}
	return nil
}

func runRulesEnable(ctx *appContext, args []string) error {
	fs := newFlagSet("rules enable")
	addOutputFlags(fs, &ctx.globals)
	if err := parseCommandFlags(fs, "rules enable", args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fail(2, "rules enable takes no positional arguments")
	}
	doc, revision, blob, exists, err := fetchRulesDocument(ctx)
	if err != nil {
		return mapRuntimeError("rules enable failed", err)
	}
	if exists {
		if err := refuseIfReadOnly(doc); err != nil {
			return err
		}
	}
	now := time.Now().UnixMilli()
	createOnly := !exists
	if !exists {
		doc = &rules.Document{
			Clipman:       "sync-rules",
			Version:       1,
			Enabled:       true,
			UpdatedUnixMs: now,
			UpdatedBy:     ctx.config.Machine,
			Channels:      []rules.Channel{},
			Devices:       []rules.Device{{Name: ctx.config.Machine, Channels: []string{"*"}}},
		}
	} else {
		doc.Enabled = true
		doc.UpdatedUnixMs = now
		doc.UpdatedBy = ctx.config.Machine
	}
	if err := rules.Validate(doc); err != nil {
		return fail(2, "%v", err)
	}
	if err := putRulesDocument(ctx, doc, revision, blob, createOnly); err != nil {
		return mapRuntimeError("rules enable failed", err)
	}
	cacheRulesDocument(ctx, doc)
	if ctx.globals.json {
		return writeJSON(doc)
	}
	if !ctx.globals.quiet {
		fmt.Println("Sync rules are enabled.")
	}
	return nil
}

func runRulesDisable(ctx *appContext, args []string) error {
	fs := newFlagSet("rules disable")
	addOutputFlags(fs, &ctx.globals)
	if err := parseCommandFlags(fs, "rules disable", args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fail(2, "rules disable takes no positional arguments")
	}
	doc, revision, blob, exists, err := fetchRulesDocument(ctx)
	if err != nil {
		return mapRuntimeError("rules disable failed", err)
	}
	if !exists {
		if ctx.globals.json {
			return writeJSON(nil)
		}
		if !ctx.globals.quiet {
			fmt.Println("Sync rules are not enabled.")
		}
		return nil
	}
	if err := refuseIfReadOnly(doc); err != nil {
		return err
	}
	if doc.Enabled {
		doc.Enabled = false
		doc.UpdatedUnixMs = time.Now().UnixMilli()
		doc.UpdatedBy = ctx.config.Machine
		if err := putRulesDocument(ctx, doc, revision, blob, false); err != nil {
			return mapRuntimeError("rules disable failed", err)
		}
	}
	cacheRulesDocument(ctx, doc)
	if ctx.globals.json {
		return writeJSON(doc)
	}
	if !ctx.globals.quiet {
		fmt.Println("Sync rules are disabled.")
	}
	return nil
}

func runRulesChannelAdd(ctx *appContext, args []string) error {
	fs := newFlagSet("rules channel add")
	addOutputFlags(fs, &ctx.globals)
	var groups, sourceDevices stringListFlag
	fs.Var(&groups, "group", "match entries in this group (repeatable)")
	fs.Var(&sourceDevices, "source-device", "match entries captured on this device (repeatable)")
	kind := fs.String("kind", "", "match by kind: richtextimages")
	if err := parseCommandFlags(fs, "rules channel add", permuteArgs(fs, args)); err != nil {
		return err
	}
	positional := fs.Args()
	if len(positional) != 1 {
		return fail(2, "usage: clipman-cli rules channel add <name> [--group GROUP]... [--source-device DEVICE]... [--kind richtextimages]")
	}
	name := positional[0]

	routeKind := ""
	if strings.TrimSpace(*kind) != "" {
		if !strings.EqualFold(strings.TrimSpace(*kind), "richtextimages") {
			return fail(2, "--kind must be richtextimages")
		}
		routeKind = "RichTextImages"
	}
	if len(groups) == 0 && len(sourceDevices) == 0 && routeKind == "" {
		return fail(2, "at least one of --group, --source-device, or --kind is required")
	}

	doc, revision, blob, exists, err := fetchRulesDocument(ctx)
	if err != nil {
		return mapRuntimeError("rules channel add failed", err)
	}
	if !exists || !doc.Enabled {
		return fail(2, "sync rules are not enabled; run `clipman-cli rules enable` first")
	}
	if err := refuseIfReadOnly(doc); err != nil {
		return err
	}

	candidate := cloneDoc(doc)
	candidate.Channels = append(candidate.Channels, rules.Channel{
		Name:  name,
		Route: rules.Route{Groups: []string(groups), SourceDevices: []string(sourceDevices), Kind: routeKind},
	})
	if err := rules.Validate(candidate); err != nil {
		return fail(2, "%v", err)
	}
	candidate.UpdatedUnixMs = time.Now().UnixMilli()
	candidate.UpdatedBy = ctx.config.Machine
	if err := putRulesDocument(ctx, candidate, revision, blob, false); err != nil {
		return mapRuntimeError("rules channel add failed", err)
	}
	cacheRulesDocument(ctx, candidate)
	if ctx.globals.json {
		return writeJSON(candidate)
	}
	if !ctx.globals.quiet {
		fmt.Printf("Added channel %q.\n", name)
	}
	return nil
}

// runRulesChannelRemove implements spec section 5's channel-deletion
// algorithm in two steps. Step 1 neutralizes the channel's route (never
// matching) while it is still listed, so ReadView/MutateView keep fetching
// its bucket: entries resident there reroute to whatever else matches or to
// core, and the ordinary two-phase upload uploads the affected channels
// before emptying this one (gain-before-lose). Step 2 then removes the
// channel from the rules document itself, once it is verifiably empty.
//
// Step 2 runs only when step 1 is verified to have actually committed the
// reroute under the intended document: MutateView is not told which document
// to route against directly (there is no such parameter), so step 1 drives it
// by overriding Engine.CachedRules with a transitional document and relying
// on rules.MergeDocuments's last-writer-wins comparison to prefer it over
// whatever MutateView's own fetch returns. That can lose to a genuinely newer
// remote edit made between the initial read and this call, in which case the
// reroute silently never happened under the document this function built -
// so step 1's result is checked two ways before step 2 is allowed to touch
// the rules document at all: the document actually in effect during the
// mutation must be the transitional one (by UpdatedUnixMs/UpdatedBy), and the
// channel being removed must show no resident entries left in the result.
func runRulesChannelRemove(ctx *appContext, args []string) error {
	fs := newFlagSet("rules channel remove")
	addOutputFlags(fs, &ctx.globals)
	if err := parseCommandFlags(fs, "rules channel remove", permuteArgs(fs, args)); err != nil {
		return err
	}
	positional := fs.Args()
	if len(positional) != 1 {
		return fail(2, "usage: clipman-cli rules channel remove <name>")
	}
	name := positional[0]
	key := rules.ChannelKey(name)
	if key == "" {
		return fail(2, "%q is not a valid channel name", name)
	}

	machine := ctx.config.Machine
	viewCtx, viewCancel := context.WithTimeout(context.Background(), 30*time.Second)
	view, err := ctx.engine.ReadView(viewCtx, machine)
	viewCancel()
	if err != nil {
		return mapRuntimeError("rules channel remove failed", err)
	}
	cacheRulesFromView(ctx, view)

	if view.Rules == nil || !view.Rules.Enabled {
		return fail(2, "sync rules are not enabled")
	}
	if err := refuseIfReadOnly(view.Rules); err != nil {
		return err
	}
	found := false
	for _, channel := range view.Rules.Channels {
		if rules.ChannelKey(channel.Name) == key {
			found = true
			break
		}
	}
	if !found {
		return fail(2, "channel %q does not exist", name)
	}
	subscribed := rules.SubscribedChannels(view.Rules, machine)
	if subscribed != nil && !containsFold(subscribed, key) {
		return fail(2, "this device is not subscribed to the %q channel and cannot see its entries; subscribe to it before removing it", name)
	}

	// Step 1: neutralize the route and let the normal engine upload path
	// reroute and empty the channel.
	transitional := cloneDoc(view.Rules)
	for i := range transitional.Channels {
		if rules.ChannelKey(transitional.Channels[i].Name) == key {
			transitional.Channels[i].Route = rules.Route{}
		}
	}
	transitional.UpdatedUnixMs = nextTimestamp(view.Rules.UpdatedUnixMs)
	transitional.UpdatedBy = machine
	ctx.engine.CachedRules = transitional

	mutateCtx, mutateCancel := context.WithTimeout(context.Background(), 30*time.Second)
	mutatedView, mutateErr := ctx.engine.MutateView(mutateCtx, machine, func(*model.Database) error { return nil })
	mutateCancel()
	if absorbed := absorbWriteThrough(ctx, mutateErr); absorbed != nil {
		return mapRuntimeError("rules channel remove failed while relocating entries", mutateErr)
	}

	// Verify the reroute actually ran under the transitional document: a
	// genuinely newer remote edit can win MergeDocuments's last-writer-wins
	// comparison instead, in which case nothing was rerouted here at all.
	effective := mutatedView.Rules
	if effective == nil || effective.UpdatedUnixMs != transitional.UpdatedUnixMs || effective.UpdatedBy != transitional.UpdatedBy {
		return fail(1, "Sync rules changed on another device. Run the command again.")
	}
	// Defense in depth: even under the right document, confirm no entry is
	// still reported resident in the channel being removed before deleting it
	// from the document.
	for _, residentKey := range mutatedView.Residence {
		if residentKey == key {
			return fail(1, "channel %q still has entries after relocating them; run the command again", name)
		}
	}

	// Step 2: remove the now-empty channel from the rules document itself.
	doc, revision, blob, exists, err := fetchRulesDocument(ctx)
	if err != nil {
		return mapRuntimeError("rules channel remove failed", err)
	}
	if !exists {
		return fail(2, "sync rules are not enabled")
	}
	if err := refuseIfReadOnly(doc); err != nil {
		return err
	}
	finalDoc := cloneDoc(doc)
	finalDoc.Channels = removeChannelByKey(finalDoc.Channels, key)
	for i := range finalDoc.Devices {
		finalDoc.Devices[i].Channels = removeChannelRef(finalDoc.Devices[i].Channels, key)
	}
	finalDoc.UpdatedUnixMs = nextTimestamp(doc.UpdatedUnixMs)
	finalDoc.UpdatedBy = machine
	if err := rules.Validate(finalDoc); err != nil {
		return fail(2, "%v", err)
	}
	if err := putRulesDocument(ctx, finalDoc, revision, blob, false); err != nil {
		return mapRuntimeError("rules channel remove failed", err)
	}
	cacheRulesDocument(ctx, finalDoc)

	if ctx.globals.json {
		return writeJSON(finalDoc)
	}
	if !ctx.globals.quiet {
		fmt.Printf("Removed channel %q.\n", name)
	}
	return nil
}

func runRulesDeviceSet(ctx *appContext, args []string) error {
	fs := newFlagSet("rules device set")
	addOutputFlags(fs, &ctx.globals)
	channelsValue := fs.String("channels", "", "comma-separated channel names, or *")
	if err := parseCommandFlags(fs, "rules device set", permuteArgs(fs, args)); err != nil {
		return err
	}
	positional := fs.Args()
	if len(positional) != 1 {
		return fail(2, "usage: clipman-cli rules device set <device> --channels <k1,k2|*>")
	}
	deviceName := positional[0]
	if strings.TrimSpace(*channelsValue) == "" {
		return fail(2, "--channels is required")
	}

	doc, revision, blob, exists, err := fetchRulesDocument(ctx)
	if err != nil {
		return mapRuntimeError("rules device set failed", err)
	}
	if !exists || !doc.Enabled {
		return fail(2, "sync rules are not enabled; run `clipman-cli rules enable` first")
	}
	if err := refuseIfReadOnly(doc); err != nil {
		return err
	}

	var channelRefs []string
	for _, part := range strings.Split(*channelsValue, ",") {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			continue
		}
		channelRefs = append(channelRefs, trimmed)
	}
	if len(channelRefs) == 0 {
		return fail(2, "--channels is required")
	}

	candidate := cloneDoc(doc)
	found := false
	for i := range candidate.Devices {
		if strings.EqualFold(strings.TrimSpace(candidate.Devices[i].Name), strings.TrimSpace(deviceName)) {
			candidate.Devices[i].Channels = channelRefs
			found = true
			break
		}
	}
	if !found {
		candidate.Devices = append(candidate.Devices, rules.Device{Name: deviceName, Channels: channelRefs})
	}
	if err := rules.Validate(candidate); err != nil {
		return fail(2, "%v", err)
	}
	candidate.UpdatedUnixMs = time.Now().UnixMilli()
	candidate.UpdatedBy = ctx.config.Machine
	if err := putRulesDocument(ctx, candidate, revision, blob, false); err != nil {
		return mapRuntimeError("rules device set failed", err)
	}
	cacheRulesDocument(ctx, candidate)
	if ctx.globals.json {
		return writeJSON(candidate)
	}
	if !ctx.globals.quiet {
		fmt.Printf("Set %q subscriptions to %s.\n", deviceName, strings.Join(channelRefs, ", "))
	}
	return nil
}
