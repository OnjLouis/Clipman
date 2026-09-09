# Security Policy

## Supported Versions

Security fixes are made against the latest published release of each maintained Clipman component:

- Clipman graphical clients for Windows, macOS, Linux, Android, iPhone, and iPad
- Clipman Server
- Clipman CLI

If a report concerns an older release, please confirm whether the problem is still present in the latest release where practical.

## Reporting a Vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/OnjLouis/Clipman/security/advisories/new) for a suspected vulnerability. Do not open a public issue until the report has been assessed and a coordinated disclosure is agreed.

Include the affected component, version, platform, security impact, and the smallest reliable reproduction you can provide. Remove clipboard contents, history passwords, server tokens, private keys, connection files, and other personal data from screenshots and logs before attaching them.

Reports will be acknowledged and assessed as availability permits. Validated issues will be discussed privately until a fix or suitable mitigation is available.

## Protecting Clipman Data

- A Clipman Server token authorizes access to that server. Treat it and every exported `.clpconf` connection file as private.
- The history password encrypts clipboard history on the client and is not sent to Clipman Server. Do not send it with a connection file or include it in a report.
- Internet-facing Clipman Servers must use HTTPS. Plain HTTP is intended only for localhost, a private network, or a trusted VPN.
- Before sharing diagnostics, inspect them for clipboard contents, local paths, device names, addresses, and credentials.
