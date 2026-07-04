# Gap report — Composer, Autocomplete, Emoji/GIF pickers

**Slice:** message composer + input toolbar/buttons, attachment flow, autocomplete dropdown,
emoji picker, GIF picker, quote/edit preview chips.

**Summary:** The GIF picker is an essentially pixel-faithful port. The emoji picker and the
four autocomplete dropdowns are mostly faithful but each drops 1-2 user-visible affordances the
PWA renders (mention-row avatars + verified/flair/friend badges; channel-row geohash location;
emoji-picker category/pack favorite stars). The biggest gaps are the **quote-reply and edit
preview CHIPS above the composer** (prior audit D5): the PWA shows a colored slide-in chip and
defers the quote/edit until send, whereas Flutter inlines `> @author:` text for quotes and uses a
**modal text-prompt dialog** for edits — two materially different UXs. Toolbar deltas (D6 Nymbot
button present only in Flutter; D7 image-only vs image+video) are confirmed, plus a missing
`#translateInputBtn` and the missing `composer-popout` floating-expand behavior.

**Finding count: 12** (1 blocker, 4 high, 4 medium, 3 low). D5 verified (open). D6 confirmed
(intentional, keep). D7 confirmed (open).

---

### F1: Quote-reply preview chip missing — quote inlined as `> @author:` text  [SEVERITY: high]
- PWA: `messages.js:1816-1859` (`setQuoteReply`/`clearQuoteReply`), `2350-2361` (send-time
  prepend), markup `index.html:733-745` (`#quotePreview`), CSS `styles-chat.css:1412-1494`.
  On "Reply", the PWA sets `this.pendingQuote = {author, text, fullText}` and shows an absolutely
  positioned chip **above** the input (`.quote-preview`: `bottom:100%`, `bg var(--bg-tertiary)`,
  `border 1px var(--glass-border)`, `border-radius radius-md radius-md 0 0`, `padding 8px 12px`,
  `box-shadow shadow-lg`, slide-in `quoteSlideIn 0.2s` from `translateY(8px)`). The chip has a
  3px primary-colored left bar (`.quote-preview-bar`: `width:3px`, `min-height:28px`,
  `background var(--primary)`, `radius 2px`), a 2-line content column (author in 12px/600
  `var(--primary)` ellipsized; text in 12px `var(--text-dim)` ellipsized, truncated to 120 chars
  with markdown stripped, custom emoji rendered), and an `✕` close button
  (`.quote-preview-close`, 16×16 svg, hover `#fff` on `rgba(255,255,255,0.1)`). The user's typed
  text stays clean; the quote is prepended ONLY at send as `> @author: line0\n> line1…\n\n<text>`.
  Esc cancels (`ui-context.js:1018`).
- Flutter: `composer.dart:86-91` (`_applyComposerAction` → `QuoteAction`) — immediately writes
  `'\n> @$fullNym: $content\n' + existing` **into the TextField text**. No chip widget exists;
  `pendingComposerActionProvider` only carries `MentionAction`/`QuoteAction`
  (`interaction_hooks.dart:68-99`), and `nostr_controller.dart` has **no** `pendingQuote` state or
  `nymquote` send-time tag.
- Gap: User-visible — the reply target is dumped as raw `> @author:` markdown the user must not
  delete, instead of a dismissable chip. No left-bar color cue, no slide-in, no truncation, no
  separate author styling, and the quote can't be edited/removed as a unit. Also loses the PWA's
  `nymquote` reply semantics (handled at send).
- Fix approach: Add composer state `({String author, String text})? _pendingQuote`. Build a
  `_QuotePreviewChip` widget (Row: 3px `c.primary` bar + Column[author `c.primary` 12/w600,
  text `c.textDim` 12 ellipsis] + close IconButton) rendered above `_input` inside the
  `Container` in `build()` (between `_uploadBar` and the input). Change `QuoteAction` handling to
  set `_pendingQuote` (strip nested `>` lines, trim, cap 120) instead of writing to the field. In
  `_send()`, if `_pendingQuote != null`, prepend
  `'> @$author: ${lines.first}' + (lines.length>1 ? '\n'+lines.skip(1).map((l)=>'> $l').join('\n') : '') + '\n\n'`
  before passing to `sendCurrent`, then clear. Animate with `AnimatedSize`/`SlideTransition`
  (0.2s, dy 8→0).
