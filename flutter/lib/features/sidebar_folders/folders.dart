import 'dart:convert';

import '../../core/utils/channel_name.dart';

class FoldersLimits {
  const FoldersLimits._();

  static const int folders = 20;
  static const int perFolder = 50;
  static const int total = 100;
  static const int nameMax = 32;
  static const int removedMax = 100;
  static const int deletedMax = 20;
  static const int layoutMax = 23;
  static const int ttlMs = 180 * 24 * 60 * 60 * 1000;
  static const int rumorOverhead = 256;
  static const int wrapLimitPq2 = 16384;
  static const int wrapLimitClassic = 28672;
  static const int reserve = 1024;
  static const int oldRefMax = 64;

  static Map<String, int> toJson() => const {
        'folders': folders,
        'perFolder': perFolder,
        'total': total,
        'nameMax': nameMax,
        'removedMax': removedMax,
        'deletedMax': deletedMax,
        'layoutMax': layoutMax,
        'ttlMs': ttlMs,
        'rumorOverhead': rumorOverhead,
        'wrapLimitPq2': wrapLimitPq2,
        'wrapLimitClassic': wrapLimitClassic,
        'reserve': reserve,
        'oldRefMax': oldRefMax,
      };
}

class FoldersKeys {
  const FoldersKeys._();

  static const String dTag = 'nymchat-folders';
  static const String payload = 'sidebarFolders';
  static const String section = 'folders';
  static const String state = 'nym_sidebar_folders:';
  static const String pending = 'nym_sidebar_folders_pending:';
  static const String collapsed = 'nym_sidebar_folder_collapsed:';

  static Map<String, String> toJson() => const {
        'dTag': dTag,
        'payload': payload,
        'section': section,
        'state': state,
        'pending': pending,
        'collapsed': collapsed,
      };
}

class FoldersStrings {
  const FoldersStrings._();

  static const String newFolder = 'New folder';
  static const String folderName = 'Folder name';
  static const String create = 'Create';
  static const String addChats = 'Add chats';
  static const String searchChats = 'Search chats';
  static const String done = 'Done';
  static const String cancel = 'Cancel';
  static const String renameFolder = 'Rename folder';
  static const String rename = 'Rename';
  static const String deleteFolder = 'Delete folder';
  static const String deleteConfirm =
      'Delete this folder? Its chats go back to their sections.';
  static const String del = 'Delete';
  static const String deleted = 'Folder deleted';
  static const String addTo = 'Add to folder…';
  static const String moveTo = 'Move to folder…';
  static const String removeFrom = 'Remove from folder';
  static const String added = 'Added to {folder}';
  static const String moved = 'Moved to {folder}';
  static const String removedFrom = 'Removed from {folder}';
  static const String inFolder = 'In {folder}';
  static const String options = 'Folder options';
  static const String moveUp = 'Move folder up';
  static const String moveDown = 'Move folder down';
  static const String expand = 'Expand folder';
  static const String collapse = 'Collapse folder';
  static const String empty = 'No chats to show';
  static const String unread = '{n} unread';
  static const String headLabel = '{name}, folder';
  static const String headLabelUnread = '{name}, folder, {n} unread';
  static const String capFolders = 'You can have up to {n} folders.';
  static const String capItems = 'A folder can hold up to {n} chats.';
  static const String capTotal = 'Folders can hold up to {n} chats in all.';
  static const String nameLong = 'Folder names can be up to {n} characters.';
  static const String nameEmpty = 'Enter a folder name.';
  static const String capSize = 'Folders are full. Remove some chats to make room.';

  static Map<String, String> toJson() => const {
        'newFolder': newFolder,
        'folderName': folderName,
        'create': create,
        'addChats': addChats,
        'searchChats': searchChats,
        'done': done,
        'cancel': cancel,
        'renameFolder': renameFolder,
        'rename': rename,
        'deleteFolder': deleteFolder,
        'deleteConfirm': deleteConfirm,
        'del': del,
        'deleted': deleted,
        'addTo': addTo,
        'moveTo': moveTo,
        'removeFrom': removeFrom,
        'added': added,
        'moved': moved,
        'removedFrom': removedFrom,
        'inFolder': inFolder,
        'options': options,
        'moveUp': moveUp,
        'moveDown': moveDown,
        'expand': expand,
        'collapse': collapse,
        'empty': empty,
        'unread': unread,
        'headLabel': headLabel,
        'headLabelUnread': headLabelUnread,
        'capFolders': capFolders,
        'capItems': capItems,
        'capTotal': capTotal,
        'nameLong': nameLong,
        'nameEmpty': nameEmpty,
        'capSize': capSize,
      };
}

