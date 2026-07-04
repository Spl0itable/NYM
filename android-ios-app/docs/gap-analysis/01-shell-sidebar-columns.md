# Gap report 01 — App shell, sidebar, columns/deck, responsive chrome

**Slice:** App shell/layout (`.container`, `.main-content`), the left sidebar (`#sidebar`), the
columns/deck view (`#columnsStrip .cv-strip`), header chrome (`.chat-header` /
`.header-actions` / `.channel-header-controls`), and responsive/mobile behavior (drawer,
breakpoints 768/1024, mobile toggles).

**Headline:** The columns/deck view is the biggest gap — Flutter ships a single-channel,
no-DnD, no-mobile-carousel skeleton of a system the PWA implements with PM/group columns,
drag reorder, a mobile snap carousel + tabs sheet, per-column unread/scroll-to-bottom/typing,
and layout persistence. The shell also has **no tablet breakpoint** (769–1024 wrongly shows the
desktop fixed sidebar instead of the off-canvas drawer), the **desktop header action bar is
icon-only instead of the PWA's text pills** (prior audit DEFERRED — confirmed + detailed
below), and the **sidebar nav-title controls** (discover globe, new-PM, section reorder
arrows) plus **section collapse/order persistence** and **PM long-press menu** are missing.

**Count:** 24 findings — 0 blocker, 8 high, 11 medium, 5 low. Plus 3 verified-correct
notes and 2 incidental/cross-agent items.

Deferral verification (prior audit `docs/audit/04-ui-shell-themes.md` §Deferrals):
- `.header-actions` text-pills-vs-icons → **CONFIRMED real gap**, detailed in **F6**.
- `.channel-nav-btn` hover bg not painted → **CONFIRMED**, see **F18** (also wrong size on mobile).
- Tutorial highlight box → out of this slice (onboarding), not re-verified here.

---

### F1: Columns deck only supports channel columns — no PM or group columns  [SEVERITY: high]
- PWA: `js/modules/columns.js:215` `cvAddColumn(desc)` accepts `desc.type` of `channel`/`pm`/`group`; `_cvColIcon` (464-477) renders a 20px PM/group avatar `<img class="avatar-pm">` or a group SVG; `_cvColTitle` (479-490) resolves PM nym / group name; `_cvAvailableConversations` (774-803) lists channels + PMs + groups in the picker; `_cvSeedDefaults` (193-203) seeds `#nymchat` + most-recent PM + most-recent group.
- Flutter: `lib/widgets/columns/columns_deck.dart:36-51,57-96` — `_columnKeys` is a `List<String>` of channel keys only; `_seedIfNeeded` adds only `channelsProvider` entries; `_openAddColumn` lists only channels; `_ChannelColumn` always renders `Icon(Icons.tag)`.
- Gap: In deck mode the user can only ever see public-channel columns. PMs and group chats — a primary use of the deck — cannot be added or seeded. The add-column sheet shows "No conversations" once all channels are columns even if PMs/groups exist.
- Fix approach: Replace the `String` column model with a descriptor type `{ kind: channel|pm|group, key, channel/geohash | pubkey/nym | groupId }` mirroring `_cvDescForSave`. Seed from `#nymchat` + most-recent PM (`pmListProvider`) + most-recent group (groups provider). In `_ChannelColumn`, branch the header icon: PM/group → `NymAvatar`(size 20)/group glyph; channel → `Icons.tag`. Extend `_openAddColumn` to include PMs + groups (`_cvAvailableConversations`).
- Effort: L  Risk: med  Confidence: high

