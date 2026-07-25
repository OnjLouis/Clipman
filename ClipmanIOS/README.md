# Clipman for iOS

Clipman for iOS is a foreground-only clipboard-history client. It can keep history privately on the iPhone or iPad, or read and write the same Clipman Server history used by Windows, Mac, and Android clients.

[Join the Clipman public beta through TestFlight](https://testflight.apple.com/join/HYReZKAk).

The iOS app is built with SwiftUI. It intentionally does not poll the clipboard in the background, because iOS does not allow the same always-on clipboard workflow as desktop operating systems.

## Current Scope

- Optionally require Face ID, Touch ID, or the device passcode whenever Clipman returns to the foreground. This is off by default.
- Choose private Local storage or Clipman Server storage.
- Open the private `.clpconf` connection file from the Files app to send it to Clipman's review-and-save flow, use the importer in Clipman Settings, or enter the server address and token manually. Settings can also export the current address and token to a new private `.clpconf` credential file.
- Retain the server address, token, and history password while Local mode is selected.
- Show the private local cache immediately in Server mode, then refresh and merge with the server in the background.
- Browse text history and link history.
- Add the current iOS clipboard text into Clipman while the app is open.
- Optionally offer to add the current iOS clipboard text after each successful unlock and initial history refresh. Clipman only presents the choice when the pasteboard advertises text. The full-screen choice uses Apple's paste control, so Paste is explicit and Cancel or a VoiceOver scrub leaves history unchanged.
- Copy an entry back to the iOS clipboard.
- View, edit, pin, unpin, delete, search, and filter entries.
- Use VoiceOver-friendly rows and actions so one swipe moves between entries.
- When authentication is enabled, lock whenever Clipman leaves the foreground and authenticate again when returning.
- Check the server revision every five seconds while active, download history only when it changed, pause behind Settings or in the background, and back off connection failures.
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

In Settings, use the VoiceOver scrub gesture to cancel unsaved changes and return to history.

The server address, server token, and history password fields have explicit VoiceOver labels and instructions. Secure field contents remain hidden. The server-file importer reads the address and token, presents the address for review, and waits for Save before applying it. Export warns that the resulting file contains the private server token and must be stored and shared securely. Server mode requires a nonblank, preferably unique history password.

Activate Clipman's status line to move to the bottom of the current history list. The standard iOS status-bar gesture remains available for returning to the top.
