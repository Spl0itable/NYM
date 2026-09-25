import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/keys.dart' show randomBytes;
import 'package:nym_bar/features/mesh/mesh_bridge.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/mesh/courier/local_prekeys.dart';
import 'package:nym_bar/services/mesh/mesh_service.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/transport/mesh_transport.dart';
import 'package:nym_bar/services/storage/at_rest_cipher.dart';
import 'package:nym_bar/services/storage/at_rest_wipe.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/services/storage/sealed_key_value.dart';
import 'package:nym_bar/state/settings_provider.dart';

class _KeyStore implements AtRestKeyStore {
  String? value;
  bool locked = false;

  @override
  Future<String?> read() async {
    if (locked) throw StateError('locked');
    return value;
  }

  @override
  Future<void> write(String v) async {
    if (locked) throw StateError('locked');
    value = v;
  }

  @override
  Future<void> delete() async => value = null;
}

class _Transport implements MeshTransport {
  final _inbound = StreamController<MeshInboundFrame>.broadcast();
  final _links = StreamController<MeshLinkEvent>.broadcast();

  @override
  MeshTransportAvailability get availability => MeshTransportAvailability.ready;
  @override
  int get connectedLinkCount => 0;
  @override
  Stream<MeshInboundFrame> get inbound => _inbound.stream;
  @override
  Stream<MeshLinkEvent> get links => _links.stream;
  @override
  Future<void> broadcast(Uint8List frame) async {}
  @override
  Future<MeshTransportAvailability> start() async =>
      MeshTransportAvailability.ready;
  @override
  Future<void> stop() async {}
  @override
  Future<void> openSystemSettings() async {}
}

