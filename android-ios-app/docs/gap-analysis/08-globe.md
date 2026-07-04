# Gap report 08 — Geohash globe / map explorer UI

Slice: the interactive world map (heatmap, grid cells, channel dots, info panel,
controls, day/night terminator, zoom/pan). PWA source: `pwa/js/modules/geohash-globe.js`
(globe), `pwa/js/modules/channels.js` (channel build + info-panel content),
`pwa/js/modules/inline-bindings.js` (control wiring), CSS in
`pwa/css/styles-components.css` (lines 1690-1974, NOT styles-features.css as the
brief said) + `pwa/css/styles-themes-responsive.css` + `pwa/css/no-inline.css`.
Flutter target: `lib/features/globe/{geohash_explorer,geo_map_painter,geo_projection,geohash_channel,topojson}.dart`.

The projection/geohash/grid/day-night/heat-stop **math** is a verbatim port and is
correct (prior audit `docs/audit/07-*.md` confirmed it byte-faithful, and re-verified
here). The gaps are all in **rendering layers and panel content** that the PWA draws
but Flutter omits or simplifies. The two biggest user-visible items are the heatmap
palette-accumulation (audit DEFERRED **D1**) and the two entirely-missing map detail
layers (admin-1 borders/labels + city dots/labels), which the bundled-asset set
cannot even feed.

**Finding count: 12** (1 blocker, 4 high, 5 medium, 2 low) + 1 incidental.

---

### F1: Heatmap colors each blob by its own peak instead of accumulating alpha then palette-remapping  [SEVERITY: high]
- PWA: `geohash-globe.js:736-797` `drawHeatmap`. Renders **grayscale** radial blobs
  (`rgba(0,0,0,intensity)` → `rgba(0,0,0,0)`) additively (`globalCompositeOperation='lighter'`,
  line 746) into a half-res offscreen canvas (`HEAT_SCALE=0.5`, line 371). Then it reads
  the summed pixels back (`getImageData`, 768) and, **per pixel**, looks up the 256-entry
  palette by the *accumulated alpha* value: `d[i]=palette[a*4]; d[i+1]=palette[a*4+1]; …`
  (lines 770-778). So where two channels overlap, their alphas add and the pixel climbs
  the palette blue→green→yellow→red. The palette (`getHeatPalette`, 160-176) is a 256px
  canvas gradient with stops:
  - `0.00` → `rgba(0,0,128,0)`
  - `0.20` → `rgba(0,160,255,0.75)`
  - `0.45` → `rgba(0,255,120,0.9)`
  - `0.70` → `rgba(255,220,0,0.95)`
  - `1.00` → `rgba(255,40,0,1)`
  baseRadius `clamp(22,70, 24 + zoom*3.5)` then `*HEAT_SCALE` (748-749); weight
  `log(msgs+1)/log(maxMsg+1)`, intensity `min(1, 0.18 + 0.82*weight)` (752-760). Final blit
  `drawImage(heatCanvas, 0,0, cssWidth, cssHeight)` with `imageSmoothingQuality='low'` (782-784).
- Flutter: `geo_map_painter.dart:296-330` `_drawHeatmap`. The 256-entry palette
  (`_HeatPalette`, lines 99-141) reproduces the **exact** five stops, good. BUT each blob is
  drawn at **full** resolution as a radial gradient whose center color is already
  `palette.colorFor(alpha)` at *that blob's own* peak intensity (lines 318-321), then composited
  with `BlendMode.plus` (327). Overlaps therefore **sum the RGB of two already-colored blobs**
  (e.g. two blue blobs → brighter blue / white-ish), they do NOT climb the palette to
  green/yellow/red the way the PWA does. No half-res buffer, no per-pixel alpha→palette remap.
- Gap: Visually divergent heatmaps. PWA hotspot clusters glow red at the core; Flutter
  shows additively-brightened single-hue blobs. Dense areas read wrong. This is audit D1.