const List<String> kFolderBuiltins = ['channels', 'pms', 'nyms'];

final RegExp _rxFid = RegExp(r'^[a-z0-9]{12}$');
final RegExp _rxHex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _rxGroup = RegExp(r'^[0-9a-f]{16,64}$');
const String _idChars = 'abcdefghijklmnopqrstuvwxyz0123456789';
const String _removed = '';

class SidebarFolder {
  SidebarFolder(this.name, this.nt, this.at, this.items);

  String name;
  int nt;
  int at;
  final Map<String, int> items;

  SidebarFolder copy() => SidebarFolder(name, nt, at, Map.of(items));

  Map<String, dynamic> toJson() => {
        'name': name,
        'nt': nt,
        'at': at,
        'items': Map<String, int>.of(items),
      };
}

class FoldersState {
  FoldersState({
    Map<String, SidebarFolder>? folders,
    Map<String, int>? removed,
    Map<String, int>? deleted,
    List<String>? layout,
    this.lt = 0,
  })  : folders = folders ?? <String, SidebarFolder>{},
        removed = removed ?? <String, int>{},
        deleted = deleted ?? <String, int>{},
        layout = layout ?? <String>[];

  final Map<String, SidebarFolder> folders;
  final Map<String, int> removed;
  final Map<String, int> deleted;
  List<String> layout;
  int lt;

  String? _json;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'folders': {for (final e in folders.entries) e.key: e.value.toJson()},
        'removed': Map<String, int>.of(removed),
        'deleted': Map<String, int>.of(deleted),
        'layout': List<String>.of(layout),
        'lt': lt,
      };

  String get json => _json ??= jsonEncode(toJson());

  bool sameAs(FoldersState other) => identical(this, other) || json == other.json;

  FoldersState clone() => FoldersState(
        folders: {for (final e in folders.entries) e.key: e.value.copy()},
        removed: Map.of(removed),
        deleted: Map.of(deleted),
        layout: List.of(layout),
        lt: lt,
      );

  FoldersState withLayout(List<String> next) => FoldersState(
        folders: folders,
        removed: removed,
        deleted: deleted,
        layout: next,
        lt: lt,
      );
}

class FoldersResult {
  const FoldersResult(this.state, this.error, [this.layout]);

  final FoldersState state;
  final String? error;
  final List<String>? layout;
}

int _stamp(Object? v) {
  if (v is int) return v > 0 ? v : 0;
  if (v is double) return v.isFinite && v > 0 ? v.floor() : 0;
  return 0;
}

int _cmpStr(String a, String b) => a.compareTo(b);

String foldersFill(String s, [Map<String, Object?>? vars]) {
  var out = s;
  if (vars != null) {
    for (final e in vars.entries) {
      out = out.split('{${e.key}}').join('${e.value}');
    }
  }
  return out;
}

bool folderValidRef(Object? k) {
  final s = k is String ? k : '';
  if (s.startsWith('d:')) return _rxHex64.hasMatch(s.substring(2));
  if (s.startsWith('g:')) return _rxGroup.hasMatch(s.substring(2));
  if (s.startsWith('c:')) return isChannelName(s.substring(2));
  return false;
}

bool folderValidFid(Object? id) => id is String && _rxFid.hasMatch(id);

bool _validToken(Object? t) {
  if (kFolderBuiltins.contains(t)) return true;
  return t is String && t.startsWith('f:') && folderValidFid(t.substring(2));
}

bool _isSpace(int cp) =>
    cp == 0x20 ||
    (cp >= 0x09 && cp <= 0x0D) ||
    cp == 0x85 ||
    cp == 0xA0 ||
    cp == 0x1680 ||
    (cp >= 0x2000 && cp <= 0x200A) ||
    cp == 0x2028 ||
    cp == 0x2029 ||
    cp == 0x202F ||
    cp == 0x205F ||
    cp == 0x3000 ||
    cp == 0xFEFF;

bool _isDropped(int cp) =>
    cp <= 0x1F ||
    (cp >= 0x7F && cp <= 0x9F) ||
    cp == 0x200E ||
    cp == 0x200F ||
    (cp >= 0x202A && cp <= 0x202E) ||
    (cp >= 0x2066 && cp <= 0x2069) ||
    (cp >= 0xD800 && cp <= 0xDFFF);

