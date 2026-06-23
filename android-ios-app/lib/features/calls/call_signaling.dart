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

  /// `{ type:'reaction', callId, emoji }`
  static Map<String, dynamic> reaction({
    required String callId,
    required String emoji,
  }) =>
      {'type': 'reaction', 'callId': callId, 'emoji': emoji};

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
}
