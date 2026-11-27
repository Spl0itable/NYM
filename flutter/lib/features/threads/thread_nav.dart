import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_nav/chat_nav.dart';

class ThreadNavEntry {
  ThreadNavEntry(this.key, this.storageKey, this.root);

  final String key;
  final String storageKey;
  final String root;
  SeenMark mark = SeenMark(0);
  int base = 0;
  int openedAt = 0;
  int openedMs = 0;
  String? info;
  bool landed = false;
  bool scrolled = false;
}

class ThreadNavStore {
  ThreadNavStore({int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowMs;
  final Map<String, ThreadNavEntry> _entries = {};
  final Map<String, int> _floors = {};
  Map<String, dynamic> _mentions = emptyMentions();

  static String keyOf(String storageKey, String root) => '$storageKey|$root';

  void noteOpening(String storageKey, String root, int threadReadSec) {
    if (storageKey.isEmpty || root.isEmpty) return;
    _floors[keyOf(storageKey, root)] = threadReadSec;
  }

  ThreadNavEntry? entry(String storageKey, String root) =>
      _entries[keyOf(storageKey, root)];

  ThreadNavEntry open(
    String storageKey,
    String root, {
    required int threadReadSec,
    required int convReadSec,
    required List<ChatNavRow> rows,
  }) {
    final k = keyOf(storageKey, root);
    final had = _entries[k];
    final e = had ?? ThreadNavEntry(k, storageKey, root);
    final read = _floors.remove(k) ?? threadReadSec;
    e.mark = threadOpenMark(had?.mark, read, convReadSec);
    if (had == null) {
      _entries[k] = e;
      if (_entries.length > 200) _entries.remove(_entries.keys.first);
    }
    final now = _nowMs();
    e
      ..base = e.mark.at
      ..openedAt = now ~/ 1000
      ..openedMs = now
      ..info = null
      ..landed = false
      ..scrolled = false;
    final items = threadMentionScan(rows, e.mark, e.openedAt);
    if (items.isNotEmpty) _mentions = mentionAdd(_mentions, k, items, now);
    if (e.base > 0) {
      for (final r in rows) {
        if (r.own || r.sys || markUnder(e.mark, r.at, r.id)) continue;
        if (r.at <= e.openedAt) e.info = r.id;
        break;
      }
    }
    return e;
  }

  bool shouldLand(ThreadNavEntry e) =>
      e.info != null &&
      !e.landed &&
      !e.scrolled &&
      _nowMs() - e.openedMs < 8000;

  List<String> unseen(ThreadNavEntry e, List<ChatNavRow> rows) =>
      unseenRows(rows, e.mark);

  void advance(ThreadNavEntry e, num at, Iterable<String> ids) {
    e.mark = markAdvance(e.mark, at, ids);
  }

  void seeAll(ThreadNavEntry e, List<ChatNavRow> rows, {bool shown = true}) {
    if (rows.isNotEmpty) {
      final last = rows.last.at;
      advance(e, last, [
        for (final r in rows)
          if (r.at == last) r.id,
      ]);
    }
    if (shown && mentionCount(_mentions, e.key) > 0) {
      _mentions = mentionClear(_mentions, e.key, _nowMs());
    }
  }

  void sweep(ThreadNavEntry e) {
    if (mentionCount(_mentions, e.key) == 0) return;
    _mentions = mentionMark(_mentions, e.key, e.mark, _nowMs());
  }

  Map<String, dynamic> _shown(ThreadNavEntry e, Set<String> live) {
    final c = (_mentions['chats'] as Map)[e.key];
    if (c is! Map) return _mentions;
    final gone = [
      for (final x in c['ids'] as List)
        if (!live.contains((x as Map)['id'])) x['id'] as String,
    ];
    return gone.isEmpty ? _mentions : mentionDrop(_mentions, e.key, gone);
  }

  int mentionCountFor(ThreadNavEntry e, Set<String> live) =>
      mentionCount(_shown(e, live), e.key);

  String? nextMention(ThreadNavEntry e, Set<String> live) =>
      mentionNext(_shown(e, live), e.key);

  void mentionSeenId(ThreadNavEntry e, String id) {
    _mentions = mentionSeen(_mentions, e.key, id, _nowMs());
  }

  void dropMention(ThreadNavEntry e, String id) {
    _mentions = mentionDrop(_mentions, e.key, [id]);
  }

  void noteLive(ThreadNavEntry e, ChatNavRow row, {required bool away}) {
    if (row.own) {
      advance(e, row.at, [row.id]);
      return;
    }
    if (!away || !row.mention || markUnder(e.mark, row.at, row.id)) return;
    _mentions = mentionAdd(_mentions, e.key, [
      {'id': row.id, 'at': row.at.floor()}
    ], _nowMs());
  }
}

final threadNavProvider = Provider<ThreadNavStore>((ref) => ThreadNavStore());
