# 02 — UI Shell, Layout, Navigation, Theming & Design System

**Source of truth for a pixel-accurate Flutter reimplementation of the Nymchat PWA shell.**

Origin files:
- `index.html` (DOM skeleton)
- `css/styles-core.css` (`:root` design tokens, fonts, body backdrop, wallpaper layer)
- `css/styles-shell.css` (sidebar, lists, chat header, context-menu slideout, icon-btn, messages-container)
- `css/styles-chat.css` (messages, reactions, composer, input, send-btn, modal base, skeletons)
- `css/styles-components.css` (modals, forms, badges, autocomplete, emoji/gif pickers, settings sections)
- `css/styles-features.css` (avatars, flair/supporter/friend badges, **bubble layout** `body.chat-bubbles`, quick-context-menu, typing indicator, wallpaper patterns)
- `css/styles-columns.css` (deck/multi-column view)
- `css/styles-themes-responsive.css` (ghost theme, light-mode, solid-ui, responsive breakpoints)
- `css/no-inline.css`, `js/theme-init.js`, `js/modules/settings.js` (theme palettes in JS), `js/modules/panic.js`, `js/modules/dialog.js`, `js/modules/columns.js`

> **Critical theming note:** the 6 *color themes* (matrix, amber, cyber, hacker, ghost, bitchat) are **NOT** defined as static CSS classes. Only `ghost` has a CSS class (`body.theme-ghost`). All themes are applied at runtime by `settings.applyTheme()` in `js/modules/settings.js` (lines 865–1010) which sets inline CSS custom properties on `<body>`. The `:root` in `styles-core.css` defines the *base/fallback* (which is the Matrix/Bitchat dark green palette). See §3.

---

## 1. Overall Layout Structure

### 1.1 Region tree (DOM)

The app root is the class-only `.container` (there is **no `#app` id**). It is a two-pane flex: `aside.sidebar#sidebar` + `main.main-content`. Several overlays/panels/modals are siblings *outside* `.container`.

```
body  [classes toggle theme/mode: .light-mode .solid-ui .theme-ghost .theme-bitchat
       .chat-bubbles .columns-mode .columns-wallpaper .nymchat-app .sidebar-reorder-mode]
├─ #wallpaperLayer                          fixed full-screen wallpaper pattern layer (z:0)
├─ #mobileOverlay     .mobile-overlay        dim backdrop when sidebar open on mobile (z:9998)
├─ #contextMenuOverlay .context-menu-overlay backdrop for user context panel (z:10099)
├─ #contextMenu       .context-menu          RIGHT-SIDE user profile / message action panel (z:10100)
├─ #groupContextMenuOverlay .context-menu-overlay
├─ #groupContextMenu  .context-menu          group profile / members panel
├─ #newPMModal        .modal                 (declared early)
├─ #reportModal       .modal
│
├─ .container                                ← APP ROOT (flex row, height 100dvh)
│  ├─ aside#sidebar  .sidebar                ← LEFT SIDEBAR (width 290px)
│  │  ├─ .sidebar-header
│  │  │  ├─ pre.logo-ascii        (ASCII logo; click → openNostrLogin; hidden in NymchatApp shell)
│  │  │  ├─ .nym-display          (click → editNick; press-hold 2s → PANIC wipe)
│  │  │  │  ├─ .nym-label  +  .nym-identity (img.avatar#sidebarAvatar + .nym-value#currentNym)
│  │  │  └─ .status-indicator     (.status-dot#statusDot + span#connectionStatus → openRelayStats)
│  │  ├─ .sidebar-actions          (MOBILE-only row: Flair / Settings / About / Logout icon-btns)
│  │  ├─ .nav-section[data-section="channels"]   PUBLIC CHANNELS
│  │  │  ├─ .nav-title (reorder arrows, "Public Channels", discover/search/collapse icons)
│  │  │  ├─ #channelSearchWrapper .search-input-wrapper > input#channelSearch.search-input + .search-clear
│  │  │  ├─ #channelSearchResults
│  │  │  └─ #channelList .channel-list  →  .channel-item[.active] (.channel-name + .channel-badges>.unread-badge)
│  │  ├─ .nav-section[data-section="pms"]        PRIVATE MESSAGES
│  │  │  ├─ .nav-title (reorder arrows, "Private Messages", new-pm/search/collapse icons)
│  │  │  ├─ #pmSearchWrapper > input#pmSearch.search-input
│  │  │  └─ #pmList .pm-list  →  .pm-item
│  │  └─ #userList .user-list[data-section="nyms"]   ONLINE NYMS
│  │     ├─ .nav-title ("Online Nyms", search/collapse)
│  │     ├─ #userSearchWrapper > input#userSearch.search-input
│  │     └─ #userListContent  →  .user-item
│  │
│  └─ main.main-content                      ← CHAT COLUMN (flex column)
│     ├─ header.chat-header
│     │  ├─ .channel-info > .nm-h-15
│     │  │  ├─ .channel-header-controls (grid)
│     │  │  │  ├─ .channel-nav-buttons: #channelBackBtn #channelForwardBtn (.channel-nav-btn)
│     │  │  │  └─ .channel-action-buttons: #favoriteChannelBtn #shareChannelBtn #audioCallBtn #videoCallBtn
│     │  │  └─ .channel-title-wrap: .channel-title#currentChannel + .channel-meta#channelMeta
│     │  ├─ .header-actions          (DESKTOP: Notifications / Flair / Settings / About / Logout)
│     │  └─ .mobile-header-actions   (MOBILE: .mobile-notif-toggle + .mobile-menu-toggle hamburger)
│     ├─ #messagesScroller .messages-container   ← single-chat scroller (column-reverse)
│     │  └─ #messagesContainer .messages-list    ← message nodes injected here
│     ├─ #columnsStrip .cv-strip      ← DECK / multi-column view (shown only in .columns-mode)
│     │  └─ .cv-column × N  +  .cv-add-column
│     ├─ #typingIndicator .typing-indicator
│     ├─ button#scrollToBottomBtn .scroll-to-bottom-btn
│     └─ .input-container             ← COMPOSER
│        ├─ .input-wrapper
│        │  ├─ #autocompleteDropdown #channelAutocomplete #emojiAutocomplete (autocompletes)
│        │  ├─ #commandPalette  #kaomojiAutocomplete
│        │  ├─ #uploadProgress (.progress-fill#progressFill + cancelUpload)
│        │  ├─ #editPreview  #quotePreview     (reply / edit banners above input)
│        │  └─ .message-input-row: #messageInput.message-input (contenteditable)
│        │       + #translateInputBtn + #translateInputDropdown
│        ├─ .input-buttons   (toolbar — see §5)
│        ├─ #emojiPicker .emoji-picker
│        └─ #gifPicker  .gif-picker
│
├─ … all remaining modals (§7) …
└─ #notificationsModal .modal               (declared after scripts)
```