- Effort: M  Risk: med  Confidence: high

### F2: Edit uses a modal prompt dialog instead of inline composer + edit-preview chip  [SEVERITY: high]
- PWA: `messages.js:1861-1919` (`startEditMessage`/`cancelEditMessage`), markup
  `index.html:720-732` (`#editPreview`), CSS `styles-chat.css:1496-1547`. "Edit" populates the
  composer input with the original `content` (`input.value = content`), focuses it, and shows the
  `.edit-preview` chip above the input — identical layout to the quote chip but with an **amber**
  left bar (`.edit-preview-bar` `background:#f0ad4e`) and a fixed label "Editing message" in
  `#f0ad4e` 12px/600 plus the truncated original text (`.edit-preview-text` `var(--text-dim)`).
  Editing then happens **on the next send** (the input already holds the text). Close button
  `#editPreviewClose` (title "Cancel edit") clears `pendingEdit` and empties the input
  (`ui-context.js:269-270`). Starting an edit also clears any pending quote (`messages.js:1896`).
- Flutter: `context_menu_panel.dart:412-415, 458-472` — `CtxAction.edit` opens a **modal text
  dialog** via `_promptEdit(context, original)`, then calls
  `nostrController.editMessage(messageId, trimmed)` (`nostr_controller.dart:1284`). The
  underlying `editMessage` (channel/PM/group) is complete, but the UX is a popup, not the inline
  composer + chip.
- Gap: User-visible UX mismatch. PWA edits feel like "load into composer and resend"; Flutter
  pops a separate dialog. No amber edit chip, no "Editing message" affordance in the composer, no
  Esc-to-cancel-into-empty-input, and editing a multiline message in a small dialog is worse.
- Fix approach: Add an `EditAction(messageId, content)` to the `ComposerAction` sealed set
  (`interaction_hooks.dart`) + `requestEdit` on `InteractionHooks`. In `context_menu_panel._edit`
  call `ref.read(pendingComposerActionProvider.notifier).requestEdit(...)` instead of the dialog.
  In `composer.dart`, on `EditAction`: set `_pendingEdit = messageId`, set
  `_controller.text = content`, clear `_pendingQuote`, focus. Render a `_EditPreviewChip`
  (amber `#F0AD4E` bar, "Editing message" label `#F0AD4E` 12/600, dim truncated text, close).
  In `_send()`, if `_pendingEdit != null` route to `editMessage(_pendingEdit!, text)` (not
  `sendCurrent`) and clear. Remove `_promptEdit`/`_edit` dialog path.
- Effort: M  Risk: med  Confidence: high

### F3: Mention autocomplete rows show a status DOT, not the PWA's avatar + verified/flair/friend badges  [SEVERITY: high]
- PWA: `autocomplete.js:350-446` (`_createAutocompleteItem`/`_reconcileAutocompleteItems`), CSS
  `styles-components.css:739-806`. Each mention row is: an 18×18 avatar image
  (`.user-avatar-wrap` `width/height:18px`, `margin-right:4px`) with a status dot **overlaid**
  (`.user-status-dot status-<online|away|offline|hidden>`; `.no-status` when hidden), then
  `<strong>` containing `.ac-name-text` (`@base`, ellipsized) + `.nym-suffix` (`#sfff`,
  `opacity:0.7`, `font-size:0.9em`, `font-weight:100`), then optional **flair** HTML, a
  **verified badge** `✓` (`.verified-badge`, for dev/bot), and a **friend badge**. Selected/hover
  row: `background rgba(255,255,255,0.08)`, `color var(--text)`, `border-radius radius-xs`.
- Flutter: `autocomplete_dropdown.dart:174-205` (`_mentionRow`) — renders only an 8×8 colored
  `_statusDot` (`#22C55E`/`#EAB308`/dim) + `@base` (primary/bold) + `#suffix` (primary@0.7,
  w100, 13px). No avatar image, no flair, no `✓` verified badge, no friend badge.
