# Clipman CLI (<code>clipman-cli</code>) — Design Specification

Status: partly implemented; reconciled against shipped source
Target: Clipman v2 command-line client for Linux, Unix-like systems, and Windows
Language: Go 1.25
Original revision date: 2026-07-21
Reconciliation date: 2026-08-06, against <code>ClipmanCli/</code> at version
<code>0.9.0</code>

This document incorporates a source audit of the Windows, macOS, Android, iOS,
and Python server implementations. Where the clients disagree, the shared
Windows/macOS desktop behavior is the compatibility baseline unless this
document identifies a deliberate exception.

The 2026-08-06 pass reconciles the design against the code that actually
shipped. Sections describing shipped behavior are now descriptive, not
aspirational. Sections describing work that has not been done are marked
**Deferred** and are the forward plan. Read section 0 first.

---

## 0. Implementation status

### 0.1 Shipped

| Area | State |
|---|---|
| Model, <code>.clipdb</code> codec, identity, merge, normalization | Complete, unit-tested |
| Config file, protected paths, Windows DPAPI secret protection | Complete |
| HTTP client, URL/token normalization, status mapping, redirect guard | Complete |
| Conditional create with <code>If-None-Match: *</code> | Complete |
| Commands <code>init status list get put rm sync pick menu help</code> | Complete |
| Kind filters, selectors, ordering, exit codes, porcelain/JSON output | Complete |
| Line-based <code>menu</code> and <code>pick</code> on the controlling terminal | Complete |
| Template variable resolution, <code>get --raw</code> | Complete (added after the original draft) |
| TLS trust for private authorities: <code>--ca-cert</code>, <code>--insecure</code>, connection-file CA | Complete (added after the original draft) |
| Full-screen renderer, <code>--renderer</code>/<code>--tui</code>/<code>--line</code>, <code>renderer</code> config key | Complete (section 8.2) |
| Interface self-naming, <code>u</code> switching with carried place, <code>status</code> <code>Interface:</code> | Complete (section 8.3) |
| Reading, saving, and running a clip (<code>v</code>, <code>w</code>, <code>x</code>) in both interfaces | Complete (section 8.4) |
| Editable prompts, display-width drawing and caret placement | Complete (section 8.2) |
| Windows interoperability fixture corpus and generator | Complete; macOS, Android, iOS generators absent (section 0.3 item 5) |
| <code>Manual.html</code>, <code>clipman-cli.1</code>, built-in help | Complete and in sync with the code |
| Cross-build to 7 targets in per-platform directories | Complete |

### 0.2 Deliberate departures from the original draft

- **Passwordless buckets are not supported.** Clipman Server requires a
  nonblank history password, so <code>init</code> rejects an empty password,
  <code>password_mode = "passwordless"</code> is a config error, and
  <code>identity.DatabaseID</code> returns an empty string for a blank password.
  Every <code>--allow-passwordless</code> reference in the original draft is
  obsolete.
- **No OS secret store.** <code>--save-password</code> accepts
  <code>none</code> or <code>config</code>. On Windows the stored token and
  password are DPAPI CurrentUser blobs; on Unix they are plaintext inside an
  owner-only 0600 file. Secret Service and Credential Manager were dropped to
  keep the build dependency-free and cgo-free.
- **Config is a restricted TOML subset parsed by hand**
  (<code>internal/config/config.go</code>), not a TOML library. Strings must be
  quoted; only the <code>[limits]</code> table exists. No third-party TOML
  dependency was added.
- **Connection-file import.** <code>init --connection-file</code> reads a
  Clipman Server <code>.clpconf</code>/<code>.txt</code> and extracts address,
  token, and an optional exclusive private certificate authority.
- **Templates resolve variables on output.** <code>get</code>,
  <code>pick</code>, and <code>menu</code> resolve template variables;
  <code>get --raw</code> returns stored text unchanged.
- **Entry carries <code>ModifiedUnixMs</code>** in addition to the fields listed
  in section 5.5, and rich-text HTML/RTF fields survive through
  <code>Extra</code> unknown-field preservation.

### 0.3 Deferred — the remaining work

Nothing below exists in the tree. No stub, no flag, no documentation claim.

1. **Daemon and offline writes** (sections 10.5–10.7). No
   <code>internal/daemon</code>, no cache, no pending queue, no IPC. Every
   command is stateless: read, mutate, upload, exit.
2. ~~**TUI renderer**~~ — **shipped.** See section 8.2. The line renderer
   remains the default; the full-screen one is opt-in.
3. **<code>sync</code> uploads.** <code>sync</code> currently downloads,
   decodes, and validates. It always reports <code>"uploaded": false</code>
   because with no pending queue there is nothing to replay. Its full contract
   in section 7.12 arrives with the daemon.
4. **<code>status</code> local fields.** Daemon reachability, cache freshness,
   last sync, pending count, and oldest pending age depend on the daemon.
5. **Interoperability fixture corpus** (section 14.1) — **started.** The
   Windows corpus exists and passes in both directions; macOS, Android, and iOS
   generators remain future work. See
   <code>ClipmanCli/testdata/fixtures/README.md</code>.
6. **CI.** Build targets and checksum determinism are not exercised by a
   workflow.

### 0.4 Working baseline

~~~sh
cd ClipmanCli && go test ./...     # all packages pass as of 2026-08-06
~~~

Version lives in <code>ClipmanCli/VERSION</code> and the <code>version</code>
variable in <code>cmd/clipman-cli/main.go</code>; both read
<code>0.9.0</code> and must be bumped together. Release tags use
<code>cli-v&lt;x.y.z&gt;</code>.

---

## 1. Purpose

Clipman has native GUI clients and a history server, but no command-line peer.
<code>clipman-cli</code> exposes shared text history through ordinary streams:

~~~sh
some_command | clipman-cli put
clipman-cli get | some_command
clipman-cli get 3 > snippet.txt
~~~

This supports headless servers, SSH sessions, WSL, Windows terminals, and
cross-machine text transfer without a local clipboard, daemon, kernel module,
or privileged device.

The server remains an opaque blob store. The CLI interoperates by:

1. deriving the same password-scoped database ID;
2. reading and writing the same <code>.clipdb</code> wire format;
3. applying desktop-compatible merge and tombstone rules; and
4. using the existing revision-based HTTP API.

### 1.1 Non-goals for v1

- Monitoring or bridging an X11, Wayland, macOS, or Windows local clipboard.
- File-list history and the separate secrets database.
- General server administration or backup restoration.
- Treating binary data as native clip content. V1 clips are valid UTF-8 text.
- Replacing the GUI clients.

Templates are in scope as a filtered view of the text-history database, and
template variables are resolved on output unless <code>--raw</code> is used.

---

## 2. Compatibility authority and decision log

### 2.1 Source authority

Interoperability behavior is checked against:

- Windows: <code>src/ClipDatabaseFile.cs</code>,
  <code>src/ServerDatabaseIdentity.cs</code>,
  <code>src/ServerStorageClient.cs</code>, and <code>src/ClipStore.cs</code>.
- macOS: the corresponding files under
  <code>ClipmanMac/Sources/ClipmanCore</code> and
  <code>ClipmanMac/Sources/Clipman</code>.
- Android and iOS codec, identity, storage-client, and conflict-resolver code.
- <code>ClipmanServerLinux/clipman_server.py</code> for the HTTP contract.

Golden fixtures generated by those implementations decide format questions;
prose does not override a failing interoperability fixture.

**<code>ClipmanCli/internal/</code> is a fork of
<code>ClipmanLinuxBackend/internal/</code>.** The two trees are identical apart
from module paths, except that the CLI adds the TLS trust options of section 3.4
(<code>server.WithCACertPEM</code>, <code>server.WithInsecureSkipVerify</code>,
<code>server.WithExclusiveCACertPEM</code>, config keys
<code>ca_cert_pem</code>/<code>ca_host</code>/<code>ca_exclusive</code>/<code>tls_insecure</code>)
and targets Go 1.25 rather than 1.20. Any change to shared logic — codec,
identity, merge, model, operation, sync engine — must be applied to both trees
in the same change, or Linux and CLI clients will disagree about the same
database.

### 2.2 Resolved product decisions

- Reproduce shared Windows/macOS behavior wherever practical.
- **Superseded:** the original draft supported passwordless
  <code>CLIPDB1</code> buckets. Server mode requires a nonblank history
  password, so the CLI writes and reads <code>CLIPDB2</code> only. It still
  *decodes* a <code>CLIPDB1</code> or bare-gzip blob it is handed, because the
  codec is shared, but no CLI path produces one.
- Ship a supported Windows CLI, not merely an untested cross-build.
- **Superseded:** the daemon was planned as a v1 runtime accelerator. It is
  deferred; see section 0.3. Every shipped command is stateless.
- Expose templates through an explicit kind filter; normal history is the default.
- An ambiguous delete search must result in one user-selected entry. It never
  implies bulk deletion, even with <code>--yes</code>.
- Support connecting to a server with a privately issued TLS certificate,
  because Clipman Server can now issue its own; see section 3.4.

### 2.3 Resolved: safe initial bucket creation

**Resolved in favor of the conditional branch.** The server supports
<code>If-None-Match: *</code> on database PUT and answers 412 when the bucket
already exists. <code>server.Client.Put</code> takes a <code>createOnly</code>
argument, and <code>syncengine.Engine.Mutate</code> passes
<code>!state.Exists</code>, so a first write is always conditional and a losing
racer receives <code>ErrConflict</code>, re-reads, reapplies the same mutation,
and retries.

The CLI therefore *may* claim no-lost-update safety for simultaneous initial
creation. The compatibility branch described in the original draft — an
unconditional PUT followed by read-back verification — was not implemented and
must not be reintroduced.

---

## 3. Server protocol

### 3.1 Required endpoints

| Method | Path | Authentication | Meaning |
|---|---|---|---|
| <code>GET</code> | <code>/api/v1/health</code> | none | Server status |
| <code>HEAD</code> | <code>/api/v1/database/{id}</code> | bearer | Revision and length |
| <code>GET</code> | <code>/api/v1/database/{id}</code> | bearer | Raw database blob |
| <code>PUT</code> | <code>/api/v1/database/{id}</code> | bearer | Replace raw database blob |

Every authenticated request sends:

~~~text
Authorization: Bearer <canonical-token>
User-Agent: clipman-cli/<version> (<goos>/<goarch>)
~~~

Successful HEAD and GET responses contain <code>X-Clipman-Revision</code>,
<code>ETag</code>, and <code>Content-Length</code>. Successful PUT responses
contain <code>X-Clipman-Revision</code>. The client accepts a quoted or unquoted
revision and prefers <code>X-Clipman-Revision</code>, falling back to
<code>ETag</code>.

An upload against an existing revision sends:

~~~text
If-Match: "<revision>"
Content-Type: application/octet-stream
Content-Length: <bytes>
~~~

HTTP 409 and 412 both mean revision conflict. HTTP 404 on GET or HEAD means the
bucket does not exist. A valid database PUT route creates a missing bucket; PUT
itself is not expected to return 404 for a missing database.