**Persistent right-side panels** (`#contextMenu`, `#groupContextMenu`) are *not* modals — they are always-present slideouts. The call UI `#callOverlay` and `#tutorialOverlay` are full-screen overlays distinct from the `.modal` family.

### 1.2 Responsive breakpoints

| Breakpoint | Behavior |
|---|---|
| **`max-width: 480px`** | Emoji/GIF picker full-bleed (`left:5px;right:5px`); emoji grid 5 cols; relay-stats cards 3 cols; latency col hidden. |
| **`max-width: 768px`** (MOBILE) | Sidebar becomes a **fixed off-canvas drawer**: `position:fixed; left:0; top:0; width:300px; height:100dvh; z-index:9999; transform:translateX(-100%)`. `.sidebar.open` → `translateX(0)` + `box-shadow:10px 0 40px rgba(0,0,0,0.5)`. `.mobile-overlay`, `.sidebar-actions`, `.mobile-header-actions` shown; `.header-actions` hidden. Composer stacks vertically (`flex-direction:column`); message rows stack (`.message{flex-direction:column}`); input font forced `16px` (prevents iOS zoom). Emoji grid 6 cols. Uses `--keyboard-inset` var to shrink height when on-screen keyboard appears. |
| **`769px–1024px`** (TABLET) | Same off-canvas sidebar drawer (`width:300px`) + mobile header actions; composer stacks vertically. Effectively "mobile chrome, wider drawer". |
| **`min-width: 769px`** (DESKTOP) | Static 290px sidebar inline; desktop `.header-actions` visible; column pager (`.cv-pager`) can show. |

Other media queries: `@media (pointer:coarse)` disables text selection except in inputs; `@media (hover:hover)` gates hover states; `@media (prefers-reduced-motion:reduce)` neutralizes all animations; `@media (hover:none)` always shows video expand button.

---

## 2. Design Tokens (base / default theme)

From `css/styles-core.css :root` (`color-scheme: dark`). This base palette **is** the Matrix/Bitchat dark green scheme.

### 2.1 Color tokens

| Token | Value | Role |
|---|---|---|
| `--primary` | `#00ff00` | Accent / brand (neon green) |
| `--secondary` | `#00ffff` | Secondary accent (cyan) — author names, links |
| `--warning` | `#ffff00` | Warnings, geohash badges |
| `--danger` | `#ff4444` | Errors, destructive actions, delete |
| `--purple` | `#ff00ff` | PM accent |
| `--blue` | `#0080ff` | Standard channel badge |
| `--lightning` | `#f7931a` | Zaps / Bitcoin Lightning (orange) |
| `--bg` | `#0a0a0f` | App background (near-black) |
| `--bg-secondary` | `rgba(15,15,25,0.85)` | Sidebar, modal, header surfaces |
| `--bg-tertiary` | `rgba(20,20,35,0.9)` | Context menu, channel menu, skeletons |
| `--text` | `#00ff00` | Primary body text |
| `--text-dim` | `#8a8a9a` | Secondary / muted text, timestamps |
| `--text-bright` | `#00ffaa` | Emphasis text |
| `--border` | `rgb(from --primary r g b / 0.2)` | Default border (= green @20%) |
| `--glass-bg` | `rgba(15,15,30,0.6)` | Translucent surface fill |
| `--glass-border` | `rgba(255,255,255,0.08)` | Hairline border on glass surfaces |
| `--glass-glow` | `rgb(from --primary r g b / 0.06)` | Subtle glow |

### 2.2 Radii, shadows, motion, type metrics

