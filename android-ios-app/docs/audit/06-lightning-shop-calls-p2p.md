# Audit 06 — Lightning (zaps), Flair Shop, Calls (WebRTC), P2P, Notifications

**Scope:** `lib/features/zaps/**`, `lib/features/shop/**`, `lib/features/calls/**`,
`lib/features/p2p/**`, `lib/features/notifications/**`
**Reference PWA:** `../js/modules/{zaps,shop,calls,p2p,notifications}.js` + `../js/app.js`
**Date:** 2026-06-23
**Verification:** `flutter analyze` (5 dirs) → *No issues found*;
`flutter test test/payments_test.dart test/calls_notifications_test.dart` → **53 passed**.

This slice was already a remarkably faithful port. Most subsystems matched the PWA
1:1 (every shop item id/price, every synthesized-sound note table, the zap millisat
math, the call signaling shapes, the p2p chunk/verify logic). Three real
discrepancies were found and fixed; the remainder are platform-justified deferrals.

## Discrepancy table

| # | Subsystem | Severity | PWA behavior | Flutter (before) | Fix |
|---|-----------|----------|--------------|------------------|-----|
| 1 | Shop | **Med** | `bundle-everything.bundle` is filled at startup from every non-limited, non-bundle item id (`app.js:2061-2069`); buying it grants all components. | `bundle: []`, never populated → buying the Everything Pack granted only the bundle entry, none of its 45 components. | Added `ShopCatalog.bundleComponents(id)` + `_everythingComponents` (computed `styles+flair+special` where `maxSupply == null`); `ShopController.grant` now grants those. New tests lock the 45-item resolution + exclusions. |
| 2 | Calls | **Med** | `_onCallInvite` validates *claimed* group members against the real roster (`!roster \|\| roster.includes(pk)`) and only adds extra members for group calls (`calls.js:340-353`). | Added every claimed member with no roster check, and ran the loop even for 1:1 calls. | Gated the member loop behind `isGroup && groupId != null`, look up the group via `_groupById`, and require `roster == null \|\| roster.contains(pk)`. |
| 3 | Shop | **Med (UI)** | Owned/unowned item cards expose **GIFT** (`promptGiftShopItem`) and inventory items expose **Transfer** (`promptTransferShopItem`) — both prompt for a 64-hex recipient pubkey with validation. The controller methods existed but no UI invoked them. | `shop_modal.dart` only wired Buy / Activate / Redeem. | Added a shared `_RecipientPubkeyDialog` (64-hex validation + self-pubkey rejection), a `Gift` pill on buyable cards, a `Transfer` pill on inventory items, and threaded `recipientPubkey` through `_InvoiceDialog → buy()`. Gift's offline manual-confirm grants nothing locally (item goes to recipient). |

## Subsystem fidelity notes

### Zaps (`lib/features/zaps/**`) — faithful
- LNURL-pay: address split → `https://{domain}/.well-known/lnurlp/{user}`; callback
  `amount` in **millisats** (`sats*1000`); `comment` clamped to `commentAllowed`;
  `nostr=` param only when `allowsNostr && nostrPubkey`. Matches `zaps.js:95-162`.
- kind-9734 zap request tag order matches exactly: message zaps unshift `['e', id]`
  to front and push `['k', kind]` to the end → `[e, p, amount, relays, k]`; profile
  zaps omit `e` and use `k='0'`. (`zaps.js:806-844`.)
- bolt11 amount parse (`^lnbc(\d{1,15})([munp])`, m·100000 / u·100 / n÷10 / p÷10000,
  bounds `0 < sats ≤ 1e9`) matches `parseAmountFromBolt11`.
- Receipt dedup key `'b:' + bolt11.toLowerCase()` (fallback event id) — `zaps.js:1250`.
- LUD-21 verify polling returns `settled||paid == true`. Presets/min-max validation
  match.

### Shop (`lib/features/shop/**`) — faithful after fixes
- **Full catalog verified item-by-item against `app.js:1113-2059`:** 18 styles, 18
  flair, 9 special (1 supporter + 8 cosmetics), 3 limited (genesis/eclipse/crt), 3
  bundles = **51 items**. Every id, name, price, tier, type, `maxSupply`,
  `startsAt`/`endsAt`, and bundle component list matches.
- 5 tabs (styles/flair/special/limited/inventory) present.
- `/api/storage` actions match: `shop-buy-invoice`, `shop-check`, `shop-claim`
  (402/"not confirmed" retry ×6/2s), `shop-redeem`, `shop-transfer`; gift = buy with
  `recipientPubkey`. Ownership/active record (`{owned, active}`), single-active
  style+flair, multi-active cosmetics, supporter toggle all match.
