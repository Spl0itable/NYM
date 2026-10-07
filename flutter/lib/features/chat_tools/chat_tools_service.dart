import 'dart:async';
import 'dart:convert';

import '../../models/message.dart';
import 'chat_tools.dart';

abstract class ChatToolsPrefs {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class MemoryChatToolsPrefs implements ChatToolsPrefs {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

enum SavedStatus { synced, pending, local }

enum SaveResult { saved, once, missing }

enum KeepRoute { sent, mesh, queued }

bool Function(String? nid) chatToolsKeptLookup = (_) => false;

bool chatToolsHidden(Message m, [int? nowSec]) {
  final e = m.expiresAt;
  if (e == null || e == 0) return false;
  return isExpired(e, chatToolsKeptLookup(m.nymMessageId),
      nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
}

String chatSurfaceForKey(String key) {
  if (key.startsWith('pm-')) return 'dm';
  if (key.startsWith('group-')) return 'group';
  return 'channel';
}

String chatDomId(Message m) =>
    (m.isPM || m.isGroup) ? (m.nymMessageId ?? m.id) : m.id;

ChatToolsMessage chatToolsMessageOf(Message m, {String? author}) =>
    ChatToolsMessage(
      id: m.id,
      nid: m.nymMessageId ?? '',
      pubkey: m.pubkey,
      author: author ?? m.author,
      content: m.content,
      at: m.createdAt,
      edited: m.isEdited,
      system: m.isSystemRow || m.pubkey.isEmpty,
      fileOfferName: m.isFileOffer ? (m.fileOffer?['name'] as String?) : null,
      fileOfferSize:
          m.isFileOffer ? (m.fileOffer?['size'] as num?)?.toInt() : null,
    );

class ChatToolsHooks {
  const ChatToolsHooks({
    required this.selfPubkey,
    this.online = _never,
    this.hydrated = _always,
    this.syncAllowed = _always,
    this.publishSaved,
    this.publishKeep,
    this.meshPeerFor,
    this.sendMeshKeep,
    this.groupMembers,
    this.findMessage,
    this.notice,
    this.onChanged,
    this.now,
    this.fetchEditEvents,
    this.editFetchTimeout =
        const Duration(milliseconds: ChatToolsLimits.editFetchTimeoutMs),
  });

  static bool _never() => false;
  static bool _always() => true;

  final String Function() selfPubkey;
  final bool Function() online;
  final bool Function() hydrated;
  final bool Function() syncAllowed;
  final Future<bool> Function(Map<String, dynamic> saved)? publishSaved;
  final Future<bool> Function(String storageKey, String nid, bool kept, int at)?
      publishKeep;
  final String? Function(String pubkey)? meshPeerFor;
  final Future<bool> Function(String pubkey, String nid, bool kept)?
      sendMeshKeep;
  final List<String>? Function(String groupId)? groupMembers;
  final ({Message msg, String key})? Function(String id)? findMessage;
  final void Function(String text)? notice;
  final void Function()? onChanged;
  final int Function()? now;
  final Future<List<Map<String, dynamic>>> Function(
      String surface, String id, int at)? fetchEditEvents;
  final Duration editFetchTimeout;
}

class ChatToolsService {
  ChatToolsService(this._prefs, this.hooks) {
    chatToolsKeptLookup = (nid) => isKept(_keep(), nid);
  }

  final ChatToolsPrefs _prefs;
  final ChatToolsHooks hooks;

  int get _nowMs => hooks.now?.call() ?? DateTime.now().millisecondsSinceEpoch;
  int get _nowSec => _nowMs ~/ 1000;

  void _changed() => hooks.onChanged?.call();

  Map<String, dynamic> _readMap(String key) {
    try {
      final raw = _prefs.read(key);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String get _savedKey => '${ChatToolsKeys.saved}:${hooks.selfPubkey()}';
  String get _pendingKey => '${ChatToolsKeys.savedPending}:${hooks.selfPubkey()}';

  Map<String, dynamic>? _savedCache;
  String? _savedCachePk;
  int _savedRev = 0;
  bool _syncing = false;
  bool _resync = false;

  Map<String, dynamic> savedState() {
    final pk = hooks.selfPubkey();
    if (_savedCache != null && _savedCachePk == pk) return _savedCache!;
    _savedCache = normalizeSaved(_readMap(_savedKey));
    _savedCachePk = pk;
    return _savedCache!;
  }

  List<Map<String, dynamic>> get savedItems =>
      savedState()['items'] as List<Map<String, dynamic>>;

  void _persistSaved(Map<String, dynamic> s) {
    _savedCache = s;
    _savedCachePk = hooks.selfPubkey();
    _prefs.write(_savedKey, jsonEncode(s));
  }

  bool get savedPending => _prefs.read(_pendingKey) == '1';

  void _setPending(bool on) {
    if (on) {
      _prefs.write(_pendingKey, '1');
    } else {
      _prefs.remove(_pendingKey);
    }
  }

  SavedStatus get savedStatus {
    if (!hooks.syncAllowed()) return SavedStatus.local;
    return savedPending ? SavedStatus.pending : SavedStatus.synced;
  }

  bool isMessageSaved(Message m) =>
      isSaved(savedState(), m.nymMessageId ?? m.id);

  SaveResult saveMessage(Message m, Map<String, String> chat, {String? author}) {
    final res = savedEntry(chatToolsMessageOf(m, author: author), chat, _nowMs);
    if (res.error == 'once') {
      hooks.notice?.call(ChatToolsStrings.onceNotSaved);
      return SaveResult.once;
    }
    final entry = res.entry;
    if (entry == null) return SaveResult.missing;
    _persistSaved(addSaved(savedState(), entry, _nowMs));
    _savedRev++;
    _setPending(hooks.syncAllowed());
    hooks.notice?.call(savedStatus == SavedStatus.pending && !hooks.online()
        ? 'Saved. It will sync to your other devices when you are back online.'
        : 'Saved to Saved messages.');
    _changed();
    unawaited(syncSaved());
    return SaveResult.saved;
  }

  Map<String, dynamic>? removeSavedEntry(String id) {
    final before = savedState();
    Map<String, dynamic>? entry;
    for (final e in before['items'] as List<Map<String, dynamic>>) {
      if (e['id'] == id) {
        entry = jsonDecode(jsonEncode(e)) as Map<String, dynamic>;
      }
    }
    _persistSaved(removeSaved(before, id, _nowMs));
    _savedRev++;
    _setPending(hooks.syncAllowed());
    _changed();
    unawaited(syncSaved());
    return entry;
  }

  void restoreSavedEntry(Map<String, dynamic> entry) {
    final id = entry['id'];
    if (id is! String || id.isEmpty) return;
    final state = savedState();
    if (isSaved(state, id)) return;
    final now = _nowMs;
    final sv = entry['sv'] is num ? (entry['sv'] as num).toInt() + 1 : 0;
    _persistSaved(addSaved(
        state, {...entry, 'sv': now > sv ? now : sv}, now));
    _savedRev++;
    _setPending(hooks.syncAllowed());
    _changed();
    unawaited(syncSaved());
  }

  Future<SavedStatus> syncSaved() async {
    if (!hooks.syncAllowed()) return SavedStatus.local;
    if (!savedPending) return SavedStatus.synced;
    final publish = hooks.publishSaved;
    if (publish == null || !hooks.online() || !hooks.hydrated()) {
      return SavedStatus.pending;
    }
    if (_syncing) {
      _resync = true;
      return SavedStatus.pending;
    }
    _syncing = true;
    _resync = false;
    final rev = _savedRev;
    var ok = false;
    try {
      final copy = jsonDecode(jsonEncode(savedState())) as Map<String, dynamic>;
      ok = await publish(copy);
    } catch (_) {
      ok = false;
    } finally {
      _syncing = false;
    }
    if (ok && rev == _savedRev) _setPending(false);
    _changed();
    if (_resync || (ok && rev != _savedRev)) {
      _resync = false;
      return syncSaved();
    }
    return savedStatus;
  }

  void applyRemoteSaved(dynamic remote) {
    if (remote is! Map) return;
    final merged = mergeSaved(savedState(), remote, _nowMs);
    final remoteNorm = mergeSaved(remote, null, _nowMs);
    _persistSaved(merged);
    _savedRev++;
    if (jsonEncode(merged) != jsonEncode(remoteNorm) && hooks.syncAllowed()) {
      _setPending(true);
      Timer.run(() => unawaited(syncSaved()));
    }
    _changed();
  }

  Map<String, dynamic>? _editsCache;

  bool _editsFlushQueued = false;

  void _persistEdits() {
    if (_editsFlushQueued) return;
    _editsFlushQueued = true;
    scheduleMicrotask(flushEdits);
  }

  void flushEdits() {
    if (!_editsFlushQueued) return;
    _editsFlushQueued = false;
    final cache = _editsCache;
    if (cache != null) _prefs.write(ChatToolsKeys.edits, jsonEncode(cache));
  }

  Map<String, dynamic> _edits() => _editsCache ??= _readMap(ChatToolsKeys.edits);

  void noteEdit(Message m, String nextContent, int editAtSec) {
    final key = chatDomId(m);
    if (key.isEmpty) return;
    final store = _edits();
    final prev = store[key] == null ? null : EditRecord.fromJson(store[key]);
    final rec = recordEdit(prev, m.content, nextContent, m.createdAt,
        editAtSec > 0 ? editAtSec : _nowSec);
    if (identical(rec, prev) ||
        (prev != null && jsonEncode(rec.toJson()) == jsonEncode(prev.toJson()))) {
      return;
    }
    store[key] = rec.toJson();
    _editsCache = pruneEditStore(store);
    _persistEdits();
  }

  void noteStaleEdit(Message m, String text, int editAtSec) {
    final key = chatDomId(m);
    if (key.isEmpty) return;
    final store = _edits();
    final prev = store[key] == null ? null : EditRecord.fromJson(store[key]);
    final rec = recordStaleEdit(prev, text, editAtSec, m.content);
    if (identical(rec, prev) ||
        rec.versions.isEmpty ||
        (prev != null && jsonEncode(rec.toJson()) == jsonEncode(prev.toJson()))) {
      return;
    }
    store[key] = rec.toJson();
    _editsCache = pruneEditStore(store);
    _persistEdits();
  }

  EditRecord? editHistoryFor(String domId) {
    final v = _edits()[domId];
    return v == null ? null : EditRecord.fromJson(v);
  }

  String _editSurface(Message m) =>
      m.isGroup ? 'group' : (m.isPM ? 'dm' : 'channel');

  EditHistoryPlan editHistoryPlanFor(Message m) => editHistoryPlan(
        editHistoryFor(chatDomId(m)),
        online: hooks.fetchEditEvents != null &&
            m.pubkey.isNotEmpty &&
            hooks.online(),
        mesh: m.viaMesh,
      );

  Future<String> fetchEditHistory(Message m) async {
    final domId = chatDomId(m);
    final fetcher = hooks.fetchEditEvents;
    if (domId.isEmpty || m.pubkey.isEmpty || fetcher == null) {
      return editHistoryPlan(editHistoryFor(domId), done: true).view;
    }
    final bag = <Map<String, dynamic>>[];
    var ok = false;
    try {
      bag.addAll(await fetcher(_editSurface(m), domId, m.createdAt)
          .timeout(hooks.editFetchTimeout));
      ok = true;
    } catch (_) {
      ok = false;
    }
    final live = hooks.findMessage?.call(domId)?.msg ?? m;
    final found = editSources(
        id: domId, pubkey: m.pubkey, at: m.createdAt, events: bag);
    final merged = mergeEditHistory(editHistoryFor(domId), found, live.content);
    if (ok || merged.versions.isNotEmpty) {
      final rec = ok
          ? merged
          : EditRecord(merged.versions, merged.editedAt);
      final store = _edits();
      store[domId] = rec.toJson();
      _editsCache = pruneEditStore(store);
      _editsFlushQueued = true;
      flushEdits();
    }
    return editHistoryPlan(editHistoryFor(domId), done: true).view;
  }

  Map<String, dynamic>? _keepCache;

  Map<String, dynamic> _keep() => _keepCache ??= _readMap(ChatToolsKeys.keep);

  bool isMessageKept(Message m) => isKept(_keep(), m.nymMessageId);

  bool keepAvailableFor(Message m, String storageKey) => keepAvailable(
        nid: m.nymMessageId,
        surface: chatSurfaceForKey(storageKey),
        expiresAt: m.expiresAt,
        kept: isMessageKept(m),
      );

  int _nextKeepAt(String nid) {
    final cur = _keep()[nid];
    final curAt = cur is Map && cur['at'] is num ? (cur['at'] as num).toInt() : 0;
    final now = _nowSec;
    return cur == null ? now : (now > curAt + 1 ? now : curAt + 1);
  }

  bool _applyKeep(String nid, bool kept, int at, String by) {
    final store = _keep();
    if (!applyKeep(store, nid, kept, at, by)) return false;
    _keepCache = pruneKeep(store);
    _prefs.write(ChatToolsKeys.keep, jsonEncode(_keepCache));
    _changed();
    return true;
  }

  Future<KeepRoute?> toggleKeep(Message m, String storageKey) async {
    if (!keepAvailableFor(m, storageKey)) return null;
    final nid = m.nymMessageId!;
    final kept = !isMessageKept(m);
    final at = _nextKeepAt(nid);
    _applyKeep(nid, kept, at, hooks.selfPubkey());
    KeepRoute? route;
    if (chatSurfaceForKey(storageKey) == 'dm') {
      final peer = storageKey.substring(3);
      final sendMesh = hooks.sendMeshKeep;
      if (sendMesh != null && hooks.meshPeerFor?.call(peer) != null) {
        try {
          if (await sendMesh(peer, nid, kept)) route = KeepRoute.mesh;
        } catch (_) {}
      }
    }
    var published = false;
    final publish = hooks.publishKeep;
    if (publish != null) {
      try {
        published = await publish(storageKey, nid, kept, at);
      } catch (_) {
        published = false;
      }
    }
    if (!published) {
      _outboxPush({'key': storageKey, 'nid': nid, 'kept': kept, 'at': at});
      route ??= KeepRoute.queued;
    }
    route ??= KeepRoute.sent;
    if (route == KeepRoute.queued) {
      hooks.notice?.call(kept
          ? "Kept here. Others will see it once you're back online."
          : "Unkept here. Others will see it once you're back online.");
    } else if (route == KeepRoute.mesh) {
      hooks.notice?.call(kept
          ? 'Kept. Sent over the Bluetooth mesh.'
          : 'Unkept. Sent over the Bluetooth mesh.');
    }
    return route;
  }

  List<Map<String, dynamic>> keepOutbox() {
    try {
      final raw = _prefs.read(ChatToolsKeys.keepOutbox);
      final v = raw == null ? null : jsonDecode(raw);
      if (v is! List) return [];
      return [
        for (final e in v)
          if (e is Map && e['key'] is String && e['nid'] is String)
            Map<String, dynamic>.from(e),
      ];
    } catch (_) {
      return [];
    }
  }

  void _outboxPush(Map<String, dynamic> entry) {
    final list = keepOutbox()
        .where((e) => !(e['key'] == entry['key'] && e['nid'] == entry['nid']))
        .toList()
      ..add(entry);
    while (list.length > 200) {
      list.removeAt(0);
    }
    _prefs.write(ChatToolsKeys.keepOutbox, jsonEncode(list));
  }

  bool _flushing = false;

  Future<void> flushKeepOutbox() async {
    final publish = hooks.publishKeep;
    if (_flushing || publish == null) return;
    final list = keepOutbox();
    if (list.isEmpty) return;
    _flushing = true;
    final left = <Map<String, dynamic>>[];
    try {
      for (final e in list) {
        var ok = false;
        try {
          ok = await publish(e['key'] as String, e['nid'] as String,
              e['kept'] == true, (e['at'] as num?)?.toInt() ?? _nowSec);
        } catch (_) {
          ok = false;
        }
        if (!ok) left.add(e);
      }
    } finally {
      _flushing = false;
      _prefs.write(ChatToolsKeys.keepOutbox, jsonEncode(left));
    }
  }

  bool handleKeepRumor(Map<String, dynamic> rumor, String sender) {
    if ((rumor['kind'] as num?)?.toInt() != 69420) return false;
    final p = parseKeep(rumor['tags'] as List?);
    if (p == null) return false;
    if (sender.isEmpty) return true;
    final self = hooks.selfPubkey();
    if (p.groupId != null) {
      final members = hooks.groupMembers?.call(p.groupId!);
      if (members == null || !members.contains(sender)) return true;
    }
    final at = (rumor['created_at'] as num?)?.toInt() ?? _nowSec;
    for (final id in p.ids) {
      final found = hooks.findMessage?.call(id);
      if (found != null) {
        final surface = chatSurfaceForKey(found.key);
        if (p.groupId != null && found.key != 'group-${p.groupId}') continue;
        if (p.groupId == null && surface != 'dm') continue;
        if (p.groupId == null &&
            sender != self &&
            sender != found.key.substring(3)) {
          continue;
        }
      }
      _applyKeep(id, p.kept, at, sender);
    }
    return true;
  }

  bool handleMeshKeep(String messageId, String byPubkey) {
    final parsed = parseMeshKeepId(messageId);
    if (parsed == null) return false;
    final found = hooks.findMessage?.call(parsed.id);
    if (found != null &&
        chatSurfaceForKey(found.key) == 'dm' &&
        found.key.substring(3) != byPubkey) {
      return true;
    }
    _applyKeep(parsed.id, parsed.kept, _nextKeepAt(parsed.id), byPubkey);
    return true;
  }
}
