// call_state.dart - Immutable snapshot of the active/incoming call for the UI.
//
// The CallService keeps the mutable WebRTC machinery (RTCPeerConnection map,
// MediaStream renderers) internally and publishes this plain snapshot through
// `callStateProvider` so widgets rebuild without touching plugin objects.

import 'call_signaling.dart';

/// A remote participant's render state. The actual RTCVideoRenderer lives in
/// the service (keyed by pubkey); the UI looks it up by [pubkey].
class CallParticipant {
  const CallParticipant({
    required this.pubkey,
    required this.nym,
    this.connected = false,
    this.hasVideo = false,
    this.sharing = false,
  });

  final String pubkey;
  final String nym;

  /// RTCPeerConnection reached `connected`.
  final bool connected;

  /// The remote stream currently carries a live video track.
  final bool hasVideo;

  /// The peer is screen-sharing (calls.js `sharingPeers`).
  final bool sharing;

  CallParticipant copyWith({
    String? nym,
    bool? connected,
    bool? hasVideo,
    bool? sharing,
  }) =>
      CallParticipant(
        pubkey: pubkey,
        nym: nym ?? this.nym,
        connected: connected ?? this.connected,
        hasVideo: hasVideo ?? this.hasVideo,
        sharing: sharing ?? this.sharing,
      );
}

/// One in-call chat row (calls.js `ac.chatLog` entries).
class CallChatMessage {
  const CallChatMessage({
    required this.pubkey,
    required this.text,
    required this.isSelf,
    required this.mid,
  });

  final String pubkey;
  final String text;
  final bool isSelf;
  final String mid;
}

/// The whole call snapshot consumed by the overlay + incoming modal.
class CallState {
  const CallState({
    this.phase = CallPhase.idle,
    this.callId,
    this.kind = CallKind.audio,
    this.isGroup = false,
    this.groupId,
    this.peerPubkey,
    this.peerNym,
    this.participants = const [],
    this.muted = false,
    this.cameraOff = false,
    this.sharing = false,
    this.facingMode = 'user',
    this.statusText = '',
    this.elapsedSeconds = 0,
    this.chatLog = const [],
    this.chatUnread = 0,
    this.typingNyms = const [],
  });

  final CallPhase phase;
  final String? callId;
  final CallKind kind;
  final bool isGroup;
  final String? groupId;

  /// For an incoming call / 1:1 call: the remote pubkey + nym (caller).
  final String? peerPubkey;
  final String? peerNym;

  /// Connected/known remote participants (excludes self).
  final List<CallParticipant> participants;

  final bool muted;
  final bool cameraOff;
  final bool sharing;
  final String facingMode; // 'user' | 'environment'

  /// "Calling…" / "Connecting…" / "0:42" — mirrors calls.js `callStatus`.
  final String statusText;
  final int elapsedSeconds;

  final List<CallChatMessage> chatLog;
  final int chatUnread;
  final List<String> typingNyms;

  bool get isActiveCall =>
      phase == CallPhase.ringing ||
      phase == CallPhase.connecting ||
      phase == CallPhase.active;

  bool get isIncoming => phase == CallPhase.incoming;

  static const idle = CallState();

  CallState copyWith({
    CallPhase? phase,
    String? callId,
    CallKind? kind,
    bool? isGroup,
    String? groupId,
    String? peerPubkey,
    String? peerNym,
    List<CallParticipant>? participants,
    bool? muted,
    bool? cameraOff,
    bool? sharing,
    String? facingMode,
    String? statusText,
    int? elapsedSeconds,
    List<CallChatMessage>? chatLog,
    int? chatUnread,
    List<String>? typingNyms,
  }) =>
      CallState(
        phase: phase ?? this.phase,
        callId: callId ?? this.callId,
        kind: kind ?? this.kind,
        isGroup: isGroup ?? this.isGroup,
        groupId: groupId ?? this.groupId,
        peerPubkey: peerPubkey ?? this.peerPubkey,
        peerNym: peerNym ?? this.peerNym,
        participants: participants ?? this.participants,
        muted: muted ?? this.muted,
        cameraOff: cameraOff ?? this.cameraOff,
        sharing: sharing ?? this.sharing,
        facingMode: facingMode ?? this.facingMode,
        statusText: statusText ?? this.statusText,
        elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
        chatLog: chatLog ?? this.chatLog,
        chatUnread: chatUnread ?? this.chatUnread,
        typingNyms: typingNyms ?? this.typingNyms,
      );
}
