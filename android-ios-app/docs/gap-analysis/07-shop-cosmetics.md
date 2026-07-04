# Gap report 07 — Flair Shop modal + cosmetics/flair rendering

**Slice:** Flair Shop modal (tabs, item cards, buy/gift/transfer/redeem) + cosmetic/flair
RENDERING on messages & nyms (styles, glow, gradients, supporter gold, flair badges,
Genesis edition stamps, animated/watermark effects).

**Source of truth:** `pwa/js/modules/shop.js`, `pwa/css/styles-features.css`, `pwa/index.html`.
**Target:** `lib/features/shop/{shop_modal,shop_widgets,shop_catalog,shop_controller,shop_models,cosmetics}.dart`,
`lib/widgets/chat/message_row.dart`, `lib/models/user.dart`.

## Summary
The catalog (51 items, ids/prices/SVGs) and the buy/gift/transfer/redeem **flows** are
faithfully ported. The real, user-visible gaps are concentrated in two areas: (1) **cosmetic
auras are completely unrendered** — the whole `cosmetic-aura-*` / `frost` / `hologram` /
`redacted` class of items is dropped on the way to a rendered message because `UserCosmetics`
has no `cosmetics` field and the User model has no `shopCosmetics`; and (2) the **shop modal is
missing entire sub-features** the PWA renders: per-style/cosmetic **live preview bubbles**,
**legendary ribbon**, **supply/availability badges** (limited tab), **bundle content chips +
save%**, **inventory active-summary / acquired-date / recovery-code / edition-number** blocks,
and **purchase-success recovery-code reveal**. Genesis **edition numbers are never stamped** on
rendered nyms. The prior audit's "animated prism/glitch" deferral is partly moot (the PWA styles
are *static* CSS — no `@keyframes` drive any style/cosmetic) but the **repeating-SVG watermarks**,
**conic-gradient prism ring**, **holographic sheen**, **frost snowflake borders**, **glitch dual
text-shadow**, and **box-shadow glow rings** are genuinely missing.

**Finding count: 16** (2 blocker, 6 high, 5 medium, 3 low).

---

### F1: Active cosmetic auras never render on messages (gold/neon/rainbow/phoenix/cosmic/frost/hologram/redacted)  [SEVERITY: blocker]
- PWA: `shop.js:485-509` (`_applyShopClassesToMessage` adds `cosmetic-*` classes to each `.message`),
  `shop.js:560-579` (applied for self + other users); CSS `styles-features.css:1099-1211` defines the
  8 cosmetic visuals: `cosmetic-aura-gold` (1099-1103: `box-shadow: inset 0 0 0 1px rgba(255,215,0,.35),
  0 0 18px rgba(255,215,0,.18)`, `border-left:3px solid #ffd700`, gold gradient bg), `cosmetic-aura-neon`
  (1105-1113: cyan `#00e5ff` `0 0 22px rgba(0,229,255,.32)`), `cosmetic-aura-rainbow` (1115-1139:
  `@property --prism-angle` + `conic-gradient` ring via mask), `cosmetic-frost` (1141-1167: frosted box-shadow
  + repeating snowflake SVG borders + `rgba(190,230,255,.16)` bg), `cosmetic-aura-phoenix` (1169-1177:
  `#ff6a00` `0 0 26px rgba(255,110,0,.4)`), `cosmetic-aura-cosmic` (1179-1195: `#7c5cff` + starfield SVG bg),
  `cosmetic-bubble-hologram` (1197-1211: holographic gradient sheen). `cosmetic-redacted` (1419-1440) blanks
  the author + replaces content with `████` after 10s.
- Flutter: `cosmetics.dart:21-37` — `UserCosmetics` holds ONLY `styleId`/`flairId`/`supporter`; there is **no
  `cosmetics` list field**. `message_row.dart:96-102` `_styleDecoration` resolves a message-style OR
  supporter-style and nothing else. `user.dart:30-53` carries only `shopStyle`/`shopFlair`/`isSupporter` — no
  `shopCosmetics`. The visual tables exist (`shop_catalog.dart:620-660` `cosmeticVisuals`, used only in the
  shop preview chip `shop_widgets.dart:162-205`) but are never applied to a real message bubble/row.