### 3.2 Server URL normalization

Accepted inputs:

- <code>clipman://host:port</code>, mapped to <code>http://host:port</code>;
- <code>http://...</code> and <code>https://...</code>;
- bare <code>host:port</code>, mapped to <code>clipman://host:port</code>; and
- a pasted Clipman connection-details or settings object from which a URL and
  token can be extracted.

Trailing slashes are normalized. A reverse-proxy path prefix is preserved.
Query strings, fragments, and embedded credentials are rejected or stripped.
By default HTTPS uses the operating-system trust store and normal hostname
validation. Redirects to a different scheme or host are refused rather than
followed, so bearer credentials never reach another origin; the redirect chain
is capped at five hops.

Plain HTTP exposes the bearer token to the network. Initialization warns when
HTTP is used outside loopback, private, link-local, and CGNAT ranges, and
recommends HTTPS, a VPN, or a trusted private network.

### 3.4 Private certificate authorities

Clipman Server can issue its own TLS certificate, so the CLI supports trusting
a private authority without disabling verification. Three mutually exclusive
mechanisms exist, all resolved before the first request:

| Mechanism | Effect |
|---|---|
| <code>--ca-cert FILE</code> | Adds the PEM certificates to the system pool |
| <code>--insecure</code> | Disables verification entirely; prints a warning every run |
| Connection file carrying <code>ca_cert_pem</code> | Trusts **only** that authority, and only for the connection file's HTTPS host |

The connection-file path is the strict one: <code>ParsePrivateAuthority</code>
requires exactly one PEM CERTIFICATE block under 32 KiB, refuses anything
containing private key material, requires the CA basic constraint and
certificate-signing key usage, rejects a not-yet-valid or expired authority, and
requires an HTTPS server address. It records the pinned host as
<code>ca_host</code> and refuses to load if the configured server host later
disagrees.

When <code>init</code> hits an untrusted-certificate error with no trust option
supplied and a terminal available, it fetches the presented chain for display
only, shows subject, issuer, validity window, and the **authority** SHA-256
fingerprint, tells the user to compare that fingerprint out of band, and trusts
it only on explicit confirmation. The fetched certificate is never used to make
the failed connection succeed silently.

Persisted equivalents are the config keys <code>ca_cert_pem</code>,
<code>ca_host</code>, <code>ca_exclusive</code>, and <code>tls_insecure</code>.
Explicit command-line flags win over the stored profile.

### 3.3 Timeouts and limits

Defaults, configurable within documented safe ranges:

- connection timeout: 8 seconds;
- response-header timeout: 8 seconds;
- total request timeout: 30 seconds;
- maximum downloaded blob: 64 MiB;
- maximum uploaded blob: 64 MiB, also respecting HTTP 413; and
- bounded retry count: 3 conflict retries after the initial attempt.

The client streams HTTP bodies through a size-limited reader. It never trusts
<code>Content-Length</code> alone.

---

## 4. Database identity

First canonicalize the token:

1. trim surrounding whitespace;
2. if the input is recognized connection JSON, extract <code>AuthToken</code>
   or the equivalent canonical token field;
3. otherwise remove surrounding single or double quotes and trailing comma or
   semicolon; and
4. save only the resulting canonical token.

Derive the bucket ID as follows:

~~~text
key = SHA256(UTF8(canonical_token))
msg = UTF8("Clipman.ServerDatabaseId.v1" + "\n" + password)
id  = Base64URLWithoutPadding(HMAC-SHA256(key, msg))
~~~

The result is 43 ASCII characters. A missing token is a configuration error.

A blank password has no bucket. <code>identity.DatabaseID</code> returns an
empty string when either the trimmed token or the password is empty, and the
command layer refuses a blank password before reaching it with exit code 5.
The passwordless sentinel component described in the original draft is not
implemented and must not be added while the server requires a password.

The bucket ID is sensitive operational metadata. Logs redact it; status output
shows no more than a short fingerprint unless <code>--verbose</code> and an
explicit diagnostic option are both used.

### 4.1 Password validation limitation

A wrong password normally derives another bucket ID. If that bucket is absent,
the server returns 404; there is no encrypted blob on which to detect a wrong
password. Therefore <code>init</code> can verify a password only when the
derived bucket already exists and can be decrypted.

For a missing bucket, initialization says:

~~~text
No database exists for this token/password combination.
The password cannot be verified until this bucket contains data.
Confirm it matches the other clients before creating new history.
~~~

It must not report that the password was validated.

---

## 5. <code>.clipdb</code> wire format

The requirement is wire compatibility, not byte-for-byte equality. Randomness,
gzip metadata, JSON formatting, and field order may differ.

### 5.1 Containers

~~~text
CLIPDB1 = ASCII "CLIPDB1" || gzip(UTF-8 JSON)

CLIPDB2 = ASCII "CLIPDB2"
        || 0x01
        || salt[16]
        || iv[16]
        || ciphertext[16 * n, n >= 1]
        || hmac[32]
~~~

For compatibility, a blob without either magic prefix is interpreted as raw
gzip JSON. Unsupported magic or invalid gzip is a format error.

### 5.2 Encrypted read

1. Require at least 88 bytes: header, version, salt, IV, one AES block, and HMAC.
2. Require version byte <code>0x01</code>.
3. Require nonempty ciphertext whose length is a multiple of 16.
4. Parse salt at bytes 8–23, IV at 24–39, ciphertext at 40 through the byte
   before the final 32 bytes, and HMAC from the final 32 bytes.
5. Derive keys using section 5.4.
6. Verify HMAC-SHA256 over every byte except the appended HMAC, using a
   constant-time comparison.
7. Only after successful authentication, decrypt AES-256-CBC with PKCS7 padding.
8. Decompress through the configured decompressed-size limit.
9. Validate UTF-8 and decode JSON within the JSON limits.

HMAC failure is reported as wrong password or damaged/tampered data without
revealing which.

### 5.3 Encrypted write

1. Generate a cryptographically random 16-byte IV.
2. Reuse the existing encrypted file's 16-byte salt when safely available, to
   mirror desktop behavior; otherwise generate a new random salt. Fresh salt on
   every write is also wire-compatible and is permitted for transient blobs.
3. Encode JSON as UTF-8 and gzip it.
4. Apply PKCS7 padding and AES-256-CBC encryption.
5. Assemble magic, version, salt, IV, and ciphertext.
6. Append HMAC-SHA256 over the assembled bytes.

All randomness comes from the operating-system cryptographic random source.

### 5.4 Key derivation

~~~text
dk = PBKDF2(
    PRF = HMAC-SHA1,
    password = UTF8(history_password),
    salt = salt[16],
    iterations = 150000,
    length = 64
)
encryption_key = dk[0:32]
mac_key        = dk[32:64]
~~~

HMAC-SHA1 is required for existing-client interoperability.

### 5.5 JSON model

~~~json
{
  "Version": 1,
  "UpdatedUnixMs": 0,
  "Entries": [
    {
      "Id": "32 lowercase hexadecimal characters",
      "Text": "",
      "Name": "",
      "Group": "",
      "SourceMachine": "",
      "CreatedUnixMs": 0,
      "LastUsedUnixMs": 0,
      "Pinned": false,
      "IsTemplate": false,
      "ManualOrder": 0
    }
  ],
  "DeletedEntries": [
    {
      "Id": "",
      "TextHash": "",
      "DeletedUnixMs": 0,
      "SourceMachine": ""
    }
  ]
}
~~~

Known fields are always emitted. Missing or null strings normalize to empty
strings. Times are Unix milliseconds. New IDs are random GUID/UUID values
rendered as 32 lowercase hexadecimal characters without dashes.

<code>TextHash</code> is lowercase hexadecimal SHA-256 of the exact UTF-8 bytes
of <code>Text</code>.

The shipped <code>model.Entry</code> also carries <code>ModifiedUnixMs</code>,
which the sketch above omits.

Unknown database- and entry-level JSON fields are preserved during every
read/modify/write cycle, through an <code>Extra map[string]json.RawMessage</code>
on <code>Database</code>, <code>Entry</code>, and <code>DeletedEntry</code>. This
deliberately follows the macOS forward-compatibility behavior and prevents a CLI
write from destroying fields introduced by a newer client. It is also how the
Windows and Mac rich-text HTML/RTF fields survive a CLI round trip: the CLI
never emits rich formats, but it never drops them either.

### 5.6 Parse limits and normalization

Default limits:

- decompressed JSON: 256 MiB;
- JSON nesting depth: 100;
- entries: 100,000;
- tombstones: 100,000; and
- one text value: 64 MiB of UTF-8.

Before writing:

- <code>Version</code> is at least 1 and retains a higher understood source value;
- <code>UpdatedUnixMs</code> becomes the mutation time;
- blank IDs on retained entries receive new IDs;
- zero creation times become the mutation time;
- zero last-used times become the creation time;
- manual order is normalized to contiguous values while preserving relative
  desktop order; and
- null collections become empty collections.

---

## 6. Configuration and secrets

### 6.1 Default locations

Only the configuration file exists today. Cache, queue, and endpoint paths are
**deferred** with the daemon and are recorded here as the intended layout.

Unix:

~~~text
~/.clipman/                         owner-only directory
~/.clipman/config.toml              configuration                    (shipped)
~/.clipman/cache.clipdb             daemon cache                     (deferred)
~/.clipman/pending.clipq            daemon pending-operation queue   (deferred)
$XDG_RUNTIME_DIR/clipman/<account>.sock                              (deferred)
~~~

If <code>XDG_RUNTIME_DIR</code> is unavailable, use an owner-created,
owner-verified directory under the platform temporary directory that includes
the numeric user ID. Never use a predictable shared directory without ownership
and mode validation.

Windows:

~~~text
%LOCALAPPDATA%\Clipman CLI\config.toml                               (shipped)
%LOCALAPPDATA%\Clipman CLI\cache.clipdb                              (deferred)
%LOCALAPPDATA%\Clipman CLI\pending.clipq                             (deferred)
\\.\pipe\clipman-cli-<user-sid>-<account>                            (deferred)
~~~

<code>CLIPMAN_HOME</code> relocates the configuration/data directory.
<code>CLIPMAN_CONFIG</code> selects a config file. An explicit
<code>--config</code> wins over both. Precedence is:

1. command-line flag;
2. <code>CLIPMAN_CONFIG</code>;
3. <code>CLIPMAN_HOME</code> plus the standard filename;
4. <code>config.toml</code> beside the executable, **if it already exists**;
5. platform default.

Step 4 is the portable profile: a copy of the program can carry its own
configuration, so two builds can target two servers without interfering. The
lookup adopts such a file only once it exists, so an ordinary installation
stays on the per-user profile and nothing changes for it.

Two ways to create one: <code>init --portable</code>, or answering yes to the
question an interactive <code>init</code> asks. That question deliberately
avoids two words. "System wide" would be false — nothing here writes
machine-wide, only to the user account. "Portable" is jargon that does not say
portable relative to what. It asks about the consequence instead:

