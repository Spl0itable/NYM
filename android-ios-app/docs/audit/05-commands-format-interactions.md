# Audit 05 — Commands, Autocomplete, Message Formatting & Chat-Row/Composer/Context-Menu UI

1:1 fidelity audit of the Flutter clone against the Nymchat PWA for this slice.
Authoritative PWA sources: `../js/modules/commands.js`, `../js/modules/autocomplete.js`,
`../js/modules/message-format.js`, `../js/modules/ui-context.js`, `../index.html`,
`../css/styles-chat.css`, `../css/styles-features.css`.

Owned Flutter files: `lib/features/commands/**`, `lib/features/autocomplete/**`,
`lib/features/messages/format/**`, `lib/widgets/chat/message_row.dart`,
`lib/widgets/chat/composer.dart`, `lib/widgets/context_menu/**`, plus
`test/{commands,format,interactions,web_proxy}_test.dart`.

## Verification

- `flutter analyze` on all owned files + the four test files: **No issues found**.
- `flutter test test/commands_test.dart test/format_test.dart test/interactions_test.dart test/web_proxy_test.dart`: **All 99 tests pass**.

## Re-verified invariants

- **Command count**: 33 canonical commands + 7 single-letter aliases (`/j /w /b /i /s /c /q`).
  PWA `setupCommands()` defines 40 `'/x':` keys = 33 canonical + 7 `aliasOf` entries;
  Flutter `kCommandSpecs` = 33 ids + 7 aliases. ✔
- **Command categories**: `channels, pms, groups, formatting, misc` in that order, with the
  exact PWA labels. ✔
- **Action rate limit**: 3 actions / rolling 30 s window, 60 s cooldown on breach, shared by
  `/me /slap /hug`, with the two verbatim PWA messages. `removeWhere(now-ts >= 30000)` mirrors
  the PWA's `filter(now-ts < 30000)`. ✔
- **Formatting order** (escape → fenced/inline code → bold/italic/strike → quote → headings →
  video → image → channel-link → #gjoin → links → gallery → mentions/channel-refs → shortcode
  emoji → ASCII smileys → native-emoji wrap → restore code → game token → newlines): order
  matches `message-format.js`. ✔
- **Quote parser**: line-based, `MAX_QUOTE_DEPTH = 5`, `> @author: msg` recognition,
  `name#xxxx#xxxx` collapse — matches `formatWithQuotes`. ✔
- **Context-menu action set**: now matches `ui-context.js showContextMenu` after fixes below.

## Discrepancy table

