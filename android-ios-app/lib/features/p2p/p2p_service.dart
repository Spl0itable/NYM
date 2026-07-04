import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'p2p_models.dart';

/// Transport the [P2PService] uses to move plain kind-25051 signaling +
/// kind-25052 file-status events over the relay pool. Implemented by
/// `NostrController` (`publishP2P` / `subscribeP2P`), stubbed in tests.
///
/// Signaling is **plain (not gift-wrapped) p-tagged relay events** — the key
/// difference from call signaling (docs/specs/04 §4.1).
abstract class P2PTransport {
  /// The local user's pubkey (seeder/initiator identity).
  String get selfPubkey;

  /// Publishes a plain kind-[kind] event with [tags] + [content]. The
  /// controller signs it with the local identity and pushes it to the pool.
  Future<void> publishP2P({
    required int kind,
    required List<List<String>> tags,
    required String content,
  });

  /// Subscribes to inbound kind-25051/25052 events p-tagged to us. The returned
  /// callback unsubscribes. [onEvent] receives `(senderPubkey, kind, content)`.
  void Function() subscribeP2P(
    void Function(String senderPubkey, int kind, String content) onEvent,
  );
}

/// One side of a peer connection keyed by `peerPubkey + '-' + transferId`
/// (`connectionId`, p2p.js:266).
class _P2PConnection {
  _P2PConnection(this.pc);
  final RTCPeerConnection pc;
  RTCDataChannel? channel;
  bool haveRemote = false;
  final List<RTCIceCandidate> pending = [];

  /// 30s establish timeout (`createP2PConnection`, p2p.js:309) — a transfer
  /// stuck in `connecting` (peer offline) is errored out and cleaned up.
  Timer? connectTimeout;

  /// 5s grace after `disconnected` before declaring the connection lost
  /// (`oniceconnectionstatechange`, p2p.js:295).
  Timer? disconnectGrace;
}

/// Direct WebRTC data-channel file sharing — 1:1 port of `js/modules/p2p.js`
/// §4.1. Every native share/fetch uses the direct WebRTC data-channel path.
///
/// DESIGN BOUNDARY (deliberate, not a stub): the direct WebRTC path is the SAME
/// transport the PWA uses by default and falls back to whenever WebTorrent is
/// unavailable (p2p.js:909 "Falling back to direct P2P"), so native↔native and
/// native↔(online PWA seeder) transfers all work. The PWA's OPTIONAL WebTorrent
/// route for large/torrent files (`shareP2PFileTorrent`/`downloadTorrent`, magnet
/// URIs) is intentionally not ported: WebTorrent is BitTorrent-over-WebRTC, so a
/// native classic-BitTorrent client (e.g. libtorrent — TCP/uTP/DHT) cannot join
/// its WebRTC swarms at all, and a from-scratch WebTorrent-over-`flutter_webrtc`
/// client is out of scope. The only unreachable case is a magnet-only
/// `?download torrent` offer from a browser peer whose seeder has since gone
/// offline; it surfaces as "torrent (unsupported)" in the modal.
class P2PService extends ChangeNotifier {
  P2PService(this._transport);

  final P2PTransport _transport;
  void Function()? _unsub;

  /// Files we are seeding, by offerId (`p2pPendingFiles`).
  final Map<String, Uint8List> _pendingFiles = {};

  /// Known offers (ours + peers'), by offerId (`p2pFileOffers`).
  final Map<String, FileOffer> _offers = {};

  /// Active transfers, by transferId (`p2pActiveTransfers`).
  final Map<String, P2PTransfer> _transfers = {};

  /// WebRTC connections, by connectionId (`p2pConnections`).
  final Map<String, _P2PConnection> _connections = {};

  /// Received binary chunks, by transferId (`p2pReceivedChunks`).
  final Map<String, List<Uint8List>> _received = {};

  /// Offers the seeder has stopped serving (`p2pUnseededOffers`).
  final Set<String> _unseeded = {};

  /// System-message sink (`displaySystemMessage`) + completed-download sink.
  void Function(String message)? onSystemMessage;

