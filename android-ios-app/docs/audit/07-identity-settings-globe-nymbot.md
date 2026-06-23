# Audit 07 — Identity / vault / panic / settings / geohash globe / Nymbot

1:1 fidelity audit of the Flutter port against the Nymchat PWA source
(`/home/user/nym-staging/js/**`, `/home/user/nym-staging/functions/api/bot.js`,
`/home/user/nym-staging/index.html`, `/home/user/nym-staging/README.md`).
Scope: `lib/features/identity/**`, `lib/features/settings/**`,
`lib/features/globe/**`, `lib/features/nymbot/**`,
`lib/state/settings_provider.dart`, `lib/main.dart`.

## Summary

- Discrepancies found: **6 fixed**, **2 deferred** (documented below).
- The slice was already a high-fidelity port. Verified byte-faithful with no
  change required:
  - **Identicon** (`nym_identicon.dart`): FNV-1a 32-bit hash, Mulberry32 PRNG,
    `Math.imul` emulation, hue/sat/light ranges (`60+25`, `50+15`), HSL bg
    `(hue+180)%360,25%,18%`, 5×5 mirrored grid (`half=ceil(5/2)=3`) — exact match
    to `users.js generateAvatarSvg`.
  - **Vault crypto** (`identity_vault.dart`): PBKDF2 **310000**/SHA-256, salt 16B,
    AES-GCM-256, IV 12B, `enc:v1:<b64(iv)>:<b64(ct‖tag)>` blob, check token
    `nymchat-vault-ok`, the 4-key vault list (`nym_session_nsec`, `nym_dev_nsec`,
    `nym_nostr_login_nsec`, `nym_nip46_client_secret`) — all exact.
  - **Panic UI** (`panic_overlay.dart`): 2000ms hold, 40×8 scramble grid, ~60ms
    interval, charset, 1500ms min-hold — all exact.
  - **Globe math** (`geo_projection.dart`, `topojson.dart`, `geo_map_painter.dart`):
    equirectangular projection + inverse, TopoJSON arc decode (delta + quantize
    transform, `~i` reversed-arc, shared-vertex stitch, shoelace centroid),
    geohash base32 alphabet + encode/decode + cell-size bits, grid precision (50px
    threshold, cap 9), heat palette stops/radius/intensity, day/night solar
    position + terminator, active-window options `[1,3,6,12,24]` default 24,
    selected-geohash return contract (`pop(gh.toLowerCase())`) — all exact.
  - **Nymbot** (`nymbot_models.dart`, `nymbot_service.dart`): Pro model list
    (ids/labels/order/baseCredits), `<think>` join/cap(4000)/truncation suffix,
    sats-per-credit (10/100), git providers + default hosts, `?git writes on/off`
    — all exact.
- Verification: `flutter analyze lib/features/identity lib/features/settings
  lib/features/globe lib/features/nymbot lib/state/settings_provider.dart
  lib/main.dart` clean; `flutter test test/identity_test.dart
  test/settings_test.dart test/globe_test.dart test/nymbot_test.dart
  test/vault_boot_test.dart` green (71 tests).

## Discrepancy table — fixed