### F2: No tablet breakpoint — sidebar wrongly fixed at 769–1024px  [SEVERITY: high]
- PWA: `css/styles-themes-responsive.css:442-476` — `@media (min-width:769px) and (max-width:1024px)` makes `.sidebar` `position:fixed; transform:translateX(-100%)` (off-canvas, opened by hamburger), shows `.mobile-header-actions` (hamburger), and **hides** `.header-actions`. `js/app.js:45,98,137,178` gate the open/close/toggle on `window.innerWidth <= 1024` / `> 1024`. So the off-canvas drawer governs the entire 0–1024 range; the fixed two-pane layout is **>1024 only**.
- Flutter: `lib/screens/home_shell.dart:55-56` — `isDesktop = width > NymDimens.mobileBreakpoint` (768). At 769–1024 it renders `_desktop()` (fixed 290px `Sidebar` + `Expanded`), and `chat_pane.dart:163-184` shows the full desktop action row. `NymDimens.tabletBreakpoint = 1024` exists (`nym_metrics.dart:45`) but is never used.
- Gap: On tablets / small laptops / split-screen (769–1024 logical px) Flutter shows a cramped permanent sidebar + the wrong (desktop) header instead of the PWA's hamburger drawer + mobile header. Layout and chrome diverge for the whole tablet range.
- Fix approach: Switch the shell's responsive decision to the PWA's 1024 cut: `final isWide = width > NymDimens.tabletBreakpoint;` for the fixed-vs-drawer layout. Keep a separate `compact` flag (≤768) only where the PWA further changes things (e.g. composer stacking, 24px nav buttons). Drive `ChatPane.compact` from `width <= 1024` so the mobile header (hamburger + notif) shows across 0–1024.
- Effort: M  Risk: med  Confidence: high

### F3: Sidebar action row shown on desktop — PWA shows it only ≤1024  [SEVERITY: high]
- PWA: `css/styles-shell.css:501-507` `.sidebar-actions { display:none }` by default; `styles-themes-responsive.css:203-205` (≤768) and `:466-468` (769–1024) set `display:flex`. `js/app.js:45` confirms the action surface is `'.sidebar-actions'` only when `innerWidth <= 1024`, else `'.header-actions'`. So **on desktop the Flair/Settings/About/Logout buttons live in the header**, not the sidebar; the sidebar action row is mobile/tablet-only.
- Flutter: `lib/widgets/sidebar/sidebar.dart:96` mounts `_SidebarActions` unconditionally for every breakpoint (desktop fixed sidebar included).
- Gap: On desktop, Flutter shows the action buttons in BOTH the sidebar and (icon-only) header — duplicated, and structurally wrong vs. the PWA where the desktop sidebar has no action row.
- Fix approach: Gate `_SidebarActions` to compact/drawer mode only (pass a flag from `HomeShell` when `width <= 1024`, or read `MediaQuery`). Pair with F6 so the desktop header carries the real action pills.
- Effort: S  Risk: low  Confidence: high

### F4: Column drag-to-reorder (desktop) entirely missing  [SEVERITY: high]
- PWA: `js/modules/columns.js:383-438` builds a `.cv-drag-handle` (6-dot grip) in every header; `_cvAttachDnd` (663-730) + `_cvStartColumnDrag` (673-730) implement pointer drag with a `.cv-drag-ghost` (`styles-columns.css:174-182`), `.cv-column.cv-dragging { opacity:0.4 }` (170-172), live reorder, and `_cvSaveLayout`. `.cv-column-header { cursor:grab }` (192). Desktop arrows: `_cvMoveColumn` (348-360).
- Flutter: `columns_deck.dart` — no drag handle, no DnD, no reorder. Columns are fixed in seed order; the only mutation is add/remove.
- Gap: Desktop users cannot reorder deck columns at all (no handle, no drag, no left/right move buttons).
- Fix approach: Wrap the strip in a horizontal reorderable (e.g. `ReorderableListView`/custom `Draggable`+`DragTarget`), add the 6-dot grip to `_ChannelColumn` header, persist order. Cheaper interim: add `cv-col-move` left/right buttons to the header (mirrors `_cvMoveColumn`).
- Effort: L  Risk: med  Confidence: high

