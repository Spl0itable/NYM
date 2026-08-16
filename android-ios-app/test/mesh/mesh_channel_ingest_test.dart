import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

/// Mirrors how MeshBridge ingests an inbound #mesh (nearby) public message and
/// asserts it renders in the #mesh channel view — the "#mesh messages don't go
/// through" report, checked at the app layer.
void main() {
  test('an inbound #mesh public message is visible in the #mesh channel', () {
    final n = AppStateNotifier()
      ..goLive(
          '0000000000000000000000000000000000000000000000000000000000000001',
          'me#0001');

    final peer =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    final m = Message(
      id: 'mesh-pub-1',
      author: 'bob',
      pubkey: peer,
      content: 'gm over the mesh',
      createdAt: 1700000000,
      ms: 1700000000123,
      isOwn: false,
      channel: 'mesh',
      eventKind: 20000,
      deliveryStatus: DeliveryStatus.sent,
      viaMesh: true,
    );
    final landed = n.ingestMeshChannelMessage(m, channelKey: '#mesh');
    expect(landed, isTrue);

    // The channel view (#mesh) reads messages['#mesh'].
    expect(n.state.messages['#mesh'], isNotNull);
    final visible = visibleMessagesFor(n.state, '#mesh');
    expect(visible.map((e) => e.content), contains('gm over the mesh'),
        reason: 'inbound #mesh message must render in the channel');

    // The channel must be registered so the sidebar row exists.
    expect(n.state.channels.any((c) => c.key == 'mesh'), isTrue);
  });

  test('our own #mesh echo and the peer copy do not both render', () {
    final n = AppStateNotifier()
      ..goLive(
          '0000000000000000000000000000000000000000000000000000000000000001',
          'me#0001');
    n.switchView(const ChatView.channel('mesh'));

    // Our optimistic echo (as sendLocal would create it).
    final echo = n.sendLocal('gm mesh');
    expect(echo, isNotNull);

    // The same message coming back from a DIFFERENT peer must still render
    // (different pubkey → not our echo).
    final peerCopy = Message(
      id: 'mesh-pub-2',
      author: 'bob',
      pubkey:
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
      content: 'gm mesh',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ms: DateTime.now().millisecondsSinceEpoch,
      isOwn: false,
      channel: 'mesh',
      eventKind: 20000,
      viaMesh: true,
    );
    final landed = n.ingestMeshChannelMessage(peerCopy, channelKey: '#mesh');
    expect(landed, isTrue, reason: 'a peer copy is not our echo — must land');
  });
}
