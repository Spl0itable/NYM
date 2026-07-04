# Gap report 10 — Onboarding + Tutorial spotlight + Nymbot chat + Zaps modal

Slice: first-run onboarding flow, the guided tutorial overlay (per-step element
spotlight), the Nymbot 1:1 chat screen (model picker / credits / think-blocks /
command suggestions), and the Lightning zap modal (presets / custom / comment /
states).

**Summary.** The data/protocol layers are faithful (audit 07 verified the Nymbot
Pro-model list, `<think>` split, sats/credit, git providers), but the *visible
UI* of all three surfaces diverges from the PWA. The single biggest gap is the
**tutorial spotlight box** — the PWA draws a positional highlight ring + dim
cut-out around the element each step describes and anchors the card next to it;
Flutter centers a static card for every step (audit 04 explicitly DEFERRED this).
Secondary gaps: the zap modal is missing the **"I've paid" manual-verify button**
and the `zapSuccess` animation; the Nymbot screen is missing the **command
suggestion palette** (`?…` autocomplete), uses a plain empty-state instead of the
PWA's rich welcome bubble, and styles the tier toggle / reasoning block with the
wrong accent colors. Tutorial card chrome (uppercase title in `--primary`,
uppercase pill buttons, `--bg-tertiary` card) is also mismatched.

**Count: 13 findings** — 1 blocker (F1), 4 high (F2-F5), 4 medium (F6, F8, F9,
F10... see ordering), 4 low. Plus 2 incidental. Note: F7 was downgraded to low
after confirming the PWA `.modal-header`/`.form-label` ARE uppercased (Flutter's
casing is correct); findings below are grouped by area, not strictly re-sorted by
the revised severity — read each finding's own `[SEVERITY]` tag.

PWA px/hex sources: `css/styles-components.css` (tutorial), `css/styles-chat.css`
(zap + bot), `js/app.js` (tutorial IIFE), `js/modules/pms.js` + `commands.js`
(Nymbot), `js/modules/zaps.js` + `index.html` (zap modal). `--secondary` base =
`#4DA3FF`, `--primary` base = `#7C5CFF`, `--lightning` = `#F7931A`,
`--bg-tertiary` = `#1E1E26`, `--warning` = `#E0A800`. `--radius-md`=16,
`--radius-sm`=12, `--radius-xs`=8, `--radius-lg`=20.

---