- Fix approach (the recipe the audit prescribed): the per-pixel remap can't run inside the
  synchronous `CustomPainter.paint`. Precompute an accumulation `ui.Image` **outside** paint:
  (1) build a half-res `ui.PictureRecorder`/canvas sized `(w*0.5, h*0.5)`; draw each channel as
  a **grayscale** radial `Gradient.radial(p*0.5, radius*0.5, [Color(0xAA000000*intensity-as-alpha)…
  Color(0x00000000)])` with `BlendMode.plus`; (2) `await picture.toImage(w2,h2).toByteData()`;
  (3) walk the RGBA bytes, and for each pixel with `a>0` write `palette._argb[a]` (reuse the
  existing `_HeatPalette._argb` lookup — already alpha-indexed 0..255); (4) `decodeImageFromPixels`
  back into a `ui.Image`; (5) store it on state and have the painter just `canvas.drawImageRect`
  it to full size with `FilterQuality.low`. Recompute on zoom/pan/activity change (debounced).
  The palette table already exists and is correct, so only the accumulate-then-remap pipeline
  is new. Hover white ring (lines 332-347) stays as-is in paint.
- Effort: L  Risk: med  Confidence: high

### F2: Admin-1 (state / province) border layer is entirely missing  [SEVERITY: high]
- PWA: `geohash-globe.js:580-621` `drawAdmin1` draws sub-national borders once zoom ≥
  `ADMIN1_ZOOM_THRESHOLD=2.5` (line 10), fading in over `[2.5 .. 4.0]` via `globalAlpha=t`
  (582-589), stroke `styles.adminBorder` = dark `rgba(180,200,220,0.22)` / light
  `rgba(120,140,160,0.55)` (`getMapStyles` 190), lineWidth 0.4. Data is lazy-loaded
  (`loadAdmin1Features` / `ne_50m_admin_1_states_provinces_lakes.json`, lines 7,94-97,355-361)
  via `ensureSubregions` on every zoom. Decoder exists: `geo-decode.js:102` `decodeAdmin1`.
- Flutter: `geo_map_painter.dart:177-193` `paint()` draws ocean → graticule → world →
  labels → channels/heatmap → daynight → grid → userLocation. There is **no** admin1 draw call,
  no admin1 feature list, and `geohash_explorer.dart` never loads a second dataset. `topojson.dart`
  only ports `decodeWorld` — no `decodeAdmin1`. `assets/data/` contains **only** `countries-110m.json`
  (verified: `ls assets/data`), so the source data isn't even bundled (`pubspec.yaml:98` globs
  `assets/data/`).
- Gap: Zooming into a country shows a flat fill with no state/province lines — the PWA shows
  them. Noticeable on any zoom-in.
- Fix approach: (1) vendor `ne_50m_admin_1_states_provinces_lakes.json` into `assets/data/`;
  (2) add a `decodeAdmin1` to `topojson.dart` mirroring `geo-decode.js:102-118` (GeoJSON, not
  TopoJSON — it produces `{type, coordinates, bounds, centroid, name}`); (3) in
  `geohash_explorer.dart` lazy-load it (compute) once `_view.zoom >= 2.5` (mirror `ensureSubregions`)
  and pass into the painter; (4) add `_drawAdmin1(canvas,size)` with the fade-in `t` over
  [2.5,4.0], `globalAlpha`/`saveLayer`-with-alpha, color from a new `style.adminBorder`, width 0.4,
  + bounds cull (597). Be mindful of asset size (admin1 is large — keep on isolate).
- Effort: L  Risk: med  Confidence: high

### F3: Admin-1 labels are missing  [SEVERITY: medium]
- PWA: `geohash-globe.js:623-651` `drawAdmin1Labels` — at zoom ≥ 4, stroked labels for each
  admin1 feature whose projected span ≥ `max(40, name.length*5.5)`, font `500 9px`, fill
  `styles.adminLabel` (dark `rgba(190,205,220,0.65)` / light `rgba(70,80,95,0.75)`, line 193),
  stroke `styles.labelStroke`, lineWidth 2.5.
