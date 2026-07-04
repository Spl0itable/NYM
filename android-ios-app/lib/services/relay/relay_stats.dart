/// relay_stats.dart — the live relay-traffic counters that back the Network
/// Stats modal (`relay_stats_modal.dart`).
///
/// 1:1 port of the PWA's `nym.relayStats` object (app.js:497-505, written by
/// relays.js socket handlers and sampled by `startRelayStatsSampling`,
/// app.js:7324). The PWA tracks, per session:
///   - `bytesReceived`     — sum of every inbound websocket frame's length.
///   - `bytesSent`         — sum of every outbound frame's length.
///   - `totalEvents`       — unique inbound EVENT messages.
///   - `eventsThisSecond`  — events seen since the last 1s sample (reset each
///                           tick by the sampler).
///   - `throughputHistory` — the last 60 per-second event counts (the graph;
///                           `push(eventsThisSecond)` then `shift()` past 60).
///   - `eventsPerRelay`    — url → unique-event count (per-relay rows).
///   - `latencyPerRelay`   — url → latency in ms (per-relay rows + Avg Latency).
///   - `kindStatsPerRelay` — url → (kind → {count,bytes}) so the expanded
///                           per-relay row shows the kind breakdown
///                           (`_trackRelayKindData`, relays.js:3652).
///   - `apiBytesReceived` / `apiBytesSent` — the /api backend traffic, shown as
///                           the "App data" section (`_trackApiData`, shop.js:113).
///   - `apiActionStats`    — action → {count,sent,recv} so the expanded App-data
///                           row shows the per-action breakdown.
///   - `shardInfo`         — proxy-mode shard fan-in summary
///                           (`[id,status,connected,total]` tuples, app.js:7409).
///
/// This object holds the mutable, live counters (mirroring the PWA's mutable
/// plain object). The relay layer mutates it on every frame; the modal reads a
/// stable [snapshot] each render so it never observes a half-updated map.
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

  /// `throughputHistory` cap — the PWA keeps the last 60 samples (one per
  /// second → a 60s window). app.js:7331.
  static const int throughputCap = 60;

  /// Total UTF-8 bytes received across every relay/shard socket this session.
  int bytesReceived;

  /// Total UTF-8 bytes sent across every relay/shard socket this session.
  int bytesSent;

  /// Unique inbound EVENT messages seen this session (post-dedup).
  int totalEvents;

  /// Events seen since the last 1-second sample. Pushed into
  /// [throughputHistory] and reset to 0 by the sampler each tick.
  int eventsThisSecond;

  /// Bytes received from the /api backend (HTTP proxy / storage / bot). Folded
  /// into [bytesReceived] too, but tracked separately so the modal can render the
  /// "App data" section (`_trackApiData`, shop.js:117).
  int apiBytesReceived;

  /// Bytes sent to the /api backend. Folded into [bytesSent] too.
  int apiBytesSent;

  /// Last [throughputCap] per-second event counts (oldest first). Drives the
  /// throughput graph; the empty list renders the flat-baseline placeholder.
  final List<int> throughputHistory;

  /// Relay url → unique-event count (per-relay rows' `<n> evt`).
  final Map<String, int> eventsPerRelay;

  /// Relay url → last measured latency in ms (per-relay rows' `<ms>ms` and the
  /// Avg-Latency card). Stamped REQ→EOSE per relay.
  final Map<String, int> latencyPerRelay;

  /// Relay url → (kind → {count, bytes}). Per-relay, per-kind tally so the
  /// expanded per-relay row shows what each relay is sending. Mirrors
  /// `_trackRelayKindData` (relays.js:3652). The PWA keys the breakdown by the
  /// same attributed relay url as [eventsPerRelay], so the kind counts sum to
  /// the collapsed `evt` total.
  final Map<String, Map<int, KindStat>> kindStatsPerRelay;

  /// API action → {count, bytesSent, bytesReceived}. Per-action backend traffic
  /// for the expanded App-data row (`apiActionStats`, shop.js:120).
  final Map<String, ApiActionStat> apiActionStats;

  /// Proxy-mode shard fan-in summary: one [ShardInfo] per shard worker (its id,
  /// status, connected-relay count, total-relay count). Empty in direct mode.
  /// Mirrors `relayStats.shardInfo` (app.js:7409); rebuilt from the live shard
  /// sockets each snapshot rather than parsed from a frame (the backend never
  /// emits `POOL:SHARDS`).
  final List<ShardInfo> shardInfo;

  /// True when any /api backend traffic has been recorded, gating the "App data"
  /// section (`apiHasData`, app.js:7597).
  bool get hasApiData => (apiBytesReceived + apiBytesSent) > 0;

  /// Average latency in ms across [latencyPerRelay] (rounded), or null when no
  /// latency has been measured yet (the card then renders `--`). Mirrors
  /// `renderRelayStats`'s `avgLat` computation (app.js:7376-7381).
  int? get averageLatencyMs {
    if (latencyPerRelay.isEmpty) return null;
    var sum = 0;
    for (final ms in latencyPerRelay.values) {
      sum += ms;
    }
    return (sum / latencyPerRelay.length).round();
  }

  /// Record a 1-second throughput sample: push [eventsThisSecond] onto
  /// [throughputHistory] (capped at [throughputCap]) and reset the per-second
  /// counter. Mirrors `startRelayStatsSampling`'s tick (app.js:7329-7332).
  void sampleThroughput() {
    throughputHistory.add(eventsThisSecond);
    while (throughputHistory.length > throughputCap) {
      throughputHistory.removeAt(0);
    }
    eventsThisSecond = 0;
  }

  /// Record a per-relay, per-[kind] event of [bytes] (the event's JSON length).
  /// Mirrors `_trackRelayKindData` (relays.js:3652): a non-`wss://` url is
  /// bucketed under `'relay-pool'`.
  void recordRelayKind(String relayUrl, int kind, int bytes) {
    final url = relayUrl.startsWith('wss://') ? relayUrl : 'relay-pool';
    final perKind = kindStatsPerRelay.putIfAbsent(url, () => <int, KindStat>{});
    final s = perKind.putIfAbsent(kind, () => KindStat());
    s.count += 1;
    s.bytes += bytes;
  }

  /// Tally an /api backend request for [action]: add [sent]/[recv] to the API
  /// totals AND the global byte totals, and bump the per-action stat. Mirrors
  /// `_trackApiData` (shop.js:113): the request counts (`count++`) only when
  /// there were bytes sent (a real outbound request).
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

  /// An immutable copy of the current counters. The modal reads this each
  /// render so live mutation of the source maps can never tear a frame.
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

