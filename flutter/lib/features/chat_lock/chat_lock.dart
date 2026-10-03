import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';

class ChatLockLimits {
  const ChatLockLimits._();

  static const int lockMax = 100;
  static const int removedMax = 300;
  static const int removedTtlMs = 180 * 24 * 60 * 60 * 1000;
  static const int codeMin = 4;
  static const int codeMax = 32;
  static const int passcodeMin = 4;
  static const int passcodeMax = 64;
  static const int passcodeIterations = 150000;
  static const int attemptsFree = 5;
  static const int attemptsWaitSec = 30;
  static const int attemptsMaxDoublings = 5;
  static const List<int> relockChoices = [0, 1, 5, 15, 60];
  static const int relockDefault = 1;

  static Map<String, Object> toJson() => {
        'lockMax': lockMax,
        'removedMax': removedMax,
        'removedTtlMs': removedTtlMs,
        'codeMin': codeMin,
        'codeMax': codeMax,
        'passcodeMin': passcodeMin,
        'passcodeMax': passcodeMax,
        'passcodeIterations': passcodeIterations,
        'attemptsFree': attemptsFree,
        'attemptsWaitSec': attemptsWaitSec,
        'attemptsMaxDoublings': attemptsMaxDoublings,
        'relockChoices': relockChoices,
        'relockDefault': relockDefault,
      };
}

class ChatLockKeys {
  const ChatLockKeys._();

  static const String lockedDTag = 'nymchat-locked';
  static const String locked = 'nym_locked_chats';
  static const String lockedPending = 'nym_locked_pending';
  static const String relock = 'nym_chat_lock_relock';
  static const String passcode = 'nym_chat_lock_passcode';
  static const String credential = 'nym_chat_lock_cred';
  static const String attempts = 'nym_chat_lock_attempts';
  static const String screenSecurity = 'nym_screen_security';
  static const String incognitoKeyboard = 'nym_incognito_keyboard';

  static Map<String, String> toJson() => {
        'lockedDTag': lockedDTag,
        'locked': locked,
        'lockedPending': lockedPending,
        'relock': relock,
        'passcode': passcode,
        'credential': credential,
        'attempts': attempts,
        'screenSecurity': screenSecurity,
        'incognitoKeyboard': incognitoKeyboard,
      };
}

class ChatLockStrings {
  const ChatLockStrings._();

