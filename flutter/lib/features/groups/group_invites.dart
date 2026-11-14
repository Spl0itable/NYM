import 'dart:convert';

class PendingApplyResult {
  const PendingApplyResult(this.list, this.evicted, this.changed);

  final List<Map<String, dynamic>> list;
  final List<String> evicted;
  final bool changed;
}

class HoldAddResult {
  const HoldAddResult(this.state, this.accepted, this.dropped);

  final Map<String, dynamic> state;
  final bool accepted;
  final List<Map<String, dynamic>> dropped;
}

class HoldTakeResult {
  const HoldTakeResult(this.state, this.ids);

  final Map<String, dynamic> state;
  final List<String> ids;
}

class GroupInvites {
  GroupInvites._();

  static const int _day = 86400;
  static const int pendingMax = 20;
  static const int inviteMaxAge = 30 * _day;
  static const int holdPerGroup = 50;
  static const int holdTotal = 200;
  static const int holdBytes = 512 * 1024;
  static const int declinedTtl = 60 * _day;
  static const int acceptedTtl = 7 * _day;
  static const int decisionsMax = 100;
  static const int perInviterBanner = 3600;
  static const int settleSec = 600;
  static const int globalBannersPerHour = 5;
  static const int globalWindow = 3600;
  static const int liveWindow = 30;
  static const int nameMax = 40;
  static const int wrapLimitPq2 = 16384;
  static const int wrapLimitClassic = 28672;
  static const int reserve = 1024;
  static const int rumorOverhead = 256;
  static const int itemMaxBytes = 28672;
  static const int rosterMax = 100;
  static const int storeMaxBytes = 262144;
  static const int archivePerHour = 20;

  static const Map<String, int> limits = {
    'pendingMax': pendingMax,
    'inviteMaxAge': inviteMaxAge,
    'holdPerGroup': holdPerGroup,
    'holdTotal': holdTotal,
    'holdBytes': holdBytes,
    'declinedTtl': declinedTtl,
    'acceptedTtl': acceptedTtl,
    'decisionsMax': decisionsMax,
    'perInviterBanner': perInviterBanner,
    'globalBannersPerHour': globalBannersPerHour,
    'globalWindow': globalWindow,
    'liveWindow': liveWindow,
    'nameMax': nameMax,
    'wrapLimitPq2': wrapLimitPq2,
    'wrapLimitClassic': wrapLimitClassic,
    'reserve': reserve,
    'rumorOverhead': rumorOverhead,
    'itemMaxBytes': itemMaxBytes,
    'rosterMax': rosterMax,
    'storeMaxBytes': storeMaxBytes,
    'archivePerHour': archivePerHour,
  };

  static const String dTag = 'nymchat-group-invites';
  static const String payloadKey = 'groupInvites';
  static const String section = 'groupInvites';
  static const String localPrefix = 'nym_group_invites_';
  static const String probeKey = 'nym_group_invites_probe';
  static const String notifyPrefix = 'group-invite-';

  static const Map<String, String> keys = {
    'dTag': dTag,
    'payload': payloadKey,
    'section': section,
    'local': localPrefix,
    'probe': probeKey,
    'notifyPrefix': notifyPrefix,
  };

  static const String sTitle = 'Group invites';
  static const String sRowLabel = 'Group invites, {n} waiting';
  static const String sInvitedBy = 'Invited by {nym}';
  static const String sAddedBy = '{nym} added you';
  static const String sMembers = '{n}/{max} members';
  static const String sLeftBefore = 'You left this group before.';
  static const String sAccept = 'Accept';
  static const String sDecline = 'Decline';
  static const String sMore = 'More options';
  static const String sDeclineBlock = 'Decline and block {nym}';
  static const String sAcceptLabel = 'Accept invite to {group}';
  static const String sDeclineLabel = 'Decline invite to {group}';
  static const String sNotifyTitle = 'Group invite: {name}';
  static const String sNotifyInvite =
      '{nym} invited you. Open Group invites to accept or decline.';
  static const String sNotifyAdd =
      '{nym} added you. Open Group invites to accept or decline.';
  static const String sJoined = 'Joined "{name}".';
  static const String sDeclined = 'Invite declined.';
  static const String sDeclinedBlocked = 'Invite declined. {nym} is blocked.';
  static const String sStale = 'This invite is no longer available.';
  static const String sEmpty = 'No group invites.';
  static const String sClose = 'Close';
  static const String sGroup = 'Group';