- Gap: A user who buys + activates any of the 8 special cosmetics sees the shop preview but their actual
  messages render with **zero** aura/glow/frost/hologram/redaction. For self and for other users. The most
  expensive legendary items (Prism 11000, Phoenix 12000, Hologram 13500 sats) are invisible in chat.
  `cosmetic-redacted` (the privacy item) also never blanks messages.
- Fix approach: (a) Add `List<String> cosmetics` to `UserCosmetics` (`cosmetics.dart`); populate it from
  `active.cosmetics` (self) and a new `User.shopCosmetics` list (others — add the field + ingest it in the
  presence/shop-status path that sets `shopStyle`). (b) In `message_row.dart`, after `_styleDecoration`,
  iterate active cosmetics and compose box-shadow/border/gradient/background onto the bubble (`_buildBubble`
  `BoxDecoration`) and the IRC row (`_buildIrc`). Reuse `ShopCatalog.cosmeticVisuals[id]` for accent+gradient;
  add the exact box-shadow inset+glow per id (values above). (c) Implement `cosmetic-redacted`: blank the
  content + dim author after a 10s timer (mirror `shop.js:498-503`). Frost/cosmic/hologram watermarks → see F8.
- Effort: L  Risk: med  Confidence: high

### F2: Genesis (and any numbered) edition number never stamped on rendered nym flair  [SEVERITY: blocker]
- PWA: `shop.js:1135-1145` `_flairIconHtml(id, edition)` injects `<text x=12 y=19.4 font-size=7.5
  font-weight=700>{n}</text>` into the Genesis SVG base; `shop.js:512-528` `_applyFlairBadgesToMessage` passes
  `editions[id]` for every rendered author; `shop.js:1147-1155` `getFlairForUser` and the inventory/preview
  paths all stamp the owner's number. CSS `styles-features.css:1213-1227` gives `.flair-genesis` its gold glow
  AND bolds the whole author nym (`.has-genesis-flair { font-weight:700 }`, suffix back to 400).
- Flutter: `cosmetics.dart:95-128` `CosmeticNymBadges` accepts an `edition` param, and `shop_catalog.dart:519-528`
  `flairIcon(id, edition)` can stamp it — but `message_row.dart:105-110` calls `CosmeticNymBadges(cosmetics: …)`
  **without `edition:`**, so it defaults to null. `UserCosmetics` (`cosmetics.dart:21-37`) has no edition field;
  `resolveCosmetics`/`userCosmeticsFromUser` (`cosmetics.dart:42-69`) drop `active.editions` / there is no
  `User.shopEdition`. The author nym is also never bolded for Genesis holders.
- Gap: Genesis is the headline 25000-sat "only 100 will ever exist" numbered emblem; on every rendered message
  the pyramid shows with **no number** (self and others). The Genesis bold-nym treatment is also absent.
- Fix approach: Add `int? genesisEdition` (or a `Map<String,int> editions`) to `UserCosmetics`; populate from
  `active.editions['flair-genesis']` (self, available at `shop_models.dart:113-126`) and a new `User.shopEdition`
  field for others (ingest from shop-status `active.editions`). Thread it into
  `CosmeticNymBadges(edition: …)` at `message_row.dart:105-110`. When flair is `flair-genesis`, render the
  author nym `fontWeight: w700` (keep suffix w400).
- Effort: M  Risk: low  Confidence: high

### F3: Per-style repeating-SVG watermarks omitted on every textured style (matrix/fire/ice/ghost/ocean/sakura/galaxy/toxic/gold/vapor/blood/royal/circuit/rainbow/satoshi/eclipse/crt)  [SEVERITY: high]
- PWA: `styles-features.css:946-990` — every textured style sets `--style-pattern` to a tiled `data:image/svg+xml`
  drawn behind the content via `.message-content::before { background-image: var(--style-pattern); repeat }`.
  Concrete patterns: satoshi tiled `₿` glyph (`:528/:562`), matrix falling `10/01/11` monospace (`:593`),
  fire flame tiles (`:610`), ice crystals (`:616`), ocean waves (`:735`), sakura petals (`:760`), galaxy stars
  (`:785`), toxic radiation circles (`:810`), gold sparkles (`:839`), vapor grid (`:868`), blood drops (`:893`),
  royal crowns (`:918`), circuit traces (`:943`), rainbow arcs (`:622`), ghost ghosts (`:604`), eclipse dots
  + radial (`:1255-1257`), CRT amber scanlines `repeating-linear-gradient(0deg, rgba(255,176,0,.28) 0 1px,
  transparent 1px 3px)` (`:1286`).
