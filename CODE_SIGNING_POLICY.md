# Code Signing Policy

Free code signing provided by SignPath.io, certificate by SignPath Foundation.

## Scope

This policy applies to official Windows Clipman release executables published by Andre Louis from the public [OnjLouis/Clipman](https://github.com/OnjLouis/Clipman) repository. Binaries submitted for signing must be produced from the corresponding public source revision by a trusted GitHub-hosted build. Clipman does not sign third-party builds or unrelated software under its project identity.

Every signing request and public release requires manual approval. A successful automated build is not, by itself, authorization to publish it.

## Project Roles

- Author, committer, and maintainer: Andre Louis ([@OnjLouis](https://github.com/OnjLouis))
- Reviewer: Andre Louis
- Signing and release approver: Andre Louis

Contributions from other people are reviewed before they are merged. GitHub and SignPath accounts used for project administration must use multi-factor authentication.

## Privacy And Network Access

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

Network features are deliberate and visible. They include checking for or installing updates, connecting to a Clipman Server configured by the user, explicitly requesting a website title for one selected link, and opening a user-selected project, help, contact, donation, or download page. Clipman Server synchronization sends the encrypted history database to the server selected by the user; the server does not receive or know the history password and cannot decrypt the database.

Clipman does not send clipboard contents, history, passwords, server tokens, usage analytics, or telemetry to Andre Louis, SignPath Foundation, or another third party by default. Server tokens and history passwords are not included in diagnostics or release artifacts.

## Release Integrity

The signed artifact is tied to its source revision and version. Release packaging checks the expected executable, version, documentation, license, runtime assets, and archive contents. Private maintainer tooling, credentials, local paths, settings, history databases, logs, and other machine-specific files are excluded from public source and release packages.
