# Clipman for iOS

Clipman for iOS is a foreground-only clipboard-history client. It can keep history privately on the iPhone or iPad, synchronize through an iCloud Drive or other shared folder, or read and write the same Clipman Server history used by Windows, Mac, and Android clients.

[Download Clipman from the App Store](https://apps.apple.com/app/clipman/id6793250105). Testers can also [join the public TestFlight beta](https://testflight.apple.com/join/HYReZKAk) to try approved preview builds.

The iOS app is built with SwiftUI. It intentionally does not poll the clipboard in the background, because iOS does not allow the same always-on clipboard workflow as desktop operating systems.

## Current Scope

- Optionally require Face ID, Touch ID, or the device passcode whenever Clipman returns to the foreground. This is off by default.
- Choose private Local storage, Shared Folder sync, or Clipman Server storage.
- Use Shared Folder sync with the same selected iCloud Drive or supported provider folder and history password on each device. Clipman keeps a private local cache, merges entries and deletion records while open, and never puts settings, credentials, or passwords in that folder.
- If encrypted backup already has a selected folder, Clipman reuses that folder as the initial Shared Folder choice. Choosing a different shared folder later keeps the two locations independent.
- Open the private `.clpconf` connection file from the Files app to send it to Clipman's review-and-save flow, use the importer in Clipman Settings, or enter the server address and token manually. Settings can also export the current address and token to a new private `.clpconf` credential file.
- Retain server and shared-folder details while another storage mode is selected.
- Show the private local cache immediately in Shared Folder or Server mode, then refresh and merge with the selected storage in the background.
- Browse Text, Links, and optional Rich Text history.
- Add the current iOS clipboard text into Clipman while the app is open.
- Use Quick Clip to type a new entry directly, including its optional Name, Group, pinned state, and template setting.
- Optionally offer to add the current iOS clipboard text after each successful unlock and initial history refresh. Clipman only presents the choice when the pasteboard advertises text. The full-screen choice uses Apple's paste control, so Paste is explicit and Cancel or a VoiceOver scrub leaves history unchanged.
- Copy an entry back to the iOS clipboard.
- Optionally back up encrypted history to a folder selected through Files, including iCloud Drive and supported third-party providers. Restore merges entries and deletion records with current history; the backup never includes server tokens, settings, or passwords.
- Use the built-in **Quick Clip**, **Add Clipboard to Clipman**, and **Copy Latest Clip** actions from Shortcuts, Siri, or the iPhone Action Button. The actions honour Clipman's authentication setting and continue safely from the encrypted local cache if the server is unavailable.
- Long-press the Clipman Home Screen icon for the same Quick Clip, Add Clipboard, and Copy Latest Clip commands.
- View, edit, pin, unpin, delete, search, and filter entries.
- Use VoiceOver-friendly rows and actions so one swipe moves between entries.
- When authentication is enabled, lock whenever Clipman leaves the foreground and authenticate again when returning.
- Check the shared-folder or server revision every five seconds while active, load history only when it changed, pause behind Settings or in the background, and back off connection failures.
- Preserve supported iOS clipboard content across the initial server refresh and add it only when it is not already in history, so launch capture cannot take ownership of an existing entry.
- When startup clipboard import and automatic remote copying are both enabled, preserve and save supported clipboard content already on the device before allowing the initial server refresh to copy anything back.
- Make an optional one-time tip through Apple's in-app purchase system. Tips do not unlock features or content.

## Build Notes

Full Xcode is required to compile, sign, and install the iOS app on a device. Xcode Command Line Tools alone are not enough for iOS device deployment.

The app source is under `ClipmanIOS/`. The project is generated from `project.yml` with XcodeGen:

```bash
cd ClipmanIOS
xcodegen generate
open ClipmanIOS.xcodeproj
```

If XcodeGen is not installed:

```bash
/opt/homebrew/bin/brew install xcodegen
```

The iOS Tip Jar expects three consumable in-app purchase products in App Store Connect: `me.onj.clipman.ios.tip.small`, `me.onj.clipman.ios.tip.medium`, and `me.onj.clipman.ios.tip.large`. Their customer-facing names and prices come from App Store Connect.

## Accessibility Notes

Rows expose a compact VoiceOver label and custom actions for common operations. Double-tap copies the selected entry to the clipboard. Use the Actions rotor for View, Edit, Pin or Unpin, and Delete.

Use a three-finger swipe up or down to move through history one page at a time. Three-finger left and right swipes continue to switch between enabled history sections.

In Settings, use the VoiceOver scrub gesture to cancel unsaved changes and return to history.

The server address, server token, shared-folder picker, and history password fields have explicit VoiceOver labels and instructions. Secure field contents remain hidden. The server-file importer reads the address and token, presents the address for review, and waits for Save before applying it. Export warns that the resulting file contains the private server token and must be stored and shared securely. Shared Folder and Server modes require a nonblank, preferably unique history password.

Activate Clipman's status line to move to the bottom of the current history list. The standard iOS status-bar gesture remains available for returning to the top.

Clipman's App Shortcuts appear automatically in Apple's Shortcuts app. To use one with the Action Button, choose **Shortcut** in the Action Button settings and select a Clipman action. Siri phrases include "Create a Quick Clip in Clipman", "Add clipboard to Clipman", and "Copy latest from Clipman".