- Flutter: `cosmetics.dart:143-144,170-181` `messageStyleDecoration` explicitly omits `--style-pattern`
  ("per-glyph repeating SVG watermarks … intentionally omitted"). `MessageStyleVisual` (`shop_models.dart:170-182`)
  has no pattern field. The bubble (`message_row.dart:227-244`) paints only `contentBackground` + glow halo.
- Gap: 17 of 20 styles lose their defining texture. e.g. Matrix is just green glow with no falling code;
  Satoshi has the orange bg but no ₿ watermark; CRT has no scanlines. A buyer comparing the shop preview
  (also missing watermark — see F7) to a real message sees a much plainer bubble than the PWA.
- Fix approach: Add an optional `Widget? watermark` / `DecorationImage` to `MessageStyleDecoration`. For the
  repeating-SVG ones, render the SVG (via `flutter_svg`) tiled behind the content using a `Stack` +
  `Positioned.fill` with a tiling painter, or pre-rasterize to a tileable image and use
  `DecorationImage(repeat: ImageRepeat.repeat)`. CRT/eclipse scanlines can be a cheap `CustomPainter`
  (repeating 1px amber lines every 3px). This is the single biggest visual-fidelity item; scope can start with
  the highest-value styles (satoshi/matrix/crt/eclipse) then expand.
- Effort: L  Risk: med  Confidence: high

### F4: Shop item cards have no live message-style / cosmetic PREVIEW bubble  [SEVERITY: high]
- PWA: `shop.js:722-724` `_shopStyleDemo` renders a real `<div class="message style-X"><div class="message-content">Preview message</div></div>`
  inside each styles card; `shop.js:776-787` `_shopCosmeticDemo` renders a real cosmetic demo bubble (incl.
  supporter-style demo + redacted demo); the limited tab reuses these (`shop.js:861-867`). So every styles /
  special / limited-style card shows an actual styled bubble exactly as it appears in chat.
- Flutter: `shop_widgets.dart:128-235` `ShopItemPreview` renders for `message-style` only a one-line
  `MessageStylePreview` (`text:'Your_Nick'` colored text + glow — `:128-158`), and for `cosmetic` a
  `CosmeticPreview` chip (`:162-205`). There is **no message-bubble demo** — no translucent style background,
  no watermark, no real `.message-content` rendering. The card preview box (`shop_modal.dart:527-537`) is a
  generic outlined container.
- Gap: The shop's whole selling point — "here's how your message will look" — is reduced to a colored word.
  Satoshi's orange bubble, CRT's scanline panel, the aura box-shadows, etc. are not previewed.
- Fix approach: Replace `MessageStylePreview`/`CosmeticPreview` with a small bubble that reuses the same
  decoration composition as `message_row` (the `MessageStyleDecoration` + cosmetic-aura logic from F1/F3),
  rendering "Preview message" inside a styled `.message-content`-equivalent container. Once F1/F3 land, factor
  the bubble decoration into a shared helper both the card preview and `message_row` call.
- Effort: M  Risk: low  Confidence: high

### F5: Limited tab: no supply/availability badges, no soon/ended/sold-out states  [SEVERITY: high]
- PWA: `shop.js:813-883` — `_shopItemAvailability` computes `{soon|ended|soldout|available}` from `startsAt`/
  `endsAt`/`maxSupply` + live supply; `_renderLimitedCard` renders a `.shop-supply-badge shop-supply-{state}`
  (CSS `:1332-1359`: available=green `#52ff9d`, soon=blue `#7fdfff`, ended/soldout=red `#ff6b6b`) showing
  `"{remaining} / {max} left"`, `"Starts {date}"`, `"Drop ended"`, or `"Sold out"`. Sold-out/ended/soon cards
  show the status text instead of a Buy button. `shop.js:833-854` fetches `shop-supply` and re-renders.
