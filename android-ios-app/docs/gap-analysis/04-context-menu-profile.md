# Gap report 04 — Context menu + profile card + reaction picker/burst/quick-react

**Slice:** the right-side `#contextMenu` slide-in panel (action set + the profile-card header it renders: avatar, nym, status, bio, banner, owner/mod/verified/friend labels, full pubkey + copy) and the reaction surfaces (enhanced picker grid, quick-react pill, quick-context-menu, burst animation, reactors modal).

**Summary:** The action *list* (set/order/labels/gates) and the burst/reactors-modal are faithful ports (prior audit 05 fixed the action set). The big user-visible gaps are all in the **profile-card header** — Flutter renders only avatar-identicon + nym + full-pubkey + Copy, omitting the PWA's **banner image, online/away/offline status row, bio, "Nymchat Developer/Bot" label, "Group Owner/Moderator" label, verified checkmark badge, and friend badge**, and it never loads the real avatar image (always identicon). Two actions are **no-ops** (Gift Nymbot Credits, Edit Profile — deferral D2) and one is **half-baked** (Report submit never publishes). The long-press surface is missing the PWA's **inline quick-context-menu** (labeled Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete with icons) and the **long-press dim/highlight** focus effect; quick-react also never sources recents. Action rows have **no leading icons** (PWA every row has an SVG). Several visual mismatches in the panel chrome (no banner overlap, copy/pubkey colors).

**Finding count:** 14 (1 blocker, 5 high, 5 medium, 3 low). Plus 1 incidental.

Severity order below.

---

### F1: Context-menu profile header is missing status row, bio, banner, owner/mod/verified/friend labels (audit D3)  [SEVERITY: high]
- PWA: `ui-context.js:375-464, 656-661` + markup `index.html:74-91`. The header renders, top to bottom: a **banner image** (`#ctxBannerImg`, `getBannerUrl(pubkey)`, shown only if present, adds `.has-banner`), avatar, the nym row, a **status row** (`#ctxStatusRow`: a `.user-status-dot.status-{online|away|offline}` + "Online"/"Away"/"Offline" label from `getEffectiveUserStatus`, hidden when status is `hidden`), the full pubkey + Copy, then a **bio** block (`#ctxBio` = `getBio(pubkey)`, `:empty` collapses). The nym row also appends, conditionally: a `.context-menu-dev-label` "Nymchat Developer" (`isVerifiedDeveloper`) or "Nymchat Bot" (`isVerifiedBot`); a `.context-menu-owner-label` "Group Owner"/"Moderator" when viewing the user's group (`ui-context.js:422-429`); plus inline `verified-badge` (✓) and `friend-badge` (people-icon) glyphs (`ui-context.js:407-414`).
- Flutter: `lib/widgets/context_menu/context_menu_panel.dart:196-277` (`_header`) — renders ONLY `NymAvatar` + nym `Text` + `CosmeticNymBadges` (flair/supporter only) + full-pubkey container + Copy Pubkey row. No banner, no status row, no bio, no dev/bot label, no owner/mod label, no verified ✓, no friend badge.
- Gap: A user opening another user's profile in the Flutter app sees a near-empty card (identicon + name + hex) where the PWA shows a rich profile: banner art, presence dot + word, bio text, role/verification labels. This is the most visible single-screen regression in the slice. **The data is already available** — `User.effectiveStatus()`, `UserProfile.about` (bio), `UserProfile.banner`, `User.awayMessage` all exist (`lib/models/user.dart:55-63, 82-84`), and a reusable `StatusDot` widget with PWA-exact colors (#22C55E/#EAB308/#6B7280) exists at `lib/widgets/common/nym_avatar.dart:119-135` / `statusColor` `:27-37`.
- Fix approach: In `_header`, read the target `User` from `ref.watch(usersProvider)[target.pubkey]` (Map<String,User>, `app_state.dart:1735`). Add, in PWA order:
  1. **Banner** above the avatar: if `user?.profile?.banner` non-empty, a 140px-tall `CachedNetworkImage` (`width:double.infinity, height:140, fit:BoxFit.cover`, via `proxiedAvatarUrl`); when present, overlap the avatar by `margin-top:-36px` and give the avatar a 3px `rgba(20,20,35,0.95)` border (CSS `.has-banner` at styles-features.css:3080-3088).
  2. **Status row** under the nym: `if (status != hidden && !statusHidden)` a centered `Row` (gap 6) of `StatusDot(status, size:8)` + `Text('Online'/'Away'/'Offline')` — fontSize 12, color textDim (`.ctx-status-row` styles-features.css:2375-2388).
  3. **Bio** below the pubkey/Copy block, inside the header's bottom border: `if (about?.isNotEmpty)` `Padding(8,8,16,12)` `Text(about, fontSize:13, color:textDim, height:1.5)` (`.context-menu-bio` styles-features.css:3090-3102).
  4. **Dev/Bot label**: needs `isVerifiedBot`/`isVerifiedDeveloper` — see F4 (only `NostrController.nymbotPubkey` const exists today). Render a `.context-menu-dev-label` (fontSize 10, w500, textDim, letterSpacing 0.5) "Nymchat Developer"/"Nymchat Bot".
  5. **Owner/Mod label**: when `target.inGroup`, derive from the group (`group.createdBy == pubkey` → "Group Owner", `group.mods.contains(pubkey)` → "Moderator"); `_enrichTarget` already computes `targetIsOwner`/`targetIsMod` — thread them onto `CtxTarget` (already there) and render `.context-menu-owner-label` (fontSize 10, w500, secondary, opacity 0.8, letterSpacing 0.5).
  6. **Verified ✓ + friend badge** in the nym row — see F4/F5.
