import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

/// P2P file-sharing constants, matching the PWA.
class P2PConstants {
  P2PConstants._();

  /// 16 KiB data-channel chunk.
  static const int chunkSize = 16384;

  /// 2 GiB transfer cap.
  static const int maxFileSize = 2 * 1024 * 1024 * 1024;

  /// Plain p-tagged WebRTC signaling (offer/answer/ice).
  static const int signalingKind = 25051;

  /// `unseeded` announcements.
  static const int fileStatusKind = 25052;

  static const int highWater = chunkSize * 16;

  static const int lowWater = chunkSize * 4;

  /// ICE servers shared by calls and P2P.
  static const List<Map<String, dynamic>> iceServers = [
    {'urls': 'stun:rtc.0xchat.com:5349'},
    {
      'urls': 'turn:rtc.0xchat.com:5349',
      'username': '0xchat',
      'credential': 'Prettyvs511',
    },
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
  ];
}

/// A file offer advertised on a message's `['offer', JSON]` tag.
class FileOffer {
  const FileOffer({
    required this.offerId,
    required this.name,
    required this.size,
    required this.type,
    required this.hash,
    required this.seederPubkey,
    required this.timestamp,
    this.magnetURI,
    this.infoHash,
  });

  /// `hash[:16] + '-' + base36(now)`.
  final String offerId;
  final String name;
  final int size;
  final String type;

  /// Full SHA-256 hex of the file, checked on receive.
  final String hash;
  final String seederPubkey;

  /// Unix seconds.
  final int timestamp;

  /// WebTorrent magnet URI; null for direct WebRTC.
  final String? magnetURI;
  final String? infoHash;

  bool get isTorrent => (magnetURI ?? '').isNotEmpty;

  Map<String, dynamic> toJson() => {
        'offerId': offerId,
        'name': name,
        'size': size,
        'type': type,
        'hash': hash,
        'seederPubkey': seederPubkey,
        'timestamp': timestamp,
        if (magnetURI != null) 'magnetURI': magnetURI,
        if (infoHash != null) 'infoHash': infoHash,
      };

