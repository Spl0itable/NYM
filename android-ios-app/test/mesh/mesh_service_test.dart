import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart' show randomBytes;
import 'package:nym_bar/services/mesh/mesh_constants.dart';
import 'package:nym_bar/services/mesh/mesh_service.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_packet.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_message_identity.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_message_type.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_profile.dart';
import 'package:nym_bar/services/mesh/transport/mesh_transport.dart';

/// An in-memory radio bus: every [FakeMeshTransport] attached to it delivers its
/// broadcasts to all the others, standing in for BLE so the full mesh stack can
/// be exercised without hardware.
class RadioBus {
  final List<FakeMeshTransport> _nodes = [];
  final Set<FakeMeshTransport> _started = {};
  void attach(FakeMeshTransport node) => _nodes.add(node);

  /// Marks [node] started and raises a mutual "connected" link event with every
  /// other started node — exactly what BLE surfaces when two devices link, and
  /// what drives the re-announce that seeds identity on both sides.
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

  /// Every raw frame this node put on the air — lets a test decode exactly what
  /// went out on the wire (recipient, flags, signature) as a peer would see it.
  final List<Uint8List> sentFrames = [];

  void _deliver(Uint8List frame, String fromId) {
    _inbound.add(MeshInboundFrame(data: frame, linkId: fromId));
  }

  void _link(String peerId) {
    _links.add(MeshLinkEvent(peerId, MeshLinkChange.connected));
  }

  @override
  MeshTransportAvailability get availability => MeshTransportAvailability.ready;
  @override
  int get connectedLinkCount => bus._nodes.length - 1;
  @override
  Stream<MeshInboundFrame> get inbound => _inbound.stream;
  @override
  Stream<MeshLinkEvent> get links => _links.stream;
  @override
  Future<void> broadcast(Uint8List frame) async {
    sentFrames.add(Uint8List.fromList(frame));
    bus.broadcastFrom(this, frame);
  }

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

Future<T> _firstEvent<T>(Stream<T> stream,
    {Duration timeout = const Duration(seconds: 5)}) {
  return stream.first.timeout(timeout);
}

void main() {
  // The announce cadence is jittered and stretches while no peer is known.
  // Both of those only stay SAFE while the worst-case gap remains under
  // bitchat's stale-peer timeout — past it, peers drop each other for going
  // quiet and the mesh silently partitions. Pin the relationship so a later
  // tuning change can't cross it unnoticed.
  group('announce cadence', () {
    test('worst-case gap stays under the stale-peer timeout', () {
      final busy = MeshConstants.announceInterval + MeshConstants.announceJitter;
      final idle =
          MeshConstants.announceIntervalIdle + MeshConstants.announceJitter;
      expect(busy, lessThan(MeshConstants.stalePeerTimeout),
          reason: 'a connected peer must never time us out between announces');
      expect(idle, lessThan(MeshConstants.stalePeerTimeout),
          reason: 'the idle cadence must still beat the stale timeout');
    });

    test('jitter cannot invert or zero an interval', () {
      expect(MeshConstants.announceJitter,
          lessThan(MeshConstants.announceInterval),
          reason: 'a spread wider than the interval could schedule at <= 0');
      expect(MeshConstants.announceIntervalIdle,
          greaterThan(MeshConstants.announceInterval),
          reason: 'the idle cadence should be slower, not faster');
    });
  });

  late RadioBus bus;
  late MeshService alice;
  late MeshService bob;
  late FakeMeshTransport aliceTransport;

  setUp(() async {
    bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    aliceTransport = FakeMeshTransport(bus, 'alice');
    alice = MeshService(
      identity: aliceId,
      transport: aliceTransport,
      nicknameProvider: () => 'alice',
    );
    bob = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
      profileProvider: (request) async => MeshProfile(
        nickname: 'bob',
        avatar: request.wantAvatar
            ? Uint8List.fromList(List.generate(3000, (i) => i & 0xFF))
            : null,
        avatarMime: 'image/webp',
      ),
    );
  });

  tearDown(() async {
    await alice.stop();
    await bob.stop();
    alice.dispose();
    bob.dispose();
  });

  test('peers discover each other via signed announcements', () async {
    final bobSeesAlice = _firstEvent(bob.peersStream);
    await alice.start();
    await bob.start();
    final peers = await bobSeesAlice;
    final alicePeer = peers.firstWhere((p) => p.peerID == alice.myPeerID);
    expect(alicePeer.nickname, 'alice');
    expect(alicePeer.isVerified, isTrue,
        reason: 'signed announcement with matching peerID must verify');
  });

