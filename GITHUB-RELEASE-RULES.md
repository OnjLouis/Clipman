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
powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1
```

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
- Source sound assets live in `Assets\sounds`.
- `portable` is generated output and should be treated as disposable.
- `README.md` is for GitHub/source view only, not the portable runtime package.
- `Manual.html` is the user-facing manual shipped with the app.

## Documentation

Update `Manual.html` for user-facing behavior changes.

Update `README.md` for GitHub/project overview changes.

Do not include user-specific paths, private clipboard contents, personal settings, or local machine names in public docs, changelogs, or release notes.
