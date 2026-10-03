import 'dart:convert';
import 'dart:math' as math;

class GroupToolsLimits {
  GroupToolsLimits._();
  static const int titleMax = 80;
  static const int placeMax = 80;
  static const int noteMax = 280;
  static const int joinRequestsMax = 50;
  static const int joinRequestTtlSec = 604800;
  static const int adminNymsMax = 5;
  static const int adminNymMax = 48;
  static const int summaryDescMax = 150;
  static const int summaryUrlMax = 500;
  static const int summaryContentMax = 2000;
  static const int linkNameMax = 40;
  static const int callLinksMax = 50;
  static const int liveUpdateSec = 60;

  static Map<String, int> toJson() => {
    'titleMax': titleMax,
    'placeMax': placeMax,
    'noteMax': noteMax,
    'joinRequestsMax': joinRequestsMax,
    'joinRequestTtlSec': joinRequestTtlSec,
    'adminNymsMax': adminNymsMax,
    'adminNymMax': adminNymMax,
    'summaryDescMax': summaryDescMax,
    'summaryUrlMax': summaryUrlMax,
    'summaryContentMax': summaryContentMax,
    'linkNameMax': linkNameMax,
    'callLinksMax': callLinksMax,
    'liveUpdateSec': liveUpdateSec,
  };
}

class GroupToolsTypes {
  GroupToolsTypes._();
  static const String rsvp = 'group-rsvp';
  static const String joinPending = 'group-join-pending';
  static const String joinWaiting = 'group-join-waiting';
  static const String joinDeclined = 'group-join-declined';
  static const String joinResolved = 'group-join-resolved';

  static const Set<String> all = {
    rsvp,
    joinPending,
    joinWaiting,
    joinDeclined,
    joinResolved,
  };

  static Map<String, String> toJson() => {
    'rsvp': rsvp,
    'joinPending': joinPending,
    'joinWaiting': joinWaiting,
    'joinDeclined': joinDeclined,
    'joinResolved': joinResolved,
  };
}

class GroupToolsCallSignals {
  GroupToolsCallSignals._();
  static const String join = 'link-join';
  static const String refused = 'link-refused';
  static const String memberAdd = 'member-add';

  static Map<String, String> toJson() => {
    'join': join,
    'refused': refused,
    'memberAdd': memberAdd,
  };
}

class GroupToolsStrings {
  GroupToolsStrings._();
  static const String broadcastDenied =
      'Only the group owner, admins and moderators can use @here and @everyone.';
  static const String slowmodeWait =
      'Slowmode is on. You can send again in {time}.';
  static const String groupsNeedNet =
      "Encrypted groups don't travel over the Bluetooth mesh. Connect to the internet to use this.";
  static const String callNeedsNet =
      "Call links need an internet connection. Calls don't run over the Bluetooth mesh.";
  static const String noPublicLocation =
      "Location can't be shared in public channels.";
  static const String locationNeedsNet =
      "You're offline. Location needs the internet or this person in Bluetooth range.";
  static const String refusedRevoked = 'This call link was revoked.';
  static const String refusedExpired = 'This call link has expired.';
  static const String refusedInvalid = "This call link isn't valid.";
  static const String refusedDeclined =
      'The host declined your request to join.';
  static const String refusedBusy =
      'The host is busy right now. Try again later.';
  static const String off = 'Off';
  static const String never = 'Never';
  static const String atStart = 'At start';
  static const String min10 = '10 minutes before';
  static const String hour1 = '1 hour before';
  static const String day1 = '1 day before';
  static const String live15 = '15 minutes';
  static const String live60 = '1 hour';
  static const String live480 = '8 hours';
  static const String exp1h = '1 hour';
  static const String exp24h = '24 hours';
  static const String exp7d = '7 days';

  static Map<String, String> toJson() => {
    'broadcastDenied': broadcastDenied,
    'slowmodeWait': slowmodeWait,
    'groupsNeedNet': groupsNeedNet,
    'callNeedsNet': callNeedsNet,
    'noPublicLocation': noPublicLocation,
    'locationNeedsNet': locationNeedsNet,
    'refusedRevoked': refusedRevoked,
    'refusedExpired': refusedExpired,
    'refusedInvalid': refusedInvalid,
    'refusedDeclined': refusedDeclined,
    'refusedBusy': refusedBusy,
    'off': off,
    'never': never,
    'atStart': atStart,
    'min10': min10,
    'hour1': hour1,
    'day1': day1,
    'live15': live15,
    'live60': live60,
    'live480': live480,
    'exp1h': exp1h,
    'exp24h': exp24h,
    'exp7d': exp7d,
  };
}

class SendCheck {
  const SendCheck(this.ok, this.mention, this.reason);
  final bool ok;
  final String? mention;
  final String? reason;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'mention': mention,
    'reason': reason,
  };
}

class SlowmodeMessage {
  const SlowmodeMessage(this.id, this.ts);
  final String id;
  final int ts;
}

class JoinRequest {
  const JoinRequest({required this.pubkey, required this.ts, this.via = ''});
  final String pubkey;
  final int ts;
  final String via;

  Map<String, dynamic> toJson() => {'pubkey': pubkey, 'ts': ts, 'via': via};