- Flutter: `shop_modal.dart:315-316` the limited tab just does `[...ShopCatalog.limited, ...ShopCatalog.bundles]`
  and renders identical `_ShopItemCard`s. `shop_controller.dart` has **no** `shop-supply` fetch, no
  availability computation, no `startsAt`/`endsAt` gating (grep: none). Every limited item always shows a Buy
  button with no supply context.
- Gap: Genesis ("only 100"), Eclipse ("1,000"), CRT ("250") show no remaining-count and no sold-out/soon/ended
  states. A user can tap Buy on a sold-out/ended drop. The scarcity UX (a core driver for limited drops) is gone.
- Fix approach: Add `fetchSupply(itemIds)` → `shop-supply` to `ShopController` (mirror `shop.js:833-839`), store
  a `Map<String, ({int remaining})>`. Add an `availability(item, supply)` helper returning `(state,label)` and
  render a supply badge widget (3 tier colors above) on limited cards; replace the Buy button with the status
  label when not `available`. Gate on `startsAt`/`endsAt` (millis epoch) too.
- Effort: M  Risk: med  Confidence: high

### F6: Bundle cards: no content chips, no "Save X% · N sats value" badge  [SEVERITY: high]
- PWA: `shop.js:885-914` `_renderBundleCard` lists each component as a `.shop-bundle-chip` (icon + name, capped
  at 10 with "+N more"), computes the component price sum and renders `.shop-supply-available` "Save {pct}% ·
  {sum} sats value". CSS chips `:1361-1383`.
- Flutter: `shop_modal.dart:316` renders bundles through the generic `_ShopItemCard`; `ShopItemPreview`
  (`shop_widgets.dart:213-234`) has no `bundle` case → returns `SizedBox.shrink()`. No chips, no savings badge.
- Gap: The 3 bundles (Starter 3000, Legendary Vault 30000, Everything Pack 149999) show only name+price+Buy
  with no indication of what's inside or the discount — the entire value proposition is hidden. (Note: Everything
  Pack's component list is computed for *granting* at `shop_catalog.dart:497-501` but never *displayed*.)
- Fix approach: Add a `bundle` branch to `ShopItemPreview` (or a dedicated bundle card) that renders the
  component chips (use `ShopCatalog.bundleComponents(id)` so Everything Pack shows its 45 items, capped +N more)
  and a savings badge from `sum(component.price)` vs `item.price`.
- Effort: M  Risk: low  Confidence: high

### F7: Card preview for textured/eclipse/CRT styles lacks the `style-preview-*` watermark + gradient-clip treatment  [SEVERITY: medium]
- PWA: each style additionally has a `.style-preview-X` rule used in shop/user previews with its OWN watermark
  + treatment, e.g. satoshi gradient-clipped text + ₿ tile + `drop-shadow` (`:512-543`), aurora gradient-clip
  (`:630-636`), eclipse dark panel + star tile (`:1229-1249`), CRT amber mono panel + scanlines (`:1260-1279`),
  ice/matrix/fire/ghost denser tiles (`:1041-1055`).
- Flutter: `MessageStylePreview` (`shop_widgets.dart:128-158`) renders flat colored text (+ aurora ShaderMask),
  no preview background panel, no watermark, no satoshi/eclipse/crt panel.
- Gap: Even the simplified card text-preview diverges from the PWA's richer `style-preview-*`. Largely subsumed
  by F4 (real bubble demo) but called out since the PWA maintains a *separate* denser preview pattern set.
- Fix approach: Folds into F4 — when building the card demo bubble, use the style's `.message-content` treatment
  (the in-chat one is what the PWA card actually shows for styles via `_shopStyleDemo`). The standalone
  `style-preview-*` set is only needed if a non-bubble preview surface is kept.
- Effort: S  Risk: low  Confidence: med

