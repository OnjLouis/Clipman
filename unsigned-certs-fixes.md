# Self-signed / untrusted TLS certificate support for clipman-cli

## Reported problem

Running `clipman-cli init` against a Clipman Server using a self-signed
certificate fails during the connection test with an OpenSSL/TLS trust
error (Go surfaces it as `x509: certificate signed by unknown authority`).
There was no way to make `init` (or any other command) trust that
certificate short of installing it into the OS-wide trust store.

## Root cause

`ClipmanCli/internal/server/client.go`, in `New(...)`, built the
`http.Transport` used for all server calls without ever setting
`TLSClientConfig`:

```go
transport := &http.Transport{DialContext: ..., ResponseHeaderTimeout: ..., TLSHandshakeTimeout: ...}
client := &http.Client{Transport: transport, Timeout: 30 * time.Second}
```

With no `TLSClientConfig`, Go falls back to full default certificate
verification against the OS trust store. There was no `--insecure`,
`--ca-cert`, `--skip-verify`, or equivalent anywhere in the codebase (grepped
`TLS|Insecure|SkipVerify|RootCAs|cacert` across `ClipmanCli/` — the only hit,
`IsInsecureRemoteURL`, is just the plain-HTTP warning banner, unrelated to
certificate trust). So a self-signed cert had no supported path to success;
this was a genuine gap, not user misconfiguration.

`runInit` in `cmd/clipman-cli/main.go` calls `client.Health(ctx)` right after
building the client (around the former line 389), which is where the TLS
handshake happens and the error surfaces.

## Fix

