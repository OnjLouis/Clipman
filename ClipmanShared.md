# Clipman Shared Agent Log

This is the quick cross-platform coordination file for Clipman agents. Every Mac or Windows Codex agent should read this file, `CLIPMAN_AGENT_SYNC.md`, and `CLIPMAN_SHARED_CONTRACT.md` before making Clipman changes.

Use this file for brief current-state notes and handoffs. Use `CLIPMAN_SHARED_CONTRACT.md` for mandatory database, settings, sync, password, and shared-history compatibility rules. Use `CLIPMAN_AGENT_SYNC.md` for longer-lived parity decisions, keyboard/UI choices, and release workflow notes.

## Codex Permission Mode

Andre wants Clipman work to run in full-access mode on both Windows and Mac. If Codex starts asking for repeated permission prompts while reading, writing, building, packaging, or pushing Clipman, treat that as an environment/profile problem rather than normal workflow.

Expected mode:

- Filesystem: full access / unrestricted.
- Approvals: never / do not ask for routine Clipman work.
- Network: enabled when GitHub, package, or dependency checks are needed.

On macOS, use the equivalent full-access Codex profile before building or packaging. Do not keep asking Andre to approve normal source reads, writes, Swift builds, packaging commands, Git operations, or release checks once full access has been selected. If the app silently changes back to a restricted sandbox, call that out clearly and ask Andre to fix the Codex environment profile rather than requesting many one-off approvals.

## Current 1.5.11 Mac Release-Asset Hotfix

