import 'dart:convert';

import '../../core/constants/event_kinds.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/p2p/p2p_models.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';
import '../../models/user.dart';
import 'event_time_ceilings.dart';

/// Side-effect-free mappers from [NostrEvent]s to app models.
class EventMapper {
  EventMapper._();

  /// First-seen clamps for future-dated events; null in tests, where the clamp uses a volatile now.
  static EventTimeCeilings? ceilings;

  /// Future-dated clamp: a D1 `stored_at` wins, else the first clamp is remembered per id.
  static ({int ceilingMs, int createdAt}) _clampFuture(NostrEvent e, int nowMs) {
    final nowSec = nowMs ~/ 1000;
    if (e.createdAt <= nowSec + 60) {
      return (ceilingMs: nowMs, createdAt: e.createdAt);
    }
    final storedAtMs = e.storedAt > 0 ? e.storedAt : 0;
    final createdAtMs = e.createdAt * 1000;
    final candidateMs =
        (storedAtMs > 0 && storedAtMs < createdAtMs) ? storedAtMs : createdAtMs;
    final registry = ceilings;
    final ceilingMs = registry != null
        ? registry.stableCeiling(e.id, candidateMs, nowMs)
        : (candidateMs < nowMs ? candidateMs : nowMs);
    return (ceilingMs: ceilingMs, createdAt: ceilingMs ~/ 1000);
  }

  /// Bare channel name, or null unless kind and channel shape agree (20000 + geohash `g`, 23333 + named `d`).
  static String? channelNameOf(NostrEvent e) {
    final isGeo = e.kind == EventKind.geoChannel;
    if (!isGeo && e.kind != EventKind.namedChannel) return null;
    final name = isGeo ? e.tagValue('g') : e.tagValue('d');
    if (name == null || !isValidChannelTag(name)) return null;
    if (isValidGeohash(name) != isGeo) return null;
    return name;
  }

  /// Channel storage key (`#<geohash|name>`), or null if not a channel message.
  static String? channelKeyOf(NostrEvent e) {
    final name = channelNameOf(e);
    return name == null ? null : '#$name';
  }

  /// Authoritative display time in ms, matching what [channelMessage] stamps; raw `created_at` can be future-dated.
  static int effectiveMsOf(NostrEvent e) {
    final ms = int.tryParse(e.tagValue('ms') ?? '') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clamped = _clampFuture(e, nowMs);
    return displayMs(
      ms: ms,
      createdAtRaw: e.createdAt,
      createdAt: clamped.createdAt,
      ceilingMs: clamped.ceilingMs,
    );
  }

  static const int msTagToleranceMs = 60000;

  static int displayMs({
    required int ms,
    required int createdAtRaw,
    required int createdAt,
    required int ceilingMs,
  }) {
    if (ms <= 0 || ms > createdAtRaw * 1000 + msTagToleranceMs) {
      return createdAt * 1000;
    }
    return ms < ceilingMs ? ms : ceilingMs;
  }