  factory FileOffer.fromJson(Map<String, dynamic> j) => FileOffer(
        offerId: (j['offerId'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        type: (j['type'] ?? 'application/octet-stream').toString(),
        hash: (j['hash'] ?? '').toString(),
        seederPubkey: (j['seederPubkey'] ?? '').toString(),
        timestamp: (j['timestamp'] as num?)?.toInt() ?? 0,
        magnetURI: j['magnetURI']?.toString(),
        infoHash: j['infoHash']?.toString(),
      );

  /// Builds an offer from raw bytes, computing hash and offerId like the PWA.
  static FileOffer fromBytes({
    required Uint8List bytes,
    required String name,
    required String type,
    required String seederPubkey,
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    final hashHex = sha256.convert(bytes).toString();
    final offerId =
        '${hashHex.substring(0, 16)}-${n.millisecondsSinceEpoch.toRadixString(36)}';
    return FileOffer(
      offerId: offerId,
      name: name,
      size: bytes.length,
      type: type.isEmpty ? 'application/octet-stream' : type,
      hash: hashHex,
      seederPubkey: seederPubkey,
      timestamp: n.millisecondsSinceEpoch ~/ 1000,
    );
  }
}

enum P2PStatus { connecting, transferring, complete, error }

String p2pStatusWire(P2PStatus s) => switch (s) {
      P2PStatus.connecting => 'connecting',
      P2PStatus.transferring => 'transferring',
      P2PStatus.complete => 'complete',
      P2PStatus.error => 'error',
    };

class P2PTransfer {
  P2PTransfer({
    required this.transferId,
    required this.offerId,
    required this.offer,
    this.status = P2PStatus.connecting,
    this.bytesReceived = 0,
    this.bytesSent = 0,
    required this.startTime,
    this.isOutgoing = false,
    this.message,
  });

  final String transferId;
  final String offerId;
  final FileOffer offer;
  P2PStatus status;
  int bytesReceived;
  int bytesSent;
  final int startTime;
  final bool isOutgoing;

  /// Last status detail line shown in the modal.
  String? message;

  double get progress {
    if (offer.size <= 0) return 0;
    final n = isOutgoing ? bytesSent : bytesReceived;
    final pct = (n / offer.size) * 100;
    return pct.clamp(0, 100).toDouble();
  }
}

/// Ordered 16 KiB chunks plus a final partial, like the PWA sender.
List<Uint8List> chunkBytes(Uint8List bytes,
    [int chunkSize = P2PConstants.chunkSize]) {
  final out = <Uint8List>[];
  var offset = 0;
  while (offset < bytes.length) {
    final end =
        (offset + chunkSize) < bytes.length ? offset + chunkSize : bytes.length;
    out.add(Uint8List.sublistView(bytes, offset, end));
    offset += chunkSize;
  }
  return out;
}

Uint8List reassembleChunks(List<Uint8List> chunks) {
  final total = chunks.fold<int>(0, (a, c) => a + c.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final c in chunks) {
    out.setRange(offset, offset + c.length, c);
    offset += c.length;
  }
  return out;
}

/// Lowercase SHA-256 hex, matching the receiver's integrity check.
String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

/// Kind-25051 signaling: plain (not gift-wrapped), p-tagged to [targetPubkey], `data` JSON as content.
class P2PSignalPayload {
  const P2PSignalPayload({required this.tags, required this.content});
  final List<List<String>> tags;
  final String content;
}

P2PSignalPayload buildSignalPayload({
  required String targetPubkey,
  required Map<String, dynamic> data,
}) {
  return P2PSignalPayload(
    tags: [
      ['p', targetPubkey],
    ],
    content: jsonEncode(data),
  );
}

Map<String, dynamic> offerSignal({
  required Map<String, dynamic> sdp,
  required String transferId,
  required String offerId,
}) =>
    {'type': 'offer', 'sdp': sdp, 'transferId': transferId, 'offerId': offerId};

Map<String, dynamic> answerSignal({
  required Map<String, dynamic> sdp,
  required String transferId,
}) =>
    {'type': 'answer', 'sdp': sdp, 'transferId': transferId};

Map<String, dynamic> iceSignal({
  required Map<String, dynamic> candidate,
  required String transferId,
}) =>
    {'type': 'ice-candidate', 'candidate': candidate, 'transferId': transferId};

/// Kind-25052 `unseeded` file-status event.
class FileStatusPayload {
  const FileStatusPayload({required this.tags, required this.content});
  final List<List<String>> tags;
  final String content;
}

/// Adds `['g', geohash]` or `['d', channelName]` for the open channel ([geohash] wins); neither for PM/group.
FileStatusPayload buildUnseededPayload({
  required FileOffer offer,
  String? geohash,
  String? channelName,
}) {
  final tags = <List<String>>[
    ['offer_id', offer.offerId],
    ['status', 'unseeded'],
    if (offer.hash.isNotEmpty) ['x', offer.hash],
    if (geohash != null && geohash.isNotEmpty)
      ['g', geohash]
    else if (channelName != null && channelName.isNotEmpty)
      ['d', channelName],
  ];
  return FileStatusPayload(
    tags: tags,
    content: jsonEncode({
      'offerId': offer.offerId,
      'name': offer.name,
      'status': 'unseeded',
    }),
  );
}

/// The `['offer', JSON]` tag on a file-offer message and its local echo.
List<String> fileOfferTag(FileOffer offer) =>
    ['offer', jsonEncode(offer.toJson())];

/// Parses a file offer, binding seederPubkey to the actual sender; null when absent or mismatched.
FileOffer? parseFileOfferTag(List<List<String>> tags, String senderPubkey) {
  for (final t in tags) {
    if (t.isNotEmpty && t[0] == 'offer' && t.length > 1) {
      try {
        final decoded = jsonDecode(t[1]);
        if (decoded is Map<String, dynamic> &&
            (decoded['offerId'] ?? '').toString().isNotEmpty) {
          final seeder = (decoded['seederPubkey'] ?? '').toString();
          if (seeder.isNotEmpty && seeder != senderPubkey) return null;
          decoded['seederPubkey'] = senderPubkey;
          return FileOffer.fromJson(decoded);
        }
      } catch (_) {
        return null;
      }
    }
  }
  return null;
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String sanitizeDownloadFilename(String name) {
  var safe = name
      .replaceAll(RegExp(r'[/\\]'), '_')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .replaceAll(RegExp(r'^\.+'), '');
  safe = safe.replaceAll(RegExp(r'\.(?=[^.]*\.)'), '_');
  if (safe.length > 255) safe = safe.substring(safe.length - 255);
  return safe.isEmpty ? 'download' : safe;
}
