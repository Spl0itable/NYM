import 'dart:convert';

class ChatNavLimits {
  const ChatNavLimits._();

  static const int pinMax = 10;
  static const int pinHardMax = 50;
  static const int pinRemovedMax = 300;
  static const int pinRemovedTtlMs = 180 * 24 * 60 * 60 * 1000;
  static const int mentionChatsMax = 200;
  static const int mentionPerChatMax = 100;
  static const int mentionSeenMax = 300;
  static const int scheduleMinLeadSec = 60;
  static const int scheduleMaxAheadSec = 30 * 24 * 60 * 60;
  static const int scheduleMaxPending = 50;
  static const int scheduleMaxEvents = 260;
  static const int scheduleMaxEventBytes = 70000;
  static const int scheduleMaxItemBytes = 1000000;
  static const int scheduleMaxUserBytes = 5000000;
  static const int scheduleMaxRelays = 16;
  static const int scheduleNoteMax = 16000;
  static const int scheduleTextMax = 8000;
  static const int scheduleAttempts = 4;
  static const int scheduleRetrySec = 60;
  static const int scheduleKeepDoneSec = 7 * 24 * 60 * 60;
  static const int wrapJitterSec = 7200;

  static Map<String, num> toJson() => {
        'pinMax': pinMax,
        'pinHardMax': pinHardMax,
        'pinRemovedMax': pinRemovedMax,
        'pinRemovedTtlMs': pinRemovedTtlMs,
        'mentionChatsMax': mentionChatsMax,
        'mentionPerChatMax': mentionPerChatMax,
        'mentionSeenMax': mentionSeenMax,
        'scheduleMinLeadSec': scheduleMinLeadSec,
        'scheduleMaxAheadSec': scheduleMaxAheadSec,
        'scheduleMaxPending': scheduleMaxPending,
        'scheduleMaxEvents': scheduleMaxEvents,
        'scheduleMaxEventBytes': scheduleMaxEventBytes,
        'scheduleMaxItemBytes': scheduleMaxItemBytes,
        'scheduleMaxUserBytes': scheduleMaxUserBytes,
        'scheduleMaxRelays': scheduleMaxRelays,
        'scheduleNoteMax': scheduleNoteMax,
        'scheduleTextMax': scheduleTextMax,
        'scheduleAttempts': scheduleAttempts,
        'scheduleRetrySec': scheduleRetrySec,
        'scheduleKeepDoneSec': scheduleKeepDoneSec,
        'wrapJitterSec': wrapJitterSec,
      };
}

class ChatNavKeys {
  const ChatNavKeys._();

  static const String pinnedDTag = 'nymchat-pinned';
  static const String pinned = 'nym_pinned_chats';
  static const String pinnedPending = 'nym_pinned_pending';
  static const String mentions = 'nym_unread_mentions';
  static const String scheduled = 'nym_scheduled_cache';
  static const String seenMarks = 'nym_seen_marks';

  static Map<String, String> toJson() => {
        'pinnedDTag': pinnedDTag,
        'pinned': pinned,
        'pinnedPending': pinnedPending,
        'mentions': mentions,
        'scheduled': scheduled,
        'seenMarks': seenMarks,
      };
}

class ChatNavStrings {
  const ChatNavStrings._();

  static const String newMessages = 'New messages';
  static const String jumpFirst = 'Jump to first unread';
  static const String nNew = '{n} new';
  static const String mentions = 'Unread mentions';
  static const String favoriteChat = 'Favorite';
  static const String unfavoriteChat = 'Unfavorite';
  static const String moveUp = 'Move up';
  static const String moveDown = 'Move down';
  static const String favorite = 'Favorite channel';
  static const String unfavorite = 'Unfavorite channel';
  static const String favorited = 'Favorited';
  static const String unfavorited = 'Unfavorited #{channel}';
  static const String favoriteCap =
      'You can have up to {n} favorite channels. Remove one first.';
  static const String favoriteChatCap =
      'You can have up to {n} favorite chats. Remove one first.';
  static const String unfavoritedChat = 'Unfavorited {name}';
  static const String sendLater = 'Send later';
  static const String scheduled = 'Scheduled';
  static const String held = 'Held by Nymchat until it sends';
  static const String heldDetail =
      'Nymchat holds a copy that is already signed and, for PMs and groups, already encrypted. It cannot read or change it.';
  static const String meshBlocked =
      'Send later needs the internet. This chat is on the Bluetooth mesh only.';
  static const String offlineBlocked =
      "Send later needs the internet. You're offline.";
  static const String signerBlocked =
      'Send later in PMs and groups needs your key on this device.';
  static const String serverBlocked =
      "Send later isn't available without the Nymchat server.";
  static const String past = 'Pick a time in the future.';
  static const String soon = 'Pick a time at least a minute from now.';
  static const String far = 'You can schedule up to 30 days ahead.';
  static const String full =
      'You have too many scheduled messages. Cancel one first.';
  static const String tooBig = 'This message is too large to schedule.';
  static const String pending = 'Scheduled';
  static const String sending = 'Sending';
  static const String sent = 'Sent';
  static const String failed = 'Failed';
  static const String cancelled = 'Cancelled';
  static const String sendNow = 'Send now';
  static const String editTime = 'Edit time';
  static const String cancel = 'Cancel';

