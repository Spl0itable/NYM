// Per-pubkey flood detection for the active conversation, a faithful port of the
// PWA's `trackMessage` / `isFlooding` (`js/modules/messages.js:216-322`).
//
// The PWA mutates per-channel/per-pubkey tracking maps as each event is ingested
// (`trackMessage` at arrival, `Date.now()`). We can't hook message ingest from
// the UI slice (the state layer owns it), so instead we recompute an immutable
// snapshot from the in-state recent messages — replaying their arrival times in
// chronological order yields the same `blocked`/`blockedUntil` decisions.
//
// Two independent gates, mirroring the PWA exactly:
//   * Rate flood   — >10 messages inside a fixed 2 s window from one pubkey →
//                    block for 900000 ms (`trackMessage`). The window is anchored
//                    at the first message and reset once `now - first > 2000`.
//   * Content flood — the same normalised content (whitespace-collapsed, trimmed,
//                    lower-cased, length >= 6) seen >= 3 times within a 120000 ms
//                    sliding window → block for 900000 ms (`_trackContent` /
//                    `isContentFlooding`). Content is hashed with FNV-1a 32-bit.
//
// Own messages are never flooded (the caller skips `message.isOwn`), matching the
// PWA which only dims others' rows (`.message.flooded`, `styles-chat.css:61-63`).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';

/// Block duration once a pubkey trips either flood gate: 15 minutes
/// (`now + 900000`, `messages.js:243,289`).
const int kFloodBlockMs = 900000;

/// Rate-flood window: more than [kRateFloodMax] messages inside this window
/// (`now - firstMessageTime > 2000`, `messages.js:235,241`).
const int kRateFloodWindowMs = 2000;
const int kRateFloodMax = 10;

/// Content-flood: the same normalised content repeated this many times inside
/// [kContentFloodWindowMs] (`info.count >= 3`, `WINDOW = 120000`,
/// `messages.js:274,288`).
const int kContentFloodWindowMs = 120000;
const int kContentFloodRepeat = 3;
const int kContentFloodMinLen = 6;

/// FNV-1a 32-bit hash of [s] (`_hashContent`, `messages.js:253-261`). Walks UTF-16
/// code units (`charCodeAt`) and folds with the 32-bit FNV prime, returning an
/// unsigned 32-bit result.
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    // 32-bit FNV prime multiply with explicit 32-bit truncation (mirrors
    // JS `Math.imul(h, 0x01000193)` followed by the final `>>> 0`).
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0xffffffff;
}

/// Normalises message content the way `_trackContent` does (`messages.js:265`):
/// collapse all whitespace runs to a single space, trim, and lower-case.
String _normalizeContent(String content) =>
    content.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// An immutable snapshot of which pubkeys are currently flooding within one
/// conversation, derived from that conversation's in-state messages. Recomputed
/// whenever the underlying message list changes.
///
/// [isFlooding] mirrors `messages.js:302-322`: a pubkey is flooding while the
/// real wall clock is still before its computed `blockedUntil` for either gate.
class FloodTracker {
  const FloodTracker._(this._blockedUntil);

  /// pubkey → latest computed `blockedUntil` (ms since epoch). The max of the
  /// rate-flood and content-flood block expiries.
  final Map<String, int> _blockedUntil;

  /// An empty tracker (nobody flooding).
  static const FloodTracker empty = FloodTracker._({});

