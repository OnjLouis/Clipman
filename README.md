# Clipman

Clipman is an accessible clipboard manager for Windows, macOS, Linux, Android, iPhone, and iPad. It keeps useful text close at hand without turning clipboard history into a mouse-first workflow, and it can carry the same encrypted history between your devices when you choose to sync it.

Clipman is designed around fast keyboard and screen-reader use. History is a real working list: search it, name entries, arrange them, group them, pin the important ones, edit mistakes, preserve formatting, or paste a saved item without opening Clipman first.

## Get Clipman

- [Download the latest Windows, macOS, Linux, Android, and server builds](https://github.com/OnjLouis/Clipman/releases/latest).
- [Join the public iPhone and iPad beta through TestFlight](https://testflight.apple.com/join/HYReZKAk).
- [Read the complete Clipman manual](https://onjlouis.github.io/clipman/manual.html).
- [Read the Clipman Server manual](https://github.com/OnjLouis/Clipman/blob/main/ClipmanServer/Manual.html).

Windows is portable, macOS uses a signed and notarized app, Linux includes a per-user installer, and the mobile apps use the normal platform installation flow. Clipman Server is a separate, optional download; ordinary Clipman does not require it.

## What Makes It Useful

- **One history on the devices you choose.** Windows and Mac can share a history through a cloud-synced folder or network share. Clipman Server extends encrypted synchronization to every supported platform without requiring a third-party clipboard account.
- **Built for nonvisual use.** Controls expose useful names, roles, states, values, and predictable keyboard behavior. Lists are designed for quick movement, type-to-jump navigation, search, and concise screen-reader speech.
- **Text, links, formatting, images, and files have their place.** Optional Links and Rich Text views reduce clutter without splitting the shared text database. Links receive useful offline labels, while a deliberate one-link command can save a website title as the existing synced entry name. Rich Text can optionally carry bounded PNG and JPEG images between supported clients: mobile users can share a photo to Clipman, save or share it again from its entry actions, and desktop users can move an image in either direction between Rich Text and their normal file manager. Desktop File History keeps ordinary copied file paths machine-local because those paths usually make sense only on the device that captured them.
- **Your important clips stay reachable.** Pin entries, organize them into groups, filter by group or contributing device, sort normal entries per device, and give entries short names that are easier to find than their full contents.
- **Quick Paste removes the detour.** Assign a global hotkey to a frequently used entry and paste it into the active application without opening history. Templates can resolve dates, device information, and other fields at the moment they are used.
- **Privacy features are opt-in and visible.** Encrypt history with a password, ignore selected applications, honor supported private-clipboard signals, or exclude likely sensitive values from automatic capture. Machine-local Secrets provide deliberate hotkey access to short private snippets without putting them in normal shared history.
- **Offline work is not discarded.** Mobile and server-backed clients retain local history and merge changes when the server returns. Deletions and edits synchronize as changes, rather than relying on whichever client happens to upload last.
- **It remains small and direct.** Sounds, startup behavior, remote clipboard receipt, automatic paste, monitoring, updates, retention, and deletion confirmation can be adjusted without changing the basic copy-and-paste workflow.

## Start Here

1. Install or extract the build for your platform and open Clipman.
2. Copy a few pieces of text, then open history using the shortcut shown by the app or its menu.
3. Press Enter or activate an entry to return it to the clipboard.
4. Open Preferences or Settings when you want to enable optional views, encryption, synchronization, sounds, or other behavior.

That is enough for ordinary local use. The [full manual](https://onjlouis.github.io/clipman/manual.html) covers every command, platform shortcut, accessibility behavior, import and export option, privacy control, and synchronization workflow.

## Choose How To Store History

- **Local:** Keep history private to one device. This is the default on mobile and is always available.
- **Shared folder:** On Windows and Mac, place the data folder in a cloud-synced folder or mounted network share.
- **Clipman Server:** Self-host a server on Linux, macOS, Windows, Raspberry Pi, a NAS, or a VPS. Clients authenticate with a server token while the history password determines the encrypted database bucket. Internet-facing servers must use HTTPS.

The server cannot decrypt clipboard history. A server connection file can carry its address, token, and an optional private certificate authority for app-scoped HTTPS trust, so new clients can be configured without manually transcribing credentials. Server 2.6 can also create a short-lived, revocable browser setup page that downloads this file to a new device; public pages require HTTPS and the history password is never included.

## More Ways To Use It

The [Clipman CLI preview](https://github.com/OnjLouis/Clipman/releases/tag/cli-v0.3.0-dev) provides terminal and headless access to server-backed text history on Windows, macOS, and Linux. It follows the same encrypted format and synchronization rules as the graphical clients.

## Project

- [Release history and downloads](https://github.com/OnjLouis/Clipman/releases)
- [Report a problem or suggest an improvement](https://github.com/OnjLouis/Clipman/issues)
- [Contact Andre Louis](https://onj.me/contact)
- [Support development](https://onj.me/donate)

Clipman is free and open source under the MIT License. See [LICENSE.txt](https://github.com/OnjLouis/Clipman/blob/main/LICENSE.txt).
