# Server release signatures

Starting with Server 2.7.0, program updates require both GitHub's SHA-256 asset digest and a detached publisher signature. Missing, malformed or invalid signatures fail before extraction or replacement. The release contains `ClipmanServer-<version>.zip.sig` alongside its ZIP. Containers continue to use the registry's existing image delivery mechanism; this signature describes the downloaded server ZIP, not a container signature.

The signature is a raw 384-byte RSA-3072 PKCS#1 v1.5 SHA-256 signature of this ASCII message, with lowercase hexadecimal digest and LF newlines, including the final newline:

```text
Clipman Server ZIP
<sha256 of the complete ZIP>
```

The pinned public key is embedded in the Linux updater, Windows wrapper and Mac wrapper. Linux verifies with OpenSSL; Windows uses .NET's RSA provider and Mac uses Apple's Security framework. There is no unsigned fallback. OpenSSL must be installed for Linux program updates.

Servers older than 2.7.0 cannot enforce the new publisher signature on their first upgrade. They retain their existing HTTPS and GitHub digest checks. For that transition, verify the signature independently or obtain the ZIP through the trusted project release page. After installing 2.7.0, later updates require signatures. A history password and TLS certificate are unrelated to this publisher key.

The private key is not in the repository, source archives, server package or browser assets. The signature proves that a ZIP was authorised by the publisher; it does not guarantee that the software is bug-free or that the server and visiting browser are trustworthy.
