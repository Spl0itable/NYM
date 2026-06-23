# Nymchat Feature Subsystems — Implementation Spec (04-features)

Implementation-grade reference for reimplementing Nymchat's **feature** subsystems 1:1 as a
native Flutter app. Scope: voice/video calls, Lightning zaps, flair shop, P2P file sharing,
geohash globe explorer, emoji, translation, notifications, settings, panic mode, and the Nymbot
client surface.

Source of truth: `js/modules/{calls,zaps,shop,p2p,geohash-globe,emoji,translate,notifications,settings,panic,channels}.js`,
`js/geo-decode*.js`, `functions/api/{bot,_ledger}.js`, plus shared constants in `js/app.js`.

### Shared event-kind / transport constants (`js/app.js` 711–733)

| Constant | Value | Used by |
|---|---|---|
| `P2P_SIGNALING_KIND` | `25051` | P2P file-transfer WebRTC signaling (plain p-tagged relay events) |
| `P2P_FILE_STATUS_KIND` | `25052` | P2P "unseeded" file-status announcements |
| `CALL_SIGNALING_KIND` | `25053` | Call signaling **rumor** kind, wrapped in NIP-17 kind 1059 gift wraps |
| `P2P_CHUNK_SIZE` | `16384` (16 KiB) | P2P data-channel chunk size |
| `P2P_MAX_FILE_SIZE` | `2 * 1024^3` (2 GiB) | P2P transfer cap |

`channelWire(key)` (channels.js:454): geohash channels → `{kind:20000, tag:'g'}`; named channels →
`{kind:23333, tag:'d'}`. A key is a geohash when `isValidGeohash(key)` is true.

WebRTC `iceServers` (`p2pIceServers`, app.js:711) — **shared by calls and P2P file transfer**:

```
[
  { urls: 'stun:rtc.0xchat.com:5349' },
  { urls: 'turn:rtc.0xchat.com:5349', username: '0xchat', credential: 'Prettyvs511' },
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
  { urls: 'stun:stun2.l.google.com:19302' },
  { urls: 'stun:stun.cloudflare.com:3478' }
]
```

Flutter: configure once as `Map<String,dynamic>` for `RTCPeerConnection(configuration)` in
`flutter_webrtc`. Both subsystems consume the same list.

---

## 1. Voice / Video Calls (`js/modules/calls.js`, 1993 lines)

### 1.1 Topology & approach

- **Full-mesh peer-to-peer** (no SFU). For N participants, each maintains N−1 `RTCPeerConnection`s.
- 1:1 and group calls share the same code path; group is just N>1 members.
- Media flows peer-to-peer over WebRTC. **Signaling is carried inside NIP-17 gift wraps** (rumor
  kind `25053` sealed in a kind 1059 gift wrap, via `_sendGiftWrapsAsync`). This is the key
  difference from P2P file sharing (which uses plain relay events).
- **Flutter equivalent**: `flutter_webrtc` (`RTCPeerConnection`, `MediaStream`, `RTCVideoRenderer`,
  `getUserMedia`, `getDisplayMedia`, `RTCDataChannel`). Reuse the existing NIP-17 gift-wrap send/
  receive path for signaling transport.

### 1.2 Lifecycle functions

| Function | Lines | Purpose |
|---|---|---|
| `startCall(kind)` | 70–133 | Begin outgoing audio/video call. Gets media, makes `activeCall` (status `outgoing`), broadcasts `invite`, 45 s ring timeout → `cancel`. |
| `acceptCall()` | 380–423 | Stops ringtone, gets media, builds `activeCall` (status `connecting`), broadcasts `accept`, connects to inviter then early acceptors. |
| `rejectCall()` | 425–434 | Sends `reject` with `reason:'declined'`; records call as declined. |
| `hangupCall()` / `_endCall()` | 632–655 | Broadcast `hangup`, close PCs/streams, clear timers, hide overlay, `activeCall=null`. |
| `_connectToPeer(pk)` | 492–548 | New `RTCPeerConnection`, add local tracks, wire `onicecandidate`/`ontrack`/`onconnectionstatechange`. |
| `_makeOffer(pk)` | 550–560 | **Offer only if `this.pubkey < peerPubkey`** (lexicographic tie-break to avoid glare). |
| `_onCallOffer/_onCallAnswer/_onCallIce` | 562–612 | Apply remote SDP / queue+flush ICE candidates. |
| `_renderCallGrid` / `_ensureTile` | 794–863 | Render local + per-peer tiles (avatar, nym, video, "Presenting" badge). |

Call-id: `'call-' + base36(random) + base36(now)`.

### 1.3 Signaling payloads (rumor content = JSON; `nym` appended)

Sent via `_sendCallSignal(target, payload)` (135–153). Each payload has `type`, `callId`, and
type-specific fields, plus the sender's `nym`. Group signals also carry `groupId`
(`_callSignalGroupId(callId)`).

