import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../models/message.dart';
import '../chat_tools/chat_tools_service.dart';
import 'chat_nav.dart';

class ChatNavEntry {
  ChatNavEntry({
    required this.key,
    required this.lastRead,
    required this.openedAt,
    required this.openedMs,
    required this.mark,
  }) : base = mark.at;

  final String key;
  final int lastRead;
  final int openedAt;
  final int openedMs;
  final int base;
  SeenMark mark;
  FirstUnread? info;
  bool landed = false;
  bool scrolled = false;
}

class ScheduleResult {
  const ScheduleResult(this.ok, {this.reason, this.id});
  final bool ok;
  final String? reason;
  final String? id;
}

class ScheduleApiError implements Exception {
  ScheduleApiError(this.message, {this.code = '', this.status = 0});
  final String message;
  final String code;
  final int status;
  @override
  String toString() => message;
}

typedef ScheduleBuild = ({
  List<Map<String, dynamic>> events,
  List<String> relays,
});

class ChatNavBlockContext {
  const ChatNavBlockContext({
    required this.meshOnly,
    required this.server,
    required this.online,
    required this.localKey,
  });
  final bool meshOnly;
  final bool server;
  final bool online;
  final bool localKey;
}

class ChatNavHooks {
  const ChatNavHooks({
    required this.selfPubkey,
    this.online = _never,
    this.hydrated = _always,
    this.syncAllowed = _always,
    this.publishPinned,
    this.legacyPinnedChannels,
    this.applyPinnedChannels,
    this.storeList,
    this.lastRead,
    this.badge,
    this.isMention,
    this.isOpen,
    this.scheduleApi,
    this.buildScheduled,
    this.encryptNote,
    this.decryptNote,
    this.blockContext,
    this.sendText,
    this.groupSendBlocked,
    this.notice,
    this.onChanged,
    this.now,
    this.random,
    this.storeRaw,
    this.plainlyVisible,
  });

  static bool _never() => false;
  static bool _always() => true;

  final String Function() selfPubkey;
  final bool Function() online;
  final bool Function() hydrated;
  final bool Function() syncAllowed;
  final Future<bool> Function(Map<String, dynamic> pinned)? publishPinned;
  final List<String> Function()? legacyPinnedChannels;
  final void Function(List<String> channels, bool persist)? applyPinnedChannels;
  final List<Message> Function(String key)? storeList;
  final List<Message> Function(String key)? storeRaw;
  final bool Function(Message m)? plainlyVisible;
  final int Function(String key)? lastRead;
  final int Function(String key)? badge;
  final bool Function(Message m)? isMention;
  final bool Function(String key)? isOpen;
  final Future<Map<String, dynamic>> Function(
      String action, Map<String, dynamic> body)? scheduleApi;
  final Future<ScheduleBuild> Function(
      String key, String text, int at, String? threadRoot)? buildScheduled;
  final Future<String?> Function(String json)? encryptNote;
  final Future<String?> Function(String blob)? decryptNote;
  final ChatNavBlockContext Function(String key)? blockContext;
  final Future<bool> Function(String key, String text)? sendText;
  final String? Function(String key, String text)? groupSendBlocked;
  final void Function(String text)? notice;
  final void Function()? onChanged;
  final int Function()? now;
  final Random? random;
}

String chatNavFill(String s, Map<String, Object?> vars) {
  var out = s;
  vars.forEach((k, v) => out = out.split('{$k}').join('$v'));
  return out;
}

class ChatNavService {
  ChatNavService(this._prefs, this.hooks, {String Function(String)? tr})
      : _tr = tr ?? ((s) => s);

  final ChatToolsPrefs _prefs;
  final ChatNavHooks hooks;
  final String Function(String) _tr;

  int get _nowMs => hooks.now?.call() ?? DateTime.now().millisecondsSinceEpoch;
  int get _nowSec => _nowMs ~/ 1000;

  String t(String s, [Map<String, Object?>? vars]) =>
      vars == null ? _tr(s) : chatNavFill(_tr(s), vars);