  static ({int createdAt, int timestampMs}) rumorTimes({
    required String key,
    required int createdAtRaw,
    required int ms,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final nowSec = now ~/ 1000;
    int ceilingMs;
    int createdAt;
    if (createdAtRaw <= nowSec + 60) {
      ceilingMs = now;
      createdAt = createdAtRaw;
    } else {
      final registry = ceilings;
      ceilingMs = registry != null
          ? registry.stableCeiling(key, createdAtRaw * 1000, now)
          : now;
      createdAt = ceilingMs ~/ 1000;
    }
    return (
      createdAt: createdAt,
      timestampMs: displayMs(
        ms: ms,
        createdAtRaw: createdAtRaw,
        createdAt: createdAt,
        ceilingMs: ceilingMs,
      ),
    );
  }

  /// Maps a kind 20000/23333 event to a [Message], or null if it isn't a valid channel message.
  static Message? channelMessage(NostrEvent e, {required String selfPubkey}) {
    if (e.kind != EventKind.geoChannel && e.kind != EventKind.namedChannel) {
      return null;
    }
    // [channelNameOf] is the single shape gate for the pool, D1 backfill and mesh carrier alike.
    final isGeo = e.kind == EventKind.geoChannel;
    final name = channelNameOf(e);
    if (name == null) return null;
    final geohash = isGeo ? name : null;
    final channel = isGeo ? null : name;

    final baseNym = e.tagValue('n') ?? 'nym';
    final author = getNymFromPubkey(baseNym, e.pubkey);
    final ms = int.tryParse(e.tagValue('ms') ?? '') ?? 0;

    // Clamp future timestamps to a stable ceiling, so reloads don't re-stamp archived events to now.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clamped = _clampFuture(e, nowMs);
    final ceilingMs = clamped.ceilingMs;
    final createdAt = clamped.createdAt;

    // Prefer the `ms` tag, capped at now: relays can re-stamp `created_at` forward when replaying history.
    final effectiveMs = displayMs(
      ms: ms,
      createdAtRaw: e.createdAt,
      createdAt: createdAt,
      ceilingMs: ceilingMs,
    );

    // Older than 10s by real send time: kept out of the live flood tracker and entrance animation.
    final isHistorical = nowMs - effectiveMs > 10000;

    // `parseFileOfferTag` binds the offer's seeder to the sender and returns null when mismatched.
    final fileOffer = parseFileOfferTag(e.tags, e.pubkey);

    final threadRoot = threadRootFromTags(e.tags);

    return Message(
      id: e.id,
      author: author,
      pubkey: e.pubkey,
      content: e.content,
      createdAt: createdAt,
      originalCreatedAt: e.createdAt,
      ms: ms,
      // Display and flood-tracker time only; sorting still keys on created_at.
      timestamp: effectiveMs,
      eventKind: e.kind,
      isOwn: e.pubkey == selfPubkey,
      channel: channel,
      geohash: geohash,
      senderVerified: true,
      isHistorical: isHistorical,
      isFileOffer: fileOffer != null,
      fileOffer: fileOffer?.toJson(),
      threadRoot: threadRoot,
      // Committed NIP-13 target, or null with no nonce tag; proven work is recomputed from the id.
      powTarget: powTargetOf(e),
    );
  }

  /// NIP-10 thread root: the first 'root' marked `e` tag, else 'reply'; only 64-hex ids count.
  static String? threadRootFromTags(List<List<String>> tags) {
    String? root;
    String? reply;
    for (final t in tags) {
      if (t.length < 2 || t[0] != 'e' || t[1].isEmpty) continue;
      final marker = t.length > 3 ? t[3] : '';
      if (marker == 'root') {
        root ??= t[1];
      } else if (marker == 'reply') {
        reply ??= t[1];
      }
    }
    final id = root ?? reply;
    if (id == null) return null;
    final isHex = id.length == 64 && RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(id);
    return isHex ? id : null;
  }

  /// NIP-13 committed difficulty, or null without a nonce tag; an unparseable target maps to 0.
  static int? powTargetOf(NostrEvent e) {
    for (final t in e.tags) {
      if (t.isNotEmpty && t[0] == 'nonce') {
        if (t.length < 3) return 0;
        final target = int.tryParse(t[2]);
        return (target != null && target > 0) ? target : 0;
      }
    }
    return null;
  }

  static UserProfile? profile(NostrEvent e) {
    if (e.kind != EventKind.profile) return null;
    try {
      final json = jsonDecode(e.content);
      if (json is! Map) return null;
      return UserProfile.fromJson(json.cast<String, dynamic>(),
          kind0Ts: e.createdAt);
    } catch (_) {
      return null;
    }
  }

  static ReactionInfo? reaction(NostrEvent e) {
    if (e.kind != EventKind.reaction) return null;
    final target = e.tagValue('e');
    if (target == null) return null;
    final remove =
        e.tagsNamed('action').any((t) => t.length > 1 && t[1] == 'remove');
    return ReactionInfo(
      messageId: target,
      emoji: e.content,
      reactor: e.pubkey,
      removed: remove,
      ts: e.createdAt,
    );
  }
}

class ReactionInfo {
  ReactionInfo({
    required this.messageId,
    required this.emoji,
    required this.reactor,
    required this.removed,
    required this.ts,
  });
  final String messageId;
  final String emoji;
  final String reactor;
  final bool removed;
  final int ts;
}