~~~text
Settings are normally saved for your user account, where every copy of Clipman CLI shares them.
Save them beside this program instead, so only this copy uses them? [y/N]
~~~

It is skipped when <code>--config</code>, <code>CLIPMAN_CONFIG</code>, or
<code>CLIPMAN_HOME</code> has already named a location, and on
<code>--non-interactive</code> runs.

The lookup covers the directory holding the executable, resolved through
symlinks, and deliberately **not** the working directory. A config file names a
server and carries a token; letting an unrelated <code>config.toml</code> in
whatever folder the shell happens to be in take over a session would be a
credential-substitution footgun, not a convenience.

**Deferred:** the account identifier used for IPC is a stable hash of the
canonical config path and bucket identity. Different configs and accounts never
share an endpoint.

### 6.2 Filesystem protection

On Unix:

- private directories have no group/other permissions and are owned by the
  effective user;
- secret/state files have no group/other permissions and are owned by the user;
- newly created directories use mode 0700 and files mode 0600;
- stricter safe modes are accepted when the requested operation can still run;
- symlinks are rejected for config, cache, journal, and endpoint paths;
- writes use same-directory temporary files, explicit permissions, fsync where
  durability is promised, and atomic replacement; and
- every component used for a security decision is revalidated immediately
  before opening.

On Windows:

- files and directories receive an ACL granting the current user and required
  system principals only;
- inherited broad access is removed or initialization fails with a repair hint;
- reparse points are rejected for protected state unless explicitly supported
  and safely resolved; and
- named pipes use a DACL restricted to the current user SID.

Permission failure maps to exit code 3 and includes a concrete repair command or
Windows UI instruction.

### 6.3 Config format

The file is named <code>config.toml</code> and reads as a restricted TOML
subset implemented in <code>internal/config/config.go</code>: comments, one
optional <code>[limits]</code> table, and <code>key = value</code> lines whose
string values must be Go-quoted. There is no TOML library dependency, and
unknown keys or sections are a load error rather than being ignored.

~~~toml
server = "https://server.example:52731"
token_protected = "base64 DPAPI blob"   # Windows; "token" holds plaintext on Unix
machine = "workstation"
renderer = "line"
pinned_first = false
tls_insecure = false                     # written only when true
ca_cert_pem = "-----BEGIN CERTIFICATE-----\n..."
ca_host = "server.example"               # requires ca_cert_pem
ca_exclusive = true                      # requires ca_cert_pem; written only when true
default_kind = "history"
password_mode = "prompt"
password_protected = "base64 DPAPI blob" # only with password_mode = "config"

[limits]
max_blob_bytes = 67108864
max_json_bytes = 268435456
max_entries = 100000
max_text_bytes = 67108864
~~~

The default machine name is the OS hostname. The only accepted renderer value
is <code>line</code>; <code>tui</code> is rejected until section 8.2 ships.
Kind values are <code>history</code>, <code>templates</code>, and
<code>all</code>. Password mode is <code>prompt</code> or <code>config</code>;
<code>passwordless</code> is rejected with an explanatory message, and
<code>keyring</code> is not a value.

Validation refuses contradictory profiles: token with token_protected, password
with password_protected, saved password values without
<code>password_mode = "config"</code>, <code>tls_insecure</code> together with
<code>ca_cert_pem</code>, <code>ca_host</code>/<code>ca_exclusive</code> without
<code>ca_cert_pem</code>, and any limit outside its documented ceiling.

### 6.4 Password resolution

Resolution order:

1. <code>--password</code> or <code>-​-password=</code>;
2. presence of <code>CLIPMAN_PASSWORD</code>;
3. the protected <code>password</code> in config, when
   <code>password_mode = "config"</code>; and
4. a no-echo prompt on the controlling terminal.

A blank result at the end of that chain is a failure with exit code 5, not a
passwordless profile. Non-interactive contexts that reach step 4 without a
terminal fail rather than hanging.

**Not implemented:** platform secret stores. Unix Secret Service and Windows
Credential Manager were dropped; adding either must not introduce cgo. On
Windows the config-stored password is a DPAPI CurrentUser blob, so it is bound
to the user account. On Unix it is plaintext inside an owner-only 0600 file,
and interactive <code>init</code> says so in those words before saving it.

When stdin contains clip text, password prompts read from the controlling
terminal, never stdin. <code>platform.OpenConsole</code> and
<code>OpenConsoleOutput</code> exist for exactly this.

**Deferred:** the daemon retains the history password, or an equivalent
capability sufficient to derive keys for arbitrary future salts, in process
memory. It must not claim to retain only one derived key. Memory is cleared on
orderly shutdown on a best-effort basis; swapping and crash dumps are documented
platform risks.

### 6.5 Token input

Because tokens are secrets, <code>init</code> supports:

- interactive no-echo entry;
- <code>CLIPMAN_TOKEN</code>;
- <code>--connection-file</code>, reading a Clipman Server <code>.clpconf</code>
  or connection <code>.txt</code>;
- <code>--token-file</code>; and
- <code>--token</code>, with a process-list warning.

<code>--connection-file</code> cannot be combined with <code>--token</code> or
<code>--token-file</code>. The file is size-capped at 64 KiB and may be either
the JSON connection object or the <code>Key: value</code> text form; both are
parsed by <code>server.ConnectionProfile</code>, which also extracts an optional
<code>ca_cert_pem</code>. A JSON object carrying the <code>clipman</code> marker
must declare <code>"server-connection"</code> version 1. When no address key is
present, one is synthesized from host and port, choosing <code>https</code> when
the object names a certificate and key file.

An interactive <code>init</code> with no source flags at all first asks whether
the user has a connection file, because that is the path that also carries the
private certificate authority.

Only <code>init</code> persists a token. Logs never contain the token, password,
full database ID, plaintext clip text, or authorization headers;
<code>--verbose</code> prints only an 8-character bucket fingerprint.

On Unix the canonical token lives in the owner-only config as plaintext. On
Windows it is stored as a DPAPI CurrentUser blob in <code>token_protected</code>
and the plaintext <code>token</code> key is not written.

---

## 7. Command-line contract

### 7.1 General syntax

~~~text
clipman-cli [global options] <command> [command options]
~~~

No arguments is an alias for <code>menu</code> only when a controlling terminal
exists. Otherwise it is a usage error.

Global options are defined once:

| Option | Environment | Meaning |
|---|---|---|
| <code>--config PATH</code> | <code>CLIPMAN_CONFIG</code> | Select config |
| <code>--server URL</code> | — | Override server for this invocation |
| <code>--password VALUE</code> | <code>CLIPMAN_PASSWORD</code> | Override password |
| <code>--ca-cert FILE</code> | — | Trust an additional PEM authority |
| <code>--insecure</code> | — | Disable TLS verification (warns every run) |
| <code>--json</code> | — | Use the command's documented JSON output |
| <code>--quiet</code>, <code>-q</code> | — | Suppress nonessential diagnostics |
| <code>--verbose</code> | — | Redacted debug diagnostics |
| <code>--version</code> | — | Version, GOOS, and GOARCH |
| <code>--help</code>, <code>-h</code> | — | Help |

Global options are parsed by hand before the command word and must precede it;
an option after the command is parsed by that command's flag set. An
unrecognized leading option says so and points at that rule. Within a command,
operands are permuted behind options, so <code>get 3 --json</code> and
<code>get --json 3</code> are equivalent, and <code>--</code> protects an
operand that begins with a hyphen.

For <code>init</code>, the effective global server/password/TLS values are
values to save or test. They are not separate shadowing flags.

Command summary:

| Command | Purpose | Principal options |
|---|---|---|
| <code>init</code> | Configure and test a profile | token/connection source, password storage, machine, non-interactive, force |
| <code>get</code> | Emit one entry | selector, kind, newline, touch, first, raw |
| <code>put</code> | Add or reuse text | file/text/stdin, metadata, template, duplicate mode |
| <code>list</code> | Browse entries | count, filters, kind, JSON, porcelain |
| <code>rm</code> | Delete exactly one entry | selector, kind, yes, case-sensitive |
| <code>menu</code> | Interactive line manager | count, kind, pinned-first |
| <code>pick</code> | Select and emit one entry | count, kind, pinned-first |
| <code>sync</code> | Download and validate history | JSON, quiet |
| <code>status</code> | Inspect remote state | JSON, refresh |
| <code>help</code> | Print general or per-command usage | — |

**Deferred:** <code>daemon run/start/stop</code>.

### 7.2 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Local processing, data-format, or unspecified failure |
| 2 | Invalid usage, ambiguous non-interactive selection, or confirmation required |
| 3 | Authentication, protected-file permission, ACL, or local peer-authorization failure |
| 4 | Network failure, timeout, TLS failure, HTTP 413/5xx, or server unavailable |
| 5 | Password required, HMAC/decrypt failure, or password cannot open an existing bucket |
| 6 | Entry or bucket content not found after a successful read |
| 130 | Interrupted by the user where the platform supports this convention |

HTTP 401/403 map to 3; 409/412 are handled internally until retries are
exhausted, then 1; missing database is an empty history, and selection from it
returns 6. Broken output pipes terminate quietly using the platform's normal
pipeline convention.

~~Known gap:~~ **Fixed.** <code>mapRuntimeError</code> used to fall through to 4
for anything it did not recognize, so a local encode or decode failure surfacing
through a network call path reported a network code — telling a script to retry
what retrying cannot fix. It now falls through to 1, and claims 4 only for a
failure that is the network's or the server's:
<code>net.Error</code> (timeouts, refused connections, DNS, and the
<code>*url.Error</code> the HTTP client wraps transport and TLS handshake
failures in), an unwrapped certificate-trust failure, or a
<code>server.StatusError</code> reporting 413 or 5xx. A 4xx that is not one of
the sentinels is the request's problem and exits 1.

That distinction needed a typed error: <code>server.StatusError</code> keeps the
status code rather than only formatting it into a message, because recovering it
by parsing the message back out would be worse.

### 7.3 History-kind filter

Commands that view or address entries accept:

~~~text
--kind history|templates|all
~~~

Default is <code>history</code>, which excludes <code>IsTemplate=true</code>.
<code>templates</code> includes only templates. <code>all</code> combines both.
Filtering occurs before indexing. Every displayed index is valid only within
the exact filtered view printed by that command.

### 7.4 Canonical ordering

Within the selected kind and filters:

1. <code>LastUsedUnixMs</code> descending;
2. <code>CreatedUnixMs</code> descending; and
3. <code>Id</code> ascending using ordinal comparison.

Pinned entries do not float by default, so index 0 means most recently used.
<code>--pinned-first</code> or config enables the desktop-style pinned view.

### 7.5 <code>init</code>

~~~text
clipman-cli [--ca-cert FILE | --insecure] init
                 [--connection-file PATH | --token-file PATH | --token VALUE]
                 [--save-password none|config]
                 [--machine NAME] [--non-interactive] [--force]