  static const String lockChat = 'Lock chat';
  static const String unlockChat = 'Remove chat lock';
  static const String lockedChats = 'Locked chats';
  static const String lockedEmpty = 'No locked chats';
  static const String lockedCount = '{n} unread';
  static const String unlockTitle = 'Unlock locked chats';
  static const String unlockBody =
      'Use your device unlock to open locked chats.';
  static const String unlockPasscodeBody =
      'Enter your passcode to open locked chats.';
  static const String unlockVaultBody =
      'Enter your identity password or PIN to open locked chats.';
  static const String unlock = 'Unlock';
  static const String usePasscode = 'Use passcode';
  static const String useDevice = 'Use device unlock';
  static const String passcode = 'Passcode';
  static const String passcodeConfirm = 'Confirm passcode';
  static const String passcodeWrong = 'Wrong passcode.';
  static const String passcodeWait = 'Too many tries. Wait {n} seconds.';
  static const String passcodeShort = 'Use at least {n} characters.';
  static const String passcodeMismatch = "Passcodes don't match.";
  static const String setupTitle = 'Set a chat lock passcode';
  static const String setupBody =
      'This device has no biometric or passkey unlock, so locked chats use a passcode you set here. It stays on this device.';
  static const String deviceFailed = 'Device unlock failed.';
  static const String deviceReason = 'Unlock your locked chats';
  static const String notifTitle = 'Nymchat';
  static const String notifBody = 'New message';
  static const String locked = 'Chat locked. Find it in Locked chats.';
  static const String unlocked = 'Chat lock removed.';
  static const String lockCap = 'You can lock up to {n} chats.';
  static const String defaultLocked = '#nymchat cannot be locked';
  static const String settingsTitle = 'Chat Lock';
  static const String settingsButton = 'Chat lock settings…';
  static const String settingsHint =
      'Locked chats leave the main list and open only after Face ID, fingerprint, a passkey or your passcode. Their notifications say only "New message". The list of locked chats syncs to your other devices; each device unlocks on its own.';
  static const String hideEntry = 'Hide the Locked chats entry';
  static const String hideEntryHint =
      'Open locked chats by typing your secret code in a sidebar search.';
  static const String secretCode = 'Secret code';
  static const String codeBad =
      'Use {min} to {max} characters for the secret code.';
  static const String relockAfter = 'Lock again after leaving the app';
  static const String relockNow = 'Immediately';
  static const String relockOne = 'After 1 minute';
  static const String relockMany = 'After {n} minutes';
  static const String relockHour = 'After 1 hour';
  static const String lockNow = 'Lock now';
  static const String resetPasscode = 'Change passcode';
  static const String screenSecurity = 'Screen Security';
  static const String screenSecurityAndroid =
      'Hide chats in the app switcher and block screenshots and screen recording. Always on inside locked chats and view-once media.';
  static const String screenSecurityIos =
      'Hide chats in the app switcher and cover them while the screen is recorded or mirrored. iOS does not let apps block screenshots. Always on inside locked chats and view-once media.';
  static const String screenSecurityWeb =
      'Blur chats when you switch away from Nymchat. Browsers do not let websites block screenshots or screen recording. Always on inside locked chats and view-once media.';
  static const String screenSecurityDesktop =
      'Hide chats while Nymchat is in the background. This system does not let apps block screenshots. Always on inside locked chats and view-once media.';
  static const String incognitoKeyboard = 'Incognito Keyboard';
  static const String incognitoAndroid =
      'Ask the keyboard not to learn from what you type, and turn off suggestions and autocorrect in message boxes.';
  static const String incognitoWeb =
      "Turn off autocomplete, autocorrect and spell check in message boxes. The browser can't ask your keyboard app to stop learning; only Android keyboards support that.";
  static const String incognitoOnlyAndroid =
      'Only Android keyboards support this.';
  static const String enabled = 'Enabled';
  static const String disabled = 'Disabled';
  static const String hidden = 'Content hidden';
  static const String captured =
      'Screen recording detected. Chats are hidden.';

  static Map<String, String> toJson() => {
        'lockChat': lockChat,
        'unlockChat': unlockChat,
        'lockedChats': lockedChats,
        'lockedEmpty': lockedEmpty,
        'lockedCount': lockedCount,
        'unlockTitle': unlockTitle,
        'unlockBody': unlockBody,
        'unlockPasscodeBody': unlockPasscodeBody,
        'unlockVaultBody': unlockVaultBody,
        'unlock': unlock,
        'usePasscode': usePasscode,
        'useDevice': useDevice,
        'passcode': passcode,
        'passcodeConfirm': passcodeConfirm,
        'passcodeWrong': passcodeWrong,
        'passcodeWait': passcodeWait,
        'passcodeShort': passcodeShort,
        'passcodeMismatch': passcodeMismatch,
        'setupTitle': setupTitle,
        'setupBody': setupBody,
        'deviceFailed': deviceFailed,
        'deviceReason': deviceReason,
        'notifTitle': notifTitle,
        'notifBody': notifBody,
        'locked': locked,
        'unlocked': unlocked,
        'lockCap': lockCap,
        'defaultLocked': defaultLocked,
        'settingsTitle': settingsTitle,
        'settingsButton': settingsButton,
        'settingsHint': settingsHint,
        'hideEntry': hideEntry,
        'hideEntryHint': hideEntryHint,
        'secretCode': secretCode,
        'codeBad': codeBad,
        'relockAfter': relockAfter,
        'relockNow': relockNow,
        'relockOne': relockOne,
        'relockMany': relockMany,
        'relockHour': relockHour,
        'lockNow': lockNow,
        'resetPasscode': resetPasscode,
        'screenSecurity': screenSecurity,
        'screenSecurityAndroid': screenSecurityAndroid,
        'screenSecurityIos': screenSecurityIos,
        'screenSecurityWeb': screenSecurityWeb,
        'screenSecurityDesktop': screenSecurityDesktop,
        'incognitoKeyboard': incognitoKeyboard,
        'incognitoAndroid': incognitoAndroid,
        'incognitoWeb': incognitoWeb,
        'incognitoOnlyAndroid': incognitoOnlyAndroid,
        'enabled': enabled,
        'disabled': disabled,
        'hidden': hidden,
        'captured': captured,
      };
}