List<int> _cleanCodePoints(Object? raw) {
  final out = <int>[];
  var gap = false;
  for (final cp in (raw is String ? raw : '').runes) {
    if (_isSpace(cp)) {
      gap = true;
      continue;
    }
    if (_isDropped(cp)) continue;
    if (gap && out.isNotEmpty) out.add(0x20);
    gap = false;
    out.add(cp);
  }
  return out;
}

({String name, String? error}) cleanFolderName(Object? raw) {
  final cps = _cleanCodePoints(raw);
  if (cps.isEmpty) return (name: '', error: 'name');
  if (cps.length > FoldersLimits.nameMax) return (name: '', error: 'long');
  return (name: String.fromCharCodes(cps), error: null);
}

String _storedName(Object? raw) {
  final all = _cleanCodePoints(raw);
  final cps = all.length > FoldersLimits.nameMax
      ? all.sublist(0, FoldersLimits.nameMax)
      : all;
  while (cps.isNotEmpty && cps.last == 0x20) {
    cps.removeLast();
  }
  return cps.isEmpty ? '' : String.fromCharCodes(cps);
}

String folderIdFrom(List<int> bytes) {
  final id = StringBuffer();
  var n = 0;
  for (var i = 0; i < bytes.length && n < 12; i++) {
    final v = bytes[i] & 255;
    if (v < 252) {
      id.write(_idChars[v % 36]);
      n++;
    }
  }
  return n == 12 ? id.toString() : '';
}

FoldersState emptyFolders() => FoldersState();

List<String> _sortedKeys(Map<String, Object?> o) =>
    o.keys.toList()..sort(_cmpStr);

class _Claim {
  _Claim(this.at, String who) : who = [who];
  int at;
  List<String> who;
}

FoldersState _finish(FoldersState s, Object? nowMs) {
  final now = _stamp(nowMs);
  final cutoff = now > 0 ? now - FoldersLimits.ttlMs : 0;
  final deleted = <String, int>{};
  for (final id in _sortedKeys(s.deleted)) {
    final at = s.deleted[id]!;
    if (cutoff > 0 && at < cutoff) continue;
    deleted[id] = at;
  }
  final best = <String, _Claim>{};
  void claim(String ref, String who, int at) {
    final cur = best[ref];
    if (cur == null || at > cur.at) {
      best[ref] = _Claim(at, who);
    } else if (at == cur.at && !cur.who.contains(who)) {
      cur.who.add(who);
    }
  }

  for (final id in _sortedKeys(s.folders)) {
    final items = s.folders[id]!.items;
    for (final e in items.entries) {
      claim(e.key, id, e.value);
    }
  }
  for (final e in s.removed.entries) {
    claim(e.key, _removed, e.value);
  }
  final folders = <String, SidebarFolder>{};
  for (final id in _sortedKeys(s.folders)) {
    if (deleted.containsKey(id)) continue;
    final f = s.folders[id]!;
    folders[id] = SidebarFolder(f.name, f.nt, f.at, <String, int>{});
  }
  final removed = <String, int>{};
  for (final ref in best.keys.toList()..sort(_cmpStr)) {
    final c = best[ref]!;
    final who = c.who.length == 1 ? c.who[0] : _removed;
    final target = who == _removed ? null : folders[who];
    if (target != null) {
      target.items[ref] = c.at;
    } else if (!(cutoff > 0 && c.at < cutoff)) {
      removed[ref] = c.at;
    }
  }
  final layout = <String>[];
  for (final t in s.layout) {
    if (layout.length >= FoldersLimits.layoutMax) break;
    if (!_validToken(t) || layout.contains(t)) continue;
    if (t.startsWith('f:') && deleted.containsKey(t.substring(2))) continue;
    layout.add(t);
  }
  return _fitBudget(FoldersState(
    folders: folders,
    removed: _keepNewest(removed, FoldersLimits.removedMax),
    deleted: _keepNewest(deleted, FoldersLimits.deletedMax),
    layout: layout,
    lt: _stamp(s.lt),
  ));
}

int _stateBytes(FoldersState s) =>
    foldersRumorBytes({FoldersKeys.payload: s.toJson()});