  test('public mesh message is delivered as raw UTF-8 (bitchat interop)',
      () async {
    await alice.start();
    await bob.start();
    final received = _firstEvent(bob.onPublicMessage);
    // The public mesh chat carries no channel on the wire — the payload is the
    // raw content string (bitchat's format).
    await alice.sendPublicMessage('gm mesh');
    final msg = await received;
    expect(msg.content, 'gm mesh');
    expect(msg.channel, isNull,
        reason: 'bitchat public mesh messages have no channel field');
    expect(msg.senderPeerID, alice.myPeerID);
    // The sender nickname is resolved from alice's announce (the wire carries
    // none), not from the payload.
    expect(msg.senderNickname, 'alice');
    // The id is content-derived and identical on every device.
    expect(
      msg.messageId,
      MeshMessageIdentity.stableId(
        senderIdHex: alice.myPeerID,
        timestampMs: msg.timestampMs,
        content: 'gm mesh',
      ),
    );
  });

  test(
      'public message is addressed to the BROADCAST recipient (bitchat interop)',
      () async {
    await alice.start();
    await bob.start();
    aliceTransport.sentFrames.clear();

    await alice.sendPublicMessage('gm', channel: null);

    // Find the MESSAGE frame among what alice put on the air (announces also
    // flow). It MUST carry an explicit broadcast recipient (0xFF×8) with
    // HAS_RECIPIENT set — bitchat signs the recipient into the packet, so a
    // null-recipient public message produces a signature bitchat rejects.
    BitchatPacket? messagePacket;
    for (final frame in aliceTransport.sentFrames) {
      final p = BinaryProtocol.decode(frame);
      if (p != null && p.type == MeshMessageType.message) {
        messagePacket = p;
        break;
      }
    }
    expect(messagePacket, isNotNull,
        reason: 'a public MESSAGE frame must have been broadcast');
    expect(messagePacket!.recipientID, isNotNull,
        reason: 'HAS_RECIPIENT must be set (not a null recipient)');
    expect(messagePacket.recipientID, equals(kBroadcastRecipient));
    expect(messagePacket.isBroadcast, isTrue);
    expect(messagePacket.signature, isNotNull,
        reason: 'bitchat broadcast messages are signed');
  });

  test('private message completes a Noise handshake and delivers + acks',
      () async {
    await alice.start();
    await bob.start();
    // Let announcements propagate so peers are known.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobReceives = _firstEvent(bob.onPrivateMessage);
    final aliceGetsAck = _firstEvent(alice.onReceipt);

    final messageId = await alice.sendPrivateMessage(bob.myPeerID, 'secret hi');

    final pm = await bobReceives;
    expect(pm.content, 'secret hi');
    expect(pm.messageId, messageId);
    expect(pm.senderPeerID, alice.myPeerID);

    // Bob auto-sends a delivery ack back to Alice over the same session.
    final ack = await aliceGetsAck;
    expect(ack.messageId, messageId);
    expect(ack.isRead, isFalse);
  });

