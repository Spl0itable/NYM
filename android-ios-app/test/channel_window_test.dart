import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/constants/history_window.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/storage/cache_store.dart';
import 'package:nym_bar/state/app_state.dart';

/// Public channel history is a rolling 24-hour window: `channel-get` floors its
/// query at CHANNEL_TTL_MS and the relay filters ask for `since: now - 86400`,
/// so anything older exists on no other client and cannot be re-fetched by this
/// one either. It is pruned from memory and from the cache rather than shown
/// indefinitely on a single device.

String _hex(int i) => i.toRadixString(16).padLeft(2, '0') * 32;
int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Message _msg(int i,
        {required int createdAt, String? threadRoot, bool isPM = false}) =>
    Message(
      id: _hex(i),
      author: 'alice',
      pubkey: 'alice_pk',
      content: 'm$i',
      createdAt: createdAt,
      threadRoot: threadRoot,
      isPM: isPM,
    );

NostrEvent _channelMsg(int i, int ts, {String? root}) => NostrEvent(
      id: _hex(i),
      pubkey: 'alice_pk',
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'win'],
        ['n', 'alice'],
        if (root != null) ['e', root, '', 'root'],
      ],
      content: 'm$i',
    );

Future<CacheStore> _openStore() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 2),
  );
  final store = CacheStore(db: db);
  await store.initSchema();
  return store;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('the window itself', () {
    test('is 24 hours', () {
      expect(kChannelHistoryMaxAge, const Duration(hours: 24));
      expect(CacheStore.channelHistoryMaxAge, kChannelHistoryMaxAge);
      final floor = channelWindowFloorSec();
      expect(_now - floor, closeTo(86400, 5));
    });

    test('the per-record caps match what app.js assigns, not its fallbacks', () {
      // app.js: this.channelMessageLimit = 1000; this.pmStorageLimit = 1000.
      // These used to mirror the `|| 100` / `|| 500` fallbacks the PWA never
      // reaches, so a phone kept a tenth of the web client's history.
      expect(CacheStore.channelMessageLimit, 1000);
      expect(CacheStore.pmStorageLimit, 1000);
    });
  });

  group('persisted channel history', () {
    test('aged-out messages are not written', () async {
      final store = await _openStore();
      final msgs = [
        _msg(1, createdAt: _now - 90000), // ~25h
        _msg(2, createdAt: _now - 86500),
        _msg(3, createdAt: _now - 3600), // 1h
        _msg(4, createdAt: _now - 60),
      ];
      await store.saveChannelMessages('#win', msgs);
      final loaded = await store.loadChannelMessages('#win');
      expect(loaded.map((m) => m.content), ['m3', 'm4']);
    });

    test('a channel that is entirely aged out has its row deleted', () async {
      final store = await _openStore();
      await store.saveChannelMessages('#stale', [
        _msg(1, createdAt: _now - 90000),
        _msg(2, createdAt: _now - 100000),
      ]);
      expect(await store.loadChannelMessages('#stale'), isEmpty);
      // And the whole-cache read does not resurrect it.
      expect((await store.loadAllChannelMessages()).containsKey('#stale'),
          isFalse);
    });

    test('an old thread ROOT is kept when an in-window reply needs it',
        () async {
      final store = await _openStore();
      final rootId = _hex(1);
      await store.saveChannelMessages('#win', [
        _msg(1, createdAt: _now - 90000),
        _msg(2, createdAt: _now - 600, threadRoot: rootId),
      ]);
      final loaded = await store.loadChannelMessages('#win');
      expect(loaded.any((m) => m.id == rootId), isTrue,
          reason: 'dropping it would reflow the reply inline');
      expect(loaded.length, 2);
    });

    test('a load prunes a row written before the window rule', () async {
      final store = await _openStore();
      // Write straight past saveChannelMessages' filter to simulate an old cache.
      await store.saveChannelMessages('#win', [_msg(9, createdAt: _now - 60)]);
      final all = await store.loadAllChannelMessages();
      expect(all['#win']!.length, 1);
    });

    test('PM history is NOT bounded by the channel window', () async {
      final store = await _openStore();
      final msgs = [
        _msg(1, createdAt: _now - 400000, isPM: true),
        _msg(2, createdAt: _now - 60, isPM: true),
      ];
      await store.savePmMessages('pm-peer', msgs, enabled: true);
      final loaded = await store.loadPmMessages('pm-peer');
      expect(loaded.length, 2,
          reason: 'private history is governed by its own TTL, not this window');
    });

    test('reactions for dropped ids are deleted, others untouched', () async {
      final store = await _openStore();
      await store.saveReactions(_hex(1), [
        ['👍', <dynamic>[]]
      ]);
      await store.saveReactions(_hex(2), [
        ['👍', <dynamic>[]]
      ]);
      await store.deleteReactionsFor([_hex(1)]);
      final left = await store.loadAllReactions();
      expect(left.containsKey(_hex(1)), isFalse);
      expect(left.containsKey(_hex(2)), isTrue);
    });
  });

  group('in-memory prune', () {
    test('drops aged-out channel messages and reports their ids', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestEvent(_channelMsg(1, _now - 90000));
      n.ingestEvent(_channelMsg(2, _now - 3600));
      n.ingestEvent(_channelMsg(3, _now - 60));

      final dropped = n.pruneChannelHistoryWindow();
      expect(dropped, contains(_hex(1)));
      final list = n.state.messages['#win']!;
      expect(list.map((m) => m.content), ['m2', 'm3']);
    });

    test('keeps an aged-out root an in-window reply still needs', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final rootId = _hex(1);
      n.ingestEvent(_channelMsg(1, _now - 90000));
      n.ingestEvent(_channelMsg(2, _now - 600, root: rootId));

      final dropped = n.pruneChannelHistoryWindow();
      expect(dropped, isNot(contains(rootId)));
      expect(n.state.messages['#win']!.any((m) => m.id == rootId), isTrue);
      // With the root present the reply stays collapsed rather than reflowing.
      expect(
          visibleMessagesFor(n.state, '#win').any((m) => m.threadRoot != null),
          isFalse);
    });

    test('a fully in-window channel is left alone', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      for (var i = 1; i <= 5; i++) {
        n.ingestEvent(_channelMsg(i, _now - i * 60));
      }
      expect(n.pruneChannelHistoryWindow(), isEmpty);
      expect(n.state.messages['#win']!.length, 5);
    });

    test('the surviving list stays in ascending order', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final rootId = _hex(1);
      n.ingestEvent(_channelMsg(1, _now - 90000));
      for (var i = 2; i <= 6; i++) {
        n.ingestEvent(_channelMsg(i, _now - (7 - i) * 60, root: rootId));
      }
      n.pruneChannelHistoryWindow();
      final list = n.state.messages['#win']!;
      for (var i = 1; i < list.length; i++) {
        expect(list[i - 1].createdAt <= list[i].createdAt, isTrue);
      }
    });
  });
}
