// Immutable call snapshot for the UI; the WebRTC objects stay inside CallService.

import 'call_signaling.dart';

/// Remote participant render state; the renderer lives in the service keyed by [pubkey].
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

/// Self call-chat row delivery: `sent` until a peer reads it, then `read`.
enum CallChatDelivery { sent, read }

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

  /// emoji -> reactor pubkeys.
  final Map<String, Set<String>> reactions;

  /// pubkey -> nym of peers that read this self message.
  final Map<String, String> readers;

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

/// One flying in-call reaction; the overlay animates it upward over ~3.1s.
class CallFlyReaction {
  const CallFlyReaction({
    required this.id,
    required this.emoji,
    required this.leftPercent,
    this.pubkey,
    this.who,
  });

  /// Stable key so the overlay can keep one [AnimationController] per item.
  final int id;
  final String emoji;

  /// Horizontal position as a 0–100 percentage.
  final double leftPercent;

  /// Reactor pubkey for the decorated "who" pill; null for self.
  final String? pubkey;

  /// Plain "who" label (e.g. "You") when [pubkey] is null.
  final String? who;
}

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
    this.ringing = const [],
    this.speakerOn = false,
    this.headset = false,
    this.canRouteAudio = false,
    this.hasCamera = false,
    this.rejoinGroupId,
  });

  final CallPhase phase;
  final String? callId;
  final CallKind kind;
  final bool isGroup;
  final String? groupId;

  /// Remote pubkey and nym for an incoming or 1:1 call.
  final String? peerPubkey;
  final String? peerNym;

  /// Remote participants, excluding self.
  final List<CallParticipant> participants;

  final bool muted;
  final bool cameraOff;
  final bool sharing;
  final String facingMode; // 'user' | 'environment'

  /// "Calling…", "Connecting…" or elapsed time like "0:42".
  final String statusText;
  final int elapsedSeconds;

  final List<CallChatMessage> chatLog;
  final int chatUnread;

  final List<String> typingPubkeys;

  final List<CallFlyReaction> flyReactions;

  final bool switchingCamera;

  /// Video input count; the switch-camera button hides unless more than one.
  final int videoInputCount;

  /// "Only the presenter can share" is on.
  final bool shareRestricted;

  final String? presenter;

  final Set<String> presentRequests;

  final bool isMod;

  final bool canShareScreen;

  final List<String> ringing;

  final bool speakerOn;

  final bool headset;

  final bool canRouteAudio;

  final bool hasCamera;

  final String? rejoinGroupId;

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
    List<String>? ringing,
    bool? speakerOn,
    bool? headset,
    bool? canRouteAudio,
    bool? hasCamera,
    String? rejoinGroupId,
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
        ringing: ringing ?? this.ringing,
        speakerOn: speakerOn ?? this.speakerOn,
        headset: headset ?? this.headset,
        canRouteAudio: canRouteAudio ?? this.canRouteAudio,
        hasCamera: hasCamera ?? this.hasCamera,
        rejoinGroupId: rejoinGroupId ?? this.rejoinGroupId,
      );
}
