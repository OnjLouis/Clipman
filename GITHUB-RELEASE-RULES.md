# Clipman GitHub Release Rules

This file captures the release rules for coding agents preparing Clipman for GitHub.

## Authentication

Never use a GitHub path that opens an interactive browser, passkey, Git Credential Manager, or "Connect to GitHub" prompt.

Use only non-interactive authentication:

- `gh` with `GH_TOKEN` or `GITHUB_TOKEN` set from the local token file.
- `git` with `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=Never`, credential helpers disabled, askpass disabled, and an explicit authorization header derived from the token.
- An already-authenticated GitHub connector.

If token-based authentication fails, stop and report it. Do not trigger an interactive login prompt.

## GitHub Issue Gate

Before publishing any Clipman release, release-asset refresh, or hotfix, read open GitHub issues and pull requests. Do not publish first and inspect issues afterward.

If an open issue is fixed by the release, the user-facing changelog in `Manual.html` must say `Closes issue #N`, `Fixes issue #N`, or `Resolves issue #N` so the smoke test can prove the issue is covered. If an open issue is intentionally deferred, pass it explicitly to the smoke test as a reviewed issue and mention the reason in the release notes or handoff.
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

That produces `ClipmanMac/dist/ClipmanMac-<version>.zip`, runs the macOS codec/sync/file-history smoke tests, creates a drag-to-Applications `Clipman.app`, and ad-hoc signs the app. The generated bundle reads the Windows release version from `src/AssemblyInfo.cs`, so `CFBundleShortVersionString` must match `AssemblyInformationalVersion` and `CFBundleVersion` must match `AssemblyFileVersion`. The generated `dist` folder is ignored source noise and should not be committed.

Future GitHub releases should attach both:

- the Windows portable ZIP from `D:\Dropbox\backups\Clipman\Program Builds`
- the versioned Mac ZIP from `ClipmanMac/dist/ClipmanMac-<version>.zip`

The clean portable output must contain only shipped app files:

- `clipman.exe`
- `Manual.html`
- `LICENSE.txt`
- `sqlite3.dll`
- `sounds\copy.wav`
- `sounds\on.wav`
- `sounds\off.wav`
- `sounds\remote.wav`
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

For a normal release, commit and push the complete intended source state from the repository root, not a hand-picked subset from old handoff notes. Use `git status` to review all modified and newly added source/documentation/asset files across both implementations. Include new source files and assets as well as modified files. For example, a Mac feature may require both a new Swift source file under `ClipmanMac/Sources` and a new bundled resource under `ClipmanMac/Sources/Clipman/Resources`.

Do not commit generated or local runtime output:

- `portable`
- `ClipmanMac/.build`
- `ClipmanMac/.swiftpm`
- `ClipmanMac/build`
- `ClipmanMac/dist`
- `Settings`
- `Logs`
- private handoff files
- local machine settings or local history databases

## Documentation

Update `Manual.html` for user-facing behavior changes.

Update `README.md` for GitHub/project overview changes.

Do not include user-specific paths, private clipboard contents, personal settings, or local machine names in public docs, changelogs, or release notes.

## Private Handover Parity

Andre's private Clipman handover lives at `D:\Dropbox\txt\codex\Clipman.txt`. It is not part of the source package, portable build, GitHub repository, or release ZIP.

When changing source, release rules, updater behavior, storage behavior, accessibility behavior, packaging rules, smoke-test expectations, or other facts a future Clipman thread must know, update that handover in the same pass.

`SmokeTest.ps1` checks the private handover when it exists on Andre's machine. Do not bypass that failure by deleting or shipping the handover file.
