# Clipman Sync Rules Specification

This document is normative for every Clipman client that implements machine-scoped
sync rules ("sync channels"). All clients on all platforms must implement exactly
these derivations, schemas, and algorithms so that the same buckets, routes, and
merge outcomes are produced everywhere. The implementation plan lives in `sync.md`;
this file is the contract.

Binding constraints:

- Server code must not change. Everything here works against every deployed 2.x
  Clipman Server using only `HEAD/GET/PUT /api/v1/database/{id}`.
- The `CLIPDB2` container format, PBKDF2 parameters (150,000 iterations,
  HMAC-SHA1), and AES-256-CBC + HMAC-SHA256 layout must not change.
- The `ClipEntry` wire schema gains no new required fields. Routing uses only
  existing fields.
- `ClipmanCli/internal/` and `ClipmanLinuxBackend/internal/` are forks; shared
  logic changes land in both trees in the same change.
- The feature is opt-in and off by default. With rules disabled, client behavior
  is identical to a client without this feature.
- Old clients must never lose data: they sync the core channel only and must
  never delete or corrupt channel buckets or channel files.

## 1. Concepts

- A **sync channel** is a named partition of the shared history. Each entry lives
  in exactly one channel at a time. The default channel is **core**, stored in the
  existing bucket (server mode) or the existing `clipman-history.clipdb` file
  (shared-folder mode). Enabling the feature moves nothing until a rule routes
  entries elsewhere.
- A **routing rule** is attached to each channel and decides which entries live
  there, computed only from existing entry fields (`Group`, `SourceMachine`,
  rich-text image presence). First matching channel in list order wins; no match
  means core.
- A **device subscription** lists which channels a named device downloads. Core is
  always downloaded by everyone. A device not listed in the rules document
  subscribes to everything.
- The **rules document** holds channels, routes, and device subscriptions. It is
  stored in its own bucket (server mode) or its own file (shared-folder mode),
  never inside the history database, because the Windows client drops unknown
  JSON fields on save.

## 2. Bucket identity

All inputs are trimmed of leading and trailing whitespace before derivation,
matching the existing database-id derivation. `base64url_nopad` is RFC 4648
base64url with padding stripped.

```
key            = SHA256(UTF8(trim(token)))
databaseId     = base64url_nopad(HMAC-SHA256(key, UTF8("Clipman.ServerDatabaseId.v1\n"  + password)))          [existing]
channelId(k)   = base64url_nopad(HMAC-SHA256(key, UTF8("Clipman.ServerChannelId.v1\n"   + password + "\n" + k)))
syncRulesId    = base64url_nopad(HMAC-SHA256(key, UTF8("Clipman.ServerSyncRulesId.v1\n" + password)))
```

`k` is the normalized channel key (Section 3). All ids are 43 characters and are
valid database ids on every deployed server. A blank token or blank password
yields an empty id (channel sync requires server mode's mandatory password, or
shared-folder mode where ids are not used).

Cross-client test vectors (token `example-token`, password `example-password`):

| Purpose | Input | Expected id |
|---|---|---|
| database id (existing) | - | `l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU` |
| sync rules id | - | `j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ` |
| channel id | `work` | `F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA` |
| channel id | `images` | `K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ` |
| channel id | `desktop only` | `02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o` |

Shared-folder mode maps channels to sibling files in the data folder:

```
clipman-history.clipdb                          core (existing name, unchanged)
clipman-channel-<key with spaces as dashes>.clipdb
clipman-sync-rules.clipdb
```

## 3. Channel keys and name matching

- Channel display name: what the user typed, stored as `Name` in the document.
- Channel key: `lowerInvariant(trim(Name))`. Validation, enforced by every rules
  editor: the key must match `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?` (ASCII only,
  1-32 chars, no leading/trailing space, dash, or underscore). Non-ASCII names are
  rejected so no Unicode normalization library is required anywhere.
- Reserved keys, rejected as channel names: `core`, `all`, `pinned`, `sync-rules`.
- Device-name matching (both `Devices[].Name` against the local device name and
  `Route.SourceDevices` against `Entry.SourceMachine`) compares
  `lowerInvariant(trim(x))` on both sides. This is deliberately stricter and more
  portable than the UI's culture-aware device filter; the difference is
  acceptable because routing must be identical on every platform.
