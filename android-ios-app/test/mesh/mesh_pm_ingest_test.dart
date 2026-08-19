import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/mesh/mesh_bridge.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

/// Reproduces exactly how MeshBridge builds and ingests an inbound 1:1 mesh PM
/// (an unlinked peer, so the pubkey is a 64-hex Noise-key pseudo-pubkey), then
/// asserts it is visible in that PM view — the "PM shows in the notification
/// modal but not in the chat" bug.
void main() {
  test('an inbound mesh PM is visible in its pm-<pubkey> view', () {
    final n = AppStateNotifier()
      ..goLive(
          '0000000000000000000000000000000000000000000000000000000000000001',
          'me#0001');

    // A Noise-static-key pseudo-pubkey (not a real Nostr key) for an unlinked
    // mesh peer.
    final peer =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    final key = 'pm-$peer';

    final m = Message(
      id: 'mesh-msg-1',
      author: 'bob',
      pubkey: peer,
      content: 'hi over the mesh',
      createdAt: 1700000000,
      ms: 1700000000123,
      isOwn: false,
      isPM: true,
      conversationKey: key,
      conversationPubkey: peer,
      nymMessageId: 'mesh-msg-1',
      eventKind: 1059,
      senderVerified: true,
      deliveryStatus: DeliveryStatus.delivered,
      viaMesh: true,
    );
    n.ingestPMMessage(m);

    // Stored under the pm-<pubkey> key…
    expect(n.state.messages[key], isNotNull,
        reason: 'message must be stored under the pm-<pubkey> key');
    expect(n.state.messages[key]!.map((e) => e.content),
        contains('hi over the mesh'));

    // …and visible (not spam/WoT-filtered) when that PM view is active.
    final visible = visibleMessagesFor(n.state, key);
    expect(visible.map((e) => e.content), contains('hi over the mesh'),
        reason: 'inbound mesh PM must render in the chat, not be filtered out');

    // A conversation row must exist for the sidebar.
    expect(n.state.pmConversations.any((c) => c.pubkey == peer), isTrue);
  });

  test('a mesh message bypasses the spam heuristic AND the web-of-trust gate',
      () {
    // The confirmed root cause of "received but only in the notification": the
    // heuristic spam filter / WoT gate (built for open Nostr relays) hid every
    // received mesh message, because a Bluetooth peer is never a friend / known
    // nymchat identity. A viaMesh message must be exempt from BOTH.
    final prevGate = nymVouchSpamGateEnabled;
    nymVouchSpamGateEnabled = true; // worst case: WoT gate ON
    addTearDown(() => nymVouchSpamGateEnabled = prevGate);

    final n = AppStateNotifier()
      ..goLive(
          '0000000000000000000000000000000000000000000000000000000000000001',
          'me#0001');

    const peer =
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
    final key = 'pm-$peer';
    // Content that also trips the heuristic spam scorer (a long random token),
    // from a stranger the WoT gate would otherwise hide — both gates would fire.
    const spammy = 'Xq7Zk9wPq2Vx8Jz4Kf6Lm3Np5Rt1Bd0Cg';

    n.ingestPMMessage(Message(
      id: 'mesh-spam-1',
      author: 'stranger',
      pubkey: peer,
      content: spammy,
      createdAt: 1700000000,
      ms: 1700000000123,
      isOwn: false,
      isPM: true,
      conversationKey: key,
      conversationPubkey: peer,
      nymMessageId: 'mesh-spam-1',
      eventKind: 1059,
      senderVerified: true,
      deliveryStatus: DeliveryStatus.delivered,
      viaMesh: true,
    ));

    expect(visibleMessagesFor(n.state, key).map((e) => e.content),
        contains(spammy),
        reason: 'a viaMesh message must never be spam/WoT filtered');

    // Control: the SAME content NOT over mesh IS filtered (proves the exemption
    // is what saved it, not lenient filters).
    const nonMeshKey = 'pm-'
        'abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabca0';
    n.ingestPMMessage(Message(
      id: 'nostr-spam-1',
      author: 'stranger',
      pubkey:
          'abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabca0',
      content: spammy,
      createdAt: 1700000001,
      ms: 1700000001123,
      isOwn: false,
      isPM: true,
      conversationKey: nonMeshKey,
      conversationPubkey:
          'abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabca0',
      nymMessageId: 'nostr-spam-1',
      eventKind: 1059,
      deliveryStatus: DeliveryStatus.delivered,
    ));
    expect(visibleMessagesFor(n.state, nonMeshKey), isEmpty,
        reason: 'the same stranger spam over Nostr is still gated');
  });

  // Mesh PMs are keyed by a stable pubkey derived purely from the peerID (see
  // meshStablePubkeyForPeerId / MeshBridge._pubkeyForPeerId's resolve-once
  // cache). The peerID is in every packet and known from first contact, so the
  // inbound-message path and the open-DM path can never key different threads
  // (the Noise key binds late — after the handshake — and split the thread).
  group('meshStablePubkeyForPeerId — deterministic PM keying', () {
    test('is a stable, full-entropy, lowercase 64-hex key from the peerID', () {
      const peerId = 'A1B2C3D4E5F60718';
      final k = meshStablePubkeyForPeerId(peerId);
      expect(k.length, 64);
      expect(k, equals(k.toLowerCase()));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(k), isTrue);
      // Full-entropy hash → a real (non-0000) display suffix in the PM header.
      expect(k.endsWith('0000'), isFalse);
      // Same peerID → same key on every call (inbound == open-DM == notify).
      expect(meshStablePubkeyForPeerId(peerId), equals(k));
      // Case-insensitive on the peerID (senderID hex casing must not fork it).
      expect(meshStablePubkeyForPeerId(peerId.toLowerCase()), equals(k));
    });

    test('distinct peers get distinct keys', () {
      expect(meshStablePubkeyForPeerId('1111111111111111'),
          isNot(equals(meshStablePubkeyForPeerId('2222222222222222'))));
    });
  });
}
