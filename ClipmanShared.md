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

## Release Source Push Rule

For normal releases, especially `1.6` and later, Windows must publish from the full combined repository source tree, not from a hand-picked subset of changed files listed in older dated handoff notes.

The source push/commit should include every intended tracked or newly added source/documentation/asset change under the repository root, including:

- Windows source and release files such as `src`, `Assets`, `Build.ps1`, `SmokeTest.ps1`, `Manual.html`, `README.md`, `GITHUB-RELEASE-RULES.md`, `CLIPMAN_AGENT_SYNC.md`, `CLIPMAN_SHARED_CONTRACT.md`, and `ClipmanShared.md`.
- macOS source and release files under `ClipmanMac`, including `Package.swift`, `README.md`, `Scripts`, `Sources`, and bundled source resources such as `ClipmanMac/Sources/Clipman/Resources/sounds`.
- Newly added source files and assets, not only modified files. For the current 1.6 candidate this specifically includes `ClipmanMac/Sources/Clipman/UpdateService.swift`, `ClipmanMac/Sources/Clipman/URLTrackingCleaner.swift`, `Assets/sounds/remote.wav`, and `ClipmanMac/Sources/Clipman/Resources/sounds/remote.wav`.

Do not commit generated or local runtime output, including `portable`, `ClipmanMac/.build`, `ClipmanMac/.swiftpm`, `ClipmanMac/build`, `ClipmanMac/dist`, `Settings`, `Logs`, private handoff files, local machine settings, or local history databases.

Older dated notes that say “include exactly these files” describe the narrow hotfix state at that time. They must not be used as a filter for a later full release. For a full release, use `git status` from the repository root and include the complete intended source set, then build and smoke from that exact tree before publishing.

## Mac Empty-Search F3 Parity - 2026-06-27

Andre requested one final Mac parity fix before 1.6: when search text is empty, `F3` and `Shift+F3` should focus the search field instead of moving to the next or previous history row, matching Windows.

Changed files:

- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior changed:

- Mac `F3` / `Shift+F3` still move between visible search results when search text exists.
- When search text is empty, Mac now focuses the search field.
- No shared database, manual, README, or Windows behavior changes were needed.

Mac verification:

- `swift build --scratch-path /tmp/ClipmanMac-build` passed.
- `ClipmanMac/Scripts/package-release.sh` passed on macOS, including release-mode codec, sync, and file-history smoke tests.
- `ClipmanMac/dist/ClipmanMac-1.6.zip` was regenerated.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed `/Applications/Clipman.app` reports `1.6 / 1.6.0.0`.
- Installed `Contents/Resources/Manual.html` matches root `Manual.html`, and installed `Contents/Resources/LICENSE.txt` matches root `LICENSE.txt`.
- `codesign --verify --deep --strict /Applications/Clipman.app` passed.

## Mac Contact and Donate Menu Parity - 2026-06-27

Andre requested Contact and Donate in the Mac menus before 1.6, and corrected the Donate URL to `https://onj.me/donate`.

Changed files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `src/UpdateService.cs`
- `Manual.html`
- `README.md`
- `SmokeTest.ps1`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior changed:

- Mac app menu, status menu, and in-window Clipman menu now include `Contact` and `Donate`.
- Mac `Contact` opens `https://onj.me/contact`.
- Mac and Windows `Donate` now open `https://onj.me/donate`.
- The shared manual no longer says Contact and Donate are Windows-only.
- Windows smoke guards the shared manual, README, Windows source, and Mac source against the old PayPal Donate URL.

Mac verification:

- `swift build --scratch-path /tmp/ClipmanMac-build` passed.
- `ClipmanMac/Scripts/package-release.sh` passed on macOS, including release-mode codec, sync, and file-history smoke tests.
- `ClipmanMac/dist/ClipmanMac-1.6.zip` was regenerated.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed `/Applications/Clipman.app` reports `1.6 / 1.6.0.0`.
- Installed `Contents/Resources/Manual.html` matches root `Manual.html`, and installed `Contents/Resources/LICENSE.txt` matches root `LICENSE.txt`.
- Installed manual documents Mac `Contact` and `Donate`, and the Donate URL is `https://onj.me/donate`.
- `codesign --verify --deep --strict /Applications/Clipman.app` passed.

Windows next action:

- Include this as part of the full 1.6 source set. Windows source was also updated so `UpdateService.OpenDonatePage()` uses `https://onj.me/donate`.
- Windows build and smoke verification passed after reading this section: `Build.ps1`, then `SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck`.

## Shared README and Manual Release Wording - 2026-06-27

Andre noted that the GitHub front page still read too much like a Windows-only project and that the first `1.6` changelog item sounded too self-congratulatory. The shared README and manual now present Clipman as a Windows and macOS clipboard manager, use the user-facing release heading `1.6.0`, and describe the coordinated Windows/Mac work in neutral release-note language.

Andre also asked that the opening manual text make the shared database behavior more obvious. The README and manual now say that when history lives in a cloud service or network share, adding, removing, moving, renaming, grouping, pinning, or editing text entries on one machine can be picked up automatically by other machines watching the same shared database.

Andre also caught that the Quick Copy release note still said `Fixed Windows Quick Copy assignments...`, which made the feature sound like users had already seen it before 1.6. The README and manual now say `Quick Copy assignments made from Entry Properties now take effect immediately when global hotkeys are added, changed, or cleared.`

Changed files:

- `README.md`
- `Manual.html`
- `SmokeTest.ps1`
- `ClipmanShared.md`

Windows verification:

- `SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck` passed.
- Updated `Manual.html` was copied to Andre's live Windows Clipman folder at `D:\Dropbox\SOFTWARE\clipman\Manual.html` for review.

Mac verification:

- `ClipmanMac/Scripts/package-release.sh` passed on macOS, including release-mode codec, sync, and file-history smoke tests.
- `ClipmanMac/dist/ClipmanMac-1.6.zip` was regenerated.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed `/Applications/Clipman.app` reports `1.6 / 1.6.0.0`.
- Installed `Contents/Resources/Manual.html` matches root `Manual.html`, and installed `Contents/Resources/LICENSE.txt` matches root `LICENSE.txt`.
- Both installed `Manual.html` and the ZIP-bundled `Manual.html` include the clearer shared-database opening text.
- Both installed `Manual.html` and the ZIP-bundled `Manual.html` include the corrected Quick Copy wording and not the stale `Fixed Windows Quick Copy assignments...` wording.
- `codesign --verify --deep --strict /Applications/Clipman.app` passed.

## Mac 1.6 Parity Hotkey Completion - 2026-06-27

Andre requested that Mac no longer show avoidable “Not yet available” entries in the shared manual's keyboard table.

Changed files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipStore.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `ClipmanMac/Sources/Clipman/URLTrackingCleaner.swift` (new file)
- `ClipmanMac/README.md`
- `Manual.html`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior added on Mac:

