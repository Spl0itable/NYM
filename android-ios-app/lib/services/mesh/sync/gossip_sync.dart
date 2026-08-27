// gossip_sync.dart - Gossip-synced public history.
//
// The controlled flood delivers a public message to whoever is in radio range
// AT THAT MOMENT. Walk into the room a minute late, or come back after the
// crowd has split into two partitions that never touched, and that message is
// simply gone — the mesh has no memory. This is the memory: every device keeps
// a bounded window of recent public packets and periodically reconciles it with
// its neighbours, so a phone that moves between partitions (or relaunches
// hours later) serves the backlog to whoever missed it.
//
// The reconciliation is bitchat's, wire-for-wire, so a Nymchat device and a
// bitchat device sync each other's history rather than each holding half of it:
// a REQUEST_SYNC ([RequestSyncPacket]) carries a Golomb-Coded Set of the ids
// the sender already holds, and the receiver replies with whatever falls
// outside it. See `gcs_filter.dart` for why a GCS rather than a list of ids.
//
// Everything here is pure: the store is in memory, the diff is a function of
// (store, request), and IO belongs to [MeshService], which owns the radio. That
// is what lets the interesting parts — freshness, eviction, the diff, the
// since-cursor — be tested without a Bluetooth stack.

import 'dart:convert';
import 'dart:typed_data';

import '../protocol/bitchat_packet.dart';
import '../protocol/mesh_message_type.dart';
import 'gcs_filter.dart';
import 'request_sync_packet.dart';

/// Tuning, matching bitchat's `TransportConfig` so both sides agree on how much
/// history exists to sync.
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

  /// Most public packets held. bitchat's `seenCapacity`.
  final int capacity;

  /// How long a public message stays sync-able — 6h, bitchat's
  /// `syncPublicMessageMaxAgeSeconds`. This is the window that makes a device a
  /// town crier rather than a live relay.
  final int publicMessageMaxAgeMs;

  /// Announces age out faster: they are presence, and a stale one advertises a
  /// peer who has long since walked away.
  final int announceMaxAgeMs;

  /// Prekey bundles live longest — 24h, matching bitchat. Their whole purpose
  /// is to be available while the owner is away.
  final int prekeyBundleMaxAgeMs;

  /// Filter size budget on the wire.
  final int gcsMaxBytes;

  /// Target false-positive rate. A false positive costs one message this round;
  /// the next round's different id set almost always carries it.
  final double gcsTargetFpr;

  /// How often a peer is asked to reconcile.
  final int syncIntervalMs;

  /// Minimum gap between answering the same peer. A response can replay the
  /// whole store, so this bounds what one peer can make us spend however fast
  /// it asks.
  final int responseRateLimitMs;
}

/// A bounded, freshness-filtered store of recent public packets, plus the
/// reconciliation logic over it.
class GossipSync {
  GossipSync({this.config = const GossipSyncConfig(), int Function()? nowMs})
      : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final GossipSyncConfig config;
  final int Function() _now;

  /// Public messages, insertion-ordered so the oldest evicts first.
  final Map<String, BitchatPacket> _messages = <String, BitchatPacket>{};

  /// One announce per peer — they are replaced, not accumulated, because only
  /// the newest describes where a peer actually is.
  final Map<String, BitchatPacket> _announces = <String, BitchatPacket>{};

  /// One prekey bundle per device, newest wins — an older bundle would offer
  /// keys its owner has already deleted.
  final Map<String, BitchatPacket> _prekeyBundles = <String, BitchatPacket>{};

  /// When each peer was last answered, for the response rate limit.
  final Map<String, int> _lastAnsweredAt = <String, int>{};

  /// When each peer was last asked, so the schedule is per-peer.
  final Map<String, int> _lastAskedAt = <String, int>{};

  int get messageCount => _messages.length;
  int get announceCount => _announces.length;

  /// The stored public packets, newest first.
  List<BitchatPacket> get messages {
    final live = _messages.values.where(_isFresh).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return live;
  }

  /// Records a public packet seen on the air (received OR sent by us).
  ///
  /// Only types that make sense to replay are kept — see [isSyncable]. A
  /// directed packet is never stored: it is somebody's private traffic, and
  /// gossiping it would hand it to peers it was never addressed to.
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

