import 'dart:async';
import 'dart:convert';

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import '../../services/api/storage_sync.dart';
import '../../services/nostr/verified_rows.dart';

/// D1 archive of public kind-9735 receipts: batched `zap-put` uploads and `zap-get` backfill.
class ZapArchive {
  ZapArchive(this._sync, {Future<bool> Function(NostrEvent event)? verify})
      : _verify = verify ?? _verifyInline;

  final StorageSync _sync;
  final Future<bool> Function(NostrEvent event) _verify;

  static Future<bool> _verifyInline(NostrEvent event) async =>
      schnorr.verifyEvent(event);

  /// Session receipt-id dedup (cap 6000, trimmed to 4000).
  final Set<String> _archivedIds = <String>{};

  /// Pending receipts for the debounced `zap-put` (cap 300, oldest dropped).
  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];

  Timer? _flushTimer;
  bool _disposed = false;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  /// Archive scope from the receipt's zap-request `k` tag, or null if absent or not archived.
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
      // Ignore parse errors.
    }
    return null;
  }

  /// Queues a bolt11-bearing receipt for `zap-put`; skips unarchivable scopes, missing `e` tags and repeats.
  void archive(NostrEvent event) {
    if (_disposed) return;
    if (event.kind != 9735 || event.id.isEmpty) return;
    final scope = scopeFor(event);
    if (scope == null) return;
    // Channel/pm zaps key on the zapped event id; profile zaps are keyed on the recipient server-side.
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

  /// Sends one 100-receipt batch, re-arming the 4s timer while a backlog remains.
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

  /// Backfills receipts for [ids] (max 500) through [onReceipt]; best-effort.
  Future<void> backfill(
    List<String> ids,
    String scope,
    void Function(NostrEvent receipt) onReceipt,
  ) async {
    if (_disposed || ids.isEmpty) return;
    final events = await _sync.zapGet(scope, ids);
    for (final receipt in await verifiedRows(events, _verify)) {
      try {
        onReceipt(receipt);
      } catch (_) {}
    }
  }

  /// Cancels the pending flush on identity switch or shutdown.
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