typedef ChatLockTr = String Function(String s);

String _same(String s) => s;

final RegExp _rxHex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _rxGroup = RegExp(r'^[0-9a-f]{16,64}$');
final RegExp _rxChannel = RegExp(r'^[\p{L}\p{N}]{1,64}$', unicode: true);

num _num(Object? v) {
  if (v is num) return v.isFinite ? v : 0;
  if (v is bool) return v ? 1 : 0;
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return 0;
    final d = double.tryParse(t);
    return d != null && d.isFinite ? d : 0;
  }
  return 0;
}

int _floor(Object? v) => _num(v).floor();

String _fill(String s, Map<String, Object?>? vars) {
  var out = s;
  if (vars != null) {
    vars.forEach((k, v) => out = out.split('{$k}').join('$v'));
  }
  return out;
}

int _cmpStr(String a, String b) => a.compareTo(b);

final Map<String, String> _lockKeyMemo = <String, String>{};

String lockKey(String kind, Object? id) {
  final memoKey = '$kind\u0000${id ?? ''}';
  final hit = _lockKeyMemo[memoKey];
  if (hit != null) return hit;
  if (_lockKeyMemo.length >= 4096) _lockKeyMemo.clear();
  return _lockKeyMemo[memoKey] = _lockKeyOf(kind, id);
}

String _lockKeyOf(String kind, Object? id) {
  final raw = (id == null ? '' : '$id').trim();
  if (kind == 'dm') {
    final pk = raw.toLowerCase();
    return _rxHex64.hasMatch(pk) ? 'd:$pk' : '';
  }
  if (kind == 'group') {
    final g = raw.toLowerCase();
    return _rxGroup.hasMatch(g) ? 'g:$g' : '';
  }
  if (kind == 'channel') {
    final c = raw.replaceFirst(RegExp(r'^#'), '').toLowerCase();
    return _rxChannel.hasMatch(c) ? 'c:$c' : '';
  }
  return '';
}

({String kind, String id})? lockParse(String? k) {
  final s = k ?? '';
  if (s.startsWith('d:') && _rxHex64.hasMatch(s.substring(2))) {
    return (kind: 'dm', id: s.substring(2));
  }
  if (s.startsWith('g:') && _rxGroup.hasMatch(s.substring(2))) {
    return (kind: 'group', id: s.substring(2));
  }
  if (s.startsWith('c:') && _rxChannel.hasMatch(s.substring(2))) {
    return (kind: 'channel', id: s.substring(2));
  }
  return null;
}

String lockKeyForChat(String? chatKey, [String? selfPubkey]) {
  final k = chatKey ?? '';
  if (k.startsWith('pm-')) {
    final parts =
        k.substring(3).toLowerCase().split('-').where((p) => p.isNotEmpty).toList();
    final self = (selfPubkey ?? '').toLowerCase();
    String? peer;
    if (parts.length > 1) {
      peer = parts.firstWhere((p) => p != self, orElse: () => parts.first);
    } else if (parts.isNotEmpty) {
      peer = parts.first;
    }
    return lockKey('dm', peer);
  }
  if (k.startsWith('group-')) return lockKey('group', k.substring(6));
  return lockKey('channel', k);
}

String normCode(Object? code) =>
    (code == null ? '' : '$code').trim().toLowerCase();

Map<String, dynamic> emptyLocks() => <String, dynamic>{
      'v': 1,
      'items': <String, int>{},
      'removed': <String, int>{},
      'hide': <String, dynamic>{'on': false, 'code': '', 'at': 0},
    };

