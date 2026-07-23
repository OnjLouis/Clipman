# Clipman for iOS

Clipman for iOS is a foreground-only clipboard-history client. It can keep history privately on the iPhone or iPad, or read and write the same Clipman Server history used by Windows, Mac, and Android clients.

[Join the Clipman public beta through TestFlight](https://testflight.apple.com/join/HYReZKAk).

The iOS app is built with SwiftUI. It intentionally does not poll the clipboard in the background, because iOS does not allow the same always-on clipboard workflow as desktop operating systems.

## Current Scope

- Unlock with Face ID, Touch ID, or the device passcode.
- Choose private Local storage or Clipman Server storage.
- Retain the server address, token, and history password while Local mode is selected.
- Keep a private local cache in Server mode, save changes while offline, and merge them when the server becomes reachable again.
- Browse text history and link history.
- Add the current iOS clipboard text into Clipman while the app is open.
- Optionally offer to add the current iOS clipboard text after each successful unlock and initial history refresh. Clipman only presents the choice when the pasteboard advertises text. The full-screen choice uses Apple's paste control, so Paste is explicit and Cancel or a VoiceOver scrub leaves history unchanged.
- Copy an entry back to the iOS clipboard.
- View, edit, pin, unpin, delete, search, and filter entries.
- Use VoiceOver-friendly rows and actions so one swipe moves between entries.
- Lock whenever Clipman leaves the foreground and authenticate again when returning.

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

## Accessibility Notes

Rows expose a compact VoiceOver label and custom actions for common operations. Double-tap copies the selected entry to the clipboard. Use the Actions rotor for View, Edit, Pin or Unpin, and Delete.

In Settings, use the VoiceOver scrub gesture to cancel unsaved changes and return to history.

The server address, server token, and history password fields have explicit VoiceOver labels and instructions. Secure field contents remain hidden.

Activate Clipman's status line to move to the bottom of the current history list. The standard iOS status-bar gesture remains available for returning to the top.