| Token | Value |
|---|---|
| `--radius-xs` | `8px` |
| `--radius-sm` | `12px` |
| `--radius-md` | `16px` |
| `--radius-lg` | `20px` |
| `--radius-xl` | `24px` |
| `--shadow-sm` | `0 2px 8px rgba(0,0,0,0.3)` |
| `--shadow-md` | `0 4px 16px rgba(0,0,0,0.4)` |
| `--shadow-lg` | `0 8px 32px rgba(0,0,0,0.5)` |
| `--shadow-glow` | `0 0 20px rgb(from --primary r g b / 0.1)` |
| `--transition` | `0.25s cubic-bezier(0.4,0,0.2,1)` |
| `--user-text-size` | `15px` (user-adjustable 12–28px; base message + list font size) |
| `--keyboard-inset` | runtime px (mobile keyboard height) |
| `--wp-r/--wp-g/--wp-b` | runtime RGB components of `--primary` (tints wallpaper patterns) |

> **Flutter mapping tip:** colors use CSS relative-color `rgb(from var(--x) r g b / α)`. In Flutter take the base hex and apply opacity. Recurring alphas off `--primary`: `.05 .06 .08 .1 .12 .15 .18 .2 .25 .3 .4`.

### 2.3 Body backdrop layers

`body::before` paints two radial gradients (primary @4% top-left, secondary @3% bottom-right) plus a center vignette. `body::after` is reserved (empty by default). `#wallpaperLayer` is a fixed full-screen layer above the backdrop. In `light-mode` the vignette is removed.

---

## 3. The 6 Themes

Applied via `settings.applyTheme(theme)` (`js/modules/settings.js:865`). Each theme overrides **only** these 6 inline vars on `<body>`: `--primary --secondary --text --text-dim --text-bright --lightning`. Backgrounds (`--bg`, `--bg-secondary`, `--bg-tertiary`) come from `:root` (or the ghost / light-mode / solid-ui classes) and are **shared** across themes. The default theme key is **`bitchat`** (`localStorage 'nym_theme'` default = `'bitchat'`).

Each theme has a **dark** and **light** variant (light = when `body.light-mode`).

### 3.1 Theme: Bitchat (Multicolor / DEFAULT)
`theme === 'bitchat'` adds class `body.theme-bitchat`. Multicolor = per-user nym colors come from a 16-color palette (`.bitchat-user-0..15`), independent of these accent tokens.

| Var | Dark | Light |
|---|---|---|
| primary | `#00ff00` | `#007a00` |
| secondary | `#00ffff` | `#007a7a` |
| text | `#00ff00` | `#006600` |
| text-dim | `#cccccc` | `#666666` |
| text-bright | `#00ffaa` | `#004d00` |
| lightning | `#f7931a` | `#c47a15` |

### 3.2 Theme: Matrix Green
| Var | Dark | Light |
|---|---|---|
| primary | `#00ff00` | `#007a00` |
| secondary | `#00ffff` | `#007a7a` |
| text | `#00ff00` | `#006600` |
| text-dim | `#00BD00` | `#558855` |
| text-bright | `#00ffaa` | `#004d00` |
| lightning | `#f7931a` | `#c47a15` |

### 3.3 Theme: Amber Terminal
| Var | Dark | Light |
|---|---|---|
| primary | `#ffb000` | `#9a6a00` |
| secondary | `#ffd700` | `#8a7200` |
| text | `#ffb000` | `#7a5500` |
| text-dim | `#cc8800` | `#8a7a55` |
| text-bright | `#ffcc00` | `#5a3a00` |
| lightning | `#ffa500` | `#b87300` |

### 3.4 Theme: Cyberpunk (`cyber`)
| Var | Dark | Light |
|---|---|---|
| primary | `#ff00ff` | `#990099` |
| secondary | `#00ffff` | `#007a7a` |
| text | `#ff00ff` | `#880088` |
| text-dim | `#DB16DB` | `#885588` |
| text-bright | `#ff66ff` | `#660066` |
| lightning | `#ffaa00` | `#b87300` |

### 3.5 Theme: Hacker Blue (`hacker`)
| Var | Dark | Light |
|---|---|---|
| primary | `#00ffff` | `#007a7a` |
| secondary | `#00ff00` | `#007a00` |
| text | `#00ffff` | `#006666` |
| text-dim | `#01c2c2` | `#558888` |
| text-bright | `#66ffff` | `#004d4d` |
| lightning | `#00ff88` | `#009955` |

### 3.6 Theme: Ghost (B&W)
`theme === 'ghost'` adds class `body.theme-ghost`, which (uniquely) **also overrides backgrounds** (see CSS `styles-themes-responsive.css:502`):

Dark (`body.theme-ghost`): `--bg:#080808`, `--bg-secondary:rgba(15,15,15,0.85)`, `--bg-tertiary:rgba(20,20,20,0.9)`, `--border:rgba(255,255,255,0.1)`, `--glass-border:rgba(255,255,255,0.06)`, plus `--warning:#888888 --danger:#cccccc --purple:#999999 --blue:#bbbbbb`.

| Var | Dark | Light |
|---|---|---|
| primary | `#ffffff` | `#333333` |
| secondary | `#cccccc` | `#555555` |
| text | `#ffffff` | `#222222` |
| text-dim | `#cccccc` / CSS `#999999` | `#777777` |
| text-bright | `#ffffff` | `#000000` |
| lightning | `#dddddd` | `#999999` |

### 3.7 Cross-cutting body modifiers (combine with any theme)