  /// True when [pubkey] is currently flood-blocked — i.e. it tripped a gate and
  /// the 15-minute block has not yet elapsed against the real clock. Mirrors the
  /// PWA's `Date.now() < blockedUntil` check (and its lazy expiry: once the block
  /// lapses the pubkey is no longer flooding).
  bool isFlooding(String pubkey) {
    final until = _blockedUntil[pubkey];
    if (until == null) return false;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  /// Replays [messages] (any order; sorted here by arrival) through the PWA's
  /// rate- and content-flood state machines, using each message's millisecond
  /// [Message.timestamp] as its arrival time (the analogue of the PWA's
  /// `Date.now()` at ingest). [selfPubkey] is exempt (own messages are never
  /// flooded). Historical messages are tracked the same as live ones here — the
  /// PWA skips `isHistorical`, so we honour [Message.isHistorical] too.
  factory FloodTracker.fromMessages(
    List<Message> messages, {
    required String selfPubkey,
  }) {
    if (messages.isEmpty) return empty;

    // Chronological replay order. `seq` is the monotonic arrival tiebreak.
    final ordered = [...messages]..sort((a, b) {
        final dt = a.timestamp - b.timestamp;
        if (dt != 0) return dt;
        return a.seq - b.seq;
      });

    // Rate-flood per-pubkey window state (mirrors `channelTracking` entries:
    // count, firstMessageTime, and the sticky `blocked` flag).
    final rateCount = <String, int>{};
    final rateFirst = <String, int>{};
    final rateBlocked = <String>{};
    // Content-flood per-pubkey state: hash → (count, lastSeen).
    final contentHashes = <String, Map<int, _ContentInfo>>{};

    final blockedUntil = <String, int>{};

    void block(String pubkey, int until) {
      final cur = blockedUntil[pubkey];
      if (cur == null || until > cur) blockedUntil[pubkey] = until;
    }

    for (final m in ordered) {
      final pubkey = m.pubkey;
      if (pubkey.isEmpty || pubkey == selfPubkey || m.isOwn) continue;
      if (m.isHistorical) continue;
      final now = m.timestamp;

      // --- rate flood (`trackMessage`) ---
      final first = rateFirst[pubkey];
      if (first == null) {
        rateCount[pubkey] = 1;
        rateFirst[pubkey] = now;
      } else if (now - first > kRateFloodWindowMs) {
        // Window elapsed → reset the counter + sticky block (`count = 1`,
        // `blocked = false`).
        rateCount[pubkey] = 1;
        rateFirst[pubkey] = now;
        rateBlocked.remove(pubkey);
      } else {
        final count = (rateCount[pubkey] ?? 0) + 1;
        rateCount[pubkey] = count;
        // Block ONCE on the first message past the threshold (the PWA's
        // `count > 10 && !blocked` guard sets `blockedUntil` a single time).
        if (count > kRateFloodMax && !rateBlocked.contains(pubkey)) {
          rateBlocked.add(pubkey);
          block(pubkey, now + kFloodBlockMs);
        }
      }

      // --- content flood (`_trackContent`) ---
      final normalized = _normalizeContent(m.content);
      if (normalized.length < kContentFloodMinLen) continue;
      final hashes = contentHashes.putIfAbsent(pubkey, () => {});
      // Evict entries older than the 120 s window.
      hashes.removeWhere((_, info) => now - info.lastSeen > kContentFloodWindowMs);
      final hash = fnv1a32(normalized);
      final info = hashes.putIfAbsent(hash, () => _ContentInfo());
      info.count++;
      info.lastSeen = now;
      if (info.count >= kContentFloodRepeat) {
        block(pubkey, now + kFloodBlockMs);
      }
    }

    if (blockedUntil.isEmpty) return empty;
    return FloodTracker._(blockedUntil);
  }
}

/// Mutable per-hash content tally used only while replaying (`info` in
/// `_trackContent`).
class _ContentInfo {
  int count = 0;
  int lastSeen = 0;
}

/// Flood tracker for the **active conversation**. Recomputed from
/// [messagesForCurrentViewProvider] (the current view's recent messages) and the
/// self pubkey, so `message_row` can dim flooded rows without touching state.
///
/// Per-channel scoping falls out of `messagesForCurrentViewProvider` already
/// keying on the active `storageKey`; content-flood — global-per-pubkey in the
/// PWA — is likewise scoped to the visible conversation here, which is all the UI
/// can dim anyway.
final floodTrackerProvider = Provider<FloodTracker>((ref) {
  final messages = ref.watch(messagesForCurrentViewProvider);
  final selfPubkey = ref.watch(appStateProvider).selfPubkey;
  return FloodTracker.fromMessages(messages, selfPubkey: selfPubkey);
});