  /// Completed-download sink. When unset (the default), [_complete] saves the
  /// bytes to disk and offers the OS share sheet itself ([_saveDownload]) so a
  /// finished transfer always lands somewhere the user can open — mirroring the
  /// PWA's automatic `a.download` blob save (`completeFileTransfer`, p2p.js:586).
  /// A host may override this to route the bytes elsewhere (e.g. a custom
  /// save-as flow).
  void Function(String filename, Uint8List bytes)? onDownloadReady;

  // --- read-only views for the modal -----------------------------------------

  List<P2PTransfer> get transfers => _transfers.values.toList(growable: false);
  Map<String, FileOffer> get seeding => {
        for (final id in _pendingFiles.keys)
          if (_offers[id] != null) id: _offers[id]!,
      };
  bool isUnseeded(String offerId) => _unseeded.contains(offerId);
  FileOffer? offer(String offerId) => _offers[offerId];

  /// Begins listening for inbound signaling/status. Idempotent.
  void start() {
    _unsub ??= _transport.subscribeP2P(_onSignalEvent);
  }

  @override
  void dispose() {
    _unsub?.call();
    for (final c in _connections.values) {
      c.connectTimeout?.cancel();
      c.disconnectGrace?.cancel();
      try {
        c.channel?.close();
      } catch (_) {}
      try {
        c.pc.close();
      } catch (_) {}
    }
    _connections.clear();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Seeding (sender) — shareP2PFile
  // ---------------------------------------------------------------------------

  /// Hashes [bytes], builds + registers a [FileOffer], and stores the file for
  /// seeding. Returns the offer so the caller (controller) can announce it as a
  /// channel/PM message with a `['offer', JSON]` tag (`publishFileOffer`).
  ///
  /// Large files use the same direct WebRTC chunk path as small ones; the PWA's
  /// optional WebTorrent route for big files is a documented boundary (class doc).
  FileOffer shareFile({
    required Uint8List bytes,
    required String name,
    required String type,
  }) {
    final offer = FileOffer.fromBytes(
      bytes: bytes,
      name: name,
      type: type,
      seederPubkey: _transport.selfPubkey,
    );
    _pendingFiles[offer.offerId] = bytes;
    _offers[offer.offerId] = offer;
    notifyListeners();
    return offer;
  }

  /// Registers a peer's offer parsed off an inbound message tag
  /// (`parseFileOfferTag`) so the receiver can later [requestFile] it. Starts
  /// the signaling subscription as a side effect so the offer card is live the
  /// moment it renders, even for a user who has never shared a file themselves.
  void registerOffer(FileOffer offer) {
    _offers[offer.offerId] = offer;
    start();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Receiving — requestP2PFile
  // ---------------------------------------------------------------------------

  /// Requests [offerId] from its seeder: creates the transfer state and the
  /// initiating WebRTC connection (`requestP2PFile` → `createP2PConnection`).
  Future<void> requestFile(String offerId) async {
    // A pure receiver may never have shared a file, so ensure the signaling
    // subscription is live before we send our offer — otherwise the seeder's
    // answer/ICE would never reach us and the transfer would hang `connecting`.
    start();
    final offer = _offers[offerId];
    if (offer == null) {
      _system('File offer not found');
      return;
    }
    if (offer.seederPubkey == _transport.selfPubkey) {
      _system('Cannot download your own file');
      return;
    }
    if (_unseeded.contains(offerId)) {
      _system('This file is no longer being seeded by the owner');
      return;
    }
    final transferId =
        '$offerId-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    _transfers[transferId] = P2PTransfer(
      transferId: transferId,
      offerId: offerId,
      offer: offer,
      startTime: DateTime.now().millisecondsSinceEpoch,
    );
    _received[transferId] = [];
    notifyListeners();
    await _createConnection(offer.seederPubkey, transferId, true);
  }

  // ---------------------------------------------------------------------------
  // Stop seeding — stopSeeding (broadcasts kind 25052 unseeded)
  // ---------------------------------------------------------------------------

  Future<void> stopSeeding(String offerId,
      {String? geohash, String? channelName}) async {
    final offer = _offers[offerId];
    _pendingFiles.remove(offerId);
    _unseeded.add(offerId);
    // Cancel active transfers for this offer.
    for (final id in _transfers.keys
        .where((id) => _transfers[id]!.offerId == offerId)
        .toList()) {
      cancelTransfer(id, silent: true);
    }
    if (offer != null) {
      final payload = buildUnseededPayload(
          offer: offer, geohash: geohash, channelName: channelName);
      try {
        await _transport.publishP2P(
          kind: P2PConstants.fileStatusKind,
          tags: payload.tags,
          content: payload.content,
        );
      } catch (e) {
        debugPrint('P2P unseeded broadcast failed: $e');
      }
    }
    _system('Stopped seeding file${offer != null ? ': ${offer.name}' : ''}');
    notifyListeners();
  }

  void cancelTransfer(String transferId, {bool silent = false}) {
    final transfer = _transfers.remove(transferId);
    _received.remove(transferId);
    for (final id in _connections.keys
        .where((id) => id.endsWith(transferId))
        .toList()) {
      _cleanupConnection(id);
    }
    if (transfer != null && !silent) _system('Transfer cancelled');
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Inbound signaling routing — handleP2PSignalingEvent / FileStatusEvent
  // ---------------------------------------------------------------------------

  void _onSignalEvent(String senderPubkey, int kind, String content) {
    if (kind == P2PConstants.fileStatusKind) {
      try {
        final data = jsonDecode(content);
        if (data is Map &&
            data['status'] == 'unseeded' &&
            data['offerId'] != null) {
          _unseeded.add(data['offerId'].toString());
          notifyListeners();
        }
      } catch (_) {}
      return;
    }
    if (kind != P2PConstants.signalingKind) return;
    try {
      final data = jsonDecode(content);
      if (data is! Map<String, dynamic>) return;
      switch (data['type']) {
        case 'offer':
          _handleOffer(senderPubkey, data);
        case 'answer':
          _handleAnswer(senderPubkey, data);
        case 'ice-candidate':
          _handleIce(senderPubkey, data);
      }
    } catch (e) {
      debugPrint('P2P signaling error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // WebRTC plumbing — createP2PConnection / setupDataChannel
  // ---------------------------------------------------------------------------

  Future<_P2PConnection> _createConnection(
      String peerPubkey, String transferId, bool isInitiator) async {
    final connectionId = '$peerPubkey-$transferId';
    final pc = await createPeerConnection({
      'iceServers': P2PConstants.iceServers,
    });
    final conn = _P2PConnection(pc);
    _connections[connectionId] = conn;

    pc.onIceCandidate = (c) {
      // p2p.js `onicecandidate` guards `if (event.candidate)`: skip the empty
      // end-of-gathering marker flutter_webrtc emits.
      if (c.candidate == null || c.candidate!.isEmpty) return;
      final sig = iceSignal(candidate: {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }, transferId: transferId);
      _sendSignal(peerPubkey, sig);
    };

    pc.onIceConnectionState = (s) {
      final transfer = _transfers[transferId];
      if (s == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        conn.connectTimeout?.cancel();
        if (transfer != null) {
          _updateStatus(transferId, P2PStatus.error,
              'Connection failed - peer may be offline');
        }
        _cleanupConnection(connectionId);
      } else if (s == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        // Give it a moment to recover before declaring error (p2p.js:295).
        conn.disconnectGrace?.cancel();
        conn.disconnectGrace = Timer(const Duration(seconds: 5), () {
          final st = conn.pc.iceConnectionState;
          if (st == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
              st == RTCIceConnectionState.RTCIceConnectionStateFailed) {
            final t = _transfers[transferId];
            if (t != null && t.status != P2PStatus.complete) {
              _updateStatus(transferId, P2PStatus.error, 'Connection lost');
            }
            _cleanupConnection(connectionId);
          }
        });
      } else if (s == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          s == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        // Established — cancel the connect timeout (p2p.js:321).
        conn.connectTimeout?.cancel();
        conn.disconnectGrace?.cancel();
        if (transfer != null && transfer.status == P2PStatus.connecting) {
          transfer.status = P2PStatus.transferring;
          notifyListeners();
        }
      }
    };

    // 30s establish timeout (p2p.js:309): a transfer still `connecting` after
    // 30s (peer offline / no answer) is errored out and torn down.
    conn.connectTimeout = Timer(const Duration(seconds: 30), () {
      final t = _transfers[transferId];
      if (t != null && t.status == P2PStatus.connecting) {
        _updateStatus(transferId, P2PStatus.error,
            'Connection timed out - peer may be offline');
        _cleanupConnection(connectionId);
      }
    });

    if (isInitiator) {
      // Receiver side opens the data channel to pull the file.
      final dc = await pc.createDataChannel(
          'fileTransfer', RTCDataChannelInit()..ordered = true);
      conn.channel = dc;
      _setupDataChannel(dc, transferId, isSender: false);

      final offerDesc = await pc.createOffer();
      await pc.setLocalDescription(offerDesc);
      final transfer = _transfers[transferId];
      _sendSignal(
        peerPubkey,
        offerSignal(
          sdp: {'type': offerDesc.type, 'sdp': offerDesc.sdp},
          transferId: transferId,
          offerId: transfer?.offerId ?? '',
        ),
      );
    } else {
      pc.onDataChannel = (dc) {
        conn.channel = dc;
        _setupDataChannel(dc, transferId, isSender: true);
      };
    }
    return conn;
  }

  void _setupDataChannel(RTCDataChannel dc, String transferId,
      {required bool isSender}) {
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (isSender) {
          unawaited(_startSending(transferId, dc));
        } else {
          _updateStatus(transferId, P2PStatus.transferring, 'Receiving...');
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        final t = _transfers[transferId];
        if (t != null &&
            t.status != P2PStatus.complete &&
            t.status != P2PStatus.error) {
          _updateStatus(transferId, P2PStatus.error, 'Connection closed');
        }
      }
    };
    dc.onMessage = (msg) {
      if (!isSender) _handleChunk(transferId, msg);
    };
  }

  /// Sender loop — metadata JSON first, then 16 KiB chunks with backpressure,
  /// then `{type:'complete'}` (`startSendingFile`, p2p.js:405).
  Future<void> _startSending(String transferId, RTCDataChannel dc) async {
    final transfer = _transfers[transferId];
    if (transfer == null) return;
    final bytes = _pendingFiles[transfer.offerId];
    if (bytes == null) {
      try {
        await dc.send(RTCDataChannelMessage(jsonEncode(
            {'type': 'error', 'message': 'File no longer available'})));
      } catch (_) {}
      _updateStatus(transferId, P2PStatus.error, 'File no longer available');
      return;
    }

    await dc.send(RTCDataChannelMessage(jsonEncode({
      'type': 'metadata',
      'name': transfer.offer.name,
      'size': transfer.offer.size,
      'mimeType': transfer.offer.type,
    })));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final chunks = chunkBytes(bytes);
    for (final chunk in chunks) {
      if (dc.state != RTCDataChannelState.RTCDataChannelOpen) {
        _updateStatus(transferId, P2PStatus.error,
            'Connection closed during transfer');
        return;
      }
      // Backpressure: flutter_webrtc surfaces bufferedAmount; pause above the
      // high-water mark and poll until it drains below low-water (p2p.js:472).
      var guard = 0;
      while ((await _bufferedAmount(dc)) > P2PConstants.highWater &&
          guard++ < 1000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (dc.state != RTCDataChannelState.RTCDataChannelOpen) return;
      }
      await dc.send(RTCDataChannelMessage.fromBinary(chunk));
      transfer.bytesSent += chunk.length;
      notifyListeners();
    }

    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      await dc.send(RTCDataChannelMessage(jsonEncode({'type': 'complete'})));
    } catch (_) {}
    transfer.status = P2PStatus.complete;
    notifyListeners();
  }

  Future<int> _bufferedAmount(RTCDataChannel dc) async {
    try {
      return dc.bufferedAmount ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Receiver — accumulates chunks, verifies size + SHA-256 on `complete`
  /// (`handleFileChunk` / `completeFileTransfer`, p2p.js:498/549).
  void _handleChunk(String transferId, RTCDataChannelMessage msg) {
    final transfer = _transfers[transferId];
    if (transfer == null) return;

    if (!msg.isBinary) {
      try {
        final data = jsonDecode(msg.text);
        if (data is Map) {
          if (data['type'] == 'metadata') {
            transfer.message = 'Receiving ${data['name']}';
            notifyListeners();
          } else if (data['type'] == 'complete') {
            _complete(transferId);
          } else if (data['type'] == 'error') {
            _updateStatus(transferId, P2PStatus.error,
                data['message']?.toString() ?? 'Transfer error');
          }
        }
      } catch (_) {}
      return;
    }

    final bin = msg.binary;
    final chunks = _received[transferId];
    if (chunks == null) return;
    final newTotal = transfer.bytesReceived + bin.length;
    if (newTotal > P2PConstants.maxFileSize) {
      _abort(transferId, 'Transfer aborted: file exceeds maximum allowed size');
      return;
    }
    if (newTotal > transfer.offer.size) {
      _abort(transferId, 'Transfer aborted: received more data than advertised');
      return;
    }
    chunks.add(bin);
    transfer.bytesReceived += bin.length;
    // Live progress: %/speed status line (p2p.js:540-543 `handleFileChunk` →
    // `updateTransferProgress`, p2p.js:606-621). pct is clamped to 100 and the
    // throughput is bytesReceived over elapsed seconds since the transfer
    // started, humanized with the shared `formatFileSize`.
    if (transfer.offer.size > 0) {
      final pct =
          ((transfer.bytesReceived / transfer.offer.size) * 100).clamp(0, 100);
      final elapsed =
          (DateTime.now().millisecondsSinceEpoch - transfer.startTime) / 1000;
      final speed = elapsed > 0 ? transfer.bytesReceived / elapsed : 0;
      transfer.message =
          '${pct.toStringAsFixed(1)}% • ${formatFileSize(speed.round())}/s';
    }
    notifyListeners();
  }

  void _complete(String transferId) {
    final transfer = _transfers[transferId];
    final chunks = _received[transferId];
    if (transfer == null || chunks == null) return;
    final offer = transfer.offer;

    if (transfer.bytesReceived != offer.size) {
      _abort(transferId,
          'Transfer rejected: received size does not match advertised size');
      return;
    }
    final bytes = reassembleChunks(chunks);
    if (offer.hash.isNotEmpty) {
      final got = sha256Hex(bytes);
      if (got != offer.hash.toLowerCase()) {
        _abort(transferId,
            'Transfer rejected: file content does not match advertised hash');
        return;
      }
    }
    _updateStatus(transferId, P2PStatus.complete, 'Download complete!');
    _received.remove(transferId);
    final safeName = sanitizeDownloadFilename(offer.name);
    final handler = onDownloadReady;
    if (handler != null) {
      handler(safeName, bytes);
    } else {
      // No host save handler: persist + offer the OS share/save sheet so the
      // file actually reaches the user (the PWA triggers a browser download).
      unawaited(_saveDownload(safeName, bytes));
    }
    _system('File "${offer.name}" downloaded successfully');
  }

  /// Writes [bytes] to a temp file and opens the OS share sheet so the user can
  /// save it to Files/Downloads — the native stand-in for the PWA's blob
  /// `a.download` (`completeFileTransfer`, p2p.js:586). Best-effort: a failure
  /// only surfaces a system message, never throws.
  Future<void> _saveDownload(String filename, Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$filename';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(path)], subject: filename);
    } catch (e) {
      debugPrint('P2P save download failed: $e');
      _system('Downloaded "$filename" but could not open the save dialog');
    }
  }

  void _abort(String transferId, String message) {
    _updateStatus(transferId, P2PStatus.error, message);
    _received.remove(transferId);
    for (final id in _connections.keys
        .where((id) => id.endsWith(transferId))
        .toList()) {
      _cleanupConnection(id);
    }
    _system(message);
  }

  // --- offer/answer/ice handlers (seeder side answers) -----------------------

  Future<void> _handleOffer(
      String senderPubkey, Map<String, dynamic> data) async {
    final offerId = data['offerId']?.toString() ?? '';
    final transferId = data['transferId']?.toString() ?? '';
    if (!_pendingFiles.containsKey(offerId)) return; // we don't have this file
    final fileOffer = _offers[offerId];
    if (fileOffer == null || fileOffer.seederPubkey != _transport.selfPubkey) {
      return;
    }
    _transfers[transferId] = P2PTransfer(
      transferId: transferId,
      offerId: offerId,
      offer: fileOffer,
      startTime: DateTime.now().millisecondsSinceEpoch,
      isOutgoing: true,
    );
    notifyListeners();

    final conn = await _createConnection(senderPubkey, transferId, false);
    final sdp = data['sdp'];
    if (sdp is Map) {
      await conn.pc.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?));
      conn.haveRemote = true;
      await _flushPending(conn);
    }
    final answer = await conn.pc.createAnswer();
    await conn.pc.setLocalDescription(answer);
    _sendSignal(
      senderPubkey,
      answerSignal(
        sdp: {'type': answer.type, 'sdp': answer.sdp},
        transferId: transferId,
      ),
    );
  }

  Future<void> _handleAnswer(
      String senderPubkey, Map<String, dynamic> data) async {
    final transferId = data['transferId']?.toString() ?? '';
    final conn = _connections['$senderPubkey-$transferId'];
    final sdp = data['sdp'];
    if (conn != null && sdp is Map) {
      await conn.pc.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?));
      conn.haveRemote = true;
      await _flushPending(conn);
    }
  }

