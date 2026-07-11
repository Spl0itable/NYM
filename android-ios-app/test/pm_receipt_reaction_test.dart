import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/pms/pm_logic.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// Restore an OWN group message (indexed by its shared nymMessageId), the way a
/// D1/group-history backfill lands it.
void _restoreOwn(AppStateNotifier n,
    {required String convKey,
    required String id,
    required String nymMessageId,
    required String groupId,
    bool isOwn = true,
    String pubkey = 'self_pk'}) {
  n.applyGroupHistorySync({
    convKey: [
      {
        'id': id,
        'pubkey': pubkey,
        'content': 'hi',
        'created_at': 1700000000,
        'isOwn': isOwn,
        'nymMessageId': nymMessageId,
        'groupId': groupId,
      },
    ],
  });
}

void main() {
  test('a PM/group receipt that arrives BEFORE its message is replayed on land',
      () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    // Live 'read' receipt beats the async restore — its target isn't indexed
    // yet, so it must be buffered, not dropped.
    n.applyReceipt(ReceiptInfo(messageId: 'nym1', receiptType: 'read'));
    // The own message now lands from the backfill and gets indexed by nym1.
    _restoreOwn(n,
        convKey: 'group-g1', id: 'wrap1', nymMessageId: 'nym1', groupId: 'g1');
    final msg =
        n.state.messages['group-g1']!.firstWhere((m) => m.id == 'wrap1');
    expect(msg.deliveryStatus, DeliveryStatus.read);
  });

  test('a receipt after the message still advances (no buffer needed)', () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    _restoreOwn(n,
        convKey: 'group-g1', id: 'wrap1', nymMessageId: 'nym1', groupId: 'g1');
    n.applyReceipt(ReceiptInfo(messageId: 'nym1', receiptType: 'delivered'));
    final msg =
        n.state.messages['group-g1']!.firstWhere((m) => m.id == 'wrap1');
    expect(msg.deliveryStatus, DeliveryStatus.delivered);
  });

  test('an own PM echo is indexed on send so a live receipt advances its tick',
      () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.switchView(const ChatView.pm('peer_pk'));
    // The optimistic echo must be indexed by its nymMessageId immediately —
    // receipts are ephemeral, so an unindexed echo would strand the checkmark.
    final echo = n.sendLocal('hello', nymMessageId: 'nymP1');
    expect(echo, isNotNull);
    expect(echo!.deliveryStatus, DeliveryStatus.sent);
    n.applyReceipt(ReceiptInfo(messageId: 'nymP1', receiptType: 'delivered'));
    expect(echo.deliveryStatus, DeliveryStatus.delivered);
    n.applyReceipt(ReceiptInfo(messageId: 'nymP1', receiptType: 'read'));
    expect(echo.deliveryStatus, DeliveryStatus.read);
  });

  test('a group read receipt records the reader avatar (not a checkmark)', () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    _restoreOwn(n,
        convKey: 'group-g3', id: 'wrap3', nymMessageId: 'nym3', groupId: 'g3');
    // A peer reads our group message → a 'read' receipt carrying their pubkey.
    n.applyReceipt(ReceiptInfo(
      messageId: 'nym3',
      receiptType: 'read',
      readerPubkey: 'reader_pk',
    ));
    final msg =
        n.state.messages['group-g3']!.firstWhere((m) => m.id == 'wrap3');
    // Groups show a reader avatar, not a delivery tick.
    expect(msg.readers.containsKey('reader_pk'), isTrue);
    expect(msg.deliveryStatus, isNot(DeliveryStatus.read));
  });

  test('a reaction targeting the shared nymMessageId attaches to the row', () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    // A peer's group message, stored under its wrap id, indexed by nym2.
    _restoreOwn(n,
        convKey: 'group-g2',
        id: 'wrap2',
        nymMessageId: 'nym2',
        groupId: 'g2',
        isOwn: false,
        pubkey: 'peer_pk');
    // The reaction references the SHARED nymMessageId (as the PWA sends it).
    n.ingestEvent(NostrEvent(
      id: 'rx1',
      pubkey: 'reactor_pk',
      createdAt: 1700000001,
      kind: EventKind.reaction,
      tags: const [
        ['e', 'nym2'],
        ['p', 'peer_pk'],
        ['k', '1059'],
      ],
      content: '👍',
    ));
    // The tally must land under the stored Message.id (wrap2), which the row
    // reads — not under the nym2 the reaction referenced.
    final tally = n.state.reactions['wrap2'];
    expect(tally, isNotNull);
    expect(tally!.any((r) => r.emoji == '👍'), isTrue);
  });
}
