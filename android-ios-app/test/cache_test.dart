import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/storage/cache_store.dart';

Message _msg(String id, {int createdAt = 0, bool isPM = false}) => Message(
      id: id,
      author: 'alice',
      pubkey: 'pk_$id',
      content: 'body $id',
      createdAt: createdAt,
      isPM: isPM,
    );

/// Open a fresh in-memory CacheStore backed by sqflite_common_ffi.
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

  group('channel messages', () {
    test('save/load round-trips', () async {
      final store = await _openStore();
      final msgs = [
        _msg('a', createdAt: 10),
        _msg('b', createdAt: 20),
        _msg('c', createdAt: 30),
      ];
      await store.saveChannelMessages('#nymchat', msgs);

      final loaded = await store.loadChannelMessages('#nymchat');
      expect(loaded.length, 3);
      expect(loaded.map((m) => m.id), ['a', 'b', 'c']);
      expect(loaded[1].createdAt, 20);
      expect(loaded[2].content, 'body c');
      await store.close();
    });

    test('trims to the per-channel limit, keeping the newest', () async {
      final store = await _openStore();
      final n = CacheStore.channelMessageLimit + 25; // 125
      final msgs = [
        for (var i = 0; i < n; i++) _msg('m$i', createdAt: i),
      ];
      await store.saveChannelMessages('#big', msgs);

      final loaded = await store.loadChannelMessages('#big');
      expect(loaded.length, CacheStore.channelMessageLimit); // 100
      // slice(-limit): the last `limit` messages are retained.
      expect(loaded.first.id, 'm25');
      expect(loaded.last.id, 'm${n - 1}');
      await store.close();
    });

    test('empty list deletes the record', () async {
      final store = await _openStore();
      await store.saveChannelMessages('#x', [_msg('a')]);
      expect((await store.loadChannelMessages('#x')).length, 1);
      await store.saveChannelMessages('#x', []);
      expect(await store.loadChannelMessages('#x'), isEmpty);
      await store.close();
    });
  });

  group('pm messages', () {
    test('NOT written when enabled=false', () async {
      final store = await _openStore();
      await store.savePmMessages('peer', [_msg('p', isPM: true)],
          enabled: false);
      expect(await store.loadPmMessages('peer'), isEmpty);
      await store.close();
    });

    test('written when enabled=true and round-trips', () async {
      final store = await _openStore();
      final msgs = [
        _msg('p1', createdAt: 5, isPM: true),
        _msg('p2', createdAt: 6, isPM: true),
      ];
      await store.savePmMessages('peer', msgs, enabled: true);
      final loaded = await store.loadPmMessages('peer');
      expect(loaded.map((m) => m.id), ['p1', 'p2']);
      expect(loaded.every((m) => m.isPM), isTrue);
      await store.close();
    });

    test('trims to pmStorageLimit', () async {
      final store = await _openStore();
      final n = CacheStore.pmStorageLimit + 10; // 510
      final msgs = [
        for (var i = 0; i < n; i++) _msg('p$i', createdAt: i, isPM: true),
      ];
      await store.savePmMessages('peer', msgs, enabled: true);
      final loaded = await store.loadPmMessages('peer');
      expect(loaded.length, CacheStore.pmStorageLimit);
      expect(loaded.last.id, 'p${n - 1}');
      await store.close();
    });
  });

  group('profiles', () {
    test('save/load round-trips with kind0Ts', () async {
      final store = await _openStore();
      final profile = UserProfile(
        name: 'alice',
        displayName: 'Alice',
        about: 'hi',
        picture: 'https://e/x.png',
        lud16: 'a@b.com',
        kind0Ts: 1717000000,
      );
      await store.saveProfile('pk1', profile);

      final loaded = await store.loadProfile('pk1');
      expect(loaded, isNotNull);
      expect(loaded!.name, 'alice');
      expect(loaded.displayName, 'Alice');
      expect(loaded.picture, 'https://e/x.png');
      expect(loaded.lud16, 'a@b.com');
      expect(loaded.kind0Ts, 1717000000);

      final all = await store.loadAllProfiles();
      expect(all.keys, contains('pk1'));
      expect(all['pk1']!.kind0Ts, 1717000000);
      await store.close();
    });
  });

  group('reactions', () {
    test('save/loadAll round-trips entries shape', () async {
      final store = await _openStore();
      // [[emoji, [[reactor, value], ...]], ...]
      final entries = [
        ['👍', [['pkA', 1], ['pkB', 1]]],
        ['🔥', [['pkC', 1]]],
      ];
      await store.saveReactions('msg1', entries);
      final all = await store.loadAllReactions();
      expect(all.keys, contains('msg1'));
      expect((all['msg1']!.first as List).first, '👍');
      await store.close();
    });
  });

  group('meta set', () {
    test('round-trips', () async {
      final store = await _openStore();
      final ids = {'id1', 'id2', 'id3'};
      await store.saveMetaSet(CacheStore.metaProcessedPmEventIds, ids);
      final loaded =
          await store.loadMetaSet(CacheStore.metaProcessedPmEventIds);
      expect(loaded, ids);
      await store.close();
    });

    test('empty set deletes the record', () async {
      final store = await _openStore();
      await store.saveMetaSet('k', {'a'});
      await store.saveMetaSet('k', <String>{});
      expect(await store.loadMetaSet('k'), isEmpty);
      await store.close();
    });
  });

  group('enforceLruLimits', () {
    test('evicts oldest beyond the store limit, trimming to 90%', () async {
      final store = await _openStore();
      const limit = 50; // channels limit
      final over = limit + 20; // 70
      // Insert channels with strictly increasing lastTouched by spacing writes.
      for (var i = 0; i < over; i++) {
        await store.saveChannelMessages('#c$i', [_msg('m$i')]);
      }

      await store.enforceLruLimits();

      // Count remaining channels.
      final remaining = <int>[];
      for (var i = 0; i < over; i++) {
        if ((await store.loadChannelMessages('#c$i')).isNotEmpty) {
          remaining.add(i);
        }
      }
      // Trimmed to floor(limit * 0.9) = 45.
      expect(remaining.length, (limit * 0.9).floor());
      // Oldest (#c0..) evicted; newest retained.
      expect(remaining.contains(0), isFalse);
      expect(remaining.contains(over - 1), isTrue);
      await store.close();
    });

    test('does not evict when under the limit', () async {
      final store = await _openStore();
      for (var i = 0; i < 10; i++) {
        await store.saveChannelMessages('#c$i', [_msg('m$i')]);
      }
      await store.enforceLruLimits();
      for (var i = 0; i < 10; i++) {
        expect((await store.loadChannelMessages('#c$i')).isNotEmpty, isTrue);
      }
      await store.close();
    });
  });
}
