import 'dart:convert';
import 'dart:math';

import '../calls/call_history.dart';
import '../chat_nav/chat_nav.dart' show markMax, markStoreNorm;

class SyncMergeCaps {
  const SyncMergeCaps._();

  static const int threadLastRead = 500;
  static const int rsvpEvents = 300;
  static const int reminders = 300;
  static const int reminderRemoved = 300;
  static const int callLinks = 50;
  static const int calls = 200;

  static Map<String, int> toJson() => {
        'threadLastRead': threadLastRead,
        'rsvpEvents': rsvpEvents,
        'reminders': reminders,
        'reminderRemoved': reminderRemoved,
        'callLinks': callLinks,
        'calls': calls,
      };
}

const Map<String, List<String>> kStampedPrefs = {
  'spamFilter': ['spamFilterEnabled', 'spamFilterAggressive'],
  'hidePreviews': ['hidePreviews'],
  'colorfulMessages': ['colorfulMessages'],
  'pubkeyFormat': ['pubkeyFormat'],
  'voiceSpeed': ['voiceSpeed'],
  'keepCallHistory': ['keepCallHistory'],
  'largeTargets': ['largeTargets'],
  'highContrast': ['highContrast'],
  'theme': ['theme'],
  'colorMode': ['colorMode'],
  'uiLanguage': ['uiLanguage'],
  'chatLayout': ['chatLayout'],
  'chatViewMode': ['chatViewMode'],
  'columnsWallpaper': ['columnsWallpaper'],
  'wallpaperType': ['wallpaperType', 'wallpaperCustomUrl'],
  'transparencyEnabled': ['transparencyEnabled'],
  'textSize': ['textSize'],
  'showTimestamps': ['showTimestamps'],
  'timeFormat': ['timeFormat'],
  'dateFormat': ['dateFormat'],
  'nickStyle': ['nickStyle'],
  'sound': ['sound'],
  'blurOthersImages': ['blurOthersImages'],
  'autoscroll': ['autoscroll'],
  'dmForwardSecrecyEnabled': ['dmForwardSecrecyEnabled'],
  'dmTTLSeconds': ['dmTTLSeconds'],
  'readReceiptsScope': ['readReceiptsScope', 'readReceiptsEnabled'],
  'typingIndicatorsScope': ['typingIndicatorsScope', 'typingIndicatorsEnabled'],
  'acceptPMs': ['acceptPMs'],
  'acceptCalls': ['acceptCalls'],
  'showStatus': ['showStatus'],
  'channelCounts': ['channelCounts'],
  'powDifficulty': ['powDifficulty'],
  'appVerifiedFilter': ['appVerifiedFilter'],
  'filterPacks': ['filterPacks'],
  'remotePanic': ['remotePanic'],
  'groupChatPMOnlyMode': ['groupChatPMOnlyMode'],
  'threadsEnabled': ['threadsEnabled'],
  'translateLanguage': ['translateLanguage'],
  'gesturesEnabled': ['gesturesEnabled'],
  'swipeLeftAction': ['swipeLeftAction'],
  'swipeRightAction': ['swipeRightAction'],
  'swipeThreshold': ['swipeThreshold'],
  'hoverActions': ['hoverActions'],
  'sortByProximity': ['sortByProximity'],
  'pinnedLandingChannel': ['pinnedLandingChannel'],
  'hideNonPinned': ['hideNonPinned'],
  'lowDataMode': ['lowDataMode'],
  'backgroundConnectivity': ['backgroundConnectivity', 'backgroundConnectivityChosen'],
  'cachePMs': ['cachePMs'],
  'addedRelays': ['addedRelays'],
};

final RegExp _event = RegExp(r'^[0-9a-f]{16}$');
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
const List<String> _rsvp = ['going', 'maybe', 'no'];
const List<int> _offsets = [0, 10, 60, 1440];

int _int(Object? v) => v is num && v.isFinite ? v.floor() : 0;

Map<String, dynamic> _obj(Object? v) =>
    v is Map ? v.map((k, v) => MapEntry('$k', v)) : <String, dynamic>{};

int _cmp(String a, String b) => a.compareTo(b);

bool prefTake(Object? localTs, Object? remoteTs) =>
    _int(remoteTs) >= _int(localTs);

class PrefGateResult {
  const PrefGateResult(this.payload, this.take, this.skipped);

  final Map<String, dynamic> payload;
  final Map<String, int> take;
  final bool skipped;
}

