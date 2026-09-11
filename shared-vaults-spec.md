# Clipman Shared Vaults Specification

This document is normative for every Clipman client that implements shared
vaults. All clients on all platforms must implement exactly these derivations,
formats, and algorithms so that the same buckets, keys, and access decisions are
produced everywhere. Companion documents: `sync-rules-spec.md` defines sync
channels, and `clipman-cli-spec.md` defines the command-line client.

A **shared vault** is a named, separately encrypted collection of clipboard
entries that several people can read, with per-person permissions, cryptographic
revocation, and no plaintext exposure to the server.

**Status: proposed. Nothing in this document is implemented or released.** No
Clipman client ships vault support today, and no server release implements
Section 13. Where this document says "a vault-aware server", it means a future
server that would add the access-control layer specified here; it is not a
version you can install. The current releases are Clipman 3.0 on the client side
and Clipman Server 2.6.4 on the server side, which version independently of each
other. Everything except Section 13 is designed to work against a 2.6 server
unchanged.

Shared vaults are not sync channels. Channels partition one person's history
across their own devices and are explicitly not an access boundary, because
every channel id derives from the one token and history password that person's
devices already share. Vaults exist to be an access boundary between different
people, which requires per-person keys, and that is the whole substance of this
document.

## Binding constraints

- The `CLIPDB2` container format, its PBKDF2 parameters (150,000 iterations,
  HMAC-SHA1), and its AES-256-CBC plus HMAC-SHA256 layout must not change. Vault
  blobs are ordinary `CLIPDB2` containers whose password is a derived key, so
  every existing encode and decode path is reused verbatim.
- Vault content is a `ClipDatabase`-shaped payload, so the existing merge,
  tombstone, revision, and `If-Match` machinery is reused without a parallel
  sync engine.
- The data path on the server does not change. Vault buckets are ordinary
  buckets reached with `HEAD`, `GET`, and `PUT /api/v1/database/{id}`, and every
  derived id is 43 characters of base64url, which is already a valid database id
  on every deployed 2.x server.
- A vault-aware server adds membership tokens and per-vault access control.
  That layer is required for enforcement against untrusted members and is
  specified in Section 13. Confidentiality never depends on it. No such server
  release exists today; it is proposed by this document.
- Only primitives available natively on all six client stacks may be used.
  Section 4 records what that rules out and why.
- The feature is opt-in and off by default. A client with no vaults behaves
  exactly as a client without the feature, and never reads or writes a vault
  bucket.
- Old clients must never be harmed: they cannot derive a vault bucket id, so
  they cannot touch one. Compatibility is by construction, not by convention.
- `ClipmanCli/internal/` and `ClipmanLinuxBackend/internal/` are forks; shared
  logic changes land in both trees in the same change.

## 1. Concepts

- A **vault** is a named collection of entries with its own key hierarchy, its
  own buckets, and its own membership roster. A person's personal history is
  never a vault and is never reachable from one.
- A **device** is the unit of cryptographic identity. Each device generates its
  own P-256 signing keypair and P-256 key-agreement keypair, and the private
  halves never leave that device, never sync, and are never escrowed.
- A **person** is a named grouping of devices in the roster. Roles are granted
  to a person; key material is wrapped to each of that person's devices.
- The **fingerprint** identifies a device. It is displayed as safety digits for
  out-of-band verification (Section 5).
- An **epoch** is a generation of the vault's content key. Every revocation
  advances the epoch, which is what makes revocation cryptographic rather than
  advisory (Section 11).
- The **manifest** is the vault's control document: epoch, roster, roles,
  policy, wrapped keys, and the audit log. It is signed, chained, and
  rollback-resistant (Section 7).
- The **content bucket** for an epoch holds the entries themselves, encrypted
  under that epoch's content key (Section 8).

### 1.1 What a vault protects, and what it does not

State this plainly in the user interface, not only in this document.

A vault controls **who can obtain an entry from the server**. It cannot control
what a person does with an entry they were entitled to read. Anyone who could
read an entry can remember it, screenshot it, or write it down. Revocation is
therefore forward-only: it removes future access, never past knowledge.

Copy controls (Section 12) are a courtesy that helps a cooperating client avoid
accidental leakage. They are not a control, they are not represented as one
anywhere in the interface, and a modified client can ignore them.

## 2. Threat model

Adversaries the design defends against:

| Adversary | Defended | Mechanism |
| --- | --- | --- |
| The server operator, or anyone who steals the server's disk | Yes, for content | Content and roster are encrypted client-side; the server holds opaque blobs and opaque bucket ids |
| A malicious server serving stale control data | Yes | Signed manifest chain with monotonic sequence and client-persisted high-water mark (Section 7.4) |
| A revoked member, for content added after revocation | Yes | Epoch rotation and re-wrap (Section 11) |
| A revoked member, for content they already read | No, and it is not claimable | Stated as a limitation in the interface |
| A revoked member vandalizing or deleting buckets | Yes, with a vault-aware server | Membership token revocation and per-vault access control (Section 13) |
| A current member forging another member's authorship | Yes | Per-entry ECDSA signature over a fixed input (Section 8.3) |
| A current member deleting another member's entries | Yes, by client rule | Tombstone authorship rule (Section 8.4); admins may override |
| A network observer | Yes, for content | HTTPS is mandatory for any non-loopback deployment, as today |
| The server correlating vaults, members, and personal histories | Partially | Section 14 states exactly what leaks and what does not |

Explicit non-goals: the design does not attempt post-compromise security for a
device whose private keys were exfiltrated without the owner noticing, beyond
the epoch rotation an admin performs once the compromise is known. It does not
attempt deniability. It does not attempt to hide the existence of vault activity
from the server operator, only its content and its participants.