  static Map<String, String> toJson() => {
        'newMessages': newMessages,
        'jumpFirst': jumpFirst,
        'nNew': nNew,
        'mentions': mentions,
        'favoriteChat': favoriteChat,
        'unfavoriteChat': unfavoriteChat,
        'moveUp': moveUp,
        'moveDown': moveDown,
        'favorite': favorite,
        'unfavorite': unfavorite,
        'favorited': favorited,
        'unfavorited': unfavorited,
        'favoriteCap': favoriteCap,
        'favoriteChatCap': favoriteChatCap,
        'unfavoritedChat': unfavoritedChat,
        'sendLater': sendLater,
        'scheduled': scheduled,
        'held': held,
        'heldDetail': heldDetail,
        'meshBlocked': meshBlocked,
        'offlineBlocked': offlineBlocked,
        'signerBlocked': signerBlocked,
        'serverBlocked': serverBlocked,
        'past': past,
        'soon': soon,
        'far': far,
        'full': full,
        'tooBig': tooBig,
        'pending': pending,
        'sending': sending,
        'sent': sent,
        'failed': failed,
        'cancelled': cancelled,
        'sendNow': sendNow,
        'editTime': editTime,
        'cancel': cancel,
      };
}

const List<String> chatNavStatuses = [
  'pending',
  'sending',
  'sent',
  'failed',
  'cancelled'
];

final RegExp _rxHex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _rxGroup = RegExp(r'^[0-9a-f]{16,64}$');
final RegExp _rxChannel = RegExp(r'^[\p{L}\p{N}]{1,64}$', unicode: true);

typedef ChatNavTr = String Function(String s);

num _num(Object? v) {
  if (v is num) return v.isFinite ? v : 0;
  if (v is bool) return v ? 1 : 0;
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return 0;
    final d = double.tryParse(t);
    return d != null && d.isFinite ? d : 0;
  }
  return 0;
}

int _floor(Object? v) => _num(v).floor();

String _fill(String s, Map<String, Object?>? vars) {
  var out = s;
  if (vars != null) {
    vars.forEach((k, v) => out = out.split('{$k}').join('$v'));
  }
  return out;
}

String _tr(ChatNavTr? t, String s) => t == null ? s : t(s);

int _cmp(String a, String b) => a.compareTo(b);

class ChatNavRow {
  const ChatNavRow({
    required this.id,
    required this.at,
    this.own = false,
    this.sys = false,
    this.mention = false,
  });

  factory ChatNavRow.fromJson(Map<String, dynamic> j) => ChatNavRow(
        id: '${j['id'] ?? ''}',
        at: _num(j['at']),
        own: j['own'] == true,
        sys: j['sys'] == true,
        mention: j['mention'] == true,
      );

  final String id;
  final num at;
  final bool own;
  final bool sys;
  final bool mention;
}

class FirstUnread {
  const FirstUnread({
    required this.id,
    required this.index,
    required this.count,
    required this.beyond,
  });

  final String id;
  final int index;
  final int count;
  final bool beyond;

  Map<String, Object> toJson() =>
      {'id': id, 'index': index, 'count': count, 'beyond': beyond};
}

FirstUnread? firstUnread(List<ChatNavRow> list, num lastRead,
    {num before = 0, bool olderMayExist = false, num badge = 0}) {
  final floor = _num(lastRead);
  if (!(floor > 0)) return null;
  var index = -1;
  for (var i = 0; i < list.length; i++) {
    final m = list[i];
    if (m.own || m.sys) continue;
    if (m.at <= floor) continue;
    if (before > 0 && m.at > before) continue;
    index = i;
    break;
  }
  if (index < 0) return null;
  var count = 0;
  for (var i = index; i < list.length; i++) {
    final m = list[i];
    if (m.own || m.sys) continue;
    if (m.at > floor) count++;
  }
  final beyond = index == 0 && olderMayExist;
  if (beyond) count = count > badge.floor() ? count : badge.floor();
  return FirstUnread(id: list[index].id, index: index, count: count, beyond: beyond);
}

bool landOnDivider(FirstUnread? info) =>
    info != null && info.id.isNotEmpty && !info.beyond;

String jumpLabel(FirstUnread? info, [ChatNavTr? t]) {
  if (info == null) return '';
  if (info.beyond) return _tr(t, ChatNavStrings.jumpFirst);
  return _fill(_tr(t, ChatNavStrings.nNew), {'n': info.count});
}

bool showJump(FirstUnread? info, bool dividerAbove, bool dismissed) =>
    info != null && info.id.isNotEmpty && dividerAbove && !dismissed;

class ChatJump {
  const ChatJump._();

  static const double bottomPx = 48;
  static const double landPx = 8;
  static const int markMax = 200;
  static const int storeMax = 300;
  static const int storeIds = 50;

  static Map<String, num> toJson() => {
        'bottomPx': bottomPx,
        'landPx': landPx,
        'markMax': markMax,
        'storeMax': storeMax,
        'storeIds': storeIds,
      };
}

class ChatFabs {
  const ChatFabs._();

  static const List<String> order = ['mention', 'jump', 'bottom'];
  static const double gap = 8;
  static const double right = 24;
  static const double rightPhone = 16;
  static const double rightColumn = 16;
  static const double phoneMax = 768;
  static const double floatBottom = 16;

  static Map<String, Object> toJson() => {
        'order': order,
        'gap': gap,
        'right': right,
        'rightPhone': rightPhone,
        'rightColumn': rightColumn,
        'phoneMax': phoneMax,
        'floatBottom': floatBottom,
      };
}

