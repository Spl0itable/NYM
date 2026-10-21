import 'dart:math';

import 'call_wake.dart' show CallWakeBook, newWakeSecret, parseWake;

const int kWakePad = 4;
const int kWakeCap = 512;
const List<int> kWakeBuckets = [16, 32, 64, 128, 256, 512];
const int kWakeRotateMs = 12 * 3600000;
const int kWakeRetryMs = 5 * 60000;
const int kWakeHoldMs = CallWakeBook.ttlMs + 2 * 86400000;
const int kWakeLifeMinMs = 86400000;
const int kWakeLifeMaxMs = kWakeHoldMs + 120 * 86400000;

int _bucketAtLeast(int n) =>
    kWakeBuckets.firstWhere((b) => b >= n, orElse: () => kWakeCap);

int wakeBucket(int assigned) => _bucketAtLeast(assigned + kWakePad);

int _spread(int base, Random rng) => base ~/ 2 + rng.nextInt(base + 1);

int wakeRoutineDelay(Random rng) => _spread(kWakeRotateMs, rng);

int wakeRetryDelay(int fails, Random rng) =>
    _spread(min(kWakeRetryMs << min(max(fails - 1, 0), 8), kWakeRotateMs), rng);

int wakeLife(Random rng) =>
    kWakeLifeMinMs +
    rng.nextInt((kWakeLifeMaxMs - kWakeLifeMinMs) ~/ 60000 + 1) * 60000;

class WakeBatch {
  WakeBatch(this.set, this.fresh, this.dropped);

  final List<String> set;
  final List<String> fresh;
  final List<String> dropped;
}

class ContactWakes {
  ContactWakes({
    required this.device,
    Map<String, (int, int)>? wakes,
    Map<String, (String, int)>? held,
    List<String>? gone,
    this.since = 0,
    this.rotatedAt = 0,
    this.nextAt = 0,
    this.fails = 0,
  })  : wakes = wakes ?? <String, (int, int)>{},
        held = held ?? <String, (String, int)>{},
        gone = gone ?? <String>[];

  final String device;
  final Map<String, (int, int)> wakes;
  final Map<String, (String, int)> held;
  final List<String> gone;
  int since;
  int rotatedAt;
  int nextAt;
  int fails;
  final Set<String> _holding = <String>{};

  bool get registered => rotatedAt > 0;

  int _handoutEnd(String w) {
    final r = wakes[w];
    return r == null ? 0 : r.$1 + r.$2 - kWakeHoldMs;
  }

  String? tokenFor(String peer, int now, Random rng) {
    if (!registered) return null;
    String? current;
    var at = -1;
    held.forEach((w, h) {
      if (h.$1 == peer && h.$2 > at) {
        current = w;
        at = h.$2;
      }
    });
    final cur = current;
    if (cur != null && now < _handoutEnd(cur) && !_holding.contains(cur)) {
      return cur;
    }
    final free = [
      for (final w in wakes.keys)
        if (!held.containsKey(w) &&
            !gone.contains(w) &&
            !_holding.contains(w) &&
            now < _handoutEnd(w))
          w,
    ];
    if (free.isEmpty) return null;
    final w = free[rng.nextInt(free.length)];
    held[w] = (peer, now);
    return w;
  }

  bool withdraw(String peer) {
    final mine = [
      for (final e in held.entries)
        if (e.value.$1 == peer) e.key,
    ];
    for (final w in mine) {
      held.remove(w);
      gone.add(w);
    }
    return mine.isNotEmpty;
  }

  bool due(int now) => !registered || now >= nextAt;

  WakeBatch plan(int now, Random rng) {
    final dropped = <String>{
      ...gone,
      for (final e in wakes.entries)
        if (now - e.value.$1 >= e.value.$2) e.key,
    };
    _holding
      ..clear()
      ..addAll(dropped);
    final kept = [
      for (final w in wakes.keys)
        if (!dropped.contains(w)) w,
    ];
    final handed = held.keys.where((w) => !dropped.contains(w)).length;
    final spare = kept
        .where((w) =>
            !held.containsKey(w) &&
            _handoutEnd(w) - now >= 2 * kWakeRotateMs)
        .length;
    final want = max(
      handed + kWakePad,
      spare >= kWakePad ? kept.length : kept.length + kWakePad - spare,
    );
    final target = min(kWakeCap, _bucketAtLeast(want));
    final fresh = [
      for (var i = kept.length; i < target; i++) newWakeSecret(rng),
    ];
    return WakeBatch(
      [...kept, ...fresh]..sort(),
      fresh,
      dropped.toList(),
    );
  }

  void commit(WakeBatch b, int now, Random rng) {
    final dropped = b.dropped.toSet();
    wakes.removeWhere((w, _) => dropped.contains(w));
    held.removeWhere((w, _) => dropped.contains(w));
    gone.removeWhere(dropped.contains);
    for (final w in b.fresh) {
      wakes[w] = (now, wakeLife(rng));
    }
    _holding.clear();
    rotatedAt = now;
    if (since == 0) since = now;
    fails = 0;
    nextAt = now + wakeRoutineDelay(rng);
  }

  void abort(int now, Random rng) {
    _holding.clear();
    fails++;
    nextAt = now + wakeRetryDelay(fails, rng);
  }

  Map<String, dynamic> toJson() => {
        'd': device,
        'w': {
          for (final e in wakes.entries) e.key: [e.value.$1, e.value.$2],
        },
        'h': {
          for (final e in held.entries) e.key: [e.value.$1, e.value.$2],
        },
        'g': gone,
        's': since,
        'r': rotatedAt,
        'n': nextAt,
        'f': fails,
      };

  static ContactWakes? fromJson(Object? j, int now) {
    if (j is! Map) return null;
    final device = parseWake(j['d']);
    if (device == null) return null;
    int toInt(Object? v) => (v as num?)?.toInt() ?? 0;
    final wakes = <String, (int, int)>{};
    final w = j['w'];
    if (w is Map) {
      w.forEach((k, v) {
        final key = parseWake(k);
        if (key != null && v is List && v.length == 2) {
          wakes[key] = (toInt(v[0]), toInt(v[1]));
        }
      });
    }
    final held = <String, (String, int)>{};
    final pool = j['p'];
    if (pool is List) {
      for (final x in pool) {
        final key = parseWake(x);
        if (key != null) wakes[key] = (now, kWakeLifeMinMs);
      }
    }
    final assigned = j['a'];
    if (assigned is Map) {
      assigned.forEach((k, v) {
        final key = v is List && v.isNotEmpty ? parseWake(v[0]) : null;
        if (k is String && key != null) {
          wakes[key] = (now, kWakeHoldMs);
          held[key] = (k, now);
        }
      });
    }
    final h = j['h'];
    if (h is Map) {
      h.forEach((k, v) {
        final key = parseWake(k);
        if (key != null &&
            wakes.containsKey(key) &&
            v is List &&
            v.length == 2 &&
            v[0] is String) {
          held[key] = (v[0] as String, toInt(v[1]));
        }
      });
    }
    final g = j['g'];
    return ContactWakes(
      device: device,
      wakes: wakes,
      held: held,
      gone: g is List
          ? [for (final x in g) parseWake(x)].whereType<String>().toList()
          : <String>[],
      since: toInt(j['s']),
      rotatedAt: wakes.isEmpty ? 0 : toInt(j['r']),
      nextAt: toInt(j['n']),
      fails: toInt(j['f']),
    );
  }
}