## 3. Storage layout

Every vault object is an ordinary server bucket.

| Object | Bucket id | Encrypted under | Written by |
| --- | --- | --- | --- |
| Manifest | `manifestId` | Manifest key `MK_e` | Owner and admins |
| Content for epoch `e` | `contentId(e)` | Content key `VCK_e` | Any contributor |
| Member inbox | `inboxId(fpr)` | That device's key-agreement key | Admins, at admission |
| Invitation rendezvous | `inviteId` | Key derived from the invite secret | Inviter and invitee |
| Personal vault registry | `vaultRegistryId` | The person's own history password | That person's devices |

The personal vault registry is how a person's own devices learn which vaults
exist and what their seeds are. It lives in the person's existing token and
password space, so it synchronizes across their devices through the mechanism
they already have, and it is unreadable to anyone else including other vault
members.

## 4. Cryptographic primitives

| Purpose | Primitive |
| --- | --- |
| Key agreement | ECDH on NIST P-256 |
| Signatures | ECDSA on NIST P-256 with SHA-256 |
| Key derivation | HKDF-SHA256 (RFC 5869) |
| Symmetric encryption | AES-256-CBC with PKCS#7 padding |
| Authentication | HMAC-SHA256, encrypt-then-MAC |
| Bucket id derivation | HMAC-SHA256, base64url without padding |
| Hashing | SHA-256 |

### 4.1 Why P-256 and not Curve25519

The Windows client is compiled by invoking `csc.exe` from
`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` directly against a fixed list of
framework assemblies (`Build.ps1`). There is no project file, no package
manager, and no third-party dependency anywhere in the build. Introducing one
would also enlarge the reproducible-build surface that the SignPath signing
process depends on, described in `CODE_SIGNING_POLICY.md`.

.NET Framework 4.x offers no X25519 and no Ed25519. It does offer
`ECDiffieHellmanCng` and `ECDsaCng` on P-256, both in `System.Core.dll`, which
is already referenced. The same curve is available natively as
`P256.KeyAgreement` and `P256.Signing` in Apple CryptoKit, through the standard
JCA providers on Android, and in `crypto/ecdh` and `crypto/ecdsa` in Go.

P-256 is therefore the only asymmetric choice that every client can implement
today with zero new dependencies. AES-256-CBC with encrypt-then-MAC is chosen
for the same reason: it is exactly what `CLIPDB2` already does, so no client
gains a new symmetric code path, and `AesGcm` does not exist in .NET
Framework 4.x.

HKDF has no class in .NET Framework 4.x, but it is a short construction over
`HMACSHA256`. Clients implement RFC 5869 directly, as the Go client already
implements PBKDF2 directly in `ClipmanCli/internal/clipdb/codec.go`.

### 4.2 Encoding conventions

- `b64u(x)` is RFC 4648 base64url of `x` with padding stripped, matching the
  existing database id encoding.
- `b64(x)` is standard base64 with padding, used for binary fields inside JSON.
- Public keys are X9.62 uncompressed points, 65 bytes, first byte `0x04`.
- All strings are UTF-8. All integers in derivation inputs are decimal ASCII
  with no leading zeros and no sign.
- All inputs are trimmed of leading and trailing whitespace before derivation,
  matching the existing database id derivation.

## 5. Device identity

Each device generates, on first vault use, two P-256 keypairs: a signing
keypair `(sigPriv, sigPub)` and a key-agreement keypair `(ecdhPriv, ecdhPub)`.
Private keys are stored in the platform keystore where one exists (Windows DPAPI
scoped to the user, Apple Keychain with device-only accessibility, Android
Keystore), and otherwise beside the existing machine-scoped settings with the
same file permissions the settings already use. They are never written to any
synchronized database, never included in any export, and never transmitted.

The fingerprint is:

```
fingerprint = SHA-256(UTF8("Clipman.DeviceFingerprint.v1\n") || sigPub || ecdhPub)
```

`fpr` denotes `b64u(fingerprint)` wherever it appears in a derivation input.

### 5.1 Safety digits

Verification is presented as **safety digits**: the first 16 bytes of the
fingerprint, taken as eight big-endian 16-bit integers, each rendered as exactly
five decimal digits with leading zeros, joined by single spaces.

```
46947 05216 00880 26750 07710 14115 61928 21148
```

Decimal digit groups are chosen over hexadecimal, colour swatches, or QR codes
alone because they are read aloud correctly and unambiguously by every screen
reader on every supported platform, and because two people can compare them over
a phone call. A QR code may be offered in addition, never instead.

Verification is a first-class, reversible state on each device in the roster:
`unverified`, `verified`, or `changed`. A fingerprint that changes after
verification moves to `changed`, and clients must surface that as a warning that
requires an explicit decision, in text, never by colour alone.

## 6. Key hierarchy and bucket identity

A vault is created with a random 256-bit **vault id seed** `VIS` from a
cryptographic random source. `VIS` is the capability to locate a vault's
buckets. It is distributed only inside admission records encrypted to an
approved device (Section 9), and is held in each member's personal vault
registry.

```
manifestId        = b64u(HMAC-SHA256(VIS, UTF8("Clipman.VaultManifest.v1")))
contentId(e)      = b64u(HMAC-SHA256(VIS, UTF8("Clipman.VaultContent.v1\n"   + e)))
inboxId(fpr)      = b64u(HMAC-SHA256(VIS, UTF8("Clipman.VaultInbox.v1\n"     + fpr)))
wrapIndex(fpr, e) = b64u(HMAC-SHA256(VIS, UTF8("Clipman.VaultWrapIndex.v1\n" + fpr + "\n" + e)))
serverRef         = b64u(HMAC-SHA256(VIS, UTF8("Clipman.VaultServerRef.v1")))
inviteId          = b64u(HMAC-SHA256(inviteSecret, UTF8("Clipman.VaultInvite.v1")))
```

