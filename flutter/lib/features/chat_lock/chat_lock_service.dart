import 'dart:async';
import 'dart:convert';

import '../chat_tools/chat_tools_service.dart' show ChatToolsPrefs;
import 'chat_lock.dart';

abstract class ChatLockAuthenticator {
  Future<bool> deviceAvailable();

  Future<bool?> deviceAuth(String reason);
}

class ChatLockPromptResult {
  const ChatLockPromptResult({this.values = const [], this.alt = false});
  final List<String> values;
  final bool alt;
}

typedef ChatLockPrompter = Future<ChatLockPromptResult?> Function({
  required String title,
  required String body,
  required List<String> fields,
  required String ok,
  String? alt,
  String error,
});

class ChatLockHooks {
  const ChatLockHooks({
    required this.selfPubkey,
    this.online = _never,
    this.hydrated = _always,
    this.syncAllowed = _always,
    this.publishLocked,
    this.vaultMethod,
    this.verifyVaultPassword,
    this.currentKey,
    this.onRelock,
    this.onChanged,
    this.notice,
    this.now,
  });

  static bool _never() => false;
  static bool _always() => true;

  final String Function() selfPubkey;
  final bool Function() online;
  final bool Function() hydrated;
  final bool Function() syncAllowed;
  final Future<bool> Function(Map<String, dynamic> locked)? publishLocked;
  final String Function()? vaultMethod;
  final Future<bool> Function(String password)? verifyVaultPassword;
  final String? Function()? currentKey;
  final void Function()? onRelock;
  final void Function()? onChanged;
  final void Function(String text)? notice;
  final int Function()? now;
}

String chatLockFill(String s, Map<String, Object?> vars) {
  var out = s;
  vars.forEach((k, v) => out = out.split('{$k}').join('$v'));
  return out;
}

class ChatLockService {
  ChatLockService(this._prefs, this.hooks,
      {this.authenticator, this.prompter, String Function(String)? tr})
      : _tr = tr ?? ((s) => s);

  final ChatToolsPrefs _prefs;
  final ChatLockHooks hooks;
  ChatLockAuthenticator? authenticator;
  ChatLockPrompter? prompter;
  final String Function(String) _tr;

  int get _nowMs => hooks.now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  String t(String s, [Map<String, Object?>? vars]) =>
      vars == null ? _tr(s) : chatLockFill(_tr(s), vars);

  void _changed() => hooks.onChanged?.call();

  String get _stateKey => '${ChatLockKeys.locked}:${hooks.selfPubkey()}';
  String get _pendingKey =>
      '${ChatLockKeys.lockedPending}:${hooks.selfPubkey()}';

  Map<String, dynamic>? _cache;
  String? _cachePk;
  int _rev = 0;
  bool _syncing = false;
  bool _resync = false;
  LockSession _session = LockSession.idle;
  bool _revealed = false;
  bool _authing = false;
  bool bypass = false;
  int passcodeIterations = ChatLockLimits.passcodeIterations;

  Map<String, dynamic> state() {
    final pk = hooks.selfPubkey();
    if (_cache != null && _cachePk == pk) return _cache!;
    Map<String, dynamic> s;
    try {
      final raw = _prefs.read(_stateKey);
      s = raw == null || raw.isEmpty ? emptyLocks() : normalizeLocks(jsonDecode(raw));
    } catch (_) {
      s = emptyLocks();
    }
    _cache = s;
    _cachePk = pk;
    return s;
  }

  void _persist(Map<String, dynamic> s) {
    _cache = s;
    _cachePk = hooks.selfPubkey();
    _prefs.write(_stateKey, jsonEncode(s));
  }

  bool get pending => _prefs.read(_pendingKey) == '1';

  void _setPending(bool on) {
    if (on) {
      _prefs.write(_pendingKey, '1');
    } else {
      _prefs.remove(_pendingKey);
    }
  }

  List<String> get lockedKeys => lockList(state());

  bool isChatLocked(String lockKey) => isLocked(state(), lockKey);

  bool isConversationLocked(String? chatKey) =>
      isLocked(state(), lockKeyForChat(chatKey, hooks.selfPubkey()));

  bool get unlocked => _session.unlocked;

  LockSession get session => _session;

  bool get revealed => _revealed;

  set revealed(bool on) {
    if (_revealed == on) return;
    _revealed = on;
    _changed();
  }

  int get relockMinutes => normalizeRelock(_prefs.read(ChatLockKeys.relock));

  set relockMinutes(int n) {
    _prefs.write(ChatLockKeys.relock, '${normalizeRelock(n)}');
    _changed();
  }

  bool get screenSecurity => _prefs.read(ChatLockKeys.screenSecurity) == '1';

