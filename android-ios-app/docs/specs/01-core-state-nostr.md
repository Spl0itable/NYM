# Nymchat — Core / State / Nostr / Networking / Storage / Crypto Spec

Single source of truth for a 1:1 native Flutter reimplementation of the Nymchat Nostr messenger PWA. Identifier names, event kinds, storage keys, and crypto parameters are taken verbatim from the production source under `js/` and `functions/api/`.

Source map (web → meaning):
- `js/app.js` — `NYM` class constructor (all instance state) + boot orchestration + NIP-46/login.
- `js/modules/*.js` — methods `Object.assign`ed onto `NYM.prototype` (relays, nostr-core, persistence, settings, pms, groups, …).
- `js/nym-crypto.js` / `js/modules/crypto-pool.js` — gift-wrap crypto + worker pool.
- `js/modules/key-vault.js` — encrypted identity key storage.
- `js/workers/*` (`js/*-worker.js`) — Web Workers (verify, format, geo-decode, highlight).
- `functions/api/*.js` — Cloudflare Pages Functions backend.

The whole app is one singleton: `nym = new NYM(); window.nym = nym;`. In Flutter this maps to a single root `AppState` (e.g. a Riverpod/Provider root or GetX controller) holding the sub-stores below.

---

## 1. Global App State (NYM instance)

All fields are initialized in the `NYM` constructor (`js/app.js` ~485–795). Grouped by subsystem with Dart-shaped models. JS `Map` → Dart `Map`, JS `Set` → Dart `Set`, lazily-built getters are noted.

### 1.1 Identity / keys

```dart
class Identity {
  String? pubkey;            // 64-hex, current active identity
  Uint8List? privkey;        // null when signing is delegated (extension / nip46)
  String? nym;               // display nickname (null until kind-0/profile resolved)
  String connectionMode = 'ephemeral';   // 'ephemeral' | (developer/persistent variants)
  String? nostrLoginMethod;  // null | 'extension'(NIP-07) | 'nsec' | 'nip46'
  String? nostrLoginPubkey;
  Uint8List? nostrLoginSecretKey;
}
```
PoW / trust:
```dart
int powDifficulty = 12;          // user-chosen
bool enablePow = false;
int nymchatPowFloor = 16;        // self-attestation floor for "is a nymchat client"
Set<String> nymchatVouches = {}; // web-of-trust observations to publish
Set<String> nymchatPubkeys = {}; // trusted nymchat-client pubkeys
Set<String> trustedPubkeys = {};
int lastVouchPublishAt = 0;
```

### 1.2 Connection / relay state

```dart
Map<String, RelayConn> relayPool = {};   // url -> {ws, status, subscriptions:Set<String>}
bool useRelayProxy;                       // = host is http(s) served (see _getApiHost)
List<PoolEntry> poolSockets = [];         // per-shard proxy sockets
PoolEntry? poolSocket;                    // legacy ref to first open socket
List<String> poolConnectedRelays = [];
Map<String,String> poolRelayTypes = {};
bool poolReady = false;
bool connected = false;
bool initialConnectionInProgress = false;

int RELAYS_PER_WORKER = 50;               // shard size when proxying
int maxRelaysForReq = 1000;
int relayTimeout = 2000;                  // ms
String appRelay = 'wss://relay.nymchat.app';

List<String> defaultRelays = [...18 urls];        // see §4.1
Set<String> writeOnlyRelays = {'wss://sendit.nosflare.com'};
Set<String> allRelayUrls;                          // union of all known
List<GeoRelay> geoRelays = [];                      // {url, lat, lng}
Map<String,Set<String>> geoRelayConnections = {};   // geohash -> relay urls
Set<String> currentGeoRelays = {};
int geoRelayCount = 5;

Set<String> blacklistedRelays = {};
Map<String,int> blacklistTimestamps = {};
int blacklistDuration = 120000;           // ms
Map<String,FailRecord> failedRelays = {};
int relayRetryDelay = 120000;             // ms
Set<String> reconnectingRelays = {};

RelayStats relayStats;                     // §4.6
```
`RelayConn`/`PoolEntry`: `{ WebSocket ws; String role; List<String> relays; List<String> dmRelays; List<String> connectedRelays; int lastMessage; }`.

### 1.3 Current view / navigation

```dart
String? currentChannel = 'nymchat';   // geohash string OR named channel; null in PM-only mode
String? currentGeohash = '';
String? currentPM;                    // peer pubkey when a PM is open
String? currentGroup;                 // group id when a group is open
bool inPMMode = false;
List<NavEntry> navigationHistory = [];
int navigationIndex = -1;
PinnedLanding pinnedLandingChannel;   // { type:'geohash', geohash:'nymchat' }
RegExp geohashRegex = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
List<String> commonGeohashes = ['nymchat','9q','w2','dr5r','9q8y','u4pr','gcpv','f2m6','xn77','tjm5'];
```

### 1.4 Messages / channels (caches)

```dart
Map<String, List<Message>> messages = {};      // channelKey -> messages (geohash keys prefixed '#')
Map<String, List<Message>> pmMessages = {};     // conversationKey -> messages
int channelMessageLimit = 1000;
int channelPageSize = 50, channelLoadMoreSize = 50;
int pmStorageLimit = 1000, pmPageSize = 50, pmLoadMoreSize = 50;
int channelDomNodeLimit = 200, pmDomNodeLimit = 200;

Map<String, Channel> channels = {};
Set<String> userJoinedChannels;     // persisted nym_user_joined_channels
Set<String> pinnedChannels;         // lazy nym_pinned_channels
Set<String> hiddenChannels;         // lazy nym_hidden_channels
Set<String> blockedChannels;        // lazy nym_blocked_channels
Set<String> discoveredGeohashes = {};
Map<String,String> channelSubscriptions = {};   // channelKey -> subId
Set<String> channelLoadedFromRelays = {};

Map<String,int> unreadCounts = {};        // persisted nym_unread_counts
Map<String,int> channelLastRead = {};     // persisted nym_channel_last_read
Map<String,int> channelLastActivity = {}; // persisted nym_channel_activity

Set<String> processedMessageEventIds = {};
Set<String> deletedEventIds = {};
Map<String,Edit> editedMessages = {};
Map<String,dynamic> pendingDeletions = {};
```

