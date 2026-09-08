# Clipman Machine-Scoped Sync Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user define named sync channels and per-device rules so each named machine downloads and uploads only the clips it wants, instead of the entire database, cutting transfer size and CPU cost proportionally.

**Architecture:** Partition the single encrypted server bucket into a small set of encrypted "channel" buckets plus a tiny encrypted rules document, all addressed through the existing `GET/HEAD/PUT /api/v1/database/{id}` endpoint. Routing of entries to channels is computed client-side from existing entry fields (`Group`, `SourceMachine`, rich-text image presence), so the server needs **zero changes** and the encryption boundary is unchanged. Each device subscribes to a subset of channels; unsubscribed channels are never downloaded.

**Tech Stack:** Existing per-platform stacks: C#/.NET Framework WinForms (Windows), Swift (macOS, iOS), Kotlin (Android), Go (CLI and Linux backend), Python (Linux UI, server). No new dependencies on any platform.

## Global Constraints

- Server code (`ClipmanServerLinux/clipman_server.py`) must not change. The feature must work against every deployed 2.x server.
- The `CLIPDB2` container format, PBKDF2 parameters (150,000 iterations, HMAC-SHA1), and AES-CBC + HMAC-SHA256 layout must not change.
- The `ClipEntry` wire schema must not gain new required fields. Routing uses only existing fields.
- `ClipmanCli/internal/` is a fork of `ClipmanLinuxBackend/internal/`. Any change to codec, identity, merge, model, or sync engine MUST be applied to both trees in the same task (policy documented at `clipman-cli-spec.md:160-170`).
- User-facing terminology: "Device" (never "machine") for the visible concept, matching `Manual.html:310`; the on-disk field stays `SourceMachine`.
- All UI work follows the accessibility rules in the repository owner's global config: accessible names on every control, keyboard access, meaningful screen-reader announcements, no color-only signaling.
- Plain ASCII in all user-visible strings; no emoji; no decorative Unicode.
- Feature is opt-in and off by default. With rules disabled, behavior is byte-for-byte identical to today.
- Old clients must never lose data. They may see a subset (core channel only); they must never delete or corrupt channel contents.
- Windows sources are compiled by `tests/Run-WindowsRegressionTests.ps1` with the legacy .NET Framework compiler `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, which supports **C# 5 only**. No string interpolation (`$"..."`), no null-conditional (`?.`), no `nameof`, no expression-bodied members, no auto-property initializers, no static using. Match the existing `src/` style exactly.

---

# Part 1: Current architecture (verified facts)

Everything below was read from the code in this repository. File references are exact.

## 1.1 One server, one blob, no increments

- There is exactly one HTTP server implementation: `ClipmanServerLinux/clipman_server.py` (2169 lines). `ClipmanServerWindows/Program.cs` and `ClipmanServerMac/Sources/ClipmanServer/main.swift` are tray/menu wrappers that spawn the same Python script. Docker packages it too.
- Storage: one opaque `.clipdb` blob per bucket at `Databases/<database-id>/clipman-history.clipdb`, replaced wholesale on every `PUT` (`clipman_server.py:1811-1885`). No event log, no sequence numbers, no delta endpoint, no pagination, no query parameters on any database endpoint.
- Endpoints: `GET /api/v1/health` (unauthenticated), `HEAD|GET|PUT /api/v1/database/{id}` (Bearer token). `{id}` must be 32-128 chars of `[A-Za-z0-9_-]` (`clipman_server.py:1263-1273`). Optimistic concurrency via `X-Clipman-Revision`/`ETag` and `If-Match`; conflicting writes get HTTP 409; create-only via `If-None-Match: *` (412 if exists).
- The revision string is `base64url("<hex size>-<hex mtime_ns>")` (`clipman_server.py:118-123`) - opaque, not ordered.
- Identical uploaded bytes are a server no-op: file not rewritten, revision unchanged (`clipman_server.py:1863-1865`).
- Size limit: `MaxDatabaseBytes` default 64 MiB per bucket (server); clients cap between 64 MiB (Go CLI) and 272 MiB (Windows `ServerStorageClient.cs:13`).
- The server sees only ciphertext plus: bucket id, blob length, mtime, per-bucket metadata timestamps, client IPs, and User-Agent. It never receives the history password.

## 1.2 Bucket identity

Every client derives the bucket id the same way (`src/ServerDatabaseIdentity.cs:10-22`, `ClipmanCli/internal/identity/identity.go:10-21`, plus Swift and Kotlin twins):

```
databaseId = base64url_nopad( HMAC-SHA256( key = SHA256(UTF8(token)),
                                           msg = UTF8("Clipman.ServerDatabaseId.v1\n" + password) ) )