- Group matching (`Route.Groups` against `Entry.Group`) uses the same
  `lowerInvariant(trim(x))` comparison, consistent with the existing cross-client
  case-insensitive group folding.

## 4. The rules document

Stored as JSON inside a standard container: `CLIPDB2` encrypted when a history
password exists, `CLIPDB1` compressed otherwise (identical container selection to
the history database). The payload is this document, not a ClipDatabase:

```json
{
  "Clipman": "sync-rules",
  "Version": 1,
  "Enabled": true,
  "UpdatedUnixMs": 1757200000000,
  "UpdatedBy": "Desktop",
  "Channels": [
    { "Name": "Images",       "Route": { "Kind": "RichTextImages" } },
    { "Name": "Work",         "Route": { "Groups": ["Work", "Standup"] } },
    { "Name": "Desktop only", "Route": { "SourceDevices": ["Desktop", "Work-PC"] } }
  ],
  "Devices": [
    { "Name": "Desktop",     "Channels": ["*"] },
    { "Name": "Jeff-iPhone", "Channels": ["work"] },
    { "Name": "Work-PC",     "Channels": ["work", "desktop only"] }
  ]
}
```

Field semantics:

- `Clipman`: always the string `sync-rules`; readers reject other values.
- `Version`: document format version, currently 1. A client that sees a higher
  version treats the document as read-only: it applies what it understands, must
  not rewrite the document, and syncs core plus the channels it can resolve.
- `Enabled`: `false` means every client behaves exactly as without the feature,
  even if channels are defined. This is the instant global off switch.
- `Channels[].Name`: display name; its normalized key (Section 3) identifies the
  channel and feeds the id derivation. Keys must be unique within the document.
- `Channels[].Route`: conditions are ANDed within one route; a route must contain
  at least one condition. `Groups` and `SourceDevices` are lists matched per
  Section 3. `Kind` currently allows only `"RichTextImages"`, which matches when
  the entry's `RichText` is present and its `HtmlFragment` contains the ordinal
  substring `data:image/`.
- Routing is evaluated top to bottom over `Channels`; the first matching route
  wins; an entry matching no route lives in core.
- `Devices[].Name`: the device's user-visible device name.
- `Devices[].Channels`: channel keys, or the single element `"*"` meaning all
  channels. Core is implicit and always synced. A device whose name is not
  listed subscribes to everything (safe default: behaves like a full sync).
- Concurrency: the rules bucket uses the normal `If-Match` flow. Concurrent edits
  merge by whole-document last-writer-wins on `UpdatedUnixMs`; ties break toward
  the higher `UpdatedBy` string by ordinal comparison.
- Caching: every client caches the last-seen rules document locally. If the rules
  bucket returns 404 but a cache exists, the cache stays in effect and the client
  re-uploads it with `If-None-Match: *`. If neither exists, rules are disabled.
- Registry behavior: after rules are enabled, an updated client whose device name
  is missing from `Devices` adds itself with `Channels: ["*"]` on its next
  successful sync.

## 5. Multi-channel sync algorithm

Definitions: the **view** is the merged in-memory database shown to the user;
**residence** maps each entry id to the channel it was loaded from.

Download / poll (each poll tick):

1. `HEAD` the rules bucket. If its revision changed, `GET`, decode, merge
   (Section 4 LWW) into the cached document, and recompute the subscription set.
2. For each subscribed channel (core plus subscriptions), `HEAD`; `GET` only
   channels whose revision changed.
3. Assemble the view across channels by entry `Id` (core first, then channels in
   rules-document order). Cross-channel assembly deliberately does NOT use the
   entry-level field merge or text-fallback matching: within a channel the
   existing merge applies as today; across channels an `Id` collision (move
   race) is resolved by dropping the copy with the lower `ModifiedUnixMs`
   wholesale, and on a tie the earlier channel in assembly order wins. The same
   text under different ids in two channels stays duplicated (see Section 8).
   Tombstones apply only within their own channel, with one exception: a
   tombstone with a non-empty `TextHash` also suppresses matching-text entries
   in other channels, subject to the same entry-changed-before-deletion rule the
   entry-level merge uses. A relocation marker (empty `TextHash`) must never
   suppress a live entry with the same id in another channel.
4. The dropped loser of an `Id` collision is repaired (rewritten to its routed
   channel) on the next save.

Upload (each local mutation):

1. Recompute `target = route(entry)` for every entry in the view.
2. Build one database per channel: entries whose target is that channel, plus the
   tombstones that belong to that channel.
