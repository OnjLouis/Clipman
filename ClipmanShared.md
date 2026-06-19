# Clipman Shared Agent Log

This is the quick cross-platform coordination file for Clipman agents. Every Mac or Windows Codex agent should read this file, `CLIPMAN_AGENT_SYNC.md`, and `CLIPMAN_SHARED_CONTRACT.md` before making Clipman changes.

Use this file for brief current-state notes and handoffs. Use `CLIPMAN_SHARED_CONTRACT.md` for mandatory database, settings, sync, password, and shared-history compatibility rules. Use `CLIPMAN_AGENT_SYNC.md` for longer-lived parity decisions, keyboard/UI choices, and release workflow notes.

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
