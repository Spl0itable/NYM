# 04 — UI Shell / Layout / Themes / Components — Pixel-Fidelity Audit

Slice: UI shell, layout, themes, design-system components (sidebar, shell,
wallpapers, columns, onboarding). Excludes message_row / composer / context-menu
(owned by another agent).

Compared Flutter (`lib/core/theme/**`, `lib/widgets/sidebar/**`,
`lib/widgets/chat/chat_pane.dart`, `lib/widgets/chat/messages_list.dart`,
`lib/widgets/columns/**`, `lib/widgets/wallpaper/**`, `lib/screens/**`) against
the PWA `index.html` + `css/styles-core.css`, `css/styles-shell.css`,
`css/styles-themes-responsive.css`, `css/styles-features.css`,
`css/styles-columns.css`, and `js/modules/settings.js applyTheme`.

## Verified-correct (no change needed)

- **All 6 theme accent palettes** (matrix/amber/cyber/hacker/ghost/bitchat,
  dark + light) in `nym_theme.dart` `_themeAccents` match `settings.js`
  `applyTheme()` hex-for-hex.
- `:root` base tokens (`nym_colors`/`nym_theme`): primary/secondary/warning/
  danger/purple/blue/lightning/bg/bg-secondary/bg-tertiary/text/text-bright/
  border/glass-bg/glass-border — all match `styles-core.css`.
- light-mode, solid-ui, ghost-bg overrides — order and values match.
- Radii (xs8/sm12/md16/lg20/xl24), `--transition` 0.25s, slide 0.15s — match.
- Sidebar width 290 / drawer 300 / context-menu 320 / breakpoints 768/1024 — match.
- Wallpaper patterns (8 types): tile sizes + per-layer alphas match
  `styles-features.css` `#wallpaperLayer.wallpaper-pattern-*`.
- Columns: `.cv-strip` gap/padding 12, `.cv-column` 360px, `.cv-add-column` 220px
  dashed — match.
- `.user-item` 6/12 padding, dim text `calc(size-3)`, 6px status dots, 20px
  avatar — match. status dot colors online #22c55e / away #eab308 / offline
  #6b7280 — match.

## Discrepancies found + fixed

| Component | PWA value | Flutter (before) | Fixed? |
|---|---|---|---|
| Theme: ghost dark `--text-dim` | `#cccccc` (inline `applyTheme` wins over class `#999999`) | `#999999` | ✅ `nym_theme.dart` ghost.dark[3] → `#cccccc` |
| `.sidebar-header` | padding 20/16, bg `rgba(0,0,0,0.15)`, contains a bordered `.nym-display` box | flat header, no bg, no nym box | ✅ added black@0.15 header bg + inner `.nym-display` (white@0.04, glass border, radius-sm, padding 10/14) |
| `.nym-label` ("NYM") | 10px uppercase ls 1.5 textDim w500 | omitted entirely | ✅ added |
| `.nym-value` | 15px `--secondary` w600 | 14px `--text-bright` w700 | ✅ 15px secondary w600 |
| `.status-dot` (header) | 8px | 6px | ✅ 8px |
| `.status-indicator` gap | 5px | 6px | ✅ 5px |
| `.nav-title` letter-spacing | 2px (CSS), margin-bottom 10, padding-left 8 (within 12px section) | ls 1.5, padding LTRB 16/14/10/8 | ✅ ls 2, padding LTRB 20/16/12/10 |
| `.sidebar-actions` border | `border-top` | `border-bottom` | ✅ border-top |
| `.sidebar-actions` padding | 16/12 | 12/10 | ✅ 12h/16v |
| `.sidebar-actions .btn-label` | 9px, icon-gap 3 | 10px, gap 4 | ✅ 9px, gap 3 |
| `.channel-item.active` text | inherits `--text`, normal weight | recolored `--primary` + w600 | ✅ stays `--text` w400 |
| `.pm-item.active` | shares `.channel-item.active`: `--primary` fill/border/glow + primary accent bar | used `--purple` fill/border, **no accent bar** | ✅ primary fill@10/border@20/glow + 3px primary `::before` bar added |
| `.pm-name` color | `--text-dim` | `--text` (or purple when active) | ✅ `--text-dim` w400 |
| pm unread badge | `.unread-badge`: bg `--primary`, text `--bg` | bg `--purple`, text white | ✅ primary bg, `--bg` text, tabular figures |
| `.std-badge` / `.geohash-badge` | 1px border (std `blue@25%`, geo `warning@20%`), weight 500, geo bg `@8%` | no border, weight 600, geo bg `@10%` | ✅ border + weight 500 + geo bg @8% |
| `.channel-item.active` glow | `0 0 12px primary@5%` | `blur 20px primary@10%` | ✅ blur 12 / @5% |
| `.channel-item.active::before` bar | glow `0 0 8px primary@40%` | no glow | ✅ added bar glow (channel + pm) |
| `.unread-badge` min-width | `3ch` content-box + 7px padding (≈30px) | minWidth 22 | ✅ minWidth 30 |
| `.chat-header` | padding `16px 24px` (mobile `12px top / 15 bottom / 10 sides`) | fixed `height:64`, vertical padding 0 | ✅ padding-based 16/24 (mobile 12/10/10/15) + minHeight constraint |
| `.messages-container` | bg `rgba(0,0,0,0.15)`, padding `8px 20px 16px` | no bg, padding `vertical:8` only | ✅ black@0.15 bg + padding (sides 20, top 8, bottom 16) |
| `.cv-column` shadow | `box-shadow: --shadow-md` | omitted | ✅ added 0 4px 16px black@0.4 (opaque columns only) |

## Deferrals (not fixed — out of scope or cross-agent)

- **`.header-actions` desktop buttons** render as 28×28 icon-only buttons in
  Flutter, but the PWA uses `.icon-btn` text+icon uppercase pills
  (Notifications/Flair/Settings/About/Logout) only for the `.header-actions`
  group, while back/forward are `.channel-nav-btn` (28×28). Converting the
  desktop action bar to text pills risks overflow on narrow main panes and is a
  larger structural change; the icon-only treatment is a deliberate
  simplification. Flagged for a follow-up if exact desktop chrome fidelity is
  required.
- **`.channel-nav-btn` hover bg** (`rgba(255,255,255,0.08)` + primary) not yet
  painted in `_NavBtn` (relies on default InkWell). Cosmetic on touch targets.
- **Tutorial highlight box** (`#tutorialOverlay` positional spotlight) not ported
  — card is centered. Pre-existing `TODO(verify)` in `tutorial_overlay.dart`.

## Verification

- `flutter analyze` on owned files (theme, screens, app, sidebar, common,
  wallpaper, columns, chat_pane, messages_list, onboarding, both tests):
  **No issues found.**
- `flutter test test/theme_test.dart`: **6/6 passed** (added ghost-dark
  text-dim/lightning/warning/blue assertions).
- `flutter test test/shell_test.dart`: **BLOCKED — does not compile** due to a
  pre-existing error in `lib/features/shop/shop_modal.dart` (owned by the
  shop/features agent): references undefined `_RecipientPubkeyDialog` and a
  missing `recipientPubkey:` named param. `sidebar.dart` imports `ShopModal`,
  pulling the broken file into the test's compile graph. Not fixable within this
  slice's ownership; my shell widgets themselves analyze clean.
