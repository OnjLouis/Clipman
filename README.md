# Clipman: Accessible Clipboard Management Tool

Clipman is a small portable accessible clipboard management tool designed for fast keyboard and screen-reader use. The main implementation is Windows; the `ClipmanMac` folder contains the native macOS/AppKit implementation that shares the same text-history database contract.

For the full manual, open `Manual.html` from the Clipman folder or press `F1` in the history window.

Project page: <https://github.com/OnjLouis/Clipman>

macOS tester builds are produced from `ClipmanMac` and attached to releases in this same repository so Windows and Mac downloads appear together.

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
- Application key menus show pinned quick-copy shortcuts when the selected pinned text entry or file-history event is one of the first ten pinned items.
- Press Backspace in the history list to jump to the first normal entry below pinned entries.
- Press F2 to edit an entry name and stored clipboard text.
- Press Ctrl+F to search clipboard history. Press F3 for next result and Shift+F3 for previous result.
- Text history records the machine that added or most recently re-added an entry, and can sort by machine.
- Sort direction uses clearer first-style labels from the View menu, such as oldest first, newest first, A first, or Z first depending on the active sort field.
- Use the File history tab to review file copy/cut and non-text clipboard events captured by Clipman, restore one or more selected file events to the Windows clipboard, pin important file events, move them in manual order, or go to one selected file or folder. File history rows start with the file or folder name, and you can type several characters of a file name to jump to a matching event.
- File history diagnostics are capped by preference, and unavailable unpinned file-history events can be removed manually or automatically.
- Optional history size and age limits, with pinned entries kept.
- Optional ignored application list for sensitive apps.
- Import and export clipboard history for backup, including text imports from old Clipman `clipman.db` and Ditto SQLite databases.
- Compressed Clipman database can live in a cloud service, synced folder, or network share.
- Optional history password encryption. By default the unlock password is session-only; users can explicitly choose to remember it on a computer with Windows user protection.
- The app watches the database file inside the configured data folder and reloads when another machine or process replaces it.
- Tray and app menus show the configured global hotkeys.
- Help menu links to the GitHub project, release history, update checker, contact page, and donate page.
- Optional per-user Windows startup entry.
- Optional automatic update checks at startup, hourly, or daily, with silent install support when a release ZIP is available.

## Default Hotkeys

- Show clipboard history: `Ctrl+Alt+\`
- Toggle monitoring on/off: <code>Ctrl+Alt+`</code>
- Preferences: `Ctrl+,` in the history window only.
- Import clipboard entries: `Ctrl+I`
- Export clipboard entries: `Ctrl+E`
- Switch Preferences tabs: `Ctrl+1` to `Ctrl+5` in the Preferences window.
- Close history or Preferences: `Esc`
- Manual: `F1` in the history window.
- Check for updates: `Shift+F1` in the history window.
- Project page: `Ctrl+F1` in the history window.
- Diagnostics: `Alt+F1` in the history window.
- Toggle pinned entry: `Shift+Enter`
- Toggle pinned file-history event: `Shift+Enter` on the File history tab.
- Go to selected file or folder: `Ctrl+Enter` on the File history tab.
- Restore pinned file event: `Ctrl+1` to `Ctrl+0` on the File history tab.
- Copy paths from pinned file event: `Ctrl+Shift+1` to `Ctrl+Shift+0` on the File history tab.
- Copy without closing history: `Ctrl+C`
- Search: `Ctrl+F`, then `F3` or `Shift+F3`
- Edit entry name and text: `F2`

Hotkeys can be changed from Options > Preferences.

Preferences remembers the tab you used last. The File history tab controls file-event cleanup and diagnostics detail. The storage tab is named Storage and Password because it contains both the shared data folder and the history password controls.

The default data folder is `Settings` beside `clipman.exe`. If Clipman is moved while using that default data folder, settings and history follow the new folder. If you choose a different data folder, Clipman uses `clipman-history.clipdb` inside that folder and stores this machine's settings beside it. A small pointer remains in the app's `Settings` folder so Clipman can find the selected data folder on the next launch.

Clipman remembers whether clipboard monitoring was on or off. On launch it plays the on or off sound for the restored state when sounds are enabled.

## Database