  static JoinRequest? fromJson(Object? j) {
    if (j is! Map) return null;
    final pk = j['pubkey'];
    final ts = j['ts'];
    if (pk is! String || ts is! num) return null;
    final via = j['via'];
    return JoinRequest(
      pubkey: pk,
      ts: ts.floor(),
      via: via is String ? via : '',
    );
  }
}

class InviteSummaryFields {
  const InviteSummaryFields({
    required this.d,
    required this.av,
    required this.bn,
    required this.mc,
    required this.ad,
    required this.ap,
  });
  final String d;
  final String av;
  final String bn;
  final int mc;
  final List<String> ad;
  final int ap;

  Map<String, dynamic> toJson() => {
    'd': d,
    'av': av,
    'bn': bn,
    'mc': mc,
    'ad': ad,
    'ap': ap,
  };
}

class InviteSignedSummary {
  const InviteSignedSummary({
    required this.t,
    required this.c,
    required this.sig,
  });
  final int t;
  final String c;
  final String sig;

  Map<String, dynamic> toJson() => {'t': t, 'c': c, 'sig': sig};
}

class InvitePayload {
  const InvitePayload({
    required this.g,
    required this.n,
    required this.a,
    required this.e,
    this.s,
  });
  final String g;
  final String n;
  final String a;
  final int e;
  final InviteSignedSummary? s;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'g': g,
    'n': n,
    'a': a,
    'e': e,
    if (s != null) 's': s!.toJson(),
  };
}

class InvitePreview {
  const InvitePreview({
    required this.name,
    required this.description,
    required this.avatar,
    required this.banner,
    required this.memberCount,
    required this.admins,
    required this.approval,
    required this.verified,
  });
  final String name;
  final String description;
  final String avatar;
  final String banner;
  final int? memberCount;
  final List<String> admins;
  final bool approval;
  final bool verified;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'avatar': avatar,
    'banner': banner,
    'memberCount': memberCount,
    'admins': admins,
    'approval': approval,
    'verified': verified,
  };
}

class GroupEventInfo {
  const GroupEventInfo({
    required this.id,
    required this.title,
    required this.start,
    required this.offset,
    this.place = '',
    this.note = '',
  });
  final String id;
  final String title;
  final int start;
  final int offset;
  final String place;
  final String note;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'start': start,
    'offset': offset,
    'place': place,
    'note': note,
  };
}

class RsvpEntry {
  const RsvpEntry(this.s, this.ts);
  final String s;
  final int ts;

  Map<String, dynamic> toJson() => {'s': s, 'ts': ts};

  static RsvpEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['s'];
    final ts = j['ts'];
    if (s is! String || ts is! num) return null;
    return RsvpEntry(s, ts.floor());
  }
}

class RsvpApplied {
  const RsvpApplied(this.entries, this.changed);
  final Map<String, RsvpEntry> entries;
  final bool changed;
}

class RsvpTally {
  const RsvpTally(this.going, this.maybe, this.no);
  final List<String> going;
  final List<String> maybe;
  final List<String> no;

  Map<String, dynamic> toJson() => {'going': going, 'maybe': maybe, 'no': no};
}

class CallLink {
  const CallLink({
    required this.id,
    required this.host,
    required this.kind,
    required this.exp,
    required this.secret,
    required this.name,
    this.groupId,
    this.revoked = false,
    this.createdAt = 0,
  });
  final String id;
  final String host;
  final String kind;
  final int exp;
  final String secret;
  final String name;
  final String? groupId;
  final bool revoked;
  final int createdAt;

  CallLink copyWith({bool? revoked}) => CallLink(
    id: id,
    host: host,
    kind: kind,
    exp: exp,
    secret: secret,
    name: name,
    groupId: groupId,
    revoked: revoked ?? this.revoked,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'host': host,
    'kind': kind,
    'exp': exp,
    'secret': secret,
    'name': name,
    if (groupId != null) 'groupId': groupId,
    if (revoked) 'revoked': true,
    if (createdAt > 0) 'createdAt': createdAt,
  };

  static CallLink? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final host = j['host'];
    final kind = j['kind'];
    final secret = j['secret'];
    if (id is! String || host is! String || kind is! String) return null;
    if (secret is! String) return null;
    final exp = j['exp'];
    final created = j['createdAt'];
    return CallLink(
      id: id,
      host: host,
      kind: kind == 'video' ? 'video' : 'audio',
      exp: exp is num ? exp.floor() : 0,
      secret: secret,
      name: (j['name'] ?? '').toString(),
      groupId: j['groupId'] is String ? j['groupId'] as String : null,
      revoked: j['revoked'] == true,
      createdAt: created is num ? created.floor() : 0,
    );
  }
}

class CallLinkCheck {
  const CallLinkCheck(this.ok, this.reason);
  final bool ok;
  final String? reason;

  Map<String, dynamic> toJson() => {'ok': ok, 'reason': reason};
}

class SharedLocation {
  const SharedLocation({
    required this.lat,
    required this.lon,
    required this.acc,
    required this.kind,
    this.id = '',
    this.until = 0,
    this.seq = 0,
  });
  final double lat;
  final double lon;
  final int acc;
  final String kind;
  final String id;
  final int until;
  final int seq;

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    'acc': acc,
    'kind': kind,
    'id': id,
    'until': until,
    'seq': seq,
  };
}

class MapFrame {
  const MapFrame(
    this.minLon,
    this.maxLon,
    this.minLat,
    this.maxLat,
    this.x,
    this.y,
  );
  final double minLon;
  final double maxLon;
  final double minLat;
  final double maxLat;
  final double x;
  final double y;