  test('long private message is chunked and fully reassembled in order',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 600 bytes forces 3 chunks (255-byte PM content cap).
    final long =
        List.generate(600, (i) => String.fromCharCode(97 + i % 26)).join();

    final chunks = <String>[];
    final done = Completer<void>();
    final sub = bob.onPrivateMessage.listen((m) {
      chunks.add(m.content);
      if (chunks.join().length >= long.length) done.complete();
    });

    await alice.sendPrivateMessage(bob.myPeerID, long);
    await done.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    expect(chunks.join(), long);
  });

  test('a completed handshake authenticates private-media in both directions',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Establish a Noise session (any encrypted send triggers the handshake).
    await alice.sendPrivateMessage(bob.myPeerID, 'hi');
    // Let the handshake complete and the authenticatedPeerState (0x21) proofs
    // cross in both directions.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Each side now knows the other advertises the privateMedia capability, so
    // bitchat would stop warning that our client can't receive encrypted media.
    expect(bob.peerById(alice.myPeerID)?.supportsPrivateMedia, isTrue);
    expect(alice.peerById(bob.myPeerID)?.supportsPrivateMedia, isTrue);
  });

  test('reaction NoisePayloadType does not collide with bitchat 0x21', () {
    // bitchat uses NoisePayloadType 0x21 for authenticatedPeerState, which it
    // emits over the Noise session right after a handshake. Our reaction type
    // MUST NOT share it, or we decode that peer-state frame as a reaction and
    // stamp a phantom emoji on a just-sent message.
    expect(NoisePayloadType.reaction, isNot(0x21));
    expect(NoisePayloadType.reaction, 0x70);
    // Types intentionally shared with bitchat stay aligned.
    expect(NoisePayloadType.privateMessage, 0x01);
    expect(NoisePayloadType.readReceipt, 0x02);
    expect(NoisePayloadType.delivered, 0x03);
    expect(NoisePayloadType.fileTransfer, 0x20);
  });

  test('encrypted group message is readable only by members with the password',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.setChannelPassword('#crew', 'sharedpass');
    await bob.setChannelPassword('#crew', 'sharedpass');

    final bobGets = _firstEvent(bob.onPublicMessage);
    await alice.sendPublicMessage('meet at 8', channel: '#crew');

    final msg = await bobGets;
    expect(msg.channel, '#crew');
    expect(msg.content, 'meet at 8'); // decrypted with the shared key
    expect(msg.senderPeerID, alice.myPeerID);
  });

  test('encrypted group message is dropped by a non-member', () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Only alice has the key; bob never joins the channel.
    await alice.setChannelPassword('#secret', 'pw');
    var received = false;
    final sub = bob.onPublicMessage.listen((_) => received = true);
    await alice.sendPublicMessage('classified', channel: '#secret');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    expect(received, isFalse); // undecryptable → not surfaced
  });

  test(
      'a plaintext NAMED channel message keeps its channel (not folded to #mesh)',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A named channel with NO password: content rides plaintext in the
    // nymChannelMessage TLV, and the channel name must survive so it routes to
    // #r1 on the receiver instead of collapsing into the #mesh public chat.
    final bobGets = _firstEvent(bob.onPublicMessage);
    await alice.sendPublicMessage('room one', channel: '#r1');
    final msg = await bobGets;
    expect(msg.content, 'room one');
    expect(msg.channel, '#r1');
    expect(msg.senderPeerID, alice.myPeerID);
  });

  test('a file/media DM transfers encrypted and fragmented to the peer',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobGetsFile = _firstEvent(bob.onFile);
    final bytes =
        Uint8List.fromList(List.generate(5000, (i) => (i * 3) & 0xFF));
    await alice.sendFileToPeer(bob.myPeerID, 'photo.webp', 'image/webp', bytes);

    final file = await bobGetsFile;
    expect(file.fromPeerID, alice.myPeerID);
    expect(file.fileName, 'photo.webp');
    expect(file.mimeType, 'image/webp');
    expect(file.isImage, isTrue);
    expect(file.bytes, equals(bytes)); // encrypted + fragmented, then rejoined
  });

  test('a channel emoji reaction is broadcast to peers', () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobGets = _firstEvent(bob.onReaction);
    await alice.sendChannelReaction('msg-123', '👍', false);

    final r = await bobGets;
    expect(r.senderPeerID, alice.myPeerID);
    expect(r.targetId, 'msg-123');
    expect(r.emoji, '👍');
    expect(r.isRemove, isFalse);
    expect(r.isDirect, isFalse);
  });

  test('a 1:1 emoji reaction is delivered encrypted to the peer', () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobGets = _firstEvent(bob.onReaction);
    await alice.sendPrivateReaction(bob.myPeerID, 'dm-77', '❤️', false);

    final r = await bobGets;
    expect(r.senderPeerID, alice.myPeerID);
    expect(r.targetId, 'dm-77');
    expect(r.emoji, '❤️');
    expect(r.isDirect, isTrue); // arrived over the Noise session
  });

  test('a broadcast file is delivered to nearby peers as a public attachment',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobGetsFile = _firstEvent(bob.onFile);
    final bytes =
        Uint8List.fromList(List.generate(4096, (i) => (i * 7) & 0xFF));
    await alice.sendFileBroadcast('meme.gif', 'image/gif', bytes);

    final file = await bobGetsFile;
    expect(file.fromPeerID, alice.myPeerID);
    expect(file.fileName, 'meme.gif');
    expect(file.mimeType, 'image/gif');
    expect(file.isDirect, isFalse); // public/broadcast, not a DM
    expect(file.bytes, equals(bytes));
  });

  test('profile request transfers a fragmented avatar back to the requester',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final received = _firstEvent(alice.onProfile);
    await alice.requestProfile(bob.myPeerID);

    final event = await received;
    expect(event.peerID, bob.myPeerID);
    expect(event.profile.nickname, 'bob');
    // 3000-byte avatar exceeds the 512-byte fragment threshold, so this also
    // proves fragmentation + reassembly end to end.
    expect(event.profile.avatar, isNotNull);
    expect(event.profile.avatar!.length, 3000);
    expect(event.profile.avatarMime, 'image/webp');
  });
}