The personal vault registry uses the existing token and password derivation
style, so it behaves like every other bucket a person's own devices share:

```
key             = SHA-256(UTF8(trim(token)))
vaultRegistryId = b64u(HMAC-SHA256(key, UTF8("Clipman.VaultRegistry.v1\n" + password)))
```

Each epoch `e` has a random 256-bit content key `VCK_e`. The manifest key is
derived from it so that a leaked content key does not directly expose the roster
and audit log:

```
MK_e = HKDF-SHA256(ikm = VCK_e,
                   salt = UTF8(manifestId),
                   info = UTF8("Clipman.VaultManifestKey.v1"),
                   length = 32)
```

Content blobs are `CLIPDB2` containers whose password is `b64u(VCK_e)`. Manifest
bodies are `CLIPDB2` containers whose password is `b64u(MK_e)`. Both are
43-character high-entropy strings, so the container's PBKDF2 stage is redundant
but harmless, and the existing derived-key cache keyed by salt makes it a
once-per-bucket cost exactly as it is today. Reusing the container unchanged is
worth more than saving that derivation.

Salt sharing: a vault blob created for the first time copies the salt of the
vault's manifest blob, matching the salt-sharing rule channels already use.

## 7. The manifest

The manifest is a single bucket holding a JSON document with a cleartext
envelope and an encrypted body.

```json
{
  "Clipman": "vault-manifest",
  "Version": 1,
  "Epoch": 3,
  "Sequence": 17,
  "PrevHash": "wF3n...",
  "Wraps": {
    "2x8qlJwm-rTE_DwZ7eybfvRgFLl4kiWMy1vmr5oCkwI": "BFGnWAgz...",
    "gxYdqS7mh7IaYPR43qmcGppkA4F0xbDiNrQ0ix2hm0U": "BKm2Vd91..."
  },
  "Body": "Q0xJUERCMgE...",
  "SignerFpr": "t2MUYANwaH4eHjcj8ehSnKwEdD3Bg6F77maICwnVOzI",
  "Signature": "MEUCIQD..."
}
```

### 7.1 Envelope

- `Epoch` is the current epoch. It never decreases.
- `Sequence` increments by one on every manifest write, including writes that do
  not change the epoch.
- `PrevHash` is `b64(SHA-256(canonical bytes of the previous manifest))`, where
  the canonical bytes are the exact octets the previous manifest was uploaded
  as. The first manifest of a vault uses 32 zero bytes.
- `Wraps` maps `wrapIndex(fpr, Epoch)` to the base64 of that device's wrapped
  copy of `VCK_Epoch` (Section 7.3). The index is keyed on `VIS`, so the server
  sees per-epoch opaque labels that it cannot link to a device or across
  epochs. It still learns how many devices are in the vault; Section 14 covers
  the padding option that blunts this.
- `Body` is the base64 of a `CLIPDB2` container encrypted under `MK_Epoch`.
- `SignerFpr` and `Signature` are the signing device's fingerprint and its
  ECDSA-P256-SHA256 signature over:

```
UTF8("Clipman.VaultManifest.v1\n" + manifestId + "\n" + Epoch + "\n" + Sequence
     + "\n" + PrevHash + "\n") || SHA-256(canonical JSON bytes of Wraps) || SHA-256(Body bytes)
```

The `Wraps` hash is taken over the map serialized with keys sorted by ordinal
byte order and no insignificant whitespace, which is fully determined and needs
no general JSON canonicalization library.

### 7.2 Body

```json
{
  "Clipman": "vault-manifest-body",
  "Version": 1,
  "Name": "Family",
  "CreatedUnixMs": 1757200000000,
  "UpdatedUnixMs": 1757900000000,
  "Policy": {
    "AllowCopyOut": true,
    "RequireVerifiedDevices": false,
    "DeviceSelfEnrollment": "person-approves",
    "EntryExpiryDays": 0,
    "MaxEntries": 5000,
    "AuditVisibleToMembers": true,
    "PadBlobsToKiB": 4
  },
  "People": [
    {
      "PersonId": "p-7f3a",
      "Name": "Jeff",
      "Role": "owner",
      "AddedUnixMs": 1757200000000,
      "Devices": [
        { "Fpr": "t2MUYANw...", "Label": "Desktop", "SigPub": "BAIX5hfw...",
          "EcdhPub": "BNZak5d8...", "AddedUnixMs": 1757200000000,
          "SponsorFpr": "", "LastSeenUnixMs": 1757899000000 }
      ]
    },
    {
      "PersonId": "p-91c2",
      "Name": "Sam",
      "Role": "contributor",
      "AddedUnixMs": 1757300000000,
      "Devices": [ { "Fpr": "9dQ1...", "Label": "Sam iPhone", "SigPub": "...", "EcdhPub": "...",
                     "AddedUnixMs": 1757300000000, "SponsorFpr": "", "LastSeenUnixMs": 1757890000000 } ]
    }
  ],
  "Recovery": { "Enabled": true, "Fpr": "R7xk...", "EcdhPub": "BC91..." },
  "Audit": [
    { "Seq": 16, "UnixMs": 1757880000000, "Actor": "t2MUYANw...", "Action": "member-added",
      "Subject": "p-91c2", "Detail": "contributor" },
    { "Seq": 17, "UnixMs": 1757900000000, "Actor": "t2MUYANw...", "Action": "epoch-rotated",
      "Subject": "", "Detail": "3" }
  ]
}
```

