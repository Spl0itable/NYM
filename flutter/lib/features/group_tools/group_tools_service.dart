import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../models/group.dart';
import '../../models/message.dart';
import '../chat_tools/chat_tools_service.dart' show ChatToolsPrefs;
import 'group_tools.dart';

class GroupToolsKeys {
  GroupToolsKeys._();
  static const String rsvps = 'nym_gt_rsvps';
  static const String reminders = 'nym_gt_reminders';
  static const String callLinks = 'nym_gt_call_links';
  static const String pendingJoins = 'nym_gt_pending_joins';
  static const String liveShare = 'nym_gt_live_share';
}

class GtChat {
  const GtChat.group(this.id) : isGroup = true;
  const GtChat.dm(this.id) : isGroup = false;
  final String id;
  final bool isGroup;

  Map<String, dynamic> toJson() => {'type': isGroup ? 'group' : 'dm', 'id': id};

  static GtChat? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return j['type'] == 'group' ? GtChat.group(id) : GtChat.dm(id);
  }
}

class GtPosition {
  const GtPosition(this.lat, this.lon, this.acc);
  final double lat;
  final double lon;
  final double acc;
}

class LiveShare {
  LiveShare({
    required this.id,
    required this.chat,
    required this.until,
    required this.seq,
    required this.lat,
    required this.lon,
    required this.acc,
  });
  final String id;
  final GtChat chat;
  final int until;
  int seq;
  double lat;
  double lon;
  double acc;

  Map<String, dynamic> toJson() => {
    'id': id,
    'chat': chat.toJson(),
    'until': until,
    'seq': seq,
    'lat': lat,
    'lon': lon,
    'acc': acc,
  };

  static LiveShare? fromJson(Object? j) {
    if (j is! Map) return null;
    final chat = GtChat.fromJson(j['chat']);
    final id = j['id'];
    if (chat == null || id is! String) return null;
    double d(Object? v) => v is num ? v.toDouble() : 0;
    return LiveShare(
      id: id,
      chat: chat,
      until: (j['until'] as num?)?.toInt() ?? 0,
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      lat: d(j['lat']),
      lon: d(j['lon']),
      acc: d(j['acc']),
    );
  }
}

class PendingJoin {
  PendingJoin({
    required this.name,
    required this.inviter,
    required this.at,
    required this.approval,
    this.waiting = false,
    List<String>? deciders,
  }) : deciders = deciders ?? <String>[];
  final String name;
  final String inviter;
  final int at;
  final bool approval;
  bool waiting;
  List<String> deciders;

  Map<String, dynamic> toJson() => {
    'n': name,
    'a': inviter,
    'at': at,
    'approval': approval,
    'waiting': waiting,
    'deciders': deciders,
  };

  static PendingJoin? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['a'];
    if (a is! String) return null;
    return PendingJoin(
      name: (j['n'] ?? 'Group').toString(),
      inviter: a,
      at: (j['at'] as num?)?.toInt() ?? 0,
      approval: j['approval'] == true,
      waiting: j['waiting'] == true,
      deciders: [
        for (final d in (j['deciders'] as List?) ?? const [])
          if (d is String) d,
      ],
    );
  }
}

class EventReminder {
  EventReminder({
    required this.offset,
    required this.start,
    required this.title,
    required this.groupId,
    this.fired = false,
  });
  final int offset;
  final int start;
  final String title;
  final String groupId;
  bool fired;

  Map<String, dynamic> toJson() => {
    'offset': offset,
    'start': start,
    'title': title,
    'groupId': groupId,
    'fired': fired,
  };

  static EventReminder? fromJson(Object? j) {
    if (j is! Map) return null;
    final o = j['offset'];
    final s = j['start'];
    if (o is! num || s is! num) return null;
    return EventReminder(
      offset: o.toInt(),
      start: s.toInt(),
      title: (j['title'] ?? '').toString(),
      groupId: (j['groupId'] ?? '').toString(),
      fired: j['fired'] == true,
    );
  }
}

class GroupToolsHooks {
  const GroupToolsHooks({
    required this.selfPubkey,
    required this.online,
    required this.group,
    this.saveGroup,
    this.messages,
    this.sendGroupControl,
    this.sendDirect,
    this.broadcastMetadata,
    this.addMember,
    this.sendGroupContent,
    this.sendPmContent,
    this.meshPeerFor,
    this.sendMeshPm,
    this.notice,
    this.notify,
    this.nymOf,
    this.sign,
    this.verify,
    this.sendCallSignal,
    this.confirm,
    this.admitToCall,
    this.joinAccepted,
    this.position,
    this.onChanged,
    this.now,
    this.translate,
  });