Future<KeyValueStore> _kv([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  return KeyValueStore.open();
}

Future<String> _prekeyBlob() async {
  final keys = LocalPrekeys();
  await keys.replenish();
  return keys.encode();
}

Future<bool> _waitFor(bool Function() cond) async {
  for (var i = 0; i < 300; i++) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return cond();
}

Future<(MeshService, MeshBridge)> _startBridge(
    KeyValueStore kv, AtRestCipher cipher) async {
  final identity = await NoiseIdentity.fromSeeds(
      staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
  final service = MeshService(
    identity: identity,
    transport: _Transport(),
    nicknameProvider: () => 'bob',
  );
  final serviceProvider = Provider<MeshService>((ref) => service);
  final bridgeProvider = Provider<MeshBridge>((ref) => MeshBridge(
        ref: ref,
        service: ref.read(serviceProvider),
        selfNym: () => 'bob',
        cipher: cipher,
      ));
  final container = ProviderContainer(overrides: [
    keyValueStoreProvider.overrideWithValue(kv),
  ]);
  addTearDown(container.dispose);
  final bridge = container.read(bridgeProvider);
  await bridge.start();
  return (service, bridge);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SealedKeyValue key availability', () {
    test('a locked key reads as locked and never overwrites the value',
        () async {
      final kv = await _kv();
      final keys = _KeyStore();
      final writer = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      writer.write(StorageKeys.leftGroups, '["g1"]');
      await writer.idle;
      final sealed = kv.getString(StorageKeys.leftGroups)!;

      keys.locked = true;
      final store = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      final read = await store.readDetailed(StorageKeys.leftGroups);
      expect(read.status, SealedReadStatus.locked);
      expect(read.value, isNull);
      expect(store.isLocked(StorageKeys.leftGroups), isTrue);

      keys.locked = false;
      store.write(StorageKeys.leftGroups, '[]');
      await store.idle;
      expect(kv.getString(StorageKeys.leftGroups), sealed);

      final again = await store.readDetailed(StorageKeys.leftGroups);
      expect(again.status, SealedReadStatus.sealed);
      expect(again.value, '["g1"]');
      store.write(StorageKeys.leftGroups, '["g1","g2"]');
      await store.idle;
      expect(await store.read(StorageKeys.leftGroups), '["g1","g2"]');
    });

    test('a lost key reads as unreadable and a new value replaces it',
        () async {
      final kv = await _kv();
      final writer = SealedKeyValue(kv, cipher: AtRestCipher(_KeyStore()));
      writer.write(StorageKeys.meshPrekeys, 'old');
      await writer.idle;

      final store = SealedKeyValue(kv, cipher: AtRestCipher(_KeyStore()));
      final read = await store.readDetailed(StorageKeys.meshPrekeys);
      expect(read.status, SealedReadStatus.unreadable);
      expect(read.value, isNull);
      store.write(StorageKeys.meshPrekeys, 'fresh');
      await store.idle;
      expect(await store.read(StorageKeys.meshPrekeys), 'fresh');
    });

    test('plaintext is still returned while the key is locked', () async {
      final kv = await _kv({StorageKeys.leftGroupTimes: '{"g1":5}'});
      final keys = _KeyStore()..locked = true;
      final store = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      final read = await store.readDetailed(StorageKeys.leftGroupTimes);
      expect(read.status, SealedReadStatus.plain);
      expect(read.value, '{"g1":5}');
      await store.idle;
      expect(kv.getString(StorageKeys.leftGroupTimes), '{"g1":5}');
    });

    for (final key in StorageKeys.sealedPrefs) {
      test('migrates plaintext $key and keeps it sealed', () async {
        const legacy = '["legacy-secret"]';
        final kv = await _kv({key: legacy});
        final keys = _KeyStore();
        final store = SealedKeyValue(kv, cipher: AtRestCipher(keys));
        expect(await store.read(key), legacy);
        await store.idle;
        final raw = kv.getString(key)!;
        expect(AtRestCipher.isEncryptedString(raw), isTrue);
        expect(raw.contains('legacy-secret'), isFalse);
        store.write(key, '["next"]');
        await store.idle;
        expect(AtRestCipher.isEncryptedString(kv.getString(key)!), isTrue);
        final fresh = SealedKeyValue(kv, cipher: AtRestCipher(keys));
        expect(await fresh.read(key), '["next"]');
      });
    }
  });

  test('forgetAtRestData removes the sealed prefs', () async {
    final kv = await _kv({
      for (final key in StorageKeys.sealedPrefs) key: 'nymenc:v1:xyz',
      StorageKeys.pendingGroupInvite: 'keep',
    });
    final keys = _KeyStore()..value = 'unused';
    await forgetAtRestData(kv, cipher: AtRestCipher(keys));
    for (final key in StorageKeys.sealedPrefs) {
      expect(kv.getString(key), isNull);
    }
    expect(kv.getString(StorageKeys.pendingGroupInvite), 'keep');
    expect(keys.value, isNull);
  });

  test('outbound settings never read the raw left-group keys', () async {
    final kv = await _kv({
      StorageKeys.leftGroups: 'nymenc:v1:abc',
      StorageKeys.leftGroupTimes: 'nymenc:v1:def',
    });
    final sections = StorageSync.buildSectionPayloads(const Settings(), kv: kv);
    final flat = <String, dynamic>{};
    for (final s in sections.values) {
      flat.addAll(s);
    }
    expect(flat['leftGroups'], isEmpty);
    expect(flat['leftGroupTimes'], isEmpty);
  });

  group('MeshBridge sealed persistence', () {
    test('migrates plaintext prekeys and gossip archive on start', () async {
      final blob = await _prekeyBlob();
      final kv = await _kv({
        StorageKeys.meshPrekeys: blob,
        StorageKeys.meshGossipArchive: '[]',
      });
      final (service, _) = await _startBridge(kv, AtRestCipher(_KeyStore()));
      expect(service.prekeys.keys.length, LocalPrekeys.batchSize);
      expect(
          await _waitFor(() => AtRestCipher.isEncryptedString(
              kv.getString(StorageKeys.meshPrekeys) ?? '')),
          isTrue);
      expect(
          await _waitFor(() => AtRestCipher.isEncryptedString(
              kv.getString(StorageKeys.meshGossipArchive) ?? '')),
          isTrue);
    });

    test('prekey changes are written sealed and read back', () async {
      final kv = await _kv();
      final keys = _KeyStore();
      final (service, _) = await _startBridge(kv, AtRestCipher(keys));
      await service.publishPrekeyBundle();
      expect(
          await _waitFor(() => kv.getString(StorageKeys.meshPrekeys) != null),
          isTrue);
      final raw = kv.getString(StorageKeys.meshPrekeys)!;
      expect(AtRestCipher.isEncryptedString(raw), isTrue);
      expect(raw.contains('priv'), isFalse);
      final ids = service.prekeys.keys.map((k) => k.id).toList();
      final (restored, _) = await _startBridge(kv, AtRestCipher(keys));
      expect(restored.prekeys.keys.map((k) => k.id).toList(), ids);
    });

    test('a locked key neither publishes nor overwrites prekeys', () async {
      final kv = await _kv();
      final keys = _KeyStore();
      final seed = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      final blob = await _prekeyBlob();
      seed.write(StorageKeys.meshPrekeys, blob);
      seed.write(StorageKeys.meshGossipArchive, '[]');
      await seed.idle;
      final sealedPrekeys = kv.getString(StorageKeys.meshPrekeys);
      final sealedArchive = kv.getString(StorageKeys.meshGossipArchive);

      keys.locked = true;
      final (service, _) = await _startBridge(kv, AtRestCipher(keys));
      expect(service.prekeys.keys, isEmpty);
      expect(await service.publishPrekeyBundle(), isFalse);
      expect(service.prekeys.keys, isEmpty);
      service.onPrekeysChanged?.call(service.prekeys.encode());
      service.onGossipArchiveChanged?.call('[]');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(kv.getString(StorageKeys.meshPrekeys), sealedPrekeys);
      expect(kv.getString(StorageKeys.meshGossipArchive), sealedArchive);

      keys.locked = false;
      await service.publishPrekeyBundle();
      expect(
          await _waitFor(
              () => service.prekeys.keys.length == LocalPrekeys.batchSize),
          isTrue);
      final expected = LocalPrekeys()..decode(blob);
      expect(service.prekeys.keys.map((k) => k.id).toList(),
          expected.keys.map((k) => k.id).toList());
    });

    test('a lost key regenerates prekeys under the new key', () async {
      final kv = await _kv();
      final old = SealedKeyValue(kv, cipher: AtRestCipher(_KeyStore()));
      old.write(StorageKeys.meshPrekeys, await _prekeyBlob());
      await old.idle;
      final stale = kv.getString(StorageKeys.meshPrekeys);

      final keys = _KeyStore();
      final (service, _) = await _startBridge(kv, AtRestCipher(keys));
      expect(service.prekeys.keys, isEmpty);
      expect(await service.publishPrekeyBundle(), isTrue);
      expect(service.prekeys.available.length, LocalPrekeys.batchSize);
      expect(
          await _waitFor(() => kv.getString(StorageKeys.meshPrekeys) != stale),
          isTrue);
      final reread = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      final restored = LocalPrekeys()
        ..decode(await reread.read(StorageKeys.meshPrekeys));
      expect(restored.keys.map((k) => k.id).toList(),
          service.prekeys.keys.map((k) => k.id).toList());
    });
  });
}
