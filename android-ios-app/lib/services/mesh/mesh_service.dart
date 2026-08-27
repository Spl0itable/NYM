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

/// The heart of the Bluetooth mesh: it owns the radio [MeshTransport], the Noise
/// sessions, peer tracking, deduplication, TTL relay and fragmentation, and
/// turns raw frames into the high-level [MeshPublicMessage] / [MeshPrivateMessage]
/// / [MeshReceipt] events the app consumes — and the reverse for sending.
///
/// Everything on the wire is byte-compatible with bitchat, so a Nymchat device
/// running this service participates in the same mesh as real bitchat devices.
class MeshService {
  MeshService({
    required this.identity,
    required MeshTransport transport,
    required String Function() nicknameProvider,
    Uint8List? Function()? nostrLinkProvider,
    Future<MeshProfile?> Function(MeshProfileRequest request)? profileProvider,
  })  : _transport = transport,
        _nicknameProvider = nicknameProvider,
        _nostrLinkProvider = nostrLinkProvider,
        _profileProvider = profileProvider;

  final NoiseIdentity identity;
  final MeshTransport _transport;
  final String Function() _nicknameProvider;

  /// Supplies our Nostr-identity link ([NostrLink]) to advertise, or null when
  /// we have no local Nostr key to sign it with.
  final Uint8List? Function()? _nostrLinkProvider;

  /// Builds our own [MeshProfile] (avatar/banner bytes) to answer an inbound
  /// profile request. Null when we have no shareable profile.
  final Future<MeshProfile?> Function(MeshProfileRequest request)?
      _profileProvider;

  late final NoiseSessionManager _noise = NoiseSessionManager(identity);
  final MeshChannelEncryption _channelCrypto = MeshChannelEncryption();
  final SeenPackets _seen = SeenPackets();
  final FragmentReassembler _reassembler = FragmentReassembler();
  final _uuid = const Uuid();
  final _random = Random();

  final Map<String, MeshPeer> _peers = {};

  /// Plaintext we owe a peer, queued until the Noise session establishes.
  final Map<String, List<Uint8List>> _pendingPlaintext = {};

  /// Encrypted transport payloads that arrived before our session with the peer
  /// finished establishing (the initiator sends data the instant it completes
  /// the handshake, which can outrace our own completion). Drained on establish.
  final Map<String, List<Uint8List>> _pendingEncrypted = {};

  final _publicMessages = StreamController<MeshPublicMessage>.broadcast();
  final _privateMessages = StreamController<MeshPrivateMessage>.broadcast();
  final _receipts = StreamController<MeshReceipt>.broadcast();
  final _profiles = StreamController<MeshProfileReceived>.broadcast();
  final _files = StreamController<MeshFileReceived>.broadcast();
  final _typing = StreamController<MeshTypingEvent>.broadcast();
  final _reactions = StreamController<MeshReactionEvent>.broadcast();
  final _peersChanged = StreamController<List<MeshPeer>>.broadcast();

  /// Peers we've already asked for a profile (avoids re-requesting on every
  /// announce beacon).
  final Set<String> _profileRequested = {};

  StreamSubscription<MeshInboundFrame>? _inboundSub;
  StreamSubscription<MeshLinkEvent>? _linkSub;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  Timer? _syncTimer;
  bool _running = false;

  /// Recent public history, reconciled with neighbours so a peer that was out
  /// of range — or in another mesh partition — still receives it. See
  /// [GossipSync]; the radio work lives here, the policy lives there.
  final GossipSync gossip = GossipSync();

  /// Mail this device is carrying for other people — sealed messages bound for
  /// peers who were not in range when they were sent. See [CourierStore]; the
  /// radio work lives here, the policy (who may deposit, who may carry, how far
  /// a copy spreads) lives there.
  final CourierStore couriers = CourierStore();

  /// Whether Ghost Mode is on. Wired by the bridge. A ghosted device never
  /// deposits mail with a courier: the deposit would outlive the epoch and
  /// associate a throwaway identity with a message someone else still holds.
  bool Function()? isGhostMode;

  /// Whether a conversation with this peer is pinned to the mesh because it
  /// began under a ghost identity. Wired by the bridge; such a conversation
  /// never leaves the radio, courier included.
  bool Function(String recipientStaticKeyHex)? isGhostPinned;