  void _changed() => hooks.onChanged?.call();

  void _notice(String text) => hooks.notice?.call(text);

  final Map<String, ChatNavEntry> _entries = {};

  ChatNavEntry? entry(String key) => _entries[key];

  bool hasEntry(String key) => _entries.containsKey(key);

  ChatNavEntry? capture(String key) {
    if (key.isEmpty) return null;
    final have = _entries[key];
    if (have != null) return have;
    final lastRead = hooks.lastRead?.call(key) ?? 0;
    final e = ChatNavEntry(
      key: key,
      lastRead: lastRead,
      openedAt: _nowSec,
      openedMs: _nowMs,
      mark: markMax(storedMark(key), markFloor(lastRead)),
    );
    _entries[key] = e;
    _scanOnOpen(e);
    return e;
  }

  void release(String key) {
    final e = _entries.remove(key);
    if (e == null) return;
    try {
      _saveMark(key, e.mark);
      flushMarks();
    } on StateError catch (_) {}
    _changed();
  }

  ChatNavRow _row(Message m, {bool mention = false}) => ChatNavRow(
        id: m.id,
        at: effAt(m),
        own: m.isOwn || (m.pubkey.isNotEmpty && m.pubkey == hooks.selfPubkey()),
        sys: m.pubkey.isEmpty || m.isSystemRow,
        mention: mention,
      );

  bool _isMention(Message m) {
    if (m.isOwn || m.pubkey.isEmpty || m.isSystemRow) return false;
    return hooks.isMention?.call(m) ?? false;
  }

  List<Message> _store(String key) => hooks.storeList?.call(key) ?? const [];

  String get _firstSeenKey => 'nym_seen_first:${hooks.selfPubkey()}';

  Map<String, int>? _firstSeenCache;
  String? _firstSeenPk;

  Map<String, int> get _firstSeen {
    final pk = hooks.selfPubkey();
    if (_firstSeenCache != null && _firstSeenPk == pk) return _firstSeenCache!;
    final out = <String, int>{};
    try {
      final raw = _prefs.read(_firstSeenKey);
      final m = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      if (m is Map) {
        m.forEach((k, v) {
          if (k is String && v is num && v > 0) out[k] = v.toInt();
        });
      }
    } catch (_) {}
    _firstSeenPk = pk;
    return _firstSeenCache = out;
  }

  int effAt(Message m) {
    final seen = _firstSeen[m.id];
    if (seen != null) return effectiveAt(m.createdAt, seen);
    if (m.createdAt <= _nowSec) return m.createdAt;
    final map = _firstSeen;
    while (map.length >= 500) {
      map.remove(map.keys.first);
    }
    map[m.id] = _nowSec;
    _markDirty = true;
    return effectiveAt(m.createdAt, _nowSec);
  }

  String get _markKey => '${ChatNavKeys.seenMarks}:${hooks.selfPubkey()}';

  Map<String, Map<String, Object>>? _markCache;
  String? _markPk;
  bool _markDirty = false;
  int _markWritten = 0;

  Map<String, Map<String, Object>> _marks() {
    final pk = hooks.selfPubkey();
    if (_markCache != null && _markPk == pk) return _markCache!;
    Map<String, Map<String, Object>> m;
    try {
      final raw = _prefs.read(_markKey);
      m = raw == null || raw.isEmpty ? {} : markStoreNorm(jsonDecode(raw));
    } catch (_) {
      m = {};
    }
    _markPk = pk;
    return _markCache = m;
  }

  SeenMark storedMark(String key) => markNorm(_marks()[key]);

  void _saveMark(String key, SeenMark mark) {
    if (key.isEmpty || !(mark.at > 0)) return;
    final store = _marks();
    final prev = markNorm(store[key]);
    if (prev.at == mark.at && prev.ids.length == mark.ids.length) return;
    store[key] = {'at': mark.at, 'ids': [...mark.ids], 't': _nowMs};
    _markDirty = true;
    if (_nowMs - _markWritten >= 2000) flushMarks();
  }