`PersonId` is a random short opaque string minted at admission. It never
contains a name, an email address, or anything derived from one.

### 7.3 Wrapping the content key to a device

Given the recipient device's `ecdhPub` and the current `Epoch`:

1. Generate an ephemeral P-256 keypair `(ephPriv, ephPub)`.
2. `Z = ECDH-P256(ephPriv, ecdhPub)`, the 32-byte X coordinate.
3. `salt = SHA-256(UTF8("Clipman.VaultWrapSalt.v1\n" + manifestId + "\n" + Epoch))`
4. `okm = HKDF-SHA256(ikm = Z || ephPub || ecdhPub, salt, info = UTF8("Clipman.VaultWrap.v1"), length = 64)`
5. `wrapEnc = okm[0:32]`, `wrapMac = okm[32:64]`
6. `body = ephPub || iv || AES-256-CBC(wrapEnc, iv, PKCS7(VCK_Epoch))` with a
   fresh random 16-byte `iv`
7. `wrap = body || HMAC-SHA256(wrapMac, body)`

The wrap is exactly 161 bytes: 65 for `ephPub`, 16 for `iv`, 48 for the padded
32-byte key, and 32 for the tag. Binding both public keys into the HKDF input
ties the wrap to this exact pair of parties.

Unwrapping verifies the MAC before decrypting, and rejects the wrap on
mismatch. A device whose `wrapIndex` is absent from `Wraps` is not a member of
that epoch; the client reports "you no longer have access to this vault" and
stops polling the content bucket.

### 7.4 Trust, signing, and rollback resistance

A manifest at `Sequence = n` is accepted only if every one of the following
holds:

1. `n` is greater than or equal to the highest sequence this client has ever
   accepted for this vault, persisted locally outside the manifest. A lower
   sequence is a rollback attempt and is rejected without merging.
2. `Epoch` is greater than or equal to the highest epoch this client has ever
   accepted.
3. `PrevHash` matches the manifest the client last accepted, when the client has
   one and `n` is exactly one greater. A gap is permitted, because a client can
   be offline across several writes, but a mismatch at `n = last + 1` is a fork
   and is surfaced to the user rather than silently resolved.
4. `SignerFpr` belongs to a device whose person held `owner` or `admin` in the
   manifest the client already trusted. The very first manifest a client trusts
   is pinned by its admission record (Section 9), which was encrypted to that
   device by a fingerprint the joining person was shown and asked to verify.
5. The signature verifies over the input in Section 7.1.

Rule 1 is what prevents a malicious or rolled-back server from resurrecting a
revoked member by serving an older roster. Rule 4 is what prevents a
contributor from promoting themselves: a manifest asserts its own roster, so the
signer is always checked against the **previously trusted** roster, never the
one being presented.

Concurrent manifest writes use the existing `If-Match` flow. On a 409 the client
re-fetches, re-validates by these rules, re-applies its intended change on top,
and retries. Manifest edits are rare and admin-initiated, so no automatic merge
of divergent rosters is attempted: a genuine fork is reported for a human to
resolve.

## 8. Vault content

### 8.1 Container

`contentId(e)` holds a `CLIPDB2` container, password `b64u(VCK_e)`, whose
plaintext payload is a `ClipDatabase` document with the same shape the history
database and channel databases already use. All existing entry merge, tombstone,
text-hash, and manual-order logic applies unchanged within a content bucket.

### 8.2 Additional entry fields

Vault entries carry three optional fields beyond the existing `ClipEntry`
schema. They are optional so that an implementation which has not yet added them
still parses the document.

| Field | Meaning |
| --- | --- |
| `AddedByFpr` | Fingerprint of the device that created the entry |
| `Sig` | Base64 ECDSA-P256-SHA256 signature over the input in Section 8.3 |
| `ExpiresUnixMs` | Optional client-enforced expiry; `0` or absent means none |

`SourceMachine` continues to carry the human-readable device name for display
and for the existing device filter. `AddedByFpr` is the cryptographic
attribution and is the only one that may be trusted.

### 8.3 Entry signature input

Signatures are computed over a fixed concatenation, never over serialized JSON.
This follows the same reasoning that led `sync-rules-spec.md` to reject non-ASCII
channel names: no client should need a JSON canonicalization or Unicode
normalization library to agree with the others.

```
"Clipman.VaultEntry.v1\n" + Id + "\n" + CreatedUnixMs + "\n" + ModifiedUnixMs
  + "\n" + lowerHex(SHA-256(UTF8(Text))) + "\n" + AddedByFpr + "\n" + manifestId + "\n" + Epoch
```

For a rich-text entry, `Text` is the plain-text projection already stored in
`Text`, and the HTML fragment is covered by including
`lowerHex(SHA-256(UTF8(HtmlFragment)))` as a ninth line when `RichText` is
present. Including `manifestId` and `Epoch` prevents a signed entry from being
replayed into a different vault or a different epoch.

Verification failures never discard data. An entry whose signature is absent,
malformed, or made by a fingerprint not in the roster is displayed with its
attribution replaced by "unverified origin" and is excluded from any interface
that asserts who added something. Discarding would let a malicious server delete
entries by corrupting one field.

### 8.4 Write rules enforced by clients

| Role | May do |
| --- | --- |
| `reader` | Read. No writes to the content bucket at all. |
| `contributor` | Read; add entries; edit and delete entries whose `AddedByFpr` is one of their own devices. |
| `admin` | Everything a contributor may do, plus edit and delete any entry, invite, revoke, change roles below owner, rotate the epoch, and change policy. |
| `owner` | Everything an admin may do, plus transfer ownership, delete the vault, and manage the recovery credential. |