  set screenSecurity(bool on) {
    if (on) {
      _prefs.write(ChatLockKeys.screenSecurity, '1');
    } else {
      _prefs.remove(ChatLockKeys.screenSecurity);
    }
    _changed();
  }

  bool get incognitoKeyboard =>
      _prefs.read(ChatLockKeys.incognitoKeyboard) == '1';

  set incognitoKeyboard(bool on) {
    if (on) {
      _prefs.write(ChatLockKeys.incognitoKeyboard, '1');
    } else {
      _prefs.remove(ChatLockKeys.incognitoKeyboard);
    }
    _changed();
  }

  LockSession sessionEvent(String type) {
    final before = _session;
    _session = sessionStep(before, type, now: _nowMs, relock: relockMinutes);
    if (before.unlocked && !_session.unlocked) {
      _revealed = false;
      if (type != 'leave') hooks.onRelock?.call();
    }
    if (before.unlocked != _session.unlocked) _changed();
    return _session;
  }

  void lockNow() => sessionEvent('lock');

  bool blocks(String? chatKey) {
    if (chatKey == null || chatKey.isEmpty) return false;
    return !sessionAllows(_session, state(), chatKey, hooks.selfPubkey());
  }

  bool beforeOpen(String? fromKey, String? toKey, void Function() retry) {
    if (bypass || toKey == null || toKey.isEmpty) return true;
    if (blocks(toKey)) {
      if (_authing) return false;
      _authing = true;
      unawaited(authenticate().then((ok) {
        _authing = false;
        if (!ok) return;
        sessionEvent('unlock');
        bypass = true;
        try {
          retry();
        } finally {
          bypass = false;
        }
      }, onError: (Object _) {
        _authing = false;
      }));
      return false;
    }
    if (fromKey != null &&
        !_revealed &&
        leavesLocked(state(), fromKey, toKey, hooks.selfPubkey())) {
      sessionEvent('leave');
    }
    return true;
  }

  Future<bool> toggleLock(String lockKey) async {
    if (lockParse(lockKey) == null) return false;
    if (lockKey == 'c:nymchat') {
      hooks.notice?.call(t(ChatLockStrings.defaultLocked));
      return false;
    }
    if (!await authenticate()) return false;
    final s = state();
    if (isLocked(s, lockKey)) {
      _commit(lockRemove(s, lockKey, _nowMs));
      hooks.notice?.call(t(ChatLockStrings.unlocked));
      return true;
    }
    final r = lockAdd(s, lockKey, _nowMs);
    if (r.error == 'cap') {
      hooks.notice
          ?.call(t(ChatLockStrings.lockCap, {'n': ChatLockLimits.lockMax}));
      return false;
    }
    if (r.error != null) return false;
    sessionEvent('unlock');
    _commit(r.state);
    hooks.notice?.call(t(ChatLockStrings.locked));
    return true;
  }

  String setHide(bool on, String code) {
    final r = setHidden(state(), on, code, _nowMs);
    if (r.error != null) return codeError(_tr);
    _commit(r.state);
    return '';
  }

  bool matchesSecret(String term) => secretMatches(state(), term);

  bool get entryShown => entryVisible(state(), _revealed);

  ChatLockBadges badgesFor(Iterable<({String key, Object? n})> entries) =>
      badges(entries, state(), hooks.selfPubkey(), _revealed);

  bool notificationIsLocked(String? type, String? route, String? sender) =>
      notificationLocked(state(), type, route, sender);

  ({String title, String body, bool locked}) redact(
          String title, String body, bool locked) =>
      notificationText(title, body, locked, _tr);

  void _commit(Map<String, dynamic> s) {
    _persist(s);
    _rev++;
    _setPending(hooks.syncAllowed());
    _changed();
    unawaited(sync());
  }

  void applyRemote(dynamic remote) {
    if (remote is! Map) return;
    final merged = mergeLocks(state(), remote, _nowMs);
    final remoteNorm = mergeLocks(remote, null, _nowMs);
    _persist(merged);
    _rev++;
    if (jsonEncode(merged) != jsonEncode(remoteNorm) && hooks.syncAllowed()) {
      _setPending(true);
      Timer.run(() => unawaited(sync()));
    }
    _changed();
    final cur = hooks.currentKey?.call();
    if (cur != null && blocks(cur)) hooks.onRelock?.call();
  }

  Future<bool> sync() async {
    if (!hooks.syncAllowed()) return false;
    if (!pending) return true;
    final publish = hooks.publishLocked;
    if (publish == null || !hooks.online() || !hooks.hydrated()) return false;
    if (_syncing) {
      _resync = true;
      return false;
    }
    _syncing = true;
    _resync = false;
    final rev = _rev;
    var ok = false;
    try {
      ok = await publish(jsonDecode(jsonEncode(state())) as Map<String, dynamic>);
    } catch (_) {
      ok = false;
    } finally {
      _syncing = false;
    }
    if (ok && rev == _rev) _setPending(false);
    if (_resync || (ok && rev != _rev)) {
      _resync = false;
      return sync();
    }
    return !pending;
  }