  void flushMarks() {
    if (!_markDirty) return;
    _markDirty = false;
    _markWritten = _nowMs;
    _prefs.write(_markKey, jsonEncode(markStoreNorm(_marks())));
    _prefs.write(_firstSeenKey, jsonEncode(_firstSeen));
  }

  SeenMark? markFor(String key) => _entries[key]?.mark;

  List<String> unseenFor(String key, [List<Message>? list]) {
    final e = _entries[key];
    if (e == null || !(e.mark.at > 0)) return const [];
    final src = list ?? _store(key);
    final tail = <ChatNavRow>[];
    for (var i = src.length - 1; i >= 0; i--) {
      final m = src[i];
      if (m.createdAt >= e.mark.at) tail.add(_row(m));
    }
    if (tail.isEmpty) return const [];
    return unseenRows(tail.reversed.toList(), e.mark);
  }

  int jumpCountFor(String key, [List<Message>? list]) =>
      unseenFor(key, list).length;

  String? jumpTargetFor(String key, [List<Message>? list]) {
    final u = unseenFor(key, list);
    return u.isEmpty ? null : u.first;
  }

  String jumpTextFor(String key, [List<Message>? list]) =>
      jumpText(jumpCountFor(key, list), _tr);

  bool advance(String key, num at, Iterable<String> ids) {
    final e = _entries[key];
    if (e == null) return false;
    final next = markAdvance(e.mark, at, ids);
    if (next.at == e.mark.at && next.ids.length == e.mark.ids.length) {
      return false;
    }
    e.mark = next;
    _saveMark(key, next);
    final ms = mentions();
    final after = mentionMark(ms, key, next, _nowMs);
    if (mentionCount(after, key) != mentionCount(ms, key)) _setMentions(after);
    return true;
  }

  bool seeAll(String key, [List<Message>? list]) {
    final e = _entries[key];
    if (e == null) return false;
    final src = list ?? _store(key);
    var changed = false;
    if (src.isNotEmpty) {
      var newest = effAt(src.first);
      for (final m in src) {
        final at = effAt(m);
        if (at > newest) newest = at;
      }
      changed = advance(key, newest, [
        for (final m in src)
          if (effAt(m) == newest) m.id,
      ]);
    }
    if (mentionCountFor(key) > 0) {
      _setMentions(mentionClear(mentions(), key, _nowMs));
      changed = true;
    }
    return changed;
  }

  FirstUnread? infoFor(String key, [List<Message>? list]) {
    final e = _entries[key];
    if (e == null) return null;
    if (e.info != null || e.landed || e.base <= 0) return e.info;
    final src = list ?? _store(key);
    final id = jumpTargetFor(key, src);
    if (id == null) return null;
    final i = src.indexWhere((m) => m.id == id);
    if (i < 0) return null;
    final seen = _firstSeen[id];
    if (src[i].createdAt > e.openedAt && (seen == null || seen >= e.openedAt)) {
      return null;
    }
    e.info = FirstUnread(
        id: id, index: i, count: jumpCountFor(key, src), beyond: false);
    _rescanFor(e, list);
    return e.info;
  }

  void _rescanFor(ChatNavEntry e, List<Message>? list) {
    final items = mentionScan(
        [for (final m in list ?? _store(e.key)) _row(m, mention: _isMention(m))],
        e.lastRead,
        e.openedAt);
    if (items.isNotEmpty) _setMentions(mentionAdd(mentions(), e.key, items, _nowMs));
  }

  bool shouldLand(String key) {
    final e = _entries[key];
    if (e == null || e.landed || e.scrolled) return false;
    if (!landOnDivider(e.info)) return false;
    return _nowMs - e.openedMs < 8000;
  }

  void markLanded(String key) => _entries[key]?.landed = true;

  void markScrolled(String key) => _entries[key]?.scrolled = true;

