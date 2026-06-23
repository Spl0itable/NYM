import 'dart:math';

import '../../core/constants/event_kinds.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';

/// Pure, socket-free logic for NIP-17 private messages: rumor construction,
/// rumor→[Message] mapping, and receipt/typing parsing. Kept testable so the
/// crypto/relay layers can be exercised without networking.
/// (docs/specs/03 §3.1–§3.4, §10)
class PmLogic {
  PmLogic._();

  static final Random _rng = Random.secure();

  /// 64-hex CSPRNG shared id (mirrors `_generateSharedEventId`). Used for the
  /// `['x', nymMessageId]` tag carried across PM/group copies for dedup +
  /// receipt matching.
  static String generateSharedEventId() {
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Builds the kind-14 PM rumor for [content] addressed to [recipientPubkey].
  /// Tags: `['p',recipient]`, `['x',nymMessageId]`, `['ms',ms]` (docs/specs/03
  /// §3.2). [nowSec]/[nowMs] are injectable for deterministic tests.
  static UnsignedEvent buildPmRumor({
    required String selfPubkey,
    required String recipientPubkey,
    required String content,
    required String nymMessageId,
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
      ],
      content: content,
    );
  }

  /// AppState storage key for a PM thread with [peerPubkey]. Matches the UI's
  /// `ChatView.pm(pubkey)` keying (`pm-<peerPubkey>`), so PM messages land in
  /// the same map the sidebar opens.
  static String pmStorageKey(String peerPubkey) => 'pm-$peerPubkey';

  /// Wire-level conversation key per the spec (`pm-<sorted pubkeys>`). Useful
  /// for cross-device dedup keys; not the AppState store key.
  static String pmWireKey(String self, String other) =>
      getPMConversationKey(self, other);

  /// Maps a decrypted rumor map (kind 14) recovered from a gift wrap into a PM
  /// [Message]. [wrapId] is the gift-wrap event id (for reactions/zaps).
  /// [selfPubkey] determines ownership; [senderVerified] flows from NIP-59
  /// seal verification.
  static Message? mapPmRumor({
    required Map<String, dynamic> rumor,
    required String wrapId,
    required String selfPubkey,
    required bool senderVerified,
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

    // Guard against clock skew: cap at current time so PMs never appear in the
    // future (pms.js: `tsSec = Math.min(tsSec, nowSec)`).
    final createdAtRaw = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final createdAt = createdAtRaw > nowSec ? nowSec : createdAtRaw;

    final isOwn = senderPubkey == selfPubkey;
    final author = getNymFromPubkey('anon', senderPubkey);

    return Message(
      id: wrapId.isNotEmpty ? wrapId : (nymMessageId ?? ''),
      author: author,
      pubkey: senderPubkey,
      content: content,
      createdAt: createdAt,
      originalCreatedAt: createdAtRaw,
      ms: ms,
      isOwn: isOwn,
      isPM: true,
      conversationKey: pmStorageKey(peer),
      conversationPubkey: peer,
      eventKind: EventKind.giftWrap,
      nymMessageId: nymMessageId,
      senderVerified: senderVerified,
      deliveryStatus: isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
    );
  }

  // ---- receipts / typing (kind 69420 rumor) -------------------------------

  /// True if [rumor] carries a `['receipt', 'delivered'|'read']` tag.
  static bool isReceipt(Map<String, dynamic> rumor) {
    for (final t in _tags(rumor)) {
      if (t.isNotEmpty && t[0] == 'receipt' && t.length > 1) {
        return t[1] == 'delivered' || t[1] == 'read';
      }
    }
    return false;
  }

  /// True if [rumor] carries a `['typing', …]` tag.
  static bool isTyping(Map<String, dynamic> rumor) =>
      _tags(rumor).any((t) => t.isNotEmpty && t[0] == 'typing');

  /// Parses a receipt rumor → (messageId, receiptType), or null.
  static ReceiptInfo? parseReceipt(Map<String, dynamic> rumor) {
    String? messageId;
    String? type;
    for (final t in _tags(rumor)) {
      if (t.length < 2) continue;
      if (t[0] == 'x') messageId = t[1];
      if (t[0] == 'receipt') type = t[1];
    }
    if (messageId == null || type == null) return null;
    return ReceiptInfo(messageId: messageId, receiptType: type);
  }

  /// Parses a typing rumor → (status, groupId?), or null.
  static TypingInfo? parseTyping(Map<String, dynamic> rumor) {
    String? status;
    String? groupId;
    for (final t in _tags(rumor)) {
      if (t.length < 2) continue;
      if (t[0] == 'typing') status = t[1];
      if (t[0] == 'g') groupId = t[1];
    }
    if (status == null) return null;
    return TypingInfo(
      status: status,
      groupId: groupId,
      pubkey: rumor['pubkey'] as String?,
    );
  }

  /// Maps a receipt type to a [DeliveryStatus] rank (so we only advance, never
  /// regress, delivery state).
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

/// A parsed delivery/read receipt from a kind-69420 rumor.
class ReceiptInfo {
  ReceiptInfo({required this.messageId, required this.receiptType});

  /// The `['x', …]` nymMessageId of the original message.
  final String messageId;

  /// 'delivered' | 'read'.
  final String receiptType;
}

/// A parsed typing indicator from a kind-69420 rumor.
class TypingInfo {
  TypingInfo({required this.status, this.groupId, this.pubkey});

  /// 'start' | 'stop'.
  final String status;
  final String? groupId;
  final String? pubkey;

  bool get isStart => status == 'start';
}