  /// This device's one-time prekeys. Publishing them lets a sender seal courier
  /// mail to a key we DELETE after use, so an envelope captured in transit
  /// cannot be opened later even if our identity key is compromised.
  final LocalPrekeys prekeys = LocalPrekeys();

  /// Peers' published bundles, newest per device. Fed by gossip, so a bundle
  /// reaches us while its owner is away — which is exactly when their mail is
  /// being couriered.
  final Map<String, PrekeyBundle> _peerPrekeys = <String, PrekeyBundle>{};

  /// Called when our prekey batch changes and should be re-published. Wired by
  /// the bridge so the private halves are persisted; null in tests.
  void Function(String encoded)? onPrekeysChanged;

  /// Completed [ping] probes, for the mesh diagnostics panel.
  Stream<MeshPingResult> get onPingResult => _pingResults.stream;
  final _pingResults = StreamController<MeshPingResult>.broadcast();

  /// Outstanding probes: nonce hex → (peerID, sent-at, origin TTL).
  final Map<String, (String, int, int)> _pendingPings = {};

  /// Signed Nostr events a mesh-only peer has asked us to publish, and events
  /// a gateway has rebroadcast to us. Wired by the bridge, which owns the relay
  /// connection; null when this device is not acting as a gateway.
  void Function(NostrCarrierPacket carrier, String fromPeerID)? onNostrCarrier;

  /// Called whenever the gossip store changes enough to be worth persisting, so
  /// the carried history survives a restart. Wired by the bridge; null in
  /// tests.
  void Function(String archive)? onGossipArchiveChanged;

  /// Set when the store has changed since the last archive write. Encoding the
  /// whole store per packet would be absurd in a busy room, so the tick does
  /// it.
  bool _gossipDirty = false;

  // ---- Public API -----------------------------------------------------------

  String get myPeerID => identity.peerID;

  /// The live peer record for [peerID] (announced nickname + keys), or null if
  /// not currently known. Lets the bridge resolve inbound identity from the same
  /// object the peers list uses, independent of stream ordering.
  MeshPeer? peerById(String peerID) => _peers[peerID];

  /// The peer's 32-byte Noise static public key as 64-hex, or null if unknown.
  /// Resolved from the announced peer record first, then the established Noise
  /// session's remote static key — so an ENCRYPTED private message (which can
  /// only arrive over a completed handshake) can ALWAYS resolve the sender's
  /// stable, real identity, even if that peer's announce hasn't been processed
  /// yet. This is the canonical mesh identity (bitchat keys peers by it, and the
  /// 16-hex peerID is just its SHA-256 fingerprint prefix).
  String? noiseKeyHexForPeer(String peerID) {
    final fromPeer = _peers[peerID]?.noisePublicKey;
    if (fromPeer != null && fromPeer.length == 32) return _hex(fromPeer);
    final fromSession = _noise.remoteStaticKey(peerID);
    if (fromSession != null && fromSession.length == 32)
      return _hex(fromSession);
    return null;
  }

  bool get isRunning => _running;
  int get connectedLinkCount => _transport.connectedLinkCount;
  MeshTransportAvailability get availability => _transport.availability;

  /// Opens the OS settings page so the user can grant Bluetooth permission.
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