- Gap: User-visible — mention dropdown looks bare vs the PWA's avatar-led rows; verified bots/devs
  and friends are not distinguishable, and the avatar (the primary visual identifier) is absent.
- Fix approach: In `_mentionRow`, replace the bare `_statusDot` with an 18×18 avatar stack:
  `CircleAvatar`/`CachedNetworkImage` of `getAvatarUrl(pubkey)` with the status dot as a small
  `Positioned` overlay (bottom-right). Append, after the name spans: flair widget (if the
  state-layer flair lookup is reachable), a `✓` badge for `isVerifiedDeveloper`/`isVerifiedBot`,
  and a friend badge. `MentionResult` currently lacks pubkey/flair/verified flags — extend it in
  `autocomplete_queries.dart` (it already ranks by status so the user objects are in hand).
  NOTE: flair/verified/friend sources may live in another slice; if unreachable, ship the
  avatar + overlaid status dot (the highest-impact part) and note the badges as a sub-deferral.
- Effort: M  Risk: med  Confidence: med

### F4: Channel autocomplete rows omit the geohash LOCATION name  [SEVERITY: medium]
- PWA: `autocomplete.js:592-630` (`_renderChannelAutocompleteItems`), CSS
  `styles-components.css:823-847`. Row = `#name` (`<strong>` primary), optional `current` badge
  (`.channel-ac-badge`: `font-size:0.7em`, `background var(--primary)`, `color var(--bg)`,
  `padding:1px 5px`, `radius-xs`, `margin-left:4px`), then for valid geohash channels a
  **location name** `.channel-ac-location` (`getGeohashLocation(name)`, e.g. a city/region,
  `font-size:0.8em`, `opacity:0.5`), then a right-aligned count `.channel-ac-count`
  (`N msg(s)`, `0.75em`, `opacity:0.4`, `margin-left:auto`). Joined channels get a `.joined`
  class.
- Flutter: `autocomplete_dropdown.dart:207-238` (`_channelRow`) — `#name`, `current` pill, and
  `N msgs` only. **No geohash location** is rendered (and the message-count pill uses `Spacer()`
  so it sits where the location should differentiate).
- Gap: User-visible — for geohash channels the human-readable place name (a key disambiguator,
  e.g. "London" for `gcpv…`) is missing, so channels read as opaque geohash strings.
- Fix approach: Add an optional `location` to `ChannelResult` populated by a geohash→location
  lookup in `queryChannels` (the PWA's `isValidGeohash`+`getGeohashLocation`; reuse the globe/
  geohash module if exposed). In `_channelRow` insert a `Text(location, 0.8em, c.textDim@0.5)`
  between the badge and the count. If `getGeohashLocation` lives in another slice and is
  unreachable, note as a sub-deferral but render whatever location field already exists on the
  channel model.
- Effort: S  Risk: low  Confidence: med

### F5: Emoji picker missing category-favorite and pack-favorite STAR toggles  [SEVERITY: medium]
- PWA: `emoji.js:446-519` (`_emojiCategoryFavButtonHtml`, `buildCustomEmojiSectionsHtml`),
  `534-557` (`_emojiSectionsHtml`), `391-444` (favorite logic + reorder), CSS
  `styles-components.css:1269-1380`. Each default-category title row (`.emoji-default-cat-title`,
  flex space-between) carries a star button `.emoji-category-fav-btn` (14×14 svg, `padding:2px 4px`,
  `color var(--text-dim)`, hover `var(--primary)`, **active `#f5c518`** filled). Each custom-pack
  title (`.emoji-pack-title`) carries `.emoji-pack-fav-btn` (active `#f5c518`, see 1300-1304).
  Favoriting reorders that category/pack to the top of its block live and persists
  (`nym_emoji_category_favorites` / `nym_emoji_pack_favorites`); favorited/subscribed/own packs
  also sort first and get a ` ★` title suffix (`emoji.js:487-507`).
- Flutter: `emoji_picker.dart:280-364` (`_section`/`_GridSection`) — section titles are plain
  text (10px uppercase dim, letter-spacing 1) with **no star button** and no favorite/reorder
  behavior. Pack ordering uses `custom.packs` order, not the PWA's fav→own→subscribed→rest rank.
