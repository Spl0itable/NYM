# Audit 03 — Messaging state + logic (channels, messages, PMs, groups, reactions, polls)

1:1 fidelity audit of the Flutter messaging slice against the Nymchat Nostr PWA.
Owned surface: `lib/state/app_state.dart`, `lib/state/nostr_controller.dart`,
`lib/features/{pms,groups,channels,polls,reactions}/**` (logic only),
`test/pm_group_test.dart`, `test/engine_ext_test.dart`.

PWA references: `js/modules/{channels,messages,pms,groups,reactions,polls}.js`.

## Verification

- `flutter analyze lib/state lib/features/pms lib/features/groups lib/features/channels lib/features/polls lib/features/reactions` → **No issues found**.
- `flutter test test/pm_group_test.dart test/engine_ext_test.dart` → **35 passed** (31 pre-existing + 4 new).

## Discrepancies found and fixed

| # | Area | PWA behavior (source) | Flutter (before) | Fix |
|---|------|----------------------|------------------|-----|
| 1 | Channel pin protection | `togglePin('nymchat')` is a full no-op — never added to/removed from `pinnedChannels` (channels.js:700-705) | `togglePin('nymchat')` **added** `#nymchat` to the pinned set when not already pinned | `togglePin` now returns the current pinned state for `#nymchat` without mutating (`app_state.dart`) |
| 2 | Channel hide protection | `toggleHideChannel('nymchat')` is a full no-op (channels.js:790-794) | `hideChannel('nymchat')` **added** it to `hiddenChannels` | `hideChannel` returns `false` for `#nymchat` without mutating |
| 3 | Pinned-band ordering | Within the pinned band the PWA does **not** alphabetize; it falls through to proximity/activity/unread like any channel (channels.js:1819-1869) | Pinned channels were sorted **alphabetically by key** (an invented tiebreak) | Removed the alpha tiebreak in `ChannelManager._compare`; pinned band now orders by activity→unread. Test updated to assert PWA order |
| 4 | Reaction kind filter | `handleReaction` rejects a reaction whose `['k', …]` tag is not one of `20000/23333/1059/14` (reactions.js:218) | No `k`-tag validation — reactions from other Nostr apps were tallied | `_ingestReaction` rejects unsupported `k` tags (missing `k` still allowed) |
| 5 | Reaction blocked guard | `handleReaction` drops reactions from blocked pubkeys (reactions.js:204) | No blocked-user guard on reaction ingest | `_ingestReaction` drops reactions whose reactor is in `blockedUsers` |
| 6 | Closed-PM re-open | `closedPMs` + `closedPMTimes`: a closed thread re-opens only when a message **strictly newer** than the close time arrives; older backlog stays suppressed (pms.js:1129-1141) | `_closedPMs` permanently suppressed **all** future messages for a closed peer (no time tracking) | Added `_closedPMTimes`; `closePM(peer, {nowSec})` stamps the close time; `ingestPMMessage` re-opens on a strictly-newer message |
| 7 | PM future-timestamp clamp | `tsSec = Math.min(tsSec, nowSec)` — strict cap at now (pms.js:1155) | `mapPmRumor` used a `+60s` tolerance (`createdAtRaw > nowSec + 60 ? nowSec : raw`) | Strict cap to `nowSec` |
| 8 | Mod-log entry timestamp | `_appendModLog` stamps `Math.floor(Date.now()/1000)` (receive/apply time), not the event ts (groups.js:519-524) | `_appendModLog` stored the **event** `ts` | New `_modLog` helper stamps wall-clock now; all 5 control cases use it |
| 9 | Metadata zero-ts guard | `_applyGroupMetadataTags` rejects a falsy/zero `metaTs` (`if (!metaTs ...)`, groups.js:2169) | `_applyMetadata` accepted `ts == 0` when `metaUpdatedAt == 0` | Added `if (ts <= 0) return false` |
| 10 | Unread count vs blocked | `_recomputeUnreadCount` skips `blockedUsers` (and spam) messages (channels.js:1724) | Channel/PM/group unread bumped for **any** non-own message, including blocked/keyword-filtered | Unread increments now gated on `!isMessageFiltered(m)` at all three ingest sites |

## Verified faithful (no change needed)