| `type` | Fields | Meaning |
|---|---|---|
| `invite` | `kind('audio'|'video')`, `isGroup`, `groupId`, `members[]` | Ring |
| `accept` | — | Callee accepted |
| `reject` | `reason('busy'|'media'|'declined')` | Callee declined |
| `cancel` | — | Caller cancelled (timeout) |
| `hangup` | — | Leave/end |
| `offer` / `answer` | `sdp` (RTCSessionDescription) | SDP exchange |
| `ice` | `candidate` (RTCIceCandidate) | Trickle ICE |
| `share` | `on(bool)` | Screen-share toggle |
| `present-state` | `restricted(bool)`, `presenter(pk|null)` | Mod presenter lock |
| `present-request` | — | Request presenter |
| `reaction` | `emoji`, emoji tags | In-call emoji |
| `chat` | `text(≤2000)`, `mid` | In-call text |
| `chat-reaction` | `mid`, `emoji`, `op('add'|'remove')` | React to in-call msg |
| `chat-typing` | `status('start'|'stop')` | Typing |
| `chat-read` | `mid` | Read receipt |

### 1.4 Media constraints (`_getLocalMedia`, 58–68)

- Video: `{audio:true, video:{width:{ideal:1280}, height:{ideal:720}, facingMode:'user'}}`
- Audio: `{audio:true, video:false}`
- Mute/camera toggles disable tracks (`toggleCallMute`/`toggleCallVideo`); `switchCamera` flips
  `facingMode` and `videoSender.replaceTrack(newTrack)`. Screen share uses `getDisplayMedia`,
  replacing the video sender's track.

### 1.5 Timeouts / ringtone

- Outgoing & incoming ring: **45 s**. Ringtone: 480 Hz oscillator, 0.4 s beep every 2 s.
- In-call timer: MM:SS elapsed. Typing expiry 5 s; stop-throttle 3 s.
- Peer `connectionState` `failed`/`closed` → `_removePeer` (group) or end (1:1). No auto-reconnect.
- Seen-call cache in localStorage `nym_seen_calls`, 24 h TTL (statuses: pending/missed/declined/
  answered/seen) prevents re-ringing on reload.

### 1.6 Data models (Dart-mappable)

```dart
class ActiveCall {
  String callId; String kind;            // 'audio'|'video'
  bool isGroup; String? groupId;
  MediaStream? localStream, screenStream; bool sharing;
  String status;                          // 'outgoing'|'connecting'|'active'
  Map<String,PeerEntry> peers; List<String> members;
  bool muted, cameraOff; String facingMode; bool switchingCamera;
  int? startedAt; Timer? timerInterval, ringTimeout;
  Set<String> sharingPeers; bool shareRestricted; String? presenter; Set<String> presentRequests;
  List<CallChatMessage> chatLog; int chatUnread;
  Map<String,Map<String,Set<String>>> chatReactions;        // mid->emoji->pubkeys
  Map<String,ChatTyper> chatTypers; Map<String,Map<String,String>> chatReaders; Set<String> sentChatReads;
}
class PeerEntry { RTCPeerConnection pc; MediaStream stream; List<RTCIceCandidate> pendingCandidates;
  bool haveRemote; RTCRtpSender? videoSender; String nym; }
class IncomingCall { String callId, kind; bool isGroup; String? groupId; String from, nym;
  List<String> members; Set<String> acceptedPeers; Timer? timeout; }
class CallChatMessage { String pubkey, text; bool isSelf; String mid; }
```

---

## 2. Lightning Zaps — NIP-57 (`js/modules/zaps.js`, 2025 lines)

### 2.1 Flow summary

LN address → LNURL-pay lookup → optional zap request (9734) → invoice (bolt11) → pay (WebLN/QR/
copy/open-wallet) → confirm (LUD-21 verify URL, else listen for kind 9735 receipt) → record/display.

### 2.2 LNURL / Lightning-address resolution (`fetchLightningInvoice`, 95–162)

- LN address `user@domain` → `GET https://{domain}/.well-known/lnurlp/{user}` (via CF proxy
  `proxiedJsonFetch`). Response: `minSendable`/`maxSendable` (millisats), `callback`,
  `commentAllowed?`, `allowsNostr?`, `nostrPubkey?`.
- Invoice fetch: `GET {callback}?amount={millisats}&comment={...}&nostr={zapRequestJSON}`.
  Returns `pr` (bolt11), `successAction?`, `verify?` (LUD-21).
- **Always millisats on the wire (sats×1000); display sats.** Comment truncated to `commentAllowed`.

### 2.3 Zap request — kind 9734 (`createZapRequest`, 800–848)

Tags: message zap → `['e',msgId]`, `['p',recipient]`, `['amount',msat]`, `['relays',...≤5]`,
`['k',originalKind]` where originalKind ∈ `'20000'|'23333'|'1059'`. Profile zap → no `e`, `['k','0']`.
Signed; saved as `_lastSignedZapRequest` for the receipt.

### 2.4 Payment & confirmation

Methods: LUD-21 `verify` polling (every 1 s, ≤180 = 3 min); fallback kind-9735 receipt listen
(`kinds:[9735],"#p":[recipient]`, 3 min); QR (raw bolt11); copy invoice; `openInWallet()` →
`lightning:{pr}` / `window.nymOpenExternal`. Bot-credit purchases use a worker `create-invoice` +
`check-invoice` poll (every 2 s). Verification trust order: LUD-21 > provider pubkey match > best-
effort bolt11 receipt match. Dedup key `'b:'+bolt11.toLowerCase()`.

### 2.5 Zap receipts — kind 9735

