// mesh_outbox.dart - The sender outbox.
//
// With no internet, an outgoing message rides the Bluetooth mesh instead of
// Nostr (`MeshBridge.shouldSendOverMesh`). That reaches whoever is in radio
// range and NOBODY else — the message never existed as far as the relays are
// concerned, and nothing ever went back for it. Someone who was two rooms away,
// or reading from another device, simply never saw it.
//
// This is the queue that closes that gap, mirroring bitchat's
// `MessageRouter`/`MessageOutboxStore` pair: a send that could not reach Nostr
// is retained here, and the moment relays come back the controller publishes it
// (`NostrController.flushMeshOutbox`). The mesh copy still went out immediately
// — this is the second, slower delivery path, not a replacement for it.
//
// Deliberately free of Riverpod and IO: entries are plain data and every rule
// (TTL, cap, attempt ceiling) is a pure function of `nowMs`, so the whole
// policy is unit-testable without a relay, a radio, or a disk.

import 'dart:convert';

/// Which conversation surface an outbox entry replays into.
enum MeshOutboxKind { channel, pm }

/// One retained send.
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
    this.attempts = 0,
  });

  /// channel → replayed as a public channel message; pm → as a gift-wrapped DM.
  final MeshOutboxKind kind;

  /// The bare channel key (`nymchat`, a geohash) or the peer's REAL Nostr
  /// pubkey. A mesh-only peer's synthetic `sha256("mesh:…")` pubkey must never
  /// reach here — there is no Nostr identity behind it to deliver to.
  final String target;

  final String content;

  /// The thread this reply belongs to, so a queued send lands back in its
  /// thread rather than at the bottom of the flat conversation.
  final String? threadRoot;

  /// The original send time. The replay publishes with THIS, not with the time
  /// the relays happened to come back: it keeps the message where it belongs in
  /// history, and it is what lets the sender's own optimistic echo reconcile
  /// (the channel ingest matches a placeholder within 60s of the event) however
  /// long the entry sat in the queue.
  final int createdAtSec;

  /// The optimistic echo this entry belongs to, so the publish can swap in the
  /// real event id — and a drop can mark the bubble failed instead of leaving
  /// it looking sent forever.
  final String localId;

  /// The id the mesh copy carried. Republished as a `['nymmesh', id]` tag so a
  /// peer who already received this over the radio drops the Nostr copy instead
  /// of showing the message twice.
  final String? meshMessageId;

  /// A PM's shared cross-recipient id. The mesh DM already used it, so reusing
  /// it here dedups the two copies through the ordinary PM path.
  final String? nymMessageId;

  /// The event signed at send time, as raw JSON, when one could be built.
  ///
  /// Gateway mode may already be carrying this exact event to the relays.
  /// Republishing the SAME bytes means the same event id, so the relays treat
  /// the second copy as a duplicate; rebuilding it here would differ by the
  /// proof-of-work nonce alone and put the message on the relays twice. It is
  /// also what the user actually wrote — a rebuild hours later would re-read
  /// the current nym and settings.
  final Map<String, dynamic>? signedEvent;

  /// Publish attempts spent. Bounded so a message to a dead relay set cannot
  /// retry forever.
  int attempts;

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
        if (attempts > 0) 'attempts': attempts,
      };

  /// Rebuilds an entry from persisted JSON. Null for a row missing anything the
  /// replay needs, so a corrupt blob costs one message rather than throwing on
  /// every boot.
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
      attempts: raw['attempts'] is num ? (raw['attempts'] as num).toInt() : 0,
    );
  }
}

/// The retained sends, oldest first.
///
/// Every bound here exists so an outbox cannot grow without limit or replay
/// something the user has long since given up on:
/// * [ttlMs] — 24h, the same window the bell history and the mesh's own
///   store-and-forward use. Past it a message is stale enough that surfacing it
///   would confuse rather than help.
/// * [cap] — the newest [cap] entries survive; the oldest are dropped first.
/// * [maxAttempts] — a publish that keeps failing (relays up, but rejecting)
///   stops rather than looping.
///
/// [onDropped] fires with the entry's [MeshOutboxEntry.localId] whenever one
/// leaves without being delivered, so the UI can fail the bubble instead of
/// leaving it looking sent.
class MeshOutbox {
  MeshOutbox({this.onDropped});

  /// 24 hours, matching the mesh's own store-and-forward window.
  static const int ttlMs = 24 * 60 * 60 * 1000;

  /// Most retained sends. Bounded because this survives restarts.
  static const int cap = 200;

  /// Publish attempts before an entry is given up on.
  static const int maxAttempts = 3;

  final void Function(String localId)? onDropped;

  final List<MeshOutboxEntry> _entries = <MeshOutboxEntry>[];

  /// The retained sends, oldest first. Read-only.
  List<MeshOutboxEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  int get length => _entries.length;

  /// Retains [entry], dropping the oldest if that would exceed [cap]. An entry
  /// whose [MeshOutboxEntry.localId] is already held is ignored, so a repeated
  /// enqueue for one echo cannot double-publish.
  void add(MeshOutboxEntry entry) {
    if (_entries.any((e) => e.localId == entry.localId)) return;
    _entries.add(entry);
    while (_entries.length > cap) {
      final evicted = _entries.removeAt(0);
      onDropped?.call(evicted.localId);
    }
  }

  /// Removes the entry for [localId] (delivered, or given up on). Returns
  /// whether anything was held.
  bool remove(String localId) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.localId == localId);
    return _entries.length != before;
  }

  /// Drops everything older than [ttlMs] at [nowMs], reporting each. Returns
  /// whether anything went.
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

  /// The entries a flush should publish at [nowMs]: everything still inside the
  /// TTL, oldest first, so a conversation replays in the order it was written.
  /// Prunes as a side effect — an expired entry is never handed out.
  /// Attaches the event signed at send time to an entry already queued.
  ///
  /// Separate from [add] because the enqueue must not wait on it: signing mines
  /// proof of work, and a message must be durably queued the moment the radio
  /// carried it, not a second later. Returns whether an entry was updated.
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

  /// Records a spent publish attempt for [localId], dropping the entry once it
  /// reaches [maxAttempts]. Returns true when the entry was dropped.
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

  /// Empties the queue WITHOUT reporting drops — sign-out / panic, where the
  /// messages are being discarded along with everything else.
  void clear() => _entries.clear();

  /// Serializes for [StorageKeys.meshOutbox].
  String encode() => jsonEncode([for (final e in _entries) e.toJson()]);

  /// Replaces the contents from a persisted blob. Unparseable rows are skipped;
  /// a wholly unparseable blob leaves the queue empty rather than throwing.
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
