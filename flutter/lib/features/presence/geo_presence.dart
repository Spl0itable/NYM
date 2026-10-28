import 'dart:math' as math;

class GeoPresenceVerdict {
  const GeoPresenceVerdict(this.ok, this.reason, this.atMs);
  final bool ok;
  final String reason;
  final int atMs;
  Map<String, dynamic> toJson() => {'ok': ok, 'reason': reason, 'atMs': atMs};
}

class GeoPresenceActivity {
  const GeoPresenceActivity(this.counts, this.seenMs, this.shownSeenMs);
  final bool counts;
  final int seenMs;
  final int shownSeenMs;
  Map<String, dynamic> toJson() =>
      {'counts': counts, 'seenMs': seenMs, 'shownSeenMs': shownSeenMs};
}

class GeoPresenceSendInput {
  const GeoPresenceSendInput({
    this.type = 'geohash',
    required this.geohash,
    this.name,
    required this.onScreen,
    required this.foreground,
    required this.focused,
    required this.idle,
    required this.presence,
    required this.status,
    required this.connected,
    required this.meshOnly,
    required this.locked,
    required this.rotatingKey,
    this.showInCounts = true,
    this.anonymous = false,
    this.sendAs,
    this.key = 'identity',
  });

  factory GeoPresenceSendInput.fromJson(Map<String, dynamic> i) =>
      GeoPresenceSendInput(
        type: i['type'] is String ? i['type'] as String : '',
        geohash: i['geohash'] is String ? i['geohash'] as String : null,
        name: i['name'] is String ? i['name'] as String : null,
        onScreen: i['onScreen'] == true,
        foreground: i['foreground'] == true,
        focused: i['focused'] == true,
        idle: i['idle'] != false,
        presence: i['presence'] == true,
        status: i['status'] is String ? i['status'] as String : null,
        connected: i['connected'] == true,
        meshOnly: i['meshOnly'] == true,
        locked: i['locked'] == true,
        rotatingKey: i['rotatingKey'] == true,
        showInCounts: i['showInCounts'] == true,
        anonymous: i['anonymous'] == true,
        sendAs: i['sendAs'] is String ? i['sendAs'] as String : null,
        key: i['key'] == 'anonymous' ? 'anonymous' : 'identity',
      );

  final String type;
  final String? geohash;
  final String? name;
  final bool onScreen;
  final bool foreground;
  final bool focused;
  final bool idle;
  final bool presence;
  final String? status;
  final bool connected;
  final bool meshOnly;
  final bool locked;
  final bool rotatingKey;
  final bool showInCounts;
  final bool anonymous;
  final String? sendAs;
  final String key;

  GeoPresenceSendInput withOverrides(
          {bool? onScreen, bool? focused, bool? idle, String? key}) =>
      GeoPresenceSendInput(
        type: type,
        geohash: geohash,
        name: name,
        onScreen: onScreen ?? this.onScreen,
        foreground: foreground,
        focused: focused ?? this.focused,
        idle: idle ?? this.idle,
        presence: presence,
        status: status,
        connected: connected,
        meshOnly: meshOnly,
        locked: locked,
        rotatingKey: rotatingKey,
        showInCounts: showInCounts,
        anonymous: anonymous,
        sendAs: sendAs,
        key: key ?? this.key,
      );
}

class GeoPresenceSendPlan {
  const GeoPresenceSendPlan(this.send, this.reason, this.key);
  final bool send;
  final String reason;
  final String? key;
  Map<String, dynamic> toJson() => {'send': send, 'reason': reason, 'key': key};
}

class GeoPresenceAnonInput {
  const GeoPresenceAnonInput({
    required this.gate,
    required this.pubkey,
    required this.newest,
    required this.signedIn,
    required this.nowMs,
    this.stopAtMs = 0,
    this.identityMs = const [],
  });

  factory GeoPresenceAnonInput.fromJson(Map<String, dynamic> i) =>
      GeoPresenceAnonInput(
        gate: GeoPresenceSendInput.fromJson(i),
        pubkey: i['pubkey'] is String ? i['pubkey'] as String : '',
        newest: i['newest'] is String ? i['newest'] as String : '',
        signedIn: i['signedIn'] == true,
        nowMs: i['nowMs'] is num ? (i['nowMs'] as num).toInt() : 0,
        stopAtMs: i['stopAtMs'] is num ? (i['stopAtMs'] as num).toInt() : 0,
        identityMs: i['identityMs'] is List
            ? List<Object?>.from(i['identityMs'] as List)
            : const [],
      );

