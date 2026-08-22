# 03 — Messaging Subsystems

Implementation-grade specification of the Nymchat messaging subsystems for a 1:1 native
Flutter reimplementation. Covers channels, channel messages, private messages (NIP-17),
group chats (NIP-17/NIP-59 multi-member), reactions, polls, commands, autocomplete,
message formatting, read receipts/typing, disappearing messages, blocking and keyword
filtering.

Source modules (all under `/home/user/nym-staging/js/`):

| Module | Path | Responsibility |
|--------|------|----------------|
| Channels | `js/modules/channels.js` | Channel registry, join/leave, list sort, favorites, sharing, geohash |
| Channel messages | `js/modules/messages.js` | Channel message model, send/receive, dedup, ordering, flood, rendering |
| Publish/core | `js/modules/nostr-core.js` | `publishMessage`, presence, `randomNow`, receipts, gift-wrap helpers |
| Private messages | `js/modules/pms.js` | NIP-17 1:1 PMs, gift wrap send/receive, conversation model, receipts |
| Groups | `js/modules/groups.js` | Multi-member NIP-59, ephemeral key rotation, roles, moderation, invites |
| Reactions | `js/modules/reactions.js` | Kind 7 reactions, custom emoji, reactor lists, picker |
| Polls | `js/modules/polls.js` | Poll create/vote/render (kind 30078) |
| Commands | `js/modules/commands.js` | Slash command parser + handlers |
| Autocomplete | `js/modules/autocomplete.js` | `@` `#` `:` `\` autocompletes |
| Formatting | `js/modules/message-format.js`, `js/format-worker.js` | Pure content→HTML formatter (shared with worker) |
| Users | `js/modules/users.js` | User/profile model, presence, blocking, keyword filter, friends |

> **Authoritative-kind note.** Channel messages are kinds **20000** (geohash) / **23333**
> (named). PMs/groups use NIP-17 **kind 14** rumor → **kind 13** seal → **kind 1059** gift
> wrap (verified directly in `nostr-core.js` and `pms.js`). Receipts/typing use rumor
> **kind 69420**. Reactions are **kind 7**; deletions **kind 5**; zaps **kind 9735**;
> presence/poll state **kind 30078**.

---

## 1. Channels

### 1.1 Channel types

| Aspect | Geohash channel | Named channel |
|--------|-----------------|---------------|
| Event kind | **20000** | **23333** |
| Identifier tag | `['g', geohash]` | `['d', channelName]` |
| Validation | `isValidGeohash(str)` → `/^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/` on lowercase | non-geohash; sanitize to `/^[\p{L}\p{N}]+$/u` |
| Storage key | `#<geohash>` (e.g. `#u10h8`) | `#<name>` (e.g. `#nymchat`) |
| Model field | `geohash` set | `geohash` empty, `channel` set |
| Default channel | — | `nymchat` (cannot be left/blocked) |

`channelWire(channelKey)` (`channels.js:454`) returns `{ isGeohash, kind: 20000|23333, tag: 'g'|'d' }`.
The kind/tag decision for both channel-message send and reactions is driven by `isValidGeohash`.

### 1.2 Channel data model

`this.channels: Map<key, ChannelEntry>` where key = geohash or name (lowercase):

| Field | Type | Meaning |
|-------|------|---------|
| `channel` | String | Channel name (always present) |
| `geohash` | String | Geohash if geohash channel; `''` for named |

Companion state maps (all keyed by channel key):

| Map / Set | Type | Meaning | localStorage key |
|-----------|------|---------|------------------|
| `userJoinedChannels` | `Set<String>` | Channels the user explicitly joined | `nym_user_joined_channels` |
| `pinnedChannels` | `Set<String>` | Favorited channels | `nym_pinned_channels` |
| `hiddenChannels` | `Set<String>` | Hidden from sidebar | `nym_hidden_channels` |
| `blockedChannels` | `Set<String>` | Blocked from discovery | `nym_blocked_channels` |
| `unreadCounts` | `Map<String,int>` | Unread message count | `nym_unread_counts` |
| `channelLastActivity` | `Map<String,int>` (ms) | Last activity timestamp (sort) | `nym_channel_activity` |
| `channelLastRead` | `Map<String,int>` (sec) | Last read time per channel | `nym_channel_last_read` |
| (joined snapshot) | JSON `[{key,channel,geohash}]` | Persisted channel registry | `nym_user_channels` |

Messages are stored separately in `this.messages: Map<"#<key>", Message[]>` (always `#`-prefixed).

### 1.3 Join / leave flow

| Function (`channels.js`) | Effect |
|--------------------------|--------|
| `handleChannelLink(input, event)` | Entry point for channel links/refs; strips legacy `g:` prefix, sanitizes, validates geohash, then adds + switches + joins |
| `addChannel(channel, geohash)` | Adds sidebar DOM row + `channels.set(key,{channel,geohash})` |
| `switchChannel(channel, geohash)` | Sets `currentChannel`, `currentGeohash`, `inPMMode=false`; calls `loadChannelFromRelays()` |
| `removeChannel(channel, geohash)` | Deletes from `channels`+`userJoinedChannels`+DOM; if active, switches to `#nymchat`; cannot remove `#nymchat` |
| `blockChannel(channel, geohash)` | Adds to `blockedChannels`, removes from sidebar |
| `saveUserChannels()` | Persists `nym_user_channels` + `nym_user_joined_channels` |

On join, state changes: `channels`, `userJoinedChannels`, `currentChannel`, `currentGeohash`,
`inPMMode=false`, `channelLastActivity`.

### 1.4 Subscriptions (REQ filters)

Channels are subscribed by **kind only** — the `g`/`d` tags live in the event, not the REQ.
`loadChannelFromRelays` → `_queueChannelSubscription` (30 ms foreground / 150 ms background debounce).
Broad filters from `_buildCriticalFilters` (in `relays.js`):

