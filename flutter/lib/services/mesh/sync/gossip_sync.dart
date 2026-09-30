// Gossip-synced public history reconciled via bitchat's REQUEST_SYNC; pure, IO lives in [MeshService].

import 'dart:convert';
import 'dart:typed_data';

import '../protocol/bitchat_packet.dart';
import '../protocol/mesh_message_type.dart';
import 'gcs_filter.dart';
import 'request_sync_packet.dart';

/// Tuning matching bitchat's `TransportConfig`, so both sides agree on how much history exists.
class GossipSyncConfig {
  const GossipSyncConfig({
    this.capacity = 1000,
    this.publicMessageMaxAgeMs = 6 * 60 * 60 * 1000,
    this.announceMaxAgeMs = 15 * 60 * 1000,
    this.prekeyBundleMaxAgeMs = 24 * 60 * 60 * 1000,
    this.gcsMaxBytes = 400,
    this.gcsTargetFpr = 0.01,
    this.syncIntervalMs = 15 * 1000,
    this.responseRateLimitMs = 30 * 1000,
  });

  /// Most public packets held (bitchat's `seenCapacity`).
  final int capacity;

  /// How long a public message stays syncable: 6h, bitchat's `syncPublicMessageMaxAgeSeconds`.
  final int publicMessageMaxAgeMs;

  /// Announces age out faster, since a stale one advertises a peer who has left.
  final int announceMaxAgeMs;

  /// Prekey bundles live longest (24h, as bitchat) since they serve an absent owner.
  final int prekeyBundleMaxAgeMs;

  final int gcsMaxBytes;

  /// Target false-positive rate; a false positive only delays a message to the next round.
  final double gcsTargetFpr;

  final int syncIntervalMs;

  /// Minimum gap between answers to one peer, since a response can replay the whole store.
  final int responseRateLimitMs;
}

class GossipSync {
  GossipSync({this.config = const GossipSyncConfig(), int Function()? nowMs})
      : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final GossipSyncConfig config;
  final int Function() _now;

  /// Public messages, insertion-ordered so the oldest evicts first.
  final Map<String, BitchatPacket> _messages = <String, BitchatPacket>{};

  /// One announce per peer, replaced since only the newest is meaningful.
  final Map<String, BitchatPacket> _announces = <String, BitchatPacket>{};

  /// One prekey bundle per device, newest wins, since older ones offer deleted keys.
  final Map<String, BitchatPacket> _prekeyBundles = <String, BitchatPacket>{};

  final Map<String, int> _lastAnsweredAt = <String, int>{};

  final Map<String, int> _lastAskedAt = <String, int>{};

  int get messageCount => _messages.length;
  int get announceCount => _announces.length;

  List<BitchatPacket> get messages {
    final live = _messages.values.where(_isFresh).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return live;
  }

  /// Records a public packet seen on the air; directed packets are never stored.
  void onPublicPacketSeen(BitchatPacket packet) {
    if (!packet.isBroadcast) return;
    if (!isSyncable(packet.type)) return;
    if (!_isFresh(packet)) return;
    if (packet.type == MeshMessageType.announce) {
      _announces[_hex(packet.senderID)] = packet;
      return;
    }
    if (packet.type == MeshMessageType.prekeyBundle) {
      final key = _hex(packet.senderID);
      final held = _prekeyBundles[key];
      if (held != null && held.timestamp >= packet.timestamp) return;
      _prekeyBundles[key] = packet;
      return;
    }
    final id = _idHexFor(packet);
    if (_messages.containsKey(id)) return;
    _messages[id] = packet;
    while (_messages.length > config.capacity) {
      _messages.remove(_messages.keys.first);
    }
  }

  /// Whether a type is worth replaying; directed traffic, REQUEST_SYNC and Nymchat ephemera are excluded.
  static bool isSyncable(int type) =>
      type == MeshMessageType.announce ||
      type == MeshMessageType.message ||
      type == MeshMessageType.nymChannelMessage ||
      // Bundles must reach senders while the owner is away; signed, so gossip can't forge them.
      type == MeshMessageType.prekeyBundle;

  bool _isFresh(BitchatPacket packet) {
    final maxAge = switch (packet.type) {
      MeshMessageType.announce => config.announceMaxAgeMs,
      MeshMessageType.prekeyBundle => config.prekeyBundleMaxAgeMs,
      _ => config.publicMessageMaxAgeMs,
    };
    final age = _now() - packet.timestamp;
    // A future-stamped packet is clock skew; keep it.
    if (age < 0) return true;
    return age <= maxAge;
  }

  /// Drops aged-out packets; returns whether anything went.
  bool prune() {
    final before = _messages.length + _announces.length + _prekeyBundles.length;
    _messages.removeWhere((_, p) => !_isFresh(p));
    _announces.removeWhere((_, p) => !_isFresh(p));
    _prekeyBundles.removeWhere((_, p) => !_isFresh(p));
    return (_messages.length + _announces.length + _prekeyBundles.length) !=
        before;
  }

