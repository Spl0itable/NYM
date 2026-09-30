// Pure, plugin-free call signaling logic matching the PWA's message shapes.

import 'dart:math';

/// Call media kind; the wire only uses `'audio'` / `'video'`.
enum CallKind {
  audio,
  video;

  String get wire => this == CallKind.video ? 'video' : 'audio';

  static CallKind fromWire(Object? v) =>
      v == 'video' ? CallKind.video : CallKind.audio;
}

/// Call lifecycle for the UI; [ended] collapses back to [idle] for the next call.
enum CallPhase { idle, ringing, incoming, connecting, active, ended }

/// `'call-' + base36 random + base36 Date.now()`, like the PWA.
String genCallId([Random? rng]) {
  final r = rng ?? Random();
  // 11 base36 chars approximates JS `Math.random().toString(36).slice(2)`.
  final buf = StringBuffer();
  for (var i = 0; i < 11; i++) {
    buf.write(r.nextInt(36).toRadixString(36));
  }
  final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  return 'call-$buf$t';
}

/// Timeout for both outgoing ringing and incoming invites.
const Duration kCallRingTimeout = Duration(seconds: 45);

/// Glare guard: the lexicographically smaller pubkey offers for each pair.
bool isOfferer({required String selfPubkey, required String peerPubkey}) {
  return selfPubkey.compareTo(peerPubkey) < 0;
}

/// `acceptCalls` gate: 'disabled' never rings, 'friends' only for friends, 'enabled' always.
bool shouldRingForInvite({
  required String acceptCalls,
  required bool isFriend,
}) {
  if (acceptCalls == 'disabled') return false;
  if (acceptCalls == 'friends' && !isFriend) return false;
  return true;
}

/// Payload builders for kind-25053 rumor content; the caller attaches `nym` at send.
class CallSignal {
  CallSignal._();

  static Map<String, dynamic> invite({
    required String callId,
    required CallKind kind,
    required bool isGroup,
    String? groupId,
    required List<String> members,
  }) =>
      {
        'type': 'invite',
        'callId': callId,
        'kind': kind.wire,
        'isGroup': isGroup,
        'groupId': groupId,
        'members': members,
      };

  static Map<String, dynamic> accept(String callId) =>
      {'type': 'accept', 'callId': callId};

  /// Reason is busy, declined or media.
  static Map<String, dynamic> reject(String callId, String reason) =>
      {'type': 'reject', 'callId': callId, 'reason': reason};

  static Map<String, dynamic> cancel(String callId) =>
      {'type': 'cancel', 'callId': callId};

  static Map<String, dynamic> hangup(String callId) =>
      {'type': 'hangup', 'callId': callId};

  static Map<String, dynamic> offer({
    required String callId,
    required String sdpType,
    required String sdp,
  }) =>
      {
        'type': 'offer',
        'callId': callId,
        'sdp': {'type': sdpType, 'sdp': sdp},
      };

  static Map<String, dynamic> answer({
    required String callId,
    required String sdpType,
    required String sdp,
  }) =>
      {
        'type': 'answer',
        'callId': callId,
        'sdp': {'type': sdpType, 'sdp': sdp},
      };

  static Map<String, dynamic> ice({
    required String callId,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) =>
      {
        'type': 'ice',
        'callId': callId,
        'candidate': {
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
        },
      };

  static Map<String, dynamic> share(
          {required String callId, required bool on}) =>
      {'type': 'share', 'callId': callId, 'on': on};

  /// Adds `emojiTags` only for a custom `:shortcode:` the receiver may lack; omitted when empty.
  static Map<String, dynamic> reaction({
    required String callId,
    required String emoji,
    List<List<String>>? emojiTags,
  }) =>
      {
        'type': 'reaction',
        'callId': callId,
        'emoji': emoji,
        if (emojiTags != null && emojiTags.isNotEmpty) 'emojiTags': emojiTags,
      };

  static Map<String, dynamic> chat({
    required String callId,
    required String text,
    required String mid,
  }) =>
      {
        'type': 'chat',
        'callId': callId,
        // Outbound chat is capped at 2000 chars.
        'text': text.length > 2000 ? text.substring(0, 2000) : text,
        'mid': mid,
      };

  /// op is add or remove; `emojiTags` as in [reaction].
  static Map<String, dynamic> chatReaction({
    required String callId,
    required String mid,
    required String emoji,
    required String op,
    List<List<String>>? emojiTags,
  }) =>
      {
        'type': 'chat-reaction',
        'callId': callId,
        'mid': mid,
        'emoji': emoji,
        'op': op,
        if (emojiTags != null && emojiTags.isNotEmpty) 'emojiTags': emojiTags,
      };

  /// status is start or stop.
  static Map<String, dynamic> chatTyping({
    required String callId,
    required String status,
  }) =>
      {'type': 'chat-typing', 'callId': callId, 'status': status};

  static Map<String, dynamic> chatRead({
    required String callId,
    required String mid,
  }) =>
      {'type': 'chat-read', 'callId': callId, 'mid': mid};

  static Map<String, dynamic> presentRequest(String callId) =>
      {'type': 'present-request', 'callId': callId};

  static Map<String, dynamic> presentState({
    required String callId,
    required bool restricted,
    String? presenter,
  }) =>
      {
        'type': 'present-state',
        'callId': callId,
        'restricted': restricted,
        'presenter': presenter,
      };
}

/// The 8 default reaction-bar emoji.
const List<String> kCallReactionDefaults = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '👏',
  '🎉',
  '🙌',
  '🔥'
];

/// Recents first, padded with defaults, deduped, unknown custom packs dropped, capped at 8.
List<String> callReactionBarEmojis(
  List<String> recents, {
  bool Function(String code)? isKnownCustom,
}) {
  final out = <String>[];
  final seen = <String>{};
  bool known(String e) {
    final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
    if (m == null) return true;
    return isKnownCustom?.call(m.group(1)!) ?? false;
  }

  void add(String e) {
    if (e.isNotEmpty && known(e) && !seen.contains(e)) {
      seen.add(e);
      out.add(e);
    }
  }

  for (final e in recents) {
    add(e);
  }
  for (final e in kCallReactionDefaults) {
    add(e);
  }
  return out.take(8).toList();
}