String _fpCanon(Object? v) {
  if (v == null) return 'null';
  if (v is num) {
    if (!v.isFinite) return 'null';
    if (v is int) return '$v';
    return v == v.truncateToDouble() ? '${v.toInt()}' : jsonEncode(v);
  }
  if (v is bool) return v ? 'true' : 'false';
  if (v is String) return jsonEncode(v);
  if (v is List) return '[${v.map(_fpCanon).join(',')}]';
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_fpCanon(v[k])}').join(',')}}';
  }
  return 'null';
}

String prefFp(Object? payload, List<String> keys) {
  final src = _obj(payload);
  var h = 0x811c9dc5;
  for (final b in utf8.encode(_fpCanon([for (final k in keys) src[k]]))) {
    h = h ^ b;
    h = (h * 0x193 + ((h << 24) & 0xFFFFFFFF)) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

Map<String, dynamic> prefRowStamp(
  Object? payload,
  Object? rowTs, [
  Map<String, List<String>> stamped = kStampedPrefs,
]) {
  final out = Map<String, dynamic>.of(_obj(payload));
  final at = max(0, _int(rowTs));
  stamped.forEach((name, keys) {
    if (!keys.any(out.containsKey)) return;
    final ts = '${name}Ts';
    final fp = '${name}Fp';
    if (out.containsKey(ts) &&
        (!out.containsKey(fp) || out[fp] == prefFp(out, keys))) {
      return;
    }
    if (!out.containsKey(ts) && at <= 0) return;
    out[ts] = at;
    out.remove(fp);
  });
  return out;
}

PrefGateResult prefGate(
  Object? payload,
  Object? stamps, [
  Map<String, List<String>> stamped = kStampedPrefs,
  Object? rowTs,
]) {
  final src = prefRowStamp(payload, rowTs, stamped);
  final local = _obj(stamps);
  final out = Map<String, dynamic>.of(src);
  final take = <String, int>{};
  var skipped = false;
  stamped.forEach((name, keys) {
    if (!keys.any(src.containsKey)) return;
    final remote = src['${name}Ts'];
    if (prefTake(local[name], remote)) {
      take[name] = _int(remote);
      return;
    }
    for (final k in keys) {
      out.remove(k);
    }
    out.remove('${name}Ts');
    out.remove('${name}Fp');
    skipped = true;
  });
  return PrefGateResult(out, take, skipped);
}

Map<String, dynamic> prefApply(
  PrefGateResult gate,
  Iterable<String> queued, [
  Map<String, List<String>> stamped = kStampedPrefs,
]) {
  final hold = queued.toSet();
  if (hold.isEmpty) return gate.payload;
  final decided = <String>{};
  gate.take.forEach((name, ts) {
    final keys = stamped[name];
    if (ts <= 0 || keys == null) return;
    decided
      ..addAll(keys)
      ..add('${name}Ts');
  });
  return {
    for (final e in gate.payload.entries)
      if (!hold.contains(e.key) || decided.contains(e.key)) e.key: e.value,
  };
}

Map<String, int> tsMapNorm(Object? raw, [int? cap]) {
  final rows = <MapEntry<String, int>>[];
  _obj(raw).forEach((k, v) {
    final n = _int(v);
    if (k.isNotEmpty && n > 0) rows.add(MapEntry(k, n));
  });
  rows.sort((x, y) {
    final d = y.value.compareTo(x.value);
    return d != 0 ? d : _cmp(x.key, y.key);
  });
  final lim = cap == null ? rows.length : (cap < 0 ? 0 : cap);
  return {for (final e in rows.take(lim)) e.key: e.value};
}

Map<String, int> tsMapMerge(Object? a, Object? b, [int? cap]) {
  final out = Map<String, int>.of(tsMapNorm(a));
  tsMapNorm(b).forEach((k, v) {
    final cur = out[k];
    if (cur == null || v > cur) out[k] = v;
  });
  return tsMapNorm(out, cap);
}

Map<String, Map<String, Object>> marksMerge(Object? a, Object? b) {
  final x = markStoreNorm(a is Map ? a : const {});
  final y = markStoreNorm(b is Map ? b : const {});
  final out = <String, Map<String, Object>>{};
  for (final k in {...x.keys, ...y.keys}) {
    final xa = x[k];
    final yb = y[k];
    if (xa == null) {
      out[k] = yb!;
      continue;
    }
    if (yb == null) {
      out[k] = xa;
      continue;
    }
    final m = markMax(xa, yb);
    final xt = _int(xa['t']);
    final yt = _int(yb['t']);
    out[k] = {'at': m.at, 'ids': m.ids, 't': xt > yt ? xt : yt};
  }
  return markStoreNorm(out);
}

Map<String, Map<String, Map<String, Object>>> rsvpNorm(Object? raw) {
  final out = <String, Map<String, Map<String, Object>>>{};
  _obj(raw).forEach((id, ev) {
    if (!_event.hasMatch(id)) return;
    final entries = <String, Map<String, Object>>{};
    _obj(ev).forEach((pk, e) {
      final o = _obj(e);
      final s = o['s'];
      final ts = _int(o['ts']);
      if (!_hex64.hasMatch(pk) || s is! String || !_rsvp.contains(s) || ts <= 0) {
        return;
      }
      entries[pk] = {'s': s, 'ts': ts};
    });
    if (entries.isNotEmpty) out[id] = entries;
  });
  return out;
}

int _rsvpNewest(Map<String, Map<String, Object>> ev) {
  var n = 0;
  for (final e in ev.values) {
    final t = e['ts'] as int;
    if (t > n) n = t;
  }
  return n;
}

Map<String, Map<String, Map<String, Object>>> rsvpMerge(Object? a, Object? b) {
  final all = <String, Map<String, Map<String, Object>>>{};
  for (final src in [rsvpNorm(a), rsvpNorm(b)]) {
    src.forEach((id, entries) {
      final ev = all.putIfAbsent(id, () => <String, Map<String, Object>>{});
      entries.forEach((pk, e) {
        final cur = ev[pk];
        final ts = e['ts'] as int;
        final s = e['s'] as String;
        if (cur == null ||
            ts > (cur['ts'] as int) ||
            (ts == cur['ts'] && s.compareTo(cur['s'] as String) > 0)) {
          ev[pk] = {'s': s, 'ts': ts};
        }
      });
    });
  }
  final ids = all.keys.toList()
    ..sort((p, q) {
      final d = _rsvpNewest(all[q]!).compareTo(_rsvpNewest(all[p]!));
      return d != 0 ? d : _cmp(p, q);
    });
  return {for (final id in ids.take(SyncMergeCaps.rsvpEvents)) id: all[id]!};
}

Map<String, Object>? reminderNorm(Object? r) {
  final o = _obj(r);
  final rawOffset = o['offset'];
  final offset = _int(rawOffset);
  final start = _int(o['start']);
  if (rawOffset is! num || !_offsets.contains(offset) || start <= 0) {
    return null;
  }
  final t = _int(o['t']);
  final by = o['by'];
  return {
    'offset': offset,
    'start': start,
    'title': o['title'] is String ? o['title'] as String : '',
    'groupId': o['groupId'] is String ? o['groupId'] as String : '',
    'fired': o['fired'] == true,
    't': t < 0 ? 0 : t,
    if (by is String && _hex64.hasMatch(by.toLowerCase())) 'by': by.toLowerCase(),
  };
}

Map<String, dynamic> remindersNorm(Object? raw) {
  final o = _obj(raw);
  final items = <String, Map<String, Object>>{};
  _obj(o['items']).forEach((id, r) {
    if (!_event.hasMatch(id)) return;
    final n = reminderNorm(r);
    if (n != null) items[id] = n;
  });
  final removed = <String, int>{};
  tsMapNorm(o['removed']).forEach((id, t) {
    if (_event.hasMatch(id)) removed[id] = t;
  });
  return {'items': items, 'removed': removed};
}

Map<String, dynamic> remindersMerge(Object? a, Object? b) {
  final x = remindersNorm(a);
  final y = remindersNorm(b);
  final removed = Map<String, int>.of(tsMapMerge(x['removed'], y['removed']));
  final items = Map<String, Map<String, Object>>.of(
      x['items'] as Map<String, Map<String, Object>>);
  (y['items'] as Map<String, Map<String, Object>>).forEach((id, r) {
    final cur = items[id];
    final rt = r['t'] as int;
    if (cur == null || rt > (cur['t'] as int)) {
      items[id] = r;
    } else if (rt == cur['t'] && r['fired'] == true && cur['fired'] != true) {
      items[id] = {...cur, 'fired': true};
    }
  });
  for (final id in items.keys.toList()) {
    final gone = removed[id];
    if (gone == null) continue;
    if (gone >= (items[id]!['t'] as int)) {
      items.remove(id);
    } else {
      removed.remove(id);
    }
  }
  final ids = items.keys.toList()
    ..sort((p, q) {
      final ip = items[p]!;
      final iq = items[q]!;
      var d = (iq['t'] as int).compareTo(ip['t'] as int);
      if (d != 0) return d;
      d = (iq['start'] as int).compareTo(ip['start'] as int);
      return d != 0 ? d : _cmp(p, q);
    });
  return {
    'items': {for (final id in ids.take(SyncMergeCaps.reminders)) id: items[id]!},
    'removed': tsMapNorm(removed, SyncMergeCaps.reminderRemoved),
  };
}

Map<String, Object>? callLinkNorm(Object? l) {
  if (l is! Map) return null;
  final id = l['id'];
  final host = l['host'];
  final kind = l['kind'];
  final secret = l['secret'];
  if (id is! String || host is! String || kind is! String || secret is! String) {
    return null;
  }
  final name = l['name'];
  final out = <String, Object>{
    'id': id,
    'host': host,
    'kind': kind == 'video' ? 'video' : 'audio',
    'exp': _int(l['exp']),
    'secret': secret,
    'name': name == null ? '' : '$name',
  };
  if (l['groupId'] is String) out['groupId'] = l['groupId'] as String;
  if (l['revoked'] == true) out['revoked'] = true;
  final created = _int(l['createdAt']);
  if (created > 0) out['createdAt'] = created;
  return out;
}

List<Map<String, Object>> callLinksMerge(Object? a, Object? b) {
  final byId = <String, Map<String, Object>>{};
  for (final list in [a, b]) {
    if (list is! List) continue;
    for (final raw in list) {
      final l = callLinkNorm(raw);
      if (l == null) continue;
      final id = l['id'] as String;
      final cur = byId[id];
      if (cur == null) {
        byId[id] = l;
      } else if (l['revoked'] == true && cur['revoked'] != true) {
        byId[id] = {...cur, 'revoked': true};
      }
    }
  }
  final out = byId.values.toList()
    ..sort((p, q) {
      final d = _int(q['createdAt']).compareTo(_int(p['createdAt']));
      return d != 0 ? d : _cmp(p['id'] as String, q['id'] as String);
    });
  return out.take(SyncMergeCaps.callLinks).toList();
}

CallRecord _callPick(CallRecord x, CallRecord y) {
  if (x.missed != y.missed) return x.missed ? y : x;
  if (x.dur != y.dur) return x.dur > y.dur ? x : y;
  if (x.at != y.at) return x.at > y.at ? x : y;
  return x;
}

class CallsSync {
  const CallsSync(this.clearedAt, this.seen, this.items);
  final int clearedAt;
  final int seen;
  final List<CallRecord> items;

  Map<String, dynamic> toJson() => {
        'clearedAt': clearedAt,
        'seen': seen,
        'items': [for (final r in items) r.toJson()],
      };
}

CallsSync callsNorm(Object? raw) {
  final o = _obj(raw);
  final list = o['items'];
  final items = <CallRecord>[
    if (list is List)
      for (final r in list)
        if (CallHistory.normalize(r) != null) CallHistory.normalize(r)!,
  ];
  final cleared = _int(o['clearedAt']);
  final seen = _int(o['seen']);
  return CallsSync(cleared < 0 ? 0 : cleared, seen < 0 ? 0 : seen, items);
}

CallsSync callsMerge(Object? a, Object? b) {
  final x = a is CallsSync ? a : callsNorm(a);
  final y = b is CallsSync ? b : callsNorm(b);
  final clearedAt = x.clearedAt > y.clearedAt ? x.clearedAt : y.clearedAt;
  final byId = <String, CallRecord>{};
  for (final r in [...x.items, ...y.items]) {
    final cur = byId[r.id];
    byId[r.id] = cur == null ? r : _callPick(cur, r);
  }
  final items = byId.values.where((r) => r.at > clearedAt).toList()
    ..sort((p, q) {
      final d = q.at.compareTo(p.at);
      return d != 0 ? d : _cmp(p.id, q.id);
    });
  return CallsSync(
    clearedAt,
    x.seen > y.seen ? x.seen : y.seen,
    items.take(SyncMergeCaps.calls).toList(),
  );
}

String callsRowAction(bool keep, Object? keepTs, Object? row) {
  final present = row is Map;
  if (keep) return present ? 'apply' : 'none';
  if (!present) return 'clear';
  final local = _int(keepTs);
  return _int(row['keepTs']) > (local < 0 ? 0 : local) ? 'wait' : 'delete';
}