### F8: Conic-gradient prism ring, holographic sheen, frost snowflake borders, cosmic starfield not rendered  [SEVERITY: medium]
- PWA: `cosmetic-aura-rainbow` `:1127-1139` paints a `conic-gradient(from var(--prism-angle), #ff2d2d,#ff8a00,
  #ffe600,#33dd00,#00c3ff,#2a5bff,#b13bff,#ff2d2d)` ring masked to a 3px border. `cosmetic-bubble-hologram`
  `:1203-1211` layers a 115deg white sheen over a 135deg multi-color gradient (`#ff00c8/#00c8ff/#78ffaa/
  #ffe100`) with `background-blend-mode: screen`. `cosmetic-frost` `:1149-1163` tiles a snowflake SVG on all 4
  edges. `cosmetic-aura-cosmic` `:1182-1195` layers a star-dot SVG over a purple gradient.
  **Note:** despite the prior audit's "animated prism" deferral, `--prism-angle` is declared (`:1115`) but
  **never animated** (no `animation:` references it anywhere — grep confirms zero `@keyframes` for any
  style/cosmetic). So these are STATIC and reproducible without animation.
- Flutter: `shop_catalog.dart:629-658` reduces each to a single `accent` + a flat `LinearGradient`; the preview
  chip (`shop_widgets.dart:186-204`) draws a left-border + soft box-shadow only. On real messages: nothing (F1).
- Gap: The 3 legendary cosmetics (Prism/Phoenix-Hologram) and Frost/Cosmic lose their signature look even in the
  shop chip. Prism's rainbow ring → flat gradient fill; hologram's sheen → none; frost's snowflakes → none.
- Fix approach: Prism ring → `SweepGradient` painted as a border ring (mask the interior). Hologram → stacked
  `LinearGradient`s with `BlendMode.screen` via a `ShaderMask`/`DecorationImage`. Frost snowflakes / cosmic stars
  → tiled SVG (shared with F3 watermark mechanism). These can be static (no animation needed).
- Effort: L  Risk: med  Confidence: high

### F9: Inventory tab missing active-summary, acquired-date, edition number, and recovery-code blocks  [SEVERITY: medium]
- PWA: `shop.js:969-1071` `renderInventoryTab` renders, above the grid: a **live "Preview" self-message**
  (`_renderActiveItemsPreview` `:937-967` — your nym with active style+flair+supporter+cosmetics), then
  **"Active Message Style / Active Nickname Flair / Active Special Items"** summary blocks, then per item:
  the **edition number** `#{n}/{max}` (`:1015-1016`, gold `.shop-edition-no` `:1385-1390`), **"Acquired: {date}"**
  (`:1023-1025`), an Activate/Deactivate button, the **recovery code** (click-to-copy, `:1055-1058`), and a
  **"TRANSFER TO PUBKEY"** button.
- Flutter: `shop_modal.dart:317-322` inventory just lists owned items as the same generic `_ShopItemCard` with
  Activate + Transfer pills. No preview self-message, no active-summary headers, no acquired date, no
  edition-number display, no recovery-code reveal/copy. (`OwnedItem` carries `timestamp`/`code`/`edition` —
  `shop_models.dart:70-108` — but none are surfaced.)
- Gap: Owners can't see their Genesis edition number in inventory, can't copy a recovery code (so they can't
  restore an item on another pubkey — the stated purpose), and get no acquired-date or active-at-a-glance summary.
- Fix approach: In the inventory branch of `_body`/`_ShopItemCard`, when `inventory` add: edition `#{edition}/
  {editionMax}` (gold), `"Acquired {date}"` from `OwnedItem.timestamp`, and a tappable recovery-code row
  (copy to clipboard) when `OwnedItem.code != null`. Add a top-of-tab active-items summary + self preview bubble
  (reuse F4 bubble + F1/F2 badges).
- Effort: M  Risk: low  Confidence: high

### F10: Purchase-success dialog doesn't reveal recovery code / edition / bundle codes  [SEVERITY: medium]
- PWA: `shop.js:1559-1594` `_renderShopSuccess` shows "✅ Purchase successful! / {name}", the **edition**
  `"Edition #{n} of {max}"`, and a prominent **"⚠️ SAVE YOUR RECOVERY CODE"** block with the click-to-copy code
  (or per-component codes for bundles). Gifts show "Gift sent!".
- Flutter: `shop_modal.dart:1059-1065` the `paid` phase shows only "⚡ / Purchase complete!" then auto-closes
  after 2s (`:962-964`). No code, no edition, no bundle codes, no save-your-code warning.
- Gap: After buying, the user is never shown the recovery code (and the dialog auto-dismisses), so they can't
  save it — losing the ability to restore the purchase on another pubkey. Edition number not shown either.
