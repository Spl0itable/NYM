# Gap report 02 — Chat pane, message rendering, rows, indicators, previews, galleries, quotes

**Scope:** Chat pane / messages list / message rows / delivery+read indicators / reader avatars /
link previews / image galleries / quote rendering. PWA source: `js/modules/messages.js`,
`js/modules/message-format.js`, `css/styles-chat.css`, `css/styles-features.css`, `index.html`.
Flutter target: `lib/widgets/chat/{chat_pane,messages_list,message_row}.dart`,
`lib/features/messages/format/{message_content,nym_format,link_preview}.dart`.

**Summary:** The formatter pipeline (nym_format → message_content) is a faithful port and the PM
tick glyphs were already fixed in audit #14. The big user-visible holes are: (1) reader-avatar
delivery indicators for own channel/group messages are entirely absent (prior audit deferral **D4**),
(2) composer quote/edit preview chips are absent — quotes are inlined into the input (**D5**),
(3) the link-preview card is laid out vertically where the PWA is a horizontal thumbnail card,
(4) `/me` action messages and in-list system messages are not rendered at all, (5) flooded/spam-gated
message states, emoji-only enlargement, and "blur others' images" are missing, (6) the IRC layout
drops the `(edited)` marker, (7) the gallery grid geometry (3-up tall-first, max-widths) and several
mention/self/mentioned tint specifics are off.

**Count:** 16 findings — 0 blocker, 4 high, 8 medium, 4 low. (D4/D5 are state-layer-gated and tracked
as high/medium respectively with the data-source caveat noted.)

---

### F1: Reader-avatar delivery indicators for own channel/group messages are entirely missing  [SEVERITY: high]
- PWA: `messages.js:824-847` builds the delivery affordance for own messages. For an own **channel**
  message (`message.isOwn && !isPM && geohash && /^[0-9a-f]{64}$/`) it renders
  `<span class="channel-readers" data-msg-id="…">` whose inner HTML comes from
  `_buildChannelReadersHtml(id)` (`groups.js:2737-2741` → `_buildGroupReadersHtmlFromMap`). For an own
  **group** message it renders `<span class="group-readers" data-nym-msg-id="…">` from
  `_buildGroupReadersHtml(nymMessageId)` (`groups.js:2783-2787`). `_buildGroupReadersHtmlFromMap`
  (`groups.js:2624-2641`): up to `MAX_VISIBLE = 3` stacked `<img class="group-reader-avatar">`, plus a
  `<span class="group-reader-overflow">+N</span>` (abbreviated) when more. CSS
  (`styles-chat.css:612-654`): `.group-readers/.channel-readers` are `display:flex;
  justify-content:flex-end; flex-basis:100%; margin-top:3px; padding-right:4px; min-height:14px`
  (hidden when `:empty`); each `.group-reader-avatar` is **14×14**, `border-radius:50%`,
  `border:1.5px solid var(--bg-primary)`, `opacity:0.85`, and overlaps the previous by
  `margin-left:-5px`; `.group-reader-overflow` is `9px` text-dim, `line-height:14px`,
  `margin-left:3px`. Long-press (500 ms, `groups.js:2754-2774` / `2801-2821`) opens a "seen by"
  readers modal (`showChannelReadersModal`/`showReadersModal`). The reader set is "waterfalled" so each
  reader's avatar only shows on their latest-seen own message (`_computeWaterfallReaders`,
  `groups.js:2586-2608`).
- Flutter: `message_row.dart:204` (IRC) and `:270-273` (bubble) call `_deliveryTicks`/`_ticksGlyph`
  **only when `self && message.isPM`**. Own **channel** messages get no indicator at all, and own
  **group** messages fall through the same PM-tick path (single ✓/✓✓ glyph) instead of reader avatars.
  No `channel-readers`/`group-readers` widget, no stacked-avatar stack, no overflow badge, no long-press
  "seen by" modal. The `Message` model (`lib/models/message.dart`) has **no readers field**
  (no analogue of `channelMessageReaders`/`groupMessageReaders`).