  final String Function() selfPubkey;
  final bool Function() online;
  final Group? Function(String groupId) group;
  final void Function(Group g)? saveGroup;
  final List<Message> Function(String storageKey)? messages;
  final Future<bool> Function(
    Group g,
    String type,
    List<List<String>> extraTags,
    List<String> recipients, {
    String content,
  })?
  sendGroupControl;
  final Future<bool> Function(
    String to,
    List<List<String>> tags,
    String content,
  )?
  sendDirect;
  final Future<bool> Function(Group g)? broadcastMetadata;
  final Future<void> Function(String groupId, String pubkey)? addMember;
  final Future<bool> Function(String groupId, String content)? sendGroupContent;
  final Future<bool> Function(String pubkey, String content)? sendPmContent;
  final String? Function(String pubkey)? meshPeerFor;
  final Future<bool> Function(String pubkey, String content)? sendMeshPm;
  final void Function(String text)? notice;
  final void Function(String title, String body, String route, String type)?
  notify;
  final String Function(String pubkey)? nymOf;
  final Future<Map<String, dynamic>?> Function(Map<String, dynamic> template)?
  sign;
  final bool Function(Map<String, dynamic> event)? verify;
  final Future<void> Function(String to, Map<String, dynamic> payload)?
  sendCallSignal;
  final Future<bool> Function(
    String message, {
    String? title,
    String? okLabel,
    String? cancelLabel,
  })?
  confirm;
  final Future<void> Function(CallLink link, String joiner)? admitToCall;
  final void Function()? joinAccepted;
  final Future<GtPosition?> Function()? position;
  final void Function()? onChanged;
  final int Function()? now;
  final String Function(String text, [Map<String, String>? vars])? translate;
}

class GroupToolsService {
  GroupToolsService(this._prefs, this.hooks);

  final ChatToolsPrefs _prefs;
  final GroupToolsHooks hooks;
  final Random _rng = Random.secure();

  int get _nowMs => hooks.now?.call() ?? DateTime.now().millisecondsSinceEpoch;
  int get _nowSec => _nowMs ~/ 1000;
  String get _self => hooks.selfPubkey();

