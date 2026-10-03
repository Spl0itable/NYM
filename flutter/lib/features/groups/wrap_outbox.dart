import 'dart:math' as math;

class WrapTier {
  static const int critical = 0;
  static const int normal = 1;
  static const int bulk = 2;
}

const List<String> kWrapCriticalTypes = [
  'group-invite',
  'group-join-request',
  'group-join-declined',
  'group-join-pending',
  'group-join-waiting',
  'group-join-resolved',
  'group-roster',
  'group-roster-req',
  'group-history',
  'group-remove-member',
  'group-transfer-owner',
];

const List<String> kWrapBulkTypes = ['group-metadata'];

class WrapBucketConfig {
  const WrapBucketConfig(this.capacity, this.perMinute);

  final int capacity;
  final int perMinute;
}

const WrapBucketConfig kRelayWrapBucket = WrapBucketConfig(160, 100);

const WrapBucketConfig kDepositWrapBucket = WrapBucketConfig(100, 480);

class WrapBucket {
  const WrapBucket(this.tokens, this.at);

  final double tokens;
  final int at;
}

class WrapTake {
  const WrapTake(this.ok, this.waitMs, this.state);

  final bool ok;
  final int waitMs;
  final WrapBucket state;
}

class WrapQueueEntry {
  const WrapQueueEntry(this.id, this.tier, this.seq);

  final String id;
  final int tier;
  final num seq;
}

int wrapTier({
  Object? kind,
  String? type,
  bool resyncReq = false,
  int? fanout,
  bool toNew = false,
}) {
  if (toNew) return WrapTier.critical;
  final k = kind is num ? kind : (kind is String ? num.tryParse(kind) : null);
  if (k != 14 && k != 15) return WrapTier.bulk;
  final t = (type != null && type.isNotEmpty) ? type : null;
  if (t == 'key-resync') return resyncReq ? WrapTier.bulk : WrapTier.critical;
  if (t != null && kWrapCriticalTypes.contains(t)) return WrapTier.critical;
  if (t != null && kWrapBulkTypes.contains(t)) return WrapTier.bulk;
  if (t != null) return WrapTier.normal;
  return (fanout ?? 0) > 1 ? WrapTier.normal : WrapTier.critical;
}

WrapTake wrapBucketTake(
    WrapBucket? state, int nowMs, num units, WrapBucketConfig cfg,
    {bool force = false}) {
  final cap = cfg.capacity.toDouble();
  final perMinute = cfg.perMinute.toDouble();
  final n = units > 0 ? units.toDouble() : 0.0;
  final prev = state ?? WrapBucket(cap, nowMs);
  final elapsed = math.max(0, nowMs - prev.at);
  final tokens = math.min(cap, prev.tokens + elapsed * perMinute / 60000);
  if (tokens >= n || force) {
    return WrapTake(true, 0, WrapBucket(tokens - n, nowMs));
  }
  final waitMs =
      perMinute > 0 ? ((n - tokens) * 60000 / perMinute).ceil() : 60000;
  return WrapTake(false, waitMs, WrapBucket(tokens, nowMs));
}

int wrapBucketAvailable(WrapBucket? state, int nowMs, WrapBucketConfig cfg) {
  final r = wrapBucketTake(state, nowMs, 0, cfg);
  return math.max(0, r.state.tokens.floor());
}

int _tierOf(WrapQueueEntry e) =>
    e.tier == 0 || e.tier == 1 || e.tier == 2 ? e.tier : WrapTier.normal;

List<WrapQueueEntry> _valid(List<WrapQueueEntry?> entries) => [
      for (final e in entries)
        if (e != null && e.id.isNotEmpty) e,
    ];

({List<String> keep, List<String> evicted}) wrapQueueEvict(
    List<WrapQueueEntry?> entries, int cap) {
  final list = _valid(entries);
  final over = list.length - math.max(0, cap);
  if (over <= 0) {
    return (keep: [for (final e in list) e.id], evicted: <String>[]);
  }
  final order = List<WrapQueueEntry>.of(list);
  _stableSort(order, (a, b) {
    final t = _tierOf(b) - _tierOf(a);
    return t != 0 ? t : a.seq.compareTo(b.seq);
  });
  final gone = Set<WrapQueueEntry>.identity();
  final evicted = <String>[];
  for (var i = 0; i < over; i++) {
    gone.add(order[i]);
    evicted.add(order[i].id);
  }
  return (
    keep: [
      for (final e in list)
        if (!gone.contains(e)) e.id
    ],
    evicted: evicted,
  );
}

List<String> wrapTierOrder(List<WrapQueueEntry?> entries, List<num> rand) {
  final list = _valid(entries);
  _stableSort(list, (a, b) {
    final t = _tierOf(a) - _tierOf(b);
    return t != 0 ? t : a.seq.compareTo(b.seq);
  });
  final r = [
    for (final x in rand)
      if (x is int && x >= 0) x,
  ];
  if (r.isEmpty) return [for (final e in list) e.id];
  var k = 0;
  var start = 0;
  while (start < list.length) {
    var end = start;
    final t = _tierOf(list[start]);
    while (end < list.length && _tierOf(list[end]) == t) {
      end++;
    }
    for (var i = end - 1; i > start; i--) {
      final j = start + (r[k % r.length] % (i - start + 1));
      k++;
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
    start = end;
  }
  return [for (final e in list) e.id];
}

void _stableSort<T>(List<T> list, int Function(T a, T b) cmp) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = cmp(a.$2, b.$2);
    return c != 0 ? c : a.$1 - b.$1;
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