- Gap: User-visible — users can't pin frequently-used categories/packs to the top; the star
  affordance and the ` ★` suffix on own/subscribed packs are absent.
- Fix approach: Persist two `List<String>` prefs (category keys, pack keys) via `EmojiPrefs*`.
  Add a trailing `IconButton`(star, 14px, active `#F5C518`) to each `_GridSection` title row
  (pass an `onToggleFavorite`+`isFavorite` into `_Section`). Reorder `kEmojiCategoryOrder`
  (favorited first) and `custom.packs` (fav→own→subscribed→created_at) before building sections.
  Append ` ★` to own/subscribed pack titles. Pack own/subscribed flags come from
  `CustomEmojiState`/state layer — wire if reachable, else ship category favorites alone.
- Effort: M  Risk: med  Confidence: med

### F6: Image toolbar button is image-only; PWA accepts image AND video (D7)  [SEVERITY: medium]
- PWA: `index.html:759-766` — the file input is
  `accept="image/*,video/mp4,video/webm,video/ogg,video/quicktime"` `multiple`, and the button
  `title="Upload Image/Video"` (`data-action="selectImage"`).
- Flutter: `composer.dart:401-441` (`_pickAndUploadImage`) uses
  `ImagePicker().pickImage(source: ImageSource.gallery)` (images only, single file), tooltip is
  `'Image'` (`composer.dart:676`), and the upload-bar label is hardcoded `'Uploading image…'`
  (`composer.dart:548`).
- Gap: User-visible — users cannot attach a video from the composer (PWA can), the tooltip
  understates the capability, and multi-select is unsupported.
- Fix approach: Switch to `ImagePicker().pickMedia()` (or `FilePicker` with
  `type: FileType.media`) to allow image+video; set tooltip `'Upload Image/Video'`; make the
  upload-bar label depend on the picked mime (`'Uploading video…'` for `video/*`). `_guessImageMime`
  already maps mp4/webm. (Per audit D7 the actual video-upload pipeline may be owned by the media
  slice — at minimum fix the tooltip + accept filter so the affordance matches.)
- Effort: S  Risk: low  Confidence: high

### F7: Composer `#translateInputBtn` (in-input translate button + language dropdown) missing  [SEVERITY: medium]
- PWA: `index.html:749-755`, CSS `styles-chat.css:1758-1820+`. Inside `.message-input-row` sits a
  26×26 translate button (`.translate-input-btn`: absolute `right:8px bottom:10px`, `radius 4px`,
  `color var(--text-dim)`, `opacity:0.6`, hover `var(--primary)` on `rgba(255,255,255,0.08)`,
  `.translating` pulse animation) plus a 230px language-picker dropdown (`.translate-input-dropdown`,
  `bottom:100%+4px`, `right:0`, search + list). It translates the typed draft before sending.
- Flutter: `composer.dart` — **no translate button** anywhere in `_input`/`_textField`/`_toolbar`
  (grep for "translate" returns nothing in the composer).
- Gap: User-visible affordance absent; users can't translate their outgoing draft from the
  composer.
- Fix approach: Add a small overlaid `IconButton` (translate glyph, 26×26, `c.textDim`@0.6,
  hover→primary) anchored bottom-right inside the `_textField` Stack, opening a language dropdown.
  NOTE: translation logic lives in the translate slice (`js/modules/translate.js`); if no Flutter
  controller entry point is reachable, treat as a cross-slice deferral but still place the button +
  dropdown shell so the layout matches.
- Effort: M  Risk: med  Confidence: med

### F8: Composer `composer-popout` floating-expand behavior not replicated  [SEVERITY: medium]
- PWA: `ui-context.js:1726-1759` (`_refreshComposerOffsets` + popout toggle), CSS
  `styles-chat.css:1721-1756`. When the draft exceeds ~1.5 lines the container gets
  `.composer-popout`: the input detaches to an absolutely-positioned floating box
  (`position:absolute; bottom:0; max-height:min(40vh,360px)`, `bg var(--bg-tertiary)`,
  `border primary@0.3`, `border-radius radius-md` (all corners), `box-shadow shadow-lg`,
  `z-index:12`) that overlays upward, and the quote/edit/autocomplete layers shift by
  `--popout-overhang` and raise to `z-index:20`.