FoldersState _fitBudget(FoldersState s) {
  var bytes = _stateBytes(s);
  if (bytes <= FoldersLimits.wrapLimitPq2) return s;
  final seen = foldersLiveBytes(_oldBuildView(s));
  final budget = FoldersLimits.wrapLimitPq2 + foldersLiveBytes(s) - seen;
  if (bytes <= budget || seen > FoldersLimits.wrapLimitPq2) return s;
  final tombs = <({Map<String, int> m, String k, int at, int o})>[
    for (final e in s.removed.entries) (m: s.removed, k: e.key, at: e.value, o: 0),
    for (final e in s.deleted.entries) (m: s.deleted, k: e.key, at: e.value, o: 1),
  ]..sort((a, b) {
      final d = a.at - b.at;
      if (d != 0) return d.sign;
      if (a.o != b.o) return a.o - b.o;
      return _cmpStr(a.k, b.k);
    });
  for (final t in tombs) {
    if (bytes <= budget) break;
    t.m.remove(t.k);
    bytes = _stateBytes(s);
  }
  return s;
}

int foldersLiveBytes(FoldersState s) => _stateBytes(FoldersState(
      folders: s.folders,
      layout: s.layout,
      lt: s.lt,
    ));

bool _hasRoom(FoldersState s) =>
    foldersLiveBytes(s) <= FoldersLimits.wrapLimitPq2 - FoldersLimits.reserve;

FoldersState _rawState(Object? raw) {
  final s = emptyFolders();
  if (raw is! Map) return s;
  final rf = raw['folders'];
  if (rf is Map) {
    for (final e in rf.entries) {
      final id = e.key;
      final f = e.value;
      if (!folderValidFid(id) || f is! Map) continue;
      final name = _storedName(f['name']);
      if (name.isEmpty) continue;
      final items = <String, int>{};
      final ri = f['items'];
      if (ri is Map) {
        for (final x in ri.entries) {
          final at = _stamp(x.value);
          if (folderValidRef(x.key) && at > 0) items[x.key as String] = at;
        }
      }
      s.folders[id as String] =
          SidebarFolder(name, _stamp(f['nt']), _stamp(f['at']), items);
    }
  }
  final rr = raw['removed'];
  if (rr is Map) {
    for (final x in rr.entries) {
      final at = _stamp(x.value);
      if (folderValidRef(x.key) && at > 0) s.removed[x.key as String] = at;
    }
  }
  final rd = raw['deleted'];
  if (rd is Map) {
    for (final x in rd.entries) {
      final at = _stamp(x.value);
      if (folderValidFid(x.key) && at > 0) s.deleted[x.key as String] = at;
    }
  }
  final rl = raw['layout'];
  if (rl is List) s.layout = [for (final t in rl) if (t is String) t];
  s.lt = _stamp(raw['lt']);
  return s;
}

FoldersState normalizeFolders(Object? raw, [Object? nowMs]) =>
    _finish(_rawState(raw is FoldersState ? raw.toJson() : raw), nowMs);

FoldersState _asState(Object? state) =>
    state is FoldersState ? state : normalizeFolders(state);

String folderOf(Object? state, String ref) =>
    _folderOfState(normalizeFolders(state), ref);

String _folderOfState(FoldersState s, String ref) {
  for (final e in s.folders.entries) {
    if (e.value.items.containsKey(ref)) return e.key;
  }
  return '';
}

String folderOfState(FoldersState s, String ref) => _folderOfState(s, ref);

typedef FolderEntry = ({String id, String name, List<String> refs});

List<FolderEntry> folderList(Object? state) {
  final s = _asState(state);
  return [
    for (final t in layoutOf(s))
      if (t.startsWith('f:'))
        (
          id: t.substring(2),
          name: s.folders[t.substring(2)]!.name,
          refs: s.folders[t.substring(2)]!.items.keys.toList()..sort(_cmpStr),
        ),
  ];
}

int _itemCount(FoldersState s) {
  var n = 0;
  for (final f in s.folders.values) {
    n += f.items.length;
  }
  return n;
}

int _prevStamp(FoldersState s, String ref) {
  var at = s.removed[ref] ?? 0;
  for (final f in s.folders.values) {
    final v = f.items[ref];
    if (v != null && v > at) at = v;
  }
  return at;
}

List<String> layoutOf(Object? state) {
  final s = _asState(state);
  final out = <String>[];
  for (final t in s.layout) {
    if (out.contains(t)) continue;
    if (kFolderBuiltins.contains(t) ||
        (t.startsWith('f:') && s.folders.containsKey(t.substring(2)))) {
      out.add(t);
    }
  }
  for (final b in kFolderBuiltins) {
    if (!out.contains(b)) out.add(b);
  }
  final missing = s.folders.keys
      .where((id) => !out.contains('f:$id'))
      .toList()
    ..sort((a, b) {
      final d = s.folders[a]!.at - s.folders[b]!.at;
      return d != 0 ? d.sign : _cmpStr(a, b);
    });
  out.insertAll(out.indexOf('channels'), [for (final id in missing) 'f:$id']);
  return out;
}