  void _changed() => hooks.onChanged?.call();
  String _t(String text, [Map<String, String>? vars]) {
    final tr = hooks.translate;
    if (tr != null) return tr(text, vars);
    var out = text;
    vars?.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  void _notice(String text, [Map<String, String>? vars]) =>
      hooks.notice?.call(_t(text, vars));
  String _nym(String pk) => hooks.nymOf?.call(pk) ?? pk.substring(0, 8);

  String randomHex(int bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  Object? _readJson(String key) {
    try {
      final raw = _prefs.read(key);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  String _k(String base) => '$base:$_self';

  String role(String groupId, String pubkey) {
    final g = hooks.group(groupId);
    if (g == null) return 'member';
    if (g.createdBy == pubkey) return 'owner';
    if (g.admins.contains(pubkey)) return 'admin';
    if (g.mods.contains(pubkey)) return 'mod';
    return 'member';
  }

  bool isRosterMember(Group g, String pubkey) =>
      g.createdBy == pubkey || g.members.contains(pubkey);

  FeatureAvailability availability(
    String feature,
    String surface, {
    String? peer,
  }) {
    final meshPeer = peer != null && hooks.meshPeerFor?.call(peer) != null;
    return GroupTools.availability(
      feature,
      surface: surface,
      online: hooks.online(),
      meshPeer: meshPeer,
    );
  }

  FeatureAvailability gate(String feature, String surface, {String? peer}) {
    final a = availability(feature, surface, peer: peer);
    if (!a.ok) _notice(a.reason ?? GroupToolsStrings.groupsNeedNet);
    return a;
  }

  List<SlowmodeMessage> _ownSlowmodeMessages(String groupId) {
    final list = hooks.messages?.call('group-$groupId') ?? const <Message>[];
    return [
      for (final m in list)
        if (m.pubkey == _self && m.deliveryStatus != DeliveryStatus.failed)
          SlowmodeMessage(
            m.nymMessageId ?? m.id,
            m.originalCreatedAt ?? m.createdAt,
          ),
    ];
  }

  int slowmodeWait(String groupId) {
    final g = hooks.group(groupId);
    if (g == null) return 0;
    final interval = GroupTools.normalizeSlowmode(g.slowmode);
    if (interval == 0) return 0;
    final last = GroupTools.slowmodeLastAccepted(
      _ownSlowmodeMessages(groupId),
      interval,
      g.slowmodeSince,
    );
    return GroupTools.slowmodeWait(interval, last, _nowSec);
  }

  String? sendBlockedReason(String groupId, String content) {
    final g = hooks.group(groupId);
    if (g == null || _self.isEmpty) return null;
    final loc = GroupTools.parseLocation(content);
    if (loc != null && loc.kind != 'pin' && loc.seq > 0) return null;
    final r = role(groupId, _self);
    final check = GroupTools.sendCheck('group', r, content);
    if (!check.ok) return _t(check.reason!);
    final interval = GroupTools.normalizeSlowmode(g.slowmode);
    if (interval > 0 && !GroupTools.slowmodeExempt(r)) {
      final wait = slowmodeWait(groupId);
      if (wait > 0) {
        return _t(GroupToolsStrings.slowmodeWait, {
          'time': GroupTools.formatWait(wait),
        });
      }
    }
    return null;
  }

  bool applySlowmode(String groupId, List<Message> list, String sender) {
    final g = hooks.group(groupId);
    if (g == null) return false;
    final interval = GroupTools.normalizeSlowmode(g.slowmode);
    final exempt = GroupTools.slowmodeExempt(role(groupId, sender));
    final mine = [
      for (final m in list)
        if (m.pubkey == sender) m,
    ];
    final held = (interval == 0 || exempt)
        ? const <String>[]
        : GroupTools.slowmodeHeld(
            [
              for (final m in mine)
                SlowmodeMessage(
                  m.nymMessageId ?? m.id,
                  m.originalCreatedAt ?? m.createdAt,
                ),
            ],
            interval,
            g.slowmodeSince,
          );
    final set = held.toSet();
    var flipped = false;
    for (final m in mine) {
      final h = set.contains(m.nymMessageId ?? m.id);
      if (m.slowHeld != h) {
        m.slowHeld = h;
        flipped = true;
      }
    }
    return flipped;
  }

  bool mentionsAll(Message m) {
    if (m.isOwn || !m.isGroup || m.groupId == null) return false;
    return GroupTools.notifiesAll(
      'group',
      role(m.groupId!, m.pubkey),
      m.content,
    );
  }

  bool absorbLive(Message m, List<Message> list) {
    final loc = GroupTools.parseLocation(m.content);
    if (loc == null || loc.kind == 'pin') return false;
    Message? first;
    SharedLocation? cur;
    for (final e in list) {
      if (identical(e, m) || e.pubkey != m.pubkey) continue;
      final l = GroupTools.parseLocation(e.content);
      if (l != null && l.kind != 'pin' && l.id == loc.id) {
        first = e;
        cur = l;
        break;
      }
    }
    if (first == null) return false;
    if (GroupTools.liveSupersedes(cur, loc)) {
      first.content = m.content;
      _changed();
    }
    return true;
  }

  Future<void> setSlowmode(String groupId, int sec) async {
    final g = hooks.group(groupId);
    if (g == null) return;
    final r = role(groupId, _self);
    if (r != 'owner' && r != 'admin') {
      _notice('Only the group owner or an admin can change this setting.');
      return;
    }
    if (!gate('slowmode', 'group').ok) return;
    final next = GroupTools.normalizeSlowmode(sec);
    if (next == GroupTools.normalizeSlowmode(g.slowmode)) return;
    final ts = _nowSec;
    g.slowmode = next;
    g.slowmodeSince = ts;
    g.metaUpdatedAt = ts;
    g.metaUpdatedBy = _self;
    hooks.saveGroup?.call(g);
    await hooks.broadcastMetadata?.call(g);
    if (next > 0) {
      _notice(
        'Slowmode is on: members can send one message every {interval}.',
        {'interval': _t(GroupTools.slowmodeLabel(next))},
      );
    } else {
      _notice('Slowmode is off.');
    }
    _changed();
  }

  Future<void> setJoinApproval(String groupId, bool on) async {
    final g = hooks.group(groupId);
    if (g == null) return;
    final r = role(groupId, _self);
    if (r != 'owner' && r != 'admin') {
      _notice('Only the group owner or an admin can change this setting.');
      return;
    }
    if (!gate('approval', 'group').ok) return;
    if (on == g.joinApproval) return;
    g.joinApproval = on;
    g.metaUpdatedAt = _nowSec;
    g.metaUpdatedBy = _self;
    hooks.saveGroup?.call(g);
    await hooks.broadcastMetadata?.call(g);
    _notice(
      on
          ? 'Admins now approve join requests from invite links.'
          : 'Invite links admit new members automatically again.',
    );
    _changed();
  }

  List<String> _deciders(Group g) =>
      [if (g.createdBy != null) g.createdBy!, ...g.admins]
          .where((pk) => pk.isNotEmpty && pk != _self && g.members.contains(pk))
          .toSet()
          .toList();

  Future<void> queueJoinRequest(
    String groupId,
    String joiner,
    String via,
    int ts, {
    required bool forward,
  }) async {
    final g = hooks.group(groupId);
    if (g == null) return;
    final before = g.joinRequests.length;
    g.joinRequests = GroupTools.addJoinRequest(
      g.joinRequests,
      JoinRequest(pubkey: joiner, ts: ts, via: via),
      _nowSec,
    );
    hooks.saveGroup?.call(g);
    final grew = g.joinRequests.length > before;
    if (forward) {
      final deciders = _deciders(g);
      if (deciders.isNotEmpty) {
        await hooks.sendGroupControl?.call(g, GroupToolsTypes.joinPending, [
          ['joiner', joiner],
          ['joiner_ts', '$ts'],
        ], deciders);
      }
      await hooks.sendDirect?.call(joiner, [
        ['g', groupId],
        ['subject', g.name],
        ['type', GroupToolsTypes.joinWaiting],
        for (final pk in [
          if (g.createdBy != null) g.createdBy!,
          ...g.admins,
        ].where((pk) => g.members.contains(pk)))
          ['decider', pk],
        ['x', randomHex(32)],
      ], '');
    }
    if (grew && GroupTools.mayApproveJoins(role(groupId, _self))) {
      hooks.notify?.call(
        _t('Join request in {group}', {
          'group': g.name.isEmpty ? 'Group' : g.name,
        }),
        _t('{nym} wants to join. Open the group menu to approve or decline.', {
          'nym': _nym(joiner),
        }),
        groupId,
        'group',
      );
    }
    _changed();
  }

  Future<bool> handleJoinRequest(
    Group g,
    String joiner,
    int reqEpoch,
    int createdAt,
    bool selfCanAdd,
  ) async {
    final action = GroupTools.joinRequestAction(
      inviteEnabled: g.inviteEnabled,
      epoch: g.inviteEpoch,
      approval: g.joinApproval,
      members: g.members,
      banned: g.banned,
      requester: joiner,
      requestEpoch: reqEpoch,
      selfCanAdd: selfCanAdd,
    );
    if (action != 'queue') return false;
    await queueJoinRequest(
      g.id,
      joiner,
      _self,
      min(createdAt, _nowSec),
      forward: true,
    );
    return true;
  }

  Future<void> decideJoin(String groupId, String joiner, bool approve) async {
    final g = hooks.group(groupId);
    if (g == null) return;
    if (!GroupTools.mayApproveJoins(role(groupId, _self))) {
      _notice('Only the group owner or an admin can approve join requests.');
      return;
    }
    if (!gate('approval', 'group').ok) return;
    g.joinRequests = GroupTools.removeJoinRequest(g.joinRequests, joiner);
    hooks.saveGroup?.call(g);
    final deciders = _deciders(g);
    if (deciders.isNotEmpty) {
      await hooks.sendGroupControl?.call(g, GroupToolsTypes.joinResolved, [
        ['joiner', joiner],
        ['decision', approve ? 'approve' : 'decline'],
      ], deciders);
    }
    if (approve) {
      if (g.banned.contains(joiner)) return;
      if (!g.members.contains(joiner)) {
        await hooks.addMember?.call(groupId, joiner);
      }
      _notice('Approved. {nym} was added to the group.', {'nym': _nym(joiner)});
    } else {
      await hooks.sendDirect?.call(joiner, [
        ['g', groupId],
        ['subject', g.name],
        ['type', GroupToolsTypes.joinDeclined],
        ['x', randomHex(32)],
      ], '');
      _notice('Declined the join request from {nym}.', {'nym': _nym(joiner)});
    }
    _changed();
  }

  Map<String, PendingJoin>? _pendingCache;
  String? _pendingPk;

  Map<String, PendingJoin> pendingJoins() {
    if (_pendingCache != null && _pendingPk == _self) return _pendingCache!;
    final raw = _readJson(_k(GroupToolsKeys.pendingJoins));
    final out = <String, PendingJoin>{};
    if (raw is Map) {
      final cutoff = _nowSec - GroupToolsLimits.joinRequestTtlSec;
      raw.forEach((k, v) {
        final p = PendingJoin.fromJson(v);
        if (p != null && k is String && p.at > cutoff) out[k] = p;
      });
    }
    _pendingCache = out;
    _pendingPk = _self;
    return out;
  }

  void _savePending() {
    _prefs.write(
      _k(GroupToolsKeys.pendingJoins),
      jsonEncode(pendingJoins().map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  bool isPendingJoin(String groupId) => pendingJoins().containsKey(groupId);

  PendingJoin rememberPendingJoin(InvitePayload p) {
    final fields = verifySummary(p);
    final name = GroupTools.sanitizeName(p.n, 40);
    final pj = PendingJoin(
      name: name.isEmpty ? 'Group' : name,
      inviter: p.a,
      at: _nowSec,
      approval: fields != null && fields.ap == 1,
    );
    pendingJoins()[p.g] = pj;
    _savePending();
    return pj;
  }

  void clearPendingJoin(String groupId) {
    if (pendingJoins().remove(groupId) != null) _savePending();
  }

  Future<bool> handleControl(
    String type,
    List<List<String>> tags,
    String groupId,
    String sender,
    int createdAt,
  ) async {
    String? tv(String k) {
      for (final t in tags) {
        if (t.length > 1 && t[0] == k && t[1].isNotEmpty) return t[1];
      }
      return null;
    }

    final isOwn = sender == _self;
    if (type == 'group-invite' || type == 'group-add-member') {
      clearPendingJoin(groupId);
      return false;
    }
    if (type == GroupToolsTypes.rsvp) {
      if (!isOwn) applyRsvpRumor(tags, groupId, sender, createdAt);
      return true;
    }
    if (type == GroupToolsTypes.joinPending) {
      if (isOwn) return true;
      final g = hooks.group(groupId);
      final joiner = tv('joiner');
      if (g == null ||
          joiner == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(joiner)) {
        return true;
      }
      if (!isRosterMember(g, sender)) return true;
      if (g.members.contains(joiner) || g.banned.contains(joiner)) return true;
      final ts = int.tryParse(tv('joiner_ts') ?? '') ?? createdAt;
      await queueJoinRequest(
        groupId,
        joiner,
        sender,
        min(ts, _nowSec),
        forward: false,
      );
      return true;
    }
    if (type == GroupToolsTypes.joinResolved) {
      if (isOwn) return true;
      final g = hooks.group(groupId);
      final joiner = tv('joiner');
      if (g == null || joiner == null) return true;
      if (!GroupTools.mayApproveJoins(role(groupId, sender))) return true;
      g.joinRequests = GroupTools.removeJoinRequest(g.joinRequests, joiner);
      hooks.saveGroup?.call(g);
      _changed();
      return true;
    }
    if (type == GroupToolsTypes.joinWaiting ||
        type == GroupToolsTypes.joinDeclined) {
      if (isOwn) return true;
      final p = pendingJoins()[groupId];
      if (p == null) return true;
      if (type == GroupToolsTypes.joinWaiting) {
        if (sender != p.inviter) return true;
        p.deciders = [
          for (final t in tags)
            if (t.length > 1 &&
                t[0] == 'decider' &&
                RegExp(r'^[0-9a-f]{64}$').hasMatch(t[1]))
              t[1],
        ].take(20).toList();
        _savePending();
        if (!p.waiting) {
          p.waiting = true;
          _savePending();
          _notice('Waiting for approval to join "{name}".', {'name': p.name});
          _changed();
        }
        return true;
      }
      if (sender != p.inviter && !p.deciders.contains(sender)) return true;
      clearPendingJoin(groupId);
      final body = _t('Your request to join "{name}" was declined.', {
        'name': p.name,
      });
      hooks.notice?.call(body);
      hooks.notify?.call(_t('Join request declined'), body, groupId, 'group');
      _changed();
      return true;
    }
    return false;
  }

  final Map<String, ({String c, int at, InviteSignedSummary s})> _summaries =
      {};

  InviteSignedSummary? cachedSummary(String groupId) => _summaries[groupId]?.s;

  Future<InviteSignedSummary?> ensureSummary(String groupId) async {
    final g = hooks.group(groupId);
    final sign = hooks.sign;
    if (g == null || sign == null || _self.isEmpty) return null;
    final admins = [if (g.createdBy != null) g.createdBy!, ...g.admins];
    final content = GroupTools.summaryContent(
      description: g.description ?? '',
      avatar: g.avatar ?? '',
      banner: g.banner ?? '',
      memberCount: g.members.length,
      adminNyms: [
        for (final pk in admins) '${_nym(pk)}#${pk.substring(pk.length - 4)}',
      ],
      approval: g.joinApproval,
    );
    final cached = _summaries[groupId];
    if (cached != null &&
        cached.c == content &&
        _nowMs - cached.at < 10 * 60 * 1000) {
      return cached.s;
    }
    try {
      final signed = await sign(
        GroupTools.summaryTemplate(groupId, _self, _nowSec, content),
      );
      final sig = signed?['sig'];
      final created = signed?['created_at'];
      if (sig is! String ||
          !RegExp(r'^[0-9a-f]{128}$').hasMatch(sig) ||
          created is! int) {
        return null;
      }
      final s = InviteSignedSummary(t: created, c: content, sig: sig);
      _summaries[groupId] = (c: content, at: _nowMs, s: s);
      return s;
    } catch (_) {
      return null;
    }
  }

  InviteSummaryFields? verifySummary(InvitePayload p) {
    final s = p.s;
    final verify = hooks.verify;
    if (s == null || verify == null) return null;
    final ev = GroupTools.summaryTemplate(p.g, p.a, s.t, s.c);
    ev['sig'] = s.sig;
    try {
      if (!verify(ev)) return null;
    } catch (_) {
      return null;
    }
    return GroupTools.parseSummaryContent(s.c);
  }

  Map<String, Map<String, RsvpEntry>>? _rsvpCache;
  String? _rsvpPk;

  Map<String, Map<String, RsvpEntry>> rsvpStore() {
    if (_rsvpCache != null && _rsvpPk == _self) return _rsvpCache!;
    final raw = _readJson(_k(GroupToolsKeys.rsvps));
    final out = <String, Map<String, RsvpEntry>>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k is! String || v is! Map) return;
        final m = <String, RsvpEntry>{};
        v.forEach((pk, e) {
          final r = RsvpEntry.fromJson(e);
          if (pk is String && r != null) m[pk] = r;
        });
        out[k] = m;
      });
    }
    _rsvpCache = out;
    _rsvpPk = _self;
    return out;
  }

  void _saveRsvps() {
    final s = rsvpStore();
    if (s.length > 300) {
      final keys = s.keys.toList();
      for (final k in keys.take(keys.length - 300)) {
        s.remove(k);
      }
    }
    _prefs.write(
      _k(GroupToolsKeys.rsvps),
      jsonEncode(
        s.map(
          (k, v) => MapEntry(k, v.map((pk, e) => MapEntry(pk, e.toJson()))),
        ),
      ),
    );
  }

  Map<String, RsvpEntry> rsvpEntries(String eventId) =>
      rsvpStore()[eventId] ?? const {};

  void applyRsvpRumor(
    List<List<String>> tags,
    String groupId,
    String sender,
    int createdAt,
  ) {
    final g = hooks.group(groupId);
    if (g == null || !isRosterMember(g, sender)) return;
    final eventId = GroupToolsTags.value(tags, 'e');
    if (eventId == null || !RegExp(r'^[0-9a-f]{16}$').hasMatch(eventId)) {
      return;
    }
    final r = GroupTools.applyRsvp(
      rsvpEntries(eventId),
      sender,
      GroupToolsTags.value(tags, 'rsvp') ?? '',
      min(createdAt, _nowSec + 300),
    );
    if (!r.changed) return;
    rsvpStore()[eventId] = r.entries;
    _saveRsvps();
    _changed();
  }

  GroupEventInfo? findEvent(String groupId, String eventId) {
    final list = hooks.messages?.call('group-$groupId') ?? const <Message>[];
    for (final m in list) {
      final ev = GroupTools.parseEvent(m.content);
      if (ev != null && ev.id == eventId) return ev;
    }
    return null;
  }

  Future<void> rsvp(String groupId, String eventId, String status) async {
    final g = hooks.group(groupId);
    if (g == null || GroupTools.normalizeRsvp(status) == null) return;
    if (!gate('rsvp', 'group').ok) return;
    final title = findEvent(groupId, eventId)?.title ?? '';
    final prev = rsvpEntries(eventId)[_self]?.ts ?? 0;
    final ts = max(_nowSec, prev + 1);
    final r = GroupTools.applyRsvp(rsvpEntries(eventId), _self, status, ts);
    rsvpStore()[eventId] = r.entries;
    _saveRsvps();
    _changed();
    await hooks.sendGroupControl?.call(
      g,
      GroupToolsTypes.rsvp,
      [
        ['e', eventId],
        ['rsvp', status],
      ],
      g.members,
      content: GroupTools.rsvpContent(status, title),
    );
  }

  Map<String, EventReminder>? _remCache;

  Map<String, EventReminder> reminders() {
    if (_remCache != null) return _remCache!;
    final raw = _readJson(GroupToolsKeys.reminders);
    final out = <String, EventReminder>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final r = EventReminder.fromJson(v);
        if (k is String && r != null) out[k] = r;
      });
    }
    return _remCache = out;
  }