- Flutter: MISSING — depends on F2's admin1 data; no equivalent.
- Gap: No state/province names at high zoom. The PWA shows them.
- Fix approach: after F2, add `_drawAdmin1Labels` reusing `_strokedText` with weight w500,
  fontSize 9, the new `style.adminLabel`, the same span gate. Trivial once admin1 features exist.
- Effort: S (after F2)  Risk: low  Confidence: high

### F4: City dots + city labels are missing  [SEVERITY: high]
- PWA: `geohash-globe.js:653-689` `drawCities` — at zoom ≥ `CITY_ZOOM_THRESHOLD=2.5` (line 11)
  draws 1.5px dots (`dotR=1.5`) colored `styles.cityDot` (dark `rgba(220,232,245,0.9)` / light
  `rgba(60,70,85,0.85)`, line 194) for populated places whose `scalerank ≤ rankCutoff`, where
  rankCutoff steps with zoom: `<3→2, <4→4, <6→6, <8→8, else 10` (657-660). At zoom ≥ 3 it also
  draws the city name (`500 9px`, left-aligned, offset `+4px`, fill `styles.cityLabel`, line 195)
  (669,681-687). Data lazy-loaded (`ne_50m_populated_places_simple.json`, lines 8,99-103,362-368);
  decoder `geo-decode.js:119` `decodeCities` (reads `scalerank`, sorts by rank).
- Flutter: MISSING — `paint()` has no city layer, `topojson.dart` has no `decodeCities`,
  and the cities asset isn't bundled.
- Gap: Zooming in never reveals city markers/labels; the PWA progressively reveals cities by
  importance. Significant loss of map context.
- Fix approach: vendor `ne_50m_populated_places_simple.json`; add `decodeCities` to `topojson.dart`
  (output `{lng,lat,name,rank}`, sort by rank like 136); lazy-load on zoom ≥ 2.5 in the explorer;
  add `_drawCities(canvas,size)` with the rankCutoff ladder, 1.5px dots (`style.cityDot`), and
  the zoom ≥ 3 left-aligned stroked labels (`style.cityLabel`). Use `inView(p,80)` cull (674).
- Effort: M  Risk: med  Confidence: high

### F5: Info panel content is wrong — no reverse-geocoded location, no distance, no loading state  [SEVERITY: high]
- PWA: `channels.js:345-409` `selectGeohashChannel` builds the panel as four rows
  (`channels.js:361-372`):
  - **Coordinates:** `${lat.toFixed(4)}, ${lng.toFixed(4)}` — raw decimal degrees, 4 dp.
  - **Location:** starts as the literal text `Loading location...` (line 360), then async
    `fetchGeocode(lat,lng,10)` fills it with `"city, country"` (or `Unknown location` / `Unknown`
    on error) by replacing `#locationInfoItem` (388-407).
  - **Distance:** `${calculateDistance(...).toFixed(1)} km away` — only when `this.userLocation`
    exists (355-357, 368); omitted otherwise.
  - **Messages:** `${channel.messages}` (369-371).
  Title `#<geohash>` (353). Join button label is **`Go to Channel`** when already joined, else
  **`Join Channel`** (375-379). CSS rows: `.geohash-info-item` margin 5px / padding 5px / 1px
  bottom border (`styles-components.css:1831-1839`). Panel `top:20 right:20 max-width:300
  padding:16 padding-right:36` rgba(0,0,0,0.7) (1785-1798); on < 768px it becomes a fixed bottom
  bar `bottom:60 left:10 right:10` (`styles-themes-responsive.css:120-127`).