~~~

Initialization:

1. resolves and canonicalizes URL and token, optionally from a connection file;
2. resolves a nonblank password;
3. resolves TLS trust, offering the fingerprint prompt of section 3.4;
4. derives the bucket ID;
5. checks health and authenticated download access;
6. decrypts the bucket if it exists;
7. clearly reports when a missing bucket prevents password validation;
8. creates protected platform directories;
9. writes canonical config atomically; and
10. optionally stores the password protected for this user.

Non-interactive mode requires server, token, and a nonblank password. Existing
config requires <code>--force</code>. A failed connectivity test does not
overwrite existing config, because the config write happens only after health
and download checks pass.

Without an explicit <code>--save-password</code>, an interactive run asks
whether to save the password and states the protection the platform actually
gives it.

With <code>--json</code>, initialization emits one object containing
<code>server</code>, <code>bucket_fingerprint</code>,
<code>bucket_exists</code>, <code>password_validated</code>, and
<code>config_path</code>.

### 7.6 Selectors

The following selectors are mutually exclusive:

- positional index;
- <code>--id ID</code>;
- <code>--name NAME</code>; and
- <code>--search TEXT</code>.

Index is zero-based after kind and other filters. ID is exact. Name and search
are Unicode case-insensitive by default; <code>--case-sensitive</code> changes
that. Search considers Name and Text in canonical order.

If a name or search expected to identify one entry produces multiple matches:

- read-only <code>get</code> uses the first canonical match only when
  <code>--first</code> is supplied;
- interactive commands ask the user to select one; and
- non-interactive commands fail with code 2 and print candidate indices/IDs to
  stderr or a structured error under <code>--json</code>.

### 7.7 <code>get</code>

~~~text
clipman-cli get [INDEX]
clipman-cli get --id ID
clipman-cli get --name NAME [--first]
clipman-cli get --search TEXT [--first]
~~~

Options:

- common selector and kind options;
- <code>--newline</code>, <code>-n</code>;
- <code>--touch</code>;
- <code>--raw</code>;
- <code>--pinned-first</code>; and
- <code>--case-sensitive</code>.

Default output is exact UTF-8 Text with no added bytes, except that a template
entry has its variables resolved. <code>--raw</code> suppresses that resolution
and emits the stored text. <code>--newline</code> ensures the output ends in one
LF byte; it does not add another LF when one is already present.

<code>--touch</code> records one write operation that updates only
<code>LastUsedUnixMs</code>, matching desktop <code>MarkUsed</code> behavior.
It does not change <code>SourceMachine</code>. A concurrent delete wins; touch
does not resurrect an entry.

With <code>--json</code>, stdout is one JSON entry object plus
<code>Index</code>, and a resolved template additionally carries
<code>ResolvedText</code>; plaintext Text is not separately emitted.

### 7.8 <code>put</code>

~~~text
command | clipman-cli put
clipman-cli put --file PATH
clipman-cli put --text VALUE
~~~

Exactly one input source is used. <code>--file</code> and <code>--text</code>
are mutually exclusive; otherwise stdin is read. TTY stdin is allowed but help
explains that input ends at EOF.

Options:

- <code>--name NAME</code>;
- <code>--group GROUP</code>;
- <code>--pin</code>;
- <code>--template</code>;
- <code>--duplicate ignore|movetotop|keep</code>, default
  <code>movetotop</code>; and
- <code>--file</code> or <code>--text</code>.

Input must be valid UTF-8, nonempty, and within the text limit. Whitespace,
line endings, and NUL characters that are valid UTF-8 are preserved, matching
Windows desktop text behavior. No implicit trimming occurs.

Duplicate behavior matches the desktop:

- <code>ignore</code>: return the existing ID without writing;
- <code>movetotop</code>: update only LastUsedUnixMs and SourceMachine on the
  existing exact-Text match; metadata flags do not modify that existing entry;
- <code>keep</code>: create a new entry with a new ID.

Duplicate lookup is restricted to the requested kind. This is a deliberate CLI
adaptation of the desktop's separate history/template workflows: an explicit
<code>put --template</code> must not silently move a non-template history entry
instead of creating or updating a template. Within one kind, the desktop
duplicate behavior is reproduced exactly.

New entries receive current creation/last-used times and
<code>ManualOrder=max(existing)+1</code>. The database is not pruned for maximum
entry count or age, but tombstones are normalized as required by section 9.
Name and Group flag values are trimmed like desktop metadata editors; Text is
never trimmed.

Default stdout is empty. The resulting ID is informational stderr unless quiet.
With <code>--json</code>, the resulting entry and whether it was
<code>created</code>, <code>moved</code>, or <code>ignored</code> are emitted
on stdout.

### 7.9 <code>list</code>

~~~text
clipman-cli list [-n COUNT | --all]
                 [--group GROUP] [--search TEXT]
                 [--kind history|templates|all]
                 [--pinned-first]
                 [--json | --porcelain]
~~~

Default count is 20. Human output contains index, P/T flags, age, source
machine, name/group, and a one-line escaped preview. Width-aware truncation
never splits a UTF-8 sequence.

JSON output is an array of wire-shaped entries with an added numeric
<code>Index</code>. Porcelain output is:

~~~text
index<TAB>id<TAB>age_ms<TAB>source<TAB>name<TAB>preview
~~~

Backslash, tab, LF, CR, and other control bytes in every textual column use
C-style escapes. One physical output line always represents one entry.

### 7.10 <code>rm</code>

~~~text
clipman-cli rm INDEX
clipman-cli rm --id ID
clipman-cli rm --name NAME
clipman-cli rm --search TEXT
~~~

Options include common selector/kind options, <code>--yes</code>, and
<code>--case-sensitive</code>.

Exactly one entry must be selected. Multiple name/search matches open a
single-selection prompt on a controlling terminal. Without a terminal, the
command fails with code 2 and requires an exact ID or index. There is no
implicit bulk-delete mode.

Deletion requires confirmation unless <code>--yes</code>. That flag skips
confirmation only after one entry is identified. It never changes selection
scope.

The operation removes the entry and adds/updates a tombstone with ID, exact
text hash, current time, and this CLI machine name.

Default stdout is empty; a concise deletion result goes to stderr unless quiet.
With <code>--json</code>, stdout contains the removed entry ID, its former
filtered index, kind, and the written tombstone.

### 7.11 Interactive commands

~~~text
clipman-cli menu [-n COUNT | --all] [--kind ...] [--pinned-first]
clipman-cli pick [-n COUNT | --all] [--kind ...] [--pinned-first]
~~~

Only the line renderer exists. **Deferred:** <code>--renderer line|tui</code>,
the <code>--tui</code> and <code>--line</code> aliases, and config-driven
renderer selection all arrive with section 8.2. Until then <code>renderer</code>
in config accepts <code>line</code> only, and neither command takes positional
arguments.

<code>menu</code> rejects <code>--json</code>: it is a conversation, not a
data format.

All prompts and interface drawing use the controlling terminal. Stdout is
reserved for a selected clip's Text. Therefore these remain composable:

~~~sh
clipman-cli pick | ssh web-02 'cat > /tmp/snippet'
clipman-cli menu | some_command
~~~

If no controlling terminal exists, interactive commands fail with code 2
instead of mixing prompts with payload output.

### 7.12 Synchronization and status

~~~text
clipman-cli sync [--json]
clipman-cli status [--json] [--refresh]
~~~

**Shipped.** <code>sync</code> downloads, decodes, and validates the current
database, then reports the entry count or says plainly that no database exists
for this token and history password — because an absent bucket usually means a
mistyped password rather than an empty history, and "history is current" would
hide that. Its JSON object carries <code>revision</code>,
<code>database_exists</code>, <code>entries</code>, and
<code>uploaded</code>, which is always <code>false</code> today.

<code>status</code> reports the server URL, the 8-character bucket fingerprint,
whether the database exists, its revision and length, and the server health
object. <code>--refresh</code> additionally downloads and counts entries;
without it, <code>entries</code> stays <code>null</code> in JSON so a consumer
cannot mistake "not counted" for zero. Unlike the original design, status always
makes a network request, since there is no local cache to report on.

**Deferred with the daemon:**

~~~text
clipman-cli daemon run
clipman-cli daemon start
clipman-cli daemon stop
~~~

<code>daemon run</code> stays in the foreground for systemd, launchd-like
supervision where supported, or Windows service wrappers.
<code>daemon start</code> launches a per-user background process.

Once the daemon exists, <code>sync</code> forces immediate download, merge,
pending-operation replay, and upload; if work remains because the server is
unreachable it exits 4 without discarding pending work, and its JSON gains
pending count, freshness, and any redacted error. <code>status</code> gains
daemon reachability, cache freshness, last successful sync, last error, pending
operation count, and oldest pending age, and stops requiring a network request
unless <code>--refresh</code> is supplied.

---

## 8. Interactive accessibility

### 8.1 Line renderer

Line mode is the only mode. It lives in <code>internal/ui/line</code> behind a
<code>Store</code> and a <code>Console</code> interface, so the whole interface
is drivable from a test that records every announced line.

~~~text
Clipman line interface. Type ? for commands.
Clipman history: 42 entries.
Page 1 of 3, entries 0 to 19.
0. kubectl get pods -A; group ops; from win-desktop; used 3m ago
1. deploy runbook; pinned; group ops; from web-01; used 1h ago
Command (? for help):
~~~

Each row is a complete labeled sentence with a relative time, because a row
heard on its own carries no column headers. An empty field is announced as a
dash rather than as silence. Counts agree with their nouns.

Command set: <code>NUMBER</code> view, <code>o NUMBER</code> emit and exit,
<code>d NUMBER</code> delete after confirmation, <code>/TEXT</code> search,
<code>/</code> clear search, <code>n</code>/<code>p</code> page,
<code>a</code> add, <code>r</code> reload, <code>u</code> (also <code>ui</code>,
<code>renderer</code>) switch interface, <code>v</code>/<code>w</code>/<code>x</code>
<code>NUMBER</code> read, save, and run (section 8.4), <code>?</code> help,
<code>q</code> quit. The search prefix is handled before the command is split
on whitespace, so search text may contain spaces.

A bare <code>NUMBER</code> opens the paged reader rather than announcing the
whole clip. It used to call <code>Console.Say(b.text(entry))</code>, so a
five-thousand-line clip arrived as one unstoppable announcement with no way to
slow down, go back, or leave — the listening equivalent of a wall of text with
no scrollbar, in the interface built for listening.

Viewing, prompts, selection, and errors remain on the terminal. Only
<code>o</code> or the final <code>pick</code> result writes payload text to
stdout. A template is resolved before it is viewed or emitted.

**The view is loaded once.** A network round trip per command turns list
navigation into a stall on every keystroke, which is worst for exactly the
users this renderer exists for. <code>Store.Load</code> runs when the browser
opens and on explicit <code>r</code>; a delete or add updates the in-memory list
and re-sorts it through <code>operation.SortView</code> rather than downloading
the database to observe a change the client just made.