- Gap: Users never see who has read their channel/group messages — a prominent PWA affordance is
  invisible. Own group messages additionally show the wrong UI (checkmark vs avatar stack).
- Fix approach: This is prior-audit **D4** and is **state-layer-gated**: first add a reader map to the
  message read-receipt store (`channelMessageReaders: Map<msgId, Map<pubkey,nym>>` and
  `groupMessageReaders: Map<nymMessageId, …>`) plus the waterfall computation, then build a
  `ReaderAvatars` widget: a right-aligned `Row` of up to 3 overlapping `NymAvatar`s (14px, white 1.5px
  border, `opacity 0.85`, `-5px` left margin via `Transform`/negative `SizedBox`), a `+N` overflow
  `Text` (9px `c.textDim`), `min-height 14`, `margin-top 3`, `padding-right 4`. Render it in
  `message_row.dart` for `self && !isPM && isChannel` and `self && isGroup`; gate the existing tick
  glyph to `self && isPM && !isGroup`. Long-press → a "seen by" modal listing reactor nyms (mirror the
  reactors modal already in `lib/features/reactions/reactors_modal.dart`).
- Effort: L  Risk: med  Confidence: high

### F2: Link-preview card is vertical; the PWA card is a horizontal thumbnail layout  [SEVERITY: high]
- PWA: `styles-features.css:4348-4414`. `.link-preview` is `display:flex` (horizontal),
  `max-width:400px`, `border:1px solid glass-border`, `border-radius:8px`, bg `rgba(255,255,255,0.03)`,
  hover bg `rgba(255,255,255,0.06)`. `.link-preview-image` is a **left** thumbnail: `width:120px;
  min-height:80px; object-fit:cover; flex-shrink:0`. `.link-preview-text` is the right column,
  `padding:8px 12px; gap:3px`. `.link-preview-site` is `0.75em` text-dim **UPPERCASE**
  `letter-spacing:0.3px` with a `14×14` favicon (`border-radius:2px`). Title `0.9em` weight 600,
  `-webkit-line-clamp:2`. Desc `0.8em` text-dim, `line-clamp:2`. Container margin-top 8px.
- Flutter: `link_preview.dart:122-209`. `_Card` is a **vertical** `Column`: image on top
  (`width:double.infinity, height:150, BoxFit.cover`), then a 10px-padded text column. `maxWidth:320`
  (PWA 400). Site label is NOT uppercased and uses `fontSize:11` (PWA `0.75em` ≈ 11.25 of a 15px base
  but should be relative + uppercase + `letter-spacing 0.3`). Description clamps to 3 lines (PWA 2).
  Image is full-bleed top, not a 120px left thumbnail.
- Gap: The card looks like a different component — a big banner image vs the PWA's compact
  left-thumbnail row. Most noticeable for links with images.
- Fix approach: In `link_preview.dart` `_Card`, replace the `Column` with a `Row`: left
  `SizedBox(width:120, child: CachedNetworkImage(...minHeight:80, BoxFit.cover))`, right
  `Expanded(child: Padding(8,12) → Column gap 3)`. Bump `maxWidth` 320→400. Uppercase the site label
  (`data.host.toUpperCase()`) with `letterSpacing:0.3`. Title fontSize → `size*0.9` weight 600,
  2-line clamp. Desc → `size*0.8`, 2-line clamp. Add hover bg change (desktop). Outer `margin-top:8`.
- Effort: M  Risk: low  Confidence: high

### F3: `/me` action messages are not rendered (no italic "* author action *" line)  [SEVERITY: high]
- PWA: `messages.js:662-683`. When `message.content.startsWith('/me ')` the row is built as
  `class="system-message me-message"` with innerHTML `* <avatar><author>#suffix<flair> <formattedAction> *`
  (the action text after `/me ` is run through `formatMessage` + `_enrichActionMentions`). CSS
  `styles-chat.css:1380-1382` `.system-message.me-message { font-style: italic; }` on top of the
  `.system-message` centered pill (`:1334-1347`). `/slap` and `/hug` arrive as `/me` content too.
