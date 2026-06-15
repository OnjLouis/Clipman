# Clipman: Accessible Clipboard Management Tool for Windows

Clipman is a small portable accessible clipboard management tool for Windows, designed for fast keyboard and screen-reader use.

For the full manual, open `Manual.html` from the Clipman folder or press `F1` in the history window.

Project page: <https://github.com/OnjLouis/Clipman>

## Features

- Runs from its folder with no installer.
- Lives in the notification area.
- Tray icon and tooltip show whether clipboard monitoring is on or off.
- Plays copy/on/off/skip sounds when enabled.
- Lets custom sounds live in `Settings\sounds` so updates do not overwrite them.
- Global hotkeys for showing history and toggling monitoring.
- User-configurable hotkeys.
- Press Enter on a history entry to copy it back to the clipboard and close history.
- Press Ctrl+C to copy without closing the history window.
- Press Shift+Enter to pin or unpin an entry. Pinned entries are protected from delete and cleanup.
- Press Backspace in the history list to jump to the first normal entry below pinned entries.
- Press F2 to edit an entry name and stored clipboard text.
- Press Ctrl+F to search clipboard history. Press F3 for next result and Shift+F3 for previous result.
- Text history records the machine that added or most recently re-added an entry, and can sort by machine.
- Use the File history tab to review file copy/cut clipboard events captured while Clipman is running and restore them to the Windows clipboard.
- Optional history size and age limits, with pinned entries kept.
- Optional ignored application list for sensitive apps.
- Import and export clipboard history for backup, including text imports from old Clipman `clipman.db` and Ditto SQLite databases.
- Compressed Clipman database can live in a cloud service, synced folder, or network share.
- Optional history password encryption, with the password protected by Windows per user and machine.
- The app watches the database file and reloads when another machine or process replaces it.
- Tray and app menus show the configured global hotkeys.
- Help menu links to the GitHub project, release history, update checker, contact page, and donate page.
- Optional per-user Windows startup entry.
- Optional automatic update checks at startup, hourly, or daily, with silent install support when a release ZIP is available.

## Default Hotkeys

- Show clipboard history: `Ctrl+Alt+\`
- Toggle monitoring on/off: <code>Ctrl+Alt+`</code>
- Preferences: `Ctrl+,` in the history window only.
- Switch Preferences tabs: `Ctrl+1` to `Ctrl+4` in the Preferences window.
- Manual: `F1` in the history window.
- Check for updates: `Shift+F1` in the history window.
- Project page: `Ctrl+F1` in the history window.
- Diagnostics: `Alt+F1` in the history window.
- Toggle pinned entry: `Shift+Enter`
- Copy without closing history: `Ctrl+C`
- Search: `Ctrl+F`, then `F3` or `Shift+F3`
- Edit entry name and text: `F2`

Hotkeys can be changed from Options > Preferences.

Preferences remembers the tab you used last. The storage tab is named Storage and Password because it contains both the shared database path and the history password controls.

Clipman remembers whether clipboard monitoring was on or off. On launch it plays the on or off sound for the restored state when sounds are enabled.

## Database

By default Clipman stores machine-specific settings and shared history in a `Settings` folder beside `clipman.exe`. Settings use the computer name, such as `Desktop-settings.json`, while the live history file uses the `.clipdb` format, which is compressed with a Clipman-specific header rather than plain text.

To share a database between machines, open Options > Preferences on each machine and set the database file to the same synced or network-shared `.clipdb` path. When that file changes, Clipman reloads it without needing to restart.

Multiple machines can write to the same history database. Clipman saves the database atomically, reloads changed files when they arrive, and records the machine name on each text entry so shared setups can tell where an entry came from.

Preferences can encrypt the shared history database with a password. On a new database, leaving the password fields blank means Clipman uses compressed `.clipdb` storage without password encryption. Clipman protects saved passwords with Windows for the current user and machine, so copying a settings file to another computer does not copy a working key. Enter the same history password in Preferences on each computer that shares the encrypted database. The Generate password button copies the new password to the Windows clipboard, and Clipman deliberately ignores that generated password copy so it is not saved in clipboard history.

When a history password is saved, `.clipdb` imports and exports use the current history password. JSON and text exports are readable backup formats, so use `.clipdb` for private encrypted backups.

Old Clipman and Ditto imports read text entries only. They do not import images or every custom clipboard format.

If a sync service creates conflict copies of Clipman's own settings or history database, Clipman attempts to tidy them automatically. History database conflicts are merged by entry, and machine settings conflicts keep the newest settings copy for that machine.

Clipman also writes a small shared update-state file in the `Settings` folder. It includes the public version, an internal UTC build stamp, and the expected executable hash. If another running instance sees a newer build stamp and the updated executable has synced to that machine, it restarts itself so shared-folder installs can pick up the current build even when the public version number has not changed.

During an update, Clipman downloads the release ZIP to a temporary folder, publishes a short close request so other instances running from the same shared folder stand down, replaces app files while preserving `Settings`, then restarts. The updated copy publishes the new shared state so other machines restart after the updated executable reaches them through a cloud service or network share.

Custom sounds can be placed in `Settings\sounds` using the same file names as the bundled sounds: `copy.wav`, `on.wav`, `off.wav`, and `skip.wav`. Clipman uses those first and falls back to the bundled defaults for any missing sound.

Questions and feedback can be sent through `Help` > `Contact` in the app or <https://onj.me/contact>.

Clipman is free software. If you want to support Andre's work, use `Help` > `Donate` in the app or visit <https://www.paypal.me/AndreLouis>.

Clipman is based on earlier Clipman work by Tyler Spivey. SQLite import support uses the public-domain SQLite runtime from the SQLite project.

## Development and Release Checks

Before preparing a GitHub push or release, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1
```

Release rules for coding agents live in `GITHUB-RELEASE-RULES.md`.

## License

Clipman is released under the MIT License. See `LICENSE.txt`.