int markIndexBy(int count, num Function(int i) bottomAt, num viewTop, num viewBottom) {
  final vt = _num(viewTop), vb = _num(viewBottom);
  if (!(vb > vt) || count <= 0) return -1;
  var lo = 0, hi = count - 1, hit = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (_num(bottomAt(mid)) <= vb) {
      hit = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return hit >= 0 && _num(bottomAt(hit)) > vt ? hit : -1;
}

int markIndex(List<Object?> bottoms, num viewTop, num viewBottom) =>
    markIndexBy(bottoms.length, (i) => _num(bottoms[i]), viewTop, viewBottom);

int effectiveAt(Object? createdAt, Object? seenAt) {
  final c = _floor(createdAt);
  final s = _floor(seenAt);
  return s > 0 && s < c ? s : c;
}

bool atBottom(Object? distance) => _num(distance).abs() <= ChatJump.bottomPx;

String jumpDir({Object? top, Object? viewTop, Object? at, Object? firstAt}) {
  if (top is num && top.isFinite) {
    return _num(top) - _num(viewTop) - ChatJump.landPx > 0 ? 'down' : 'up';
  }
  return _num(at) < _num(firstAt) ? 'up' : 'down';
}

class SeenMark {
  SeenMark(this.at, [List<String>? ids]) : ids = ids ?? <String>[];

  int at;
  List<String> ids;

  Map<String, Object> toJson() => {'at': at, 'ids': ids};
}

SeenMark markNorm(Object? raw) {
  if (raw is SeenMark) return SeenMark(raw.at, [...raw.ids]);
  final r = raw is Map ? raw : const {};
  var at = _floor(r['at']);
  if (at < 0) at = 0;
  final ids = <String>[];
  final list = r['ids'];
  if (at > 0 && list is List) {
    for (final id in list) {
      if (id is String && id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
  }
  return SeenMark(
      at,
      ids.length > ChatJump.markMax
          ? ids.sublist(ids.length - ChatJump.markMax)
          : ids);
}

SeenMark markFloor(Object? sec) {
  final s = _floor(sec);
  return s > 0 ? SeenMark(s + 1) : SeenMark(0);
}

bool markUnder(Object? mark, Object? at, String id) {
  final m = mark is SeenMark ? mark : markNorm(mark);
  if (!(m.at > 0)) return false;
  final a = _floor(at);
  if (a < m.at) return true;
  return a == m.at && m.ids.contains(id);
}

SeenMark markAdvance(Object? mark, Object? at, Iterable<Object?> ids) {
  final m = markNorm(mark);
  final a = _floor(at);
  if (!(a > 0) || a < m.at) return m;
  if (a > m.at) {
    m.at = a;
    m.ids = <String>[];
  }
  for (final id in ids) {
    if (id is String && id.isNotEmpty && !m.ids.contains(id)) m.ids.add(id);
  }
  if (m.ids.length > ChatJump.markMax) {
    m.ids = m.ids.sublist(m.ids.length - ChatJump.markMax);
  }
  return m;
}

SeenMark markMax(Object? a, Object? b) {
  final x = markNorm(a), y = markNorm(b);
  if (x.at != y.at) return x.at > y.at ? x : y;
  return markAdvance(x, y.at, y.ids);
}

List<String> unseenRows(List<ChatNavRow> list, Object? mark) {
  final out = <String>[];
  final m = markNorm(mark);
  if (!(m.at > 0)) return out;
  for (final r in list) {
    if (r.own || r.sys || r.id.isEmpty) continue;
    if (markUnder(m, r.at, r.id)) continue;
    out.add(r.id);
  }
  return out;
}

int unseenCount(List<ChatNavRow> list, Object? mark) =>
    unseenRows(list, mark).length;

String? unseenFirst(List<ChatNavRow> list, Object? mark) {
  final rows = unseenRows(list, mark);
  return rows.isEmpty ? null : rows.first;
}

String jumpText(Object? count, [ChatNavTr? t]) {
  final n = _floor(count);
  if (n <= 0) return '';
  return _fill(_tr(t, ChatNavStrings.nNew), {'n': n});
}

Map<String, Map<String, Object>> markStoreNorm(Object? raw) {
  final out = <String, Map<String, Object>>{};
  if (raw is! Map) return out;
  final keys = [
    for (final k in raw.keys)
      if ('$k'.isNotEmpty && raw[k] is Map) '$k',
  ];
  keys.sort((a, b) {
    final d = _num((raw[b] as Map)['t']).compareTo(_num((raw[a] as Map)['t']));
    return d != 0 ? d : _cmp(a, b);
  });
  for (final k in keys.take(ChatJump.storeMax)) {
    final src = raw[k] as Map;
    final m = markNorm(src);
    if (!(m.at > 0)) continue;
    final t = _floor(src['t']);
    out[k] = {
      'at': m.at,
      'ids': m.ids.length > ChatJump.storeIds
          ? m.ids.sublist(m.ids.length - ChatJump.storeIds)
          : m.ids,
      't': t < 0 ? 0 : t,
    };
  }
  return out;
}

List<String> fabRow({bool bottom = false, bool jump = false, bool mention = false}) {
  final v = {'bottom': bottom, 'jump': jump, 'mention': mention};
  return [for (final k in ChatFabs.order) if (v[k] == true) k];
}

double fabRight(num width, bool column) {
  if (column) return ChatFabs.rightColumn;
  final w = _num(width);
  return w > 0 && w <= ChatFabs.phoneMax ? ChatFabs.rightPhone : ChatFabs.right;
}

Map<String, dynamic> emptyMentions() =>
    <String, dynamic>{'v': 1, 'chats': <String, dynamic>{}};

Map<String, dynamic> _normMentionChat(Object? raw) {
  final c = raw is Map ? raw : null;
  final ids = <Map<String, dynamic>>[];
  final seenIds = <String>{};
  final rawIds = c?['ids'];
  if (rawIds is List) {
    for (final e in rawIds) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! String || id.isEmpty || seenIds.contains(id)) continue;
      seenIds.add(id);
      final at = _floor(e['at']);
      ids.add(<String, dynamic>{'id': id, 'at': at < 0 ? 0 : at});
    }
  }
  final seen = <String>[];
  final rawSeen = c?['seen'];
  if (rawSeen is List) {
    for (final s in rawSeen) {
      if (s is String && s.isNotEmpty && !seen.contains(s)) seen.add(s);
    }
  }
  ids.sort((a, b) {
    final d = (a['at'] as int) - (b['at'] as int);
    return d != 0 ? d : _cmp(a['id'] as String, b['id'] as String);
  });
  final keepSeen = seen.length > ChatNavLimits.mentionSeenMax
      ? seen.sublist(seen.length - ChatNavLimits.mentionSeenMax)
      : seen;
  final t = _num(c?['t']);
  return <String, dynamic>{'ids': ids, 'seen': keepSeen, 't': t < 0 ? 0 : t};
}

Map<String, dynamic> normalizeMentions(Object? raw) {
  final out = emptyMentions();
  if (raw is! Map) return out;
  final chats = raw['chats'];
  if (chats is! Map) return out;
  final dst = out['chats'] as Map<String, dynamic>;
  for (final k in chats.keys) {
    final key = '$k';
    if (key.isEmpty) continue;
    dst[key] = _normMentionChat(chats[k]);
  }
  return out;
}

Map<String, dynamic> _chats(Map<String, dynamic> s) =>
    s['chats'] as Map<String, dynamic>;

Map<String, dynamic> _pruneMentions(Map<String, dynamic> state) {
  final chats = _chats(state);
  final keys = chats.keys.toList();
  if (keys.length <= ChatNavLimits.mentionChatsMax) return state;
  keys.sort((a, b) {
    final d = _num(chats[b]['t']).compareTo(_num(chats[a]['t']));
    return d != 0 ? d : _cmp(a, b);
  });
  final keep = <String, dynamic>{};
  for (final k in keys.take(ChatNavLimits.mentionChatsMax)) {
    keep[k] = chats[k];
  }
  state['chats'] = keep;
  return state;
}

List<Map<String, dynamic>> _ids(Map<String, dynamic> c) =>
    (c['ids'] as List).cast<Map<String, dynamic>>();

List<String> _seen(Map<String, dynamic> c) =>
    (c['seen'] as List).cast<String>();

Map<String, dynamic> mentionAdd(Map<String, dynamic>? state, String key,
    List<Map<String, dynamic>> items, num nowMs) {
  final s = normalizeMentions(state);
  if (key.isEmpty || items.isEmpty) return s;
  final c = (_chats(s)[key] as Map<String, dynamic>?) ?? _normMentionChat(null);
  final ids = _ids(c);
  final have = ids.map((e) => e['id'] as String).toSet();
  final seen = _seen(c).toSet();
  var changed = false;
  for (final it in items) {
    final id = it['id'];
    if (id is! String || id.isEmpty) continue;
    if (have.contains(id) || seen.contains(id)) continue;
    have.add(id);
    final at = _floor(it['at']);
    ids.add(<String, dynamic>{'id': id, 'at': at < 0 ? 0 : at});
    changed = true;
  }
  if (!changed) return s;
  ids.sort((a, b) {
    final d = (a['at'] as int) - (b['at'] as int);
    return d != 0 ? d : _cmp(a['id'] as String, b['id'] as String);
  });
  if (ids.length > ChatNavLimits.mentionPerChatMax) {
    c['ids'] = ids.sublist(ids.length - ChatNavLimits.mentionPerChatMax);
  } else {
    c['ids'] = ids;
  }
  c['t'] = _num(nowMs);
  _chats(s)[key] = c;
  return _pruneMentions(s);
}

void _markSeen(Map<String, dynamic> c, List<String> ids) {
  final seen = _seen(c).toList();
  for (final id in ids) {
    seen.remove(id);
    seen.add(id);
  }
  c['seen'] = seen.length > ChatNavLimits.mentionSeenMax
      ? seen.sublist(seen.length - ChatNavLimits.mentionSeenMax)
      : seen;
}

Map<String, dynamic> mentionSeen(
    Map<String, dynamic>? state, String key, String id, num nowMs) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  if (c == null || id.isEmpty) return s;
  c['ids'] = _ids(c).where((e) => e['id'] != id).toList();
  _markSeen(c, [id]);
  c['t'] = _num(nowMs);
  return s;
}

