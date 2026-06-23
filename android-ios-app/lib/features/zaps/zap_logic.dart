import '../../core/constants/event_kinds.dart';
import '../../models/nostr_event.dart';

/// Pure, socket-free logic for the Nostr side of Lightning zaps (NIP-57):
/// building the kind-9734 zap request, parsing bolt11 amounts, and the
/// receipt-dedup key. The LNURL HTTP/invoice/pay flow lives in the zap UI
/// agent — this only covers the request builder + receipt ingest helpers.
/// Mirrors `js/modules/zaps.js` (`createZapRequest`, `parseAmountFromBolt11`,
/// `_recordMessageZap` dedup). (docs/specs/03 §Appendix A kind 9734/9735)
class ZapLogic {
  ZapLogic._();

  /// Builds the NIP-57 kind-9734 zap-request event (zaps.js `createZapRequest`).
  ///
  /// Tags, in the PWA's order:
  /// - `['e', messageId]` first (only for message zaps; profile zaps omit it),
  /// - `['p', recipientPubkey]`,
  /// - `['amount', millisats]`,
  /// - `['relays', r0, r1, … up to 5]`,
  /// - `['k', originalKind]` last (`'20000'`/`'23333'`/`'1059'` for message
  ///   zaps; `'0'` for profile zaps).
  /// content = comment (may be empty).
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
    // ['relays', ...firstFive] — note: a single multi-value tag, matching
    // zaps.js `['relays', ...this.defaultRelays.slice(0, 5)]`.
    tags.add(['relays', ...relays.take(5)]);
    // k tag: message zaps default to '20000'; profile zaps tag k=0.
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

  /// Parses the sats amount from a bolt11 invoice string (zaps.js
  /// `parseAmountFromBolt11`). Returns null when malformed or out of bounds.
  static int? parseAmountFromBolt11(String? bolt11) {
    if (bolt11 == null || bolt11.length < 6 || bolt11.length > 4096) return null;
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

  /// Receipt dedup key (zaps.js `_recordMessageZap`): the lowercased bolt11
  /// prefixed `b:`, falling back to the receipt event id when no bolt11.
  static String dedupKey({String? bolt11, required String eventId}) =>
      (bolt11 != null && bolt11.isNotEmpty)
          ? 'b:${bolt11.toLowerCase()}'
          : eventId;

  /// Parsed fields from a kind-9735 zap receipt. Returns null when the receipt
  /// carries no `['e', …]` target (message zaps only — profile zaps are handled
  /// separately and don't accrue to a message).
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

/// A parsed kind-9735 message zap receipt.
class ZapReceiptInfo {
  ZapReceiptInfo({
    required this.messageId,
    required this.recipientPubkey,
    required this.zapperPubkey,
    required this.amountSats,
    required this.bolt11,
    required this.eventId,
  });

  /// The `['e', …]` zapped message id.
  final String messageId;

  /// The `['p', …]` recipient pubkey (may be null).
  final String? recipientPubkey;

  /// The receipt event author (zapper / provider).
  final String zapperPubkey;
  final int amountSats;
  final String? bolt11;
  final String eventId;

  String get dedupKey => ZapLogic.dedupKey(bolt11: bolt11, eventId: eventId);
}