- Fix approach: In `_claim`, capture the claim response (`code`/`edition`/`bundle` — `shop_controller.dart`
  already parses these at `:363-368`/grant). In the `paid` phase render the code (copyable) + edition + the
  warning; don't auto-close while a code is shown (require a Close tap, mirror `dismissShopSuccess`).
- Effort: M  Risk: low  Confidence: high

### F11: "Glitch" style renders as plain green text — missing the dual offset chromatic text-shadow  [SEVERITY: medium]
- PWA: `styles-features.css:625-628` `.message.style-glitch .message-content { color:#00ff00; text-shadow:
  -2px 0 #ff0000, 2px 0 #00ffff }` — a red/cyan chromatic-aberration offset (the defining "glitch" look).
- Flutter: `shop_catalog.dart:540-543` maps `style-glitch` to `color #00FF00`, `glow #6600FFFF` (a single soft
  cyan glow). The glow is rendered only as a bubble box-shadow halo (`message_row.dart:242-244`), and the text
  itself gets no shadow. There is no red/-2px + cyan/+2px offset shadow.
- Gap: Glitch (10101 sats) looks identical to a plain green message with a faint halo — none of the signature
  chromatic split. `MessageStyleVisual` has no representation for multi-offset shadows.
- Fix approach: Add support for explicit `List<Shadow>` on `MessageStyleVisual`/`MessageStyleDecoration` and
  thread it into the content text style (currently `cosmetics.dart:163-164` only emits a single blurred glow
  shadow and `message_row.dart:494-495` deliberately doesn't push glow onto glyphs). For glitch emit two
  zero-blur shadows: `Shadow(color:#FFFF0000, offset:(-2,0))`, `Shadow(color:#FF00FFFF, offset:(2,0))`.
- Effort: S  Risk: low  Confidence: high

### F12: Per-glyph text-shadow glow approximated as a bubble halo (matrix/neon/fire/etc.)  [SEVERITY: medium]
- PWA: each style's glow is a `text-shadow` ON THE GLYPHS, e.g. neon `0 0 10/20/30px #ff00ff` (`:598`), matrix
  `0 0 10/20px #00ff00` (`:592`), fire `0 0 14px rgba(255,160,0,.8)` (`:609`). The text itself glows.
- Flutter: `message_row.dart:490-495` explicitly notes the glow "can't be pushed through `MessageContent`, so
  the glow is rendered as the bubble/row halo instead" — `_buildBubble` paints `glow` as a `BoxShadow`
  (`:242-244`), and the IRC row paints no glyph glow at all. `MessageContent.baseColor` sets the color but the
  text gets no `shadows`.
- Gap: In bubble mode the glow is a soft halo around the whole bubble rather than a neon glow on the letters
  (noticeably different for neon/matrix/fire/ghost). In IRC layout there's no glow at all (no bubble to halo).
- Fix approach: Thread a `List<Shadow>` into `MessageContent`'s `TextStyle` (add a `shadows`/`glowShadow`
  param to `MessageContent`) so glyphs carry the blurred glow, matching CSS. Keep/relax the bubble halo. Pairs
  with F11 (same plumbing).
- Effort: M  Risk: med  Confidence: med

### F13: CRT style not rendered in monospace on real messages  [SEVERITY: low]
- PWA: `styles-features.css:1281-1287` `.message.style-crt .message-content { font-family: var(--font-mono,
  monospace) }` (amber phosphor terminal). The `style-preview-crt` is also mono.
- Flutter: `shop_catalog.dart:612-616` sets `style-crt` `monospace: true`, and `messageStyleDecoration`
  (`cosmetics.dart:170-181`) does **not** copy `monospace` into the returned decoration (it passes `textColor`,
  `glow`, `contentBackground` but omits the `monospace:` flag — defaults to false). `message_row._content`
  (`:496-506`) never applies a monospace family. So CRT renders in the default font. (The shop card preview
  `MessageStylePreview:144` *does* honor it — inconsistent.)
- Gap: CRT (12000-sat legendary) loses its terminal monospace look on actual messages.
- Fix approach: In `messageStyleDecoration` pass `monospace: v.monospace`; in `message_row._content` apply
  `fontFamily: 'monospace'` to `MessageContent` when `deco.monospace`. (Add a monospace/fontFamily param to
  `MessageContent`.)