  Map<String, dynamic> toJson() => {
    'minLon': minLon,
    'maxLon': maxLon,
    'minLat': minLat,
    'maxLat': maxLat,
    'x': x,
    'y': y,
  };
}

class FeatureAvailability {
  const FeatureAvailability(this.ok, this.reason, this.mesh);
  final bool ok;
  final String? reason;
  final bool mesh;

  Map<String, dynamic> toJson() => {'ok': ok, 'reason': reason, 'mesh': mesh};
}

class GroupTools {
  GroupTools._();

  static const List<int> slowmodeSeconds = [0, 10, 30, 60, 300, 900, 3600];
  static const int slowmodeGraceSec = 2;
  static const List<int> liveDurationsSec = [900, 3600, 28800];
  static const List<int> reminderOffsetsMin = [0, 10, 60, 1440];
  static const List<int> callLinkExpirySec = [3600, 86400, 604800, 0];
  static const List<String> rsvpStatuses = ['going', 'maybe', 'no'];
  static const int summaryKind = 27312;

  static final RegExp _hex16 = RegExp(r'^[0-9a-f]{16}$');
  static final RegExp _hex8 = RegExp(r'^[0-9a-f]{8}$');
  static final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _hex128 = RegExp(r'^[0-9a-f]{128}$');
  static final RegExp _groupId = RegExp(
    r'^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$',
    caseSensitive: false,
  );

  static int roleRank(String role) {
    switch (role) {
      case 'owner':
        return 0;
      case 'admin':
        return 1;
      case 'mod':
        return 2;
      default:
        return 3;
    }
  }

