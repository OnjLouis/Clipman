# Clipman Agent Sync

This is the day-to-day coordination file for Codex agents working on Windows Clipman and Clipman for macOS.

Always read `ClipmanShared.md`, this file, and `CLIPMAN_SHARED_CONTRACT.md` before changing either implementation. Treat `CLIPMAN_SHARED_CONTRACT.md` as the mandatory compatibility contract for database, settings, sync, password, and shared-history behavior. Use this file for product parity, keyboard/UI decisions, recent changes, and handoff notes.

## Repositories

```text
Repository: /Users/andrelouis/Dropbox/backups/Codex/current/clipman
Windows:    /Users/andrelouis/Dropbox/backups/Codex/current/clipman/src
macOS:      /Users/andrelouis/Dropbox/backups/Codex/current/clipman/ClipmanMac
```

Older Windows notes may show `D:\Dropbox\backups\Codex\current`; on macOS that maps to `/Users/andrelouis/Dropbox/backups/Codex/current`.

## Current Shared Storage Model

- User chooses a Clipman data/settings folder.
- Shared text history lives at `clipman-history.clipdb` inside that folder.
- Machine settings live as `<MachineName>-settings.json` inside that folder.
- Machine file history lives as `<MachineName>-file-history.clipdb` inside that folder.
- Passwords are not shared in settings:
  - Windows uses DPAPI-protected per-user/per-machine storage.
  - macOS uses Keychain keyed by database path.

## Current macOS Keyboard/UI Decisions

- Global hotkeys:
  - Show History: `Option+Shift+\`
  - Toggle Monitoring: `Option+Shift+grave`
- `Command+grave` must remain macOS Switch Windows and must not be used by Clipman.
- History window:
  - The history window has an accessible toolbar after the history type control. `Clipman` remains tabbable; Set Group, Set to current filter, Filter, selected group status, Sort, Direction, and Preferences are toolbar controls for VoiceOver navigation.
  - `Control+1`: Text History.
  - `Control+2`: File History.
  - `Option+M`: opens the bespoke Clipman menu.
  - `Command+G`: group selected text entries.
  - `Option+G`: opens the group filter menu.
  - `Option+1` through `Option+0`: apply one of the first ten real groups; reserved filters such as All and Ungrouped stay menu-only.
  - `Command+1` through `Command+0`: choose pinned item 1-10 in the active history.
  - Clipboard writes initiated by Clipman must play the bundled copy sound as confirmation, including choose/copy text and file-history restore/copy.
  - `Enter`: choose selected text entry or restore selected file event.
  - `Shift+Enter`: pin/unpin selected item.
  - `Command+C`: copy selected text entries or file paths.
  - `Command+X`: cut selected text entries.
  - `Command+V`: paste clipboard text after selected text entry.
  - `Command+Backspace`: delete selected unpinned items.
  - `Backspace`: jump to first normal item below pinned items.
  - `Command+F`: focus search.
  - `Escape`: hide history.
- The macOS history window uses a bespoke `Clipman` menu button because the app is an accessory/status app and may not expose a reliable normal menu bar to VoiceOver users.
- The Text/File history control should stay near the relevant table. Less-used sort and command actions belong in the bespoke Clipman menu.

## Recent macOS Changes

- macOS settings moved from Application Support into the selected Clipman data folder. Application Support keeps only a small `settings-location.json` pointer.
- macOS Preferences includes `Run Clipman at login`, implemented with a per-user LaunchAgent so unsigned tester builds can launch at startup without notarization.
- macOS has `Scripts/package-release.sh`, which builds `dist/ClipmanMac.zip` containing a drag-to-Applications `Clipman.app` for testers.
- macOS release and dev app bundles read the Windows release version from root `src/AssemblyInfo.cs` through `ClipmanMac/Scripts/shared-version.sh`. `CFBundleShortVersionString` matches `AssemblyInformationalVersion`; `CFBundleVersion` matches `AssemblyFileVersion`.
- macOS bundled sounds are copied into `Clipman.app/Contents/Resources/sounds` by `Scripts/build-dev-app.sh` and `Scripts/package-release.sh`. `SoundService` must load them through `Bundle.main.resourceURL`, not `Bundle.module`; using SwiftPM resources here caused packaged apps to crash looking for `ClipmanMac_Clipman.bundle`.
- Future GitHub releases attach the Windows portable ZIP and `ClipmanMac/dist/ClipmanMac.zip` to the same release. Windows remains the source of truth for Git history, release workflow, and version numbers.
- macOS file history now uses a separate machine-specific `.clipdb` and no longer writes file clipboard events into shared text history.
- macOS has in-window Text/File history switching, sorting, pinned shortcuts, and a bespoke Clipman menu.
- macOS has basic text-entry group assignment and group filtering through the bespoke Clipman menu.
- macOS shows selected text-entry group status in the toolbar and offers `Set selected to current filter` when the active filter is a real group.
- Status/menu key equivalents for Show History and Toggle Monitoring were removed to avoid hijacking `Command+grave`.

## Current Testing Baseline

macOS:

```bash
cd /Users/andrelouis/Dropbox/backups/Codex/current/clipman/ClipmanMac
Scripts/build-dev-app.sh --restart
```

That runs:

```text
ClipmanCodecSmoke
ClipmanSyncSmoke
ClipmanFileHistorySmoke
```

Windows smoke path from the shared contract remains authoritative for Windows.

## Coordination Rules

- When either platform changes shared storage, settings-folder behavior, password behavior, sync behavior, or serialized fields, update `CLIPMAN_SHARED_CONTRACT.md`.
- When either platform changes UI parity, shortcut behavior, menu structure, or daily-driver workflow, update this file.
- When implementing a Mac behavior that Windows should mirror, add a note here for the Windows agent.
- When implementing a Windows behavior that Mac should mirror, add a note here for the Mac agent.
- Do not rely only on chat history for cross-platform decisions.

## Open Parity Work

- Import/export UI on macOS.
- Fuller Preferences on macOS.
- Diagnostics/help report on macOS.
- Signing, notarization, and installer/DMG plan for public macOS distribution.
- Consider mirroring macOS pinned shortcuts submenu structure in Windows.