  static const Map<String, String> strings = {
    'title': sTitle,
    'rowLabel': sRowLabel,
    'invitedBy': sInvitedBy,
    'addedBy': sAddedBy,
    'members': sMembers,
    'leftBefore': sLeftBefore,
    'accept': sAccept,
    'decline': sDecline,
    'more': sMore,
    'declineBlock': sDeclineBlock,
    'acceptLabel': sAcceptLabel,
    'declineLabel': sDeclineLabel,
    'notifyTitle': sNotifyTitle,
    'notifyInvite': sNotifyInvite,
    'notifyAdd': sNotifyAdd,
    'joined': sJoined,
    'declined': sDeclined,
    'declinedBlocked': sDeclinedBlocked,
    'stale': sStale,
    'empty': sEmpty,
    'close': sClose,
    'group': sGroup,
  };

  static const List<String> verdicts = [
    'route',
    'pending-new',
    'pending-update',
    'hold',
    'drop',
  ];

  static const Map<String, int> _rank = {'d': 1, 'a': 2};
  static final RegExp _gidRe = RegExp(r'^[0-9A-Za-z_-]{1,128}$');
  static final RegExp _ctl = RegExp('[\u0000-\u001f\u007f]');
  static final RegExp _ws = RegExp(r'\s+');
  static final RegExp _edge = RegExp(r'^\s+|\s+$');

  static int toInt(Object? x) {
    num? n;
    if (x is num) {
      n = x;
    } else if (x is bool) {
      n = x ? 1 : 0;
    } else if (x is String) {
      final t = x.replaceAll(_edge, '');
      n = t.isEmpty ? 0 : num.tryParse(t);
    }
    if (n == null || !n.isFinite) return 0;
    final f = n.floor();
    return f > 0 ? f : 0;
  }

  static String _str(Object? x) => x is String ? x : '';

  static bool _t(Object? x) =>
      x != null &&
      x != false &&
      x != 0 &&
      x != '' &&
      !(x is double && x.isNaN);

  static int _cmpStr(String a, String b) => a.compareTo(b);

