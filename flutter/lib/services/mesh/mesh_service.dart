import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'dedup.dart';
import 'fragmentation.dart';
import 'mesh_constants.dart';
import 'mesh_events.dart';
import 'mesh_peer.dart';
import 'noise/channel_encryption.dart';
import 'noise/noise_crypto.dart';
import 'noise/noise_identity.dart';
import 'noise/noise_session_manager.dart';
import 'noise/nostr_link.dart';
import 'protocol/authenticated_peer_state.dart';
import 'protocol/bitchat_file_packet.dart';
import 'protocol/bitchat_message.dart';
import 'protocol/bitchat_packet.dart';
import 'protocol/fragment_payload.dart';
import 'protocol/identity_announcement.dart';
import 'protocol/mesh_message_identity.dart';
import 'protocol/mesh_diagnostics_packets.dart';
import 'protocol/mesh_message_type.dart';
import 'protocol/nostr_carrier_packet.dart';
import 'courier/courier_envelope.dart';
import 'courier/local_prekeys.dart';
import 'courier/prekey_bundle.dart';
import 'courier/courier_store.dart';
import 'sync/gossip_sync.dart';
import 'sync/request_sync_packet.dart';
import 'protocol/mesh_profile.dart';
import 'protocol/noise_payload.dart';
import 'transport/mesh_transport.dart';

/// Bluetooth mesh core: radio, Noise sessions, peers, dedup, relay and fragmentation, byte-compatible with bitchat.
class MeshService {
  MeshService({
    required this.identity,
    required this._transport,
    required this._nicknameProvider,
    this._nostrLinkProvider,
    this._profileProvider,
  });

  final NoiseIdentity identity;
  final MeshTransport _transport;
  final String Function() _nicknameProvider;

  /// Supplies our [NostrLink] to advertise, or null without a local Nostr key.
  final Uint8List? Function()? _nostrLinkProvider;

  /// Builds our [MeshProfile] for an inbound request; null when there is none to share.
  final Future<MeshProfile?> Function(MeshProfileRequest request)?
      _profileProvider;

  late final NoiseSessionManager _noise = NoiseSessionManager(identity);
  final MeshChannelEncryption _channelCrypto = MeshChannelEncryption();
  final SeenPackets _seen = SeenPackets();
  final FragmentReassembler _reassembler = FragmentReassembler();
  final _uuid = const Uuid();
  final _random = Random();

  final Map<String, MeshPeer> _peers = {};

  /// Plaintext owed to a peer, queued until the Noise session establishes.
  final Map<String, List<Uint8List>> _pendingPlaintext = {};

  /// Encrypted frames that beat our own handshake completion; drained on establish.
  final Map<String, List<Uint8List>> _pendingEncrypted = {};

  final _publicMessages = StreamController<MeshPublicMessage>.broadcast();
  final _privateMessages = StreamController<MeshPrivateMessage>.broadcast();
  final _receipts = StreamController<MeshReceipt>.broadcast();
  final _profiles = StreamController<MeshProfileReceived>.broadcast();
  final _files = StreamController<MeshFileReceived>.broadcast();
  final _typing = StreamController<MeshTypingEvent>.broadcast();
  final _reactions = StreamController<MeshReactionEvent>.broadcast();
  final _peersChanged = StreamController<List<MeshPeer>>.broadcast();

  /// Peers already asked for a profile, so announce beacons don't re-request.
  final Set<String> _profileRequested = {};

  StreamSubscription<MeshInboundFrame>? _inboundSub;
  StreamSubscription<MeshLinkEvent>? _linkSub;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  Timer? _syncTimer;
  bool _running = false;

  /// Recent public history reconciled with neighbors; policy lives in [GossipSync].
  final GossipSync gossip = GossipSync();

  /// Mail carried for other peers; policy lives in [CourierStore].
  final CourierStore couriers = CourierStore();

  /// Ghost Mode state; a ghosted device never deposits courier mail.
  bool Function()? isGhostMode;

  /// Whether a conversation is mesh-pinned from a ghost identity; such mail never leaves the radio.
  bool Function(String recipientStaticKeyHex)? isGhostPinned;

  /// One-time prekeys, deleted after use so captured courier mail stays unreadable.
  final LocalPrekeys prekeys = LocalPrekeys();

  /// Peers' newest published bundles, fed by gossip.
  final Map<String, PrekeyBundle> _peerPrekeys = <String, PrekeyBundle>{};

  /// Called when the prekey batch changes, so the bridge persists it; null in tests.
  void Function(String encoded)? onPrekeysChanged;

  bool Function()? prekeysReady;

  Stream<MeshPingResult> get onPingResult => _pingResults.stream;
  final _pingResults = StreamController<MeshPingResult>.broadcast();

  /// Outstanding probes: nonce hex to (peerID, sent-at, origin TTL).
  final Map<String, (String, int, int)> _pendingPings = {};

  /// Carried Nostr events to publish or display, wired by the bridge; null when not a gateway.
  void Function(NostrCarrierPacket carrier, String fromPeerID)? onNostrCarrier;

  /// Called when the gossip store is worth persisting; null in tests.
  void Function(String archive)? onGossipArchiveChanged;

  /// Dirty flag so the tick, not every packet, encodes the archive.
  bool _gossipDirty = false;

  // Public API

  String get myPeerID => identity.peerID;

  /// Live peer record for [peerID], or null if unknown.
  MeshPeer? peerById(String peerID) => _peers[peerID];

  /// Peer's Noise static key hex from its announce or established session; the canonical mesh identity.
  String? noiseKeyHexForPeer(String peerID) {
    final fromPeer = _peers[peerID]?.noisePublicKey;
    if (fromPeer != null && fromPeer.length == 32) return _hex(fromPeer);
    final fromSession = _noise.remoteStaticKey(peerID);
    if (fromSession != null && fromSession.length == 32) {
      return _hex(fromSession);
    }
    return null;
  }

  bool get isRunning => _running;
  int get connectedLinkCount => _transport.connectedLinkCount;
  MeshTransportAvailability get availability => _transport.availability;

  Future<void> openSystemSettings() => _transport.openSystemSettings();

  List<MeshPeer> get peers => _peers.values.toList(growable: false);
  Stream<List<MeshPeer>> get peersStream => _peersChanged.stream;
  Stream<MeshPublicMessage> get onPublicMessage => _publicMessages.stream;
  Stream<MeshPrivateMessage> get onPrivateMessage => _privateMessages.stream;
  Stream<MeshReceipt> get onReceipt => _receipts.stream;
  Stream<MeshProfileReceived> get onProfile => _profiles.stream;
  Stream<MeshFileReceived> get onFile => _files.stream;
  Stream<MeshTypingEvent> get onTyping => _typing.stream;
  Stream<MeshReactionEvent> get onReaction => _reactions.stream;