- **`body.light-mode`** — light scheme. Overrides: `--bg:#f5f5f2`, `--bg-secondary:rgba(255,255,255,0.85)`, `--bg-tertiary:rgba(240,240,237,0.9)`, `--border:rgba(0,0,0,0.1)`, `--glass-bg:rgba(255,255,255,0.6)`, `--glass-border:rgba(0,0,0,0.08)`, shadows lightened; and accent overrides `--warning:#8a6d00 --danger:#cc0000 --purple:#880088 --blue:#0060cc`. Applied at boot by `theme-init.js` based on `localStorage 'nym_color_mode'` (`auto`/`light`/`dark`) and `prefers-color-scheme`.
- **`body.solid-ui`** — opaque ("transparency disabled") UI. Sets `--glass-bg:#14141e; --bg-secondary:#14141e; --bg-tertiary:#1c1c2c` (light: `#ffffff/#ffffff/#f0f0ed`) and forces solid backgrounds on every glass surface (sidebar, header, menus, modals, pickers). **Default ON** — `theme-init.js` adds `solid-ui` unless `localStorage 'nym_transparency_enabled' === 'true'`.
- **`body.chat-bubbles`** — bubble (vs IRC) message layout. See §6.
- **`body.columns-mode`** — deck view. See §1.1 / `styles-columns.css`.

---

## 4. Typography

- **Sans stack** `--font-sans`: `'ColorEmoji', -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Inter', 'Segoe UI', system-ui, sans-serif`. (`ColorEmoji` is a local-only `@font-face` mapping emoji unicode ranges to platform emoji fonts.) Base `line-height: 1.4`.
- **Mono stack** `--font-mono`: `'Courier New', 'Consolas', 'Monaco', monospace`. Used for code, pubkeys, ASCII logo (`.logo-ascii` 4.5px), panic scramble.
- No remote/Google web fonts are loaded — all system fonts.

### Adjustable text size feature
- Driven by `--user-text-size` (default **15px**). Slider `#textSizeSlider` `type=range min=12 max=28 step=1` (`index.html:1514`). `previewTextSize()` live-applies; `resetTextSize()` returns to 15 (`js/app.js:2176`). Persisted in `localStorage 'nym_text_size'`.
- Derived sizes: message rows & channel/PM items `= var(--user-text-size)`; user-list items `= calc(var(--user-text-size) - 3px)`; channel title `= calc(var(--user-text-size) + 3px)`.

### Notable fixed type sizes
modal-header 22px · section/nav-title 10px (uppercase, letter-spacing 1.5–2px) · form-label 11px uppercase · icon-btn 12px uppercase · message-time 12px · reaction-badge 12px · channel-meta 11px · unread-badge / flair-context 10px · bubble-time 10px.

---

## 5. Components Catalogue

### 5.1 Buttons

| Component | Key styling |
|---|---|
| **`.icon-btn`** | bg `rgba(255,255,255,0.05)`; `1px solid --glass-border`; radius `--radius-xs` (8px); color `--text`; padding `7px 14px`; 12px uppercase, letter-spacing `0.8px`; gap 5px. Hover: bg `--primary@12%`, color `--primary`, border `@30%`, glow `0 0 15px @10%`. |
| **`.icon-btn.input-btn`** | composer toolbar; height `42px`, padding `0 12px`, radius `--radius-sm`; SVG `18×18`, stroke `--text` (→ primary on hover). On mobile `flex:1`. |
| **`.send-btn`** | bg `--primary@10%`; `1px solid --primary@30%`; radius `--radius-sm` (12px); color `--primary`; padding `10px 22px`; height `42px`; 12px uppercase letter-spacing `1.5px` weight 600. Hover bg `@18%`+glow. Disabled `opacity:0.35`. Label text "SEND". `.send-btn.danger` = red variant. |
| **`.channel-nav-btn`** | `28×28`, radius 4px, transparent, color `--text-dim`; hover bg `rgba(255,255,255,0.08)` + primary. Disabled `opacity:0.3`. |
| **`.section-reorder-btn`** | `18×18`, radius `--radius-xs`, bg `rgba(255,255,255,0.08)`; hover bg `--primary`, color #fff; disabled `opacity:0.25`. |

### 5.2 Inputs

| Component | Key styling |
|---|---|
| **`.message-input`** (contenteditable) | bg `rgba(255,255,255,0.05)`; `1px solid --glass-border`; radius `0 0 var(--radius-md) var(--radius-md)` (bottom-rounded only); color `#ffffff`; padding `10px 16px`; font `--user-text-size`; `min-height calc(15px*1.4)`, `max-height 160px`. Focus: border `--primary@30%`, bg `0.07`, ring `0 0 0 3px --primary@06%`. Mobile forces `16px`. Placeholder via `data-placeholder` attr. |
| **`.search-input`** | radius `--radius-xs`; padding `8px 28px 8px 12px`; 12px; bg `0.05`. `.search-clear` ✕ at right (shows on `.has-value`). Wrapper hidden until `.active`. |
| **`.form-input/.form-select/.form-textarea`** | width 100%; bg `0.05`; `1px solid --glass-border`; radius `--radius-sm`; color `#ffffff`; padding `11px 14px`; 15px. textarea `min-height 100px; resize:vertical`. Focus ring identical to message-input. |
| **`.form-range`** | track `height 4px` bg `--glass-border` radius 2px; thumb `16×16` round, bg `--primary`. |
| **`.form-label`** | 11px uppercase, letter-spacing 1.2px, color `--text-dim`, weight 600. |