Indices are positions in the filtered view, not in the page, so a number stays
valid across paging. <code>-n</code> sets the page size for <code>menu</code>
rather than truncating the list — the previous behavior made entries past the
limit unreachable — and <code>--all</code> disables paging.

New-entry input terminates on a lone <code>.</code>, escapes a literal period
line as <code>..</code>, and cancels on <code>!cancel</code>. The clip joins the
kind being browsed.

**Still deferred within the line renderer:** save-to-file (<code>s</code>). If
added it must refuse overwrite unless explicitly confirmed. Any pipe-to-command
action must avoid implicit shell parsing; omit it rather than define an
injection-prone mini-shell.

### 8.2 TUI renderer — shipped

The TUI uses tcell and remains pure Go. It provides a scrollable list, live
filter, preview, kind switching, and accessible action labels.

It lives in <code>internal/ui/tui</code> and is a second renderer over the same
model, not a second program: rows come from <code>output.Describe</code> and it
drives the same <code>Store</code>, so an entry is described identically in
both renderers. The <code>Store</code> interface is redeclared locally rather
than imported from <code>line</code>, so neither renderer depends on the other.

<code>Run</code> owns the terminal lifecycle — Init, deferred Fini, panic
recovery — and delegates to an unexported <code>loop</code> that runs against an
already-initialized screen. That split exists so behavior can be asserted while
the screen is still readable; finalizing it clears both its contents and its
size.

Keys: arrows, Page Up/Down, Home/End navigate; <code>g</code> goes to an entry
by number; Enter emits and exits; <code>/</code> filters live with Escape to
clear; Tab cycles history → templates → all; <code>d</code> deletes after
confirmation and is refused under <code>pick</code>; <code>r</code> reloads;
<code>u</code> switches to the line interface after a <code>y</code>
confirmation and is refused under <code>pick</code>; <code>v</code> reads the
whole clip, <code>w</code> saves it, <code>x</code> runs a program on it
(section 8.4); <code>?</code> shows keys; <code>q</code> or Escape quits.

Layout rows are heading, status, preview label, preview, then the list from row
four. A diagnostic row above the list was removed once the caret was proven and
the file trace existed: it cost one entry row on every session for something
almost nobody enables.

Prompts are editable rather than backspace-only. <code>promptEditor</code> holds
the typed line and a caret offset within it, <code>promptParts</code> returns
that offset, and <code>caretPosition</code> uses it, so the caret rests on the
character being edited and moving back through a line reads it out. Left, Right,
Home, End, Delete, Ctrl+U, Ctrl+A, and Ctrl+E work in every prompt through one
shared <code>editPrompt</code>. Correcting a forty-character command line by
destroying everything after the mistake is the cost this removes.

### 8.3 Switching interface, and saying which one you are in

Two interchangeable interfaces shipped with nothing naming the one you were in,
so a user had no reason to suspect the other existed. That is a discoverability
defect and it cost a debugging session: the line interface's prompt cursor was
mistaken for a full-screen caret bug, and the fix was attempted in the renderer
that was not running. Top-level help asserting <code>menu — Open the accessible
line-based history manager</code> was the proximate cause; it was wrong whenever
<code>renderer = "tui"</code>.

Each interface therefore names itself on entry — <code>Clipman line
interface</code> in the greeting, <code>Full-screen interface</code> on the
status row — and <code>status</code> reports the configured one as
<code>Interface:</code> and as <code>interface</code> under <code>--json</code>,
which answers the question without opening either.

<code>u</code> moves between them, after a confirmation in both directions:
tcell clears whatever the line interface printed the moment it initializes, so a
message announced on the way out cannot be relied on to be heard, while a
question that must be answered is certain to have been read.

<code>internal/ui/handoff</code> carries <code>{Selected, Filter, Kind}</code>
across, returned as an error because that is the only channel a browser has back
to its caller and matched with <code>errors.As</code> at every interception
point. The whole screen changes under someone who cannot see it, so arriving at
the top of an unfiltered list is how a person loses their place; the full-screen
interface lands the caret on the carried row, and the line interface, having no
caret to land, says <code>You were on entry 12.</code> instead. Kind travels
because Tab can change it in one interface and the other cannot.

Three failure modes are deliberate. The screen is created before the choice is
saved, so a terminal that cannot run the full-screen interface costs no session
and no setting. A configuration file that cannot be written costs the saved
preference, not the session. <code>pick</code> refuses to switch on both sides:
it offers one choice and exits, so switching out would strand the user in a
picker with no way back, and saving a preference as a side effect of
<code>pick | ssh host</code> would be a surprise write to a file holding a
credential.

The already-downloaded database is handed to the interface being started
(<code>cliStore.handOver</code>, consumed once so <code>r</code> still reaches
the server). Without it the screen is torn down and then goes silent through a
download and a PBKDF2 decrypt, with nothing to explain the gap.

**Cursor placement is one rule, revised after real-terminal testing.** The
caret goes in whatever the user is moving through or typing into, because a
screen reader reads the line the caret is on:

- moving through the list keeps the caret at column zero of the selected row;
- a question puts the caret at the end of the typed answer, on the **same line**
  as the question, so the line reads <code>Go to entry number: 12</code> and the
  user hears both the question and their answer so far.

`promptParts` is the single place that pairs a question with its answer, so
every prompt inherits the behavior rather than re-deriving it.

The first implementation instead handed the caret to the status line for one
draw after any message, to get the message announced. On a real terminal that
read as the caret being stuck outside the list: the opening heading is a
message, so the caret started off the list, and every delete, filter change,
and kind switch threw it off again. Knowing where you are in a list is worth
more than hearing a confirmation.

Selection is additionally carried in the row text as a <code>-&gt;</code>
marker, with unselected rows indented to match. Reverse video alone tells a
screen reader nothing and is lost in review-mode navigation.

**Layout order and redraw budget** are accessibility constraints, not cosmetics,
and both came out of real-terminal testing.

tcell buffers a frame and emits only changed cells, scanning top to bottom, so
a line's position on screen — not the order of draw calls — decides when its
text reaches the terminal. The heading, status line, and preview therefore sit
*above* the list, which runs to the bottom of the window, making the entry rows
the last text written on every frame. With the status line at the bottom, every
redraw ended by writing it, which is the most likely explanation for it being
read out repeatedly no matter where the caret was.

Everything redrawn is resent to the terminal and so to a screen reader, so the
renderer redraws as little as it can:

- lines are rewritten individually and padded to the width instead of clearing
  the screen, since rewriting identical text costs nothing through tcell's diff
  while a screen-wide clear risks resending everything;
- the selected row carries **no** reverse video. A style change across a row
  makes every character of it dirty, so one arrow key would resend two entire
  rows; only the three-cell marker is highlighted.

An arrow key therefore changes the two markers and the preview line, and
nothing else — a budget enforced by test rather than left to intent. Paging,
scrolling, filtering, and reloading must repaint the list; the requirement
there is only that the caret ends on the selected row afterwards.

On every selection change:

- the real terminal cursor moves to column zero of the selected row;
- the cursor remains visible by default; and
- each row is a complete spoken description rather than a visual-only marker.

There is no claim of portable automatic screen-reader detection. Users select
line mode explicitly through config, <code>--line</code>, or an environment
setting documented for deployment. If tcell cannot initialize the requested
terminal, the command explains the failure and offers line mode; it does not
silently change output semantics.

Simulation-screen tests assert cursor position, complete row text, focus order,
and restoration of terminal state after exit or panic.

---

### 8.4 Reading, saving, and running a clip

Both interfaces offer the same three things on the selected entry, and they are
the same code underneath, so a clip behaves identically in each.

**Reading.** The full-screen interface opens a viewer with <code>v</code>; the
line interface opens a paged reader with a bare number or <code>v NUMBER</code>.
Line motion is primary in the viewer even though Page Up/Down, space, and
<code>b</code> page: a page key repaints the content area and resends a
screenful of text to a screen reader, while an arrow rewrites two markers. Rows
are numbered by logical line so position is spoken as part of the row the caret
lands on rather than announced separately, and continuation rows of a wrapped
line use <code>+</code> instead of <code>.</code>. Position is held as a logical
line, never a row index, so re-wrapping on a resize leaves the reader on the same
text. Help renders through the same viewer, which is what stopped it being
clipped once the key list outgrew a standard terminal.

Clip text passes through <code>output.PlainLines</code> in both interfaces: line
endings normalised so a stray carriage return cannot move the cursor
mid-announcement, tabs expanded because a terminal's own tab handling moves the
cursor without the program knowing, and control characters shown in caret
notation rather than dropped — dropping them would make what is displayed
disagree with what <code>w</code> writes and Enter emits.

**Saving** (<code>w</code>) writes verbatim through <code>internal/clipfile</code>:
no added newline, mode <code>0600</code> because a clip may be a credential, a
leading <code>~/</code> expanded because there is no shell to do it, and a
directory refused with a sentence rather than the operating system's message. A
new path is not confirmed — it was typed, and typing is deliberation — but an
existing one is, because that is the only branch which destroys something the
user did not name.

**Running** (<code>x</code>) has no shell anywhere.
<code>internal/clipexec</code> splits the typed line into argv, the clip
replaces whole arguments that are never re-split, and <code>os/exec</code> runs
the result. A clip is untrusted data: substituting it into a command string for
<code>sh -c</code> would mean a clip containing <code>; rm -rf ~</code> ran when
the user asked to echo it. Unquoted shell operators, and the spellings
<code>{}</code>, <code>{clip}</code>, <code>$clip</code>, <code>%clip%</code>,
are refused with an explanation rather than passed through, because quoting is a
clean escape hatch so a refusal fires only on the real mistake. The placeholder
is <code>@clip</code> and must be an argument on its own; with none present the
clip is piped to standard input.

A child process never receives <code>os.Stdout</code>. That stream may be a pipe
belonging to the user — <code>pick --tui | ssh host 'cat &gt; f'</code> has one —
and child output written into it would be injected into the payload and corrupt
the file at the far end. Output is captured, capped at 1 MiB, and presented in
the viewer, because the alternate screen is repainted on return and anything
printed to the terminal would be gone: one unrepeatable pass at output with no
scrollback. The exit status is always reported, including for a command that
printed nothing, which must not read as never having run. The clip never travels
in an environment variable.

In the full-screen interface the command runs on a goroutine and reports back by
posting an event, so the loop keeps turning and Escape stops a program that will
not finish; a still-running command says so every ten seconds with a changing
number, since an identical line would be redrawn into identical cells and never
spoken again. The line interface runs it synchronously — there is no event loop
to keep alive, and Ctrl+C is the terminal's own way out.

**Announcing completion.** The caret returns to the row being read, by design,
so a status line written on the way past is very likely never spoken. That is
tolerable for "reloaded" and not for "was my file written" or "was that entry
deleted". Both are held in a mode whose prompt is the message, which puts the
caret on it and costs one keypress on the branches that matter.

