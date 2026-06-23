# Audit 01 — Protocol / crypto / constants / models

1:1 fidelity audit of the Flutter port against the Nymchat PWA source
(`/home/user/nym-staging/js/**`). Scope: `lib/core/crypto/**`,
`lib/core/constants/**`, `lib/core/utils/**`, `lib/models/**`.

## Summary

- Discrepancies found: **5** (2 protocol bugs fixed, 3 missing constants added).
- Most of the slice was already a faithful port (NIP-44 v2, NIP-59 seal/wrap,
  bitchat XChaCha20, PoW, bech32, geohash codec, haversine, suffix/PM-key
  helpers all verified correct against the PWA).
- Verification: `flutter analyze lib/core lib/models` clean;
  `flutter test test/crypto_test.dart test/models_test.dart test/signer_test.dart`
  green (40 tests).

## Discrepancy table

| Item | PWA behavior | Flutter before | Action |
|------|--------------|----------------|--------|
| `compareMessages` ms tiebreak | `_hasRealMsTag(m)` requires `_ms > created_at*1000` (i.e. a genuine sub-second tag, since `_ms` is the **full** `Date.now()` ms value). Only then is `_ms` used as a tiebreak; otherwise falls to `_seq`. | Used `a.ms != 0 && b.ms != 0` as the gate — would treat any non-zero ms (including the floor-to-second fallback) as a real tag. | **Fixed** — added `_hasRealMsTag` mirroring the PWA (`ms > 0 && ms > createdAt*1000`); corrected the misleading "sub-second" doc on `Message.ms` (it is an absolute ms timestamp). Updated `models_test.dart` to use realistic full-ms values; added cases for the at/below-boundary fallback. |
| `channelWire(channelKey)` | `!!channelKey && isValidGeohash(channelKey)` → geohash (20000/`g`) else named (23333/`d`). No special-case for the default channel. | Had an extra `&& channelKey != kDefaultChannel`. Harmless in practice ('nymchat' contains 'a' so it already fails `isValidGeohash`), but a literal deviation. | **Fixed** — now matches PWA exactly (`channelKey.isNotEmpty && isValidGeohash(...)`); behavior for every channel including 'nymchat' is unchanged. |
| Missing kind 15 (NIP-17 file message) | Accepted in the DM rumor list (`pms.js`: `rumor.kind !== 15`). | Not present in `EventKind`. | **Fixed** — added `EventKind.fileMessage = 15`. |
| Missing kind 1984 (NIP-56 report) | `ui-context.js`: report event `kind: 1984`. | Not present. | **Fixed** — added `EventKind.report = 1984`. |
| Missing kind 24242 (Blossom auth) | `users.js` `_signBlossomEvent`: `kind: 24242`. | Not present. | **Fixed** — added `EventKind.blossomAuth = 24242`. |
| `expiration` tag on gift wraps | PWA `if (expirationTs) wrap.tags.push(['expiration', ...])` — truthy check skips both `null` and `0`. | `if (expiration != null)` — would emit `['expiration','0']` for a `0` arg. | **Fixed** — guard is now `expiration != null && expiration != 0` in all four wrap fns (defensive; callers pass null/real ts). |

## Verified already-correct (no change)

| Area | Notes |
|------|-------|
| NIP-44 v2 | HKDF-Extract(salt=`nip44-v2`), HKDF-Expand→(chachaKey32, nonce12, hmacKey32), `calcPaddedLen` (bit-length form equals nostr-tools `1<<(floor(log2(len-1))+1)`), payload `0x02‖nonce32‖ct‖mac32`, AAD=`nonce‖ct`, constant-time MAC. Passes official vectors (conversation-key + fixed-nonce encrypt). |
| NIP-59 seal/wrap | seal kind 13 signed by sender, wrap kind 1059 signed by fresh ephemeral key, `['p', recipient]` tag, `randomNow` ±2h CSPRNG backdating (`now - r*7200`, rounded). `unwrapGiftWrap` candidate loop + bitchat-first-on-`v2:` ordering matches `nym-crypto.js`. Async signer variants are a faithful extension of the remote-signer path. |
| bitchat transport | IKM = 33-byte **compressed** shared point `sk·liftEven(pub)` (incl. parity prefix byte), HKDF-Extract(empty salt)→Expand(info=`nip44-v2`,32), XChaCha20-Poly1305, 24-byte nonce, `v2:<base64url(nonce‖ct‖tag)>`. Decrypt tries `02`/`03` parity like the PWA. |
| PoW (NIP-13) | `getPow` leading-zero-bit count, `minePow` appends/replaces `['nonce', n, difficulty]` and commits difficulty in 3rd element, `validatePow` checks both raw zero bits and the committed target. |
| bech32 (NIP-19) | npub/nsec/note, 8↔5 bit conversion + padding rules; passes known npub/nsec vectors. |
| keys / schnorr | secp256k1 order bound on key gen, BIP340 x-only pubkey, `finalizeEvent` rebinds pubkey before id/sig. |
| event id | NIP-01 `[0,pubkey,created_at,kind,tags,content]` sha256 (both `NostrEvent` and `UnsignedEvent`). |
| relays | 18 default relays in exact order, write-only `{sendit.nosflare.com}`, app relay `relay.nymchat.app`, geoRelayCount 5, maxRelaysForReq 1000, relayTimeout 2000, blacklist 120000 — all match `app.js`. |
| ICE servers | 6 servers (0xchat stun/turn incl. `Prettyvs511` cred, 3× google stun, cloudflare) in exact order, matches `app.js` `p2pIceServers`. |
| event kinds | All other kinds verified against `kind:` literals + instance constants across `js/**`: 0,5,7,13,14,1059,9734,9735,10000,10030,20000,23333,24133,24420,24421,25051-25054,27235,30030,30078,69420. |
| geohash codec | alphabet `0123456789bcdefghjkmnpqrstuvwxyz`, lng-first bit interleave, decode/encode match `geohash-globe.js` (encode `>= mid`, 5-bit emit). |
| haversine | R=6371; Flutter uses the `(1-cos)/2` + `2·asin(√a)` identity = PWA `sin²` + `2·atan2` form (mathematically identical output). |
| nym helpers | `getPubkeySuffix` (last-4 hex or `????`), `stripPubkeySuffix` (`#[0-9a-f]{4}$`), `getPMConversationKey` (`pm-` + lexicographically-sorted pair) all match PWA `users.js`/`pms.js`. |

## Deferred / notes (no change)

- **`getNymFromPubkey`**: the PWA method of this name (`users.js`) is a *stateful*
  lookup over `this.users`/`this.pmConversations` and belongs in the service
  layer (out of this slice's edit scope). The Flutter `getNymFromPubkey(baseNym,
  pubkey)` in `nym_utils.dart` is a distinct *pure* `base#suffix` formatter — not
  a 1:1 port but a reasonable local utility. Left as-is; the stateful version is
  a services concern.
- **`POLL_VOTE_KIND`/`POLL_KIND`/`PRESENCE_KIND` = 30078**: correctly aliased to
  `appData`; topic discrimination via `['t', ...]` (`AppDataTopic`) matches.