Map<String, dynamic> mentionMark(
    Map<String, dynamic>? state, String key, Object? mark, num nowMs) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  if (c == null || _ids(c).isEmpty) return s;
  final m = markNorm(mark);
  final drop = [
    for (final e in _ids(c))
      if (markUnder(m, e['at'], e['id'] as String)) e['id'] as String,
  ];
  if (drop.isEmpty) return s;
  c['ids'] = _ids(c).where((e) => !drop.contains(e['id'])).toList();
  _markSeen(c, drop);
  c['t'] = _num(nowMs);
  return s;
}

Map<String, dynamic> mentionClear(
    Map<String, dynamic>? state, String key, num nowMs) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  if (c == null || _ids(c).isEmpty) return s;
  _markSeen(c, _ids(c).map((e) => e['id'] as String).toList());
  c['ids'] = <Map<String, dynamic>>[];
  c['t'] = _num(nowMs);
  return s;
}

Map<String, dynamic> mentionPrune(
    Map<String, dynamic>? state, String key, num floorSec) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  final f = _num(floorSec);
  if (c == null || !(f > 0)) return s;
  final ids = _ids(c);
  final drop = ids
      .where((e) => (e['at'] as int) <= f)
      .map((e) => e['id'] as String)
      .toList();
  if (drop.isEmpty) return s;
  c['ids'] = ids.where((e) => (e['at'] as int) > f).toList();
  _markSeen(c, drop);
  return s;
}

Map<String, dynamic> mentionDrop(
    Map<String, dynamic>? state, String key, List<String> ids) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  if (c == null || ids.isEmpty) return s;
  final gone = ids.toSet();
  c['ids'] = _ids(c).where((e) => !gone.contains(e['id'])).toList();
  return s;
}