  String get _mentionKey => 'nym_unread_mentions:${hooks.selfPubkey()}';

  Map<String, dynamic>? _mentionCache;
  String? _mentionPk;
  Timer? _mentionTimer;

  Map<String, dynamic> mentions() {
    final pk = hooks.selfPubkey();
    if (_mentionCache != null && _mentionPk == pk) return _mentionCache!;
    Map<String, dynamic> s;
    try {
      final raw = _prefs.read(_mentionKey);
      s = raw == null || raw.isEmpty
          ? emptyMentions()
          : normalizeMentions(jsonDecode(raw));
    } catch (_) {
      s = emptyMentions();
    }
    _mentionCache = s;
    _mentionPk = pk;
    return s;
  }

  void _setMentions(Map<String, dynamic> s) {
    _mentionCache = s;
    _mentionPk = hooks.selfPubkey();
    _mentionTimer ??= Timer(const Duration(milliseconds: 400), () {
      _mentionTimer = null;
      _prefs.write(_mentionKey, jsonEncode(mentions()));
    });
    _changed();
  }

  void flushMentions() {
    _mentionTimer?.cancel();
    _mentionTimer = null;
    _prefs.write(_mentionKey, jsonEncode(mentions()));
  }

  void _scanOnOpen(ChatNavEntry e) {
    final items = mentionScan(
        [for (final m in _store(e.key)) _row(m, mention: _isMention(m))],
        e.lastRead,
        e.openedAt);
    if (items.isNotEmpty) {
      _setMentions(mentionAdd(mentions(), e.key, items, _nowMs));
    }
  }

  int mentionCountFor(String key) => mentionCount(mentions(), key);

  String? nextMention(String key) => mentionNext(mentions(), key);

  List<String> queuedMentionIds(String key) {
    final c = (mentions()['chats'] as Map)[key];
    if (c is! Map) return const [];
    return [for (final e in c['ids'] as List) (e as Map)['id'] as String];
  }