  /// Broadcasts an emoji reaction to a public/channel message [targetId].
  Future<void> sendChannelReaction(
      String targetId, String emoji, bool remove) async {
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.nymReaction,
      payload: _encodeReaction(targetId, emoji, remove),
    ));
  }

  /// Sends an encrypted emoji reaction to a 1:1 message [targetId] over the
  /// Noise session with [peerID] (handshaking first if needed).
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

  /// Broadcasts (or directs) an ephemeral typing indicator. [channel] tags a
  /// channel indicator (null = nearby); [toPeerID] directs it to a single peer
  /// for a 1:1 DM. Nymchat-only — bitchat ignores the unknown packet type.
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

  /// Powers up the radio and joins the mesh. Returns radio availability.
  Future<MeshTransportAvailability> start() async {
    if (_running) return _transport.availability;
    // Subscribe before powering up the radio so no early frame or link event
    // (e.g. a peer that links during startup) is missed.
    _running = true;
    debugLog?.call('service.start(): peerID=$myPeerID');
    _inboundSub = _transport.inbound.listen(_onFrame);
    _linkSub = _transport.links.listen(_onLink);
    final availability = await _transport.start();
    debugLog?.call('transport up → availability=${availability.name}');
    _scheduleAnnounce();
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _cleanupStalePeers());
    // Reconcile public history with whoever is in range. The per-peer schedule
    // lives in [GossipSync]; this tick just gives it a heartbeat.
    _syncTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_gossipTick()));
    await _broadcastAnnounce();
    // Publish our one-time prekeys so senders can seal courier mail to a key we
    // delete after use rather than to our long-lived identity key. Broadcast
    // and gossiped, because it has to reach people while we are AWAY.
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

  /// Broadcasts a public [content] message (optionally to a [channel]).
  /// Returns the generated message id.
  Future<String> sendPublicMessage(
    String content, {
    String? channel,
    List<String>? mentions,
  }) async {
    final timestampMs = DateTime.now().millisecondsSinceEpoch;
    // A NAMED channel (anything other than the default #mesh public chat) is
    // Nymchat-only: bitchat has no named channels over the BLE mesh (its
    // hashtag / geohash channels ride Nostr, not Bluetooth). Carry the channel
    // name in a BitchatMessage TLV under the Nymchat-only nymChannelMessage
    // type so it routes to the RIGHT channel on other Nymchat devices instead
    // of collapsing into #mesh — and so bitchat (which ignores 0x54) never
    // mis-renders it. The body is AES-sealed when we hold a password key for
    // the channel, otherwise sent as plaintext in the TLV.
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

    // Public mesh chat (bitchat's "Mesh", channel == null): the wire payload is
    // the RAW UTF-8
    // content — NOT a TLV. bitchat-iOS/android both read a broadcast MESSAGE's
    // payload straight back as a UTF-8 string (`String(data: payload)`), derive
    // the message id from the signed fields, and take the sender nickname from
    // the peer's announce. Sending a BitchatMessage TLV here makes bitchat show
    // (and dedup) binary garbage — the reason #mesh never interoperated. The id
    // is content-derived so a relayed copy dedups against the original.
    final payload = Uint8List.fromList(utf8.encode(content));
    final packet = await _buildPacket(
      type: MeshMessageType.message,
      payload: payload,
      // Broadcast recipient (0xFF×8) matches bitchat-android; bitchat-iOS sends
      // a null recipient but accepts either, since each packet's signature is
      // verified against the recipientID it actually carries.
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

  /// Joins/creates an encrypted mesh group [channel] with a shared [password]
  /// (bitchat password channels). Members who set the same password can read it.
  Future<void> setChannelPassword(String channel, String password) =>
      _channelCrypto.setChannelPassword(channel, password);

  /// True when we hold the key for an encrypted [channel].
  bool hasChannelKey(String channel) => _channelCrypto.hasKey(channel);

  void leaveChannel(String channel) => _channelCrypto.removeChannel(channel);

  /// Sends a private [content] message to [peerID], performing a Noise handshake
  /// first if needed (the message is queued and flushed on establishment).
  /// Long content is chunked into 255-byte private-message packets. Returns the
  /// message id of the first chunk.
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

  /// Sends a file/media [bytes] to [peerID] as an encrypted DM attachment
  /// (Noise-sealed, fragmented). Reuses the same session as text DMs.
  Future<void> sendFileToPeer(
    String peerID,
    String fileName,
    String mimeType,
    Uint8List bytes,
  ) async {
    final file = BitchatFilePacket(
        fileName: fileName, mimeType: mimeType, content: bytes);
    final encoded = file.encode();
    if (encoded == null) return;
    final plaintext =
        NoisePayload(NoisePayloadType.fileTransfer, encoded).encode();
    await _sendOrQueueEncrypted(peerID, plaintext);
  }

  /// Broadcasts a file/media [bytes] to the mesh (Nearby or a public group),
  /// as a fragmented FILE_TRANSFER packet.
  Future<void> sendFileBroadcast(
    String fileName,
    String mimeType,
    Uint8List bytes,
  ) async {
    final file = BitchatFilePacket(
        fileName: fileName, mimeType: mimeType, content: bytes);
    final encoded = file.encode();
    if (encoded == null) return;
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.fileTransfer,
      payload: encoded,
      // bitchat drops a raw (non-Noise) file transfer without a valid sender
      // signature (BLEFileTransferHandler), so a broadcast image must be signed
      // exactly like a public message or it never appears on the far side.
      recipientID: kBroadcastRecipient,
      sign: true,
    ));
  }

  /// Sends a read receipt for [messageId] to [peerID].
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

  // ---- Inbound handling -----------------------------------------------------

  /// Debug sink for the receive pipeline (wired to the in-app mesh diagnostics
  /// panel by the bridge). Null in production/tests unless set.
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
    // Ignore our own echoes.
    if (senderPeerID == identity.peerID) return;

    debugLog?.call('pkt type=0x${packet.type.toRadixString(16)} '
        'from=$senderPeerID '
        'rcpt=${packet.recipientID == null ? 'null' : (packet.isBroadcast ? 'bcast' : 'direct')} '
        '${packet.payload.length}B');

    // Deduplicate the controlled flood.
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

    // Remember public traffic so this device can serve it to a peer who was
    // out of range when it went by. Directed packets are refused inside — the
    // store is public history, never anybody's private mail.
    if (packet.isBroadcast && GossipSync.isSyncable(packet.type)) {
      gossip.onPublicPacketSeen(packet);
      // Persisting on the tick rather than here: encoding the whole store is
      // far too expensive to do per packet in a busy room.
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
        // bitchat sends a PM image as a DIRECTED (rcpt=our peerID) plaintext
        // fileTransfer, and a #mesh image as a broadcast one. Route by the
        // recipient so a directed file lands in the sender's DM, not #mesh.
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
        // Directed mail. Try to open it: if it is ours, deliver it; if not,
        // carry it for whoever it belongs to.
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
        // Directed = "publish this for me"; broadcast = a gateway relaying what
        // it heard. Either way the carried event is verified by the handler,
        // never trusted because a gateway passed it on.
        _handleNostrCarrier(packet, senderPeerID);
        break;
      case MeshMessageType.requestSync:
        // Local-only by design: a sync request is answered by the peer that
        // heard it and never relayed, which is why it carries TTL 0 below.
        if (forUs || packet.isBroadcast) {
          await _handleRequestSync(packet, senderPeerID);
        }
        break;
      default:
        break;
    }

    // Relay the controlled flood (never relay packets addressed solely to us,
    // and never relay a directed packet we just consumed as recipient).
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
      // …and, when the announcement is signed, the signature must check out.
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

    // Resolve a Nostr-identity link, if the peer advertised one and the schnorr
    // signature binds it to the Noise key they just announced.
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
    // Meeting a peer is the moment mail can move: hand them anything we carry
    // for them, and a share of anything still spreading. Best-effort and
    // unawaited so a slow radio never stalls the announce path.
    unawaited(_courierEncounter(peer));
  }

  /// bitchat public mesh message ([MeshMessageType.message]): the payload is the
  /// raw UTF-8 content — no TLV. The sender nickname comes from the peer's
  /// announce (the wire carries none), the timestamp from the packet header, and
  /// the id is content-derived so it matches across our own send/relay copies.
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

  /// Nymchat NAMED-channel broadcast ([MeshMessageType.nymChannelMessage]): a
  /// [BitchatMessage] TLV carrying the channel name and either plaintext content
  /// or, for a password channel, AES-sealed content we can read only if we hold
  /// the key (non-members drop it). Routes to the named channel — NOT #mesh.
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
      // A fresh/in-progress handshake supersedes any prior session, so the
      // once-per-session peer-state proof must be re-sent on the new session.
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
        // Announce our capabilities inside the session BEFORE flushing queued
        // media, so bitchat has authenticated us as private-media-capable by
        // the time our encrypted attachments arrive.
        await _sendAuthenticatedPeerState(senderPeerID);
        await _flushPending(senderPeerID);
        await _drainPendingEncrypted(senderPeerID);
      }
    } catch (_) {
      // Handshake failed or peerID binding rejected; drop silently.
    }
  }

  /// Peers we've already sent the current session's [AuthenticatedPeerStatePacket]
  /// to. Cleared per peer when a new handshake begins so each session re-proves.
  final Set<String> _peerStateSentTo = {};

  /// Sends the session-authenticated capability proof (Noise `0x21`) so the far
  /// side treats us as private-media-capable — bitchat then stops warning that
  /// our client can't receive encrypted private media and accepts our
  /// Noise-sealed attachments. Sent at most once per established session.
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
      // Session still handshaking — hold the frame and process it on establish
      // rather than dropping it (fixes the initiator-sends-immediately race).
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

  /// Handles a decrypted transport payload from [senderPeerID].
  ///
  /// Shared by the live Noise session path and the courier path: an envelope
  /// opened out of a courier's hands yields the SAME plaintext a session would
  /// have, so a message that arrived by mail behaves exactly like one that
  /// arrived over the air.
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
          // Echo our own proof back once (bitchat echoes at most once when the
          // remote state arrives), so the session is authenticated in both
          // directions even if the peer's state beat our handshake-completion
          // send.
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

  /// Asks [peerID] for their rich profile (avatar/banner) over the mesh, once.
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
      // NOTE: a profile response is NOT a signed identity link, so its claimed
      // nostrPubkey is deliberately NOT adopted here — only a verified NostrLink
      // (from the announcement) may set peer.nostrPubkey. This prevents a peer
      // from claiming (and skinning messages as) another Nostr identity.
      peer.touch();
      _emitPeers();
    }
    _profiles.add(MeshProfileReceived(peerID: senderPeerID, profile: profile));
  }

  void _onLink(MeshLinkEvent event) {
    // A new direct link is a good moment to (re)announce so the peer learns us
    // immediately rather than waiting for the periodic beacon.
    if (event.change == MeshLinkChange.connected) {
      unawaited(_broadcastAnnounce());
    }
  }

  // ---- Outbound helpers -----------------------------------------------------

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
      // New session ⇒ the peer-state proof must be re-sent once it establishes.
      _peerStateSentTo.remove(peerID);
      final msg1 = await _noise.initiateHandshake(peerID);
      await _sendDirected(
        peerID: peerID,
        type: MeshMessageType.noiseHandshake,
        payload: msg1,
      );
    }
  }

  /// Re-processes encrypted frames that arrived before the session existed.
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

  /// Capability bitfield advertised in the announce (bitchat `PeerCapabilities`,
  /// little-endian, trailing zero bytes dropped). We set bit 8 = `privateMedia`
  /// (encrypted direct-message media as Noise payload 0x20) — which we DO
  /// support ([_handleEncrypted]'s fileTransfer case) — so bitchat stops
  /// warning that our client can't receive encrypted private media and sends it
  /// Noise-sealed instead of as a signed-but-plaintext directed file. 0x100
  /// little-endian is [0x00, 0x01].
  static final Uint8List _capabilities = Uint8List.fromList([0x00, 0x01]);

  /// Schedules the next identity announce on a JITTERED, load-adaptive gap
  /// instead of a fixed period.
  ///
  /// Two reasons. A metronome is a fingerprint in its own right — a listener
  /// can follow a device between places by beacon rhythm without decoding any
  /// field — and while no peer is known the beacons buy nothing, so the gap
  /// stretches to [MeshConstants.announceIntervalIdle].
  ///
  /// Both bounds stay far below bitchat's [MeshConstants.stalePeerTimeout], so
  /// a peer never drops us for going quiet, and the announce contents are
  /// unchanged — this is invisible to bitchat peers.
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

  /// Broadcasts our identity announcement.
  ///
  /// NOTE ON MESH ANONYMITY, before anyone reaches for peerID rotation:
  /// everything below goes out UNENCRYPTED, on every cycle — the nickname, the
  /// Noise static key (from which the peerID derives), the signing key, and
  /// `nostrLink`, which is `nostrPubkey(32) ‖ signature(64)`, i.e. the user's
  /// actual Nostr identity.
  ///
  /// So rotating the peerID on an epoch — bitchat's WHITEPAPER §9 design, and
  /// the obvious response to a stable BLE identifier being physically
  /// trackable — buys NOTHING on its own: a tracker follows the nostrLink or
  /// the nickname instead. A cloaking mode has to suppress all three together
  /// or none of them.
  ///
  /// That is exactly what Ghost Mode does (features/mesh/ghost_mode.dart): it
  /// rotates the Noise static key, the signing key, the nickname and the
  /// nostrLink TOGETHER, on an epoch. The nostrLink it advertises is real but
  /// ephemeral, so peers can still reach the device while nothing resolves to
  /// the user's npub. It stays opt-in because losing that link is a real cost,
  /// not a free win.
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

  /// Builds a packet from us with the standard TTL, optionally Ed25519-signed.
  // ---- Diagnostics: ping / pong ---------------------------------------------

  /// Probes [peerID]: are you there, and how many links away?
  ///
  /// A peer list cannot tell you the difference between someone in the same
  /// room and someone three relays away. The reply carries the TTL this packet
  /// was LAUNCHED with, so the hop count falls out of comparing it against the
  /// TTL that arrives ([MeshPingPayload.hopCount]). The nonce is unguessable,
  /// so only a genuine answer to this probe can complete it.
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

  /// Answers a probe by echoing its nonce, with our own launch TTL so the far
  /// end can measure the return path too.
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

  /// Completes a probe. An unknown nonce is silently dropped: it answers a
  /// probe we never sent, which is either a stale reply or somebody guessing.
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

  // ---- Gateway mode: carrying Nostr events ---------------------------------

  /// Asks [gatewayPeerID] to publish a signed Nostr event for us.
  ///
  /// The sender outbox waits for OUR internet to come back. This does not wait
  /// for ours: one peer with a signal is enough for the whole room. The event
  /// is signed by us before it leaves, so the gateway is a postbox — it cannot
  /// alter or forge what it publishes, and the relays would reject it if it
  /// tried.
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

  /// Rebroadcasts a relay event to mesh-only peers, so they can READ a geohash
  /// channel and not only write to it.
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
    // The bridge verifies the signature before publishing or displaying. A
    // gateway relays; it does not vouch.
    onNostrCarrier?.call(carrier, senderPeerID);
  }

  // ---- Prekey bundles -------------------------------------------------------

  /// Signs and broadcasts our current batch of one-time prekeys.
  ///
  /// Broadcast rather than directed, and gossip-synced, because the whole point
  /// is that a bundle reaches senders while we are AWAY. Anyone holding our
  /// announce-verified signing key can check it offline, so it can spread
  /// through devices that have never spoken to us.
  Future<bool> publishPrekeyBundle() async {
    // Never while ghosted. Courier mail to or from a ghost is refused at both
    // ends ([CourierStore.mayDeposit]), so the bundle could not deliver
    // anything — it would only be one more thing the epoch broadcasts.
    if (isGhostMode?.call() ?? false) return false;
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

  /// Files a peer's bundle after verifying it against the signing key their
  /// announce bound to that Noise key.
  ///
  /// Verification is what makes gossip safe: without it, anyone could publish
  /// prekeys "for" someone else and harvest mail sealed to keys they hold.
  void _handlePrekeyBundle(BitchatPacket packet, String senderPeerID) {
    final bundle = PrekeyBundle.decode(packet.payload);
    if (bundle == null) return;
    final ownerHex = _hex(bundle.noiseStaticPublicKey);
    // The signing key comes from the owner's own verified announce, NOT from
    // the packet — a relayed bundle's carrier is not its author.
    final ownerPeerID = _peerIdForNoiseKey(bundle.noiseStaticPublicKey);
    final owner = _peers[ownerPeerID];
    final signingKey = owner?.signingPublicKey;
    if (owner == null || signingKey == null || !owner.isVerified) {
      debugLog?.call('prekey bundle from unknown/unverified owner — dropped');
      return;
    }
    final existing = _peerPrekeys[ownerHex];
    // A newer bundle replaces an older one; an older one is refused so a
    // replayed bundle cannot resurrect keys its owner has already deleted.
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

  // ---- Couriers -------------------------------------------------------------

  /// The Noise transport payload a private message rides in, built without a
  /// session — so a courier envelope can carry exactly what a live session
  /// would have, and the receiver's dispatch cannot tell the difference.
  ///
  /// Null when the content does not fit one packet (the TLV length is a single
  /// byte). Couriered mail is not chunked: a stranger carries one envelope, not
  /// a reassembly job.
  static Uint8List? privateMessagePayload({
    required String messageId,
    required String content,
  }) {
    final body =
        PrivateMessagePacket(messageID: messageId, content: content).encode();
    if (body == null) return null;
    return NoisePayload(NoisePayloadType.privateMessage, body).encode();
  }

  /// Seals [payload] to [recipientStaticKeyHex] and hands sealed copies to
  /// nearby peers, who carry it and deliver it if they meet the recipient.
  ///
  /// The last-resort delivery path: the recipient is not in range and, with no
  /// internet, the sender outbox cannot help either. Returns how many couriers
  /// took a copy — zero when the deposit was refused, which the caller should
  /// treat as "no worse off", never as an error.
  ///
  /// Refusal is the important half. [CourierStore.mayDeposit] blocks a
  /// ghost-pinned conversation and a ghosted sender outright: handing an
  /// envelope to a courier tells that courier a message exists and that we sent
  /// it, and a ghost identity exists precisely so that no such link is made.
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
    // Prefer a one-time PREKEY over the long-lived static key when the
    // recipient has published one. Both seal the same way; the difference is
    // that they DELETE a prekey after use, so an envelope captured in transit
    // cannot be opened later even if their identity key is compromised. Falling
    // back to the static key keeps mail flowing to a peer whose bundle we have
    // never seen — worse secrecy, but delivered.
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
      // The TAG is always derived from the identity key, prekey or not: it is
      // how the recipient recognises their own mail, and they cannot look up an
      // envelope by a prekey they may already have retired.
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
        // A courier that will not take it is not a failure; try the next.
      }
    }
    debugLog?.call('courier deposit: $handed carrier(s)');
    return handed;
  }

  /// An envelope arrived. Either it is ours — open and deliver it — or it is
  /// somebody else's mail we have been asked to carry.
  Future<void> _handleCourierEnvelope(
      BitchatPacket packet, String senderPeerID) async {
    final envelope = CourierEnvelope.decode(packet.payload);
    if (envelope == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (envelope.isExpiredAt(now)) return;

    // Is it for us? Only the recipient can open it, so this is also the test.
    // A v2 envelope names the prekey it was sealed to; if that key was never
    // ours (or its grace window has lapsed) the open fails and we simply carry
    // it, exactly as for any other stranger's mail.
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
        // First open of this key: republish the shrunken batch. Redeliveries
        // of the same envelope arrive later (spray-and-wait), so the private
        // half survives a grace window before it is really deleted.
        onPrekeysChanged?.call(prekeys.encode());
        unawaited(publishPrekeyBundle());
      }
      // The sender's static key is AUTHENTICATED by the seal's `ss` DH, so the
      // peerID derived from it is who really wrote this — not whoever handed
      // it over.
      final originPeerID = _peerIdForNoiseKey(senderStatic);
      debugLog?.call('courier envelope OPENED from $originPeerID '
          '(carried by $senderPeerID)');
      await _dispatchNoisePayload(originPeerID, plaintext);
      return;
    } catch (_) {
      // Not ours. That is the ordinary case — carry it.
    }

    final key = _courierKey(envelope.ciphertext);
    if (couriers.accept(envelope, key)) {
      debugLog?.call('carrying courier envelope for someone (copies='
          '${envelope.copies})');
      couriers.markHandedTo(key, senderPeerID);
    }
  }

  /// A peer just became known: hand them any mail we carry for them, and give
  /// them a share of anything that still has budget to spread.
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
          // Delivered: stop carrying it. If the peer could not open it after
          // all, the sender's own retries still cover the message.
          couriers.drop(entry.key);
          debugLog?.call('courier delivered to ${peer.peerID}');
        } catch (_) {}
      }
    }

    // Spray: hand a share of the remaining budget on, so the message keeps
    // spreading toward a recipient neither of us has met. Only to a verified
    // peer — an unverified one is a radio claiming a name, and telling it we
    // carry mail is telling a stranger.
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

  /// The peerID a Noise static key derives to — the first 16 hex chars of its
  /// SHA-256 fingerprint, the same rule [NoiseIdentity] uses. Lets a key that
  /// arrived inside a payload be matched against the peer table.
  static String _peerIdForNoiseKey(Uint8List staticPublicKey) =>
      _hex(NoiseCrypto.sha256(staticPublicKey)).substring(0, 16);

  /// A stable key for an envelope, so the same mail arriving from two couriers
  /// is carried once.
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

  // ---- Gossip sync ----------------------------------------------------------

  /// Files one of OUR public sends into the gossip store.
  ///
  /// The inbound path never sees our own packets (it drops self-echoes), so
  /// without this a device would carry everyone's history except its own — and
  /// the message a user actually sent in a dead spot would be the one thing it
  /// could not serve to the peer who arrived a minute later.
  void _rememberOwnPublic(BitchatPacket packet) {
    if (!packet.isBroadcast || !GossipSync.isSyncable(packet.type)) return;
    gossip.onPublicPacketSeen(packet);
    _gossipDirty = true;
  }

  /// Asks each connected peer, on its own schedule, to reconcile public
  /// history: "here is a compact set of what I hold — send me the rest".
  ///
  /// Directed rather than broadcast, and TTL 0 so it is never relayed: a sync
  /// request is a question for the peer that can hear it, and flooding it would
  /// ask the whole mesh a question only its neighbours can answer.
  Future<void> _gossipTick() async {
    if (!_running) return;
    if (gossip.prune()) _gossipDirty = true;
    // Mail we are carrying expires too — someone else's message is not worth
    // holding forever.
    couriers.prune();
    // Delete consumed prekeys whose grace window has lapsed. This is where
    // forward secrecy actually happens: until the private half is really gone,
    // [LocalPrekeys.privateKeyFor] only declines to use it.
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

  /// Answers a peer's reconciliation request with whatever their filter says
  /// they are missing.
  ///
  /// Responses go out DIRECTED and with TTL 0 — the requester asked, nobody
  /// else did, and a replayed public message re-entering the flood would go
  /// round the mesh a second time.
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
        // Re-addressed to the requester: the original was a broadcast, and
        // re-broadcasting it would hand it to peers who already have it.
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
        // One packet failing must not abandon the rest of the round.
      }
      await Future<void>.delayed(MeshConstants.interFragmentDelay);
    }
  }

  /// Sends a packet addressed to [peerID], or sends nothing at all when that
  /// is not a real peerID.
  ///
  /// Deliberately never falls back to an unaddressed packet. Everything routed
  /// through here is meant for ONE peer — a handshake, Noise ciphertext, a
  /// profile — and [BitchatPacket] treats a null recipient as "not directed",
  /// so a malformed id would quietly hand that traffic to the whole mesh.
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

  /// The 8 raw bytes of a 16-hex peerID, or null when it is not one.
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

  /// Serializes, fragments if needed, and broadcasts a packet.
  ///
  /// Multi-fragment payloads (images/files) are PACED. iOS Core Bluetooth
  /// accepts `writeValue(.withoutResponse)` / `updateValue` (notify) into a
  /// bounded queue and SILENTLY DROPS once it's full — firing a hundred
  /// fragments back-to-back in a tight loop overruns it, so a file left with
  /// holes never reassembles on the far side (the "images don't send over mesh"
  /// symptom). A short gap between fragments keeps the queue drained. Single
  /// fragments (text, reactions, typing, receipts) are unaffected.
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

  // ---- Peer bookkeeping -----------------------------------------------------

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

  // ---- Utilities ------------------------------------------------------------

  List<String> _chunkContent(String content) {
    // Chunk on UTF-8 byte boundaries to respect the 255-byte PM content cap
    // while never splitting a multi-byte rune.
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

  // Static so the static derivations above ([_peerIdForNoiseKey]) can use it;
  // unqualified calls from instance methods resolve to it unchanged.
  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Decoded mesh reaction payload (target message id + emoji + add/remove).
class _ReactionData {
  _ReactionData(this.targetId, this.emoji, this.isRemove, this.reactorNick);
  final String targetId;
  final String emoji;
  final bool isRemove;
  final String reactorNick;
}