**<code>pick</code> allows <code>v</code> and refuses <code>w</code> and
<code>x</code>.** The principle is that pick has exactly one output and its
caller chose it. Confirming which clip is about to go down the pipe is what pick
most needs; writing a file the pipeline knows nothing about is not that output,
and an arbitrary-program affordance reachable from inside a pipeline stage is a
wider surface than the same key in an interactive menu.

**Windows.** With no shell, a <code>.cmd</code> or <code>.bat</code> target
needs its interpreter named (<code>x cmd /c mytask.cmd</code>), and Go 1.19+
removed the working directory from <code>LookPath</code>, so a program there
needs an explicit path. Both are documented rather than left to fail
cryptically.

## 9. Merge and normalization

### 9.1 Tombstones

Desktop-compatible normalization:

- discard null markers and markers with blank IDs;
- trim marker IDs;
- retain markers no older than 90 days;
- group by ID and keep the greatest DeletedUnixMs;
- fill a missing TextHash from another marker for the same ID;
- normalize null TextHash and SourceMachine to empty strings; and
- sort deterministically by DeletedUnixMs descending, then ID.

The Windows and macOS clients differ on a zero DeletedUnixMs. The CLI follows
macOS and assigns the normalization time, because retaining zero forever defeats
the documented 90-day policy. This is a deliberate, tested exception.

After tombstone union, remove any entry whose exact ID or lowercase exact
TextHash is covered.

### 9.2 Entry union

For each incoming nonempty-Text entry not covered by a tombstone:

1. match an existing entry by ID, using case-insensitive comparison because
   generated IDs are hexadecimal and casing must not create duplicates;
2. otherwise match by exact Text;
3. otherwise clone the incoming entry, including IsTemplate and unknown fields.

Case-insensitive ID matching is a deliberate robustness choice where Windows
and macOS currently differ.

When IDs match but Text differs, preserve the target Text, matching desktop
merge behavior. Text editing is not silently inferred from timestamp metadata.

### 9.3 Metadata merge

For a matched entry:

~~~text
incoming_wins         = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs
incoming_created_wins = incoming.CreatedUnixMs > existing.CreatedUnixMs
~~~

- LastUsedUnixMs becomes the larger value.
- CreatedUnixMs follows the desktop condition:
  use incoming when it is positive and existing is zero, incoming is newer, or
  incoming is older while the existing side wins LastUsed.
- A nonblank incoming Name or Group replaces the target only when incoming wins.
- A nonblank incoming SourceMachine replaces the target when incoming wins or
  incoming_created_wins.
- Pinned is sticky true.
- IsTemplate is not changed on a matched entry, reproducing shared
  Windows/macOS behavior. Android/iOS currently make it sticky; that divergence
  is covered by fixtures and called out in release notes.
- ManualOrder becomes the smaller positive value, treating nonpositive as unset.
- Unknown fields are unioned without overwriting a known field; on unknown-field
  conflicts, the more recently used side wins.

Blank metadata does not clear an older nonblank desktop value.

### 9.4 Final normalization

After merging:

- apply tombstones again;
- remove entries with empty Text;
- repair IDs and zero timestamps;
- retain relative manual ordering, with unset values last and CreatedUnixMs as
  tie-breaker;
- renumber ManualOrder from 1;
- set Version to at least 1 while preserving a higher source value;
- set UpdatedUnixMs to the operation time; and
- preserve deterministic output ordering independent of map iteration.

---

## 10. Synchronization

### 10.1 Stateless read

GET, size-limit, decode, normalize in memory without writing, filter, and emit.
A missing bucket is empty history. Read-only commands never upload normalization
changes merely because they observed older data.

### 10.2 Operation intents

**Partly deferred.** The shipped engine represents a mutation as a Go closure
passed to <code>syncengine.Engine.Mutate</code>, re-executed against freshly
downloaded state on each conflict retry. That gives retries the same reapplied
semantics without a serializable intent: <code>put</code> preassigns its new ID
before the first attempt, and one mutation timestamp is captured before the
loop and reused by every retry. The serializable form below is required only
once operations must outlive the process, which is a daemon concern.

Every mutation is represented as an immutable operation intent with:

- random operation ID;
- kind: put-ignore, put-movetotop, put-keep, touch, or delete;
- original mutation timestamp;
- target ID and/or exact text/hash as required;
- new entry ID for keep/new operations;
- requested metadata; and
- originating machine.

Retries reapply the same intent and timestamp. They do not create another ID,
advance time, or broaden a selection.

Delivery metadata is separate from the immutable intent. In particular, a
delete that remains pending beyond the desktop's 90-day tombstone window is
not silently discarded: before its next upload attempt, the daemon durably
assigns one refreshed replay tombstone timestamp and reuses that value for all
retries. The original deletion time remains recorded for status and recovery.

### 10.2.1 Shipped retry behavior

<code>Engine.Mutate</code> reads, normalizes, applies the mutation, normalizes
again, encodes, and uploads. A mutation reporting no change returns without a
PUT. On <code>ErrConflict</code> it sleeps <code>30 + attempt*40</code>
milliseconds and retries up to <code>Retries</code> times, default 3.
Exhaustion returns "database changed repeatedly; operation was not committed"
wrapping the conflict, which surfaces as exit code 1. The backoff is fixed, not
jittered; adding jitter is a reasonable small improvement.

### 10.3 Existing-bucket write

1. GET current blob and revision R.
2. Decode and normalize.
3. Apply the operation intent.
4. If the intent is a no-op, return success without PUT.
5. Encode and PUT with <code>If-Match: "R"</code>.
6. On success, verify the returned revision and finish.
7. On 409/412, back off with jitter, GET the new revision, reapply the same
   intent, and retry up to the configured limit.
8. Exhaustion returns code 1 and preserves a daemon pending operation.

Delete and touch do not resurrect a remotely deleted entry. A keep/new operation
uses its preassigned ID across retries. Move-to-top re-finds exact Text.

### 10.4 Missing-bucket write

**Shipped, conditional branch.** A write against a bucket that did not exist at
read time sends <code>If-None-Match: *</code> and no <code>If-Match</code>. The
server answers 412 if another client created it first, which the client maps to
<code>ErrConflict</code> and rebases exactly like an ordinary revision conflict.
The compatibility branch is not implemented and is not needed.

### 10.5 Daemon local-first writes — deferred

Sections 10.5 through 10.7 describe unbuilt work. No cache, pending queue, IPC
endpoint, or <code>CLIPQ</code> container exists in the tree.


The pending queue uses a private, versioned container:

~~~text
CLIPQ01 = ASCII "CLIPQ01" || gzip(UTF-8 PendingQueue JSON)
CLIPQ02 = ASCII "CLIPQ02" || the CLIPDB2 version/salt/IV/ciphertext/HMAC layout
~~~

<code>CLIPQ02</code> uses the same password, PBKDF2 parameters, authentication
order, and limits as CLIPDB2. Since every profile now has a password,
<code>CLIPQ02</code> is the only form the daemon should write; the
<code>CLIPQ01</code> container is reserved but unused. PendingQueue contains
Version, AccountId, UpdatedUnixMs, and an ordered Operations array of the
immutable intents from section 10.2. Unknown queue versions or a mismatched
AccountId fail closed.

For a daemon-backed mutation:

1. validate and authorize the local request;
2. atomically rewrite the protected pending queue with the added intent and
   durably flush the file and containing directory;
3. apply it to the local cache;
4. atomically save and durably flush the cache;
5. only then acknowledge success;
6. attempt network synchronization immediately; and
7. retain the intent until a server state containing it is confirmed, then
   atomically rewrite the queue without that intent.

If a crash occurs after queue flush but before cache save, startup replay repairs
the cache. If cache save completed but acknowledgement was lost, the same
request ID retrieves the recorded result. Request and operation IDs make all
replay idempotent.

Cache and pending-queue data are authenticated-encrypted with the history
password, in addition to owner-only filesystem protection.

A password or token change produces a different account identity. Pending work
is never silently sent to the new account. The CLI requires the old account to
sync, or an explicit reviewed migration/export operation, before removing its
queue and cache.

### 10.6 Daemon reads and freshness

Daemon reads serve the local committed view. The daemon HEAD-polls while online
and records the last verified revision and time. Default freshness target is
two seconds while active, with backoff after failures.

Offline or stale reads still succeed from cache but emit a concise stderr
freshness warning unless quiet. JSON output includes freshness metadata in a
wrapper rather than corrupting the entry object.

### 10.7 Daemon discovery and fallback

The client performs a handshake containing protocol version, account identity,
config fingerprint, and request ID. It uses a daemon only for the exact
effective profile. Per-command server/password overrides bypass a mismatched
daemon.

Safe read-only requests may fall back to stateless mode after connection failure.
A mutation whose completion is uncertain must not be replayed statelessly; the
client reconnects with the same request ID or reports an indeterminate local
daemon error.

The newline-delimited JSON socket example in the earlier draft is replaced by a
versioned, length-limited protocol:

~~~text
uint32 big-endian payload length
UTF-8 JSON payload
~~~

The default payload limit is 1 MiB; large clip bodies use a separately bounded
stream frame rather than unbounded JSON allocation. Every request contains
<code>ProtocolVersion</code>, <code>AccountId</code>,
<code>RequestId</code>, <code>Operation</code>, and typed arguments. Every
response repeats RequestId and contains <code>Ok</code>, a stable local error
code, freshness/pending metadata where relevant, and typed result data.
Unsupported protocol versions fail before processing. The complete schema and
compatibility policy are committed with the daemon implementation.

---

## 11. Project layout

Actual layout, with deferred packages marked:

~~~text
ClipmanCli/
  cmd/clipman-cli/main.go        + main_test.go
  internal/model/                model.go, file_history.go
  internal/clipdb/               CLIPDB1/CLIPDB2 codec
  internal/identity/             bucket ID derivation
  internal/config/               restricted TOML subset
  internal/server/               HTTP client, URL/token/CA parsing
  internal/merge/                merge, normalization, ID generation
  internal/operation/            kinds, selectors, put/delete/touch
  internal/syncengine/           read + optimistic mutate
  internal/template/             template variable resolution
  internal/platform/             paths, console, DPAPI; _unix/_windows files
  VERSION
  build.sh
  Build.ps1
  go.mod
  go.sum
  Manual.html
  clipman-cli.1

  internal/output/               pure formatting, no I/O
  internal/ui/line/              line browser behind Store/Console interfaces
  internal/ui/tui/               tcell renderer, same Store and row text
  internal/daemon/               deferred with section 10.5
  testdata/                      deferred with section 14.1
~~~

One departure worth noting: platform code is split by build-tagged files in a
single <code>internal/platform</code> package rather than <code>unix/</code> and
<code>windows/</code> subpackages.

<code>internal/output</code> is deliberately pure — every function takes the
current time as an argument and returns a string, so the exact bytes a screen
reader announces are assertable. <code>internal/ui/line</code> depends on
<code>Store</code> and <code>Console</code> interfaces rather than on the sync
engine and the terminal, which is what makes the transcript tests possible and
what a second renderer would reuse.