| # | Area | PWA ref | Flutter ref | Issue | Severity | Resolution |
|---|------|---------|-------------|-------|----------|------------|
| 1 | Format | message-format.js:251 | nym_format.dart:663 | `:shortcode:` regex was `[a-zA-Z0-9_+-]+`; PWA formatter uses `[a-zA-Z0-9_]+` (so `:+1:`/`:-1:` stay literal — only reachable via autocomplete). | BUG | **Fixed** — regex narrowed to `[a-zA-Z0-9_]+`. |
| 2 | Format | message-format.js:251-257 | nym_format.dart:663-674 | Custom-emoji resolved BEFORE builtin and with a lowercase fallback; PWA tries builtin `emojiMap[lc]` FIRST, then custom with the EXACT (case-sensitive) code, no fallback. | BUG | **Fixed** — builtin-first, exact-case custom, no lowercase fallback. |
| 3 | Format | message-format.js:89-91 | nym_format.dart:320 | Fast path split trigger-free text on blank lines into multiple paragraphs and dropped empty ones; PWA returns ONE block with `\n`→`<br>` (blank lines preserved). | BUG | **Fixed** — `_plainParagraphs` returns a single `ParagraphBlock` of the raw content. |
| 4 | Format | message-format.js:271 | nym_format.dart:680 | Native-emoji wrap regex omitted keycap sequences (`1️⃣`, `#️⃣`). | BUG (cosmetic) | **Fixed** — added `[#*0-9]️?⃣` alternative. Tag-sequence subdivision flags (England flag etc.) still omitted — see deferral D1. |
| 5 | Autocomplete | ui-context.js:1671-1707 | autocomplete_triggers.dart:31-35 | Trigger regexes lacked the PWA's leading `(?:^\|\s)` boundary (so an email's mid-token `@`/`:` opened a dropdown), and the mention/channel needle was `[^\s@#]*`/`[^\s#]*` instead of the PWA's `[^\s]*` (which keeps `@name#xxxx` live in mention mode). | BUG | **Fixed** — regexes now mirror `handleInputChange` exactly. |
| 6 | Autocomplete | ui-context.js:1681-1712 | autocomplete_triggers.dart:61-76 | `detectTrigger` chose the "latest-starting token"; PWA uses fixed precedence mention > channel > kaomoji > emoji. | BUG (latent) | **Fixed** — fixed-precedence chain; trigger-char index derived from needle length (so the `(?:^\|\s)` prefix doesn't offset the splice). |
| 7 | Context menu | ui-context.js:498-534 | context_menu_actions.dart | "Slap with Trout" / "Give warm Hug" actions (injected after PM for every other-user menu) were absent. | BUG | **Fixed** — added `CtxAction.slap/.hug`, ordered after PM, dispatched via `sendCurrent('/me …')` (shares the action rate limiter). |
| 8 | Context menu | ui-context.js:575-580 | context_menu_actions.dart | "Create Group Chat" (`ctxAddToGroup`, gated `!self && !bot && !inGroup`) was absent. | BUG | **Fixed** — added `CtxAction.addToGroup` with the PWA gate; dispatched via `createGroup`. |
| 9 | Context menu | ui-context.js:583-584 | context_menu_actions.dart | "Gift Nymbot Credits" (`!self && !bot`) was absent. | BUG | **Fixed** (action set/order/label/gate). Dispatch deferred — see D2. |
| 10 | Context menu | ui-context.js:587-594 | context_menu_actions.dart | "Edit Profile" (own messages only) was absent. | BUG | **Fixed** (action set/order/label/gate). Dispatch deferred — see D2. |
| 11 | Context menu | ui-context.js:640-642 | context_menu_actions.dart:122 | Mention was self-gated (`if (!t.isSelf)`); PWA shows Mention on own messages (only hidden in profileOnly). | BUG | **Fixed** — Mention now unconditional outside profileOnly. |
| 12 | Context menu | ui-context.js:640-654 | context_menu_actions.dart:81-87 | profile-only mode returned only PM/Report/Block; PWA also leaves Friend, AddToGroup, GiftCredits visible (others fall away for lack of messageId/content). | BUG | **Fixed** — profileOnly returns PM, AddToGroup, GiftCredits, Friend, Report, Block. |
| 13 | Context menu | index.html:94-260 + ui-context.js:507-530 | context_menu_actions.dart:120-139 | Action ORDER: Zap immediately followed PM; PWA runtime order is PM → Slap → Hug → AddToGroup → Zap → GiftCredits → … → Block → EditProfile. | BUG | **Fixed** — list reordered to the runtime DOM order. |
| 14 | Message row | messages.js:838-840, styles-chat.css:677-683 | message_row.dart:546-548 | `delivered` rendered `✓✓` (PWA = single `✓`); `delivered` color was text-dim (PWA `#4CAF50` green); `read` color was `c.secondary` (PWA `#2196F3` blue). | BUG | **Fixed** — single `✓`/green for delivered, `✓✓`/blue for read. |
| 15 | Message row | messages.js:837-845 | message_row.dart:558 | A `sending` state rendered `⋯`; the PWA renders nothing for non-final statuses. | MINOR | **Fixed** — `sending` now emits `SizedBox.shrink()`. |
| 16 | Format | message-format.js:201 | nym_format.dart:628 | Bare-link regex lacked the PWA's `(?!__)` lookahead. | NONE (false positive) | No change — `[^\s]+` is greedy and already consumes trailing `__`, so `(?!__)` is a no-op given no HTML boundary; output identical. |
| 17 | Format | message-format.js:124,131 | nym_format.dart:420-435 | Reported placeholder collision (`F0`/`C9` in user text). | NONE (false positive) | No change — placeholders are already wrapped in U+0001 sentinels (`F<idx>`), unforgeable. Confirmed by re-reading raw bytes. |

## Deferrals

| ID | Item | PWA ref | Reason |
|----|------|---------|--------|
| D1 | Native-emoji **tag sequences** (subdivision flags, e.g. 🏴󠁧󠁢󠁥󠁮󠁧󠁿) not wrapped in the enlarged emoji span | message-format.js:271 | Rare; the tag-sequence regex is fragile and high-risk for marginal cosmetic gain. Keycaps + ZWJ + skin-tone + regional pairs are covered. |
| D2 | **Gift Nymbot Credits** + **Edit Profile** dispatch (action shows + closes the menu, but no effect yet) | ui-context.js:102-107 (`showBotCreditsModal`), 587-594 (`editNick`) | The bot-credits modal and profile editor are owned by other slices and expose no controller entry point reachable from `lib/widgets/context_menu/**`. Action set/order/label/visibility are in place; wiring requires a state-layer method I must not add here. |
| D3 | Context-menu **header status row / bio / banner / owner-mod-verified labels** | ui-context.js:376-464, 656-661 | `_header` renders avatar, nym + cosmetics, full pubkey + Copy. Status/bio/banner need `getEffectiveUserStatus`/`getBio`/banner profile reads from the state layer (not owned). |
| D4 | Channel/group **reader-avatar** delivery indicators for own channel & group messages | messages.js:826-835 | PWA shows stacked reader avatars (not checkmarks) for own channel/group messages via `_buildChannelReadersHtml`/`_buildGroupReadersHtml`. Needs a read-receipt/reader-set source from the state layer; PM tick glyphs (the in-file part) are fixed (#14). |
| D5 | Composer **quote/edit preview chips**; quote currently inlined as `> @author: msg` into the input | messages.js:1816-1859 (`setQuoteReply`), 1861+ (`startEditMessage`) | PWA holds a `pendingQuote`/edit state shown as a chip above the composer and prepends the quote only at send time. Reproducing it needs a chip widget + send-time prepend in `sendCurrent` (state layer). Mention-insert already matches the PWA's `insertMention` (inlines `@nym ` into the input). |
| D6 | Composer **Nymbot toolbar button** (`smart_toy`) present in Flutter, absent from PWA `.input-buttons` | index.html:758-790 | The PWA toolbar is Image/Video, P2P File, Emoji, GIF, SEND. Removing the Flutter Nymbot button would orphan the app's only bot-PM entry point (the PM-list/bot-discovery path is owned by another slice), so it is retained and noted rather than removed. |
| D7 | Image toolbar button is image-only; PWA accepts image **and** video upload | index.html:759-760 | `_pickAndUploadImage` uses `ImageSource.gallery` (images). Video upload + the "Upload Image/Video" tooltip belong to the upload/media slice. |

## Notes on faithful ports (spot-checked, no change needed)

- Slash parse (`split(' ')`, `parts[0].toLowerCase()`, `slice(1).join(' ')`), alias collapse,
  per-command usage strings, formatting transforms (`/bold`→`**x**`, `/code`→```` ```\nx\n``` ````,
  `/quote`→`> x`, `/me`→`/me x`), and context gates (`/who` channel-only, `/poll` channel-only,
  group-only mod commands) all match.
- The four autocomplete query engines: mention ranking (channel online→away→offline then others,
  alphabetical, cap 8), channel ranking (current→joined→msg-count→name, valid-name filter,
  `commonGeohashes` seed), emoji ranking (exact→prefix→priority→shorter-name; recents-first on
  empty), kaomoji category filtering (no cap) — all match.
- Insert formats: `@base#suffix ` (mention), `#name ` (channel), `emoji ` / `:shortcode: `
  (emoji), `kaomoji ` (kaomoji) — all match.
- Message-row bubble grouping (5-min window), self/mention tints, reactions row, IRC-vs-bubble
  anatomy: verified faithful.