Tags include `['p',recipient]`, `['e',eventId]?`, `['bolt11',pr]`, `['description',zapReqJSON]`,
optional `['k',...]`/`['g',...]`/`['d',...]`. Receipts archived to D1 scoped `channel`/`pm`/`profile`
(batch flush 4 s, ≤100); backfilled on startup from D1 then relays. Incoming profile/message zaps
trigger notifications and a **zap-burst animation** (flash + 9 radiating bolts, 800 ms;
`.zap-badge-shock` 600 ms). Badge shows aggregated sats with zapper count.

### 2.6 Own lightning address

Stored localStorage `nym_lightning_address_{pubkey}` + in-memory `lightningAddress`; falls back to
kind 0 profile `lud16`/`lud06`. Settings field `lightningAddress` (synced via privacy section).

### 2.7 Data models

```dart
class LNURLPayResponse { int minSendable, maxSendable; String callback; int? commentAllowed; bool allowsNostr; String? nostrPubkey; }
class InvoiceResponse { String pr; dynamic successAction; String? verify, providerPubkey; int amount; }
class ZapRequest { int kind=9734, createdAt; String pubkey, content; List<List<String>> tags; String? id, sig; }
class ZapReceipt { int kind=9735, createdAt; String pubkey, content; List<List<String>> tags; String id, sig; }
class PendingZap { String? messageId; String recipientPubkey, recipientNym, lnAddress;
  bool isProfileZap=false, isBotCreditPurchase=false; String? giftRecipientPubkey, messageKind, geohash, channelId, groupId, pmPeer; }
class MessageZaps { Set<String> receipts; Map<String,int> amounts; Map<String,int>? unverified; }
```

---

## 3. Flair Shop (`js/modules/shop.js` 2023 + `functions/api/_ledger.js` 412)

### 3.1 Catalog (server `SHOP_CATALOG`; exact ids/prices)

**Message styles** (`type:'message-style'`): `style-satoshi` 21420 (legendary), `style-glitch`
10101, `style-aurora` 2424, `style-neon` 1984, `style-ghost` 666, `style-matrix` 1337 (legendary),
`style-fire` 911, `style-ice` 777, `style-rainbow` 2222, `style-ocean` 1500, `style-sakura` 3000,
`style-galaxy` 4444, `style-toxic` 1300, `style-gold` (Midas) 8888, `style-vapor` 1995,
`style-blood` 1313, `style-royal` 6000, `style-circuit` 2048. **Limited**: `style-eclipse` 9000
(supply 1000), `style-crt` 12000 (supply 250, legendary).

