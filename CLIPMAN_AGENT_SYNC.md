# Clipman Agent Sync

This is the day-to-day coordination file for Codex agents working on Windows Clipman and Clipman for macOS.

Always read `ClipmanShared.md`, this file, and `CLIPMAN_SHARED_CONTRACT.md` before changing either implementation. Treat `CLIPMAN_SHARED_CONTRACT.md` as the mandatory compatibility contract for database, settings, sync, password, and shared-history behavior. Use this file for product parity, keyboard/UI decisions, recent changes, and handoff notes.

## Repositories

```text
Repository: <Codex workspace root>/clipman
Windows:    <Codex workspace root>/clipman/src
macOS:      <Codex workspace root>/clipman/ClipmanMac
```

Older Windows notes may show `<Codex workspace root>`; on macOS that maps to `<Codex workspace root>`.

## Current Shared Storage Model

- User chooses a Clipman data/settings folder.
- Shared text history lives at `clipman-history.clipdb` inside that folder.
- Machine settings live as `<MachineName>-settings.json` inside that folder.
- Machine file history lives as `<MachineName>-file-history.clipdb` inside that folder.
- Database passwords are not stored in the shared `.clipdb` files.
- Remembering the database password is optional and should default off on new installs:
  - When remember is off, each platform prompts once per app session and keeps the password only in process memory.
  - Windows may use DPAPI-protected per-user/per-machine storage only when remember is explicitly enabled.
  - macOS may use Keychain keyed by database path only when remember is explicitly enabled.
  - Remembered passwords are convenience, not protection from malware or tools running as the same signed-in user.

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
  - `Option+1` through `Option+0`: apply one of the first ten group filters in Windows/manual order: All, Pinned, Named, Ungrouped, then custom groups.
  - `Command+1` through `Command+0`: choose pinned item 1-10 in the active history.
  - Pinned text entries and pinned file-history events are numbered in the visible row label when they are in the first ten shortcut positions. The pinned state is still exposed as `Pinned: Yes` in metadata rather than being spoken before the item text.
  - `F3` / `Shift+F3`: move to next/previous visible search result; if search is empty, focus the search field instead, matching Windows.
  - `F4`: view selected text entry or file-history event details in a read-only window.
  - `Option+Up` / `Option+Down`: move selected text entries or file-history events in manual order. Pinned and normal items must be moved separately.
  - `Command+F1`: open the project page. `Control+F1` is accepted if macOS passes it through, but it is not the documented Mac shortcut because it can be intercepted before Clipman receives it.
  - `Option+F1`: open diagnostics.
  - Clipboard writes initiated by Clipman must play the bundled copy sound as confirmation, including choose/copy text and file-history restore/copy.
  - `Enter`: choose selected text entry or restore selected file event.
  - `Shift+Enter`: pin/unpin selected item.
  - `Command+C`: copy selected text entries or file paths.
  - `Command+X`: cut selected text entries.
  - `Command+V`: paste clipboard text after selected text entry.
  - `Command+Backspace`: delete selected unpinned items.
  - `Control+Backspace`: clear normal file history when File history is active.
  - `Option+Backspace`: remove unavailable unpinned file-history events when File history is active.
  - `Backspace`: jump to first normal item below pinned items.
  - `Home` / `End`: first/last visible history row.
  - `Page Up` / `Page Down`: move by roughly one visible page of rows, matching the native Windows list behavior rather than a fixed app-defined count.
  - `Command+F`: focus search.
  - `Escape`: hide history.
  - `F2`: open Entry Properties. `Alt+Enter` / `Option+Enter` should not be used for this command.
  - `Command+I`: import text-history entries from `.clipdb`, JSON, or text.
  - `Command+E`: export text history to `.clipdb`, JSON, or text.
  - `Command+Shift+R`: remove URL tracking parameters from selected text entries, update storage, and copy the cleaned text to the Mac clipboard.
  - `Command+Shift+S`: clean selected links for sharing, including YouTube share-state parameters, update storage, and copy the cleaned text to the Mac clipboard.
  - `Command+Enter`: go to the selected file-history file or folder in Finder.
- The normal-entry separator is selectable on macOS, matching the Windows dummy row. After `Backspace` jumps to the first normal item, pressing Up once should land on `Normal entries` or `Normal file events` when a pinned section exists.
- Delete on a pinned text entry or pinned file-history event should not mutate storage or trigger a reload; it should simply reject the action.
- Pressing the global Show History hotkey while the macOS history window is already visible hides it. This gives VoiceOver users a reliable recovery path when macOS reports a new window but focus lands badly: press once to dismiss, then press again to reopen with a fresh focus attempt.
- When showing history, macOS force-orders the window front, activates the accessory app, focuses the history table, posts an accessibility focus notification, and repeats focus attempts after short delays.
- The macOS history window uses a bespoke `Clipman` menu button because the app is an accessory/status app and may not expose a reliable normal menu bar to VoiceOver users.
- The shared manual should mention Mac VoiceOver-specific access where it removes friction: `Option+M` for the history window Clipman menu, `VO+Shift+M` for Finder context menu/Open on unsigned tester builds, and the Show History hotkey recovery path when macOS reports a new window without landing focus correctly.
- The Text/File history control should stay near the relevant table. Less-used sort and command actions belong in the bespoke Clipman menu.

## Recent Cross-Platform Changes

