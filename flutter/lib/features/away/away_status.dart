import 'dart:async';
import 'dart:math';

import 'away_sync.dart';

class AwayStatusEngine {
  AwayStatusEngine({
    required this.selfPubkey,
    required this.syncAllowed,
    required this.read,
    required this.write,
    required this.reflect,
    required this.publishPresence,
    required this.publishSync,
    required this.hydrated,
    required this.messagesIn,
    required this.sendReply,
    int Function()? now,
    double Function()? random,
  })  : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random().nextDouble;

  final String? Function() selfPubkey;
  final bool Function() syncAllowed;
  final String? Function(String key) read;
  final void Function(String key, String value) write;
  final void Function(String pubkey, AwayState? state) reflect;
  final Future<void> Function(String status, String message) publishPresence;
  final Future<bool> Function(Map<String, dynamic> payload) publishSync;
  final bool Function() hydrated;
  final Iterable<Map<String, Object?>> Function(String channelKey) messagesIn;
  final Future<void> Function(String channelKey, String text) sendReply;
  final int Function() _now;
  final double Function() _random;

  AwayState? _state;
  String? _restoredFor;
  bool _pending = false;
  final Set<String> _replied = <String>{};
  final Set<Timer> _timers = <Timer>{};

  AwayState? get state {
    ensureRestored();
    return _state;
  }

  bool get isAway => state?.enabled == true;

  String get message => isAway ? _state!.message : '';

  void ensureRestored() {
    final pk = selfPubkey();
    if (pk == null || pk.isEmpty || _restoredFor == pk) return;
    final prev = _restoredFor;
    _restoredFor = pk;
    _cancelReplies();
    if (prev != null) reflect(prev, null);
    AwayState? restored;
    if (syncAllowed()) restored = AwaySync.decode(read(AwaySync.storageKey(pk)));
    _state = restored;
    _pending = false;
    reflect(pk, restored);
  }

  void _store(AwayState next) {
    _state = next;
    if (!syncAllowed()) return;
    final pk = selfPubkey();
    final encoded = AwaySync.encode(next);
    if (pk == null || pk.isEmpty || encoded == null) return;
    write(AwaySync.storageKey(pk), encoded);
  }

  void _cancelReplies() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _replied.clear();
  }

  void _show(AwayState next) {
    final pk = selfPubkey();
    if (pk != null) reflect(pk, next);
  }

  Future<void> _announce(AwayState next) async {
    _show(next);
    final p = AwaySync.presence(next);
    await publishPresence(p['status']!, p['message']!);
  }

  Future<AwayState> enable(String message) async {
    ensureRestored();
    final next = AwaySync.enable(_state, message, _now());
    _store(next);
    _cancelReplies();
    _show(next);
    await _sync();
    await _announce(next);
    return next;
  }

  Future<bool> disable() async {
    ensureRestored();
    if (_state?.enabled != true) return false;
    final next = AwaySync.disable(_state, _now());
    _store(next);
    _cancelReplies();
    _show(next);
    await _sync();
    await _announce(next);
    return true;
  }

  Future<bool> _sync() async {
    if (!syncAllowed()) return false;
    final payload = AwaySync.payload(_state);
    if (payload == null) return false;
    if (!hydrated()) {
      _pending = true;
      return false;
    }
    _pending = false;
    var ok = false;
    try {
      ok = await publishSync(payload);
    } catch (_) {
      ok = false;
    }
    if (!ok) _pending = true;
    return ok;
  }

  Future<void> flushPending() async {
    ensureRestored();
    if (!_pending) return;
    await _sync();
  }

  Future<void> applyRemote(Object? raw) async {
    ensureRestored();
    if (!syncAllowed()) return;
    final remote = AwaySync.normalize(raw);
    if (remote == null) return;
    final local = _state;
    final merged = AwaySync.merge(local, remote);
    if (merged == null) return;
    if (AwaySync.encode(merged) != AwaySync.encode(remote)) {
      await _sync();
      return;
    }
    if (AwaySync.encode(local) == AwaySync.encode(merged)) return;
    final before = AwaySync.presence(local);
    _store(merged);
    final after = AwaySync.presence(merged);
    if (before['status'] == after['status'] &&
        before['message'] == after['message']) {
      return;
    }
    _cancelReplies();
    await _announce(merged);
  }

  void maybeAutoReply({
    required String nym,
    required String channelKey,
    required String senderPubkey,
    required bool mentioned,
    required bool historical,
  }) {
    ensureRestored();
    final self = selfPubkey() ?? '';
    if (!AwaySync.shouldAutoReply(
      state: _state,
      selfPubkey: self,
      senderPubkey: senderPubkey,
      mentioned: mentioned,
      historical: historical,
    )) {
      return;
    }
    final key = AwaySync.sessionKey(self, nym);
    if (!_replied.add(key)) return;
    final armed = _state!;
    late final Timer timer;
    timer = Timer(Duration(milliseconds: AwaySync.delayMs(_random())), () {
      _timers.remove(timer);
      final current = _state;
      if (selfPubkey() != self ||
          current == null ||
          !current.enabled ||
          current.updatedAt != armed.updatedAt) {
        return;
      }
      if (AwaySync.hasOwnAutoReply(messagesIn(channelKey), self, nym,
          AwaySync.sinceSec(current))) {
        return;
      }
      unawaited(sendReply(
              channelKey, AwaySync.autoReplyText(nym, current.message))
          .catchError((_) {}));
    });
    _timers.add(timer);
  }
}
