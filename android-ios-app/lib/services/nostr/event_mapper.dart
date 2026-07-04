import 'dart:convert';

import '../../core/constants/event_kinds.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/p2p/p2p_models.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';
import '../../models/user.dart';

/// Pure mappers from Nostr [NostrEvent]s to app models. Kept side-effect free so
/// they can be unit-tested without networking.
class EventMapper {
  EventMapper._();

  /// The channel storage key for a channel-message event (`#<geohash|name>`),
  /// or null if it isn't a channel message.
  static String? channelKeyOf(NostrEvent e) {
    if (e.kind == EventKind.geoChannel) {
      final g = e.tagValue('g');
      return g == null ? null : '#$g';
    }
    if (e.kind == EventKind.namedChannel) {
      final d = e.tagValue('d');
      return d == null ? null : '#$d';
    }
    return null;
  }

  /// Maps a channel message event (kind 20000/23333) to a [Message].
  /// [selfPubkey] marks ownership. Returns null if the event isn't a valid
  /// channel message.
  static Message? channelMessage(NostrEvent e, {required String selfPubkey}) {
    if (e.kind != EventKind.geoChannel && e.kind != EventKind.namedChannel) {
      return null;
    }
    final isGeo = e.kind == EventKind.geoChannel;
    final geohash = isGeo ? e.tagValue('g') : null;
    final channel = isGeo ? null : e.tagValue('d');
    if (isGeo && geohash == null) return null;
    if (!isGeo && channel == null) return null;

    final baseNym = e.tagValue('n') ?? 'nym';
    final author = getNymFromPubkey(baseNym, e.pubkey);
    final ms = int.tryParse(e.tagValue('ms') ?? '') ?? 0;

    // Clamp future timestamps to now (mirrors the PWA).
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final createdAt = e.createdAt > nowSec + 60 ? nowSec : e.createdAt;

    // A channel message can carry a P2P file offer on an `['offer', JSON]` tag
    // (`shareP2PFile` → `publishFileOffer`). nostr-core.js:434/502 parses it off
    // the inbound event and sets `isFileOffer`/`fileOffer` so the row renders a
    // file-offer card. `parseFileOfferTag` binds the offer's seederPubkey to the
    // actual sender (anti-spoof) and returns null when absent/mismatched.
    final fileOffer = parseFileOfferTag(e.tags, e.pubkey);

    return Message(
      id: e.id,
      author: author,
      pubkey: e.pubkey,
      content: e.content,
      createdAt: createdAt,
      originalCreatedAt: e.createdAt,
      ms: ms,
      eventKind: e.kind,
      isOwn: e.pubkey == selfPubkey,
      channel: channel,
      geohash: geohash,
      senderVerified: true,
      isFileOffer: fileOffer != null,
      fileOffer: fileOffer?.toJson(),
    );
  }

  /// Parses a kind-0 profile event into a [UserProfile].
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

  /// Reaction descriptor parsed from a kind-7 event.
  static ReactionInfo? reaction(NostrEvent e) {
    if (e.kind != EventKind.reaction) return null;
    final target = e.tagValue('e');
    if (target == null) return null;
    final remove = e.tagsNamed('action').any((t) => t.length > 1 && t[1] == 'remove');
    return ReactionInfo(
      messageId: target,
      emoji: e.content,
      reactor: e.pubkey,
      removed: remove,
      ts: e.createdAt,
    );
  }
}

/// A parsed reaction (kind 7).
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