### F1: Tutorial per-step element spotlight + positional card not ported  [SEVERITY: blocker]
- PWA: `js/app.js:206-283` (`positionStep`) + `css/styles-components.css:1990-1998`
  (`.tutorial-highlight`). For each step with a `selector`, the PWA measures the
  target element's `getBoundingClientRect()`, draws a **highlight ring** padded
  `8px` on every side (`hlLeft=max(8, rect.left-8)`, `hlTop=max(8, rect.top-8)`,
  width/height = `rect.size + 16` clamped to viewport) with:
  `border: 2px solid var(--secondary)` (#4DA3FF);
  `box-shadow: 0 0 30px rgb(secondary / 0.3), 0 0 0 9999px rgba(0,0,0,0.5)` — the
  `9999px` spread is the **dim cut-out** that darkens everything *except* the
  highlighted element; `border-radius: var(--radius-md)` (16px);
  `transition: all 0.25s ease`. The card is then placed **below** the target
  (`rect.bottom + 12`) if it fits, else **above** (`rect.top - cardH - 12`), else
  clamped into the bottom area; horizontally centered on the target and clamped
  12px from edges (`js/app.js:248-269`). Off-screen targets `scrollIntoView`
  first (`js/app.js:219-228`). Re-positions on `resize`/`scroll`
  (`js/app.js:392-395`).
- Flutter: `lib/features/onboarding/tutorial_overlay.dart:18` (`TODO(verify)`
  comment), `:157-248` — every step renders the SAME centered card over a flat
  `Colors.black @0.7` scrim. No target measurement, no highlight ring, no
  per-step anchoring. The 11 step `selector` targets (`.nym-display`,
  `.status-indicator`, `.header-actions`/`.sidebar-actions`, `#channelList`,
  `.discover-icon`, `#pmList`, `#userList`, `#messagesContainer`,
  `.input-container`, `#shareChannelBtn`) are documented only in prose in the
  step `body`.
- Gap: The defining behavior of the tour — "look HERE" — is absent. The user
  reads "Tap here to edit the nickname…" with nothing pointed at, on every one of
  the 10 element-anchored steps. This is the headline DEFERRED item from audit
  `04-ui-shell-themes.md:71-72`.
- Fix approach: Give the shell's tour-target widgets `GlobalKey`s
  (`HomeShell`/sidebar: nym display, status indicator, header/sidebar actions,
  channel list, discover/globe icon, pm list, user list, messages container,
  composer, share button), keyed to a `TutorialTarget` enum. In
  `tutorial_overlay.dart` add a `selector`/`targetKey` to each `TutorialStep`.
  On each step, resolve the key's `RenderBox` → global rect, inflate by 8px, and
  paint via a `CustomPainter`/`Stack`: (a) a full-screen dim using
  `Path.combine(difference, fullRect, RRect(targetRect, 16))` filled
  `Colors.black @0.5`; (b) a `2px` `c.secondary` border ring with a `30px`
  `c.secondary @0.3` glow (BoxShadow blur 30). Position the card below/above the
  rect per the PWA algorithm; animate rect changes over 250ms. Center the card
  (current behavior) only when `selector == null` (steps 1 "Nymchat Tutorial" and
  12 "All set!"). Honor `scrollIntoView` for off-screen targets. On mobile the
  PWA also opens/closes the sidebar per step (`onBefore`, see F2).
- Effort: L  Risk: med  Confidence: high

### F2: Tutorial does not open/close the sidebar per step on mobile  [SEVERITY: high]
- PWA: `js/app.js:32-94` (`onBefore` hooks) + `:97-195`. Steps whose targets live
  in the sidebar (Your Nym, Connection, Main Menu, Channels, Explore Geohash,
  Private Messages, Active Nyms) call `ensureSidebarOpenOnMobile()`
  (`js/app.js:97-133`) which adds `.open` to `#sidebar` + `.active` to
  `#mobileOverlay` and **awaits the 400ms transform transition** before measuring.
  The "Messages" step calls `ensureSidebarClosedOnMobile()` (`js/app.js:136-175`)
  to reveal the message pane. On teardown `restoreSidebarAfterTutorial()`
  (`js/app.js:177-195`) restores the sidebar to its pre-tour open/closed state
  (captured at `js/app.js:376`).
- Flutter: MISSING — `tutorial_overlay.dart` has no notion of the sidebar/drawer
  and never drives `HomeShell`'s drawer state.
- Gap: On a phone, every sidebar-anchored step would point at a collapsed drawer
  (once F1 lands). Without coordinating the drawer the spotlight has nothing to
  ring on narrow layouts.
- Fix approach: Add an optional `onBefore` callback per `TutorialStep` that, on a
  narrow layout (`< NymDimens.tabletBreakpoint` = 1024), opens or closes
  `HomeShell`'s drawer (Scaffold drawer or the app's responsive drawer state)
  and waits one animation (~250-400ms) before the overlay measures the target.
  Restore drawer state on dismiss. Couple this to F1.
- Effort: M  Risk: med  Confidence: high

### F3: Zap modal missing the "I've paid" manual-verify button  [SEVERITY: high]
- PWA: `index.html:2090` (`<button id="zapPaidBtn" data-action="manualCheckPayment">I've paid</button>`),
  revealed in `js/modules/zaps.js:967-968` (`displayZapInvoice` →
  `paidBtn.classList.remove('nm-hidden')`), handled by `manualCheckPayment`
  (`js/modules/zaps.js:707-736`). Once the invoice QR is shown, a primary
  **"I've paid"** button appears next to **Cancel**; tapping it immediately
  re-checks the invoice (LUD-21 verify / bot wallet) instead of waiting for the
  poll. Timeout/no-detection states explicitly tell the user to *"tap 'I've paid'"*
  (e.g. `zaps.js:691`).
- Flutter: `lib/features/zaps/zap_modal.dart:515-522` — `_actions()` only renders
  a single **Cancel** button in every phase. There is no manual re-check
  affordance and no button revealed in the `invoice` phase.
