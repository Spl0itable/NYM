# Nymchat native-clone fidelity audit — summary

An 8-agent (Opus 4.8) line-level audit comparing the native Flutter app against
the Nymchat PWA source (`js/`, `css/`, `index.html`, `functions/api/`). Each
agent audited a disjoint slice, applied surgical fidelity fixes, and wrote a
findings table. Full suite **554 tests pass**, whole-project `flutter analyze`
clean.

| # | Slice | Discrepancies fixed | Report |
|---|---|---|---|
| 01 | Protocol / crypto / constants / models | 5 (+ ordering/edge) | `01-protocol-crypto-models.md` |
| 02 | Relay transport / network / API | 4 | `02-relay-network-api.md` |
| 03 | Messaging (channels/PMs/groups/reactions/polls) | 10 | `03-messaging.md` |
| 04 | UI shell / layout / themes / components | 20 | `04-ui-shell-themes.md` |
| 05 | Commands / autocomplete / formatting / interactions | 13 | `05-commands-format-interactions.md` |
| 06 | Lightning / shop / calls / P2P / notifications | 3 | `06-lightning-shop-calls-p2p.md` |
| 07 | Identity / vault / panic / settings / globe / Nymbot | 6 | `07-identity-settings-globe-nymbot.md` |
| 08 | iOS + Android platform readiness | ~15 platform | `08-ios-android-readiness.md` |

**~76 fidelity + platform corrections total.** Highlights:

- **Protocol**: `_ms` ordering used a 0–999 offset instead of the full epoch-ms
  timestamp (real bug); added kinds 15/1984/24242; `expiration` skips 0.
- **Relay**: geohash sends now route via `GEO_EVENT`, all gift wraps via
  `DM_EVENT`, `POOL:RELAY_BAN` permanently blacklists; host confirmed canonical.
- **Messaging**: `#nymchat` pin/hide no-ops; pinned band sorts by activity (not
  alpha); reaction `k`-tag + blocked-user filtering; closed-PM re-open; strict
  PM timestamp clamp; mod-log wall-clock ts.
- **UI**: 20 px/hex corrections — PM items used `--purple` not `--primary`;
  sidebar header structure; chat-header padding `16/24`; ghost text-dim
  `#cccccc`; channel-item badges/glows.
- **Commands/format**: shortcode regex; builtin-emoji-first ordering; fast-path
  block; autocomplete trigger boundaries + precedence; context menu gained
  Slap/Hug/Create-Group/Gift/Edit-Profile; delivery ticks (single-green ✓ /
  blue ✓✓).
- **Lightning/shop**: "Everything Pack" now resolves to 45 components;
  group-call roster validation; shop Gift/Transfer UI.
- **Identity**: biometric secret now `Random.secure()` (was time-derived);
  panic encrypt-with-discarded-key pass + correct step order; Nymbot
  `?changelog` added, phantom `?roll` removed; per-pubkey blur key.

## iOS + Android verdict: **both will build & run**

- **Android**: fixed the leftover template package (`com.example.counter` /
  `com.mycompany.CounterApp` → `com.nym.bar`), added ~12 permissions
  (audio/notifications/biometric/foreground-service/media/Bluetooth),
  `usesCleartextTraffic=false`, deep-link hosts. Dart compiles + all plugins
  register; a full APK build couldn't run only because the sandbox lacks the
  Android SDK (`dl.google.com` blocked) — environmental, not a code issue.
- **iOS**: wired `CODE_SIGN_ENTITLEMENTS` (was never set), bumped deployment
  target `12.0 → 15.0` for flutter_webrtc, added Face ID / photo-add /
  encryption-exempt / background-modes (audio/voip/push) usage keys.

### Remaining manual (non-repo) steps
1. iOS `DEVELOPMENT_TEAM` + enable Associated Domains/Keychain in Xcode.
2. Host `.well-known/{assetlinks.json,apple-app-site-association}` at the live
   hosts; insert the real signing-cert SHA-256.
3. Android release keystore via `key.properties`.
4. FCM is a guarded no-op by design; add `firebase_*` plugins + config to enable.

### Notable deferrals (documented per-report, with fix recipes)
Globe heatmap per-pixel palette remap (needs async `ui.Image`), WebTorrent
native client (WebRTC-chunk fallback), settings D1 hashed-category scheme
(native↔native sync works; cross-client read differs), and a few
animated cosmetic effects.
</content>
