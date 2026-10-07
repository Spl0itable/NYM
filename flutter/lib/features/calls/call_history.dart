import 'dart:convert';

class CallRecord {
  const CallRecord({
    required this.id,
    this.peer = '',
    this.group = '',
    this.kind = 'audio',
    this.dir = 'out',
    required this.at,
    this.dur = 0,
    this.missed = false,
  });

  final String id;
  final String peer;
  final String group;
  final String kind;
  final String dir;
  final int at;
  final int dur;
  final bool missed;

  bool get isVideo => kind == 'video';
  bool get incoming => dir == 'in';

  CallRecord copyWith({int? dur, bool? missed}) => CallRecord(
        id: id,
        peer: peer,
        group: group,
        kind: kind,
        dir: dir,
        at: at,
        dur: dur ?? this.dur,
        missed: missed ?? this.missed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'peer': peer,
        'group': group,
        'kind': kind,
        'dir': dir,
        'at': at,
        'dur': dur,
        'missed': missed,
      };
}

class CallHistoryStore {
  const CallHistoryStore({
    required this.owner,
    this.seen = 0,
    this.items = const [],
  });

  final String owner;
  final int seen;
  final List<CallRecord> items;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'owner': owner,
        'seen': seen,
        'items': [for (final r in items) r.toJson()],
      };
}

class CallHistory {
  static const int cap = 200;
  static final RegExp _peer = RegExp(r'^[0-9a-f]{64}$');

  static CallHistoryStore empty(String owner) => CallHistoryStore(owner: owner);

  static CallRecord? normalize(Object? r) {
    if (r is! Map) return null;
    final rawId = r['id'];
    final id = rawId is String ? rawId : '';
    if (id.isEmpty || id.length > 96) return null;
    final rawPeer = r['peer'];
    final peer = rawPeer is String ? rawPeer : '';
    if (peer.isNotEmpty && !_peer.hasMatch(peer)) return null;
    final rawGroup = r['group'];
    final group = rawGroup is String ? rawGroup : '';
    if (group.length > 128) return null;
    if (peer.isEmpty && group.isEmpty) return null;
    final rawAt = r['at'];
    if (rawAt is! num || !rawAt.isFinite) return null;
    final at = rawAt.floor();
    if (at <= 0) return null;
    final dir = r['dir'] == 'in' ? 'in' : 'out';
    final missed = dir == 'in' && r['missed'] == true;
    final rawDur = r['dur'];
    final d = rawDur is num && rawDur.isFinite ? rawDur.floor() : 0;
    final dur = missed ? 0 : (d < 0 ? 0 : d);
    return CallRecord(
      id: id,
      peer: peer,
      group: group,
      kind: r['kind'] == 'video' ? 'video' : 'audio',
      dir: dir,
      at: at,
      dur: dur,
      missed: missed,
    );
  }

  static List<CallRecord> _tidy(List<CallRecord> list) {
    final sorted = List.of(list)..sort((a, b) => b.at.compareTo(a.at));
    final seen = <String>{};
    final out = <CallRecord>[];
    for (final r in sorted) {
      if (!seen.add(r.id)) continue;
      out.add(r);
      if (out.length >= cap) break;
    }
    return out;
  }

  static CallHistoryStore decode(String? raw, String owner) {
    final base = empty(owner);
    if (raw == null || raw.isEmpty) return base;
    Object? j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return base;
    }
    if (j is! Map || owner.isEmpty || j['owner'] != owner) return base;
    final rawItems = j['items'];
    final items = <CallRecord>[
      if (rawItems is List)
        for (final x in rawItems) ?normalize(x),
    ];
    final s = j['seen'];
    final seen = s is num && s.isFinite && s > 0 ? s.floor() : 0;
    return CallHistoryStore(owner: owner, seen: seen, items: _tidy(items));
  }

  static String encode(CallHistoryStore store) => jsonEncode(store.toJson());

  static CallHistoryStore upsert(CallHistoryStore store, Object? rec) {
    final r = rec is CallRecord ? normalize(rec.toJson()) : normalize(rec);
    if (r == null) {
      return CallHistoryStore(
          owner: store.owner, seen: store.seen, items: List.of(store.items));
    }
    final rest = store.items.where((x) => x.id != r.id);
    return CallHistoryStore(
      owner: store.owner,
      seen: store.seen,
      items: _tidy([r, ...rest]),
    );
  }

  static List<CallRecord> visible(CallHistoryStore store,
          [bool Function(CallRecord r)? hidden]) =>
      [
        for (final r in store.items)
          if (hidden == null || !hidden(r)) r,
      ];

  static int missedCount(CallHistoryStore store,
      [bool Function(CallRecord r)? hidden]) {
    var n = 0;
    for (final r in visible(store, hidden)) {
      if (r.missed && r.at > store.seen) n++;
    }
    return n;
  }

  static CallHistoryStore markSeen(CallHistoryStore store, int nowMs) =>
      CallHistoryStore(
        owner: store.owner,
        seen: nowMs > store.seen ? nowMs : store.seen,
        items: List.of(store.items),
      );

  static String label(CallRecord r) {
    if (r.missed) return 'missed';
    return r.dir == 'in' ? 'incoming' : 'outgoing';
  }

  static String duration(int sec) {
    final t = sec < 0 ? 0 : sec;
    if (t == 0) return '';
    final h = t ~/ 3600;
    final m = (t % 3600) ~/ 60;
    final s = (t % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }
}
