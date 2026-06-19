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