  Future<void> sendChannelReaction(
      String targetId, String emoji, bool remove) async {
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.nymReaction,
      payload: _encodeReaction(targetId, emoji, remove),
    ));
  }

  /// Sends an encrypted reaction to 1:1 message [targetId], handshaking first if needed.
  Future<void> sendPrivateReaction(
      String peerID, String targetId, String emoji, bool remove) async {
    final plaintext = NoisePayload(
      NoisePayloadType.reaction,
      _encodeReaction(targetId, emoji, remove),
    ).encode();
    await _sendOrQueueEncrypted(peerID, plaintext);
  }

  Uint8List _encodeReaction(String targetId, String emoji, bool remove) {
    final out = BytesBuilder();
    out.addByte(remove ? 0x01 : 0);
    void lp(String s) {
      var b = Uint8List.fromList(utf8.encode(s));
      if (b.length > 255) b = b.sublist(0, 255);
      out.addByte(b.length);
      out.add(b);
    }

    lp(targetId);
    lp(emoji);
    lp(_nicknameProvider());
    return out.toBytes();
  }

  static _ReactionData? _decodeReaction(Uint8List data) {
    if (data.isEmpty) return null;
    var off = 0;
    final remove = (data[off++] & 0x01) != 0;
    String? read() {
      if (off >= data.length) return null;
      final len = data[off++];
      if (off + len > data.length) return null;
      final s = utf8.decode(data.sublist(off, off + len), allowMalformed: true);
      off += len;
      return s;
    }

    final targetId = read();
    final emoji = read();
    final nick = read() ?? '';
    if (targetId == null ||
        emoji == null ||
        targetId.isEmpty ||
        emoji.isEmpty) {
      return null;
    }
    return _ReactionData(targetId, emoji, remove, nick);
  }

  /// Sends an ephemeral typing indicator: [channel] for a channel (null = nearby), [toPeerID] for a DM.
  Future<void> sendTyping({
    String? channel,
    String? toPeerID,
    bool start = true,
  }) async {
    final out = BytesBuilder();
    out.addByte((start ? 0x01 : 0) | (channel != null ? 0x02 : 0));
    void lenPrefixed(String s) {
      var b = Uint8List.fromList(utf8.encode(s));
      if (b.length > 255) b = b.sublist(0, 255);
      out.addByte(b.length);
      out.add(b);
    }

    lenPrefixed(_nicknameProvider());
    if (channel != null) lenPrefixed(channel);
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.nymTyping,
      payload: out.toBytes(),
      recipientID: toPeerID != null ? _peerIdBytes(toPeerID) : null,
    ));
  }

  void _handleTyping(BitchatPacket packet, String senderPeerID) {
    final data = packet.payload;
    if (data.isEmpty) return;
    var offset = 0;
    final flags = data[offset++];
    final isStart = (flags & 0x01) != 0;
    final hasChannel = (flags & 0x02) != 0;
    String readStr() {
      if (offset >= data.length) return '';
      final len = data[offset++];
      if (offset + len > data.length) {
        offset = data.length;
        return '';
      }
      final s =
          utf8.decode(data.sublist(offset, offset + len), allowMalformed: true);
      offset += len;
      return s;
    }

    final nickname = readStr();
    final channel = hasChannel ? readStr() : null;
    _typing.add(MeshTypingEvent(
      senderPeerID: senderPeerID,
      nickname: nickname,
      isStart: isStart,
      isDirect: !packet.isBroadcast,
      channel: channel,
    ));
  }

  /// Powers up the radio and joins the mesh; returns availability.
  Future<MeshTransportAvailability> start() async {
    if (_running) return _transport.availability;
    // Subscribe before powering up so no early frame or link event is missed.
    _running = true;
    debugLog?.call('service.start(): peerID=$myPeerID');
    _inboundSub = _transport.inbound.listen(_onFrame);
    _linkSub = _transport.links.listen(_onLink);
    final availability = await _transport.start();
    debugLog?.call('transport up → availability=${availability.name}');
    _scheduleAnnounce();
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _cleanupStalePeers());
    // Gossip heartbeat; the per-peer schedule lives in [GossipSync].
    _syncTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_gossipTick()));
    await _broadcastAnnounce();
    // Publish our prekeys; broadcast and gossiped so they reach senders while we're away.
    unawaited(publishPrekeyBundle());
    debugLog?.call('sent initial identity announce — awaiting peers');
    return availability;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    // Best-effort LEAVE so peers drop us promptly.
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.leave,
      payload: Uint8List.fromList(identity.peerID.codeUnits),
    ));
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _syncTimer?.cancel();
    await _inboundSub?.cancel();
    await _linkSub?.cancel();
    await _transport.stop();
    _noise.clear();
    _seen.clear();
    _reassembler.clear();
    _peers.clear();
    _pendingPlaintext.clear();
    _pendingEncrypted.clear();
    _profileRequested.clear();
  }

  /// Broadcasts a public [content] message, optionally to a [channel]; returns its id.
  Future<String> sendPublicMessage(
    String content, {
    String? channel,
    List<String>? mentions,
  }) async {
    final timestampMs = DateTime.now().millisecondsSinceEpoch;
    // Named channels are Nymchat-only (0x54 TLV), AES-sealed when we hold the channel key.
    if (channel != null) {
      final encrypted = _channelCrypto.hasKey(channel);
      final msg = BitchatMessage(
        id: _uuid.v4(),
        sender: _nicknameProvider(),
        content: encrypted ? '' : content,
        timestampMs: timestampMs,
        senderPeerID: identity.peerID,
        channel: channel,
        mentions: mentions,
        isEncrypted: encrypted,
        encryptedContent:
            encrypted ? await _channelCrypto.encrypt(channel, content) : null,
      );
      final packet = await _buildPacket(
        type: MeshMessageType.nymChannelMessage,
        payload: msg.toBinaryPayload(),
        recipientID: kBroadcastRecipient,
        sign: true,
      );
      await _sendPacket(packet);
      _rememberOwnPublic(packet);
      return msg.id;
    }

    // #mesh payload is raw UTF-8 as bitchat expects, not a TLV; the id is content-derived.
    final payload = Uint8List.fromList(utf8.encode(content));
    final packet = await _buildPacket(
      type: MeshMessageType.message,
      payload: payload,
      // 0xFF×8 recipient as bitchat-android; iOS sends null but accepts either.
      recipientID: kBroadcastRecipient,
      sign: true,
    );
    await _sendPacket(packet);
    _rememberOwnPublic(packet);
    return MeshMessageIdentity.stableId(
      senderIdHex: identity.peerID,
      timestampMs: timestampMs,
      content: content,
    );
  }

  /// Joins an encrypted group [channel] with a shared [password] (bitchat password channels).
  Future<void> setChannelPassword(String channel, String password) =>
      _channelCrypto.setChannelPassword(channel, password);

  bool hasChannelKey(String channel) => _channelCrypto.hasKey(channel);

  void leaveChannel(String channel) => _channelCrypto.removeChannel(channel);

  /// Sends a private message, handshaking first if needed; chunks at 255 bytes and returns the first id.
  Future<String> sendPrivateMessage(String peerID, String content) async {
    final chunks = _chunkContent(content);
    String? firstId;
    for (final chunk in chunks) {
      final messageId = _uuid.v4();
      firstId ??= messageId;
      final pm = PrivateMessagePacket(messageID: messageId, content: chunk);
      final encoded = pm.encode();
      if (encoded == null) continue;
      final plaintext =
          NoisePayload(NoisePayloadType.privateMessage, encoded).encode();
      await _sendOrQueueEncrypted(peerID, plaintext);
    }
    return firstId ?? '';
  }

  bool fileFits(String fileName, String mimeType, Uint8List bytes,
      {String? peerID}) {
    final encoded = BitchatFilePacket(
            fileName: fileName, mimeType: mimeType, content: bytes)
        .encode();
    if (encoded == null) return false;
    final bodyLength = peerID == null ? encoded.length : encoded.length + 21;
    final probe = BitchatPacket(
      version: packetVersionForPayload(bodyLength),
      type: peerID == null
          ? MeshMessageType.fileTransfer
          : MeshMessageType.noiseEncrypted,
      senderID: Uint8List(8),
      recipientID: peerID == null ? kBroadcastRecipient : Uint8List(8),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: Uint8List(bodyLength),
      signature: peerID == null ? Uint8List(64) : null,
      ttl: MeshConstants.messageTtl,
    );
    return PacketFragmenter.fragment(probe).isNotEmpty;
  }

  /// Sends [bytes] to [peerID] as a Noise-sealed, fragmented DM attachment.
  Future<bool> sendFileToPeer(
    String peerID,
    String fileName,
    String mimeType,
    Uint8List bytes,
  ) async {
    if (!fileFits(fileName, mimeType, bytes, peerID: peerID)) return false;
    final file = BitchatFilePacket(
        fileName: fileName, mimeType: mimeType, content: bytes);
    final encoded = file.encode();
    if (encoded == null) return false;
    final plaintext =
        NoisePayload(NoisePayloadType.fileTransfer, encoded).encode();
    await _sendOrQueueEncrypted(peerID, plaintext);
    return true;
  }

  /// Broadcasts [bytes] as a fragmented FILE_TRANSFER packet.
  Future<bool> sendFileBroadcast(
    String fileName,
    String mimeType,
    Uint8List bytes,
  ) async {
    final file = BitchatFilePacket(
        fileName: fileName, mimeType: mimeType, content: bytes);
    final encoded = file.encode();
    if (encoded == null) return false;
    final packet = await _buildPacket(
      type: MeshMessageType.fileTransfer,
      payload: encoded,
      // bitchat drops unsigned raw file transfers, so broadcasts must be signed.
      recipientID: kBroadcastRecipient,
      sign: true,
    );
    if (PacketFragmenter.fragment(packet).isEmpty) return false;
    await _sendPacket(packet);
    return true;
  }

  Future<void> sendReadReceipt(String peerID, String messageId) async {
    await _sendOrQueueEncrypted(
        peerID, NoisePayload.readReceipt(messageId).encode());
  }

  void dispose() {
    _publicMessages.close();
    _privateMessages.close();
    _receipts.close();
    _profiles.close();
    _files.close();
    _typing.close();
    _reactions.close();
    _pingResults.close();
    _peersChanged.close();
  }

  // Inbound handling

  /// Receive-pipeline debug sink for the mesh diagnostics panel; null unless set.
  static void Function(String line)? debugLog;

  Future<void> _onFrame(MeshInboundFrame frame) async {
    final packet = BinaryProtocol.decode(frame.data);
    if (packet == null) {
      debugLog?.call('frame ${frame.data.length}B — DECODE FAILED');
      return;
    }
    await _processPacket(packet, frame.linkId, frame.rssi);
  }

  Future<void> _processPacket(
      BitchatPacket packet, String linkId, int rssi) async {
    final senderPeerID = _hex(packet.senderID);
    if (senderPeerID == identity.peerID) return;

    debugLog?.call('pkt type=0x${packet.type.toRadixString(16)} '
        'from=$senderPeerID '
        'rcpt=${packet.recipientID == null ? 'null' : (packet.isBroadcast ? 'bcast' : 'direct')} '
        '${packet.payload.length}B');

    final key = SeenPackets.keyFor(
      type: packet.type,
      senderID: packet.senderID,
      timestamp: packet.timestamp,
      payload: packet.payload,
    );
    if (!_seen.checkAndAdd(key)) {
      debugLog
          ?.call('  ↳ deduped (seen) type=0x${packet.type.toRadixString(16)}');
      return;
    }

    final forUs = packet.recipientID == null ||
        packet.isBroadcast ||
        _hex(packet.recipientID!) == identity.peerID;

    // Store syncable public traffic for peers who missed it; directed packets are refused inside.
    if (packet.isBroadcast && GossipSync.isSyncable(packet.type)) {
      gossip.onPublicPacketSeen(packet);
      // Persist on the tick; encoding per packet is too expensive.
      _gossipDirty = true;
    }

    switch (packet.type) {
      case MeshMessageType.announce:
        await _handleAnnounce(packet, senderPeerID, rssi);
        break;
      case MeshMessageType.message:
        _handlePublicMessage(packet, senderPeerID);
        break;
      case MeshMessageType.nymChannelMessage:
        await _handleChannelMessage(packet, senderPeerID);
        break;
      case MeshMessageType.leave:
        _removePeer(senderPeerID);
        break;
      case MeshMessageType.noiseHandshake:
        if (forUs) await _handleHandshake(senderPeerID, packet.payload);
        break;
      case MeshMessageType.noiseEncrypted:
        if (forUs) await _handleEncrypted(senderPeerID, packet.payload);
        break;
      case MeshMessageType.fragment:
        await _handleFragment(packet, linkId, rssi);
        break;
      case MeshMessageType.fileTransfer:
        // bitchat sends PM images directed and #mesh images broadcast; route by recipient.
        _handleFile(
          packet,
          senderPeerID,
          direct: packet.recipientID != null &&
              !packet.isBroadcast &&
              _hex(packet.recipientID!) == identity.peerID,
        );
        break;
      case MeshMessageType.nymProfileRequest:
        if (forUs) await _handleProfileRequest(senderPeerID, packet.payload);
        break;
      case MeshMessageType.nymProfileResponse:
        if (forUs) _handleProfileResponse(senderPeerID, packet.payload);
        break;
      case MeshMessageType.nymTyping:
        if (forUs) _handleTyping(packet, senderPeerID);
        break;
      case MeshMessageType.nymReaction:
        _handleReactionBroadcast(packet, senderPeerID);
        break;
      case MeshMessageType.courierEnvelope:
        // Directed mail: deliver it if ours, else carry it.
        if (forUs) await _handleCourierEnvelope(packet, senderPeerID);
        break;
      case MeshMessageType.ping:
        if (forUs) await _handlePing(packet, senderPeerID);
        break;
      case MeshMessageType.pong:
        if (forUs) _handlePong(packet, senderPeerID);
        break;
      case MeshMessageType.prekeyBundle:
        _handlePrekeyBundle(packet, senderPeerID);
        break;
      case MeshMessageType.nostrCarrier:
        // The handler verifies carried events; a gateway never vouches.
        _handleNostrCarrier(packet, senderPeerID);
        break;
      case MeshMessageType.requestSync:
        // Sync requests are answered locally and never relayed (TTL 0).
        if (forUs || packet.isBroadcast) {
          await _handleRequestSync(packet, senderPeerID);
        }
        break;
      default:
        break;
    }

    // Never relay packets addressed solely to us or directed packets we consumed.
    final directedToUs = packet.recipientID != null &&
        !packet.isBroadcast &&
        _hex(packet.recipientID!) == identity.peerID;
    if (!directedToUs &&
        packet.ttl > 1 &&
        packet.type != MeshMessageType.leave) {
      _scheduleRelay(packet);
    }
  }

  Future<void> _handleAnnounce(
      BitchatPacket packet, String senderPeerID, int rssi) async {
    final announcement = IdentityAnnouncement.decode(packet.payload);
    if (announcement == null) return;

    var verified = false;
    // The peerID must be the fingerprint of the announced Noise key…
    if (NoiseIdentity.matchesClaimedPeerID(
        senderPeerID, announcement.noisePublicKey)) {
      // …and a signed announcement's signature must verify.
      if (packet.signature != null) {
        final signable = packet.toBytesForSigning();
        verified = signable != null &&
            await NoiseIdentity.verify(
              signable,
              packet.signature!,
              announcement.signingPublicKey,
            );
      }
    }

    final peer =
        _peers.putIfAbsent(senderPeerID, () => MeshPeer(peerID: senderPeerID));
    peer.nickname = announcement.nickname;
    peer.noisePublicKey = announcement.noisePublicKey;
    peer.signingPublicKey = announcement.signingPublicKey;
    peer.isVerified = verified;
    peer.rssi = rssi;

    // Adopt a Nostr link only when its schnorr signature binds it to the announced Noise key.
    final link = announcement.nostrLink;
    if (link != null) {
      final linkedPubkey = NostrLink.verify(link, announcement.noisePublicKey);
      if (linkedPubkey != null) {
        peer.nostrPubkey = linkedPubkey;
        peer.nostrLinkVerified = true;
      }
    }

    peer.touch();
    _emitPeers();
    // Meeting a peer is when mail can move; unawaited so the announce path never stalls.
    unawaited(_courierEncounter(peer));
  }

  /// bitchat public message: raw UTF-8, nickname from the announce, content-derived id.
  void _handlePublicMessage(BitchatPacket packet, String senderPeerID) {
    final content = utf8.decode(packet.payload, allowMalformed: true);
    if (content.isEmpty) return;
    final peer = _peers[senderPeerID];
    final nickname = peer?.displayName ?? senderPeerID;
    _touchPeer(senderPeerID);
    _publicMessages.add(MeshPublicMessage(
      senderPeerID: senderPeerID,
      senderNickname: nickname,
      content: content,
      messageId: MeshMessageIdentity.stableId(
        senderIdHex: senderPeerID,
        timestampMs: packet.timestamp,
        content: content,
      ),
      timestampMs: packet.timestamp,
      channel: null,
    ));
  }

  /// Nymchat named-channel broadcast, possibly AES-sealed; routes to that channel, not #mesh.
  Future<void> _handleChannelMessage(
      BitchatPacket packet, String senderPeerID) async {
    final tlv = BitchatMessage.fromBinaryPayload(packet.payload);
    if (tlv == null || tlv.channel == null) return;
    String content;
    if (tlv.isEncrypted) {
      final enc = tlv.encryptedContent;
      if (enc == null || !_channelCrypto.hasKey(tlv.channel!)) return;
      try {
        content = await _channelCrypto.decrypt(tlv.channel!, enc);
      } catch (_) {
        return;
      }
    } else {
      content = tlv.content;
    }
    _touchPeer(senderPeerID, nickname: tlv.sender);
    _publicMessages.add(MeshPublicMessage(
      senderPeerID: tlv.senderPeerID ?? senderPeerID,
      senderNickname: tlv.sender,
      content: content,
      messageId: tlv.id,
      timestampMs: tlv.timestampMs,
      channel: tlv.channel,
      mentions: tlv.mentions ?? const [],
      isRelay: tlv.isRelay,
    ));
  }

  Future<void> _handleHandshake(String senderPeerID, Uint8List payload) async {
    try {
      // A new handshake supersedes the session, so the peer-state proof must be re-sent.
      if (!_noise.isEstablished(senderPeerID)) {
        _peerStateSentTo.remove(senderPeerID);
      }
      final response = await _noise.handleHandshake(senderPeerID, payload);
      if (response != null) {
        await _sendDirected(
          peerID: senderPeerID,
          type: MeshMessageType.noiseHandshake,
          payload: response,
        );
      }
      if (_noise.isEstablished(senderPeerID)) {
        // Send peer state before queued media so bitchat accepts our encrypted attachments.
        await _sendAuthenticatedPeerState(senderPeerID);
        await _flushPending(senderPeerID);
        await _drainPendingEncrypted(senderPeerID);
      }
    } catch (_) {
      // Handshake failed or peerID binding rejected; drop silently.
    }
  }

  /// Peers sent this session's peer-state proof; cleared when a new handshake begins.
  final Set<String> _peerStateSentTo = {};

  /// Sends the Noise 0x21 capability proof once per session so bitchat accepts our private media.
  Future<void> _sendAuthenticatedPeerState(String peerID) async {
    if (!_peerStateSentTo.add(peerID)) return;
    final encoded = AuthenticatedPeerStatePacket(
      capabilities: _capabilities,
      signingPublicKey: identity.signingPublic,
    ).encode();
    if (encoded == null) return;
    await _sendOrQueueEncrypted(
        peerID,
        NoisePayload(NoisePayloadType.authenticatedPeerState, encoded)
            .encode());
  }

  Future<void> _handleEncrypted(String senderPeerID, Uint8List payload) async {
    if (!_noise.isEstablished(senderPeerID)) {
      // Session still handshaking: queue the frame for establish.
      _pendingEncrypted.putIfAbsent(senderPeerID, () => []).add(payload);
      return;
    }
    Uint8List plaintext;
    try {
      plaintext = await _noise.decrypt(senderPeerID, payload);
    } catch (_) {
      return;
    }
    await _dispatchNoisePayload(senderPeerID, plaintext);
  }

  /// Handles a decrypted payload, shared by live sessions and opened courier envelopes.
  Future<void> _dispatchNoisePayload(
      String senderPeerID, Uint8List plaintext) async {
    final noisePayload = NoisePayload.decode(plaintext);
    if (noisePayload == null) return;

    switch (noisePayload.type) {
      case NoisePayloadType.privateMessage:
        final pm = PrivateMessagePacket.decode(noisePayload.data);
        if (pm == null) return;
        _touchPeer(senderPeerID);
        _privateMessages.add(MeshPrivateMessage(
          senderPeerID: senderPeerID,
          messageId: pm.messageID,
          content: pm.content,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ));
        // Auto-acknowledge delivery.
        await _sendOrQueueEncrypted(
            senderPeerID, NoisePayload.delivered(pm.messageID).encode());
        break;
      case NoisePayloadType.delivered:
        _receipts.add(MeshReceipt(
          fromPeerID: senderPeerID,
          messageId: noisePayload.receiptMessageId(),
          isRead: false,
        ));
        break;
      case NoisePayloadType.readReceipt:
        _receipts.add(MeshReceipt(
          fromPeerID: senderPeerID,
          messageId: noisePayload.receiptMessageId(),
          isRead: true,
        ));
        break;
      case NoisePayloadType.fileTransfer:
        final file = BitchatFilePacket.decode(noisePayload.data);
        if (file != null) {
          _touchPeer(senderPeerID);
          _files.add(MeshFileReceived(
            fromPeerID: senderPeerID,
            fileName: file.fileName,
            mimeType: file.mimeType,
            bytes: file.content,
          ));
        }
        break;
      case NoisePayloadType.authenticatedPeerState:
        final state = AuthenticatedPeerStatePacket.decode(noisePayload.data);
        if (state != null) {
          final peer = _peers[senderPeerID];
          if (peer != null) {
            peer.supportsPrivateMedia = state.supportsPrivateMedia;
          }
          // Echo our proof once so the session is authenticated both ways.
          await _sendAuthenticatedPeerState(senderPeerID);
        }
        break;
      case NoisePayloadType.reaction:
        final r = _decodeReaction(noisePayload.data);
        if (r != null) {
          _touchPeer(senderPeerID);
          _reactions.add(MeshReactionEvent(
            senderPeerID: senderPeerID,
            targetId: r.targetId,
            emoji: r.emoji,
            isRemove: r.isRemove,
            reactorNick: r.reactorNick,
            isDirect: true,
          ));
        }
        break;
      default:
        break;
    }
  }

  void _handleReactionBroadcast(BitchatPacket packet, String senderPeerID) {
    final r = _decodeReaction(packet.payload);
    if (r == null) return;
    _reactions.add(MeshReactionEvent(
      senderPeerID: senderPeerID,
      targetId: r.targetId,
      emoji: r.emoji,
      isRemove: r.isRemove,
      reactorNick: r.reactorNick.isNotEmpty
          ? r.reactorNick
          : (_peers[senderPeerID]?.nickname ?? ''),
      isDirect: false,
    ));
  }

  void _handleFile(BitchatPacket packet, String senderPeerID,
      {required bool direct}) {
    final file = BitchatFilePacket.decode(packet.payload);
    if (file == null) return;
    final peer = _peers[senderPeerID];
    _files.add(MeshFileReceived(
      fromPeerID: senderPeerID,
      fileName: file.fileName,
      mimeType: file.mimeType,
      bytes: file.content,
      isDirect: direct,
      senderNickname: peer?.nickname ?? '',
    ));
  }

  Future<void> _handleFragment(
      BitchatPacket packet, String linkId, int rssi) async {
    final fragment = FragmentPayload.decode(packet.payload);
    if (fragment == null) return;
    final reassembled = _reassembler.accept(fragment);
    if (reassembled == null) return;
    final inner = BinaryProtocol.decode(reassembled);
    if (inner != null) {
      await _processPacket(inner, linkId, rssi);
    }
  }

  /// Asks [peerID] once for their rich profile over the mesh.
  Future<void> requestProfile(String peerID,
      {bool avatar = true, bool banner = false}) async {
    if (!_running || _profileRequested.contains(peerID)) return;
    _profileRequested.add(peerID);
    await _sendDirected(
      peerID: peerID,
      type: MeshMessageType.nymProfileRequest,
      payload:
          MeshProfileRequest(wantAvatar: avatar, wantBanner: banner).encode(),
    );
  }

  Future<void> _handleProfileRequest(
      String senderPeerID, Uint8List payload) async {
    final provider = _profileProvider;
    if (provider == null) return;
    final request = MeshProfileRequest.decode(payload);
    final profile = await provider(request);
    if (profile == null) return;
    await _sendDirected(
      peerID: senderPeerID,
      type: MeshMessageType.nymProfileResponse,
      payload: profile.encode(),
    );
  }

  void _handleProfileResponse(String senderPeerID, Uint8List payload) {
    final profile = MeshProfile.decode(payload);
    if (profile == null) return;
    final peer = _peers[senderPeerID];
    if (peer != null) {
      if (profile.nickname.isNotEmpty) peer.nickname = profile.nickname;
      // A profile response is not a signed link, so its nostrPubkey is never adopted.
      peer.touch();
      _emitPeers();
    }
    _profiles.add(MeshProfileReceived(peerID: senderPeerID, profile: profile));
  }

  void _onLink(MeshLinkEvent event) {
    // Announce on a new link so the peer learns us immediately.
    if (event.change == MeshLinkChange.connected) {
      unawaited(_broadcastAnnounce());
    }
  }

  // Outbound helpers

  Future<void> _sendOrQueueEncrypted(String peerID, Uint8List plaintext) async {
    if (_noise.isEstablished(peerID)) {
      final ciphertext = await _noise.encrypt(peerID, plaintext);
      await _sendDirected(
        peerID: peerID,
        type: MeshMessageType.noiseEncrypted,
        payload: ciphertext,
      );
      return;
    }
    _pendingPlaintext.putIfAbsent(peerID, () => []).add(plaintext);
    if (!_noise.isHandshaking(peerID)) {
      // New session: the peer-state proof must be re-sent once it establishes.
      _peerStateSentTo.remove(peerID);
      final msg1 = await _noise.initiateHandshake(peerID);
      await _sendDirected(
        peerID: peerID,
        type: MeshMessageType.noiseHandshake,
        payload: msg1,
      );
    }
  }

  Future<void> _drainPendingEncrypted(String peerID) async {
    final queued = _pendingEncrypted.remove(peerID);
    if (queued == null) return;
    for (final payload in queued) {
      await _handleEncrypted(peerID, payload);
    }
  }

  Future<void> _flushPending(String peerID) async {
    final queued = _pendingPlaintext.remove(peerID);
    if (queued == null) return;
    for (final plaintext in queued) {
      try {
        final ciphertext = await _noise.encrypt(peerID, plaintext);
        await _sendDirected(
          peerID: peerID,
          type: MeshMessageType.noiseEncrypted,
          payload: ciphertext,
        );
      } catch (_) {}
    }
  }

  /// Announce capabilities: bit 8 `privateMedia`, little-endian [0x00, 0x01], as bitchat `PeerCapabilities`.
  static final Uint8List _capabilities = Uint8List.fromList([0x00, 0x01]);

  /// Jittered, load-adaptive announce gap against rhythm fingerprinting; stays under the stale timeout.
  void _scheduleAnnounce() {
    _announceTimer?.cancel();
    if (!_running) return;
    final base = _peers.isEmpty
        ? MeshConstants.announceIntervalIdle
        : MeshConstants.announceInterval;
    final spreadMs = MeshConstants.announceJitter.inMilliseconds;
    final jitterMs = _random.nextInt(spreadMs * 2 + 1) - spreadMs;
    var next = base + Duration(milliseconds: jitterMs);
    if (next < const Duration(seconds: 5)) next = const Duration(seconds: 5);
    _announceTimer = Timer(next, () {
      _broadcastAnnounce();
      _scheduleAnnounce();
    });
  }

  /// Broadcasts our announce; nickname, keys and nostrLink go out in clear, so only Ghost Mode cloaks them together.
  Future<void> _broadcastAnnounce() async {
    if (!_running) return;
    final announcement = IdentityAnnouncement(
      nickname: _nicknameProvider(),
      noisePublicKey: identity.staticPublic,
      signingPublicKey: identity.signingPublic,
      capabilities: _capabilities,
      nostrLink: _nostrLinkProvider?.call(),
    );
    final payload = announcement.encode();
    if (payload == null) return;
    final packet = await _buildPacket(
      type: MeshMessageType.announce,
      payload: payload,
      sign: true,
    );
    await _sendPacket(packet);
  }

  // Diagnostics: ping / pong

  /// Probes [peerID] for presence and hop count; the unguessable nonce binds the reply.
  Future<bool> ping(String peerID, {int ttl = MeshConstants.messageTtl}) async {
    final recipient = _peerIdBytes(peerID);
    if (recipient == null) return false;
    final nonce = Uint8List.fromList(List<int>.generate(
        MeshPingPayload.nonceLength, (_) => _random.nextInt(256)));
    final payload = MeshPingPayload.create(nonce: nonce, originTtl: ttl);
    if (payload == null) return false;
    _pendingPings[_hex(nonce)] =
        (peerID, DateTime.now().millisecondsSinceEpoch, ttl);
    try {
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.ping,
        payload: payload.encode(),
        recipientID: recipient,
        ttl: ttl,
      ));
      return true;
    } catch (_) {
      _pendingPings.remove(_hex(nonce));
      return false;
    }
  }

  /// Echoes the nonce with our launch TTL so the far end can measure the return path.
  Future<void> _handlePing(BitchatPacket packet, String senderPeerID) async {
    final probe = MeshPingPayload.decode(packet.payload);
    if (probe == null) return;
    final recipient = _peerIdBytes(senderPeerID);
    if (recipient == null) return;
    const ttl = MeshConstants.messageTtl;
    final reply = MeshPingPayload.create(nonce: probe.nonce, originTtl: ttl);
    if (reply == null) return;
    try {
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.pong,
        payload: reply.encode(),
        recipientID: recipient,
        ttl: ttl,
      ));
    } catch (_) {}
  }

  /// Completes a probe; unknown nonces are dropped.
  void _handlePong(BitchatPacket packet, String senderPeerID) {
    final reply = MeshPingPayload.decode(packet.payload);
    if (reply == null) return;
    final pending = _pendingPings.remove(_hex(reply.nonce));
    if (pending == null) return;
    final (peerID, sentAt, _) = pending;
    if (peerID != senderPeerID) return;
    final rtt = DateTime.now().millisecondsSinceEpoch - sentAt;
    final hops = MeshPingPayload.hopCount(
      originTtl: reply.originTtl,
      receivedTtl: packet.ttl,
    );
    debugLog?.call('pong from $senderPeerID rtt=${rtt}ms hops=${hops ?? '?'}');
    if (!_pingResults.isClosed) {
      _pingResults.add(MeshPingResult(
          peerID: senderPeerID, roundTripMs: rtt, hops: hops));
    }
  }

  // Gateway mode

  /// Asks [gatewayPeerID] to publish our signed event; the gateway cannot alter it.
  Future<bool> carryToGateway({
    required String gatewayPeerID,
    required String geohash,
    required Map<String, dynamic> event,
  }) async {
    final recipient = _peerIdBytes(gatewayPeerID);
    if (recipient == null) return false;
    final carrier = NostrCarrierPacket.fromEvent(
      direction: NostrCarrierDirection.toGateway,
      geohash: geohash,
      event: event,
    );
    if (carrier == null) return false;
    try {
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.nostrCarrier,
        payload: carrier.encode(),
        recipientID: recipient,
        ttl: MeshConstants.messageTtl,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Rebroadcasts a relay event so mesh-only peers can read a geohash channel.
  Future<bool> broadcastFromGateway({
    required String geohash,
    required Map<String, dynamic> event,
  }) async {
    final carrier = NostrCarrierPacket.fromEvent(
      direction: NostrCarrierDirection.fromGateway,
      geohash: geohash,
      event: event,
    );
    if (carrier == null) return false;
    try {
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.nostrCarrier,
        payload: carrier.encode(),
        recipientID: kBroadcastRecipient,
        ttl: MeshConstants.messageTtl,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleNostrCarrier(BitchatPacket packet, String senderPeerID) {
    final carrier = NostrCarrierPacket.decode(packet.payload);
    if (carrier == null) return;
    debugLog?.call('nostr carrier ${carrier.direction.name} '
        'geo=${carrier.geohash} from $senderPeerID');
    // The bridge verifies the signature before publishing or displaying.
    onNostrCarrier?.call(carrier, senderPeerID);
  }

  // Prekey bundles

  /// Signs and broadcasts our prekey batch, gossiped so it reaches senders while we're away.
  Future<bool> publishPrekeyBundle() async {
    // Never while ghosted: courier mail to or from a ghost is refused anyway.
    if (isGhostMode?.call() ?? false) return false;
    if (!(prekeysReady?.call() ?? true)) return false;
    if (await prekeys.replenish()) {
      onPrekeysChanged?.call(prekeys.encode());
    }
    final available = prekeys.available;
    if (available.isEmpty) return false;
    final bundle = PrekeyBundle(
      noiseStaticPublicKey: identity.staticPublic,
      prekeys: [
        for (final k in available) Prekey(id: k.id, publicKey: k.publicKey),
      ],
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
      signature: Uint8List(PrekeyBundle.signatureLength),
    );
    final signed = PrekeyBundle(
      noiseStaticPublicKey: bundle.noiseStaticPublicKey,
      prekeys: bundle.prekeys,
      generatedAtMs: bundle.generatedAtMs,
      signature: await identity.sign(bundle.signableBytes()),
    );
    final bytes = signed.encode();
    if (bytes == null) return false;
    try {
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.prekeyBundle,
        payload: bytes,
        recipientID: kBroadcastRecipient,
        ttl: MeshConstants.messageTtl,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Files a peer's bundle only after verifying it against their announce-bound signing key.
  void _handlePrekeyBundle(BitchatPacket packet, String senderPeerID) {
    final bundle = PrekeyBundle.decode(packet.payload);
    if (bundle == null) return;
    final ownerHex = _hex(bundle.noiseStaticPublicKey);
    // The signing key comes from the owner's verified announce, never the packet.
    final ownerPeerID = _peerIdForNoiseKey(bundle.noiseStaticPublicKey);
    final owner = _peers[ownerPeerID];
    final signingKey = owner?.signingPublicKey;
    if (owner == null || signingKey == null || !owner.isVerified) {
      debugLog?.call('prekey bundle from unknown/unverified owner — dropped');
      return;
    }
    final existing = _peerPrekeys[ownerHex];
    // Refuse older bundles so replays can't resurrect deleted keys.
    if (existing != null && existing.generatedAtMs >= bundle.generatedAtMs) {
      return;
    }
    unawaited(() async {
      final ok = await NoiseIdentity.verify(
        bundle.signableBytes(),
        bundle.signature,
        signingKey,
      );
      if (!ok) {
        debugLog?.call('prekey bundle signature FAILED — dropped');
        return;
      }
      _peerPrekeys[ownerHex] = bundle;
      debugLog?.call('prekey bundle from $ownerPeerID: '
          '${bundle.prekeys.length} key(s)');
    }());
  }

  // Couriers

  /// Session-less Noise payload for a private message; null when it exceeds one packet.
  static Uint8List? privateMessagePayload({
    required String messageId,
    required String content,
  }) {
    final body =
        PrivateMessagePacket(messageID: messageId, content: content).encode();
    if (body == null) return null;
    return NoisePayload(NoisePayloadType.privateMessage, body).encode();
  }

  /// Seals and hands copies to nearby couriers; returns how many took it, 0 when refused (not an error).
  Future<int> depositWithCouriers({
    required String recipientStaticKeyHex,
    required Uint8List payload,
    int copies = 4,
  }) async {
    final ghosted = isGhostMode?.call() ?? false;
    final pinned = isGhostPinned?.call(recipientStaticKeyHex) ?? false;
    final key = _fromHex(recipientStaticKeyHex);
    if (!CourierStore.mayDeposit(
      isGhostPinned: pinned,
      isGhostMode: ghosted,
      hasRecipientStaticKey: key != null && key.length == 32,
    )) {
      debugLog?.call('courier deposit refused (ghost/no key)');
      return 0;
    }
    final recipientPeerID = _peerIdForNoiseKey(key!);
    final now = DateTime.now().millisecondsSinceEpoch;
    // Prefer a one-time prekey over the static key when the recipient published one.
    final bundle = _peerPrekeys[recipientStaticKeyHex.toLowerCase()];
    final prekey = bundle == null ? null : prekeys.chooseFrom(bundle.prekeys);
    Uint8List sealed;
    try {
      sealed = await CourierSeal.seal(
        payload: payload,
        recipientStaticKey: prekey?.publicKey ?? key,
        senderStaticPrivate: identity.staticPrivate,
        senderStaticPublic: identity.staticPublic,
        prologue:
            prekey == null ? null : courierPrekeyPrologue(prekey.id),
      );
    } catch (e) {
      debugLog?.call('courier seal failed: $e');
      return 0;
    }
    final envelope = CourierEnvelope(
      // The tag always derives from the identity key so the recipient recognizes their mail.
      recipientTag: await CourierEnvelope.recipientTagFor(
        noiseStaticKey: key,
        epochDay: CourierEnvelope.epochDayFor(now),
      ),
      expiryMs: now + CourierEnvelope.maxLifetimeMs,
      ciphertext: sealed,
      copies: copies,
      prekeyId: prekey?.id,
    );
    final bytes = envelope.encode();
    if (bytes == null) return 0;

    var handed = 0;
    for (final peer in _peers.values) {
      if (handed >= couriers.maxCouriersPerDeposit) break;
      if (!CourierStore.mayCourier(
        isVerified: peer.isVerified,
        isSelf: peer.peerID == identity.peerID,
        isRecipient: peer.peerID == recipientPeerID,
      )) {
        continue;
      }
      final recipient = _peerIdBytes(peer.peerID);
      if (recipient == null) continue;
      try {
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.courierEnvelope,
          payload: bytes,
          recipientID: recipient,
          ttl: 0,
        ));
        handed++;
      } catch (_) {
        // A courier that refuses is not a failure; try the next.
      }
    }
    debugLog?.call('courier deposit: $handed carrier(s)');
    return handed;
  }

  /// Opens and delivers an envelope if ours, else carries it.
  Future<void> _handleCourierEnvelope(
      BitchatPacket packet, String senderPeerID) async {
    final envelope = CourierEnvelope.decode(packet.payload);
    if (envelope == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (envelope.isExpiredAt(now)) return;

    // Only the recipient can open it, so opening is the test.
    final pkId = envelope.prekeyId;
    final pkPriv = pkId == null ? null : prekeys.privateKeyFor(pkId);
    final pkPub = pkId == null ? null : prekeys.publicKeyFor(pkId);
    try {
      if (pkId != null && (pkPriv == null || pkPub == null)) {
        throw StateError('not our prekey');
      }
      final (plaintext, senderStatic) = await CourierSeal.open(
        ciphertext: envelope.ciphertext,
        localStaticPrivate: pkPriv ?? identity.staticPrivate,
        localStaticPublic: pkPub ?? identity.staticPublic,
        prologue: pkId == null ? null : courierPrekeyPrologue(pkId),
      );
      if (pkId != null && prekeys.markConsumed(pkId)) {
        // First open: republish the shrunken batch; the private half survives a grace window.
        onPrekeysChanged?.call(prekeys.encode());
        unawaited(publishPrekeyBundle());
      }
      // The `ss` DH authenticates the sender's static key, so this is the real author.
      final originPeerID = _peerIdForNoiseKey(senderStatic);
      debugLog?.call('courier envelope OPENED from $originPeerID '
          '(carried by $senderPeerID)');
      await _dispatchNoisePayload(originPeerID, plaintext);
      return;
    } catch (_) {
      // Not ours: carry it.
    }

    final key = _courierKey(envelope.ciphertext);
    if (couriers.accept(envelope, key)) {
      debugLog?.call('carrying courier envelope for someone (copies='
          '${envelope.copies})');
      couriers.markHandedTo(key, senderPeerID);
    }
  }

  /// Delivers mail carried for [peer] and sprays a share of anything still spreading.
  Future<void> _courierEncounter(MeshPeer peer) async {
    if (couriers.length == 0) return;
    final staticKey = peer.noisePublicKey;
    final recipient = _peerIdBytes(peer.peerID);
    if (recipient == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Delivery: mail addressed to this peer, matched on the rotating tag.
    if (staticKey != null && staticKey.length == 32) {
      final tags = await CourierEnvelope.candidateTagsFor(
        noiseStaticKey: staticKey,
        nowMs: now,
      );
      for (final entry in couriers.forTags(tags)) {
        final bytes = entry.value.envelope.encode();
        if (bytes == null) continue;
        try {
          await _sendPacket(await _buildPacket(
            type: MeshMessageType.courierEnvelope,
            payload: bytes,
            recipientID: recipient,
            ttl: 0,
          ));
          // Delivered: stop carrying it; the sender's retries cover a failed open.
          couriers.drop(entry.key);
          debugLog?.call('courier delivered to ${peer.peerID}');
        } catch (_) {}
      }
    }

    // Spray only to verified peers.
    if (!CourierStore.mayCourier(
      isVerified: peer.isVerified,
      isSelf: peer.peerID == identity.peerID,
      isRecipient: false,
    )) {
      return;
    }
    for (final entry in couriers.sprayableTo(peer.peerID)) {
      final copies = entry.value.envelope.copies;
      final share = CourierStore.sprayShare(copies);
      if (share <= 0) continue;
      final bytes = entry.value.envelope.withCopies(share).encode();
      if (bytes == null) continue;
      try {
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.courierEnvelope,
          payload: bytes,
          recipientID: recipient,
          ttl: 0,
        ));
        couriers.setCopies(entry.key, CourierStore.keepShare(copies));
        couriers.markHandedTo(entry.key, peer.peerID);
      } catch (_) {}
    }
  }

  /// PeerID of a Noise static key: first 16 hex chars of its SHA-256.
  static String _peerIdForNoiseKey(Uint8List staticPublicKey) =>
      _hex(NoiseCrypto.sha256(staticPublicKey)).substring(0, 16);

  /// Stable key so the same mail from two couriers is carried once.
  String _courierKey(Uint8List ciphertext) =>
      _hex(NoiseCrypto.sha256(ciphertext)).substring(0, 32);

  static Uint8List? _fromHex(String hex) {
    if (hex.length.isOdd || hex.isEmpty) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  // Gossip sync

  /// Files our own public sends, which the inbound path drops as self-echoes.
  void _rememberOwnPublic(BitchatPacket packet) {
    if (!packet.isBroadcast || !GossipSync.isSyncable(packet.type)) return;
    gossip.onPublicPacketSeen(packet);
    _gossipDirty = true;
  }

  /// Asks each peer on its own schedule to reconcile; directed with TTL 0, never relayed.
  Future<void> _gossipTick() async {
    if (!_running) return;
    if (gossip.prune()) _gossipDirty = true;
    // Carried mail expires too.
    couriers.prune();
    // Delete consumed prekeys past their grace window; this is where forward secrecy happens.
    if (prekeys.prune()) onPrekeysChanged?.call(prekeys.encode());
    if (_gossipDirty) {
      _gossipDirty = false;
      _persistGossipArchive();
    }
    final peerIds = _peers.keys.toList(growable: false);
    if (peerIds.isEmpty) return;
    for (final peerID in peerIds) {
      if (!gossip.shouldAsk(peerID)) continue;
      gossip.markAsked(peerID);
      final recipient = _peerIdBytes(peerID);
      if (recipient == null) continue;
      try {
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.requestSync,
          payload: gossip.buildRequest(),
          recipientID: recipient,
          ttl: 0,
        ));
      } catch (_) {
        // Best-effort: a failed sync round costs history, never the session.
      }
    }
  }

  /// Answers a sync request directed with TTL 0 so replies never re-flood.
  Future<void> _handleRequestSync(
      BitchatPacket packet, String senderPeerID) async {
    if (!gossip.shouldAnswer(senderPeerID)) {
      debugLog?.call('  ↳ sync from $senderPeerID rate-limited');
      return;
    }
    final request = RequestSyncPacket.decode(packet.payload);
    if (request == null) {
      debugLog?.call('  ↳ sync from $senderPeerID — undecodable');
      return;
    }
    gossip.markAnswered(senderPeerID);
    final missing = gossip.packetsMissingFrom(request);
    if (missing.isEmpty) return;
    debugLog?.call('  ↳ sync to $senderPeerID: ${missing.length} packet(s)');
    final recipient = _peerIdBytes(senderPeerID);
    for (final pkt in missing) {
      try {
        // Re-addressed to the requester instead of re-broadcast.
        await _sendPacket(BitchatPacket(
          version: pkt.version,
          type: pkt.type,
          senderID: pkt.senderID,
          recipientID: recipient,
          timestamp: pkt.timestamp,
          payload: pkt.payload,
          signature: pkt.signature,
          ttl: 0,
        ));
      } catch (_) {
        // One packet failing must not abandon the round.
      }
      await Future<void>.delayed(MeshConstants.interFragmentDelay);
    }
  }

  /// Sends to [peerID], or nothing when it is invalid; never falls back to an unaddressed packet.
  Future<void> _sendDirected({
    required String peerID,
    required int type,
    required Uint8List payload,
    int? ttl,
  }) async {
    final recipient = _peerIdBytes(peerID);
    if (recipient == null) {
      debugLog?.call('refusing to send type $type to malformed peerID');
      return;
    }
    await _sendPacket(await _buildPacket(
      type: type,
      payload: payload,
      recipientID: recipient,
      ttl: ttl,
    ));
  }

  /// The 8 raw bytes of a 16-hex peerID, or null.
  static Uint8List? _peerIdBytes(String peerID) {
    if (peerID.length != 16) return null;
    final out = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      final byte = int.tryParse(peerID.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  void _persistGossipArchive() {
    final hook = onGossipArchiveChanged;
    if (hook == null) return;
    try {
      hook(gossip.encodeArchive());
    } catch (_) {}
  }

  Future<BitchatPacket> _buildPacket({
    required int type,
    required Uint8List payload,
    Uint8List? recipientID,
    bool sign = false,
    int? ttl,
  }) async {
    final packet = BitchatPacket(
      version: packetVersionForPayload(payload.length),
      type: type,
      senderID: identity.peerIdBytes,
      recipientID: recipientID,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
      ttl: ttl ?? MeshConstants.messageTtl,
    );
    if (sign) {
      final signable = packet.toBytesForSigning();
      if (signable != null) {
        packet.signature = await identity.sign(signable);
      }
    }
    return packet;
  }

  /// Serializes, fragments and broadcasts; paces fragments so iOS's bounded send queue doesn't drop them.
  Future<void> _sendPacket(BitchatPacket packet) async {
    final fragments = PacketFragmenter.fragment(packet);
    final paced = fragments.length > 1;
    for (var i = 0; i < fragments.length; i++) {
      final bytes = fragments[i].toBytes();
      if (bytes != null) await _broadcast(bytes);
      if (paced && i != fragments.length - 1) {
        await Future<void>.delayed(MeshConstants.interFragmentDelay);
      }
    }
  }

  Future<void> _broadcast(Uint8List? bytes) async {
    if (bytes == null) return;
    await _transport.broadcast(bytes);
  }

  void _scheduleRelay(BitchatPacket packet) {
    final relayed = packet.copyWith(ttl: packet.ttl - 1);
    final jitter = MeshConstants.relayJitterMinMs +
        _random.nextInt(
            MeshConstants.relayJitterMaxMs - MeshConstants.relayJitterMinMs);
    Timer(Duration(milliseconds: jitter), () {
      if (_running) unawaited(_sendPacket(relayed));
    });
  }

  // Peer bookkeeping

  void _touchPeer(String peerID, {String? nickname}) {
    final peer = _peers.putIfAbsent(peerID, () => MeshPeer(peerID: peerID));
    if (nickname != null && nickname.isNotEmpty) peer.nickname = nickname;
    peer.touch();
    _emitPeers();
  }

  void _removePeer(String peerID) {
    if (_peers.remove(peerID) != null) {
      _noise.remove(peerID);
      _emitPeers();
    }
  }

  void _cleanupStalePeers() {
    final now = DateTime.now();
    final removed = <String>[];
    _peers.removeWhere((id, peer) {
      final stale =
          now.difference(peer.lastSeen) > MeshConstants.stalePeerTimeout;
      if (stale) removed.add(id);
      return stale;
    });
    for (final id in removed) {
      _noise.remove(id);
    }
    if (removed.isNotEmpty) _emitPeers();
  }

  void _emitPeers() {
    if (!_peersChanged.isClosed) _peersChanged.add(peers);
  }

  // Utilities

  List<String> _chunkContent(String content) {
    // Chunk on UTF-8 boundaries for the 255-byte cap without splitting a rune.
    final chunks = <String>[];
    final buffer = StringBuffer();
    var byteCount = 0;
    for (final rune in content.runes) {
      final ch = String.fromCharCode(rune);
      final len = ch.codeUnits
          .fold<int>(0, (n, u) => n + (u <= 0x7F ? 1 : (u <= 0x7FF ? 2 : 3)));
      if (byteCount + len > PrivateMessagePacket.maxContentBytes) {
        chunks.add(buffer.toString());
        buffer.clear();
        byteCount = 0;
      }
      buffer.write(ch);
      byteCount += len;
    }
    if (buffer.isNotEmpty || chunks.isEmpty) chunks.add(buffer.toString());
    return chunks;
  }

  // Static so static derivations like [_peerIdForNoiseKey] can use it.
  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _ReactionData {
  _ReactionData(this.targetId, this.emoji, this.isRemove, this.reactorNick);
  final String targetId;
  final String emoji;
  final bool isRemove;
  final String reactorNick;
}
