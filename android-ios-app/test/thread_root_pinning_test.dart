import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/constants/history_window.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/storage/cache_store.dart';
import 'package:nym_bar/state/app_state.dart';

/// Both windows a conversation passes through — the in-memory retention cap and
/// the persisted last-N slice — are plain front trims. A thread ROOT older than
/// the window therefore falls out while its replies stay, and a reply whose root
/// is gone reflows INLINE, as though it were a top-level message, with a thread
/// affordance that dead-ends: `visibleMessages` only collapses a reply whose
/// root is present locally. Both windows must pin the roots their kept messages
/// still reference (PWA `persistence.js#_withPinnedThreadRoots`).

String _hex(int i) => i.toRadixString(16).padLeft(2, '0') * 32;

NostrEvent _channelMsg(int i, int ts, {String? root}) => NostrEvent(
      id: _hex(i),
      pubkey: 'alice_pk',
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'flood'],
        ['n', 'alice'],
        if (root != null) ['e', root, '', 'root'],
      ],
      content: 'm$i',
    );

/// Channel fixtures must sit inside the rolling 24-hour window
/// ([kChannelHistoryMaxAge]) or the persisted-window tests would be measuring
/// the age prune instead of the count cap. [createdAt] is an offset in seconds
/// from a base an hour ago.
int get _base => (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 3600;

Message _msg(int i, {required int createdAt, String? threadRoot, String? nymMessageId, bool isPM = false}) =>
    Message(
      id: _hex(i),
      author: 'alice',
      pubkey: 'alice_pk',
      content: 'm$i',
      createdAt: _base + createdAt,
      threadRoot: threadRoot,
      nymMessageId: nymMessageId,
      isPM: isPM,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('in-memory channel cap', () {
    const cap = 1000; // mirrors AppStateNotifier._kChannelHistoryCap
    const key = '#flood';
    final base = 1000000000;

    // A root can only be PINNED while it is still in the list, so the case that
    // matters is a long-lived thread: replies keep landing while the flood
    // pushes the root's own age past the cap.
    void floodWithThread(AppStateNotifier n, String rootId) {
      n.ingestEvent(_channelMsg(1, base));
      for (var i = 2; i < cap + 400; i++) {
        n.ingestEvent(i % 100 == 0
            ? _channelMsg(i, base + i, root: rootId)
            : _channelMsg(i, base + i));
      }
    }

    test('keeps a thread root the surviving window still replies to', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final rootId = _hex(1);
      floodWithThread(n, rootId);

      final list = n.state.messages[key]!;
      expect(list.any((m) => m.id == rootId), isTrue,
          reason: 'the root the kept replies point at is pinned, not evicted');

      // And with the root present, the replies stay collapsed instead of
      // reflowing inline as top-level messages.
      final visible = visibleMessagesFor(n.state, key);
      expect(visible.any((m) => m.id == rootId), isTrue);
      expect(visible.any((m) => m.threadRoot == rootId), isFalse);
    });

    test('the pinned root does not defeat the cap for everything else', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      floodWithThread(n, _hex(1));
      final list = n.state.messages[key]!;
      // One pinned root on top of the cap — the ordinary overflow is still gone.
      expect(list.length, cap + 1);
      expect(list.any((m) => m.content == 'm2'), isFalse);
      // Still ascending by timestamp (the pinned root is the oldest).
      for (var i = 1; i < list.length; i++) {
        expect(list[i - 1].createdAt <= list[i].createdAt, isTrue);
      }
    });

    test('a root stops being pinned once its last reply ages out', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final rootId = _hex(1);
      n.ingestEvent(_channelMsg(1, base));
      n.ingestEvent(_channelMsg(2, base + 2, root: rootId));
      for (var i = 3; i < cap * 2; i++) {
        n.ingestEvent(_channelMsg(i, base + i));
      }
      final list = n.state.messages[key]!;
      expect(list.any((m) => m.id == rootId), isFalse,
          reason: 'nothing in the window references it any more');
      expect(list.length, cap);
    });

    test('a channel with no threads caps exactly as before', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      for (var i = 0; i < cap + 500; i++) {
        n.ingestEvent(_channelMsg(i, base + i));
      }
      final list = n.state.messages[key]!;
      expect(list.length, cap);
      expect(list.first.content, 'm500');
    });
  });

  group('persisted window', () {
    Future<CacheStore> openStore() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 2),
      );
      final store = CacheStore(db: db);
      await store.initSchema();
      return store;
    }

    test('a channel root outside the last-N slice is pinned into it', () async {
      final store = await openStore();
      final rootId = _hex(1);
      // Sized off the constant so the fixture keeps overflowing the slice if
      // the cap moves again.
      final n = CacheStore.channelMessageLimit + 100;
      final msgs = <Message>[
        _msg(1, createdAt: 1000),
        for (var i = 2; i < n; i++) _msg(i, createdAt: 1000 + i),
        for (var i = n; i < n + 5; i++) _msg(i, createdAt: 1000 + i, threadRoot: rootId),
      ];
      await store.saveChannelMessages('#flood', msgs);

      final loaded = await store.loadChannelMessages('#flood');
      expect(loaded.any((m) => m.id == rootId), isTrue,
          reason: 'the root survives the last-100 slice its replies fell inside');
      expect(loaded.length, CacheStore.channelMessageLimit + 1);
      expect(loaded.first.id, rootId, reason: 'pinned in front, oldest-first');
    });

    test('a PM root is pinned by its shared nymMessageId', () async {
      final store = await openStore();
      final rootShared = _hex(0x40);
      final n = CacheStore.pmStorageLimit + 100;
      final msgs = <Message>[
        _msg(1, createdAt: 1000, nymMessageId: rootShared, isPM: true),
        for (var i = 2; i < n; i++) _msg(i, createdAt: 1000 + i, isPM: true),
        for (var i = n; i < n + 5; i++)
          _msg(i, createdAt: 1000 + i, threadRoot: rootShared, isPM: true),
      ];
      await store.savePmMessages('pm-peer', msgs, enabled: true);

      final loaded = await store.loadPmMessages('pm-peer');
      expect(loaded.any((m) => m.nymMessageId == rootShared), isTrue);
      expect(loaded.length, CacheStore.pmStorageLimit + 1);
    });

    test('a history that fits the window is written unchanged', () async {
      final store = await openStore();
      final rootId = _hex(1);
      final msgs = <Message>[
        _msg(1, createdAt: 1000),
        _msg(2, createdAt: 1010, threadRoot: rootId),
      ];
      await store.saveChannelMessages('#small', msgs);
      final loaded = await store.loadChannelMessages('#small');
      expect(loaded.length, 2);
      expect(loaded.first.id, rootId);
    });

    test('a trimmed history with no threads keeps the plain last-N slice', () async {
      final store = await openStore();
      final over = 50;
      final n = CacheStore.channelMessageLimit + over;
      final msgs = [for (var i = 0; i < n; i++) _msg(i, createdAt: 1000 + i)];
      await store.saveChannelMessages('#flat', msgs);
      final loaded = await store.loadChannelMessages('#flat');
      expect(loaded.length, CacheStore.channelMessageLimit);
      expect(loaded.first.id, _hex(over));
    });
  });
}
