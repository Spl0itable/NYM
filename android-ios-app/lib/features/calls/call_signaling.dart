// call_signaling.dart - Pure, plugin-free signaling logic for WebRTC calls.
//
// Mirrors `../js/modules/calls.js` message shapes exactly. Everything here is
// side-effect free so it can be unit-tested without flutter_webrtc, media
// permissions or a relay. The CallService composes these with the actual
// RTCPeerConnection plumbing.

import 'dart:math';

/// Call media kind. calls.js only ever uses the strings `'audio'` / `'video'`.
enum CallKind {
  audio,
  video;

  String get wire => this == CallKind.video ? 'video' : 'audio';

  static CallKind fromWire(Object? v) =>
      v == 'video' ? CallKind.video : CallKind.audio;
}

/// High-level call lifecycle exposed to the UI via `callStateProvider`.
///
/// - [idle]: no call.
/// - [ringing]: we placed an outgoing call, waiting for the peer (calls.js
///   `activeCall.status === 'outgoing'`).
/// - [incoming]: an inbound invite is being presented (calls.js
///   `incomingCall`).
/// - [connecting]: accepted / answered, negotiating peers (calls.js
///   `activeCall.status === 'connecting'`).
/// - [active]: at least one peer connected (calls.js
///   `activeCall.status === 'active'`).
/// - [ended]: terminal — collapses back to [idle] for the next call.
enum CallPhase { idle, ringing, incoming, connecting, active, ended }

/// calls.js `_genCallId()`:
///   'call-' + Math.random().toString(36).slice(2) + Date.now().toString(36)
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

/// Ring / incoming timeout — calls.js uses 45000ms on both the outgoing
/// ringTimeout and the incomingCall.timeout.
const Duration kCallRingTimeout = Duration(seconds: 45);

/// Glare guard. calls.js `_connectToPeer`:
///   `if (this.pubkey < peerPubkey) this._makeOffer(peerPubkey);`
/// i.e. the lexicographically-smaller pubkey is the offerer for that pair.
bool isOfferer({required String selfPubkey, required String peerPubkey}) {
  return selfPubkey.compareTo(peerPubkey) < 0;
}

/// `acceptCalls` preference gate, mirroring calls.js `_onCallInvite`:
///   pref 'disabled' -> never ring
///   pref 'friends'  -> ring only if the caller is a friend
///   pref 'enabled'  -> always ring
/// [isFriend] is supplied by the host (engine `isFriend`).
bool shouldRingForInvite({
  required String acceptCalls,
  required bool isFriend,
}) {
  if (acceptCalls == 'disabled') return false;
  if (acceptCalls == 'friends' && !isFriend) return false;
  return true;
}

/// Builders for the signaling payloads that ride inside a kind-25053 rumor's
/// `content`. Each returns the exact JSON shape calls.js emits (the engine's
/// `sendCallSignal` adds nothing but the `nym` field at send time — calls.js
/// merges `{ ...payload, nym }` in `_sendCallSignal`; we let the caller attach
/// `nym` so these stay pure and comparable in tests).
class CallSignal {
  CallSignal._();

  /// `{ type:'invite', callId, kind, isGroup, groupId, members }`
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

  /// `{ type:'accept', callId }`
  static Map<String, dynamic> accept(String callId) =>
      {'type': 'accept', 'callId': callId};

  /// `{ type:'reject', callId, reason }` — reason ∈ busy|declined|media.
  static Map<String, dynamic> reject(String callId, String reason) =>
      {'type': 'reject', 'callId': callId, 'reason': reason};

  /// `{ type:'cancel', callId }`
  static Map<String, dynamic> cancel(String callId) =>
      {'type': 'cancel', 'callId': callId};

  /// `{ type:'hangup', callId }`
  static Map<String, dynamic> hangup(String callId) =>
      {'type': 'hangup', 'callId': callId};

  /// `{ type:'offer', callId, sdp:{ type, sdp } }`
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

  /// `{ type:'answer', callId, sdp:{ type, sdp } }`
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

  /// `{ type:'ice', callId, candidate:{ candidate, sdpMid, sdpMLineIndex } }`
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

  /// `{ type:'share', callId, on }`
  static Map<String, dynamic> share({required String callId, required bool on}) =>
      {'type': 'share', 'callId': callId, 'on': on};

  /// `{ type:'reaction', callId, emoji }`, plus an optional `emojiTags` array of
  /// `['emoji', code, url]` tuples when [emoji] is a custom `:shortcode:` whose
  /// pack the receiver may not have. calls.js `sendCallReaction` (1149-1160):
  /// `const tags = customEmojiTagsForContent(emoji); if (tags.length)
  /// payload.emojiTags = tags;` — the field is omitted entirely when empty.
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

  /// `{ type:'chat', callId, text, mid }`
  static Map<String, dynamic> chat({
    required String callId,
    required String text,
    required String mid,
  }) =>
      {
        'type': 'chat',
        'callId': callId,
        // calls.js slices outbound chat to 2000 chars.
        'text': text.length > 2000 ? text.substring(0, 2000) : text,
        'mid': mid,
      };

  /// `{ type:'chat-reaction', callId, mid, emoji, op }` (op ∈ add|remove), plus
  /// an optional `emojiTags` array when [emoji] is a custom `:shortcode:`. calls.js
  /// `_toggleCallChatReaction` (1644-1646) attaches `customEmojiTagsForContent(emoji)`
  /// the same way the fly-reaction does, omitting the field when empty.
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

  /// `{ type:'chat-typing', callId, status }` (status ∈ start|stop).
  /// calls.js `_sendCallTypingSignal` (1246).
  static Map<String, dynamic> chatTyping({
    required String callId,
    required String status,
  }) =>
      {'type': 'chat-typing', 'callId': callId, 'status': status};

  /// `{ type:'chat-read', callId, mid }`. calls.js `_sendCallChatRead` (1324).
  static Map<String, dynamic> chatRead({
    required String callId,
    required String mid,
  }) =>
      {'type': 'chat-read', 'callId': callId, 'mid': mid};

  /// `{ type:'present-request', callId }`. calls.js `requestToPresent` (1038).
  static Map<String, dynamic> presentRequest(String callId) =>
      {'type': 'present-request', 'callId': callId};

  /// `{ type:'present-state', callId, restricted, presenter }`.
  /// calls.js `_broadcastPresentState` (1055).
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

/// The 8 default reaction-bar emoji (calls.js `_callReactionDefaults`, 1102).
const List<String> kCallReactionDefaults = [
  '👍', '❤️', '😂', '😮', '👏', '🎉', '🙌', '🔥'
];

/// Builds the call reactions-bar emoji list: recents-first, padded with the 8
/// defaults, deduped, custom `:code:` shortcodes whose pack is unknown dropped,
/// capped at 8. Mirrors `_callReactionBarEmojis` (calls.js 1106-1118).
///
/// [isKnownCustom] decides whether a `:shortcode:` token's pack is still
/// available; unicode emoji are always kept.
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
