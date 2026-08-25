# Changelog

All notable changes to Nymchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version corresponds to a tag on
[github.com/Spl0itable/NYM](https://github.com/Spl0itable/NYM/releases).

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