- Effort: L  Risk: med  Confidence: high

---

### F2: Report action never publishes — Submit is a no-op  [SEVERITY: high]
- PWA: `ui-context.js:312-352` (`submitReport`) builds and SIGNS a NIP-56 kind-1984 event (`tags:[['p',pubkey,type]]`, plus `['e',messageId,type]` when "report specific message" is checked) and `sendToRelay(["EVENT", signedEvent])`, then "Report submitted successfully". The report modal is the action's entire purpose.
- Flutter: `lib/widgets/context_menu/report_modal.dart:174-183` — `onSubmit?.call(...)` then closes. But the caller `ContextMenuPanel._invoke` at `context_menu_panel.dart:356-364` invokes `ReportModal.show(context, targetNym:…, hasMessage:…)` with **no `onSubmit`**, so submitting the form does nothing at all (just dismisses).
- Gap: A user fills out a report and taps "Submit Report"; nothing is published — the report is silently dropped. High-impact because the modal *looks* fully functional.
- Fix approach: Add a `reportUser`/`submitReport` method on `NostrController` that builds + signs + publishes the kind-1984 event (mirroring `submitReport`), then pass `onSubmit: (type, details, reportMessage) => controller.submitReport(pubkey: t.pubkey, messageId: reportMessage ? t.messageId : null, type: type, details: details)` from `_invoke`. The signing/relay path lives in the controller (out of this widget slice), so the fix straddles two slices — flag for the controller owner. Until then the modal is misleading.
- Effort: M  Risk: med  Confidence: high

---