**Nickname flair** (`type:'nickname-flair'`): `flair-crown` 5000, `flair-diamond` 10000 (legendary),
`flair-skull` 1666, `flair-star` 2500, `flair-lightning` 2100, `flair-heart` 1111, `flair-mask`
(Fawkes) 4200 (legendary), `flair-rocket` 2300, `flair-shield` 1900, `flair-flame` 1200,
`flair-snowflake` 1400, `flair-moon` 1600, `flair-sun` 1500, `flair-leaf` 900, `flair-music` 1100,
`flair-eye` 1800, `flair-anchor` 1000, `flair-gem` (Ruby) 3300. **Limited**: `flair-genesis` 25000
(supply 100, numbered #1–100, legendary).

**Special**: `supporter-badge` 42069 (`type:'supporter'`); auras `cosmetic-aura-gold` 3500,
`-neon` 3200, `-cosmic` 5000, `-phoenix` 12000 (legendary), `-rainbow` (Prism) 11000 (legendary);
`cosmetic-redacted` 2800, `cosmetic-frost` 2600, `cosmetic-bubble-hologram` 13500 (legendary).

**Bundles** (`type:'bundle'`): `bundle-starter` 3000 (flair-flame+style-ice+cosmetic-frost),
`bundle-legendary` 30000 (phoenix+rainbow+hologram), `bundle-everything` 149999 (all non-limited,
non-bundle items).

### 3.2 Purchase / claim flow

`purchaseItem(itemId, recipientPubkey?)` → `shop-buy-invoice` (validates item & availability,
generates bolt11, reserves a slot for limited items via ledger `shop-reserve`, returns `pr`,
`verify?`, `serverVerify`, `invoiceId=sha256(pr)`). Pay → verify (LUD-21 / server poll / NIP-57
receipt) → `_claimShopPurchase` → `shop-claim` (atomic; bundles grant each component with its own
code; numbered items allocate an edition number; gift → gift-wrapped DM). Item lands in the user's
shop record; recovery code shown.

### 3.3 Storage & application

Per-pubkey shop record (D1 `DB_SHOP`): `owned{itemId:{at,amountSats,code,gift,edition?,editionMax?,
fromBundle?,transferredFrom?,redeemed?}}`, `active{style?,flair[],cosmetics[],supporter,editions{}}`.
Cached locally (`nym_shop_record`, `nym_shop_active_cache`). Applied by adding CSS classes to
`.message` (style id, `supporter-style`, cosmetic id, `cosmetic-redacted-message`) and badge spans
to `.message-author` (`.flair-badge.{id}`, `.supporter-badge`). Activation: `shop-set-active` +
local re-render; only one style and one flair active at a time, multiple cosmetics allowed.

### 3.4 Gifting / transfer / redeem

- **Gift**: buy with `recipientPubkey`; item granted to recipient + gift DM.
- **Transfer**: `shop-transfer {itemId,toPubkey}` — atomic move, preserves edition & code, marks
  `gift:true,transferredFrom`.
- **Redeem code**: format `NYM-[0-9A-F]{32}`; `shop-redeem {code}` moves item to redeemer
  (`redeemed:true`), does **not** preserve edition number. One code per purchase, travels with item.

### 3.5 Ledger Durable Object (`_ledger.js`)

Single global instance, all money ops serialized through `_exclusive()`. SQL tables: `replay`
(auth nonces), `claims` (double-spend gate), `edition_minted`, `edition_resv` (reservations,
TTL 1800 s). Ops: `replay`, `transfer-credits`, `consume-credits`, `claim-credits`, `shop-claim`,
`shop-transfer`, `shop-redeem`, `shop-reserve`, `shop-supply`. Credit record (`DB_CREDITS`, key
`pk` or `pk#pro`): `{balance,totalPurchased,totalUsed,rl[],createdAt}`.

### 3.6 Public shop endpoints for Flutter

`shop-get`, `shop-set-active`, `shop-buy-invoice`, `shop-check`, `shop-claim`, `shop-transfer`,
`shop-redeem` (auth required); `shop-status` (batch active items for other users) and `shop-supply`
(remaining counts) are public/unauthenticated.

```dart
class ShopItem { String id,name,description,type; int price; String? tier,icon; int? maxSupply,startsAt,endsAt; List<String>? bundle; }
class OwnedItem { String itemId; int timestamp,amountSats; String? code; bool gift; int? edition,editionMax; String? fromBundle,transferredFrom; bool? redeemed; }
class ActiveItems { String? style; List<String> flair,cosmetics; bool supporter; Map<String,int>? editions; }
```

---

## 4. P2P File Sharing (`js/modules/p2p.js`, 1145 lines)

Two paths: **WebRTC data channels** (direct, default) and **WebTorrent** (larger/torrent files).

### 4.1 Direct WebRTC data-channel transfer

- `shareP2PFile(file)`: SHA-256 the file → `offerId = hash[:16]+'-'+base36(now)`; store in
  `p2pPendingFiles`; build `fileOffer{offerId,name,size,type,hash,seederPubkey,timestamp}`; announce
  it (`publishFileOffer`) into the channel/PM/group as an `['offer', JSON]` tag.
- Receiver `requestP2PFile(offerId)` → `createP2PConnection(seeder, transferId, true)`. **Signaling
  is plain `kind 25051` events p-tagged to the peer** (`sendP2PSignal`) — NOT gift-wrapped.
  Types: `offer`/`answer`/`ice-candidate` (each with `transferId`, offer carries `offerId`).
- Data channel `'fileTransfer'` (ordered). Sender: metadata JSON first, then 16 KiB chunks with
  backpressure (`bufferedAmount` high-water `chunk*16`, low-water `chunk*4`), then `{type:'complete'}`.
- Receiver accumulates chunks; **verifies size + SHA-256 hash** against the offer before triggering
  a browser download. Caps at `P2P_MAX_FILE_SIZE` (2 GiB). 30 s connect timeout; `iceConnectionState`
  `failed`/`disconnected` → error+cleanup.
- `stopSeeding` broadcasts `kind 25052` (`status:'unseeded'`) so peers grey out the offer.

### 4.2 WebTorrent (`shareP2PFileTorrent`, `downloadTorrent`)

- Lazy-imports WebTorrent (`window.NYM_CDN.webtorrent`). `client.seed(file)` (or add a `.torrent`)
  → `onTorrentReady` adds `magnetURI`/`infoHash` to the same `fileOffer` shape and announces it.
- Download validates magnet infohash (40-hex or 32-base32) against the advertised hash, rejects
  oversize, saves each file via `file.getBlob`. Falls back to direct P2P if WebTorrent unavailable.

### 4.3 Flutter strategy

`flutter_webrtc` `RTCDataChannel` for the direct path (same chunking/backpressure/hash-verify).
WebTorrent has no first-class Flutter port — either bridge `dart-torrent` / a native torrent lib or
omit the torrent path initially and rely on direct WebRTC + the existing image/video upload host.

```dart
class FileOffer { String offerId,name,type,hash,seederPubkey; int size,timestamp; String? magnetURI,infoHash; }
class P2PTransfer { String offerId; FileOffer offer; String status; int bytesReceived,startTime; bool isTorrent; }
```

---

## 5. Geohash Globe Explorer (`js/modules/geohash-globe.js`, 1284 lines)

### 5.1 What it actually is

**Not three.js / d3.** It is a hand-rolled **2D equirectangular world map drawn on a `<canvas>`**
(`#geohashMapCanvas`). No external mapping library; `project(lng,lat)`/`unproject` do a plain
linear lng/lat→pixel mapping with a `view{cx,cy,zoom}` camera (zoom 1–16).

### 5.2 Data files (`/data/*.json`, vendored)

| URL | File | Decoder | Zoom gate |
|---|---|---|---|
| `/data/countries-110m.json` | world-atlas TopoJSON | `decodeWorld` (`objects.countries`) | always |
| `/data/ne_50m_admin_1_states_provinces_lakes.json` | Natural Earth GeoJSON | `decodeAdmin1` | zoom ≥ 2.5 |
| `/data/ne_50m_populated_places_simple.json` | Natural Earth GeoJSON | `decodeCities` | zoom ≥ 2.5 |

Decoding (`js/geo-decode.js`) is portable JS: TopoJSON arc-stitching + per-feature bounds/centroid/
area annotation; cities keep `scalerank`/`pop`. Decoding runs in a **Web Worker**
(`js/geo-decode-worker.js`, `importScripts('/js/geo-decode.js')`) with main-thread fallback. Files
fetched `cache:'force-cache'`.

### 5.3 Rendering & interaction

`draw()` layers: ocean fill → graticule → countries (`evenodd`) → admin1 (fade-in past 2.5) →
country labels → admin1 labels → then either **heatmap** (log-scaled message density, custom 256px
gradient palette, `lighter` compositing) or cities+channel dots → optional **day/night terminator**
(computed `solarPosition(date)`) → optional **geohash grid** (precision auto from zoom, base32
encode/decode inline) → user-location dot.

Channels render as dots (`geohashChannels[]`, color green if joined else `--primary`). Interaction:
pointer drag to pan, wheel/pinch to zoom (zoom-to-cursor), click a dot → `selectGeohashChannel`,
or in grid mode click a cell → `_selectGeohashCell(geohash)` → zoom-to-bounds + select. Controls:
zoom ±, Reset View, Heat, Day/Night, Geohash grid, and an **active-window selector (1/3/6/12/24 h)**.
Activity counts pulled from D1 (`fetchGeohashActivityFromD1`), refreshed every 30 s; day/night every
60 s. `joinSelectedGeohash` adds the channel, switches to it, and persists to `userJoinedChannels`.

### 5.4 Flutter strategy

Reimplement on a `CustomPainter` over a `Canvas` (or `flutter_map` if a tile/GeoJSON renderer is
preferred). Port `geo-decode.js` to Dart (TopoJSON arc-stitch + GeoJSON), ship the same 3 JSON assets
under `assets/data/`, decode in an `Isolate` (worker equivalent). Reuse the inline base32 geohash
encode/decode, `solarPosition`, heat palette, and the equirectangular `project`/`unproject` math
verbatim.

---

## 6. Emoji (`js/modules/emoji.js`, 570 lines)

- **Custom emoji = NIP-30.** Sources: message `['emoji', shortcode, url]` tags (`ingestEmojiTags`),
  kind **30030** emoji-pack events (`handleEmojiPackEvent`, ≤120 emoji/pack), kind **10030** user
  emoji list (`handleUserEmojiListEvent`, `a` refs `30030:pubkey:identifier` + inline `emoji` tags).
- Shortcode regex `^[a-zA-Z0-9_]+$`; url must be `https?://`. Custom emoji never shadow built-in
  unicode shortcodes. Rendered as `<img class="custom-emoji" width=30 height=30>` via proxied URL.
- Storage: `customEmojis` map (localStorage `nym_custom_emojis`, ≤5000), `customEmojiPacks`
  (`nym_custom_emoji_packs`, ≤200). Outgoing content auto-tagged via `customEmojiTagsForContent`.
- Picker sections order: **Recently Used** → custom packs (favorited→own→subscribed→rest) → default
  categories (favorited categories first). Recents synced (`recentEmojis`, ≤24). Pack/category
  favorites synced (`emojiPackFavorites`, `emojiCategoryFavorites`). `_runEmojiPrefetch` warms
  recents + favored/own/subscribed pack images (budget 60), skipped in low-data mode.

```dart
class CustomEmojiPack { String pubkey, identifier, title; int createdAt; List<({String shortcode,String url})> emojis; }
```

---

## 7. Translation (`js/modules/translate.js`, 602 lines)

- **On-demand** translation of received messages, polls, and the input box. Target language is
  `settings.translateLanguage`; if unset, a searchable language picker is shown and the choice saved.
- **API**: CF proxy `POST {proxyBase}?action=translate` with `{text, source:'auto', target}` →
  `{translatedText, detectedLanguage}`. **Fallback**: direct Google Translate GET
  `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={lang}&dt=t&q={≤5000}`
  (8 s timeout). 109 languages in `NYM_TRANSLATE_LANGUAGES`.
- Pre-processing: strip blockquotes/quoted lines and trailing timestamps; shield emoji
  (`EMJ{n}EMJ` placeholders) and `@mentions` (split on `/(@[^\s@]+)/`) so they survive translation,
  then restore. No-op detected when output equals input ("Already in X"). Favorites pinned in the
  input dropdown (`nym_translate_favorites`).

Flutter: call the same proxy endpoint (preferred) with Google fallback; reuse the language list and
the emoji/mention shielding logic.

---

## 8. Notifications (`js/modules/notifications.js`, 869 lines)

### 8.1 Web (PWA) behaviour

- `showNotification(title, body, channelInfo?, timestamp?)`: gated by `notificationsEnabled`,
  blocked users, `notifyFriendsOnly`, verified-bot suppression, and dedup (by `eventId` or
  title+body+sender within 60 s). Adds to 24 h-rolling `notificationHistory`, updates badge,
  plays sound, and fires a Web `Notification` (with click → open PM/group/channel/reaction source).
- Seen-state: durable `seenNotificationKeys` (localStorage `nym_notification_seen`, 48 h, ≤500),
  synced via the `nymchat-notifications` gift wrap for cross-device read state. An
  `IntersectionObserver` marks items read as they scroll into view. Badge coalesced per animation
  frame; shows `99+` cap.

### 8.2 Sounds (`NOTIFICATION_SOUNDS`, Web Audio synthesized)

The settings-facing four are **Classic Beep (`beep`)**, **ICQ Uh-Oh (`uhoh`, legacy key `icq`)**,
**MSN Alert (`msnding`, legacy key `msn`)**, **Silent (`none`)**. The map also defines many extra
jingles (low, high, nudge, nokia, nokiatune, dialup, tetris, chirp, coin, powerup, pokeheal, f1,
oneup, secret, gameboy). Each is a note sequence (`f`, `d`, `f2` glide, `gap`, `chord`, `g`, `a`, `h`,
`noise`/`q`) played via `AudioContext` oscillators/bandpass noise. 2 s replay dedup. Flutter: synth
via an audio engine or ship pre-rendered clips; map legacy keys `icq→uhoh`, `msn→msnding`.

### 8.3 Flutter shell push/local notifications (`android-ios-app/lib/services/`)

- **`notification_service.dart`**: `flutter_local_notifications`. Android channel
  `'nymchat_channel'` (importance/priority high, vibration, sound). iOS Darwin alert/badge/sound.
  Unique id per notification; `payloadStream` broadcasts taps; `takeInitialPayload()` for cold-start
  launch payloads.
- **`firebase_messaging_service.dart`**: **stub / no-op** — FCM deliberately removed so the app runs
  on de-Googled devices (no Google Play Services). `getToken()` returns null. There is **no remote
  push**; notifications are local, driven by the in-WebView app logic.

---

## 9. Settings (`js/modules/settings.js`, 1198 lines)

Loaded by `loadSettings()` (localStorage) + synced via per-section encrypted gift wraps
(`_buildSettingsPayload`, sections: appearance/privacy/messaging/channels/data, schema `v:2`). Sync
skipped for ephemeral random/hardcore keypair modes. Full settings model (type · default · options):

### 9.1 Appearance
| Key | Type | Default | Options/notes |
|---|---|---|---|
| `theme` | enum | `bitchat` | `bitchat`(Multicolor), `matrix`, `amber`, `cyber`, `hacker`, `ghost`. Each has dark+light palettes. |
| `colorMode` | enum | `auto` | `auto`/`light`/`dark` (localStorage `nym_color_mode`) |
| `sound` | enum | `beep` | `beep`,`uhoh`(ICQ),`msnding`(MSN),`none`(Silent) + extra jingles |
| `autoscroll` | bool | `true` | |
| `showTimestamps` | bool | `true` | |
| `timeFormat` | enum | `12hr` | `12hr`/`24hr` |
| `dateFormat` | string | `default` | |
| `chatLayout` | enum | `bubbles` (load) / `irc` (sync default) | `irc`/`bubbles` |
| `chatViewMode` | enum | `single` | `single`/`columns` |
| `columnsWallpaper` | bool | `false` | |
| `columnsLayout` | array | `[]` | column config |
| `nickStyle` | enum | `fancy` | nick rendering |
| `wallpaperType` | enum | `geometric` | built-in patterns / custom (`nym_wallpaper_type`) |
| `wallpaperCustomUrl` | string | `''` | custom wallpaper image |
| `textSize` | int | `15` | px (`nym_text_size`) |
| `transparencyEnabled` | bool | `false` | glass/transparency |
| `sidebarSectionOrder` | array | — | sidebar ordering |

### 9.2 Privacy / identity
| Key | Type | Default | Options/notes |
|---|---|---|---|
| `blurOthersImages` | bool\|`'friends'` | `true` | blur others' images until tapped; per-pubkey + global |
| `lightningAddress` | string | `''` | your LN address for zaps |
| `dmForwardSecrecyEnabled` | bool | `false` | per-message FS for DMs |
| `dmTTLSeconds` | int | `86400` | disappearing-msg TTL |
| `readReceiptsScope` | enum | `everywhere` | `disabled`/`pms`/`groups`/`pms-groups`/`everywhere` |
| `typingIndicatorsScope` | enum | `everywhere` | same 5 scopes |
| `acceptPMs` | enum | `enabled` | who can PM you |
| `acceptCalls` | enum | `enabled` | who can call you |
| `showStatus` | bool\|`'friends'` | `true` | online-status visibility |
| `powDifficulty` | int | `0` | NIP-13 PoW (`nym_pow_difficulty`) |
| `keypairMode` | enum | `persistent` | `persistent`/`random`/`hardcore` (per-message keys) |
| `encryptAtRestPreferred` | bool | `false` | non-sensitive synced flag; per-device encryption setup (WebAuthn-PRF / PBKDF2). No key/salt/credential synced. |
| `blockedUsers`/`friends`/`blockedKeywords`/`blockedChannels`/`hiddenChannels` | set | `[]` | moderation lists |

### 9.3 Messaging
| Key | Type | Default | Notes |
|---|---|---|---|
| `groupChatPMOnlyMode` | bool | `false` | |
| `translateLanguage` | string | `''` | target lang code (empty = disabled) |
| `translateFavoriteLanguages` | array | `[]` | pinned langs |
| `emojiPackFavorites` | array | `[]` | |
| `emojiCategoryFavorites` | array | `[]` | |
| `favoriteGifs` | array | `[]` (≤100) | |
| `recentEmojis` | array | `[]` (≤24) | |
| `gesturesEnabled` | bool | `true` | swipe gestures |
| `swipeLeftAction` | enum | `quote` | |
| `swipeRightAction` | enum | `translate` | |
| `swipeThreshold` | int | `60` | px |
| `swipeReactEmoji` | string | `❤️` | |
| `notificationsEnabled` | bool | `true` | |
| `groupNotifyMentionsOnly` | bool | `false` | |
| `notifyFriendsOnly` | bool | `false` | |
| `syncMLSHistory` | bool | `true` | group-history sync |
| `seenCalls` | map | — | seen-call dedup (24 h) |

### 9.4 Channels
`pinnedChannels`, `userJoinedChannels`, `sortByProximity`(bool, `false`),
`pinnedLandingChannel`(default `{type:'geohash',geohash:'nymchat'}`), `hideNonPinned`(bool),
`closedPMs`, `leftGroups`, `closedPMTimes`, `leftGroupTimes`.

### 9.5 Data
`lowDataMode`(bool, `false`), `cachePMs`(bool, `true`), `tutorialSeen`, `botPmWelcomed`,
`botPmClearedAt`.

**Total: ~60 settings** across 5 sync sections. Themes apply via CSS custom properties
(`--primary/--secondary/--text/--text-dim/--text-bright/--lightning` + `--wp-r/g/b`); the Flutter
shell mirrors theme/light-mode to the native status bar via `window.FlutterTheme.postMessage`.

---

## 10. Panic Mode (`js/modules/panic.js`, 279 lines)

### 10.1 Trigger

`bindNymPanicGesture()` on `.nym-display`: **press-and-hold 2000 ms** (`_PANIC_HOLD_MS`) →
`panicWipe()` (haptic tap, no confirmation). A normal single tap still opens the nick editor; the
post-hold click is swallowed in capture phase. Bound for mouse + touch (`mousedown`/`touchstart`,
cancel on up/leave/move/cancel; `contextmenu` prevented).

### 10.2 Wipe sequence (`panicWipe`)

1. Show full-screen scramble overlay (`_panicShowOverlay`): "Encrypting" title, 40×8 hex/symbol
   grid re-randomized every 60 ms, status line, progress bar. Opaque so content is hidden.
2. Stop persistence/network: disable cache, clear trim/persist timers, close all relay sockets +
   proxy WS; null out `privkey`/`pubkey`/`_vaultKey`/`_vaultMem`/`_botAuthCache`.
3. **Encrypt every localStorage + sessionStorage value** with a fresh non-extractable AES-GCM-256
   key that is immediately discarded (`_panicEncryptStorage`, 600 ms budget; values prefixed
   `panic:`). Then **overwrite each value with random junk** (`_panicJunk`, 2 KiB base64) and
   `clear()`.
4. **Shred IndexedDB**: enumerate DBs (+ `nym-cache`), open each, write junk records, `clear` stores,
   `deleteDatabase` (`_panicWipeDb`, self-times-out 1.5 s).
5. **Clear Cache Storage** (`caches.keys`→delete) and **unregister all service workers**.
6. Best-effort cookie clear.
7. Final `localStorage.clear()`/`sessionStorage.clear()`, hold ≥1.5 s for effect, then
   `location.replace(origin+pathname)` → pristine first-run state.

With Identity Encryption on, any surviving bytes are already ciphertext under a key nobody holds.

### 10.3 Flutter equivalent

Wipe secure storage / Hive / sqflite DBs / app cache dirs and the WebView's localStorage+IndexedDB,
re-randomize-then-delete, and reset to first-run. Mirror the 2 s press-and-hold gesture and scramble
animation. No network/server call — entirely local.

---

## 11. Nymbot — client interaction surface (`functions/api/bot.js`, 4145 lines)

### 11.1 Public `?` commands (channel)

POST `/api/bot` `{command,args,geohash,conversation?,senderNym?,publishedContent?,channelMessages?,
activeUsers?}` → `{event}` (a **signed Nostr event**, kind 20000 geohash / 23333 named). Rate limit
20/60 s per IP. Commands: `?ask`(also `@Nymbot ...`), `?define`, `?translate`, `?news`, `?trivia
[cat]`, `?joke`, `?riddle`, `?wordplay [mode]`, `?roll [NdN]`, `?flip`, `?8ball`, `?pick`, `?math`,
`?units`, `?time`, `?btc`, `?who`, `?summarize`, `?top`, `?last [N≤25]`, `?seen`, `?help`, `?about`,
`?nostr`, `?changelog`. Context-aware (`?ask`/`?summarize` receive recent channel messages + active
users); quote-reply continues a thread (≤6 msgs history).

### 11.2 Private paid chat — credits

Same endpoint, `action` ∈ `pm|balance|create-invoice|check-invoice|claim-credits|transfer-credits|
clear-history`. **Standard credits = 10 sats each** (1 credit general/creative/translate, 2
coding/reasoning, auto-routed). **Pro credits = 100 sats each.** Bulk bonuses +10/15/20% at higher
sat tiers. PM request: `{action:'pm', pubkey, auth{id,sig,url}, eventId, fresh?, proModel?, git?}` →
`{reply, taskType, modelCalls, outputTokens}`; insufficient credits → `{noCredits, pro, balance,
required, error}`. Lightning buy: `create-invoice {amountSats, tier:'standard'|'pro', recipientPubkey?,
zapRequest?}` → `{pr, verify?, serverVerify, invoiceId}` → poll `check-invoice` → `claim-credits`.

### 11.3 Pro models (`?model <name>` / `?model off`)

`claude-fable`(Fable 5, base 2cr), `claude-opus`(4.8), `claude-sonnet`(4.6), `claude-haiku`(4.5),
`gpt-5`(GPT-5.1), `gpt-5-mini`, `codex`(GPT-5.1 Codex) — base 1 credit (Fable 2) + per-length scaling
to a per-model max (max reserved, only actual charged). Selection passed as `proModel`.

### 11.4 Git integration (`?git`)

Providers GitHub/GitLab/Gitea (incl. Codeberg/self-hosted). `git:{provider,host,token,repo,branch,
allowWrites}` — **PAT stored client-side only** (wiped by Panic Mode), sent per request, never
server-stored. Read tools (`list_files`/`read_file`/`search_code`) always; write tools
(`write_file`/`create_branch`/`open_pull_request`) when `allowWrites` (`?git writes on`). Agent loop
≤6 model calls/message (only used calls billed at the Pro model price).

### 11.5 Reasoning display

Replies may contain `<think>...</think>`; in private chat the client renders it as a collapsed
"💭 Reasoning" section (cap 4000 chars), stripped entirely in public channels.

```dart
class GitConfig { String provider,host,token,repo; String? branch; bool allowWrites; }
class BotPmResponse { String reply; String? taskType; int modelCalls, outputTokens; }
class BotBalance { int balance,totalPurchased,totalUsed,proBalance,proTotalPurchased,proTotalUsed; }
```

---

## Summary (20 lines)

1. **Calls**: full-mesh WebRTC (no SFU); 1 RTCPeerConnection per other participant; map to `flutter_webrtc`.
2. **Call signaling**: rumor kind `25053` inside NIP-17 kind-1059 gift wraps; offer only if `myPk < peerPk` (glare guard).
3. **Call types**: `invite/accept/reject/cancel/hangup/offer/answer/ice/share/present-*/reaction/chat*`; 45 s ring; full in-call chat.
4. **ICE**: shared `p2pIceServers` — 0xchat STUN+TURN (`0xchat`/`Prettyvs511`) + Google + Cloudflare STUN.
5. **Zaps (NIP-57)**: LN addr → `.well-known/lnurlp` → 9734 zap request → bolt11 → pay → confirm via LUD-21 verify or kind-9735 receipt.
6. **Zap pay**: millisats on the wire, sats in UI; QR/copy/open-wallet; dedup by lowercased bolt11; zap-burst animation.
7. **Shop catalog**: ~46+ items — 18+2 message styles, 18+1 flair, supporter + auras/cosmetics, 3 bundles; legendary tier + numbered Genesis.
8. **Shop model**: server `DB_SHOP` record `{owned,active}`; CSS classes/badges applied to messages; gifting, transfer, `NYM-` redeem codes.
9. **Shop backend**: serialized Ledger Durable Object (`_ledger.js`) — reservations, edition minting, atomic claim/transfer/redeem, replay+claim gates.
10. **P2P files**: WebRTC data channel (16 KiB chunks, backpressure, SHA-256 verify, 2 GiB cap) + WebTorrent for large/torrent files.
11. **P2P signaling**: plain `kind 25051` p-tagged relay events (offer/answer/ice), NOT gift-wrapped; `25052` unseeded announcements.
12. **Globe library**: NONE — hand-rolled 2D equirectangular `<canvas>` map (no three.js/d3); port to a Dart `CustomPainter` + isolate decode.
13. **Globe data**: `countries-110m.json` (TopoJSON), `ne_50m_admin_1...` + `ne_50m_populated_places...` (GeoJSON); decoded in a Web Worker.
14. **Globe features**: pan/zoom, heatmap, day/night terminator, geohash grid, 1–24 h active window; dots = geohash channels.
15. **Emoji**: NIP-30 — kind 30030 packs, kind 10030 user list, message `emoji` tags; recents+favorites synced; built-in unicode set.
16. **Translation**: CF proxy `?action=translate` (Google fallback, 109 langs); shields emoji + @mentions; on-demand per message/poll/input.
17. **Notifications**: web Notification + synthesized Web Audio sounds (Classic Beep/ICQ/MSN/Silent + extras); seen-state synced cross-device.
18. **Flutter notifications**: `flutter_local_notifications` only; Firebase/FCM is a deliberate no-op stub (de-Googled support) — no remote push.
19. **Settings**: ~60 settings across 5 synced sections (appearance/privacy/messaging/channels/data); 6 themes; enumerated above with types/defaults.
20. **Panic**: 2 s press-and-hold on "Your Nym" → encrypt-with-discarded-key + junk-overwrite + clear storage/IDB/caches/SW, then reload to first-run.
