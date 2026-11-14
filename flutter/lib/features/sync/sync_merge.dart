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
  static const int reportedTargets = 200;

  static Map<String, int> toJson() => {
        'threadLastRead': threadLastRead,
        'rsvpEvents': rsvpEvents,
        'reminders': reminders,
        'reminderRemoved': reminderRemoved,
        'callLinks': callLinks,
        'calls': calls,
        'reportedTargets': reportedTargets,
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
  'sidebarChannelsMode': ['sidebarChannelsMode'],
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
  'columnsLayout': ['columnsLayout'],
  'notificationsEnabled': ['notificationsEnabled'],
  'notifyFriendsOnly': ['notifyFriendsOnly'],
  'groupNotifyMentionsOnly': ['groupNotifyMentionsOnly'],
  'threadNotifyMentionsOnly': ['threadNotifyMentionsOnly'],
  'eventToasts': ['eventToasts'],
  'sidebarSectionOrder': ['sidebarSectionOrder'],
  'lightningAddress': ['lightningAddress'],
  'syncMLSHistory': ['syncMLSHistory'],
  'encryptAtRestPreferred': ['encryptAtRestPreferred'],
  'botMaxRuns': ['botMaxRuns'],
  'botAnonEnabled': ['botAnonEnabled'],
  'botProModel': ['botProModel'],
  'streetDetail': ['streetDetail'],
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

const Map<String, String> kSyncedSets = {
  'blockedUsers': '',
  'friends': '',
  'blockedKeywords': '',
  'blockedChannels': '',
  'hiddenChannels': '',
  'pinnedChannels': '',
  'userJoinedChannels': '',
  'translateFavoriteLanguages': '',
  'emojiPackFavorites': '',
  'emojiCategoryFavorites': '',
  'favoriteGifs': 'url',
  'blockedEmojiPacks': 'coord',
};

const String kSetSuffix = 'Set';
const int kSetSeed = 1;
const int kSetTombstoneMs = 90 * 86400000;
const int kSetRemovedCap = 100;

class SetState {
  const SetState(this.a, this.r);

  final Map<String, int> a;
  final Map<String, int> r;

  Map<String, dynamic> toJson() => {'a': a, 'r': r};
}

class SetGateResult {
  const SetGateResult(this.payload, this.states, this.behind);

  final Map<String, dynamic> payload;
  final Map<String, SetState> states;
  final bool behind;
}

String setKeyOf(String name, Object? el) {
  final field = kSyncedSets[name] ?? '';
  if (field.isNotEmpty) {
    if (el is! Map) return '';
    final v = el[field];
    return v is String ? v : '';
  }
  return el is String ? el : '';
}

List<String> setKeys(String name, Object? list) {
  final out = <String>[];
  final seen = <String>{};
  for (final el in list is List ? list : const []) {
    final k = setKeyOf(name, el);
    if (k.isEmpty || !seen.add(k)) continue;
    out.add(k);
  }
  return out;
}

SetState _setSettle(Map<String, int> a, Map<String, int> r, Object? now) {
  for (final k in a.keys.toList()) {
    final rm = r[k];
    if (rm == null) continue;
    if (rm >= a[k]!) {
      a.remove(k);
    } else {
      r.remove(k);
    }
  }
  final floor = _int(now) - kSetTombstoneMs;
  r.removeWhere((_, v) => v < floor);
  return SetState(tsMapNorm(a), tsMapNorm(r, kSetRemovedCap));
}

SetState _setState(Object? raw, Object? now) {
  if (raw is SetState) return _setSettle({...raw.a}, {...raw.r}, now);
  final o = _obj(raw);
  return _setSettle({...tsMapNorm(o['a'])}, {...tsMapNorm(o['r'])}, now);
}

SetState setObserve(Object? raw, String name, Object? list, Object? now) {
  final keys = setKeys(name, list);
  if (raw == null) {
    return _setSettle({for (final k in keys) k: kSetSeed}, <String, int>{}, now);
  }
  final s = _setState(raw, now);
  final a = {...s.a};
  final r = {...s.r};
  final t = max(1, _int(now));
  final has = keys.toSet();
  for (final k in keys) {
    if (a.containsKey(k)) continue;
    a[k] = max(t, (r[k] ?? 0) + 1);
    r.remove(k);
  }
  for (final k in a.keys.toList()) {
    if (has.contains(k)) continue;
    r[k] = max(t, a[k]! + 1);
    a.remove(k);
  }
  return _setSettle(a, r, now);
}

SetState setAdopt(Object? raw, String name, Object? list, Object? now) {
  final s = _setState(raw ?? const <String, dynamic>{}, now);
  final a = <String, int>{};
  final r = {...s.r};
  for (final k in setKeys(name, list)) {
    a[k] = s.a[k] ?? kSetSeed;
    r.remove(k);
  }
  return _setSettle(a, r, now);
}

String _setFp(String name, Object? list) =>
    prefFp({name: list is List ? list : const []}, [name]);

Map<String, dynamic> setWire(Object? raw, String name, Object? list) {
  final s = raw is SetState ? raw.toJson() : _obj(raw);
  final a = _obj(s['a']);
  final l = list is List ? list : const [];
  return {
    'f': _setFp(name, l),
    'a': [
      for (final el in l)
        if (_int(a[setKeyOf(name, el)]) > 0)
          _int(a[setKeyOf(name, el)])
        else
          kSetSeed,
    ],
    'r': tsMapNorm(s['r'], kSetRemovedCap),
  };
}

bool _setWireValid(String name, Object? list, Object? wire) {
  final w = _obj(wire);
  final l = list is List ? list : const [];
  final a = w['a'];
  return w['f'] is String &&
      w['f'] == _setFp(name, l) &&
      a is List &&
      a.length == l.length;
}

Map<String, dynamic> setRowStamp(Object? payload, Object? rowTs) {
  final out = Map<String, dynamic>.of(_obj(payload));
  final at = max(0, _int(rowTs));
  if (at <= 0) return out;
  for (final name in kSyncedSets.keys) {
    final wk = '$name$kSetSuffix';
    final list = out[name];
    if (list is! List) continue;
    if (_setWireValid(name, list, out[wk])) continue;
    out[wk] = {
      'f': _setFp(name, list),
      'a': [for (final _ in list) at],
      'r': tsMapNorm(_obj(out[wk])['r'], kSetRemovedCap),
      'w': at,
    };
  }
  return out;
}

({Map<String, int> a, Map<String, int> r, int w}) setRemote(
    String name, Object? list, Object? wire, Object? now) {
  final w = _obj(wire);
  final l = list is List ? list : const [];
  final r = tsMapNorm(w['r']);
  final a = <String, int>{};
  if (_setWireValid(name, l, w)) {
    final stamps = w['a'] as List;
    for (var i = 0; i < l.length; i++) {
      final k = setKeyOf(name, l[i]);
      final t = max(kSetSeed, _int(stamps[i]));
      final cur = a[k];
      if (k.isNotEmpty && (cur == null || cur < t)) a[k] = t;
    }
    return (a: a, r: r, w: max(0, _int(w['w'])));
  }
  final at = max(1, _int(now));
  for (final k in setKeys(name, l)) {
    a[k] = at;
  }
  return (a: a, r: r, w: at);
}

SetState setMerge(
  Object? local,
  ({Map<String, int> a, Map<String, int> r, int w}) remote,
  Object? now,
) {
  final x = local is SetState ? local.toJson() : _obj(local);
  final a = {...tsMapNorm(x['a'])};
  final r = {...tsMapNorm(x['r'])};
  final ya = tsMapNorm(remote.a);
  final yr = tsMapNorm(remote.r);
  ya.forEach((k, v) {
    final cur = a[k];
    if (cur == null || cur < v) a[k] = v;
  });
  yr.forEach((k, v) {
    final cur = r[k];
    if (cur == null || cur < v) r[k] = v;
  });
  final w = max(0, remote.w);
  if (w > 0) {
    for (final k in a.keys.toList()) {
      if (ya.containsKey(k) || a[k]! > w) continue;
      final cur = r[k];
      if (cur == null || cur < w) r[k] = w;
    }
  }
  return _setSettle(a, r, now);
}

List<dynamic> setList(
    String name, SetState state, Object? remoteList, Object? localList) {
  final out = <dynamic>[];
  final seen = <String>{};
  for (final src in [remoteList, localList]) {
    for (final el in src is List ? src : const []) {
      final k = setKeyOf(name, el);
      if (k.isEmpty || seen.contains(k) || !state.a.containsKey(k)) continue;
      seen.add(k);
      out.add(el);
    }
  }
  return out;
}

SetGateResult setGate(
  Object? payload,
  Object? states,
  Map<String, List<dynamic>> lists,
  Object? now,
) {
  final out = Map<String, dynamic>.of(_obj(payload));
  final local = states is Map ? states : const {};
  final next = <String, SetState>{};
  var behind = false;
  for (final name in kSyncedSets.keys) {
    final wk = '$name$kSetSuffix';
    final hasWire = out[wk] is Map;
    if (out[name] is! List && !hasWire) continue;
    final list = out[name] is List ? out[name] as List : const [];
    final own = lists[name] ?? const [];
    final merged = setMerge(setObserve(local[name], name, own, now),
        setRemote(name, list, out[wk], now), now);
    final result = setList(name, merged, list, own);
    final got = setKeys(name, result);
    final want = setKeys(name, list).toSet();
    if (got.length != want.length || got.any((k) => !want.contains(k))) {
      behind = true;
    }
    out[name] = result;
    out.remove(wk);
    next[name] = merged;
  }
  return SetGateResult(out, next, behind);
}

Map<String, dynamic> setWires(
    Map<String, dynamic> payload, Map<String, Object?> states) {
  final out = <String, dynamic>{};
  for (final name in kSyncedSets.keys) {
    if (!payload.containsKey(name) && states[name] == null) continue;
    final list = payload[name];
    out['$name$kSetSuffix'] = setWire(states[name], name, list is List ? list : const []);
  }
  return out;
}

bool setShed(Map<String, dynamic> p) {
  var best = '';
  var most = 0;
  for (final name in kSyncedSets.keys) {
    final w = p['$name$kSetSuffix'];
    final n = w is Map ? _obj(w['r']).length : 0;
    if (n > most) {
      best = name;
      most = n;
    }
  }
  if (best.isNotEmpty) {
    final w = _obj(p['$best$kSetSuffix']);
    final r = tsMapNorm(w['r']);
    final keys = r.keys.toList();
    final drop = max(1, keys.length ~/ 4);
    p['$best$kSetSuffix'] = {
      ...w,
      'r': {for (final k in keys.take(keys.length - drop)) k: r[k]},
    };
    return true;
  }
  var big = '';
  var size = -1;
  for (final name in kSyncedSets.keys) {
    final w = p['$name$kSetSuffix'];
    if (w is! Map) continue;
    final a = w['a'];
    final n = a is List ? a.length : 0;
    if (n > size) {
      big = name;
      size = n;
    }
  }
  if (big.isEmpty) return false;
  p.remove('$big$kSetSuffix');
  return true;
}

Map<String, dynamic> setRealign(Object? before, Object? after) {
  final out = Map<String, dynamic>.of(_obj(after));
  final b = _obj(before);
  for (final name in kSyncedSets.keys) {
    final wk = '$name$kSetSuffix';
    final cur = out[wk];
    if (cur is! Map) continue;
    final list = out[name] is List ? out[name] as List : const [];
    if (_setWireValid(name, list, cur)) continue;
    final bl = b[name] is List ? b[name] as List : const [];
    final bw = _obj(b[wk]);
    final a = <String, int>{};
    if (_setWireValid(name, bl, bw)) {
      final stamps = bw['a'] as List;
      for (var i = 0; i < bl.length; i++) {
        final k = setKeyOf(name, bl[i]);
        if (k.isNotEmpty) a[k] = _int(stamps[i]);
      }
    }
    out[wk] = setWire({'a': a, 'r': _obj(cur)['r']}, name, list);
  }
  return out;
}

const String kColWire = 'columnsLayoutSet';
const String _kCol = 'columnsLayout';

class ColState {
  const ColState(this.a, this.r, this.w, this.o, this.k,
      [this.h = const {}]);

  final Map<String, int> a;
  final Map<String, int> r;
  final int w;
  final int o;
  final List<String> k;
  final Map<String, String> h;

  Map<String, dynamic> toJson() =>
      {'a': a, 'r': r, 'w': w, 'o': o, 'k': k, 'h': h};
}

class ColGateResult {
  const ColGateResult(
      this.payload, this.state, this.list, this.stamp, this.behind);

  final Map<String, dynamic> payload;
  final ColState? state;
  final List<dynamic>? list;
  final int stamp;
  final bool behind;
}

final RegExp _asciiUpper = RegExp('[A-Z]');

String _asciiLower(String s) =>
    s.replaceAllMapped(_asciiUpper, (m) => m[0]!.toLowerCase());

String colKey(Object? d) {
  if (d is! Map) return '';
  String str(Object? v) => v is String ? v : '';
  switch (d['type']) {
    case 'channel':
      final g = str(d['geohash']);
      final id = g.isNotEmpty ? g : str(d['channel']);
      return id.isEmpty ? '' : 'channel:${_asciiLower(id)}';
    case 'pm':
      final pk = str(d['pubkey']);
      return pk.isEmpty ? '' : 'pm:${_asciiLower(pk)}';
    case 'group':
      final g = str(d['groupId']);
      return g.isEmpty ? '' : 'group:$g';
  }
  return '';
}

Map<String, dynamic> _colItems(Object? list) {
  final out = <String, dynamic>{};
  for (final d in list is List ? list : const []) {
    final k = colKey(d);
    if (k.isNotEmpty && !out.containsKey(k)) out[k] = d;
  }
  return out;
}

String _colForm(Object? d) {
  final m = d is Map ? d : const {};
  String str(Object? v) => v is String ? v : '';
  return _setFp(_kCol, [
    str(m['type']),
    str(m['channel']),
    str(m['geohash']),
    str(m['pubkey']),
    str(m['nym']),
    str(m['groupId']),
  ]);
}

Map<String, String> _colForms(Map<String, dynamic> items, Map<String, int> a) =>
    {
      for (final e in items.entries)
        if (a.containsKey(e.key)) e.key: _colForm(e.value),
    };

List<String> _colKeyList(Object? raw) {
  final out = <String>[];
  for (final k in raw is List ? raw : const []) {
    if (k is String && k.isNotEmpty && !out.contains(k)) out.add(k);
  }
  return out;
}

ColState _colSettle(Map<String, int> a, Map<String, int> r, Object? w,
    Object? o, Object? k, Object? now) {
  final wipe = max(0, _int(w));
  for (final key in a.keys.toList()) {
    final rm = r[key];
    if (rm != null && rm >= a[key]!) {
      a.remove(key);
      continue;
    }
    r.remove(key);
    if (a[key]! < wipe) a.remove(key);
  }
  final floor = _int(now) - kSetTombstoneMs;
  r.removeWhere((_, v) => v < floor);
  final an = tsMapNorm(a);
  return ColState(an, tsMapNorm(r, kSetRemovedCap), wipe, max(0, _int(o)),
      [for (final x in _colKeyList(k)) if (an.containsKey(x)) x]);
}

ColState _colState(Object? raw, Object? now) {
  if (raw is ColState) {
    return _colSettle({...raw.a}, {...raw.r}, raw.w, raw.o, raw.k, now);
  }
  final o = _obj(raw);
  return _colSettle(
      {...tsMapNorm(o['a'])}, {...tsMapNorm(o['r'])}, o['w'], o['o'], o['k'], now);
}

List<String> _colOrder(ColState st) {
  final out = <String>[];
  final seen = <String>{};
  for (final k in st.k) {
    final v = st.a[k];
    if (v == null || v > st.o || seen.contains(k)) continue;
    seen.add(k);
    out.add(k);
  }
  final rest = st.a.keys.where((k) => !seen.contains(k)).toList()
    ..sort((x, y) {
      final d = st.a[x]!.compareTo(st.a[y]!);
      return d != 0 ? d : _cmp(x, y);
    });
  return [...out, ...rest];
}

ColState colObserve(
    Object? raw, Object? list, Object? now, Object? resetAt, Object? stamp) {
  final items = _colItems(list);
  final keys = items.keys.toList();
  final t = max(1, _int(now));
  final fresh = !(raw is ColState || raw is Map);
  final s = fresh ? null : _colState(raw, now);
  final Map<String, dynamic> was = fresh
      ? const {}
      : raw is ColState
          ? raw.h
          : _obj(_obj(raw)['h']);
  final w = max(s?.w ?? max(0, _int(stamp)), max(0, _int(resetAt)));
  final a = <String, int>{...?s?.a};
  final r = <String, int>{...?s?.r};
  for (final k in keys) {
    if (fresh) {
      a[k] = max(kSetSeed, w);
      continue;
    }
    final cur = a[k];
    if (cur != null && cur >= w) {
      final p = was[k];
      if (p is String && p != _colForm(items[k])) a[k] = max(t, cur + 1);
      continue;
    }
    a[k] = max(max(t, (r[k] ?? 0) + 1), w);
    r.remove(k);
  }
  if (!fresh) {
    for (final k in a.keys.toList()) {
      if (items.containsKey(k)) continue;
      r[k] = max(t, a[k]! + 1);
      a.remove(k);
    }
  }
  final st = _colSettle(
      a,
      r,
      w,
      fresh ? (keys.isNotEmpty ? max(1, _int(stamp)) : 0) : s!.o,
      fresh ? keys : s!.k,
      now);
  final moved = _colOrder(st).join('\n') != keys.join('\n');
  return ColState(st.a, st.r, st.w, moved ? t : st.o, moved ? keys : st.k,
      _colForms(items, st.a));
}

Map<String, dynamic> colWire(Object? st, Object? list, Object? ts) {
  final s = st is ColState ? st.toJson() : _obj(st);
  final a = _obj(s['a']);
  final l = list is List ? list : const [];
  return {
    'f': _setFp(_kCol, l),
    't': max(0, _int(ts)),
    'a': [
      for (final el in l)
        if (_int(a[colKey(el)]) > 0) _int(a[colKey(el)]) else kSetSeed,
    ],
    'r': tsMapNorm(s['r'], kSetRemovedCap),
    'w': max(0, _int(s['w'])),
    'o': max(0, _int(s['o'])),
    'k': _colKeyList(s['k']),
  };
}

bool _colWireValid(List<dynamic> list, Object? wire, int ts) {
  final w = _obj(wire);
  final a = w['a'];
  return w['f'] is String &&
      w['f'] == _setFp(_kCol, list) &&
      w['t'] is num &&
      _int(w['t']) == ts &&
      a is List &&
      a.length == list.length;
}

ColState _colRemote(List<dynamic> list, Map<String, dynamic> wire, Object? now) {
  final a = <String, int>{};
  final stamps = wire['a'] as List;
  for (var i = 0; i < list.length; i++) {
    final k = colKey(list[i]);
    final v = max(kSetSeed, _int(stamps[i]));
    final cur = a[k];
    if (k.isNotEmpty && (cur == null || cur < v)) a[k] = v;
  }
  return _colSettle(
      a, {...tsMapNorm(wire['r'])}, wire['w'], wire['o'], wire['k'], now);
}

({ColState state, List<dynamic> list}) _colMerge(ColState l,
    Map<String, dynamic> li, ColState rr, Map<String, dynamic> ri, Object? now) {
  final a = {...l.a};
  final r = {...l.r};
  rr.a.forEach((k, v) {
    final cur = a[k];
    if (cur == null || cur < v) a[k] = v;
  });
  rr.r.forEach((k, v) {
    final cur = r[k];
    if (cur == null || cur < v) r[k] = v;
  });
  final win = rr.o > l.o ||
          (rr.o == l.o && _cmp(rr.k.join('\n'), l.k.join('\n')) > 0)
      ? rr
      : l;
  final st = _colSettle(a, r, max(l.w, rr.w), win.o, win.k, now);
  final list = <dynamic>[];
  for (final k in _colOrder(st)) {
    final inL = li.containsKey(k);
    final inR = ri.containsKey(k);
    if (!inL && !inR) continue;
    final la = l.a[k] ?? 0;
    final ra = rr.a[k] ?? 0;
    final takeR = inR &&
        (!inL ||
            ra > la ||
            (ra == la && _cmp(_fpCanon(ri[k]), _fpCanon(li[k])) > 0));
    list.add(takeR ? ri[k] : li[k]);
  }
  return (state: st, list: list);
}

bool _colSame(ColState x, ColState y) =>
    _fpCanon({'a': x.a, 'w': x.w, 'o': x.o, 'k': x.k}) ==
    _fpCanon({'a': y.a, 'w': y.w, 'o': y.o, 'k': y.k});

ColGateResult colGate(Object? payload, Object? raw, Object? localList,
    Object? stamp, Object? resetAt, Object? rowTs, Object? now) {
  final out = Map<String, dynamic>.of(
      prefRowStamp(payload, rowTs, const {_kCol: [_kCol]}));
  final wire = out.remove(kColWire);
  final list = out[_kCol];
  if (list is! List) return ColGateResult(out, null, null, 0, false);
  final ts = max(0, _int(out['${_kCol}Ts']));
  out
    ..remove(_kCol)
    ..remove('${_kCol}Ts')
    ..remove('${_kCol}Fp');
  final mine = localList is List ? localList : const [];
  final l = colObserve(raw, mine, now, resetAt, stamp);
  final li = _colItems(mine);
  final ri = _colItems(list);
  final ColState rr;
  if (_colWireValid(list, wire, ts)) {
    rr = _colRemote(list, _obj(wire), now);
  } else if (!prefTake(stamp, ts)) {
    return ColGateResult(out, l, null, 0, true);
  } else if (_fpCanon(list) == _fpCanon(mine)) {
    rr = l;
  } else {
    rr = _colSettle({for (final k in ri.keys) k: max(kSetSeed, ts)},
        <String, int>{}, ts, max(1, ts), ri.keys.toList(), now);
  }
  final m = _colMerge(l, li, rr, ri, now);
  final ms = ColState(m.state.a, m.state.r, m.state.w, m.state.o, m.state.k,
      _colForms(_colItems(m.list), m.state.a));
  final at = max(_int(stamp), ts);
  out[_kCol] = m.list;
  out['${_kCol}Ts'] = at;
  final behind = _fpCanon(m.list) != _fpCanon(list) || !_colSame(ms, rr);
  return ColGateResult(out, ms, m.list, at, behind);
}
