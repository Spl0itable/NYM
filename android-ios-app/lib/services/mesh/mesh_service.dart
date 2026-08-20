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
import 'protocol/mesh_message_type.dart';
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
  bool _running = false;

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
    await _broadcastAnnounce();
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
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.noiseHandshake,
          payload: response,
          recipientID: _peerIdBytes(senderPeerID),
        ));
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
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.nymProfileRequest,
      payload:
          MeshProfileRequest(wantAvatar: avatar, wantBanner: banner).encode(),
      recipientID: _peerIdBytes(peerID),
    ));
  }

  Future<void> _handleProfileRequest(
      String senderPeerID, Uint8List payload) async {
    final provider = _profileProvider;
    if (provider == null) return;
    final request = MeshProfileRequest.decode(payload);
    final profile = await provider(request);
    if (profile == null) return;
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.nymProfileResponse,
      payload: profile.encode(),
      recipientID: _peerIdBytes(senderPeerID),
    ));
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
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.noiseEncrypted,
        payload: ciphertext,
        recipientID: _peerIdBytes(peerID),
      ));
      return;
    }
    _pendingPlaintext.putIfAbsent(peerID, () => []).add(plaintext);
    if (!_noise.isHandshaking(peerID)) {
      // New session ⇒ the peer-state proof must be re-sent once it establishes.
      _peerStateSentTo.remove(peerID);
      final msg1 = await _noise.initiateHandshake(peerID);
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.noiseHandshake,
        payload: msg1,
        recipientID: _peerIdBytes(peerID),
      ));
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
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.noiseEncrypted,
          payload: ciphertext,
          recipientID: _peerIdBytes(peerID),
        ));
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

  Uint8List _peerIdBytes(String peerID) {
    final out = Uint8List(8);
    for (var i = 0; i < 8 && i * 2 + 1 < peerID.length; i++) {
      out[i] = int.parse(peerID.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  String _hex(Uint8List bytes) =>
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