String? mentionNext(Map<String, dynamic>? state, String key) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  if (c == null) return null;
  final ids = _ids(c);
  return ids.isEmpty ? null : ids.first['id'] as String;
}

int mentionCount(Map<String, dynamic>? state, String key) {
  final s = normalizeMentions(state);
  final c = _chats(s)[key] as Map<String, dynamic>?;
  return c == null ? 0 : _ids(c).length;
}

List<Map<String, dynamic>> mentionScan(
    List<ChatNavRow> list, num floorSec, num beforeSec) {
  final out = <Map<String, dynamic>>[];
  final f = _num(floorSec);
  final b = _num(beforeSec);
  for (final m in list) {
    if (!m.mention || m.own || m.sys || m.id.isEmpty) continue;
    if (m.at <= f) continue;
    if (b > 0 && m.at > b) continue;
    out.add(<String, dynamic>{'id': m.id, 'at': m.at.floor()});
  }
  return out;
}

String pinKey(String kind, Object? id) {
  final raw = (id == null ? '' : '$id').trim();
  if (kind == 'dm') {
    final pk = raw.toLowerCase();
    return _rxHex64.hasMatch(pk) ? 'd:$pk' : '';
  }
  if (kind == 'group') {
    final g = raw.toLowerCase();
    return _rxGroup.hasMatch(g) ? 'g:$g' : '';
  }
  if (kind == 'channel') {
    final c = raw.replaceFirst(RegExp(r'^#'), '').toLowerCase();
    return _rxChannel.hasMatch(c) ? 'c:$c' : '';
  }
  return '';
}

({String kind, String id})? pinParse(Object? k) {
  final s = k == null ? '' : '$k';
  if (s.startsWith('d:') && _rxHex64.hasMatch(s.substring(2))) {
    return (kind: 'dm', id: s.substring(2));
  }
  if (s.startsWith('g:') && _rxGroup.hasMatch(s.substring(2))) {
    return (kind: 'group', id: s.substring(2));
  }
  if (s.startsWith('c:') && _rxChannel.hasMatch(s.substring(2))) {
    return (kind: 'channel', id: s.substring(2));
  }
  return null;
}

String pinKeyForChat(String chatKey) {
  if (chatKey.startsWith('pm-')) return pinKey('dm', chatKey.substring(3));
  if (chatKey.startsWith('group-')) {
    return pinKey('group', chatKey.substring(6));
  }
  return pinKey('channel', chatKey);
}

String chatKeyForPin(String k) {
  final p = pinParse(k);
  if (p == null) return '';
  if (p.kind == 'dm') return 'pm-${p.id}';
  if (p.kind == 'group') return 'group-${p.id}';
  return p.id;
}

Map<String, dynamic> emptyPins() => <String, dynamic>{
      'v': 1,
      'order': <String>[],
      'ot': 0,
      'items': <String, int>{},
      'removed': <String, int>{},
    };

List<String> _order(Map<String, dynamic> s) =>
    (s['order'] as List).cast<String>();
Map<String, int> _items(Map<String, dynamic> s) =>
    (s['items'] as Map).cast<String, int>();
Map<String, int> _removed(Map<String, dynamic> s) =>
    (s['removed'] as Map).cast<String, int>();

Map<String, dynamic> normalizePins(Object? raw) {
  final out = emptyPins();
  if (raw is! Map) return out;
  final items = _items(out);
  final removed = _removed(out);
  final ri = raw['items'];
  if (ri is Map) {
    ri.forEach((k, v) {
      final at = _num(v);
      if (pinParse('$k') != null && at > 0) items['$k'] = at.floor();
    });
  }
  final rr = raw['removed'];
  if (rr is Map) {
    rr.forEach((k, v) {
      final at = _num(v);
      if (pinParse('$k') != null && at > 0) removed['$k'] = at.floor();
    });
  }
  final ro = raw['order'];
  final order = _order(out);
  if (ro is List) {
    for (final k in ro) {
      if (k is String && pinParse(k) != null && !order.contains(k)) {
        order.add(k);
      }
    }
  }
  final ot = _floor(raw['ot']);
  out['ot'] = ot < 0 ? 0 : ot;
  return _finishPins(out, 0);
}

Set<String> _pinnedSet(Map<String, dynamic> s) {
  final set = <String>{};
  final removed = _removed(s);
  _items(s).forEach((k, at) {
    final r = removed[k];
    if (!(r != null && r >= at)) set.add(k);
  });
  return set;
}

Map<String, dynamic> _finishPins(Map<String, dynamic> s, num nowMs) {
  final live = _pinnedSet(s);
  final src = _items(s);
  final items = <String, int>{for (final k in live) k: src[k]!};
  var order = _order(s).where(live.contains).toList();
  final rest = live.where((k) => !order.contains(k)).toList()
    ..sort((a, b) {
      final d = items[b]! - items[a]!;
      return d != 0 ? d : _cmp(a, b);
    });
  order = [...order, ...rest];
  if (order.length > ChatNavLimits.pinHardMax) {
    for (final k in order.sublist(ChatNavLimits.pinHardMax)) {
      items.remove(k);
    }
    order = order.sublist(0, ChatNavLimits.pinHardMax);
  }
  final removed = <String, int>{};
  final cutoff = nowMs > 0 ? nowMs - ChatNavLimits.pinRemovedTtlMs : 0;
  _removed(s).forEach((k, at) {
    if (items.containsKey(k)) return;
    if (cutoff > 0 && at < cutoff) return;
    removed[k] = at;
  });
  final rk = removed.keys.toList();
  if (rk.length > ChatNavLimits.pinRemovedMax) {
    rk.sort((a, b) {
      final d = removed[b]! - removed[a]!;
      return d != 0 ? d : _cmp(a, b);
    });
    for (final k in rk.sublist(ChatNavLimits.pinRemovedMax)) {
      removed.remove(k);
    }
  }
  return <String, dynamic>{
    'v': 1,
    'order': order,
    'ot': s['ot'],
    'items': items,
    'removed': removed,
  };
}