  Map<String, dynamic>? get _passcodeRecord {
    try {
      final raw = _prefs.read(ChatLockKeys.passcode);
      if (raw == null || raw.isEmpty) return null;
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic> && v['salt'] is String && v['hash'] is String) {
        return v;
      }
    } catch (_) {}
    return null;
  }

  bool get hasPasscode => _passcodeRecord != null;

  String get _vault {
    final m = hooks.vaultMethod?.call() ?? '';
    return m;
  }

  LockAttempts get _attempts {
    try {
      return LockAttempts.fromJson(jsonDecode(_prefs.read(ChatLockKeys.attempts) ?? 'null'));
    } catch (_) {
      return LockAttempts.idle;
    }
  }

  Future<bool> _deviceAvailable() async {
    final a = authenticator;
    if (a == null) return false;
    try {
      return await a.deviceAvailable();
    } catch (_) {
      return false;
    }
  }

  Future<bool?> _deviceAuth() async {
    final a = authenticator;
    if (a == null) return false;
    try {
      return await a.deviceAuth(t(ChatLockStrings.deviceReason));
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate() async {
    final device = await _deviceAvailable();
    final vault = _vault;
    final passcode = hasPasscode;
    final factor = unlockFactor(device: device, vault: vault, passcode: passcode);
    if (factor == 'device') {
      final r = await _deviceAuth();
      if (r == true) return true;
      final fb = fallbackFactor(vault: vault, passcode: passcode);
      if (fb != null) return _passcodeFlow(fb, true);
      if (r == false) hooks.notice?.call(t(ChatLockStrings.deviceFailed));
      return false;
    }
    if (factor == 'setup') return _setupPasscode();
    return _passcodeFlow(factor, false);
  }

  Future<bool> _verify(String factor, String code) async {
    if (factor == 'vaultPasscode') {
      final v = hooks.verifyVaultPassword;
      if (v == null) return false;
      try {
        return await v(code);
      } catch (_) {
        return false;
      }
    }
    return passcodeVerify(_passcodeRecord, code);
  }

  Future<bool> _passcodeFlow(String factor, bool afterDevice) async {
    final p = prompter;
    if (p == null) return false;
    var error = '';
    for (var guard = 0; guard < 50; guard++) {
      final wait = attemptWait(_attempts, _nowMs);
      if (wait > 0) error = t(ChatLockStrings.passcodeWait, {'n': wait});
      final res = await p(
        title: t(ChatLockStrings.unlockTitle),
        body: t(factor == 'vaultPasscode'
            ? ChatLockStrings.unlockVaultBody
            : ChatLockStrings.unlockPasscodeBody),
        fields: [t(ChatLockStrings.passcode)],
        ok: t(ChatLockStrings.unlock),
        alt: afterDevice ? t(ChatLockStrings.useDevice) : null,
        error: error,
      );
      if (res == null) return false;
      if (res.alt) {
        final r = await _deviceAuth();
        if (r == true) return true;
        error = t(ChatLockStrings.deviceFailed);
        continue;
      }
      if (attemptWait(_attempts, _nowMs) > 0) continue;
      final ok = await _verify(factor, res.values.isEmpty ? '' : res.values.first);
      final next = attemptStep(_attempts, ok, _nowMs);
      if (ok) {
        _prefs.remove(ChatLockKeys.attempts);
        return true;
      }
      _prefs.write(ChatLockKeys.attempts, jsonEncode(next.toJson()));
      error = t(ChatLockStrings.passcodeWrong);
    }
    return false;
  }

  Future<bool> _setupPasscode() async {
    final p = prompter;
    if (p == null) return false;
    var error = '';
    for (var guard = 0; guard < 50; guard++) {
      final res = await p(
        title: t(ChatLockStrings.setupTitle),
        body: t(ChatLockStrings.setupBody),
        fields: [t(ChatLockStrings.passcode), t(ChatLockStrings.passcodeConfirm)],
        ok: t(ChatLockStrings.unlock),
        error: error,
      );
      if (res == null) return false;
      final code = res.values.isNotEmpty ? res.values[0] : '';
      final confirm = res.values.length > 1 ? res.values[1] : '';
      final bad = passcodeCheck(code, confirm);
      if (bad != null) {
        error = passcodeError(bad, _tr);
        continue;
      }
      _prefs.write(ChatLockKeys.passcode,
          jsonEncode(await passcodeRecord(code, iterations: passcodeIterations)));
      return true;
    }
    return false;
  }

  Future<bool> changePasscode() async {
    if (!await authenticate()) return false;
    _prefs.remove(ChatLockKeys.passcode);
    return _setupPasscode();
  }
}