- Effort: S  Risk: low  Confidence: high

### F14: Legendary ribbon ("LEGENDARY" corner banner) not rendered on cards  [SEVERITY: low]
- PWA: `shop.js:770-772` `_legendaryRibbon` renders a `.shop-legendary-ribbon` 45deg corner banner
  (CSS `:1306-1330`: gradient `#ffb340→#ff7ad9`, dark text, 8px 800-weight, top:24px right:-48px rotate(45deg))
  on every `tier:'legendary'` card across all tabs.
- Flutter: `shop_modal.dart:494-507` gives legendary cards a gold border + soft box-shadow (matching
  `.shop-item-legendary` `:1306-1310`) but **no diagonal ribbon banner**. The icon is gold-tinted (`:514`).
- Gap: Legendary items lack the distinctive corner ribbon; the legendary affordance is just a border. Minor but
  user-visible across many cards (satoshi, matrix, diamond, mask, genesis, crt, the 3 legendary cosmetics, vault).
- Fix approach: Add a `Positioned` 45deg-rotated `Transform.rotate` banner in the top-right of `_ShopItemCard`
  (clipped by the card's `Clip`), gradient `#ffb340→#ff7ad9`, text "LEGENDARY". Wrap card in a `Stack`.
- Effort: S  Risk: low  Confidence: high

### F15: Supporter-style gold treatment incomplete (header text-shadow / read-more handling) + IRC bubble wash alpha  [SEVERITY: low]
- PWA: `styles-features.css:1084-1097` supporter-style = gold content `#ffd700` text-shadow `0 0 8px
  rgba(255,215,0,.25)`, gradient bg `rgba(255,215,0,.08→.03)`, `border-left:3px solid #ffd700`; the message
  HEADER also goes gold with `0 0 10px` shadow (`:1478-1481`); read-more reverts to primary (`:1094-1097`).
- Flutter: `cosmetics.dart:198-203` `supporterStyleDecoration` = gold text, glow `0x40FFD700`,
  `contentBackground 0x14FFD700`, `borderAccent gold`. Applied via `_styleDecoration` fallback
  (`message_row.dart:100`). Close, but: the author/header isn't given the gold + shadow treatment, and the glow
  alpha (`.25`→`0x40`≈`.25` ok) renders as a bubble halo not glyph shadow (F12). Minor gradient-vs-flat bg.
- Gap: Supporter messages are mostly right (gold text + left bar) but the author line doesn't turn gold and the
  glow is a halo. Low impact.
- Fix approach: When supporter-style is active (and no explicit style), tint the author `Text` gold with a soft
  shadow in `message_row` (both layouts). Optional: gradient bg instead of flat.
- Effort: S  Risk: low  Confidence: med

### F16: Shop modal header/tabs cosmetic polish — no horizontal scroll indicator, tab label "Limited & Bundles" vs PWA "Limited & Bundles" OK; preview-box border vs PWA card chrome  [SEVERITY: low]
- PWA: `index.html:798-825` shop modal: header "FLAIR" + descriptive subtitle + recovery row; 5 tabs. CSS gives
  cards `position:relative; overflow:hidden` (`:1301-1304`) for the ribbon; tab active state underline.
- Flutter: `shop_modal.dart:100-269` reproduces header (FLAIR + same subtitle text verbatim `:126-130`),
  recovery row, and 5 tabs with active underline — this is faithful. The grid card (`:494-537`) uses a generic
  preview container rather than the PWA's inline demo region. Tabs are horizontally scrollable (`:228-235`) which
  matches small screens.
- Gap: Structurally faithful; the only residue is the preview region (covered by F4) and the missing ribbon
  overflow (F14). Listed for completeness — no separate action needed beyond F4/F14.
- Fix approach: None beyond F4/F14. The header/tabs/recovery match the PWA.
- Effort: S  Risk: low  Confidence: high

---

## Cross-reference: every animated/special style & its PWA visual vs Flutter
(Settles the prior audit's "animated prism/glitch" deferral — `styles-features.css` has **no `@keyframes`** for
any message style or cosmetic; all are static CSS. The deferral conflated "rich static effect" with "animated".)

| id | PWA visual (CSS line) | Flutter now |
|----|----------------------|-------------|
| style-satoshi | `#fff`/`#f7931a` text, `rgba(247,147,26,.2)` bg, tiled **₿ watermark** (`:545-566`) | orange text+glow halo, orange bg (`_styleContentBackground`), **no ₿ tile** |
| style-matrix | `#00ff00`, `0 0 10/20px` glow, **falling 10/01/11 watermark** (`:590-594`) | green text, glow→bubble halo, **no code rain** |
| style-neon | `#ff00ff`, `0 0 10/20/30px` triple glow (`:596-599`) | magenta text, single halo (F12) |
| style-ghost | `rgba(255,255,255,.7)`, `0 2px 16px` glow, **ghost watermark** (`:601-605`) | translucent white text+halo, **no ghosts** |
| style-fire | `#ffaa00`, `0 0 14px`, **flame watermark** (`:607-611`) | amber text+halo, **no flames** |
| style-ice | `#00ccee`, `0 0 8px`, **ice-crystal watermark** (`:613-617`) | cyan text+halo, **no crystals** |
| style-rainbow | `#c77dff`, `0 0 8px`, **rainbow-arc watermark** (`:619-623`) | violet text+halo, **no arcs** |
| style-glitch | `#00ff00` + **`-2px #f00 / +2px #0ff` dual shadow** (`:625-628`) | green text + soft cyan halo, **no chromatic split** (F11) |
| style-aurora | gradient-clip `#00ffd5→#5b8cff→#ff00ea`, `0 0 10px` (`:638-644`) | **rendered** via ShaderMask gradient (good) |
| style-ocean/sakura/galaxy/toxic/gold/vapor/blood/royal/circuit | colored text + glow + **per-theme tiled watermark** (`:732-943`) | colored text + halo, **no watermark** (F3) |
| style-eclipse | `#ffcaa0`, dark `rgba(18,14,28,.72)` bg, radial + **star watermark** (`:1251-1293`) | text+halo + dark bg (`0xB8120E1C`), **no radial/stars** |
| style-crt | `#ffb000`, dark bg, **monospace**, **amber scanlines** (`:1281-1298`) | amber text+halo + dark bg; **not monospace** (F13), **no scanlines** |
| supporter-style | gold text `0 0 8px`, gold gradient bg, left bar, gold header (`:1084-1097,1478-1481`) | gold text + halo + bar + bg; **author not gold** (F15) |
| cosmetic-aura-gold | inset+`0 0 18px` gold ring, left bar, gold bg (`:1099-1103`) | **not rendered on messages** (F1) |
| cosmetic-aura-neon | inset+`0 0 22px` cyan ring (`:1105-1113`) | **not rendered** (F1) |
| cosmetic-aura-rainbow | **conic-gradient prism ring** masked 3px (`:1115-1139`) | **not rendered**; chip = flat gradient (F1/F8) |
| cosmetic-frost | frosted box-shadow + **snowflake-edge watermark** + icy bg (`:1141-1167`) | **not rendered**; chip = border+shadow (F1/F8) |
| cosmetic-aura-phoenix | inset+`0 0 26px` orange ring, fire bg (`:1169-1177`) | **not rendered** (F1) |
| cosmetic-aura-cosmic | purple ring + **starfield watermark** (`:1179-1195`) | **not rendered** (F1/F8) |
| cosmetic-bubble-hologram | **holographic sheen + multi-gradient, screen blend** (`:1197-1211`) | **not rendered**; chip = flat gradient (F1/F8) |
| cosmetic-redacted | author dimmed; content → `████` after 10s (`:1419-1440`, `shop.js:498-503`) | **not rendered**; no blanking timer (F1) |
| flair-genesis | gold glow pyramid + **stamped edition #**, bold nym (`:1213-1227`, `shop.js:1135-1145`) | pyramid + gold; **no edition number, nym not bold** (F2) |

## Incidental (non-UI, flag only)
- `User` model has no `shopCosmetics`/`shopEdition` fields and the presence/shop-status ingestion
  (`nostr_service.dart`) populates only style/flair/supporter — so even after F1/F2 wire the renderer, the
  ingestion path must also parse `active.cosmetics` + `active.editions` from `shop-status`/`shop-update` for
  OTHER users. (`shop.js:459-478` reads both.) Cross-boundary with the `state/**` owner.
