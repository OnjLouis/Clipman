# Clipman Shared Contract

This file is a required coordination document for both Clipman implementations:

- Windows source: repository root.
- Mac source: `ClipmanMac` subfolder in this repository.

Any Codex thread working on either implementation must read this file before changing database, settings, sync, password, or shared-history behavior. Treat the details here as a compatibility contract. If one implementation changes a shared behavior, update the other implementation and this file in the same work cycle, or clearly mark the feature as platform-specific.

## Current Milestone

As of 2026-06-18, the Mac implementation can write a clipboard entry into the shared encrypted history database and the Windows implementation can reload it with the correct source machine name. This proves the shared text-history database format, password handling, machine metadata, and file reload path are interoperating across Windows and macOS.

## Shared Repository Layout

The combined project lives in:

```text
D:\Dropbox\backups\Codex\current\clipman
```

Expected folders:

```text
src          Windows C# WinForms implementation
ClipmanMac   macOS Swift/AppKit implementation
```

Do not assume either platform is the sole source of truth. Windows currently has the more complete product surface; Mac currently has a smaller but working native implementation. Shared storage behavior must remain compatible.

## Shared Database Files

The shared text-history database is named:

```text
clipman-history.clipdb
```

The preferred user-facing configuration is a data/settings folder, not direct selection of an individual `.clipdb` file. Each platform derives the shared text-history path by appending `clipman-history.clipdb` to the selected folder.

Existing explicit `.clipdb` paths may remain readable for compatibility, but new UI should guide users to choose a folder. This avoids accidentally choosing machine-specific file-history databases.

Machine-specific settings also live in the selected data/settings folder and are named like:

```text
<ComputerName>-settings.json
```

macOS may keep a small pointer under Application Support so it can find the selected data folder on launch, but the active machine settings JSON belongs beside `clipman-history.clipdb`, matching Windows behavior.

## Database Format

The `.clipdb` file has two supported binary forms:

- `CLIPDB1`: gzip-compressed UTF-8 JSON.
- `CLIPDB2`: encrypted gzip-compressed UTF-8 JSON.

Plain JSON exports/imports may exist, but the live `.clipdb` database must not become plain JSON.

### `CLIPDB1`

Layout:

```text
ASCII "CLIPDB1"
gzip-compressed UTF-8 JSON payload
```

The reader may tolerate legacy compressed `.clipdb` payloads without the `CLIPDB1` magic, but writers should emit `CLIPDB1`.

### `CLIPDB2`

Layout:

```text
ASCII "CLIPDB2"
1 byte version, currently 1
16 byte salt
16 byte IV
AES-CBC encrypted gzip-compressed UTF-8 JSON payload
32 byte HMAC-SHA256 over all preceding bytes
```

Encryption details:

- Password-derived key material: PBKDF2-HMAC-SHA1.
- Iterations: `150000`.
- Salt length: 16 bytes.
- Derived length: 64 bytes.
- Bytes 0-31: AES-256 encryption key.
- Bytes 32-63: HMAC-SHA256 key.
- Cipher: AES-CBC with PKCS#7 padding.
- IV length: 16 bytes.
- Authentication: HMAC-SHA256 over magic, version, salt, IV, and ciphertext.
- Existing encrypted salt is reused when rewriting an encrypted database, matching current Windows and Mac behavior.

Wrong or missing password must be treated as a recoverable password-required/password-incorrect state, not as data loss.

## JSON Model Compatibility

The JSON payload root for text history is a database object with an entries array. Windows currently serializes this as:

```json
{
  "Entries": []
}
```

Shared text entries must preserve fields used by the other platform, including unknown or optional fields where possible.

Known text-entry fields include:

- `Id`
- `Text`
- `Name`
- `Group`
- `Pinned`
- `CreatedUnixMs`
- `LastUsedUnixMs`
- `ManualOrder`
- `SourceMachine`

Older documentation or experimental builds may mention `AddedUtc` and `LastUsedUtc`; the current interoperable Windows and macOS text-history payload uses `CreatedUnixMs` and `LastUsedUnixMs`. Do not rename these fields without a cross-platform migration plan. Prefer adding optional fields over changing existing ones.

## Source Machine Metadata

Each platform must write the machine/source name into `SourceMachine` when adding or re-adding text entries. Windows already displays and sorts by machine. The Mac implementation has proven this field can be written and read by Windows.

Machine naming may differ by platform, but it should be stable and human-readable.

## Password Storage

The database password is not stored in the shared `.clipdb` file.

Password remembering is optional and must be explicit. New settings should default to not remembering the database password. In session-only mode, an implementation prompts for the password when it needs to open an encrypted database, keeps the password only in process memory for the current run, and clears any saved platform-specific password from settings or key storage.

Platform-specific remembered-password storage:

- Windows: DPAPI-protected per-user/per-machine settings, only when `RememberDatabasePassword` is true.
- macOS: Keychain entry keyed by database path, only when the matching remember-password preference is true.

Copying settings from one machine to another must not silently grant access to an encrypted database unless that platform explicitly stores the password for that user/machine. Remembered-password storage is a convenience feature, not protection from malware already running as the same user. Same-user malware can usually ask the OS to unprotect the stored secret or read process memory while the database is unlocked.

## File History Is Not Shared By Default

Windows and macOS have persistent file-history support in a machine-specific `.clipdb` file named like:

```text
<ComputerName>-file-history.clipdb
```

This is intentionally separate from shared text history because file paths are usually machine-specific. macOS writes Finder/file URL clipboard events to its own machine-specific file-history database in the selected Clipman data folder and must not write file events into `clipman-history.clipdb`.

When a history password is configured, macOS uses the same password for its machine-specific file-history database that it uses for the shared text-history database.

## Sync and Atomic Writes

Both implementations must:

- Save database files atomically.
- Tolerate another machine replacing the database file.
- Reload after external changes.
- Avoid blind overwrites when possible.
- Preserve entries added by another machine.

Current Windows behavior includes conflict cleanup and merge logic. If Mac adds similar conflict handling, keep it compatible with Windows rather than inventing a conflicting file scheme.

## Required Compatibility Tests

Before pushing or release-building changes that touch database format, password handling, settings-folder selection, sync, or entry serialization, run platform-local tests and, where possible, a cross-platform manual smoke:

1. Windows writes an entry, Mac reads it.
2. Mac writes an entry, Windows reads it.
3. Source machine name survives in both directions.
4. Encrypted database opens with the correct password.
5. Wrong password is rejected without corrupting the file.
6. Unencrypted compressed database still opens.
7. Each platform can rewrite the shared database and the other platform can still read it.

Windows smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File D:\Dropbox\backups\Codex\current\clipman\SmokeTest.ps1 -LivePath D:\Dropbox\SOFTWARE\clipman
```

Mac codec smoke test:

```bash
cd ~/Dropbox/backups/Codex/current/clipman/ClipmanMac
swift run ClipmanCodecSmoke
```

Adjust paths on macOS if the Dropbox folder differs, but keep the source-tree relationship intact.

## Documentation Duty

When this contract changes, update:

- This file.
- Windows handover: `D:\Dropbox\txt\codex\Clipman.txt`
- Windows `README.md` / `Manual.html` if user-facing behavior changed.
- Mac project notes/readme/handover if present.
- Any smoke tests that should guard the behavior.

Do not hide a shared-format change only in source code.
