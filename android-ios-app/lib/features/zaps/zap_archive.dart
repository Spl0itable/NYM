import 'dart:async';
import 'dart:convert';

import '../../models/nostr_event.dart';
import '../../services/api/storage_sync.dart';

/// Ports the PWA's zap-receipt D1 archive (zaps.js:29-93):
///
///  * every valid public kind-9735 receipt observed (inbound OR our own
///    published announce) is queued for an authed `zap-put`, deduped by event
///    id (cap 6000, trimmed to 4000), flushed after 4s in batches of 100
///    (`_archiveZapReceipt` / `_flushZapArchive`);
///  * message-history hydration backfills archived receipts via the public
///    NDJSON `zap-get` (`_backfillZapReceipts` / `_backfillZapReceiptsFromD1`),
///    feeding each through the SAME ingest path live receipts take.
///
/// The archive scope comes from the `k` tag inside the receipt's zap-request
/// `description`: 20000/23333 → `channel`, 1059 → `pm`, 0 → `profile`
/// (zaps.js:46-56). Channel/pm receipts must carry a hex64 `e` tag (the
/// zapped message id); profile receipts have none (the server keys them on
/// the recipient pubkey).
class ZapArchive {
  ZapArchive(this._sync);

  final StorageSync _sync;

  /// Session receipt-id dedup (`_zapArchivedIds`, cap 6000 → trim 4000).
  final Set<String> _archivedIds = <String>{};

  /// Pending receipts awaiting the debounced `zap-put` (`_zapArchiveQueue`,
  /// cap 300 — oldest dropped).
  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];

  Timer? _flushTimer;
  bool _disposed = false;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  /// The archive scope from the receipt's `description` zap request
  /// (zaps.js:46-56): `'channel'` | `'pm'` | `'profile'`, or null when the
  /// description is absent/unparseable or its `k` tag isn't one we archive.
  static String? scopeFor(NostrEvent event) {
    final description = event.tagValue('description');
    if (description == null || description.isEmpty) return null;
    try {
      final req = jsonDecode(description);
      if (req is! Map) return null;
      final tags = req['tags'];
      if (tags is! List) return null;
      for (final t in tags) {
        if (t is List && t.isNotEmpty && t[0] == 'k') {
          final k = t.length > 1 ? '${t[1]}' : '';
          if (k == '20000' || k == '23333') return 'channel';
          if (k == '1059') return 'pm';
          if (k == '0') return 'profile';
          return null;
        }
      }
    } catch (_) {
      // Ignore parse errors (zaps.js:55).
    }
    return null;
  }

  /// Queues [event] (a kind-9735 receipt WITH a bolt11 — the caller gates on
  /// that, zaps.js:1164) for the batched `zap-put`. No-ops on a non-receipt,
  /// an unarchivable scope, a channel/pm receipt without a hex64 `e` tag, or
  /// an id already archived this session. Mirrors `_archiveZapReceipt`.
  void archive(NostrEvent event) {
    if (_disposed) return;
    if (event.kind != 9735 || event.id.isEmpty) return;
    final scope = scopeFor(event);
    if (scope == null) return;
    // Channel/pm zaps key on the zapped event id; profile zaps have no e tag
    // (the server keys them on the recipient pubkey instead).
    if (scope != 'profile') {
      final targetId = event.tagValue('e');
      if (targetId == null || !_hex64.hasMatch(targetId)) return;
    }
    if (!_archivedIds.add(event.id)) return;
    if (_archivedIds.length > 6000) {
      final keep = _archivedIds.toList().sublist(_archivedIds.length - 4000);
      _archivedIds
        ..clear()
        ..addAll(keep);
    }
    _queue.add(event.toJson());
    if (_queue.length > 300) _queue.removeAt(0);
    _flushTimer ??= Timer(const Duration(seconds: 4), _flush);
  }

  /// Sends one 100-receipt batch (`zap-put`), re-arming the 4s timer while a
  /// backlog remains (`_flushZapArchive`).
  Future<void> _flush() async {
    _flushTimer = null;
    if (_disposed || _queue.isEmpty) return;
    final n = _queue.length < 100 ? _queue.length : 100;
    final batch = _queue.sublist(0, n);
    _queue.removeRange(0, n);
    await _sync.zapPut(batch);
    if (_queue.isNotEmpty && !_disposed) {
      _flushTimer ??= Timer(const Duration(seconds: 4), _flush);
    }
  }

  /// Backfills archived receipts for the zapped-message [ids] from D1
  /// (`_backfillZapReceiptsFromD1`): a public `zap-get` for [scope]
  /// (`'pm'` | `'channel'` | `'profile'`), routing every returned receipt
  /// through [onReceipt] — the same handler live kind-9735 events take
  /// (`handleZapReceipt`). Ids are validated/deduped and capped at 500
  /// (`_backfillZapReceipts`). Best-effort; failures are swallowed.
  Future<void> backfill(
    List<String> ids,
    String scope,
    void Function(NostrEvent receipt) onReceipt,
  ) async {
    if (_disposed || ids.isEmpty) return;
    final events = await _sync.zapGet(scope, ids);
    for (final raw in events) {
      try {
        onReceipt(NostrEvent.fromJson(raw));
      } catch (_) {
        // Skip a malformed archived receipt.
      }
    }
  }

  /// Cancels the pending flush (identity switch / shutdown).
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
