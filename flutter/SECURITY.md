# Security Policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub private vulnerability reporting](https://github.com/Spl0itable/flutter-app/security/advisories/new)
rather than opening a public issue. Include reproduction steps, the platform
(Android / iOS), and the app version from the About screen.

Findings that affect the shared protocol or the Cloudflare backend can also be
reported against the [nym-staging](https://github.com/Spl0itable/nym-staging)
repository — either channel reaches the same maintainers.

## Scope notes for researchers

- Private messages and group chats are end-to-end encrypted (NIP-17/NIP-44/
  NIP-59); the identity keys and the local database key live in the platform
  keystore (Keychain / Android Keystore), and the local message store is
  SQLCipher-encrypted. Reports that break any of those properties are the
  highest-value ones we can receive.
- Public channels are intentionally unencrypted.
- The Bluetooth mesh transport (bitchat-compatible, Noise protocol) is in
  scope.