<code>internal/model/file_history.go</code> and the
<code>DecodeFileHistory</code>/<code>EncodeFileHistory</code> codec functions
are inherited from the <code>ClipmanLinuxBackend</code> fork and are unreachable
from any command. File-list history remains a non-goal. Keep them in step with
the backend or delete them deliberately; do not let them rot silently.

The Go directive is 1.25.0 and would be raised only if a pinned tcell release
required it. Prefer standard <code>crypto/pbkdf2</code>; HMAC-SHA1 is passed
explicitly.

Current dependencies are <code>golang.org/x/term</code>,
<code>golang.org/x/sys</code>, and <code>github.com/gdamore/tcell/v2</code> for
the TUI, which brings <code>gdamore/encoding</code>,
<code>lucasb-eyer/go-colorful</code>, <code>rivo/uniseg</code>, and
<code>golang.org/x/text</code> indirectly. None uses cgo. The TOML library and
secret-store package the original draft anticipated were avoided by
hand-writing the config parser and dropping keyring support.

UUID generation uses the standard random source directly. No dependency may
introduce cgo without revisiting the build matrix — every target builds with
<code>CGO_ENABLED=0</code>.

---

## 12. Build and packaging

### 12.1 Supported targets

Seven targets ship, each in its own directory so the binary keeps its plain
name on every platform:

| Target | Artifact |
|---|---|
| Windows amd64 | <code>windows-amd64/clipman-cli.exe</code> |
| Windows arm64 | <code>windows-arm64/clipman-cli.exe</code> |
| Linux amd64 | <code>linux-amd64/clipman-cli</code> |
| Linux armv7 | <code>linux-armv7/clipman-cli</code> |
| Linux arm64 | <code>linux-arm64/clipman-cli</code> |
| macOS amd64 | <code>macos-amd64/clipman-cli</code> |
| macOS arm64 | <code>macos-arm64/clipman-cli</code> |

This supersedes the original four-target flat list, which named binaries
<code>clipman-cli-&lt;os&gt;-&lt;arch&gt;</code>. macOS and Windows arm64 were
promoted out of section 18's deferred list.

WSL uses Linux amd64. Raspberry Pi hardware older than ARMv7 requires a
separately advertised GOARM=6 artifact; the ARMv7 label must not claim support
for every Raspberry Pi. Running locally under Android/Termux is not implied by
the Linux artifacts and requires separate testing.

Both build scripts run <code>go test ./...</code> and <code>go vet ./...</code>
before compiling. The PowerShell entry point is <code>Build.ps1</code>, capital
B, not <code>build.ps1</code>.

### 12.2 Correct Bash pattern

~~~sh
#!/usr/bin/env bash
set -euo pipefail

ver=$(git describe --tags --always 2>/dev/null || echo dev)
ldflags="-s -w -X main.version=$ver"
mkdir -p dist

build() {
  local goos="$1" goarch="$2" goarm="$3" output="$4"
  if [[ -n "$goarm" ]]; then
    env CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" GOARM="$goarm" \
      go build -trimpath -ldflags "$ldflags" -o "dist/$output" ./cmd/clipman-cli
  else
    env CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -ldflags "$ldflags" -o "dist/$output" ./cmd/clipman-cli
  fi
}

build linux amd64 "" clipman-cli-linux-amd64
build linux arm 7 clipman-cli-linux-armv7
build linux arm64 "" clipman-cli-linux-arm64
build windows amd64 "" clipman-cli-windows-amd64.exe

(
  cd dist
  LC_ALL=C sha256sum \
    clipman-cli-linux-amd64 \
    clipman-cli-linux-armv7 \
    clipman-cli-linux-arm64 \
    clipman-cli-windows-amd64.exe |
    LC_ALL=C sort > SHA256SUMS
)
~~~

Do not generate an assignment through parameter expansion; Bash treats the
expanded <code>GOARM=7</code> word as a command rather than an environment
assignment.

### 12.3 PowerShell build

The PowerShell script uses scoped environment restoration and the same explicit
target list. The central pattern is:

~~~powershell
$ErrorActionPreference = 'Stop'
$version = (git describe --tags --always 2>$null)
if (-not $version) { $version = 'dev' }
$ldflags = "-s -w -X main.version=$version"
$targets = @(
    @{ os='linux';   arch='amd64'; arm='';  out='clipman-cli-linux-amd64' },
    @{ os='linux';   arch='arm';   arm='7'; out='clipman-cli-linux-armv7' },
    @{ os='linux';   arch='arm64'; arm='';  out='clipman-cli-linux-arm64' },
    @{ os='windows'; arch='amd64'; arm='';  out='clipman-cli-windows-amd64.exe' }
)

New-Item -ItemType Directory -Force dist | Out-Null
$saved = @{
    CGO_ENABLED = $env:CGO_ENABLED
    GOOS = $env:GOOS
    GOARCH = $env:GOARCH
    GOARM = $env:GOARM
}
try {
    foreach ($target in $targets) {
        $env:CGO_ENABLED = '0'
        $env:GOOS = $target.os
        $env:GOARCH = $target.arch
        if ($target.arm) { $env:GOARM = $target.arm }
        else { Remove-Item Env:GOARM -ErrorAction SilentlyContinue }
        & go build -trimpath -ldflags $ldflags -o "dist/$($target.out)" ./cmd/clipman-cli
        if ($LASTEXITCODE -ne 0) { throw "build failed: $($target.os)/$($target.arch)" }
    }
}
finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$name" $saved[$name] }
    }
}