Map<String, int> _items(Map<String, dynamic> s) => s['items'] as Map<String, int>;
Map<String, int> _removed(Map<String, dynamic> s) =>
    s['removed'] as Map<String, int>;
Map<String, dynamic> _hide(Map<String, dynamic> s) =>
    s['hide'] as Map<String, dynamic>;

Map<String, dynamic> _normalizeHide(Object? raw) {
  final out = <String, dynamic>{'on': false, 'code': '', 'at': 0};
  if (raw is! Map) return out;
  final code = normCode(raw['code']);
  out['code'] = code.length >= ChatLockLimits.codeMin &&
          code.length <= ChatLockLimits.codeMax
      ? code
      : '';
  out['on'] = raw['on'] == true && (out['code'] as String).isNotEmpty;
  out['at'] = math.max(0, _floor(raw['at']));
  return out;
}

Map<String, dynamic> normalizeLocks(Object? raw) {
  final out = emptyLocks();
  if (raw is! Map) return out;
  for (final f in const ['items', 'removed']) {
    final src = raw[f];
    if (src is! Map) continue;
    final dst = out[f] as Map<String, int>;
    src.forEach((k, v) {
      final at = _floor(v);
      if (lockParse('$k') != null && at > 0) dst['$k'] = at;
    });
  }
  out['hide'] = _normalizeHide(raw['hide']);
  return _finishLocks(out, 0);
}

Map<String, int> _sortObj(Map<String, int> o) {
  final keys = o.keys.toList()..sort();
  return {for (final k in keys) k: o[k]!};
}

Map<String, dynamic> _finishLocks(Map<String, dynamic> s, num nowMs) {
  final src = _items(s);
  final rem = _removed(s);
  final items = <String, int>{};
  src.forEach((k, at) {
    final r = rem[k];
    if (!(r != null && r >= at)) items[k] = at;
  });
  final keys = items.keys.toList()
    ..sort((a, b) {
      final d = items[b]! - items[a]!;
      return d != 0 ? d : _cmpStr(a, b);
    });
  if (keys.length > ChatLockLimits.lockMax) {
    for (final k in keys.sublist(ChatLockLimits.lockMax)) {
      items.remove(k);
    }
  }
  final removed = <String, int>{};
  final cutoff = _num(nowMs) > 0 ? _num(nowMs) - ChatLockLimits.removedTtlMs : 0;
  rem.forEach((k, at) {
    if (items.containsKey(k)) return;
    if (cutoff > 0 && at < cutoff) return;
    removed[k] = at;
  });
  if (removed.length > ChatLockLimits.removedMax) {
    final rk = removed.keys.toList()
      ..sort((a, b) {
        final d = removed[b]! - removed[a]!;
        return d != 0 ? d : _cmpStr(a, b);
      });
    for (final k in rk.sublist(ChatLockLimits.removedMax)) {
      removed.remove(k);
    }
  }
  final h = _hide(s);
  return <String, dynamic>{
    'v': 1,
    'items': _sortObj(items),
    'removed': _sortObj(removed),
    'hide': <String, dynamic>{'on': h['on'], 'code': h['code'], 'at': h['at']},
  };
}

Map<String, dynamic> _asState(Object? state) {
  if (state is Map<String, dynamic> &&
      state['items'] is Map<String, int> &&
      state['removed'] is Map<String, int> &&
      state['hide'] is Map<String, dynamic>) {
    return state;
  }
  return normalizeLocks(state);
}

List<String> lockList(Object? state) {
  final s = normalizeLocks(state);
  final items = _items(s);
  return items.keys.toList()
    ..sort((a, b) {
      final d = items[b]! - items[a]!;
      return d != 0 ? d : _cmpStr(a, b);
    });
}

bool isLocked(Object? state, String? k) {
  if (k == null || k.isEmpty) return false;
  final s = _asState(state);
  final at = _items(s)[k];
  if (at == null) return false;
  final r = _removed(s)[k];
  return !(r != null && r >= at);
}