- `Command+I` imports text-history entries from `.clipdb`, JSON, or text into the current history.
- `Command+E` exports text history to `.clipdb`, JSON, or text. `.clipdb` export uses the current database password when one is active.
- `Command+Shift+R` removes common URL tracking parameters from selected text entries, updates storage, and copies the cleaned text to the Mac clipboard.
- `Command+Shift+S` cleans selected links for sharing, including YouTube share-state parameters, updates storage, and copies the cleaned text to the Mac clipboard.
- `Command+Enter` on File history goes to the selected file or folder in Finder.
- The shared `Manual.html` no longer lists these Mac commands as unavailable. It still documents old Clipman and Ditto SQLite imports as Windows-only.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running from `/Applications/Clipman.app`, codesign verifies, bundle resources include `Manual.html` and `sounds/remote.wav`, version is `1.6 / 1.6.0.0`.
- Release asset regenerated at `ClipmanMac/dist/ClipmanMac-1.6.zip`.

Windows next action: for 1.6, publish from the full intended repository source set, not a subset. Include the new Mac source file `ClipmanMac/Sources/Clipman/URLTrackingCleaner.swift` along with all other tracked/new source, documentation, script, and bundled asset changes.

## Mac VoiceOver Manual Notes - 2026-06-27

Andre requested clearer Mac VoiceOver guidance in the shared manual.

Changed files:

- `Manual.html`
- `ClipmanMac/README.md`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior/documentation changed:

- The manual now explicitly says VoiceOver users can open the history window's Clipman command menu with `Option+M`.
- The Mac platform note explains that unsigned tester builds can be opened from Finder with the context menu, and gives `VO+Shift+M` as the VoiceOver way to reach that menu before choosing Open.
- A compact Mac VoiceOver note describes the history-window focus recovery path: press the Show History global hotkey once to dismiss Clipman and again to reopen if macOS reports a new window but focus lands badly.
- Application-files wording now says Mac users can move or drag `Clipman.app` to `/Applications`, and VoiceOver users can copy/paste in Finder instead of dragging.

Verified on macOS:

- `ClipmanMac/Scripts/package-release.sh` passed, including release-mode codec, sync, and file-history smoke tests.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app reports `1.6 / 1.6.0.0`.
- Bundled `/Applications/Clipman.app/Contents/Resources/Manual.html` contains the new `Option+M`, `VO+Shift+M`, and Mac VoiceOver notes.
- Release asset regenerated at `ClipmanMac/dist/ClipmanMac-1.6.zip`.

Windows next action: include these documentation updates in the full 1.6 source push/release asset set. No Windows code behavior change is required.

## Manual Basic Use Cleanup - 2026-06-27

Andre noted that the Basic Use section had become a redundant shortcut list and made the Keyboard Shortcuts table feel pointless.

Changed files:

- `Manual.html`
- `ClipmanShared.md`

Documentation changed:

- Rewrote Basic Use into a short orientation section covering what Clipman stores, opening/closing history, Text/File history views, search/group/pin/sort concepts, Entry Properties, File history limits, monitoring, and where to find platform menus.
- Removed the long duplicated shortcut walkthrough from Basic Use. Detailed keyboard commands now live in the Keyboard Shortcuts table.
- Kept `Option+M` in Basic Use as the general Mac command-menu shortcut, useful for all Mac users as well as VoiceOver users.

Verified on macOS:

- `ClipmanMac/Scripts/package-release.sh` passed, including release-mode codec, sync, and file-history smoke tests.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app reports `1.6 / 1.6.0.0`.
- Bundled `/Applications/Clipman.app/Contents/Resources/Manual.html` contains the rewritten Basic Use section.
- Release asset regenerated at `ClipmanMac/dist/ClipmanMac-1.6.zip`.

Windows next action: include the manual and `ClipmanShared.md` documentation updates in the full 1.6 source push/release asset set. No Windows code behavior change is required.

## Mac Ignored Applications and Manual Audit - 2026-06-27

Andre caught that ignored applications were still missing on Mac and asked for a top-to-bottom manual cleanup rather than only patching one section.

Changed files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipboardMonitor.swift`
- `ClipmanMac/Sources/Clipman/ClipmanSettings.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanMac/Sources/Clipman/SettingsStore.swift`
- `ClipmanMac/README.md`
- `Manual.html`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior added on Mac:

- Preferences now includes an ignored applications multiline list.
- Mac ignored applications are machine-specific settings.
- Matching accepts app names, bundle identifiers, or executable names, such as `Safari`, `com.apple.TextEdit`, or `KeePassXC`.
- Clipboard monitoring skips text and file clipboard capture while the foreground app matches the ignored list.
- Diagnostics includes the current ignored application list.

Manual cleanup:

- Shortened Notes and Basic Use so the top of the manual is an orientation, not a second shortcut table.
- Moved detail into the relevant sections by tightening Preferences, Platform Notes, Pinned Entries, Sorting, and Ignored Applications.
- Updated Ignored Applications to document both Windows and Mac behavior now that Mac support exists.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app reports `1.6 / 1.6.0.0`.
- Bundled `/Applications/Clipman.app/Contents/Resources/Manual.html` documents Mac ignored applications and contains the shortened top manual sections.
- Release asset regenerated at `ClipmanMac/dist/ClipmanMac-1.6.zip`.

Windows next action: include these Mac source/doc updates in the full 1.6 source push/release asset set. No Windows code change is required for Mac ignored-app support, but Windows should include the shared manual and coordination docs.

## Mac Ignored App Skip Sound and Preferences Close - 2026-06-27

Andre manually tested Mac ignored applications by adding Codex. Clipman correctly ignored clipboard captures from Codex, but it did not play the skip sound. Andre also asked for Escape to close Preferences and for the Save button to make clear that it saves and closes.

Changed files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipboardMonitor.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanShared.md`

Behavior fixed:

- Ignored foreground-app clipboard changes now call back to the app controller and play `skip.wav`.
- Startup clipboard capture still suppresses skip sound, so launching Clipman while an ignored app is frontmost does not make noise.
- Preferences handles Escape through `cancelOperation` as well as direct key handling, so Escape closes even when focus is inside normal controls.
- Preferences button text now says `Save and Close`; the existing action already saved settings and closed the window.
- `Codex` was removed from Andre's live Mac ignored-app list after the test.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app reports `1.6 / 1.6.0.0`.
- Andre's live Mac ignored-app list is empty after removing the temporary `Codex` test entry.
- Release asset regenerated at `ClipmanMac/dist/ClipmanMac-1.6.zip`.

Windows next action: include these Mac source and coordination doc updates in the full 1.6 source set. No Windows code behavior change is required.

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

## Mac Updater, Remote Clipboard, Quick Copy, And Auto Groups - 2026-06-27

Mac implemented the next daily-driver slice for the 1.5.12 build line. GitHub issue gate was checked before release-style packaging; there are currently no open issues in `OnjLouis/Clipman`.

Changed Mac files Windows must include exactly:

- `CLIPMAN_AGENT_SYNC.md`
- `CLIPMAN_SHARED_CONTRACT.md`
- `ClipmanShared.md`
- `GITHUB-RELEASE-RULES.md`
- `ClipmanMac/README.md`
- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipboardMonitor.swift`
- `ClipmanMac/Sources/Clipman/ClipStore.swift`
- `ClipmanMac/Sources/Clipman/ClipmanSettings.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `ClipmanMac/Sources/Clipman/HotkeyDescriptor.swift`
- `ClipmanMac/Sources/Clipman/HotkeyManager.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanMac/Sources/Clipman/SettingsStore.swift`
- `ClipmanMac/Sources/Clipman/UpdateService.swift`

Behavior changed:

- Mac package output is now versioned as `ClipmanMac/dist/ClipmanMac-<version>.zip`; the app inside remains `Clipman.app`.
- Mac adds an updater service that checks GitHub releases for Mac ZIP assets, compares versions, can prompt manually, and can install silently when enabled in Preferences.
- Preferences exposes update frequency, silent update install, and opt-in copy of latest remote text to this Mac clipboard. Quick Copy is configured only from Entry Properties / `Set As Quick Copy Target...`, not Preferences.
- The latest-remote-text option is off by default and baselines the current newest remote entry before copying, so enabling it does not grab old history on launch.
- Quick Copy is a global hotkey that copies one user-selected text entry to the clipboard from anywhere, without showing the history window. The target is set from the Clipman menu with `Set As Quick Copy Target` and is stored only in this Mac's machine settings.
- Mac text captures now set the shared `Group` field to the foreground source application name when available, so app-created groups such as Logic and TextEdit match Windows behavior.
- No shared `.clipdb` format change was made.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/dist/ClipmanMac-1.5.12.zip` generated and is ignored by Git.
- `dist/Clipman.app` reports `CFBundleShortVersionString=1.5.12` and `CFBundleVersion=1.5.12.0`.
- `codesign --verify --deep --strict dist/Clipman.app` passed.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.

Windows next action: read this file plus `CLIPMAN_AGENT_SYNC.md`, `CLIPMAN_SHARED_CONTRACT.md`, and `GITHUB-RELEASE-RULES.md`; include the exact files above in the next source/release refresh; attach the versioned Mac asset `ClipmanMac/dist/ClipmanMac-1.5.12.zip` rather than the old generic `ClipmanMac.zip`.

## Mac Quick Copy Properties Follow-Up - 2026-06-27

Andre found that `Set As Quick Copy Target` selected a clip but did not offer a way to set the global hotkey in the same workflow. Mac fixed that immediately.

Additional changed Mac files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `ClipmanShared.md`

Behavior changed:

- `Entry Properties` now replaces the old plain edit dialog for text entries. It includes entry name, group, text, a `Use this entry for Quick Copy` checkbox, and a Quick Copy hotkey capture field.
- `Set As Quick Copy Target...` now opens the same properties workflow focused on quick-copy setup, defaults the checkbox on, and lets the user capture or confirm the global Quick Copy hotkey immediately.
- Saving validates that the Quick Copy hotkey is valid and does not duplicate Show History or Toggle Monitoring.
- Saving re-registers global hotkeys immediately.

Verified on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/dist/ClipmanMac-1.5.13.zip` generated and is ignored by Git.
- `dist/Clipman.app` reports `CFBundleShortVersionString=1.5.13` and `CFBundleVersion=1.5.13.0`.
- `codesign --verify --deep --strict dist/Clipman.app` passed.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.

Windows next action: include this quick-copy follow-up with the Mac updater/remote clipboard/auto-group files above. The current Mac asset to attach is `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.

## Mac Multiple Quick Copy And Manual Follow-Up - 2026-06-27

Andre clarified that Quick Copy should allow multiple clips, each with its own global hotkey, and asked how Mac users access the manual.

Additional changed files:

- `Manual.html`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`
- `ClipmanMac/Scripts/build-dev-app.sh`
- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipmanSettings.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `ClipmanMac/Sources/Clipman/HotkeyManager.swift`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`
- `ClipmanMac/Sources/Clipman/SettingsStore.swift`

Behavior changed:

- Quick Copy is now per text entry on Mac. Multiple clips can each have their own global Quick Copy hotkey.
- Mac settings add `quickCopyHotkeys`, a machine-specific dictionary from text entry ID to `HotkeyDescriptor`. The legacy single `quickCopyEntryID`/`quickCopyHotkey` values remain readable and are migrated into the dictionary when present.
- Entry Properties and `Set As Quick Copy Target...` show the selected entry's own Quick Copy hotkey, reject duplicates against other Quick Copy entries, and reject conflicts with Show History and Toggle Monitoring.
- `HotkeyManager` now maps Carbon hotkey IDs back to either Show History, Toggle Monitoring, or a specific Quick Copy entry ID.
- Mac packages now include the shared `Manual.html` inside `Clipman.app/Contents/Resources`.
- The Mac history window opens the manual with `F1` and checks for updates with `Shift+F1`.
- The Mac status/menu includes `Open Manual` and still includes `Check for Updates...`.
- `Manual.html` now has a Mac Version section covering install, status menu, bundled manual, Mac shortcuts, Quick Copy, folder-based settings, password behavior, remote clipboard receive, file history, and app-created groups.
- No shared `.clipdb` format change was made.

Verified on macOS:

- GitHub issue gate checked again; there are no open issues in `OnjLouis/Clipman`.
- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/dist/ClipmanMac-1.5.13.zip` regenerated and ignored by Git.
- `dist/Clipman.app` reports `CFBundleShortVersionString=1.5.13` and `CFBundleVersion=1.5.13.0`.
- `dist/Clipman.app/Contents/Resources/Manual.html` is present.
- `codesign --verify --deep --strict dist/Clipman.app` passed.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.

Windows next action: include this follow-up with the previous Mac 1.5.13 files. Since `Manual.html` is shared, preserve the new Mac Version section when Windows edits the manual.

## Mac VoiceOver History Focus Recovery - 2026-06-27

Andre reported that pressing the global Mac history hotkey can sometimes make VoiceOver say "System has new window" while the Clipman history window does not gain practical focus and cannot be reached with Command+Tab.

Additional changed files:

- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`
- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`

Behavior changed:

- The macOS global Show History hotkey now toggles the history window. If history is already visible, pressing the hotkey hides it. Pressing it again reopens it and makes a fresh focus attempt.
- Showing history now force-orders the window to the front, activates the accessory app, focuses the history table, posts an accessibility focused-element notification, and repeats focus attempts after short delays.
- Menu/status Show History still opens and focuses the window; the toggle behavior is specifically for the global hotkey recovery path.

Parity check:

- Windows 1.5.13 handoff/source now includes per-entry Quick Copy bindings, latest-remote-text, manual/update parity, and focus-hardening patterns for its WinForms history window. Mac remains in parity on shared data/settings behavior; this focus recovery is macOS-specific accessibility hardening.