```
{ kinds: [20000], since: channelSince }              // geohash channel msgs
{ kinds: [23333], since: channelSince }              // named channel msgs
{ kinds: [7],    "#k": ["20000","23333"], since, limit }   // reactions
{ kinds: [5],    "#k": ["20000","23333","1059"], since, limit }  // deletions
{ kinds: [9735], "#k": ["20000","23333"], since, limit }   // zaps
```
`channelSince = D1Available ? now-300 : now-86400`. Typing subs use `_ensureChannelTypingSub`.

### 1.5 List sorting (`sortChannelsByActivity`, `channels.js:1794`)

Sequential priority:
1. `#nymchat` always first.
2. The currently-active channel next.
3. Pinned channels (alphabetical among pinned).
4. **Proximity** (only if `settings.sortByProximity && userLocation`): geohash pairs sorted by
   Haversine `calculateDistance(lat1,lon1,lat2,lon2)` (R=6371 km) using `decodeGeohash` centers.
5. Fallback: `channelLastActivity` desc, tiebreak `unreadCounts` desc.

Geohash decode/encode and `getGeohashLocation` live in `geohash-globe.js` (BASE32
`0123456789bcdefghjkmnpqrstuvwxyz`, bit-interleaved). `geohashLocation()` is also reimplemented
in `message-format.js` for rendering `"40.71°N, 74.01°W"` style titles.

### 1.6 Favoriting

- `togglePin(channel, geohash)` toggles membership in `pinnedChannels`, then `savePinnedChannels()`
  (`nym_pinned_channels`) + `nostrSettingsSave()`. `#nymchat` cannot be unpinned.
- `toggleFavoriteCurrentChannel()` / `_refreshFavoriteChannelBtn()` drive the `#favoriteChannelBtn`.

### 1.7 Sharing URLs

- `shareChannel()` builds `${origin}${pathname}#<channel>` (e.g. `https://app.nym.bar/#u10h8`).
- Formatter recognizes deep links `https://app.nym.bar/#<e|g|c>:<channelId>` and renders them as
  clickable `.channel-link` chips (`data-action="channelLink"`, `data-channel-ref="<prefix>:<id>"`).
- In-message `#channel` references are linkified by the formatter (geohash vs named distinguished,
  `active-channel` class applied when it matches the current channel).

---

## 2. Channel messages

### 2.1 Channel message model (`this.messages` entries)

| Field | Type | Meaning |
|-------|------|---------|
| `id` | String | Event id (64-hex) or optimistic `_optim_<rand><ms36>` |
| `content` | String | Raw user text (may include `> quote` lines) |
| `author` | String | Display nym, may carry `#xxxx` suffix |
| `pubkey` | String | 64-hex sender pubkey |
| `created_at` | int (sec) | Nostr timestamp |
| `timestamp` | DateTime | `created_at*1000`, clamped to now if future |
| `_ms` | int | ms from `['ms', …]` tag; sub-second tiebreak (only when "real", not floor) |
| `_seq` | int | Local arrival sequence; final tiebreak |
| `geohash` | String? | Geohash for geohash channels; null for named |
| `channel` | String? | Named-channel name |
| `isOwn` | bool | Sender is current user |
| `isHistorical` | bool | Loaded from cache/backlog (suppress notify/sound) |
| `_optimistic` | bool | Pre-sign placeholder; cleared when signed event arrives |
| `nymMessageId` | String? | Shared id used by PM/group dedup (not for plain channel msgs) |
| `_spamGated` | bool | Held until sender becomes trusted |
| `blocked` | bool | Flagged from a blocked user |

### 2.2 Sending (`publishMessage`, `nostr-core.js:2392`)

Builds tags then signs:

```
tags = [
  ['n', this.nym],                 // nym tag (display name as chosen)
  ['ms', String(Date.now())],      // ms timestamp for sub-second ordering
  [wire.tag, channelKey],          // ['g', geohash] OR ['d', name]
  ['nymquote', author, fullText],  // only when replying (see §9)
  ...customEmojiTagsForContent(wireContent),   // NIP-30
  ...imetaTagsForContent(wireContent),         // NIP-92 media mirrors
]
event = { kind: wire.kind /*20000|23333*/, created_at: now, tags, content: wireContent, pubkey }
```

`channelKey = geohash || 'nymchat'`; `storageKey = geohash ? '#'+geohash : channel`.
An **optimistic** message (temp id `_optim_…`) is displayed immediately, then replaced via
`_replaceOptimisticMessage` once signed. After signing: `sendToRelay(["EVENT", signed])`, and for
geohash channels also `ensureGeoRelayDelivery(signed, geohash)`. PoW is mined first if
`_effectivePowDifficulty() > 0`. `publishMessagePseudonymous` is the same flow with an ephemeral key.

### 2.3 Nym tag and pubkey suffix

- `['n', nym]` carries the chosen display name.
- The 4-char suffix is the **last 4 hex chars of the pubkey**: `getPubkeySuffix(pubkey)` →
  `pubkey.slice(-4)` if hex else `'????'`. `stripPubkeySuffix(nym)` removes a trailing
  `/#[0-9a-f]{4}$/i`. Display is always `base#xxxx`. `getNymFromPubkey` returns `base#suffix`.

### 2.4 Receiving / dedup / ordering

- Dedup levels: (1) `processedMessageEventIds.has(id)`; (2) DOM `[data-message-id=id]` present;
  (3) fallback same content+author within ~2 s. PM/group dedup keys on `nymMessageId`.
- Ordering comparator `_compareMessages`: primary `created_at` (sec); secondary `_ms` (only when
  **both** messages carry a real ms tag); tertiary `_seq`. Insertion uses binary-search
  `_insertMessageSorted` (memory) and `data-created-at`/`data-ms`/`data-seq` comparison (DOM).
- Filtering before render (`getFilteredMessages`): drop deleted ids, spam-gated-from-untrusted,
  blocked pubkeys, keyword-matched content, classified spam.

### 2.5 Presence / who-is-online

Presence is an event in `users.js`/`nostr-core.js`:

- Event **kind 30078**, tags `['d','nym-presence']`, `['t','nym-presence']`, `['n',nym]`,
  `['status','online'|'away'|'hidden']`, optional `['away',message]`, `['avatar-update',url]`.
