# PWA→Flutter parity — re-audit + remaining work

A fresh line-by-line re-audit of the Flutter app against the **live PWA source**
(`Spl0itable/NYM` `js/`, `css/`, `index.html`) was run across all 10 slices plus a
dedicated settings, Nymbot-chat, stub, and CSS sweep. The port was high-fidelity
but **not** 1:1; this pass then implemented the great majority of the verified
gaps, slice by slice. Each change below was confirmed against BOTH sides and ships
with `flutter analyze` clean + the full **675-test** suite green.

## Implemented in the slice-by-slice pass

- **Nymbot chat** flows through the canonical message bubble (MessageContent
  formatting, fills, 16+4 tail, avatar + blue ✓ name line, in-bubble timestamp,
  grouping).
- **Slash commands** (`/poll /zap /pm /group /addmember /invite /groupinfo /kick
  /ban /addmod /removemod /transferowner`) un-stubbed — the composer now passes
  the modal hooks; `/poll` reaches the (previously unreachable) editor.
- **Settings**: PoW difficulty wired into the send path; Cache-PMs disable wipes
  cached rows; **custom wallpaper upload** (image picker → app-dir file → render);
  **Low Data Mode** is the `.nym-switch` iOS toggle (promoted to a shared widget).
- **Chat**: custom-emoji-only enlarge; inline-`code` pill; **tap-to-zoom fullscreen
  image viewer** with gallery paging; tappable full-timestamp popup; **read-more
  height truncation**; IRC `(edited)` hoisted to full-row width; **tappable
  `@mention` → user context menu**.
- **Shop**: owned→GIFT (not ACTIVATE); limited footer label-only; bundle gifting +
  no spurious "Owned" chip; empty section-title guards; IRC-layout aura ring+glow;
  redacted author white@0.8; per-card descriptions on every tab.
- **Composer**: inert until relays connect; `:` custom-emoji recents render as
  images (no `::code::`); `?`-bot PM subcommand palette; reactive ANON
  eligibility; mention dev/bot tooltip.
- **Calls/P2P**: live transfer %/speed; block-in-call (1:1 end / group drop + grid
  filter + chat hide); in-call chat shop cosmetics.
- **Zaps**: instant self-zap badge (dedup-safe); poll-voter choices + tap-to-PM;
  **live ⚡ zap-burst** when a total ticks up.
- **Context menu / setup**: profile-only Edit Profile (self); invite-banner group
  name; corrected misleading "stub/TODO" comments on already-wired features
  (NIP-56 report publish, gift-credits observer, custom-emoji live stream).
- **Notifications**: channel/geohash @-mentions route to the channel
  (switchChannel), not the sender's PM.
- **Globe**: D1-discovered activity feeds the heatmap (presence floor — the native
  store folds D1 hourly buckets into a single last-seen ms, so an exact per-bucket
  count is unavailable); seed geohashes are candidates; refetch on explorer open +
  30s tick; isJoined unions favorites.
- **Shell**: **columns mode keeps the chat header + composer** (deck substitutes
  only the messages-list region; focusing a column re-targets the shared
  composer); remove-column confirm + "don't ask again"; add-column search; sidebar
  nyms "view more" steps by 500.

## Previously-deferred items — now ALL implemented

The hard/niche items that an earlier pass deferred have since been built in full
(each verified: analyze clean + the suite green; the suite grew to 706 tests):

- **Hardcore keypair mode**: `IdentityService.rotateEphemeral` + a post-send hook
  rotate the ephemeral identity + nym after every channel send (ephemeral only).
  `NostrService.rotateIdentity` swaps the key IN PLACE — the relay connections +
  subscriptions persist, exactly like the PWA's `generateKeypair` (no per-message
  reconnect).
- **Private + public zap announce**: `announceMessageZap` gift-wraps a kind-9735
  rumor to PM/group members and publishes a real signed kind-9735 for channels.
  Flutter's missing **public-receipt subsystem** was built too: a `#p:[self]`
  kind-9735 subscription + `_onPublicZapReceipt`, with verified = receipt pubkey
  == the recipient's LNURL provider pubkey, and own-published-id + bolt11 dedup.
- **Quick-zap LN resolve**: `resolveLightningAddressForZap` fetches the author's
  kind-0 when the address isn't cached (no more spurious "cannot receive zaps").
- **Unverified-zap tooltip**: `MessageZaps.unverified` + a `verified` flag on
  `recordMessageZap`; the badge appends `(N unverified)`.
- **Blockquote tap-to-jump**: built scroll-to-message infra
  (`scrollable_positioned_list` + a `flashedMessageProvider`); a top-level quote
  resolves its source by content and scrolls + flashes it.
- **Spam false-positive row**: ported the full `isSpamMessage` heuristic
  (`spam_filter.dart`, 29 tests) + incoming-hide + the own-message notice with a
  "Report false positive" button that opens the About contact form.
- The lone-long-blockquote read-more edge is also handled.

**Nothing is deferred.** The only items not ported are the platform-limited ones
below.

## Platform-limited (correct to stub — not gaps)
WebTorrent large-file seeding (native fallback to direct-WebRTC), WebAuthn-PRF
vault key (biometric device-secret stand-in), FCM push (the PWA has no push at
all), Nymbot/shop live-host settlement (real calls wired; host unreachable in dev).