Verified on macOS:

- GitHub issue gate checked; there are no open issues in `OnjLouis/Clipman`.
- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/dist/ClipmanMac-1.5.13.zip` regenerated and ignored by Git.
- `dist/Clipman.app` reports `CFBundleShortVersionString=1.5.13` and `CFBundleVersion=1.5.13.0`.
- `dist/Clipman.app/Contents/Resources/Manual.html` is present.
- `codesign --verify --deep --strict dist/Clipman.app` passed.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.

Windows next action: include this Mac focus follow-up with the previous 1.5.13 Mac files if publishing the Mac source/package.

## Mac Remove Quick Copy Preferences UI - 2026-06-27

Andre clarified that Quick Copy setup must not ship in Preferences because it is confusing and was only a transient/test-style default. Quick Copy should be configured only from the selected clip's Entry Properties or `Set As Quick Copy Target...` workflow.

Additional changed files:

- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`
- `Manual.html`
- `ClipmanMac/Sources/Clipman/PreferencesWindowController.swift`

Behavior changed:

- Mac Preferences no longer shows a default Quick Copy hotkey field.
- Mac Preferences only validates and saves Show History and Toggle Monitoring hotkeys.
- Per-entry Quick Copy remains available from Entry Properties and `Set As Quick Copy Target...`.
- `Manual.html` no longer lists a default Quick Copy hotkey or says Quick Copy is configured from the Hotkeys tab.
- The legacy/internal `quickCopyHotkey` and `quickCopyEntryID` settings remain readable for one-way migration only and are not user-facing. They should not be written back to modern settings, and they should not provide a default hotkey for new Quick Copy assignments.

Windows parity action:

- Windows removed the Preferences-level Quick Copy hotkey before publication. Quick Copy is assigned only from Entry Properties or `Set as quick-copy target...`.

Mac verification pending after this note:

- Run `swift build --scratch-path /tmp/ClipmanMac-build`.
- Run the three Mac smoke executables.
- Package/reinstall `/Applications/Clipman.app`.

## Windows Quick Copy And Remote Clipboard Parity - 2026-06-27

Windows mirrored the Mac Quick Copy/latest-remote-text model for candidate `1.5.13`.

Changed Windows files:

- `src/AssemblyInfo.cs`
- `src/Models.cs`
- `src/SettingsStore.cs`
- `src/ClipStore.cs`
- `src/ClipmanApplicationContext.cs`
- `src/EntryPropertiesForm.cs`
- `src/HistoryForm.cs`
- `src/PreferencesForm.cs`
- `src/SyncConflictResolver.cs`
- `README.md`
- `Manual.html`
- `CLIPMAN_AGENT_SYNC.md`
- `CLIPMAN_SHARED_CONTRACT.md`
- `ClipmanShared.md`
- Private handover: `D:\Dropbox\txt\codex\Clipman.txt`

Behavior changed:

- Windows candidate version is now `1.5.13`; do not publish with a stale `1.5.12` Mac package.
- Quick Copy uses machine-specific settings: `QuickCopyHotkeys` stores per-entry hotkey assignments. There is no Preferences-level Quick Copy hotkey and no single-target bridge in the shipping Windows model.
- No Quick Copy field is stored in shared text entries or the `.clipdb` payload.
- Entry Properties can assign or clear a Quick Copy hotkey for the selected entry in the same workflow. Several entries can each have their own global Quick Copy hotkey.
- The selected entry menu has `Set as quick-copy target...`, which opens the same properties workflow focused on Quick Copy setup.
- Preferences has an opt-in General setting to put the latest text received from another machine onto this machine's clipboard. The Quick Copy hotkey must not ship in Preferences; assign Quick Copy only from Entry Properties / `Set as quick-copy target...`.
- Latest-remote-text copying baselines current remote history when enabled and writes to the local clipboard on the UI thread when a future external database change arrives.

Windows verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed and built `portable\clipman.exe`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -Version 1.5.13` passed, including GitHub issue and PR gate. There were no open GitHub issues or pull requests.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.5.13 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and deployed the candidate to Andre's live Dropbox Clipman copy.
- Live process restarted from `D:\Dropbox\SOFTWARE\clipman\clipman.exe`.
- Follow-up cleanup removed the Windows Preferences-level/default Quick Copy hotkey and the earlier single-target compatibility bridge before publication. `QuickCopyHotkeys` is the only Windows Quick Copy settings model. `Build.ps1`, full `SmokeTest.ps1 -Version 1.5.13`, and live deployment smoke all passed again after this cleanup.

Next action before any release:

- Manual-test Windows per-entry Quick Copy bindings: assign distinct hotkeys to at least two text entries from Entry Properties, verify both work globally, then clear one assignment and verify the other remains registered.
- Mac must package the current source as `ClipmanMac/dist/ClipmanMac-1.5.13.zip` before a shared release asset refresh.
- Do not push/release until Andre has confirmed manual testing if requested.

## Shared Manual Refactor - 2026-06-27

Windows refactored the shared root `Manual.html` so the documentation no longer treats Windows or Mac as the primary build.

Changed files:

- `Manual.html`
- `ClipmanShared.md`
- `CLIPMAN_AGENT_SYNC.md`

Behavior/documentation changed:

- The standalone early Mac manual section was removed.
- The old Default Hotkeys section is now `Keyboard Shortcuts`.
- Keyboard shortcuts are documented in one cross-platform table with three columns: what it does, Windows shortcut, and Mac shortcut.
- Genuine platform differences now live under a smaller `Platform Notes` section after Preferences.
- The Mac build scripts already package the shared root manual by copying `../Manual.html` into `Clipman.app/Contents/Resources/Manual.html`.
- This supersedes older handoff notes that said to preserve a standalone `Mac Version` manual section.

Mac next action:

- Read this note and the updated root `Manual.html`.
- Repackage or rebuild the Mac app so the bundle includes the updated shared manual.
- Verify `Clipman.app/Contents/Resources/Manual.html` is present and that `F1` opens the refreshed manual.

## Mac Packaging For Shared Manual Refactor - 2026-06-27

Mac read the updated `ClipmanShared.md`, `CLIPMAN_AGENT_SYNC.md`, and root `Manual.html` after Windows refactored the manual into one cross-platform document.

Packaging result:

- GitHub issue gate checked before release-style packaging; there are no open issues in `OnjLouis/Clipman`.
- `ClipmanMac/Scripts/package-release.sh` passed.
- Release package regenerated: `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.
- Packaged `dist/Clipman.app` reports `CFBundleShortVersionString=1.5.13` and `CFBundleVersion=1.5.13.0`.
- `codesign --verify --deep --strict dist/Clipman.app` passed.
- `dist/Clipman.app/Contents/Resources/Manual.html` is byte-for-byte identical to the refreshed root `Manual.html`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed `/Applications/Clipman.app` reports `1.5.13 / 1.5.13.0`.
- Installed `/Applications/Clipman.app/Contents/Resources/Manual.html` is byte-for-byte identical to the refreshed root `Manual.html`.
- The refreshed bundled manual contains the cross-platform `Keyboard Shortcuts` section, the `Windows shortcut` / `Mac shortcut` table columns, and `Platform Notes`; it no longer contains the old standalone `Mac Version` section.