List<String> folderBuiltinOrder(Object? applied) {
  final out = <String>[];
  if (applied is List) {
    for (final t in applied) {
      if (kFolderBuiltins.contains(t) && !out.contains(t)) out.add(t as String);
    }
  }
  for (final b in kFolderBuiltins) {
    if (!out.contains(b)) out.add(b);
  }
  return out;
}

List<String> effectiveLayout(Object? state, Object? applied) {
  final order = folderBuiltinOrder(applied);
  var i = 0;
  return [
    for (final t in layoutOf(state))
      kFolderBuiltins.contains(t) ? order[i++] : t,
  ];
}

int _bump(Object? prev, Object? nowMs) {
  final a = _stamp(nowMs);
  final b = _stamp(prev) + 1;
  return a > b ? a : b;
}

int _atLeastOne(Object? nowMs) {
  final n = _stamp(nowMs);
  return n > 1 ? n : 1;
}

List<String>? _cleanRefs(Object? refs) {
  final out = <String>[];
  if (refs is List) {
    for (final r in refs) {
      if (!folderValidRef(r)) return null;
      if (!out.contains(r)) out.add(r as String);
    }
  }
  return out;
}

FoldersResult folderCreate(Object? state, Object? id, Object? name, Object? nowMs,
    [Object? refs, Object? applied]) {
  final s = normalizeFolders(state, nowMs);
  if (!folderValidFid(id) ||
      s.folders.containsKey(id) ||
      s.deleted.containsKey(id)) {
    return FoldersResult(s, 'invalid');
  }
  final fid = id as String;
  final n = cleanFolderName(name);
  if (n.error != null) return FoldersResult(s, n.error);
  if (s.folders.length >= FoldersLimits.folders) {
    return FoldersResult(s, 'folders');
  }
  final list = refs == null ? <String>[] : _cleanRefs(refs);
  if (list == null) return FoldersResult(s, 'invalid');
  final t = s.clone();
  final at = _atLeastOne(nowMs);
  final layout = applied is List ? effectiveLayout(s, applied) : layoutOf(s);
  t.folders[fid] = SidebarFolder(n.name, at, at, <String, int>{});
  layout.insert(layout.indexOf('channels'), 'f:$fid');
  t.layout = layout;
  t.lt = _bump(s.lt, nowMs);
  final created = _finish(t, nowMs);
  if (!_hasRoom(created)) return FoldersResult(s, 'size');
  if (list.isEmpty) return FoldersResult(created, null);
  final r = folderAdd(created, fid, list, nowMs);
  return r.error != null ? FoldersResult(s, r.error) : r;
}

FoldersResult folderRename(Object? state, String id, Object? name, Object? nowMs) {
  final s = normalizeFolders(state, nowMs);
  final f = s.folders[id];
  if (f == null) return FoldersResult(s, 'invalid');
  final n = cleanFolderName(name);
  if (n.error != null) return FoldersResult(s, n.error);
  if (n.name == f.name) return FoldersResult(s, null);
  final t = s.clone();
  t.folders[id]!
    ..name = n.name
    ..nt = _bump(f.nt, nowMs);
  final next = _finish(t, nowMs);
  if (!_hasRoom(next) && foldersLiveBytes(next) > foldersLiveBytes(s)) {
    return FoldersResult(s, 'size');
  }
  return FoldersResult(next, null);
}

FoldersResult folderAdd(Object? state, String id, Object? refs, Object? nowMs) {
  final s = normalizeFolders(state, nowMs);
  final f = s.folders[id];
  if (f == null) return FoldersResult(s, 'invalid');
  final list = _cleanRefs(refs);
  if (list == null) return FoldersResult(s, 'invalid');
  final fresh = [for (final r in list) if (!f.items.containsKey(r)) r];
  if (fresh.isEmpty) return FoldersResult(s, null);
  if (f.items.length + fresh.length > FoldersLimits.perFolder) {
    return FoldersResult(s, 'cap');
  }
  final outside = fresh.where((r) => _folderOfState(s, r).isEmpty).length;
  if (_itemCount(s) + outside > FoldersLimits.total) {
    return FoldersResult(s, 'total');
  }
  final t = s.clone();
  for (final r in fresh) {
    final at = _bump(_prevStamp(s, r), nowMs);
    for (final other in t.folders.values) {
      other.items.remove(r);
    }
    t.removed.remove(r);
    t.folders[id]!.items[r] = at;
  }
  final next = _finish(t, nowMs);
  if (!_hasRoom(next)) return FoldersResult(s, 'size');
  return FoldersResult(next, null);
}