- Flutter: `composer.dart:624-669` (`_textField`) uses an inline `TextField` with
  `maxLines:5, minLines:1` that simply grows in place (bottom-rounded radius only); there is no
  floating popout, no all-corner radius, no `bg-tertiary` swap, and no overhang offset for the
  dropdowns/chips.
- Gap: Visual — for long multi-line drafts the PWA shows a distinct elevated rounded box; Flutter
  just grows the bordered field, and the autocomplete/quote chips don't re-anchor above the
  expanded box (they're already overlay-anchored in Flutter, so this is mostly cosmetic, but the
  rounding/elevation/bg differ).
- Fix approach: When line-count/extent exceeds ~1.5 lines, switch the field decoration to
  all-corners `NymRadius.md`, fill `c.bgTertiary`, border `c.primaryA(0.3)`, add `shadow-lg`, and
  cap height at `min(40vh, 360)`. Lower priority since Flutter's overlay anchoring already keeps
  dropdowns above the input.
- Effort: M  Risk: low  Confidence: med

### F9: Input placeholder text differs from the PWA  [SEVERITY: low]
- PWA: `index.html:748` — `data-placeholder="Message, / for commands, ? for Nymbot..."`
  (rendered via `div.message-input:empty::before`, color `rgba(255,255,255,0.4)`,
  `styles-chat.css:1697-1700`).
- Flutter: `composer.dart:640` — `hintText: 'Type a message…'`.
- Gap: User-visible — the PWA placeholder teaches the `/` command and `?` Nymbot affordances;
  Flutter's generic hint loses that discoverability.
- Fix approach: Set `hintText: 'Message, / for commands, ? for Nymbot...'` in `_textField`
  (and keep `hintStyle` colour ≈ `c.textDim` ~ `rgba(255,255,255,0.4)`).
- Effort: S  Risk: low  Confidence: high

### F10: Toolbar button spacing / icon hover color minor mismatches  [SEVERITY: low]
- PWA: `styles-chat.css:1914-1965` — `.input-buttons { gap:5px }`; `.icon-btn.input-btn`
  `padding:0 12px` (no explicit border), icon svg stroke `var(--text)` → hover `var(--primary)`;
  `.send-btn padding:10px 22px`, hover glow `box-shadow 0 0 15px primary@0.1`.
- Flutter: `composer.dart:703,714` use `SizedBox(width:6)` between buttons (PWA 5px);
  `_IconBtn` (`807-846`) draws a `Border.all(c.glassBorder)` the PWA's input-btn does **not** have,
  icon color static `c.text` with **no hover→primary**; `_SendButton` has no hover glow.
- Gap: Visual — icon buttons carry an extra border outline, no hover affordance on icons/send, and
  1px-off gap. Minor but noticeable side-by-side.
- Fix approach: Set inter-button gap to 5; drop the `Border.all` on `_IconBtn` (the PWA input-btn
  is borderless — only the picker/send buttons differ); add hover state (`MouseRegion`/
  `onHover`) switching icon to `c.primary` and a send-btn glow shadow on hover. (Desktop/web only;
  low priority on touch.)
- Effort: S  Risk: low  Confidence: high

### F11: `#uploadProgress` chip lacks the PWA's cancel (✕) button  [SEVERITY: low]
- PWA: `index.html:708-719` — the upload-progress block has a `.upload-progress-close`
  button (`data-action="cancelUpload"`, 16×16 ✕) top-right, a label `#uploadProgressLabel`, and a
  `.progress-bar > .progress-fill`.
- Flutter: `composer.dart:541-562` (`_uploadBar`) renders the label + `LinearProgressIndicator`
  only — **no cancel button**.
- Gap: User-visible — an in-flight upload cannot be cancelled from the UI (the PWA can).
- Fix approach: Add a trailing ✕ `IconButton` to `_uploadBar` wired to cancel the upload
  (the `uploadImage` future/cancel token must be exposed by the controller; if not cancellable,
  at least hide the bar + abort the append).
- Effort: S  Risk: low  Confidence: med

