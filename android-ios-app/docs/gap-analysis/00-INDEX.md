# UI/UX fidelity gap analysis — Nymchat PWA → Flutter

A 10-agent (Opus 4.8) line-by-line comparison of the Flutter app against the Nymchat
PWA source (`js/`, `css/`, `index.html`), focused on **user-visible UI/UX** gaps —
missing elements, half-baked features, visual mismatches, broken interactions. This
complements the earlier `docs/audit/` pass (which covered protocol/logic/platform).

**~157 findings** across 10 slices. Each report cites exact PWA line numbers + px/hex
values and a concrete Flutter fix approach, ordered by severity.

| # | Slice | Findings | Headline gaps |
|---|-------|----------|---------------|
| 01 | Shell / sidebar / columns | 24 | Columns deck skeletal (no PM/group cols, no DnD, no mobile carousel); no tablet breakpoint; desktop header icons-not-pills |
| 02 | Chat / messages | 16 | Reader avatars missing; link-preview card vertical not horizontal; `/me` renders raw; quote/edit chips inlined |
| 03 | Composer / autocomplete / emoji | 12 | Quote/edit preview chips; mention-row avatars/badges; image-only upload; in-composer translate |
| 04 | Context menu / profile | 14 | Profile card missing banner/status/bio/labels/badges; Report submit no-op; no quick-context-menu |
| 05 | Modals | 14 | Report submit dead; nick-edit blanks bio/lightning; new-PM missing group section |
| 06 | Settings / About | 18 | Blocked/Friends/Keywords lists hardcoded-empty (data exists); dead buttons; stale version/cache |
| 07 | Shop / cosmetics | 16 | Cosmetic auras/watermarks/editions never render on messages; no card preview/supply/bundle UI |
| 08 | Globe / geohash | 12 | Heatmap doesn't climb palette; missing map layers; info-panel content wrong |
| 09 | Calls / P2P / notifications | 18 | Flying reactions dead; no in-message file-offer card; no presenter menu; silent call toasts; no notif history |
| 10 | Onboarding / Nymbot / Zaps | 13 | Tutorial spotlight not drawn; bot command palette; zap "I've paid" button missing |

Implementation proceeds in ownership-partitioned waves (see commit history).