({Map<String, dynamic> state, String? error}) lockAdd(
    Object? state, String k, num nowMs) {
  final s = normalizeLocks(state);
  if (lockParse(k) == null) return (state: s, error: 'invalid');
  if (k == 'c:nymchat') return (state: s, error: 'default');
  if (isLocked(s, k)) return (state: s, error: null);
  if (_items(s).length >= ChatLockLimits.lockMax) {
    return (state: s, error: 'cap');
  }
  final items = _items(s);
  final removed = _removed(s);
  items[k] = [
    _num(nowMs).floor(),
    (removed[k] ?? 0) + 1,
    (items[k] ?? 0) + 1,
  ].reduce(math.max);
  removed.remove(k);
  return (state: _finishLocks(s, nowMs), error: null);
}

Map<String, dynamic> lockRemove(Object? state, String k, num nowMs) {
  final s = normalizeLocks(state);
  if (!isLocked(s, k)) return s;
  _removed(s)[k] = math.max(_num(nowMs).floor(), (_items(s)[k] ?? 0) + 1);
  _items(s).remove(k);
  return _finishLocks(s, nowMs);
}

({Map<String, dynamic> state, String? error}) setHidden(
    Object? state, bool on, String? code, num nowMs) {
  final s = normalizeLocks(state);
  final h = _hide(s);
  final c = normCode(code ?? h['code']);
  final ok = c.length >= ChatLockLimits.codeMin && c.length <= ChatLockLimits.codeMax;
  if (on && !ok) return (state: s, error: 'code');
  s['hide'] = <String, dynamic>{
    'on': on,
    'code': on ? c : (ok ? c : ''),
    'at': math.max(_num(nowMs).floor(), (h['at'] as int) + 1),
  };
  return (state: _finishLocks(s, nowMs), error: null);
}

Map<String, dynamic> mergeLocks(Object? a, Object? b, num nowMs) {
  final x = normalizeLocks(a);
  final y = normalizeLocks(b);
  final items = Map<String, int>.of(_items(x));
  _items(y).forEach((k, at) {
    final cur = items[k];
    if (!(cur != null && cur >= at)) items[k] = at;
  });
  final removed = Map<String, int>.of(_removed(x));
  _removed(y).forEach((k, at) {
    final cur = removed[k];
    if (!(cur != null && cur >= at)) removed[k] = at;
  });
  var hide = _hide(x);
  final yh = _hide(y);
  final xa = hide['at'] as int;
  final ya = yh['at'] as int;
  if (ya > xa || (ya == xa && jsonEncode(yh).compareTo(jsonEncode(hide)) > 0)) {
    hide = yh;
  }
  return _finishLocks(<String, dynamic>{
    'v': 1,
    'items': items,
    'removed': removed,
    'hide': Map<String, dynamic>.of(hide),
  }, nowMs);
}

bool trimLockedPayload(Map<String, dynamic> p) {
  final s = p['lockedChats'];
  if (s is! Map) return false;
  final removed = s['removed'];
  final rk = removed is Map ? removed.keys.map((k) => '$k').toList() : <String>[];
  if (rk.length > 20 && removed is Map) {
    rk.sort((a, b) {
      final d = _num(removed[a]).compareTo(_num(removed[b]));
      return d != 0 ? d : _cmpStr(a, b);
    });
    for (final k in rk.sublist(0, (rk.length / 4).ceil())) {
      removed.remove(k);
    }
    return true;
  }
  final items = s['items'];
  final ik = items is Map ? items.keys.map((k) => '$k').toList() : <String>[];
  if (ik.length > 20 && items is Map) {
    ik.sort((a, b) {
      final d = _num(items[a]).compareTo(_num(items[b]));
      return d != 0 ? d : _cmpStr(a, b);
    });
    for (final k in ik.sublist(0, (ik.length / 4).ceil())) {
      items.remove(k);
    }
    return true;
  }
  return false;
}

bool secretMatches(Object? state, String? term) {
  final h = _hide(normalizeLocks(state));
  final code = h['code'] as String;
  return h['on'] == true && code.isNotEmpty && normCode(term) == code;
}