A tombstone is honoured only when its `SourceMachine` device is an admin or
owner, or when the tombstone is signed by a device that also holds
`AddedByFpr` on the entry being deleted. Tombstones failing this rule are
ignored and the entry is restored on the next upload by any client that notices.
On a 2.x server these rules are client-enforced only; Section 13 explains what
a vault-aware server adds.

## 9. Joining a vault

The invitation flow never puts the vault key or `VIS` into the invitation code,
never requires the inviter to have the invitee's key in advance, and always
requires an explicit human approval step with a fingerprint shown.

### 9.1 The code

An admin creates a random 256-bit `inviteSecret` and writes an **offer** to
`inviteId`. The offer is a `CLIPDB2` container whose password is
`b64u(HKDF-SHA256(inviteSecret, salt = UTF8(inviteId), info = UTF8("Clipman.VaultInviteOffer.v1"), 32))`
and whose payload is:

```json
{
  "Clipman": "vault-invite",
  "Version": 1,
  "VaultName": "Family",
  "InviterFpr": "t2MUYANw...",
  "InviterName": "Jeff",
  "ExpiresUnixMs": 1757990000000,
  "Server": "https://lp.example/clipman/",
  "EnrollToken": "..."
}
```

The invitation code handed to the invitee carries only the server address and
`b64u(inviteSecret)`. It does not carry `VIS`, so intercepting a code does not
reveal the vault's buckets, and it does not carry the vault key, so intercepting
a code does not reveal any content. `EnrollToken` is a vault-aware-server token scoped
to `inviteId` alone and to a short lifetime; on a 2.x server this field is
absent and the shared server token is used, with the consequences in
Section 13.3.

Invitations expire, are single-use, and are revoked by deleting `inviteId`,
which an admin can do at any time before acceptance.

### 9.2 Claim and approval

1. The invitee enters the code, derives `inviteId`, fetches and decrypts the
   offer, and is shown the vault name, the inviter's name, and the inviter's
   safety digits.
2. The invitee's device adds a **claim**: it re-encodes the offer document with
   its claim appended to a `Claims` array and `PUT`s it back to `inviteId` with
   `If-Match`, under the same invite key, so the payload stays encrypted and a
   concurrent write is detected rather than lost. A claim carries its `sigPub`,
   `ecdhPub`, fingerprint, a device label, a proposed person name, and a
   self-signature over `"Clipman.VaultClaim.v1\n" + inviteId + "\n" + fpr`. An
   offer that already holds a claim for a different fingerprint is rejected by
   the admin unless the invitation was explicitly created as multi-use.
3. An admin device polls `inviteId`, verifies the self-signature, and shows the
   claiming device's safety digits alongside the label and proposed name. The
   admin confirms out of band, by phone or in person, and chooses a role.
4. On approval the admin writes an **admission record** to `inboxId(fpr)`,
   encrypted to the invitee's `ecdhPub` with the Section 7.3 wrap construction
   and `info = UTF8("Clipman.VaultAdmission.v1")`. The record contains `VIS`,
   the current `Epoch`, the member token where a vault-aware server is in use, and the
   pinned trusted signer set, meaning the fingerprints and public keys of the
   current owner and admins.
5. The admin adds the person and device to the manifest roster, adds their
   `wrapIndex` and wrap, increments `Sequence`, signs, and uploads. The admin
   then deletes `inviteId`.
6. The invitee polls `inboxId(fpr)`, decrypts the admission, pins the trusted
   signers, stores `VIS` in their personal vault registry, and performs a first
   sync.

The invitee never learns `VIS` until an admin has approved a specific device
fingerprint, and the admin never wraps a key to a device whose fingerprint they
have not seen. If policy sets `RequireVerifiedDevices`, the admin client refuses
to complete step 4 until the fingerprint has been explicitly marked verified.

### 9.3 Adding another of your own devices

Any device already holding `VCK_e` can wrap it to another device, so a person
adding their second device does not inherently need an admin. Policy governs
which is required:

- `DeviceSelfEnrollment: "person-approves"`: an existing device of the same
  person may add a new device of that person. It writes the new device into its
  own person record, signs the roster change with its own signing key, and adds
  the wrap. The audit entry records the sponsoring fingerprint in `SponsorFpr`.
- `DeviceSelfEnrollment: "owner-approves"`: only an owner or admin may add any
  device. Self-sponsored roster changes are rejected by rule 4 of Section 7.4.

Clients must show every device of every person in the roster, with its label,
sponsor, and last-seen time, because an unexpected device is the visible symptom
of a compromised member.

## 10. Permissions

Roles are `owner`, `admin`, `contributor`, and `reader`, defined in
Section 8.4. Exactly one person holds `owner`.

Role changes are manifest edits and follow Section 7.4. Demoting a person from
`admin` does not by itself require an epoch rotation, because an admin has no
key material a contributor lacks. Removing a person entirely always requires
one.

Policy flags in the manifest body:

| Flag | Effect |
| --- | --- |
| `AllowCopyOut` | When false, cooperating clients omit the actions that move a vault entry into personal history or an exported file. Advisory; see Section 12. |
| `RequireVerifiedDevices` | Admin clients refuse to wrap a key to a device whose fingerprint has not been marked verified. |
| `DeviceSelfEnrollment` | `person-approves` or `owner-approves`, per Section 9.3. |
| `EntryExpiryDays` | Non-zero means clients hide and then prune entries older than this. |
| `MaxEntries` | Retention cap evaluated within the vault only, never against personal history. |
| `AuditVisibleToMembers` | When false, only owner and admins render the audit log. The log is still present in the body, so this is a presentation choice and must not be described as concealment. |
| `PadBlobsToKiB` | Pad content blobs up to a multiple of this many kibibytes; see Section 14. |

