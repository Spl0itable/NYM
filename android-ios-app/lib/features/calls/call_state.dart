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

/// Per-message delivery state for a self call-chat row (calls.js
/// `.call-chat-receipt`): `sent` until at least one peer reads it, then `read`.
enum CallChatDelivery { sent, read }

/// One in-call chat row (calls.js `ac.chatLog` entries).
class CallChatMessage {
  const CallChatMessage({
    required this.pubkey,
    required this.text,
    required this.isSelf,
    required this.mid,
    this.reactions = const {},
    this.readers = const {},
    this.delivery = CallChatDelivery.sent,
  });

  final String pubkey;
  final String text;
  final bool isSelf;
  final String mid;

  /// emoji → set of reactor pubkeys (calls.js `ac.chatReactions[mid]`). A
  /// reaction is "self" when the set contains the local pubkey.
  final Map<String, Set<String>> reactions;

  /// pubkey → nym of peers that have read this self message (group calls render
  /// reader avatars; 1:1 renders ✓/✓✓). calls.js `ac.chatReaders[mid]`.
  final Map<String, String> readers;

  /// 1:1 receipt state for self rows (calls.js delivery-status sent|read).
  final CallChatDelivery delivery;

  CallChatMessage copyWith({
    Map<String, Set<String>>? reactions,
    Map<String, String>? readers,
    CallChatDelivery? delivery,
  }) =>
      CallChatMessage(
        pubkey: pubkey,
        text: text,
        isSelf: isSelf,
        mid: mid,
        reactions: reactions ?? this.reactions,
        readers: readers ?? this.readers,
        delivery: delivery ?? this.delivery,
      );
}

/// One floating/flying in-call reaction (calls.js `.call-react-fly-item`). The
/// overlay animates each from the bottom upward over ~3.1s, then drops it.
class CallFlyReaction {
  const CallFlyReaction({
    required this.id,
    required this.emoji,
    required this.leftPercent,
    this.pubkey,
    this.who,
  });

  /// Stable key so the overlay can keep an [AnimationController] per item.
  final int id;
  final String emoji;

  /// Horizontal position as a 0–100 percentage (calls.js `8 + random*74`).
  final double leftPercent;

  /// The reactor's pubkey (decorated nym in the "who" pill); null for self.
  final String? pubkey;

  /// A plain "who" label (e.g. "You") when [pubkey] is null.
  final String? who;
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
    this.typingPubkeys = const [],
    this.flyReactions = const [],
    this.switchingCamera = false,
    this.videoInputCount = 0,
    this.shareRestricted = false,
    this.presenter,
    this.presentRequests = const {},
    this.isMod = false,
    this.canShareScreen = true,
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

  /// Pubkeys currently typing in call chat (decorated by the overlay). calls.js
  /// `ac.chatTypers` keys.
  final List<String> typingPubkeys;

  /// Active floating reactions (self + incoming) to animate over the grid.
  final List<CallFlyReaction> flyReactions;

  // --- presenter / screen-share moderation (group calls, calls.js) ----------

  /// Mid-switch-camera flag — disables the switch button (calls.js
  /// `ac.switchingCamera`).
  final bool switchingCamera;

  /// Number of video input devices (the switch-cam button hides unless > 1;
  /// calls.js `_updateCameraSwitchBtn`).
  final int videoInputCount;

  /// "Only the presenter can share" is on (calls.js `ac.shareRestricted`).
  final bool shareRestricted;

  /// The assigned presenter's pubkey, if any (calls.js `ac.presenter`).
  final String? presenter;

  /// Pubkeys that requested to present (calls.js `ac.presentRequests`).
  final Set<String> presentRequests;

  /// We can moderate this (group) call (calls.js `_isCallMod`).
  final bool isMod;

  /// We are allowed to screen-share right now (calls.js `canShareScreen`).
  final bool canShareScreen;

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
    List<String>? typingPubkeys,
    List<CallFlyReaction>? flyReactions,
    bool? switchingCamera,
    int? videoInputCount,
    bool? shareRestricted,
    String? presenter,
    Set<String>? presentRequests,
    bool? isMod,
    bool? canShareScreen,
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
        typingPubkeys: typingPubkeys ?? this.typingPubkeys,
        flyReactions: flyReactions ?? this.flyReactions,
        switchingCamera: switchingCamera ?? this.switchingCamera,
        videoInputCount: videoInputCount ?? this.videoInputCount,
        shareRestricted: shareRestricted ?? this.shareRestricted,
        presenter: presenter ?? this.presenter,
        presentRequests: presentRequests ?? this.presentRequests,
        isMod: isMod ?? this.isMod,
        canShareScreen: canShareScreen ?? this.canShareScreen,
      );
}
