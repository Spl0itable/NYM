# Changelog

All notable changes to Nymchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version corresponds to a tag on
[github.com/Spl0itable/NYM](https://github.com/Spl0itable/NYM/releases).

## [3.75.543] - 2026-08-26

### Added
- Nymbot works inside channel message threads. Opening a thread on one of its
  messages and replying there continues the conversation with no `?` prefix or
  `@Nymbot` mention needed, and Nymbot answers inside the thread instead of the
  flat channel. The whole thread is sent as its context, so a game started or
  continued in a thread (`?trivia`, `?wordle`, `?riddle`, `?anagram`) keeps its
  state. In a thread rooted on someone else's message, `?commands` and
  `@Nymbot` mentions still reach it and are answered in that thread; it only
  replies unprompted once it is already the thread's last speaker.
- Slack-style message threads across channels, PMs, and group chats. Tapping a
  message (or its "N replies" row under the reactions/zaps row) swaps the
  current view to the thread — the root message plus its replies — using the
  same composer, and the chat header's back/forward buttons navigate in and
  out of threads. Desktop hover actions gain a thread button beside quick
  react/translate, and the long-press menu gains "Reply in Thread". On by
  default; a new "Message Threads" setting (synced across devices) restores
  the classic flat view. Channel replies carry a NIP-10 marked
  `['e', rootId, '', 'root']` tag so other clients still see a normal channel
  message; PM/group replies carry `['nymthread', rootNymMessageId]` inside the
  encrypted rumor.

### Fixed
- Outgoing event signing (every send, read receipt, presence ping) now uses
  native libsecp256k1 when available — the CPU profile showed the pure-Dart
  path costing 10-20 ms of BigInt math ON THE UI THREAD per signature, which
  is scroll-time jank whenever receipts fire. The gift-wrap worker isolates
  load the native library too, so seal signing and seal verification inside
  PM processing take the fast path as well.
- The iOS scroll jank measured in the DevTools captures (a quarter to a third
  of ALL frames blowing the raster budget, spikes to 60–127 ms) traced to
  ~23 offscreen render passes (`Canvas::saveLayer`) per frame. The dominant
  source was SVG icon tinting: a srcIn colorFilter forces vector_graphics to
  saveLayer every icon, every frame, and 15–25 tinted icons are always on
  screen (header, composer toolbar, the per-row add-reaction pills, badges).
  Icons now tint via the SVG theme's `currentColor` — resolved at parse time,
  rendered identically, no offscreen pass. The add-reaction pill's and the
  composer translate button's resting `Opacity` dims are likewise folded
  directly into their colors.
- The fullscreen image viewer now opens media from the shared disk cache the
  inline tile already populated, instead of re-downloading it with a separate
  uncached fetch.
- The "Stay Connected in Background" descriptions (settings and the network
  stats modal) now say the mode uses more data as well as more battery.
- Opening a thread from another conversation no longer throws a
  "Cannot use ref after the widget was disposed" error storm: the post-frame
  callback captured the tapping row's ref, which the view switch itself could
  dispose before the frame ended. It now captures the provider notifier.
- The whole-app freezes during the first minutes after opening (scroll not
  responding, the sidebar stalling) are fixed at their two sources. The
  periodic cache flush serialized every dirty conversation, every known
  profile and every reaction tally to JSON on the UI thread every few seconds
  while the catch-up backfill kept marking stores dirty — that now happens in
  a worker isolate, writes only what actually changed, and the finished rows
  are committed as before in one transaction. And the live relay inflow,
  which rebuilt the visible message list for every arriving batch (many per
  second during catch-up), is paced to at most ~6 list updates per second —
  plus unchanged visible rows are now reused verbatim across those rebuilds
  instead of being rebuilt from scratch each time.
- Force-closing and reopening the app no longer visibly re-downloads and
  re-renders the whole message history (and no longer re-uploads already-
  archived PM wraps). Boot previously gave the local cache only 1.5 seconds
  before connecting to relays; a heavy account's hydration — decoding tens of
  thousands of cached messages, previously on the UI thread — lost that race,
  so the app came up empty and re-fetched everything. Cache decoding now runs
  in a worker isolate and the network waits for hydration to land.
- Link previews no longer fire an unfurl request for every link-bearing
  message the moment it scrolls into range — the card waits until it has been
  on screen ~300ms, so flinging through history stops causing a burst of
  network fetches and mid-scroll relayouts.
- Event signature verification now uses the native libsecp256k1 library
  (bundled per platform) instead of pure Dart — ~70 µs per event instead of
  ~12 ms (~150×) — with the pure-Dart implementation kept as an automatic
  fallback wherever the library is unavailable. Together with the persisted
  verification cache this removes the boot/resume CPU grind entirely, first
  run included.
- Animated GIFs and animated custom emoji now pause whenever they are off
  screen (scrolled away, behind another screen) instead of decoding frames
  forever, and resume exactly where they froze when scrolled back — a chat
  full of GIFs no longer keeps the CPU/GPU busy for as long as it is open.
- Opening the app on an account with lots of history no longer pegs the CPU
  for seconds while messages stream in. Signatures verified in past sessions
  are now remembered on disk, so the boot/resume relay replay of already-seen
  reactions, profiles, presence and history skips the ~12 ms-per-event
  signature math (a seeded replay measures ~460× faster in the benchmark), and
  verification batches now run one at a time instead of fanning out across
  every core.
- Images decode at the size they are shown instead of their full resolution:
  avatars, inline media tiles, link previews, GIF-picker cells, banners and
  composer thumbnails all cap their decode to the on-screen pixels, cutting
  the decode CPU, GPU texture uploads and image-cache churn that made
  media-heavy conversations stutter.
- The loading skeleton no longer rebuilds its entire placeholder tree on every
  animation frame — the shimmer is repaint-only now — and the wallpaper,
  ambient glow, typing dots and skeletons each render in their own layer, so a
  tiny animation can't force the full-screen background patterns to re-draw at
  60fps.
- Debug builds no longer collapse into a per-frame exception storm (and the
  heavy lag it caused on startup as messages load) whenever a conversation
  contains a custom `:shortcode:` emoji. The emoji's inline baseline-shift
  render object read its `size` while the surrounding paragraph was still
  laying out, which Flutter's debug asserts (before the framework's 3.41 fix,
  flutter/flutter#176906) treat as an error — the thrown assert aborted the
  paragraph's layout mid-flight and corrupted the whole message list into
  re-throwing every frame. The baseline is now computed from a height recorded
  during the render object's own layout pass, which is legal on every Flutter
  version.
- Tapping a quoted block inside an open thread now leaves the thread and jumps
  to the original message in the conversation, instead of silently doing
  nothing because the thread list never held it.
- The app dialog (including the post-quantum `nympq1…` recovery-code paste
  prompt) now lifts above the soft keyboard instead of hiding its input
  behind it, matching the other keyboard-aware modals.

## [3.74.542] - 2026-08-25

### Added
- Quantum-resistant messaging now works with browser-extension and remote-signer
  logins in both directions, not only when sending. Synced settings and archived
  history are covered too.
- A post-quantum recovery code (`nympq1...`) that a second device is linked with,
  shown beside the nsec in View or Edit Nym's Details.

### Changed
- The Nym details modal opens on your full public key, with the nickname below
  it, and explains that the `#` suffix is the last four characters of the key's
  hex spelling.
- The shield no longer claims full quantum resistance on a message that only got
  part of it.

### Fixed
- A manually translated message is no longer cleared when a new message arrives.
- The pop-out composer keeps its rounded corners, and the formatting toolbar is
  no longer hidden behind it.

## [3.74.535] - 2026-08-24

### Fixed
- Settings changes now stick. A save that failed for any reason was still
  recorded as done, so it was never retried and the change reverted the next
  time the app opened.
- A setting one app knows about and the other does not is no longer wiped when
  the other app saves the section it lives in.
- The app language and the auto-translate options are stored in the same place
  the web app stores them, instead of a second location the two kept
  overwriting.

## [3.74.534] - 2026-08-23

### Fixed
- The quantum-resistant badge now updates as soon as a message is sent or
  upgraded, instead of staying blank until the app was reopened.
- A message that arrived conventionally encrypted and was later delivered
  quantum-resistant now shows that straight away, matching how the sender
  verification mark already behaved.
- Your own settings, message archive and self-addressed copies are sealed to a
  key this device can always reopen. Another device on the same account could
  previously seal them to a key this one had never held, leaving them
  permanently unreadable.
- Key announcements are no longer re-fetched in bulk from relays on every
  reconnect; they are read from the archive, as everything else already was.

## [3.74.533] - 2026-08-23

### Fixed
- Post-quantum keys are now announced on a first connect, not only after a
  reconnect, so a newly signed-in account is discoverable straight away.
- The announcement no longer rides the tail of the archive restore, which
  could skip it for a whole session when that restore was throttled or failed.
- Peers' announced keys survive a relaunch, so the first message after a
  restart is post-quantum instead of falling back to classical while
  discovery re-runs.
- Key lookups check the archive before fanning out to relays, and wait past
  the first "nothing here" answer, both of which could leave a conversation
  classical between two capable clients.
- Your own sent message shows its quantum-resistant badge immediately, instead
  of staying unmarked until the app was restarted and the chat reopened.
- Group messages now report how many members received a quantum-resistant copy.
- The attachment preview no longer disappears when its upload finishes.
- Media translated on demand is no longer asked for a language you already
  chose when you first opened the app.

### Changed
- Attachments are now shown as tiles you can remove or retry individually, each
  with its own progress wheel, replacing the single upload bar that covered the
  previews and could not say which file it was waiting on. A failed upload keeps
  its file so one tap retries it, and the links are added to the message when
  you send rather than typed into the box as each upload lands.

## [3.73.533] - 2026-08-22

### Added
- WYSIWYG text editor for the message composer.
- Inline image and video previews in messages.

## [3.73.532] - 2026-08-21

### Fixed
- All commands now appear in the app's localized language.

## [3.73.531] - 2026-08-20

### Fixed
- Various bug fixes.

## [3.73.530] - 2026-08-20

### Added
- Bluetooth mesh in supporting browsers.

## [3.73.529] - 2026-08-20

### Fixed
- Sidebar bugs.

## [3.73.528] - 2026-08-19

### Fixed
- Multiple bug fixes.

## [3.73.527] - 2026-08-19

### Fixed
- Many bug fixes and performance improvements.

## [3.73.526] - 2026-08-19

### Fixed
- Performance improvements.

## [3.73.525] - 2026-08-19

### Fixed
- Bugs when leaving groups.
- Sidebar now shows channel locations.

## [3.73.524] - 2026-08-18

### Fixed
- Further bug fixes with Nymbot premium models.

## [3.73.523] - 2026-08-18

### Fixed
- Many bugs related to Nymbot premium models.

## [3.73.522] - 2026-08-17

### Changed
- Local message store is now an encrypted SQLite database.

## [3.73.521] - 2026-08-17

### Changed
- Refinements to the encrypted group chats implementation.

## [3.73.520] - 2026-08-14

### Fixed
- Missed inline script breaking CSP.
- Stale messages showing as new.

## [3.73.519] - 2026-07-11

### Added
- Localized translation of the entire app.
- Auto-translate messages into your preferred language.

[3.73.533]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.533
[3.73.532]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.532
[3.73.531]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.531
[3.73.530]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.530
[3.73.529]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.529
[3.73.528]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.528
[3.73.527]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.527
[3.73.526]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.526
[3.73.525]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.525
[3.73.524]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.524
[3.73.523]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.523
[3.73.522]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.522
[3.73.521]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.521
[3.73.520]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.520
[3.73.519]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.519
