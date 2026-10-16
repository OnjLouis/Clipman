# Clipman Shared Vaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a person share a named, separately encrypted collection of clips
with other people, with per-person roles, out-of-band device verification, and
revocation that removes future access cryptographically rather than by
convention.

**Architecture:** A vault is a set of ordinary server buckets addressed through
the existing `HEAD/GET/PUT /api/v1/database/{id}` endpoint. Bucket ids are HMACs
under a random per-vault seed instead of the existing token-and-password
derivation, which is what decouples a vault from any one person's history
password. Content is a `ClipDatabase`-shaped payload inside an unmodified
`CLIPDB2` container whose password is a derived per-epoch key, so the existing
codec, merge, tombstone, and `If-Match` machinery is reused. Per-epoch content
keys are wrapped to each member device with ECDH P-256; revocation rotates the
epoch and re-wraps. The normative contract is `shared-vaults-spec.md`; this file
is the build order.

**Tech Stack:** Existing per-platform stacks: C#/.NET Framework WinForms
(Windows), Swift (macOS, iOS), Kotlin (Android), Go (CLI and Linux backend),
Python (Linux UI, server). No new dependencies on any platform.

## Global Constraints

- Phases 0 through 7 must not change `ClipmanServerLinux/clipman_server.py`. The
  feature must work against every deployed 2.x server, currently 2.6.4. Server
  work is isolated in Phase 8 and is additive.
- The `CLIPDB2` container format, PBKDF2 parameters (150,000 iterations,
  HMAC-SHA1), and AES-CBC + HMAC-SHA256 layout must not change. Vault blobs are
  ordinary containers whose password is `b64u(key)`.
- No new dependency on any platform. Asymmetric work uses ECDH and ECDSA on
  P-256, which every stack has natively; see `shared-vaults-spec.md` Section 4.1
  for why Curve25519 is not available here. HKDF is implemented directly from
  HMAC-SHA256 per RFC 5869, as PBKDF2 already is in
  `ClipmanCli/internal/clipdb/codec.go`.
- `ClipmanCli/internal/` is a fork of `ClipmanLinuxBackend/internal/`. Any change
  to codec, identity, merge, model, or sync engine MUST be applied to both trees
  in the same task (policy at `clipman-cli-spec.md:160-170`).