  bool shouldAsk(String peerID) {
    final last = _lastAskedAt[peerID] ?? 0;
    return _now() - last >= config.syncIntervalMs;
  }

  void markAsked(String peerID) => _lastAskedAt[peerID] = _now();

  /// Whether [peerID]'s request should be answered or is coming too fast.
  bool shouldAnswer(String peerID) {
    final last = _lastAnsweredAt[peerID];
    if (last == null) return true;
    return _now() - last >= config.responseRateLimitMs;
  }

  void markAnswered(String peerID) => _lastAnsweredAt[peerID] = _now();

  /// Forgets a departed peer's rate-limit and schedule state.
  void forgetPeer(String peerID) {
    _lastAnsweredAt.remove(peerID);
    _lastAskedAt.remove(peerID);
  }

  /// REQUEST_SYNC for what we hold; newest-first input makes the since-cursor an exact boundary.
  Uint8List buildRequest({SyncTypeFlags? types}) {
    final want = types ?? SyncTypeFlags.publicMessages;
    final candidates = <BitchatPacket>[
      if (want.contains(MeshMessageType.announce))
        ..._announces.values.where(_isFresh),
      if (want.contains(MeshMessageType.message))
        ..._messages.values.where(_isFresh),
      if (want.contains(MeshMessageType.prekeyBundle))
        ..._prekeyBundles.values.where(_isFresh),
    ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (candidates.isEmpty) {
      return RequestSyncPacket(
        p: GcsFilter.deriveP(config.gcsTargetFpr),
        m: 1,
        data: Uint8List(0),
        types: want,
      ).encode();
    }

    final p = GcsFilter.deriveP(config.gcsTargetFpr);
    final nMax =
        GcsFilter.estimateMaxElements(sizeBytes: config.gcsMaxBytes, p: p);
    final takeN = candidates.length < nMax ? candidates.length : nMax;
    final included = candidates.take(takeN).toList();
    final params = GcsFilter.buildFilter(
      ids: [for (final pkt in included) _idFor(pkt)],
      maxBytes: config.gcsMaxBytes,
      targetFpr: config.gcsTargetFpr,
    );
    final covered = params.includedCount;
    final since = (covered < candidates.length && covered > 0)
        ? included[covered - 1].timestamp
        : null;
    return RequestSyncPacket(
      p: params.p,
      m: params.m,
      data: params.data,
      types: want,
      sinceTimestampMs: since,
    ).encode();
  }

  /// Packets the requester lacks, as TTL-0 replies; announces bypass the since-cursor.
  List<BitchatPacket> packetsMissingFrom(RequestSyncPacket request) {
    final want = request.types ?? SyncTypeFlags.publicMessages;
    final sorted = GcsFilter.decodeToSortedSet(
      p: request.p,
      m: request.m,
      data: request.data,
    );
    bool mightContain(BitchatPacket pkt) {
      final bucket = GcsFilter.bucket(_idFor(pkt), request.m);
      return GcsFilter.contains(sorted, bucket);
    }

    final out = <BitchatPacket>[];
    if (want.contains(MeshMessageType.announce)) {
      for (final pkt in _announces.values) {
        if (!_isFresh(pkt)) continue;
        if (mightContain(pkt)) continue;
        out.add(pkt.copyWith(ttl: 0));
      }
    }
    if (want.contains(MeshMessageType.message)) {
      final since = request.sinceTimestampMs;
      for (final pkt in messages) {
        if (since != null && pkt.timestamp < since) continue;
        if (mightContain(pkt)) continue;
        out.add(pkt.copyWith(ttl: 0));
      }
    }
    if (want.contains(MeshMessageType.prekeyBundle)) {
      // Bypasses the cursor like announces: one per device, and missing it forces a non-forward-secret seal.
      for (final pkt in _prekeyBundles.values) {
        if (!_isFresh(pkt)) continue;
        if (mightContain(pkt)) continue;
        out.add(pkt.copyWith(ttl: 0));
      }
    }
    return out;
  }

  /// Everything held, as raw packet bytes, for the on-disk archive.
  String encodeArchive() {
    final rows = <String>[];
    for (final pkt in messages) {
      final bytes = pkt.toBytes(padding: false);
      if (bytes == null) continue;
      rows.add(base64Encode(bytes));
    }
    return jsonEncode(rows);
  }

  /// Restores an [encodeArchive] blob, skipping undecodable or aged-out rows; never throws.
  void decodeArchive(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final row in decoded) {
        if (row is! String) continue;
        try {
          final pkt = BinaryProtocol.decode(base64Decode(row));
          if (pkt != null) onPublicPacketSeen(pkt);
        } catch (_) {
          // One unreadable row costs one message.
        }
      }
    } catch (_) {
      // A corrupt archive costs the history, never the launch.
    }
  }

  Uint8List _idFor(BitchatPacket packet) => packetIdFor(
        type: packet.type,
        senderID: packet.senderID,
        timestampMs: packet.timestamp,
        payload: packet.payload,
      );

  String _idHexFor(BitchatPacket packet) => _hex(_idFor(packet));

  static String _hex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