Windows should include all five currently modified Mac files in the next 1.5.11 Mac release asset:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipboardMonitor.swift`
- `ClipmanMac/Sources/Clipman/HotkeyCaptureField.swift`
- `ClipmanMac/Sources/Clipman/HotkeyDescriptor.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`

Why all five are required:

- `AppController.swift` and `ClipboardMonitor.swift`: add startup clipboard capture so text already on the pasteboard when Clipman launches is captured once monitoring starts.
- `HotkeyCaptureField.swift`: fixes Preferences hotkey field focus/accessibility so VoiceOver activation and mouse interaction focus the intended shortcut field and clear stale modifier state.
- `PreferencesWindowController.swift`: fixes Preferences checkboxes so toggling Monitoring enabled or Run Clipman at login does not immediately call Save and close Preferences.
- `HotkeyDescriptor.swift`: fixes canonical display/parsing for digit keys and enables F1-F12, so Option+Shift+1 displays as Option+Shift+1 rather than a keyboard-layout character such as ⁄.

The Mac `Scripts/package-release.sh` run for the current tester build was built from all five changes, then `/Applications/Clipman.app` was replaced and relaunched from that packaged app.

Verified on macOS for this combined state:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- Installed `/Applications/Clipman.app` is running, codesign verifies, version `1.5.11 / 1.5.11.0`.

## Agent Handoff Rule

Before each Clipman task, read this file plus `CLIPMAN_AGENT_SYNC.md` and `CLIPMAN_SHARED_CONTRACT.md`.

After a Mac or Windows task that changes behavior, update this file with a short note containing:

- changed files,
- user-visible bug or behavior fixed,
- tests/build/package commands run,
- whether the installed/running app was refreshed,
- what the other platform agent needs to do next.

## Windows Release Publication Note - 2026-06-19

Windows agent accepted the Mac clarification that the 1.5.11 Mac release-asset hotfix must include all five Mac files listed above plus `ClipmanShared.md` and `CLIPMAN_AGENT_SYNC.md`.

Windows-side checks before publication:

- Read `ClipmanShared.md`, `CLIPMAN_AGENT_SYNC.md`, and `CLIPMAN_SHARED_CONTRACT.md`.
- Ran `powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild`; Windows smoke/release checks passed, including GitHub issue and PR checks.
- Confirmed `ClipmanMac/dist/ClipmanMac.zip` was regenerated on 2026-06-19 and came from the Mac-verified combined state.

Next Windows action: commit the five Mac source files plus the two coordination docs, retarget `v1.5.11`, regenerate the source snapshot from `HEAD`, and replace the GitHub release Mac/source assets.

## Mac Hotkey Field Fix - 2026-06-19

Andre reported that Preferences could only set the first hotkey field: even focusing the second field changed the history hotkey, and invalid shortcuts such as `Command+C` appeared to be accepted. He also requested Tab and Shift+Tab navigation between Preferences fields.

Changed files:

- `ClipmanMac/Sources/Clipman/HotkeyCaptureField.swift`
- `ClipmanMac/Sources/Clipman/HotkeyDescriptor.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`

Behavior fixed:

- Hotkey fields are now non-editing capture controls, so AppKit's shared field editor should not route captured keys to the wrong field.
- VoiceOver press and mouse click still explicitly focus the intended hotkey field.
- Tab and Shift+Tab move forward/backward through the Preferences key-view loop instead of being captured as hotkeys.
- Command-key equivalents bubble to the window, so `Command+W` can still close Preferences and `Command+C` is not captured as a hotkey.
- Valid global hotkeys must use Option+Shift, must not include Command, and must use a supported letter, number, F1-F12, grave, backslash, or ISO key.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running, codesign verifies, version `1.5.11 / 1.5.11.0`.

Windows next action: include these three files and this `ClipmanShared.md` update in the next commit/release asset refresh.

## Mac Hotkey Field Focus Follow-up - 2026-06-19

Andre reported that Tab and Shift+Tab now move between Preferences fields, but the second hotkey field still would not accept a captured hotkey. The likely cause was AppKit sending `performKeyEquivalent` to controls in view order before normal `keyDown`, letting the first hotkey field capture Option+Shift shortcuts even when it was not the first responder.

Changed file:

- `ClipmanMac/Sources/Clipman/HotkeyCaptureField.swift`

Behavior fixed:

- `HotkeyCaptureField.performKeyEquivalent` now returns `false` unless `window?.firstResponder === self`, so only the focused hotkey field can capture a non-command shortcut.
- Command shortcuts still bubble to the window/app.
- Tab and Shift+Tab behavior remains as previously fixed.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `/Applications/Clipman.app` was replaced and relaunched.
- Installed app is running, codesign verifies, version `1.5.11 / 1.5.11.0`.

Windows next action: include this `HotkeyCaptureField.swift` follow-up plus the `ClipmanShared.md` update in the next Mac asset/source refresh after Andre confirms manual testing.

## Mac Hotkey Validation Relaxed - 2026-06-19

Andre asked for Preferences hotkey capture to be less restrictive while still avoiding unsafe/global system conflicts. Users may now use Control and Command in hotkeys, but unsafe single-modifier letter/number shortcuts remain rejected.

Changed files:

- `ClipmanMac/Sources/Clipman/HotkeyCaptureField.swift`
- `ClipmanMac/Sources/Clipman/HotkeyDescriptor.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanShared.md`

Behavior changed:

- Valid letter, number, grave, backslash, and ISO-key hotkeys require at least two modifiers in any combination of Control, Option, Shift, and Command.
- F1-F12 hotkeys require at least one modifier.
- Single-modifier letter/number shortcuts such as `Command+C`, `Control+A`, or `Option+1` are rejected.
- Escape, Tab, Backspace/Delete, Return, and Space remain unavailable for global hotkeys.
- `Command+W` still closes Preferences instead of being captured.
- Valid multi-modifier Command shortcuts such as `Command+Option+C` or `Command+Shift+F1` can be captured when the intended hotkey field is focused.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running, codesign verifies, version `1.5.11 / 1.5.11.0`.

Windows next action: read this file and include these Mac hotkey policy changes in the next source/release asset refresh after Andre confirms manual testing.

## Windows Release Publication Note - Mac Hotkey Validation - 2026-06-19

Andre manually tested the relaxed Mac hotkey validation build and confirmed it works well. Windows agent is publishing this as a same-version `1.5.11` Mac release-asset refresh.

Included files:

- `ClipmanMac/Sources/Clipman/HotkeyCaptureField.swift`
- `ClipmanMac/Sources/Clipman/HotkeyDescriptor.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanShared.md`

Windows-side checks before publication:

- Read `ClipmanShared.md`.
- Ran `powershell -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild`; Windows smoke/release checks passed, including GitHub issue and PR checks.
- Confirmed `ClipmanMac/dist/ClipmanMac.zip` was regenerated on 2026-06-19 after the Mac-side package verification.

Next Windows action: commit these four files, retarget `v1.5.11`, regenerate the source snapshot from `HEAD`, and replace the GitHub release Mac/source assets.
## Windows Password Remembering Hardening - 2026-06-20

Andre received a report that a same-user attacker could recover a remembered Clipman database password from Windows-protected settings. Windows agent agreed the report is valid: DPAPI protects against offline copying and other users, but not malware already running as the same Windows user.

Changed files on Windows:

- `src/Models.cs`
- `src/SettingsStore.cs`
- `src/ClipmanApplicationContext.cs`
- `src/PreferencesForm.cs`
- `SmokeTest.ps1`
- `README.md`
- `Manual.html`
- `CLIPMAN_SHARED_CONTRACT.md`
- `ClipmanShared.md`
- Private handover: `D:\Dropbox\txt\codex\Clipman.txt`

Behavior changed:

- New settings default to not remembering the database password.
- Encrypted databases can be unlocked for the current Clipman session without saving an unlockable password in settings.
- The new `RememberDatabasePassword` setting controls whether Windows stores a DPAPI-protected password.
- `PlainDatabasePassword` is a session-transfer field only and is marked with `ScriptIgnore` so it is not serialized to settings.
- Turning Remember off clears `ProtectedDatabasePassword` while keeping the database encrypted and unlocked for the current process.
- Command-line import/export/Send To can open encrypted databases only when the password is remembered, because those paths do not have an active unlocked Clipman process to borrow from.

Mac next action required:

- Mirror this behavior before the next cross-platform release.
- Add a remember-password setting defaulting to false for new installs.
- Store in Keychain only when remember is true.
- If remember is false and an encrypted database exists, prompt at startup/unlock and keep the password only in memory for the current run.
- If remember is turned off, delete any existing Keychain item for the database path.
- Do not change the shared `.clipdb` format.

Windows verification:

- Build passed locally for candidate version `1.5.12`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Dropbox\backups\Codex\current\clipman\SmokeTest.ps1 -SkipBuild -Version 1.5.12 -SkipGitHubActivityCheck` passed.