  static String _stripQuotesAndCode(String content) {
    final lines = content
        .split('\n')
        .where((l) => !l.replaceFirst(RegExp(r'^\s+'), '').startsWith('>'))
        .join('\n');
    return lines
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'`[^`\n]*`'), ' ');
  }

  static final RegExp _broadcastRx = RegExp(
    r'(^|[^A-Za-z0-9_@#\/.-])@(everyone|here)(?![A-Za-z0-9_#@-])',
    caseSensitive: false,
  );

  static String? broadcastMention(String? content) {
    if (content == null || !content.contains('@')) return null;
    final m = _broadcastRx.firstMatch(_stripQuotesAndCode(content));
    return m?.group(2)!.toLowerCase();
  }

  static bool mayBroadcast(String role) => roleRank(role) <= 2;

  static SendCheck sendCheck(String surface, String role, String content) {
    if (surface != 'group') return const SendCheck(true, null, null);
    final mention = broadcastMention(content);
    if (mention != null && !mayBroadcast(role)) {
      return SendCheck(false, mention, GroupToolsStrings.broadcastDenied);
    }
    return SendCheck(true, mention, null);
  }

  static bool notifiesAll(String surface, String senderRole, String content) =>
      surface == 'group' &&
      mayBroadcast(senderRole) &&
      broadcastMention(content) != null;

  static List<String> broadcastSuggestions(
    String surface,
    String role,
    String query,
  ) {
    if (surface != 'group' || !mayBroadcast(role)) return const [];
    final q = query.toLowerCase();
    return ['here', 'everyone'].where((w) => w.startsWith(q)).toList();
  }

  static int _leadingInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.isFinite ? v.truncate() : 0;
    if (v is String) {
      final m = RegExp(r'^\s*([+-]?\d+)').firstMatch(v);
      if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    }
    return 0;
  }

  static int normalizeSlowmode(Object? v) {
    final n = _leadingInt(v);
    return slowmodeSeconds.contains(n) ? n : 0;
  }

  static bool slowmodeExempt(String role) => roleRank(role) <= 2;

  static String slowmodeLabel(Object? sec) {
    final s = normalizeSlowmode(sec);
    if (s == 0) return GroupToolsStrings.off;
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m';
    return '${s ~/ 3600}h';
  }

  static String _pad2(int n) => n < 10 ? '0$n' : '$n';

  static String formatWait(num sec) {
    final s = math.max(0, sec.ceil());
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}:${_pad2(s % 60)}';
    return '${s ~/ 3600}:${_pad2((s % 3600) ~/ 60)}:${_pad2(s % 60)}';
  }

  static int slowmodeWait(Object? interval, int lastSentSec, int nowSec) {
    final i = normalizeSlowmode(interval);
    if (i == 0 || lastSentSec <= 0) return 0;
    return math.max(0, lastSentSec + i - nowSec);
  }

  static List<SlowmodeMessage> _sortedForSlowmode(
    Iterable<SlowmodeMessage> messages,
  ) {
    final list = messages.toList()
      ..sort((a, b) {
        final c = a.ts.compareTo(b.ts);
        if (c != 0) return c;
        return a.id.compareTo(b.id);
      });
    return list;
  }

  static (List<String>, int) _slowmodeScan(
    Iterable<SlowmodeMessage> messages,
    Object? interval,
    int sinceSec,
  ) {
    final i = normalizeSlowmode(interval);
    final held = <String>[];
    int? last;
    if (i == 0) return (held, 0);
    for (final m in _sortedForSlowmode(messages)) {
      if (m.ts < sinceSec) continue;
      if (last != null && m.ts < last + i - slowmodeGraceSec) {
        held.add(m.id);
      } else {
        last = m.ts;
      }
    }
    return (held, last ?? 0);
  }

  static List<String> slowmodeHeld(
    Iterable<SlowmodeMessage> messages,
    Object? interval,
    int sinceSec,
  ) => _slowmodeScan(messages, interval, sinceSec).$1;

  static int slowmodeLastAccepted(
    Iterable<SlowmodeMessage> messages,
    Object? interval,
    int sinceSec,
  ) => _slowmodeScan(messages, interval, sinceSec).$2;

  static String descriptionLine(String? desc) =>
      (desc ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool mayApproveJoins(String role) => roleRank(role) <= 1;

  static String joinRequestAction({
    required bool inviteEnabled,
    required int epoch,
    required bool approval,
    required List<String> members,
    required List<String> banned,
    required String requester,
    required int requestEpoch,
    required bool selfCanAdd,
  }) {
    if (!inviteEnabled) return 'ignore';
    if (requestEpoch != epoch) return 'ignore';
    if (members.contains(requester)) return 'ignore';
    if (banned.contains(requester)) return 'ignore';
    if (approval) return 'queue';
    return selfCanAdd ? 'admit' : 'ignore';
  }

  static List<JoinRequest> pruneJoinRequests(
    Iterable<JoinRequest> list,
    int nowSec,
  ) {
    final cutoff = nowSec - GroupToolsLimits.joinRequestTtlSec;
    return [
      for (final r in list)
        if (_hex64.hasMatch(r.pubkey) && r.ts > cutoff)
          JoinRequest(
            pubkey: r.pubkey,
            ts: r.ts,
            via: _hex64.hasMatch(r.via) ? r.via : '',
          ),
    ];
  }

  static List<JoinRequest> addJoinRequest(
    Iterable<JoinRequest> list,
    JoinRequest req,
    int nowSec,
  ) {
    var out = pruneJoinRequests(list, nowSec);
    final pruned = pruneJoinRequests([req], nowSec);
    if (pruned.isEmpty) return out;
    final r = pruned.first;
    for (final x in out) {
      if (x.pubkey == r.pubkey && x.ts >= r.ts) return out;
    }
    out = out.where((x) => x.pubkey != r.pubkey).toList()..add(r);
    out.sort((a, b) {
      final c = a.ts.compareTo(b.ts);
      if (c != 0) return c;
      return a.pubkey.compareTo(b.pubkey) < 0 ? -1 : 1;
    });
    while (out.length > GroupToolsLimits.joinRequestsMax) {
      out.removeAt(0);
    }
    return out;
  }

  static List<JoinRequest> removeJoinRequest(
    Iterable<JoinRequest> list,
    String pubkey,
  ) => list.where((r) => r.pubkey != pubkey).toList();

  static String b64uEncode(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');

  static String b64uDecode(String token) {
    if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(token) || token.length % 4 == 1) {
      throw const FormatException('b64');
    }
    var t = token;
    while (t.length % 4 != 0) {
      t += '=';
    }
    return utf8.decode(base64Url.decode(t));
  }

  static String _sanitizeLine(Object? s, int max) {
    final v = (s is String ? s : (s == null ? '' : '$s'))
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return v.length > max ? v.substring(0, max) : v;
  }

  static String sanitizeName(
    Object? name, [
    int max = GroupToolsLimits.linkNameMax,
  ]) => _sanitizeLine(name, max);

  static String _httpsUrl(Object? u) {
    final s = u is String ? u : '';
    return (RegExp(r'''^https://[^\s"'<>]+$''').hasMatch(s) &&
            s.length <= GroupToolsLimits.summaryUrlMax)
        ? s
        : '';
  }

  static InviteSummaryFields summaryFields({
    Object? description,
    Object? avatar,
    Object? banner,
    Object? memberCount,
    Object? adminNyms,
    bool approval = false,
  }) {
    final ad = <String>[];
    if (adminNyms is List) {
      for (final n in adminNyms) {
        final v = _sanitizeLine(n, GroupToolsLimits.adminNymMax);
        if (v.isNotEmpty) ad.add(v);
        if (ad.length >= GroupToolsLimits.adminNymsMax) break;
      }
    }
    var mc = 0;
    if (memberCount is num && memberCount.isFinite) {
      mc = math.max(0, memberCount.floor());
    }
    return InviteSummaryFields(
      d: _sanitizeLine(description, GroupToolsLimits.summaryDescMax),
      av: _httpsUrl(avatar),
      bn: _httpsUrl(banner),
      mc: mc,
      ad: ad,
      ap: approval ? 1 : 0,
    );
  }

  static String summaryContent({
    Object? description,
    Object? avatar,
    Object? banner,
    Object? memberCount,
    Object? adminNyms,
    bool approval = false,
  }) => jsonEncode(
    summaryFields(
      description: description,
      avatar: avatar,
      banner: banner,
      memberCount: memberCount,
      adminNyms: adminNyms,
      approval: approval,
    ).toJson(),
  );

  static Map<String, dynamic> summaryTemplate(
    String groupId,
    String inviter,
    int createdAt,
    String content,
  ) => {
    'kind': summaryKind,
    'pubkey': inviter,
    'created_at': createdAt,
    'tags': [
      ['g', groupId],
    ],
    'content': content,
  };

  static InviteSummaryFields? parseSummaryContent(String? content) {
    if (content == null ||
        content.length > GroupToolsLimits.summaryContentMax) {
      return null;
    }
    Object? o;
    try {
      o = jsonDecode(content);
    } catch (_) {
      return null;
    }
    if (o is! Map) return null;
    return summaryFields(
      description: o['d'],
      avatar: o['av'],
      banner: o['bn'],
      memberCount: o['mc'],
      adminNyms: o['ad'],
      approval: o['ap'] == 1,
    );
  }

  static String encodeInvite(InvitePayload p) {
    final name = p.n.isEmpty ? 'Group' : p.n;
    final payload = InvitePayload(
      g: p.g,
      n: name.length > 80 ? name.substring(0, 80) : name,
      a: p.a,
      e: p.e,
      s: p.s,
    );
    return b64uEncode(jsonEncode(payload.toJson()));
  }

  static InvitePayload? parseInviteInput(String? str) {
    if (str == null || str.isEmpty) return null;
    var token = str.trim();
    final m = RegExp(r'[#&?]gjoin=([A-Za-z0-9_-]+)').firstMatch(token);
    if (m != null) {
      token = m.group(1)!;
    } else if (token.startsWith('gjoin=')) {
      token = token.substring(6);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) return null;
    Object? obj;
    try {
      obj = jsonDecode(b64uDecode(token));
    } catch (_) {
      return null;
    }
    if (obj is! Map || obj['v'] != 1) return null;
    final g = '${obj['g'] ?? ''}';
    if (!_groupId.hasMatch(g)) return null;
    final a = '${obj['a'] ?? ''}';
    if (!RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(a)) {
      return null;
    }
    InviteSignedSummary? sum;
    final s = obj['s'];
    if (s is Map) {
      final t = s['t'];
      final c = s['c'];
      final sig = s['sig'];
      if (t is int &&
          t > 0 &&
          c is String &&
          c.length <= GroupToolsLimits.summaryContentMax &&
          sig is String &&
          _hex128.hasMatch(sig)) {
        sum = InviteSignedSummary(t: t, c: c, sig: sig);
      }
    }
    return InvitePayload(
      g: g,
      n: obj['n'] is String ? obj['n'] as String : '',
      a: a,
      e: _leadingInt(obj['e']),
      s: sum,
    );
  }

  static InvitePreview invitePreview(InvitePayload p, InviteSummaryFields? f) {
    final name = sanitizeName(p.n, 40);
    return InvitePreview(
      name: name.isEmpty ? 'Group' : name,
      description: f == null ? '' : descriptionLine(f.d),
      avatar: f?.av ?? '',
      banner: f?.bn ?? '',
      memberCount: f?.mc,
      admins: f == null ? const [] : List.of(f.ad),
      approval: f != null && f.ap == 1,
      verified: f != null,
    );
  }

  static String pctEncode(String s) {
    final sb = StringBuffer();
    for (final b in utf8.encode(s)) {
      final unreserved =
          (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          b == 0x5F ||
          b == 0x2E ||
          b == 0x7E ||
          b == 0x2D;
      if (unreserved) {
        sb.writeCharCode(b);
      } else {
        sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }

  static String pctDecode(String s) {
    if (!RegExp(r'^(?:[A-Za-z0-9_.~-]|%[0-9A-Fa-f]{2})*$').hasMatch(s)) {
      throw const FormatException('pct');
    }
    final bytes = <int>[];
    for (var i = 0; i < s.length;) {
      if (s[i] == '%') {
        bytes.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
        i += 3;
      } else {
        bytes.add(s.codeUnitAt(i));
        i++;
      }
    }
    return utf8.decode(bytes);
  }

  static String tzLabel(int offsetMin) {
    if (offsetMin == 0) return 'UTC';
    final a = offsetMin.abs();
    return 'UTC${offsetMin < 0 ? '-' : '+'}${_pad2(a ~/ 60)}:${_pad2(a % 60)}';
  }

  static int wallToUtc(int y, int mo, int d, int h, int mi, int offsetMin) =>
      DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000 -
      offsetMin * 60;

  static GroupEventInfo _cleanEvent({
    required Object? id,
    required Object? title,
    required int start,
    required int offset,
    Object? place,
    Object? note,
  }) => GroupEventInfo(
    id: id is String ? id : '',
    title: _sanitizeLine(title, GroupToolsLimits.titleMax),
    start: start,
    offset: offset,
    place: _sanitizeLine(place, GroupToolsLimits.placeMax),
    note: _sanitizeLine(note, GroupToolsLimits.noteMax),
  );

  static bool _validEvent(GroupEventInfo e) =>
      _hex16.hasMatch(e.id) &&
      e.title.isNotEmpty &&
      e.start > 0 &&
      e.start < 100000000000 &&
      e.offset >= -720 &&
      e.offset <= 840;

  static String? buildEventContent({
    required String id,
    required String title,
    required int start,
    required int offset,
    String place = '',
    String note = '',
  }) {
    final e = _cleanEvent(
      id: id,
      title: title,
      start: start,
      offset: offset,
      place: place,
      note: note,
    );
    if (!_validEvent(e)) return null;
    final lines = <String>[
      'Event: ${e.title}',
      'When: <t:${e.start}:F> (${tzLabel(e.offset)})',
      if (e.place.isNotEmpty) 'Where: ${e.place}',
      if (e.note.isNotEmpty) e.note,
    ];
    var machine =
        'nymevent:v=1;id=${e.id};s=${e.start};o=${e.offset};t=${pctEncode(e.title)}';
    if (e.place.isNotEmpty) machine += ';p=${pctEncode(e.place)}';
    if (e.note.isNotEmpty) machine += ';n=${pctEncode(e.note)}';
    lines.add(machine);
    return lines.join('\n');
  }

  static final RegExp _eventLine = RegExp(
    r'(?:^|\n)nymevent:([A-Za-z0-9_.~%=;-]+)[ \t]*$',
  );

  static GroupEventInfo? parseEvent(String? content) {
    if (content == null || !content.contains('nymevent:')) return null;
    final m = _eventLine.firstMatch(content);
    if (m == null) return null;
    final params = <String, String>{};
    for (final part in m.group(1)!.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) return null;
      params[part.substring(0, i)] = part.substring(i + 1);
    }
    if (params['v'] != '1') return null;
    final s = params['s'] ?? '';
    final o = params['o'] ?? '';
    if (!RegExp(r'^-?\d{1,12}$').hasMatch(s) ||
        !RegExp(r'^-?\d{1,4}$').hasMatch(o)) {
      return null;
    }
    String title;
    var place = '';
    var note = '';
    try {
      title = pctDecode(params['t'] ?? '');
      final p = params['p'];
      if (p != null && p.isNotEmpty) place = pctDecode(p);
      final n = params['n'];
      if (n != null && n.isNotEmpty) note = pctDecode(n);
    } catch (_) {
      return null;
    }
    final e = _cleanEvent(
      id: params['id'],
      title: title,
      start: int.parse(s),
      offset: int.parse(o),
      place: place,
      note: note,
    );
    return _validEvent(e) ? e : null;
  }

  static String eventFallbackText(String content) =>
      content.replaceFirst(RegExp(r'\n?nymevent:[^\n]*$'), '');

  static String previewText(String content) {
    final loc = parseLocation(content);
    if (loc != null) return loc.kind == 'pin' ? 'Location' : 'Live location';
    return eventFallbackText(content);
  }

  static String? normalizeRsvp(Object? s) =>
      (s is String && rsvpStatuses.contains(s)) ? s : null;

  static RsvpApplied applyRsvp(
    Map<String, RsvpEntry> entries,
    String pubkey,
    String status,
    int ts,
  ) {
    final out = Map<String, RsvpEntry>.of(entries);
    final st = normalizeRsvp(status);
    if (st == null || !_hex64.hasMatch(pubkey) || ts <= 0) {
      return RsvpApplied(out, false);
    }
    final cur = out[pubkey];
    if (cur != null &&
        (ts < cur.ts || (ts == cur.ts && st.compareTo(cur.s) <= 0))) {
      return RsvpApplied(out, false);
    }
    out[pubkey] = RsvpEntry(st, ts);
    return RsvpApplied(out, true);
  }

  static RsvpTally rsvpTally(
    Map<String, RsvpEntry> entries, [
    List<String>? allowed,
  ]) {
    final list =
        entries.entries
            .where((e) => allowed == null || allowed.contains(e.key))
            .where((e) => normalizeRsvp(e.value.s) != null)
            .toList()
          ..sort((a, b) {
            final c = a.value.ts.compareTo(b.value.ts);
            if (c != 0) return c;
            return a.key.compareTo(b.key) < 0 ? -1 : 1;
          });
    final going = <String>[];
    final maybe = <String>[];
    final no = <String>[];
    for (final e in list) {
      switch (e.value.s) {
        case 'going':
          going.add(e.key);
        case 'maybe':
          maybe.add(e.key);
        default:
          no.add(e.key);
      }
    }
    return RsvpTally(going, maybe, no);
  }

  static List<List<String>> rsvpTags(String eventId, String status) => [
    ['type', GroupToolsTypes.rsvp],
    ['e', eventId],
    ['rsvp', status],
  ];

  static String rsvpContent(String status, String title) =>
      'RSVP $status: ${_sanitizeLine(title, GroupToolsLimits.titleMax)}';

  static int reminderAt(int start, int offsetMin) => start - offsetMin * 60;

  static String reminderLabel(int offsetMin) {
    switch (offsetMin) {
      case 0:
        return GroupToolsStrings.atStart;
      case 10:
        return GroupToolsStrings.min10;
      case 60:
        return GroupToolsStrings.hour1;
      case 1440:
        return GroupToolsStrings.day1;
      default:
        return '';
    }
  }

  static String encodeCallLink(CallLink link) {
    final o = <String, dynamic>{
      'v': 1,
      'i': link.id,
      'h': link.host,
      'k': link.kind == 'video' ? 'video' : 'audio',
      'x': math.max(0, link.exp),
      's': link.secret,
      'n': sanitizeName(link.name),
    };
    if (link.groupId != null && link.groupId!.isNotEmpty) {
      o['g'] = link.groupId;
    }
    return b64uEncode(jsonEncode(o));
  }

  static CallLink? parseCallLinkInput(String? str) {
    if (str == null || str.isEmpty) return null;
    var token = str.trim();
    final m = RegExp(r'[#&?]call=([A-Za-z0-9_-]+)').firstMatch(token);
    if (m != null) {
      token = m.group(1)!;
    } else if (token.startsWith('call=')) {
      token = token.substring(5);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) return null;
    Object? o;
    try {
      o = jsonDecode(b64uDecode(token));
    } catch (_) {
      return null;
    }
    if (o is! Map || o['v'] != 1) return null;
    final i = '${o['i'] ?? ''}';
    final h = '${o['h'] ?? ''}';
    final s = '${o['s'] ?? ''}';
    if (!_hex16.hasMatch(i) || !_hex64.hasMatch(h) || !_hex32.hasMatch(s)) {
      return null;
    }
    final k = o['k'];
    if (k != 'audio' && k != 'video') return null;
    final x = o['x'];
    if (x is! int || x < 0) return null;
    final g = o['g'];
    if (g != null && !_groupId.hasMatch('$g')) return null;
    return CallLink(
      id: i,
      host: h,
      kind: k as String,
      exp: x,
      secret: s,
      name: sanitizeName(o['n']),
      groupId: (g == null || '$g'.isEmpty) ? null : '$g',
    );
  }

  static String callLinkState(CallLink? link, int nowSec) {
    if (link == null) return 'unknown';
    if (link.revoked) return 'revoked';
    if (link.exp > 0 && nowSec >= link.exp) return 'expired';
    return 'active';
  }

  static CallLinkCheck checkCallLinkJoin(
    Iterable<CallLink> links,
    String linkId,
    String secret,
    int nowSec,
  ) {
    CallLink? link;
    for (final l in links) {
      if (l.id == linkId) {
        link = l;
        break;
      }
    }
    if (link == null) return const CallLinkCheck(false, 'unknown');
    final st = callLinkState(link, nowSec);
    if (st != 'active') return CallLinkCheck(false, st);
    if (link.secret != secret) return const CallLinkCheck(false, 'secret');
    return const CallLinkCheck(true, null);
  }

  static String callLinkRefusal(String? reason) {
    switch (reason) {
      case 'revoked':
        return GroupToolsStrings.refusedRevoked;
      case 'expired':
        return GroupToolsStrings.refusedExpired;
      case 'declined':
        return GroupToolsStrings.refusedDeclined;
      case 'busy':
        return GroupToolsStrings.refusedBusy;
      default:
        return GroupToolsStrings.refusedInvalid;
    }
  }

  static String expiryLabel(int sec) {
    switch (sec) {
      case 3600:
        return GroupToolsStrings.exp1h;
      case 86400:
        return GroupToolsStrings.exp24h;
      case 604800:
        return GroupToolsStrings.exp7d;
      default:
        return GroupToolsStrings.never;
    }
  }

  static List<CallLink> addCallLink(Iterable<CallLink> list, CallLink link) {
    final out = [link, ...list.where((l) => l.id != link.id)];
    return out.length > GroupToolsLimits.callLinksMax
        ? out.sublist(0, GroupToolsLimits.callLinksMax)
        : out;
  }

  static List<CallLink> revokeCallLink(Iterable<CallLink> list, String id) => [
    for (final l in list) l.id == id ? l.copyWith(revoked: true) : l,
  ];

  static int coordDecimals(num acc) {
    if (acc <= 10) return 5;
    if (acc <= 100) return 4;
    if (acc <= 1000) return 3;
    if (acc <= 10000) return 2;
    return 1;
  }

  static double _wrapLon(num lon) {
    var x = lon.toDouble();
    while (x > 180) {
      x -= 360;
    }
    while (x < -180) {
      x += 360;
    }
    return x;
  }

  static String _fixed(double x, int d) {
    final s = x.toStringAsFixed(d);
    return RegExp(r'^-0\.?0*$').hasMatch(s) ? s.substring(1) : s;
  }

  static String? buildLocation({
    required num lat,
    required num lon,
    required num acc,
    String kind = 'pin',
    String id = '',
    int until = 0,
    int seq = 0,
  }) {
    final la = math.max(-90.0, math.min(90.0, lat.toDouble()));
    final lo = _wrapLon(lon);
    final a = math.max(1, acc.round());
    final d = coordDecimals(a);
    var out = 'geo:${_fixed(la, d)},${_fixed(lo, d)};u=$a';
    if (kind == 'live') {
      if (!_hex8.hasMatch(id)) return null;
      out += ';nymk=live;nymid=$id;nymuntil=$until;nymq=${math.max(0, seq)}';
    } else if (kind == 'end') {
      if (!_hex8.hasMatch(id)) return null;
      out += ';nymk=end;nymid=$id;nymq=${math.max(0, seq)}';
    } else {
      out += ';nymk=pin';
    }
    return out;
  }

  static final RegExp _geoRx = RegExp(
    r'^geo:(-?\d{1,2}(?:\.\d{1,7})?),(-?\d{1,3}(?:\.\d{1,7})?)((?:;[a-z]{1,10}=[A-Za-z0-9._-]{1,20}){0,6})$',
  );

  static SharedLocation? parseLocation(String? content) {
    if (content == null) return null;
    final m = _geoRx.firstMatch(content.trim());
    if (m == null) return null;
    final lat = double.parse(m.group(1)!);
    final lon = double.parse(m.group(2)!);
    if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)) return null;
    final p = <String, String>{};
    for (final part in m.group(3)!.split(';').where((s) => s.isNotEmpty)) {
      final i = part.indexOf('=');
      p[part.substring(0, i)] = part.substring(i + 1);
    }
    final u = p['u'] ?? '';
    final acc = RegExp(r'^\d{1,8}$').hasMatch(u) ? int.parse(u) : 0;
    final kind = p['nymk'] ?? 'pin';
    if (kind == 'pin') {
      return SharedLocation(lat: lat, lon: lon, acc: acc, kind: 'pin');
    }
    if (kind != 'live' && kind != 'end') return null;
    final id = p['nymid'] ?? '';
    final q = p['nymq'] ?? '';
    if (!_hex8.hasMatch(id) || !RegExp(r'^\d{1,9}$').hasMatch(q)) return null;
    final untilRaw = p['nymuntil'] ?? '';
    if (kind == 'live' && !RegExp(r'^\d{1,12}$').hasMatch(untilRaw)) {
      return null;
    }
    return SharedLocation(
      lat: lat,
      lon: lon,
      acc: acc,
      kind: kind,
      id: id,
      until: kind == 'live' ? int.parse(untilRaw) : 0,
      seq: int.parse(q),
    );
  }

  static String precisionText(num acc) {
    final a = math.max(1, acc.round());
    if (a < 1000) return '$a m';
    final km = (a / 100).round() / 10;
    return '${km % 1 == 0 ? km.toInt().toString() : km.toStringAsFixed(1)} km';
  }

  static const List<int> _geohashAcc = [
    2500000,
    630000,
    78000,
    20000,
    2400,
    610,
    76,
    19,
    3,
  ];

  static int geohashAccuracy(int len) =>
      _geohashAcc[math.max(1, math.min(_geohashAcc.length, len)) - 1];

  static String liveState(SharedLocation? loc, int nowSec) {
    if (loc == null) return 'none';
    if (loc.kind == 'pin') return 'pin';
    if (loc.kind == 'end') return 'ended';
    return nowSec >= loc.until ? 'expired' : 'live';
  }

  static bool liveSupersedes(SharedLocation? cur, SharedLocation? next) {
    if (cur == null || next == null) return false;
    if (cur.kind == 'pin' || next.kind == 'pin' || cur.id != next.id) {
      return false;
    }
    return next.seq > cur.seq;
  }

  static MapFrame mapFrame(double lat, double lon, num acc) {
    final double span = acc <= 1000
        ? 4
        : (acc <= 20000 ? 8 : (acc <= 200000 ? 16 : 40));
    var minLat = lat - span / 2;
    var maxLat = lat + span / 2;
    if (minLat < -90) {
      maxLat += -90 - minLat;
      minLat = -90;
    }
    if (maxLat > 90) {
      minLat -= maxLat - 90;
      maxLat = 90;
    }
    final minLon = lon - span;
    final maxLon = lon + span;
    return MapFrame(
      minLon,
      maxLon,
      minLat,
      maxLat,
      (lon - minLon) / (maxLon - minLon),
      (maxLat - lat) / (maxLat - minLat),
    );
  }

  static const double pickStartSpan = 180;

  static int pickAccuracy(num span) =>
      math.max(5, (span * 111320 / 20).round());

  static double pickZoomIn(num span) => math.max(0.005, span / 4);

  static double pickZoomOut(num span) =>
      math.min(pickStartSpan, span * 4).toDouble();

  static ({double lat, double lon, double span}) pickTap(
    double lat,
    double lon,
    double span,
    double fx,
    double fy,
  ) {
    final x = math.max(0.0, math.min(1.0, fx));
    final y = math.max(0.0, math.min(1.0, fy));
    final nlat = math.max(-89.9, math.min(89.9, lat + span / 2 - y * span));
    final nlon = _wrapLon(lon - span + x * 2 * span);
    return (lat: nlat, lon: nlon, span: pickZoomIn(span));
  }

  static String liveDurationLabel(int sec) {
    switch (sec) {
      case 900:
        return GroupToolsStrings.live15;
      case 3600:
        return GroupToolsStrings.live60;
      case 28800:
        return GroupToolsStrings.live480;
      default:
        return '';
    }
  }

  static const List<String> _groupFeatures = [
    'mentionAll',
    'slowmode',
    'description',
    'approval',
    'preview',
    'event',
    'rsvp',
  ];

  static FeatureAvailability availability(
    String feature, {
    required String surface,
    required bool online,
    bool meshPeer = false,
  }) {
    const ok = FeatureAvailability(true, null, false);
    if (feature == 'location' || feature == 'liveLocation') {
      if (surface == 'channel') {
        return const FeatureAvailability(
          false,
          GroupToolsStrings.noPublicLocation,
          false,
        );
      }
      if (surface == 'group') {
        return online
            ? ok
            : const FeatureAvailability(
                false,
                GroupToolsStrings.groupsNeedNet,
                false,
              );
      }
      if (online) return ok;
      if (meshPeer) return const FeatureAvailability(true, null, true);
      return const FeatureAvailability(
        false,
        GroupToolsStrings.locationNeedsNet,
        false,
      );
    }
    if (feature == 'callLink') {
      return online
          ? ok
          : const FeatureAvailability(
              false,
              GroupToolsStrings.callNeedsNet,
              false,
            );
    }
    if (_groupFeatures.contains(feature)) {
      return online
          ? ok
          : const FeatureAvailability(
              false,
              GroupToolsStrings.groupsNeedNet,
              false,
            );
    }
    return const FeatureAvailability(false, null, false);
  }
}