  final GeoPresenceSendInput gate;
  final String pubkey;
  final String newest;
  final bool signedIn;
  final int nowMs;
  final int stopAtMs;
  final List<Object?> identityMs;
}

class GeoPresenceAnonTick {
  const GeoPresenceAnonTick(this.action, this.reason, this.atMs);
  final String action;
  final String reason;
  final int atMs;
  Map<String, dynamic> toJson() =>
      {'action': action, 'reason': reason, 'atMs': atMs};
}

class GeoPresenceShape {
  const GeoPresenceShape(this.ok, this.reason, this.type, this.channel, this.atMs);
  final bool ok;
  final String reason;
  final String? type;
  final String? channel;
  final int atMs;
  Map<String, dynamic> toJson() => {
        'ok': ok,
        'reason': reason,
        'type': type,
        'channel': channel,
        'atMs': atMs,
      };
}

class GeoPresence {
  GeoPresence._();

  static const int kind = 20001;
  static const int futureSkewSec = 600;
  static const int sinceWindowSec = 120;
  static const int maxSendPrecision = 5;
  static const List<int> firstDelayMs = [2000, 5000];
  static const List<int> loopDelayMs = [40000, 80000];
  static const List<int> tailDelayMs = [5000, 120000];
  static const int channelCap = 500;
  static const int namedBusyThreshold = 50;
  static const int namedMaxLoopMs = 240000;
  static const int anonSpacingMs = 5000;
  static const List<String> winningStatuses = ['away', 'hidden', 'offline'];
  static const List<String> listingStatuses = ['online', 'active'];