## 11. Revocation

Removing a person from a vault is one atomic admin operation:

1. Generate `VCK_{e+1}` from a cryptographic random source.
2. Fetch and decrypt the current content at `contentId(e)`.
3. Re-encrypt it under `VCK_{e+1}` and upload to `contentId(e+1)`.
4. Build the new manifest at `Epoch = e+1` and `Sequence = n+1`: remove the
   person and all their devices from the roster, compute `wrapIndex(fpr, e+1)`
   and a fresh wrap for every remaining device, derive `MK_{e+1}`, re-encrypt
   the body, append the audit entry, sign, and upload with `If-Match`.
5. On a vault-aware server, revoke that person's membership token and register
   `contentId(e+1)` to the vault reference, so the removed person loses write
   access to every bucket in the same operation.
6. Delete `contentId(e)` and, when a vault-aware server is in use, its access grants.

Ordering matters. Step 3 precedes step 4 so that no member is ever pointed at an
epoch whose content does not yet exist. Step 6 follows the manifest write so
that a failure between them leaves the old content readable by current members
rather than leaving the vault empty. A failure anywhere before step 4 leaves the
vault entirely on epoch `e` and is retried; a partially written `contentId(e+1)`
is simply overwritten.

Remaining members notice the epoch change on their next manifest poll, unwrap
`VCK_{e+1}`, and switch buckets. A member offline across two rotations still
finds a wrap for the current epoch, because wraps are rebuilt for every
remaining device on every rotation.

Other operations that must rotate the epoch: a device removed for loss or theft,
a fingerprint transitioning to `changed`, a recovery credential being used or
retired, and any explicit "rotate keys now" action, which clients must offer
unconditionally.

The interface must state, at the moment of revocation, that the person keeps
whatever they have already read. Presenting revocation as though it retracts
past access would be a false security claim.

## 12. Copying, in and out

Adding to a vault is always explicit. Clipman never routes a captured clipboard
entry into a vault automatically, and no rule engine, including sync rules, may
target a vault. Automatic routing into a shared destination is precisely how
private material leaks, so the design does not offer it.

| Action | Behaviour |
| --- | --- |
| Add to vault | Copies the selected entry into the vault. The personal copy stays. A new `Id` is minted so the vault entry and the personal entry are independent afterwards. |
| Move to vault | As above, then deletes the personal copy. |
| Copy from vault | Places the entry on the clipboard. Always permitted for any member who can read the vault, because pasting is the point of the feature. |
| Save to personal history | Copies a vault entry into personal history. Hidden when `AllowCopyOut` is false. |
| Export vault | Owner and admin only. Writes a decrypted export. Always confirms first and always states that the export is unprotected. |

Quick Paste may target a vault entry. If the entry becomes unreachable because
the vault was left or access was revoked, the hotkey behaves exactly as it does
for a deleted entry, matching the existing rule for unsubscribed channels.

Vault entries never enter Secrets, and Secrets never enter a vault. Secrets are
machine-local by definition and that boundary is not negotiable.

## 13. Server support

### 13.1 What 2.x servers already provide

Everything in Sections 1 through 12 works against any deployed 2.x server.
Vault buckets are ordinary buckets, the ids are valid, and the server never
needs to understand any of it. Confidentiality, authorship integrity, and
cryptographic revocation are all in place.

What is missing is enforcement of availability and write access. With one shared
server token, every member can write to every bucket on that server, including
buckets belonging to other vaults and to personal histories. They cannot read
any of it, because they lack the passwords, but they could overwrite or delete
it.

### 13.2 The vault-aware server: membership and access control

A vault-aware server adds membership tokens and per-vault grants. The data path
does not change.

Settings gain a `Members` array. Tokens are stored only as
`SHA-256(UTF8(token))`, never in the clear, so a stolen settings file does not
yield working credentials:

```json
{
  "Members": [
    { "TokenSha256": "3f9a...", "Label": "Sam", "Vaults": ["gdGMkKa0..."],
      "Rights": "write", "ExpiresUnixMs": 0, "Revoked": false }
  ],
  "Vaults": [
    { "Ref": "gdGMkKa0...", "Buckets": ["x_U4B4yG...", "fdN_LFh3...", "cZymHixM..."] }
  ]
}
```

Request handling: the existing `AuthToken` remains the owner credential with
unrestricted access. A request bearing a member token is authorized only when
the token is not revoked, not expired, and the requested bucket is registered to
a vault the token is granted. `Rights: "read"` permits `HEAD` and `GET` only.
Everything else returns the existing 401, with no distinction between "unknown
token" and "not permitted for this bucket", so the API does not become a bucket
oracle.

One new administrative endpoint registers buckets to a vault reference, since
the server cannot derive them:

```
PUT /api/v1/vault/{serverRef}      owner token only; body lists buckets and members
GET /api/v1/vault/{serverRef}      owner token only
```

An admin client calls it when creating a vault, admitting a member, and on every
epoch rotation to register the new content bucket. `serverRef` is
`b64u(HMAC-SHA256(VIS, "Clipman.VaultServerRef.v1"))`, so it is opaque to the
server and derivable by every member.

New `clipmanserver` subcommands, matching the existing command style:
`vault list`, `vault show`, `member add`, `member list`, `member revoke`,
`member token-rotate`.