bool entryVisible(Object? state, bool revealed) {
  final s = normalizeLocks(state);
  if (_items(s).isEmpty) return false;
  return _hide(s)['on'] != true || revealed;
}

({List<String> visible, List<String> locked}) partition(
    Iterable<String> chatKeys, Object? state,
    [String? selfPubkey]) {
  final s = normalizeLocks(state);
  final visible = <String>[];
  final locked = <String>[];
  for (final k in chatKeys) {
    if (isLocked(s, lockKeyForChat(k, selfPubkey))) {
      locked.add(k);
    } else {
      visible.add(k);
    }
  }
  return (visible: visible, locked: locked);
}

class ChatLockBadges {
  const ChatLockBadges(this.main, this.locked, this.shown);
  final int main;
  final int locked;
  final int shown;

  Map<String, int> toJson() => {'main': main, 'locked': locked, 'shown': shown};
}

ChatLockBadges badges(Iterable<({String key, Object? n})> entries,
    Object? state, String? selfPubkey, bool revealed) {
  final s = _asState(state);
  var main = 0;
  var locked = 0;
  for (final e in entries) {
    final n = math.max(0, _floor(e.n));
    if (n == 0) continue;
    if (isLocked(s, lockKeyForChat(e.key, selfPubkey))) {
      locked += n;
    } else {
      main += n;
    }
  }
  final shown = _hide(s)['on'] == true && !revealed ? 0 : locked;
  return ChatLockBadges(main, locked, shown);
}

List<String> notificationLockKeys(String? type, String? route, String? sender) {
  final t = type ?? '';
  final r = route ?? '';
  final out = <String>[];
  void add(String k) {
    if (k.isNotEmpty && !out.contains(k)) out.add(k);
  }

  final isPk = _rxHex64.hasMatch(r.toLowerCase());
  if (t == 'pm') {
    add(lockKey('dm', r));
    add(lockKey('dm', sender));
  } else if (t == 'group') {
    add(lockKey('group', r));
  } else if (t == 'channel' || t == 'geohash') {
    add(lockKey('channel', r));
  } else if (t == 'mention') {
    add(isPk ? lockKey('dm', r) : lockKey('channel', r));
  } else if (t == 'call') {
    add(isPk ? lockKey('dm', r) : lockKey('group', r));
    if (r.isEmpty) add(lockKey('dm', sender));
  } else {
    if (isPk) {
      add(lockKey('dm', r));
    } else {
      add(lockKey('group', r));
      add(lockKey('channel', r));
    }
  }
  return out;
}

bool notificationLocked(
    Object? state, String? type, String? route, String? sender) {
  final s = _asState(state);
  if (_items(s).isEmpty) return false;
  return notificationLockKeys(type, route, sender).any((k) => isLocked(s, k));
}

({String title, String body, bool locked}) notificationText(
    String? title, String? body, bool locked,
    [ChatLockTr t = _same]) {
  if (!locked) return (title: title ?? '', body: body ?? '', locked: false);
  return (
    title: t(ChatLockStrings.notifTitle),
    body: t(ChatLockStrings.notifBody),
    locked: true,
  );
}

class LockSession {
  const LockSession({this.unlocked = false, this.at = 0, this.bg = 0});
  final bool unlocked;
  final int at;
  final int bg;

  static const LockSession idle = LockSession();

  factory LockSession.fromJson(Map<String, dynamic> j) => LockSession(
        unlocked: j['unlocked'] == true,
        at: _floor(j['at']),
        bg: _floor(j['bg']),
      );

  Map<String, dynamic> toJson() => {'unlocked': unlocked, 'at': at, 'bg': bg};
}