  /// Whether a packet type is worth replaying to a peer that missed it.
  ///
  /// Public chat and announces are. Deliberately excluded: anything directed
  /// (handshakes, encrypted transport, courier envelopes — replaying those
  /// would spread private traffic), REQUEST_SYNC itself (replaying a
  /// reconciliation request is a loop), and Nymchat's own ephemera — typing
  /// indicators and live voice are meaningless once stale, and a reaction
  /// without its message is noise.
  static bool isSyncable(int type) =>
      type == MeshMessageType.announce ||
      type == MeshMessageType.message ||
      type == MeshMessageType.nymChannelMessage ||
      // A bundle has to reach senders while its owner is away — the one time
      // it matters. Signed, so gossip cannot forge one.
      type == MeshMessageType.prekeyBundle;

  bool _isFresh(BitchatPacket packet) {
    final maxAge = switch (packet.type) {
      MeshMessageType.announce => config.announceMaxAgeMs,
      // A bundle stays useful far longer than a message: its owner is away, and
      // stale prekeys are refused by the owner rather than being dangerous.
      MeshMessageType.prekeyBundle => config.prekeyBundleMaxAgeMs,
      _ => config.publicMessageMaxAgeMs,
    };
    final age = _now() - packet.timestamp;
    // A packet stamped in the future is clock skew, not a time traveller: keep
    // it rather than discarding a perfectly good message over a bad clock.
    if (age < 0) return true;
    return age <= maxAge;
  }

  /// Drops everything that has aged out. Returns whether anything went.
  bool prune() {
    final before = _messages.length + _announces.length + _prekeyBundles.length;
    _messages.removeWhere((_, p) => !_isFresh(p));
    _announces.removeWhere((_, p) => !_isFresh(p));
    _prekeyBundles.removeWhere((_, p) => !_isFresh(p));
    return (_messages.length + _announces.length + _prekeyBundles.length) !=
        before;
  }

  /// Whether [peerID] is due a reconciliation request.
  bool shouldAsk(String peerID) {
    final last = _lastAskedAt[peerID] ?? 0;
    return _now() - last >= config.syncIntervalMs;
  }

  /// Records that [peerID] was just asked.
  void markAsked(String peerID) => _lastAskedAt[peerID] = _now();

  /// Whether [peerID]'s request should be answered, or is coming too fast.
  bool shouldAnswer(String peerID) {
    final last = _lastAnsweredAt[peerID];
    if (last == null) return true;
    return _now() - last >= config.responseRateLimitMs;
  }

  /// Records that [peerID] was just answered.
  void markAnswered(String peerID) => _lastAnsweredAt[peerID] = _now();

  /// Forgets a peer that has gone (leave / timeout), so its rate-limit and
  /// schedule state does not accumulate for the life of the app.
  void forgetPeer(String peerID) {
    _lastAnsweredAt.remove(peerID);
    _lastAskedAt.remove(peerID);
  }

  /// Builds the REQUEST_SYNC payload advertising what we already hold.
  ///
  /// Candidates go in newest-first, which is what makes the since-cursor exact:
  /// [GcsFilter.buildFilter] trims from the tail to fit the byte budget, so the
  /// covered set is always a contiguous newest-prefix and the oldest included
  /// timestamp is a true boundary. Without the cursor, a store larger than one
  /// filter would make the responder re-send the uncovered tail every round,
  /// forever.
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

  /// The packets a requester is missing — the whole reconciliation, as a pure
  /// function of the store and the request.
  ///
  /// Announces are exempt from the since-cursor: they carry the signing keys
  /// everything else is verified against, and there is at most one per peer, so
  /// the resend cost is negligible next to a peer that cannot verify anything.
  ///
  /// Returned packets are ready to send as solicited responses — TTL 0, so a
  /// reply never re-floods the mesh it was extracted from.
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
      // Exempt from the cursor, like announces: there is at most one per
      // device, and a sender without it falls back to the non-forward-secret
      // static seal — a real loss for a negligible resend.
      for (final pkt in _prekeyBundles.values) {
        if (!_isFresh(pkt)) continue;
        if (mightContain(pkt)) continue;
        out.add(pkt.copyWith(ttl: 0));
      }
    }
    return out;
  }

  /// Everything held, as raw packet bytes, for the on-disk archive.
  ///
  /// These are signed public broadcasts — already visible to anyone in radio
  /// range — so they are stored as-is. Nothing private is ever in this store
  /// ([onPublicPacketSeen] refuses directed packets), which is what makes
  /// plain persistence the right posture rather than a sealed one.
  String encodeArchive() {
    final rows = <String>[];
    for (final pkt in messages) {
      final bytes = pkt.toBytes(padding: false);
      if (bytes == null) continue;
      rows.add(base64Encode(bytes));
    }
    return jsonEncode(rows);
  }

  /// Restores an archive written by [encodeArchive]. Rows that no longer decode
  /// (a protocol change) or have aged out are skipped; a wholly unreadable blob
  /// leaves the store empty rather than throwing on every launch.
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