  void _saveReminders() => _prefs.write(
    GroupToolsKeys.reminders,
    jsonEncode(reminders().map((k, v) => MapEntry(k, v.toJson()))),
  );

  int? reminderOffset(String eventId) => reminders()[eventId]?.offset;

  void setReminder(String groupId, String eventId, int? offset) {
    final ev = findEvent(groupId, eventId);
    if (offset == null || ev == null) {
      reminders().remove(eventId);
    } else {
      if (!GroupTools.reminderOffsetsMin.contains(offset)) return;
      reminders()[eventId] = EventReminder(
        offset: offset,
        start: ev.start,
        title: ev.title,
        groupId: groupId,
      );
      final at = GroupTools.reminderAt(ev.start, offset);
      if (at <= _nowSec) {
        _notice('That reminder time has already passed.');
      } else {
        _notice('Reminder set: {label}.', {
          'label': _t(GroupTools.reminderLabel(offset)),
        });
      }
    }
    _saveReminders();
    _changed();
    armReminders();
  }

  Timer? _remTimer;

  List<String> dueReminders() {
    final out = <String>[];
    var dirty = false;
    final now = _nowSec;
    reminders().forEach((id, r) {
      if (r.fired) return;
      final at = GroupTools.reminderAt(r.start, r.offset);
      if (at <= now) {
        r.fired = true;
        dirty = true;
        if (now - at < 3600) out.add(id);
      }
    });
    if (dirty) _saveReminders();
    return out;
  }