- **`compareMessages`** (`models/message.dart`) == `_compareMessages`: `created_at` → real-`ms` tag → `seq` (messages.js:71). Used by every insert/sort path.
- **Message 3-level dedup**: `_seenIds` (event id) + `_seenNymMessageIds` (shared `x` id across PM/group recipient copies) + per-conversation list membership — mirrors messages.js (`isDuplicateMessage`, the PM `nymMessageId` dedup at messages.js:595).
- **Reaction latest-by-ts**: `actionKey = messageId:emoji:reactor`, stale-skip on `last > ts`, reactor map prune at >5000 → keep last 4000 (reactions.js:247-259). Reactor map drop-to-empty cascade matches.
- **PM rumor**: kind-14 tags `['p',recipient]`/`['x',nymMessageId]`/`['ms',ms]`; conversation key `pm-<sorted pubkeys>` (`getPMConversationKey`, pms.js:1393); self-copy maps `isOwn` with peer from the `p` tag.
- **Group rumor + role matrix**: kick/ban = owner|mod (mods cannot act on owner/other mods); unban/promote/revoke/transfer = owner-only; stale guard (`ts < lastModTs`, or `==` with same event id); `recordModEvent` clamps `min(ts, now+300)` and only advances `lastModTs` (groups.js:969-1163, 2144-2163). Add-member: owner, or member when `allowMemberInvites`; re-admit clears ban for owner/mod.
- **Ephemeral keys**: `current/prev[]` rotation, prev cap 30, member-key stale guard by ts, `encryptionPubkeyFor` (member eph → self current for self-copy → real pubkey), `selfSecretKeys` unwrap candidates (groups.js — `groupEphemeralKeys`).
- **Polls**: kind-30078 create/vote tag shapes; `processedPollVoteIds` dedup cap 3000→keep 2000; `pendingPollVotes` buffer + replay on poll arrival; one vote/pubkey (first wins); `expiration` honored on receive; channel-only construction (polls.js:93-185).
- **Filtering**: `hasBlockedKeyword(text, nick)` matches content OR base-nym (suffix stripped), own messages exempt from keyword (messages.js:93-99, 2946); `messagesForCurrentViewProvider` drops blocked-user + keyword matches.
- **Channel sort priority**: `#nymchat` → active → pinned band → proximity (valid-geohash pairs only, when `sortByProximity && userLocation`) → activity desc → unread desc (channels.js:1804-1869).

## Deferrals (out of slice or needs services/models edits)

| Item | Reason |
|------|--------|
| `deletedEventIds` filter set | PWA `getFilteredMessages` filters messages whose `id`/`nymMessageId` are in `deletedEventIds`, catching a kind-5 deletion that arrives **before** its target (messages.js:2938-2939). Flutter only physically removes via `removeMessage` (no pending-deletion set), so a message arriving after its deletion would still display. Adding the set + the ingest hook spans the controller’s kind-5 handler; deferred to keep the fix surgical. |
| `isSpamMessage` filter | PWA filters spam content in `getFilteredMessages` (messages.js:2947) and on render; Flutter has no spam classifier in-state. New subsystem; deferred. |
| Pubkey-gating (`_isPubkeyGated` / `nymchatPubkeys`) | PWA gates non-friend, non-nymchat senders past a per-pubkey volume threshold (messages.js:2941-2942, 481-483). Anti-spam volume gate lives in the relay/controller layer; deferred. |
| Flood protection thresholds | PWA `trackMessage`/`isFlooding`: >10 msgs/2 s → 900 000 ms block; content FNV-1a hash repeat ≥3 within 120 000 ms → 900 000 ms block (messages.js:216-322). Render-level cosmetic (`message flooded` class) + send gate, not part of the in-memory store; no Flutter equivalent in this slice. Deferred. |
| Group metadata `meta_ts` piggyback | PWA accepts a piggybacked `['meta_ts', …]` tag as the metadata timestamp source (groups.js:1293-1295). Flutter uses the message ts directly. Edge optimization; deferred. |
| Unread count keying (`pm-<sorted>` vs bare pubkey) | PWA keys PM/group unread by the wire conversation key; Flutter keys by bare peer pubkey / group id. Internally consistent in Flutter (`switchView` clears both `view.id` and `view.storageKey`); no observable difference. Noted, not changed. |
| `blockChannel('#nymchat')` guard | Flutter returns `false` for `#nymchat`; the PWA `blockChannel` has no such guard (relies on the UI never offering it). Kept as benign Flutter hardening (the UI likewise never offers it). |

## Tests added (for real bugs)

- `engine_ext_test.dart` → reactions: unsupported `k` tag ignored; supported `k=14` registers; blocked-user reaction dropped.
- `engine_ext_test.dart` → channel sort: `#nymchat` can neither be pinned nor hidden; normal channel pins/hides; pinned band ordered by activity (not alpha).
- `pm_group_test.dart` → closed-PM: stale backlog stays suppressed, strictly-newer message re-opens.
