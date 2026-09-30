import '../../core/constants/event_kinds.dart';
import '../../models/nostr_event.dart';

/// Socket-free NIP-57 helpers: zap request builder, bolt11 amount parsing, receipt dedup.
class ZapLogic {
  ZapLogic._();

  /// NIP-57 kind-9734 zap request; tag order is e (message zaps only), p, amount, relays, k.
  static UnsignedEvent buildZapRequest({
    required String pubkey,
    required String recipientPubkey,
    required int amountSats,
    required List<String> relays,
    String? messageId,
    String? originalKind,
    String comment = '',
    int? nowSec,
  }) {
    final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final tags = <List<String>>[];
    if (messageId != null && messageId.isNotEmpty) {
      tags.add(['e', messageId]);
    }
    tags.add(['p', recipientPubkey]);
    tags.add(['amount', '${amountSats * 1000}']);
    // A single multi-value relays tag with at most five relays.
    tags.add(['relays', ...relays.take(5)]);
    // k tag: message zaps default to '20000'; profile zaps use '0'.
    final k = messageId != null && messageId.isNotEmpty
        ? (originalKind ?? '20000')
        : '0';
    tags.add(['k', k]);
    return UnsignedEvent(
      pubkey: pubkey,
      createdAt: now,
      kind: EventKind.zapRequest,
      tags: tags,
      content: comment,
    );
  }

  /// Sats amount from a bolt11 invoice, or null when malformed or out of bounds.
  static int? parseAmountFromBolt11(String? bolt11) {
    if (bolt11 == null || bolt11.length < 6 || bolt11.length > 4096) {
      return null;
    }
    final m = RegExp(r'^lnbc(\d{1,15})([munp])', caseSensitive: false)
        .firstMatch(bolt11);
    if (m == null) return null;
    final amount = int.tryParse(m.group(1)!);
    if (amount == null || amount <= 0) return null;
    int sats;
    switch (m.group(2)!.toLowerCase()) {
      case 'm':
        sats = amount * 100000;
        break;
      case 'u':
        sats = amount * 100;
        break;
      case 'n':
        sats = (amount / 10).round();
        break;
      case 'p':
        sats = (amount / 10000).round();
        break;
      default:
        return null;
    }
    if (sats <= 0 || sats > 1000000000) return null;
    return sats;
  }

  /// Lowercased bolt11 prefixed `b:`, falling back to the receipt event id.
  static String dedupKey({String? bolt11, required String eventId}) =>
      (bolt11 != null && bolt11.isNotEmpty)
          ? 'b:${bolt11.toLowerCase()}'
          : eventId;

  /// Parses a kind-9735 receipt, or null without an `e` target (profile zaps don't accrue to a message).
  static ZapReceiptInfo? parseReceipt(NostrEvent e) {
    if (e.kind != EventKind.zapReceipt) return null;
    final messageId = e.tagValue('e');
    if (messageId == null || messageId.isEmpty) return null;
    final bolt11 = e.tagValue('bolt11');
    final amount = parseAmountFromBolt11(bolt11);
    if (amount == null) return null;
    return ZapReceiptInfo(
      messageId: messageId,
      recipientPubkey: e.tagValue('p'),
      zapperPubkey: e.pubkey,
      amountSats: amount,
      bolt11: bolt11,
      eventId: e.id,
    );
  }
}

class ZapReceiptInfo {
  ZapReceiptInfo({
    required this.messageId,
    required this.recipientPubkey,
    required this.zapperPubkey,
    required this.amountSats,
    required this.bolt11,
    required this.eventId,
  });

  final String messageId;

  final String? recipientPubkey;

  final String zapperPubkey;
  final int amountSats;
  final String? bolt11;
  final String eventId;

  String get dedupKey => ZapLogic.dedupKey(bolt11: bolt11, eventId: eventId);
}