LockSession sessionStep(LockSession s, String type,
    {num now = 0, num relock = 0}) {
  final relockMs = math.max<num>(0, _num(relock)) * 60000;
  switch (type) {
    case 'unlock':
      return LockSession(unlocked: true, at: _num(now).floor(), bg: 0);
    case 'leave':
    case 'lock':
      return LockSession.idle;
    case 'background':
      if (!s.unlocked) return s;
      if (relockMs == 0) return LockSession.idle;
      return LockSession(
          unlocked: true, at: s.at, bg: s.bg > 0 ? s.bg : _num(now).floor());
    case 'foreground':
      if (!s.unlocked) return s;
      if (s.bg > 0 && _num(now) - s.bg >= relockMs) return LockSession.idle;
      return LockSession(unlocked: true, at: s.at, bg: 0);
    default:
      return s;
  }
}

bool sessionAllows(LockSession s, Object? state, String? chatKey,
    [String? selfPubkey]) {
  final k = lockKeyForChat(chatKey, selfPubkey);
  if (!isLocked(state, k)) return true;
  return s.unlocked;
}

bool leavesLocked(Object? state, String? fromKey, String? toKey,
    [String? selfPubkey]) {
  final from = isLocked(state, lockKeyForChat(fromKey, selfPubkey));
  final to = isLocked(state, lockKeyForChat(toKey, selfPubkey));
  return from && !to;
}

String unlockFactor({bool device = false, String vault = '', bool passcode = false}) {
  if (device) return 'device';
  if (vault == 'password' || vault == 'pin') return 'vaultPasscode';
  if (passcode) return 'passcode';
  return 'setup';
}

String? fallbackFactor({String vault = '', bool passcode = false}) {
  if (vault == 'password' || vault == 'pin') return 'vaultPasscode';
  if (passcode) return 'passcode';
  return null;
}

class LockAttempts {
  const LockAttempts({this.fails = 0, this.until = 0});
  final int fails;
  final int until;

  static const LockAttempts idle = LockAttempts();

  factory LockAttempts.fromJson(Object? j) {
    if (j is! Map) return idle;
    return LockAttempts(fails: _floor(j['fails']), until: _floor(j['until']));
  }

  Map<String, int> toJson() => {'fails': fails, 'until': until};
}

LockAttempts attemptStep(LockAttempts s, bool ok, num nowMs) {
  if (ok) return LockAttempts.idle;
  final fails = s.fails + 1;
  final until = fails >= ChatLockLimits.attemptsFree
      ? _num(nowMs).floor() +
          ChatLockLimits.attemptsWaitSec *
              1000 *
              math
                  .pow(
                      2,
                      math.min(fails - ChatLockLimits.attemptsFree,
                          ChatLockLimits.attemptsMaxDoublings))
                  .toInt()
      : 0;
  return LockAttempts(fails: fails, until: until);
}

int attemptWait(LockAttempts s, num nowMs) {
  final left = s.until - _num(nowMs);
  return left > 0 ? (left / 1000).ceil() : 0;
}

String? passcodeCheck(String? code, [String? confirm]) {
  final c = code ?? '';
  if (c.length < ChatLockLimits.passcodeMin) return 'short';
  if (c.length > ChatLockLimits.passcodeMax) return 'long';
  if (confirm != null && confirm != c) return 'mismatch';
  return null;
}

String passcodeError(String? code, [ChatLockTr t = _same]) {
  if (code == 'short' || code == 'long') {
    return _fill(t(ChatLockStrings.passcodeShort),
        {'n': ChatLockLimits.passcodeMin});
  }
  if (code == 'mismatch') return t(ChatLockStrings.passcodeMismatch);
  if (code == 'wrong') return t(ChatLockStrings.passcodeWrong);
  return '';
}

String codeError([ChatLockTr t = _same]) => _fill(t(ChatLockStrings.codeBad),
    {'min': ChatLockLimits.codeMin, 'max': ChatLockLimits.codeMax});

List<({int value, String label})> relockOptions([ChatLockTr t = _same]) => [
      for (final n in ChatLockLimits.relockChoices)
        (
          value: n,
          label: n == 0
              ? t(ChatLockStrings.relockNow)
              : n == 1
                  ? t(ChatLockStrings.relockOne)
                  : n == 60
                      ? t(ChatLockStrings.relockHour)
                      : _fill(t(ChatLockStrings.relockMany), {'n': n}),
        ),
    ];