  static final RegExp _geohashRe = RegExp(r'^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$');
  static final RegExp _hex64Re = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _nameRe = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);
  static final RegExp _upperOrTitleRe =
      RegExp(r'[\p{Lu}\p{Lt}]', unicode: true);
  static final RegExp _asciiUpperRe = RegExp('[A-Z]');

  static String _asciiLower(String v) =>
      v.replaceAllMapped(_asciiUpperRe, (m) => m.group(0)!.toLowerCase());

  static Map<String, dynamic> config() => {
        'kind': kind,
        'futureSkewSec': futureSkewSec,
        'sinceWindowSec': sinceWindowSec,
        'maxSendPrecision': maxSendPrecision,
        'firstDelayMs': firstDelayMs,
        'loopDelayMs': loopDelayMs,
        'tailDelayMs': tailDelayMs,
        'channelCap': channelCap,
        'winningStatuses': winningStatuses,
        'namedBusyThreshold': namedBusyThreshold,
        'namedMaxLoopMs': namedMaxLoopMs,
        'anonSpacingMs': anonSpacingMs,
      };

  static bool isGeohash(String? g) => g != null && _geohashRe.hasMatch(g);

  static bool isChannelName(String? name) {
    if (name == null || name.isEmpty) return false;
    final lower = name.toLowerCase();
    return _nameRe.hasMatch(lower) && !isGeohash(lower);
  }

  static List? _firstTag(Object? tags, String name) {
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List && t.isNotEmpty && t[0] == name) return t;
    }
    return null;
  }

  static String _tagValue(List? t) =>
      t != null && t.length > 1 && t[1] is String
          ? (t[1] as String).toLowerCase()
          : '';

  static GeoPresenceVerdict _refuse(String reason) =>
      GeoPresenceVerdict(false, reason, 0);

  static GeoPresenceVerdict accept(
      Map<String, dynamic> ev, Map<String, dynamic> ctx) {
    if (ev['kind'] != kind) return _refuse('kind');
    final pubkey = ev['pubkey'];
    if (pubkey is! String || !_hex64Re.hasMatch(pubkey)) {
      return _refuse('pubkey');
    }
    if (ctx['verified'] != true) return _refuse('sig');
    final content = ev['content'];
    if (content is! String || content.trim().isNotEmpty) {
      return _refuse('content');
    }
    final g = _firstTag(ev['tags'], 'g');
    final d = _firstTag(ev['tags'], 'd');
    if ((g == null) == (d == null)) return _refuse('tags');
    final channelRaw = ctx['channel'];
    final channel = channelRaw is String ? channelRaw.toLowerCase() : '';
    if (ctx['type'] == 'named') {
      final dv = _tagValue(d);
      if (!isChannelName(dv) || dv != channel) return _refuse('name');
    } else {
      final gv = _tagValue(g);
      if (!isGeohash(gv) || gv != channel) return _refuse('geohash');
    }
    final at = ev['created_at'];
    if (at is! num || at != at.roundToDouble() || at <= 0) {
      return _refuse('time');
    }
    final nowMsRaw = ctx['nowMs'];
    final nowMs = nowMsRaw is num
        ? nowMsRaw.toInt()
        : DateTime.now().millisecondsSinceEpoch;
    final atSec = at.toInt();
    if (atSec > nowMs ~/ 1000 + futureSkewSec) return _refuse('future');
    final own = ctx['own'];
    if (own is List && own.contains(pubkey)) return _refuse('own');
    final excluded = ctx['excluded'];
    if (excluded is List && excluded.contains(pubkey)) {
      return _refuse('excluded');
    }
    return GeoPresenceVerdict(true, 'ok', math.min(atSec * 1000, nowMs));
  }

  static GeoPresenceActivity activity({
    required int geoAtMs,
    required int nowMs,
    int prevSeenMs = 0,
    String? status,
    int statusAtMs = 0,
  }) {
    final now = nowMs > 0 ? nowMs : 0;
    final prev = math.min(prevSeenMs > 0 ? prevSeenMs : 0, now);
    final at = math.min(geoAtMs > 0 ? geoAtMs : 0, now);
    final hidden = status == 'hidden';
    int shown(int seen) => hidden ? 0 : seen;
    if (at <= 0) return GeoPresenceActivity(false, prev, shown(prev));
    if (winningStatuses.contains(status) && statusAtMs >= at) {
      return GeoPresenceActivity(false, prev, shown(prev));
    }
    final seen = math.max(prev, at);
    return GeoPresenceActivity(true, seen, shown(seen));
  }

  static bool listsFromPresence(bool known, String? status) =>
      known || listingStatuses.contains(status);

  static GeoPresenceSendPlan sendPlan(GeoPresenceSendInput o) {
    GeoPresenceSendPlan no(String reason) =>
        GeoPresenceSendPlan(false, reason, null);
    if (o.type == 'named') {
      if (!isChannelName(o.name)) return no('not-named');
    } else if (o.type == 'geohash') {
      final g = o.geohash;
      if (!isGeohash(g)) return no('not-geohash');
      if (g!.length > maxSendPrecision) return no('precision');
    } else {
      return no('not-channel');
    }
    if (!o.onScreen) return no('not-on-screen');
    if (o.locked) return no('locked');
    if (o.rotatingKey) return no('rotating-key');
    if (!o.foreground || !o.focused || o.idle) return no('inactive');
    if (!o.presence || o.status != 'online') return no('status');
    if (!o.showInCounts) return no('counts-off');
    if (!o.connected || o.meshOnly) return no('offline');
    return GeoPresenceSendPlan(
        true, 'ok', o.key == 'anonymous' ? 'anonymous' : 'identity');
  }

  static int spacedAtMs(int atMs, List<Object?> others) {
    var t = atMs > 0 ? atMs : 0;
    final list = others
        .whereType<num>()
        .where((x) => x.isFinite && x > 0)
        .map((x) => x.toInt())
        .toList()
      ..sort();
    for (final o in list) {
      if ((t - o).abs() < anonSpacingMs) t = o + anonSpacingMs;
    }
    return t;
  }

  static GeoPresenceAnonTick anonTick(GeoPresenceAnonInput o) {
    GeoPresenceAnonTick act(String action, String reason, [int atMs = 0]) =>
        GeoPresenceAnonTick(action, reason, atMs);
    if (o.pubkey.isEmpty || o.pubkey != o.newest) {
      return act('stop', 'superseded');
    }
    if (!o.signedIn) return act('stop', 'signed-out');
    final g = o.gate;
    if (!g.foreground) return act('stop', 'background');
    if (!g.presence) return act('stop', 'presence-off');
    if (!g.showInCounts) return act('stop', 'counts-off');
    final now = o.nowMs > 0 ? o.nowMs : 0;
    final stopAt = o.stopAtMs > 0 ? o.stopAtMs : 0;
    if (stopAt > 0 && now >= stopAt) return act('stop', 'left');
    final gate = stopAt > 0
        ? g.withOverrides(
            onScreen: true, focused: true, idle: false, key: 'anonymous')
        : g.withOverrides(key: 'anonymous');
    final plan = sendPlan(gate);
    if (!plan.send) return act('skip', plan.reason);
    final at = spacedAtMs(now, o.identityMs);
    if (at > now) return act('defer', 'spacing', at);
    return act('send', 'ok');
  }

  static Map<String, dynamic> publishRoute(String key) => key == 'anonymous'
      ? {'lane': 'anonymous', 'userRelays': false}
      : {'lane': 'identity', 'userRelays': true};

  static int delayMs(String phase, double r) {
    final span = phase == 'loop'
        ? loopDelayMs
        : phase == 'tail'
            ? tailDelayMs
            : firstDelayMs;
    var x = r >= 0 ? r : 0.0;
    if (x >= 1) x = 0.999999;
    return (span[0] + x * (span[1] - span[0])).floor();
  }

  static int loopMs(String type, num? online, double r) {
    final base = delayMs('loop', r);
    final n = online != null && online.isFinite ? online : 0;
    if (type != 'named' || n <= namedBusyThreshold) return base;
    return math.min(namedMaxLoopMs, base * (n / namedBusyThreshold).ceil());
  }

  static Map<String, dynamic>? template(String geohash, int createdAt) {
    if (!isGeohash(geohash) || geohash.length > maxSendPrecision) return null;
    return {
      'kind': kind,
      'created_at': createdAt,
      'content': '',
      'tags': [
        ['g', geohash]
      ],
    };
  }

  static Map<String, dynamic>? filter(String geohash, int nowSec) {
    if (!isGeohash(geohash)) return null;
    return {
      'kinds': [kind],
      'since': nowSec - sinceWindowSec,
      '#g': [geohash],
    };
  }

  static Map<String, dynamic>? namedTemplate(String name, int createdAt) {
    if (!isChannelName(name)) return null;
    return {
      'kind': kind,
      'created_at': createdAt,
      'content': '',
      'tags': [
        ['d', name.toLowerCase()]
      ],
    };
  }

  static Map<String, dynamic>? namedFilter(String name, int nowSec) {
    if (!isChannelName(name)) return null;
    return {
      'kinds': [kind],
      'since': nowSec - sinceWindowSec,
      '#d': [name.toLowerCase()],
    };
  }

  static bool admits(int count, bool known) => known || count < channelCap;

  static const int wideFutureSkewSec = 120;
  static const int wideMaxAgeSec = 300;
  static const int wideDecayMs = 300000;
  static const int wideMaxNameLength = 64;
  static const int wideRatePerMin = 6;
  static const int wideMaxChannels = 1000;
  static const int wideMaxEntries = 20000;
  static const int wideDedupeMax = 4096;
  static const int wideRateKeysMax = 20000;
  static const int wideSweepMs = 60000;
  static const int wideUiFlushMs = 2000;

  static Map<String, dynamic> wideConfig() => {
        'sinceWindowSec': sinceWindowSec,
        'futureSkewSec': wideFutureSkewSec,
        'maxAgeSec': wideMaxAgeSec,
        'decayMs': wideDecayMs,
        'maxPrecision': maxSendPrecision,
        'maxNameLength': wideMaxNameLength,
        'ratePerMin': wideRatePerMin,
        'channelCap': channelCap,
        'maxChannels': wideMaxChannels,
        'maxEntries': wideMaxEntries,
        'dedupeMax': wideDedupeMax,
        'rateKeysMax': wideRateKeysMax,
        'sweepMs': wideSweepMs,
        'uiFlushMs': wideUiFlushMs,
      };

  static Map<String, dynamic> wideFilter(int nowSec) => {
        'kinds': [kind],
        'since': nowSec - sinceWindowSec,
      };

  static GeoPresenceShape _shapeRefuse(String reason) =>
      GeoPresenceShape(false, reason, null, null, 0);

  static GeoPresenceShape shape(
      Map<String, dynamic> ev, Map<String, dynamic> ctx) {
    if (ev['kind'] != kind) return _shapeRefuse('kind');
    final pubkey = ev['pubkey'];
    if (pubkey is! String || !_hex64Re.hasMatch(pubkey)) {
      return _shapeRefuse('pubkey');
    }
    final id = ev['id'];
    if (id is! String || !_hex64Re.hasMatch(id)) return _shapeRefuse('id');
    if (ctx['verified'] != true) return _shapeRefuse('sig');
    if (ev['content'] != '') return _shapeRefuse('content');
    final tags = ev['tags'];
    if (tags is! List || tags.length != 1) return _shapeRefuse('tags');
    final t = tags[0];
    if (t is! List ||
        t.length != 2 ||
        (t[0] != 'g' && t[0] != 'd') ||
        t[1] is! String) {
      return _shapeRefuse('tags');
    }
    final value = _asciiLower(t[1] as String);
    final cased = _upperOrTitleRe.hasMatch(value);
    final String type;
    if (t[0] == 'g') {
      if (cased || !isGeohash(value)) return _shapeRefuse('geohash');
      if (value.length > maxSendPrecision) return _shapeRefuse('precision');
      type = 'geohash';
    } else {
      if (cased || !isChannelName(value) || value.length > wideMaxNameLength) {
        return _shapeRefuse('name');
      }
      type = 'named';
    }
    final at = ev['created_at'];
    if (at is! num || at != at.roundToDouble() || at <= 0) {
      return _shapeRefuse('time');
    }
    final nowMsRaw = ctx['nowMs'];
    final nowMs = nowMsRaw is num
        ? nowMsRaw.toInt()
        : DateTime.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    final atSec = at.toInt();
    if (atSec > nowSec + wideFutureSkewSec) return _shapeRefuse('future');
    if (atSec < nowSec - wideMaxAgeSec) return _shapeRefuse('stale');
    final own = ctx['own'];
    if (own is List && own.contains(pubkey)) return _shapeRefuse('own');
    final excluded = ctx['excluded'];
    if (excluded is List && excluded.contains(pubkey)) {
      return _shapeRefuse('excluded');
    }
    return GeoPresenceShape(
        true, 'ok', type, value, math.min(atSec * 1000, nowMs));
  }
}