$records = foreach ($target in $targets) {
    $hash = (Get-FileHash "dist/$($target.out)" -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($target.out)"
}
$lf = [char]10
$manifest = (($records | Sort-Object) -join $lf) + $lf
[IO.File]::WriteAllText(
    (Join-Path (Resolve-Path dist) 'SHA256SUMS'),
    $manifest,
    [Text.UTF8Encoding]::new($false)
)
~~~

It fails immediately on any nonzero Go exit code. Production scripts build into
a fresh staging directory under <code>dist</code> and publish only after all
targets succeed; the compact example above focuses on correct target/environment
handling.

Checksums are computed from an explicit ordered artifact list. Existing
<code>SHA256SUMS</code>, stale binaries, directories, and unrelated files are
never included. Both scripts write lowercase hashes, two spaces, filename, LF,
and a final LF so the checksum manifest is reproducible.

### 12.4 Release gates

For every target:

- cross-build succeeds with <code>CGO_ENABLED=0</code>;
- the binary starts and prints version/help on the target OS or emulator;
- codec and identity fixtures pass on the target;
- Windows ACL, credential, console, and IPC tests pass on Windows;
- the binary has no unintended dynamic runtime dependency;
- generated checksums verify; and
- help/manual command tables match.

---

## 13. Security requirements

- Authenticate encrypted data before decryption or decompression.
- Use constant-time MAC comparisons and OS cryptographic randomness.
- Enforce compressed, decompressed, JSON, entry, text, IPC, and HTTP limits.
- Never log secrets, bucket IDs, clip text, journal contents, or auth headers.
- Treat <code>--password</code>, <code>--token</code>, and
  <code>--text</code> as process-list exposure risks in help.
- Protect Unix files by ownership and mode and Windows files by DACL.
- Reject unsafe symlink/reparse-point paths.
- Authenticate daemon peers and namespace endpoints by user and account
  (deferred with the daemon).
- Use request IDs and durable queue-before-cache ordering before acknowledging
  offline writes (deferred with the daemon).
- Bound conflict retries and network backoff.
- Refuse to follow a redirect that changes scheme or host, so bearer credentials
  never reach another origin.
- Warn on every run when TLS verification is disabled, and require an
  out-of-band fingerprint comparison before trusting a private authority
  interactively.
- Explain that the token/password combination provides confidentiality and
  bucket discovery, while stolen authorization or bucket metadata may still
  enable corruption or denial of service.
- Do not provide an interactive arbitrary shell-command action without a
  separately reviewed execution and quoting design.

---

## 14. Testing

Current state: Go unit tests cover the codec, identity, merge, operation,
config, server client, sync engine, template resolver, line UI, output
formatting, and CLI argument parsing, and all pass. The Windows half of 14.1 is
done; most of 14.3–14.6 is outstanding.

### 14.1 Interoperability — Windows done, others outstanding

The corpus lives in <code>ClipmanCli/testdata/fixtures/&lt;generator&gt;/</code>
and is documented by its own README. Generators are discovered rather than
listed, so adding a directory brings it into every test with no Go change, and
tests skip cleanly when the corpus is absent.

Done:

- CLIPDB1 and CLIPDB2 fixtures from Windows, generated by
  <code>tools/ClipmanFixtures</code> compiled against <code>src/</code> so the
  blobs come from the canonical <code>ClipDatabaseFile</code>.
- Identity vectors for ASCII, Unicode token, Unicode password, whitespace
  requiring trimming, and the empty-token and empty-password cases that have no
  bucket.
- Windows decrypts CLI-written blobs, via the generator's
  <code>verify</code> mode and <code>go test -clipman-export</code>.
- Awkward-text coverage: CRLF, LF, no trailing newline, trailing whitespace,
  NUL, Unicode, emoji, quotes, backslashes, and embedded JSON and HTML.
- Unknown-field preservation, proven with a Windows rich-text payload the CLI
  has no field for. Compared by meaning, not bytes: preserving a field does not
  oblige a client to reproduce another's whitespace or key order.
- Wrong-password and single-bit-tamper rejection on every encrypted fixture.
- Live-server round trip: the bucket directory the server creates matches the
  client-derived ID, and Windows reads the blob the CLI uploaded through HTTP.

Outstanding:

- macOS, Android, and iOS generators. Blocked on tooling, not design.
- Quoted and JSON token input vectors.
- Connection-file parsing: JSON and <code>Key: value</code> forms, version
  marker rejection, and private-authority validation failures.
- Desktop merge fixtures for timestamps, blank metadata, pins, templates,
  manual order, tombstones, and 90-day boundaries. The corpus carries tombstone
  *blobs* but does not yet assert merge *outcomes* across clients.
- Explicit tests and release notes for known desktop/mobile divergence.

### 14.2 Negative and resource tests

- Short container, unsupported version, empty/misaligned ciphertext, bad
  padding behind a valid/invalid MAC, corrupt gzip, invalid UTF-8, deep JSON,
  oversized download, decompression bomb, excessive entry count, and huge text.
- Fuzz container parsing, model normalization, porcelain escaping, and IPC framing.
- Ensure unauthenticated ciphertext never reaches AES/gzip processing.

### 14.3 Synchronization and concurrency

- Two writers against an existing revision retain both operations.
- Simultaneous initial creation proves no lost operation under the conditional
  branch. There is no second branch to test.
- Conflict retries preserve new entry ID and mutation timestamp.
- Concurrent delete beats touch and does not resurrect content.
- Duplicate modes match desktop behavior exactly.
- 401, 403, 404, 409, 412, 413, timeout, TLS, and 5xx mappings.

### 14.4 CLI and accessibility

- Byte-exact put/get UTF-8 round trips, including whitespace, CRLF, LF, NUL,
  and no-final-newline cases.
- <code>--newline</code> behavior with and without an existing LF.
- stdout contains payload only; terminal prompts never enter a pipe.
- JSON schemas and porcelain escapes are golden-tested.
- Ambiguous selectors and one-entry delete selection.
- History/template/all indices and pinned-first ordering.
- Line renderer screen-reader transcript tests.
- TUI cursor tracking, focus, terminal restoration, and panic recovery.

### 14.5 Filesystem, daemon, and platform — daemon items deferred

- Unix ownership/mode/symlink attacks and Windows ACL/reparse-point attacks.
- Alternate configs create distinct daemon endpoints.
- Mismatched overrides bypass the daemon.
- Queue-before-cache acknowledgement crash points and idempotent recovery.
- Offline put/delete, later merge/upload, pending status, and password rotation.
- A delete pending beyond 90 days receives one durable replay timestamp and
  still converges without changing ID or selection.
- Lost daemon response does not duplicate a keep operation.
- Windows named-pipe peer restrictions and Console/ConPTY behavior.

### 14.6 Build and documentation

- Execute all build targets in CI.
- Verify staged builds contain no stale artifacts.
- Generate and verify deterministic SHA256SUMS twice.
- Lint Markdown fences and links.
- Compare built-in help, manual, man page, and command metadata for drift.

---

## 15. Phased implementation plan

### Phase 0 — decision closure and fixtures — **partly done**

- ~~Resolve conditional initial creation.~~ Done: server supports
  <code>If-None-Match: *</code>; see section 2.3.
- **Outstanding:** freeze golden identity, codec, merge, and tombstone fixtures
  generated by the Windows, macOS, Android, and iOS clients.
- ~~Record approved desktop exceptions and mobile divergence.~~ Recorded in
  sections 9.1 and 9.3.

### Phase 1 — portable format and platform core — **done**

Model, codec, identity, normalization, limits; Unix and Windows protected config
paths and DPAPI secret protection; HTTP client with redaction, limits, timeouts,
and status mapping. TLS trust for private authorities (section 3.4) was added
here after the fact.

### Phase 2 — stateless CLI — **done**

<code>init get put list rm sync status</code>, selectors, kind filters, output
contracts, merge, optimistic uploads, and conditional initial create.

Outstanding from this phase's original exit gate: cross-client live-server
interoperability and concurrency tests. Go unit tests pass; nothing exercises a
real server against a real desktop client.

### Phase 3 — accessible interaction — **done, reduced scope**

Line <code>menu</code> and <code>pick</code>, controlling-terminal I/O
separation, template/history switching, single-entry delete selection. Search,
paging, multiline new-entry input, and later reading, saving, and running a clip
were all subsequently built. Nothing from this phase remains deferred: the
save-to-file affordance shipped as <code>w</code>, and the pipe-to-command one
as <code>x</code> with no shell (section 8.4). See section 8.1.

### Phase 4 — TUI — **done**

tcell renderer with physical-cursor tracking, kind filters, preview, and
actions; explicit renderer selection without screen-reader detection;
<code>renderer = "tui"</code> accepted in config;
<code>--renderer</code>/<code>--tui</code>/<code>--line</code> added. The
shared formatting seam was extracted in Phase 3, which is what made the second
renderer cheap.

Exit gate met for simulation and terminal restoration: 21 SimulationScreen
tests assert cursor position after navigation, cursor visibility, complete row
text, focus order, payload-only stdout, and exactly one Fini on both normal
exit and panic. All seven targets still cross-build with
<code>CGO_ENABLED=0</code>, and no dependency in the graph uses cgo.

Outstanding from the gate: the renderer has not been exercised on a real Linux
terminal or Windows console, only against a simulation screen.

### Phase 5 — daemon and offline synchronization — **not started**

- Per-account Unix socket and Windows IPC.
- Peer authorization and versioned request protocol.
- Protected cache, pending queue, idempotent request IDs, offline mutation,
  freshness polling, crash recovery, and enhanced status.
- Foreground/background lifecycle and service documentation.
- Serializable operation intents replacing today's closures (section 10.2).

Exit gate: crash-point, offline convergence, multi-account, and lost-response tests pass.

### Phase 6 — packaging and documentation — **partly done**

- ~~Bash and PowerShell build pipelines.~~ Done, seven targets.
- ~~HTML manual, man page, built-in help.~~ Done and currently in sync.
- **Outstanding:** supported-target smoke tests, deterministic checksum
  verification, CI execution of all build targets, help/manual drift checks, and
  installation packages.

### Recommended next steps

Ordered by value per unit of risk, for whoever picks this up next:

1. **Fixture corpus** (Phase 0 remainder). It is the one gap that can silently
   break cross-device sync, and every later phase is safer behind it.
2. ~~**Narrow the exit-code default** in <code>mapRuntimeError</code> from 4 to 1
   (section 7.2).~~ Done; see section 7.2.
3. ~~**Split <code>main.go</code>** into <code>internal/output</code> and
   <code>internal/ui/line</code>.~~ Done; it is what made the second renderer
   cheap.
4. ~~**Menu completeness** (section 8.1): search and paging.~~ Done, along with
   multiline add. Save-to-file remains deferred.
5. **CI** for build targets and checksums (Phase 6 remainder).
6. **Phase 4 or Phase 5**, whichever the users are actually asking for. They are
   independent; neither blocks the other.

Phases 2 and 3 are independently useful without a daemon, which is what ships
today.

---

## 16. Documentation deliverables

One command metadata source drives built-in help and reference tables.
Narrative Markdown drives the accessible HTML manual and man page. CI detects
drift rather than relying on manual synchronization.

Required artifacts:

1. <code>ClipmanCli/Manual.html</code>, matching project visual style while
   meeting semantic-heading, landmark, keyboard, contrast, zoom, and focus requirements.
2. <code>clipman-cli.1</code> with NAME, SYNOPSIS, DESCRIPTION, COMMANDS,
   OPTIONS, ENVIRONMENT, FILES, EXIT STATUS, EXAMPLES, SECURITY, and SEE ALSO.
3. Complete <code>--help</code> and per-command help.

Commands and output are real selectable <code>pre/code</code> text, never
terminal screenshots.

The manual must explain:

- that a nonblank history password is required, and that the server stores only
  blobs it cannot read;
- the inability to validate a password for a missing bucket;
- conditional initial create, which carries no residual race;
- Windows DPAPI versus Unix file-permission secret storage;
- trusting a privately issued server certificate, and what
  <code>--insecure</code> gives up;
- template filters, variable resolution, <code>--raw</code>, and index scoping;
- process-list exposure of secret-bearing flags; and
- exact exit-code handling.

Once the daemon ships, add offline success and pending synchronization. Until
then the manual must not imply that any command works without the server.

---

## 17. Corrected example bank

### 17.1 Put and get

~~~sh
printf '%s' 'kubectl rollout restart deploy/api -n prod' | clipman-cli put
clipman-cli put --file ./deploy-runbook.md --name deploy-runbook --group ops
clipman-cli put --text 'Hello' --template --name greeting

clipman-cli get
clipman-cli get 3 > snippet.txt
clipman-cli get --name deploy-runbook
clipman-cli get --search kubectl --first
clipman-cli get --kind templates --name greeting
clipman-cli get -n > with-final-lf.txt
~~~

### 17.2 Browse and select

~~~sh
clipman-cli list
clipman-cli list --kind templates
clipman-cli list --kind all --search postgres
clipman-cli list --porcelain
clipman-cli pick | ssh web-02 'cat > /tmp/snippet'
~~~

### 17.3 Delete one entry

~~~sh
clipman-cli rm 5
clipman-cli rm --id 0123456789abcdef0123456789abcdef --yes
clipman-cli rm --search 'old token'
~~~

If the search has several matches, the last command opens a one-choice selector.
In a script, use the selected ID and <code>--yes</code>.

### 17.4 Correct exit-code handling

~~~sh
set +e
text=$(clipman-cli get --name build-flag 2>/dev/null)
rc=$?
set -e

case "$rc" in
  0) printf 'flag is: %s\n' "$text" ;;
  6) printf '%s\n' 'no build-flag clip yet' ;;
  *) printf 'clipman failed with exit %s\n' "$rc" >&2; exit "$rc" ;;
esac
~~~

Do not pipe a clip into <code>source /dev/stdin</code> expecting it to modify
the calling shell; a pipeline normally runs that side in a subshell. If changing
the current shell is truly intended, review the clip and source a protected
temporary file explicitly.

### 17.5 Non-interactive initialization

~~~sh
CLIPMAN_TOKEN='token' CLIPMAN_PASSWORD='password' \
  clipman-cli --server 'https://clipman.example:52731' init \
  --non-interactive --save-password config
~~~

A password is always required; there is no passwordless form.

From a connection file, which also carries the server's private certificate
authority when it has one:

~~~sh
CLIPMAN_PASSWORD='password' \
  clipman-cli init --non-interactive \
  --connection-file ~/clipman-server-connection.clpconf
~~~

With a separately obtained CA certificate:

~~~sh
CLIPMAN_TOKEN='token' CLIPMAN_PASSWORD='password' \
  clipman-cli --ca-cert ./clipman-ca.pem \
  --server 'https://clipman.example:52731' init --non-interactive
~~~

### 17.6 Offline daemon workflow — deferred

Not available. Every command reaches the server; there is no local queue, and a
mutation attempted offline fails with exit code 4 rather than committing
locally. The intended workflow once section 10.5 ships:

~~~sh
clipman-cli daemon start
printf '%s' 'queued while offline' | clipman-cli put
clipman-cli status
clipman-cli sync
~~~

The put would succeed after durable local commit, and status would show it as
pending until a server state containing the operation is confirmed.

---

## 18. Deferred items

Deferred but planned, with a design in this document:

- The daemon, local cache, pending queue, and offline writes (sections 10.5–10.7).
- Line-renderer save-to-file (section 8.1).
- The cross-client fixture corpus (section 14.1).

Deferred with no current plan to build:

- Native binary/base64 clip types.
- File-list history and secrets database. The inherited
  <code>file_history</code> model and codec are unused; see section 11.
- Desktop clipboard monitoring or bridging.
- Bulk deletion by search.
- Arbitrary pipe-to-shell actions inside the interactive UI.
- Server administration and backup restoration.
- OS secret stores (Secret Service, Credential Manager), unless one can be added
  without cgo.

Withdrawn — passwordless operation, in every form: <code>CLIPDB1</code> writes,
the empty-password bucket, <code>--allow-passwordless</code>, and
<code>password_mode = "passwordless"</code>. Clipman Server requires a nonblank
history password.

Shipped since the original draft, formerly deferred: macOS and Windows ARM64
release artifacts.

Any future schema extension must preserve unknown fields and add cross-client
fixtures before the CLI writes it.