int normalizeRelock(Object? v) {
  if (v == null || v is bool) return ChatLockLimits.relockDefault;
  num? n;
  if (v is num) {
    n = v;
  } else {
    final t = '$v'.trim();
    if (t.isEmpty) return ChatLockLimits.relockDefault;
    n = num.tryParse(t);
  }
  if (n == null || !n.isFinite || n.floor() != n) {
    return ChatLockLimits.relockDefault;
  }
  final i = n.toInt();
  return ChatLockLimits.relockChoices.contains(i)
      ? i
      : ChatLockLimits.relockDefault;
}

bool obscureWanted(
        {bool setting = false, bool lockedOpen = false, bool viewOnce = false}) =>
    setting || lockedOpen || viewOnce;

bool shieldStep(bool shielded, String ev, bool wanted) {
  if (!wanted) return false;
  if (ev == 'hidden' || ev == 'blur' || ev == 'pagehide' || ev == 'freeze') {
    return true;
  }
  if (ev == 'visible' || ev == 'focus' || ev == 'pageshow' || ev == 'resume') {
    return false;
  }
  return shielded;
}

String screenSecurityHint(String platform) {
  if (platform == 'android') return ChatLockStrings.screenSecurityAndroid;
  if (platform == 'ios') return ChatLockStrings.screenSecurityIos;
  if (platform == 'web') return ChatLockStrings.screenSecurityWeb;
  return ChatLockStrings.screenSecurityDesktop;
}

({String mode, bool available, String hint}) incognitoSupport(String platform) {
  if (platform == 'android') {
    return (
      mode: 'keyboard',
      available: true,
      hint: ChatLockStrings.incognitoAndroid,
    );
  }
  if (platform == 'web') {
    return (mode: 'browser', available: true, hint: ChatLockStrings.incognitoWeb);
  }
  return (
    mode: 'none',
    available: false,
    hint: ChatLockStrings.incognitoOnlyAndroid,
  );
}

Map<String, String> inputAttrs(bool on) {
  if (!on) return const {};
  return const {
    'autocomplete': 'off',
    'autocorrect': 'off',
    'autocapitalize': 'off',
    'spellcheck': 'false',
  };
}

({bool imeLearning, bool autocorrect, bool suggestions}) textFieldFlags(
    bool on, String platform) {
  final active = on && platform == 'android';
  return (imeLearning: !active, autocorrect: !active, suggestions: !active);
}

final _pbkdfCache = <int, Pbkdf2>{};

Future<String> passcodeHash(String code, List<int> salt, int iterations) async {
  final it = math.max(1, iterations);
  final algo = _pbkdfCache.putIfAbsent(
      it, () => Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: it, bits: 256));
  final key = await algo.deriveKey(
      secretKey: SecretKey(utf8.encode(code)), nonce: salt);
  return base64.encode(await key.extractBytes());
}

Future<Map<String, dynamic>> passcodeRecord(String code,
    {List<int>? salt, int? iterations}) async {
  final it = math.max(1, iterations ?? ChatLockLimits.passcodeIterations);
  final s = salt ??
      List<int>.generate(16, (_) => math.Random.secure().nextInt(256));
  return <String, dynamic>{
    'v': 1,
    'it': it,
    'salt': base64.encode(s),
    'hash': await passcodeHash(code, s, it),
  };
}

Future<bool> passcodeVerify(Object? record, String code) async {
  if (record is! Map) return false;
  final salt = record['salt'];
  final hash = record['hash'];
  if (salt is! String || salt.isEmpty || hash is! String || hash.isEmpty) {
    return false;
  }
  try {
    final it = _floor(record['it']);
    final h = await passcodeHash(code, base64.decode(salt),
        it > 0 ? it : ChatLockLimits.passcodeIterations);
    if (h.length != hash.length) return false;
    var diff = 0;
    for (var i = 0; i < h.length; i++) {
      diff |= h.codeUnitAt(i) ^ hash.codeUnitAt(i);
    }
    return diff == 0;
  } catch (_) {
    return false;
  }
}