- `recordOwnActivity()` updates own `lastSeen=Date.now()`, keeps `online` (unless `away`), throttles
  broadcasts to ≤ once/60 s.
- `getEffectiveUserStatus(pubkey)` → `'hidden'` (opted out) | `'online'` (verified bot, or
  `now-lastSeen < 300000` ms) | `'away'` (away message present / status away) | `'offline'`.
  Friends in "friends only" mode share real status privately, overriding `hidden`.
- `/who` lists current-channel users with `lastSeen < 300 s`, excluding blocked/spam-gated.

### 2.6 Flood protection (`messages.js`)

| Mechanism | Function | Threshold | Action |
|-----------|----------|-----------|--------|
| Per-channel rate | `trackMessage` / `isFlooding` | > 10 msgs / 2 s window | block sender 15 min |
| Duplicate content | `trackContent` / `isContentFlooding` | same FNV-1a hash ≥ 3× / 120 s | block sender 15 min |
| Spam classifier | `isSpamMessage` | model/heuristic | hide from public; still visible to sender |

No hard client-side length cap (relay enforces NIP-01 limits). Reaction rate limit (`reactions.js`):
3 toggles / 30 s per `messageId:emoji`, 60 s cooldown on breach.

### 2.7 Rendering pipeline

1. `_shouldDeferLiveFormat`: defer to worker when live + content ≥ 120 chars + has markdown triggers.
2. Placeholder = escaped content with `\n`→`<br>`.
3. Worker pool (≤ 3) calls `NymFormat.formatWithQuotes(content, ctx)`; 5 s timeout fallback to inline;
   formatted-HTML LRU cache (~1200 entries).
4. `_finalizeMessageContent`: blockquote "Read more" truncation (400 mobile / 600 desktop), image
   blur for others' images (setting), video blob fallback, link previews, media fallbacks.
5. DOM row carries `data-message-id/author/pubkey/raw-content/timestamp/created-at/ms/seq`.
   Bubble layout groups consecutive same-author messages within 5 min into `.message-group`.

---

## 3. Private messages (NIP-17 / NIP-59)

### 3.1 Crypto envelope

```
rumor  (kind 14, unsigned)  →  seal (kind 13, signed by identity)  →  gift wrap (kind 1059, signed by one-time ephemeral key)
```

- **Rumor (14)** content + tags (see model). Encrypted (NIP-44) into the seal.
- **Seal (13)** `pubkey = sender identity`, signs to prove authorship; no tags. Encrypted (NIP-44)
  with the ephemeral key into the wrap.
- **Gift wrap (1059)** `pubkey = ephemeral pk`, `tags:[['p', recipient]]`, optional
  `['expiration', ts]`. A **fresh ephemeral keypair per wrap** (`NostrTools.generateSecretKey`) is
  forward secrecy: no long-lived DM key.
- **Timestamp jitter**: both seal and wrap use `randomNow()` (`nostr-core.js:995`) =
  `now - rand*7200` (CSPRNG, **up to 2 hours backward**) to defeat timing correlation.
- A **self-copy** wrap addressed to the sender is also published so own messages appear across
  devices (`pms.js:3213`).

### 3.2 Send (`sendNIP17PM`, `pms.js:296`; wrapper `sendPM`, `pms.js:1579`)

Rumor:
```
{ kind:14, created_at:now, pubkey:self, content,
  tags:[ ['p',recipient], ['x',nymMessageId], ['ms',String(nowMs)],
         (fileOffer? ['offer',JSON]), ...emojiTags, ...imetaTags,
         (edit? ['edit',originalId]) ] }
```
TTL: if `settings.dmForwardSecrecyEnabled && settings.dmTTLSeconds>0`, add `['expiration', now+ttl]`
**to the gift wrap**. Bitchat interop: for unknown/known-bitchat peers a parallel `bitchat1:`-encoded
wrap is also sent; both share the same `nymMessageId` (`x` tag). Pending wraps tracked via
`trackPendingDM` and retried (`retryPendingDMs`, on reconnect `retryPendingDMsOnReconnect`).

### 3.3 Receive (`handleGiftWrapDM`, `pms.js:612`)

Dedup on `processedPMEventIds` → unwrap with candidate secret keys (real privkey + stored ephemeral
keys) via `NymCrypto.unwrapGiftWrap` → verify `seal.pubkey === rumor.pubkey && verifyEvent(seal)`
(`senderVerified=true`; bitchat wraps `false`). Route by rumor kind: 14 message / 69420 receipt or
typing / 7 reaction / 9735 zap / 30078 settings sync. Respect `closedPMs`/`closedPMTimes` (deleted
conversations ignore older backlog). Send delivery receipt; send read receipt if currently viewing.

### 3.4 Conversation model

`getPMConversationKey(other)` = `'pm-' + [self,other].sort().join('-')`.

`pmConversations: Map<pubkey,{ nym:String, lastMessageTime:int }>`.
`pmMessages: Map<conversationKey, PMMessage[]>`:

| Field | Type | Meaning |
|-------|------|---------|
| `id` | String | Gift-wrap event id (for reactions/zaps) |
| `author` | String | Display name |
| `pubkey` | String | Sender pubkey |
| `content` | String | Decrypted plaintext |
| `created_at` | int (sec) | Possibly clamped to now |
| `_originalCreatedAt` | int? | Pre-clamp timestamp |
| `_ms` | int | Sub-second ordering |
| `_seq` | int | Global sequence |
| `timestamp` | DateTime | `created_at*1000` |
| `isOwn` | bool | Sent by self |
| `isPM` | bool | Always true |
| `isGroup` | bool | False for 1:1 |
| `isHistorical` | bool | From backlog |
| `isEdited` | bool | Edited after send |
| `conversationKey` | String | `pm-…` / `group-…` |
| `conversationPubkey` | String | Peer pubkey (1:1) |
| `eventKind` | int | 1059 |
| `senderVerified` | bool | NIP-59 verified vs bitchat |
| `isFileOffer` | bool | File share |
| `fileOffer` | Object? | `{type,name,size,mime,…}` |
| `thinking` | String? | Nymbot reasoning block |
| `bitchatMessageId` | String? | Receipt matching (bitchat) |
| `nymMessageId` | String? | Receipt/dedup id (`x` tag) |
| `deliveryStatus` | String? | `sent`/`delivered`/`read`/`failed` |
| `readReceiptSent` | bool? | We sent the read receipt |

