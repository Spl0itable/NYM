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

  test('a channel reader avatar waterfalls to their newest-seen own message',
      () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    // Two OWN messages in the same named channel, older then newer.
    n.ingestEvent(NostrEvent(
      id: 'cmA',
      pubkey: 'self_pk',
      createdAt: 1000,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room'],
        ['n', 'me'],
      ],
      content: 'first',
    ));
    n.ingestEvent(NostrEvent(
      id: 'cmB',
      pubkey: 'self_pk',
      createdAt: 2000,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room'],
        ['n', 'me'],
      ],
      content: 'second',
    ));
    final a = n.state.messages['#room']!.firstWhere((m) => m.id == 'cmA');
    final b = n.state.messages['#room']!.firstWhere((m) => m.id == 'cmB');
    // A peer reads the OLDER message first → their avatar shows on it.
    n.applyChannelReader(
        messageId: 'cmA', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    expect(a.readers.containsKey('reader_pk'), isTrue);
    expect(b.readers.containsKey('reader_pk'), isFalse);
    // The same peer then reads the NEWER message → the avatar slides off the
    // older one onto the newer one; it must NOT linger on both (the bug).
    n.applyChannelReader(
        messageId: 'cmB', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    expect(a.readers.containsKey('reader_pk'), isFalse,
        reason: 'avatar must not remain on the already-seen older message');
    expect(b.readers.containsKey('reader_pk'), isTrue);
  });

  test('a reader who reads a newer own message BEFORE it lands waterfalls '
      'correctly once it does', () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.ingestEvent(NostrEvent(
      id: 'cx1',
      pubkey: 'self_pk',
      createdAt: 1000,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room2'],
        ['n', 'me'],
      ],
      content: 'first',
    ));
    final older = n.state.messages['#room2']!.firstWhere((m) => m.id == 'cx1');
    // Reads land for both messages, but the newer message hasn't arrived yet.
    n.applyChannelReader(
        messageId: 'cx1', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    n.applyChannelReader(
        messageId: 'cx2', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    // With only the older message present it correctly carries the avatar.
    expect(older.readers.containsKey('reader_pk'), isTrue);
    // The newer message finally lands → the buffered receipt replays and the
    // avatar moves forward onto it, clearing the older one.
    n.ingestEvent(NostrEvent(
      id: 'cx2',
      pubkey: 'self_pk',
      createdAt: 2000,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room2'],
        ['n', 'me'],
      ],
      content: 'second',
    ));
    final newer = n.state.messages['#room2']!.firstWhere((m) => m.id == 'cx2');
    expect(older.readers.containsKey('reader_pk'), isFalse);
    expect(newer.readers.containsKey('reader_pk'), isTrue);
  });

  test('a channel receipt that beats our own echo renders once the optimistic '
      'row reconciles to its real event id', () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.switchView(const ChatView.channel('room3'));
    // We send a message → an optimistic `_optim_*` placeholder, no real id yet.
    final echo = n.sendLocal('hello everyone');
    expect(echo, isNotNull);
    expect(echo!.id.startsWith('_optim_'), isTrue);
    // A reader acks the PUBLISHED event id before our own echo comes back and
    // reconciles the placeholder — the reader is buffered but has no own message
    // to mirror onto yet, so no avatar shows.
    n.applyChannelReader(
        messageId: 'real_evt', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    expect(echo.readers.containsKey('reader_pk'), isFalse);
    // Our own relay echo lands with the real id and reconciles the placeholder
    // in place → the buffered receipt replays and the avatar appears.
    n.ingestEvent(NostrEvent(
      id: 'real_evt',
      pubkey: 'self_pk',
      createdAt: echo.createdAt,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room3'],
        ['n', 'me#0001'],
      ],
      content: 'hello everyone',
    ));
    final reconciled =
        n.state.messages['#room3']!.firstWhere((m) => m.id == 'real_evt');
    expect(reconciled.readers.containsKey('reader_pk'), isTrue,
        reason: 'buffered receipt must render once the row owns its real id');
  });

  test('waterfall is per-conversation: a reader shows in each channel they read',
      () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.ingestEvent(NostrEvent(
      id: 'ra',
      pubkey: 'self_pk',
      createdAt: 1000,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'alpha'],
        ['n', 'me'],
      ],
      content: 'in alpha',
    ));
    n.ingestEvent(NostrEvent(
      id: 'rb',
      pubkey: 'self_pk',
      createdAt: 2000,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'beta'],
        ['n', 'me'],
      ],
      content: 'in beta',
    ));
    // The reader sees our message in BOTH channels; the newer read is in beta.
    n.applyChannelReader(
        messageId: 'ra', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    n.applyChannelReader(
        messageId: 'rb', readerPubkey: 'reader_pk', readerNym: 'r#0001');
    final a = n.state.messages['#alpha']!.firstWhere((m) => m.id == 'ra');
    final b = n.state.messages['#beta']!.firstWhere((m) => m.id == 'rb');
    // Each conversation waterfalls independently, so the avatar shows in both —
    // the newer beta read must NOT hide the alpha avatar.
    expect(a.readers.containsKey('reader_pk'), isTrue);
    expect(b.readers.containsKey('reader_pk'), isTrue);
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