```

43 characters, within the server's accepted 32-128 range. This means: **any 32-128 char base64url string is a valid bucket id on every deployed server, under the same token**. Additional buckets cost nothing server-side. This is the load-bearing fact for the whole design.

## 1.3 Sync loop (identical shape on all six clients)

1. `HEAD` the bucket; compare revision to cached value. Windows polls every 2 s (`ClipStore.cs:1166-1175`), Mac 2 s, iOS/Android 5 s with backoff, Linux UI 2 s.
2. If changed: `GET` the entire blob, decrypt (PBKDF2 150k iterations per decode), gunzip, parse, merge into local state.
3. On every local mutation: re-serialize the whole database, gzip, encrypt, `PUT` the entire blob with `If-Match`. Windows uploads from `SaveLocked()` after **every** operation including `MarkUsed` on every paste (`ClipStore.cs:1041`, `:1342-1389`).
4. On 409: `GET`, merge, `PUT` again.

Merge is per-entry field-level last-writer-wins keyed by `Id` then exact `Text`, with 90-day tombstones (`DeletedEntries`, matched by `Id` or by `TextHash` + entry-older-than-marker). Reference implementations: `ClipmanCli/internal/merge/merge.go` (317 lines, byte-identical in `ClipmanLinuxBackend`), `src/ClipStore.cs:1391-1519`, `SyncConflictResolver.kt`, `SyncConflictResolver.swift`.

## 1.4 Entry model (shared wire schema, PascalCase JSON)

`Entry`: `Id`, `Text`, `Name`, `Group`, `SourceMachine`, `CreatedUnixMs`, `LastUsedUnixMs`, `ModifiedUnixMs`, `Pinned`, `IsTemplate`, `ManualOrder`, `RichText` (`{Version, HtmlFragment, RtfBase64, PreferredFormat}`), `RichTextUpdatedUnixMs`.
`DeletedEntry`: `Id`, `TextHash`, `DeletedUnixMs`, `SourceMachine`.

- `SourceMachine` is the device attribution field: free text, set from the user-configurable device name at capture time. Every platform lets the user rename the device (Windows `AppSettings.DeviceName`, `Models.cs:191`; Mac `settings.deviceName`; iOS `settings.deviceName`; Android `deviceName` pref; Linux/CLI `machine` config). Default is the hostname or platform device name.
- Go clients preserve unknown JSON fields via `Extra map[string]json.RawMessage` (`model.go:20`); Swift via `unknownFields`. **The Windows client uses `JavaScriptSerializer` into fixed DTOs and drops unknown fields** - so nothing new can be stored in the shared database and survive an old Windows client's save. This rules out storing the rules document inside the existing bucket.

## 1.5 Existing device features to build on

- Device filter (view-only): `AppSettings.HistoryFilterType`/`DeviceFilter`, filtering on trimmed case-insensitive `SourceMachine` (`HistoryForm.cs:361-368`); device list computed by `ClipStore.GetDevices()` via `CanonicalLabels` (`ClipStore.cs:1517-1550`). Android has `HistoryFilterKind.Device`; Mac has `deviceFilter`.
- Manual terminology (`Manual.html:852-865`): "entries attributed to one device", "Device name setting for new clipboard events", "Device column".
- Machine-local by design: settings files (`<MACHINE>-settings.json`), File History, Secrets, sort/tab order.
- Shared-folder mode (Windows/Mac): the `.clipdb` file sits in a cloud-synced folder; change detection via `FileSystemWatcher` (500 ms debounce, `ClipStore.cs:1098-1135`); cloud conflict copies merged then deleted by `SyncConflictResolver.ResolveDatabaseConflicts` (`SyncConflictResolver.cs:42-72`).

## 1.6 Where the time and bytes go today

- Every observed change on any device costs every other device a full download (up to the whole database) and every local mutation costs a full upload. A paste (`MarkUsed`) uploads the entire database.
- Images are base64 data: URIs inside `RichText.HtmlFragment` in the same blob (`EmbeddedImageHTML.swift:145`, `RichImageData.cs`). Devices with rich text disabled still download every image byte; they merely decline to display them.
- PBKDF2 at 150k iterations runs per decode and per encode (single-slot key cache on Windows keyed by password+salt, `ClipDatabaseFile.cs:380-415`; salt is reused across saves so the cache holds).
- Merge is O(n^2) over the full entry list (`ClipStore.cs:1401-1407`).

---

# Part 2: Design

## 2.1 Concepts

- **Sync channel**: a named partition of the shared history. Each entry lives in exactly one channel at a time. The unnamed default channel is **core** and is stored in the existing bucket / existing `clipman-history.clipdb` file - so enabling the feature moves nothing until a rule routes entries elsewhere.
- **Routing rule**: attached to each channel; decides which entries live there, computed from existing entry fields only. Conditions: group membership, source device, rich-text-image presence. First matching channel in list order wins; no match means core.
- **Device subscription**: the rules document lists named devices; each has a channel list (or `*`). A device downloads only the channels it subscribes to, plus core (always). A device it captures for but does not subscribe to gets a write-through (Section 2.7).
- **Rules document**: a small JSON document holding channels, routes, and device subscriptions. Stored in its own tiny bucket (server mode) or its own small file (shared-folder mode), never inside the history database, because the Windows client drops unknown fields (Section 1.4).

User-facing naming: the feature is "Sync rules"; channels are "sync channels"; devices are "devices" (matching existing manual terminology). Example user story this design serves directly: "My phone should only get the Personal group and clips from my desktop; it should never download images. My work laptop should not get the Personal group at all."

## 2.2 Why not the alternatives

- **Server-side filtering**: impossible without breaking the encryption boundary; the server cannot read `Group`/`SourceMachine`. Rejected.
- **Client-side filtering after full download**: no transfer-speed win, which is an explicit goal. Rejected.
- **Per-writer channels (each device uploads only its own outbound channel)**: attractive for upload cost but breaks down on cross-device edits (any device may edit any entry, changing `Text`/`Group`/`Pinned`), which the entry-level LWW model requires to land in the entry's home channel anyway. The chosen design gets the same upload win (only the touched channel uploads) without a second routing dimension.
- **Protocol v2 with per-entry sync**: correct long-term but requires simultaneous changes to one server and six clients, plus a new sequence-number concept the revision string cannot express (`clipman_server.py:118-123`). Out of scope; noted in future work (Part 8).

## 2.3 Wire-level: channel and rules bucket identity

New derivations, alongside the existing one, in every client's identity module. Inputs are trimmed exactly as the existing derivation trims them (see `ClipmanCli/internal/identity/fixture_test.go`, `TestTrimmedTokenSelectsTheSameBucket`).

```
key            = SHA256(UTF8(trim(token)))
channelId(k)   = base64url_nopad(HMAC-SHA256(key, UTF8("Clipman.ServerChannelId.v1\n"  + password + "\n" + k)))
syncRulesId    = base64url_nopad(HMAC-SHA256(key, UTF8("Clipman.ServerSyncRulesId.v1\n" + password)))
```

where `k` is the normalized channel key (Section 2.4). Both produce 43-char base64url ids the deployed server already accepts. The core channel keeps the existing `Clipman.ServerDatabaseId.v1` id - existing data never moves.

Cross-client test vectors (token `example-token`, password `example-password`):

| Purpose | Input | Expected id |
|---|---|---|
| existing database id | - | `l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU` |
| sync rules id | - | `j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ` |
| channel id | `work` | `F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA` |
| channel id | `images` | `K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ` |
| channel id | `desktop only` | `02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o` |

The existing-database-id vector doubles as a regression check that the new code did not disturb the old derivation.

Shared-folder mode maps channels to sibling files in the data folder:

```
clipman-history.clipdb                  (core - unchanged name)
clipman-channel-<key-with-spaces-as-dashes>.clipdb
clipman-sync-rules.clipdb
```

Old clients ignore unknown sibling files (the conflict resolver only matches siblings of the stem it is asked about, `SyncConflictResolver.cs:96-113`), so mixed folders are safe.

## 2.4 Channel keys and device matching

- Channel display name: what the user typed, stored in the rules document (`Name`).
- Channel key: `lower(trim(Name))`, ASCII only. Validation (enforced by every rules editor): 1-32 chars matching `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?` after lowering; reject non-ASCII so no Unicode normalization library is needed on any platform. Reserved keys, rejected as channel names: `core`, `all`, `pinned`, `sync-rules`.
- Device matching (rules `Devices[].Name` vs the local device name, and routes' `SourceDevices` vs `Entry.SourceMachine`): compare `lowerInvariant(trim(x))`. This is deliberately stricter than the UI filter's `CurrentCultureIgnoreCase` because routing must be identical on every platform; document the difference in the spec. Device names themselves stay free text.

## 2.5 The rules document

Stored as JSON inside a standard `CLIPDB2` container (encrypted when a history password exists, `CLIPDB1` compressed otherwise - exactly the container selection logic in `ClipDatabaseFile.cs:64-79`). The payload is this document, not a `ClipDatabase`:

```json
{
  "Clipman": "sync-rules",
  "Version": 1,
  "Enabled": true,
  "UpdatedUnixMs": 1757200000000,
  "UpdatedBy": "Desktop",
  "Channels": [
    { "Name": "Images",  "Route": { "Kind": "RichTextImages" } },
    { "Name": "Work",    "Route": { "Groups": ["Work", "Standup"] } },
    { "Name": "Desktop only", "Route": { "SourceDevices": ["Desktop", "Work-PC"] } }
  ],
  "Devices": [
    { "Name": "Desktop",     "Channels": ["*"] },
    { "Name": "Jeff-iPhone", "Channels": ["work"] },
    { "Name": "Work-PC",     "Channels": ["work", "desktop only"] }
  ]
}
```

Semantics:

- `Version`: document format version. Clients that see a higher major version than they understand treat rules as read-only and sync core plus the channels they can resolve; they must not rewrite the document.
- `Enabled`: false means every updated client behaves exactly as today (single bucket), even if channels are defined. The off switch is instant and global.
- `Channels[].Route` conditions are ANDed within one route; a route must have at least one condition. `Groups` and `SourceDevices` match case-insensitively per Section 2.4. `Kind` currently allows only `"RichTextImages"`: matches when `RichText != null` and `RichText.HtmlFragment` contains the substring `data:image/` (ordinal). Routing is evaluated top to bottom; first match wins; no match = core.
- `Devices[].Channels`: channel keys, or the single element `"*"` meaning all channels. Core is implicit and always synced by everyone. A device whose name is not listed subscribes to **everything** (safe default: behaves like today).
- Concurrency: the rules bucket uses the same `If-Match` flow. Merge rule for concurrent edits is whole-document last-writer-wins on `UpdatedUnixMs` (ties: higher `UpdatedBy` ordinal), mirroring the existing settings-conflict rule (`SyncConflictResolver.cs:12-40`). Rules edits are rare; entry-level rules merging is not worth its complexity.
- Every client caches the last-seen rules document locally (next to its server cache / settings). If the rules bucket is missing (404) but a cache exists, the cache stays in effect and the client re-uploads it with `If-None-Match: *`; if neither exists, rules are treated as disabled.

## 2.6 Multi-channel sync algorithm

Terminology: the **view** is the merged in-memory database the UI shows; **residence** maps each entry id to the channel blob it was loaded from.

Download/poll (per poll tick):

1. `HEAD` the rules bucket. If revision changed, `GET` + decode + LWW-merge into the cached rules document; recompute the subscription set.
2. For each subscribed channel (core + subscriptions), `HEAD`; `GET` only those whose revision changed. Requests run in parallel where the platform's HTTP stack allows; on Windows keep them sequential inside the existing lock for the first iteration (matching current architecture) - it is still at most a handful of small requests.
3. Merge each changed channel database into the view using the existing entry-level merge, remembering residence. Tombstones apply only within their own channel, with one exception: a tombstone with a non-empty `TextHash` also suppresses matching-text entries in other channels (preserves today's cross-copy dedupe behavior).
4. If the same `Id` appears in two channels (race during a move), the copy with the higher `ModifiedUnixMs` wins; the loser is dropped from the view and queued for repair on next save.

Upload (per local mutation, replacing "upload the whole database"):

1. Recompute `target = route(entry)` for every entry in the view.
2. Build one `ClipDatabase` per channel: entries whose target is that channel; tombstones belonging to that channel.
3. Relocations (residence != target): the entry moves into the target channel's database, and a **relocation tombstone** is added to the source channel: `{Id: entry.Id, TextHash: "", DeletedUnixMs: now, SourceMachine: <this device>}`. The empty `TextHash` is the marker distinguishing "moved" from "deleted": every merge implementation must skip text-hash matching when `TextHash` is empty (the Go merge already only matches non-empty hashes; verify and test on each platform).
4. Dirty detection: for each channel, serialize the plaintext JSON deterministically and compare its SHA-256 to the hash recorded at last download/upload. Only dirty channels are encrypted and `PUT` (with per-channel `If-Match`). This is essential: ciphertext differs every encode (fresh IV), so byte comparison must happen on plaintext, before encryption.
5. On 409 for one channel: `GET` that channel, merge, rebuild, retry - the existing conflict dance, scoped to one small blob.

Ordering note: `NormalizeManualOrderLocked` renumbers densely across the view (`ClipStore.cs:1084-1096`). Appending at the end (the overwhelmingly common capture path) does not renumber existing entries, so only the target channel goes dirty. Deletions and manual reorders can renumber entries across channels and dirty several; the plaintext-hash check keeps untouched channels from uploading. Accept this; do not redesign ordering.

Salt sharing: a channel blob created for the first time copies the core database's salt (the codecs already prefer an existing salt: `codec.go:174-183`, `ClipDatabaseFile.cs:417-433`, `preferredSalt` in `MobileHistoryRepository.swift:63`). One PBKDF2 derivation then serves every channel through the existing key caches.

Deleting a channel (rules editor action): the editing client first re-routes that channel's entries (they fall through to the next matching rule or core), uploads the affected channels, then uploads the now-empty channel database (a few hundred bytes), then removes the channel from the rules document. The empty bucket remains server-side; the server admin may prune it with the existing `--delete-database` tooling. Document this in the server manual.

Rules edits and migration: the device that edits the rules performs the re-route immediately (it already holds the full view if subscribed to `*`; the rules UI requires a device subscribed to all affected channels - enforce in the editor by disabling edits of channels the device does not subscribe to, with an explanatory message). Other devices simply observe moved entries via normal channel merges. Additionally, any client that notices a misrouted resident entry during step 1-2 of upload migrates it; the move operation is idempotent and convergent (same Id LWW-merges in the target; relocation tombstones are per-channel).

## 2.7 Write-through to unsubscribed channels

A device may capture an entry that routes to a channel it does not subscribe to (phone with images excluded captures an image). The writer must not silently keep it local-only:

- Perform a one-shot fetch-merge-put of the target channel: `GET` (or 404 = new), merge the single new entry, `PUT` with `If-Match`/`If-None-Match: *`, then drop the channel from memory. The entry disappears from the device's own view (it is not subscribed) - the UI announces "Added to <channel name> for your other devices." exactly once via the existing status/announcement mechanism of that platform.
- If the write-through fails (offline), the entry stays in a small local pending store and retries on the next successful poll, mirroring the iOS pending-share pattern (`PendingSharedTextStoreTests.swift`).

## 2.8 What old clients see (mixed fleets)

- Old server: no change needed; channels are just more buckets.
- Old client, server mode: syncs only the core bucket. It sees and edits core entries; it never sees channel entries; nothing is lost or corrupted. Its new captures land in core, and updated clients will re-route them on their next save.
- Old client, shared-folder mode: same, via files.
- Consequences to document prominently: enable sync rules only after updating every device; devices left behind simply live in core. The rules UI shows the registered device list so the user can tell who has checked in (Section 2.10).
- Tombstone semantics: an old client deleting a core entry writes a core tombstone; updated clients apply it in core - correct. An old client cannot delete a channel entry it cannot see - acceptable.

## 2.9 Performance analysis (the speed win)

Worked example, using realistic proportions from the caps in the code (iOS embedded-image budget 8 MiB, `EmbeddedImage.swift:57`; Share Extension refuses databases over 32 MiB, `ShareSyncService.swift:29`):

Database: 20 MiB total = 14 MiB images channel + 4 MiB work group channel + 2 MiB core.

| Operation | Today | With rules |
|---|---|---|
| Phone (core only) initial sync | 20 MiB down | 2 MiB down (10x) |
| Phone poll after any desktop change | 20 MiB down | 2 MiB down, and 0 when only the images channel changed |
| Desktop pastes a core entry (MarkUsed) | 20 MiB up | 2 MiB up |
| Desktop captures an image | 20 MiB up | 14 MiB up (images channel only) |
| Merge cost | O(n^2) over all entries | O(n^2) per changed channel only |
| Encrypt/decrypt cost | whole blob | changed channels only; one PBKDF2 total (shared salt + key cache) |

Additional per-poll cost: one `HEAD` per subscribed channel plus one for rules instead of one total. `HEAD`s are bodyless and the server drops successful database `HEAD`s from its log (`clipman_server.py:1685-1691`). For typical rule sets (2-5 channels) this is negligible against the download savings. A future manifest bucket can collapse polling back to one `HEAD` (Part 8).

The iOS Share Extension's 32 MiB refusal threshold and the server's 64 MiB default `MaxDatabaseBytes` both become per-channel limits, which meaningfully raises the practical ceiling on total history size - a second, independent win.

## 2.10 Device registry side benefit

The rules document's `Devices` list doubles as the device registry the codebase currently lacks (`GetDevices()` today only reflects devices that still have entries, `ClipStore.cs:1517-1523`). Updated clients add their own device name to `Devices` on first sync after rules are enabled (with `Channels: ["*"]`), so the rules UI can present real devices instead of free-text guesses. Renaming a device in preferences updates its registry entry (matched by old name) on next sync.

## 2.11 Security and operations notes

- The encryption boundary is unchanged: channel contents, channel names, group names, and device names are never visible to the server. Channel bucket ids are HMACs; the server cannot link them to each other cryptographically, though it can correlate them behaviorally (same client IP polls the set together) - same class of metadata it already sees.
- Per-channel blob sizes give the server slightly finer-grained size/activity telemetry than one blob. Document in the server manual's "what the server can see" section.
- The known weakness that the bucket id is an unstretched HMAC over the password with a server-known key (offline guessing oracle for a malicious server operator) is unchanged in kind; channel ids add nothing new since they require the same password guess. Do not advertise otherwise.
- Backups multiply: `CreateBackupBeforeEveryUpload: true` with `MaxBackups: 48` now applies per bucket. Mention in the server manual; defaults are fine because channel blobs are smaller.
- The per-bucket lock dictionary in the server grows by a few entries per user - no action needed.

## 2.12 Known limitations (document, do not solve now)

- Quick Paste hotkeys referencing an entry in an unsubscribed channel behave as they do today for a deleted entry (hotkey reports the entry as unavailable).
- Deleting an entry on device A while device B concurrently moves it to another channel can resurrect it (tombstone landed in the old channel). Rare; converges on the next edit or delete.
- Text-dedupe on capture only consults subscribed channels, so the same text captured on two devices with disjoint subscriptions can exist twice (in different channels). The cross-channel `TextHash` tombstone rule (2.6 step 3) still applies on delete.
- Retention limits (max entries / max age) evaluate against the subscribed view only. Pinned and named entries remain exempt as today.
- History filter UI (`Device` filter) is unchanged; it filters the subscribed view.

---

# Part 3: File structure

New files:

| Path | Responsibility |
|---|---|
| `sync-rules-spec.md` (repo root) | Normative cross-client spec: derivations, vectors, rules schema, routing, relocation tombstones, write-through. Source of truth for all ports. |
| `ClipmanLinuxBackend/internal/rules/rules.go` + `rules_test.go` | Rules document model, validation, normalization, LWW merge, routing. |
| `ClipmanCli/internal/rules/rules.go` + `rules_test.go` | Byte-identical fork (per policy). |
| `ClipmanLinuxBackend/internal/syncengine/channels.go` + `channels_test.go` | Multi-channel engine: ReadView, MutateView, dirty tracking, relocation. |
| `ClipmanCli/internal/syncengine/channels.go` + `channels_test.go` | Fork. |
| `src/SyncRules.cs` | C#: rules document DTOs, validation, routing, LWW merge, channel id derivation helpers. |
| `src/SyncRulesForm.cs` | Accessible rules editor dialog (channels list, devices list, per-device subscriptions). |
| `ClipmanMac/Sources/ClipmanCore/SyncRules.swift`, `ClipmanIOS/ClipmanIOS/Core/SyncRules.swift`, `ClipmanAndroid/.../SyncRules.kt` | Per-platform ports of the same module. |

Modified files (primary): `ClipmanCli/internal/identity/identity.go` and fork, `ClipmanCli/internal/merge/merge.go` and fork (empty-TextHash skip verification), `src/ServerDatabaseIdentity.cs`, `src/ClipStore.cs`, `src/Models.cs` (settings field), `src/PreferencesForm.cs` (entry point button), `src/SettingsStore.cs` (rules cache path), `ClipmanMac/Sources/Clipman/ClipStore.swift`, `ClipmanIOS/ClipmanIOS/Core/MobileHistoryRepository.swift`, `ClipmanIOS/Shared/ShareSyncService.swift`, `ClipmanAndroid/.../LocalHistoryStore.kt`, `MainActivity.kt`, `ClipmanLinux/clipman.py` (settings dialog), `Manual.html`, `ClipmanServer/Manual.html`, `clipman-cli-spec.md`, test files per platform.

---

# Part 4: Tasks

Execute phases in order. Within a phase, tasks are ordered. Ship-readiness gates: Phase 1 (Go, both trees) is the reference implementation and must be green before any port begins; each port phase ends with the cross-client fixtures passing.

## Phase 0 - Specification

### Task 0.1: Write sync-rules-spec.md

**Files:**
- Create: `sync-rules-spec.md`

**Interfaces:**
- Produces: the normative spec every later task cites. Content: Sections 2.3-2.8 of this plan verbatim (derivation strings, test-vector table, rules JSON schema with field-by-field semantics, routing algorithm, relocation tombstone rule, write-through rule, mixed-fleet behavior), plus the channel-key grammar `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?` and reserved keys `core`, `all`, `pinned`, `sync-rules`.

- [ ] **Step 1: Create the file** by copying Part 2 of this plan into a standalone document with a short intro stating it is normative for all clients, and the constraint list from Global Constraints.
- [ ] **Step 2: Verify vectors** by re-running the derivation independently (any language) and confirming the five values in the table in Section 2.3.
- [ ] **Step 3: Commit** - `git add sync-rules-spec.md && git commit -m "docs: add normative sync rules specification"` (create commits only if the repository owner has asked for commits; otherwise leave staged and note it - this applies to every commit step in this plan).

## Phase 1 - Go reference implementation (CLI and Linux backend, both trees in every task)

### Task 1.1: Channel identity derivation

**Files:**
- Modify: `ClipmanLinuxBackend/internal/identity/identity.go`, `ClipmanCli/internal/identity/identity.go`
- Test: `ClipmanLinuxBackend/internal/identity/identity_test.go`, `ClipmanCli/internal/identity/identity_test.go`

**Interfaces:**
- Consumes: existing `DatabaseID(token, password string) string` (inspect the file for the exact existing name and trimming; reuse its key computation).
- Produces: `func ChannelDatabaseID(token, password, channelKey string) string` and `func SyncRulesDatabaseID(token, password string) string`. Empty result when token or password is blank (mirroring the existing function).

- [ ] **Step 1: Write the failing tests** (same file content in both trees):

```go
func TestChannelDatabaseIDMatchesFixture(t *testing.T) {
    got := ChannelDatabaseID("example-token", "example-password", "work")
    want := "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
    if got != want {
        t.Fatalf("channel id = %q, want %q", got, want)
    }
    if ChannelDatabaseID("", "p", "work") != "" || ChannelDatabaseID("t", "", "work") != "" {
        t.Fatal("blank token or password must yield empty id")
    }
}