  static String fill(String text, Map<String, Object?> vars) =>
      text.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
        final v = vars[m[1]];
        return v == null ? m[0]! : '$v';
      });

  static String clampName(Object? name) {
    final s = _str(name)
        .replaceAll(_ctl, ' ')
        .replaceAll(_ws, ' ')
        .replaceAll(_edge, '');
    return String.fromCharCodes(s.runes.take(nameMax)).replaceAll(_edge, '');
  }

  static String notifyId(Object? gid) => '$notifyPrefix${_str(gid)}';

  static int inviteTime(Object? createdAt, Object? now) {
    final a = toInt(createdAt);
    final b = toInt(now);
    return a < b ? a : b;
  }

  static bool isLive(Object? it, Object? now, bool backlog) =>
      !backlog && toInt(now) - toInt(it) <= liveWindow;

  static List<String> _tagVals(List tags, String k, [int max = 0]) {
    final out = <String>[];
    for (final t in tags) {
      if (max > 0 && out.length >= max) break;
      if (t is List &&
          t.length > 1 &&
          t[0] == k &&
          t[1] is String &&
          (t[1] as String).isNotEmpty &&
          !out.contains(t[1])) {
        out.add(t[1] as String);
      }
    }
    return out;
  }

  static int rumorBytes(Object? rumor) {
    if (rumor is! Map) return 0;
    try {
      return utf8.encode(jsonEncode(rumor)).length;
    } catch (_) {
      return itemMaxBytes + 1;
    }
  }

  static int storeBytes(List list) {
    var t = 0;
    for (final i in list) {
      if (i is Map) t += toInt(i['b']);
    }
    return t;
  }

  static String? bellPicture(String? eventId, String? picture) =>
      (eventId ?? '').startsWith(notifyPrefix) ? null : picture;

  static String? _tagVal(List tags, String k) {
    final v = _tagVals(tags, k);
    return v.isEmpty ? null : v.first;
  }

  static List _tagsOf(Object? rumor) {
    if (rumor is Map && rumor['tags'] is List) return rumor['tags'] as List;
    return const [];
  }

  static Map<String, dynamic> rosterOf(Object? rumor) {
    final tags = _tagsOf(rumor);
    List? ai;
    for (final t in tags) {
      if (t is List && t.isNotEmpty && t[0] == 'allow_invites') {
        ai = t;
        break;
      }
    }
    return {
      'members': _tagVals(tags, 'p', rosterMax),
      'admins': _tagVals(tags, 'admin', rosterMax),
      'mods': _tagVals(tags, 'mod', rosterMax),
      'owner': _tagVal(tags, 'owner'),
      'gowner': _tagVal(tags, 'gowner'),
      'ai': ai == null ? true : (ai.length < 2 || ai[1] != '0'),
    };
  }

  static bool _has(Object? list, String pk) => list is List && list.contains(pk);

  static String? roleOf(Map? item, String? pk) {
    if (item == null || pk == null || pk.isEmpty) return null;
    if (item['owner'] == pk) return 'owner';
    if (_has(item['admins'], pk)) return 'admin';
    if (_has(item['mods'], pk)) return 'mod';
    if (_has(item['members'], pk)) return 'member';
    return null;
  }

  static Map<String, dynamic> _drop(String r) => {'v': 'drop', 'r': r};

  static Map<String, dynamic> gate(Map x) {
    if (_t(x['anon'])) return _drop('anon');
    if (_t(x['own'])) return {'v': 'route', 'r': 'own'};
    if (_t(x['joined'])) return {'v': 'route', 'r': 'joined'};
    if (_t(x['started'])) return {'v': 'route', 'r': 'started'};
    if (_t(x['blocked'])) return _drop('blocked');
    if (_t(x['hidden'])) return _drop('hidden');
    if (x['accept'] == 'disabled') return _drop('pms-off');
    if (x['accept'] == 'friends' && !_t(x['friend'])) {
      return _drop('friends-only');
    }
    final inv = x['type'] == 'group-invite';
    final add = x['type'] == 'group-add-member';
    final pending = _t(x['pending']) && x['pending'] is Map
        ? x['pending'] as Map
        : null;
    if (!inv && !add) {
      return pending != null
          ? {'v': 'hold', 'r': 'held'}
          : _drop('unknown-group');
    }
    if (x['genesis'] == false) return _drop('genesis');
    var boot = false;
    final sender = x['sender'];
    if (inv) {
      if (x['genesis'] == true && sender != x['gowner']) {
        return _drop('not-owner');
      }
      if (pending != null &&
          _t(pending['owner']) &&
          pending['owner'] != sender) {
        return _drop('not-owner');
      }
      boot = true;
    } else {
      final claimed = _t(x['owner']) &&
          x['owner'] == sender &&
          (x['genesis'] != true || x['owner'] == x['gowner']);
      if (pending != null) {
        final role = roleOf(pending, sender is String ? sender : null);
        final ok = role == 'owner' ||
            role == 'admin' ||
            role == 'mod' ||
            (role == 'member' && pending['ai'] != false);
        if (!ok) return _drop('no-role');
        boot = claimed && role == 'owner';
      } else {
        if (!claimed) return _drop('not-owner');
        boot = true;
      }
    }
    if (toInt(x['bytes']) > itemMaxBytes) return _drop('too-big');
    final now = toInt(x['now']);
    final it = toInt(x['it']);
    if (now - it > inviteMaxAge) return _drop('expired');
    final decision = x['decision'];
    if (_t(decision) &&
        it <= toInt(decision is Map ? decision['dt'] : null)) {
      return _drop('decided');
    }
    if (_t(x['left']) && it <= toInt(x['leftAt'])) return _drop('left');
    final left = _t(x['left']);
    if (pending != null) {
      if (it > toInt(pending['it'])) {
        return {'v': 'pending-update', 'r': 'newer', 'boot': boot, 'left': left};
      }
      return _drop('older');
    }
    return {'v': 'pending-new', 'r': 'new', 'boot': boot, 'left': left};
  }

  static Map<String, dynamic> itemFrom(Map x) {
    final r = rosterOf(x['rumor']);
    final tags = _tagsOf(x['rumor']);
    final via = x['type'] == 'group-add-member' ? 'add' : 'invite';
    final owner = r['owner'] as String?;
    return {
      'gid': _str(x['gid']),
      'it': toInt(x['it']),
      'by': _str(x['sender']),
      'via': via,
      'n': clampName(_tagVal(tags, 'subject') ?? ''),
      'm': (r['members'] as List).length,
      'owner': via == 'invite'
          ? _str(x['sender'])
          : _str(owner != null && owner.isNotEmpty ? owner : x['sender']),
      'admins': r['admins'],
      'mods': r['mods'],
      'members': r['members'],
      'ai': r['ai'],
      'at': toInt(x['now']),
      'nt': 0,
      'left': _t(x['left']),
      'rumor': x['rumor'] is Map ? x['rumor'] : null,
      'wrapId': _str(x['wrapId']),
      'b': rumorBytes(x['rumor']),
    };
  }

  static List<Map<String, dynamic>> _sortItems(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      final d = toInt(b['it']) - toInt(a['it']);
      return d != 0 ? d : _cmpStr(_str(a['gid']), _str(b['gid']));
    });
    return list;
  }

  static PendingApplyResult capPending(
      List<Map<String, dynamic>> list, List? friends) {
    final out = List<Map<String, dynamic>>.of(list);
    final fr = friends ?? const [];
    final evicted = <String>[];
    while (out.length > pendingMax ||
        (out.length > 1 && storeBytes(out) > storeMaxBytes)) {
      final pool = out.where((i) => !fr.contains(i['by'])).toList();
      final from = pool.isNotEmpty ? pool : out;
      var v = from.first;
      for (final i in from) {
        final a = toInt(i['it']);
        final b = toInt(v['it']);
        if (a < b || (a == b && _cmpStr(_str(i['gid']), _str(v['gid'])) < 0)) {
          v = i;
        }
      }
      out.remove(v);
      evicted.add(_str(v['gid']));
    }
    return PendingApplyResult(_sortItems(out), evicted, true);
  }

  static const List<String> _bootKeys = [
    'owner',
    'rumor',
    'wrapId',
    'admins',
    'mods',
    'ai',
    'b',
  ];

  static PendingApplyResult pendingApply(
      List<Map<String, dynamic>>? list, Map verdict, Map item, List? friends) {
    final cur = List<Map<String, dynamic>>.of(list ?? const []);
    final at = cur.indexWhere((i) => i['gid'] == item['gid']);
    final v = verdict['v'];
    if (v == 'pending-new') {
      if (at >= 0) return PendingApplyResult(_sortItems(cur), const [], false);
      cur.add(Map<String, dynamic>.of(item.cast<String, dynamic>()));
    } else if (v == 'pending-update') {
      if (at < 0) return PendingApplyResult(_sortItems(cur), const [], false);
      final old = cur[at];
      final next = Map<String, dynamic>.of(item.cast<String, dynamic>())
        ..['at'] = old['at']
        ..['nt'] = old['nt']
        ..['left'] = _t(old['left']) || _t(item['left']);
      if (!_t(verdict['boot'])) {
        for (final k in _bootKeys) {
          if (old.containsKey(k)) {
            next[k] = old[k];
          } else {
            next.remove(k);
          }
        }
      }
      cur[at] = next;
    } else {
      return PendingApplyResult(_sortItems(cur), const [], false);
    }
    final c = capPending(cur, friends);
    return PendingApplyResult(c.list, c.evicted, true);
  }

  static List<Map<String, dynamic>> pendingRemove(
          List<Map<String, dynamic>>? list, String gid) =>
      [for (final i in list ?? const <Map<String, dynamic>>[]) if (i['gid'] != gid) i];

  static Map<String, dynamic> notifyState(Object? s, int now) {
    final last = <String, int>{};
    final src = s is Map && s['last'] is Map ? s['last'] as Map : const {};
    final ks = [for (final k in src.keys) '$k']..sort();
    for (final k in ks) {
      final t = toInt(src[k]);
      if (t != 0 && now - t < perInviterBanner) last[k] = t;
    }
    final raw = s is Map && s['recent'] is List ? s['recent'] as List : const [];
    final recent = [
      for (final x in raw)
        if (toInt(x) != 0 && now - toInt(x) < globalWindow) toInt(x),
    ]..sort();
    return {'last': last, 'recent': recent};
  }

  static Map<String, dynamic> notifyDecision(Object? s, Map x) {
    final now = toInt(x['now']);
    final st = notifyState(s, now);
    final last = st['last'] as Map<String, int>;
    final recent = st['recent'] as List<int>;
    final bell = x['verdict'] == 'pending-new';
    var reason = 'banner';
    if (!bell) {
      reason = 'not-new';
    } else if (!_t(x['live'])) {
      reason = 'historical';
    } else if (!_t(x['toast'])) {
      reason = 'toast-off';
    } else if (last.containsKey(x['by'])) {
      reason = 'inviter-recent';
    } else if (recent.length >= globalBannersPerHour) {
      reason = 'global-cap';
    }
    final banner = reason == 'banner';
    if (banner) {
      last['${x['by']}'] = now;
      recent.add(now);
    }
    return {'banner': banner, 'bell': bell, 'reason': reason, 'state': st};
  }

  static Map<String, dynamic>? _clean(Object? e) {
    if (e is! Map || !_rank.containsKey(e['s'])) return null;
    final it = toInt(e['it']);
    final dt = toInt(e['dt']);
    if (it == 0 || dt == 0) return null;
    return {'s': e['s'], 'it': it, 'dt': dt};
  }

  static int cmpDecision(Map a, Map b) {
    final i = (a['it'] as int) - (b['it'] as int);
    if (i != 0) return i;
    final r = _rank[a['s']]! - _rank[b['s']]!;
    if (r != 0) return r;
    return (a['dt'] as int) - (b['dt'] as int);
  }

  static bool _expired(Map e, int now) {
    final ttl = e['s'] == 'a' ? acceptedTtl : declinedTtl;
    return now - (e['dt'] as int) > ttl;
  }

  static Map<String, Map<String, dynamic>> normalizeDecisions(
      Object? d, Object? now) {
    final n = toInt(now);
    final src = d is Map ? d : const {};
    var entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final k in src.keys) {
      if (k is! String || !_gidRe.hasMatch(k)) continue;
      final e = _clean(src[k]);
      if (e == null || _expired(e, n)) continue;
      entries.add(MapEntry(k, e));
    }
    if (entries.length > decisionsMax) {
      entries.sort((x, y) {
        final c = cmpDecision(y.value, x.value);
        return c != 0 ? c : _cmpStr(x.key, y.key);
      });
      entries = entries.sublist(0, decisionsMax);
    }
    entries.sort((x, y) => _cmpStr(x.key, y.key));
    return {for (final e in entries) e.key: e.value};
  }

  static Map<String, Map<String, dynamic>> mergeDecisions(
      Object? a, Object? b, Object? now) {
    final aa = normalizeDecisions(a, now);
    final bb = normalizeDecisions(b, now);
    final out = Map<String, Map<String, dynamic>>.of(aa);
    for (final k in bb.keys) {
      final cur = out[k];
      if (cur == null || cmpDecision(bb[k]!, cur) > 0) out[k] = bb[k]!;
    }
    return normalizeDecisions(out, now);
  }

  static Map<String, Map<String, dynamic>> decide(
          Object? d, String gid, String s, Object? it, Object? now) =>
      mergeDecisions(d, {
        gid: {'s': s, 'it': toInt(it), 'dt': toInt(now)},
      }, now);

  static Map<String, dynamic> publishable(Object? d) =>
      {'v': 1, 'd': d is Map ? d : <String, dynamic>{}};

  static Map fromPayload(Object? p) {
    if (p is! Map) return const {};
    final d = p['d'];
    return d is Map ? d : const {};
  }

  static int rowBytes(Object? payload) =>
      utf8.encode(jsonEncode(jsonEncode(payload))).length + rumorOverhead;

  static bool fitsRow(Object? payload, {bool pq2 = true}) =>
      rowBytes(payload) <= (pq2 ? wrapLimitPq2 : wrapLimitClassic) - reserve;

  static bool trimPayload(Map<String, dynamic> payload) {
    final g = payload[payloadKey];
    final d = g is Map ? g['d'] : null;
    if (d is! Map) return false;
    final ks = d.keys.toList();
    if (ks.isEmpty) return false;
    var lo = ks.first;
    for (final k in ks) {
      final e = _clean(d[k]);
      final l = _clean(d[lo]);
      if (e == null) {
        lo = k;
        break;
      }
      if (l == null ||
          cmpDecision(e, l) < 0 ||
          (cmpDecision(e, l) == 0 && _cmpStr('$k', '$lo') < 0)) {
        lo = k;
      }
    }
    d.remove(lo);
    return true;
  }

  static Map<String, dynamic> holdNew() => {'g': <String, dynamic>{}};

  static Map<String, List<Map<String, dynamic>>> _holdCopy(Object? state) {
    final out = <String, List<Map<String, dynamic>>>{};
    final src = state is Map && state['g'] is Map ? state['g'] as Map : const {};
    for (final k in src.keys) {
      out['$k'] = [
        for (final e in (src[k] as List))
          {'id': (e as Map)['id'], 'ts': e['ts'], 'b': e['b']},
      ];
    }
    return out;
  }

  static ({String gid, Map<String, dynamic> e})? _holdOldest(
      Map<String, List<Map<String, dynamic>>> h, String? only) {
    ({String gid, Map<String, dynamic> e})? best;
    for (final gid in h.keys) {
      if (only != null && gid != only) continue;
      for (final e in h[gid]!) {
        final b = best;
        if (b == null ||
            (e['ts'] as int) < (b.e['ts'] as int) ||
            (e['ts'] == b.e['ts'] &&
                _cmpStr(e['id'] as String, b.e['id'] as String) < 0)) {
          best = (gid: gid, e: e);
        }
      }
    }
    return best;
  }

  static void _holdDrop(
      Map<String, List<Map<String, dynamic>>> h, String gid, String id) {
    final list = h[gid] ?? <Map<String, dynamic>>[];
    final i = list.indexWhere((e) => e['id'] == id);
    if (i >= 0) list.removeAt(i);
    if (list.isEmpty) h.remove(gid);
  }

  static HoldAddResult holdAdd(Object? state, Map x) {
    final h = _holdCopy(state);
    final gid = _str(x['gid']);
    final e = <String, dynamic>{
      'id': _str(x['id']),
      'ts': toInt(x['ts']),
      'b': toInt(x['b']),
    };
    Map<String, dynamic> wrap() => {'g': h};
    if ((e['id'] as String).isEmpty || (e['b'] as int) > holdBytes) {
      return HoldAddResult(wrap(), false, const []);
    }
    if ((h[gid] ?? const []).any((y) => y['id'] == e['id'])) {
      return HoldAddResult(wrap(), false, const []);
    }
    h.putIfAbsent(gid, () => <Map<String, dynamic>>[]).add(e);
    final dropped = <Map<String, dynamic>>[];
    while ((h[gid] ?? const []).length > holdPerGroup) {
      final o = _holdOldest(h, gid)!;
      _holdDrop(h, o.gid, o.e['id'] as String);
      dropped.add({'gid': o.gid, 'id': o.e['id']});
    }
    while (true) {
      var n = 0;
      var b = 0;
      for (final l in h.values) {
        for (final y in l) {
          n++;
          b += y['b'] as int;
        }
      }
      if (n <= holdTotal && b <= holdBytes) break;
      final o = _holdOldest(h, null)!;
      _holdDrop(h, o.gid, o.e['id'] as String);
      dropped.add({'gid': o.gid, 'id': o.e['id']});
    }
    final accepted =
        !dropped.any((d) => d['gid'] == gid && d['id'] == e['id']);
    for (final l in h.values) {
      l.sort((a, b) {
        final d = (a['ts'] as int) - (b['ts'] as int);
        return d != 0 ? d : _cmpStr(a['id'] as String, b['id'] as String);
      });
    }
    return HoldAddResult(wrap(), accepted, dropped);
  }

  static HoldTakeResult holdTake(Object? state, String gid) {
    final h = _holdCopy(state);
    final list = h.remove(gid) ?? <Map<String, dynamic>>[];
    list.sort((a, b) {
      final d = (a['ts'] as int) - (b['ts'] as int);
      return d != 0 ? d : _cmpStr(a['id'] as String, b['id'] as String);
    });
    return HoldTakeResult({'g': h}, [for (final e in list) e['id'] as String]);
  }

  static Map<String, dynamic> archiveDecision(Object? s, Map x) {
    final now = toInt(x['now']);
    final st = notifyState(s, now);
    final last = st['last'] as Map<String, int>;
    final recent = st['recent'] as List<int>;
    final v = x['verdict'];
    final by = _str(x['by']);
    var reason = 'archive';
    if (v != 'pending-new' && !(v == 'pending-update' && _t(x['boot']))) {
      reason = 'not-new';
    } else if (!_t(x['kept'])) {
      reason = 'evicted';
    } else if (by.isNotEmpty && last.containsKey(by)) {
      reason = 'per-inviter';
    } else if (recent.length >= archivePerHour) {
      reason = 'global';
    }
    final archive = reason == 'archive';
    if (archive) {
      if (by.isNotEmpty) last[by] = now;
      recent.add(now);
    }
    return {'archive': archive, 'reason': reason, 'state': st};
  }

  static List _capList(Object? a) =>
      a is List ? a.take(rosterMax).toList() : <dynamic>[];

  static List<Map<String, dynamic>> normalizeItems(Object? list, Object? now) {
    final n = toInt(now);
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final i in list is List ? list : const []) {
      if (i is! Map) continue;
      final gid = _str(i['gid']);
      if (!_gidRe.hasMatch(gid) || seen.contains(gid)) continue;
      if (n - toInt(i['it']) > inviteMaxAge) continue;
      if (i['rumor'] is! Map) continue;
      final b = rumorBytes(i['rumor']);
      if (b > itemMaxBytes) continue;
      seen.add(gid);
      final m = toInt(i['m']);
      out.add(Map<String, dynamic>.of(i.cast<String, dynamic>())
        ..['members'] = _capList(i['members'])
        ..['admins'] = _capList(i['admins'])
        ..['mods'] = _capList(i['mods'])
        ..['m'] = m > rosterMax ? rosterMax : m
        ..['b'] = b);
    }
    final kept = <Map<String, dynamic>>[];
    var total = 0;
    for (final i in _sortItems(out)) {
      if (kept.length >= pendingMax) break;
      final b = toInt(i['b']);
      if (kept.isNotEmpty && total + b > storeMaxBytes) continue;
      total += b;
      kept.add(i);
    }
    return kept;
  }

  static List<String> _uniqKeys(Object? list, [Iterable<String> skip = const []]) {
    final out = <String>[];
    final seen = <String>{...skip};
    for (final k in list is List ? list : const []) {
      if (k is! String || k.isEmpty || seen.contains(k)) continue;
      seen.add(k);
      out.add(k);
    }
    return out;
  }

  static String _cur(Object? m) =>
      m is Map && m['current'] is String ? m['current'] as String : '';

  static Map<String, dynamic>? settleSelf(
      Object? local, Object? synced, bool settle, Object? max) {
    final cap = toInt(max);
    final sc = _cur(synced);
    final lc = _cur(local);
    final sp = synced is Map ? synced['prev'] : null;
    if (lc.isEmpty) {
      return sc.isEmpty
          ? null
          : {
              'current': sc,
              'prev': _uniqKeys(sp, [sc]).take(cap).toList(),
              'adopted': true,
            };
    }
    var current = lc;
    var prev = _uniqKeys((local as Map)['prev'], [lc]);
    var adopted = false;
    if (sc.isNotEmpty && sc != lc && settle && sc.compareTo(lc) < 0) {
      prev = [lc, ...prev.where((k) => k != sc)];
      current = sc;
      adopted = true;
    }
    if (sc.isNotEmpty) {
      prev = [
        ...prev,
        ..._uniqKeys([sc, ...(sp is List ? sp : const [])], [current, ...prev]),
      ];
    }
    return {
      'current': current,
      'prev': prev.take(cap).toList(),
      'adopted': adopted,
    };
  }

  static bool settleOpen(Object? m, int now) {
    final at = m is Map ? toInt(m['at']) : 0;
    return at > 0 && now - at < settleSec && at - now < settleSec;
  }

  static bool settleDue(
      Object? m, Object? row, Object? minted, Object? current, int now) {
    return settleOpen(m, now) &&
        !(m is Map && m['repaired'] == true) &&
        settleRepair(row, minted, current);
  }

  static const int leftRolesMax = 9;
  static const int leftGroupsMax = 100;
  static const int leftRolesSyncMax = 8;
  static final RegExp _pkx = RegExp(r'^[0-9a-f]{64}$');

  static Map<String, List<String>> leftRoles(Object? m, [Iterable<String>? gids]) {
    final src = m is Map ? m : const {};
    final only = gids?.toSet();
    final out = <String, List<String>>{};
    final keys = [for (final k in src.keys) '$k']..sort(_cmpStr);
    for (final k in keys) {
      if (out.length >= leftGroupsMax) break;
      if (!_gidRe.hasMatch(k) || (only != null && !only.contains(k))) continue;
      final v = _uniqKeys(src[k]);
      if (v.isEmpty || v.length > leftRolesMax || !v.every(_pkx.hasMatch)) continue;
      out[k] = v;
    }
    return out;
  }

  static Map<String, List<String>> leftRolesNote(
      Object? m, Object? gid, Object? owner, Object? mods, [Iterable<String>? gids]) {
    final g = _str(gid);
    final out = {...leftRoles(m, gids)}..remove(g);
    final list = _uniqKeys([_str(owner), ...(mods is List ? mods : const [])]);
    if (_gidRe.hasMatch(g) &&
        _pkx.hasMatch(_str(owner)) &&
        list.length <= leftRolesMax &&
        list.every(_pkx.hasMatch)) {
      out[g] = list;
    }
    return leftRoles(out);
  }

  static Map<String, List<String>> leftRolesSync(
      Object? m, Iterable<String>? gids, Object? times) {
    final all = leftRoles(m, gids ?? const <String>[]);
    final t = times is Map ? times : const {};
    int at(String k) {
      final v = toInt(t[k]);
      return v > 0 ? v : 0;
    }
    final keep = all.keys.toList()
      ..sort((a, b) {
        final d = at(b) - at(a);
        return d != 0 ? d : _cmpStr(a, b);
      });
    final pick = keep.take(leftRolesSyncMax).toList()..sort(_cmpStr);
    return {for (final k in pick) k: all[k]!};
  }

  static Map<String, List<String>> leftRolesMerge(
      Object? m, Object? incoming, Iterable<String>? gids) {
    final out = {...leftRoles(m)};
    final add = leftRoles(incoming, gids ?? const <String>[]);
    for (final e in add.entries) {
      out.putIfAbsent(e.key, () => e.value);
    }
    return leftRoles(out);
  }

  static bool? leftRole(Object? m, Object? gid, Object? sender) {
    final v = leftRoles(m)[_str(gid)];
    return v?.contains(_str(sender));
  }

  static Map<String, dynamic>? settleKeep(Object? m, int now) {
    if (m is! Map) return null;
    final pk = m['pk'];
    if (pk is! String || pk.isEmpty || !settleOpen(m, now)) return null;
    return {'pk': pk, 'at': toInt(m['at']), 'repaired': m['repaired'] == true};
  }

  static bool settleRepair(Object? row, Object? minted, Object? current) {
    if (minted is! String || minted.isEmpty) return false;
    final rc = row is Map ? row['current'] : null;
    final rp = row is Map ? row['prev'] : null;
    final pks = rc is String ? [rc, ...(rp is List ? rp : const [])] : const [];
    return !pks.contains(minted) || !pks.contains(current);
  }

  static Map<String, dynamic> probe(Map x) {
    final now = toInt(x['now']);
    final counted = _uniqKeys(x['counted'])..sort(_cmpStr);
    Map<String, dynamic> out(String v, Object? r, [Map<String, dynamic>? extra]) => {
          'v': v,
          'r': r,
          'count': v == 'count',
          'notify': false,
          'counted': counted,
          'ns': notifyState(x['ns'], now),
          ...?extra,
        };
    final g = gate(x);
    if (g['v'] == 'route') return out('route', g['r']);
    if (g['v'] != 'pending-new') return out('none', g['r']);
    final gid = _str(x['gid']);
    if (counted.contains(gid)) return out('none', 'counted');
    if (toInt(x['stored']) + counted.length >= pendingMax) {
      return out('none', 'cap');
    }
    final nd = notifyDecision(x['ns'], {
      'verdict': 'pending-new',
      'now': now,
      'live': isLive(toInt(x['it']), now, !_t(x['live'])),
      'toast': true,
      'by': x['sender'],
    });
    return out('count', nd['reason'], {
      'notify': nd['banner'] == true && x['readable'] != false,
      'counted': [...counted, gid]..sort(_cmpStr),
      'ns': nd['state'],
    });
  }

  static Map<String, dynamic> probeState(Object? s, int now,
      [Iterable<String> skip = const []]) {
    final drop = skip.toSet();
    final c0 = s is Map ? s['c'] : null;
    final src = c0 is Map ? c0 : const {};
    final kept = [
      for (final e in src.entries)
        if (_gidRe.hasMatch('${e.key}') &&
            !drop.contains('${e.key}') &&
            toInt(e.value) != 0 &&
            now - toInt(e.value) < inviteMaxAge &&
            toInt(e.value) - now < inviteMaxAge)
          MapEntry('${e.key}', toInt(e.value)),
    ]..sort((p, q) {
        final byT = q.value.compareTo(p.value);
        return byT != 0 ? byT : _cmpStr(p.key, q.key);
      });
    final top = kept.take(pendingMax).toList()
      ..sort((p, q) => _cmpStr(p.key, q.key));
    return {
      'c': <String, int>{for (final e in top) e.key: e.value},
      'ns': notifyState(s is Map ? s['ns'] : null, now),
    };
  }

  static Map<String, dynamic> probeKeep(
      Object? st, Map? r, Object? gid, int now) {
    final base = probeState(st, now);
    final g = _str(gid);
    if (r == null || r['v'] != 'count' || !_gidRe.hasMatch(g)) return base;
    return probeState({
      'c': {...base['c'] as Map<String, int>, g: now},
      'ns': r['ns'],
    }, now);
  }

  static Map<String, dynamic> unbanState(Object? s, int now) {
    final src = s is Map && s['last'] is Map ? s['last'] as Map : const {};
    final kept = [
      for (final e in src.entries)
        if (_gidRe.hasMatch('${e.key}') &&
            toInt(e.value) != 0 &&
            now - toInt(e.value) < perInviterBanner)
          MapEntry('${e.key}', toInt(e.value)),
    ]..sort((p, q) {
        final byT = q.value.compareTo(p.value);
        return byT != 0 ? byT : _cmpStr(p.key, q.key);
      });
    final top = kept.take(decisionsMax).toList()
      ..sort((p, q) => _cmpStr(p.key, q.key));
    return {
      'last': <String, int>{for (final e in top) e.key: e.value},
    };
  }

  static Map<String, dynamic> unbanNotice(Object? s, Map x) {
    final now = toInt(x['now']);
    final state = unbanState(s, now);
    Map<String, dynamic> no(String r) =>
        {'notice': false, 'archive': false, 'r': r, 'state': state};
    if (_t(x['blocked'])) return no('blocked');
    if (_t(x['hidden'])) return no('hidden');
    if (x['accept'] == 'disabled') return no('pms-off');
    if (x['accept'] == 'friends' && !_t(x['friend'])) return no('friends-only');
    if (toInt(x['it']) <= toInt(x['leftAt'])) return no('left');
    final known = _t(x['known']);
    if (x['role'] == false || (known && x['role'] != true)) return no('role');
    final gid = _str(x['gid']);
    final last = state['last'] as Map<String, int>;
    if (last.containsKey(gid)) return no('gid-recent');
    last[gid] = now;
    return {
      'notice': true,
      'archive': known,
      'generic': !known,
      'r': 'notice',
      'state': unbanState(state, now),
    };
  }
}