- Cosmetic application (style text/glow/gradient/bg, supporter-style gold, flair
  badges with Genesis edition stamping) ported from `css/styles-features.css`.

### Calls (`lib/features/calls/**`) — faithful after fix #2
- kind-25053 signaling gift-wrapped (kind 1059) via engine `sendCallSignal`.
- Glare guard `selfPubkey < peerPubkey` (offerer = smaller); full-mesh one
  `RTCPeerConnection` per peer; `videoSender` tracked for screenshare/switch.
- Signal payload shapes (invite/accept/reject{reason}/cancel/hangup/offer{sdp:{type,
  sdp}}/answer/ice{candidate:{…}}/share{on}/reaction/chat{text≤2000,mid}) match
  `calls.js` and the existing `calls_notifications_test.dart` golden assertions.
- ICE config (`lib/core/constants/relays.dart IceServers`) = the PWA's 6-server list
  (0xchat STUN+TURN `Prettyvs511`, 3× Google STUN, Cloudflare STUN).
- 45s ring/incoming timeout; `acceptCalls` gate (disabled/friends/enabled); in-call
  mute/cam/screenshare/switch/hangup track manipulation all match.

### P2P (`lib/features/p2p/**`) — faithful
- 16 KiB (`16384`) chunks; 2 GiB cap; whole-file SHA-256 verify with the exact abort
  message "file content does not match advertised hash" (`p2p.js:572`).
- Signaling kinds 25051 (offer/answer/ice-candidate) + 25052 (unseeded), **plain
  p-tagged, NOT gift-wrapped** — matches. Signal type strings `offer`/`answer`/
  `ice-candidate` match `p2p.js:53-57`.
- Backpressure high/low water = `chunkSize*16` / `chunkSize*4`. Transfer states
  connecting/transferring/complete/error; progress = bytes/size.

### Notifications (`lib/features/notifications/**`) — faithful
- All **18** synthesized sounds ported **note-for-note** (frequencies, durations,
  gaps, gains, chords, a/h/g envelopes) from `notifications.js:680-805`; legacy
  aliases `icq→uhoh`, `msn→msnding`; 2 s replay dedup; `none`/unknown → silent.
- Gating mirrors `showNotification`: `notificationsEnabled`, blocked, bot,
  `notifyFriendsOnly`, group `mentionsOnly`, channel-mention-only, active-view skip.

## Deferrals (platform-justified, not fidelity defects)

| Area | Note |
|------|------|
| P2P WebTorrent | No native WebTorrent client on Flutter; the large-file/torrent path falls back to the direct WebRTC data-channel. Documented in `p2p_service.dart`. Magnet/torrent *offers* surface as unsupported rather than crashing. |
| Call signal `nym` field | The PWA merges `{...payload, nym}` at send; the native engine `nostr_controller.sendCallSignal` (in `state/**`, out of this slice's edit scope) omits `nym`. The receiver tolerates it (`data['nym'] ?? _nymFor(sender)`), so display nyms still resolve. Flagged for the `state/**` owner. |
| `_isFriend` (calls) | Returns `false` until friends land in the native store, so `acceptCalls:'friends'` errs safe (blocks unknown callers). TODO in `call_service.dart`. |
| `notifyFriendsOnly` / `groupNotifyMentionsOnly` | Not yet on the shared `Settings` model; passed as params (default off = PWA default). TODO in `notifications_service.dart`. |
| Live `/api/storage` + LNURL hosts | Unreachable in this environment; request/response shapes mirror the PWA byte-for-byte and are unit-tested, with offline manual-confirm fallbacks. |
| `playSound` dedup ordering | PWA stamps `_lastSoundPlayedAt` before the silent/unknown check; Flutter stamps only for audible sounds. No observable difference because `notify()` only calls `playSound` when `soundIsAudible`. |
| Animated/watermark style effects | Per-glyph SVG watermarks and animated prism/glitch effects from CSS are intentionally approximated (static colour+glow+gradient+bg). |

## Summary
- **Discrepancies found:** 3 (all fixed).
- **Fixes:** Everything-Pack bundle resolution (#1), group-call roster validation
  (#2), Gift/Transfer shop UI (#3) + 3 new catalog tests.
- **Deferrals:** 7 (platform/cross-boundary, documented above).
- **Verify:** scoped `flutter analyze` clean; `payments_test` + `calls_notifications_test`
  → 53 passed.