F1 verification:

- Source path verified: `HistoryWindowController` handles `kVK_F1`, calls `historyWindowDidRequestManual`, and `AppController.openManual` opens `Bundle.main.resourceURL/Manual.html`.
- A live synthetic F1 keystroke test from shell was blocked by macOS because `osascript` is not allowed to send keystrokes on this machine. Manual user testing can still confirm the physical F1 path.

## Mac Shortcut Parity And Manual Pass - 2026-06-27

Andre asked Mac shortcuts and the shared manual to match Windows as closely as practical without changing normal Mac editing shortcuts such as `Command+C`, `Command+V`, and `Command+X`.

Changed files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipStore.swift`
- `ClipmanMac/Sources/Clipman/FileHistoryStore.swift`
- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `CLIPMAN_AGENT_SYNC.md`
- `Manual.html`
- `ClipmanShared.md`

Behavior changed on Mac:

- Added `F3` and `Shift+F3` to step through visible history/search results.
- Added `F4` to view selected text entries and file-history event details in a read-only window.
- Added `Option+Up` and `Option+Down` to move selected text entries or file-history events in manual order; pinned and normal items must be moved separately.
- Changed `Option+1` through `Option+0` group filters to match Windows/manual order: All, Pinned, Named, Ungrouped, then custom groups.
- Added `Control+F1` for the GitHub project page and `Option+F1` for a Mac diagnostics report.
- Added Project Page and Diagnostics to the Mac status menu and history-window Clipman menu.
- Existing Mac `Command+C`, `Command+V`, `Command+X`, `Command+1` through `Command+0`, `Command+Backspace`, `Control+Backspace`, and `Option+Backspace` behavior remains platform-appropriate.

Manual/documentation changed:

- `Manual.html` now documents the new Mac shortcut equivalents in the shared keyboard table.
- Notes, Basic Use, Preferences, Platform Notes, Startup, Groups, Sorting, File History, Updates, Sounds, Application Files, Non-text Clipboard Events, Send To, and Command Line sections now include Mac-facing wording where relevant instead of describing only `clipman.exe` or Windows behavior.
- Windows-only items such as Send To, command-line import/export, cleanup Actions, and Explorer go-to-file are now labelled as Windows-only or not-yet-available on Mac rather than implying Mac support.
- `CLIPMAN_AGENT_SYNC.md` records the Mac shortcut decisions and open Mac parity gaps.

Verification on macOS:

- GitHub release gate checked through the GitHub app: no open issues found for `OnjLouis/Clipman`.
- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- Release packaging produced `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running from `/Applications/Clipman.app/Contents/MacOS/Clipman`.
- Installed app version is `1.5.13 / 1.5.13.0`.
- Installed bundled manual is byte-for-byte identical to root `Manual.html`.

Windows next action:

- Read this file, `CLIPMAN_AGENT_SYNC.md`, and `Manual.html`.
- Include exactly the changed Mac/source/docs files listed above when publishing the next combined 1.5.13 release refresh.
- Preserve the shared manual's Mac-facing edits when making future Windows manual changes.

## Pinned Row Numbering And Navigation Parity - 2026-06-27

Andre asked Windows and Mac to align how pinned rows are spoken and how larger list navigation works.

Changed files:

- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `CLIPMAN_AGENT_SYNC.md`
- `Manual.html`
- `ClipmanShared.md`

Mac behavior changed:

- Pinned text entries and pinned file-history events now show their shortcut position in the visible row label when they are in the first ten pinned items: `1.`, `2.`, through `0.` for the tenth.
- Pinned state is still announced, but it appears in the row metadata as `Pinned: Yes` instead of before the item text.
- The `Normal entries` and `Normal file events` separator rows are selectable, matching Windows's dummy separator row. After pressing `Backspace` to jump to the first normal item, pressing Up once can land on the separator.
- `Home`, `End`, `Page Up`, and `Page Down` are handled in the Mac history table. `Home`/`End` go to first/last visible row. `Page Up`/`Page Down` move by roughly one visible page, matching native Windows list behavior rather than an app-defined fixed count.
- Pressing delete on a pinned text entry or pinned file-history event rejects the action without mutating storage.

Documentation changed:

- `Manual.html` now documents `Home`, `End`, `Page Up`, and `Page Down` in the shared keyboard table.
- `Manual.html` documents pinned numbering, `Pinned: Yes` placement, and selectable normal-entry separators.
- `CLIPMAN_AGENT_SYNC.md` records the cross-platform pinned-row and navigation behavior.

Verification on macOS:

- GitHub release gate checked through the GitHub app: no open issues found for `OnjLouis/Clipman`.
- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- Release packaging produced `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running from `/Applications/Clipman.app/Contents/MacOS/Clipman`.
- Installed app version is `1.5.13 / 1.5.13.0`.
- Installed bundled manual is byte-for-byte identical to root `Manual.html`.

Windows next action:

- Read this note, `CLIPMAN_AGENT_SYNC.md`, and `Manual.html`.
- Mirror the pinned row numbering and `Pinned` column/metadata placement on Windows if not already done.
- Preserve the shared manual edits when publishing the next combined 1.5.13 release refresh.

## Latest Remote Text Creation-Time Rule - 2026-06-27

Andre clarified that opt-in latest-remote-text clipboard handoff must only react to newly created remote entries. Reusing or copying an old pinned/history item on one machine is local intent and must not push that old text onto other opted-in machines.

Changed files:

- `ClipmanMac/Sources/Clipman/AppController.swift`
- `ClipmanMac/Sources/Clipman/ClipStore.swift`
- `CLIPMAN_AGENT_SYNC.md`
- `CLIPMAN_SHARED_CONTRACT.md`
- `Manual.html`
- `ClipmanShared.md`

Mac behavior changed:

- `ClipStore.latestRemoteEntry` was replaced with `newestRemoteCreatedEntry`, ordered by `CreatedUnixMs` only.
- `AppController.copyLatestRemoteTextIfNeeded()` and `resetRemoteClipboardBaseline()` now baseline and compare `CreatedUnixMs` only.
- `LastUsedUnixMs` updates from choosing/reusing an old entry no longer trigger latest-remote-text auto-copy on this Mac.
- Remote auto-copy still ignores this machine's own `SourceMachine`, remains opt-in, and still baselines current remote history before copying.

Documentation/contract changed:

- `CLIPMAN_SHARED_CONTRACT.md` now states that newest-remote-text handoff must use `CreatedUnixMs`, not `LastUsedUnixMs`.
- `CLIPMAN_AGENT_SYNC.md` records the cross-platform rule.
- `Manual.html` explains that reusing an old pinned/history item on another machine should not make this machine copy the old text.

Verification on macOS:

- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- Release packaging produced `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running from `/Applications/Clipman.app/Contents/MacOS/Clipman`.
- Installed app version is `1.5.13 / 1.5.13.0`.
- Installed bundled manual is byte-for-byte identical to root `Manual.html`.

