import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../models/message.dart';
import '../chat_tools/chat_tools_service.dart';
import '../sync/sync_merge.dart' show marksMerge;
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
  const ScheduleResult(this.ok, {this.reason, this.id, this.code});
  final bool ok;
  final String? reason;
  final String? id;
  final String? code;
}

const _signerRetryMs = 10 * 60 * 1000;

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
    this.hardcore = false,
  });
  final bool meshOnly;
  final bool server;
  final bool online;
  final bool localKey;
  final bool hardcore;
}

class ChatNavHooks {
  const ChatNavHooks({
    required this.selfPubkey,
    this.selfWrapPq2,
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
    this.sendNowRefusal,
    this.restoreText,
    this.localNoteKey,
    this.groupSendBlocked,
    this.laneRefusal,
    this.notice,
    this.undoNotice,
    this.chatName,
    this.onChanged,
    this.now,
    this.random,
    this.storeRaw,
    this.plainlyVisible,
    this.messageHidden,
    this.scanEpoch,
    this.replyVisible,
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
  final bool Function(Message m)? messageHidden;
  final Object? Function()? scanEpoch;
  final bool Function(Message m, bool rootLocal)? replyVisible;
  final bool Function()? selfWrapPq2;
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
  final Future<bool> Function(String key, String text,
      {String? threadRoot, String? quoteSource})? sendText;
  final Future<String?> Function(String key, String text,
      {String? threadRoot, String? quoteSource, bool quiet})? sendNowRefusal;
  final Future<String> Function(String key, String text)? restoreText;
  final bool Function()? localNoteKey;
  final String? Function(String key, String text)? groupSendBlocked;
  final String? Function(String key, String? threadRoot, String? quoteSource,
      {bool composer})? laneRefusal;
  final void Function(String text)? notice;
  final void Function(String text, void Function() undo)? undoNotice;
  final String Function(String kind, String id)? chatName;
  final void Function()? onChanged;
  final int Function()? now;
  final Random? random;
}

String _threadKey(Message m) =>
    (m.isPM || m.isGroup) ? (m.nymMessageId ?? m.id) : m.id;

class _IdEntry {
  _IdEntry(this.m)
      : id = m.id,
        nid = m.nymMessageId,
        root = m.threadRoot == null ? _threadKey(m) : null,
        replyTo = m.threadRoot;

  final Message m;
  final String id;
  final String? nid;
  final String? root;
  final String? replyTo;
}

class _IdIndex {
  _IdIndex(this.list) : edits = _chatNavEdits[list] ?? 0 {
    _chatNavTrims[list] = null;
    for (final m in list) {
      _put(m);
    }
  }

  static const int _reach = 256;

  final List<Message> list;
  final List<_IdEntry> seq = [];
  final Map<String, Message> byId = {};
  final Map<String, int> roots = {};
  final Map<String, int> replies = {};
  final int edits;
  int orphans = 0;
  bool clash = false;

  bool hasRoot(String root) => (roots[root] ?? 0) > 0;

  bool hasReplies(String root) => (replies[root] ?? 0) > 0;

  void _key(String k, Message m) {
    if (k.isEmpty) return;
    final had = byId[k];
    if (had != null && !identical(had, m)) clash = true;
    byId[k] = m;
  }

  void _put(Message m) {
    final e = _IdEntry(m);
    _key(e.id, m);
    final nid = e.nid;
    if (nid != null) _key(nid, m);
    final root = e.root;
    if (root != null && root.isNotEmpty) roots[root] = (roots[root] ?? 0) + 1;
    final to = e.replyTo;
    if (to != null) replies[to] = (replies[to] ?? 0) + 1;
    seq.add(e);
  }

  void _count(Map<String, int> map, String k) {
    final n = (map[k] ?? 0) - 1;
    if (n > 0) {
      map[k] = n;
    } else {
      map.remove(k);
    }
  }

  void _drop(_IdEntry e) {
    if (identical(byId[e.id], e.m)) byId.remove(e.id);
    final nid = e.nid;
    if (nid != null && identical(byId[nid], e.m)) byId.remove(nid);
    final root = e.root;
    if (root != null && root.isNotEmpty) _count(roots, root);
    final to = e.replyTo;
    if (to != null) _count(replies, to);
  }

  bool sync(List<Message> raw) {
    final trimmed = _chatNavTrims[raw];
    _chatNavTrims[raw] = null;
    if (!identical(raw, list) || clash) return false;
    if ((_chatNavEdits[raw] ?? 0) != edits) return false;
    final n = seq.length;
    if (n == 0) {
      if (raw.isEmpty) return true;
      return false;
    }
    final last = seq[n - 1];
    var p = -1;
    for (var i = raw.length - 1; i >= 0 && i >= raw.length - _reach; i--) {
      if (identical(raw[i], last.m)) {
        p = i;
        break;
      }
    }
    if (p < 0 || raw[p].id != last.id) return false;
    final d = n - 1 - p;
    if (d < 0 || d > _reach) return false;
    if (trimmed != null && trimmed != d) return false;
    final gone = <int>[];
    var i = 0;
    var j = 0;
    while (gone.length < d) {
      if (j >= n || j > _reach) return false;
      final e = seq[j];
      if (i <= p && identical(raw[i], e.m)) {
        if (raw[i].id != e.id) return false;
        i++;
      } else {
        gone.add(j);
      }
      j++;
    }
    if (i <= p && (!identical(raw[i], seq[j].m) || raw[i].id != seq[j].id)) {
      return false;
    }
    final lost = [for (final k in gone) seq[k]];
    for (var k = gone.length - 1; k >= 0; k--) {
      _drop(seq[gone[k]]);
      seq.removeAt(gone[k]);
    }
    for (final e in lost) {
      final root = e.root;
      if (root != null && root.isNotEmpty && hasReplies(root) && !hasRoot(root)) {
        orphans++;
      }
    }
    for (var i = p + 1; i < raw.length; i++) {
      _put(raw[i]);
    }
    return !clash;
  }
}

final Expando<int> _chatNavTrims = Expando<int>('chatNavTrims');
final Expando<int> _chatNavDrops = Expando<int>('chatNavDrops');
final Expando<int> _chatNavEdits = Expando<int>('chatNavEdits');

void chatNavNoteTrim(List<Message> list, int dropped) {
  if (dropped <= 0) return;
  _chatNavTrims[list] = (_chatNavTrims[list] ?? 0) + dropped;
  _chatNavDrops[list] = (_chatNavDrops[list] ?? 0) + dropped;
}

void chatNavNoteEdit(List<Message> list) {
  _chatNavEdits[list] = (_chatNavEdits[list] ?? 0) + 1;
}

class _ClosedScan {
  _ClosedScan(this.epoch, this.floor, List<Message> raw, this.value,
      {this.hit, this.idx})
      : list = raw,
        len = raw.length,
        last = raw.isEmpty ? null : raw.last,
        lastId = raw.isEmpty ? null : raw.last.id,
        lastAt = raw.isEmpty ? 0 : raw.last.createdAt,
        edits = _chatNavEdits[raw] ?? 0,
        drops = _chatNavDrops[raw] ?? 0,
        orphans = idx?.orphans ?? 0;

  final Object? epoch;
  final int floor;
  final List<Message> list;
  final int len;
  final Message? last;
  final String? lastId;
  final int lastAt;
  final bool value;
  final Message? hit;
  final _IdIndex? idx;
  final int edits;
  final int drops;
  final int orphans;
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

  void release(String key, {bool quiet = false}) {
    final e = _entries.remove(key);
    if (e == null) return;
    final hook = onMarksChanged;
    if (quiet) onMarksChanged = null;
    try {
      _saveMark(key, e.mark);
      flushMarks();
    } on StateError catch (_) {
    } finally {
      if (quiet) onMarksChanged = hook;
    }
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

  void Function()? onMarksChanged;

  bool Function(String key, num at, Iterable<String> ids)? quietAdvance;

  Map<String, Map<String, Object>> marksForSync() => markStoreNorm(_marks());

  void applyRemoteMarks(Object? raw) {
    final cur = marksForSync();
    final merged = marksMerge(cur, raw);
    if (jsonEncode(merged) == jsonEncode(cur)) return;
    final store = _marks();
    store
      ..clear()
      ..addAll(merged);
    _markDirty = true;
    _markWritten = _nowMs;
    _prefs.write(_markKey, jsonEncode(markStoreNorm(store)));
    var ms = mentions();
    var changed = false;
    merged.forEach((k, m) {
      if (_entries.containsKey(k)) return;
      final next = mentionMark(ms, k, m, _nowMs);
      if (mentionCount(next, k) != mentionCount(ms, k)) {
        ms = next;
        changed = true;
      }
    });
    if (changed) _setMentions(ms);
  }

  void _saveMark(String key, SeenMark incoming) {
    if (key.isEmpty || !(incoming.at > 0)) return;
    final store = _marks();
    final prev = markNorm(store[key]);
    final mark = markMax(prev, incoming);
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
    onMarksChanged?.call();
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

  bool advance(String key, num at, Iterable<String> ids, {bool sweep = true}) {
    final e = _entries[key];
    if (e == null) return false;
    final next = markAdvance(e.mark, at, ids);
    if (next.at == e.mark.at && next.ids.length == e.mark.ids.length) {
      return false;
    }
    e.mark = next;
    final hush = quietAdvance?.call(key, at, ids) ?? false;
    final hook = onMarksChanged;
    if (hush) onMarksChanged = null;
    try {
      _saveMark(key, next);
    } finally {
      if (hush) onMarksChanged = hook;
    }
    if (sweep) sweepMentions(key);
    return true;
  }

  void sweepMentions(String key) {
    final e = _entries[key];
    if (e == null) return;
    final ms = mentions();
    final after = mentionMark(ms, key, e.mark, _nowMs);
    if (mentionCount(after, key) != mentionCount(ms, key)) _setMentions(after);
  }

  bool seeAll(String key, [List<Message>? list, bool shown = true]) {
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
      changed = advance(
          key,
          newest,
          [
            for (final m in src)
              if (effAt(m) == newest) m.id,
          ],
          sweep: shown);
    }
    if (shown && mentionCountFor(key) > 0) {
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
    final pk = _mentionPk;
    final s = _mentionCache;
    if (pk == null || s == null) return;
    _prefs.write('nym_unread_mentions:$pk', jsonEncode(s));
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

  int mentionCountFor(String key) => mentionCount(_shownMentions(key), key);

  String? nextMention(String key) => mentionNext(_shownMentions(key), key);

  List<String> queuedMentionIds(String key) =>
      _queuedIds(_shownMentions(key), key);

  List<String> _queuedIds(Map<String, dynamic> s, String key) {
    final c = (s['chats'] as Map)[key];
    if (c is! Map) return const [];
    return [for (final e in c['ids'] as List) (e as Map)['id'] as String];
  }

  final Map<String, _IdIndex> _idIndexes = {};

  _IdIndex _idIndexOf(String key, List<Message> raw) {
    final had = _idIndexes[key];
    if (had != null && had.sync(raw)) return had;
    final next = _IdIndex(raw);
    _idIndexes[key] = next;
    return next;
  }

  Map<String, dynamic> _shownMentions(String key) {
    final s = mentions();
    final hidden = hooks.messageHidden;
    final raw = hooks.storeRaw;
    if (hidden == null || raw == null) return s;
    final ids = _queuedIds(s, key);
    if (ids.isEmpty) return s;
    final list = raw(key);
    final idx = _idIndexOf(key, list);
    var byId = idx.byId;
    if (idx.clash) {
      byId = <String, Message>{};
      for (final m in list) {
        byId[m.id] = m;
        final n = m.nymMessageId;
        if (n != null && n.isNotEmpty) byId[n] = m;
      }
    }
    final reply = hooks.replyVisible;
    bool off(Message m) {
      if (hidden(m)) return true;
      final root = m.threadRoot;
      return reply != null && root != null && !reply(m, idx.hasRoot(root));
    }
    final gone = [
      for (final id in ids)
        if (byId[id] != null && off(byId[id]!)) id,
    ];
    return gone.isEmpty ? s : mentionDrop(s, key, gone);
  }

  final Map<String, _ClosedScan> _closedScans = {};
  Message? _scanHit;

  bool hasUnreadMention(String key, {List<String> aliases = const []}) {
    if (mentionCountFor(key) > 0) return true;
    if (_entries.containsKey(key) || (hooks.isOpen?.call(key) ?? false)) {
      _closedScans.remove(key);
      return false;
    }
    var unread = hooks.badge?.call(key) ?? 0;
    for (final a in aliases) {
      final n = hooks.badge?.call(a) ?? 0;
      if (n > unread) unread = n;
    }
    if (unread <= 0) return false;
    final floor = hooks.lastRead?.call(key) ?? 0;
    final epoch = hooks.scanEpoch?.call();
    final raw = epoch == null ? null : hooks.storeRaw?.call(key);
    if (raw != null) {
      final hit = _closedScanStep(key, raw, floor, epoch);
      if (hit != null) return hit;
    }
    _scanHit = null;
    final (value, keep) = _closedFullScan(key, floor);
    if (raw != null) {
      if (keep) {
        _closedScans[key] = _ClosedScan(epoch, floor, raw, value,
            hit: value ? _scanHit : null, idx: _idIndexOf(key, raw));
      } else {
        _closedScans.remove(key);
      }
    }
    return value;
  }

  bool? _closedScanStep(String key, List<Message> raw, int floor, Object? epoch) {
    final b = _closedScans[key];
    if (b == null || b.epoch != epoch || b.floor != floor) return null;
    if (!identical(b.list, raw) || (_chatNavEdits[raw] ?? 0) != b.edits) {
      return null;
    }
    final dropped = (_chatNavDrops[raw] ?? 0) - b.drops;
    final p = b.len - dropped;
    if (dropped < 0 || p < 0 || raw.length < p) return null;
    if (b.len > 0) {
      if (p == 0) return null;
      final tail = raw[p - 1];
      if (!identical(tail, b.last) || tail.id != b.lastId) return null;
    }
    if (raw.length == p && dropped == 0) return b.value;
    var value = b.value;
    var hit = b.hit;
    final idx = hooks.replyVisible == null && dropped == 0
        ? null
        : _idIndexOf(key, raw);
    if (dropped > 0) {
      if (idx == null || idx.clash || !identical(idx, b.idx)) return null;
      if (idx.orphans != b.orphans) return null;
      if (value && (hit == null || !identical(idx.byId[hit.id], hit))) {
        return null;
      }
    }
    if (idx != null) {
      for (var i = p; i < raw.length; i++) {
        final m = raw[i];
        if (m.threadRoot == null && idx.hasReplies(_threadKey(m))) return null;
      }
    }
    if (!value) {
      final plain = hooks.plainlyVisible;
      if (plain == null) return null;
      var at = b.lastAt;
      for (var i = p; i < raw.length; i++) {
        final m = raw[i];
        if (m.createdAt < at) return null;
        at = m.createdAt;
        if (m.createdAt <= floor || !_isMention(m)) continue;
        final shown = plain(m) ? true : _replyShown(idx, m);
        if (shown == null) return null;
        if (!shown) continue;
        value = true;
        hit = m;
        break;
      }
    }
    _closedScans[key] = _ClosedScan(epoch, floor, raw, value,
        hit: value ? hit : null, idx: idx ?? b.idx);
    return value;
  }

  (bool, bool) _closedFullScan(String key, int floor) {
    final fast = _rawMentionScan(key, floor);
    if (fast != null) return (fast, true);
    final list = _store(key);
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.createdAt <= floor) break;
      if (_isMention(m)) return (true, false);
    }
    return (false, true);
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
      if (_isMention(m)) {
        final shown = plain(m) ? true : _replyShown(_replyIndex(key, list), m);
        if (shown == null) return null;
        if (shown) {
          _scanHit = m;
          return true;
        }
      }
    }
    return false;
  }

  _IdIndex? _replyIndex(String key, List<Message> raw) =>
      hooks.replyVisible == null ? null : _idIndexOf(key, raw);

  bool? _replyShown(_IdIndex? idx, Message m) {
    final reply = hooks.replyVisible;
    final root = m.threadRoot;
    if (idx == null || reply == null || root == null || m.expiresAt != null) {
      return null;
    }
    return reply(m, idx.hasRoot(root));
  }

  void noteLive(String key, Message m,
      {required bool away, bool shown = true}) {
    final e = _entries[key];
    final row = _row(m);
    if (row.own) {
      if (e != null) advance(key, row.at, [m.id], sweep: shown);
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

  void pruneHiddenMentions() => _changed();

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
      final index = pinList(s).indexOf(key);
      _commitPins(pinRemove(s, key, _nowMs));
      final p = pinParse(key)!;
      hooks.undoNotice?.call(
        p.kind == 'channel'
            ? t(ChatNavStrings.unfavorited, {'channel': p.id})
            : t(ChatNavStrings.unfavoritedChat,
                {'name': hooks.chatName?.call(p.kind, p.id) ?? p.id}),
        () => restorePin(key, index),
      );
      return true;
    } else {
      final r = pinAdd(s, key, _nowMs, pq2: _wrapPq2);
      if (r.error == 'cap') {
        final isChannel = pinParse(key)!.kind == 'channel';
        _notice(t(
            isChannel ? ChatNavStrings.favoriteCap : ChatNavStrings.favoriteChatCap,
            {'n': isChannel ? ChatNavLimits.pinChannelMax : ChatNavLimits.pinMax}));
        return false;
      }
      if (r.error == 'size') {
        _notice(t(ChatNavStrings.favoriteFull));
        return false;
      }
      s = r.state;
    }
    _commitPins(s);
    return true;
  }

  bool get _wrapPq2 => hooks.selfWrapPq2?.call() ?? true;

  void restorePin(String key, int index) {
    final s = pinState();
    if (isPinned(s, key)) return;
    final r = pinAdd(s, key, _nowMs, pq2: _wrapPq2);
    if (r.error != null) return;
    _commitPins(pinMove(r.state, key, index, _nowMs));
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
  final Map<String, ScheduleNote> _noteCache = {};
  final Map<String, int> _noteRetryAt = {};
  final List<Map<String, dynamic>> _journal = [];
  final Set<String> _sendingNow = {};
  int _seq = 0;
  int _req = 0;
  int _applied = 0;

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

  List<ScheduledItem> _itemsFor(String pk) {
    if (pk == hooks.selfPubkey()) return scheduledItems();
    try {
      final raw = _prefs.read('${ChatNavKeys.scheduled}:$pk');
      if (raw != null && raw.isNotEmpty) {
        final v = jsonDecode(raw);
        if (v is List) return scheduleNormalize(v.cast<Object?>());
      }
    } catch (_) {}
    return [];
  }

  void _setItemsFor(String pk, List<ScheduledItem> items) {
    if (pk == hooks.selfPubkey()) {
      _setScheduled(items);
      return;
    }
    _prefs.write('${ChatNavKeys.scheduled}:$pk',
        jsonEncode([for (final x in items) x.toJson(withText: true)]));
  }

  void _setToken(String pk, String id, String token) {
    _setItemsFor(pk, [
      for (final x in _itemsFor(pk))
        if (x.id == id) (x..sendToken = token) else x,
    ]);
  }

  void _dropItem(String pk, String id) {
    _mutate({'t': 'drop', 'id': id}, pk: pk);
    _setItemsFor(pk, _itemsFor(pk).where((x) => x.id != id).toList());
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
      hardcore: ctx.hardcore,
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

  void _mutate(Map<String, dynamic> entry, {String? pk}) {
    _seq++;
    _journal.add({'seq': _seq, 'pk': pk ?? hooks.selfPubkey(), ...entry});
    if (_journal.length > 200) _journal.removeRange(0, _journal.length - 200);
  }

  static ScheduledItem _keep(ScheduledItem it, Map<String, dynamic> src) {
    final q = src['quote'];
    return it
      ..text = src['text'] is String ? src['text'] as String : ''
      ..threadRoot = src['threadRoot'] is String ? src['threadRoot'] as String : ''
      ..quote = q is Map ? {for (final e in q.entries) '${e.key}': '${e.value}'} : null
      ..quoteSource =
          src['quoteSource'] is String ? src['quoteSource'] as String : '';
  }

  Future<ScheduleResult> schedule(String key, String text, int at,
      {String? replaces,
      String? threadRoot,
      Map<String, String>? quote,
      String? quoteSource,
      bool quiet = false,
      bool stored = false}) async {
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
    final laneBlocked = hooks.laneRefusal
        ?.call(key, threadRoot, quoteSource, composer: !stored);
    if (laneBlocked != null) return refuse(laneBlocked);
    final build = hooks.buildScheduled;
    final api = hooks.scheduleApi;
    if (build == null || api == null) return refuse(t(ChatNavStrings.serverBlocked));
    final extras = scheduleNoteExtras({
      'threadRoot': threadRoot,
      'quote': quote,
      'quoteSource': quoteSource,
    });
    ScheduleBuild built;
    try {
      built = await build(key, content, at, threadRoot);
    } catch (_) {
      return refuse(t("Couldn't prepare the message to schedule."));
    }
    final chat = scheduleChatOf(key);
    String? note;
    try {
      note = await hooks.encryptNote
          ?.call(scheduleNoteJson(content, chat, scheduleNoteExtrasJson(extras)));
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
    final since = _seq;
    final pk = hooks.selfPubkey();
    try {
      await api('schedule-add', body);
    } catch (err) {
      final status = err is ScheduleApiError ? err.status : 0;
      final code = err is ScheduleApiError ? err.code : '';
      final refused = replaces != null &&
          (code == 'gone' || code == 'sent' || code == 'sending');
      var held = false;
      if (refused) {
        final now = await _refresh(since, owner: pk);
        held = now.any((x) => x.id == id);
      } else if (status == 0 || status >= 500) {
        try {
          final data = await api('schedule-list', const {});
          final raw = data['items'];
          held = raw is List && raw.any((x) => x is Map && x['id'] == id);
        } catch (_) {
          held = false;
        }
      }
      if (!held) {
        final msg = _errorText(err);
        _notice(msg);
        return ScheduleResult(false, reason: msg, code: refused ? code : null);
      }
    }
    if (hooks.selfPubkey() != pk) return ScheduleResult(true, id: id);
    final src = <String, dynamic>{
      'text': content,
      ...scheduleNoteExtrasJson(extras),
    };
    final item = _keep(
        ScheduledItem(id: id, at: at, chat: chat, status: 'pending', note: note),
        src);
    if (replaces != null) _mutate({'t': 'drop', 'id': replaces});
    _mutate({'t': 'add', 'item': item.toJson(withText: true)});
    _noteCache[note] = (
      text: content,
      chat: chat,
      threadRoot: extras.threadRoot,
      quote: extras.quote,
      quoteSource: extras.quoteSource,
    );
    final items = scheduledItems()
        .where((x) => x.id != replaces && x.id != id)
        .toList()
      ..add(item);
    _setScheduled(scheduleNormalize([for (final x in items) x.toJson(withText: true)]));
    if (!quiet) {
      _notice(t('Scheduled for {time}. Held by Nymchat until it sends.',
          {'time': formatScheduleTime(at)}));
    }
    _armRefresh();
    return ScheduleResult(true, id: id);
  }

  Future<ScheduleNote?> _openNote(String blob) async {
    if (blob.isEmpty) return null;
    final hit = _noteCache[blob];
    if (hit != null) return hit;
    final local = hooks.localNoteKey?.call() ?? true;
    final retryAt = _noteRetryAt[blob];
    if (retryAt != null && !local && _nowMs < retryAt) return null;
    ScheduleNote? parsed;
    try {
      final json = await hooks.decryptNote?.call(blob);
      parsed = json == null ? null : scheduleNoteParse(json);
    } catch (_) {
      parsed = null;
    }
    if (parsed != null) {
      _noteRetryAt.remove(blob);
      _noteCache[blob] = parsed;
      if (_noteCache.length > 500) _noteCache.remove(_noteCache.keys.first);
    } else if (local) {
      _noteRetryAt.remove(blob);
    } else {
      _noteRetryAt[blob] = _nowMs + _signerRetryMs;
      if (_noteRetryAt.length > 500) _noteRetryAt.remove(_noteRetryAt.keys.first);
    }
    return parsed;
  }

  Future<List<ScheduledItem>> refreshScheduled() => _refresh(_seq);

  Future<List<ScheduledItem>> _refresh(int since, {String? owner}) async {
    final api = hooks.scheduleApi;
    final pk = owner ?? hooks.selfPubkey();
    if (api == null || pk.isEmpty || hooks.selfPubkey() != pk) {
      return scheduledItems();
    }
    final req = ++_req;
    Map<String, dynamic> data;
    try {
      data = await api('schedule-list', const {});
    } catch (_) {
      return scheduledItems();
    }
    if (hooks.selfPubkey() != pk) return scheduledItems();
    final prev = {for (final x in scheduledItems()) x.id: x};
    final raw = data['items'];
    final out = <Map<String, dynamic>>[];
    for (final it in scheduleNormalize(raw is List ? raw.cast<Object?>() : const [])) {
      final old = prev[it.id];
      Map<String, dynamic>? src;
      Map<String, String>? chat;
      if (old != null && old.text.isNotEmpty && (old.chat['t'] ?? '').isNotEmpty) {
        src = old.toJson(withText: true);
        chat = old.chat;
      } else {
        final p = await _openNote(it.note);
        if (p != null) {
          src = scheduleNoteJsonMap(p);
          chat = p.chat;
        }
      }
      final row = ScheduledItem(
        id: it.id,
        at: it.at,
        chat: chat ?? it.chat,
        status: it.status,
        attempts: it.attempts,
        error: it.error,
        sentAt: it.sentAt,
        note: it.note,
      );
      out.add(_keep(row, src ?? const {}).toJson(withText: true));
    }
    if (hooks.selfPubkey() != pk || req < _applied) return scheduledItems();
    _applied = req;
    final later = [
      for (final e in _journal)
        if ((e['seq'] as int) > since && e['pk'] == pk) e,
    ];
    final merged = scheduleNormalize(
        scheduleHoldTaking(_rawItems(), scheduleReplay(out, later)));
    final failedNow = scheduleNewFailures(
        _rawItems(), [for (final x in merged) x.toJson()]);
    _setScheduled(merged);
    if (failedNow.isNotEmpty) _notice(t(ChatNavStrings.failedNotice));
    _armRefresh();
    return merged;
  }

  void _armRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final wait = scheduleRefreshWaitMs(_rawItems(), _nowSec);
    if (wait <= 0) return;
    _refreshTimer = Timer(Duration(milliseconds: wait), () {
      _refreshTimer = null;
      unawaited(refreshScheduled());
    });
  }

  Future<({String code, String error})> _take(String id,
      {String? token}) async {
    final api = hooks.scheduleApi;
    if (api == null) return (code: 'retry', error: '');
    try {
      final r = await api('schedule-cancel', {'id': id, 'token': ?token});
      if (r['removed'] == true) return (code: 'removed', error: '');
      if (r['status'] == 'gone') {
        return (code: r['taken'] == true ? 'taken' : 'gone', error: '');
      }
      return (code: 'retry', error: '');
    } catch (err) {
      final msg = err is ScheduleApiError ? err.message : '$err';
      if (err is ScheduleApiError &&
          err.status == 409 &&
          (err.code == 'sent' || err.code == 'sending')) {
        return (code: err.code, error: msg);
      }
      return (code: 'retry', error: msg);
    }
  }

  ScheduledItem? _find(String id) {
    ScheduledItem? it;
    for (final x in scheduledItems()) {
      if (x.id == id) it = x;
    }
    return it;
  }

  Future<bool> cancelScheduled(String id) async {
    final pk = hooks.selfPubkey();
    final it = _find(id);
    final token =
        it != null && scheduleSendTokenValid(it.sendToken) ? it.sendToken : null;
    final took = await _take(id, token: token);
    if (took.code == 'removed' || took.code == 'gone' || took.code == 'taken') {
      _dropItem(pk, id);
      return true;
    }
    if (hooks.selfPubkey() == pk) {
      _notice(t("Couldn't cancel it: {error}", {'error': took.error}));
      unawaited(refreshScheduled());
    }
    return false;
  }

  Future<String?> _sendNowGate(ScheduledItem it, String key,
      {required bool quiet}) async {
    if (it.text.trim().isEmpty || key.isEmpty) return t(ChatNavStrings.noText);
    final gate = hooks.sendNowRefusal;
    if (gate == null) return null;
    return gate(key, it.text,
        threadRoot: it.threadRoot.isEmpty ? null : it.threadRoot,
        quoteSource: it.quoteSource.isEmpty ? null : it.quoteSource,
        quiet: quiet);
  }

  Future<bool> _liveSend(ScheduledItem it, String key) async {
    final send = hooks.sendText;
    if (send == null) return false;
    try {
      return await send(key, it.text,
          threadRoot: it.threadRoot.isEmpty ? null : it.threadRoot,
          quoteSource: key.startsWith('pm-') && it.quoteSource.isNotEmpty
              ? it.quoteSource
              : null);
    } catch (_) {
      return false;
    }
  }

  Future<void> _rehold(ScheduledItem it, String key) async {
    final at = max(it.at, _nowSec + 90);
    final r = await schedule(key, it.text, at,
        threadRoot: it.threadRoot.isEmpty ? null : it.threadRoot,
        quote: it.quote,
        quoteSource: it.quoteSource.isEmpty ? null : it.quoteSource,
        quiet: true,
        stored: true);
    if (r.ok) {
      _notice(t(ChatNavStrings.sendNowHeld, {'time': formatScheduleTime(at)}));
      return;
    }
    var where = '';
    try {
      where = await hooks.restoreText?.call(key, it.text) ?? '';
    } catch (_) {
      where = '';
    }
    _notice(t(where == 'composer'
        ? ChatNavStrings.sendNowComposer
        : where == 'copied'
            ? ChatNavStrings.sendNowLost
            : ChatNavStrings.sendNowFailed));
  }

  Future<bool> sendScheduledNow(String id) async {
    final pk = hooks.selfPubkey();
    final it = _find(id);
    if (it == null ||
        !scheduleItemActions(it.toJson(withText: true)).contains('now')) {
      return false;
    }
    final key = scheduleChatKey(it.chat);
    if (!hooks.online()) {
      _notice(t("You're offline. Try again when you're back online."));
      return false;
    }
    if (!_sendingNow.add(id)) return false;
    try {
      final gate = await _sendNowGate(it, key, quiet: false);
      if (gate != null) {
        if (gate.isNotEmpty) _notice(gate);
        return false;
      }
      if (hooks.selfPubkey() != pk) return false;
      var token = it.sendToken;
      if (!scheduleSendTokenValid(token)) {
        final rng = hooks.random ?? Random.secure();
        token = scheduleId([for (var i = 0; i < 16; i++) rng.nextInt(256)]);
        _setToken(pk, id, token);
      }
      final took = await _take(id, token: token);
      final here = hooks.selfPubkey() == pk;
      switch (took.code) {
        case 'retry':
          if (here) {
            _notice(t(ChatNavStrings.sendNowRetry));
            unawaited(refreshScheduled());
          }
          return false;
        case 'sent':
        case 'sending':
          _setToken(pk, id, '');
          if (here) {
            _notice(scheduleErrorText(took.code, _tr));
            unawaited(refreshScheduled());
          }
          return false;
        case 'taken':
          _dropItem(pk, id);
          if (here) {
            _notice(t(ChatNavStrings.gone));
            unawaited(refreshScheduled());
          }
          return false;
      }
      if (!here) return false;
      if (took.code == 'gone') {
        final now = await refreshScheduled();
        if (scheduleTakenElsewhere(it.toJson(withText: true),
            [for (final x in now) x.toJson(withText: true)])) {
          _dropItem(pk, id);
          _notice(t(ChatNavStrings.gone));
          return false;
        }
        if (hooks.selfPubkey() != pk) return false;
      }
      final again = await _sendNowGate(it, key, quiet: true);
      if (hooks.selfPubkey() != pk) return false;
      final sent = again == null && await _liveSend(it, key);
      _dropItem(pk, id);
      if (sent) return true;
      if (again != null && again.isNotEmpty) _notice(again);
      if (hooks.selfPubkey() == pk) await _rehold(it, key);
      return false;
    } finally {
      _sendingNow.remove(id);
    }
  }

  Future<ScheduleResult> reschedule(String id, int at) async {
    ScheduledItem? it;
    for (final x in scheduledItems()) {
      if (x.id == id) it = x;
    }
    if (it == null) {
      final msg = t(ChatNavStrings.gone);
      _notice(msg);
      return ScheduleResult(false, reason: msg, code: 'gone');
    }
    if (it.text.isEmpty) return const ScheduleResult(false);
    return schedule(scheduleChatKey(it.chat), it.text, at,
        replaces: id,
        threadRoot: it.threadRoot.isEmpty ? null : it.threadRoot,
        quote: it.quote,
        quoteSource: it.quoteSource.isEmpty ? null : it.quoteSource,
        stored: true);
  }

  String scheduledItemStatus(ScheduledItem it) =>
      scheduleItemStatus(it, _nowSec);

  String scheduleFailText(ScheduledItem it) {
    const map = {
      'spam': 'The spam filter held it back.',
      'relays': 'No relay accepted it.',
      'late': 'It was too late to send.',
      'partial': 'Some copies may not have arrived.',
      'retry': 'Retrying.',
      'deposited': ChatNavStrings.depositedDetail,
    };
    final s = map[it.error];
    if (s != null) return t(s);
    return scheduleItemStatus(it, _nowSec) == 'overdue'
        ? t(ChatNavStrings.overdueDetail)
        : '';
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
