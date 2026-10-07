import 'dart:convert';

typedef PanicMarkerVerifier = bool Function(Map<String, dynamic> event);

class RemotePanicStrings {
  RemotePanicStrings._();

  static const String label = 'Panic wipe also erases my other devices';
  static const String hint =
      'When you hold "Your Nym" or the wordmark on the unlock screen for 2 '
      'seconds, every other device signed in as this identity also wipes '
      'this identity the next time it connects. Other identities on those '
      'devices are not touched. An encrypted identity that is still locked '
      "when you panic from the unlock screen can't send this signal.";
  static const String confirmTitle = 'Erase other devices too?';
  static const String confirm =
      'A panic wipe will then also erase this identity from every device '
      "signed in as it, and that can't be undone. Messages protected by your "
      'post-quantum recovery code are lost forever if no device keeps it. '
      'Save your nsec and your nympq1… recovery code first.';
  static const String confirmOk = 'Turn on';
  static const String confirmBackup = 'Back up first';

  static Map<String, String> toJson() => {
        'label': label,
        'hint': hint,
        'confirmTitle': confirmTitle,
        'confirm': confirm,
        'confirmOk': confirmOk,
        'confirmBackup': confirmBackup,
      };
}

class RemotePanicDecision {
  const RemotePanicDecision(this.action, this.reason);

  final String action;
  final String reason;

  bool get wipe => action == 'wipe';

  Map<String, dynamic> toJson() => {'action': action, 'reason': reason};
}

class RemotePanic {
  RemotePanic._();

  static const int kind = 30078;
  static const String dTag = 'nym-panic';
  static const String deleteDTag = 'nym-account-deleted';
  static const int ttlSeconds = 90 * 86400;
  static const int futureSkewSeconds = 600;
  static const String setting = 'remotePanic';
  static const Duration checkEvery = Duration(minutes: 5);

  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');

  static bool _isHex(Object? s, int n) =>
      s is String && s.length == n && _hex.hasMatch(s);

  static Map<String, dynamic> template(int at, {bool deleted = false}) => {
        'kind': kind,
        'created_at': at,
        'tags': [
          ['d', deleted ? deleteDTag : dTag]
        ],
        'content': '',
      };

  static String? _dTagOf(Map<dynamic, dynamic>? ev) {
    final tags = ev?['tags'];
    if (tags is! List || tags.isEmpty) return null;
    final t = tags.first;
    return t is List && t.length > 1 && t[1] is String ? t[1] as String : null;
  }

  static bool isDeletion(Map<dynamic, dynamic>? ev) =>
      _dTagOf(ev) == deleteDTag;

  static Map<String, dynamic> _clean(Map<String, dynamic> ev) => {
        'id': ev['id'],
        'pubkey': ev['pubkey'],
        'created_at': ev['created_at'],
        'kind': ev['kind'],
        'tags': [
          ['d', isDeletion(ev) ? deleteDTag : dTag]
        ],
        'content': '',
        'sig': ev['sig'],
      };

  static Map<String, dynamic>? fromRow(String pubkey, Object? row) {
    if (row is! Map || !_isHex(pubkey, 64)) return null;
    final at = row['at'];
    if (at is! int || !_isHex(row['id'], 64) || !_isHex(row['sig'], 128)) {
      return null;
    }
    final d = row['d'];
    if (d != null && d != dTag && d != deleteDTag) return null;
    return _clean({
      'id': row['id'],
      'pubkey': pubkey,
      'created_at': at,
      'kind': kind,
      'tags': [
        ['d', d == deleteDTag ? deleteDTag : dTag]
      ],
      'sig': row['sig'],
    });
  }

  static bool shapeOk(Object? ev) {
    if (ev is! Map) return false;
    final at = ev['created_at'];
    if (ev['kind'] != kind || ev['content'] != '' || at is! int || at <= 0) {
      return false;
    }
    final tags = ev['tags'];
    if (tags is! List || tags.length != 1) return false;
    final t = tags.first;
    if (t is! List ||
        t.length != 2 ||
        t[0] != 'd' ||
        (t[1] != dTag && t[1] != deleteDTag)) {
      return false;
    }
    return _isHex(ev['pubkey'], 64) &&
        _isHex(ev['id'], 64) &&
        _isHex(ev['sig'], 128);
  }

  static bool markerValid(
      Map<String, dynamic>? ev, String pubkey, PanicMarkerVerifier verify) {
    if (ev == null || !shapeOk(ev) || ev['pubkey'] != pubkey) return false;
    try {
      return verify(_clean(ev));
    } catch (_) {
      return false;
    }
  }

  static RemotePanicDecision decide({
    required bool enabled,
    required int? loginAt,
    required int now,
    required String pubkey,
    required Map<String, dynamic>? marker,
    required PanicMarkerVerifier verify,
  }) {
    final m = marker;
    if (!enabled && !(m != null && isDeletion(m))) {
      return const RemotePanicDecision('ignore', 'off');
    }
    if (m == null) return const RemotePanicDecision('ignore', 'none');
    if (!shapeOk(m)) return const RemotePanicDecision('ignore', 'shape');
    if (m['pubkey'] != pubkey) {
      return const RemotePanicDecision('ignore', 'pubkey');
    }
    if (!markerValid(m, pubkey, verify)) {
      return const RemotePanicDecision('ignore', 'sig');
    }
    if (loginAt == null || loginAt <= 0) {
      return const RemotePanicDecision('ignore', 'nologin');
    }
    final at = m['created_at'] as int;
    if (at <= loginAt) {
      return const RemotePanicDecision('ignore', 'before-login');
    }
    if (at > now + futureSkewSeconds) {
      return const RemotePanicDecision('ignore', 'future');
    }
    if (now - at > ttlSeconds) {
      return const RemotePanicDecision('ignore', 'expired');
    }
    return isDeletion(m)
        ? const RemotePanicDecision('wipe', 'deleted')
        : const RemotePanicDecision('wipe', 'wipe');
  }

  static Map<String, dynamic> rumor(Map<String, dynamic> marker) => {
        'kind': kind,
        'created_at': marker['created_at'],
        'tags': [
          ['d', isDeletion(marker) ? deleteDTag : dTag]
        ],
        'content': jsonEncode(_clean(marker)),
        'pubkey': marker['pubkey'],
      };

  static bool isRumor(Map<String, dynamic>? r) {
    if (r == null || r['kind'] != kind) return false;
    final tags = r['tags'];
    if (tags is! List) return false;
    return tags.any((t) =>
        t is List &&
        t.length > 1 &&
        t[0] == 'd' &&
        (t[1] == dTag || t[1] == deleteDTag));
  }

  static Map<String, dynamic>? markerFromRumor(Map<String, dynamic>? r) {
    if (!isRumor(r) || r!['content'] is! String) return null;
    try {
      final ev = jsonDecode(r['content'] as String);
      if (ev is! Map<String, dynamic>) return null;
      if (!shapeOk(ev) || ev['pubkey'] != r['pubkey']) return null;
      return _clean(ev);
    } catch (_) {
      return null;
    }
  }

  static bool shouldSend(bool enabled, bool canSign) => enabled && canSign;
}