By default Clipman stores machine-specific settings and shared history in a `Settings` folder beside `clipman.exe`. If you choose a different data folder, active machine settings move into that selected folder. Settings use the computer name, such as `Desktop-settings.json`, while the live history file uses the `.clipdb` format, which is compressed with a Clipman-specific header rather than plain text.

File and non-text clipboard history is stored separately in a machine-specific file such as `Settings\Desktop-file-history.clipdb`. It uses the same history password when one is configured, but it is not shared by default because file paths are usually machine-specific. It stores paths and clipboard format details only, not file contents.

To share a database between machines, open Options > Preferences on each machine and set the data folder to the same synced or network-shared folder. Clipman uses `clipman-history.clipdb` inside that folder. When that file changes, Clipman reloads it without needing to restart. Existing explicit `.clipdb` paths remain readable for compatibility, but the Preferences Browse button now chooses a folder so users do not accidentally select a machine-specific file-history database.

If the shared database file is missing but its folder is available, Clipman creates it when it next saves. If the folder or drive is temporarily unavailable, Clipman keeps running and reports the storage problem in diagnostics; when the location returns, it merges the existing database before saving.

Multiple machines can write to the same history database. Clipman saves the database atomically, reloads changed files when they arrive, and records the machine name on each text entry so shared setups can tell where an entry came from.

Preferences can encrypt the shared history database with a password. On a new database, leaving the password fields blank means Clipman uses compressed `.clipdb` storage without password encryption. If a password is set, Clipman unlocks the database for the current run. The Remember history password on this computer option is off by default for new settings; when it is off, Clipman asks for the password when it starts and does not save an unlockable password in settings. If you turn Remember on, Windows protects the saved password for the current user and machine, which is convenient but does not defend against malware already running as the same user. Enter the same history password in Preferences on each computer that shares the encrypted database. The Generate password button copies the new password to the Windows clipboard, and Clipman deliberately ignores that generated password copy so it is not saved in clipboard history.

When a history password is saved, `.clipdb` imports and exports use the current history password. JSON and text exports are readable backup formats, so use `.clipdb` for private encrypted backups.

Old Clipman and Ditto imports read text entries only. They do not import images or every custom clipboard format.

The File history tab can delete selected unpinned file events with `Del`, clear normal file history with `Ctrl+Del`, and remove unavailable unpinned events with `Alt+Del`. Unavailable events include non-file clipboard events that cannot be restored as files, and file events where all referenced files or folders are now missing.

File history rows start with the file or folder name, followed by the operation and file count. File history supports buffered type-to-jump navigation by file name, so typing `13.t` keeps looking for that full prefix rather than jumping separately on `t`. It also supports standard Windows multi-selection. Select multiple file events, then press `Enter` to restore all existing files and folders from those events to the Windows clipboard, or `Ctrl+C` to copy their paths as text. Restored file events include both Windows file-drop data and a text version of the paths. Use the View menu to sort normal file events by time captured, file count, name, operation, source application, or manual order. The direction command names the next result plainly, such as oldest first, newest first, fewest files first, most files first, A first, or Z first. Press `Backspace` to jump to the first normal file event below pinned file events. Use `Shift+Enter` to pin or unpin selected file events, `Ctrl+Enter` to open Explorer at one selected file or folder, and `Alt+Up` or `Alt+Down` to move selected file events within the pinned or normal section. Use `Ctrl+Shift+1` through `Ctrl+Shift+0` to copy paths from one of the first ten pinned file events as text and close history. When one of those pinned file events is selected, its Application key menu shows the matching restore and copy-path shortcuts. Pinned file events are kept during delete, clear, unavailable-event cleanup, and file-history size trimming.

The Actions menu includes cleanups for selected text entries. `Ctrl+Shift+R` removes ordinary URL tracking parameters. `Ctrl+Shift+S` cleans links for sharing by removing tracking plus share-state parameters such as YouTube timestamps, so a copied video link can be shared from the start rather than the current playback position.

File history preferences can automatically remove unavailable unpinned events as new file-history events arrive. Diagnostics include the total file-history count, but only list the configured number of recent events so copied file operations do not make diagnostics excessively long.

If a sync service creates conflict copies of Clipman's own settings or history database, Clipman attempts to tidy them automatically. History database conflicts are merged by entry, and machine settings conflicts keep the newest settings copy for that machine.