  void armReminders() {
    _remTimer?.cancel();
    for (final id in dueReminders()) {
      final r = reminders()[id]!;
      final g = hooks.group(r.groupId);
      hooks.notify?.call(
        _t('Reminder: {title}', {'title': r.title}),
        _t('Starts {when}', {'when': '<t:${r.start}:R>'}) +
            (g != null ? ' · ${g.name}' : ''),
        r.groupId,
        'group',
      );
    }
    var next = 0;
    reminders().forEach((id, r) {
      if (r.fired) return;
      final at = GroupTools.reminderAt(r.start, r.offset);
      if (next == 0 || at < next) next = at;
    });
    if (next > 0) {
      final waitMs = min((next - _nowSec) * 1000 + 50, 3600000);
      _remTimer = Timer(Duration(milliseconds: max(50, waitMs)), armReminders);
    }
  }

  List<CallLink>? _linksCache;
  String? _linksPk;

  List<CallLink> callLinks() {
    if (_linksCache != null && _linksPk == _self) return _linksCache!;
    final raw = _readJson(_k(GroupToolsKeys.callLinks));
    _linksCache = [
      if (raw is List)
        for (final e in raw)
          if (CallLink.fromJson(e) != null) CallLink.fromJson(e)!,
    ];
    _linksPk = _self;
    return _linksCache!;
  }