**`Message` shape** (the IndexedDB-serialised record, authoritative for the Flutter model):
```dart
class Message {
  String id;                 // event id (or nymMessageId for PM/group)
  String author;             // display nym
  String pubkey;
  String content;
  int created_at;            // seconds
  int? _originalCreatedAt;
  int? _ms;                  // sub-second ms from 'ms' tag
  int _seq;                  // local monotonic insert order
  int timestamp;
  bool isOwn, isPM, isGroup;
  String? groupId, conversationKey, conversationPubkey;
  int eventKind;             // 20000 | 23333 | 14 | 1059 | ...
  bool isHistorical;
  bool senderVerified;
  String? bitchatMessageId, nymMessageId;
  String deliveryStatus;     // 'sending'|'sent'|'delivered'|'read'|'failed'
  bool isEdited;
  String? channel, geohash;
  bool isFileOffer; Map? fileOffer;
  bool isBot, thinking;
}
```

### 1.5 PMs / groups / DM queue

```dart
Map<String, PMConv> pmConversations = {};      // pubkey -> conversation meta
Map<String, GroupConv> groupConversations = {};
Map<String, dynamic> groupEphemeralKeys = {};  // group -> ephemeral keypair history
int EPHEMERAL_PREV_KEYS_MAX = 30;
int GROUP_META_PIGGYBACK_WINDOW = 604800;      // 7d seconds
List<String> ephemeralSubIds = [];
List<String> newPMRecipients = [];
Map groupMessageReaders = {}, channelMessageReaders = {};

Map<String,PendingDM> pendingDMs = {};         // gift-wrap retry queue
int dmRetryCheckMs = 5000, dmRetryMaxAttempts = 3;
Set<String> processedPMEventIds = {};
int lastPMSyncTime = nowSec - 604800;          // 7 days back

Set<String> bitchatUsers = {};   // peers reachable via bitchat (v2:) DMs
Set<String> nymUsers = {};       // peers reachable via nym NIP-17 DMs

Set<String> closedPMs;           // lazy nym_closed_pms
Set<String> leftGroups;          // lazy nym_left_groups
Map<String,int> closedPMTimes;   // lazy nym_closed_pm_times
Map<String,int> leftGroupTimes;  // lazy nym_left_group_times
```

### 1.6 Users / presence / social

```dart
Map<String, UserProfile> users = {};   // pubkey -> profile (name, about, picture, banner, lud16, ...)
Map<String, Set<String>> channelUsers = {};
Set<String> blockedUsers;       // lazy nym_blocked
Set<String> friends;            // lazy nym_friends
Set<String> blockedKeywords;    // lazy nym_blocked_keywords

Map<String,Typing> typingUsers = {};
int typingSendInterval = 3000, typingExpireMs = 5000;
Map<String,String> awayMessages = {};
Set<String> statusHiddenUsers = {};
Set<String> friendsSharingStatus = {};
```
Supplementary profile maps (populated/hydrated alongside `users`): `userAvatars`, `userBanners`, `userBios`, `userLightningAddresses`, `_kind0Ts` (Map pubkey→kind0 timestamp), plus blob caches `avatarBlobCache` / `bannerBlobCache` (pubkey→objectURL).

### 1.7 Reactions / polls / P2P / calls

```dart
Map<String, Map<String, Map<String,String>>> reactions = {}; // msgId -> emoji -> reactor -> value
Map polls = {}, pendingPollVotes = {}; Set processedPollVoteIds = {};

// P2P / calls — kinds are instance constants:
int P2P_SIGNALING_KIND   = 25051;
int P2P_FILE_STATUS_KIND = 25052;
int CALL_SIGNALING_KIND  = 25053;
int FRIEND_PRESENCE_KIND = 25054;
int PRESENCE_KIND = 30078, POLL_KIND = 30078, POLL_VOTE_KIND = 30078;
int P2P_CHUNK_SIZE = 16384;
List<IceServer> p2pIceServers = [ stun/turn rtc.0xchat.com + google + cloudflare ]; // see §3.3
```

### 1.8 Notifications / misc

```dart
List notificationHistory; Set seenNotificationKeys;
int notificationLastReadTime;          // nym_notification_last_read
int lastSettingsSyncTs;                // nym_last_settings_sync_ts
bool notificationsEnabled = true;      // nym_notifications_enabled != 'false'
bool groupNotifyMentionsOnly = false;
bool notifyFriendsOnly = false;
String giphyApiKey = 'G6neFEExTMBM0h3hM2QjQg4vG8jMMLa9';
```

### 1.9 Settings object (`this.settings` — built by `loadSettings()`)

Authoritative shape (settings.js:1095). Each field maps to one localStorage key (see §5). Defaults shown:
```dart
class Settings {
  String theme = 'bitchat';
  String sound = 'beep';              // legacy 'icq'->'uhoh', 'msn'->'msnding'
  bool autoscroll = true;             // nym_autoscroll != 'false'
  bool showTimestamps = true;         // nym_timestamps != 'false'
  bool sortByProximity = false;
  String timeFormat = '12hr';
  String dateFormat = 'default';
  bool dmForwardSecrecyEnabled = false;
  int dmTTLSeconds = 86400;
  String readReceiptsScope = 'everywhere';   // 'everywhere'|'friends'|'disabled'
  String typingIndicatorsScope = 'everywhere';
  PinnedLanding pinnedLandingChannel = {type:'geohash', geohash:'nymchat'};
  String nickStyle = 'fancy';
  String chatLayout = 'bubbles';
  String chatViewMode = 'single';     // 'single'|'columns'
  bool columnsWallpaper = false;
  bool lowDataMode = false;
  int textSize = 15;
  bool transparencyEnabled = false;
  bool groupChatPMOnlyMode = false;
  String translateLanguage = '';
  bool gesturesEnabled = true;
  String swipeLeftAction = 'quote';
  String swipeRightAction = 'translate';
  int swipeThreshold = 60;
  String swipeReactEmoji = '❤️';
  String acceptPMs = 'enabled';
  String acceptCalls = 'enabled';
  bool cachePMs = true;               // controls PM IndexedDB persistence
  bool syncMLSHistory = true;
  dynamic showStatus = true;          // true | false | 'friends'
}
```
Image-blur is separate (`blurOthersImages`): `true | false | 'friends'`, stored per-pubkey `nym_image_blur_<pubkey>` with global fallback `nym_image_blur` (default blur = true).