### F12: Autocomplete dropdown max-height / `bg` minor parity  [SEVERITY: low]
- PWA: `styles-components.css:718-732` — `.autocomplete-dropdown`/`.emoji-autocomplete`
  `max-height:150px`, `bg var(--bg-tertiary)`, `border 1px var(--glass-border)`, top-rounded
  `radius-md`; `.command-palette` (`849-863`) uses `bg rgba(20,20,35,0.9)`, `padding:6px`,
  `max-height:200px`. Selected/hover row radius is `radius-xs` (`796-801`).
- Flutter: `autocomplete_dropdown.dart:89-100` — `maxHeight:150` ✓, `bgTertiary` ✓, top radius
  `16` (PWA `radius-md`; verify md==16), but the selectable row uses `borderRadius 8`
  (`_selectable`, line 153) vs the PWA's `radius-xs` (typically 4). Command palette
  (`command_palette.dart`, not in this slice's owned set but rendered by the composer) should use
  `rgba(20,20,35,0.9)` / 200px — verify.
- Gap: Visual nuance — selected-row corner radius is ~2× the PWA's; otherwise close.
- Fix approach: Change `_selectable` row radius from 8 to `NymRadius.xs` (4) to match
  `.autocomplete-item.selected { border-radius: var(--radius-xs) }`. Confirm the command-palette
  bg/padding/max-height match the PWA values.
- Effort: S  Risk: low  Confidence: high

---

## Verified deferrals (from docs/audit/05-commands-format-interactions.md)

- **D5 (quote/edit preview chips):** OPEN — see F1 (quote chip) + F2 (edit chip/flow). The PWA
  `pendingQuote`/`pendingEdit` chip model is unimplemented; quote is inlined, edit uses a dialog.
- **D6 (Nymbot toolbar button):** CONFIRMED intentional. Flutter `composer.dart:688-693` adds an
  `Icons.smart_toy_outlined` "Nymbot" button absent from the PWA `.input-buttons`
  (`index.html:758-789` = Image/Video, P2P File, Emoji, GIF, SEND). It is the app's only bot-PM
  entry point here (`_openBotChat`), so **keep it** — but if the PM-list/bot-discovery entry is
  added by another slice, remove this to match the PWA's 5-button toolbar. No action now.
- **D7 (image-only vs image+video upload):** OPEN — see F6. Tooltip + accept filter + label can be
  fixed in-slice even if the video pipeline is owned elsewhere.

## Confirmed NON-gaps (do not "fix")

- **Skin-tone selector:** the PWA emoji picker has **no** skin-tone picker
  (`1F3FB-1F3FF` appears only in emoji-detection regexes in message-format.js / translate.js /
  messages.js, not in any picker UI). Flutter correctly omits it. Not a gap.
- **GIF picker:** faithful port. Trending-on-open, 500ms search debounce (`gif_picker.dart:224`
  ↔ `ui-context.js:2045`), 2-col grid, Favorites-above-Trending section labels, per-tile star
  toggle (active `c.warning` ↔ `--warning`, `styles-features.css:1665`), `nym_favorite_gifs`
  ≤100, "Powered by GIPHY" attribution — all match `ui-context.js:2003-2186`. No gap found.
- **Emoji autocomplete row:** `autocomplete_dropdown.dart:240-268` (23px glyph + `:name:` 12px)
  matches `autocomplete.js:106-136` and CSS `.emoji-item` (`styles-components.css:808-821`).
- **Kaomoji autocomplete + command palette categories:** row layout / headers match
  (`styles-components.css:849-955`); ranking logic was re-verified faithful by audit 05.
- **Emoji category data + order:** `emoji_data.dart:22-36, 40+` is verbatim from
  `app.js:780-793` (smileys→people→gestures→hearts→symbols→objects→clothing→nature→food→
  activities→travel→weather→flags). 6-col grid (5 ≤480px) matches `styles-components.css:2150`
  + responsive. No gap.

## Incidental (logic, not UI — out of slice, noted only)

- `nostr_controller.editMessage` (`:1284`) does not capture the PWA's `nymMessageId`/isPM/isGroup
  context the way `startEditMessage` (`messages.js:1865-1893`) does; it infers from the current
  `view`. Likely fine since edits happen in the active view, but if F2 is implemented, ensure the
  edit targets the correct conversation when the active view changed after the menu opened.