  void _saveLinks(List<CallLink> l) {
    _linksCache = l;
    _linksPk = _self;
    _prefs.write(
      _k(GroupToolsKeys.callLinks),
      jsonEncode([for (final x in l) x.toJson()]),
    );
    _changed();
  }

  CallLink createCallLink({
    required String kind,
    required int expirySec,
    required String name,
    String? groupId,
  }) {
    final cleaned = GroupTools.sanitizeName(name);
    final link = CallLink(
      id: randomHex(8),
      host: _self,
      kind: kind == 'video' ? 'video' : 'audio',
      exp: expirySec > 0 ? _nowSec + expirySec : 0,
      secret: randomHex(16),
      name: cleaned.isEmpty ? 'Call' : cleaned,
      groupId: groupId,
      createdAt: _nowSec,
    );
    _saveLinks(GroupTools.addCallLink(callLinks(), link));
    return link;
  }

  void revokeCallLink(String id) {
    _saveLinks(GroupTools.revokeCallLink(callLinks(), id));
    _notice(
      'Call link revoked. Anyone who tries it now is told it was revoked.',
    );
  }

  ({String id, String host, int at})? _linkJoin;

  ({String id, String host, int at})? get pendingLinkJoin => _linkJoin;

  bool linkJoinMatches(String sender, Map<String, dynamic> data) {
    final j = _linkJoin;
    return j != null &&
        data['link'] == j.id &&
        sender == j.host &&
        _nowMs - j.at < 120000;
  }