---

## 2. Identity & Key Management

### 2.1 Login methods

| Method | `nostrLoginMethod` | Secret held? | Signing path |
|---|---|---|---|
| Ephemeral (default) | `null` | yes (`privkey`) | `NostrTools.finalizeEvent(event, privkey)` |
| NIP-07 extension | `'extension'` | no | `window.nostr.signEvent(unsigned)` |
| nsec paste | `'nsec'` | yes | local `finalizeEvent` |
| NIP-46 remote signer | `'nip46'` | no (remote) | `_nip46SignEvent` over relay |

`signEvent(event)` (nostr-core.js:1834) dispatches on `nostrLoginMethod`; with a local `privkey` it uses `finalizeEvent`; else extension/nip46; else throws. `generateKeypair()` = `generateSecretKey()` + `getPublicKey()`.

**Ephemeral identity** (boot, app.js ~4572): if `nym_auto_ephemeral==='true'`:
- If `nym_random_keypair_per_session==='true'` → fresh keypair + fresh random nym every session.
- Else reuse `nym_session_nsec` (nsec) if present, else generate one and save it; nick = `nym_auto_ephemeral_nick` or `generateRandomNym()`.
- Reserved/developer nick path: verify `nym_dev_nsec` via `verifyDeveloperNsec` → `applyDeveloperIdentity`.

**NIP-07** (`nostrLoginWithExtension`): `window.nostr.getPublicKey()` (must be 64-hex). Stores `nym_nostr_login_method='extension'`, `_pubkey`, `_npub`. `privkey=null`.

**nsec** (`nostrLoginWithNsec`): `decodeNsec` → `getPublicKey`. Stores method `'nsec'`, pubkey, npub, and the nsec in the vault under `nym_nostr_login_nsec`.

**NIP-46** (app.js 5077–5430): generates ephemeral client keypair + 16-hex secret; builds `nostrconnect://<clientPubkey>?relay=wss://relay.primal.net&metadata={"name":"Nymchat"}&secret=<secret>`; shows QR. Opens WS to `wss://relay.primal.net`, subscribes to **kind 24133** `#p=clientPubkey`. Inbound 24133 content is NIP-44 decrypted with `getConversationKey(clientSecretKey, event.pubkey)`. On connect → `get_public_key`. Requests (`sign_event`, `nip44_encrypt`, `nip44_decrypt`) sent as NIP-44-encrypted kind-24133 with an id, awaited via `pendingRequests`. Persists `nym_nostr_login_method='nip46'`, remote pubkey (`nym_nip46_remote_pubkey`), relay (`nym_nip46_relay`), and client secret (hex) in the vault under `nym_nip46_client_secret`. Session restored on boot via `_nip46RestoreSession()`.

### 2.2 Key Vault (encryption at rest of identity secrets) — key-vault.js

Protects only the four identity secrets (NOT the message cache):
```
_VAULT_KEYS = ['nym_session_nsec','nym_dev_nsec','nym_nostr_login_nsec','nym_nip46_client_secret']
```
Indirection: `nymSecretGet/Set/Remove(name)` → `nym.secretGet/secretSet/secretRemove`, falling back to plain localStorage when no vault.

**Encrypted blob format**: `enc:v1:<base64(iv)>:<base64(ciphertext)>` — AES-GCM, 256-bit key, **12-byte random IV**.

**Passphrase/PIN derivation** (`_deriveKeyFromPassword`): **PBKDF2**, **iterations 310000**, **SHA-256**, salt = stored 16 random bytes → AES-GCM-256 (non-extractable). PIN is treated as a password (method persisted as `'password'`).

**WebAuthn PRF derivation** (`_webauthnDeriveKey`): `navigator.credentials.get` with `extensions:{prf:{eval:{first: salt}}}`, `userVerification:'required'`. PRF output → HKDF base key → `deriveKey({name:'HKDF', salt: Uint8Array(0), info: utf8('nym-vault'), hash:'SHA-256'})` → AES-GCM-256.

**WebAuthn enroll** (`_webauthnEnroll`): `navigator.credentials.create`, 32-byte challenge, `rp:{name:'Nymchat', id: location.hostname}`, `pubKeyCredParams:[{alg:-7},{alg:-257}]`, `authenticatorSelection:{userVerification:'required', residentKey:'required'}` (+ `authenticatorAttachment:'platform'` when biometric), `extensions:{prf:{}}`. Credential rawId stored base64.

**Vault localStorage keys**:
| Key | Value |
|---|---|
| `nym_vault_enabled` | `'1'` |
| `nym_vault_method` | `'password'` \| `'biometric'` \| `'passkey'` |
| `nym_vault_salt` | base64(16 random bytes) (PBKDF2 salt + PRF eval input) |
| `nym_vault_cred` | base64 WebAuthn rawId (WebAuthn only) |
| `nym_vault_check` | `_vaultEncrypt('nymchat-vault-ok')` verification token |
| `nym_encrypt_at_rest_pref` | `'1'` (cross-device synced preference, no key material) |
| `nym_encrypt_at_rest_prompt_dismissed` | `'1'` |

In-memory only: `_vaultKey` (CryptoKey; presence = unlocked) and `_vaultMem` (Map name→plaintext). `unlockVaultAtBoot()` runs in `DOMContentLoaded` *before* `initialize()`. `unlockVault` verifies against `nym_vault_check` decrypting to `'nymchat-vault-ok'` before populating `_vaultMem`. `resetVault()` discards encrypted secrets; `_forgetIdentityAndReload()` wipes login pointers and reloads.

**Flutter mapping**: use `flutter_secure_storage` (Keychain/Keystore) for the four secrets; replicate the PBKDF2(310000,SHA-256)/AES-GCM scheme only if cross-device password unlock parity is required. WebAuthn PRF maps to platform biometric + a derived key; otherwise rely on OS secure storage.

---

## 3. Nostr Core

### 3.1 Event kinds (complete table)