Added two independent ways to trust a self-signed/private cert, plus a way
to trust it system-wide as a no-code-change alternative (documented below
for reference, not implemented in code since it's an OS-level action):

1. **`--ca-cert FILE`** — trust one additional PEM-encoded certificate (the
   server's self-signed cert, or the CA that issued it), on top of normal
   verification. This is the recommended option: it doesn't disable
   verification, it just extends the trust anchor.
2. **`--insecure`** — disable TLS certificate verification entirely
   (`InsecureSkipVerify`). Quick, but appropriate only on a trusted private
   network; a warning is printed to stderr whenever it's used.

Both are **global flags** (parsed before the subcommand, same as `--server`
and `--password`), usable on `init` and on every other command
(`status`, `list`, `get`, `put`, `rm`, `sync`, `pick`, `menu`).

- On `init`, whichever option was used is **persisted to the config file**
  (`tls_insecure` / `ca_cert_pem` keys) so later commands don't need to
  repeat the flag.
- On any other command, passing `--insecure` or `--ca-cert` explicitly
  overrides whatever was persisted, for that invocation only.
- `--insecure` and `--ca-cert` are mutually exclusive; combining them is a
  `fail(2, ...)` usage error.
- `Validate()` in the config package rejects a config that somehow has both
  set, and rejects a `ca_cert_pem` value that doesn't parse as a valid PEM
  certificate.

## Files changed

### `ClipmanCli/internal/server/client.go`
- Added `crypto/tls`, `crypto/x509` imports.
- Added a small functional-options API so the existing zero-arg call sites
  (tests, etc.) kept compiling unchanged:
  ```go
  type Option func(*tlsSettings)
  type tlsSettings struct {
      insecureSkipVerify bool
      caCertPEM          []byte
  }
  func WithInsecureSkipVerify() Option { ... } // sets tls.Config.InsecureSkipVerify = true
  func WithCACertPEM(pem []byte) Option { ... } // adds pem to a new x509.CertPool used as tls.Config.RootCAs
  ```
- `New(rawURL, token, databaseID, version string, opts ...Option) (*Client, error)`
  now applies the resolved `tlsSettings` to `transport.TLSClientConfig`.
  `WithCACertPEM` returns an error from `New` if the PEM data has no
  parseable certificate.

### `ClipmanCli/internal/config/config.go`
- Added `Config.TLSInsecure bool` and `Config.CACertPEM string`.
- `Save()` always writes `tls_insecure = <bool>`; writes `ca_cert_pem = "..."`
  only when non-empty (same pattern already used for the optional saved
  password).
- `assign()` parses both keys back on `Load()`.
- `Validate()` rejects setting both at once, and rejects a `ca_cert_pem`
  that doesn't parse via `x509.NewCertPool().AppendCertsFromPEM`.

### `ClipmanCli/cmd/clipman-cli/main.go`
- `globals` struct gained `caCertFile string` and `insecure bool`.
- `parseGlobals` parses `--ca-cert VALUE` (same value-parsing helper used
  for `--config`/`--server`/`--password`) and the boolean `--insecure`.
- New helpers:
  - `readCACertFile(path string) ([]byte, error)` — reads the file, validates
    it parses as PEM, wraps errors with `fail(...)`.
  - `tlsOptionsForGlobals(g globals, cfg config.Config) ([]server.Option, error)`
    — resolves effective TLS options for a loaded context: explicit global
    flags win, otherwise fall back to whatever is persisted in `cfg`.
- `loadContext` (used by every command except `init`) now calls
  `tlsOptionsForGlobals` and passes the result into `server.New(...)`.
- `runInit`:
  - Rejects `--insecure` + `--ca-cert` together.
  - Prints a stderr warning when `--insecure` is used.
  - Reads/validates the CA cert file when `--ca-cert` is used.
  - Passes the resolved `server.Option`s into `server.New(...)`.
  - Persists `cfg.TLSInsecure` / `cfg.CACertPEM` after a successful health
    check, so the trust decision sticks for future commands.
- Updated the global-options usage text and the `init` command usage text
  to document `--ca-cert FILE` and `--insecure`.

### `ClipmanCli/cmd/clipman-gui-backend/main.go`
- `session.activate(cfg, password)` builds `tlsOptions` from
  `cfg.TLSInsecure` / `cfg.CACertPEM` (same config struct as the CLI) and
  passes them into `server.New(...)`, so a profile configured via
  `clipman-cli init --ca-cert ...` also works from the GUI backend without
  any GUI-specific change. This was required just to keep the package
  compiling after the `server.New` signature changed, but it's also the
  logically correct behavior since both binaries share `internal/config`.

## Design notes / things to double check

- Went with a **functional-options** signature (`opts ...server.Option`)
  specifically so the three pre-existing call sites in
  `internal/syncengine/engine_test.go` and `internal/server/client_test.go`
  didn't need to change. If you'd rather have an explicit struct parameter
  for readability, that's a mechanical change.
- `ca_cert_pem` is stored as the **raw PEM text** inside the config file,
  not a path to the original file. This was deliberate — a path can move or
  be deleted after `init` runs, and the cert isn't secret, so copying the
  PEM bytes in felt more robust than the token/password's
  encrypt-at-rest-and-reference approach. Worth confirming this matches your
  preference for what belongs in the config file.
- No plumbing was added to the GUI frontend (whatever calls
  `clipman-gui-backend`) to let a user pick a CA cert or toggle insecure
  mode from the UI — only the backend now honors it if it's already in the
  config (e.g. because `clipman-cli init` wrote it, or someone hand-edits
  the config file). Whether the GUI needs its own affordance for this is
  a product decision, not made here.
- `--insecure` disables verification for **all** requests made by that
  `Client`, which is only ever pointed at the one configured server, so the
  blast radius is limited to that server relationship — flagging in case
  the security model assumed differently elsewhere.

## Testing performed

No CI/test runner was available in the working environment initially;
installed `golang-go` via `apt-get install -y golang-go` to build/test.

- `go build ./...` — clean.
- `go vet ./...` — clean.
- `go test ./...` — all packages pass, including
  `internal/server`, `internal/config`, `cmd/clipman-cli`, and
  `cmd/clipman-gui-backend`.
- Manual end-to-end smoke test against a real self-signed HTTPS server
  (`openssl req -x509 -newkey rsa:2048 ... -subj "/CN=localhost"`, a
  throwaway Go `http.ListenAndServeTLS` serving `/api/v1/health`):
  1. **Baseline** (no new flags): `clipman-cli init` reproduced the exact
     reported failure:
     `server health check failed: ... x509: certificate signed by unknown authority`.
  2. **`--insecure`**: `init` succeeded (with the stderr warning), and a
     subsequent `status` call — with no `--insecure` flag — succeeded too,
     confirming the persisted setting is picked up automatically.
  3. **`--ca-cert cert.pem`**: `init` succeeded, and `status` afterward
     (again with no flag) succeeded, confirming persistence works for the
     CA-pinning path too.
  4. **`--insecure --ca-cert ... ` together**: correctly rejected with
     `--insecure and --ca-cert cannot be used together` (exit code 2).
  5. **`--ca-cert /nonexistent.pem`**: correctly rejected with
     `cannot read CA certificate file: ...` (exit code 3).

## TODO for maintainer: documentation

Docs were **not** updated as part of this change — flagging explicitly so
it doesn't get lost:

- `ClipmanCli/Manual.html` — the `init` row in the command table (~line 54)
  and the `init` example (~line 43) should mention `--ca-cert FILE` and
  `--insecure`, plus a short explanation of when to use which (self-signed
  server cert vs. arbitrary trust-anything).
- `ClipmanCli/clipman-cli.1` (man page) — no existing mention of TLS/cert
  handling at all; add `--ca-cert` and `--insecure` to the option list, and
  probably a line under the existing security/permissions discussion
  (~line 90-95, which already covers token/password storage) noting that
  `ca_cert_pem`/`tls_insecure` are stored in the config file too.
- Top-level `README.md` and/or `ClipmanServer*` docs, if they walk through
  setting up a server with a self-signed cert for local/private use — this
  is the natural place to point people at `--ca-cert` instead of "add it to
  your OS trust store."
- Worth a line in whatever changelog/release-notes file this project keeps,
  since `tls_insecure` / `ca_cert_pem` are new config file keys (backward
  compatible — old configs without them just default to normal
  verification).

## Reference: trusting the cert system-wide (no code change)

Mentioned to the user as the zero-code-change alternative, in case it's
useful to document as well:

- **Linux**: copy the server's cert to
  `/usr/local/share/ca-certificates/clipman.crt` and run
  `update-ca-certificates`.
- **macOS**: add it to Keychain Access and mark it "Always Trust".
- **Windows**: import it into the Local Machine "Trusted Root Certification
  Authorities" store.

This trusts the cert for *every* application on the machine, which is a
much bigger blast radius than pinning it for just this one server — hence
building `--ca-cert`/`--insecure` instead of only documenting this path.

---

# `init` interactive connection-file prompt

Unrelated to the TLS work above, but logged here at the maintainer's request
so it can be handed off together. This came out of a follow-up conversation
about `init` UX: the user felt that requiring `--connection-file PATH` (or
manually typing a server address and token) was more command-line ceremony
than necessary for an interactive setup.

## Problem

`clipman-cli init`, run interactively with nothing supplied, only ever
prompted for the server address and then the token, one field at a time.
There was no interactive path to "I have a `.clpconf` file, just read it,"
even though that's the flow the accompanying server (`clipman_server.py
--write-connection-info`) is built around — you had to already know to pass
`--connection-file` on the command line.

## Options considered

Discussed two shapes with the user before implementing:

1. A numbered menu ("press 1 for connection file, press 2 for manual entry").
2. A single yes/no question ("Do you have a connection file? [y/N]") that
   branches into the existing connection-file logic or falls through to the
   existing manual prompts.

Recommended (2): fewer keystrokes, matches the direct-question style the
rest of `init`'s prompts already use, and a numbered menu only earns its
complexity once there are 3+ paths — there are exactly two here. The user
agreed and asked for the y/n version.

## Fix

`ClipmanCli/cmd/clipman-cli/main.go`, in `runInit`:

- Added a `promptYesNo(label string, defaultYes bool) (bool, error)` helper
  next to the existing `promptLine`/`promptPassword` (built on top of
  `promptLine`), accepting `y`/`yes`/`n`/`no` case-insensitively, blank input
  falling back to `defaultYes`, and anything else returning a `fail(2, ...)`
  usage error.
- Right after `serverURL := g.server` and before the existing
  `if *connectionFile != ""` block, inserted:
  ```go
  if *connectionFile == "" && *tokenValue == "" && *tokenFile == "" && serverURL == "" && !*nonInteractive {
      useFile, promptErr := promptYesNo("Do you have a Clipman Server connection file (.clpconf)?", false)
      if promptErr != nil {
          return promptErr
      }
      if useFile {
          filePath, promptErr := promptLine("Path to connection file: ")
          if promptErr != nil {
              return promptErr
          }
          *connectionFile = strings.TrimSpace(filePath)
      }
  }
  ```
  This only fires when nothing relevant was already supplied via flags and
  the run isn't `--non-interactive`. Answering `y` populates
  `*connectionFile`, so it flows straight into the **existing, unmodified**
  connection-file handling below (same mutual-exclusion checks, same
  65536-byte size limit, same `server.ConnectionDetails` parsing). Answering
  `n`, pressing Enter (blank defaults to no), or `--non-interactive` leaves
  `*connectionFile` empty and falls through to the pre-existing
  `Clipman Server address:` / `Clipman Server token:` prompts unchanged.
- No changes anywhere else in `runInit` — the history-password prompt later
  in the function is unconditional and untouched, so it still runs after
  either path (confirmed in testing below — this was a specific point the
  user asked me to double check).

## Testing performed

`go build ./...`, `go vet ./...`, `go test ./...` all still pass.

Manual prompts open `/dev/tty` directly (`platform.OpenConsole`), so piped
stdin isn't enough to exercise them — used a real pty via Python's
`os.forkpty()` to drive three scenarios against a throwaway plain-HTTP test
server:

1. **`y` → path**: answered `y`, then gave the path to a `.clpconf` file.
   Output showed the file being read, then the (unconditional) `History
   password:` prompt, then a successful `Clipman CLI configured at ...`
   with exit code 0.
2. **`n` → manual entry**: answered `n`, then got prompted for
   `Clipman Server address:`, `Clipman Server token:`, and `History
   password:` in the original order, then succeeded.
3. **Blank Enter on the y/n prompt**: confirmed it defaults to `N` (falls
   through to manual entry), matching the `[y/N]` label.

## Documentation updated

Both docs were updated as part of this change (unlike the TLS flags above,
which are still outstanding):

- `ClipmanCli/Manual.html`:
  - Quick Start section: added a paragraph after the `--connection-file`
    example explaining the new prompt and its `y`/`n`/blank/`--non-interactive`
    behavior.
  - Commands table: reworded the `init` row to mention the interactive
    connection-file question.
- `ClipmanCli/clipman-cli.1`:
  - Extended the `init` `.TP` entry with the same behavior description.
  - Verified with `groff -man -Tascii -ww clipman-cli.1` — no warnings — and
    checked the rendered plain-text output for correct line-wrapping and
    quoting around the prompt text.

---

# `init` browser-style "trust this certificate?" prompt

Also unrelated to the original TLS work above, logged here at the
maintainer's request for the same handoff. This is the natural follow-up to
the `--ca-cert`/`--insecure` flags: instead of requiring the operator to
already have the server's certificate file in hand, `init` can now offer to
fetch, display, and trust it interactively — the way old browsers handled an
unrecognized certificate.

## Problem

Even with `--ca-cert`/`--insecure` available, using them required the
operator to already possess the server's certificate file, or to know in
advance that `--insecure` was acceptable for that connection. There was no
"the cert isn't trusted, here's what it looks like, do you want to trust it"
path — the kind of prompt SSH shows for an unknown host key, or old browsers
showed for a self-signed certificate.

## Design discussion

Walked through feasibility and the security model with the user before
implementing:

- **Feasible**: on the TLS trust failure, open a second, throwaway TLS
  connection to the same host with verification disabled *purely to read
  the certificate the server presents*, compute its SHA-256 fingerprint, and
  show it for confirmation before pinning it — this does not use the
  unverified connection for anything else.
- **Security model called out explicitly**: this is trust-on-first-use
  (TOFU), the same model as an SSH host-key prompt — it protects against a
  passive eavesdropper but **not** against an active man-in-the-middle on
  that very first connection. The mitigation is that
  `clipman_server.py --create-tls-certificate` already prints an "Authority
  SHA-256 fingerprint" line for the admin to read out-of-band, so the
  `init` prompt tells the user to compare fingerprints rather than trust
  blindly. The user agreed this was an acceptable, clearly-labeled tradeoff
  and asked me to implement it.

## Fix

All in `ClipmanCli/cmd/clipman-cli/main.go`. New imports:
`crypto/sha256`, `crypto/tls`, `encoding/pem`, `net`, `net/url` (in addition
to the `crypto/x509` already added for `--ca-cert`).

New helpers, added next to `readCACertFile`:

- `isCertificateTrustError(err error) bool` — narrows down which health-check
  failures are worth offering a trust prompt for, via `errors.As` against
  `*tls.CertificateVerificationError`, `x509.UnknownAuthorityError`,
  `x509.HostnameError`, and `x509.CertificateInvalidError`. A plain
  connection failure (refused, timeout, DNS) does **not** match, so the
  prompt only appears for genuine certificate-trust problems — verified in
  testing below.
- `fetchServerCertificate(ctx, rawURL) (*x509.Certificate, error)` — dials
  the host with `tls.Dialer{Config: &tls.Config{InsecureSkipVerify: true}}`
  *only* to read `ConnectionState().PeerCertificates[0]`; the connection is
  closed immediately afterward and never used for an actual API call.
  Returns an error (not a panic/fatal) if the server isn't HTTPS, so the
  caller can fall back cleanly.
- `certificateFingerprintSHA256(cert) string` — SHA-256 of `cert.Raw`,
  formatted as colon-separated uppercase hex pairs (same visual convention
  as the fingerprint `clipman_server.py` already prints for the admin).
- `promptTrustCertificate(ctx, rawURL) ([]byte, error)` — fetches the cert,
  prints Subject/Issuer/validity dates/fingerprint plus the
  compare-with-the-admin reminder to stderr, then calls the existing
  `promptYesNo("Trust this certificate for this server", false)`. Returns
  the PEM-encoded cert (via `pem.EncodeToMemory` on `cert.Raw`) if trusted,
  or `nil, nil` if declined or if the cert couldn't be fetched at all (in
  which case the original health-check error is what gets reported).

`runInit` change — replaced the single unconditional health check with:

```go
healthCtx, healthCancel := context.WithTimeout(context.Background(), 30*time.Second)
_, healthErr := client.Health(healthCtx)
healthCancel()
if healthErr != nil && len(tlsOptions) == 0 && !*nonInteractive && isCertificateTrustError(healthErr) {
    fetchCtx, fetchCancel := context.WithTimeout(context.Background(), 15*time.Second)
    trustedPEM, promptErr := promptTrustCertificate(fetchCtx, normalized)
    fetchCancel()
    if promptErr != nil {
        return promptErr
    }
    if len(trustedPEM) > 0 {
        caCertPEM = trustedPEM
        tlsOptions = append(tlsOptions, server.WithCACertPEM(caCertPEM))
        client, err = server.New(normalized, token, databaseID, version+" ("+runtime.GOOS+"/"+runtime.GOARCH+")", tlsOptions...)
        if err != nil {
            return fail(2, "invalid server configuration: %v", err)
        }
        retryCtx, retryCancel := context.WithTimeout(context.Background(), 30*time.Second)
        _, healthErr = client.Health(retryCtx)
        retryCancel()
        if healthErr == nil && !g.quiet {
            fmt.Fprintln(os.Stderr, "Certificate trusted; it will be remembered for this server.")
        }
    }
}
if healthErr != nil {
    return mapRuntimeError("server health check failed", healthErr)
}
```

Notes on the conditions guarding this:

- `len(tlsOptions) == 0` — only offers the discovery prompt when the operator
  didn't already pass `--ca-cert` or `--insecure`. If they explicitly gave a
  CA cert and it still failed (e.g. wrong file), that's a real configuration
  problem and shouldn't be silently papered over by a "want to trust the
  live cert instead?" prompt.
- `!*nonInteractive` — scripted/non-interactive runs get the original error
  immediately, no prompt.
- `isCertificateTrustError(healthErr)` — as above, only genuine trust
  failures qualify.
- `caCertPEM` reuses the same variable the `--ca-cert` flow already
  populates, so the existing `cfg.CACertPEM = string(caCertPEM)` persistence
  line further down needed **no changes** — trusting a discovered cert here
  and passing `--ca-cert` up front end up stored identically in the config
  file.
- Deliberately used separate short-lived contexts for the initial probe,
  the certificate fetch/prompt, and the retry, rather than one shared 30s
  context — the original code shared one `ctx` across the health check and
  the interactive prompt, which meant however long the user took to read
  the fingerprint and answer would eat into the same 30-second budget as
  the network call. Splitting them out means user think-time no longer
  risks a spurious timeout on the retry.

## Testing performed

`go build ./...`, `go vet ./...`, `go test ./...` all pass.

Pty-driven scenarios (`os.forkpty()`, same technique as the earlier prompt
testing) against a throwaway self-signed HTTPS test server
(`openssl req -x509 ... -subj "/CN=localhost"` + a one-off Go
`http.ListenAndServeTLS`):

1. **Answer `y`**: prompt showed `Subject: CN=localhost`,
   `Issuer: CN=localhost`, a validity range, and a colon-separated SHA-256
   fingerprint; answering `y` printed
   `Certificate trusted; it will be remembered for this server.` and `init`
   completed successfully (exit 0). A following `status` call — with no
   `--ca-cert`/`--insecure` flag — succeeded too, confirming the discovered
   cert was persisted exactly like an explicit `--ca-cert` would be.
2. **Answer `n`**: same prompt shown, then `init` failed with the original
   `x509: certificate signed by unknown authority` message (exit 4) and
   wrote no config file — confirming decline doesn't silently trust
   anything.
3. **Unrelated failure (connection refused, wrong port)**: confirmed no
   trust prompt appears at all — `isCertificateTrustError` correctly
   excludes it, and the original connection-refused error is reported
   immediately.

## Documentation updated

- `ClipmanCli/Manual.html`:
  - Quick Start: added a paragraph describing the trust prompt, when it
    fires, and how to opt out (`--ca-cert`, `--insecure`, or
    `--non-interactive`).
  - Security section: added a bullet explicitly naming this as
    trust-on-first-use (SSH-host-key analogy) and telling users to compare
    fingerprints against what the server administrator provides.
- `ClipmanCli/clipman-cli.1`:
  - Extended the `init` entry with the same behavior, as a second paragraph
    within the existing `.TP` block.
  - First attempt used `.PP` to start that second paragraph, which reset
    groff's indentation back to the page margin and broke the hanging-list
    layout for the `init` entry — caught by rendering the page
    (`man -l clipman-cli.1`) and comparing indentation, not just by the
    absence of `groff -ww` warnings (which stayed silent both times).
    Switched to `.IP` with no arguments, which starts a new paragraph at
    the same body indent instead of resetting it; re-rendered to confirm
    `init`'s two paragraphs now line up under the same hanging indent as
    every other command entry.

---

# `init` interactive save-password prompt

Third and final follow-up logged for this handoff. Prompted by the user
running the built binary against their real server and noticing `init`
asked for the history password on every single command — because
`--save-password` defaults to `none`, and they hadn't passed
`--save-password config`.

## Problem

`--save-password config` already existed and already worked — nothing was
broken. But it's an opt-in flag with no interactive equivalent, so anyone
running `init` conversationally (the whole point of the y/n prompts added
earlier in this doc) would never discover it and would be stuck typing the
password on every command.

## An important correction made to the user first

Before implementing, I was direct with the user about what "saving" the
password actually means on this platform, since they explicitly asked "can
we **encrypt** it." `internal/platform/paths_unix.go:107-108`:

```go
func Protect(value []byte) (string, error)   { return string(value), nil }
func Unprotect(value string) ([]byte, error) { return []byte(value), nil }
```

On Linux/macOS these are no-ops — "saving" the password writes it to
`config.toml` in **plain text**, protected only by file permissions
(owner-only 0700/0600, the same protection the token already relies on).
Only the Windows build (`paths_windows.go`) does real encryption, via DPAPI
tied to the OS user account. I did not want the user to opt into this
believing it was encrypted when it isn't — flagging in case the maintainer
wants genuine at-rest encryption on Linux (e.g. via `libsecret`/the OS
secret service, or a passphrase-derived key) as a future project; nothing
like that exists in the codebase today.

## Fix

`ClipmanCli/cmd/clipman-cli/main.go`, `runInit`:

- Right after `fs.Parse(args)`, added detection for whether
  `--save-password` was explicitly passed on the command line, since an
  explicit flag must always win over the new prompt (same precedence rule
  used for the two earlier `init` prompts):
  ```go
  savePasswordExplicit := false
  fs.Visit(func(f *flag.Flag) {
      if f.Name == "save-password" {
          savePasswordExplicit = true
      }
  })
  ```
  (`flag.FlagSet.Visit` only calls back for flags actually set on the
  command line, unlike `VisitAll`.)
- Right after the existing password-resolution block (`if password == ""
  { return fail(5, ...) }`), added:
  ```go
  if !savePasswordExplicit && !*nonInteractive {
      save, promptErr := promptYesNo("Save the history password in the configuration file so it is not requested again?", false)
      if promptErr != nil {
          return promptErr
      }
      if save {
          *savePassword = "config"
          if !g.quiet {
              if runtime.GOOS == "windows" {
                  fmt.Fprintln(os.Stderr, "The password will be saved, encrypted for this Windows user account.")
              } else {
                  fmt.Fprintln(os.Stderr, "The password will be saved in the configuration file, protected only by file permissions (owner-only, not encrypted). Anyone with access to this account or root can read it.")
              }
          }
      }
  }
  ```
  Setting `*savePassword = "config"` reuses the existing `switch
  strings.ToLower(*savePassword)` block further down completely
  unchanged — same code path as passing `--save-password config` on the
  command line, just decided interactively instead. The
  encrypted-vs-plain-text warning is platform-conditional so Windows users
  aren't shown a caveat that doesn't apply to them.
- Declining (`n`, blank Enter, or `--non-interactive`) leaves
  `*savePassword` at its `"none"` default — identical to today's behavior,
  nothing changes for scripted/non-interactive callers.

## Testing performed

`go build ./...`, `go vet ./...`, `go test ./...` all pass.

Pty-driven scenarios against the plain-HTTP throwaway test server:

1. **Answer `y`**: after the `History password:` prompt, saw the new
   question, the plain-text warning, then a successful `init`. Confirmed
   `config.toml` had `password_mode = "config"` and
   `password_protected = "secretpw"` (unencrypted, as expected on Linux),
   and a subsequent `status` call needed **no** `--password` flag.
2. **Answer `n`**: same question shown, declined; confirmed `config.toml`
   had `password_mode = "prompt"` — unchanged from current default
   behavior.
3. **Explicit `--save-password config` on the command line** (with
   `--non-interactive`): confirmed the new question is skipped entirely and
   the password is still saved — the flag takes precedence as designed.

## Documentation updated

- `ClipmanCli/Manual.html`:
  - Quick Start: added a paragraph describing the new prompt and its
    y/n/blank/`--non-interactive`/explicit-flag behavior, cross-referencing
    the Security section.
  - Security section: strengthened the existing DPAPI-vs-Linux bullet to
    say **plain text** explicitly rather than the previous, softer
    "restricted to the owning user" phrasing — this matters more now that
    an interactive prompt actively invites users to opt in.
- `ClipmanCli/clipman-cli.1`:
  - Extended the `init` entry with a third `.IP` paragraph (same pattern as
    the certificate-trust paragraph above it).
  - Strengthened the `SECURITY` section's DPAPI/Linux wording to match
    Manual.html.
  - Verified with `groff -man -Tascii -ww` (no warnings) and by rendering
    the page to confirm indentation.

## Resolved: the user's existing config

The user's real config at `~/.clipman/config.toml` on this machine (the one
that prompted this whole thread) had `password_mode = "prompt"` — it was
created before this change existed. I did **not** obtain or handle their
actual history password to fix it myself; the password is long-lived secret
material and there's no reason for it to ever pass through this
session/transcript when the CLI can collect it directly from their own
terminal instead.

Wrote a small helper, `/root/run.sh` (local to this machine, not part of the
repository, so nothing to review here beyond context), that reads the
already-known `server` and `token_protected` values back out of their
existing `config.toml` with `grep`/`sed` and re-execs
`clipman-cli --server "$SERVER" init --force --token "$TOKEN"` — so the user
only had to interactively retype the one thing I intentionally avoided
touching: the history password. They ran it via the harness's `!`-prefixed
"run this yourself" mechanism, hit the certificate-trust prompt again
(same server, same fingerprint — expected, since `--force` starts the
config over and doesn't carry forward the previously trusted cert),
answered `y`, entered the password, and answered `y` to the new
save-password prompt. Confirmed working by the user.

---

# Official cross-platform build

Once everything above was verified, ran the project's real release build
(`ClipmanCli/build.sh`, not an ad-hoc `go build`) to produce the actual
distributable artifacts with all of this session's changes included:

```
CLIPMAN_CLI_BUILD_DIR=/root/clipman-cli-build sh ./build.sh
```

Produced `ClipmanCli-0.1.1-dev/` containing all six targets
(`windows-amd64`, `linux-amd64`, `linux-armv7`, `linux-arm64`,
`macos-amd64`, `macos-arm64`), each built with `CGO_ENABLED=0`,
`-trimpath`, `-ldflags "-s -w -X main.version=..."` exactly as the script
already specifies, plus `Manual.html`, `clipman-cli.1`, `LICENSE.txt`, and
a `SHA256SUMS` file — i.e. exactly what a real release would ship. Spot
checked the `linux-amd64` artifact's `--version`, `--help` output, and
embedded strings to confirm it's not stale and does contain this session's
`--ca-cert`/`--insecure` flags and both new `init` prompts. Nothing in
`build.sh` itself needed changes — it already picked up every new file
under `cmd/clipman-cli` automatically.