### 5.3 Sidebar list items

- Sidebar `.sidebar`: width **290px**, bg `--bg-secondary`, right border `--glass-border`, `transition: transform 0.15s linear`.
- **`.channel-item / .pm-item`**: padding `9px 12px`; margin `2px 4px`; `1px solid transparent`; radius `--radius-xs`; `min-height 36px`; font `--user-text-size`; flex space-between. Hover (hover-capable): bg `rgba(255,255,255,0.06)` + `padding-left:14px` (slide). **Active**: bg `--primary@10%`, border `@20%`, glow; 3px left accent bar via `::before` (`height:60%; border-radius:0 3px 3px 0; background:--primary`). Flex **ordering**: nymchat channel `-4`, active `-3`, pinned `-2`, has-unread `-1`. Pinned items grey-tinted with grey left bar.
- **`.user-item`**: padding `6px 12px`; margin `2px 4px`; font `calc(--user-text-size - 3px)`; color `--text-dim`; gap 8px. Hover → text + bg `0.04`. `.user-status` dot `6×6` round (online `#22c55e`, away `#eab308`, offline `#6b7280`).
- **`.unread-badge`**: bg `--primary`, color `--bg`, padding `2px 7px`, radius 20px (pill), 10px weight 600, `min-width:3ch`, tabular-nums.
- **`.std-badge`** (standard channel): 9px, `--blue`, bg `rgba(0,128,255,0.1)`, pill. **`.geohash-badge`**: 9px, `--warning`, pill.
- **`.view-more-btn`**: collapses lists past 20 items (`.list-collapsed .list-item:nth-child(n+21){display:none}`).

### 5.4 Chat header

- **`.chat-header`**: padding `16px 24px`; bottom border `--glass-border`; bg `--glass-bg`; flex space-between, overflow hidden. Mobile padding `15px 10px`.
- **`.channel-title`**: `font calc(--user-text-size + 3px)` (18px), color `--primary`, weight 700, letter-spacing 0.3px.
- **`.channel-meta`** 11px / **`.channel-location`** 12px, both `--text-dim`.
- **`.channel-header-controls`**: CSS grid `auto auto`, row-gap 12px, col-gap 2px.

### 5.5 Composer

- **`.input-container`**: padding `12px 16px`; top border `--glass-border`; bg `--glass-bg`; flex gap 10px; sticky bottom. Mobile: column layout, `padding-bottom: max(10px, env(safe-area-inset-bottom))`.
- **`.input-wrapper`**: flex column, relative. **`.message-input-row`**: flex align-end.
- **`.input-buttons`** (toolbar order): hidden `#fileInput` → image button (`selectImage`) → hidden `#p2pFileInput` → file button (`selectP2PFile`) → emoji (`toggleEmojiPicker`) → GIF (`toggleGifPicker`) → `#sendBtn`. Mobile: full-width row, image/file/emoji/gif `flex:1`, send `flex:2`.
- Popout mode `.composer-popout`: input floats absolute, `max-height min(40vh,360px)`, bg `--bg-tertiary`, full `--radius-md`, shadow-lg.

### 5.6 Avatars

| Class | Size | Notes |
|---|---|---|
| `.avatar` | 20×20 | round, cover |
| `.avatar-message` | 18×18 | inline w/ author |
| `.avatar-user-list` | 20×20 | sidebar |
| `.avatar-pm` | 26×26 | PM list / header |
| `.avatar-context` | 64×64 | context-menu profile header, `2px` border + cyan glow |
| `img.avatar-bubble` (group) | 32×32 | bubble layout, sticky bottom |
| `.group-reader-avatar` | 14×14 | overlapping read receipts |

`.user-status-dot` `8×8` round, `2px` border in `--bg`, positioned bottom-right of avatar.

### 5.7 Badges / Flair

- **`.flair-badge`**: inline emoji glyph, `font-size 20px`, `margin-left 5px`, colored + glow (`text-shadow:0 0 10px`). Named flairs: crown `#ffd700`, diamond `#00ffff`, skull `#ff0000`, star `#ffff00`, lightning `#f7931a`, heart `#ff1493`, mask `#ffffff`, plus rocket/shield/flame/snowflake/moon/sun/leaf/music/eye/anchor/gem/genesis (light-mode has muted equivalents).
- **`.supporter-badge`**: gold gradient pill, `padding 2px 10px`, radius 20px, `1px solid rgba(255,215,0,0.3)`; icon+text `#ffd700` 11px uppercase.
- **`.verified-badge`**: `20×20`; blue circle (`#1DA1F2`, light `#1a8cd8`) + white "✓".
- **`.crypto-verified-badge`**: 12×12; green `#2ecc71` / red `#e74c3c` / grey `#9aa0a6`.
- **`.friend-badge`**: inline-flex SVG `20×20`, `#4fc3f7` (light `#0288d1`).
- **`.zap-badge`**: orange gradient pill, `--lightning`, 12px weight 600.
- **`.notification-count-badge`**: bg `--danger`, white, `min-width 16px; height 16px`, radius 8px, top/right `-4px`.

### 5.8 Reactions