List<String> pinList(Object? state) =>
    List<String>.of(_order(normalizePins(state)));

bool isPinned(Object? state, String k) =>
    _order(normalizePins(state)).contains(k);

int _maxInt(List<num> xs) => xs.reduce((a, b) => a > b ? a : b).floor();

String pinSection(String k) =>
    pinParse(k)?.kind == 'channel' ? 'channel' : 'chat';

({Map<String, dynamic> state, String? error}) pinAdd(
    Object? state, String k, num nowMs,
    {int cap = 0}) {
  final s = normalizePins(state);
  if (pinParse(k) == null) return (state: s, error: 'invalid');
  final order = _order(s);
  if (order.contains(k)) return (state: s, error: null);
  final limit = cap > 0 ? cap : ChatNavLimits.pinMax;
  final section = pinSection(k);
  if (order.where((x) => pinSection(x) == section).length >= limit) {
    return (state: s, error: 'cap');
  }
  final items = _items(s);
  final removed = _removed(s);
  final at = _maxInt([nowMs, (removed[k] ?? 0) + 1, (items[k] ?? 0) + 1]);
  items[k] = at;
  removed.remove(k);
  s['order'] = <String>[k, ...order];
  s['ot'] = _maxInt([nowMs, (s['ot'] as int) + 1]);
  return (state: _finishPins(s, nowMs), error: null);
}

Map<String, dynamic> pinRemove(Object? state, String k, num nowMs) {
  final s = normalizePins(state);
  final order = _order(s);
  if (!order.contains(k)) return s;
  _removed(s)[k] = _maxInt([nowMs, (_items(s)[k] ?? 0) + 1]);
  s['order'] = order.where((x) => x != k).toList();
  s['ot'] = _maxInt([nowMs, (s['ot'] as int) + 1]);
  return _finishPins(s, nowMs);
}

Map<String, dynamic> pinMove(Object? state, String k, num toIndex, num nowMs) {
  final s = normalizePins(state);
  final order = _order(s).toList();
  final from = order.indexOf(k);
  if (from < 0) return s;
  var to = toIndex.floor();
  if (to > order.length - 1) to = order.length - 1;
  if (to < 0) to = 0;
  if (to == from) return s;
  order.removeAt(from);
  order.insert(to, k);
  s['order'] = order;
  s['ot'] = _maxInt([nowMs, (s['ot'] as int) + 1]);
  return _finishPins(s, nowMs);
}

Map<String, dynamic> pinReorderWithin(
    Object? state, List<String> subset, num nowMs) {
  final s = normalizePins(state);
  final order = _order(s);
  final want = subset.where(order.contains).toList();
  if (want.length < 2) return s;
  final slots = <int>[];
  for (var i = 0; i < order.length; i++) {
    if (want.contains(order[i])) slots.add(i);
  }
  final next = order.toList();
  for (var i = 0; i < slots.length; i++) {
    next[slots[i]] = want[i];
  }
  if (next.join('\n') == order.join('\n')) return s;
  s['order'] = next;
  s['ot'] = _maxInt([nowMs, (s['ot'] as int) + 1]);
  return _finishPins(s, nowMs);
}

Map<String, dynamic> mergePins(Object? a, Object? b, num nowMs) {
  final x = normalizePins(a);
  final y = normalizePins(b);
  final items = Map<String, int>.of(_items(x));
  _items(y).forEach((k, at) {
    final cur = items[k];
    if (!(cur != null && cur >= at)) items[k] = at;
  });
  final removed = Map<String, int>.of(_removed(x));
  _removed(y).forEach((k, at) {
    final cur = removed[k];
    if (!(cur != null && cur >= at)) removed[k] = at;
  });
  final xo = x['ot'] as int;
  final yo = y['ot'] as int;
  final Map<String, dynamic> base;
  if (xo != yo) {
    base = xo > yo ? x : y;
  } else {
    base = jsonEncode(_order(x)).compareTo(jsonEncode(_order(y))) >= 0 ? x : y;
  }
  return _finishPins(<String, dynamic>{
    'v': 1,
    'order': List<String>.of(_order(base)),
    'ot': xo > yo ? xo : yo,
    'items': items,
    'removed': removed,
  }, nowMs);
}

Map<String, dynamic> pinImportLegacy(
    Object? state, List<String> channels, num nowMs) {
  final s = normalizePins(state);
  var changed = false;
  final items = _items(s);
  final removed = _removed(s);
  final order = _order(s);
  for (final c in channels) {
    final k = pinKey('channel', c);
    if (k.isEmpty || k == 'c:nymchat') continue;
    if (items.containsKey(k) || removed.containsKey(k)) continue;
    items[k] = 1;
    order.add(k);
    changed = true;
  }
  return changed ? _finishPins(s, nowMs) : s;
}

List<String> pinChannels(Object? state) {
  final out = <String>[];
  for (final k in _order(normalizePins(state))) {
    final p = pinParse(k);
    if (p != null && p.kind == 'channel') out.add(p.id);
  }
  return out;
}

List<String> pinSort(List<String> keys, Object? state) {
  final order = _order(normalizePins(state));
  final pos = <String, int>{
    for (var i = 0; i < order.length; i++) order[i]: i
  };
  final list = <({String k, int i, int p})>[
    for (var i = 0; i < keys.length; i++)
      (k: keys[i], i: i, p: pos[pinKeyForChat(keys[i])] ?? -1),
  ];
  list.sort((a, b) {
    if (a.p >= 0 && b.p >= 0) return a.p - b.p;
    if (a.p >= 0) return -1;
    if (b.p >= 0) return 1;
    return a.i - b.i;
  });
  return [for (final e in list) e.k];
}