- Flutter: `geohash_explorer.dart:451-535` `_infoPanel` renders three rows:
  - **Location:** `decodeGeohash` center formatted as **DMS-ish** `"12.34°N, 56.78°W"`
    (lines 453-457, 492) — this is the `getGeohashLocation` string format from `channels.js:1256`,
    NOT the PWA panel's two separate Coordinates(decimal) + Location(city,country) rows.
  - **Recent messages:** `${ch.messages}` (493) — label text differs ("Recent messages" vs "Messages").
  - **Status:** `Joined`/`Not joined` (494) — a row the PWA does **not** have.
  - No **Coordinates** decimal row, no **Distance** row, no reverse-geocode, no `Loading location...`
    placeholder/async fill.
  Join button is always literally `JOIN CHANNEL` (509) — never switches to "Go to Channel" when joined.
- Gap: Users see a geohash-derived coordinate instead of a human city/country; no distance even
  with location enabled; no "joined" affordance on the button; an extra Status row the PWA lacks.
  This is the most content-divergent panel in the slice.
- Fix approach: rebuild `_infoPanel` to four rows matching the PWA: **Coordinates**
  `lat.toStringAsFixed(4), lng.toStringAsFixed(4)`; **Location** seeded "Loading location…" then
  filled from a reverse-geocode call (wire to the existing geocode service used elsewhere — check
  `channels.js fetchGeocode`; if no Flutter geocoder exists, gate this row but keep the label);
  **Distance** (only if `appState.userLocation != null`) `calculateDistance(...).toStringAsFixed(1) km away`
  (Haversine, `geohash-globe.js:1271`); **Messages** `${ch.messages}`. Drop the Status row. Make the
  Join button text conditional: `ch.isJoined ? 'Go to Channel' : 'Join Channel'`. Add the < 768px
  bottom-bar layout. Use decimal coords, not `getGeohashLocation` DMS.
- Effort: M  Risk: med  Confidence: high

### F6: Desktop hover affordances missing — no cursor change, no hover dot enlarge, no heatmap hover ring  [SEVERITY: medium]
- PWA: `geohash-globe.js:893-905,1006` — pointer move (when not dragging) calls `findChannelAt`,
  sets `hoveredChannel`, and sets the canvas cursor to `pointer` over a dot else `grab`
  (`grabbing` while dragging, 890,924). The hovered dot draws at `baseR+2` (806-807); in heatmap
  mode a 6px white ring is stroked over the hovered channel (787-796).
- Flutter: `geohash_explorer.dart` has no `MouseRegion`/`onHover` (grep: no matches in
  `lib/features/globe`). `_hoveredGeohash` is only ever set on **tap** (lines 128-131, 161), never
  on pointer hover. So on web/desktop there is no hover highlight, no enlarge, no heatmap ring on
  hover, and the cursor never changes (always default).
- Gap: On web/desktop the map feels dead on hover — no pointer cursor over dots, no dot grows,
  no heatmap white ring until you actually tap. PWA gives continuous hover feedback.
- Fix approach: wrap the `CustomPaint` in a `MouseRegion` (`cursor:` computed from a hit-test:
  `SystemMouseCursors.click` over a dot, else `grab`/`grabbing`) with `onHover` calling
  `_channelAt(event.localPosition,size)` and `setState(_hoveredGeohash = hit?.geohash)`. The
  painter already enlarges the hovered dot (276-293) and draws the heatmap ring (332-347), so
  only the hover *plumbing* is missing. Guard so touch taps don't fight it.
- Effort: M  Risk: low  Confidence: high

### F7: Legend "Your Location" row is missing  [SEVERITY: medium]
- PWA: `geohash-globe.js:236,283-288` — when `settings.sortByProximity && userLocation`
  (`showYourLocation`), the legend renders a **second** item: a warning-colored dot + `Your Location`.
  Dot CSS `.nm-geo-2 { background: var(--warning); }` (`no-inline.css:186`); the "Active" dot is
  `.nm-geo-1 { background: var(--primary); box-shadow: 0 0 5px var(--primary); }` (185).