func TestSyncRulesDatabaseIDMatchesFixture(t *testing.T) {
    got := SyncRulesDatabaseID("example-token", "example-password")
    want := "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ"
    if got != want {
        t.Fatalf("rules id = %q, want %q", got, want)
    }
}
```

- [ ] **Step 2: Run to verify failure** - `cd ClipmanCli && go test ./internal/identity/` - expected: compile error, functions undefined. Repeat in `ClipmanLinuxBackend`.
- [ ] **Step 3: Implement** in both trees, following the existing function's structure exactly (same trimming, same key = SHA256 of token, same base64url raw encoding), with messages `"Clipman.ServerChannelId.v1\n" + password + "\n" + channelKey` and `"Clipman.ServerSyncRulesId.v1\n" + password`.
- [ ] **Step 4: Run to verify pass** - `go test ./internal/identity/` in both trees, plus the existing fixture tests (`TestIdentityMatchesEveryClient`, `TestDatabaseIDMatchesWindows`) to prove no regression.
- [ ] **Step 5: Commit** - `feat: derive channel and sync-rules bucket ids`.

### Task 1.2: Rules document model, validation, routing

**Files:**
- Create: `ClipmanLinuxBackend/internal/rules/rules.go`, `ClipmanCli/internal/rules/rules.go`
- Test: `.../internal/rules/rules_test.go` in both trees

**Interfaces:**
- Consumes: `model.Entry` (fields per Section 1.4).
- Produces:

```go
package rules