bool trimPinnedPayload(Map<String, dynamic> p) {
  final s = p['pinnedChats'];
  if (s is! Map) return false;
  final removed = s['removed'];
  final rk = removed is Map ? removed.keys.map((k) => '$k').toList() : <String>[];
  if (rk.length > 20 && removed is Map) {
    rk.sort((a, b) => _num(removed[a]).compareTo(_num(removed[b])));
    for (final k in rk.take((rk.length / 4).ceil())) {
      removed.remove(k);
    }
    return true;
  }
  final order = s['order'];
  if (order is List) {
    final seen = <String, int>{'channel': 0, 'chat': 0};
    final keep = [];
    final drop = [];
    for (final k in order) {
      final sec = pinSection('$k');
      if (seen[sec]! < ChatNavLimits.pinMax) {
        seen[sec] = seen[sec]! + 1;
        keep.add(k);
      } else {
        drop.add(k);
      }
    }
    if (drop.isEmpty) return false;
    s['order'] = keep;
    final items = s['items'];
    if (items is Map) {
      for (final k in drop) {
        items.remove(k);
      }
    }
    return true;
  }
  return false;
}

String? scheduleCheck(num atSec, num nowSec) {
  final at = _num(atSec);
  final now = _num(nowSec);
  if (!(at > 0) || at <= now) return 'past';
  if (at < now + ChatNavLimits.scheduleMinLeadSec) return 'soon';
  if (at > now + ChatNavLimits.scheduleMaxAheadSec) return 'far';
  return null;
}

String scheduleErrorText(String? code, [ChatNavTr? t]) {
  const map = {
    'past': ChatNavStrings.past,
    'soon': ChatNavStrings.soon,
    'far': ChatNavStrings.far,
    'full': ChatNavStrings.full,
    'big': ChatNavStrings.tooBig,
  };
  final s = map[code];
  return s == null ? '' : _tr(t, s);
}

({int y, int mo, int d, int h, int mi, int wd}) _localParts(
    num ms, num offsetMin) {
  final dt = DateTime.fromMillisecondsSinceEpoch(
      (ms + offsetMin * 60000).floor(),
      isUtc: true);
  return (
    y: dt.year,
    mo: dt.month - 1,
    d: dt.day,
    h: dt.hour,
    mi: dt.minute,
    wd: dt.weekday % 7,
  );
}

int _localToSec(int y, int mo, int d, int h, int mi, num offsetMin) {
  final ms = DateTime.utc(y, mo + 1, d, h, mi).millisecondsSinceEpoch;
  return ((ms - offsetMin * 60000) / 1000).floor();
}

List<({String id, int at})> schedulePresets(num nowMs, num offsetMin) {
  final nowSec = (nowMs / 1000).floor();
  final p = _localParts(nowMs, offsetMin);
  final out = <({String id, int at})>[];
  final hour = ((nowSec + 3600) / 60).ceil() * 60;
  out.add((id: 'hour', at: hour));
  final tonight = _localToSec(p.y, p.mo, p.d, 21, 0, offsetMin);
  if (scheduleCheck(tonight, nowSec) == null && tonight > hour) {
    out.add((id: 'tonight', at: tonight));
  }
  final tomorrow = _localToSec(p.y, p.mo, p.d + 1, 9, 0, offsetMin);
  out.add((id: 'tomorrow', at: tomorrow));
  var ahead = ((1 - p.wd) + 7) % 7;
  if (ahead == 0) ahead = 7;
  final monday = _localToSec(p.y, p.mo, p.d + ahead, 9, 0, offsetMin);
  if (monday != tomorrow) out.add((id: 'monday', at: monday));
  return out;
}

String scheduleInputValue(num atSec, num offsetMin) {
  final p = _localParts(atSec * 1000, offsetMin);
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${p.y}-${pad(p.mo + 1)}-${pad(p.d)}T${pad(p.h)}:${pad(p.mi)}';
}

int scheduleParseInput(String? value, num offsetMin) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})$')
      .firstMatch((value ?? '').trim());
  if (m == null) return 0;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!) - 1;
  final d = int.parse(m.group(3)!);
  final h = int.parse(m.group(4)!);
  final mi = int.parse(m.group(5)!);
  if (mo < 0 || mo > 11 || d < 1 || d > 31 || h > 23 || mi > 59) return 0;
  return _localToSec(y, mo, d, h, mi, offsetMin);
}

int wrapTime(num atSec, num r) {
  var f = _num(r).toDouble();
  if (f < 0) f = 0;
  if (f > 0.999999) f = 0.999999;
  final v = _num(atSec) - f * ChatNavLimits.wrapJitterSec;
  return (v + 0.5).floor();
}

List<String> scheduleRelays(List<Object?> list) {
  final out = <String>[];
  for (final raw in list) {
    if (raw is! String) continue;
    final u = Uri.tryParse(raw.trim());
    if (u == null || u.scheme != 'wss' || u.host.isEmpty) continue;
    final host = u.hasPort ? '${u.host.toLowerCase()}:${u.port}' : u.host.toLowerCase();
    final path = u.path.isNotEmpty && u.path != '/'
        ? u.path.replaceFirst(RegExp(r'/+$'), '')
        : '';
    final s = 'wss://$host$path';
    if (!out.contains(s)) out.add(s);
    if (out.length >= ChatNavLimits.scheduleMaxRelays) break;
  }
  return out;
}