FoldersResult folderRemove(Object? state, String id, Object? refs, Object? nowMs) {
  final s = normalizeFolders(state, nowMs);
  final f = s.folders[id];
  if (f == null) return FoldersResult(s, 'invalid');
  final list = _cleanRefs(refs);
  if (list == null) return FoldersResult(s, 'invalid');
  final t = s.clone();
  var changed = false;
  for (final r in list) {
    final at = f.items[r];
    if (at == null) continue;
    t.folders[id]!.items.remove(r);
    t.removed[r] = _bump(at, nowMs);
    changed = true;
  }
  return FoldersResult(changed ? _finish(t, nowMs) : s, null);
}

FoldersResult folderDelete(Object? state, String id, Object? nowMs) {
  final s = normalizeFolders(state, nowMs);
  final f = s.folders[id];
  if (f == null) return FoldersResult(s, 'invalid');
  final t = s.clone();
  for (final e in f.items.entries) {
    t.removed[e.key] = _bump(e.value, nowMs);
  }
  t.folders.remove(id);
  t.deleted[id] = _atLeastOne(nowMs);
  t.layout = [for (final x in layoutOf(s)) if (x != 'f:$id') x];
  t.lt = _bump(s.lt, nowMs);
  return FoldersResult(_finish(t, nowMs), null);
}

FoldersResult folderRestore(Object? state, Object? id, Object? name,
    Object? refs, Object? index, Object? nowMs) {
  final r = folderCreate(state, id, name, nowMs);
  if (r.error != null) return r;
  final fid = id as String;
  var s = r.state;
  final list = _cleanRefs(refs) ?? const <String>[];
  if (list.isNotEmpty) {
    final a = folderAdd(s, fid, list, nowMs);
    if (a.error != null) {
      return FoldersResult(normalizeFolders(state, nowMs), a.error);
    }
    s = a.state;
  }
  final layout = [for (final x in layoutOf(s)) if (x != 'f:$fid') x];
  final want = index is num && index.isFinite
      ? index.floor()
      : layout.indexOf('channels');
  final at = want < 0 ? 0 : (want > layout.length ? layout.length : want);
  layout.insert(at, 'f:$fid');
  final t = s.clone();
  t.layout = layout;
  t.lt = _bump(s.lt, nowMs);
  return FoldersResult(_finish(t, nowMs), null);
}

FoldersResult layoutMove(Object? state, String token, Object? delta,
    Object? nowMs, [Object? applied]) {
  final s = normalizeFolders(state, nowMs);
  final layout = effectiveLayout(s, applied);
  final i = layout.indexOf(token);
  final d = delta is num && delta.isFinite ? delta.truncate() : 0;
  final j = i + d;
  if (i < 0 || j < 0 || j >= layout.length || i == j) {
    return FoldersResult(s, 'edge', layout);
  }
  layout
    ..removeAt(i)
    ..insert(j, token);
  final t = s.clone();
  t.layout = List.of(layout);
  t.lt = _bump(s.lt, nowMs);
  return FoldersResult(_finish(t, nowMs), null, layout);
}

FoldersState layoutSet(Object? state, Object? layout, Object? nowMs) {
  final s = normalizeFolders(state, nowMs);
  final next = <String>[
    if (layout is List)
      for (final t in layout)
        if (_validToken(t)) t as String,
  ];
  if (jsonEncode(layoutOf(s.withLayout(next))) == jsonEncode(layoutOf(s))) {
    return s;
  }
  final t = s.clone();
  t.layout = next;
  t.lt = _bump(s.lt, nowMs);
  return _finish(t, nowMs);
}