### F5: Mobile columns carousel (snap, header dots, pager, tabs sheet) missing  [SEVERITY: high]
- PWA: `css/styles-columns.css:496-571` — at ≤768 `.cv-strip` becomes `scroll-snap-type:x mandatory`, each `.cv-column` is `flex:0 0 100%` full-width with `scroll-snap-align:start`, no border/radius; header hides `.cv-col-title`+`.cv-col-icon` and shows `.cv-col-move` arrows + `.cv-col-dots` position dots. JS: `_cvRebuildHeaderDots` (809-818) draws per-column dots (`.cv-hdot`), `_cvRebuildPager` (823-832) the desktop pager (`.cv-pager`/`.cv-pdot`, ≥769 only), `_cvOpenTabsView`/`_cvBuildTabsView`/`_cvBuildTabsRows`/`_cvSetupTabsDrag` (835-959) the bottom-sheet "Columns" tab switcher with drag-reorder (`.cv-tabs-overlay`/`.cv-tab`, `styles-columns.css:623-772`). `_cvScrollToIndex` (961-977) snaps by `clientWidth` on mobile.
- Flutter: `columns_deck.dart:112-133` always renders the same horizontal `SingleChildScrollView` of 360px columns on every width — no full-width snap, no header dots, no pager, no tabs sheet.
- Gap: On phones the deck is a tiny-360px-columns horizontal scroller instead of the PWA's one-column-per-screen swipe carousel with dot indicator and a tab-switcher sheet. Major mobile UX divergence.
- Fix approach: In `ColumnsDeck`, when `width <= 768` use a `PageView` of full-width columns (snap), render a dot indicator, hide column title/icon and show prev/next + a dots affordance that opens a `showModalBottomSheet` "Columns" list (reorderable). Reuse the `.cv-tab` metrics from `styles-columns.css:684-772`.
- Effort: L  Risk: med  Confidence: high

### F6: Desktop `.header-actions` are icon-only — PWA uses uppercase text pills  [SEVERITY: high]
- PWA: `index.html:637-661` `.header-actions` = Notifications (icon+badge) + **Flair / Settings / About / Logout as `.icon-btn` with visible text labels**. `css/styles-shell.css:906-935`: `.header-actions { gap:5px; flex-wrap:wrap }`; `.icon-btn { background:rgba(255,255,255,0.05); border:1px solid var(--glass-border); border-radius:var(--radius-xs)(8); color:var(--text); padding:7px 14px; font-size:12px; font-weight:500; text-transform:uppercase; letter-spacing:0.8px; gap:5px }`, hover → primary@12 fill / primary text / primary@30 border / `0 0 15px primary@10` glow. SVG inside is 14×14.
- Flutter: `lib/widgets/chat/chat_pane.dart:234-302` `_desktopActions` renders everything via `_NavBtn` (370-403) — bare 32×32 icon-only `InkWell`s, no bg/border/label/uppercase. There is also no Notifications button and no notification count badge in the Flutter desktop header.
- Gap: The desktop header bar looks completely different: small ghost icons vs. bordered uppercase text pills with a notifications bell+badge. (Prior audit's DEFERRED item — confirmed; the overflow concern is real but the PWA's answer is `flex-wrap:wrap`, so the pills wrap rather than truncate.)
- Fix approach: Add a `_HeaderPill` widget (bg white@0.05, 1px glassBorder, radius `NymRadius.xs`, padding 7/14, 12px w500 uppercase ls 0.8, icon 14 + 5 gap, hover→primary states) and render Notifications+badge / Flair / Settings / About / Logout with it. Wrap the action group in a `Wrap` (spacing 5) to match `flex-wrap:wrap`. Keep back/forward + channel-action (favorite/share/poll/call) as 28×28 `.channel-nav-btn`-style buttons — those are a SEPARATE group in the PWA (`.channel-action-buttons`, F8/F19), not part of `.header-actions`.
- Effort: M  Risk: med  Confidence: high

