# Clipman GitHub Release Rules

This file captures the release rules for coding agents preparing Clipman for GitHub.

## Authentication

Never use a GitHub path that opens an interactive browser, passkey, Git Credential Manager, or "Connect to GitHub" prompt.

Use only non-interactive authentication:

- `gh` with `GH_TOKEN` or `GITHUB_TOKEN` set from the local token file.
- `git` with `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=Never`, credential helpers disabled, askpass disabled, and an explicit authorization header derived from the token.
- An already-authenticated GitHub connector.

If token-based authentication fails, stop and report it. Do not trigger an interactive login prompt.

## Clean Portable Output

Before pushing or publishing, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -LivePath D:\Dropbox\SOFTWARE\clipman
```

The normal smoke test also stages a disposable portable copy in `%TEMP%`, applies the freshly built ZIP with Clipman's updater command line, and verifies that runtime folders such as `Settings` and `Logs` survive while stale update folders are removed.

After publishing a GitHub release, run the post-publish updater smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -LivePath D:\Dropbox\SOFTWARE\clipman -Version <version> -RunPostPublishUpdateSmoke
```

That downloads the previous GitHub release ZIP into `%TEMP%`, starts it with startup/silent update settings, and verifies that it updates itself to `<version>`. Restart Andre's live copy afterwards if the test closed it.

macOS tester builds live in `ClipmanMac` and are released from this same GitHub repository, not a separate repo. Before attaching a macOS artifact to a GitHub release, run:

```bash
cd ClipmanMac
Scripts/package-release.sh
```

That produces `ClipmanMac/dist/ClipmanMac.zip`, runs the macOS codec/sync/file-history smoke tests, creates a drag-to-Applications `Clipman.app`, and ad-hoc signs the app. The generated bundle reads the Windows release version from `src/AssemblyInfo.cs`, so `CFBundleShortVersionString` must match `AssemblyInformationalVersion` and `CFBundleVersion` must match `AssemblyFileVersion`. The generated `dist` folder is ignored source noise and should not be committed.

Future GitHub releases should attach both:

- the Windows portable ZIP from `D:\Dropbox\backups\Clipman\Program Builds`
- the Mac ZIP from `ClipmanMac/dist/ClipmanMac.zip`

The clean portable output must contain only shipped app files:

- `clipman.exe`
- `Manual.html`
- `LICENSE.txt`
- `sqlite3.dll`
- `sounds\copy.wav`
- `sounds\on.wav`
- `sounds\off.wav`
- `sounds\skip.wav`

It must not contain:

- `README.md`
- `Settings`
- `Logs`
- `Reports`
- `Backups`
- root `clipman-history.json`
- root `clipman-settings.json`
- nested folders such as `sounds\sounds`

## Source Layout

- Source code lives in `src`.
- macOS source lives in `ClipmanMac`.
- Source sound assets live in `Assets\sounds`.
- `portable` is generated output and should be treated as disposable.
- `README.md` is for GitHub/source view only, not the portable runtime package.
- `Manual.html` is the user-facing manual shipped with the app.

## Documentation

Update `Manual.html` for user-facing behavior changes.

Update `README.md` for GitHub/project overview changes.

Do not include user-specific paths, private clipboard contents, personal settings, or local machine names in public docs, changelogs, or release notes.

## Private Handover Parity

Andre's private Clipman handover lives at `D:\Dropbox\txt\codex\Clipman.txt`. It is not part of the source package, portable build, GitHub repository, or release ZIP.

When changing source, release rules, updater behavior, storage behavior, accessibility behavior, packaging rules, smoke-test expectations, or other facts a future Clipman thread must know, update that handover in the same pass.

`SmokeTest.ps1` checks the private handover when it exists on Andre's machine. Do not bypass that failure by deleting or shipping the handover file.