- **`.reactions-row`**: flex, gap 5px, margin-top 5px, wrap (self → right-aligned in bubbles).
- **`.reaction-badge`**: bg `rgba(255,255,255,0.05)`; `1px solid --glass-border`; padding `3px 8px`; radius 20px; 12px; gap 3px. Hover scale 1.05 + primary tint. `.user-reacted`: bg `--primary@12%`, border `@35%`, glow.
- **`.add-reaction-btn`**: padding `4px 8px`, radius 20px, 12px, `opacity:0.6`.

### 5.9 Context menus / slideouts

- **`.context-menu`** (right-side user/message panel): `position:fixed; top:0; right:0; width:320px; max-width:85vw; height:100dvh; background:--bg-tertiary; border-left:1px solid --glass-border; z-index:10100; transform:translateX(100%); transition:transform 0.15s linear`. `.active` → `translateX(0)` + `box-shadow:-4px 0 24px rgba(0,0,0,0.4)`. Overlay `--bg` `rgba(0,0,0,0.6)` z 10099.
- **`.context-menu-close`**: `32×32` round, top/right 14px. **`.context-menu-item`**: padding `10px 14px`, 13px, radius `--radius-xs`; hover bg `0.08` + primary; `.danger` → red.
- **`.channel-context-menu`** (popup, not slideout): fixed, `min-width 180px`, radius `--radius-md`, padding 6px, shadow-lg; toggled `display`.
- **`.quick-context-menu`**: `min-width 200px`, padding 4px, bg `rgba(20,20,35,0.92)`, radius 14px, z 10001; hidden `opacity:0; transform:scale(0.9) translateY(-6px)` → `.active` scale 1.
- **`.pubkey-slideout`** (inline expandable in profile): `max-height 0 → 300px` (0.3s), monospace 12px value + copy button.

### 5.10 Modals / dialogs

- **`.modal`** (backdrop): `position:fixed; inset 0; background:rgba(0,0,0,0.7); z-index:10001; display:none` → `.active` flex-centered. (solid-ui: `0.75`.)
- **`.modal-content`**: bg `--bg-secondary`; `1px solid --glass-border`; radius `--radius-xl` (24px); padding 32px; `max-width 500px; width 90%; max-height 90vh`, scroll; shadow `--shadow-lg, --shadow-glow, 0 0 0 1px rgba(255,255,255,0.05)`. Mobile margin 20px.
- **`.modal-close`**: `32×32` round, top/right 14px, bg `0.05`; hover red-tint.
- **`.modal-header`**: 22px, `--primary`, uppercase letter-spacing 1.5px weight 700, bottom border, padding-bottom 14px.
- **`.modal-actions`**: flex gap 10px, centered.
- **`.app-dialog`** (JS confirm/alert/prompt from `dialog.js`): `.modal` + `.app-dialog-content` (`max-width 440px`), with message, optional checkbox/text/textarea + char-count; Cancel (`.icon-btn`) + OK (`.send-btn`, gains `.danger` when destructive). ESC=cancel, Enter=OK (single-line).
- **Settings** uses collapsible `.settings-section` (header `padding 14px 32px`, 12px uppercase, chevron rotates -90° collapsed) instead of tabs, plus sticky `.settings-search`.
- **Toggle/segment groups** (e.g. `.color-mode-group`): container bg `0.04`, radius `--radius-sm`, padding 3px; buttons `flex:1`, radius `--radius-xs`; `.active` bg `--primary@15%`.

### 5.11 Other

- **`.typing-indicator`**: hidden (`height:0; opacity:0`) → `.active` `display:flex; height:24px`; padding `4px 20px`, 12px `--text-dim`; bouncing dots `5×5` round.
- **`.scroll-to-bottom-btn`**: absolute `bottom 90px; right 24px`; `40×40` round; bg `--glass-bg`; `1px solid --glass-border`; color `--primary`; shadow-md; hover scale 1.1. `.visible` shows. (Mobile `36×36`, `bottom 130px`.)
- **`.msg-skeleton`** loading placeholders with shimmer (`sk-shimmer` 1.4s).
- **No `.toast`/snackbar class exists** in CSS — transient notices are not styled; if needed in Flutter, define new visuals.

---

## 6. Chat Layouts — IRC vs Bubble

The single body class `chat-bubbles` switches modes. Selectable via Settings (`selectMessageLayout`). The message anatomy is the same DOM; CSS reshapes it.

### Message row anatomy (shared)
`.message` → `.message-author` (nym + flair badges + verified/supporter) · `.message-time` (timestamp, hover shows full time) · `.message-content` (text/markdown/media/poll) · optional reply `.message-quote` / `blockquote` · `.reactions-row` · delivery/read status.

### IRC mode (default — `body:not(.chat-bubbles)`)
- `.message`: `display:flex; gap:10px; padding:10px 14px; radius:--radius-sm; flex-wrap:wrap; align-items:flex-start; font:--user-text-size`. Hover bg `rgba(255,255,255,0.03)`.
- `.message-author`: color `--secondary` (`.self` → `--primary`); `min-width:120px`; weight 600.
- `.message-time`: `--text-dim` 12px, `min-width:50px`, inline before content.
- `.message-content`: `flex:1`, color `--text`; images max `300×300`.
- `.message.self`: bg `--secondary@5%`, 3px left bar (`rgba(255,255,255,0.3)`). `.message.mentioned`: bg `--secondary@6%`, `--secondary` left bar + glow. `.message.pm`: transparent, purple left bar on hover.