  Future<void> _handleIce(
      String senderPubkey, Map<String, dynamic> data) async {
    final transferId = data['transferId']?.toString() ?? '';
    final conn = _connections['$senderPubkey-$transferId'];
    final c = data['candidate'];
    if (conn == null || c is! Map) return;
    // p2p.js `handleP2PIceCandidate` requires a truthy candidate; drop the empty
    // end-of-gathering marker.
    final candStr = c['candidate'] as String?;
    if (candStr == null || candStr.isEmpty) return;
    final candidate = RTCIceCandidate(
      candStr,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (conn.haveRemote) {
      try {
        await conn.pc.addCandidate(candidate);
      } catch (_) {}
    } else {
      conn.pending.add(candidate);
    }
  }

  Future<void> _flushPending(_P2PConnection conn) async {
    for (final c in conn.pending) {
      try {
        await conn.pc.addCandidate(c);
      } catch (_) {}
    }
    conn.pending.clear();
  }

  void _cleanupConnection(String connectionId) {
    final c = _connections.remove(connectionId);
    if (c == null) return;
    c.connectTimeout?.cancel();
    c.disconnectGrace?.cancel();
    try {
      c.channel?.close();
    } catch (_) {}
    try {
      c.pc.close();
    } catch (_) {}
  }

  // --- helpers ---------------------------------------------------------------

  void _updateStatus(String transferId, P2PStatus status, String message) {
    final t = _transfers[transferId];
    if (t == null) return;
    t.status = status;
    t.message = message;
    notifyListeners();
  }

  void _sendSignal(String targetPubkey, Map<String, dynamic> data) {
    final payload = buildSignalPayload(targetPubkey: targetPubkey, data: data);
    unawaited(_transport
        .publishP2P(
          kind: P2PConstants.signalingKind,
          tags: payload.tags,
          content: payload.content,
        )
        .catchError((Object e) => debugPrint('P2P signal publish failed: $e')));
  }

  void _system(String message) => onSystemMessage?.call(message);
}
