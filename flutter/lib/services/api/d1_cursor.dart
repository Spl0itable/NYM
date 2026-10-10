typedef D1CursorParts = ({int s, String id});

typedef D1CursorStep = ({bool serverOk, String? cursor, String? next});

typedef D1InboxGroup = ({List<String> keys, String after});

typedef D1InboxPlan = ({List<List<String>> legacy, List<D1InboxGroup> cursor});

typedef D1CursorHold = ({int? since, Object? after});

abstract final class D1Cursor {
  static const int overlapMs = 120000;
  static const int maxPages = 5;
  static const int pageLimit = 200;
  static const int inboxChunk = 200;
  static const int holdMs = 86400000;
  static const int coalesceMs = 10000;
  static const int _maxSafe = 9007199254740991;

  static final RegExp _cursorRe = RegExp(r'^\d{1,16}(:[0-9a-f]{64})?$');
  static final RegExp _headRe = RegExp(r'^\d{1,16}$');

  static D1CursorParts? parse(Object? c) {
    if (c is! String || !_cursorRe.hasMatch(c)) return null;
    final at = c.indexOf(':');
    final s = int.tryParse(at < 0 ? c : c.substring(0, at));
    if (s == null || s > _maxSafe) return null;
    return (s: s, id: at < 0 ? '' : c.substring(at + 1));
  }

  static bool valid(Object? c) => parse(c) != null;

  static String? format(int s, String? id) {
    if (s < 0 || s > _maxSafe) return null;
    return (id != null && id.isNotEmpty) ? '$s:$id' : '$s';
  }

  static int compare(Object? a, Object? b) {
    final pa = parse(a);
    final pb = parse(b);
    if (pa == null || pb == null) {
      return pa != null ? 1 : (pb != null ? -1 : 0);
    }
    if (pa.s != pb.s) return pa.s < pb.s ? -1 : 1;
    if (pa.id == pb.id) return 0;
    return pa.id.compareTo(pb.id) < 0 ? -1 : 1;
  }

  static String? newer(Object? a, Object? b) {
    final va = valid(a);
    final vb = valid(b);
    if (!va && !vb) return null;
    if (!va) return b as String;
    if (!vb) return a as String;
    return compare(a, b) >= 0 ? a as String : b as String;
  }

  static String? older(Object? a, Object? b) {
    final va = valid(a);
    final vb = valid(b);
    if (!va && !vb) return null;
    if (!va) return b as String;
    if (!vb) return a as String;
    return compare(a, b) <= 0 ? a as String : b as String;
  }

  static String? startAfter(Object? c) {
    final p = parse(c);
    if (p == null) return null;
    final s = p.s - overlapMs;
    return '${s < 0 ? 0 : s}';
  }

  static String? fromHead(Object? h) {
    if (h is! String || !_headRe.hasMatch(h)) return null;
    final n = int.tryParse(h);
    return (n != null && n <= _maxSafe) ? h : null;
  }

  static D1CursorStep step(
      int page, String? after, Object? xCursor, Object? xHasMore) {
    if (!valid(xCursor)) return (serverOk: false, cursor: null, next: null);
    final c = xCursor as String;
    final more = xHasMore == '1' && page + 1 < maxPages && c != after;
    return (serverOk: true, cursor: c, next: more ? c : null);
  }

  static List<String> uniqueKeys(Iterable<Object?>? keys) {
    final out = <String>[];
    final seen = <String>{};
    for (final k in keys ?? const <Object?>[]) {
      if (k is! String || k.isEmpty || !seen.add(k)) continue;
      out.add(k);
    }
    return out;
  }

  static D1InboxPlan inboxPlan(
      Iterable<Object?>? keys, Map<String, Object?>? cursors) {
    final map = cursors ?? const <String, Object?>{};
    final without = <String>[];
    final withCur = <({String k, int s})>[];
    for (final k in uniqueKeys(keys)) {
      final p = parse(map[k]);
      if (p != null) {
        withCur.add((k: k, s: p.s));
      } else {
        without.add(k);
      }
    }
    withCur.sort((x, y) {
      final d = x.s.compareTo(y.s);
      return d != 0 ? d : x.k.compareTo(y.k);
    });
    final legacy = <List<String>>[
      for (var i = 0; i < without.length; i += inboxChunk)
        without.sublist(i,
            i + inboxChunk < without.length ? i + inboxChunk : without.length),
    ];
    final cursor = <D1InboxGroup>[];
    for (var i = 0; i < withCur.length; i += inboxChunk) {
      final chunk = withCur.sublist(
          i, i + inboxChunk < withCur.length ? i + inboxChunk : withCur.length);
      final s = chunk.first.s - overlapMs;
      cursor.add((keys: [for (final e in chunk) e.k], after: '${s < 0 ? 0 : s}'));
    }
    return (legacy: legacy, cursor: cursor);
  }

  static Map<String, String> inboxStore(
    Map<String, Object?>? cursors,
    Iterable<Object?> chunkKeys,
    Object? result,
    Iterable<Object?>? liveKeys,
  ) {
    final out = <String, String>{};
    final live = liveKeys?.whereType<String>().toSet();
    (cursors ?? const <String, Object?>{}).forEach((k, v) {
      if (live != null && !live.contains(k)) return;
      if (valid(v)) out[k] = v as String;
    });
    if (valid(result)) {
      for (final k in uniqueKeys(chunkKeys)) {
        if (live != null && !live.contains(k)) continue;
        out[k] = newer(out[k], result)!;
      }
    }
    return out;
  }

  static String? persistable(
      Object? candidate, List<D1CursorHold> holds, int now) {
    final active = [
      for (final h in holds)
        if (h.since != null && now - h.since! < holdMs) h,
    ];
    final cand = valid(candidate) ? candidate as String : null;
    if (active.isEmpty) return cand;
    var out = cand;
    for (final h in active) {
      if (!valid(h.after)) return null;
      out = out == null ? h.after as String : older(out, h.after);
    }
    return out;
  }

  static bool coalesce(int? lastEndedAt, int now) =>
      lastEndedAt != null &&
      lastEndedAt > 0 &&
      now - lastEndedAt < coalesceMs;
}
