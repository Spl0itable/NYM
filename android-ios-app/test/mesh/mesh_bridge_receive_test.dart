import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nym_bar/core/crypto/keys.dart' show randomBytes;
import 'package:nym_bar/features/mesh/mesh_bridge.dart';
import 'package:nym_bar/services/mesh/mesh_service.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/transport/mesh_transport.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

/// In-memory radio bus (a trimmed copy of the one in mesh_service_test) so two
/// real MeshServices can exchange frames without hardware.
class RadioBus {
  final List<FakeMeshTransport> _nodes = [];
  final Set<FakeMeshTransport> _started = {};
  void attach(FakeMeshTransport node) => _nodes.add(node);

  void markStarted(FakeMeshTransport node) {
    for (final other in _started) {
      if (other == node) continue;
      node._link(other.id);
      other._link(node.id);
    }
    _started.add(node);
  }

  void broadcastFrom(FakeMeshTransport sender, Uint8List frame) {
    for (final node in _nodes) {
      if (node == sender || !_started.contains(node)) continue;
      node._deliver(Uint8List.fromList(frame), sender.id);
    }
  }
}

class FakeMeshTransport implements MeshTransport {
  FakeMeshTransport(this.bus, this.id) {
    bus.attach(this);
  }
  final RadioBus bus;
  final String id;
  final _inbound = StreamController<MeshInboundFrame>.broadcast();
  final _links = StreamController<MeshLinkEvent>.broadcast();

  void _deliver(Uint8List frame, String fromId) =>
      _inbound.add(MeshInboundFrame(data: frame, linkId: fromId));
  void _link(String peerId) =>
      _links.add(MeshLinkEvent(peerId, MeshLinkChange.connected));