Windows next action:

- Read this note plus `CLIPMAN_SHARED_CONTRACT.md`, `CLIPMAN_AGENT_SYNC.md`, and `Manual.html`.
- Mirror the same creation-time rule in Windows:
  - `ClipStore.GetNewestRemoteEntry` should order by `CreatedUnixMs`, not `Math.Max(LastUsedUnixMs, CreatedUnixMs)`.
  - `ClipmanApplicationContext.ResetRemoteAutoCopyBaseline` and `MaybeAutoCopyLatestRemoteEntry` should baseline/compare `CreatedUnixMs`, not `Math.Max(LastUsedUnixMs, CreatedUnixMs)`.
- Preserve the shared manual and contract updates when publishing the next combined release refresh.

## Mac Function-Key Routing Fix - 2026-06-27

Andre reported that choosing Project Page from the Mac Clipman menu worked, but pressing `Control+F1` from the history table did nothing.

Changed file:

- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`

Behavior fixed:

- Mac function-key shortcuts now run through the local key monitor as well as the normal window `keyDown` path, so the history table cannot swallow them before Clipman handles them.
- Covered function-key shortcuts:
  - `F1`: Manual
  - `Shift+F1`: Check for Updates
  - `Control+F1`: Project Page
  - `Option+F1`: Diagnostics
  - `F3`: next visible result
  - `Shift+F3`: previous visible result
  - `F4`: selected text/file-event details
- Editing shortcuts such as `Command+C`, `Command+X`, and `Command+V` were not moved into the monitor path.

Verification on macOS:

- GitHub release gate checked through the GitHub app: no open issues found for `OnjLouis/Clipman`.
- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- Release packaging produced `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running from `/Applications/Clipman.app/Contents/MacOS/Clipman`.
- Installed app version is `1.5.13 / 1.5.13.0`.
- Installed bundled manual is byte-for-byte identical to root `Manual.html`.

Windows next action:

- Include `ClipmanMac/Sources/Clipman/HistoryWindowController.swift` with the pending Mac 1.5.13 source set. No Windows code mirror is needed for this Mac-specific AppKit event-routing fix.

Windows next action: use this Mac package result when preparing the shared 1.5.13 release assets.

## Remote Sync Sound Split - 2026-06-27

Andre asked for remote clipboard sync to play its own sound. Windows now treats incoming latest-remote-text auto-copy as a separate sound event:

- `D:\projects\Forge\Remote.wav` was moved into Windows source assets as `Assets/sounds/remote.wav`.
- The same `remote.wav` asset was copied into `ClipmanMac/Sources/Clipman/Resources/sounds/remote.wav` so the Mac package can bundle it.
- Windows `SoundService` now exposes `Remote(bool enabled)` and `MaybeAutoCopyLatestRemoteEntry()` calls `sounds.Remote(settings.SoundsEnabled)` instead of the normal copy sound.
- Windows clipboard-monitor self writes from Clipman are ignored before the ignored-app/skip-sound path, so the remote sync write should not play `skip.wav` after `remote.wav`.
- Mac source was prepped from Windows: `SoundService.SoundName` now has `.remote`, and `copyLatestRemoteTextIfNeeded()` calls `sounds.play(.remote)`. Mac must still rebuild and verify this on macOS.
- `Manual.html` and `README.md` now include `remote.wav` in the custom sound override contract.
- `SmokeTest.ps1` now expects `remote.wav` in portable builds and asserts the remote sound path.

Windows verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -Version 1.5.13` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.5.13 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and deployed Andre's live Windows copy.

Mac next action:

- Read this note before packaging.
- Verify `remote.wav` is present in the bundled `Clipman.app/Contents/Resources/sounds`.
- Run the normal Mac build/smoke/package checks.
- Confirm remote latest-text sync plays `remote.wav`, while Quick Copy and ordinary local copy still play `copy.wav`.

## Windows Pinned Row Parity - 2026-06-27

Windows now mirrors the pinned-row behavior requested for the Mac build:

- Text-history pinned rows and file-history pinned rows display `1.`, `2.`, through `10.` for the first ten pinned items, matching the pinned quick-copy shortcuts.
- The pinned state still appears in the `Pinned` column instead of being prepended before the row text.
- Pressing Delete on pinned text entries or pinned file-history events now rejects the action with a status message and does not mutate storage or refresh the list.
- `README.md` and `SmokeTest.ps1` now guard the pinned numbering, pinned-column placement, Delete guards, and native list navigation documentation.

Windows notes for Mac:

- Windows uses native ListView behavior for `Home`, `End`, `Page Up`, and `Page Down`; page size is based on visible row count, not a fixed app-defined number.
- Windows already has selectable `Normal entries` and `Normal file events` separator rows. The Mac behavior should continue to match that: Backspace jumps to the first normal item and Up can land on the separator.

Windows verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -Version 1.5.13` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.5.13 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and redeployed Andre's live Windows copy.

## Remote Auto-Copy Created-Only Rule - 2026-06-27

Andre clarified that opt-in remote clipboard sync should only react to newly created remote text entries. If another machine puts an older/pinned entry on its local clipboard, that usually means the user wants to act on that machine; other machines should not auto-copy it.

Windows behavior changed:

- `ClipStore.GetNewestRemoteEntry()` now orders remote candidates by `CreatedUnixMs` only.
- Windows remote auto-copy baselines and compares `CreatedUnixMs` only.
- `LastUsedUnixMs` updates from reuse, normal copy, or Quick Copy no longer trigger remote auto-copy.
- Preferences, README, Manual, the shared contract, and smoke tests now use “newly created text entries” wording and guard against the old last-used based selection.

Mac next action:

- Mirror the same rule in Mac: latest-remote-text auto-copy must choose/baseline/compare remote entries by creation time only.
- Do not use `LastUsedUnixMs`, or `max(LastUsedUnixMs, CreatedUnixMs)`, for remote auto-copy trigger decisions.
- Reusing or Quick Copying an older entry on Mac must not cause Windows to auto-copy it, and the reverse must also hold.

Windows verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -Version 1.5.13` passed, including GitHub issue and PR gate. There were no open GitHub issues or pull requests.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.5.13 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and redeployed Andre's live Windows copy.

## Mac History Shortcut Polish - 2026-06-27

Andre reported three Mac history-window issues: `Control+F1` did not open the project page even though the menu item worked, Escape did not close the `F4` read-only details dialog, and pressing Enter from search left focus in the search field.

Changed files:

- `ClipmanMac/Sources/Clipman/HistoryWindowController.swift`
- `Manual.html`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`

Behavior changed:

- The documented Mac project-page shortcut is now `Command+F1`, because Andre confirmed macOS delivers it reliably while `Control+F1` can be intercepted before Clipman receives it. `Control+F1` remains a quiet fallback if the event is delivered.
- The Clipman menu now shows `Project Page    Command+F1`.
- The `F4` read-only details dialog binds Escape to its Close button.
- Pressing Enter in the search field returns focus to the history table. Pressing Escape in search clears the search and returns focus to the table.

Verified on macOS:

- GitHub issue gate checked for `OnjLouis/Clipman`; no open issues were returned.
- `swift build --scratch-path /tmp/ClipmanMac-build`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke`
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke`
- `ClipmanMac/Scripts/package-release.sh`
- Release packaging produced `ClipmanMac/dist/ClipmanMac-1.5.13.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app is running from `/Applications/Clipman.app/Contents/MacOS/Clipman`.
- Installed app version is `1.5.13 / 1.5.13.0`.
- Installed bundled manual is byte-for-byte identical to root `Manual.html`.
- Installed bundle includes `Contents/Resources/sounds/remote.wav`.

Windows next action:

- Include the four changed files listed above when preparing the shared 1.5.13 release/source set.

## Version Bump To 1.6 - 2026-06-27

Andre requested that the pending combined Windows/Mac build move from the local `1.5.13` candidate to `1.6` because the release now contains large cross-platform changes.

Changed files:

- `src/AssemblyInfo.cs`
- `README.md`
- `Manual.html`
- `CLIPMAN_AGENT_SYNC.md`
- `ClipmanShared.md`
- `D:\Dropbox\txt\codex\Clipman.txt`

Behavior/release state:

- Windows `AssemblyInformationalVersion` is now `1.6`.
- Windows `AssemblyVersion` and `AssemblyFileVersion` are now `1.6.0.0`.
- The user-facing changelog heading is now `1.6`, with wording that explains this is a larger cross-platform release.
- Latest public GitHub release is still `1.5.12` until Andre finishes testing and explicitly asks to publish.

Mac next action:

- Read `ClipmanShared.md`, `CLIPMAN_AGENT_SYNC.md`, and `CLIPMAN_SHARED_CONTRACT.md`.
- Rebuild/package from the current shared source so the app reports `1.6 / 1.6.0.0`.
- The Mac release asset should be `ClipmanMac/dist/ClipmanMac-1.6.zip`, not `ClipmanMac-1.5.13.zip`.
- Include the recent shared behavior: `remote.wav`, created-only remote auto-copy by `CreatedUnixMs`, per-entry Quick Copy, pinned row numbering, protected pinned deletes, and shared manual updates.
- Do not publish or replace release assets until Andre completes final manual testing.

Windows verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -Version 1.6` passed, including the GitHub issue and PR gate. There were no open GitHub issues or pull requests.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and deployed Andre's live Windows copy.
- The deployed Windows executable reports `ProductVersion=1.6` and `FileVersion=1.6.0.0`.

## Mac 1.6 Candidate Packaging - 2026-06-27

Mac rebuilt and packaged the current shared source after Windows bumped the source-of-truth version to `1.6`.

Verification:

- Read `ClipmanShared.md`, `CLIPMAN_AGENT_SYNC.md`, and `CLIPMAN_SHARED_CONTRACT.md`.
- `ClipmanMac/Scripts/shared-version.sh version` returns `1.6`.
- `ClipmanMac/Scripts/shared-version.sh build` returns `1.6.0.0`.
- GitHub issue/PR gate checked for `OnjLouis/Clipman`; no open issues or pull requests were returned.
- Source audit confirmed Mac latest-remote-text auto-copy uses `CreatedUnixMs` only through `newestRemoteCreatedEntry`, Quick Copy is registered per entry from machine settings, pinned deletes reject without mutation, pinned rows are numbered, and `remote.wav` is present in Mac resources.
- `swift build --scratch-path /tmp/ClipmanMac-build` passed.
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke` passed.
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke` passed.
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke` passed.
- `ClipmanMac/Scripts/package-release.sh` passed.
- Release packaging produced `ClipmanMac/dist/ClipmanMac-1.6.zip`.
- The ZIP's `Clipman.app` reports `CFBundleShortVersionString=1.6` and `CFBundleVersion=1.6.0.0`.
- The ZIP's bundled `Manual.html` matches root `Manual.html`.
- The ZIP includes `Clipman.app/Contents/Resources/sounds/remote.wav`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed `/Applications/Clipman.app` reports `1.6 / 1.6.0.0`, bundles the shared manual, and includes `remote.wav`.

Release note:

- Do not publish or replace GitHub release assets until Andre finishes final manual testing and explicitly asks to publish.

## Entry Properties Shortcut Decision - 2026-06-27

Andre decided to remove `Alt+Enter` for Entry Properties on both Windows and Mac. `F2` should be the single cross-platform shortcut for Entry Properties because it now covers the broader properties dialog: entry name, group, Quick Copy assignment, and stored text.

Mac state:

- No Mac code change was needed; Mac already uses `F2` to open the full Entry Properties dialog and has no `Option+Enter` Entry Properties route.
- `Manual.html` now documents `F2` only for Entry Properties on both platforms.
- `README.md` now describes `F2` as Entry Properties rather than only name/text editing.
- `CLIPMAN_AGENT_SYNC.md` records that `Alt+Enter` / `Option+Enter` should not be used for this command.
- `ClipmanMac/Scripts/package-release.sh` passed after the documentation change and regenerated `ClipmanMac/dist/ClipmanMac-1.6.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched. Installed app reports `1.6 / 1.6.0.0`, and its bundled manual matches root `Manual.html`.

Windows next action:

- Done on Windows: `Alt+Enter` is no longer wired for Entry Properties.
- Done on Windows: `F2` now opens the same full Entry Properties workflow that previously required `Alt+Enter`.
- Done on Windows: the older edit-only `EntryNameForm` path was removed so there is no narrower duplicate workflow.
- Preserve the updated shared manual and README wording when publishing 1.6.

## Mac 1.6 Pre-Release Code Audit - 2026-06-27

Andre requested a worthwhile Mac-side pre-release audit before pushing 1.6, focused on stale 1.5.13-era code, old shortcut logic, change-of-mind leftovers, avoidable slowness, and release-risk cleanup.

Mac changes made:

- Removed the hard-coded Andre-specific source-tree `Manual.html` fallback from `AppController.openManual`. The app now opens the bundled manual only; both dev and release app scripts already bundle `Manual.html`.
- Tightened history-window shortcut handling so documented shortcuts require the exact documented modifiers. This prevents combinations such as `Option+Shift+F2`, `Command+Option+1`, or `Option+Enter` from accidentally firing unrelated history commands while the window is focused.
- Removed the active legacy single Quick Copy settings model from Mac (`quickCopyHotkey` / `quickCopyEntryID`). Modern settings write only the per-entry `quickCopyHotkeys` dictionary. Old settings files can still be read and migrated into the dictionary once.
- Removed the dead `didSetQuickCopyTarget` delegate path and the dead `ClipboardMonitor.pasteboardContainsFiles` helper.
- Hardened text-history write paths so a failed latest-merge/password load aborts the pending mutation instead of reporting an error and then saving over the database.
- Hardened Mac file-history writes so a missing/wrong password locks writes instead of replacing an encrypted machine file-history database with a blank unencrypted/default database.
- Updated `README.md` to remove the stale default Quick Copy hotkey wording.
- Updated `ClipmanMac/README.md` so group-filter shortcut documentation matches the app and shared manual: `Option+1` starts with All, Pinned, Named, Ungrouped, then custom groups.
- Updated this shared log to clarify that legacy Quick Copy fields are decode-only migration fields, not default-fill fields.

Verification:

- GitHub issue/PR gate checked for `OnjLouis/Clipman`; no open issues or pull requests were returned.
- `swift build --scratch-path /tmp/ClipmanMac-build` passed.
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanCodecSmoke` passed.
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanSyncSmoke` passed.
- `swift run --scratch-path /tmp/ClipmanMac-build ClipmanFileHistorySmoke` passed.
- `ClipmanMac/Scripts/package-release.sh` passed, including release-mode smoke tests.
- Release package regenerated: `ClipmanMac/dist/ClipmanMac-1.6.zip`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed app reports `1.6 / 1.6.0.0`, bundles root `Manual.html`, and includes `remote.wav`.
- The ZIP's `Clipman.app` reports `1.6 / 1.6.0.0`, bundles root `Manual.html`, and includes `remote.wav`.

Windows next action:

- Use the full-source release rule. Include the Mac audit cleanup files with the complete intended 1.6 source tree, not as a cherry-picked subset from older handoff notes.
- Do not publish until Andre completes final manual testing and explicitly asks to publish.

## Windows 1.6 Pre-Release Code Audit - 2026-06-27

Andre requested a worthwhile Windows-side pre-release audit before pushing 1.6, focused on stale 1.5.13-era code, old shortcut logic, change-of-mind leftovers, avoidable slowness, and release-risk cleanup.

Windows changes made:

- Removed the stale edit-only `EntryNameForm` path after Entry Properties became the single F2 workflow for name, group, Quick Copy assignment, pinned state, and stored text.
- Removed the old Alt+Enter Entry Properties route. Windows now blocks Alt+Enter in the history list with a status hint instead of letting it fall through as ordinary Enter/copy.
- Quick Copy assignment changes made inside Entry Properties now refresh global hotkeys immediately after saving.
- Updated Entry Properties accessibility text so the stored clipboard text field is no longer described as read-only.
- Updated `README.md`, `Manual.html`, `SmokeTest.ps1`, and the private handover so F2-only Entry Properties and immediate Quick Copy hotkey refresh are documented and guarded.
- Updated release rules so the shipped `sounds\remote.wav` factory sound is included in the expected portable-output list.

Verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -Version 1.6` passed, including the GitHub issue and PR gate. There were no open GitHub issues or pull requests.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and redeployed Andre's live Windows copy.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CommunitySearch.ps1` completed. The generated checklist only surfaced the existing GitHub issue history/search links and was removed afterward so generated output is not committed.
- `git diff --check` passed, with only normal line-ending warnings from Git.
- Stale-code scans found no remaining shipping-source/docs references to `NameSelectedEntry`, `EntryNameForm`, or `Read-only clipboard text`.
- Windows source scan found no `TODO`, `HACK`, `TEMP`, `test only`, `debug`, or `NotImplemented` markers.
- Tracked/untracked source checks found no `Settings`, `Logs`, machine settings JSON, or `.clipdb` runtime data staged for shipping.

## Windows Alt+Number Menu Focus Fix - 2026-06-27

Andre found that Windows `Alt+1` through `Alt+0` group-filter shortcuts performed the group jump but also left focus in the menu bar.

Changed files:

- `src/HistoryForm.cs`
- `README.md`
- `Manual.html`
- `SmokeTest.ps1`
- `ClipmanShared.md`

Behavior changed:

- `Alt+1` through `Alt+0` are now consumed at form command-key level before the menu bar receives them.
- The list-level handler also suppresses those keypresses after jumping group filters.
- The live Windows `LICENSE.txt` in `D:\Dropbox\SOFTWARE\clipman` was refreshed from source because it still contained the old Sensor Readout copyright text.
- `Manual.html` now includes a keyboard-shortcut table row for `Backspace` jumping to the first normal item below pinned items, matching the existing text/file history behavior and current smoke expectations.

Windows verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck` passed.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck -LivePath D:\Dropbox\SOFTWARE\clipman` passed and redeployed Andre's live Windows copy.
- Live `D:\Dropbox\SOFTWARE\clipman\clipman.exe` reports product version `1.6`, file version `1.6.0.0`, company `Andre Louis`.
- Live `D:\Dropbox\SOFTWARE\clipman\LICENSE.txt` now starts with `Copyright (c) 2026 Clipman contributors`.

Windows next action:

- Do not publish until Andre explicitly asks to publish. When publishing, include this Windows fix with the full intended 1.6 source set and the Mac ignored-app follow-up files already recorded above.

## Shared License Packaging Follow-Up - 2026-06-27

Andre asked whether `LICENSE.txt` was part of shared assets so both platforms include it. It is not in `Assets`; it is a repo-root document, matching `Manual.html`.

Changed files:

- `ClipmanMac/Scripts/package-release.sh`
- `ClipmanMac/Scripts/build-dev-app.sh`
- `SmokeTest.ps1`
- `ClipmanShared.md`

Behavior changed:

- Mac dev and release app scripts now copy root `LICENSE.txt` into `Clipman.app/Contents/Resources/LICENSE.txt`, alongside `Manual.html`.
- Windows already copies root `LICENSE.txt` from `Build.ps1`; no Windows packaging behavior change was needed.
- Smoke test now guards that both Mac app packaging scripts bundle the root license file.

Verification:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SmokeTest.ps1 -SkipBuild -Version 1.6 -SkipGitHubActivityCheck` passed on Windows.

Mac verification:

- `ClipmanMac/Scripts/package-release.sh` passed on macOS and regenerated `ClipmanMac/dist/ClipmanMac-1.6.zip`.
- The packaged ZIP contains `Clipman.app/Contents/Resources/LICENSE.txt` and `Clipman.app/Contents/Resources/Manual.html`.
- `/Applications/Clipman.app` was replaced from `ClipmanMac/dist/Clipman.app` and relaunched.
- Installed `/Applications/Clipman.app` reports `1.6 / 1.6.0.0`.
- Installed `Contents/Resources/LICENSE.txt` matches root `LICENSE.txt`; installed `Contents/Resources/Manual.html` matches root `Manual.html`.
- `codesign --verify --deep --strict /Applications/Clipman.app` passed.