String? scheduleSizeError(List<Object?> events, num noteLen) {
  if (events.isEmpty) return 'empty';
  if (events.length > ChatNavLimits.scheduleMaxEvents) return 'big';
  var total = 0;
  for (final e in events) {
    final inner = e is Map && e['e'] != null ? e['e'] : e;
    final n = jsonEncode(inner).length;
    if (n > ChatNavLimits.scheduleMaxEventBytes) return 'big';
    total += n;
  }
  total += _num(noteLen).floor();
  if (total > ChatNavLimits.scheduleMaxItemBytes) return 'big';
  return null;
}

String scheduleNoteJson(String text, Map<String, String> chat) {
  final t = text.length > ChatNavLimits.scheduleTextMax
      ? text.substring(0, ChatNavLimits.scheduleTextMax)
      : text;
  return jsonEncode(<String, dynamic>{
    'v': 1,
    'text': t,
    'chat': {'t': chat['t'] ?? '', 'k': chat['k'] ?? ''},
  });
}

({String text, Map<String, String> chat})? scheduleNoteParse(String json) {
  try {
    final o = jsonDecode(json);
    if (o is! Map || o['v'] != 1 || o['text'] is! String) return null;
    final c = o['chat'] is Map ? o['chat'] as Map : const {};
    return (
      text: o['text'] as String,
      chat: {'t': '${c['t'] ?? ''}', 'k': '${c['k'] ?? ''}'},
    );
  } catch (_) {
    return null;
  }
}

String scheduleChatKey(Map<String, String> chat) {
  final t = chat['t'] ?? '';
  final k = chat['k'] ?? '';
  if (t == 'dm') return 'pm-${k.toLowerCase()}';
  if (t == 'group') return 'group-$k';
  if (t == 'channel') return '#${k.replaceFirst(RegExp(r'^#'), '').toLowerCase()}';
  return '';
}

Map<String, String> scheduleChatOf(String chatKey) {
  if (chatKey.startsWith('pm-')) {
    return {'t': 'dm', 'k': chatKey.substring(3).toLowerCase()};
  }
  if (chatKey.startsWith('group-')) {
    return {'t': 'group', 'k': chatKey.substring(6)};
  }
  return {
    't': 'channel',
    'k': chatKey.replaceFirst(RegExp(r'^#'), '').toLowerCase()
  };
}

class ScheduledItem {
  ScheduledItem({
    required this.id,
    required this.at,
    required this.chat,
    required this.status,
    this.attempts = 0,
    this.error = '',
    this.sentAt = 0,
    this.note = '',
    this.text = '',
  });

  final String id;
  final int at;
  final Map<String, String> chat;
  final String status;
  final int attempts;
  final String error;
  final int sentAt;
  final String note;
  String text;

  bool get open =>
      status == 'pending' || status == 'sending' || status == 'failed';

  Map<String, dynamic> toJson({bool withText = false}) => <String, dynamic>{
        'id': id,
        'at': at,
        'chat': {'t': chat['t'] ?? '', 'k': chat['k'] ?? ''},
        'status': status,
        'attempts': attempts,
        'error': error,
        'sentAt': sentAt,
        'note': note,
        if (withText) 'text': text,
      };
}

List<ScheduledItem> scheduleNormalize(List<Object?> items) {
  final out = <ScheduledItem>[];
  for (final it in items) {
    if (it is! Map) continue;
    final id = it['id'];
    if (id is! String || id.isEmpty) continue;
    final st = it['status'];
    final status = chatNavStatuses.contains(st) ? st as String : 'pending';
    final chat = it['chat'] is Map ? it['chat'] as Map : const {};
    out.add(ScheduledItem(
      id: id,
      at: _floor(it['at']),
      chat: {'t': '${chat['t'] ?? ''}', 'k': '${chat['k'] ?? ''}'},
      status: status,
      attempts: _floor(it['attempts']),
      error: it['error'] is String ? it['error'] as String : '',
      sentAt: _floor(it['sentAt']),
      note: it['note'] is String ? it['note'] as String : '',
      text: it['text'] is String ? it['text'] as String : '',
    ));
  }
  out.sort((a, b) {
    final d = a.at - b.at;
    return d != 0 ? d : _cmp(a.id, b.id);
  });
  return out;
}

List<ScheduledItem> scheduleForChat(List<Object?> items, String chatKey) =>
    scheduleNormalize(items)
        .where((it) =>
            scheduleChatKey(it.chat) == chatKey && it.status != 'cancelled')
        .toList();

int scheduleOpenCount(List<Object?> items, String chatKey) =>
    scheduleForChat(items, chatKey)
        .where((it) =>
            it.status == 'pending' ||
            it.status == 'sending' ||
            it.status == 'failed')
        .length;

String scheduleStatusText(String status, [ChatNavTr? t]) {
  const map = {
    'pending': ChatNavStrings.pending,
    'sending': ChatNavStrings.sending,
    'sent': ChatNavStrings.sent,
    'failed': ChatNavStrings.failed,
    'cancelled': ChatNavStrings.cancelled,
  };
  return _tr(t, map[status] ?? ChatNavStrings.pending);
}

String? scheduleBlockReason({
  required bool meshOnly,
  required bool server,
  required bool online,
  required String kind,
  required bool localKey,
}) {
  if (meshOnly) return ChatNavStrings.meshBlocked;
  if (!server) return ChatNavStrings.serverBlocked;
  if (!online) return ChatNavStrings.offlineBlocked;
  if ((kind == 'dm' || kind == 'group') && !localKey) {
    return ChatNavStrings.signerBlocked;
  }
  return null;
}

String scheduleId(List<int> bytes) {
  final b = StringBuffer();
  for (var i = 0; i < bytes.length && i < 16; i++) {
    b.write((bytes[i] & 255).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

List<List<String>> groupSubjectTags(Object? name) =>
    name is String && name.isNotEmpty
        ? [
            ['subject', name]
          ]
        : const [];