FoldersState mergeFolders(Object? a, Object? b, Object? nowMs) {
  final x = normalizeFolders(a, nowMs);
  final y = normalizeFolders(b, nowMs);
  final t = x.clone();
  for (final e in y.folders.entries) {
    final f = e.value;
    final g = t.folders[e.key];
    if (g == null) {
      t.folders[e.key] = f.copy();
      continue;
    }
    if (f.nt > g.nt || (f.nt == g.nt && _cmpStr(f.name, g.name) > 0)) {
      g.name = f.name;
    }
    g.nt = g.nt > f.nt ? g.nt : f.nt;
    g.at = g.at > 0 && f.at > 0
        ? (g.at < f.at ? g.at : f.at)
        : (g.at > 0 ? g.at : f.at);
    for (final r in f.items.entries) {
      final cur = g.items[r.key];
      if (cur == null || cur < r.value) g.items[r.key] = r.value;
    }
  }
  for (final r in y.removed.entries) {
    final cur = t.removed[r.key];
    if (cur == null || cur < r.value) t.removed[r.key] = r.value;
  }
  for (final r in y.deleted.entries) {
    final cur = t.deleted[r.key];
    if (cur == null || cur < r.value) t.deleted[r.key] = r.value;
  }
  if (y.lt > x.lt ||
      (y.lt == x.lt &&
          jsonEncode(y.layout).compareTo(jsonEncode(x.layout)) > 0)) {
    t.layout = List.of(y.layout);
  }
  t.lt = x.lt > y.lt ? x.lt : y.lt;
  return _finish(t, nowMs);
}

bool _oldBuildsSee(String ref) =>
    !ref.startsWith('c:') ||
    ref.substring(2).runes.length <= FoldersLimits.oldRefMax;

FoldersState _oldBuildView(FoldersState s) => FoldersState(
      folders: {
        for (final f in s.folders.entries)
          f.key: SidebarFolder(f.value.name, f.value.nt, f.value.at, {
            for (final e in f.value.items.entries)
              if (_oldBuildsSee(e.key)) e.key: e.value,
          }),
      },
      layout: s.layout,
      lt: s.lt,
    );

({FoldersState state, bool changed}) capRepair(Object? state, Object? nowMs) {
  var s = normalizeFolders(state, nowMs);
  var changed = false;
  final ids = s.folders.keys.toList()
    ..sort((a, b) {
      final d = s.folders[a]!.at - s.folders[b]!.at;
      return d != 0 ? d.sign : _cmpStr(a, b);
    });
  for (final id in ids.skip(FoldersLimits.folders)) {
    s = folderDelete(s, id, nowMs).state;
    changed = true;
  }
  int newest(({String id, String ref, int at}) p, ({String id, String ref, int at}) q) {
    final d = q.at - p.at;
    return d != 0 ? d.sign : _cmpStr(q.ref, p.ref);
  }

  for (final id in s.folders.keys.toList()) {
    final items = s.folders[id]!.items;
    final list = [
      for (final e in items.entries)
        if (_oldBuildsSee(e.key)) (id: id, ref: e.key, at: e.value),
    ]..sort(newest);
    final extra = list.length - FoldersLimits.perFolder;
    if (extra > 0) {
      s = folderRemove(s, id, [for (final e in list.take(extra)) e.ref], nowMs)
          .state;
      changed = true;
    }
  }
  final all = [
    for (final f in s.folders.entries)
      for (final e in f.value.items.entries)
        if (_oldBuildsSee(e.key)) (id: f.key, ref: e.key, at: e.value),
  ];
  final over = all.length - FoldersLimits.total;
  if (over > 0) {
    all.sort(newest);
    for (final e in all.take(over)) {
      s = folderRemove(s, e.id, [e.ref], nowMs).state;
    }
    changed = true;
  }
  for (var guard = 0;
      foldersLiveBytes(_oldBuildView(s)) > FoldersLimits.wrapLimitPq2 &&
          guard < FoldersLimits.total;
      guard++) {
    final live = [
      for (final f in s.folders.entries)
        for (final e in f.value.items.entries)
          if (_oldBuildsSee(e.key)) (id: f.key, ref: e.key, at: e.value),
    ];
    if (live.isEmpty) break;
    live.sort(newest);
    s = folderRemove(s, live.first.id, [live.first.ref], nowMs).state;
    changed = true;
  }
  return (state: s, changed: changed);
}

List<String> folderSort(Object? refs, Object? ctx) {
  final pins = ctx is Map && ctx['pins'] is List ? ctx['pins'] as List : const [];
  final act = ctx is Map && ctx['activity'] is Map ? ctx['activity'] as Map : const {};
  final pos = <Object?, int>{};
  for (var i = 0; i < pins.length; i++) {
    pos.putIfAbsent(pins[i], () => i);
  }
  num val(String r) {
    final v = act[r];
    return v is num && v.isFinite ? v : 0;
  }

  final out = refs is List ? [for (final r in refs) '$r'] : <String>[];
  out.sort((a, b) {
    final pa = pos[a] ?? -1;
    final pb = pos[b] ?? -1;
    if (pa >= 0 && pb >= 0 && pa != pb) return pa - pb;
    if (pa >= 0 && pb < 0) return -1;
    if (pb >= 0 && pa < 0) return 1;
    final d = val(b) - val(a);
    return d != 0 ? (d > 0 ? 1 : -1) : _cmpStr(a, b);
  });
  return out;
}