## Changelog

### 1.5.12

- Changed history password remembering to be explicit and optional. Encrypted databases can now be unlocked for the current Clipman session without saving an unlockable password in settings.
- Clarified the password security model: remembered passwords are protected for the current user and machine only when Remember is enabled, and same-user malware can potentially recover them.
- Improved the Mac build so database password remembering follows the same explicit, optional model as Windows, using Keychain only when Remember is enabled.
- Fixed Mac Preferences so the history location is presented as a Clipman data/settings folder rather than a direct `.clipdb` file path. Closes issue #5.
- Improved Mac VoiceOver labels on the main History window controls so useful shortcut hints are announced without adding visible text.

### 1.5.11

- Changed the sort direction command wording to clearer first-style labels, such as oldest first, newest first, A first, Z first, fewest files first, or most files first depending on the active sort field.
- Changed database selection in Preferences to choose a Clipman data folder instead of an individual `.clipdb` file. Clipman derives `clipman-history.clipdb` inside that folder while keeping existing explicit file paths compatible.
- Changed custom data folders to keep this machine's active settings beside `clipman-history.clipdb`, with a small pointer in the app's local `Settings` folder so shared/synced Clipman folders remain self-contained.

### 1.5.10

- Added File history sorting from the View menu. File history can now sort normal file events by time captured, file count, name, operation, source application, or manual order.
- Added `Backspace` on the File history tab to jump to the first normal file event below pinned file events, matching Text history navigation.
- Added Clean link for sharing with `Ctrl+Shift+S`. It removes tracking parameters and YouTube share-state parameters such as timestamps, so shared video links can open from the start instead of the copied playback position.
- Improved File history restore so restored file events also place file paths on the clipboard as text, and added `Ctrl+Shift+1` through `Ctrl+Shift+0` to copy pinned file-event paths as text.
- Improved Application key menus so selected pinned text entries and file events show their matching quick-copy shortcuts when they are in the first ten pinned items.

### 1.5.9

- Fixed Text history delete selection when deleting the last visible row. Clipman now keeps focus near the deleted row instead of jumping back to the top pinned entry.
- Fixed a Save list position off focus race where pressing an arrow key immediately after opening history could be undone by delayed or duplicate focus resets.

Clipman also writes a small shared update-state file in the `Settings` folder. It includes the public version, an internal UTC build stamp, and the expected executable hash. If another running instance sees a newer build stamp and the updated executable has synced to that machine, it restarts itself so shared-folder installs can pick up the current build even when the public version number has not changed.

During an update, Clipman downloads the release ZIP to a temporary folder, publishes a short close request so other instances running from the same shared folder stand down, replaces app files while preserving `Settings`, then restarts. The updated copy publishes the new shared state so other machines restart after the updated executable reaches them through a cloud service or network share.

Custom sounds can be placed in `Settings\sounds` using the same file names as the bundled sounds: `copy.wav`, `on.wav`, `off.wav`, and `skip.wav`. Clipman uses those first and falls back to the bundled defaults for any missing sound.

Bundled sounds in the root `sounds` folder are factory files. Updates replace them without backing them up, and only user-provided sounds in `Settings\sounds` are treated as custom data.

If Clipman is already running and you start a copy from the same folder, the existing history window is shown. If you start a copy from a different folder, the old copy is asked to close and the new folder takes over.

Questions and feedback can be sent through `Help` > `Contact` in the app or <https://onj.me/contact>.

Clipman is free software. If you want to support Andre's work, use `Help` > `Donate` in the app or visit <https://www.paypal.me/AndreLouis>.

Clipman is based on earlier Clipman work by Tyler Spivey. SQLite import support uses the public-domain SQLite runtime from the SQLite project.

## Development and Release Checks

Before preparing a GitHub push or release, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1
```

Before release, also run the community search checklist:

```powershell
powershell -ExecutionPolicy Bypass -File .\CommunitySearch.ps1
```

This checks GitHub for Clipman activity and writes web/community search links for public feedback that may not have arrived as a GitHub issue.

Release rules for coding agents live in `GITHUB-RELEASE-RULES.md`.

## License

Clipman is released under the MIT License. See `LICENSE.txt`.