### Bubble mode (`body.chat-bubbles`)
- `.message`: `padding:2px 14px; gap:0; background:none!important; border-radius:0; flex-direction:row`. Left accent bars + hover bg disabled; standalone `.message-time` hidden.
- `.message-content` is the **bubble**: `display:inline-block; padding:8px 12px 6px; border-radius:16px; border-top-left-radius:4px` (tail); `min-width:180px; max-width:85%`; bg `rgba(255,255,255,0.14)`; line-height 1.45.
- `.message.self`: row `justify-content:flex-end`; bubble bg `--primary@25%`, `border-top-right-radius:4px` (tail on right). Solid-ui self uses `color-mix(--primary 22%, #2a2a3a)`.
- `.message-author`: 11px, `flex-basis:100%` (full-width name above bubble); self → right-aligned.
- `.bubble-time-inner`: 10px `--text-dim`, inside bubble, right-aligned (carries `.edited-indicator`).
- **Grouping**: `.message-group` (`display:flex; align-items:flex-end; gap:6px`), `.group-self` reverses direction. `.message-group-avatar` `32×32` sticky-bottom (hidden for self). `.message.bubble-grouped` collapses the name + removes the 4px tail (so only the first bubble in a stack is pointed) and uses negative top margins (-4 to -8px). Entrance animation `.bubble-snap` (~240ms spring).

> Mobile bubble overrides force `flex-direction:row`, `max-width:90%`, and re-show author unless grouped.

---

## 7. Modals Inventory

| id | Wrapper class | Purpose |
|---|---|---|
| `#contextMenu` | `.context-menu` | Right-side user/message action panel (react, mention, PM, zap, gift, quote, copy, translate, friend, report, edit, block, mod/admin) |
| `#groupContextMenu` | `.context-menu` | Group profile: banner, icon, name, members, invite link |
| `#newPMModal` | `.modal` | New private message / new group chat (recipients, group name/avatar/banner/desc) |
| `#reportModal` | `.modal` | Report user/content (type + details) |
| `#shopModal` | `.shop-modal` | Flair shop (tabs: styles, flair, special, limited, inventory) + recovery-code restore |
| `#imageModal` | `.image-modal` | Image/video lightbox (prev/next, download) |
| `#pollModal` | `.modal` | Create poll (question + dynamic options) |
| `#p2pTransfersModal` | `.modal` | P2P (WebRTC) file transfers list |
| `#incomingCallModal` | `.modal` | Incoming audio/video call (accept/reject) |
| `#callOverlay` | `.call-overlay` | Active call UI (grid, in-call chat, reactions, controls) — full-screen |
| `#devNsecModal` | `.modal` | Developer reserved-nickname nsec verification |
| `#nostrLoginModal` | `.modal` | Login with Nostr (NIP-07 extension, NIP-46 remote signer + QR, paste nsec) |
| `#relayStatsModal` | `.modal` | Network/relay stats (cards, throughput canvas, relay list, low-data toggle) |
| `#nickEditModal` | `.modal .nick-edit-modal` | Edit profile (nickname, avatar, banner, bio, lightning addr, reveal privkey slideout) |
| `#setupModal` | `.modal` | Initial onboarding (nickname, avatar, banner, bio, invite banner); full-screen content |
| `#settingsModal` | `.modal` | Settings — collapsible sections (appearance, privacy, messaging, channels, mobile, data) + search |
| `#zapModal` | `.modal .zap-modal` | Send Lightning zap (presets, custom, comment, invoice QR) |
| `#shareModal` | `.modal .share-modal` | Share channel URL |
| `#aboutModal` | `.modal .about-modal` | About (version, build integrity, warrant canary, contact form) |
| `#geohashExplorerModal` | `.geohash-explorer-modal` | Geohash explorer (3D globe canvas) |
| `#tutorialOverlay` | `.tutorial-overlay` | Guided tutorial (highlight + card) |
| `#notificationsModal` | `.modal` | Notifications list + toggles |
| `#appDialogModal` | `.modal .app-dialog` | JS confirm/alert/prompt (built at runtime by `dialog.js`) |

**Inline composer popups (not modals):** `#emojiPicker`, `#gifPicker`, `#commandPalette`, `#kaomojiAutocomplete`, `#autocompleteDropdown`, `#channelAutocomplete`, `#emojiAutocomplete`, `#translateInputDropdown`, plus `#pubkeySlideout`/`#privkeySlideout` inside the nick editor. Reaction/quick-react popups are JS-injected.

---

## 8. Animations / Transitions of Note