type Document struct {
    Clipman       string    `json:"Clipman"`
    Version       int       `json:"Version"`
    Enabled       bool      `json:"Enabled"`
    UpdatedUnixMs int64     `json:"UpdatedUnixMs"`
    UpdatedBy     string    `json:"UpdatedBy"`
    Channels      []Channel `json:"Channels"`
    Devices       []Device  `json:"Devices"`
}
type Channel struct {
    Name  string `json:"Name"`
    Route Route  `json:"Route"`
}
type Route struct {
    Groups        []string `json:"Groups,omitempty"`
    SourceDevices []string `json:"SourceDevices,omitempty"`
    Kind          string   `json:"Kind,omitempty"`
}
type Device struct {
    Name     string   `json:"Name"`
    Channels []string `json:"Channels"`
}

func ChannelKey(name string) string                          // lower(trim); "" if invalid per grammar
func Validate(doc *Document) error                           // grammar, reserved keys, duplicate keys, empty routes
func RouteEntry(doc *Document, e *model.Entry) string        // channel key or "" (= core); "" when doc nil/disabled
func SubscribedChannels(doc *Document, deviceName string) []string // keys; nil means "all channels"
func MergeDocuments(local, remote *Document) *Document       // whole-doc LWW on UpdatedUnixMs, tie on UpdatedBy
func Parse(data []byte) (*Document, error)
func Serialize(doc *Document) []byte                         // deterministic field order via the struct tags above
```

- [ ] **Step 1: Write the failing tests.** Cover at minimum:

```go
func TestChannelKeyGrammar(t *testing.T)            // "Work " -> "work"; "Desktop Only" -> "desktop only"; "-bad" -> ""; "core" invalid via Validate; 33 chars -> ""
func TestRouteFirstMatchWins(t *testing.T)          // images rule before work rule: an image entry in group Work routes to images
func TestRouteConditionsAreAnded(t *testing.T)      // Route{Groups:["Work"], SourceDevices:["Desktop"]} does not match a Work entry from Phone
func TestRouteUnmatchedGoesToCore(t *testing.T)     // returns ""
func TestRouteDisabledDocRoutesEverythingToCore(t *testing.T)
func TestRouteKindRichTextImages(t *testing.T)      // matches only when HtmlFragment contains "data:image/"
func TestSubscribedUnknownDeviceGetsAll(t *testing.T) // nil result for a device not listed
func TestSubscribedStarExpandsToAllChannels(t *testing.T)
func TestMergeDocumentsLastWriterWins(t *testing.T)
func TestSerializeParseRoundTrip(t *testing.T)
```

Group/device comparisons inside `RouteEntry` use `strings.ToLower(strings.TrimSpace(x))` on both sides.

- [ ] **Step 2: Run to verify failure**, both trees.
- [ ] **Step 3: Implement** `rules.go` (~150 lines). `RouteEntry` iterates `doc.Channels` in order; a `Route` matches when every specified condition matches; `Kind == "RichTextImages"` checks `e.RichText != nil && strings.Contains(e.RichText.HtmlFragment, "data:image/")` (adjust to the actual `RichText` field type in `model.go` - it is a struct pointer with `HtmlFragment`).
- [ ] **Step 4: Run to verify pass**, both trees; then `gofmt -l internal/rules` must print nothing.
- [ ] **Step 5: Commit** - `feat: sync rules document model and routing`.

### Task 1.3: Raw-document codec support for the rules blob

**Files:**
- Modify: `ClipmanLinuxBackend/internal/clipdb/codec.go`, `ClipmanCli/internal/clipdb/codec.go`
- Test: existing `codec_test.go` files in both trees

**Interfaces:**
- Consumes: the internal encrypt/decrypt/compress helpers already present in `codec.go` (they currently operate on the marshaled `Database` bytes; factor the byte-level container logic out of the `Database`-specific entry points without changing their behavior).
- Produces: `func EncodeRaw(payload []byte, password string, preferredSalt []byte) ([]byte, error)` and `func DecodeRaw(blob []byte, password string) (payload []byte, salt []byte, err error)` - same CLIPDB1/CLIPDB2 container rules as `Encode`/`Decode`, arbitrary JSON payload.

- [ ] **Step 1: Write the failing test** (both trees):

```go
func TestRawDocumentRoundTripEncrypted(t *testing.T) {
    payload := []byte(`{"Clipman":"sync-rules","Version":1,"Enabled":true}`)
    blob, err := EncodeRaw(payload, "pw", nil)
    if err != nil { t.Fatal(err) }
    got, _, err := DecodeRaw(blob, "pw")
    if err != nil { t.Fatal(err) }
    if !bytes.Equal(got, payload) { t.Fatalf("round trip mismatch") }
    if _, _, err := DecodeRaw(blob, "wrong"); err == nil {
        t.Fatal("wrong password must fail")
    }
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** by extracting the container encode/decode paths; existing `Encode`/`Decode` become thin wrappers so every existing codec test still passes unchanged (this is the regression guard for the refactor).
- [ ] **Step 4: Run the full codec test suites** in both trees: `go test ./internal/clipdb/`.
- [ ] **Step 5: Commit** - `feat: raw document container encode/decode for rules blob`.

### Task 1.4: Empty-TextHash relocation tombstones in merge

**Files:**
- Modify (if needed): `ClipmanLinuxBackend/internal/merge/merge.go`, `ClipmanCli/internal/merge/merge.go` (must stay byte-identical to each other)
- Test: `.../internal/merge/merge_test.go` in both trees

- [ ] **Step 1: Write the failing/characterization test:**

```go
func TestEmptyTextHashTombstoneMatchesOnlyById(t *testing.T) {
    // A tombstone {Id:"a", TextHash:""} must delete entry Id "a"
    // and must NOT delete a different entry with any text.
}
func TestNormalizeKeepsEmptyTextHashTombstones(t *testing.T) {
    // normalizeDeleted must not back-fill an empty TextHash from a duplicate marker
    // when the marker is a relocation (empty hash is intentional).
}
```

- [ ] **Step 2: Run.** The first may already pass (`merge.go` `IsDeleted` matches `TextHash` only when non-empty - verify at `merge.go:104-118`); the second exercises the back-fill at `merge.go:267-274` and likely needs a guard.
- [ ] **Step 3: Implement the guard** if needed: skip hash back-fill for markers whose `TextHash` is empty. Apply identically to both trees.
- [ ] **Step 4: Run** `go test ./internal/merge/` in both trees; run the full cross-client fixture suite `go test ./...` in `ClipmanCli`.
- [ ] **Step 5: Commit** - `fix: preserve relocation tombstones with empty text hash`.

### Task 1.5: Multi-channel sync engine

**Files:**
- Create: `ClipmanLinuxBackend/internal/syncengine/channels.go` + `channels_test.go`; fork to `ClipmanCli`
- Modify: `ClipmanLinuxBackend/internal/syncengine/engine.go` only if shared helpers are needed; keep `Read`/`Mutate` untouched for the disabled-rules path

**Interfaces:**
- Consumes: `server.Client` (Get/Head/Put with revision), `clipdb.Encode/Decode/EncodeRaw/DecodeRaw`, `merge` package, `rules` package, `identity` package.
- Produces:

```go
type ChannelState struct {
    Key       string          // "" for core
    Revision  string
    PlainHash [32]byte        // sha256 of deterministic plaintext at last transfer
    Database  *model.Database
}
type ViewState struct {
    Rules         *rules.Document
    RulesRevision string
    Channels      []ChannelState
    View          *model.Database          // merged, normalized
    Residence     map[string]string        // entry id -> channel key
}
func (e *Engine) ReadView(deviceName string) (*ViewState, error)
func (e *Engine) MutateView(deviceName string, mutate func(db *model.Database) error) (*ViewState, error)
```

`ReadView` with a nil/disabled rules document must return a `ViewState` whose single core channel is exactly what `Read` returns today. `MutateView` implements Section 2.6's upload algorithm including relocation tombstones, dirty-hash skip, per-channel conflict retry (reuse the existing retry/backoff constants from `Mutate`), and write-through for unsubscribed target channels.

- [ ] **Step 1: Write the failing tests** against the same fake server the existing `engine_test.go` uses (read it first and reuse its test double):

```go
func TestReadViewDisabledRulesMatchesLegacyRead(t *testing.T)
func TestReadViewMergesSubscribedChannelsOnly(t *testing.T)      // unsubscribed channel blob never fetched (assert on fake-server request log)
func TestMutateViewUploadsOnlyDirtyChannels(t *testing.T)        // touching a core entry must not PUT the work channel
func TestMutateViewRelocatesEntryOnGroupChange(t *testing.T)     // entry moves core->work: work gains entry, core gains empty-hash tombstone
func TestMutateViewWriteThroughUnsubscribedChannel(t *testing.T) // new image entry on a device not subscribed to images still lands in images bucket
func TestReadViewDuplicateIdResolvedByModified(t *testing.T)
func TestRulesConflictLastWriterWins(t *testing.T)
func TestMissingRulesBucketFallsBackToCache(t *testing.T)
```

- [ ] **Step 2: Run to verify failure**, both trees.
- [ ] **Step 3: Implement `channels.go`** (~250 lines). Deterministic plaintext for hashing = the codec's existing deterministic `MarshalJSON` ordering (`model.go marshalOrdered`). Fetch order: rules, then channels; merge order: core first, then channels in rules order.
- [ ] **Step 4: Run** `go test ./internal/syncengine/` then `go test ./...` in both trees.
- [ ] **Step 5: Commit** - `feat: multi-channel sync engine with rules routing`.

### Task 1.6: CLI surface

**Files:**
- Modify: `ClipmanCli/cmd/clipman-cli/main.go`, `ClipmanCli/internal/operation/operation.go`
- Test: `ClipmanCli/cmd/clipman-cli/main_test.go`, `ClipmanCli/internal/operation/operation_test.go`

**Interfaces:**
- Consumes: `Engine.ReadView` / `Engine.MutateView` from Task 1.5; config key `machine` for the device name.
- Produces commands (JSON output shapes follow the existing `output` package conventions - read `internal/output` first):
  - `clipman-cli rules show` - prints the document (or "Sync rules are not enabled.").
  - `clipman-cli rules enable` / `rules disable`
  - `clipman-cli rules channel add <name> [--group G]... [--source-device D]... [--kind richtextimages]`
  - `clipman-cli rules channel remove <name>` (performs the re-route + empty upload of Section 2.6)
  - `clipman-cli rules device set <device> --channels <k1,k2|*>`
  - `list`/`get`/`put`/`delete`/`sync` switch to the view engine; behavior with rules disabled is unchanged (assert with existing tests).

- [ ] **Step 1: Write failing command tests** following the pattern of existing `main_test.go` command tests (table-driven over argv, asserting output and resulting server state via the fake server): one test per new subcommand plus `TestListUsesSubscribedViewOnly`.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement**, wiring `rules` mutations through `MutateView`-style read-modify-write on the rules bucket (with `If-Match`).
- [ ] **Step 4: Run** `go test ./...` in `ClipmanCli`; `go vet ./...`.
- [ ] **Step 5: Commit** - `feat(cli): rules management commands and channel-aware sync`.

### Task 1.7: Linux backend session integration and Linux UI

**Files:**
- Modify: `ClipmanLinuxBackend/cmd/clipman-gui-backend/main.go` (`activate`, `refresh`, `mutate`, `setState` handlers), `ClipmanLinux/clipman.py` (settings dialog + Backend calls)
- Test: `ClipmanLinuxBackend/cmd/clipman-gui-backend/main_test.go`

**Interfaces:**
- Consumes: `ReadView`/`MutateView`; the backend's JSON-lines protocol (read the existing request/response shapes in `main.go` before adding).
- Produces: new backend requests `rules-get`, `rules-set` (full document), and `refresh` responses gain `"channels": [{"key","revision"}]` alongside the existing `revision`. The Python UI gets a "Sync rules" dialog: a channel list, a device list, per-device channel checkboxes, add/remove channel with group/source-device/kind fields - all standard accessible GTK/Tk widgets consistent with the existing dialogs in `clipman.py` (mirror the structure of the existing server-connection dialog around `clipman.py:4241`).

- [ ] **Step 1: Write failing backend tests** in `main_test.go` mirroring `TestConfiguredSessionMutationRoundTrip`: `TestRulesRoundTripThroughSession`, `TestRefreshSkipsUnsubscribedChannels`.
- [ ] **Step 2: Run to verify failure** - `cd ClipmanLinuxBackend && go test ./cmd/clipman-gui-backend/`.
- [ ] **Step 3: Implement** backend handlers, then the Python dialog (manual verification for the dialog; automated coverage of Python UI is out of scope, consistent with the existing test layout).
- [ ] **Step 4: Run** `go test ./...`; launch the Linux UI against a local test server and exercise the dialog with keyboard only; verify screen-reader labels with Orca if available, otherwise verify every widget has an accessible label property set.
- [ ] **Step 5: Commit** - `feat(linux): sync rules session support and settings dialog`.

## Phase 2 - Windows client

### Task 2.1: C# identity + rules module

**Files:**
- Modify: `src/ServerDatabaseIdentity.cs`
- Create: `src/SyncRules.cs`
- Test: `tests/WindowsRegressionTests.cs`

**Interfaces:**
- Produces in `ServerDatabaseIdentity`: `public static string ChannelFromTokenAndPassword(string token, string password, string channelKey)` and `public static string SyncRulesFromTokenAndPassword(string token, string password)`, structured exactly like the existing `FromTokenAndPassword` (`ServerDatabaseIdentity.cs:10-22`).
- Produces in `SyncRules.cs`: `SyncRulesDocument`, `SyncChannel`, `SyncRoute`, `SyncDevice` DTOs (property names identical to the JSON schema in Section 2.5 so `JavaScriptSerializer` maps them directly), plus `public static class SyncRuleEngine` with `ChannelKey(string name)`, `Validate(SyncRulesDocument doc)`, `RouteEntry(SyncRulesDocument doc, ClipEntry entry)`, `SubscribedChannels(SyncRulesDocument doc, string deviceName)`, `MergeDocuments(SyncRulesDocument local, SyncRulesDocument remote)` - semantics per `sync-rules-spec.md`, comparisons via `Trim()` + `ToLowerInvariant()`.

- [ ] **Step 1: Write the failing tests** in `tests/WindowsRegressionTests.cs` following its existing static-test-method pattern (read `Run-WindowsRegressionTests.ps1` and the file's main method first to register them the same way):

```csharp
static void ChannelIdentityMatchesCrossClientFixture()
{
    AssertEqual("F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA",
        ServerDatabaseIdentity.ChannelFromTokenAndPassword("example-token", "example-password", "work"));
    AssertEqual("j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ",
        ServerDatabaseIdentity.SyncRulesFromTokenAndPassword("example-token", "example-password"));
}
static void RoutingFirstMatchAndAndSemantics() { /* port the Task 1.2 routing cases */ }
static void RulesDocumentJsonRoundTrip() { /* JavaScriptSerializer round trip preserves all fields */ }
```

- [ ] **Step 2: Run to verify failure** - `powershell -File tests/Run-WindowsRegressionTests.ps1` - expected: compile error.
- [ ] **Step 3: Implement** `SyncRules.cs` and the two identity methods.
- [ ] **Step 4: Run to verify pass** - same command; all pre-existing tests must remain green.
- [ ] **Step 5: Commit** - `feat(windows): sync rules model, routing, channel identity`.

### Task 2.2: ClipStore multi-channel storage

**Files:**
- Modify: `src/ClipStore.cs` (poll: `PollServer` `:1194`, download: `SyncFromServerLocked` `:1261`, upload: `UploadToServerLocked` `:1342`, save: `SaveLocked` `:1022`), `src/SettingsStore.cs` (channel cache paths beside `ServerCachePathFor`, `:717-732`), `src/ClipmanApplicationContext.cs` (configure path `:3044`). No `AppSettings` change is needed: rules live server-side (or in the shared folder) with a local cache file, not in per-machine settings.
- Test: `tests/WindowsRegressionTests.cs`

**Interfaces:**
- Consumes: Task 2.1 module; existing `ServerStorageClient` (constructed per bucket id - it already takes the database id, `ServerStorageClient.cs:229-232`).
- Produces inside `ClipStore`: a private `List<ChannelSlot>` (`class ChannelSlot { public string Key; public string Revision; public byte[] PlainHash; public ClipDatabase Database; public ServerStorageClient Client; }`), a residence dictionary, and rules-aware versions of the four methods above. With no rules document or `Enabled == false`, every new code path must collapse to the current single-bucket behavior (guard clause first, so the diff to today's flow is provably zero in that case).
- Shared-folder mode: channel files `clipman-channel-<key>.clipdb` in the database directory, watched by widening the existing `FileSystemWatcher` filter from the single filename to `*.clipdb` with a name check in the handler (`ClipStore.cs:1098-1135`); rules file `clipman-sync-rules.clipdb` loaded/saved via the existing generic `ClipDatabaseFile.SaveAtomic<T>`/load.

- [ ] **Step 1: Write the failing tests** (these run against temp directories in file mode, like `RunningHistoryReloadsExplicitExternalChanges` at `WindowsRegressionTests.cs:403` - follow that pattern; server-mode paths are covered by the Go engine tests and by manual verification because the Windows harness has no HTTP fake):

```csharp
static void RulesRouteEntriesIntoChannelFilesOnSave()      // file mode: enable rules with a work channel; add a Work entry; assert clipman-channel-work.clipdb exists and core lacks the entry
static void RulesDisabledKeepsSingleDatabaseFile()         // byte-for-byte legacy behavior
static void GroupChangeRelocatesEntryBetweenChannelFiles() // and leaves an empty-TextHash tombstone in the source
static void UnsubscribedChannelFileIsNotLoadedIntoView()
static void DirtyHashSkipsRewritingUntouchedChannelFiles() // record file mtimes, touch a core entry, assert work channel file unchanged
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** in this order: (a) rules cache load/save + subscription computation; (b) view assembly on load (merge channel files/buckets via the existing `MergeDatabaseIntoLocked`, tracking residence); (c) split-on-save with routing, relocation tombstones, per-channel plaintext SHA-256 dirty check (plaintext = the serialized JSON `SaveLocked` already produces, hashed before encryption); (d) per-channel server poll/upload by iterating `ChannelSlot`s inside the existing lock and generation guard; (e) write-through per Section 2.7 with a pending queue persisted beside the server cache.
- [ ] **Step 4: Run** `powershell -File tests/Run-WindowsRegressionTests.ps1`; every pre-existing test must pass (especially `RunningHistoryReloadsExplicitExternalChanges`, `ServerPollSchedulingIsBounded`, `CommandLineEntriesRetainConfiguredDeviceIdentity`).
- [ ] **Step 5: Manual server-mode verification**: run a local `clipman_server.py`, connect the built client, enable rules via the Task 2.3 UI (or a hand-written rules cache file for now), and confirm with the server's request log + bucket directory listing that only subscribed channel buckets are fetched and only dirty ones are PUT.
- [ ] **Step 6: Commit** - `feat(windows): channel-partitioned storage and sync`.

### Task 2.3: Windows rules editor UI

**Files:**
- Create: `src/SyncRulesForm.cs`
- Modify: `src/PreferencesForm.cs` (a "Sync rules..." button on the storage/server tab near `:248-348`), `src/ClipmanApplicationContext.cs` (open the form; apply changes through `ClipStore`)

**Interfaces:**
- Consumes: `SyncRulesDocument` + `SyncRuleEngine` (Task 2.1); `ClipStore.GetDevices()` (`ClipStore.cs:1517`) merged with the rules registry (Section 2.10) for the device list.
- Produces: a modal dialog: "Enable sync rules" checkbox; "Channels" ListView (columns Name, Rule summary) with Add/Edit/Remove buttons; channel editor sub-dialog with Name textbox, Groups checked list (from `ClipStore` group labels), Source devices checked list, "Rich text images" checkbox; "Devices" ListView with per-device "Receives" edit opening a checked list of channels plus an "All channels" checkbox. Every control gets `AccessibleName`/`AccessibleDescription`; state changes are announced by updating control text, not color; full keyboard operation; Enter/Escape semantics match `EntryPropertiesForm`. Warning label text (always visible, not color-coded): "Enable sync rules only after every device runs a Clipman version that supports them. Older devices will continue to sync the core channel only."
- Removing a channel triggers the re-route flow (Section 2.6) with a confirmation dialog stating exactly what happens: "Entries in this channel will move to the next matching channel or to the main history. No entries are deleted."

- [ ] **Step 1: Build the form skeleton** following `PreferencesForm.cs` layout conventions (rows, mnemonics like "Device la&bel:" at `:195`).
- [ ] **Step 2: Wire load/save** through `ClipStore` (document read from the rules cache/bucket, saved with `If-Match`, LWW on conflict, then a forced poll).
- [ ] **Step 3: Verify with keyboard and screen reader**: Tab order, mnemonics, NVDA reads every control's name and value, list navigation announces row content. Fix anything that announces as "unnamed".
- [ ] **Step 4: Run the regression suite** (UI form compiles under the same csc harness).
- [ ] **Step 5: Commit** - `feat(windows): accessible sync rules editor`.

## Phase 3 - macOS client

### Task 3.1: Port the rules module and channel sync to Mac

**Files:**
- Create: `ClipmanMac/Sources/ClipmanCore/SyncRules.swift`
- Modify: `ClipmanMac/Sources/ClipmanCore/ServerDatabaseIdentity.swift`, `ClipmanMac/Sources/Clipman/ClipStore.swift` (poll `pollServerLocked` around `:902`, sync `syncFromServerLocked` `:965`, upload path `:981-1005`), `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift` (rules window entry point)
- Test: create `ClipmanMac/Tests/ClipmanCoreTests/SyncRulesTests.swift`

**Interfaces:**
- Produces: `struct SyncRulesDocument: Codable` with `CodingKeys` matching the PascalCase JSON exactly; `enum SyncRuleEngine` with `channelKey(_:)`, `validate(_:)`, `route(document:entry:) -> String?`, `subscribedChannels(document:deviceName:) -> [String]?`, `merge(local:remote:)`; identity additions `channelDatabaseId(token:password:channelKey:)` and `syncRulesDatabaseId(token:password:)`. Mac note: `ClipStore` uploads raw file bytes from disk (`ClipStore.swift:1005`) - keep that pattern per channel file (channel cache files beside the existing one), and reuse the shared-folder channel filenames from Section 2.3 since Mac also supports folder mode.

- [ ] **Step 1: Write failing tests** in `SyncRulesTests.swift`: the identity fixture vectors, the routing table from Task 1.2, Codable round trip. Run: `cd ClipmanMac && swift test` - expected failure.
- [ ] **Step 2: Implement** `SyncRules.swift` + identity, make tests pass.
- [ ] **Step 3: Integrate** into `ClipStore.swift` per the Section 2.6 algorithm (mirror the Windows Task 2.2 structure: guard-clause legacy path, channel slots, residence, dirty hash on plaintext Data before encryption).
- [ ] **Step 4: Add the rules window** (SwiftUI or AppKit consistent with existing preferences; VoiceOver labels on every control; run through with VoiceOver once).
- [ ] **Step 5: Run** `swift test`; manual verification against a local server as in Task 2.2 Step 5.
- [ ] **Step 6: Commit** - `feat(mac): sync rules and channel-aware sync`.

## Phase 4 - iOS client

### Task 4.1: Port to iOS app and Share Extension

**Files:**
- Create: `ClipmanIOS/ClipmanIOS/Core/SyncRules.swift` (independent copy - iOS and Mac do not share code; port from the Mac file)
- Modify: `ClipmanIOS/ClipmanIOS/Core/ServerDatabaseIdentity.swift`, `ClipmanIOS/ClipmanIOS/Core/MobileHistoryRepository.swift` (persist per-channel `{identity, revision}` in `server-sync-state.json`, `:17-20`, `:260-278`), `ClipmanIOS/ClipmanAppModel.swift` (poll loop `:523-700`), `ClipmanIOS/Shared/ShareSyncService.swift` and `ShareSyncConfigurationStore.swift` (cache the rules document in the shared app group so the extension can route), `ClipmanIOS/ClipmanIOS/Views/SettingsView.swift` (rules screen)
- Test: `ClipmanIOS/ClipmanIOSTests/SyncRulesTests.swift`, extend `ShareSyncServiceTests.swift`

**Interfaces:**
- Consumes: the spec + Mac port as reference.
- Produces: same module surface as Task 3.1. Share Extension behavior: route the shared text/image with the cached rules; if the target channel is not the extension's subscribed set, do the one-shot write-through against that channel's bucket (the extension already implements a 3-attempt download-mutate-put loop at `ShareSyncService.swift:73-116` - point it at the routed channel's id instead of the core id). The 32 MiB guard (`ShareSyncService.swift:29`, `:83-85`) now applies per channel, which is the headline iOS win: sharing a photo no longer requires downloading unrelated text history at all when images have their own channel.

- [ ] **Step 1: Write failing tests**: fixture vectors, routing table, `testShareRoutesImageToImagesChannel` (extend the existing `ShareSyncServiceTests` fake transport), `testPollSkipsUnsubscribedChannels`.
- [ ] **Step 2: Implement**; iOS settings screen lists rules read-mostly (view + per-device subscription editing for this device; full channel editing stays desktop/CLI-first for v1 - the document supports it, the phone UI does not need it).
- [ ] **Step 3: Run** the iOS test suite via `xcodebuild test` per `ClipmanIOS/README.md` instructions; VoiceOver pass over the new screen.
- [ ] **Step 4: Commit** - `feat(ios): sync rules and channel-aware sync`.

## Phase 5 - Android client

### Task 5.1: Port to Android

**Files:**
- Create: `ClipmanAndroid/app/src/main/java/me/onj/clipman/SyncRules.kt`
- Modify: `ServerDatabaseIdentity.kt`, `LocalHistoryStore.kt` (`synchronize` `:159`, `persistMutation` `:104`), `MainActivity.kt` (poll loop `:1331-1337`, `loadHistory` `:792`, `saveDatabaseChange` `:931`, settings screen `:2292` area), `SecureSettings.kt` (rules cache)
- Test: `ClipmanAndroid/app/src/test/java/me/onj/clipman/SyncRulesTest.kt`, extend `MobileMutationFastPathTest.kt`

**Interfaces:** same module surface, Kotlin idioms; JSON via the same serializer `ClipModels.kt` uses. The mutation fast path (`knownRevisionUploadsDirectlyWithoutDownloading`) must become per-channel: a mutation touching only core uses core's known revision.

- [ ] **Step 1: Write failing tests**: fixture vectors, routing table, `mutationTouchingCoreOnlyUploadsCoreChannel` in `MobileMutationFastPathTest.kt` style.
- [ ] **Step 2: Implement**; Android settings gets the same read-mostly rules screen as iOS with TalkBack-verified labels.
- [ ] **Step 3: Run** `cd ClipmanAndroid && ./gradlew test`.
- [ ] **Step 4: Commit** - `feat(android): sync rules and channel-aware sync`.

## Phase 6 - Cross-client fixtures and CLI spec

### Task 6.1: Golden fixtures

**Files:**
- Modify: `ClipmanCli/testdata/fixtures/` (new fixture set + `manifest.json` entry), `ClipmanCli/internal/identity/fixture_test.go`, and each platform's fixture-consuming test

- [ ] **Step 1: Generate fixtures with the Go reference**: a rules document blob (`sync-rules.clipdb`), a core blob, and a `work` channel blob, all under token `example-token` / password `example-password`, plus an `expected-view.json` of the merged view. Write a small `go test` helper in `ClipmanCli` that regenerates them deterministically (fixed timestamps in the fixture data; no wall-clock).
- [ ] **Step 2: Extend `TestIdentityMatchesEveryClient`** with the channel and rules ids.
- [ ] **Step 3: Add a fixture-decode test on each platform** (Windows regression test, Swift test, Kotlin test) asserting the platform decodes the three blobs and produces `expected-view.json`'s entry set for device `Jeff-iPhone` (subscribed to `work` only: view = core + work).
- [ ] **Step 4: Run every suite**: `go test ./...` (both trees), Windows harness, `swift test`, `xcodebuild test`, `./gradlew test`, `python -m pytest ClipmanServerLinux/test_clipman_server.py` (unchanged, as a no-regression check).
- [ ] **Step 5: Commit** - `test: cross-client sync rules fixtures`.

### Task 6.2: Update clipman-cli-spec.md

- [ ] Document the new `rules` commands, the channel-aware behavior of `list/get/put/delete/sync`, and a pointer to `sync-rules-spec.md`. Keep the fork-policy section (`:160-170`) accurate about the new `rules` and `syncengine/channels` files. Commit - `docs(cli): sync rules commands`.

## Phase 7 - Manuals and rollout

### Task 7.1: Client manual (`Manual.html`)

- [ ] Add a "Sync rules and channels" section adjacent to the storage section (`Manual.html:982` area) covering: what channels are, the routing conditions, per-device subscriptions, the write-through behavior and its announcement, the mixed-fleet rule ("enable only after every device is updated; older devices keep syncing the main history"), channel deletion semantics, and the limitations from Section 2.12. Reuse existing terminology exactly: "Device", "entries attributed to one device", "server-side database bucket".
- [ ] Add changelog entries in the established voice (compare `Manual.html:250-251`).

### Task 7.2: Server manual (`ClipmanServer/Manual.html`)

- [ ] Update "what the server can see" (`:81-88`) and "Multiple Databases" (`:586-589`): clients using sync rules create additional buckets per channel under the same token; sizes and timing of those buckets are visible; contents are not. Note backup multiplication and that orphaned channel buckets can be pruned with the existing `--delete-database` / stale-bucket tooling.

### Task 7.3: README

- [ ] One sentence under "What Makes It Useful" describing machine-scoped sync rules, consistent with README's existing tone.

### Task 7.4: Rollout order

- [ ] Ship order: CLI + Linux backend (reference, easiest to validate), then Windows, then Mac, then iOS/Android app-store releases. The rules UI ships disabled-by-default everywhere; the manual and release notes carry the "update every device first" guidance. No server release is required; cut one anyway only if the manuals shipped inside the server bundle need the Task 7.2 text.

---

# Part 5: Verification summary

Commands that must all pass at the end (also the per-phase gates):

```
cd ClipmanCli && go build ./... && go vet ./... && go test ./...
cd ClipmanLinuxBackend && go build ./... && go vet ./... && go test ./...
powershell -File tests/Run-WindowsRegressionTests.ps1
cd ClipmanMac && swift test
cd ClipmanIOS && xcodebuild test (per ClipmanIOS/README.md scheme)
cd ClipmanAndroid && ./gradlew test
python ClipmanServerLinux/test_clipman_server.py   (unchanged; regression only)
```

Manual end-to-end scenario (run once after Phase 2 and once after Phase 5): local `clipman_server.py`; desktop with rules `{Images -> RichTextImages; Work -> group Work}`; phone subscribed to core only. Verify: (1) phone initial sync downloads only core + rules buckets (server access log); (2) desktop image capture PUTs only the images bucket; (3) phone paste uploads only core; (4) group reassignment desktop-side moves the entry between buckets and the phone view updates accordingly; (5) disabling rules returns both devices to single-bucket behavior; (6) an old-build client pointed at the same server still syncs core untouched.

# Part 6: Effort estimate

- Phase 0-1 (spec + Go reference, both trees): the largest single chunk; everything else is porting.
- Phases 2-5 are independent of each other once Phase 1 is green and can be parallelized across sessions.
- Phases 6-7 are small but gate the release.

# Part 7: Explicit non-goals

- No server code changes, no protocol v2, no per-entry delta sync.
- No per-device encryption keys or token scoping (single bearer token remains; revocation story unchanged).
- No mobile full channel-editing UI in v1 (view + this-device subscription only; editing is desktop/CLI).
- No changes to File History, Secrets, or settings sync - they stay machine-local.

# Part 8: Future work enabled by this design

- **Manifest bucket**: a tiny bucket listing per-channel revisions, updated after each channel PUT, collapsing polling to one HEAD regardless of channel count.
- **Pinned-everywhere channel**: an optional built-in route that mirrors pinned entries into a channel every device subscribes to, so pins survive aggressive subscriptions.
- **Lazy image channel**: subscribe to the images channel metadata-only (download on demand) - requires splitting image bytes from entries, a natural next step once images already live in their own channel.
- **Protocol v2 deltas**: if a real sequence number is ever added server-side, channels shrink the blobs that deltas would diff, so the two approaches compose.
