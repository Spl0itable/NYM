# Gap report — Slice 09: Calls UI + P2P file-transfer UI + Notifications/Toast UI

**Summary.** The Flutter call overlay is a thin skeleton of the PWA's. It ships the
controls row, a basic video grid, a basic chat panel and a (no-op) reactions bar,
but is missing the **flying/floating reactions** entirely (the headline call
feature — incoming reactions are dropped on the floor), the **presenter/screenshare
restriction menu** (group calls), the **chat-message reactions + read receipts +
typing decorations**, **@mention autocomplete in call chat**, the **reactions-bar
"+" / more-emoji picker**, the **switch-camera availability gating**, decorated
nyms (suffix/badges/flair) in tiles & chat, and **every user-facing call status
toast** ("Call declined", "No answer", "Missed call", "User is busy", media-error).
The video-grid breakpoints differ from the PWA. On P2P, the **in-message file-offer
card** (Download button + inline progress + seeding/unseeded status) is **completely
absent** even though the data model carries it; only the transfers *modal* exists.
On notifications, there is **no in-app notification surface at all** — no
notification-history list/badge (the PWA's bell + modal) and no in-chat system-message
("action"/"system") rendering for the dozens of `displaySystemMessage` call sites.

**Finding count: 18** (2 blocker, 8 high, 6 medium, 2 low) + 2 incidental.

---

### F1: Floating/flying in-call reactions not rendered (send OR receive)  [SEVERITY: blocker]
- PWA: `js/modules/calls.js:1149-1186` — `sendCallReaction()` broadcasts the emoji **and** calls `_showFlyReaction(emoji,'You')`; `_onCallReaction` (1162-1167) calls `_showFlyReaction(emoji,null,sender)` for incoming. `_showFlyReaction` (1169-1186) appends a `.call-react-fly-item` into `#callReactionsFly` (`index.html:938`) at a random `left: 8%–82%`, with the emoji (`.call-react-emoji` 2.5rem) and a decorated "who" pill (`.call-react-who`), auto-removed after 3200ms. Animation `@keyframes callReactFly` (`css/styles-features.css:5144-5149`): rises `translateY(0 → -260px)`, scale `0.6 → 1`, fade in then out over 3.1s.
- Flutter: `lib/features/calls/call_overlay.dart` — **MISSING**. There is no `#callReactionsFly` equivalent layer in the `Stack` (lines 59-76). `call_service.dart:289-296 sendReaction` broadcasts but never surfaces a local fly. `call_service.dart:407-408` explicitly drops incoming reactions: `// Floating reactions are visual only; surfaced via state if desired.` (no-op).
- Gap: Tapping a reaction emoji does nothing visible locally, and reactions sent by remote peers are invisible. The single most visible "fun" call feature is dead in both directions.
- Fix approach: Add a `List<_FlyReaction>` (emoji + nym + left% + key) to `CallState` (or a local `AnimationController`-driven overlay in `CallOverlay`). On `sendReaction`, append a self fly. In `call_service.dart` `case 'reaction'`, push an incoming fly (decorated nym) into state. Render a `Positioned.fill(IgnorePointer(Stack(...)))` of `_FlyReaction` widgets in the grid `Stack` (overlay.dart:59), each a `TweenAnimationBuilder`/implicit anim translating `0 → -260` over 3100ms with scale 0.6→1 and opacity in/out, removing itself on completion. Random `left` 8–82%. Emoji 24sp (PWA 2.5rem ≈ 40px on a phone; use ~40sp), "who" pill bg `black 0.5`, radius 8.
- Effort: M  Risk: low  Confidence: high

### F2: In-message P2P file-offer card entirely missing (Download + inline progress + seeding state)  [SEVERITY: blocker]
- PWA: `js/modules/messages.js:851-917` builds a `.file-offer` card inside the message bubble for `message.isFileOffer`: header = `.file-offer-icon` (category-colored doc SVG) + `.file-offer-name` + `.file-offer-meta` (`size • type • Torrent?`), then a status block — own+seeding → green dot "Seeding - available for download" + **Stop** (`stopSeeding`); own+unseeded → grey dot "No longer seeding"; peer+unseeded → "No longer available"; peer+available → `.file-offer-actions` with **Download** (`requestP2PFile`) or **Download (Torrent)** (`downloadTorrent`), plus a hidden `.file-offer-progress` bar (`.file-offer-progress-fill` + `.file-offer-progress-text`) revealed during transfer. Live progress: `p2p.js:608-622 updateFileOfferProgress` writes `pct% • speed/s` into `#progress-text-{offerId}`; `updateTransferStatus` (625-648) flips the button to "Downloaded" / "Retry". CSS card: `css/styles-features.css:2087-2290` (`.file-offer-name`, `.file-offer-btn`, `.file-offer-progress-bar`, torrent/unavailable variants).
- Flutter: `lib/widgets/chat/message_row.dart` — **MISSING** (grep for offer/download/p2p/file → 0 hits). The model already carries the data: `lib/models/message.dart:98-99 isFileOffer`/`fileOffer`, and the service is ready: `lib/features/p2p/p2p_service.dart:150 requestFile(offerId)`, `:181 stopSeeding`, `:140 registerOffer`. Only `p2p_transfers_modal.dart` shows transfers, and only if the user opens the modal — there's no entry point or per-message UI.
- Gap: A received file offer renders as a plain text message (or empty) with no way to download it, no size/type, no seeding indicator, and no inline progress. The whole P2P file-sharing UX is unreachable from chat.
- Fix approach: In `message_row.dart`, when `message.isFileOffer && message.fileOffer != null`, render a `FileOfferCard` widget instead of the text body. Parse the map via `FileOffer.fromJson`. Header: doc icon + name (ellipsis) + meta (`formatFileSize(size)` + type + ` • Torrent` if `isTorrent`). Wire **Download** → `p2pService.requestFile(offerId)`, **Stop** → `stopSeeding`. Drive the card from `P2PService` (a `ChangeNotifier`) keyed by offerId: show a `LinearProgressIndicator` + `pct% • speed` while a transfer for that offerId is active, "Downloaded"/"Retry" on complete/error. Add a seeding/unseeded dot row for own offers. Match radii/colors from CSS 2087-2290.
- Effort: L  Risk: med  Confidence: high

### F3: Presenter / screen-share-restriction menu absent (group calls)  [SEVERITY: high]
- PWA: `js/modules/calls.js:1735-1851` — `#callPresenterBtn` (`index.html:978`, mod-only, shows a request-count badge) opens `#callPresenterMenu` (`index.html:940`). `_renderPresenterMenu` (1790-1824) renders: a "Only the presenter can share" checkbox (`setScreenShareRestricted`), a "Requests" section (peers who tapped "request to present", each with **Approve**), and a "Participants" list each with **Make presenter** / **Clear** (`assignPresenter`). Non-mods who can't share get a **request-mode** share button (`_updateCallControls` 1757-1765, `.request-mode` border=primary) that calls `requestToPresent()`. CSS `styles-features.css:5207-5234+` (`.call-presenter-menu` 280px, bottom 92px right 16px).
- Flutter: `lib/features/calls/call_overlay.dart` — **MISSING** entirely. No presenter button, no menu, no request-mode share state. `call_service.dart:263-265` comment: "no group presenter restriction here — 1:1 + open group" — the entire moderation layer (`shareRestricted`, `presenter`, `presentRequests`, `present-state`/`present-request` signals) is unimplemented. `CallState` has no `shareRestricted`/`presenter`/`presentRequests` fields.
- Gap: In a group call, moderators cannot restrict who shares or assign a presenter; non-mods cannot request to present. Anyone can screen-share unconditionally (or the feature silently mismatches the protocol the PWA peers speak).
- Fix approach: Add `shareRestricted`, `presenter` (pubkey?), `presentRequests` (Set) to `CallState` + the active-call model. Implement `present-state`/`present-request` signal handling + `requestToPresent`/`setScreenShareRestricted`/`assignPresenter` in `call_service.dart` (mirror calls.js 1033-1099). Add a presenter `_CtrlBtn` (people icon, mod-only, badge=requests.length) to `_Controls` and a `_PresenterMenu` bottom-anchored panel. Gate the share button into request-mode when `!canShareScreen()`. This is the largest call-UI gap after reactions.
- Effort: L  Risk: med  Confidence: high

### F4: In-call chat-message reactions (+ picker, badges, long-press) missing  [SEVERITY: high]
- PWA: `js/modules/calls.js:1397-1705` — every call-chat row gets a `.call-chat-react-btn` (＋, top-right) and a `.call-chat-reactions` badge strip. `callChatReact`/`_showCallChatQuickReact` (1482-1585) shows a 6-emoji quick-react popup (recents+defaults) plus a "more" picker and a user-menu button. `_toggleCallChatReaction` (1629-1650) broadcasts `chat-reaction` add/remove; `_renderCallChatReactions` (1668-1705) renders `.call-chat-reaction` count badges (self-highlight via `color-mix primary 22%`) + an add-reaction button. Long-press to open is wired in `_setupCallChatInteractions` (1589-1622, 500ms, haptic). CSS 4960-5004.
- Flutter: `lib/features/calls/call_overlay.dart:287-397 _ChatPanel` — **MISSING**. Each chat bubble is a plain `Container` with text only (lines 335-344). No react button, no badges, no long-press. `CallChatMessage` (`call_state.dart:48-60`) has no reactions field; `call_service.dart` doesn't handle `chat-reaction` (handleSignal has no such case).
- Gap: Users cannot react to in-call chat messages, and reactions from peers are invisible.
- Fix approach: Add `Map<String,Set<String>> reactions` to `CallChatMessage`; handle `chat-reaction` in `call_service.dart`. In `_ChatPanel` bubbles, add a long-press → quick-react sheet and a wrap of count badges below the text. Reuse the app's existing reaction picker. Self badge highlight = primary 22%.
- Effort: M  Risk: low  Confidence: high

### F5: Every user-facing call status toast is silent in Flutter  [SEVERITY: high]
- PWA: `js/modules/calls.js` surfaces ~12 status strings via `displaySystemMessage` (a chat system-message bubble, `messages.js:1511`): "Must be connected to start a call" (73), "Already in a call" (77), "No one to call in this group" (97), media error "Could not access camera/microphone: …" (66), "No answer" (130), "Call declined" / "User is busy" (462), "Call ended" (486), "Missed call from X" (375/476), "Requested to present" (1039), "X requested to present" (1046), "You can now share your screen" (1066), "No moderator available…" (1037), "Screen sharing is not supported…" (983), "Left the call — you blocked X" (1968).
- Flutter: `lib/features/calls/call_service.dart` — **MISSING**. Grep for these strings → none. The service has no `displaySystemMessage`/SnackBar sink; it silently `reject`s on busy (`:441`) / declined (`:208`) and silently ends. (`p2p_service.dart:78` has an `onSystemMessage` sink — calls has no equivalent.)
- Gap: A declined call, a busy peer, a missed call, a failed `getUserMedia`, or "already in a call" all happen with zero feedback. The user has no idea why a call didn't connect or ended.
- Fix approach: Add an `onSystemMessage`/event sink to `CallService` (mirroring `P2PService.onSystemMessage`) and pump these strings to it at each PWA call site. Route the sink to the same in-chat system-message rendering built for F16, or to a `ScaffoldMessenger` SnackBar as an interim. Critically, also raise a **missed-call notification** (see F15) for the 45s-timeout and cancel paths.
- Effort: M  Risk: low  Confidence: high

### F6: @mention autocomplete in call chat missing  [SEVERITY: high]
- PWA: `js/modules/calls.js:1853-1954` + `index.html:921 #callMentionAutocomplete`. Typing `@` in the call-chat input opens `.call-mention-autocomplete` (CSS 5044-5078) listing call participants (avatar + decorated `@nym#suffix`), keyboard-navigable (↑/↓/Enter/Tab/Esc via `handleCallChatKeydown` 1205-1218), inserts `@base#suffix `. Scoped to call members only (`_callMentionParticipants`), excludes blocked.
- Flutter: `lib/features/calls/call_overlay.dart:359-392` chat input — **MISSING**. Plain `TextField`, no `@` detection, no autocomplete overlay. `_formatCallChatText` mention-highlighting (calls.js 1457-1472) is also absent (sent text renders raw).
- Gap: No way to mention a participant in call chat; mentions in received messages aren't visually highlighted.
- Fix approach: Add an `OverlayEntry`/`Stack`-positioned autocomplete above the input listening to the controller; on `@token`, filter `call.participants`, render avatar + decorated nym rows, insert on tap. Add mention regex highlighting to the bubble text builder (primary color, w600). Lower priority than F1-F5 but listed high because the PWA chat input behaves noticeably differently.
- Effort: M  Risk: low  Confidence: high

### F7: Reactions bar lacks the "+" / more-emoji picker and recents ordering  [SEVERITY: high]
- PWA: `js/modules/calls.js:1106-1147` — `_callReactionBarEmojis()` builds the bar from **recents-first** padded with 8 defaults (`👍 ❤️ 😂 😮 👏 🎉 🙌 🔥`), dropping unknown custom shortcodes. `_renderCallReactionsBar` appends a `.call-react-more` ＋ button (`openCallReactionPicker`, 1142-1147) that opens the full enhanced emoji picker. Custom emoji render as `<img>`.
- Flutter: `lib/features/calls/call_overlay.dart:258-285 _ReactionsBar` + const `_reactionEmojis` (line 24) — **half-baked**. Hardcoded 8 defaults only, **no recents ordering, no "+" more button, no custom-emoji support**. (Combined with F1, the bar is also entirely non-functional because the picked emoji never animates.)
- Gap: Users can't pick beyond 8 fixed emoji; their recents don't surface; custom pack emoji unavailable.
- Fix approach: Build the bar list from the app's recent-emoji store + defaults (mirror `_callReactionBarEmojis`), append a ＋ tile opening the shared emoji picker, render custom shortcodes as images. Wire the pick through the new fly-reaction path (F1).
- Effort: S  Risk: low  Confidence: high

### F8: In-call chat read receipts + typing indicator decorations missing  [SEVERITY: high]
- PWA: `js/modules/calls.js:1316-1395` — 1:1 calls show a per-message ✓/✓✓ `.call-chat-receipt` (sent/read); group calls show reader avatars (`.call-chat-readers`, long-press → readers modal). Read receipts are sent on chat-open (`_flushCallChatReads` 1329-1335) and per incoming message. Typing: `_onCallChatTyping`/`_renderCallChatTyping` (1264-1303) renders "X is typing" / "X and Y are typing" / "N people are typing" into `.call-chat-typing` (decorated nyms), throttled, respecting privacy prefs (`isTypingIndicatorAllowedFor`, `isReadReceiptAllowedFor`).
- Flutter: `lib/features/calls/call_overlay.dart:349-358` shows a **plain** typing line ("X is typing" / "N people are typing") but bubbles have **no read receipts at all**; `call_service.dart` `markChatRead` only zeros the local unread badge (`:300-305`) and never sends `chat-read`, nor handles incoming `chat-read`/`chat-typing` privacy gating. `CallChatMessage` has no readers/receipt field. The typing nyms are undecorated (no suffix/badges).
- Gap: No "Sent/Read" or reader avatars on call-chat messages; senders never learn their message was read; typing decorations differ.
- Fix approach: Handle `chat-read`/`chat-typing` in `call_service.dart` (respect typing/read-receipt prefs), add `readers`/`deliveryState` to `CallChatMessage`, render ✓/✓✓ (1:1) or reader avatars (group) under self bubbles, and decorate typing nyms. Send reads on panel open + per inbound.
- Effort: M  Risk: med  Confidence: high

### F9: Decorated nyms (suffix, verified/bot/supporter/friend badges, flair) absent in call tiles, chat, title, reactions  [SEVERITY: medium]
- PWA: `js/modules/calls.js:19-36 _callNymHtml` renders base nym + `#suffix` + flair + verified/bot ✓ badge + Supporter badge + friend icon. Used in tile names (846/854), chat from-line (1417), call title (747), fly-reaction "who" (1180), mention items (1900), incoming-call name (870). CSS styles each (`.call-tile-name .nym-suffix/.verified-badge/...` 4894-4897, `.call-chat-from ...` 4886-4889, `.call-react-who ...` 5138-5142).
- Flutter: tiles/chat/title/incoming all show the **plain nym string only** — `call_overlay.dart:227` (`Text(label)`), `:315` ('Chat' literal but from-line not shown per-message at all — see F11), `_Top:114` (plain `peerNym`), `incoming_call.dart:55` (plain `nym`). No suffix, no badges, no flair anywhere in the call UI.
- Gap: A user's `#suffix` and earned badges/flair (which appear everywhere else) vanish inside calls, so identity is ambiguous (two users with the same base nym are indistinguishable).
- Fix approach: Build a shared "decorated nym" widget (likely already exists for channel messages — reuse it) and use it for tile labels, the chat from-line (F11), the title, incoming-call name, mention rows, and fly "who" pills. Pull suffix + badge/flair providers the same way the message list does.
- Effort: M  Risk: low  Confidence: med

### F10: Video-grid breakpoints differ from PWA (column counts + aspect ratio)  [SEVERITY: medium]
- PWA: `css/styles-features.css:4699-4722` — phone widths: count 1–2 → **1 column** (full-width stacked), 3–4 → 2 cols, 5–9 → 3 cols. ≥700px: default 2 cols, count 1–2 → 2 cols capped 1100px centered. Tiles have `min-height:160px`, `border-radius:14px`, video `object-fit:cover`, no-video → 84px avatar; name pill bottom-left `rgba(0,0,0,.55)` radius 8.
- Flutter: `lib/features/calls/call_overlay.dart:160-169 _Grid` — `columns = count<=1?1 : count<=4?2 : 3` and a fixed `childAspectRatio: 3/4`. So a **2-person** call shows 2 side-by-side columns (PWA = 1 full-width column stacked), and the forced 3:4 portrait aspect doesn't match the PWA's flexible `min-height:160px` `align-content:center` rows. Tile radius is 12 (PWA 14), avatar 64 (PWA 84).
- Gap: A 1:1 video call (the common case) lays out as two narrow side-by-side tiles instead of two stacked full-width tiles, and tiles are squished to a fixed portrait ratio.
- Fix approach: Replace `GridView.count` count logic with the PWA mapping (1–2→1 col on narrow, 3–4→2, 5+→3; widen to 2 base on tablet). Prefer a flex/wrap layout with `minHeight 160` + `align center` over a fixed `childAspectRatio`. Bump tile radius→14, avatar→84. Confidence med (responsive breakpoints need device testing, which we can't run).
- Effort: M  Risk: med  Confidence: med

### F11: Call-chat bubble omits the sender name line (and per-sender flair styling)  [SEVERITY: medium]
- PWA: `js/modules/calls.js:1415-1422` every non-self chat row shows a `.call-chat-from` decorated nym line (clickable → user menu), and the row carries the sender's purchased message-flair classes (style-matrix/neon/fire/.../supporter/aura — calls.js 1409-1414, CSS 4901-4954). Self rows render "You" in dim.
- Flutter: `lib/features/calls/call_overlay.dart:330-345` — bubbles show **text only**, no sender name, no flair styling, and the nym isn't tappable. In a group call you cannot tell who said what.
- Gap: Group call chat is unreadable (no author labels); cosmetic flair (a paid feature) doesn't apply.
- Fix approach: Add a from-line (decorated nym, F9) above non-self bubble text; make it tap → user menu. Optionally map the flair style classes to text styling (lower priority).
- Effort: S  Risk: low  Confidence: high

### F12: Switch-camera button always shown; not gated on multi-camera availability  [SEVERITY: medium]
- PWA: `js/modules/calls.js:714-727 _updateCameraSwitchBtn` enumerates devices and **hides** the switch-cam button unless `videoinput > 1`. Disabled while sharing or mid-switch (`_updateCallControls` 1751-1755), with a directional tooltip ("Switch to front/rear camera").
- Flutter: `lib/features/calls/call_overlay.dart:451-456` shows the switch-cam `_CtrlBtn` whenever `isVideo && !sharing`, with a generic "Switch camera" tooltip — **no device-count gating, no disabled-during-switch state, no directional tooltip**. On a single-camera device the button is a dead control.
- Gap: Desktop/single-camera users see a non-functional switch button; no disabled feedback while switching.
- Fix approach: Query `navigator.mediaDevices.enumerateDevices` equivalent (`Helper.enumerateDevices`/`MediaDevices`) and hide when ≤1 videoinput; disable during `switchingCamera`; set directional tooltip from `facingMode`.
- Effort: S  Risk: low  Confidence: high

### F13: P2P transfer card lacks transfer speed + "Downloaded/Retry" terminal affordances  [SEVERITY: medium]
- PWA: `js/modules/p2p.js:608-622 updateFileOfferProgress` shows `pct% • <speed>/s`; `updateTransferStatus` (625-648) flips the in-card button to **"Downloaded"** (complete) or **"Retry"** (error, re-arms `requestP2PFile`). The transfers-modal rows (`p2p.js:752-790`) show status text colored by state and a Cancel/Stop button.
- Flutter: `lib/features/p2p/p2p_transfers_modal.dart:143-196 _TransferRow` shows `pct% • <statusText>` but **no transfer speed**, and the modal has **no Retry on error** and **no Downloaded affordance** (just hides Cancel when complete). `P2PTransfer` (`p2p_models.dart:138-169`) tracks bytes but no rolling speed. (The bigger miss — the in-message card with these states — is F2.)
- Gap: Users don't see transfer speed and can't retry a failed transfer from the modal.
- Fix approach: Track a rolling bytes/sec on `P2PTransfer`; render `pct% • speed/s`. Add a Retry button (→ `requestFile`) when `status == error`, and a "Downloaded" label when complete. Mirror the colored status text.
- Effort: S  Risk: low  Confidence: high

### F14: No in-app notification surface (bell badge + notification-history modal)  [SEVERITY: high]
- PWA: `js/modules/notifications.js:5-114 showNotification` pushes into `notificationHistory`, updates a badge (`_updateNotificationBadge`), refreshes a notifications modal (`_refreshNotificationsModalIfOpen`), and fires a browser `Notification` with click-routing (open PM/group/channel/reaction source). Missed calls are recorded into the same history (`calls.js:287-308 _recordMissedCall`, type `'call'`).
- Flutter: `lib/features/notifications/notifications_service.dart` is **sound + OS local-notification only** (`notify()` → `NotificationService.showNotification`). There is **no notification-history list, no unread bell badge, no in-app notifications modal** anywhere in `lib/` (grep for `Notification(Modal|Panel|List|History|Badge)` → 0). Missed/declined calls have nowhere to land (compounds F5).
- Gap: The app cannot show the user a list of recent notifications, an unread count, or a missed-call entry — a whole surface present in the PWA is absent.
- Fix approach: Port a `NotificationHistory` store (24h-trimmed list, dedup, viewed flag) + a bell-with-badge in the shell + a notifications modal/sheet listing entries with avatar/title/body/timestamp and tap-routing. Feed both message notifications and missed-calls (F5/F15) into it. Larger scope — confirm whether another slice owns the shell bell before implementing.
- Effort: L  Risk: med  Confidence: med

### F15: Missed-call notification + 45s ring-timeout surfacing not implemented  [SEVERITY: medium]
- PWA: `js/modules/calls.js:368-378` rings 45s then auto-marks missed, shows "Missed call from X", and records it to history (`_recordMissedCall`). Outgoing side rings 45s then "No answer" + ends (`startCall` 127-133). `_onCallCancel` (467-479) → missed. Stale invites (>60s old) are logged as missed on reopen (310-331).
- Flutter: `lib/features/calls/call_service.dart` — the 45s ring `Timer` **does exist** (outgoing `:357-365`, incoming `:478-483`), but both callbacks are silent: outgoing sends cancel + `_endCall()` with **no "No answer" toast**; incoming just clears `_incoming` + `_publishIdle()` with **no "Missed call from X" toast and no missed-call history entry**. `_onCancel` (`:514`) likewise doesn't record a miss. No missed-call history surface exists (F14).
- Gap: An unanswered/declined/cancelled call ends silently with no trace and no toast; the user never learns they missed a call. (The timer fires correctly — only the user-facing surfacing is missing.)
- Fix approach: On ring timeout / cancel / decline, emit the status toast (F5) and push a missed-call entry into the notification history (F14). Mirror calls.js seen-call ranking if porting the dedup, else a simpler entry.
- Effort: M  Risk: low  Confidence: med

### F16: In-chat system/action messages ("system-message"/"action-message") not rendered  [SEVERITY: medium]
- PWA: `js/modules/messages.js:1511-1529 displaySystemMessage(content,type)` appends a `.system-message` or `.action-message` div into the message list (optionally HTML). This is the sink for call status (F5), P2P status ("File offered for P2P download", "Stopped seeding…", "Cannot download your own file"), and dozens of app events.
- Flutter: `lib/widgets/chat/composer.dart:464` calls `_onSystemMessage('File offered for P2P download.')` and `p2p_service.dart:78 onSystemMessage` exists — but there is **no `.system-message`/`.action-message` bubble style in `message_row.dart`** (grep: message_row has no system/action branch). Where these sink to (SnackBar? dropped?) is unverified, but the distinct centered grey system-bubble styling of the PWA is not present.
- Gap: System/action notices (including all P2P + call statuses once F5 lands) either vanish or render as normal messages, losing the PWA's centered muted styling.
- Fix approach: Add a system/action message variant to `message_row.dart` (centered, muted, smaller) and route `onSystemMessage` sinks (P2P + new call sink) to inject such rows. Confirm the existing `_onSystemMessage` target.
- Effort: M  Risk: med  Confidence: med  (Note: chat message rendering may be another slice's primary area — flag overlap.)

### F17: Incoming-call avatar lacks the pulsing ring animation; uses a static border  [SEVERITY: low]
- PWA: `css/styles-features.css:4542-4554` — `.incoming-call-avatar` has `@keyframes incomingCallPulse` (1.6s infinite expanding box-shadow ring from the primary color, `0 → 12px` spread). Decline button SVG is rotated 135° (`:4593`). Buttons 58px, gap 36px, accept=primary/bg, decline=danger.
- Flutter: `lib/features/calls/incoming_call.dart:46-53` — a **static** 2px primary ring (`Border.all`), **no pulse animation**. Buttons are 64px (PWA 58px) with `spaceEvenly` (PWA fixed 36px gap), and use generic phone icons (accept = `Icons.call` green `0xFF22C55E`; PWA accent is `var(--primary)` cyan, not green).
- Gap: The incoming call avatar doesn't pulse, button sizing/spacing/color differ slightly from the PWA (decline color OK; accept tint differs — PWA uses primary, Flutter uses a hardcoded green).
- Fix approach: Wrap the avatar in a repeating `AnimatedBuilder`/`TweenAnimationBuilder` pulsing a `BoxShadow` spread 0→12 over 1.6s. Set accept button to `c.primary` with `c.bg` foreground (PWA), size 58, fixed 36 gap.
- Effort: S  Risk: low  Confidence: high

### F18: Call title is plain text — missing avatar(s), group avatar stack, "kind ·" styling  [SEVERITY: low]
- PWA: `js/modules/calls.js:729-748 _callTitleHtml` renders `"Video call ·"` (dim `.call-title-kind`) + peer avatar (22px) + decorated nym for 1:1; for groups a group icon + up-to-4 member avatars + group name (`.group-header-row`). CSS 4633-4691.
- Flutter: `lib/features/calls/call_overlay.dart:113-125 _Top` — a single `Text('$kindLabel · $title')`, **no avatar, no group avatar stack, no decorated nym**; group title is the literal "Group call" (line 114) even when the group has a name, because `call.groupId` isn't resolved to a group name.
- Gap: The call header is a bare string; group calls don't show the group name/avatars; 1:1 doesn't show the peer avatar.
- Fix approach: Build a title row with the peer avatar (22) + decorated nym (F9), or a group icon + member-avatar stack + group name (resolve `groupId` → group). Style the "kind ·" prefix dim.
- Effort: S  Risk: low  Confidence: high

---

## Incidental (logic, noted but out of UI scope)

### I1: Incoming call reactions dropped at the service layer
`lib/features/calls/call_service.dart:407-408` — `case 'reaction':` is a deliberate no-op (`surfaced via state if desired`). This is the root cause of F1's receive half; fixing F1 requires touching this signal handler, not just the widget.

### I2: Call-chat read receipts never sent
`lib/features/calls/call_service.dart:300-305 markChatRead` only clears the local unread counter; it never broadcasts `chat-read`, so even if peers implement receipts, this client appears to never read. Root cause of F8's send half.