- Flutter: `geohash_explorer.dart:384-414` `_legend` renders **only** the "Active" row (primary
  dot + "Active" + window group). No conditional "Your Location" row, and the Active dot has no
  `box-shadow:0 0 5px primary` glow (just a flat circle, lines 399-404).
- Gap: When proximity sort is on with a known location, the user-location marker (drawn yellow on
  the map, painter 451-465) is unexplained — the legend key is absent. Also the "Active" dot lacks
  the PWA's primary glow.
- Fix approach: in `_legend`, read `appState` for the proximity-sort flag + `userLocation`; when
  both set, append a second `Row` with a `nym.warning` dot + `Text('Your Location')`. Add a
  `BoxShadow(color: nym.primary, blurRadius: 5)` to the Active dot container to match `.nm-geo-1`.
- Effort: S  Risk: low  Confidence: high

### F8: Narrow-layout window `<select>` fallback is missing (button group never collapses)  [SEVERITY: medium]
- PWA: `geohash-globe.js:248-249,280-281` renders BOTH a `.geohash-window-group` (the 1h/3h/6h/
  12h/24h buttons) AND a `.geohash-window-select` dropdown. CSS shows the button group and hides
  the select by default (`.geohash-window-select{display:none}` `styles-components.css:1963-1964`);
  under 768px it **swaps** them: `.geohash-window-group{display:none}` +
  `.geohash-window-select{display:inline-block}` (`styles-themes-responsive.css:147-153`). So on a
  phone-width window the five buttons collapse into a compact dropdown.
- Flutter: `geohash_explorer.dart:416-431` `_windowGroup` **always** renders the five inline
  buttons; there is no `<select>`/`DropdownButton` fallback and no width breakpoint. On a narrow
  screen the five buttons + legend can overflow / crowd the bottom-right.
- Gap: On small screens the active-window control is cramped where the PWA shows a tidy dropdown.
- Fix approach: in `_legend`, branch on available width (e.g. `MediaQuery`/`LayoutBuilder`
  < 768): show the `_windowGroup` row above it, else a `DropdownButton<int>(items: kActiveWindowOptions)`
  styled per `.geohash-window-select` (rgba(255,255,255,0.05) bg, glassBorder, fontSize 11,
  padding 2/6). Both update `_activeWindowHours`.
- Effort: S  Risk: low  Confidence: high

### F9: Day/night terminator repaints every 30 s instead of 60 s (audit D2)  [SEVERITY: low]
- PWA: two timers — `ACTIVE_WINDOW_REFRESH_MS=30000` for activity (1020-1029) and a separate
  `DAYNIGHT_REFRESH_MS=60000` for the terminator (1031-1034).
- Flutter: `geohash_explorer.dart:71-73` a single `Timer.periodic(30s)` bumps `_ticker`, which is
  the painter's `repaint` Listenable — so both activity and day/night repaint at 30 s.
- Gap: Strictly *more* frequent (terminator updates twice as often as the PWA). No user-visible
  defect; documented as harmless in audit D2. Logged for completeness only.
- Fix approach: leave as-is, OR (for exactness) split into a 30 s activity tick + a 60 s day/night
  tick driving two notifiers. Not worth the extra state unless pixel-exact cadence is required.
- Effort: S  Risk: low  Confidence: high

### F10: Zoom-control glyph + spacing nits  [SEVERITY: low]
- PWA: `geohash-globe.js:262-264` zoom-in is `+`, zoom-out is `&minus;` (U+2212 MINUS SIGN),
  reset is `Reset View`; all three live in one top-left row `.geohash-controls-tl` (gap 10px,
  `styles-components.css:1872-1878`); zoom buttons are 34px wide, `padding:8px 0`, fontSize 16,
  weight 600 (1769-1776).
