# Clipman for macOS

Native macOS implementation of Clipman, sharing the same text-history `.clipdb` database contract as the Windows Clipman project.

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

The normal development build runs all three smoke executables and keeps compiler output beneath `~/Projects/Codex/Temp/clipman`:

```bash
Scripts/build-dev-app.sh
```

When database compatibility changes, also perform a manual cross-platform smoke:

1. Windows writes a text entry and Mac reads it.
2. Mac writes a text entry and Windows reads it.
3. Source machine names survive both ways.
4. Encrypted databases reject wrong passwords without corrupting the file.
5. Finder/file clipboard events appear in File History and do not appear in shared Text History.

## Window and Menu Bar

Clipman keeps its menu extra while running. Opening History, Preferences, Secrets, or Sync Rules shows Clipman in the Dock and Command-Tab with native menus. After the last window closes, Clipman returns to menu-extra-only mode without quitting clipboard monitoring.

The native menu bar provides Clipman, File, Edit, Actions, Groups, Quick Paste, View, Window, and Help menus. Check for Updates is in the Clipman menu. History commands follow the current tab and selection. Commands that require a history selection are disabled when another Clipman window has focus. In File History, Actions also provides Clear Unpinned File History and Remove Unavailable File Events. Clearing asks for confirmation and never deletes files from disk.

## History Window Shortcuts

The history window includes an accessible toolbar after the history type control. Set Group, Set to current filter, Filter, selected group status, Sort, Direction, and Preferences remain available there without adding extra Tab stops. Use the native menu bar for the full command set.

- `Command+1` through `Command+4`: switch to the visible history area currently shown at that position. The View menu shows the current assignments.
- `Option+Left` or `Option+Right`: move the focused history tab, keep focus on it, and update the positional `Command+number` assignments.
- `Tab` or `Shift+Tab`: enter the selected history tab from the normal key loop and continue between the main controls and history list.
- `Command+G`: group selected text entries.
- `Option+G`: open the group filter menu.
- `Option+1` through `Option+0`: apply one of the first ten group filters in menu order: All, Pinned, Named, Ungrouped, then custom groups.
- `Control+1` through `Control+0`: choose one of the first ten pinned items in the active history.
- `Option+Up` or `Option+Down`: move selected entries in manual order.
- `Enter`: choose the selected text entry or restore the selected file event.
- `Shift+Enter`: pin or unpin the selected item.
- `Command+C`: copy selected text entries or selected file paths.
- `Command+X`: cut selected text entries.
- `Command+V`: paste clipboard text after the selected text entry.
- `Command+N`: open Quick Clip and type a new saved entry directly.
- `Option+Enter`: open the selected standalone HTTP or HTTPS link in the default browser.
- `Command+I`: import clipboard entries from `.clipdb`, JSON, or text.
- `Command+E`: export clipboard entries to `.clipdb`, JSON, or text.
- `Command+Shift+R`: remove URL tracking from selected text entries.
- `Command+Shift+S`: clean selected links for sharing.
- `Command+Enter`: go to the selected file-history file or folder in Finder.
- `Command+Backspace`: delete selected unpinned items.
- `Control+Backspace`: clear unpinned File History after confirmation.
- `Option+Backspace`: remove unavailable unpinned file-history events.
- `Backspace`: jump to the first normal item below pinned items.
- `Home` or `End`: jump to the first or last history row.
- `Page Up` or `Page Down`: move through the history list by page.
- `Command+F`: focus search.
- `Escape`: hide the history window.
- `Command+W`: close the focused Clipman window. Closing History hides it in the menu bar.

Preferences can assign an optional global Quick Clip hotkey. It is unset by default and opens the same editor from another application without reading or replacing the current clipboard.

Add current clipboard item on start adds genuinely new content but leaves an existing entry or file event unchanged, including its original device, group, and timestamp.

For VoiceOver users, the native File, Edit, Actions, Groups, Quick Paste, View, Window, and Help menus provide history commands while a Clipman window is open. If macOS reports a new Clipman window but focus lands badly, press the Show History global hotkey once to dismiss the window and again to reopen it with a fresh focus attempt.

## Development App Build

Build a normal launchable development app with:

```bash
Scripts/build-dev-app.sh
```

The app is created at:

```text
~/Projects/Codex/Temp/clipman/mac-dev/Clipman.app
```

Compiler intermediates are removed after each build so the source tree remains clean.

To rebuild and restart it after changes:

```bash
Scripts/build-dev-app.sh --restart
```

This is an ad-hoc signed development app, not a notarized public release.

## Release Zip

Build a release app zip for testers with:

```bash
Scripts/package-release.sh
```

The default Apple Silicon signed and notarized ZIP is created at:

```text
~/Projects/Codex/Temp/clipman/mac-release-dist/Clipman-macOS-<version>.zip
```

Set `CLIPMAN_MAC_ARCH=x86_64` to build the Intel ZIP named `Clipman-macOS-Intel-<version>.zip` instead. Each package contains a single-architecture app for macOS 13 or later. The in-app updater selects the matching architecture automatically.

For a Mac-only release, `VERSION` supplies the Mac app and ZIP version without changing other clients. Update or remove that file when the next coordinated release catches up.

Testers should unzip it, move or drag `Clipman.app` into `/Applications`, and open it normally. The package is Developer ID signed, notarized by Apple, stapled, and verified with Gatekeeper before release.

In Preferences, enable `Run Clipman at login` after the app is in `/Applications`. This writes a per-user LaunchAgent pointing at the current app bundle path, so if the app is moved later, save Preferences again to refresh the login item.

For a startup problem that prevents the menu extra from appearing, quit or force-quit every existing Clipman process and run:

```bash
CLIPMAN_DEBUG_LOG=1 /Applications/Clipman.app/Contents/MacOS/Clipman 2>&1 | tee ~/Desktop/clipman-debug.log
```

The opt-in console trace records startup phases, result states, timings, and error types. It does not record passwords, server tokens, clipboard contents, or history data. Normal launches remain silent.