/// Per-relay, per-kind tally: how many events of a kind a relay delivered and
/// their total JSON byte size. Mirrors the `{count, bytes}` object in
/// `_trackRelayKindData` (relays.js:3658).
class KindStat {
  KindStat({this.count = 0, this.bytes = 0});
  int count;
  int bytes;
  KindStat copy() => KindStat(count: count, bytes: bytes);
}

/// Per-action /api tally: how many requests of an action, plus bytes sent/recv.
/// Mirrors the `{count, bytesSent, bytesReceived}` object in `_trackApiData`
/// (shop.js:121).
class ApiActionStat {
  ApiActionStat({this.count = 0, this.bytesSent = 0, this.bytesReceived = 0});
  int count;
  int bytesSent;
  int bytesReceived;
  int get bytes => bytesSent + bytesReceived;
  ApiActionStat copy() =>
      ApiActionStat(count: count, bytesSent: bytesSent, bytesReceived: bytesReceived);
}

/// One shard's fan-in summary for the proxy-mode shard line (app.js:7409). The
/// PWA represents this as a 4-tuple `[id, status, connected, total]`; the shard
/// line renders `${connected}/${total}` plus a `(status)` suffix when status is
/// anything other than `'connected'`.
class ShardInfo {
  ShardInfo({
    required this.id,
    required this.status,
    required this.connected,
    required this.total,
  });

  final String id;

  /// `'connected'` when the shard socket is open, else `'connecting'` (the
  /// suffix the shard line shows in parentheses).
  final String status;

  /// Relays this shard reports as connected (from its POOL:STATUS).
  final int connected;

  /// Relays assigned to this shard.
  final int total;

  ShardInfo copy() =>
      ShardInfo(id: id, status: status, connected: connected, total: total);
}