  bool hasUnreadMention(String key, {List<String> aliases = const []}) {
    if (mentionCountFor(key) > 0) return true;
    if (_entries.containsKey(key)) return false;
    if (hooks.isOpen?.call(key) ?? false) return false;
    var unread = hooks.badge?.call(key) ?? 0;
    for (final a in aliases) {
      final n = hooks.badge?.call(a) ?? 0;
      if (n > unread) unread = n;
    }
    if (unread <= 0) return false;
    final floor = hooks.lastRead?.call(key) ?? 0;
    final fast = _rawMentionScan(key, floor);
    if (fast != null) return fast;
    final list = _store(key);
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.createdAt <= floor) break;
      if (_isMention(m)) return true;
    }
    return false;
  }

  bool? _rawMentionScan(String key, int floor) {
    final raw = hooks.storeRaw;
    final plain = hooks.plainlyVisible;
    if (raw == null || plain == null) return null;
    final list = raw(key);
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.createdAt <= floor) {
        if (plain(m)) return false;
        return null;
      }
      if (_isMention(m)) return plain(m) ? true : null;
    }
    return false;
  }

  void noteLive(String key, Message m, {required bool away}) {
    final e = _entries[key];
    final row = _row(m);
    if (row.own) {
      if (e != null) advance(key, row.at, [m.id]);
      return;
    }
    if (!away || !_isMention(m)) return;
    if (e != null && markUnder(e.mark, row.at, m.id)) return;
    _setMentions(mentionAdd(mentions(), key, [
      {'id': m.id, 'at': row.at}
    ], _nowMs));
  }

  void markMentionsSeen(String key, Iterable<String> ids) {
    final queued = queuedMentionIds(key).toSet();
    var s = mentions();
    var changed = false;
    for (final id in ids) {
      if (!queued.contains(id)) continue;
      s = mentionSeen(s, key, id, _nowMs);
      changed = true;
    }
    if (changed) _setMentions(s);
  }

  void dropMention(String key, String id) =>
      _setMentions(mentionDrop(mentions(), key, [id]));

  void pruneRemoteRead(String key, int floorSec) {
    if (_entries.containsKey(key)) return;
    if (mentionCountFor(key) == 0) return;
    _setMentions(mentionPrune(mentions(), key, floorSec));
  }

  String get _pinKey => '${ChatNavKeys.pinned}:${hooks.selfPubkey()}';
  String get _pinPendingKey => '${ChatNavKeys.pinnedPending}:${hooks.selfPubkey()}';

  Map<String, dynamic>? _pinCache;
  String? _pinPk;
  int _pinRev = 0;
  bool _pinSyncing = false;
  bool _pinResync = false;

  Map<String, dynamic> pinState() {
    final pk = hooks.selfPubkey();
    if (_pinCache != null && _pinPk == pk) return _pinCache!;
    Map<String, dynamic> s;
    try {
      final raw = _prefs.read(_pinKey);
      s = raw == null || raw.isEmpty ? emptyPins() : normalizePins(jsonDecode(raw));
    } catch (_) {
      s = emptyPins();
    }
    _pinCache = s;
    _pinPk = pk;
    return s;
  }

  void _persistPins(Map<String, dynamic> s) {
    _pinCache = s;
    _pinPk = hooks.selfPubkey();
    _prefs.write(_pinKey, jsonEncode(s));
  }

  bool get pinPending => _prefs.read(_pinPendingKey) == '1';

  void _setPinPending(bool on) {
    if (on) {
      _prefs.write(_pinPendingKey, '1');
    } else {
      _prefs.remove(_pinPendingKey);
    }
  }

  List<String> get pinnedKeys => pinList(pinState());

  bool isChatPinned(String key) => isPinned(pinState(), key);

  int pinIndexOfChat(String chatKey) {
    final k = pinKeyForChat(chatKey);
    return k.isEmpty ? -1 : pinnedKeys.indexOf(k);
  }

  bool togglePin(String key) {
    if (pinParse(key) == null) return false;
    if (key == 'c:nymchat') {
      _notice(t('#nymchat is always at the top'));
      return false;
    }
    var s = pinState();
    if (isPinned(s, key)) {
      s = pinRemove(s, key, _nowMs);
    } else {
      final r = pinAdd(s, key, _nowMs);
      if (r.error == 'cap') {
        _notice(t(ChatNavStrings.pinCap, {'n': ChatNavLimits.pinMax}));
        return false;
      }
      s = r.state;
    }
    _commitPins(s);
    return true;
  }

  List<String> _sameList(String key) {
    final p = pinParse(key);
    if (p == null) return const [];
    final isChannel = p.kind == 'channel';
    return pinnedKeys
        .where((k) => (pinParse(k)?.kind == 'channel') == isChannel)
        .toList();
  }

  bool canMovePin(String key, int dir) {
    final same = _sameList(key);
    final i = same.indexOf(key);
    final j = i + dir;
    return i >= 0 && j >= 0 && j < same.length;
  }

  void movePin(String key, int dir) {
    if (!canMovePin(key, dir)) return;
    final same = _sameList(key);
    final i = same.indexOf(key);
    same.removeAt(i);
    same.insert(i + dir, key);
    _commitPins(pinReorderWithin(pinState(), same, _nowMs));
  }

  bool canDropPin(String fromKey, String toKey) {
    if (fromKey == toKey) return false;
    final pins = pinnedKeys;
    if (!pins.contains(fromKey) || !pins.contains(toKey)) return false;
    final a = pinParse(fromKey);
    final b = pinParse(toKey);
    if (a == null || b == null) return false;
    return (a.kind == 'channel') == (b.kind == 'channel');
  }

  void dropPin(String fromKey, String toKey) {
    if (!canDropPin(fromKey, toKey)) return;
    final next = _sameList(fromKey).where((k) => k != fromKey).toList();
    next.insert(next.indexOf(toKey), fromKey);
    _commitPins(pinReorderWithin(pinState(), next, _nowMs));
  }

  void _commitPins(Map<String, dynamic> s) {
    _persistPins(s);
    _pinRev++;
    _setPinPending(hooks.syncAllowed());
    _applyPins(true);
    unawaited(syncPins());
  }

  void _applyPins(bool persist) {
    hooks.applyPinnedChannels?.call(pinChannels(pinState()), persist);
    _changed();
  }

  void afterLegacyChange() {
    final legacy = hooks.legacyPinnedChannels?.call() ?? const <String>[];
    final s = pinState();
    final next = pinImportLegacy(s, legacy, _nowMs);
    if (!identical(next, s)) {
      _persistPins(next);
      _pinRev++;
      _setPinPending(hooks.syncAllowed());
      Timer.run(() => unawaited(syncPins()));
    }
    _applyPins(false);
  }

  void applyRemotePinned(dynamic remote) {
    if (remote is! Map) return;
    final merged = mergePins(pinState(), remote, _nowMs);
    final remoteNorm = mergePins(remote, null, _nowMs);
    _persistPins(merged);
    _pinRev++;
    if (jsonEncode(merged) != jsonEncode(remoteNorm) && hooks.syncAllowed()) {
      _setPinPending(true);
      Timer.run(() => unawaited(syncPins()));
    }
    _applyPins(true);
  }

  Future<bool> syncPins() async {
    if (_disposed || !hooks.syncAllowed()) return false;
    if (!pinPending) return true;
    final publish = hooks.publishPinned;
    if (publish == null || !hooks.online() || !hooks.hydrated()) return false;
    if (_pinSyncing) {
      _pinResync = true;
      return false;
    }
    _pinSyncing = true;
    _pinResync = false;
    final rev = _pinRev;
    var ok = false;
    try {
      ok = await publish(jsonDecode(jsonEncode(pinState())) as Map<String, dynamic>);
    } catch (_) {
      ok = false;
    } finally {
      _pinSyncing = false;
    }
    if (ok && rev == _pinRev) _setPinPending(false);
    if (_pinResync || (ok && rev != _pinRev)) {
      _pinResync = false;
      return syncPins();
    }
    return !pinPending;
  }

  String get _schedKey => '${ChatNavKeys.scheduled}:${hooks.selfPubkey()}';

  List<ScheduledItem>? _sched;
  String? _schedPk;
  Timer? _refreshTimer;
  final Map<String, ({String text, Map<String, String> chat})?> _noteCache = {};

  List<ScheduledItem> scheduledItems() {
    final pk = hooks.selfPubkey();
    if (_sched != null && _schedPk == pk) return _sched!;
    var items = <ScheduledItem>[];
    try {
      final raw = _prefs.read(_schedKey);
      if (raw != null && raw.isNotEmpty) {
        final v = jsonDecode(raw);
        if (v is List) items = scheduleNormalize(v.cast<Object?>());
      }
    } catch (_) {
      items = [];
    }
    _sched = items;
    _schedPk = pk;
    return items;
  }

  void _setScheduled(List<ScheduledItem> items) {
    _sched = items;
    _schedPk = hooks.selfPubkey();
    _prefs.write(
        _schedKey, jsonEncode([for (final x in items) x.toJson(withText: true)]));
    _changed();
  }

  List<Map<String, dynamic>> _rawItems() =>
      [for (final x in scheduledItems()) x.toJson(withText: true)];

  List<ScheduledItem> scheduledFor(String key) {
    final byId = {for (final x in scheduledItems()) x.id: x.text};
    return [
      for (final x in scheduleForChat(_rawItems(), key)) x..text = byId[x.id] ?? ''
    ];
  }

  int scheduledOpenCount(String key) => scheduleOpenCount(_rawItems(), key);

  String? blockReason(String key) {
    if (key.isEmpty) return t(ChatNavStrings.serverBlocked);
    final kind = key.startsWith('pm-')
        ? 'dm'
        : key.startsWith('group-')
            ? 'group'
            : 'channel';
    final ctx = hooks.blockContext?.call(key) ??
        const ChatNavBlockContext(
            meshOnly: false, server: false, online: false, localKey: false);
    final r = scheduleBlockReason(
      meshOnly: ctx.meshOnly,
      server: ctx.server,
      online: ctx.online,
      kind: kind,
      localKey: ctx.localKey,
    );
    return r == null ? null : t(r);
  }

  String _errorText(Object err) {
    if (err is ScheduleApiError) {
      final mapped = scheduleErrorText(err.code, _tr);
      if (mapped.isNotEmpty) return mapped;
      return t("Couldn't schedule it: {error}", {'error': err.message});
    }
    return t("Couldn't schedule it: {error}", {'error': '$err'});
  }

  Future<ScheduleResult> schedule(String key, String text, int at,
      {String? replaces, String? threadRoot}) async {
    final content = text.trim();
    if (content.isEmpty) return const ScheduleResult(false);
    ScheduleResult refuse(String msg) {
      _notice(msg);
      return ScheduleResult(false, reason: msg);
    }

    final block = blockReason(key);
    if (block != null) return refuse(block);
    if (content.startsWith('/')) return refuse(t("Commands can't be scheduled."));
    final check = scheduleCheck(at, _nowSec);
    if (check != null) return refuse(scheduleErrorText(check, _tr));
    if (key.startsWith('group-')) {
      final blocked = hooks.groupSendBlocked?.call(key, content);
      if (blocked != null) return refuse(blocked);
    }
    final build = hooks.buildScheduled;
    final api = hooks.scheduleApi;
    if (build == null || api == null) return refuse(t(ChatNavStrings.serverBlocked));
    ScheduleBuild built;
    try {
      built = await build(key, content, at, threadRoot);
    } catch (_) {
      return refuse(t("Couldn't prepare the message to schedule."));
    }
    final chat = scheduleChatOf(key);
    String? note;
    try {
      note = await hooks.encryptNote?.call(scheduleNoteJson(content, chat));
    } catch (_) {
      note = null;
    }
    if (note == null) return refuse(t(ChatNavStrings.signerBlocked));
    if (scheduleSizeError(built.events, note.length) != null) {
      return refuse(t(ChatNavStrings.tooBig));
    }
    final rng = hooks.random ?? Random.secure();
    final id = scheduleId([for (var i = 0; i < 16; i++) rng.nextInt(256)]);
    final body = <String, dynamic>{
      'id': id,
      'at': at,
      'events': built.events,
      'relays': built.relays,
      'note': note,
      'replaces': ?replaces,
    };
    try {
      await api('schedule-add', body);
    } catch (err) {
      return refuse(_errorText(err));
    }
    final items = scheduledItems().where((x) => x.id != replaces).toList()
      ..add(ScheduledItem(
          id: id, at: at, chat: chat, status: 'pending', note: note, text: content));
    _noteCache[note] = (text: content, chat: chat);
    _setScheduled(scheduleNormalize([for (final x in items) x.toJson(withText: true)]));
    _notice(t('Scheduled for {time}. Held by Nymchat until it sends.',
        {'time': formatScheduleTime(at)}));
    _armRefresh();
    return ScheduleResult(true, id: id);
  }

  Future<({String text, Map<String, String> chat})?> _openNote(String blob) async {
    if (blob.isEmpty) return null;
    if (_noteCache.containsKey(blob)) return _noteCache[blob];
    ({String text, Map<String, String> chat})? parsed;
    try {
      final json = await hooks.decryptNote?.call(blob);
      parsed = json == null ? null : scheduleNoteParse(json);
    } catch (_) {
      parsed = null;
    }
    _noteCache[blob] = parsed;
    return parsed;
  }

  Future<List<ScheduledItem>> refreshScheduled() async {
    final api = hooks.scheduleApi;
    if (api == null || hooks.selfPubkey().isEmpty) return scheduledItems();
    Map<String, dynamic> data;
    try {
      data = await api('schedule-list', const {});
    } catch (_) {
      return scheduledItems();
    }
    final prev = {for (final x in scheduledItems()) x.id: x};
    final raw = data['items'];
    final out = <ScheduledItem>[];
    for (final it in scheduleNormalize(raw is List ? raw.cast<Object?>() : const [])) {
      final old = prev[it.id];
      var text = old?.text ?? '';
      var chat = (old != null && (old.chat['t'] ?? '').isNotEmpty) ? old.chat : null;
      if (text.isEmpty || chat == null) {
        final p = await _openNote(it.note);
        if (p != null) {
          text = p.text;
          chat = p.chat;
        }
      }
      if (chat == null) continue;
      out.add(ScheduledItem(
        id: it.id,
        at: it.at,
        chat: chat,
        status: it.status,
        attempts: it.attempts,
        error: it.error,
        sentAt: it.sentAt,
        note: it.note,
        text: text,
      ));
    }
    _setScheduled(out);
    _armRefresh();
    return out;
  }

  void _armRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final open = scheduledItems()
        .where((x) => x.status == 'pending' || x.status == 'sending')
        .toList();
    if (open.isEmpty) return;
    final next = open.map((x) => x.at).reduce(min);
    var wait = (next - _nowSec) * 1000 + 15000;
    if (wait < 5000) wait = 5000;
    if (wait > 60000) wait = 60000;
    _refreshTimer = Timer(Duration(milliseconds: wait), () {
      _refreshTimer = null;
      unawaited(refreshScheduled());
    });
  }

  Future<bool> cancelScheduled(String id) async {
    final api = hooks.scheduleApi;
    if (api == null) return false;
    try {
      final r = await api('schedule-cancel', {'id': id});
      if (r['removed'] == true || r['status'] == 'gone') {
        _setScheduled(scheduledItems().where((x) => x.id != id).toList());
        return true;
      }
    } catch (err) {
      final msg = err is ScheduleApiError ? err.message : '$err';
      _notice(t("Couldn't cancel it: {error}", {'error': msg}));
      unawaited(refreshScheduled());
      return false;
    }
    return false;
  }

  Future<bool> sendScheduledNow(String id) async {
    ScheduledItem? it;
    for (final x in scheduledItems()) {
      if (x.id == id) it = x;
    }
    if (it == null || it.text.isEmpty) return false;
    if (!hooks.online()) {
      _notice(t("You're offline. Try again when you're back online."));
      return false;
    }
    if (!await cancelScheduled(id)) return false;
    final send = hooks.sendText;
    if (send == null) return false;
    return send(scheduleChatKey(it.chat), it.text);
  }

  Future<ScheduleResult> reschedule(String id, int at) async {
    ScheduledItem? it;
    for (final x in scheduledItems()) {
      if (x.id == id) it = x;
    }
    if (it == null || it.text.isEmpty) return const ScheduleResult(false);
    return schedule(scheduleChatKey(it.chat), it.text, at, replaces: id);
  }

  String scheduleFailText(ScheduledItem it) {
    const map = {
      'spam': 'The spam filter held it back.',
      'relays': 'No relay accepted it.',
      'late': 'It was too late to send.',
      'partial': 'Some copies may not have arrived.',
      'retry': 'Retrying.',
    };
    final s = map[it.error];
    return s == null ? '' : t(s);
  }

  String formatScheduleTime(int at) {
    final d = DateTime.fromMillisecondsSinceEpoch(at * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String presetLabel(String id, int at) {
    final d = DateTime.fromMillisecondsSinceEpoch(at * 1000);
    final time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    const map = {
      'hour': 'In 1 hour',
      'tonight': 'Tonight at {time}',
      'tomorrow': 'Tomorrow at {time}',
      'monday': 'Monday at {time}',
    };
    return t(map[id] ?? '{time}', {'time': time});
  }

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_mentionTimer != null) flushMentions();
    try {
      flushMarks();
    } on StateError catch (_) {}
  }
}
