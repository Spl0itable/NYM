import 'dart:math';

import '../../core/constants/event_kinds.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';
import '../../services/nostr/event_mapper.dart';
import '../p2p/p2p_models.dart';

/// Socket-free NIP-17 PM logic: rumor construction, rumor-to-[Message] mapping, receipt and typing parsing.
class PmLogic {
  PmLogic._();

  static final Random _rng = Random.secure();

  /// 64-hex CSPRNG shared id for the `['x', nymMessageId]` tag used for dedup and receipt matching.
  static String generateSharedEventId() {
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Kind-14 PM rumor with p, x and ms tags, then [extraTags] (offer, NIP-30 emoji, NIP-92 imeta) in PWA order.
  static UnsignedEvent buildPmRumor({
    required String selfPubkey,
    required String recipientPubkey,
    required String content,
    required String nymMessageId,
    List<List<String>> extraTags = const [],
    int? nowSec,
    int? nowMs,
  }) {
    final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final sec = nowSec ?? (ms ~/ 1000);
    return UnsignedEvent(
      pubkey: selfPubkey,
      createdAt: sec,
      kind: EventKind.dmRumor,
      tags: [
        ['p', recipientPubkey],
        ['x', nymMessageId],
        ['ms', '$ms'],
        ...extraTags,
      ],
      content: content,
    );
  }

  /// Storage key matching `ChatView.pm(pubkey)`, so messages land where the sidebar opens.
  static String pmStorageKey(String peerPubkey) => 'pm-$peerPubkey';

  /// Wire-level key (`pm-<sorted pubkeys>`) for cross-device dedup; not the store key.
  static String pmWireKey(String self, String other) =>
      getPMConversationKey(self, other);

  /// Maps a decrypted kind-14 rumor to a PM [Message]; [senderVerified] comes from NIP-59 seal verification.
  static Message? mapPmRumor({
    required Map<String, dynamic> rumor,
    required String wrapId,
    required String selfPubkey,
    required bool senderVerified,
    bool pqEncrypted = false,
    // Applied to the resolved peer, which for our own copy is the `p` tag, not the author.
    bool Function(String peerPubkey)? pqRootFor,
  }) {
    if ((rumor['kind'] as num?)?.toInt() != EventKind.dmRumor) return null;
    final senderPubkey = rumor['pubkey'] as String?;
    if (senderPubkey == null || senderPubkey.isEmpty) return null;
    final content = rumor['content'];
    if (content is! String) return null;

    final tags = _tags(rumor);
    final peer = senderPubkey == selfPubkey
        ? _tagValue(tags, 'p') ?? senderPubkey
        : senderPubkey;
    final nymMessageId = _tagValue(tags, 'x');
    final ms = int.tryParse(_tagValue(tags, 'ms') ?? '') ?? 0;
    // Thread reply marker: the root's shared nymMessageId.
    final threadRoot = _tagValue(tags, 'nymthread');

    // `parseFileOfferTag` binds the seeder to the actual sender (anti-spoof); registering the offer is the ingest layer's job.
    final fileOffer = parseFileOfferTag(tags, senderPubkey);

    final createdAtRaw = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final times = EventMapper.rumorTimes(
      key: nymMessageId ?? wrapId,
      createdAtRaw: createdAtRaw,
      ms: ms,
    );

    final isOwn = senderPubkey == selfPubkey;
    // Fallback `nym#xxxx`, never 'anon'; the controller re-resolves the author afterwards.
    final author = getNymFromPubkey('nym', senderPubkey);

    return Message(
      id: wrapId.isNotEmpty ? wrapId : (nymMessageId ?? ''),
      author: author,
      pubkey: senderPubkey,
      content: content,
      createdAt: times.createdAt,
      originalCreatedAt: createdAtRaw,
      ms: ms,
      timestamp: times.timestampMs,
      isOwn: isOwn,
      isPM: true,
      conversationKey: pmStorageKey(peer),
      conversationPubkey: peer,
      eventKind: EventKind.giftWrap,
      nymMessageId: nymMessageId,
      threadRoot: threadRoot,
      senderVerified: senderVerified,
      pqEncrypted: pqEncrypted,
      pqRoot: pqEncrypted && (pqRootFor?.call(peer) ?? false),
      isFileOffer: fileOffer != null,
      fileOffer: fileOffer?.toJson(),
      deliveryStatus: isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
    );
  }

  static const Set<String> _unverifiedBlockedTags = {
    'g',
    'edit',
    'typing',
    'receipt',
    'offer',
    'type',
  };

  static bool unverifiedWrapAllowed(Map<String, dynamic> rumor,
      {required String selfPubkey}) {
    if ((rumor['kind'] as num?)?.toInt() != EventKind.dmRumor) return false;
    final sender = rumor['pubkey'];
    if (sender is! String || sender.isEmpty || sender == selfPubkey) {
      return false;
    }
    if (rumor['content'] is! String) return false;
    for (final t in _tags(rumor)) {
      if (t.isNotEmpty && _unverifiedBlockedTags.contains(t[0])) return false;
    }
    return !isTyping(rumor) && !isReceipt(rumor);
  }

  /// True if [rumor] carries a `['receipt', 'delivered'|'read']` tag.
  static bool isReceipt(Map<String, dynamic> rumor) {
    for (final t in _tags(rumor)) {
      if (t.isNotEmpty && t[0] == 'receipt' && t.length > 1) {
        return t[1] == 'delivered' || t[1] == 'read';
      }
    }
    return false;
  }

  static bool isTyping(Map<String, dynamic> rumor) =>
      _tags(rumor).any((t) => t.isNotEmpty && t[0] == 'typing');

  /// Parses a receipt with its reader, needed for group read-receipt avatars; group vs PM comes from the matched message.
  static ReceiptInfo? parseReceipt(Map<String, dynamic> rumor) {
    final messageIds = <String>[];
    String? type;
    for (final t in _tags(rumor)) {
      if (t.length < 2) continue;
      if (t[0] == 'x') messageIds.add(t[1]);
      if (t[0] == 'receipt') type = t[1];
    }
    if (messageIds.isEmpty || type == null) return null;
    return ReceiptInfo(
      messageId: messageIds.first,
      messageIds: messageIds,
      receiptType: type,
      readerPubkey: rumor['pubkey'] as String?,
    );
  }

  static TypingInfo? parseTyping(Map<String, dynamic> rumor) {
    String? status;
    String? groupId;
    var ttl = 0;
    for (final t in _tags(rumor)) {
      if (t.length < 2) continue;
      if (t[0] == 'typing') status = t[1];
      if (t[0] == 'g') groupId = t[1];
      if (t[0] == 'ttl') ttl = int.tryParse(t[1]) ?? 0;
    }
    if (status == null) return null;
    return TypingInfo(
      status: status,
      groupId: groupId,
      pubkey: rumor['pubkey'] as String?,
      ttlSec: ttl > 0 ? ttl : 0,
    );
  }

  /// Delivery status rank, so state only advances.
  static int statusOrder(DeliveryStatus s) {
    switch (s) {
      case DeliveryStatus.read:
        return 3;
      case DeliveryStatus.delivered:
        return 2;
      case DeliveryStatus.sent:
        return 1;
      default:
        return 0;
    }
  }

  static DeliveryStatus deliveryFromReceipt(String receiptType) {
    switch (receiptType) {
      case 'read':
        return DeliveryStatus.read;
      case 'delivered':
        return DeliveryStatus.delivered;
      default:
        return DeliveryStatus.sent;
    }
  }

  static List<List<String>> _tags(Map<String, dynamic> rumor) {
    final raw = rumor['tags'];
    if (raw is! List) return const [];
    return raw
        .whereType<List>()
        .map((t) => t.map((e) => e.toString()).toList())
        .toList();
  }

  static String? _tagValue(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }
}

class ReceiptInfo {
  ReceiptInfo({
    required this.messageId,
    required this.receiptType,
    List<String>? messageIds,
    this.readerPubkey,
  }) : messageIds = messageIds ?? [messageId];

  final String messageId;

  final List<String> messageIds;

  /// 'delivered' | 'read'.
  final String receiptType;

  /// The peer who delivered or read our message, for group read-receipt avatars.
  final String? readerPubkey;
}

class TypingInfo {
  TypingInfo({required this.status, this.groupId, this.pubkey, this.ttlSec = 0});

  /// 'start' | 'stop'.
  final String status;
  final String? groupId;
  final String? pubkey;

  final int ttlSec;

  bool get isStart => status == 'start';
}