### 3.5 UI

State: `inPMMode`, `currentPM` (peer pubkey), `currentGroup` (mutually exclusive).
`openUserPM(nym,pubkey)` opens/creates a thread; `addPMConversation`/`movePMToTop`/`insertPMInOrder`
maintain the sidebar (most-recent first). PM history persists to IndexedDB (`persistPMMessages`,
limit 2000/conversation) and a durable identity can archive/restore via D1 (`pm-put`/`pm-deposit`,
`pmRestoreFromD1`, `pmLoadOlderFromD1`). Dedup set persisted to `nym_processed_pm_event_ids`
(cap 5000); last sync at `nym_last_pm_sync_<pubkey>`.

---

## 4. Group chats (NIP-17 / NIP-59 multi-member)

### 4.1 Group model (`groupConversations: Map<groupId, Group>`)

`groupId` = 64-hex CSPRNG (`_generateSharedEventId()`).

| Field | Type | Meaning |
|-------|------|---------|
| `name` | String | ≤ 40 chars, single line |
| `members` | `List<String>` | Member pubkeys incl. owner + self |
| `lastMessageTime` | int (ms) | Sidebar ordering |
| `createdBy` | String? | Owner pubkey (null until invite received) |
| `mods` | `List<String>` | Moderator pubkeys |
| `banned` | `List<String>` | Banned pubkeys |
| `avatar` | String? | Group avatar URL |
| `banner` | String? | Group banner URL |
| `description` | String? | ≤ 150 chars, newlines kept |
| `allowMemberInvites` | bool | Non-owners may add members (default true) |
| `inviteEnabled` | bool | Join-via-link allowed (default false) |
| `inviteEpoch` | int | Bump to revoke all outstanding links |
| `metaUpdatedAt` | int (sec) | Last metadata broadcast |
| `lastModTs` | int (sec) | Last applied moderation event time |
| `lastModEventId` | String? | Last moderation event id (dedup) |
| `modLog` | `List<ModLogEntry>` | ≤ 50 entries |

`ModLogEntry`: `{ type: 'kick'|'ban'|'unban'|'promote'|'revoke'|'transfer'|'delete-message',
actor:String, target:String?, messageId:String?, ts:int }`.

Persistence: `nym_groups_<pubkey>` (snapshot incl. `memberProfiles` cache); ephemeral keys at
`nym_ephemeral_keys_<pubkey>`; left-groups at `nym_left_groups[_<pubkey>]` + `nym_left_group_times`;
cross-device encrypted sync category `nymchat-groups`.

### 4.2 Group rumor (kind 14) — common tags

```
['p', member…]                 // every current member
['g', groupId]
['subject', groupName]
['type', <control-type>]       // see table below
['ephemeral_pk', senderNewEphemeralPk]   // rotated every send
['x', nymMessageId]            // shared id across all per-member copies
['ms', String(ms)]             // sub-second ordering (messages)
```
Bootstrap/metadata events additionally carry `['owner',pk]`, `['mod',pk]…`, `['avatar',url]`,
`['banner',url]`, `['description',…]`, `['allow_invites','1'|'0']`, `['invite_enabled','1'|'0']`,
`['invite_epoch',n]`. Each rumor is wrapped per member as a kind-1059 gift wrap.

Control `type` values: `group-message`, `group-invite`, `group-add-member`,
`group-remove-member`, `group-promote-mod`, `group-revoke-mod`, `group-transfer-owner`,
`group-metadata`, `group-delete-message`, `group-join-request`, `group-leave`, `group-unban`,
`key-resync`.

### 4.3 Per-member gift wrap + rotating ephemeral keys

`_sendGiftWrapsAsync(members, rumor, expirationTs, groupId)` (`groups.js:1576`) sends **one gift wrap
per member**. `groupEphemeralKeys: Map<groupId,{ self:{current:{sk,pk},prev:[…]},
members:{pk→ephemeralPk}, _memberKeyTs:{pk→ts} }>`.

- `_ensureSelfEphemeralKey` / `_rotateSelfEphemeralKey`: on every send, push `current`→`prev`
  (keep ≤ `EPHEMERAL_PREV_KEYS_MAX = 30`), generate a fresh `current`, advertise its pubkey in the
  rumor (`['ephemeral_pk', …]`).
- `_getEncryptionPubkey(groupId, memberPk)`: encrypt to the member's known ephemeral pubkey if any,
  else their real pubkey. Out-of-order `ephemeral_pk` updates are guarded by `_memberKeyTs`.
- **Post-compromise recovery**: sending any new message advertises a fresh key that replaces the old
  one for all members; previous keys (≤ 30) keep older messages decryptable; keys merge across
  devices on sync.

### 4.4 Membership & roles

- Add: `addMemberToGroup(groupId, newPk)` (`groups.js:1415`) — owner, or member when
  `allowMemberInvites`; sends `group-add-member`; re-admitting a banned user clears the ban
  (owner/mod only).
- Roles: `_isGroupOwner` (`createdBy===pk`), `_isGroupMod` (`pk in mods`), `_canModerate`
  (owner||mod), `_canAddMembers` (owner || (member && allowMemberInvites)).
- Role checks run **on send and on every received moderation event**; mods cannot act on the owner or
  other mods; only the owner can promote/revoke mods, unban, and transfer ownership.

### 4.5 Moderation events