### F3: Long-press has no inline quick-context-menu (Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete)  [SEVERITY: high]
- PWA: `ui-context.js:1349-1516`. On long-press (500ms) of a message, BELOW the 6-emoji quick-react pill the PWA also pops a separate `.quick-context-menu` — a vertical card (`min-width:200px`, radius 14, `rgba(20,20,35,0.92)`) of labeled rows with icons: **Slap with Trout, Give warm Hug** (other users), **Zap Bitcoin** (`.lightning` orange #f7931a, other-user + has msg), **Quote Message, Copy Message, Translate Message** (any msg with content), **Edit Message** (own + content), **Delete Message** (`.danger`, own). Each row is `.quick-context-item` (icon + `<span>label</span>`, 8/12 padding, gap 10, fontSize 14). It animates in with `scale(0.9) translateY(-6px)→1` over 150ms.
- Flutter: `lib/features/reactions/quick_react_popup.dart:66-74` + `lib/widgets/chat/message_row.dart:406-418`. The Flutter quick-react pill has only the 6 emojis + a "more" chevron + a single `more_vert` icon that, for non-own messages, opens the FULL `ContextMenuPanel`. There is **no inline quick-context-menu** card. For own messages `onMenu` is null (`message_row.dart:416`), so a user long-pressing their OWN message gets only the emoji pill — no Edit/Delete/Quote/Copy fast path at all.
- Gap: The PWA's fast long-press action surface (the primary mobile interaction for quote/copy/edit/delete/slap/hug) is absent. Flutter substitutes the heavyweight full panel and only for other users. Own-message long-press loses Edit/Delete entirely from the quick path.
- Fix approach: Add a `QuickContextMenu` widget (vertical card, the CSS values above) rendered below `QuickReactPopup` in the same overlay (`showQuickReactPopup`), built from a list mirroring `ui-context.js:1358-1450` gates. Reuse the existing action dispatch in `ContextMenuPanel._invoke` (extract the per-`CtxAction` handlers, or have items call `controller.sendCurrent('/me …')` for slap/hug, the quote/copy hooks for quote/copy, etc.). Position: centered on press point, `top + popupHeight + 8`, flip above if it would overflow. Icons: use the same Material icons already chosen for the panel (see F8). Pass it for own messages too (gate Edit/Delete on `isOwn`).
- Effort: L  Risk: med  Confidence: high

---

### F4: Verified-developer / verified-bot checkmark + "Nymchat Developer/Bot" label absent everywhere; no detection in state  [SEVERITY: high]
- PWA: `ui-context.js:407-411` renders a `verified-badge` (✓ on a #1DA1F2 circle, styles-components.css:1382-1411) after the nym for `isVerifiedDeveloper(pubkey)` (title from `this.verifiedDeveloper.title`) or `isVerifiedBot(pubkey)` ("Nymchat Bot"); `ui-context.js:416-420` adds the `.context-menu-dev-label` text line.
- Flutter: No `isVerifiedDeveloper`/`isVerifiedBot` anywhere — only a single hardcoded `NostrController.nymbotPubkey` const (`nostr_controller.dart:2527`). `CosmeticNymBadges` (`features/shop/cosmetics.dart:95+`) renders flair + supporter only, no verified ✓. So the blue verified checkmark and the dev/bot label are missing from the context-menu header **and** anywhere else nyms render.
- Gap: Verified bot/developer identity is never signalled to the user — a user can't tell the official Nymbot from an impersonator in the profile card. (Impersonation is even a report category — F2.)
- Fix approach: Add `bool isVerifiedBot(String pubkey)` (compare against `nymbotPubkey`) and `isVerifiedDeveloper` (needs the verified-developer pubkey set — check whether the spec/app.js defines `verifiedDeveloper.pubkey`; if not in scope, wire bot-only first) to `NostrController`/app_state. Add a `VerifiedBadge` widget (20×20, #1DA1F2 circle, white ✓ 12px — CSS values) and render it in the nym row in `_header` and ideally in `CosmeticNymBadges`. Then the dev/bot text label in F1.
- Effort: M  Risk: med  Confidence: med (verified-developer pubkey source may be owned by another slice — bot detection is straightforward via the existing const)

---

### F5: Context-menu header always shows identicon, never the real avatar; no friend badge  [SEVERITY: high]
- PWA: `ui-context.js:397-401` sets `ctxAvatarImg.src = getAvatarUrl(pubkey)` (real uploaded avatar, identicon only as `onerror` fallback). `ui-context.js:412-414` appends a `friend-badge` (people+check SVG, #4fc3f7, styles-features.css:1483-1495) when `pubkey !== self && isFriend(pubkey)`.
- Flutter: `context_menu_panel.dart:211` — `NymAvatar(seed: target.pubkey, size: 64)` is called **without `imageUrl`**, so it always renders the generated identicon (`nym_avatar.dart:62-81` returns the fallback when `imageUrl` is null). No friend badge in the nym row (`CtxTarget.isFriend` is computed in `_enrichTarget:113` but only used for the Add/Remove-Friend label, never for a header badge).
- Gap: The profile card never shows the user's actual avatar photo — only a colored letter tile — even when a kind-0 picture exists. And there's no friend indicator in the card.
- Fix approach: Pass `imageUrl: ref.watch(usersProvider)[target.pubkey]?.profile?.picture` to the `NymAvatar` in `_header` (NymAvatar already proxies + caches + falls back). Add a friend badge glyph (people+check, #4fc3f7, ~12-16px) in the nym `Row` when `target.isFriend && !target.isSelf`.
- Effort: S  Risk: low  Confidence: high

---

### F6: "Gift Nymbot Credits" and "Edit Profile" actions are no-ops (audit D2)  [SEVERITY: medium]
- PWA: `ui-context.js:102-108` Gift Credits → `showBotCreditsModal({pubkey, nym})`; `ui-context.js:587-594` Edit Profile → `editNick()`.
- Flutter: `context_menu_panel.dart:400-411` — both cases call only `onClose()` (explicitly documented as deferral D2). The rows appear in the list (set/order/label/gate correct) but tapping them just closes the menu silently.
- Gap: Two actions look live but do nothing — a user taps "Edit Profile" on their own message and the menu just dismisses. Classic half-baked.
- Fix approach: Wire `editProfile` → the profile-editor entry point (the editNick/profile modal owned by the identity/settings slice — see audit 07) and `giftCredits` → the bot-credits modal (shop/zaps slice). Both need a controller/route method from another slice; coordinate. If the editor route already exists, this is a one-line dispatch each.
- Effort: M (cross-slice)  Risk: low  Confidence: high

---

### F7: Quick-react never sources recent emojis (always the 6 defaults)  [SEVERITY: medium]
- PWA: `ui-context.js:1281-1297` builds the 6 quick emojis as **recents-first** (`this.recentEmojis.slice(0,6)`), padding with defaults `['👍','❤️','😂','🔥','👎','😮']` only to fill. After a reaction it calls `addToRecentEmojis(emoji)` (`:1552, :1564`).
- Flutter: `message_row.dart:413` calls `quickReactEmojis(const [])` — always passes an EMPTY recents list, so the pill is permanently the 6 hardcoded defaults. `_quickReact` (`message_row.dart:420-434`) never records the chosen emoji to recents either. The helper `quickReactEmojis` (`quick_react_popup.dart:12-23`) is correct; it's just fed nothing.
- Gap: The quick-react row never personalizes; a user's most-used reactions never surface, unlike the PWA. **The same bug hits the full reaction picker** — `messages_list.dart:81` calls `showReactionPicker(context, ref, msg)` with no `recents`, so `reaction_picker.dart:24` uses its `recents = const []` default and the picker's "Recently Used" section never appears. (Note the doc comment at `quick_react_popup.dart:5` cites `calls.js:1491` for the defaults; the message long-press path is actually `ui-context.js:1282` — same list, harmless mis-citation.)
- Fix approach: The recents store already exists — `RecentEmojis` (`lib/features/emoji/emoji_data.dart:350-380`, `loadRecentEmojis`/`addToRecentEmojis`, key `nym_recent_emojis`, ≤24, most-recent-first) — it's just not wired in. Expose it via a provider (or read the existing store), thread it into BOTH `quickReactEmojis(...)` at `message_row.dart:413` AND `showReactionPicker(..., recents: …)` at `messages_list.dart:81`, and call `addToRecentEmojis(emoji)` after a successful toggle in `_quickReact` (`message_row.dart:420-434`) and in the picker's `onSelect` (`reaction_picker.dart:42-62`, which currently never records the pick).
- Effort: S  Risk: low  Confidence: high

---

### F8: Context-menu action rows have no leading icons  [SEVERITY: medium]
- PWA: Every `#contextMenu` item carries a leading 16×16 SVG (`index.html:94-266`): React (smiley), Mention (@), PM (envelope), Slap (fish), Hug (two heads), Create Group (person+), Zap (bolt), Gift Credits (gift), Quote, Copy, Translate (文/A), Friend (person+/person✓), Report (!), Edit (pencil), Delete (trash), mod-star, transfer, kick, ban, Block (∅), Edit Profile (person). The injected Slap/Hug items also carry their SVGs (`ui-context.js:504, 524`).
- Flutter: `context_menu_panel.dart:153-158, 641-648` (`_ActionItem`) renders **label text only** — no icon column. `ctxActionLabel` returns just strings.
- Gap: The action list reads as a plain text list vs the PWA's icon+label rows — a noticeable visual/affordance downgrade (icons aid scanning, especially for the danger/lightning rows).
- Fix approach: Add an `IconData ctxActionIcon(CtxAction)` map and prepend an `Icon(icon, size:16)` (colored via the existing `_colorFor`, dimmed/textDim for neutral rows) with an 8-10px gap in `_ActionItem`. Material equivalents: React `sentiment_satisfied`, Mention `alternate_email`, PM `mail_outline`, Slap `set_meal`/custom fish, Hug `favorite_border`, Create Group `group_add`, Zap `bolt`, Gift `card_giftcard`, Quote `format_quote`, Copy `content_copy`, Translate `translate`, Friend `person_add`/`how_to_reg`, Report `error_outline`, Edit `edit`, Delete `delete_outline`, mod `star_outline`, transfer `swap_horiz`, kick `person_remove`, ban `block`, Block `block`, Edit Profile `manage_accounts`. Reuse the same icons for F3's quick-context-menu.
- Effort: M  Risk: low  Confidence: high

---

### F9: No long-press dim/highlight focus effect on the pressed message  [SEVERITY: medium]
- PWA: `ui-context.js:1302-1307` + CSS styles-features.css:2848-2874. On long-press, the whole list gets `.has-long-press-highlight` which fades all other messages to `opacity:0.35; filter:blur(0.5px)` (150ms) and lifts the pressed `.long-press-highlight` message to `opacity:1; filter:none; z-index:1` (plus the group avatar). Cleared on close (`cleanupHighlight`).
- Flutter: `showQuickReactPopup` (`quick_react_popup.dart:95-153`) inserts an overlay with only a transparent dismiss scrim (`Positioned.fill` GestureDetector) — no dimming/blur of the underlying list, no highlight of the pressed message.
- Gap: The PWA's "spotlight" focus on the long-pressed message is missing; the popup floats over an un-dimmed list, weakening the modal feel and making the anchor ambiguous.
- Fix approach: In `showQuickReactPopup`, replace the transparent scrim with a dim layer (e.g. `Container(color: Colors.black.withOpacity(0.35))` or a backdrop blur `BackdropFilter(sigmaX/Y:0.5)`), and optionally re-draw the pressed message above it (harder — needs the message's painted bounds; at minimum dim the rest). Animate in over 150ms.
- Effort: M  Risk: med  Confidence: med (re-rendering the lifted message above the scrim is non-trivial; the dim alone is easy and covers most of the effect)

---

### F10: Enhanced reaction picker presented as a centered dialog, not anchored to the trigger  [SEVERITY: low]
- PWA: `reactions.js:812-853` (`showEnhancedReactionPicker`) anchors the picker to the trigger button: desktop computes top/bottom + left/right from the button rect (open below if `spaceBelow>450`, else above; right-align if button past mid-screen), `max-height:400px`. Mobile (`<=768`) centers it (`top/left:50%; translate(-50%,-50%); max-height:80vh`).
- Flutter: `lib/features/reactions/reaction_picker.dart:20-67` always presents a centered `showDialog` (`Center`, maxWidth 360, maxHeight 420). The doc comment acknowledges "natively we present it centred (mirroring the PWA's mobile branch)."
- Gap: On a wide/desktop window the picker pops dead-center instead of next to the message's add-reaction button, unlike the PWA desktop behavior. Acceptable on phones; off on tablet/desktop.
- Fix approach: Accept the trigger's global `Rect` and, when width > 768, present via `OverlayEntry`/`showMenu`-style positioning (below-or-above + left/right clamp) like the PWA; keep centered for narrow. Lower priority since the app targets mobile first.
- Effort: M  Risk: low  Confidence: med

---

### F11: Panel scrim/animation timing minor mismatches  [SEVERITY: low]
- PWA: `.context-menu` slides `translateX(100%)→0` over **0.15s linear** with `box-shadow:-4px 0 24px rgba(0,0,0,0.4)` when active (styles-shell.css:611-634); overlay `rgba(0,0,0,0.6)` fades over **0.25s ease** (styles-shell.css:636-652). Width 320, `max-width:85vw`.
- Flutter: `context_menu_panel.dart:67-90` — `showGeneralDialog` with `transitionDuration:150ms`, `barrierColor:0x99000000` (=rgba 0,0,0,0.6 ✓), slide `Curves.linear` ✓, width fixed `320` (no `85vw` clamp — on a <377px-wide phone the panel could exceed 85vw). No active box-shadow on the panel; barrier uses the dialog's default fade (≈150ms, not 250ms). The left border is present (`:179`).
- Gap: Minor — barrier fade is ~100ms faster than the PWA; panel lacks the `-4px 0 24px` drop shadow (subtle edge separation); width not clamped to 85vw on very narrow screens.
- Fix approach: Add `boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius:24, offset:Offset(-4,0))]` to the panel container; clamp `width: min(320, screenWidth*0.85)`. Barrier fade timing is cosmetic; leave unless pixel-matching.
- Effort: S  Risk: low  Confidence: high

---

### F12: Copy Pubkey / full-pubkey block — missing system-message confirmation, hover, selectable text  [SEVERITY: low]
- PWA: `ui-context.js:217-229` — on Copy, `displaySystemMessage('Copied pubkey to clipboard')` (user feedback) and closes the menu. The `.context-menu-copy-pubkey` has a hover state (bg→`rgba(255,255,255,0.08)`, color→primary; styles-features.css:2707-2710). The `.ctx-full-pubkey` block is `user-select:all` (tap-to-select-all) and centered mono (styles-features.css:2683-2698).
- Flutter: `context_menu_panel.dart:256-273` — Copy writes to clipboard but shows **no confirmation** and does NOT close the menu (`onTap` just sets clipboard). No hover state (plain InkWell). The pubkey `Text` (`:245-254`) is not selectable. (Visual: bg `rgba(255,255,255,0.04)`, border `0.08`, radius 6, mono 11 — matches; missing `height:1.35`? actually present `:252`.)
- Gap: Tapping Copy gives no feedback and leaves the menu open (PWA closes + toasts); the hex can't be tap-selected. Minor but the silent copy is a small UX regression.
- Fix approach: In the Copy `onTap`, after `Clipboard.setData`, show a confirmation (the app's system-message/snackbar equivalent) and call `onClose()`. Wrap the pubkey `Text` in `SelectableText` (or `SelectionArea`). Add a hover tint (MouseRegion) on the copy row.
- Effort: S  Risk: low  Confidence: high

---

### F13: Quick-react pill emoji size + active/hover micro-interactions off  [SEVERITY: low]
- PWA: `.quick-react-emoji` font-size **28px**, padding 4/6, radius 8, hover `scale(1.3)`, active `scale(0.95)` (styles-features.css:2731-2756); the "more" affordance is `.quick-react-expand` — a chevron with a **left divider** (`border-left:1px solid rgba(255,255,255,0.1)`), text-dim→primary on hover (styles-features.css:2758-2776). Pill gap 4, padding 6/8, radius 24, `rgba(20,20,35,0.92)`, animates `scale(0.8) translateY(8px)→1` over 150ms.
- Flutter: `quick_react_popup.dart:64` emoji `fontSize: 22` (PWA 28); buttons have no hover-scale/active-scale; the "more" chevron has no left divider (`_btn` is a plain padded InkWell). The pill bg `0xEB141423` (=rgba 20,20,35,0.92 ✓), padding 8/6 (PWA 8/6 ✓), radius 24 ✓, shadow ✓ — but the **enter animation is missing** (overlay inserts at full opacity/scale; PWA scales+rises in).
- Gap: Emojis render ~21% smaller; no tactile hover/press feedback; the "more" button isn't visually separated; the popup snaps in instead of the PWA's scale/rise. Subtle but noticeable next to the PWA.
- Fix approach: Bump emoji `fontSize` to 28; add a 1px left `Border` divider before the chevron button; wrap the popup in a 150ms `ScaleTransition`+`SlideTransition` (from `scale 0.8 / +8px`). Optional hover/press scale on emoji buttons.
- Effort: S  Risk: low  Confidence: high

---

### F14: Back button (group→user return) absent in Flutter context menu  [SEVERITY: low]
- PWA: `index.html:70-72` + `ui-context.js:369-373`. When `showContextMenu` is opened from a group member list (`backToGroupId`), a `.context-menu-back` chevron button (top-left, styles-features.css:5393-5411) shows to return to the group context menu; hidden for all other entry points.
- Flutter: `context_menu_panel.dart` renders only the close button (`:184-188, 279-294`). No back button; `CtxTarget` has no `backToGroupId`, and `ContextMenuPanel.show` has no group-return parameter.
- Gap: The group-member→profile→back navigation affordance is missing. Low impact (only reachable from the group context menu, which itself — `#groupContextMenu` — is a separate panel likely owned by the groups slice).
- Fix approach: Add an optional `onBack`/`backToGroupId` to `ContextMenuPanel.show`; when set, render a top-left chevron (`Icons.chevron_left`, 18px) that pops the panel and re-opens the group menu. Defer until the group context menu exists in Flutter.
- Effort: S  Risk: low  Confidence: med (depends on group-context-menu slice)

---

## Incidental (logic-adjacent, note only)

- **I1 — Translate language not persisted (already self-flagged):** `context_menu_panel.dart:568-581` (`_translate`) acknowledges that when `settings.translateLanguage` is empty it prompts but does NOT save the chosen language to settings (PWA `translate.js` persists it). Settings persistence is another slice; the inline render still works. Not a UI gap per se.
- **I2 — `inGroup` over-eager for AddToGroup gate:** `ctxTargetForMessage` (`context_menu_actions.dart:238`) sets `inGroup = message.isGroup || message.groupId != null` from the message, but `_enrichTarget` (`context_menu_panel.dart:99`) recomputes `inGroup` from the active VIEW (`view.kind == group`). The enriched value wins in the panel, so the AddToGroup/owner-mod gates are correct there; the message-derived value only matters if `buildContextMenuActions` is ever called without enrichment (e.g. quick-context-menu F3). Keep them consistent when wiring F3.

## Faithful ports (verified, no change needed)
- **Action set / order / labels / visibility gates** — `buildContextMenuActions` + `ctxActionLabel` (`context_menu_actions.dart:84-218`) match `ui-context.js showContextMenu` runtime order (React→Mention→PM→Slap→Hug→AddToGroup→Zap→GiftCredits→Quote→Copy→Translate→Friend→Report→Edit→Delete→mod items→Block→EditProfile) and profile-only subset (prior audit 05 #7-13 fixed these). Slap/Hug dispatch via `sendCurrent('/me …')` shares the rate limiter ✔.
- **Reaction burst** — `reaction_burst.dart` mirrors `_playReactionBurst` + `@keyframes reactionBurst`(0.85s)/`reactionSpark`(0.7s): 10 sparks, angle/dist math identical, emoji scale 0→1.5→1.15→0.5, y 0→-20%→-130%, 45px glyph, spark radial-gradient #ffd86b→#ff7b1f→transparent, ~900ms lifetime ✔ (the rotate component of the keyframe is dropped — imperceptible).
- **Reactors modal** — `reactors_modal.dart` matches `showReactorsModal` (40px emoji header + count, 50-row cap + "+N more", row = avatar+nym+`#suffix`(0.5 alpha)+"you", anchored above badge, outside-tap dismiss) ✔.
- **Report modal form** — type options (7, PWA order), details textarea, "report specific message" checkbox gated on `hasMessage` — all match `index.html`/`openReportModal`; only the SUBMIT is unwired (F2).
- **Action-item base style** — `.context-menu-item` 10/14 padding, radius xs, fontSize 13, hover `rgba(255,255,255,0.08)`, danger/lightning/warning colors via `_colorFor` ✔ (missing only the leading icon, F8).
- **Container chrome** — width 320, `bgTertiary`, left glass border, close button (32px circle, white/0.05 bg, glass border, ✕) ✔ (minor shadow/width-clamp nits in F11).
