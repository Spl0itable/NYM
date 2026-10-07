import 'dart:convert';

class AwayState {
  const AwayState({
    required this.enabled,
    required this.message,
    required this.updatedAt,
  });

  final bool enabled;
  final String message;
  final int updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'message': message,
        'updatedAt': updatedAt,
      };
}

abstract final class AwaySync {
  static const String dTag = 'nymchat-away';
  static const String payloadKey = 'awayStatus';
  static const String storagePrefix = 'nym_away_state_';
  static const String sessionPrefix = 'brb_universal_';
  static const int messageMax = 500;
  static const String autoReplyTag = '[Auto-Reply]';
  static const int delayMinMs = 1000;
  static const int delaySpanMs = 2000;
  static const int skewSec = 60;
  static const int ringMs = 1500;
  static const int ringRetryMs = 6000;

  static final RegExp _edges = RegExp(r'^\s+|\s+$');

  static String _trim(String s) => s.replaceAll(_edges, '');

  static AwayState? normalize(Object? raw) {
    if (raw is AwayState) raw = raw.toJson();
    if (raw is! Map) return null;
    final u = raw['updatedAt'];
    if (u is! num || !u.isFinite || u < 0) return null;
    final m = raw['message'];
    var message = m is String ? _trim(m) : '';
    if (message.length > messageMax) {
      message = _trim(message.substring(0, messageMax));
    }
    final enabled = raw['enabled'] == true && message.isNotEmpty;
    return AwayState(
      enabled: enabled,
      message: enabled ? message : '',
      updatedAt: u.floor(),
    );
  }

  static AwayState? merge(Object? local, Object? remote) {
    final a = normalize(local);
    final b = normalize(remote);
    if (a == null) return b;
    if (b == null) return a;
    if (b.updatedAt > a.updatedAt) return b;
    if (a.updatedAt > b.updatedAt) return a;
    if (a.enabled != b.enabled) return a.enabled ? b : a;
    return a.message.compareTo(b.message) <= 0 ? a : b;
  }

  static int _next(Object? prev, int nowMs) {
    final p = normalize(prev);
    if (p != null && p.updatedAt >= nowMs) return p.updatedAt + 1;
    return nowMs;
  }

  static AwayState enable(Object? prev, Object? message, int nowMs) =>
      normalize(<String, dynamic>{
        'enabled': true,
        'message': message,
        'updatedAt': _next(prev, nowMs),
      })!;

  static AwayState disable(Object? prev, int nowMs) =>
      AwayState(enabled: false, message: '', updatedAt: _next(prev, nowMs));

  static String? encode(Object? state) {
    final s = normalize(state);
    return s == null ? null : jsonEncode(s.toJson());
  }

  static AwayState? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return normalize(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? payload(Object? state) {
    final s = normalize(state);
    return s == null ? null : <String, dynamic>{payloadKey: s.toJson()};
  }

  static AwayState? fromPayload(Object? p) =>
      p is Map ? normalize(p[payloadKey]) : null;

  static Map<String, String> presence(Object? state) {
    final s = normalize(state);
    if (s != null && s.enabled) {
      return <String, String>{'status': 'away', 'message': s.message};
    }
    return const <String, String>{'status': 'online', 'message': ''};
  }

  static String autoReplyText(String nym, String message) =>
      '@$nym $autoReplyTag $message';

  static int delayMs(Object? r) {
    var x = (r is num && r.isFinite) ? r.toDouble() : 0.0;
    if (x < 0) x = 0;
    if (x > 1) x = 1;
    return delayMinMs + (x * delaySpanMs).floor();
  }

  static bool shouldAutoReply({
    required Object? state,
    required String selfPubkey,
    required String senderPubkey,
    required bool mentioned,
    required bool historical,
  }) {
    final s = normalize(state);
    return s != null &&
        s.enabled &&
        mentioned &&
        !historical &&
        senderPubkey.isNotEmpty &&
        senderPubkey != selfPubkey;
  }

  static bool hasOwnAutoReply(
      Object? messages, String selfPubkey, String nym, num sinceSec) {
    if (messages is! Iterable) return false;
    final prefix = '@$nym $autoReplyTag';
    for (final m in messages) {
      if (m is! Map) continue;
      final content = m['content'];
      final at = m['createdAt'];
      if (m['pubkey'] == selfPubkey &&
          content is String &&
          content.startsWith(prefix) &&
          (at is num ? at : 0) >= sinceSec - skewSec) {
        return true;
      }
    }
    return false;
  }

  static bool presenceRings(
      Object? state, String? status, String? away, num createdAtSec) {
    final s = normalize(state);
    final at = createdAtSec.isFinite ? createdAtSec : 0;
    if (s != null && at < sinceSec(s) - skewSec) return false;
    if (status == 'away') {
      if (s == null || !s.enabled) return true;
      final msg = away == null ? '' : _trim(away);
      return msg.isNotEmpty && msg != s.message;
    }
    if (status == 'online') return s != null && s.enabled;
    return false;
  }

  static int sinceSec(Object? state) {
    final s = normalize(state);
    return s == null ? 0 : s.updatedAt ~/ 1000;
  }

  static String storageKey(String pubkey) => '$storagePrefix$pubkey';

  static String sessionKey(String selfPubkey, String nym) =>
      '$sessionPrefix${selfPubkey}_$nym';
}