- Flutter: `geohash_explorer.dart:340-361` matches closely — `+`, `−` (U+2212, line 352 — good),
  `Reset View`, width 34, vertical pad 8, fontSize 16 weight 600 (537-573). This is essentially
  correct; the only nit is the control button base bg uses `Color(0xB3000000)` which matches
  `rgba(0,0,0,0.7)` and the active state matches. No real gap — included so the fix agent doesn't
  re-audit. **Likely no action needed.**
- Gap: none material (verified match).
- Fix approach: none.
- Effort: S  Risk: low  Confidence: high

### F11: Modal presentation differs (full-screen route vs centered scrim dialog)  [SEVERITY: low]
- PWA: `index.html:2185-2195` + `styles-components.css:1690-1751` — the explorer is a centered
  **overlay**: a fixed full-viewport scrim `rgba(0,0,0,0.4)` (1697) with a centered card
  `width:90% height:90% max 1200×800`, `border-radius:var(--radius-xl)`, `box-shadow: shadow-lg,
  shadow-glow` (1707-1720). The underlying app stays visible behind the scrim.
- Flutter: `geohash_explorer.dart:193-220` is a full-page `Scaffold` pushed via
  `MaterialPageRoute` (`chat_pane.dart:306`) with `backgroundColor: Color(0x66000000)` and a
  centered `FractionallySizedBox(0.95×0.95)` card (no `shadow-glow`). Because it's an opaque route,
  the app behind is **not** visible through the scrim, and there's no glow shadow.
- Gap: Subtle — the PWA dims-and-floats over the chat; Flutter is a full route transition with a
  slightly larger card (0.95 vs 0.90) and no glow. Minor visual/UX difference.
- Fix approach (optional): push with a transparent `PageRouteBuilder`
  (`opaque:false, barrierColor: Color(0x66000000)`) so the app shows through, set the card to
  0.90×0.90, and add the `--shadow-glow` equivalent (`BoxShadow(color: nym.primaryA(...),
  blurRadius:...)`) to the card decoration.
- Effort: S  Risk: low  Confidence: med

### F12: Reset View also force-resets the active window to 24h — verify parity  [SEVERITY: low]
- PWA: `geohash-globe.js:1057-1077` `resetView` resets cx/cy/zoom, clears hover, and turns OFF
  heatmap/daynight/grid (and their saved preferences). Separately `resetGlobeView` (1214-1221)
  also hides the info panel AND, if the window ≠ 24, calls `setGeohashActiveWindow(24)`. So a full
  reset returns the window selector to 24h.
- Flutter: `geohash_explorer.dart:166-176` `_resetView` resets view + heatmap/daynight/grid +
  selection AND sets `_activeWindowHours = 24` (174). This **matches** the combined PWA behavior.
- Gap: none — included to confirm parity (heat/day/grid OFF on reset + window→24 both present).
  **No action needed.**
- Fix approach: none.
- Effort: S  Risk: low  Confidence: high

---

## Incidental (logic-adjacent, not pure UI but affects what's drawn)

### I1: Flutter plots zero-activity geohash channels; PWA filters them out
- PWA: `channels.js:98` `if (recentCount < 1) return;` — a channel is added to `geohashChannels`
  **only** if it has ≥ 1 message within the active window. Empty channels are not plotted as dots.
- Flutter: `geohash_channel.dart:54-61` `buildGeohashChannels` does
  `counts.putIfAbsent(gh, () => 0)` for every registered geohash channel, so channels with **0**
  recent messages are still emitted and drawn as dots (and counted into heatmap `maxMsg`).
- Impact: Flutter shows dots for joined-but-silent channels that the PWA hides, and a 0-message
  channel can appear in the info panel. User-visible (extra dots) but rooted in the build function,
  not the painter. Fix: after tallying, drop entries with `count < 1` to mirror line 98 — but note
  this would also stop showing a user's joined-yet-quiet channels, so confirm intended behavior
  against the PWA (the PWA genuinely hides them).
- Confidence: high