- Flutter: No `/me` path anywhere in the renderer. `message_row.dart` always builds a normal
  IRC/bubble row; `message_content.dart`/`nym_format.dart` have no `/me` handling (grep confirms zero
  hits). The literal text `/me waves` renders as a normal message bubble showing "/me waves".
- Gap: Every emote (`/me`, `/slap`, `/hug` — which the context-menu Slap/Hug actions and the swipe
  slap/hug actions all dispatch) renders as raw `/me …` text instead of the styled italic action line.
- Fix approach: In `message_row.dart build()`, branch when `message.content.startsWith('/me ')` to a
  dedicated `_buildActionMessage` that renders a centered italic line `* author#suffix <action> *`
  (action via `MessageContent` on `content.substring(4)`), styled like the system-message pill
  (`c.textDim`, italic, centered, rounded pill bg `white@0.03`, border `glassBorder`). Author should
  use the purple/secondary accent + inline avatar like the PWA.
- Effort: M  Risk: low  Confidence: high

### F4: In-list system messages are not rendered (only surfaced as SnackBars)  [SEVERITY: medium]
- PWA: `messages.js:1511-1529` `displaySystemMessage` appends a centered `.system-message` (or
  `.action-message`) div into the message container, inline in the conversation flow. Styling
  `styles-chat.css:1334-1360`: centered pill, `max-width:fit-content`, text-dim, `border-radius:20px`,
  `font-size: calc(user-text-size - 3px)`; `.action-message { color: var(--purple); font-style:italic }`.
  Used for command feedback, flood/spam notices, "Message copied", retis, etc.
- Flutter: `composer.dart:110-115` `_onSystemMessage` shows a `SnackBar` instead of an in-conversation
  pill, and that's the only system-message sink. There is no `.system-message`/`.action-message`
  equivalent in `messages_list.dart` (the list renders only `Message` rows).
- Gap: System notices appear as transient bottom snackbars rather than persistent centered pills in
  the timeline — different placement, different lifetime, and no `.action-message` purple variant.
- Fix approach: Model system messages as list entries (a lightweight sealed `ChatEntry` of
  `MessageEntry | SystemEntry`, or inject synthetic `Message`s with an `isSystem` flag) and render a
  centered pill in `messages_list.dart`/`message_row.dart` (text-dim, `textSize-3`, rounded-20 pill,
  `white@0.03` bg, `glassBorder`); add the purple-italic `.action-message` variant. Keep the snackbar
  only as a fallback if a separate channel isn't wired.
- Effort: M  Risk: med  Confidence: med

### F5: Flooded and spam-gated message visual states are missing  [SEVERITY: medium]
- PWA: `messages.js:652-656` adds `class="message flooded"` for messages from a flooding pubkey in
  the current channel (`isFlooding`). CSS `styles-chat.css:61-63` `.message.flooded { opacity:0.2; }`.
  Spam-gated own messages surface a `.system-message` with a "Report false positive" button
  (`messages.js:643-647`), and `.message.blocked { display:none }` (`:57-59`).
- Flutter: `messages_list.dart`/`message_row.dart` have no `flooded`/`spamGated` styling. The model
  carries `spamGated`/`blocked` fields (`message.dart:52-53,110-113`) and the provider filters blocked
  (`app_state.dart:1755-1759`), but flooding produces no dimmed (`opacity 0.2`) row, and there's no
  spam "report false positive" affordance.
- Gap: Flood spam is shown at full opacity instead of the PWA's 0.2 dim; the spam false-positive
  reporting path is absent.