- Gap: A user who pays in an external wallet has no way to force a confirmation;
  they must wait out the 180s poll (`zap_modal.dart:182`). The PWA's primary
  call-to-action on the invoice screen is missing.
- Fix approach: In `zap_modal.dart`, when `_phase == _Phase.invoice`, render an
  "I'VE PAID" filled/primary button beside Cancel in `_actions()` (reuse
  `_iconBtn` styling but accent it). Wire it to a `_manualCheck()` that calls
  `_api.zapVerify(...)` once and, if true, runs `_markPaid(_invoice!)`; on false,
  set a status line ("Not paid yet — complete the payment in your wallet, then tap
  again", mirroring `zaps.js:728`). Mirror PWA timeout copy in
  `_startVerifyPolling` failure (`zap_modal.dart:186`).
- Effort: S  Risk: low  Confidence: high

### F4: Nymbot chat has no command-suggestion palette (`?…` autocomplete)  [SEVERITY: high]
- PWA: `js/modules/commands.js:436-468` (`showBotCommandPalette`) +
  `:272-281` (`botPMCommands`). Typing `?` in the Nymbot PM opens a filterable
  dropdown (`#commandPalette`, `.command-item` rows: `.command-name` +
  `.command-desc`), keyboard-navigable (`navigateCommandPalette`,
  `commands.js:475-487`), listing the 8 PM commands: `?help`, `?model`, `?git`,
  `?buy`, `?balance`, `?gift`, `?transfer`, `?clear`. After a base command + space
  (e.g. `?git `) it surfaces **subcommands** (`commands.js:446-454`,
  `_botPMSubcommands`).
- Flutter: `lib/features/nymbot/bot_chat_screen.dart:629-696` (`_Composer`) — a
  plain `TextField` with hint "Message Nymbot…  (try ?help)" and a send button.
  No palette, no autocomplete, no subcommand hints. The catalogue exists in a
  provider (`nymbot_providers.dart:343-344` `botCommandsProvider`) but is **never
  rendered**, and that catalogue is the *public-channel* set, not the 8 PM
  commands the PWA shows here.
- Gap: Users can't discover `?model`/`?git`/`?gift`/`?transfer`/`?clear` — the
  brief's "command suggestions" feature is entirely absent on this screen.
- Fix approach: Add a `botPMCommands` const list (the 8 above with descriptions)
  to the nymbot feature. In `_Composer`, listen to the controller text; when it
  starts with `?` and has no space, show an overlay/`Column` above the input with
  filtered `command-item`-style rows (name in `c.text` w600 + desc in `c.textDim`,
  bgTertiary surface, border `c.border`, radius 8). Tap fills the input. Optionally
  add `?git`/`?model` subcommand hints after a trailing space. Mirror the
  `.command-item.selected` highlight for the first match.
- Effort: M  Risk: low  Confidence: high

### F5: Nymbot empty-state is a plain blurb, not the rich welcome bubble  [SEVERITY: medium]
- PWA: `js/modules/pms.js:1707-1730` (`_botWelcomeHtml`) /
  `:1822-1835` (`_botFirstContactText`), rendered as an actual **message bubble
  from Nymbot** (`_displayBotInfoMessage` / `_displayBotWelcomeMessage`,
  `pms.js:1776-1817`) with the bot avatar, verified ✓ badge, and a multi-paragraph
  intro: "Hey, I'm **Nymbot** 👋 …", the premium-vs-Pro pitch, a command list
  (`?help`, `?balance`, `?buy`, `?model`, `?transfer` each in `<code>`), and the
  pricing paragraph. Brand-new users also get this **proactively** pushed as a PM
  (`_maybeSendBotWelcomePM`, `pms.js:1840-1879`).
- Flutter: `bot_chat_screen.dart:128-141` — when `messages.isEmpty`, a single
  centered grey paragraph: "Private, end-to-end encrypted chat with Nymbot. /
  Standard replies are auto-routed (10 sats each)… / Type ?help for the guide."
  No avatar, no ✓ badge, no command list, no pricing, not styled as a bubble.
- Gap: First impression of the premium bot is a thin placeholder vs the PWA's
  branded onboarding bubble; the command/pricing discovery it provides is lost.
- Fix approach: Replace the empty-state with a non-`fromUser` `_MessageBubble`
  seeded as the first message (avatar 🤖 + "Nymbot" + ✓), carrying the
  `_botWelcomeHtml` copy (port the bullet list verbatim, render `?…`/code spans in
  a monospace pill). Either inject it as a synthetic first message in
  `BotChatController` init, or render it in place of the empty-state with bubble
  styling. Keep "Type ?help" as the closer.
- Effort: M  Risk: low  Confidence: high

### F6: Tutorial card chrome mismatched (title color/case, button style, card bg)  [SEVERITY: medium]
- PWA: `css/styles-components.css:2000-2088`.
  - `.tutorial-title` (`:2022-2028`): `color: var(--primary)` (#7C5CFF),
    `font-weight: bold`, `letter-spacing: 1px`, `text-transform: uppercase`,
    `font-size: 14px` → renders **"YOUR NYM"** in purple.
  - `.tutorial-card` (`:2000-2012`): `background: var(--bg-tertiary)` (#1E1E26),
    `border-radius: var(--radius-lg)` (20px), `padding: 20px`.
  - `.tutorial-btn` (Back AND Next, `:2069-2082`): identical pills —
    `background: rgba(255,255,255,0.05)`, `1px solid var(--glass-border)`,
    `border-radius: var(--radius-xs)` (8px), `padding: 8px 16px`, `font-size 12px`,
    `font-weight 500`, `text-transform uppercase`, `letter-spacing 1px`,
    `color var(--text)`; both **right-aligned** (`.tutorial-actions` `:2062-2067`
    `justify-content: flex-end`, gap 8). Hover tints primary.
  - `.tutorial-skip` (`:2030-2043`): an uppercase outlined pill (not a bare text
    button), `font-size 11px`, `padding 6px 12px`.
  - `.tutorial-progress` (`:2056-2060`): 11px `var(--text-dim)`, `margin-top 10px`.
- Flutter: `tutorial_overlay.dart:185-241` — title is `c.textBright`, **17px**,
  w700, **mixed-case, no letter-spacing**; card uses `c.bgSecondary` (should be
  bgTertiary) and `NymRadius.rlg` (20 ✓); Back is a plain `TextButton`, **Next is
  a filled primary** `FilledButton` (PWA has two identical ghost pills);
  buttons are **spaceBetween** (PWA right-aligns both); Skip is a bare `TextButton`
  (PWA is an outlined uppercase pill); body 13.5px (PWA 13px); progress 12px
  (PWA 11px).
- Gap: The tour card reads visibly different — wrong title color/case, a
  primary-filled Next that the PWA doesn't have, and left/right button split vs
  the PWA's right-aligned pair.
- Fix approach: In `tutorial_overlay.dart`: title → `c.primary`, 14px, w700,
  `letterSpacing: 1`, `text.toUpperCase()`; card color → `c.bgTertiary`; render
  Back+Next as two identical ghost pills (`white@0.05` fill, `c.glassBorder`,
  radius 8, uppercase 12px w500 ls1, `c.text`) in a right-aligned Row (`gap 8`,
  `MainAxisAlignment.end`); make Skip an outlined uppercase pill (11px, padding
  6/12); body 13px; progress 11px `c.textDim`. Last-step Next label "DONE".
- Effort: S  Risk: low  Confidence: high

### F7: Zap modal header is 20px + lacks the divider/padding the PWA `.modal-header` has  [SEVERITY: low]
- PWA: `index.html:2024` header text "Send Lightning Zap" rendered through
  `.modal-header` (`css/styles-components.css:117-126`): `font-size: 22px`,
  `color: var(--primary)`, `text-transform: uppercase`, `letter-spacing: 1.5px`,
  `font-weight: 700`, **`margin-bottom: 24px`**, **`border-bottom: 1px solid
  var(--glass-border)`**, **`padding-bottom: 14px`**. Labels via `.form-label`
  (`:219-227`): uppercase, 11px, `letter-spacing: 1.2px`, w600, `var(--text-dim)`.
  → The PWA DOES render "SEND LIGHTNING ZAP" / "SELECT AMOUNT" / "COMMENT
  (OPTIONAL)" in uppercase, so Flutter's casing is **correct** (earlier suspicion
  withdrawn).
- Flutter: `zap_modal.dart:272-278` header is **20px** (PWA 22px), w700, ls 1.5,
  `c.primary` — but has **no bottom border / no padding-bottom divider** under the
  title (the close button sits inline in a Row, `:267-297`). Labels match
  (`:302`, `:335`) at 11px ls 1.2.
- Gap: Header is 2px smaller and the PWA's hairline rule separating the title from
  the body is absent — a minor structural/visual mismatch. Casing is fine.
- Fix approach: Bump the header `fontSize` to 22; add a `Divider`/`Border(bottom:
  c.glassBorder)` under the header Row with ~14px padding-bottom and ~24px gap
  before the body. Cosmetic.
- Effort: S  Risk: low  Confidence: high

### F8: Reasoning ("💭") block styled with wrong accent + no scroll cap  [SEVERITY: medium]
- PWA: `css/styles-chat.css:1193-1237` (`.bot-think`). Collapsible with a
  rotating `▸` marker (`:2214-1223`, rotates 90° when `[open]`),
  `border: 1px solid var(--glass-border)` **plus** `border-left: 3px solid
  rgb(primary / 0.45)`, `background: rgb(secondary / 0.08)` (#4DA3FF @8%),
  `font-size: 0.88em`; body is italic `var(--text-dim)` with
  `max-height: 320px; overflow-y: auto`. Summary label is **"💭 Reasoning"**
  (`messages.js:1417`). It is rendered **inside** the bot bubble, prepended to the
  message content.
- Flutter: `bot_chat_screen.dart:534-601` (`_ReasoningSection`) — uses an
  `expand_more`/`expand_less` chevron (not the `▸`), `c.bgTertiary` background
  (PWA = secondary @8%), `c.border` only (no 3px primary left accent), no
  `max-height`/scroll, and is rendered as a **separate widget above** the bubble
  (PWA renders it inside, prepended). Label "Reasoning" with 💭 ✓.
- Gap: The reasoning card looks plain/grey instead of the PWA's blue-tinted,
  primary-left-barred panel; very long reasoning won't scroll in a capped box.
- Fix approach: In `_ReasoningSection`: background `c.secondary.withValues(alpha:
  0.08)`, add `border(left: BorderSide(color: c.primary @0.45, width: 3))`, keep
  the 1px glass border on the other sides; wrap the expanded body in a
  `ConstrainedBox(maxHeight: 320)` + `SingleChildScrollView`; optionally swap the
  chevron for a rotating ▸. Consider rendering it inside the bubble (top) to match
  the PWA's in-bubble placement.
- Effort: S  Risk: low  Confidence: high

### F9: Nymbot Standard/Pro tier toggle uses wrong accent (blue/purple vs lightning)  [SEVERITY: medium]
- PWA: `css/styles-chat.css:1239-1268` (`.bot-credit-tier-toggle` /
  `.bot-credit-tier-btn`). Two equal-flex pills; the **active** one is
  `border-color: rgba(247,147,26,0.5)`, `background: rgba(247,147,26,0.12)`,
  `color: var(--lightning)` (#F7931A), `font-weight: bold` — i.e. the
  **lightning/orange** accent for *both* Standard and Pro; inactive is
  `var(--text-dim)` on `white@0.04` + glass border (`:1245-1256`). Used in the
  buy-credits modal (`zaps.js:417-440`).
- Flutter: `bot_chat_screen.dart:393-461` (`_TierSwitch`) — active Standard is
  tinted **`c.blue`** and active Pro is tinted **`c.primary`** (purple), each with
  an 18%/border accent. This two-color scheme doesn't exist in the PWA, where both
  segments use the orange lightning accent.
- Gap: The buy/credits tier switch reads blue+purple instead of the PWA's
  consistent lightning-orange selected state.
- Fix approach: In `_TierSwitch._segment`, pass `c.lightning` as the accent for
  **both** segments (drop the per-segment `c.blue`/`c.primary` split). Active fill
  `c.lightning @0.12`, border `c.lightning @0.5`, text `c.lightning` w700; inactive
  `c.textDim`. (The header subtitle "Standard · auto-routed" / "Pro · <label>" can
  stay.)
- Effort: S  Risk: low  Confidence: high

### F10: Zap success state missing the `zapSuccess` pop animation  [SEVERITY: low]
- PWA: `css/styles-chat.css:288-310` — `.zap-status.paid` runs
  `animation: zapSuccess 0.5s` (`@keyframes zapSuccess`: scale 1 → 1.05 → 1),
  border/color `var(--primary)`. The ⚡ + "Zap sent successfully!" + "<n> sats"
  block (`zaps.js:1130-1134`) pops on success.
- Flutter: `zap_modal.dart:462-482` (`_paidSection`) renders the ⚡/text/sats
  correctly with a primary border but **no scale animation**.
- Gap: Success confirmation appears statically rather than with the PWA's brief
  scale pop. Minor polish gap.
- Fix approach: Wrap `_paidSection` in a `TweenAnimationBuilder<double>` (0→1 over
  500ms) driving a `Transform.scale` 1.0→1.05→1.0 (or a `ScaleTransition` with a
  `TweenSequence`). Cosmetic.
- Effort: S  Risk: low  Confidence: high

### F11: Zap amount-button selected state missing glow; Generate button only on custom row  [SEVERITY: low]
- PWA: `css/styles-chat.css:164-194`. `.zap-amount-btn` padding `15px 10px`, sats
  span 18px bold `var(--lightning)`, "sats" 12px below; hover tints lightning;
  **`.selected`** (`:183-187`) adds `box-shadow: 0 0 15px rgba(247,147,26,0.15)`
  on top of the @0.12 fill / @0.5 border. The `.zap-amounts` grid has
  `margin: 20px 0` (`:157-162`). There is exactly ONE inline "Generate" button,
  on the custom-amount row (`index.html:2063`); presets auto-generate on tap
  (`zaps.js:383-391`).
- Flutter: `zap_modal.dart:348-386` (`_amountBtn`) — `c.lightning @0.12` fill +
  `c.lightning @0.5` border on selected, but **no glow box-shadow**; uses
  `childAspectRatio: 1.6` rather than fixed `15px 10px` padding. The single
  Generate button (`_generateBtn`, `:388-411`) is on the custom row ✓, presets
  auto-generate ✓.
- Gap: Selected preset lacks the soft orange glow the PWA shows. Minor.
- Fix approach: Add `boxShadow: selected ? [BoxShadow(color: c.lightning @0.15,
  blurRadius: 15)] : null` to `_amountBtn`'s `Container` decoration. Optionally
  match preset cell padding to 15/10. Cosmetic.
- Effort: S  Risk: low  Confidence: high

### F12: Pro model picker shows model-id instead of the PWA's price-range label  [SEVERITY: low]
- PWA: `js/modules/pms.js:2096-2099` (`_botProPriceLabel`) + `:2122-2123`. The
  `?model` list shows, per model, the human label plus a **price phrase**:
  `"<credits> Pro credit(s)/reply"` for flat models, or `"from <credits> Pro
  credit(s), up to <max> for max-length replies"` for usage-scaled ones (uses the
  `max` field: Fable 16, Opus 8, Sonnet 6, GPT-5.1 4, Codex 4, Haiku/mini 1). The
  selected model gets a ✓.
- Flutter: `bot_chat_screen.dart:349-365` — the picker `ListTile.subtitle` shows
  `'${m.modelId} · base ${m.baseCredits} cr'` (e.g. "anthropic/claude-opus-4.8 ·
  base 1 cr"). The `ProModel` class (`nymbot_models.dart:13-32`) **has no `max`
  field**, so the up-to-N range can't be shown. (Standard row + ✓ check ✓.)
- Gap: Users see an internal model id and a bare base cost instead of the PWA's
  "from 1, up to 8 for long replies" guidance. Per-model max pricing isn't
  surfaced.
- Fix approach: Add `final int max;` to `ProModel` with the PWA values
  (fable 16, opus 8, sonnet 6, haiku 1, gpt-5 4, gpt-5-mini 1, codex 4); add a
  `priceLabel` getter mirroring `_botProPriceLabel`; in the picker subtitle render
  `m.priceLabel` (drop `modelId`, or keep id dim on a second line). Effort bumps to
  S+ because a model field is added.
- Effort: S  Risk: low  Confidence: high

### F13: Nymbot screen omits `?clear` / `?transfer` / `?gift` / `?help` command handling  [SEVERITY: low]
- PWA: `js/modules/pms.js:2393-2441` (`_handleBotPM`) intercepts `?help`,
  `?balance`, `?buy`, `?model`, `?clear` (`_clearBotPMHistory`, `pms.js:1894`),
  `?transfer` (`_handleBotTransferCommand`, `:1919`), `?gift` (opens the gift
  credit modal, `:2426-2441`). A leading `!` marks a "fresh" message that skips
  history (`pms.js:2450`).
- Flutter: `bot_chat_screen.dart:158-202` (`_handleSubmit`) intercepts only
  `?balance`, `?buy`, `?model`, `?git`. `?clear`, `?transfer`, `?gift`, `?help`
  fall through to `ctrl.send(text)` (sent as a normal paid message) and the `!`
  fresh prefix is ignored (`send(..., fresh:false)` always).
- Gap: `?clear` won't wipe history, `?gift`/`?transfer` won't open their flows,
  `?help` is sent as a paid message instead of showing the local guide, and `!`
  doesn't reset context — all silently mis-handled.
- Fix approach: Extend `_handleSubmit`'s `?`-branch to handle `?help` (show local
  guide bubble / scroll to welcome), `?clear` (clear `state.messages` +
  controller history), `?gift`/`?transfer` (open the respective modals — gift
  reuses the buy modal with a recipient; transfer is a confirm dialog). Detect a
  leading `!` and pass `fresh: true` to `ctrl.send`. (Some of these depend on
  flows owned by other slices — coordinate; mark TODO where the backing flow
  isn't built.)
- Effort: M  Risk: med  Confidence: med

---

## Incidental (logic, not pure UI — noted per brief)

- **I1 — Tutorial keyboard shortcuts not ported.** PWA `js/app.js:401-410`
  (`keyHandler`): `Escape` ends the tour, `ArrowRight`/`Enter` = Next,
  `ArrowLeft` = Back. Flutter `tutorial_overlay.dart` wires none of these (no
  `Focus`/`Shortcuts`). On a keyboard/desktop build the tour can't be driven by
  keys. (S, low risk.)

- **I2 — Tutorial "skip steps whose target is missing" not ported.** PWA
  `js/app.js:332-356` (`skipIfTargetMissingForward/Backward`) auto-advances past
  any step whose `selector` resolves to no element (e.g. `#shareChannelBtn` hidden
  on a layout). Flutter shows all 12 steps unconditionally. Once F1 lands, a step
  pointing at an absent widget would have nothing to highlight; port the skip
  guard. (S, low risk, depends on F1.)

## Cross-checks / non-issues (verified, no finding)

- Pro model list (key/label/baseCredits/order) in Flutter `kProModels`
  (`nymbot_models.dart:37-80`) matches PWA `_botProModels` (`pms.js:2084-2092`)
  exactly — confirmed by audit 07. Only the `max` field is absent (see F12).
- `<think>` split (case-insensitive, dot-all, 4000-char cap + truncation suffix)
  in `splitReasoning` (`nymbot_models.dart:337-381`) matches the worker/PWA.
- Zap presets `[21,100,500,1000,5000,10000]` (`zap_modal.dart:48`) match
  `index.html:2033-2056` `data-amount`s; `1K/5K/10K` short labels match
  (`zap_modal.dart:350`).
- Zap LUD-21 verify poll (180×1s) (`zap_modal.dart:170-189`) matches
  `zaps.js:1012-1033`; bolt11 dedup set matches `_selfCountedZapInvoices`.
- Git connect modal (provider chips, host/PAT/repo/branch fields, allow-writes
  switch, disconnect) (`bot_chat_screen.dart:904-1090`) covers the PWA `?git`
  fields; the 3 providers + default hosts match `pms.js:2152-2156`.
- BootGate needs-setup logic (`boot_gate.dart:42-49`) and tutorial-seen gating
  (`:78-100`, 1-frame defer ≈ PWA's `setTimeout(300)`) match
  `setup-modal-init.js` + `maybeStartTutorial` (`app.js:441-452`).