({int n, String label}) folderUnread(Object? counts) {
  var n = 0;
  if (counts is List) {
    for (final c in counts) {
      if (c is num && c.isFinite && c > 0) n += c.floor();
      if (n > 99) {
        n = 100;
        break;
      }
    }
  }
  return (n: n, label: n <= 0 ? '' : n > 99 ? '99+' : '$n');
}

class FolderVisibility {
  const FolderVisibility({
    this.exists = const {},
    this.hidden = const {},
    this.blocked = const {},
    this.locked = const {},
    this.filtered = const {},
    this.active = '',
    this.pmOnly = false,
  });

  factory FolderVisibility.fromJson(Object? raw) {
    final c = raw is Map ? raw : const {};
    Set<String> set(String k) =>
        c[k] is List ? {for (final x in c[k] as List) '$x'} : const <String>{};
    return FolderVisibility(
      exists: set('exists'),
      hidden: set('hidden'),
      blocked: set('blocked'),
      locked: set('locked'),
      filtered: set('filtered'),
      active: c['active'] is String ? c['active'] as String : '',
      pmOnly: c['pmOnly'] == true,
    );
  }

  final Set<String> exists;
  final Set<String> hidden;
  final Set<String> blocked;
  final Set<String> locked;
  final Set<String> filtered;
  final String active;
  final bool pmOnly;

  bool shows(Object? r) {
    if (!folderValidRef(r)) return false;
    final ref = r as String;
    if (!exists.contains(ref) ||
        locked.contains(ref) ||
        filtered.contains(ref) ||
        blocked.contains(ref)) {
      return false;
    }
    if (ref.startsWith('c:')) {
      if (pmOnly) return false;
      if (hidden.contains(ref) && active != ref) return false;
    }
    return true;
  }
}

List<String> visibleRefs(Object? refs, FolderVisibility ctx) => [
      if (refs is List)
        for (final r in refs)
          if (ctx.shows(r)) r as String,
    ];

List<String> navRefs(Object? state, Object? collapsed,
    [List<String> Function(List<String>)? visibleOf]) {
  final s = normalizeFolders(state);
  final closed = collapsed is List ? {for (final x in collapsed) '$x'} : const <String>{};
  final out = <String>[];
  for (final f in folderList(s)) {
    if (closed.contains(f.id)) continue;
    final refs = visibleOf != null ? visibleOf(f.refs) : f.refs;
    for (final r in refs) {
      out.add('${f.id} $r');
    }
  }
  return out;
}

Map<String, int> _keepNewest(Map<String, int> o, int max) {
  if (o.length <= max) return o;
  final keys = o.keys.toList()
    ..sort((a, b) {
      final d = o[b]! - o[a]!;
      return d != 0 ? d.sign : _cmpStr(a, b);
    });
  final kept = keys.take(max).toList()..sort(_cmpStr);
  return {for (final k in kept) k: o[k]!};
}

FoldersState foldersPublishable(Object? state) => normalizeFolders(state);

bool trimFoldersPayload(Map<String, dynamic> p) {
  final s = p[FoldersKeys.payload];
  if (s is! Map) return false;
  for (final k in const ['removed', 'deleted']) {
    final o = s[k];
    if (o is! Map || o.isEmpty) continue;
    num at(Object? key) {
      final v = o[key];
      return v is num ? v : 0;
    }

    final keys = o.keys.map((e) => '$e').toList()
      ..sort((a, b) {
        final d = at(a) - at(b);
        return d != 0 ? (d > 0 ? 1 : -1) : _cmpStr(a, b);
      });
    for (final x in keys.take((keys.length / 4).ceil())) {
      o.remove(x);
    }
    return true;
  }
  return false;
}

int foldersRumorBytes(Map<String, dynamic> payload) =>
    utf8.encode(jsonEncode(jsonEncode(payload))).length +
    FoldersLimits.rumorOverhead;

bool hasFolders(Object? state) => _asState(state).folders.isNotEmpty;