### F7: Whole sidebar scrolls in PWA; Flutter pins header/actions and scrolls only sections  [SEVERITY: high]
- PWA: `css/styles-shell.css:23-35` `.sidebar { overflow-y:auto; height:100dvh }` — the entire column (header + actions + all three sections) is one scroll container; the identity header scrolls away with content.
- Flutter: `lib/widgets/sidebar/sidebar.dart:90-166` — `_header` and `_SidebarActions` are fixed `Column` children; only the three sections live inside the scrolling `ListView` (97-165).
- Gap: Scroll behavior differs — in Flutter the identity header/actions stay pinned while the PWA scrolls them off. With many channels/PMs/nyms the layouts diverge (and the pinned-header version can't reach the bottom of long lists if the viewport is short, though `Expanded` mitigates).
- Fix approach: Move `_header` + `_SidebarActions` to be the first scrolling children of a single `ListView`/`CustomScrollView` (everything in one scrollable), matching `.sidebar { overflow-y:auto }`. Verify the mobile drawer still scrolls as one piece.
- Effort: M  Risk: med  Confidence: med (layout judgment call; confirm against device behavior)

### F8: `.channel-header-controls` is a 2-column wrapping grid; Flutter lays nav/action buttons inline  [SEVERITY: medium]
- PWA: `css/styles-shell.css:773-786` — `.channel-header-controls { display:grid; grid-template-columns:auto auto; row-gap:12px; column-gap:2px }`, with `.channel-nav-buttons` and `.channel-action-buttons` as `display:contents` so back/forward (row 1) and favorite/share/call/video (row 2+) flow into a 2-wide grid. In columns-mode this block has `min-height:68px` (`styles-columns.css:17-20`).
- Flutter: `chat_pane.dart:161-227` puts back/forward and all desktop actions in a single horizontal `Row` (no grid, no 12px row-gap, no wrapping).
- Gap: On the left side of the desktop header the PWA stacks nav vs. action buttons into a compact 2-column grid above the title; Flutter strings them in one row, changing header height/wrapping and the title's vertical position.
- Fix approach: Recreate the left controls cluster as a `Wrap`(2 columns, runSpacing 12, spacing 2) or a small grid: row 1 back/forward, row 2 favorite/share/poll. Reserve `min-height:68px` in columns mode (ties to F23).
- Effort: M  Risk: med  Confidence: med

### F9: Per-column unread badge missing  [SEVERITY: medium]
- PWA: `index.html` header includes `<span class="cv-col-unread">`; `css/styles-columns.css:237-253` styles it (bg `--primary`, color `--bg`, radius 20, 10px w600, min-width 3ch content-box, tabular-nums, `:empty{display:none}`); `js/modules/columns.js:26-58` (`_cvMarkColumnRead`/`_cvMarkVisibleColumnsRead`) maintains it.
- Flutter: `columns_deck.dart:183-214` column header has icon + title + close only — no unread count.
- Gap: Deck columns don't surface unread counts; users can't see which non-focused columns have new messages.
- Fix approach: Add a `_UnreadPill` (reuse sidebar's) to `_ChannelColumn` header before the close button, fed by `unreadCountsProvider[entry.key]`.
- Effort: S  Risk: low  Confidence: high

### F10: Per-column "scroll to bottom" button missing  [SEVERITY: medium]
- PWA: `js/modules/columns.js:415-420` adds a `.cv-scroll-bottom` button per column; `css/styles-columns.css:136-163`: 36×36 circle, `position:absolute; bottom:16px; right:16px`, bg `--glass-bg`, 1px glassBorder, color `--primary`, shadow `--shadow-md`, `.visible{display:flex}`, hover scale 1.1. Shown when the column isn't at bottom (`_cvAttachColumnScroll`, 629-662).
- Flutter: `columns_deck.dart:216-236` — plain reversed `ListView`, no scroll-to-bottom affordance.
- Gap: When scrolled up in a column there's no jump-to-latest button (the single-view PWA has one too — see Incidental I1).
- Fix approach: Wrap each column body in a `Stack`; track scroll offset; show a 36×36 circular primary button bottom-right when not at bottom, animate-scroll to bottom on tap.
- Effort: M  Risk: low  Confidence: high

### F11: Sidebar section collapse state not persisted (and uses different control)  [SEVERITY: medium]
- PWA: `js/modules/sidebar-sections.js:72-108` persists collapsed sections to `localStorage['nym_sidebar_section_collapsed']` (+ settings sync) and restores on load; collapse is a dedicated `.collapse-icon` chevron (`index.html:485-487,533-535,566-568`) that rotates −90° when collapsed (`styles-shell.css:226-228`). The whole `.nav-title` row is the toggle target only in reorder mode.
- Flutter: `lib/widgets/sidebar/sidebar.dart:37-39,101-161` — `_channelsOpen/_pmsOpen/_nymsOpen` are in-memory `setState` flags (lost on restart); the entire title row toggles open/close (459-491), and a separate chevron mirrors it.
- Gap: Collapsed sections reset every launch; no settings/cloud sync. Minor: tapping the title toggles collapse (PWA reserves that for reorder long-press).
- Fix approach: Back the three flags with persisted settings (`StorageKeys`, mirror `nym_sidebar_section_collapsed`); load on init. Keep the chevron as the collapse control.
- Effort: M  Risk: low  Confidence: high

### F12: Sidebar section reordering (long-press + up/down arrows, persisted) missing  [SEVERITY: medium]
- PWA: `index.html:461-468,512-518,551-557` each `.nav-title` has `.section-reorder-arrows` (up/down `.section-reorder-btn`, 18×18, `styles-shell.css:149-187`), hidden until `body.sidebar-reorder-mode`. `js/modules/sidebar-sections.js:42-65,309-378`: 500ms long-press on a title toggles reorder mode; arrows move sections; order persists to `localStorage['nym_sidebar_section_order']` and is reapplied on load.
- Flutter: `sidebar.dart` — section order is hardcoded (Channels, PMs, Nyms); no reorder mode, no arrows, no persistence.
- Gap: Users can't reorder the three sidebar sections; PWA users who did will see their saved order ignored.
- Fix approach: Add a `reorderMode` state toggled by a 500ms long-press on the section title; render up/down arrow buttons (18×18, white@0.08 bg, primary hover) in the header when active; reorder a list-of-sections and persist (`nym_sidebar_section_order`).
- Effort: M  Risk: med  Confidence: high

### F13: PM list items have no long-press / context menu (Block / Leave)  [SEVERITY: medium]
- PWA: `js/modules/sidebar-sections.js:216-307` — 500ms long-press on `.pm-item` opens a context menu with Block/Unblock user + Leave conversation (and channels get Favorite/Hide/Block; `setupSidebarItemMenus` attaches to `pmList` too). Haptic on fire.
- Flutter: `lib/widgets/sidebar/pm_list_item.dart` (whole file) — only `InkWell.onTap`; no `onLongPress`/`onSecondaryTap`/menu. (Channels DO have it: `channel_list_item.dart:46-49`.)
- Gap: From the sidebar a user cannot block a user or leave/delete a PM thread via long-press; the affordance exists for channels but not PMs, an inconsistency a user will notice.
- Fix approach: Add `onLongPressStart`/`onSecondaryTapDown` to `PMListItem` opening a context menu (Block/Unblock, Leave conversation) wired to the existing block/deletePM actions, mirroring `_buildSidebarMenuItems` PM branch.
- Effort: M  Risk: low  Confidence: high

### F14: Mobile hamburger/notif toggles wrong style (40×40 bordered pill vs 32×32 ghost icon)  [SEVERITY: medium]
- PWA: `index.html:662-677` `.mobile-header-actions` holds `.mobile-notif-toggle` (with `.notification-count-badge`) + `.mobile-menu-toggle` (hamburger). `css/styles-components.css:680-708`: each toggle is **40×40**, `border-radius:var(--radius-sm)(12)`, `background:rgba(20,20,35,0.8)`, `1px solid --glass-border`, `color:var(--primary)`, SVG 20×20. The group has `gap:8px; margin-left:12px`.
- Flutter: `chat_pane.dart:163-217` compact branch renders the hamburger and notif as bare `_NavBtn` (32×32, no bg/border, `color: textDim`, icon 20). No notification count badge.
- Gap: The mobile header buttons are visually wrong — small borderless dim-grey icons instead of 40×40 dark rounded primary-colored pills; and the unread notification badge is absent on mobile.
- Fix approach: Build a dedicated mobile-toggle widget (40×40, radius `NymRadius.sm`, bg `0xFF14141F`@0.8 ≈ `rgba(20,20,35,0.8)`, 1px glassBorder, color primary, icon 20) and use it for both buttons; add a notification count badge overlay (see F22).
- Effort: S  Risk: low  Confidence: high

### F15: Sidebar nav-title "discover globe" (channels) and "new message" (PMs) icons missing  [SEVERITY: medium]
- PWA: `index.html:470-478` channels `.nav-title` has a `.discover-icon` (globe) → `showGeohashExplorer`; `:521-526` PMs `.nav-title` has a `.search-icon new-pm-btn` (plus) → `openNewPMModal`. Styled in `styles-shell.css:189-214` (20×20 hit, 14×14 SVG, dim→primary hover).
- Flutter: `lib/widgets/sidebar/sidebar.dart:432-501` `_NavSection` renders only a search `_MiniIcon` + collapse `_MiniIcon`. No globe on the Channels header, no plus on the PMs header.
- Gap: Two discoverable entry points are gone from the sidebar: the geohash globe explorer (Channels) and "new PM" (PMs). (Both exist in the desktop header in Flutter, but the sidebar affordances — the only ones on mobile/tablet where the header is collapsed — are missing.)
- Fix approach: Parameterize `_NavSection` with optional leading action icons: add a globe icon (→ `GeohashExplorer`) for Channels and a plus icon (→ `NewPmModal`) for PMs, placed before the search/collapse icons (order: [reorder arrows] title [globe|plus] search collapse).
- Effort: S  Risk: low  Confidence: high

### F16: Sidebar identity header missing ASCII logo + uses 20px avatar instead of 32px  [SEVERITY: medium]
- PWA: `index.html:410-422` `.sidebar-header` opens with a `<pre class="logo-ascii">` "nymchat" ASCII banner (`styles-shell.css:44-53`: 4.5px monospace, color `--primary`, opacity 0.9, margin-bottom 8) — hidden only when `body.nymchat-app` (the native wrapper), so in the web shell it shows. The `.nym-display` avatar `#sidebarAvatar` is `class="avatar nm-h-14"` = **32×32** (`no-inline.css:32` overrides `.avatar`'s 20px; matching skeleton `.nym-sk-avatar` is 32px, `styles-chat.css:2115`). `.nym-label` text is **"Your Nym (click to edit)"**.
- Flutter: `lib/widgets/sidebar/sidebar.dart:178-248` — no ASCII logo; avatar `NymAvatar(size: 20)` (215); label is `"NYM"` (203).
- Gap: (a) Header avatar is 20px vs the PWA's 32px — visibly smaller. (b) Label reads "NYM" vs "Your Nym (click to edit)" (loses the affordance hint). (c) The ASCII banner is absent. Note: `body.nymchat-app` hides the logo for the *native* build, so omitting it in a native-styled Flutter app is arguably intentional — flag (c) as low/optional but call it out so the fix agent decides.
- Fix approach: Bump `NymAvatar(size: 32)` in the header; change label string to "Your Nym (click to edit)". Decide on the ASCII logo (likely keep hidden to match `body.nymchat-app`; if web-parity wanted, add a `Text` with the banner in a monospace ~4.5px). Prior audit's "20 avatar" note referred to `.user-item`, not this header — this is a genuine miss.
- Effort: S  Risk: low  Confidence: high

### F17: `.user-list` (Online Nyms) section structure differs — no border, wrong padding, not a collapsible nav-section  [SEVERITY: medium]
- PWA: `index.html:549` the nyms group is `<div class="user-list" id="userList" data-section="nyms">`, NOT a `.nav-section`. `css/styles-shell.css:537-542` `.user-list { flex:0 1 auto; padding:10px; min-height:0 }` — **no bottom border**, 10px padding (vs `.nav-section` 16/12/12 with bottom border, lines 121-125). It still has its own `.nav-title` with search + collapse + reorder.
- Flutter: `lib/widgets/sidebar/sidebar.dart:145-161` renders Online Nyms via the same `_NavSection` as Channels/PMs — so it gets the nav-section padding (`fromLTRB(20,16,12,10)`, 462) and there is no border modeling either way; the section box metrics don't match the PWA's distinct `.user-list` treatment.
- Gap: The Online Nyms section's outer padding (10 vs 16/12/12) and lack-of-border differ from the PWA, making the third section's spacing slightly off relative to the two above it.
- Fix approach: Give the nyms section a distinct wrapper with 10px padding and no bottom divider (the channels/pms sections DO get `border-bottom:1px solid glass-border`, which Flutter also omits — see F21).
- Effort: S  Risk: low  Confidence: med

### F18: `.channel-nav-btn` fixed 32×32 — PWA is 28×28 desktop / 24×24 mobile; no hover bg  [SEVERITY: medium]
- PWA: `css/styles-shell.css:788-816` `.channel-nav-btn { width:28px; height:28px; border-radius:4px; color:--text-dim }`, hover `background:rgba(255,255,255,0.08); color:--primary`, `:disabled{opacity:0.3}`. Mobile `styles-themes-responsive.css:316-319` → **24×24** (and `.channel-nav-buttons{gap:0}` at 312-314). SVG 18×18.
- Flutter: `chat_pane.dart:370-402` `_NavBtn` is a hardcoded **32×32** `SizedBox` at every breakpoint; disabled handled (0.3), but **no hover background** (prior audit DEFERRED this — confirmed). Used for back/forward AND repurposed for all desktop action icons and the mobile hamburger.
- Gap: Nav/back-forward buttons are 4px too big on desktop and 8px too big on mobile, and lack the white@0.08 hover fill. (Also conflated with header action buttons and mobile toggles — see F6/F14.)
- Fix approach: Size `_NavBtn` 28 desktop / 24 compact; add a hover/highlight color (white@0.08 bg + primary icon) via `InkWell` `hoverColor`/`onHover` or a `MouseRegion`. Icon 18.
- Effort: S  Risk: low  Confidence: high

### F19: Channel header is missing the Favorite/Share buttons that the PWA shows for non-nymchat channels  [SEVERITY: low]
- PWA: `index.html:602-628` `.channel-action-buttons` = favorite + share + audio-call + video-call, always present in the DOM (call buttons toggle via `nm-call-hidden`). Favorite/share are part of the header controls grid for channels.
- Flutter: `chat_pane.dart:256-279` includes favorite, share, AND poll for channels (good), plus call/video (281-290). So Flutter actually has favorite+share+poll+calls — close. The discrepancy: PWA puts these in the left `.channel-action-buttons` grid (row 2), while Flutter appends them to the right action cluster.
- Gap: Mostly a placement/grouping difference (covered by F8). Functionally Flutter has the buttons; the poll button is an addition not in the PWA's channel-action group (PWA exposes poll via the composer command, not a header button) — verify whether the header poll button is desired or should move.
- Fix approach: Resolve via F8 (grid placement). Confirm the poll header button is intended; if matching PWA exactly, drop it from the header.
- Effort: S  Risk: low  Confidence: med

### F20: Mobile overlay backdrop opacity 0.5 vs PWA 0.6  [SEVERITY: low]
- PWA: `index.html:63` `.mobile-overlay`; `css/styles-shell.css:1-10` `background: rgba(0,0,0,0.6)` (and `styles-themes-responsive` solid-ui variants). Sidebar open shadow `10px 0 40px rgba(0,0,0,0.5)` (`:200`).
- Flutter: `lib/screens/home_shell.dart:118` backdrop `Colors.black.withValues(alpha: 0.5)`.
- Gap: The dim behind the open drawer is slightly lighter than the PWA (0.5 vs 0.6).
- Fix approach: Change the backdrop alpha to 0.6 in `home_shell.dart`.
- Effort: S  Risk: low  Confidence: high

### F21: `.nav-section` bottom divider between Channels/PMs not rendered  [SEVERITY: low]
- PWA: `css/styles-shell.css:121-125` `.nav-section { border-bottom:1px solid var(--glass-border) }` — a hairline separates Channels from PMs (and PMs from the nyms list).
- Flutter: `lib/widgets/sidebar/sidebar.dart:452-500` `_NavSection` draws no bottom border between sections.
- Gap: The sidebar's three sections run together without the PWA's separating hairlines.
- Fix approach: Add a `Border(bottom: BorderSide(color: c.glassBorder))` (or a trailing `Divider`) to the Channels and PMs `_NavSection` wrappers (not the last/nyms one per F17).
- Effort: S  Risk: low  Confidence: high

### F22: Desktop header notifications button + count badge absent  [SEVERITY: low]
- PWA: `index.html:638-644` `.icon-btn.notifications-btn` is the FIRST header action, with a `.notification-count-badge` (`styles-components.css:968+`: absolute, top/right −4px). Mobile mirror `notifBadgeMobile` (`index.html:663-669`).
- Flutter: `chat_pane.dart:234-302` desktop actions start at Discover — no Notifications button, no badge (desktop or mobile).
- Gap: No way to open the notifications modal from the desktop header, and no unread-notification indicator anywhere in the header chrome.
- Fix approach: Prepend a Notifications pill (F6) on desktop and a badge on the mobile notif toggle (F14), both opening the notifications modal and showing an unread count.
- Effort: S  Risk: low  Confidence: med

### F23: Columns-mode chat-header height reservation not modeled  [SEVERITY: low]
- PWA: `css/styles-columns.css:17-25` — in `body.columns-mode` `.channel-header-controls{min-height:68px}` and `.chat-header{height:calc(37px + max(68px,(--user-text-size+3px)*1.4+35px))}`; mobile (≤768) resets to `height:auto` (497-499).
- Flutter: `chat_pane.dart:149-160` uses the same padding-based header in both single and columns modes; no extra height in columns mode.
- Gap: In deck mode the header is shorter than the PWA's, subtly shifting the columns' top alignment vs. the PWA.
- Fix approach: When `useColumns` is true (and width>768), give the header a `minHeight` of `37 + max(68, (textSize+3)*1.4 + 35)`.
- Effort: S  Risk: low  Confidence: med

### F24: `.cv-add-column` hover/affordance states minor mismatch  [SEVERITY: low]
- PWA: `css/styles-columns.css:299-320` `.cv-add-column` hover → `border-color:--primary; color:--text-bright; background:primary@4`. The dashed border is `2px dashed --glass-border`.
- Flutter: `columns_deck.dart:245-334` draws the 2px dashed border + "+ Add column" label, but no hover state (border-color/color/bg change on hover) and the dash pattern is hardcoded 6/4 (PWA dash length is browser-default for `dashed`, not 6/4 — visually close, low risk).
- Gap: The add-column tile doesn't react on hover (cosmetic on touch; visible on desktop).
- Fix approach: Add a `StatefulWidget`/`MouseRegion` hover that swaps the dashed color to primary, label to textBright, and fills primary@0.04.
- Effort: S  Risk: low  Confidence: med

---

## Verified correct (no gap)

- **No FAB exists in the PWA.** Searched `index.html` + all CSS/JS for `fab`/floating-action/compose-fab — none. The mobile compose affordance is the new-PM plus icon in the PM section header (F15) + the hamburger. Flutter correctly has no FAB; the brief's "FAB" is a non-issue. (Verified.)
- **Mobile drawer mechanics** (300px width, `translateX(-100%)`→0 over `0.15s linear`, slide-in shadow) match between `css/styles-themes-responsive.css:179-201` and `home_shell.dart:103-142` (modulo the backdrop alpha, F20, and the breakpoint, F2).
- **Columns dimensions** — `.cv-strip` gap/padding 12, `.cv-column` 360px, `.cv-add-column` 220px dashed, `.cv-column-header` 10/12 + bottom border, shadow `--shadow-md`, transparent-on-wallpaper — all match (`styles-columns.css` ↔ `columns_deck.dart`), as the prior audit found. Only the *behaviors* (F1/F4/F5/F9/F10) and mobile layout are missing, not the desktop box metrics.

## Incidental / cross-agent (note, don't fix here)

- **I1 — single-view scroll-to-bottom button + typing indicator missing.** `index.html:688-699` has `.typing-indicator` and `.scroll-to-bottom-btn` (36×36; `styles-themes-responsive.css:347-353`), driven by `js/app.js:7040-7138`. Flutter `lib/widgets/chat/messages_list.dart` has neither (grep found nothing). These belong to the chat/messages slice (another agent), but they are shell-adjacent overlays inside `.main-content`; flag for that owner.
- **I2 — `body.columns-mode` hides `#messagesScroller` and shows `#columnsStrip`** as siblings inside one `.main-content` (`styles-columns.css:9-15`); the single composer/typing/scroll overlays are shared. Flutter swaps the whole content widget (`home_shell.dart:83-92`: `ColumnsDeck` *replaces* `ChatPane`), so in deck mode Flutter has **no composer at all**, whereas the PWA keeps the composer (`_cvSetColumnHeader`/`_cvSetComposeHeader`, columns.js:607-623, retarget the shared input to the focused column). This is a real gap but spans composer ownership — verify with the chat-composer agent whether the deck should keep a (focused-column-targeted) composer.
