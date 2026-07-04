# Implementation status — UI/UX fidelity pass

> **Correction (re-audit):** the "nothing is deferred" claim below was overstated.
> A fresh line-by-line re-audit against the **live PWA source** found ~80 real,
> verified remaining gaps (settings that were saved-but-unread, slash-command
> modals that silently no-opped, the Nymbot chat using a divergent bubble, and
> more). See **`REMAINING-WORK.md`** for the current, accurate state and the
> prioritized to-do list. The notes below describe the earlier wave's intent, not a
> finished 1:1 port.

The earlier wave implemented a large share of the ~157 catalogued gaps; the whole
project passes `flutter analyze` with **0 errors / 0 warnings** and the test suite
(now **675 tests**) is green.

## Everything landed
Discovery (10 agents) → implementation in waves (Batch 1, Batch 2, integration,
completion wave, long-tail), each verified by `flutter analyze` + `flutter test`.

- **Cosmetics**: all auras (gold/neon/prism/phoenix/cosmic/hologram/frost) with true
  inset rings, all 16 textured-style SVG watermarks, glitch chromatic shadows,
  per-glyph glow, supporter gold, Genesis edition stamp + bold nym, redacted.
- **Chat**: `/me`/system pills, horizontal link previews, reader receipts, emoji-only
  enlarge, IRC `(edited)`, gallery geometry, blur-others-images, **flood-dim**,
  **inline video playback**, in-message **P2P file-offer card**.
- **Context menu**: full profile card, Report publish (NIP-56), quick-context-menu,
  action icons, dim, recents; **group context menu** (member roles + owner controls:
  edit name/description/avatar/banner, allow-invites, add members, leave) + back chevron.
- **Composer**: quote/edit chips, mention rows (avatar/status/verified/friend/**flair**),
  geohash location, emoji favorites, image+video upload, in-composer translate, popout.
- **Shell**: 1024 breakpoint + drawer, header pills + notif badge, whole-sidebar scroll,
  PM long-press menu, mobile toggles, sidebar globe/new-PM, section collapse+reorder
  persistence, **columns deck mobile carousel + desktop drag-reorder + tabs sheet + pager**.
- **Settings**: live Blocked/Friends/Keywords/Hidden lists, real cache readout+wipe, live
  reset revert, Add-Keyword/Clear-Cache/Reset, About version+links+**contact send**,
  PM-only row hiding, landing channel, proximity prompt, **outbound settings transfer (F9)**,
  **pending transfers list**, vault launcher.
- **Calls**: flying reactions, presenter menu, in-call chat reactions, status toasts →
  **notification-history panel**, @mention autocomplete, read receipts + typing, decorated
  nyms, video-grid breakpoints, switch-cam gating, transfer speed+retry, **missed-call
  entries**, incoming-call pulse.
- **Globe**: per-pixel heatmap palette, info panel, hover, legend, narrow select, **admin-1
  state borders + city dots/labels** (bundled `ne_50m_*` datasets, lazy-loaded), split
  30s/60s timers.
- **Onboarding/Nymbot/Zaps**: **tutorial spotlight + sidebar driver**, bot `?`-command
  palette + welcome bubble + **gift-credits modal/observer + ?gift/?transfer/?clear/?help**,
  zap "I've paid" verify + success pop.
- **Identity**: **encrypt-at-rest boot prompt**, nick-edit prefill, vault prompts.

## Notes
- Adds the `video_player` dependency (inline video).
- Bundles `ne_50m_admin_1_states_provinces_lakes.json` + `ne_50m_populated_places_simple.json`.
- Remaining `flutter analyze` output is info-level only (doc-comment `<>`, Flutter-3.44
  deprecations, unnecessary imports) — no errors or warnings; nothing functional.
- A full APK/IPA build still needs the Android SDK / macOS toolchain (unavailable here);
  `analyze` + `test` + `build web` all pass.
