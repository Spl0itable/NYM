// Per-pubkey flood detection recomputed from recent messages: >10 in 2s, or the same content 3x in 120s, blocks for 15 min.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';

/// Block duration once a pubkey trips either gate: 15 minutes.
const int kFloodBlockMs = 900000;

/// Rate-flood window: more than [kRateFloodMax] messages inside it.
const int kRateFloodWindowMs = 2000;
const int kRateFloodMax = 10;

/// Same normalized content repeated this many times inside [kContentFloodWindowMs].
const int kContentFloodWindowMs = 120000;
const int kContentFloodRepeat = 3;
const int kContentFloodMinLen = 6;

/// FNV-1a 32-bit over UTF-16 code units, unsigned, matching the PWA.
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    // 32-bit truncation mirrors JS `Math.imul` then `>>> 0`.
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0xffffffff;
}

/// Collapse whitespace, trim, lowercase.
String _normalizeContent(String content) =>
    content.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// Immutable snapshot of which pubkeys are flooding in one conversation, against the real clock.
class FloodTracker {
  const FloodTracker._(this._blockedUntil);

  /// pubkey -> latest `blockedUntil` ms across both gates.
  final Map<String, int> _blockedUntil;

  static const FloodTracker empty = FloodTracker._({});

  /// True while [pubkey]'s block hasn't elapsed on the real clock.
  bool isFlooding(String pubkey) {
    final until = _blockedUntil[pubkey];
    if (until == null) return false;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  /// Replays [messages] in arrival order through both gates; [selfPubkey] and historical messages are exempt.
  factory FloodTracker.fromMessages(
    List<Message> messages, {
    required String selfPubkey,
  }) {
    if (messages.isEmpty) return empty;

    // `seq` is the monotonic arrival tiebreak.
    final ordered = [...messages]..sort((a, b) {
        final dt = a.timestamp - b.timestamp;
        if (dt != 0) return dt;
        return a.seq - b.seq;
      });

    final rateCount = <String, int>{};
    final rateFirst = <String, int>{};
    final rateBlocked = <String>{};
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

      final first = rateFirst[pubkey];
      if (first == null) {
        rateCount[pubkey] = 1;
        rateFirst[pubkey] = now;
      } else if (now - first > kRateFloodWindowMs) {
        // Window elapsed: reset the counter and sticky block.
        rateCount[pubkey] = 1;
        rateFirst[pubkey] = now;
        rateBlocked.remove(pubkey);
      } else {
        final count = (rateCount[pubkey] ?? 0) + 1;
        rateCount[pubkey] = count;
        // Block once, on the first message past the threshold.
        if (count > kRateFloodMax && !rateBlocked.contains(pubkey)) {
          rateBlocked.add(pubkey);
          block(pubkey, now + kFloodBlockMs);
        }
      }

      final normalized = _normalizeContent(m.content);
      if (normalized.length < kContentFloodMinLen) continue;
      final hashes = contentHashes.putIfAbsent(pubkey, () => {});
      // Evict entries older than the 120s window.
      hashes.removeWhere(
          (_, info) => now - info.lastSeen > kContentFloodWindowMs);
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

class _ContentInfo {
  int count = 0;
  int lastSeen = 0;
}

/// Flood tracker for the active conversation; content flood is scoped to the visible conversation too.
final floodTrackerProvider = Provider<FloodTracker>((ref) {
  final s = ref.watch(appStateProvider);
  if (!s.clientGatesActive) return FloodTracker.empty;
  final messages = ref.watch(messagesForCurrentViewProvider);
  return FloodTracker.fromMessages(messages, selfPubkey: s.selfPubkey);
});