- Fix approach: Thread an `isFlooding(pubkey, channel)` check (logic exists in app_state/controller)
  into `MessageRow`; wrap the row in `Opacity(0.2)` when flooded. Add the spam false-positive
  system-message affordance (depends on F4's system-message rendering).
- Effort: M  Risk: low  Confidence: med

### F6: Emoji-only messages are not enlarged  [SEVERITY: medium]
- PWA: `messages.js:922-924` tags content as `emoji-only` when `isEmojiOnly(content)` or
  `isCustomEmojiOnly(content)` (1-6 emoji, optional whitespace, no other text — `messages.js:1424-1430`,
  regex `_RX_EMOJI_ONLY`). CSS `styles-chat.css:835-837` `.emoji-only .emoji { font-size:2.5em }` and
  `:848-852` `.emoji-only .custom-emoji { width:2.75em; height:2.75em }`.
- Flutter: No emoji-only detection in the render path. `message_content.dart` always renders
  `EmojiNode` at a fixed `size * 1.25` (`:247`) and custom emoji at fixed `22×22` (`:263-272`).
  `nym_format.dart` only references emoji in comments; there is no `isEmojiOnly` (grep: 1 hit, the
  formatter, none in render).
- Gap: A message that is just "🎉🎉🎉" renders at inline size instead of the PWA's large 2.5em emoji.
- Fix approach: Add an `isEmojiOnly` helper (port `_RX_EMOJI_ONLY`, 1-6 emoji units) to
  `nym_format.dart`/`message_content.dart`; when true, scale `EmojiNode` to ~`size*2.5` and
  `CustomEmojiNode` images to ~`2.75em` (≈ `size*2.75`). Thread a flag from `MessageContent` down to
  `_RichInline`.
- Effort: M  Risk: low  Confidence: high

### F7: IRC layout omits the `(edited)` indicator  [SEVERITY: medium]
- PWA: `messages.js:931-939`. Edited messages get BOTH a bubble indicator
  (`.bubble-time-inner .edited-indicator`, shown only in `.chat-bubbles`) AND an IRC indicator
  `<span class="edited-indicator edited-indicator-irc">(edited)</span>` after `.message-content`. CSS
  `styles-chat.css:1549-1574`: `.edited-indicator` = 10px text-dim italic opacity 0.7;
  `.edited-indicator-irc` = `display:block; text-align:right; margin-top:2px; margin-left:auto`
  (visible in IRC mode, `display:none` in bubble mode).
- Flutter: `message_row.dart:261-265` renders an `'edited '` prefix **only in the bubble layout**
  (`_buildBubble`). `_buildIrc` (`:119-215`) has no `(edited)` text at all.
- Gap: In IRC mode (the default non-bubble layout) edited messages give no "(edited)" hint.
- Fix approach: In `_buildIrc`, after the content column add a right-aligned
  `Text('(edited)', style: 10px italic c.textDim @0.7)` when `message.isEdited`. (Bubble already
  matches; note PWA uses literal `(edited)` with parentheses — Flutter bubble currently shows
  `edited ` without parens, a minor copy mismatch worth aligning.)
- Effort: S  Risk: low  Confidence: high

### F8: Composer quote/edit preview chips absent — quote is inlined into the input  [SEVERITY: medium]
- PWA: `messages.js:1816-1859` (`setQuoteReply`/`clearQuoteReply`) and `:1861-1919`
  (`startEditMessage`/`cancelEditMessage`) hold a `pendingQuote`/`pendingEdit` state shown as a chip
  ABOVE the composer (`index.html:720-745`: `#editPreview` with bar+label "Editing message"+text+×,
  `#quotePreview` with bar+author+text+×). The raw quote (`> @author: …`) is prepended only at SEND time
  (`messages.js:2354-2361`). CSS `styles-chat.css:1412-1494`: `.quote-preview` absolute `bottom:100%`,
  bg `bg-tertiary`, `border-radius: md md 0 0`, 3px primary `.quote-preview-bar`, author 12px/600
  primary, text 12px text-dim ellipsis, `quoteSlideIn` 0.2s animation.
- Flutter: `composer.dart:79-96` `_applyComposerAction` **inlines** the quote directly into the text
  field (`'> @$fullNym: $content\n…'`) and there is no preview chip, no edit-preview bar, no × cancel.
  Edit mode is not wired through a chip at all.
- Gap: No visible quote/edit chip above the input; the user sees raw `> @author:` markdown in their
  textbox instead of a styled reply preview, and editing has no preview affordance.
- Fix approach: Prior-audit **D5**, state-layer-gated. Add `pendingQuote`/`pendingEdit` to the
  composer/controller state; render a chip above the `_input` (a `bottom:100%`-style banner with a 3px
  primary left bar, author 12px primary 600, 1-line text-dim preview, × close) and prepend the quote
  only inside `sendCurrent` at send time (not into the visible text). Reuse the slide-in animation.
- Effort: M  Risk: med  Confidence: high

### F9: Image-gallery grid geometry differs (3-up tall-first, max-widths, single-image size)  [SEVERITY: medium]
- PWA: `message-format.js:205-216` collapses adjacent media into
  `.message-gallery` with `gallery-2`/`gallery-3`/`gallery-4plus`. CSS `styles-chat.css:987-1023`:
  gallery is `display:grid; gap:4px; max-width:420px; border-radius: var(--radius-sm)`. `gallery-2` =
  `1fr 1fr`; `gallery-3` = `1fr 1fr` with **`:first-child { grid-row: span 2 }`** (tall left image);
  `gallery-4plus` = `1fr 1fr` (2-column wrap). Each cell is `width/height:100%`, `max-height:220px`,
  `object-fit:cover`. A single image (`styles-chat.css:1029-1034`) is `max-width:300px;
  max-height:300px; min-height:80px`.
- Flutter: `message_content.dart:538-562` `_MediaGallery` uses `GridView.count` with
  `crossAxisCount = 2 | 3 | 4` (so a 3-image gallery is **3 columns** not 2-cols-with-tall-first; a
  4-image gallery is **4 columns** not a 2×2 wrap), `maxWidth:300` (PWA 420), tiles `maxSize:150`. A
  single image is `maxSize:300` square-ish.
- Gap: 3-image and 4+-image galleries have the wrong column count and lose the PWA's
  hero-tall-first-of-three layout; overall width is 300 vs 420; per-tile cap 150 vs 220.
- Fix approach: Rework `_MediaGallery`: always 2 columns for 2/3/4+; for 3 items make the first item
  span 2 rows (`StaggeredGrid`/custom layout or a `Row` of [tall left] + [Column of 2 right]); set the
  container `maxWidth:420`, tile `max-height:220`, gap 4, radius sm. Keep single-image at
  `max 300 × 300, min-height 80`.
- Effort: M  Risk: med  Confidence: high

### F10: "Blur others' images" privacy setting is not applied  [SEVERITY: medium]
- PWA: `messages.js:1267-1274`. For non-own senders, when `blurOthersImages === true` (or
  `'friends'` and the sender isn't a friend) every `<img>` in the message gets `class="blurred"`.
- Flutter: No blur is applied to gallery/inline images in `message_content.dart` `_MediaTile`
  (`:564-613`) — images always render sharp. No `blurOthersImages` read in the render path
  (grep: 0 hits in lib for `blurOthers`/`blurred`).
- Gap: Users who enabled image blurring still see other users' images unblurred.
- Fix approach: Read the blur setting from `settingsProvider`, pass an `isOwn`/`isFriend`-derived
  `blur` flag down to `_MediaGallery`/`_MediaTile`, and wrap the image in an `ImageFiltered`
  (gaussian) + a tap-to-reveal, matching the PWA's `.blurred` (tap removes blur).
- Effort: M  Risk: low  Confidence: med

### F11: Empty-state copy + loading skeleton differ  [SEVERITY: low]
- PWA: empty channel/PM shows a shimmering skeleton first (`.msg-skeleton` with `sk-avatar`/`sk-line`/
  `sk-time` shimmer bars, `styles-chat.css:1980-2028`) and only settles to the note
  **"No recent messages"** (`messages.js:3043-3052,3069`, `.msg-empty-note`).
- Flutter: `messages_list.dart:31-41` shows a static centered **"No messages yet"** (13px text-dim),
  with no skeleton/shimmer.
- Gap: Different empty-state wording ("No messages yet" vs "No recent messages") and no loading shimmer
  while history streams in.
- Fix approach: Change the empty text to "No recent messages" and add a simple shimmer skeleton
  placeholder (a few `sk-line`/`sk-avatar` shimmer bars) shown while messages are still loading.
- Effort: S  Risk: low  Confidence: high

### F12: Messages-container padding + background differ from the PWA  [SEVERITY: low]
- PWA: `messages.js`/`styles` — `.messages-container` bg `rgba(0,0,0,0.15)`, padding **8px 20px 16px**
  (comment confirmed in `messages_list.dart:28`).
- Flutter: `messages_list.dart:62` uses `EdgeInsets.fromLTRB(20, 8, 20, 16)` (matches) and bg
  `Colors.black.withValues(alpha:0.15)` (matches). NOTE: this one looks correct — flagging only to
  confirm the gallery/bubble horizontal insets don't double up. **Likely no change needed**; verify
  the bubble layout's per-row `fromLTRB(14, …, 14, …)` (`message_row.dart:339-342`) plus the list's 20px
  doesn't over-indent vs the PWA's single 20px.
- Gap: Possible double horizontal padding in bubble mode (list 20 + row 14 = 34 vs PWA ~20).
- Fix approach: If over-indented, drop the row-level 14px horizontal padding in bubble mode (the list
  already supplies 20px), or reduce the list padding. Verify visually.
- Effort: S  Risk: low  Confidence: low

### F13: Mention `#`-suffix color/size and channel-chip active tint differ slightly  [SEVERITY: low]
- PWA: a `.nm-mention` renders `@name` + `<span class="nym-suffix">#xxxx</span>`; mentions/self use
  theme primary/secondary. Channel refs: `.channel-reference` underlined; geohash refs add
  `.geohash-reference`; active channel adds `.active-channel`. (`message-format.js:218-249`.)
- Flutter: `message_content.dart` `_MentionChip` (`:302-333`) renders the suffix at
  `c.primaryA(0.6)` and `size*0.92`; `_ChannelChip` (`:335-361`) tints the active background at
  `fg.withValues(alpha:0.18)`. These are plausible but the exact suffix opacity and active-chip
  background should be reconciled against the PWA's `.nym-suffix` (typically `text-dim`/reduced-opacity)
  and `.active-channel` styling in `styles-chat.css` rather than hand-picked 0.6/0.18 alphas.
- Gap: Subtle color/size drift on mention suffixes and the active-channel chip background.
- Fix approach: Pull the exact `.nym-suffix`, `.nm-mention`, `.channel-reference.active-channel`,
  `.geohash-reference` rules from `styles-chat.css` and map them to the chip styles. Low priority.
- Effort: S  Risk: low  Confidence: low

### F14: Reaction pill row spacing/size minor drift  [SEVERITY: low]
- PWA: `styles-chat.css:414-488`. `.reaction-badge` padding `3px 8px`, `border-radius:20px`,
  `font-size:12px`, `gap:3px`, `transition:all 0.2s`, hover `scale(1.05)`, active `scale(0.95)`,
  user-reacted bg `primary@0.12`/border `primary@0.35`/`box-shadow 0 0 10px primary@0.1`.
  `.add-reaction-btn` padding `4px 8px`, `radius 20px`, `opacity:0.6`, svg `16×16` filled `var(--text)`.
- Flutter: `message_row.dart:579-650`. `_ReactionBadge` padding `8h×3v` (≈ matches), radius 20,
  `fontSize:12`, user-reacted `primaryA(0.12)`/border `primaryA(0.35)` (matches) but **no glow
  box-shadow** and **no hover/active scale**. `_AddReactionBtn` padding `8h×4v`, radius 20,
  `opacity 0.6`, uses an `Icons.add_reaction_outlined` 14px (PWA is a 16px "+smiley" SVG filled
  `var(--text)`).
- Gap: Missing user-reacted glow halo and hover/press scale; add-button icon is a different glyph/size.
- Fix approach: Add the `box-shadow 0 0 10px primary@0.1` (a soft `BoxShadow`) on user-reacted badges;
  add an `AnimatedScale` on tap-down/hover; bump the add-reaction icon to 16px. Cosmetic.
- Effort: S  Risk: low  Confidence: med

### F15: Quote-block author chip + tint differ from the PWA blockquote  [SEVERITY: low]
- PWA: `message-format.js:319-323` renders `<blockquote><span class="quote-author">author#suffix:</span>
  …</blockquote>` where the suffix is a `.nym-suffix`. The blockquote uses the standard `<blockquote>`
  styling (left bar + tinted bg from `styles-chat.css`).
- Flutter: `message_content.dart:482-534` `_QuoteBox` left-borders at `c.secondaryA(0.6)` width 2, bg
  `c.secondaryA(0.05)`, author `c.secondary` 600 `size-1`, body `c.textDim` `size-1`. The author is
  rendered as one `Text('$author:')` — the `#xxxx` suffix is NOT visually de-emphasized as a
  `.nym-suffix` (PWA splits base vs suffix span). Otherwise close.
- Gap: Quote author suffix isn't dimmed; quote bar/bg alphas are hand-picked vs the PWA `<blockquote>`
  rule (verify they match `styles-chat.css` blockquote, not just secondary@0.05/0.6).
- Fix approach: Split the quote author into base + dimmed `#suffix` spans; reconcile the bar color/bg
  alpha against the PWA `<blockquote>` CSS. Minor.
- Effort: S  Risk: low  Confidence: med

### F16: Inline video has no playback; gallery videos render as a static play tile  [SEVERITY: low]
- PWA: `message-format.js:152-166` renders inline `<video controls playsinline preload="metadata">`
  with a fullscreen-expand button; `messages.js:1276-1304` wires iOS blob fallback; tap-expand opens the
  image/video modal (`expandVideo`, `messages.js:1457-1509`).
- Flutter: `message_content.dart:574-585` `_MediaTile` renders videos as a **non-interactive** dark
  tile with a `play_circle_fill` icon ("no playback yet" per the file's own comment `:537`). No inline
  player, no expand-to-modal.
- Gap: Videos in messages can't be played or expanded — only a placeholder tile.
- Fix approach: Likely owned by the media/upload slice, but for parity add a `video_player`/`chewie`
  inline player (or at minimum a tap → fullscreen video route) so the tile is interactive. Note as
  cross-slice.
- Effort: L  Risk: med  Confidence: med

---

## Notes on faithful ports (spot-checked, no change needed)
- **Formatter pipeline** (`nym_format.dart` → `message_content.dart`): markdown subset, code/quote/
  heading blocks, mention/channel/group-invite/channel-link chips, custom-emoji, media-gallery
  collapse, and pass ordering all mirror `message-format.js` (re-confirmed against audit #1-4 fixes).
- **PM tick glyphs** (`message_row.dart:537-574`): single ✓ green `#4CAF50` (delivered), ✓✓ blue
  `#2196F3` (read), ✓ text-dim (sent), ! danger (failed), nothing for `sending` — a 1:1 port of
  `messages.js:837-844` + `styles-chat.css:665-689` (audit #14/#15, verified still correct).
- **Bubble grouping** (`messages_list.dart:44-53`): 5-min same-author window, name+tail collapse,
  sticky avatar on the last bubble of a group — matches `_applyBubbleGroupingTo`
  (`messages.js:1551-1568`). Bubble radius tail corners (`message_row.dart:469-487`) match.
- **Self/mentioned IRC tints** (`message_row.dart:124-140`): self bg `secondary@0.05` + white@0.30
  3px bar, mentioned bg `secondary@0.06` + secondary 3px bar — matches `styles-chat.css:65-100`
  (the PWA's `::before` bar is `height:60%` centered + a glow `box-shadow`; the Flutter full-height
  `Border(left)` is a reasonable approximation but **omits the mentioned bar's glow**
  `box-shadow 0 0 8px secondary@0.4` and the 60%-height rounded nub — a sub-finding folded into F13).
- **Link-preview gating**: `isInlineMediaUrl` (`link_preview.dart:65-68`) and the "render only with
  title/description" gate (`:49,102`) mirror `ui-context.js:778,815`.

## Incidental (non-UI, noted in passing)
- The `Message` model lacks a readers/read-receipt map, which is the hard blocker for F1 (D4). Adding
  it is a state-layer change (out of this slice's edit scope but required for the F1 fix).
- `bubble-snap` insert animation (`messages.js:1043-1048`, a 320ms pop on a newly grouped bubble) has
  no Flutter equivalent — very minor; could be added with an `AnimatedScale` in `messages_list`.