- Windows sources are compiled by `tests/Run-WindowsRegressionTests.ps1` with the
  legacy .NET Framework compiler
  `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, which supports
  **C# 5 only**. No string interpolation (`$"..."`), no null-conditional (`?.`),
  no `nameof`, no expression-bodied members, no auto-property initializers, no
  static using. Match the existing `src/` style exactly.
- `Build.ps1` references only framework assemblies. `ECDiffieHellmanCng` and
  `ECDsaCng` are in `System.Core.dll`, already referenced. Do not add an
  assembly reference and do not introduce a package manager.
- Private keys never leave the device that generated them. They are never placed
  in any synchronized database, never included in an export, and never
  transmitted. This is a hard rule; a task that appears to need otherwise is
  wrong.
- User-facing terminology: "Device" (never "machine"), matching `Manual.html`;
  on-disk fields keep their existing names.
- All UI work follows the accessibility rules in the repository owner's global
  config and Section 16 of the spec: accessible names on every control, keyboard
  access, meaningful screen-reader announcements, no colour-only signalling.
  Trust state is text, never a coloured dot.
- Plain ASCII in all user-visible strings; no emoji; no decorative Unicode.
- Feature is opt-in and off by default. A client with no vaults never derives a
  vault bucket id and never issues a vault request.
- Old clients cannot derive a vault bucket id, so mixed fleets are safe by
  construction. No compatibility shim is needed or permitted.
- Vault entries never enter Secrets and Secrets never enter a vault.

---

# Part 1: Current architecture (verified facts)

Everything below was read from the code in this repository. File references are
exact.

## 1.1 There is no asymmetric cryptography anywhere today

A search across `src`, `ClipmanIOS`, `ClipmanMac`, `ClipmanAndroid`,
`ClipmanCli`, and `ClipmanLinuxBackend` for `ECDiffieHellman`, `ECDsa`, `RSA`,
`X25519`, `Ed25519`, `P256`, and `secp256` returns nothing. Every existing
secret is symmetric and derives from the history password. Vaults introduce the
first keypairs in the product, which is why Phase 1 is a standalone identity
module with its own fixtures before any vault logic exists.

## 1.2 Bucket identity is password-scoped today

`ServerDatabaseIdentity` on every client derives the bucket from
`HMAC-SHA256(SHA-256(token), purpose + "\n" + password)`. Two people therefore
share a bucket only by sharing a password, which is exactly the property vaults
must not inherit. Vault ids keep the same HMAC shape and the same 43-character
base64url encoding, so they are valid ids on a 2.x server, but they are keyed on
a per-vault random seed instead.

Reference implementations to mirror: `ClipmanIOS/ClipmanIOS/Core/ServerDatabaseIdentity.swift`,
`src/ServerDatabaseIdentity.cs`, `ClipmanCli/internal/identity/identity.go`.

## 1.3 The container takes a password, not a key

`ClipmanCli/internal/clipdb/codec.go` shows the `CLIPDB2` layout:
`"CLIPDB2" || 0x01 || salt(16) || iv(16) || AES-256-CBC(PKCS7(gzip(json))) || HMAC-SHA256`,
with `PBKDF2-HMAC-SHA1(password, salt, 150000, 64)` split into a 32-byte
encryption key and a 32-byte MAC key. `EncodeRaw` and `DecodeRaw` already accept
an arbitrary JSON payload, added for the sync-rules document.

Consequence for vaults: passing `b64u(VCK)` as the password reuses this path
byte for byte. The PBKDF2 stage becomes redundant over a high-entropy input, but
`extractSalt` already keeps the salt stable across saves so the existing
derived-key caches make it a once-per-bucket cost. Reusing the container
unchanged is worth more than saving that derivation, and it means no client
gains a new symmetric code path.

## 1.4 Sync loop shape is identical on all six clients

`HEAD` for revision, `GET` on change, decode, merge, encode, `PUT` with
`If-Match`, handle 409 by re-fetching and merging. Vault sync is the same loop
against different buckets with a different key, which is why Phase 4 is small.

## 1.5 The sync-rules feature established the patterns to copy

`sync-rules-spec.md` plus the Phase structure of the sync work is the template:
Go first as the reference implementation with fixtures, then Windows, macOS,
iOS, Android, then a cross-client fixture corpus, then manuals. Vaults follow
the same order for the same reason: the Go trees have the fastest test loop and
produce the fixtures every other port validates against.

## 1.6 What the server does and does not enforce today

`clipman_server.py` authorizes on a single bearer token compared against
`AuthToken`, and any holder can read or write any bucket id. There is no notion
of a member. Confidentiality of vault content therefore does not depend on the
server at all, but availability does: on a 2.x server any member can overwrite
buckets they cannot read. Phase 8 is the answer, and until it ships the UI must
say so at invite time.

---

# Part 2: Design

The normative design is `shared-vaults-spec.md`. This part records only the
decisions a builder needs before reading it and the alternatives that were
rejected, so they are not re-litigated mid-implementation.

## 2.1 Why not reuse sync channels

Channel ids derive from the same token and password every device of one person
already shares (`sync-rules-spec.md` Section 2). Anyone who can sync at all can
compute every channel id, which is why the README calls channels an
organizational tool and not an access boundary. Sharing between different people
requires per-person keys; there is no version of channels that provides it.

## 2.2 Why per-device keypairs rather than per-person

A person's devices already share a history bucket, so a per-person key could
have ridden along in it. Per-device was chosen because a lost phone is the
common case: the roster shows every device, an unexpected device is the visible
symptom of compromise, and a device can be removed without the person losing
access from their remaining devices. It also keeps the hard rule in Global
Constraints simple, since no private key ever needs to sync.

## 2.3 Why epochs rather than deleting a member from a list

Removing a row from a roster is advisory: the removed member still holds the
content key and the server still holds the blob. An epoch rotation generates a
fresh content key, re-wraps it to the remaining devices only, and re-encrypts
content into a new bucket, so the removed member's key decrypts nothing new.
This is the difference between the feature being a security control and being a
label, and it is why Phase 6 gates release.

## 2.4 Why the manifest is signed and chained

A vault's roster lives on the server, so a malicious or rolled-back server could
serve an old roster to resurrect a revoked member. The manifest therefore
carries a monotonic `Sequence`, a `PrevHash` chain, and an ECDSA signature, and
clients persist a high-water mark outside the manifest. The signer is validated
against the previously trusted roster, never the roster being presented, or a
contributor could sign themselves into `admin`. See spec Section 7.4.

## 2.5 Rejected alternatives

- **Server-side ACL only, no client crypto.** Rejected: it would make the server
  operator able to read shared clips, which contradicts the product's existing
  promise that the server cannot decrypt history.
- **One shared vault password instead of keypairs.** Rejected: revocation would
  require every remaining member to retype a new password out of band, which is
  the failure mode people actually experience as "we stopped bothering".
- **Per-entry access control.** Rejected for v1: it multiplies key management by
  entry count for a case a second vault already solves.
- **Hiding vault existence from the server.** Rejected as out of scope; see spec
  Section 14 for what is and is not claimed.

## 2.6 Known limitations (document, do not solve now)

Carried verbatim from spec Section 18: revocation is forward-only, copy controls
are advisory, a writer can add unwanted entries, 2.x servers do not enforce
write access, device count leaks, total device loss loses that person's access,
and a forked manifest is reported rather than auto-merged.

---

# Part 3: File structure

New files:

| Path | Responsibility |
|---|---|
| `shared-vaults-spec.md` (repo root) | Normative cross-client spec: derivations, vectors, manifest schema, wrap format, roles, revocation. Source of truth for all ports. |
| `ClipmanLinuxBackend/internal/vaultid/vaultid.go` + `_test.go` | Vault bucket id derivations, fingerprint, safety digits, HKDF. |
| `ClipmanCli/internal/vaultid/vaultid.go` + `_test.go` | Byte-identical fork (per policy). |
| `ClipmanLinuxBackend/internal/vaultkeys/vaultkeys.go` + `_test.go` | Device keypairs, ECDH wrap and unwrap, entry signing and verification. |
| `ClipmanCli/internal/vaultkeys/vaultkeys.go` + `_test.go` | Fork. |
| `ClipmanLinuxBackend/internal/vault/manifest.go` + `_test.go` | Manifest envelope and body, chain and rollback validation, roster and policy model. |
| `ClipmanCli/internal/vault/manifest.go` + `_test.go` | Fork. |
| `ClipmanLinuxBackend/internal/syncengine/vaults.go` + `_test.go` | Vault sync loop, epoch switch, access-loss handling. |
| `ClipmanCli/internal/syncengine/vaults.go` + `_test.go` | Fork. |
| `src/VaultIdentity.cs` | C#: fingerprint, safety digits, HKDF, bucket id derivations. |
| `src/VaultKeys.cs` | C#: `ECDiffieHellmanCng` and `ECDsaCng` wrappers, wrap and unwrap, DPAPI-protected key storage. |
| `src/VaultManifest.cs` | C#: manifest DTOs, validation, chain rules. |
| `src/VaultsForm.cs` | Accessible vault list and detail dialog. |
| `src/VaultMembersForm.cs` | Accessible roster, invitation, verification, and revocation dialog. |
| `ClipmanMac/Sources/ClipmanCore/Vault*.swift`, `ClipmanIOS/ClipmanIOS/Core/Vault*.swift`, `ClipmanAndroid/.../Vault*.kt` | Per-platform ports of the same four modules. |
| `tests/fixtures/vaults/` | Cross-client fixture corpus: derivations, wraps, manifests, signature inputs. |

Modified files (primary): `ClipmanCli/internal/clipdb/codec.go` and fork (blob
padding helper only), `src/ClipStore.cs`, `src/Models.cs` (vault registry and
per-vault settings), `src/PreferencesForm.cs` and `src/HistoryForm.cs` (entry
points and entry actions), `src/SettingsStore.cs` (key storage path),
`ClipmanMac/Sources/Clipman/ClipStore.swift`,
`ClipmanIOS/ClipmanIOS/Core/MobileHistoryRepository.swift`,
`ClipmanAndroid/.../LocalHistoryStore.kt` and `MainActivity.kt`,
`ClipmanLinux/clipman.py` (vault dialog), `Manual.html`,
`ClipmanServer/Manual.html`, `clipman-cli-spec.md`, test files per platform.

Phase 8 only: `ClipmanServerLinux/clipman_server.py`,
`ClipmanServerLinux/test_clipman_server.py`,
`ClipmanServerLinux/install-clipman-server.sh`,
`ClipmanServer/clipman-server-settings.example.jsonc`.

---

# Part 4: Tasks

## Phase 0 - Specification

### Task 0.1: Write shared-vaults-spec.md

- [x] Normative derivations, manifest schema, wrap construction, roles,
      invitation flow, revocation, metadata analysis, accessibility
      requirements, and test vectors.
- [x] Every published vector independently recomputed and cross-checked against
      the existing `databaseId` vector in `sync-rules-spec.md`.

### Task 0.2: Review gate before any code

- [ ] Maintainer agrees the threat model and the two-layer split (client crypto
      for confidentiality, server for enforcement) is the shape they want.
- [ ] Maintainer confirms P-256 is acceptable given the .NET Framework
      constraint, or names a dependency they would accept instead.
- [ ] Decide whether Phase 8 ships in the same release or later.

Do not start Phase 1 before Task 0.2 closes. The whole point of a spec-first
change is that the expensive part is cheap to redirect while it is still prose.

## Phase 1 - Go reference implementation: identity and keys

Both trees in every task.

### Task 1.1: Vault id derivations

- [ ] `vaultid.go`: `ManifestID`, `ContentID(epoch)`, `InboxID(fpr)`,
      `WrapIndex(fpr, epoch)`, `ServerRef`, `InviteID(secret)`,
      `VaultRegistryID(token, password)`, all per spec Section 6.
- [ ] `HKDF` per RFC 5869 over `HMAC-SHA256`, with the RFC test vectors.
- [ ] `Fingerprint(sigPub, ecdhPub)` and `SafetyDigits(fpr)` per Section 5.
- [ ] Table test asserting every vector in spec Section 17, including the
      `databaseId` cross-check that proves the derivation convention matches.

### Task 1.2: Device keypairs and storage

- [ ] Generate P-256 signing and key-agreement keypairs via `crypto/ecdh` and
      `crypto/ecdsa`.
- [ ] Store private keys beside existing machine-scoped settings with the same
      permissions the settings already use; never in a synced path.
- [ ] Key rotation and deletion, so "forget this device" is implementable.

### Task 1.3: Wrap and unwrap

- [ ] `Wrap(vck, recipientEcdhPub, manifestID, epoch)` producing the exact
      161-byte layout in spec Section 7.3.
- [ ] `Unwrap` verifying the MAC before decrypting and rejecting on mismatch.
- [ ] Assert the Section 17 wrap vector byte for byte with the fixed ephemeral
      key and IV, then assert a fresh random round trip.
- [ ] Negative tests: truncated wrap, flipped ciphertext bit, wrong recipient,
      wrong epoch, wrong manifest id.

### Task 1.4: Entry signing

- [ ] Build the signature input of spec Section 8.3 by concatenation, never by
      serializing JSON.
- [ ] Sign and verify with ECDSA-P256-SHA256.
- [ ] Assert `SHA-256(signature input)` equals the Section 17 vector.
- [ ] Verification failure annotates the entry as unverified and never discards
      it.

## Phase 2 - Go reference implementation: manifest and sync

### Task 2.1: Manifest model and container

- [ ] Envelope and body DTOs per Section 7, body carried in `EncodeRaw` and
      `DecodeRaw` under `b64u(MK_e)`.
- [ ] Deterministic `Wraps` hashing with keys sorted by ordinal byte order.
- [ ] Sign and verify the Section 7.1 input.

### Task 2.2: Chain and rollback rules

- [ ] Persist the per-vault high-water mark outside the manifest.
- [ ] Enforce all five acceptance rules of Section 7.4.
- [ ] Tests for each rejection path individually: lower sequence, lower epoch,
      broken `PrevHash` at `n = last + 1`, signer absent from the previously
      trusted roster, and bad signature.
- [ ] Test the self-promotion attack explicitly: a contributor signs a manifest
      granting themselves `admin`, and it is rejected.

### Task 2.3: Vault sync engine

- [ ] Poll manifest, validate, decrypt body, recompute roster, policy, epoch.
- [ ] On epoch advance, unwrap the new key and switch content bucket.
- [ ] On missing wrap, mark `access-lost`, retain the local read-only cache,
      stop polling content.
- [ ] Content merge reuses the existing entry-level merge unchanged.
- [ ] Dirty detection with the database-level `UpdatedUnixMs` zeroed, matching
      the existing rule.
- [ ] `If-Match` and 409 retry.

### Task 2.4: Roles and write rules

- [ ] Enforce the Section 8.4 table client-side.
- [ ] Tombstone authorship rule, including the admin override.
- [ ] Test that a reader's write attempt is refused locally before any request.

## Phase 3 - Go reference implementation: membership lifecycle

### Task 3.1: Invitation

- [ ] Create offer, derive `InviteID`, encrypt under the invite-derived key.
- [ ] Claim by read-modify-write with `If-Match`, self-signature verified.
- [ ] Expiry, single-use, and revocation by deleting the bucket.
- [ ] Test that a code alone reveals neither `VIS` nor any content.

### Task 3.2: Admission

- [ ] Wrap the admission record to the claiming device's key with
      `info = "Clipman.VaultAdmission.v1"`.
- [ ] Pin the trusted signer set in the admission, and prove in a test that the
      joiner's first accepted manifest is validated against that pin.
- [ ] Roster and wrap added, sequence incremented, signed, uploaded.

### Task 3.3: Revocation

- [ ] The six-step ordering of Section 11, exactly.
- [ ] Test failure injection between each pair of steps and assert the stated
      invariant: never point members at a nonexistent epoch, never empty the
      vault, always retryable.
- [ ] Test that a revoked device's wrap is absent at the new epoch and that its
      old key decrypts nothing in the new content bucket.

### Task 3.4: CLI surface

- [ ] `clipman-cli vault list|show|create|join|leave`.
- [ ] `clipman-cli vault member list|invite|approve|role|revoke`.
- [ ] `clipman-cli vault verify <fpr>` printing safety digits.
- [ ] JSON output mode for every command, matching existing CLI conventions.
- [ ] Update `clipman-cli-spec.md`.

## Phase 4 - Windows client

C# 5 only. `ECDiffieHellmanCng` and `ECDsaCng` from `System.Core.dll`.

### Task 4.1: `src/VaultIdentity.cs` and `src/VaultKeys.cs`

- [ ] Port Phase 1 and validate against the fixture corpus.
- [ ] Private keys protected with DPAPI scoped to the current user.
- [ ] Verify `Build.ps1` still compiles with no reference changes.

### Task 4.2: `src/VaultManifest.cs` and storage integration

- [ ] Port Phase 2, including the high-water mark in `SettingsStore`.
- [ ] `ClipStore` gains vault-scoped read and write paths kept fully separate
      from personal history and from Secrets.

### Task 4.3: Windows UI

- [ ] `VaultsForm`: vault list with name, role, member count, enforcement level,
      and access state, each in the accessible name.
- [ ] `VaultMembersForm`: roster as a real list with devices as an expandable
      level; invite, approve with safety digits shown, set role, verify, revoke.
- [ ] Entry actions: Add to vault, Move to vault, Copy from vault, Save to
      personal history gated by `AllowCopyOut`.
- [ ] Every destructive confirmation states its consequence before the
      affirmative button, including that revocation does not retract past
      access.
- [ ] Keyboard-complete, no hover-only affordance, no colour-only state.

## Phase 5 - macOS client

### Task 5.1: Port the four modules to `ClipmanMac/Sources/ClipmanCore`

- [ ] CryptoKit `P256.KeyAgreement` and `P256.Signing`; keys in the Keychain
      with device-only accessibility.
- [ ] Validate against the fixture corpus.

### Task 5.2: macOS UI

- [ ] Vault list, roster, invitation, verification, revocation, entry actions.
- [ ] VoiceOver announcements for epoch rotation and access loss through the
      existing status region.

## Phase 6 - iOS client

### Task 6.1: Port to `ClipmanIOS/ClipmanIOS/Core`

- [ ] Same modules; Keychain with device-only accessibility; no key in the app
      group container.
- [ ] Share-sheet additions must never target a vault implicitly.

### Task 6.2: iOS UI

- [ ] Vault list, roster, invitation, verification, revocation, entry actions.
- [ ] Safety digits with a "read digits" action that spells one group at a time.

## Phase 7 - Android client

### Task 7.1: Port to `ClipmanAndroid/.../`

- [ ] JCA `ECDH` and `SHA256withECDSA`; keys in the Android Keystore.
- [ ] Validate against the fixture corpus.

### Task 7.2: Android UI

- [ ] Vault list, roster, invitation, verification, revocation, entry actions.
- [ ] TalkBack named actions matching the existing history conventions.

## Phase 8 - Vault-aware server (optional, separate release)

Additive only. A client must keep working against a 2.x server.

### Task 8.1: Membership tokens

- [ ] `Members` and `Vaults` in settings, tokens stored only as
      `SHA-256(token)`.
- [ ] Authorize member tokens against the granted vault's registered buckets;
      `read` permits `HEAD` and `GET` only.
- [ ] Return the existing 401 for every failure so the API is not a bucket
      oracle. Test this explicitly.

### Task 8.2: Vault registration endpoint

- [ ] `PUT` and `GET /api/v1/vault/{serverRef}`, owner token only.
- [ ] Per-token rate limiting and a per-vault bucket quota.

### Task 8.3: Server tooling and docs

- [ ] `clipmanserver vault list|show`, `member add|list|revoke|token-rotate`.
- [ ] `ClipmanServer/Manual.html` and the settings example.
- [ ] Bump the server version and note that clients without vaults are
      unaffected.

## Phase 9 - Cross-client fixtures and manuals

### Task 9.1: Fixture corpus

- [ ] `tests/fixtures/vaults/`: derivations, a wrap with fixed ephemeral key and
      IV, a signed manifest chain including a rejected rollback, and signature
      inputs.
- [ ] Every client's test suite consumes the corpus. A port is not done until it
      passes it.

### Task 9.2: Manuals

- [ ] `Manual.html`: vaults, roles, verification, invitation, revocation, and an
      explicit statement that revocation is forward-only and copy controls are
      advisory.
- [ ] `README.md`: one paragraph under storage choices.
- [ ] `ClipmanServer/Manual.html`: Phase 8 only.

### Task 9.3: Rollout order

- [ ] Ship no client before Phase 3 is complete on that client. A vault that can
      add members but not cryptographically remove them teaches a security model
      the software does not implement.
- [ ] Release clients before the vault-aware server, since clients degrade
      safely and the server is an enforcement upgrade.
- [ ] Guidance for users: create a vault only once every device you intend to
      share with runs a version that supports vaults.
