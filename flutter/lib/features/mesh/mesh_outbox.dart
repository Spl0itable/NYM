// Sender outbox: sends that went mesh-only are retained and published to Nostr once relays return; pure and IO-free.

import 'dart:convert';

/// Which conversation surface an entry replays into.
enum MeshOutboxKind { channel, pm }

class MeshOutboxEntry {
  MeshOutboxEntry({
    required this.kind,
    required this.target,
    required this.content,
    required this.createdAtSec,
    required this.localId,
    this.threadRoot,
    this.meshMessageId,
    this.nymMessageId,
    this.signedEvent,
    this.owner,
    this.attempts = 0,
  });

  /// channel replays as a public channel message; pm as a gift-wrapped DM.
  final MeshOutboxKind kind;

  /// Bare channel key or the peer's real Nostr pubkey, never a mesh-only synthetic pubkey.
  final String target;

  final String content;

  /// Thread root, so a queued reply lands back in its thread.
  final String? threadRoot;

  /// Original send time, used for the replay so history order holds and the optimistic echo reconciles.
  final int createdAtSec;

  /// Optimistic echo id, so publish swaps in the real id and a drop marks the bubble failed.
  final String localId;

  /// Republished as `['nymmesh', id]` so peers who got the radio copy drop the Nostr one.
  final String? meshMessageId;

  /// A PM's shared cross-recipient id, deduping mesh and Nostr copies.
  final String? nymMessageId;

  /// Event signed at send time; republishing the same bytes keeps one event id and the original content.
  final Map<String, dynamic>? signedEvent;

  final String? owner;

  /// Publish attempts spent, bounded so a dead relay set can't retry forever.
  int attempts;

  bool belongsTo(String pubkey) {
    final signed = signedEvent?['pubkey'];
    final who = owner ?? (signed is String ? signed : null);
    return who == null || who.isEmpty || who == pubkey;
  }

  MeshOutboxEntry ownedBy(String pubkey) => MeshOutboxEntry(
        kind: kind,
        target: target,
        content: content,
        createdAtSec: createdAtSec,
        localId: localId,
        threadRoot: threadRoot,
        meshMessageId: meshMessageId,
        nymMessageId: nymMessageId,
        signedEvent: signedEvent,
        owner: pubkey,
        attempts: attempts,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'target': target,
        'content': content,
        'createdAt': createdAtSec,
        'localId': localId,
        if (threadRoot != null) 'threadRoot': threadRoot,
        if (meshMessageId != null) 'meshMessageId': meshMessageId,
        if (nymMessageId != null) 'nymMessageId': nymMessageId,
        if (signedEvent != null) 'signedEvent': signedEvent,
        if (owner != null) 'owner': owner,
        if (attempts > 0) 'attempts': attempts,
      };

  /// Null for a row missing required fields, so a corrupt blob costs one message rather than throwing.
  static MeshOutboxEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kindName = raw['kind'];
    final target = raw['target'];
    final content = raw['content'];
    final createdAt = raw['createdAt'];
    final localId = raw['localId'];
    if (kindName is! String ||
        target is! String ||
        content is! String ||
        createdAt is! num ||
        localId is! String) {
      return null;
    }
    if (target.isEmpty || content.isEmpty) return null;
    MeshOutboxKind? kind;
    for (final k in MeshOutboxKind.values) {
      if (k.name == kindName) kind = k;
    }
    if (kind == null) return null;
    String? str(String k) => raw[k] is String ? raw[k] as String : null;
    return MeshOutboxEntry(
      kind: kind,
      target: target,
      content: content,
      createdAtSec: createdAt.toInt(),
      localId: localId,
      threadRoot: str('threadRoot'),
      meshMessageId: str('meshMessageId'),
      nymMessageId: str('nymMessageId'),
      signedEvent: raw['signedEvent'] is Map
          ? Map<String, dynamic>.from(raw['signedEvent'] as Map)
          : null,
      owner: str('owner'),
      attempts: raw['attempts'] is num ? (raw['attempts'] as num).toInt() : 0,
    );
  }
}

/// Retained sends, oldest first, bounded by [ttlMs], [cap] and [maxAttempts]; [onDropped] reports undelivered drops.
class MeshOutbox {
  MeshOutbox({this.onDropped});

  /// 24 hours, matching the mesh's store-and-forward window.
  static const int ttlMs = 24 * 60 * 60 * 1000;

  /// Bounded because this survives restarts.
  static const int cap = 200;

  /// Publish attempts before an entry is given up on.
  static const int maxAttempts = 3;

  final void Function(String localId)? onDropped;

  final List<MeshOutboxEntry> _entries = <MeshOutboxEntry>[];

  List<MeshOutboxEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  int get length => _entries.length;

  /// Retains [entry], dropping the oldest past [cap]; a repeated localId is ignored.
  void add(MeshOutboxEntry entry) {
    if (_entries.any((e) => e.localId == entry.localId)) return;
    _entries.add(entry);
    while (_entries.length > cap) {
      final evicted = _entries.removeAt(0);
      onDropped?.call(evicted.localId);
    }
  }

  /// Removes the entry for [localId]; returns whether one was held.
  bool remove(String localId) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.localId == localId);
    return _entries.length != before;
  }

  /// Drops entries older than [ttlMs], reporting each; returns whether any went.
  bool prune(int nowMs) {
    final cutoffSec = (nowMs - ttlMs) ~/ 1000;
    final expired = _entries
        .where((e) => e.createdAtSec <= cutoffSec)
        .toList(growable: false);
    if (expired.isEmpty) return false;
    for (final e in expired) {
      _entries.remove(e);
      onDropped?.call(e.localId);
    }
    return true;
  }

  /// Separate from [add] so the enqueue never waits on proof-of-work signing; returns whether an entry was updated.
  bool attachSignedEvent(String localId, Map<String, dynamic> event) {
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (e.localId != localId) continue;
      if (e.signedEvent != null) return false;
      _entries[i] = MeshOutboxEntry(
        kind: e.kind,
        target: e.target,
        content: e.content,
        createdAtSec: e.createdAtSec,
        localId: e.localId,
        threadRoot: e.threadRoot,
        meshMessageId: e.meshMessageId,
        nymMessageId: e.nymMessageId,
        signedEvent: event,
        owner: e.owner,
        attempts: e.attempts,
      );
      return true;
    }
    return false;
  }

  List<MeshOutboxEntry> due(int nowMs) {
    prune(nowMs);
    return List.unmodifiable(_entries);
  }

  /// Records a spent attempt, dropping the entry at [maxAttempts]; true when dropped.
  bool noteAttempt(String localId) {
    for (final e in _entries) {
      if (e.localId != localId) continue;
      e.attempts++;
      if (e.attempts >= maxAttempts) {
        _entries.remove(e);
        onDropped?.call(e.localId);
        return true;
      }
      return false;
    }
    return false;
  }

  /// Empties without reporting drops, for sign-out or panic.
  void clear() => _entries.clear();

  String encode() => jsonEncode([for (final e in _entries) e.toJson()]);

  /// Unparseable rows are skipped; a wholly unparseable blob leaves the queue empty.
  void decode(String? raw) {
    _entries.clear();
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final row in decoded) {
        final e = MeshOutboxEntry.fromJson(row);
        if (e != null) _entries.add(e);
      }
    } catch (_) {
      _entries.clear();
    }
    while (_entries.length > cap) {
      _entries.removeAt(0);
    }
  }
}
