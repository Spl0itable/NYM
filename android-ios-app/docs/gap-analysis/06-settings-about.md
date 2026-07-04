# Gap report 06 — Settings screen (all sections) + About screen

Slice: `lib/features/settings/{settings_screen,settings_widgets,about_screen}.dart`
cross-ref `lib/state/settings_provider.dart`, `lib/models/settings.dart`,
`lib/state/app_state.dart`. PWA source of truth:
`scratchpad/pwa/index.html` (settings modal 1350–2016, about modal 2118–2182),
`js/modules/settings.js`, `js/app.js`, `js/modules/users.js`,
`css/styles-components.css`.

## Summary
The six settings sections, their dropdowns, option lists, defaults and labels are
**byte-faithful** to the PWA (verified line-by-line; the prior audit's claim holds).
The gaps are **interactive/data completeness**, not layout: a large cluster of
controls is wired to no-op `TODO` stubs even though the backing state already exists
in `appStateProvider`. The most severe are the **populated** Friends / Blocked Users /
Blocked Keywords / Hidden Channels / Blocked Channels lists (data exists, UI shows a
hardcoded empty box — entries are invisible and unremovable), the **non-functional
SAVE button**, and the **wrong About version** (`v1.0.0` vs PWA `v3.72.517`). Several
controls (Add Keyword, Quick React emoji, Transfer Send, Clear Cache, Reset Settings,
Default Landing Channel, About → Send Message, all external links) do nothing.

**Finding count: 18** (1 blocker, 7 high, 7 medium, 3 low).

The prior audit (`docs/audit/07-*.md`) listed these as "intentionally stubbed / out of
scope." For a UI/UX fidelity pass they are in scope and are the bulk of the user-visible
breakage; each is detailed below with the exact PWA behavior to reproduce.

---

### F1: Friends / Blocked Users / Blocked Keywords / Hidden Channels / Blocked Channels lists never render their contents  [SEVERITY: blocker]
- PWA: index.html:1667-1685 (keyword/friends/blocked), 1874-1886 (hidden/blocked channels); renderers `users.js:180 updateKeywordList`, `users.js:2005 updateFriendsList` (+ `loadFriendsListAsync` 2021), and the parallel blocked-users/hidden/blocked-channels renderers. When the backing Set is non-empty each renders one `.keyword-item`/`.blocked-item` row per entry, each with a **Remove**/**Unblock** button (`removeBlockedKeyword`/`removeFriendByPubkey`/etc.); friends/blocked fetch metadata and show `Loading...` then the nym. Empty → the dim placeholder only.
- Flutter: settings_screen.dart:641 (`_emptyListBox('No blocked keywords')`), 650, 654, 804, 808 — **all five list boxes are hardcoded to the empty-state string**. They never read state.
- Gap: `appStateProvider` ALREADY holds live `friends`, `blockedUsers`, `blockedKeywords`, `hiddenChannels`, `blockedChannels` Sets (app_state.dart:166-183, with `isFriend`/`isUserBlocked`/keyword-match logic). A user who has blocked someone or added a keyword sees an empty box in Settings and **cannot view or remove any entry**. This is the single biggest user-visible regression in the slice.
- Fix approach: replace each `_emptyListBox(...)` with a `Consumer`/`ref.watch(appStateProvider)` that maps the relevant Set to rows. Each row: a `Text` (nym/keyword/geohash) + a trailing "Remove" `NymOutlineButton(danger: false)`. Wire removal to the app-state notifier's remove method (already exists per app_state.dart add/remove). Keyword rows show the raw lowercase keyword; friend/blocked rows should resolve a display nym (fall back to abbreviated pubkey). Keep the dim placeholder only when the Set is empty.
- Effort: M  Risk: low  Confidence: high

### F2: About version is wrong (`v1.0.0` vs `v3.72.517`)  [SEVERITY: high]
- PWA: app.js:4229 `const NYMCHAT_VERSION = 'v3.72.517';` rendered into `#aboutVersion` (index.html:2121) by `showAbout` (app.js:4363-4364).
- Flutter: about_screen.dart:13 `const String kAboutVersion = 'v1.0.0';` rendered in the header (line 176).
- Gap: the About header shows a fake placeholder version. User-visible and wrong on first open.
- Fix approach: set `kAboutVersion = 'v3.72.517'` to match the current PWA constant (or wire to the native build version once available; at minimum stop showing `v1.0.0`). Note the PWA uses `v3.x` semantic-ish build numbers, not `v1.0.0`.
- Effort: S  Risk: low  Confidence: high

### F3: SAVE button is a no-op that closes the modal without confirmation  [SEVERITY: high]
- PWA: index.html:2013 `data-action="saveSettings"` → app.js:3719 `saveSettings()`. It reads every control fresh from the DOM, commits theme/sound/color-mode/blur/acceptPMs/acceptCalls/DM-fwd-sec+TTL/receipts/typing/status/translation/gestures/swipe/threshold/cachePMs/keypair-mode/hide-non-pinned/pinned-landing-channel/proximity(with geolocation prompt)/text-size/groupChat-PM-only/low-data, then `nym.displaySystemMessage('Settings saved')` (line 3992) and `closeModal` (3997).
- Flutter: settings_screen.dart:261-282 the SAVE button's `onTap` is `Navigator.of(context).maybePop()` only.
- Gap: Flutter's controls write-on-change (so most values persist regardless), but: (a) there is **no "Settings saved" confirmation** — the button looks like it does nothing; (b) any control that is NOT write-on-change is silently dropped on SAVE (see F8 landing channel, F13 proximity-on-save geolocation). User taps SAVE expecting a commit + feedback and gets neither.
- Fix approach: on SAVE, show a SnackBar/system message equivalent to "Settings saved", then pop. Ensure every visible control has a committed setter (most do). If keeping write-on-change, at minimum add the confirmation toast so SAVE has an observable effect.
- Effort: S  Risk: low  Confidence: high

### F4: "Add Keyword" button does nothing (clears input only)  [SEVERITY: high]
- PWA: index.html:1666 `data-action="addBlockedKeyword"` → users.js:121 `addBlockedKeyword()`: trims+lowercases input, `blockedKeywords.add`, `saveBlockedKeywords()` (writes `nym_blocked_keywords`), `updateKeywordList()` (renders the new row), clears input, hides matching messages, `displaySystemMessage('Blocked keyword: "x"')`, `nostrSettingsSave()`.
- Flutter: settings_screen.dart:632-638 `onPressed` only calls `_keywordController.clear()` with a `TODO(verify)` comment.
- Gap: typing a keyword and pressing Add appears to do nothing (input clears, nothing is stored, no row appears, no toast). Filtering never updates.
- Fix approach: wire to an app-state method that adds the trimmed/lowercased keyword to `blockedKeywords`, persists `StorageKeys.blockedKeywords`, and triggers F1's list re-render. Show a confirmation. (Message re-filtering is the messaging subsystem's concern but the persistence+list update belongs here.)
- Effort: S  Risk: low  Confidence: high

### F5: Quick React emoji "Change" button does nothing  [SEVERITY: high]
- PWA: index.html:1937 `#swipeReactEmojiBtn` → app.js:3294 `openSwipeReactEmojiPicker` calls `nym.showEnhancedReactionPicker(...)`; on pick it sets `nym.settings.swipeReactEmoji`, writes `nym_swipe_react_emoji`, and live-updates the preview (app.js:3296-3301). Default `❤️`.
- Flutter: settings_screen.dart:876-886 button label `'${s.swipeReactEmoji}   Change'` but `onPressed` is an empty `TODO(verify)`.
- Gap: user cannot change the swipe quick-react emoji; the picker never opens.
- Fix approach: open the app's emoji/reaction picker (an emoji subsystem exists — `js/modules/emoji.js` analogue); on selection call `ctrl.setSwipeReactEmoji(emoji)` (setter already exists, settings_provider.dart:273) which persists and updates the label.
- Effort: M  Risk: med  Confidence: high

### F6: Geohash-only Channels rows stay visible in "Group Chats & PMs Only Mode"  [SEVERITY: high]
- PWA: index.html marks Proximity (1844), Default Landing Channel (1853), Hide Non-Favorited (1865), Hidden Channels (1874), Blocked Channels (1881) with `data-geohash-setting`. app.js:3598-3607: when `groupChatPMOnlyMode` is on these rows are `display:none`, and the `groupChatPMOnlySelect.onchange` toggles them live.
- Flutter: settings_screen.dart:770-809 renders all five rows unconditionally; `_channels` has no dependence on `s.groupChatPMOnlyMode`.
- Gap: enabling "Group Chats & PMs Only" should collapse the geohash-specific settings (they're irrelevant in that mode). Flutter keeps showing them, so the UI contradicts the chosen mode.
- Fix approach: in `_channels`, wrap those five `FormGroup`s in `if (!s.groupChatPMOnlyMode)`. The first row (the mode dropdown itself) stays. Rebuild already happens on `setGroupChatPMOnlyMode` (it's a synced setter updating state).
- Effort: S  Risk: low  Confidence: high

### F7: App cache size readout is permanently stuck on "Calculating…"  [SEVERITY: high]
- PWA: index.html:1992 `#appCacheSizeDisplay`; on settings open app.js:3625 `refreshAppCacheSize()` (app.js:3681) replaces it with e.g. `"1.2 MB cached on device — 3 channels, 2 PM/group threads, 5 profiles, 1 reaction record"`, or `"No cached data on device yet"`, or `"IndexedDB unavailable (...) — cache disabled"`.
- Flutter: settings_screen.dart:961-964 hardcodes the text `'Calculating…'` and never updates it.
- Gap: the Data & Backup section always shows "Calculating…" indefinitely — looks broken/hung.
- Fix approach: compute an on-device cache size (count of cached channels/PMs/profiles/reactions + byte estimate from the storage layer) and render the same breakdown string, or at least an honest "No cached data on device yet" once computed. Falls back gracefully if the cache store isn't wired.
- Effort: M  Risk: med  Confidence: med

### F8: "Default Landing Channel" is a bare, non-functional text field (no autocomplete, no value, not saved)  [SEVERITY: medium]
- PWA: index.html:1853-1863 — a searchable autocomplete: `#pinnedLandingChannelSearch` text input + hidden `#pinnedLandingChannelValue` + `#pinnedLandingChannelDropdown`. app.js:3350-3389 builds grouped options ("Common Geohash Channels" / "Joined Geohash Channels") with location labels, seeds the current selection, filters as you type; SAVE (app.js:3899-3914) persists `nym_pinned_landing_channel` as JSON (default `{type:'geohash',geohash:'nymchat'}`).
- Flutter: settings_screen.dart:782-788 — a plain `FormInput` with hint "Type to search or select a channel...", no controller, no dropdown, no current value, no persistence.
- Gap: the input shows no current landing channel, produces no suggestions, and nothing is saved — the feature is inert.
- Fix approach: build an autocomplete (`Autocomplete`/overlay) over the geohash channel list from app-state, show the current `pinnedLandingChannel`, and persist the selection to `nym_pinned_landing_channel` on change/SAVE. Storage key likely needs adding to `storage_keys.dart`.
- Effort: M  Risk: med  Confidence: high

### F9: "Transfer Settings → Send" is a no-op with no validation/error feedback  [SEVERITY: medium]
- PWA: index.html:1977 `data-action="executeSettingsTransfer"` → shop.js:1767. Validates pubkey is 64-hex (else shows `#settingsTransferError` "Invalid pubkey. Must be 64 hex characters."), rejects self-transfer, requires login, then sends a kind-30078 gift-wrapped settings payload. Error element index.html:1979.
- Flutter: settings_screen.dart:940-947 — Send button `onPressed` is an empty `TODO(verify)`; the error `<div>` has no counterpart.
- Gap: pressing Send does nothing and gives no feedback even for an obviously invalid pubkey. At minimum the client-side validation + inline error UI is missing.
- Fix approach: even if the networked send stays deferred, wire the input validation (64-hex regex, self-check) and render an inline error string below the field on failure, mirroring the PWA messages. Add an error `Text` slot.
- Effort: M  Risk: med  Confidence: high

### F10: "Clear Local Storage Cache" button does nothing (no confirm, no action, no toast)  [SEVERITY: medium]
- PWA: index.html:1995 `data-action="clearLocalStorageCache"` → app.js:4001. Shows a danger confirm dialog ("Clear cached channel history, PMs, group chats, profiles, and reactions? ..."), wipes the IndexedDB cache + in-memory maps, re-renders, `displaySystemMessage('Local storage cache cleared. ...')`, closes modal.
- Flutter: settings_screen.dart:967-974 `onPressed` is an empty `TODO(verify)`.
- Gap: the button is dead; no confirm, no clear, no feedback.
- Fix approach: show a danger confirm dialog with the PWA copy, clear the on-device cache stores, show a confirmation, and pop. Coordinate the actual cache-store wipe with the storage owner, but the button must at least confirm + act + toast.
- Effort: M  Risk: med  Confidence: med

### F11: "Reset Settings to Defaults" button does nothing  [SEVERITY: medium]
- PWA: index.html:2002 `data-action="resetSettings"` → app.js:4040. Danger confirm, then removes the exact `SETTINGS_KEY_EXACT` set (app.js:4048-4073) + `nym_image_blur_*` prefix keys, resets in-memory Sets (pinned/hidden/blocked/keywords), reloads defaults, re-applies color-mode/wallpaper('none')/layout('bubbles'), `displaySystemMessage('Settings reset to defaults. ...')`, closes.
- Flutter: settings_screen.dart:986-991 `onPressed` is an empty `TODO(verify)`.
- Gap: reset is dead; the user cannot restore defaults.
- Fix approach: show the danger confirm with PWA copy, clear the listed `nym_*` keys from the KeyValueStore (and `nym_image_blur_*`), rebuild `Settings.fromStore`, reset the app-state moderation Sets, and toast. The exact key list is enumerated at app.js:4048-4074 — reuse it.
- Effort: M  Risk: med  Confidence: high

### F12: About → "Send Message" is a no-op; no status text; topic/message not delivered  [SEVERITY: medium]
- PWA: index.html:2179 `data-action="sendAboutContact"` → app.js:4406. Validates non-empty message + relay connection (else writes `#aboutContactStatus` in danger color: "Please enter a message." / "Not connected to relay..."), builds `"[Nymchat contact — <topic>]\n\n<text>"`, sends an encrypted PM to `nym.verifiedDeveloper.pubkey`, sets button to "Sending..." then status "Message sent. Thanks for reaching out!" and clears the field.
- Flutter: about_screen.dart:352-356 the SEND MESSAGE button `onTap` is an empty `TODO(verify)`; there is **no status/error text element** (the PWA's `#aboutContactStatus`, index.html:2175, is omitted).
- Gap: the contact form looks functional (topic dropdown + message box + counter) but submitting does nothing and gives no feedback. Even the empty-message validation is missing.
- Fix approach: add a status `Text` slot below the message box. On send: validate non-empty (show the PWA error copy), then deliver the encrypted PM to the developer pubkey (networked — coordinate with messaging owner), updating the button label and status text per the PWA states.
- Effort: M  Risk: med  Confidence: high

### F13: Proximity toggle doesn't trigger the location-permission prompt the PWA shows  [SEVERITY: medium]
- PWA: in `saveSettings` (app.js:3916-3953) enabling "Sort by Proximity" calls `navigator.geolocation.getCurrentPosition`, and on grant/deny shows a system message ("Location access granted/denied...") and re-sorts; on deny it flips the select back to Disabled.
- Flutter: settings_provider.dart:234-238 `setSortByProximity` only writes `nym_sort_proximity` and updates state — no geolocation request, no grant/deny feedback, no revert-on-deny.
- Gap: user enables proximity sorting and nothing visibly happens (no permission prompt, no confirmation, and the toggle stays on even if location is unavailable).
- Fix approach: on enabling proximity, request location permission via the platform geolocation plugin; on grant show a confirmation and let the channel-sort use it; on deny show a message and reset the dropdown to Disabled (and persist false). Coordinate the actual re-sort with the channels feature.
- Effort: M  Risk: med  Confidence: med

### F14: External links (About build/canary/GitHub/ToS/PP/DMCA + inline Nostr/Bitchat) do nothing  [SEVERITY: medium]
- PWA: every `<a target="_blank">` in the about modal opens the URL — build `source`/`Build provenance`/`How to verify` (index.html:2129-2135), `canary` (2144), `GitHub`/`Terms of Service`/`Privacy Policy`/`DMCA` (2153-2156), inline `Nostr`/`Bitchat` (2151).
- Flutter: about_screen.dart:382-394 `_link` `onTap` is `/* TODO(verify): external link handling */` (empty); 396-405 `_linkSpan` likewise empty. So **all** About links are dead.
- Gap: none of the source/provenance/canary/legal/credit links are tappable — the entire link surface of the About screen is inert.
- Fix approach: use `url_launcher` to open the absolute URLs; map the two relative `static/*.html` (ToS/PP/DMCA, about_screen.dart:301-303) to their hosted equivalents (the PWA serves them relative to its origin — pick the canonical `web.nymchat.app/static/*` or repo URLs).
- Effort: S  Risk: low  Confidence: high

### F15: About build-integrity & warrant-canary panels are static "—" placeholders  [SEVERITY: low]
- PWA: index.html:2123-2150. On open, `runBuildVerification` (app.js:4233) sets `#aboutBuildStatus` to "Verifying…" then one of ✓ Verified (n/total) / ✗ Mismatch / ✗ Unofficial build / ⚠ Provenance unreachable / "Unavailable offline", plus a commit link + `#bundleHash`. `runCanaryCheck` (app.js:4288) sets `#aboutCanaryStatus` to ✓ All clear / ✗ Signature invalid / ⚠ Canary removed / ✗ Update overdue, with note/date/sig/nostr-event/btc-anchor. Status colors: `.ok #3fb950`, `.bad #f85149`, `.stale/warning #d29922`, `.checking text-dim` (styles-components.css:386-472).
- Flutter: about_screen.dart:226, 263 both status values are a hardcoded `'—'` in `c.textDim`; no commit hash, sig, date, nostr-event or btc-anchor rows.
- Gap: the trust panels look present but never report anything. Lower priority (the underlying verification is web-bundle-/attestation-specific and largely N/A on a native build), but a user opening About sees perpetual "—".
- Fix approach: at minimum show an honest static state for native (e.g. "Verified release" / link out) rather than "—"; full provenance/canary verification is its own feature. Also note the panel titles use `c.text` in Flutter (about_screen.dart:223,261) but the PWA `.about-build-title`/`.about-canary-title` are `--text-dim` (styles-components.css:378,434) — minor color mismatch.
- Effort: M  Risk: low  Confidence: med

### F16: Swipe sub-settings (Left/Right/Emoji/Sensitivity) don't hide when gestures are disabled  [SEVERITY: low]
- PWA: app.js:3305-3308 `updateSwipeSubsettings()` hides `#swipeLeftActionGroup`, `#swipeRightActionGroup`, `#swipeReactEmojiGroup`, `#swipeThresholdGroup` when `gesturesEnabledSelect.value !== 'true'`, and re-runs on change.
- Flutter: settings_screen.dart:854-902 renders all four sub-controls unconditionally regardless of `s.gesturesEnabled`.
- Gap: with swipe gestures Disabled, the four now-irrelevant sub-settings stay visible (minor clutter / inconsistency vs PWA).
- Fix approach: in `_mobile`, gate the four sub-`FormGroup`s behind `if (s.gesturesEnabled)`. Rebuild fires via `setGesturesEnabled`.
- Effort: S  Risk: low  Confidence: high

### F17: "Pending Settings Transfers" list is a static empty box (never renders incoming transfers)  [SEVERITY: low]
- PWA: index.html:1986 `#pendingSettingsTransfers`; populated by `nym.renderPendingSettingsTransfers()` on settings open (app.js:3622) — when an inbound settings-transfer offer exists it renders accept/decline rows.
- Flutter: settings_screen.dart:950-953 hardcodes `_emptyListBox('No pending transfers')`; no render path.
- Gap: an incoming settings transfer would never appear in the Flutter settings UI (cannot accept/decline). Niche, but the row is non-functional.
- Fix approach: read pending-transfer state (if surfaced by the sync subsystem) and render accept/decline rows; otherwise keep the empty box but flag the data source as missing. Lower priority than F1.
- Effort: M  Risk: med  Confidence: low

### F18: Identity Encryption launcher button does nothing  [SEVERITY: low]
- PWA: index.html:1534 `#vaultSettingsBtn data-action="openVaultSettings"` opens the vault settings modal (encrypt nsec with password/PIN/passkey/biometric).
- Flutter: settings_screen.dart:424-430 the `NymOutlineButton` `onPressed` is an empty `TODO(verify)` (deferred to the identity feature).
- Gap: the "Encrypt identity (nsec) key on this device…" button is inert from Settings. The vault UI exists elsewhere in the port (`vault_settings_modal.dart`, per audit 07) but is not reachable from this button.
- Fix approach: wire `onPressed` to open the existing vault-settings modal (`VaultSettingsModal`/equivalent). Likely a one-line navigation hook since the modal already exists.
- Effort: S  Risk: low  Confidence: med

---

## Verified correct (no finding — for the fix agent's confidence)
- **Section inventory & order**: Appearance, Privacy & Security, Messaging & Display, Channels, Mobile Gestures, Data & Backup — all present in PWA order with matching titles (settings_screen.dart:76-122 vs index.html section keys).
- **Every dropdown's option set + default matches `settings.js`**, verified value-for-value:
  - Theme 6 (index.html:1378-1383), color-mode 3 (default `auto`, 1369), wallpaper 9 incl. Upload (1421-1471; default `geometric` per users.js:911 — the markup's static `none` selected is corrected on init, so Flutter's `geometric` default is right), layout bubbles/irc (1481-1496), transparency Solid/Glass (1504-1505).
  - Keypair mode persistent/random/hardcore (default `persistent`, 1541-1543) + hardcore warning text (1546). PoW 0/8/12/16/20/24 (default 0, 1552-1557). Accept PMs / Accept Calls enabled/friends/disabled (1565-1577) + calls WebRTC IP warning (1580). DM forward secrecy + TTL 3600/21600/86400/259200/604800 (default 86400, 1598-1602). Read-receipts & typing scopes everywhere/pms-groups/pms/groups/disabled (1610-1627). Show-status true/friends/false (1635-1637). Cache PMs true/false (1645-1646). Blur images true/friends/false (1654-1656).
  - Translation: 47 entries incl. empty=Disabled, exact order (1698-1744). Sounds: 19 incl. legacy `icq→uhoh`/`msn→msnding` migration (1752-1770; settings.dart:196-197). Autoscroll, timestamps, time-format (default 12hr), date-format (default `default`), nick-style fancy/simple — all match (1776-1814).
  - Channels: group-PM-only, proximity, hide-non-pinned, hidden/blocked channels (1837-1886). Mobile: gestures, swipe-left (leads `quote`), swipe-right (leads `translate`), emoji, sensitivity 40/60/80/100 (1898-1951). Data: low-data, transfer, pending, cache, reset (1965-2005).
  - About contact topics: General feedback/Bug report/Feature request/Question/Spam false positive (index.html:2164-2168 vs about_screen.dart:116-129) + message maxlength 2000 (2173 vs about_screen.dart:311).
- **Text-size slider** range 12–28 default 15 (index.html:1514) matches (settings_provider.dart:76, settings.dart:222). Reset-to-15 present.
- **`.form-warning` styling** danger@0.08 bg / danger@0.4 border / radius 6 / 11px (styles-components.css:263-272) matches settings_widgets.dart:130-144.
- **Reset-columns button** (audit 07 fix #7) present and correctly gated on column view (settings_screen.dart:332-339).
- **`#autoEphemeralSettingGroup`** (index.html:1818) is `nm-hidden` by default — correctly omitted from Flutter (settings_screen.dart:743-745).

## Incidental (non-UI, noted in passing)
- The device-local-only setters (`setKeypairMode`, `setPowDifficulty`, `setBlurImages`, `setHideNonPinned`) intentionally do NOT fire `_syncedChanged()` (settings_provider.dart:28-30, 136-245), matching the PWA's "not synced" semantics. Not a gap; flagged so the fix agent doesn't "fix" it.
- `setShowStatus`/`setAcceptCalls`/`setCachePMs` etc. persist on-change in Flutter, so most SAVE-button work (F3) is already durable; the SAVE gap is the missing confirmation + the few non-write-on-change controls (F8 landing channel, F13 proximity prompt, cache-PMs-off wipe at app.js:3857).