| Action | type | Key tags | Validated by | Local effect |
|--------|------|----------|--------------|--------------|
| Kick | `group-remove-member` | `['kick',target]` | owner/mod | remove from `members` |
| Ban | `group-remove-member` | `['kick',target]`,`['ban','1']` | owner/mod | remove + add to `banned` |
| Unban | `group-unban` | `['unban',target]` | owner | remove from `banned` |
| Promote mod | `group-promote-mod` | `['mod',target]` | owner | add to `mods` |
| Demote mod | `group-revoke-mod` | `['mod',target]` | owner | remove from `mods` |
| Transfer owner | `group-transfer-owner` | `['owner',newOwner]` | owner | set `createdBy`; drop old owner from `mods` |
| Delete message | `group-delete-message` | `['e',msgId]`,`['target_pubkey',author]` | owner/mod (not owner's msg) | `_applyGroupMessageDeletion` |

Stale/out-of-order guard: `_isStaleModEvent` rejects when `ts < lastModTs` (or equal ts with same
event id); `_recordModEvent` updates `lastModTs`/`lastModEventId`. Every applied action appends to
`modLog`.

### 4.6 Invite links

Token payload (base64url JSON, parsed by `parseGroupInvite` in `message-format.js`):

| Field | Type | Meaning |
|-------|------|---------|
| `v` | int | Version = 1 |
| `g` | String | Group id (64-hex or UUID) |
| `a` | String | Approver pubkey (link sharer) |
| `e` | int | Invite epoch |
| `n` | String | Group name (≤ 80) |

- `buildGroupInviteLink(groupId)` returns `${origin}${pathname}#gjoin=<token>`, only when
  `inviteEnabled` and the caller can add members; returns null otherwise. The formatter renders
  `#gjoin=<token>` deep links as a "Join <name>" chip (`data-action="joinGroupFromInvite"`).
- Join: `requestJoinGroupViaInvite(payload)` — if not logged in, prompt for nym then resume; sends a
  `group-join-request` rumor to the approver (carrying `invite_epoch`); the approver auto-admits if
  enabled and the epoch matches.
- Toggles: `setGroupInviteEnabled`, `setGroupAllowMemberInvites`. Revoke: `rotateGroupInviteEpoch`
  increments `inviteEpoch` and broadcasts `group-metadata`; requests with a stale epoch are rejected.

Constants: `EPHEMERAL_PREV_KEYS_MAX=30`, `GROUP_META_PIGGYBACK_WINDOW=604800` (7 d),
`pmStorageLimit=2000`.

---

## 5. Reactions (kind 7, NIP-25) and custom emoji (NIP-30)

### 5.1 Public channel reaction (`sendReaction`, `reactions.js:944`)

```
event = { kind:7, created_at:now, content:emoji, pubkey,
  tags:[ ['e',messageId], ['p',targetPubkey], ['k',originalKind],
         ...customEmojiTagsForContent(emoji),
         (geohash? ['g',geohash] : namedChannel? ['d',channel]) ] }
```
`originalKind` is inferred from context: `'20000'` geohash channel (default), `'23333'` named
channel, `'1059'` for PM/group messages (DOM `.pm`/`data-isPM`). Removal re-sends the same event
with `['action','remove']`. Optimistic local update + revert on signing failure.

### 5.2 Private reactions

For group messages, the reaction is a **gift-wrapped rumor** `{kind:7, tags:[['g',groupId],
['e',messageId],['k','14'],…]}` sent to all members. For 1:1 PMs, a gift-wrapped
`{kind:7, tags:[['e',messageId],['p',target],['k','1059'],…]}` to `[self, peer]`.

### 5.3 Storage & handling

`reactions: Map<messageId, Map<emoji, Map<pubkey,nym>>>`. `handleReaction` accepts only `k` ∈
`{20000,23333,1059,14}` (or no `k` but a known local message); uses `reactionLastAction`
(`messageId:emoji:pubkey → {action,ts}`) so the latest-by-timestamp action wins on out-of-order
delivery. `_migrateReactionKey(oldId,newId)` moves reaction state when a message's id changes to its
`nymMessageId`. Reactor list modal `showReactorsModal` (cap 50, "+N more"); burst animation on add.

### 5.4 Custom emoji (NIP-30)

`:shortcode:` tokens resolve via `ctx.emojiMap` (standard) then `ctx.customEmojis` (NIP-30 URL map);
`renderCustomEmojiImg` emits `<img class="custom-emoji" …>` (30×30, proxied via
`proxiedEmoji(url, proxyBase)`). `ingestEmojiTags`/`customEmojiTagsForContent` declare/parse the
`['emoji', shortcode, url]` tags. Reaction badges render custom emoji via `renderReactionEmoji`.

---

## 6. Polls (`polls.js`)

Event **kind 30078** (parameterized replaceable) for both the poll and each vote.

Poll create (`publishPoll(question, options)`):
```
tags = [ ['d', 'nym-poll-'+id8], ['t','nym-poll'], ['n',nym], ['g',geohash],
         ['poll_question', question],
         ['poll_option','0',opt0], ['poll_option','1',opt1], … ]
content = question
```
Vote (`votePoll(pollId, optionIndex)`):
```
tags = [ ['d','nym-poll-vote-'+pollId], ['t','nym-poll-vote'], ['e',pollId],
         ['n',nym], ['g',geohash], ['response', String(optionIndex)] ]
content = ''
```

Poll model (`this.polls: Map<pollId, Poll>`):

| Field | Type | Meaning |
|-------|------|---------|
| `question` | String | Poll question |
| `options` | `List<{index:int, text:String}>` | ≥ 2 options |
| `votes` | `Map<pubkey,int>` | Voter → option index (one vote each) |
| `pubkey` | String | Creator |
| `nym` | String | Creator nym |
| `geohash` | String | Owning channel |
| `created_at` | int (sec) | Creation time |

Handling: `handlePollEvent` (skip `['expiration',…]`-expired, require question + ≥ 2 options, dedup by
id), `handlePollVoteEvent` (dedup `processedPollVoteIds` cap 3000; buffer votes that arrive before the
poll in `pendingPollVotes`; one vote per pubkey). Render: `displayPollMessage` (inserted in time order
like a message), `updatePollDisplay` (in-place bar/percentage/voter-avatar update, top 8 + "+N"),
`showPollVotersModal`, `renderChannelPolls`. **Polls are channel-only** (`/poll` errors in PM/group).

---

## 7. Commands (`commands.js`)

Entry: `handleCommand(command)` (`commands.js:508`). Detected by `content.startsWith('/')` in the
message handlers (`messages.js:2367/2436`). Parsing: `parts = command.split(' ')`;
`cmd = parts[0].toLowerCase()`; `args = parts.slice(1).join(' ')`; dispatch `this.commands[cmd].fn(args)`.
Routing helper `_sendToCurrentTarget(content)` → `sendGroupMessage` / `sendPM` / `publishMessage`
based on `inPMMode`/`currentGroup`/`currentPM`/`currentGeohash`.

| Command | Aliases | Args | Effect | Context |
|---------|---------|------|--------|---------|
| `/help` | — | — | `showHelp()` — categorized command palette | all |
| `/join` | `/j` | `[#]channel` | sanitize, block-check, add+switch channel, persist | channels |
| `/pm` | — | `@nym` \| `nym#xxxx` \| 64-hex | resolve pubkey, `openUserPM`; error on self | all |
| `/nick` | — | `newnym` (≤ 20) | reserved-check, set `this.nym`, persist `nym_nickname_<pubkey>`, `saveToNostrProfile` | all |
| `/who` | `/w` | — | list active users (lastSeen < 300 s) in channel | channels only |
| `/clear` | — | — | clear messages container | all |
| `/leave` | — | — | group→`leaveGroup`; PM→`deletePMDirect`; channel→`removeChannel` (not `#nymchat`) | all |
| `/quit` | — | — | clear connection localStorage, close ws, reload | all |
| `/me` | — | `action` | rate-limited; send `/me action` (rendered `* nym action *`) | all |
| `/slap` | — | target | rate-limited; `/me slaps @t around a bit with a large trout 🐟` | all |
| `/hug` | — | target | rate-limited; `/me gives @t a warm hug 🫂` | all |
| `/bold` | `/b` | text | send `**text**` | all |
| `/italic` | `/i` | text | send `*text*` | all |
| `/strike` | `/s` | text | send `~~text~~` | all |
| `/code` | `/c` | text | send ```` ```text``` ```` | all |
| `/quote` | `/q` | text | send `> text` | all |
| `/brb` | — | message | `awayMessages.set`, `publishPresence('away',msg)` | all |
| `/back` | — | — | clear away, `publishPresence('online')` | all |
| `/poll` | — | — | open poll modal (2 option fields) | channels only |
| `/zap` | — | target | resolve LN address, open zap modal | all |
| `/share` | — | — | `shareChannel()` | channels |
| `/block` | — | `[target\|#channel]` | no-arg in channel → block channel→`#nymchat`; else toggle block user / block channel; persist | all |
| `/unblock` | — | `target\|#channel` | unblock user/channel, re-show messages | all |
| `/invite` | — | target | channel → PM invite + public `@`-notice; PM → `startGroupFromPM`; group → `addMemberToGroup` | channel/PM/group |
| `/group` | — | `@u1 @u2 [name]` | requires logged-in (`_canSendGiftWraps`); resolve members (excl. self/Nymbot), `createGroup` | groups |
| `/addmember` | — | target | PM(no group) → `startGroupFromPM`; else group `addMemberToGroup` | groups |
| `/groupinfo` | — | — | list members by role (owner→mods→members) | groups only |
| `/kick` | — | target | `kickFromGroup` (owner/mod) | groups only |
| `/ban` | — | target | `cmdBanFromGroup` (owner/mod) | groups only |
| `/unban` | — | target | `cmdUnbanFromGroup` (owner) | groups only |
| `/addmod` | — | target | `promoteModerator` (owner) | groups only |
| `/removemod` | — | target | `revokeModerator` (owner) | groups only |
| `/transferowner` | — | target | confirm dialog → `transferOwner` (owner) | groups only |

Notes: there is **no `/shrug`** despite the README listing it. Total = **34 commands** (`/help`,
`/join`, `/pm`, `/nick`, `/who`, `/clear`, `/leave`, `/quit`, `/me`, `/slap`, `/hug`, `/bold`,
`/italic`, `/strike`, `/code`, `/quote`, `/brb`, `/back`, `/poll`, `/zap`, `/share`, `/block`,
`/unblock`, `/invite`, `/group`, `/addmember`, `/groupinfo`, `/kick`, `/ban`, `/unban`, `/addmod`,
`/removemod`, `/transferowner`) plus **7 single-letter aliases** (`/j`→`/join`, `/w`→`/who`,
`/b`→`/bold`, `/i`→`/italic`, `/s`→`/strike`, `/c`→`/code`, `/q`→`/quote`). Action commands (`/me`,`/slap`,`/hug`) share a rate limit:
3 per 30 s, 60 s cooldown (`_checkActionCommandRateLimit`).

Bot commands use a separate `?`-prefix path (`_handleBotCommand`) and are out of scope for the core
messaging client (documented in README): `?ask ?define ?translate ?news ?trivia ?joke ?riddle
?wordplay ?roll ?flip ?8ball ?pick ?math ?units ?time ?btc ?who ?summarize ?top ?last ?seen ?help
?balance ?buy ?model ?git ?gift ?transfer ?about ?nostr`.

Autocomplete command palette categories (`setupCommands`): channels, pms, groups, formatting, misc.

---

## 8. Autocomplete (`autocomplete.js`)

Four independent dropdowns, each driven by the active trigger token at the cursor; selection inserts a
token and refocuses the input. Max 8 results each.

| Trigger | Dropdown id | Source | Behavior |
|---------|-------------|--------|----------|
| `@` mention | `autocompleteDropdown` | `this.users` | filter by `base#suffix` substring; rank channel members (online→away→offline) then others; insert `@base#suffix ` (suffix disambiguates same-named users). `_mentionPriorityPubkeys` prioritizes the current PM peer / group members |
| `#` channel | `channelAutocomplete` | `messages` keys + `channels` + `commonGeohashes` | filter valid names; sort current→joined→by msg count→name; shows location + msg count; insert `#name ` |
| `:` emoji | `emojiAutocomplete` | `emojiMap` + `allEmojis` + `customEmojis` | empty = recents+common; else fuzzy (exact→prefix→priority→shorter); custom emoji shown as `<img>`; insert resolved emoji/`:shortcode:` + space |
| `\` kaomoji | `kaomojiAutocomplete` | `kaomojiCategories` | filter category label; insert kaomoji + space |

Each has `navigate*(direction)` (arrow keys, wraps), `select*()` (Enter), and `hide*()`.
`refreshAutocompleteIfOpen` / `refreshChannelAutocompleteIfOpen` re-query as the user types.
Command (`/`) autocomplete is the command palette (`commands.js` `showCommandPalette`).

---

## 9. Message formatting (`message-format.js`, `format-worker.js`)

`NymFormat.format(content, ctx)` and `NymFormat.formatWithQuotes(content, ctx, depth)` are pure and
shared between the main thread and `format-worker.js` (which imports `syntax-highlight.js` +
`message-format.js`, receives an `init` emojiMap, and formats batches off-thread). Fast path: if no
trigger chars (`RX_FORMAT_TRIGGERS`), only `\n`→`<br>`.

**Markdown subset** (in order):
- HTML escaped first (`& < > "`).
- Code: ```` ```lang\ncode``` ```` fenced (language label + syntax highlight + copy button,
  placeholder `﷐i﷑`), unterminated ```` ``` ````, inline `` `code` ``.
- `**bold**`, `__bold__`, `*italic*`, `_italic_`, `~~strike~~`.
- `> quote` lines (and `formatWithQuotes` builds nested `<blockquote>` up to depth 5, parsing
  `> @Author: msg` headers into `.quote-author` + resolved flair).
- Headings `#`, `##`, `###`.

**Media & links**:
- Video `mp4|webm|ogg|mov` → `<video>` container (proxied, fallback mirrors, expand button).
- Image `jpg|jpeg|png|gif|webp` → `<img class="msg-img">` (proxied, fallbacks). Adjacent media collapse
  into `.message-gallery` (`gallery-2/3/4plus`).
- `app.nym.bar/#<e|g|c>:<id>` → channel-link chip. `…#gjoin=<token>` → group-invite "Join <name>" chip
  (validated via `parseGroupInvite`). Other `https?://…` → `<a target=_blank rel=noopener>`.

**Mentions & emoji**:
- `@name#xxxx` and `@name` → `.nm-mention` (`#xxxx` wrapped in `.nym-suffix`). The collapse
  `@name#xxxx#xxxx`→`@name#xxxx` runs first.
- `#channel` → `.channel-reference` (geohash adds `.geohash-reference`; current channel adds
  `.active-channel`; title shows geohash location).
- `:shortcode:` → standard emoji or NIP-30 custom emoji image; ASCII smileys (`:)`, `:(`, `:D`, `:P`,
  `;)`, `:o`, `:|`, `<3`, `/\`) → unicode; bare unicode emoji wrapped in `.emoji`.
- `[gc:…]` game tokens hidden; finally `\n`→`<br>`.

Reply/quote on send (`publishMessage`, §2.2): wire content becomes `@author userText` with the full
blockquote preserved in `['nymquote', author, fullText]`; NYM reconstructs the visual blockquote on
render. `extractQuoteAuthors` resolves flair for quoted authors on the main thread.

`ctx` passed to the formatter includes: `emojiMap`, `customEmojis`, `mediaFallbacks`, `proxyBase`,
`currentChannel`, `currentGeohash`, `highlightCode`, `quoteFlair`.

---

## 10. Read receipts, typing, disappearing messages, forward secrecy

**Receipts / typing** use a gift-wrapped rumor **kind 69420**:
```
{ kind:69420, content:'', pubkey,
  tags:[ ['p',peer] (or ['g',groupId]), ['x',messageId],
         ['receipt','delivered'|'read']  // receipts
         | ['typing','start'|'stop'] ] } // typing
```
Channel read receipts use a public **kind 24421** aggregated per sender (`sendChannelReadReceipt`).
Typing TTL ~4 s, throttled ~1/s. Scopes: `settings.readReceiptsMode` / `typingIndicatorsMode` ∈
`{everyone, friends, off}` (gated by `isReadReceiptAllowedFor`/`isTypingIndicatorAllowedFor`). Bitchat
interop receipts encode NoisePayloadType `0x02` (read) / `0x03` (delivered). PM delivery status maps
to checkmarks (✓ sent, ✓✓ read).

**Disappearing / TTL**: NIP-40 `['expiration', ts]` on the **gift wrap**, enabled when
`settings.dmForwardSecrecyEnabled && settings.dmTTLSeconds>0` (e.g. 600 s). Relays enforce deletion.
Poll/poll-vote events also honor an `expiration` tag on receive. `cosmetic-redacted` channel messages
schedule a kind-5 deletion ~600 s after send.

**Forward secrecy**: every gift wrap (PM and per-member group) is signed by a **fresh one-time
ephemeral key** — there is no persistent DM key. Groups additionally **rotate** an advertised
`ephemeral_pk` every message (post-compromise recovery; ≤ 30 previous keys retained for decryption).

---

## 11. Blocking & keyword filtering (`users.js`)

**User blocking**: `blockedUsers: Set<pubkey>`, persisted `nym_blocked` (JSON array).
`toggleBlockUserByPubkey`, `unblockByPubkey` (+ `showMessagesFromUnblockedUser`). Blocked users are
skipped in the user list, message render, autocomplete, reaction handling, and notifications. Channel
blocking uses `blockedChannels` / `nym_blocked_channels` (§1.2).

**Keyword filtering**: `blockedKeywords: Set<String>` (lowercase), persisted
`nym_blocked_keywords` (JSON array). `addBlockedKeyword`/`removeBlockedKeyword`/`updateKeywordList`;
`hasBlockedKeyword(content, nym)` matches a keyword inside message content **or** the author nym
(case-insensitive); matched DOM messages get `.blocked`; matched users are hidden from the list.

**Friends**: `friends: Set<pubkey>`, persisted `nym_friends`. `isFriend`, `toggleFriend`,
`removeFriendByPubkey`, `getFriendBadgeHtml`. Friend status gates the `friends`-scope read
receipts/typing and the friends-only presence override.

**Verified identities**: `isVerifiedDeveloper(pubkey)` (single hardcoded `verifiedDeveloper.pubkey`),
`isVerifiedBot(pubkey)` / `verifiedBotPubkeys`. Reserved nicks: `['luxas','nymbot']`
(`isReservedNick`).

### User model (`this.users: Map<pubkey, User>`)

| Field | Type | Meaning |
|-------|------|---------|
| `nym` | String | Display name (may carry suffix) |
| `pubkey` | String | 64-hex pubkey |
| `lastSeen` | int (ms) | Last activity |
| `status` | String | `online` / `away` / `offline` |
| `channels` | `Set<String>` | Channels the user was seen in |

Profile (kind 0): `name`, `display_name`, `picture`, `banner`, `about`, `nip05`, `lud16`. Avatars
resolved via `getAvatarUrl` (blob cache → custom URL → deterministic identicon SVG). Presence
threshold `ACTIVE_THRESHOLD = 300000` ms; user eviction at > 10000 entries older than 24 h.

---

## Appendix A — Event kinds

| Kind | Use |
|------|-----|
| 0 | Profile metadata (name, picture, banner, about, nip05, lud16) |
| 5 | Deletion (NIP-09) — filtered with `#k` 20000/23333/1059 |
| 7 | Reaction (NIP-25), `['k', originalKind]` |
| 13 | NIP-59 seal (signed by identity) |
| 14 | NIP-17 private-message rumor (PM and group) |
| 1059 | NIP-59 gift wrap (signed by one-time ephemeral key) |
| 9735 | Lightning zap receipt (NIP-57) |
| 20000 | Geohash channel message (`['g', geohash]`) |
| 23333 | Named channel message (`['d', channel]`) |
| 24421 | Public channel read receipt (aggregated) |
| 30078 | Parameterized replaceable: presence (`nym-presence`), polls (`nym-poll`/`nym-poll-vote`), encrypted settings sync |
| 69420 | Gift-wrapped receipt / typing rumor |

## Appendix B — Tag reference

| Tag | Where | Meaning |
|-----|-------|---------|
| `['n', nym]` | 20000/23333/30078 | Display nym |
| `['ms', ms]` | 20000/23333/14 | Millisecond send time (sub-second ordering) |
| `['g', geohash\|groupId]` | 20000 / group rumor / poll | Geohash channel id, or group id |
| `['d', channel]` | 23333 / 30078 / reaction | Named channel id / replaceable identifier |
| `['k', kind]` | 7 / 5 | Original target kind (20000/23333/1059/14) |
| `['e', id]` | 7 / 9735 / poll-vote / delete-message | Target event id |
| `['p', pubkey]` | 14 / 1059 / 7 / 69420 | Recipient / reaction target |
| `['x', id]` | 14 / 69420 | Shared `nymMessageId` for dedup/receipts |
| `['action','remove']` | 7 | Reaction removal |
| `['expiration', ts]` | 1059 / 30078(poll) | NIP-40 TTL |
| `['nymquote', author, fullText]` | 20000/23333 | Reply reconstruction |
| `['type', …]` | 14 (group) | Group control-event type |
| `['ephemeral_pk', pk]` | 14 (group) | Sender's rotated ephemeral pubkey |
| `['owner'/'mod'/'kick'/'ban'/'unban'/'subject'/'avatar'/'banner'/'description'/'allow_invites'/'invite_enabled'/'invite_epoch']` | 14 (group) | Group metadata / moderation |
| `['receipt', type]` / `['typing', status]` | 69420 | Delivery/read receipt or typing |
| `['poll_question', q]` / `['poll_option', idx, text]` / `['response', idx]` / `['t', 'nym-poll'…]` | 30078 | Poll |
| `['emoji', shortcode, url]` | any | NIP-30 custom emoji declaration |
| `['imeta', …]` | any | NIP-92 media mirror metadata |

## Appendix C — localStorage / persistence keys

`nym_user_channels`, `nym_user_joined_channels`, `nym_pinned_channels`, `nym_hidden_channels`,
`nym_blocked_channels`, `nym_unread_counts`, `nym_channel_activity`, `nym_channel_last_read`,
`nym_blocked`, `nym_blocked_keywords`, `nym_friends`, `nym_nickname_<pubkey>`,
`nym_processed_pm_event_ids`, `nym_last_pm_sync_<pubkey>`, `nym_closed_pms`, `nym_closed_pm_times`,
`nym_groups_<pubkey>`, `nym_ephemeral_keys_<pubkey>`, `nym_left_groups[_<pubkey>]`,
`nym_left_group_times`, `nym_recent_emojis`, `nym_avatar_url`, `nym_banner_url`. IndexedDB stores
channel messages (≤ 500/channel) and PM/group messages (≤ 2000/conversation). Durable identities
archive PMs to D1 (`pm-put`/`pm-deposit`) and sync groups to the `nymchat-groups` category.

## Appendix D — Relevant DOM (index.html)

| Element | id / class | Purpose |
|---------|-----------|---------|
| Channel list | `#channelList` | Sidebar channels |
| PM list | `#pmList` | Sidebar conversations |
| Messages scroller / list | `#messagesScroller` / `#messagesContainer` | Message rows |
| Composer input | `#messageInput` (contenteditable role=textbox) | Message entry |
| Mention AC | `#autocompleteDropdown` | `@` mentions |
| Channel AC | `#channelAutocomplete` | `#` channels |
| Emoji AC | `#emojiAutocomplete` | `:` emoji |
| Kaomoji AC | `#kaomojiAutocomplete` | `\` kaomoji |

Message row attributes: `data-message-id`, `data-author`, `data-pubkey`, `data-raw-content`,
`data-timestamp`, `data-created-at`, `data-ms`, `data-seq`, plus `data-pollId`/`data-groupId`/
`data-isPM` where applicable. Reaction badges carry `data-message-id`/`data-emoji`.