- Windows and macOS 1.5.12 hardening makes remembered database passwords explicit and optional. New settings default to remember off. Windows uses DPAPI only when remember is on; macOS uses Keychain only when remember is on. When remember is off, each platform prompts once per app session, keeps the password only in process memory, and clears saved platform password storage.
- Windows and macOS 1.6 add machine-specific Quick Copy and latest-remote-text behavior. Quick Copy stores per-entry hotkey assignments in this machine's settings, so several clips can each have their own global hotkey. The opt-in latest-remote-text setting copies future newly created text entries received from another machine onto the local clipboard after baselining current history. It must compare `CreatedUnixMs`, not `LastUsedUnixMs`, so reusing an old pinned/history item on one machine does not push that old clip to other machines. Do not store either behavior in shared text entries.
- `Manual.html` is the shared manual source for Windows and macOS. Keep it platform-neutral wherever possible. Keyboard shortcuts should use the shared three-column table: what it does, Windows shortcut, and Mac shortcut. Put genuine platform differences in the Platform Notes section rather than maintaining separate Windows/Mac manual blocks.

## Recent macOS Changes

- macOS settings moved from Application Support into the selected Clipman data folder. Application Support keeps only a small `settings-location.json` pointer.
- macOS Preferences includes `Run Clipman at login`, implemented with a per-user LaunchAgent so unsigned tester builds can launch at startup without notarization.
- macOS has `Scripts/package-release.sh`, which builds a versioned `dist/ClipmanMac-<version>.zip` containing a drag-to-Applications `Clipman.app` for testers.
- macOS release and dev app bundles read the Windows release version from root `src/AssemblyInfo.cs` through `ClipmanMac/Scripts/shared-version.sh`. `CFBundleShortVersionString` matches `AssemblyInformationalVersion`; `CFBundleVersion` matches `AssemblyFileVersion`.
- macOS bundled sounds are copied into `Clipman.app/Contents/Resources/sounds` by `Scripts/build-dev-app.sh` and `Scripts/package-release.sh`. `SoundService` must load them through `Bundle.main.resourceURL`, not `Bundle.module`; using SwiftPM resources here caused packaged apps to crash looking for `ClipmanMac_Clipman.bundle`.
- Future GitHub releases attach the Windows portable ZIP and the versioned Mac ZIP from `ClipmanMac/dist/ClipmanMac-<version>.zip` to the same release. Windows remains the source of truth for Git history, release workflow, and version numbers.
- macOS file history now uses a separate machine-specific `.clipdb` and no longer writes file clipboard events into shared text history.
- macOS has in-window Text/File history switching, sorting, pinned shortcuts, and a bespoke Clipman menu.
- macOS has basic text-entry group assignment and group filtering through the bespoke Clipman menu.
- macOS text captures now set the shared text-entry `Group` to the foreground source application name when available, matching Windows app-created group behavior.
- macOS shows selected text-entry group status in the toolbar and offers `Set selected to current filter` when the active filter is a real group.
- Status/menu key equivalents for Show History and Toggle Monitoring were removed to avoid hijacking `Command+grave`.
- macOS Preferences now includes opt-in update checks, optional silent update install, and opt-in copying of the latest remote text entry to this Mac clipboard. Quick Copy is not configured in Preferences; individual text entries each get their own global Quick Copy hotkey from Entry Properties or `Set As Quick Copy Target...`, and assignments are stored in machine settings only.
- macOS Preferences includes machine-specific ignored applications. Mac matching accepts app names, bundle identifiers, or executable names, such as `Safari`, `com.apple.TextEdit`, or `KeePassXC`, and skips text/file clipboard capture while a matching foreground app owns the copy workflow.
- macOS packages include the shared `Manual.html` in `Clipman.app/Contents/Resources`. The history window opens it with `F1`; `Shift+F1` checks for updates; `Command+F1` opens the project page; `Option+F1` opens diagnostics. The Clipman status/menu also includes `Open Manual`, `Check for Updates...`, `Version History...`, `Project Page`, `Contact`, `Donate`, and `Diagnostics...`.

## Current Testing Baseline

macOS:

```bash
cd <Codex workspace root>/clipman/ClipmanMac
Scripts/build-dev-app.sh --restart
```

That runs:

```text
ClipmanCodecSmoke
ClipmanSyncSmoke
ClipmanFileHistorySmoke
```

Windows smoke path from the shared contract remains authoritative for Windows.

## Release Gate: GitHub Issues

Before publishing any Clipman release, release-asset refresh, or hotfix, the active agent must read GitHub issues and decide whether any open issue needs action. Do not ship first and check issues afterward.
## Coordination Rules

- When either platform changes shared storage, settings-folder behavior, password behavior, sync behavior, or serialized fields, update `CLIPMAN_SHARED_CONTRACT.md`.
- When either platform changes UI parity, shortcut behavior, menu structure, or daily-driver workflow, update this file.
- When implementing a Mac behavior that Windows should mirror, add a note here for the Windows agent.
- When implementing a Windows behavior that Mac should mirror, add a note here for the Mac agent.
- Do not rely only on chat history for cross-platform decisions.

## Open Parity Work

- Fuller Preferences on macOS.
- Signing, notarization, and installer/DMG plan for public macOS distribution.
- Consider mirroring macOS pinned shortcuts submenu structure in Windows.
