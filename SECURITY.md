# Security Policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub private vulnerability reporting](https://github.com/Spl0itable/NYM/security/advisories/new)
rather than opening a public issue. Include reproduction steps and the affected
surface (PWA, Cloudflare Functions backend, or the native Android/iOS app —
the native client lives in the `android-ios-app` directory, which accepts reports
the same way).

We aim to acknowledge reports promptly and to credit reporters in release
notes unless they prefer otherwise.

## Scope notes for researchers

- Private messages and group chats are end-to-end encrypted (NIP-17/NIP-44/
  NIP-59); relays and the D1 storage layer only ever hold ciphertext. Findings
  that break that property are the highest-value reports we can receive.
- Public channels (kinds 20000/23333) are intentionally unencrypted.
- The `/api/proxy` endpoint is intentionally unauthenticated (it exists to
  keep user IPs away from third-party servers); reports about its abuse
  potential should focus on bypasses of its SSRF, rate-limit, or content-type
  controls.

## Vendored cryptography

The Cloudflare Functions backend vendors its crypto primitives
(secp256k1/schnorr, SHA-256/HMAC/HKDF, NIP-44) in `functions/api/_shared.js`
rather than importing them, so dependency scanners will not flag upstream
advisories automatically. Maintainers: when a security advisory lands for
`@noble/curves`, `@noble/hashes`, or `nostr-tools`, re-vendor from the patched
release. The provenance header at the top of `_shared.js` records what to
compare against.
