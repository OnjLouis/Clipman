# Clipman for iOS

This is the first iOS client for Clipman. It is a foreground-only companion for a Clipman Server connection: it reads and writes the same encrypted clipboard history used by the Windows, Mac, and Android clients.

The iOS app is built with SwiftUI. It intentionally does not poll the clipboard in the background, because iOS does not allow the same always-on clipboard workflow as desktop operating systems.

## Current Scope

- Unlock with Face ID, Touch ID, or the device passcode.
- Configure a Clipman Server address, token, and history password.
- Browse text history and link history.
- Add the current iOS clipboard text into Clipman while the app is open.
- Copy an entry back to the iOS clipboard.
- View, edit, pin, unpin, delete, search, and filter entries.
- Use VoiceOver-friendly rows and actions so one swipe moves between entries.

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