| # | Item | PWA behavior (source of truth) | Flutter before | Action |
|---|------|--------------------------------|----------------|--------|
| 1 | Biometric device secret entropy | Biometric factor keyed off WebAuthn-PRF output (`key-vault.js`). Native substitute must have real entropy. | `_deviceBiometricSecret` (`vault_settings_modal.dart`) built the secret from `microsecondsSinceEpoch.toRadixString(16) + hashCode.toRadixString(16)` — **low-entropy, time-derived**, guessable. | **Fixed** — now 32 bytes from `Random.secure()`, base64-encoded. The boot-unlock side only reads the key, so only the generation site changed. |
| 2 | Panic wipe: encrypt-with-discarded-key | `panic.js _panicEncryptStorage` encrypts every web-storage value under a fresh non-extractable AES-GCM-256 key (discarded immediately) → `'panic:'+b64(iv‖ct)`, **then** junk-overwrites + clears. | `_SharedPrefsAdapter.wipe` only junk-overwrote then cleared — no encrypt-with-discarded-key pass. | **Fixed** — added the discarded-key AES-GCM-256 encrypt pass over every SharedPreferences value before the junk overwrite, mirroring `_panicEncryptStorage` (`panic_wipe.dart`). |
| 3 | Panic wipe step order | `panic.js`: (1) encrypt+junk+clear web-storage, (2) shred IndexedDB, (3) caches/SW. Web-storage (holding the encrypted nsec blobs) goes first. | Order was `secure → cache → prefs`. | **Fixed** — reordered to `prefs (web-storage analogue) → cache (IndexedDB analogue) → secure keystore`. |
| 4 | Nymbot `?changelog` command missing | Real worker command (`bot.js:1722` dispatch `changelog`/`release`/`releases`/`version`/`versions`; help text `bot.js:1894`). | Absent from `kBotCommands` (`bot_commands.dart`). | **Fixed** — added the Info-group `changelog` command (usage `?changelog [version]`, the worker's help description, aliases `release(s)`/`version(s)`). |
| 5 | Nymbot `?roll` advertised but not handled | **No `roll` handler in `bot.js`** — `?roll` falls through to `default` → 400 "Unknown command". Listed only in `README.md:189` (a README bug). | `kBotCommands` advertised `?roll` as a working command. | **Fixed** — removed the `roll` `BotCommand` so the client never advertises a command that 400s; updated the file doc-comment and `nymbot_test.dart` catalogue list (removed `roll`, added `changelog`) and the `isBotCommand` example. |
| 6 | Settings: per-pubkey image-blur key | `settings.js saveImageBlurSettings` writes **both** global `nym_image_blur` and per-pubkey `nym_image_blur_<pubkey>`. | `setBlurImages` wrote only the global key. | **Fixed** — `setBlurImages` now takes an optional `pubkey` and also writes `StorageKeys.imageBlurFor(pubkey)`; the settings-screen call site passes `appStateProvider.selfPubkey`. |
| 7 | Settings: missing "Reset columns to defaults" button | `index.html:1406` button → `resetColumnView` → `cvResetColumns` (`columns.js:363`), whose durable effect is `localStorage.removeItem('nym_columns_layout')`. | No such control in the Chat View section. | **Fixed** — added a `resetColumns()` controller method (removes `nym_columns_layout`) and a "Reset columns to defaults" `NymOutlineButton`, shown when column view is active. Runtime re-seed remains the columns feature's concern (re-seeds on next column-view load). |
| 8 | Globe: channel-dot tap zoomed the camera | `geohash-globe.js` onPointerUp: a channel-dot tap calls `selectGeohashChannel(ch)` **only** — no `zoomToBounds`. Only a grid-cell tap (`_selectGeohashCell`) zooms. | `_onTapUp` channel branch ran `_view.fitBounds(...)`, re-framing the camera on channel selection. | **Fixed** — channel-dot tap now only sets `_selected`/`_hoveredGeohash` (shows the info panel) with no camera move; removed the now-unused `_boundsFor`/`_pointBounds` helpers. Grid-cell zoom (`_selectCell`) unchanged. |

## Deferred (documented, not fixed)

| # | Item | PWA behavior | Flutter | Why deferred |
|---|------|--------------|---------|--------------|
| D1 | Globe heatmap palette-application order | `geohash-globe.js` accumulates grayscale-alpha blobs additively into an offscreen (half-res) canvas, **then** remaps the summed alpha through the 256-entry palette per pixel (`d[i]=palette[a*4]`). Overlapping channels climb blue→green→yellow→red. | `geo_map_painter._drawHeatmap` colors each blob by its own peak intensity, then adds RGB via `BlendMode.plus`. Overlapping hotspots sum colors, not intensities, so they don't climb the palette identically. | A faithful port needs a per-pixel alpha→palette remap, which requires reading back pixels (`ui.Image.toByteData`) — **async**, impossible inside the synchronous `CustomPainter.paint`. Correct fix: precompute the accumulation `ui.Image` outside paint (half-res, `BlendMode.plus` grayscale blobs), remap alpha→palette, and pass the finished image into the painter to `drawImage` with `FilterQuality.low`. Visual-only divergence; all geohash selection/return and interaction are correct. Large enough to warrant its own change. |
| D2 | Day/night refresh cadence | Two timers: `ACTIVE_WINDOW_REFRESH_MS=30000` (activity) + `DAYNIGHT_REFRESH_MS=60000` (day/night). | Single `Timer.periodic(30s)` drives both (`geohash_explorer.dart`). | Strictly **more** frequent than the PWA (30s vs 60s for day/night) — harmless, the terminator just repaints twice as often. Splitting into two timers adds state for no user-visible benefit. |

## Notes / non-issues confirmed

- **Settings inventory**: all six sections (Appearance, Privacy & Security,
  Messaging & Display, Channels, Mobile Gestures, Data & Backup) render in PWA
  order with matching titles. Every functioning dropdown/slider matches the PWA
  verbatim — sounds (19), translation languages (47), swipe actions (8/8),
  wallpapers (9), themes (6), PoW (6), DM TTL (5), receipt/typing scopes (5),
  text size (12–28, default 15) — and every wired setter writes the correct
  `nym_*` key with the correct default.
- **Intentionally stubbed settings actions** (Identity Encryption launcher, Add
  Keyword, Quick React emoji picker, Transfer Settings send, Clear Cache, Reset
  Settings, the no-op SAVE button, and the static Friends/Blocked/Hidden lists)
  are cross-subsystem or networked flows that live outside this slice's owned
  files; they remain as documented TODOs and are out of scope here.
- **`?help` `isFree` flag** is metadata only — the worker answers `?help`
  server-side and the chat screen does not intercept it; the flag is harmless and
  left in place (doc-comment corrected).
- **`passkey` vault method** and the WebAuthn-PRF biometric scheme are
  browser-only; the native build documents the local-secret substitute (now with
  full entropy, fix #1).

## Verification

```
flutter analyze lib/features/identity lib/features/settings lib/features/globe \
  lib/features/nymbot lib/state/settings_provider.dart lib/main.dart
# No issues found!

flutter test test/identity_test.dart test/settings_test.dart test/globe_test.dart \
  test/nymbot_test.dart test/vault_boot_test.dart
# All tests passed! (71)
```