- **Sidebar slide (mobile)**: `transform: translateX(-100%) ↔ 0` over `0.15s linear`; `.sidebar.open` adds heavy shadow.
- **Context-menu slide (right)**: `transform: translateX(100%) ↔ 0` over `0.15s linear`; overlay fades `opacity 0.25s`.
- **Quick-context-menu**: scale+fade pop (`scale(0.9) translateY(-6px) → scale(1)` 0.15s ease).
- **Panic wipe overlay** (`.nm-panic-overlay`, built in `panic.js`): triggered by **press-and-hold the `.nym-display` for 2000ms** (`_PANIC_HOLD_MS`). Full-screen overlay with "Encrypting" title, a `40×8` Matrix-style hex/symbol scramble grid (`.nm-panic-grid`) re-randomized every **60ms**, a status line, and a progress bar `.nm-panic-bar`/`.nm-panic-fill`. While shown, all storage is encrypted-then-wiped.
- **Message scroll flash** (`messageScrollFlash`), **quote slide-in** (`quoteSlideIn`), **zap success** (`zapSuccess`), **translate pulse** (`translatePulse`), **typing dots bounce**, **skeleton shimmer** (`sk-shimmer` 1.4s), **bubble entrance** (`.bubble-snap` ~240ms spring), **blink** / **glow** for unread.
- **Channel/PM item hover**: slides right via `padding-left: 12px → 14px`.
- All animations neutralized under `prefers-reduced-motion: reduce`.

---

## 9. Wallpapers Feature

`#wallpaperLayer` (fixed, full-screen, z:0) receives a `wallpaper-pattern-<name>` class. Patterns are tinted by `--wp-r/--wp-g/--wp-b` (the RGB of the active `--primary`, set in `applyTheme`). Default type = `geometric` (`localStorage 'nym_wallpaper_type'`). Setting picker options (`index.html:1421`, `data-wallpaper` values):

| Option | Implementation |
|---|---|
| `none` | no layer |
| `geometric` | layered diagonal `linear-gradient`s (≈8–15% primary tint) |
| `circuit` | base tint `--primary@10%` + circuit SVG pattern |
| `dots` | `radial-gradient(circle, --primary@10% 1px, transparent 1px)` |
| `waves` | tint `@8%` + wave SVG |
| `topography` | tint `@8%` + topo SVG |
| `hexagons` | tint `@8%` + hex SVG |
| `diamonds` | tint `@8%` + diamond SVG |
| `custom` | user-uploaded image → `triggerWallpaperUpload`, stored as `nym_wallpaper_custom_url`; preview `#customWallpaperPreview` |

Settings shows swatches `.wallpaper-preview.wallpaper-<name>` (selected = `.wallpaper-option.selected`). `body.columns-wallpaper` makes column backgrounds transparent so the wallpaper shows through the deck. Light-mode lowers tint opacities.

---

## 10. Icons

All icons are **inline `<svg>`** (mostly `viewBox="0 0 24 24"`, `stroke="currentColor"`, feather/lucide-style 2px stroke, `fill:none`). No icon font, no sprite, no `<img>` icons. Tiny context-menu icons carry helper classes `nm-ico4`/`nm-ico8`. Recurring icons (map to Flutter vector icons / custom painters):

- **send** (paper-plane — actually a "SEND" text button in composer), **attach/image** (framed-image), **file** (folded-corner), **emoji** (smiley), **GIF** (literal `<text>GIF</text>`).
- **settings** (gear), **about/info** (circle-i), **logout** (door+arrow), **search** (magnifier), **bell/notifications**.
- **back/forward/chevron** (polylines — back `15 18 9 12 15 6`, forward `9 6 15 12 9 18`, down `6 9 12 15 18 9` used for collapse + scroll-to-bottom).
- **close** (`✕`/`×` glyph or X-cross SVG).
- **reply/quote** (quote marks), **react** (smiley), **zap/lightning** (bolt), **star/favorite/flair** (5-point star), **share** (3-node graph), **copy** (overlapping rects), **translate** (文/A glyph), **mention** (`@`), **mail/PM** (envelope).
- **friend/user** (head+shoulders variants: add/edit/kick/ban/transfer-owner), **moderator** (star, revoke = star+strike), **block** (circle-slash), **report** (circle-!), **warning** (triangle-!), **edit** (pencil), **delete** (trash).
- **hamburger** (3 lines), **discover/geohash/globe**, call icons (phone, video-camera, mic, screen-share, switch-camera, presenter), **eye** (visibility), **upload-cloud** (wallpaper), **drag-handle** (dots) for columns.

---

## Appendix A — Body class matrix (Flutter state flags)

| Class | Source | Meaning |
|---|---|---|
| `.light-mode` | theme-init / settings | light color scheme |
| `.solid-ui` | theme-init (default ON) | opaque surfaces (no glass blur) |
| `.theme-ghost` | applyTheme | ghost theme (also overrides bg) |
| `.theme-bitchat` | applyTheme | bitchat multicolor (default) |
| `.chat-bubbles` | settings | bubble vs IRC layout |
| `.columns-mode` | settings | deck/multi-column view |
| `.columns-wallpaper` | settings | wallpaper behind columns |
| `.sidebar-reorder-mode` | settings | show section reorder arrows |
| `.nymchat-app` | UA sniff | running in native shell (hides ASCII logo) |
| `.sidebar.open` | runtime | mobile drawer open |
| `.list-collapsed/.list-expanded` | runtime | sidebar list >20 items |
| `.section-collapsed` | runtime | nav section collapsed |

## Appendix B — Z-index ladder

`0` wallpaper/backdrop · `2` sidebar · `100` composer · `150` scroll-to-bottom · `500` mobile input · `9998` mobile-overlay · `9999` mobile sidebar drawer / drag ghost · `10001` modals / quick-context · `10002` login & dev-nsec modals · `10099` context-menu-overlay · `10100` context-menu / channel-context-menu.
