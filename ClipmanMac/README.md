# Clipman for macOS

Native macOS implementation of Clipman, sharing the same text-history `.clipdb` database contract as the Windows Clipman project.

## Required Coordination

Before changing database, settings, sync, password, or shared-history behavior, read:

```text
<repo root>\CLIPMAN_SHARED_CONTRACT.md
```

Before changing product parity, keyboard behavior, menus, or cross-platform workflow, also read:

```text
<repo root>\CLIPMAN_AGENT_SYNC.md
```

On the Mac, the same file should be reachable from the sibling folder under Dropbox, for example:

```text
<repo root>/CLIPMAN_SHARED_CONTRACT.md
```

Both Windows and macOS implementations must stay compatible with that contract. If a shared behavior changes, update both implementations and the contract document in the same work cycle, or clearly mark the feature as platform-specific.

## Project Shape

Swift package targets:

- `ClipmanCore`: shared `.clipdb` codec and models.
- `Clipman`: AppKit menu-bar application.
- `ClipmanCodecSmoke`: codec smoke tests for compressed and encrypted database round-trips.
- `ClipmanSyncSmoke`: shared-history folder watcher/reload smoke tests.
- `ClipmanFileHistorySmoke`: machine-specific file-history `.clipdb` smoke tests.

## Storage

The shared text history database is always named:

```text
clipman-history.clipdb
```

Preferences choose a Clipman data folder and the app derives that file name inside it. File clipboard events are stored separately in a machine-specific database beside it:

```text
<MachineName>-file-history.clipdb
```

The file-history database stores file paths and event metadata, not file contents. It uses the same history password as the shared text database when one is configured.

The active machine settings file also lives in the selected data folder:

```text
<MachineName>-settings.json
```

macOS keeps only a small Application Support pointer so it can find that folder again on launch.

Ignored applications are machine-specific settings. Add one Mac app name, bundle identifier, or executable name per line in Preferences, such as `Safari`, `com.apple.TextEdit`, or `KeePassXC`. When the foreground app matches that list, Clipman does not capture text or file clipboard changes from it.

## Smoke Test

Run:

```bash
swift run ClipmanCodecSmoke
swift run ClipmanSyncSmoke
swift run ClipmanFileHistorySmoke
```

When database compatibility changes, also perform a manual cross-platform smoke:

1. Windows writes a text entry and Mac reads it.
2. Mac writes a text entry and Windows reads it.
3. Source machine names survive both ways.
4. Encrypted databases reject wrong passwords without corrupting the file.
5. Finder/file clipboard events appear in File History and do not appear in shared Text History.

## History Window Shortcuts

The history window includes an accessible toolbar after the history type control. The Clipman button remains tabbable as the main command menu; Set Group, Set to current filter, Filter, selected group status, Sort, Direction, and Preferences are exposed in the toolbar for VoiceOver navigation without adding extra Tab stops.

- `Control+1`: Text History.
- `Control+2`: File History.
- `Option+M`: Open the Clipman actions menu.
- `Command+G`: group selected text entries.
- `Option+G`: open the group filter menu.
- `Option+1` through `Option+0`: apply one of the first ten group filters in menu order: All, Pinned, Named, Ungrouped, then custom groups.
- `Command+1` through `Command+0`: choose one of the first ten pinned items in the active history.
- `Enter`: choose the selected text entry or restore the selected file event.
- `Shift+Enter`: pin or unpin the selected item.
- `Command+C`: copy selected text entries or selected file paths.
- `Command+X`: cut selected text entries.
- `Command+V`: paste clipboard text after the selected text entry.
- `Command+I`: import clipboard entries from `.clipdb`, JSON, or text.
- `Command+E`: export clipboard entries to `.clipdb`, JSON, or text.
- `Command+Shift+R`: remove URL tracking from selected text entries.
- `Command+Shift+S`: clean selected links for sharing.
- `Command+Enter`: go to the selected file-history file or folder in Finder.
- `Command+Backspace`: delete selected unpinned items.
- `Backspace`: jump to the first normal item below pinned items.
- `Command+F`: focus search.
- `Escape`: hide the history window.

For VoiceOver users, `Option+M` opens the history window's Clipman command menu directly. If macOS reports a new Clipman window but focus lands badly, press the Show History global hotkey once to dismiss the window and again to reopen it with a fresh focus attempt.

## Development App Build

Build a normal launchable development app with:

```bash
Scripts/build-dev-app.sh
```

The app is created at:

```text
build/Clipman.app
```

To rebuild and restart it after changes:

```bash
Scripts/build-dev-app.sh --restart
```

This is an ad-hoc signed development app, not a notarized public release.

## Tester Zip

Build a release app zip for testers with:

```bash
Scripts/package-release.sh
```

The zip is created at:

```text
dist/ClipmanMac-<version>.zip
```

Testers should unzip it, move or drag `Clipman.app` into `/Applications`, then open it with Control-click or Option-click and choose Open if macOS Gatekeeper blocks the unsigned app on first launch. VoiceOver users can use `VO+Shift+M` on the app in Finder to open the same context menu, then choose Open.

In Preferences, enable `Run Clipman at login` after the app is in `/Applications`. This writes a per-user LaunchAgent pointing at the current app bundle path, so if the app is moved later, save Preferences again to refresh the login item.