  void consumeLinkJoin() => _linkJoin = null;

  Future<void> requestLinkJoin(CallLink link) async {
    _linkJoin = (id: link.id, host: link.host, at: _nowMs);
    await hooks.sendCallSignal?.call(link.host, {
      'type': GroupToolsCallSignals.join,
      'linkId': link.id,
      'secret': link.secret,
      'kind': link.kind,
    });
  }

  Future<void> onCallSignal(
    String sender,
    Map<String, dynamic> data, {
    bool Function(String kind)? busyFor,
  }) async {
    final type = data['type'];
    if (type == GroupToolsCallSignals.refused) {
      final j = _linkJoin;
      if (j == null || j.host != sender || data['linkId'] != j.id) return;
      _linkJoin = null;
      _notice(GroupTools.callLinkRefusal(data['reason'] as String?));
      return;
    }
    if (type != GroupToolsCallSignals.join) return;
    final linkId = (data['linkId'] ?? '').toString();
    final secret = (data['secret'] ?? '').toString();
    final check = GroupTools.checkCallLinkJoin(
      callLinks(),
      linkId,
      secret,
      _nowSec,
    );
    if (!check.ok) {
      if (check.reason != 'unknown') {
        await hooks.sendCallSignal?.call(sender, {
          'type': GroupToolsCallSignals.refused,
          'linkId': linkId,
          'reason': check.reason == 'secret' ? 'invalid' : check.reason,
        });
      }
      return;
    }
    final link = callLinks().firstWhere((l) => l.id == linkId);
    if (busyFor?.call(link.kind) == true) {
      await hooks.sendCallSignal?.call(sender, {
        'type': GroupToolsCallSignals.refused,
        'linkId': linkId,
        'reason': 'busy',
      });
      return;
    }
    final who = '${_nym(sender)}#${sender.substring(sender.length - 4)}';
    hooks.notify?.call(
      _t('Call link: {name}', {'name': link.name}),
      _t('{nym} wants to join', {'nym': who}),
      sender,
      'call',
    );
    final admit =
        await (hooks.confirm?.call(
              _t('{nym} wants to join your call link "{name}".', {
                'nym': who,
                'name': link.name,
              }),
              title: _t('Join request'),
              okLabel: _t('Admit'),
              cancelLabel: _t('Decline'),
            ) ??
            Future.value(false));
    final recheck = GroupTools.checkCallLinkJoin(
      callLinks(),
      linkId,
      secret,
      _nowSec,
    );
    if (!admit || !recheck.ok) {
      await hooks.sendCallSignal?.call(sender, {
        'type': GroupToolsCallSignals.refused,
        'linkId': linkId,
        'reason': admit ? recheck.reason : 'declined',
      });
      return;
    }
    await hooks.admitToCall?.call(link, sender);
  }