3. Relocation: when residence differs from target, the entry moves into the
   target channel's database and a **relocation tombstone** is added to the source
   channel: `{Id: <entry id>, TextHash: "", DeletedUnixMs: <now>, SourceMachine:
   <this device>}`. The empty `TextHash` distinguishes "moved" from "deleted";
   merge implementations must only match `TextHash` when it is non-empty, and
   normalization must not back-fill an empty `TextHash` on such markers.
4. Dirty detection: serialize each channel's plaintext JSON deterministically
   with the database-level `UpdatedUnixMs` field zeroed, and compare its SHA-256
   to the hash recorded at the last transfer. Zeroing `UpdatedUnixMs` makes the
   hash durable across poll cycles (normalization restamps that field on every
   pass). Only dirty channels are encrypted and `PUT` (with per-channel
   `If-Match`). The comparison must happen on plaintext: ciphertext differs on
   every encode because the IV is fresh.
5. Upload ordering (add-then-remove two-phase): a partial failure must never
   leave an entry deleted from its source channel without having been committed
   to its target. To guarantee this per entry, including for channels that both
   gain and lose in one save and for relocation chains or cycles, uploads happen
   in two phases. Phase 1: every channel is uploaded with its rebuilt content
   EXCEPT that entries departing it are still included and its new relocation
   markers are withheld (targets receive additions; sources do not yet drop
   departures). Phase 1 carries the copy of a departing entry that the source
   channel was fetched with, not the locally modified one, so a channel whose
   only change is a departure is byte-identical to what the server holds and
   skips its phase-1 upload; the target receives the modified copy, whose higher
   `ModifiedUnixMs` wins the duplicate resolution of download step 3 for the
   transient window in which both channels hold the id. Phase 2: only after every phase-1 upload has committed, each
   losing channel is rebuilt with departures removed and relocation markers
   added, and uploaded again. A phase-2 failure is safe: the entry exists in
   both channels, and view assembly (step 3) resolves the duplicate until the
   next save repairs it. Channels that lose nothing are uploaded once, in phase
   1, subject to the dirty check. On a 409 for one channel: `GET` that channel,
   merge, rebuild for the current phase, retry.

Salt sharing: a channel blob created for the first time copies the core
database's salt, so one PBKDF2 derivation serves every channel through the
existing derived-key caches. The rules blob does the same.

Channel deletion (rules editor action): the editing client re-routes that
channel's entries (they fall through to the next matching rule or core), uploads
the affected channels, uploads the now-empty channel database, then removes the
channel from the rules document. The empty bucket remains server-side and can be
pruned with existing server admin tooling.

Rules edits: the device that edits the rules performs the re-route immediately.
Editors must be subscribed to every channel a given edit affects; rules UIs
disable edits that the local device cannot see. Additionally, any client that
notices a misrouted resident entry during upload migrates it; moves are
idempotent and convergent under the entry-level LWW merge.

## 6. Write-through to unsubscribed channels

A device may capture an entry that routes to a channel it does not subscribe to.
The writer performs a one-shot fetch-merge-put of the target channel: `GET` (404
means new; then `If-None-Match: *`), merge the new entry, `PUT` with `If-Match`,
then discard the channel from memory. The entry does not appear in the local
view; the UI announces once: "Added to <channel name> for your other devices."
If the write-through fails (offline), the entry is kept in a small local pending
store and retried after the next successful poll.

## 7. Mixed fleets and compatibility

- Old servers need no changes; channels are ordinary buckets.
- An old client (server or folder mode) syncs only core. It never sees channel
  entries; nothing is lost or corrupted. Its new captures land in core and are
  re-routed by updated clients on their next save.
- Guidance shown to users: enable sync rules only after every device runs a
  version that supports them; older devices keep syncing the main history only.
- An old client deleting a core entry writes a core tombstone, which updated
  clients apply normally.

## 8. Known limitations (accepted)

- Quick Paste hotkeys referencing an entry in an unsubscribed channel behave as
  for a deleted entry.
- Deleting an entry on one device while another concurrently moves it between
  channels can resurrect it; converges on the next edit or delete.
- Capture-time text dedupe consults only subscribed channels, so identical text
  captured on devices with disjoint subscriptions can exist once per channel.
- Retention limits evaluate against the subscribed view only; pinned and named
  entries remain exempt as today.