  @override
  MeshTransportAvailability get availability => MeshTransportAvailability.ready;
  @override
  int get connectedLinkCount => bus._nodes.length - 1;
  @override
  Stream<MeshInboundFrame> get inbound => _inbound.stream;
  @override
  Stream<MeshLinkEvent> get links => _links.stream;
  @override
  Future<void> broadcast(Uint8List frame) async =>
      bus.broadcastFrom(this, frame);
  @override
  Future<MeshTransportAvailability> start() async {
    bus.markStarted(this);
    return MeshTransportAvailability.ready;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> openSystemSettings() async {}
}

/// Builds the MeshBridge inside the container so it gets a real Ref.
final _bridgeServiceProvider =
    Provider<MeshService>((ref) => throw UnimplementedError());
final _bridgeProvider = Provider<MeshBridge>((ref) => MeshBridge(
      ref: ref,
      service: ref.read(_bridgeServiceProvider),
      selfNym: () => 'bob',
    ));

Future<bool> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return cond();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The PM notification path plays a sound / posts a local notification, whose
  // plugins have no implementation under `flutter test`. Swallow those platform
  // channel calls so the async fire-and-forget doesn't error after a test ends.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in const [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
    'dexterous.com/flutter/local_notifications',
    'flutter.baseflow.com/permissions/methods',
  ]) {
    messenger.setMockMethodCallHandler(
        MethodChannel(name), (call) async => null);
  }

  test('an inbound #mesh message from a peer lands in the #mesh channel view',
      () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(
        bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');

    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.sendPublicMessage('gm from alice');

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages['#mesh'] ?? const [])
            .any((m) => m.content == 'gm from alice'));

    expect(landed, isTrue,
        reason: 'the #mesh channel store must contain the received message');

    // Open the #mesh channel the way the UI does, and read the EXACT provider
    // the message list widget watches.
    app.switchView(const ChatView.channel('mesh'));
    final shown = container.read(messagesForCurrentViewProvider);
    expect(shown.map((e) => e.content), contains('gm from alice'),
        reason:
            'the received #mesh message must render via messagesForCurrentViewProvider');

    // Let any in-flight delivery-ack / receipt async settle before teardown so
    // it can't complete against a disposed container and cross-fail a sibling.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });

  test('a frame naming a channel the app could not have created falls back to '
      '#mesh', () async {
    // A radio frame names its own channel and that name went straight into the
    // message, with none of the checks the Nostr ingest makes. There is no
    // event kind here to pair a shape against, but the name still has to be one
    // the app could have created — otherwise a peer files a message under a
    // channel that can never exist.
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(
        bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');

    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.sendPublicMessage('junk channel', channel: 'has space');
    await alice.sendPublicMessage('real channel', channel: 'radio');

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages['#mesh'] ?? const [])
            .any((m) => m.content == 'junk channel'));
    expect(landed, isTrue,
        reason: 'the words were still said over the radio — Nearby, not lost');

    final keys = container.read(appStateProvider).messages.keys.toList();
    expect(keys.any((k) => k.contains(' ')), isFalse,
        reason: 'no store key may come from an unsanitised frame');

    final onRadio = await _waitFor(() =>
        (container.read(appStateProvider).messages['#radio'] ?? const [])
            .any((m) => m.content == 'real channel'));
    expect(onRadio, isTrue, reason: 'a legal name still routes to its channel');

    // A named channel is 23333 on the wire, so a reaction to this row carries
    // the same `k` the relay copy would — the row used to hardcode 20000.
    final radio = container.read(appStateProvider).messages['#radio']!.first;
    expect(radio.eventKind, 23333);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });

  test('an inbound mesh PM from a peer lands in its pm-<pubkey> view',
      () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(
        bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');

    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.sendPrivateMessage(bobService.myPeerID, 'secret from alice');

    // The conversation pubkey is derived purely from alice's peerID — the same
    // value the inbound path and the open-DM path both resolve.
    final convo = meshStablePubkeyForPeerId(alice.myPeerID);
    final pmKey = 'pm-$convo';

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages[pmKey] ?? const [])
            .any((m) => m.content == 'secret from alice'));

    expect(landed, isTrue,
        reason: 'the mesh PM must be stored under pm-<peerID-derived-key>');

    // Open the DM the way openPeerDm → switchView does, and read the EXACT
    // provider the message list widget watches.
    app.switchView(ChatView.pm(convo));
    final shown = container.read(messagesForCurrentViewProvider);
    expect(shown.map((e) => e.content), contains('secret from alice'),
        reason:
            'the received mesh PM must render via messagesForCurrentViewProvider');

    // Let any in-flight delivery-ack / receipt async settle before teardown so
    // it can't complete against a disposed container and cross-fail a sibling.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });

  test('a PM arriving before the sender announce still keys the real Noise key',
      () async {
    // Reproduces the runtime "notification but not chat" + #0000 bug: when a
    // PM decrypts before the sender's announce is processed, the peer record
    // has no noisePublicKey yet. The bridge must still key the thread by the
    // real Noise static key (from the live session), NOT the padded pseudo —
    // otherwise the notification opens pm-<pseudo> while the later open-DM
    // opens pm-<realkey>, and the message is invisible.
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(
        bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');
    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Force the pre-announce condition: the peer record exists (from the
    // connection) but has NOT captured alice's announced Noise key yet.
    bobService.peerById(alice.myPeerID)!.noisePublicKey = null;

    await alice.sendPrivateMessage(bobService.myPeerID, 'early bird');

    // The key is peerID-derived, so it's identical regardless of announce /
    // session state — no dependence on the (late-binding) Noise key.
    final convo = 'pm-${meshStablePubkeyForPeerId(alice.myPeerID)}';

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages[convo] ?? const [])
            .any((m) => m.content == 'early bird'));

    expect(landed, isTrue,
        reason: 'PM must key the stable peerID-derived thread pre-announce');
    // The header suffix (last 4 of the pubkey) must be real hex, never #0000.
    expect(convo.endsWith('0000'), isFalse);

    // Let any in-flight delivery-ack / receipt async settle before teardown so
    // it can't complete against a disposed container and cross-fail a sibling.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });

  test('open DM BEFORE handshake, then receive reply — same thread (no split)',
      () async {
    // The exact user sequence: tap a peer to open a DM (no session yet, and we
    // force no announced key), THEN the peer replies (handshake → session, so
    // the reply resolves the REAL Noise key). If openPeerDm and the inbound
    // path disagree, the opened view is empty while the message sits in another
    // thread — "received but only in the notification". They MUST agree.
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(
        bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');
    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Simulate opening the DM before the handshake AND before the announce is
    // captured: no session, no announced key.
    bobService.peerById(alice.myPeerID)!.noisePublicKey = null;
    final openedPubkey =
        bridge.openPeerDm(bobService.peerById(alice.myPeerID)!);
    app.switchView(ChatView.pm(openedPubkey));

    // Now the peer replies — this drives the handshake and resolves the real key.
    await alice.sendPrivateMessage(bobService.myPeerID, 'reply text');

    await _waitFor(
        () => container.read(messagesForCurrentViewProvider).isNotEmpty);

    final shown = container.read(messagesForCurrentViewProvider);
    expect(shown.map((e) => e.content), contains('reply text'),
        reason:
            'the reply must appear in the ALREADY-OPEN DM view — no thread split');

    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });
}