  LiveShare? _live;
  Timer? _liveTimer;

  LiveShare? get liveShare => _live;

  Future<bool> sendToChat(GtChat chat, String content) async {
    if (chat.isGroup) {
      return await hooks.sendGroupContent?.call(chat.id, content) ?? false;
    }
    if (hooks.online()) {
      return await hooks.sendPmContent?.call(chat.id, content) ?? false;
    }
    if (hooks.meshPeerFor?.call(chat.id) != null && hooks.sendMeshPm != null) {
      return hooks.sendMeshPm!(chat.id, content);
    }
    _notice(GroupToolsStrings.locationNeedsNet);
    return false;
  }

  Future<bool> sendPin(GtChat chat, GtPosition pos) async {
    final content = GroupTools.buildLocation(
      lat: pos.lat,
      lon: pos.lon,
      acc: pos.acc,
      kind: 'pin',
    );
    if (content == null) return false;
    return sendToChat(chat, content);
  }

  Future<void> startLive(GtChat chat, int durationSec, GtPosition pos) async {
    if (!GroupTools.liveDurationsSec.contains(durationSec)) return;
    if (_live != null) await stopLive(auto: true);
    final share = LiveShare(
      id: randomHex(4),
      chat: chat,
      until: _nowSec + durationSec,
      seq: 0,
      lat: pos.lat,
      lon: pos.lon,
      acc: pos.acc,
    );
    _live = share;
    _prefs.write(GroupToolsKeys.liveShare, jsonEncode(share.toJson()));
    await sendToChat(chat, _liveContent(share, 'live'));
    _armLive();
    _changed();
  }

  String _liveContent(LiveShare s, String kind) => GroupTools.buildLocation(
    lat: s.lat,
    lon: s.lon,
    acc: s.acc,
    kind: kind,
    id: s.id,
    until: s.until,
    seq: s.seq,
  )!;

  void _armLive() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(
      const Duration(seconds: GroupToolsLimits.liveUpdateSec),
      (_) => unawaited(tickLive()),
    );
  }

  Future<void> tickLive() async {
    final s = _live;
    if (s == null) return;
    if (_nowSec >= s.until) {
      await stopLive(auto: true);
      return;
    }
    final pos = await hooks.position?.call();
    if (pos != null) {
      s.lat = pos.lat;
      s.lon = pos.lon;
      s.acc = pos.acc;
    }
    s.seq++;
    _prefs.write(GroupToolsKeys.liveShare, jsonEncode(s.toJson()));
    await sendToChat(s.chat, _liveContent(s, 'live'));
  }

  Future<void> stopLive({bool auto = false}) async {
    final s = _live;
    if (s == null) return;
    _live = null;
    _liveTimer?.cancel();
    _liveTimer = null;
    _prefs.remove(GroupToolsKeys.liveShare);
    s.seq++;
    await sendToChat(s.chat, _liveContent(s, 'end'));
    _notice(
      auto && _nowSec >= s.until
          ? 'Your live location share ended.'
          : 'Stopped sharing your live location.',
    );
    _changed();
  }

  Future<void> resumeLive() async {
    final s = LiveShare.fromJson(_readJson(GroupToolsKeys.liveShare));
    if (s == null) return;
    _live = s;
    if (_nowSec >= s.until) {
      await stopLive(auto: true);
      return;
    }
    _armLive();
    _notice('Still sharing your live location until {time}.', {
      'time': '<t:${s.until}:t>',
    });
    _changed();
  }

  void dispose() {
    _remTimer?.cancel();
    _liveTimer?.cancel();
  }
}

class GroupToolsTags {
  GroupToolsTags._();

  static String? value(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.length > 1 && t[0] == name && t[1].isNotEmpty) return t[1];
    }
    return null;
  }
}
