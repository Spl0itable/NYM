/// Live relay-traffic counters for the Network Stats modal, a port of the PWA's `nym.relayStats`.
class RelayStats {
  RelayStats({
    this.bytesReceived = 0,
    this.bytesSent = 0,
    this.totalEvents = 0,
    this.eventsThisSecond = 0,
    this.apiBytesReceived = 0,
    this.apiBytesSent = 0,
    List<int>? throughputHistory,
    Map<String, int>? eventsPerRelay,
    Map<String, int>? latencyPerRelay,
    Map<String, Map<int, KindStat>>? kindStatsPerRelay,
    Map<String, ApiActionStat>? apiActionStats,
    List<ShardInfo>? shardInfo,
  })  : throughputHistory = throughputHistory ?? <int>[],
        eventsPerRelay = eventsPerRelay ?? <String, int>{},
        latencyPerRelay = latencyPerRelay ?? <String, int>{},
        kindStatsPerRelay = kindStatsPerRelay ?? <String, Map<int, KindStat>>{},
        apiActionStats = apiActionStats ?? <String, ApiActionStat>{},
        shardInfo = shardInfo ?? <ShardInfo>[];

  /// Keeps the last 60 one-second samples, as the PWA does.
  static const int throughputCap = 60;

  /// Total UTF-8 bytes received across every relay socket this session.
  int bytesReceived;

  /// Total UTF-8 bytes sent across every relay socket this session.
  int bytesSent;

  /// Unique inbound EVENTs this session, after dedup.
  int totalEvents;

  /// Events since the last 1s sample; the sampler pushes and resets it.
  int eventsThisSecond;

  /// /api backend bytes received, also folded into [bytesReceived].
  int apiBytesReceived;

  /// /api backend bytes sent, also folded into [bytesSent].
  int apiBytesSent;

  /// Last [throughputCap] per-second event counts, oldest first.
  final List<int> throughputHistory;

  /// Relay url to unique-event count.
  final Map<String, int> eventsPerRelay;

  /// Relay url to last REQ→EOSE latency in ms.
  final Map<String, int> latencyPerRelay;

  /// Relay url to per-kind {count, bytes}, keyed like [eventsPerRelay] so totals agree.
  final Map<String, Map<int, KindStat>> kindStatsPerRelay;

  /// API action to {count, bytesSent, bytesReceived}.
  final Map<String, ApiActionStat> apiActionStats;

  /// One [ShardInfo] per proxy shard, rebuilt from live sockets; empty in direct mode.
  final List<ShardInfo> shardInfo;

  bool get hasApiData => (apiBytesReceived + apiBytesSent) > 0;

  /// Rounded average of [latencyPerRelay], or null when none measured.
  int? get averageLatencyMs {
    if (latencyPerRelay.isEmpty) return null;
    var sum = 0;
    for (final ms in latencyPerRelay.values) {
      sum += ms;
    }
    return (sum / latencyPerRelay.length).round();
  }

  /// Pushes [eventsThisSecond] onto the capped history and resets it.
  void sampleThroughput() {
    throughputHistory.add(eventsThisSecond);
    while (throughputHistory.length > throughputCap) {
      throughputHistory.removeAt(0);
    }
    eventsThisSecond = 0;
  }

  /// Records an event of [bytes] for [kind]; non-`wss://` urls are bucketed as 'relay-pool'.
  void recordRelayKind(String relayUrl, int kind, int bytes) {
    final url = relayUrl.startsWith('wss://') ? relayUrl : 'relay-pool';
    final perKind = kindStatsPerRelay.putIfAbsent(url, () => <int, KindStat>{});
    final s = perKind.putIfAbsent(kind, () => KindStat());
    s.count += 1;
    s.bytes += bytes;
  }

  /// Adds /api traffic to the API and global totals; `count` only bumps when bytes were sent.
  void recordApiData(String action, {int sent = 0, int recv = 0}) {
    apiBytesSent += sent;
    apiBytesReceived += recv;
    bytesSent += sent;
    bytesReceived += recv;
    final s = apiActionStats.putIfAbsent(action, () => ApiActionStat());
    if (sent > 0) s.count += 1;
    s.bytesSent += sent;
    s.bytesReceived += recv;
  }

  /// Immutable copy, so the modal never renders a half-updated map.
  RelayStats snapshot() => RelayStats(
        bytesReceived: bytesReceived,
        bytesSent: bytesSent,
        totalEvents: totalEvents,
        eventsThisSecond: eventsThisSecond,
        apiBytesReceived: apiBytesReceived,
        apiBytesSent: apiBytesSent,
        throughputHistory: List<int>.from(throughputHistory),
        eventsPerRelay: Map<String, int>.from(eventsPerRelay),
        latencyPerRelay: Map<String, int>.from(latencyPerRelay),
        kindStatsPerRelay: {
          for (final e in kindStatsPerRelay.entries)
            e.key: {for (final k in e.value.entries) k.key: k.value.copy()},
        },
        apiActionStats: {
          for (final e in apiActionStats.entries) e.key: e.value.copy(),
        },
        shardInfo: [for (final s in shardInfo) s.copy()],
      );
}

class KindStat {
  KindStat({this.count = 0, this.bytes = 0});
  int count;
  int bytes;
  KindStat copy() => KindStat(count: count, bytes: bytes);
}

class ApiActionStat {
  ApiActionStat({this.count = 0, this.bytesSent = 0, this.bytesReceived = 0});
  int count;
  int bytesSent;
  int bytesReceived;
  int get bytes => bytesSent + bytesReceived;
  ApiActionStat copy() => ApiActionStat(
      count: count, bytesSent: bytesSent, bytesReceived: bytesReceived);
}

/// One proxy shard's fan-in, PWA tuple `[id, status, connected, total]`.
class ShardInfo {
  ShardInfo({
    required this.id,
    required this.status,
    required this.connected,
    required this.total,
  });

  final String id;

  /// 'connected' when the shard socket is open, else 'connecting'.
  final String status;

  /// Relays this shard reports as connected (from POOL:STATUS).
  final int connected;

  final int total;

  ShardInfo copy() =>
      ShardInfo(id: id, status: status, connected: connected, total: total);
}