| Kind | Name / usage |
|---|---|
| **0** | Profile metadata (NIP-01). name/display_name/about/picture/banner/lud16/lud06. Mirrored to D1. |
| **5** | Deletion (NIP-09). tags `['e',id]`,`['k',origKind]`. Author-only; for NIP-17 DMs deletes underlying 1059 wraps. |
| **7** | Reaction (NIP-25). `['e',msgId]`; un-react adds `['action','remove']`. |
| **13** | Seal (NIP-59) — inner sealed layer inside a gift wrap. |
| **14** | DM rumor (NIP-17). Used as bitchat receipt rumor kind. |
| **1059** | Gift wrap (NIP-59). Inbound DMs/group msgs; `['p',recipient]`, ephemeral pubkey. |
| **10000** | Mute list (NIP-51). `['p',pk]` muted users, `['word',kw]` muted keywords. |
| **10030** | User emoji list (NIP-30). |
| **20000** | Ephemeral geohash channel message (bitchat-compatible). channel in `['g',geohash]`. |
| **23333** | Ephemeral named channel message (Nymchat). channel in `['d',name]`. |
| **24133** | NIP-46 remote-signer transport (client↔signer). |
| **24420** | Channel typing indicator (ephemeral, Nymchat). |
| **24421** | Channel read receipt (ephemeral, Nymchat). |
| **25051** | P2P WebRTC signaling (SDP/ICE). `P2P_SIGNALING_KIND`. |
| **25052** | P2P file status (unseeded notifications). `P2P_FILE_STATUS_KIND`. |
| **25053** | Call signaling. `CALL_SIGNALING_KIND`. |
| **25054** | Friend presence (private, gift-wrapped) rumor kind. `FRIEND_PRESENCE_KIND`. |
| **27235** | NIP-98 HTTP auth event (sent as `body.auth` to backend). |
| **30030** | Custom emoji pack (NIP-30, parameterized replaceable). |
| **30078** | App data (NIP-78). Multiplexed by `['t',...]`: `nym-presence`, `nym-poll`, `nym-poll-vote`, `nym-vouches`, `nym-settings-transfer-*`. Also `PRESENCE_KIND`/`POLL_KIND`/`POLL_VOTE_KIND`. |
| **9734 / 9735** | Zap request / Zap receipt (NIP-57). |
| **69420** | Nymchat rumor kind for typing indicators & receipts inside gift wraps (kept off 14 so blank receipts don't render as DMs in other clients). |

bitchat TLV type bytes (inside `bitchat1:` payloads, NOT Nostr kinds): `0x01` PRIVATE_MESSAGE, `0x02` READ_RECEIPT, `0x03` DELIVERED; packet header `0x11` NOISE_ENCRYPTED.

### 3.2 Tag conventions

| Tag | Meaning |
|---|---|
| `['n', nym]` | sender display nickname (channel msgs, typing, receipts, presence). bitchat suffix stripped via `stripPubkeySuffix`. |
| `['g', geohash]` | geohash channel id (kind 20000). |
| `['d', name]` | named-channel id (kind 23333) / replaceable `d` identifier on 30078. |
| `['t', topic]` | type discriminator on 30078. |
| `['p', pubkey]` | recipient (1059), muted pk (10000), author (receipts). |
| `['e', id]` | referenced event (7, 5, 24421). |
| `['k', kind]` | original kind on deletion (5). |
| `['ms', millis]` | sub-second ms timestamp on channel messages. |
| `['nonce', n, difficulty]` | NIP-13 PoW. |
| `['nymquote', author, fullText]` | NYM quote-reply reconstruction. |
| `['edit', originalId]` | channel message edit marker. |
| `['typing', 'start'|'stop']` | typing status (24420 / 69420). |
| `['receipt','delivered'|'read']` + `['x', msgId]` | Nymchat receipt rumor (69420); `x` marks a nym message id. |
| `['status',..]`,`['away',msg]`,`['avatar-update',url]`,`['shop-update','1']` | presence sub-fields (30078 / 25054). `status='hidden'` when visibility limited. |
| `['word', kw]` | muted keyword (10000). |
| `['action','remove']` | reaction removal (7). |
| `['expiration', ts]` | NIP-40 expiry (plumbed into gift wraps). |
| `['action',...]`,`['method','POST']`,`['u',url]`,`['payload',sha256]` | NIP-98 request-binding tags on kind 27235 auth events. |

### 3.3 Encryption / gift wrap (nym-crypto.js)

Two DM transports, both producing a kind-1059 gift wrap:

**NIP-44 / NIP-59 (`nip59Wrap`)** — standard:
1. rumor = inner event (e.g. kind 14/69420), `pubkey` = real sender, hashed id.
2. seal = kind 13, content = `nip44.encrypt(rumor, getConversationKey(senderSk, recipientPub))`, signed by sender, `created_at = randomNow()`.
3. wrap = kind 1059, ephemeral key `ephSk`, content = `nip44.encrypt(seal, getConversationKey(ephSk, recipientPub))`, `tags=[['p',recipientPub]]`, optional `['expiration',ts]`, `created_at = randomNow()`.

**Bitchat (`bitchatWrap` / `encryptBitchat`)** — interop with Bitchat clients:
- `encryptBitchat`: shared point = `secp256k1.getSharedSecret(sk,'02'+recipientPub)`; `prk = hkdfExtract(sha256, sharedPoint, emptySalt)`; `key = hkdfExpand(prk, utf8('nip44-v2'), 32)`; `XChaCha20-Poly1305` with 24-byte random nonce; output `v2:<base64url(nonce||ct)>`.
- `bitchatWrap`: seal kind 13 + wrap kind 1059, both content via `encryptBitchat`.

**`randomNow()`**: CSPRNG-jittered timestamp `Date.now()/1000 − rand·7200` → **±2h backdating** for NIP-59 metadata protection.

**Conversation keys**: `nip44.getConversationKey(sk, pub)`, cached per-self in a `convKey(sk,pubkey,selfId)` LRU (cap 1000).

**Unwrap (`unwrapGiftWrap(event, candidates)`)**: candidates `[{sk, bitchat, selfId?}]`; tries bitchat (`v2:`) then NIP-44; returns `{seal, rumor, isBitchat, idx}` or null. Inbound 1059 → `_enqueueGiftWrapDM` → `_cryptoCall('unwrapGiftWrap', …)` (worker).

**PoW (NIP-13)**: `minePow(event, difficulty)` sets `['nonce',n,difficulty]`, re-hashes until `nip13.getPow(id) >= difficulty`. `validatePow`, `_effectivePowDifficulty()` = `max(userPow, nymchatPowFloor)`. Inbound PoW ≥ floor = self-attestation → `_markNymchatPubkey`.

P2P ICE servers:
```
stun:rtc.0xchat.com:5349
turn:rtc.0xchat.com:5349 (user '0xchat', cred 'Prettyvs511')
stun:stun.l.google.com:19302 / stun1 / stun2
stun:stun.cloudflare.com:3478
```

### 3.4 Key nostr-core methods

`handleEvent` (central inbound dispatcher by kind), `signEvent`, `generateKeypair`, `publishMessage` / `publishMessagePseudonymous` (channel send; pseudonymous = fresh ephemeral key per message), `publishDeletionEvent` / `handleDeletionEvent`, `saveToNostrProfile` (kind 0 + D1 mirror), `fetchProfileDirect` / `queueProfileFetch` / `_fetchProfilesFromD1` (D1-first batched kind-0), `publishPresence` / `recordOwnActivity` / `_sendFriendPresence`, typing (`handleTypingSignal`/`sendChannelTypingStop`/…), receipts (`sendNymReceipt`/`sendBitchatReceipt`/`sendChannelReadReceipt`), web-of-trust (`publishNymchatVouches`/`handleVouchEvent`/`_observeNymchatPubkey`), spam (`isSpamMessage`/`handleMuteList`), `nip59WrapEventAsync`/`bitchatWrapEventAsync`.

Signature verification is centralized in relays.js (`_verifyRelayEventAsync` → `/js/verify-worker.js` pool, sync `verifyEvent` fallback).

---

## 4. Relay Layer

### 4.1 Default relays (always connected first)
```
wss://sendit.nosflare.com        (also the write-only publish relay)
wss://relay.nymchat.app          (appRelay)
wss://relay.damus.io
wss://offchain.pub
wss://relay.primal.net
wss://nos.lol
wss://nostr21.com
wss://relay.coinos.io
wss://relay.snort.social
wss://relay.nostr.net
wss://nostr-pub.wellorder.net
wss://relay1.nostrchat.io
wss://nostr-01.yakihonne.com
wss://nostr-02.yakihonne.com
wss://relay.0xchat.com
wss://relay.satlantis.io
wss://relay.fountain.fm
wss://nostr.mom
```

### 4.2 Proxy decision & URLs
- `useRelayProxy = !!_getApiHost()`; `_getApiHost()` returns `location.host` only on http(s) (web-served), else null → direct WS.
- Pool: `wss://<host>/api/relay-pool` (multiplexed, one socket per shard).
- Single-relay proxy: `wss://<host>/api/relay?relay=<encoded wss url>`.
- HTTP proxy base: `https://<host>/api/proxy` (geocode/giphy/geo-relays/translate/unfurl/upload/json/zap-verify).

**Flutter note**: a native app sends `User-Agent: NymchatApp/…` or `NYMApp`, which satisfies the backend `isNymchatClient` guard without a same-origin Origin header. `_getApiHost()` (which keys off `https:` page serving) does not apply natively — the Flutter app should target a fixed API host (e.g. `web.nymchat.app`) and always use the pool proxy, OR connect to relays directly.

### 4.3 Sharding (proxy mode)
`_shardRelaysByRole(allRelays, geoRelayUrls, dmRelays)` buckets relays into roles, each chunked by `RELAYS_PER_WORKER`(50):
- `critical-*` = defaultRelays + dmRelays (minus appRelay)
- `geo-*` = geo CSV relays
- `discovered-*` = everything else
- `app-0` = always `[wss://relay.nymchat.app]`

Shard ids are stable (role+index). Hardcoded `blocked` relays + `_permanentBlacklist` excluded.

### 4.4 Connection lifecycle
- `connectToRelays()` — entry. Pool mode → `_connectToRelayPool()` (≤2 retries, exp backoff+jitter); on total failure sets `useRelayProxy=false`, `_poolFallbackActive=true`, keeps retrying pool in background while running direct. On success: `connected=true`, `_startPoolShardHealthCheck()` (15s), `_poolSubscribe()`, drain `messageQueue`, navigate to landing channel.
- `_connectSinglePoolWorker(shard)` — opens `wss://host/api/relay-pool`; 12s connect timeout; `onopen` → `["RELAYS",{relays,dmRelays}]` (+ `["KIND_BLACKLIST",…]`); routes Nostr frames to `handleRelayMessage`.
- Reconnect: `_schedulePoolReconnect()` (2s debounce, `min(3000·2^retries,30000)`×jitter, 2 fails → fall to direct), `_reconnectPoolShard` (`min(3000·1.7^retries,60000)`), `_ensureAllShardsConnected()` (zombie = open w/ 0 relays for 45s). Direct: `ws.onclose` exp `1.5^attempt`, max 10 (∞ for appRelay). App-relay watchdog every 15s.
- Blacklist: `blacklistDuration=120000ms`; `shouldRetryRelay` cooldown `min(5min·2^(fails-3),6h)` after ≥3 fails; `_permanentlyBlacklistRelay` (10-year, never appRelay/defaults).

### 4.5 Subscriptions & publishing
- Master filter built by `_buildCriticalFilters(since)` — kinds 1059(#p self), 20000/23333, 7, 5, 9735/9734, 25051/25052, 30078(#t presence/poll/vouches), 30030/10030, 0. When D1 available, `since=now`, `limit=1` (history from D1).
- `_poolSubscribe()` → `["REQ", subId, ...filters]` to every pool socket; subId = `Math.random().toString(36).slice(2)`. Tracking: `channelSubscriptions`, `_channelTypingSubs`, `_ephemeralSubIds`, `_lastPoolSubId`, `_backfillSubs` (auto-CLOSE ~300ms post-EOSE / 4s timeout), `_eoseWaiters`.
- Channel typing sub: `[{kinds:[24420,24421], #g|#d:[key], since}]` for current channel only (20000/23333 are ephemeral so no per-channel backfill).
- Ephemeral (group) sub: `[{kinds:[1059], "#p": ephPks}]`.
- `sendToRelay(msg)` routes EVENT→`broadcastEvent`, REQ→`sendRequestToAllRelays`. `broadcastEvent`: pool mode — kind-20000 w/ `g` → `["GEO_EVENT", evt, [closestGeoUrls]]`, else `["EVENT", evt]`. DM → `["DM_EVENT", evt]` (DM relays prioritized). Write-only relays (`sendit.nosflare.com`) skipped in REQ, always receive EVENTs. `OK` with `accepted:false` → kind-blacklist / rate-limit / error classification.

### 4.6 relay-pool wire protocol (client ↔ `/api/relay-pool`)

Wrapped/multiplexed JSON frames (NOT raw per-relay nostr):

Client → proxy:
```
["RELAYS", { relays, dmRelays }]            // or legacy {critical, geo, dmRelays}
["EVENT", eventObj]
["GEO_EVENT", eventObj, ["wss://geo1", …]]
["DM_EVENT", eventObj]
["REQ", subId, ...filters]
["CLOSE", subId]
["KIND_BLACKLIST", { "wss://relay":[kind,…] }]
["ROLE", role, innerMsg]                    // optional role routing
```
Proxy → client (note the extra relay-attribution arg vs raw nostr):
```
["EVENT", subId, eventObj]                  // deduped across upstreams
["OK", id, bool, msg]
["EOSE", subId]
["NOTICE", reason, relayUrl]
["CLOSED", subId, reason, relayUrl]
["POOL:STATUS", { connected, count, latency, events }]
["POOL:PING", ts]                           // keepalive ~30s
["POOL:RELAY_BAN", relayUrl, reason]
["POOL:SHARDS", [...]]
```
Single-relay `/api/relay?relay=…` passes raw nostr frames through verbatim.

### 4.7 Geo relays & stats
- `fetchGeoRelays()`: proxy `?action=geo-relays` JSON, else bitchat CSV (`raw.githubusercontent.com/permissionlesstech/georelays/.../nostr_relays.csv`). `geoRelays=[{url,lat,lng}]`.
- `getClosestRelaysForGeohash(geohash, count=5)`: decode geohash, haversine to each, pick closest.
- `relayStats`: `eventsPerRelay`, `bytesReceived`, `bytesSent`, `latencyPerRelay`, `totalEvents`, `eventsThisSecond`, `throughputHistory`, `startTime`, `shardInfo`, `kindStatsPerRelay`. Failure history persisted in `localStorage['nym_relay_stats']` (≤200 entries).

---

## 5. Persistence

### 5.1 IndexedDB (`nym-cache`, version 2) — persistence.js

Stores (`STORES`), **no secondary indexes**, every record stamped `lastTouched`:
| Store | keyPath | Record |
|---|---|---|
| `meta` | `key` | `{key, ids:[...]}` or `{key, map:{...}}` |
| `profiles` | `pubkey` | `{pubkey, profile:{...,pictureUrl,bannerUrl,bio,lnAddress,kind0Ts}, lastTouched}` |
| `channels` | `key` | `{key, messages:[serialisedMessage], lastTouched}` (last `channelMessageLimit||100`) |
| `pms` | `key` | `{key, messages:[serialisedMessage], lastTouched}` (last `pmStorageLimit||500`; only if `settings.cachePMs`) |
| `reactions` | `messageId` | `{messageId, entries:[[emoji,[[reactor,value]]]], lastTouched}` |
| `avatars` | `pubkey` | `{pubkey, blob:Blob, sourceUrl, kind0Ts, lastTouched}` |
| `banners` | `pubkey` | same as avatars |

`meta` keys: `processedPMEventIds`, `deletedEventIds`, `nymchatPubkeys`, `nymchatVouches`, `trustedPubkeys` (≤20000), `poolShardLastSeen`.

LRU limits (`STORE_LIMITS`): profiles 2000, channels 50, pms 100, reactions 5000, avatars 500, banners 200; evict to 90% when over; trim debounced 30s. **No time expiry.**

Debounce: profiles/avatars/banners/reactions 1500ms; messages 6000ms; dedup/pool 5000ms. Flush wired to `pagehide`/`beforeunload`/`visibilitychange(hidden)`/`freeze`/`blur`.

`hydrateFromCache()` (boot, raced against 1500ms): loads all stores in parallel → repopulates `users`, avatar/banner objectURL caches, `messages`, `pmMessages` (if allowed), `reactions`, dedup sets; rebuilds `nymUsers`/`bitchatUsers`; `channelLastActivity`; then `_populateSidebarFromHydration()`.

**Message cache is NOT encrypted at rest.** Only privacy control = `settings.cachePMs` (skip PM persistence). `nym_encrypt_at_rest_pref` governs the identity key vault only (§2.2).

### 5.2 localStorage keys (complete enumeration)

`sessionStorage` is NOT used anywhere.

Identity / login / vault:
```
nym_nostr_login_method, nym_nostr_login_pubkey, nym_nostr_login_npub,
nym_nostr_login_profile, nym_nip46_remote_pubkey, nym_nip46_relay,
nym_auto_ephemeral, nym_auto_ephemeral_nick, nym_auto_ephemeral_channel,
nym_random_keypair_per_session, nym_keypair_mode, nym_connection_mode(legacy, cleared),
nym_nsec(legacy, cleared), nym_bunker_uri(legacy), nym_relay_url(legacy),
nym_vault_enabled, nym_vault_method, nym_vault_salt, nym_vault_cred, nym_vault_check,
nym_encrypt_at_rest_pref, nym_encrypt_at_rest_prompt_dismissed
```
Vault-encrypted (values, via nymSecretSet): `nym_session_nsec, nym_dev_nsec, nym_nostr_login_nsec, nym_nip46_client_secret`.

Settings (one per Settings field):
```
nym_theme, nym_color_mode, nym_sound, nym_autoscroll, nym_timestamps,
nym_time_format, nym_date_format, nym_sort_proximity, nym_text_size,
nym_transparency_enabled, nym_chat_layout, nym_chat_view_mode, nym_columns_layout,
nym_columns_wallpaper, nym_wallpaper_type, nym_wallpaper_custom_url, nym_low_data_mode,
nym_groupchat_pm_only_mode, nym_nick_style, nym_pinned_landing_channel,
nym_dm_fwdsec_enabled, nym_dm_ttl_seconds, nym_read_receipts_scope,
nym_read_receipts_enabled, nym_typing_indicators_scope, nym_typing_indicators_enabled,
nym_accept_pms, nym_accept_calls, nym_cache_pms, nym_sync_mls_history, nym_show_status,
nym_gestures_enabled, nym_swipe_left_action, nym_swipe_right_action, nym_swipe_threshold,
nym_swipe_react_emoji, nym_translate_language, nym_translate_favorites,
nym_pow_difficulty, nym_hide_non_pinned, nym_image_blur, nym_image_blur_<pubkey>
```
Profile / wallet:
```
nym_bio, nym_avatar_url, nym_banner_url,
nym_lightning_address_global, nym_lightning_address, nym_lightning_address_<pubkey>,
nym_custom_nick
```
Channels / lists:
```
nym_pinned_channels, nym_hidden_channels, nym_blocked_channels,
nym_user_joined_channels, nym_user_channels,
nym_unread_counts, nym_channel_activity, nym_channel_last_read
```
Social / blocks:
```
nym_blocked, nym_friends, nym_blocked_keywords
```
PMs / groups:
```
nym_closed_pms, nym_closed_pm_times, nym_left_group_times,
nym_last_pm_sync_<pubkey>, nym_pending_group_invite
```
Notifications / sync:
```
nym_notifications_enabled, nym_group_notify_mentions_only, nym_notify_friends_only,
nym_notification_last_read, nym_last_settings_sync_ts
```
Emoji / gifs:
```
nym_emoji_pack_favorites, nym_emoji_category_favorites, nym_recent_emojis, nym_favorite_gifs
```
Bot / shop:
```
nym_botpm_welcomed, nym_botpm_cleared_at, nym_botpm_pro_model, nym_botpm_git,
nym_purchases_cache, nym_active_style, nym_active_flair
```
Misc:
```
nym_tutorial_seen, nym_dismissed_transfers, nym_relay_stats
```
(~110 distinct keys; per-pubkey variants `nym_lightning_address_<pk>`, `nym_image_blur_<pk>`, `nym_last_pm_sync_<pk>` are dynamic.)

---

## 6. Backend API (Cloudflare Pages Functions)

Routing = file path under `/functions/api`. No R2/KV; persistence is Cloudflare **D1** + a **`NymLedger` Durable Object** + edge cache. Guards: `isNymchatClient` (same-origin Origin OR UA `NymchatApp/`|`NYMApp`) on relay/storage/bot; NIP-98 signed auth (kind 27235) on mutating storage/bot actions.

| Method | Path | Purpose | Request | Response |
|---|---|---|---|---|
| GET (WS) | `/api/relay?relay=<wss>` | single-relay privacy proxy (SSRF-guarded) | WS upgrade | raw nostr frames |
| GET (WS) | `/api/relay-pool` | multiplexed pool proxy + D1 channel archiving | WS upgrade; `["RELAYS",…]` in-band | framed protocol (§4.6) |
| GET | `/api/proxy?url=<u>[&emoji=1]` | media/image proxy (Range, 100MB cap) | `url`, optional `Range` | media bytes |
| POST | `/api/proxy?action=translate` | Google translate | `{text,source?,target}` | `{translatedText,detectedLanguage}` |
| GET | `/api/proxy?action=unfurl&url=` | OpenGraph link preview (1h cache) | `url` | `{url,title,description,image,siteName,type,favicon}` |
| PUT/POST | `/api/proxy?action=upload&server=` | Blossom blob upload | binary + `Authorization: Nostr …` | Blossom JSON |
| PUT/POST | `/api/proxy?action=mirror&server=` | Blossom mirror | `{url}` + `Authorization: Nostr …` | Blossom JSON |
| GET | `/api/proxy?action=geo-relays` | geo relay CSV→JSON (300s cache) | — | `{relays:[{url,lat,lng}]}` |
| GET | `/api/proxy?action=geocode&lat&lng` | Nominatim reverse geocode (1d cache) | `lat,lng,zoom?,lang?` | Nominatim JSON |
| GET | `/api/proxy?action=giphy&api_key&q\|trending` | Giphy search/trending | `api_key`,`q`/`trending` | Giphy JSON |
| GET/POST | `/api/proxy?action=json&url=` | generic JSON proxy (LNURL/NIP-11, 512KB) | `url` | upstream JSON |
| POST | `/api/proxy?action=zap-verify` | confirm zap paid | `{pr,providerPubkey,receipt?,verifyUrl?}` | `{paid}` |
| POST | `/api/storage` (`settings-get/set`) | encrypted settings blobs (`DB_SETTINGS`) | `{action,pubkey,category?,blob?,auth}` | `{settings}` / `{ok}` |
| POST | `/api/storage` (`profile-get/set`) | kind-0 events (`DB_PROFILES`) | `{action,pubkeys?\|event,auth?}` | `{profiles}` / `{ok}` |
| POST | `/api/storage` (`pm-get/put/deposit/delete`) | gift-wrapped DM inbox (`DB_PM`) | `{action,pubkey\|event\|ids,auth}` | `{events}` / `{ok}` |
| POST | `/api/storage` (`channel-get/activity/active/delete`) | archived channel events (`DB_CHANNELS`) | `{action,channel/filters/event}` | `{events}`/`{activity}`/`{ok}` |
| POST | `/api/storage` (`emoji-get`) | NIP-30 packs (30030/10030) | `{action,pubkey?}` | `{events}` |
| POST | `/api/storage` (`zap-get/put`) | zap receipts (9735) | `{action,ids,scope\|events}` | `{zaps}`/`{ok}` |
| POST | `/api/storage` (`shop-*`) | cosmetics economy (`DB_SHOP`/Ledger) | `{action,pubkey,itemId?,active?,code?,auth}` | owned/active/invoice/claim |
| POST | `/api/bot` (`command`) | public @Nymbot slash commands (Workers AI/Anthropic), rate-limited | `{command,args?,geohash?,conversation?,…}` | `{response}` |
| POST | `/api/bot` (`action`) | private paid bot chat + credits (`DB_CREDITS`/`DB_BOT`) | `{action,pubkey,auth,…}` | balances/invoice/DM |
| OPTIONS | any | CORS preflight | — | 204 |

D1 bindings: `DB_SETTINGS, DB_PROFILES, DB_PM, DB_CHANNELS, DB_SHOP, DB_CREDITS, DB_INVOICES, DB_CODES, DB_BOT`. Durable Object: `NYM_LEDGER` (class `NymLedger`, single `idFromName("global-v1")`; serializes money mutations; SQLite tables `replay, claims, edition_minted, edition_resv`). AI: `AI` + AI Gateway vars + `ANTHROPIC_API_KEY`. Secrets: `BOT_PRIVKEY, BOT_NWC_URI, BOT_LIGHTNING_ADDRESS, NYMCHAT_PROXY_SECRET`.

**NIP-98 auth (`verifyClientAuth`)**: `body.auth` = signed event, `kind===27235`, `pubkey===user`, `created_at` within ±120s, valid id + Schnorr sig, tags `['action',a]`,`['method','POST']`,`['u',exactUrl]`,`['payload', sha256(JSON.stringify(canonicalAuthBody(body)))]` (canonical = drop `auth`, sort keys). Single-use via Ledger `replay` (TTL ~130s); reuse → 401.

---

## 7. Init / Boot Flow

`js/setup-modal-init.js` (before paint): show setup modal iff `nym_nostr_login_method===null && nym_auto_ephemeral!=='true'`. `js/theme-init.js` applies `nym_color_mode`/`nym_transparency_enabled`/`nym_chat_view_mode` pre-paint.

On `DOMContentLoaded` (app.js ~6784):
1. `nym = new NYM()` (runs full constructor / state init §1; lazy getters defer localStorage reads). `window.nym = nym`. `installNativeWalletBridgeCompat`.
2. Scroll/scrollbar listeners.
3. `await nym.unlockVaultAtBoot()` — if vault enabled+locked, prompt loop to decrypt the 4 secrets into `_vaultMem` BEFORE any identity read.
4. `parseUrlChannel()`; `updateSetupInviteBanner()`.
5. `await nym.initialize()` (init.js): require `window.NostrTools`; `_ensureCryptoPool()` (warm workers); wire event listeners/commands/context-menu/gestures/translate/sidebar/panic gesture; load prefs (color mode, blocked users, friends, blocked keywords, pinned/hidden channels, wallpaper, unread counts); `applyMessageLayout`; render column skeletons if columns mode; `await Promise.race([hydrateFromCache(), 1500ms])`; `loadLightningAddress()`; `cleanupOldLightningAddress`; `setupNetworkMonitoring`/`setupVisibilityMonitoring`; 8s sidebar-skeleton cleanup timer.
6. `startRelayStatsSampling()`.
7. Apply `groupChatPMOnlyMode` (hide channels section).
8. `checkSavedConnection()` chooses identity:
   - If `isNostrLoggedIn()` (method!==null): set method early; for nsec decode secret; for extension wait ≤10×300ms for `window.nostr`; for nip46 `_nip46RestoreSession()`; `generateKeypair()` then override `pubkey`(+`privkey` if nsec/null for extension); apply cached `nym_nostr_login_profile`; `connectToRelays()`; `applyCachedShopItemsToNewIdentity()`; `applyNostrLogin()`; onboarding; resume saved channel / route URL.
   - Else if `nym_auto_ephemeral==='true'`: ephemeral/persistent/developer identity (§2.1); `connectToRelays()`; load group convs / ephemeral keys / lastPMSync / left-groups; `settingsLoad()`.
   - Else: setup modal stays open.
9. `preConnect()` (direct mode only); focus nym input; timestamp listeners; geolocation if `sortByProximity`.

---

## 8. Crypto Pool / Workers

**Crypto pool** (crypto-pool.js): `_ensureCryptoPool()` builds `min(hardwareConcurrency, 4)` blob Web Workers that `importScripts(nostr-tools.js, nym-crypto.js)` and expose `NymCrypto` methods over a `{id, op, args}` RPC. `_cryptoCall(op, args, fallback)` dispatches to the least-busy worker; 20s timeout → main-thread fallback (no timeout for `minePow`). Ops: `nip59Wrap`, `bitchatWrap`, `unwrapGiftWrap`, `minePow`, `encryptBitchat`, `randomNow`.

Web Workers (`js/*-worker.js`):
| Worker | importScripts | Message in → out | Purpose |
|---|---|---|---|
| `verify-worker.js` | `nostr-tools.js` | `{seq,event}` → `{seq, ok}` | `NostrTools.verifyEvent(event)` off-thread (pool ≤4). |
| `format-worker.js` | `syntax-highlight.js`, `message-format.js` | `{op:'init',emojiMap}` / `{ctx, items}` → `{seq, results:[{key,html}]}` | render message content (quotes, emoji, code) off-thread via `NymFormat.formatWithQuotes`. |
| `highlight-worker.js` | `syntax-highlight.js` | `{seq, code, lang}` → `{seq, html}` | syntax-highlight fenced code blocks. |
| `geo-decode-worker.js` | `geo-decode.js` | `{seq, url, kind}` → `{seq, features}` | fetch + decode geohash-globe map GeoJSON via `NymGeoDecode.decodeByKind`. |

**Flutter mapping**: crypto/verify/format/highlight workers → `Isolate`s (or `compute`); geo-decode → an isolate doing the HTTP fetch + decode. Worker dispatcher RPC → a simple isolate message protocol.

Integrity helpers (not workers): `js/modules/build-verify.js` (`window.verifyRunningBuild` — re-hashes served bundle vs `/build-manifest.json`, anchors via GitHub attestations for `Spl0itable/NYM`, official host `web.nymchat.app`) and `js/modules/canary-verify.js` (`window.checkWarrantCanary` — fetches `raw.githubusercontent.com/Spl0itable/NYM/main/canary.json`, verifies signature against pubkey `d49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df`). These are About-dialog trust features; low priority for a native port.
