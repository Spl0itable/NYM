# Integration notes — remaining `TODO(verify)` items

The native Flutter clone (`android-ios-app/lib`) is feature-complete across the
PWA surface and passes the full test suite (479+) with a clean whole-project
analyze and a green `flutter build web`. This file tracks the bounded items that
remain — mostly things that depend on the live backend or on platform config
that isn't present in this build environment. Each is also marked inline with
`// TODO(verify):` at the relevant code site.

## Resolved (previously open, now wired)
- **NIP-46 remote-signer signing** — an `EventSigner` abstraction
  (`LocalSigner`/`Nip46SignerAdapter`) is threaded through every publish,
  gift-wrap **seal**, and DM-decrypt path; NIP-46 logins boot-restore and can
  publish. Byte-parity for local keys.
- **nsec login boot-restore** + **vault boot-unlock** (the decrypted secrets are
  held in memory — native `_vaultMem` analogue — and fed to identity restore;
  the `enc:v1:` blobs are never re-plaintexted, so unlock is required each
  launch).
- **Friends-only private presence** (kind 25054 gift-wrapped) send + ingest.
- **Notification audio** plays the synthesized tones (`audioplayers`).
- **Deep links** (`app_links`) for channel/PM/group/invite URLs.
- **Flair-shop cosmetics** rendered on messages + nyms (self + others via
  presence shop tags).

## Backend-dependent (real calls wired, unverifiable from this env)
- **Lightning settlement** (zap verify, shop buy/check/claim/redeem/gift/
  transfer, bot credit buy) issues the real `/api/proxy`, `/api/storage`,
  `/api/bot` calls with NIP-98 auth, but `web.nymchat.app` is unreachable from
  the build environment. Verify end-to-end against the live host; confirm the
  bot `check-invoice` field names.
- **FCM push** — `firebase_messaging_service.dart` self-guards (`_firebaseAvailable
  = false`) because no `firebase_*` packages / `google-services.json` /
  `GoogleService-Info.plist` are present. Add the plugins + config and flip the
  guard to enable real push; the deep-link routing of tapped pushes is ready.
- **Shop cosmetics on the wire** — presence inlines `shop-style`/`shop-flair`/
  `shop-supporter` tags so flair renders without a backend; the PWA derives
  these from the D1 shop status. Replace with a native shop-status fetch for
  exact parity.

## Platform-equivalence (web API → native, per the "closest equivalent" choice)
- **Vault biometric factor** uses `local_auth` + a per-device secret rather than
  the PWA's WebAuthn-PRF derivation (no PRF on native).
- **WebTorrent** large-file path uses the WebRTC-chunk fallback (no native
  WebTorrent); PM/group file offers over gift wrap not yet carried.

## Cosmetic / minor fidelity
- Per-glyph `text-shadow` glow approximated by a bubble/row halo; repeating
  `--style-pattern` SVG watermarks and animated style effects render statically.
- Tutorial per-step element-highlight box not positionally drawn; the geometric
  wallpaper gradient is approximated.
- Build-provenance / warrant-canary About checks are placeholders.
</content>