## Windows Live Copy Refreshed - 2026-06-20

Windows agent mirrored the local 1.5.12 password-remembering hardening candidate to Andre's live daily-driver copy at `D:\Dropbox\SOFTWARE\clipman`.

Live-copy actions:

- Preserved `D:\Dropbox\SOFTWARE\clipman\Settings` and all clipboard/history databases.
- Copied the candidate `clipman.exe`, `Manual.html`, `LICENSE.txt`, `sqlite3.dll`, and factory `sounds` folder from `portable`.
- Restarted the live Clipman process from `D:\Dropbox\SOFTWARE\clipman\clipman.exe`.
- Ran the live-path smoke test:
  - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Dropbox\backups\Codex\current\clipman\SmokeTest.ps1 -SkipBuild -Version 1.5.12 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman`
  - Result: passed.

Mac next action: read `ClipmanShared.md`, `CLIPMAN_AGENT_SYNC.md`, and `CLIPMAN_SHARED_CONTRACT.md`, then mirror the 1.5.12 password remembering model: remember off by default, session-only unlock when remember is off, Keychain only when remember is explicitly enabled, and delete any Keychain item when remember is disabled.

## Release Gate: GitHub Issues

GitHub issues must be checked before any Clipman release, release-asset refresh, hotfix publication, or push that is intended to ship. Do not publish first and inspect issues afterward. If open issues exist, decide whether they are fixed, need action before release, or should be explicitly deferred.

## Mac Password Remembering Hardening - 2026-06-20

Mac mirrored the Windows 1.5.12 password model. GitHub issue gate was checked before release-style packaging: open issue #5 (`Difference in file location preference between windows and mac versions`) was reviewed and is not a blocker for this password change because current Mac Preferences already presents a settings-folder picker and derives `clipman-history.clipdb`.

Changed files on Mac:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipmanSettings.swift`
- `ClipmanMac/Sources/Clipman/KeychainPasswordStore.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanMac/Sources/Clipman/SettingsStore.swift`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior changed:

- New Mac settings default to `rememberDatabasePassword = false`.
- Preferences now has an explicit `Remember history password in Keychain` checkbox.
- When remember is off, Mac prompts for encrypted history unlock and keeps the password only in process memory for the current app run.
- When remember is on, Mac reads/writes the database password through Keychain keyed by database path.
- Turning remember off deletes the Keychain item for the current database path and the previous path if the path changed while saving Preferences.
- Existing legacy Mac installs with a Keychain password and no `rememberDatabasePassword` setting migrate to remember-on once, mirroring the Windows legacy protected-password migration.
- The shared `.clipdb` format did not change.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`

Next action: package, replace `/Applications/Clipman.app`, relaunch, then hand this note to Windows so it can include the Mac files in the 1.5.12 push/release flow.

Mac packaging follow-up for the password remembering hardening:

- `ClipmanMac/Scripts/package-release.sh` passed and regenerated `ClipmanMac/dist/ClipmanMac.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running, codesign verifies, version `1.5.12 / 1.5.12.0`.

Windows next action: read this file, include the Mac password remembering changes in the 1.5.12 source/release flow, and keep the release gate requiring GitHub issue review before publication.

## Mac Issue #5 Settings Folder UI Fix - 2026-06-20

Mac addressed GitHub issue #5 (`Difference in file location preference between windows and mac versions`) after the 1.5.12 password remembering work.

Changed file:

- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanShared.md`

Behavior changed:

- Mac Preferences now displays the user-selected Clipman data/settings folder in the `Settings folder` field, not the derived `clipman-history.clipdb` file path.
- The folder picker writes the selected folder path into the field.
- Saving still derives the live shared text-history database as `<selected folder>/clipman-history.clipdb`, preserving the existing internal settings/database path model and shared `.clipdb` behavior.
- Existing settings that contain an explicit `.clipdb` path are still read, but Preferences presents their parent folder to the user to match Windows' folder-based model.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`

Windows next action: include this issue #5 Mac UI fix together with the earlier Mac 1.5.12 password remembering files when publishing. Issue #5 can be treated as fixed by the Mac changes once Windows includes the listed file in the release/source refresh.

Mac packaging follow-up for issue #5 settings-folder UI fix:

- `ClipmanMac/Scripts/package-release.sh` passed and regenerated `ClipmanMac/dist/ClipmanMac.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running, codesign verifies, version `1.5.12 / 1.5.12.0`.

Combined Windows publishing note: include the Mac 1.5.12 password remembering files, this issue #5 Preferences UI fix, and the coordination doc updates in the same publish/release asset refresh. The release gate was satisfied for Mac work by checking open GitHub issues before packaging; issue #5 is now addressed by the Mac Preferences change.

## Mac VoiceOver Shortcut Labels - 2026-06-20

Andre asked for VoiceOver-only shortcut context on the main Clipman History window controls without adding visible text.

Changed files:

- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `ClipmanShared.md`

Behavior changed:

- Main History window accessibility labels now include concise shortcut hints where useful:
  - Search history, `Command+F`
  - History type group: Text History `Control+1`, File History `Control+2`
  - Clipman menu, `Option+M`
  - Set Group, `Command+G`
  - Filter by group, `Option+G`
  - Preferences, `Command+,`
- These are accessibility labels only; visible UI text is unchanged.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`

Windows next action: read this file and include `ClipmanMac/Sources/Clipman/HistoryWindowController.swift` plus `ClipmanShared.md` in the next 1.5.12 source/release refresh if Andre confirms the VoiceOver labels are good.

Mac packaging follow-up for VoiceOver shortcut labels:

- `ClipmanMac/Scripts/package-release.sh` passed and regenerated `ClipmanMac/dist/ClipmanMac.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running, codesign verifies, version `1.5.12 / 1.5.12.0`.