class GeoPresenceTracker {
  final Set<String> _seen = <String>{};
  final Map<String, List<int>> _rate = <String, List<int>>{};
  final Map<String, Map<String, int>> _chans = <String, Map<String, int>>{};
  int _entries = 0;
  int _lastSweep = 0;

  void _dropOld(Map<String, int> members, int nowMs) {
    members.removeWhere((pk, at) {
      final old = nowMs - at >= GeoPresence.wideDecayMs;
      if (old) _entries--;
      return old;
    });
  }

  void sweep(int nowMs) {
    _chans.removeWhere((ch, m) {
      _dropOld(m, nowMs);
      return m.isEmpty;
    });
    _rate.removeWhere((pk, list) => list.isEmpty || nowMs - list.last >= 60000);
    _lastSweep = nowMs;
  }

  GeoPresenceShape ingest(Map<String, dynamic> ev, Map<String, dynamic> ctx) {
    final v = GeoPresence.shape(ev, ctx);
    if (!v.ok) return v;
    final nowRaw = ctx['nowMs'];
    final nowMs =
        nowRaw is num ? nowRaw.toInt() : DateTime.now().millisecondsSinceEpoch;
    final id = ev['id'] as String;
    if (_seen.contains(id)) return GeoPresence._shapeRefuse('dup');
    _seen.add(id);
    if (_seen.length > GeoPresence.wideDedupeMax) _seen.remove(_seen.first);
    if (nowMs - _lastSweep >= GeoPresence.wideSweepMs) sweep(nowMs);
    final pk = ev['pubkey'] as String;
    final list = (_rate.remove(pk) ?? <int>[])
        .where((x) => nowMs - x < 60000)
        .toList();
    if (list.length >= GeoPresence.wideRatePerMin) {
      _rate[pk] = list;
      return GeoPresence._shapeRefuse('rate');
    }
    list.add(nowMs);
    _rate[pk] = list;
    if (_rate.length > GeoPresence.wideRateKeysMax) {
      _rate.remove(_rate.keys.first);
    }
    final ch = v.channel!;
    var members = _chans.remove(ch);
    if (members != null) {
      _dropOld(members, nowMs);
    } else {
      members = <String, int>{};
    }
    _chans[ch] = members;
    final prev = members[pk];
    if (prev == null && members.length >= GeoPresence.channelCap) {
      return GeoPresence._shapeRefuse('cap');
    }
    if (prev == null) _entries++;
    members[pk] = math.max(prev ?? 0, v.atMs);
    while (_chans.length > GeoPresence.wideMaxChannels ||
        _entries > GeoPresence.wideMaxEntries) {
      final first = _chans.keys.first;
      if (first == ch) break;
      _entries -= _chans.remove(first)!.length;
    }
    return v;
  }

  List<String> active(String channel, int nowMs,
      [List<String> excluded = const []]) {
    final m = _chans[channel.toLowerCase()];
    if (m == null) return const [];
    return [
      for (final e in m.entries)
        if (nowMs - e.value < GeoPresence.wideDecayMs &&
            !excluded.contains(e.key))
          e.key
    ]..sort();
  }

  int count(String channel, int nowMs, [List<String> excluded = const []]) =>
      active(channel, nowMs, excluded).length;

  Map<String, int> stats() => {
        'channels': _chans.length,
        'entries': _entries,
        'seen': _seen.length,
        'rateKeys': _rate.length,
      };
}