A vault-aware server must also apply per-token rate limiting and a per-vault bucket
quota, so that a member cannot exhaust disk by creating buckets.

### 13.3 Guidance

Clients must show the vault's enforcement level in the vault's detail view, in
words: "Access is enforced by this server" or "Access is not enforced by this
server; every member can overwrite data they cannot read". Sharing a vault with
someone you would not trust with your server token requires a vault-aware server, and the
interface must say so at the point of inviting rather than in documentation
alone.

## 14. Metadata privacy

What the server learns, stated exactly:

- That some bucket exists and its size and modification time. It does not learn
  a vault's name, its members' names, or which personal history the vault
  relates to, because every id is an HMAC under a secret seed.
- How many devices are in a vault, from the size of `Wraps`. It cannot identify
  them or link them across epochs, because `wrapIndex` is keyed on `VIS` and
  rotates with the epoch.
- With a vault-aware server, which member token touched which bucket and when. This is the
  price of enforcement, and it is a deliberate trade the operator makes
  knowingly. A vault on a server the operator does not control should weigh it.

Mitigations clients implement:

- `PadBlobsToKiB` pads content plaintext with a trailing ignored field to the
  next multiple of the configured size before encryption, so ordinary edits do
  not reveal their size. Default 4 KiB.
- Poll jitter of up to 20 percent of the poll interval, so a vault's activity
  pattern is less sharply correlated with a person's working rhythm.
- Manifest polls follow the same schedule as content polls whether or not a
  change is expected, so a rotation is not distinguishable by timing alone.

Not attempted: hiding the fact that vault activity is occurring, and hiding the
number of vaults on a server. An operator who must hide participation itself
needs a different transport, not a different clipboard manager.

## 15. Synchronization

Vault sync reuses the existing engine. Per poll tick, for each joined vault:

1. `HEAD manifestId`. On a revision change, `GET`, validate by Section 7.4,
   decrypt the body, and recompute the roster, policy, and current epoch.
2. If the epoch advanced, unwrap the new `VCK`, and switch the content bucket to
   `contentId(newEpoch)`. If no wrap exists for this device, mark the vault
   `access-lost`, stop polling its content, retain the local read-only cache,
   and tell the user plainly.
3. `HEAD contentId(e)`; `GET` only on a revision change; decrypt; merge with the
   existing entry-level merge.
4. Verify entry signatures, annotate unverified entries, and apply the
   Section 8.4 tombstone rule.

Uploads use the existing dirty-detection rule: serialize the plaintext with the
database-level `UpdatedUnixMs` zeroed, compare SHA-256 against the hash recorded
at the last transfer, and `PUT` with `If-Match` only when it differs. On 409,
`GET`, merge, rebuild, retry.

Vaults are independent of each other and of personal history. A vault failure
never blocks personal sync, and personal sync never blocks a vault. Offline
edits queue locally and merge on reconnect exactly as they do today.

Retention limits, history limits, and search index scope evaluate per vault. A
vault's entries never count against personal history limits and never appear in
personal history exports.

## 16. Accessibility requirements

These are requirements, not suggestions. Clipman's premise is that the whole
product is usable without sight and without a mouse, and a security feature that
cannot be operated by a screen reader user is a security feature they cannot
use.

- Every trust state is text. `verified`, `unverified`, and `changed` are exposed
  in the accessible name of the control, never by colour, icon, or position
  alone.
- Safety digits are rendered as eight groups of five digits, in a control that
  reports them as text, with a "read digits" action that spells them one group
  at a time. Comparison over a phone call is the primary verification path and
  must be first-class, not a fallback behind a QR code.
- Every destructive action states its consequence in the confirmation, in
  plain language, before the affirmative button: revoking says the person keeps
  what they already read; deleting a vault says it cannot be recovered; exporting
  says the export is unencrypted.
- Vault switching, epoch rotation, and access loss are announced through the
  existing status region, using the same concise phrasing the history status bar
  already uses.
- The roster is a real list: type-to-jump, keyboard-navigable, one row per
  person, with devices as a nested level that can be expanded. Every row reports
  name, role, device count, and verification state as its accessible name.
- Every flow in Sections 9 through 12 is completable from the keyboard alone,
  with no drag, no hover-only affordance, and no timed interaction. Invitation
  expiry is the only clock, it is never shorter than 15 minutes, and the
  remaining time is available as text on demand rather than only as a countdown.
- Fingerprint and invitation strings are selectable and copyable, and the
  copy action is announced.
- Nothing in a vault interface may rely on the user perceiving a change of
  colour to understand that access was lost.

Documentation this feature adds follows the same conventions as the existing
manual: descriptive link text, no reliance on emoji to carry meaning, real table
headers, and a text alternative for any diagram. User-facing surfaces go through
the accessibility review the project already applies to UI work before release.

## 17. Test vectors

Inputs:

```
VIS          = 00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f
inviteSecret = fedcba98765432100123456789abcdeff0e1d2c3b4a5968778695a4b3c2d1e0f
sigPriv      = 0x1111111111111111111111111111111111111111111111111111111111111111
ecdhPriv     = 0x2222222222222222222222222222222222222222222222222222222222222222
ephPriv      = 0x3333333333333333333333333333333333333333333333333333333333333333
iv           = 0f1e2d3c4b5a69788796a5b4c3d2e1f0
VCK_0        = a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf
```

Bucket ids:

| Value | Expected |
| --- | --- |
| `manifestId` | `x_U4B4yGi1_cdB6aduYRpGBEY9Rd81_DC8lJik_GC9M` |
| `contentId(0)` | `fdN_LFh3xNTDJczmoHOdaBTYN0dPtillxZsEbWyHkUU` |
| `contentId(1)` | `othNcnrccnYW_x-szcZcWa6ofdh9xK05KlnVsaoJ9-8` |
| `serverRef` | `gdGMkKa0dm90_Tyt1sj7AjXpezbQ_LaUM4_iZLEsGTY` |
| `inviteId` | `lQMGMx0PyZIzcT3HXVTGG44FOi_wMsF-fSH8aaEr_5Q` |

Device identity:

| Value | Expected |
| --- | --- |
| `sigPub` | `040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794` |
| `ecdhPub` | `04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285` |
| `fingerprint` | `b76314600370687e1e1e3723f1e8529cac04743dc183a17bee66880b09d53b32` |
| `fpr` | `t2MUYANwaH4eHjcj8ehSnKwEdD3Bg6F77maICwnVOzI` |
| safety digits | `46947 05216 00880 26750 07710 14115 61928 21148` |

Per-member ids:

| Value | Expected |
| --- | --- |
| `inboxId(fpr)` | `cZymHixMIltBUtNOT7EN3zsB5nyAyvI4i0J_WMXJc6I` |
| `wrapIndex(fpr, 0)` | `2x8qlJwm-rTE_DwZ7eybfvRgFLl4kiWMy1vmr5oCkwI` |
| `wrapIndex(fpr, 1)` | `gxYdqS7mh7IaYPR43qmcGppkA4F0xbDiNrQ0ix2hm0U` |

Epoch keys:

| Value | Expected |
| --- | --- |
| content container password | `oKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr8` |
| `MK_0` | `754819eb2d1e78e068924fa3ebec80847fe7ce47964dff0ba67459fb03285aea` |
| manifest container password | `dUgZ6y0eeOBokk-j6-yAhH_nzkeWTf8LpnRZ-wMoWuo` |

Key wrap of `VCK_0` to `ecdhPub` at epoch 0:

| Value | Expected |
| --- | --- |
| shared secret `Z` | `5f1c591a4bba11bee0d5a2a642eef6385d59aab8d6a6f151d8d857e2e822a67f` |
| HKDF salt | `8b7e25594f05e9b8afb8eddf39baf8346cc31332a59d9d563d47db91994b48a2` |
| `wrapEnc` | `0cd5cc01c1dd7acd78a02b1c448ea395b8f36525405b6cf4b143b64bda7f21f6` |
| `wrapMac` | `0ec3975064f49181d521c72bbaa755c0d95d6ea1c2a2a29c199156908537d167` |
| ciphertext | `86c76ceff48bcca9b46b8b29618d762755bb4e8cf521b02a126e08d7fd2af2afc5a6ae5efda5d7de1a0893b436f19f38` |
| tag | `37786528ca16978e3773f0d97e03a42b8583473e2ea0622b80e00478e337c587` |
| wrap length | 161 bytes |

Personal registry, using the same example token and password as
`sync-rules-spec.md` so the two documents cross-check:

| Value | Expected |
| --- | --- |
| `databaseId` (existing, for cross-check) | `l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU` |
| `vaultRegistryId` | `vVc-M72b6XgCJxTSjjnOhyKTKfN7TjkbRDw6J2AxOZ0` |

Entry signature input, for entry id
`b2f1c0a4-1d3e-4a5b-8c9d-0e1f2a3b4c5d`, both timestamps `1757200000000`, text
`https://example.org/shared-link`, added by the fingerprint above, at epoch 0:

| Value | Expected |
| --- | --- |
| `SHA-256(Text)` | `8a89f86b3b0c33693d3d8b883bb4a9263a09752d9201e44ec59336a02267f958` |
| `SHA-256(signature input)` | `b139aad18ad08fd4b42cd323e1d32f9ceb6fd99d3922377a2343ef0e4183a525` |

ECDSA signatures are randomized, so no signature value is fixed here. Conformance
tests must verify a signature produced by another implementation over the
signature input hash above.

## 18. Known limitations, accepted

- Revocation is forward-only. A removed member keeps everything they already
  read, and the interface says so.
- Copy controls are advisory. A modified client can ignore `AllowCopyOut`.
- A member with write access can add entries the others did not want. The audit
  log and per-entry signatures make this attributable, not preventable.
- On a 2.x server, a member can destroy buckets they cannot read. A vault-aware server is
  the answer and the interface names it.
- The server learns how many devices a vault has, and with a vault-aware server which
  member token was active when.
- A person who loses every device loses their access; the vault survives through
  other members or the recovery credential, which is itself a bearer credential
  and is presented with that warning.
- A vault forked by concurrent admin writes is reported, not auto-merged.
- Entries added while offline to a vault whose epoch has since rotated are
  re-encrypted to the new epoch on reconnect, which briefly reveals to a member
  who was revoked in between that an entry existed only if that member captured
  the old content bucket before deletion.

## 19. Rollout

1. Device identity, keystore integration, fingerprint and safety-digit
   rendering, and the verification state machine. No vault yet, no network use.
2. Manifest read and write, the chain and rollback rules, and the key wrap. A
   single-person vault end to end.
3. Invitation, claim, approval, and admission. Multi-person read-only vaults.
4. Roles, contributor writes, entry signatures, and tombstone rules.
5. Epoch rotation and revocation, with the audit log.
6. Vault-aware server membership tokens, access control, and `clipmanserver`
   commands.
7. Copy controls, policy flags, padding, and poll jitter.

Ship nothing before stage 5. A vault feature that can add members but cannot
cryptographically remove them would teach users a security model the software
does not implement, and that is worse than not shipping.
