// call_service.dart - Full-mesh WebRTC calling over NIP-17 gift-wrapped
// kind-25053 signaling. Native port of `../js/modules/calls.js`.
//
// Responsibilities (mirroring calls.js):
//  - 1:1 and group (mesh) calls, audio or video.
//  - Per-remote RTCPeerConnection, glare-guarded by `selfPubkey < peerPubkey`
//    (the smaller pubkey is the offerer for that pair).
//  - Signaling state machine (invite/accept/reject/cancel/hangup/offer/answer/
//    ice/share/reaction/chat) over NostrController.sendCallSignal /
//    setCallSignalHandler.
//  - 45s ring timeout (outgoing) and incoming-call timeout.
//  - mute / camera toggle / screen share / switch camera / end.
//  - A published CallState snapshot via `callStateProvider`.
//
// Pure logic (payload builders, glare, ring timeout, sound selection) lives in
// call_signaling.dart so it can be tested without the plugin.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/constants/relays.dart';
import '../../models/group.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import 'call_signaling.dart';
import 'call_state.dart';

/// Internal per-peer state (calls.js `activeCall.peers` entry).
class _Peer {
  _Peer({required this.pc, required this.nym});

  final RTCPeerConnection pc;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  MediaStream? stream;
  final List<RTCIceCandidate> pendingCandidates = [];
  bool haveRemote = false;
  RTCRtpSender? videoSender;
  String nym;
  bool connected = false;
  bool sharing = false; // peer is screen-sharing
}

/// Internal mutable active-call record (calls.js `activeCall`).
class _ActiveCall {
  _ActiveCall({
    required this.callId,
    required this.kind,
    required this.isGroup,
    this.groupId,
    required this.members,
    required this.localStream,
    required this.status,
  });

  final String callId;
  final CallKind kind;
  final bool isGroup;
  final String? groupId;
  List<String> members; // includes self
  MediaStream localStream;
  String status; // 'outgoing' | 'connecting' | 'active'

  final Map<String, _Peer> peers = {};
  bool muted = false;
  bool cameraOff = false;
  String facingMode = 'user';
  bool sharing = false;
  MediaStream? screenStream;
  int startedAt = 0;
  Timer? ringTimeout;
  Timer? timerInterval;
  final List<CallChatMessage> chatLog = [];
  int chatUnread = 0;
}

/// Internal incoming-call record (calls.js `incomingCall`).
class _IncomingCall {
  _IncomingCall({
    required this.callId,
    required this.kind,
    required this.isGroup,
    this.groupId,
    required this.from,
    required this.nym,
    required this.members,
  });

  final String callId;
  final CallKind kind;
  final bool isGroup;
  final String? groupId;
  final String from;
  final String nym;
  final List<String> members;
  final Set<String> acceptedPeers = {};
  Timer? timeout;
}

class CallService {
  CallService(this._ref) {
    _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    _ref.read(nostrControllerProvider).setCallSignalHandler(handleSignal);
  }

  final Ref _ref;
  String _self = '';

  _ActiveCall? _active;
  _IncomingCall? _incoming;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _localRendererReady = false;

  /// The published snapshot.
  final ValueNotifier<CallState> state = ValueNotifier(CallState.idle);

  /// Local self-preview renderer (the overlay shows it muted).
  RTCVideoRenderer get localRenderer => _localRenderer;

  /// Look up a remote participant's renderer by pubkey (for the grid).
  RTCVideoRenderer? rendererFor(String pubkey) => _active?.peers[pubkey]?.renderer;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Start a 1:1 call to [peer]. calls.js `startCall` (PM branch).
  Future<void> startCall(String peer, {bool video = false}) async {
    if (_self.isEmpty) {
      _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    }
    if (_active != null || _incoming != null) return; // already in a call
    await _begin(
      kind: video ? CallKind.video : CallKind.audio,
      isGroup: false,
      groupId: null,
      targets: [peer],
    );
  }

  /// Start a group (mesh) call across [groupId]'s members. calls.js `startCall`
  /// (group branch): targets = members minus self.
  Future<void> startGroupCall(String groupId, {bool video = false}) async {
    if (_self.isEmpty) {
      _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    }
    if (_active != null || _incoming != null) return;
    final group = _groupById(groupId);
    if (group == null) return;
    final targets = group.members.where((pk) => pk != _self).toList();
    if (targets.isEmpty) return;
    await _begin(
      kind: video ? CallKind.video : CallKind.audio,
      isGroup: true,
      groupId: groupId,
      targets: targets,
    );
  }

  /// Accept the current incoming call. calls.js `acceptCall`.
  Future<void> answer() async {
    final inc = _incoming;
    if (inc == null) return;
    inc.timeout?.cancel();

    final stream = await _getLocalMedia(inc.kind);
    if (stream == null) {
      _send(inc.from, CallSignal.reject(inc.callId, 'media'));
      _incoming = null;
      _publishIdle();
      return;
    }

    final early = inc.acceptedPeers.toList();
    final active = _ActiveCall(
      callId: inc.callId,
      kind: inc.kind,
      isGroup: inc.isGroup,
      groupId: inc.groupId,
      members: List.of(inc.members),
      localStream: stream,
      status: 'connecting',
    );
    _active = active;
    _incoming = null;
    await _attachLocalPreview(stream);

    // Broadcast accept to all other members, then connect.
    for (final pk in active.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.accept(active.callId));
    }
    await _connectToPeer(inc.from);
    for (final pk in early) {
      if (pk != _self && pk != inc.from) await _connectToPeer(pk);
    }
    _publish();
  }

  /// Reject the current incoming call. calls.js `rejectCall`.
  void reject() {
    final inc = _incoming;
    if (inc == null) return;
    inc.timeout?.cancel();
    _send(inc.from, CallSignal.reject(inc.callId, 'declined'));
    _incoming = null;
    _publishIdle();
  }

  /// End / hang up the active call. calls.js `hangupCall`.
  void end() {
    final ac = _active;
    if (ac != null) {
      for (final pk in ac.members.where((pk) => pk != _self)) {
        _send(pk, CallSignal.hangup(ac.callId));
      }
    }
    _endCall();
  }

  /// Toggle microphone mute. calls.js `toggleCallMute`.
  void toggleMute() {
    final ac = _active;
    if (ac == null) return;
    ac.muted = !ac.muted;
    for (final t in ac.localStream.getAudioTracks()) {
      t.enabled = !ac.muted;
    }
    _publish();
  }

  /// Toggle the camera. calls.js `toggleCallVideo` (video calls only).
  void toggleCamera() {
    final ac = _active;
    if (ac == null || ac.kind != CallKind.video) return;
    ac.cameraOff = !ac.cameraOff;
    for (final t in ac.localStream.getVideoTracks()) {
      t.enabled = !ac.cameraOff;
    }
    _publish();
  }

  /// Switch front/rear camera. calls.js `switchCamera`.
  Future<void> switchCamera() async {
    final ac = _active;
    if (ac == null || ac.kind != CallKind.video || ac.sharing) return;
    final track = ac.localStream.getVideoTracks().isNotEmpty
        ? ac.localStream.getVideoTracks().first
        : null;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
      ac.facingMode = ac.facingMode == 'environment' ? 'user' : 'environment';
      _publish();
    } catch (_) {
      // ignore — camera may not support switching
    }
  }

  /// Start/stop screen share. calls.js `toggleScreenShare` (no group
  /// presenter restriction here — 1:1 + open group).
  Future<void> toggleScreenShare() async {
    final ac = _active;
    if (ac == null) return;
    if (ac.sharing) {
      await _stopScreenShare();
    } else {
      await _startScreenShare();
    }
  }

  /// Send an in-call chat message. calls.js `sendCallChat`.
  void sendChat(String text) {
    final ac = _active;
    final trimmed = text.trim();
    if (ac == null || trimmed.isEmpty) return;
    final mid = genCallId();
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.chat(callId: ac.callId, text: trimmed, mid: mid));
    }
    ac.chatLog.add(CallChatMessage(
        pubkey: _self, text: trimmed, isSelf: true, mid: mid));
    _publish();
  }

  /// Send a floating reaction. calls.js `sendCallReaction`.
  void sendReaction(String emoji) {
    final ac = _active;
    if (ac == null || emoji.isEmpty) return;
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.reaction(callId: ac.callId, emoji: emoji));
    }
  }

  /// Mark in-call chat as read (clears the unread badge). calls.js
  /// `toggleCallChat` open branch.
  void markChatRead() {
    final ac = _active;
    if (ac == null) return;
    ac.chatUnread = 0;
    _publish();
  }

  void dispose() {
    // Reading another provider can fail if the container is already tearing
    // down; deregistering the handler is best-effort.
    try {
      _ref.read(nostrControllerProvider).setCallSignalHandler(null);
    } catch (_) {}
    _endCall();
    _localRenderer.dispose();
    state.dispose();
  }

  // ---------------------------------------------------------------------------
  // Outgoing call setup
  // ---------------------------------------------------------------------------

  Future<void> _begin({
    required CallKind kind,
    required bool isGroup,
    String? groupId,
    required List<String> targets,
  }) async {
    final stream = await _getLocalMedia(kind);
    if (stream == null) return;

    final callId = genCallId();
    final members = [_self, ...targets];
    final active = _ActiveCall(
      callId: callId,
      kind: kind,
      isGroup: isGroup,
      groupId: groupId,
      members: members,
      localStream: stream,
      status: 'outgoing',
    );
    _active = active;
    await _attachLocalPreview(stream);

    final invite = CallSignal.invite(
      callId: callId,
      kind: kind,
      isGroup: isGroup,
      groupId: groupId,
      members: members,
    );
    for (final pk in targets) {
      _send(pk, invite);
    }
    _publish(statusText: isGroup ? 'Ringing group…' : 'Calling…');

    // 45s ring timeout — cancel the call if nobody answered (calls.js).
    active.ringTimeout = Timer(kCallRingTimeout, () {
      if (_active == active && active.status == 'outgoing') {
        for (final pk in targets) {
          _send(pk, CallSignal.cancel(callId));
        }
        _endCall();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Inbound signaling — calls.js handleCallSignalingEvent dispatch
  // ---------------------------------------------------------------------------

  /// Entry point registered via NostrController.setCallSignalHandler. [rumor]
  /// is the decoded kind-25053 rumor: { pubkey, content(JSON payload)... }.
  void handleSignal(Map<String, dynamic> rumor) {
    final sender = rumor['pubkey'] as String?;
    if (sender == null || sender == _self) return;
    final data = _decodePayload(rumor);
    if (data == null) return;
    switch (data['type']) {
      case 'invite':
        _onInvite(sender, data);
        break;
      case 'accept':
        _onAccept(sender, data);
        break;
      case 'reject':
        _onReject(sender, data);
        break;
      case 'cancel':
        _onCancel(sender, data);
        break;
      case 'hangup':
        _onHangup(sender, data);
        break;
      case 'offer':
        _onOffer(sender, data);
        break;
      case 'answer':
        _onAnswer(sender, data);
        break;
      case 'ice':
        _onIce(sender, data);
        break;
      case 'share':
        _onShare(sender, data);
        break;
      case 'reaction':
        // Floating reactions are visual only; surfaced via state if desired.
        break;
      case 'chat':
        _onChat(sender, data);
        break;
    }
  }

  Map<String, dynamic>? _decodePayload(Map<String, dynamic> rumor) {
    // The engine hands us the rumor; calls.js parses event.content JSON. Here
    // the payload fields may already be on the rumor (engine-decoded) or nested
    // under 'content'. Support both shapes defensively.
    if (rumor.containsKey('type')) return rumor;
    final content = rumor['content'];
    if (content is Map<String, dynamic>) return content;
    if (content is String) {
      try {
        final decoded = jsonDecodeMap(content);
        return decoded;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _onInvite(String sender, Map<String, dynamic> data) {
    // Accept-calls preference gate (calls.js _onCallInvite).
    final pref = _ref.read(settingsProvider).acceptCalls;
    final friend = _isFriend(sender);
    if (!shouldRingForInvite(acceptCalls: pref, isFriend: friend)) return;
    if (_active != null || _incoming != null) {
      _send(sender,
          CallSignal.reject(data['callId'] as String, 'busy'));
      return;
    }

    final kind = CallKind.fromWire(data['kind']);
    final isGroup = data['isGroup'] == true;
    final groupId = data['groupId'] as String?;
    final members = <String>[sender, _self];
    if (isGroup && groupId != null) {
      // Validate claimed members against the real group roster, mirroring
      // calls.js `_onCallInvite` (a claimed member is only added when there is
      // no known roster, or the roster actually contains them).
      final group = _groupById(groupId);
      final roster = (group != null && group.members.isNotEmpty)
          ? group.members
          : null;
      final claimed = (data['members'] as List?)?.cast<String>() ?? const [];
      for (final pk in claimed) {
        if (pk != sender &&
            pk != _self &&
            !members.contains(pk) &&
            (roster == null || roster.contains(pk))) {
          members.add(pk);
        }
      }
    }

    final inc = _IncomingCall(
      callId: data['callId'] as String,
      kind: kind,
      isGroup: isGroup,
      groupId: groupId,
      from: sender,
      nym: (data['nym'] as String?) ?? _nymFor(sender),
      members: members,
    );
    _incoming = inc;
    inc.timeout = Timer(kCallRingTimeout, () {
      if (_incoming == inc) {
        _incoming = null;
        _publishIdle();
      }
    });
    _publish();
  }

  void _onAccept(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac != null && ac.callId == data['callId']) {
      if (!ac.members.contains(sender)) return;
      if (ac.status == 'outgoing') {
        ac.status = 'connecting';
        ac.ringTimeout?.cancel();
        _publish(statusText: 'Connecting…');
      }
      _connectToPeer(sender);
      return;
    }
    final inc = _incoming;
    if (inc != null && inc.callId == data['callId']) {
      if (inc.members.contains(sender)) inc.acceptedPeers.add(sender);
    }
  }

  void _onReject(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    if (!ac.isGroup) {
      _endCall();
    }
  }

  void _onCancel(String sender, Map<String, dynamic> data) {
    final inc = _incoming;
    if (inc != null && inc.callId == data['callId'] && sender == inc.from) {
      inc.timeout?.cancel();
      _incoming = null;
      _publishIdle();
    }
  }

  void _onHangup(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    _removePeer(sender);
    if (!ac.isGroup || ac.peers.isEmpty) {
      _endCall();
    } else {
      _publish();
    }
  }

  Future<void> _onOffer(String sender, Map<String, dynamic> data) async {
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    if (!ac.peers.containsKey(sender)) await _connectToPeer(sender);
    final peer = ac.peers[sender];
    if (peer == null) return;
    try {
      final sdp = data['sdp'] as Map;
      await peer.pc.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?));
      peer.haveRemote = true;
      await _flushCandidates(sender);
      final answer = await peer.pc.createAnswer();
      await peer.pc.setLocalDescription(answer);
      _send(
          sender,
          CallSignal.answer(
            callId: ac.callId,
            sdpType: answer.type ?? 'answer',
            sdp: answer.sdp ?? '',
          ));
    } catch (e) {
      debugPrint('CallService offer error: $e');
    }
  }

  Future<void> _onAnswer(String sender, Map<String, dynamic> data) async {
    final ac = _active;
    if (ac == null || !ac.members.contains(sender)) return;
    final peer = ac.peers[sender];
    if (peer == null) return;
    try {
      final sdp = data['sdp'] as Map;
      await peer.pc.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?));
      peer.haveRemote = true;
      await _flushCandidates(sender);
    } catch (e) {
      debugPrint('CallService answer error: $e');
    }
  }

  Future<void> _onIce(String sender, Map<String, dynamic> data) async {
    final ac = _active;
    if (ac == null || !ac.members.contains(sender)) return;
    final peer = ac.peers[sender];
    final c = data['candidate'];
    if (peer == null || c is! Map) return;
    final candidate = RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (peer.haveRemote) {
      try {
        await peer.pc.addCandidate(candidate);
      } catch (_) {}
    } else {
      peer.pendingCandidates.add(candidate);
    }
  }

  void _onShare(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    final peer = ac.peers[sender];
    if (peer != null) peer.sharing = data['on'] == true;
    _publish();
  }

  void _onChat(String sender, Map<String, dynamic> data) {
    final ac = _active;
    final text = data['text'];
    if (ac == null || ac.callId != data['callId'] || text is! String) return;
    ac.chatLog.add(CallChatMessage(
      pubkey: sender,
      text: text,
      isSelf: false,
      mid: (data['mid'] as String?) ?? genCallId(),
    ));
    ac.chatUnread += 1;
    _publish();
  }

  // ---------------------------------------------------------------------------
  // Peer connection plumbing — calls.js _connectToPeer
  // ---------------------------------------------------------------------------

  Future<void> _connectToPeer(String peerPubkey) async {
    final ac = _active;
    if (ac == null || peerPubkey == _self) return;
    if (ac.peers.containsKey(peerPubkey)) return;

    final pc = await createPeerConnection({
      'iceServers': IceServers.servers,
    });
    final peer = _Peer(pc: pc, nym: _nymFor(peerPubkey));
    await peer.renderer.initialize();
    ac.peers[peerPubkey] = peer;

    for (final track in ac.localStream.getTracks()) {
      final sender = await pc.addTrack(track, ac.localStream);
      if (track.kind == 'video') peer.videoSender = sender;
    }

    pc.onIceCandidate = (candidate) {
      if (_active != ac) return;
      _send(
          peerPubkey,
          CallSignal.ice(
            callId: ac.callId,
            candidate: candidate.candidate ?? '',
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ));
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        peer.stream = event.streams.first;
        peer.renderer.srcObject = peer.stream;
      }
      _publish();
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        peer.connected = true;
        _onPeerConnected();
      } else if ((s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) &&
          _active == ac &&
          ac.isGroup &&
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _removePeer(peerPubkey);
        _publish();
      }
    };

    _publish();

    // Glare guard: the lexicographically-smaller pubkey makes the offer.
    if (isOfferer(selfPubkey: _self, peerPubkey: peerPubkey)) {
      await _makeOffer(peerPubkey);
    }
  }

  Future<void> _makeOffer(String peerPubkey) async {
    final ac = _active;
    final peer = ac?.peers[peerPubkey];
    if (ac == null || peer == null) return;
    try {
      final offer = await peer.pc.createOffer();
      await peer.pc.setLocalDescription(offer);
      _send(
          peerPubkey,
          CallSignal.offer(
            callId: ac.callId,
            sdpType: offer.type ?? 'offer',
            sdp: offer.sdp ?? '',
          ));
    } catch (e) {
      debugPrint('CallService makeOffer error: $e');
    }
  }

  Future<void> _flushCandidates(String peerPubkey) async {
    final peer = _active?.peers[peerPubkey];
    if (peer == null) return;
    for (final c in peer.pendingCandidates) {
      try {
        await peer.pc.addCandidate(c);
      } catch (_) {}
    }
    peer.pendingCandidates.clear();
  }

  void _removePeer(String peerPubkey) {
    final ac = _active;
    if (ac == null) return;
    final peer = ac.peers.remove(peerPubkey);
    if (peer != null) {
      try {
        peer.pc.close();
      } catch (_) {}
      peer.renderer.srcObject = null;
      peer.renderer.dispose();
    }
  }

  void _onPeerConnected() {
    final ac = _active;
    if (ac == null) return;
    if (ac.status != 'active') {
      ac.status = 'active';
      ac.startedAt = DateTime.now().millisecondsSinceEpoch;
      ac.timerInterval?.cancel();
      ac.timerInterval = Timer.periodic(const Duration(seconds: 1), (_) {
        _publish();
      });
      _publish();
    }
  }

  // ---------------------------------------------------------------------------
  // Screen share — calls.js _startScreenShare / _stopScreenShare
  // ---------------------------------------------------------------------------

  Future<void> _startScreenShare() async {
    final ac = _active;
    if (ac == null || ac.sharing) return;
    MediaStream stream;
    try {
      stream = await navigator.mediaDevices
          .getDisplayMedia({'video': true, 'audio': false});
    } catch (_) {
      return;
    }
    final track = stream.getVideoTracks().isNotEmpty
        ? stream.getVideoTracks().first
        : null;
    if (track == null) {
      for (final t in stream.getTracks()) {
        t.stop();
      }
      return;
    }
    ac.screenStream = stream;
    ac.sharing = true;
    for (final entry in ac.peers.entries) {
      final peer = entry.value;
      if (peer.videoSender != null) {
        try {
          await peer.videoSender!.replaceTrack(track);
        } catch (_) {}
      } else {
        try {
          peer.videoSender = await peer.pc.addTrack(track, stream);
          await _makeOffer(entry.key);
        } catch (_) {}
      }
    }
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.share(callId: ac.callId, on: true));
    }
    _publish();
  }

  Future<void> _stopScreenShare() async {
    final ac = _active;
    if (ac == null || !ac.sharing) return;
    final cam = ac.localStream.getVideoTracks().isNotEmpty
        ? ac.localStream.getVideoTracks().first
        : null;
    for (final peer in ac.peers.values) {
      if (peer.videoSender != null) {
        try {
          await peer.videoSender!.replaceTrack(cam);
        } catch (_) {}
      }
    }
    final screen = ac.screenStream;
    if (screen != null) {
      for (final t in screen.getTracks()) {
        t.stop();
      }
    }
    ac.screenStream = null;
    ac.sharing = false;
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.share(callId: ac.callId, on: false));
    }
    _publish();
  }

  // ---------------------------------------------------------------------------
  // Teardown — calls.js _endCall
  // ---------------------------------------------------------------------------

  void _endCall() {
    final ac = _active;
    if (ac != null) {
      ac.ringTimeout?.cancel();
      ac.timerInterval?.cancel();
      for (final peer in ac.peers.values) {
        try {
          peer.pc.close();
        } catch (_) {}
        peer.renderer.srcObject = null;
        peer.renderer.dispose();
      }
      ac.peers.clear();
      for (final t in ac.localStream.getTracks()) {
        try {
          t.stop();
        } catch (_) {}
      }
      final screen = ac.screenStream;
      if (screen != null) {
        for (final t in screen.getTracks()) {
          try {
            t.stop();
          } catch (_) {}
        }
      }
    }
    _active = null;
    if (_localRendererReady) _localRenderer.srcObject = null;
    _publishIdle();
  }

  // ---------------------------------------------------------------------------
  // Media + helpers
  // ---------------------------------------------------------------------------

  Future<MediaStream?> _getLocalMedia(CallKind kind) async {
    try {
      final constraints = kind == CallKind.video
          ? {
              'audio': true,
              'video': {
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
                'facingMode': 'user',
              },
            }
          : {'audio': true, 'video': false};
      return await navigator.mediaDevices.getUserMedia(constraints);
    } catch (e) {
      debugPrint('CallService getUserMedia error: $e');
      return null;
    }
  }

  Future<void> _attachLocalPreview(MediaStream stream) async {
    if (!_localRendererReady) {
      await _localRenderer.initialize();
      _localRendererReady = true;
    }
    _localRenderer.srcObject = stream;
  }

  Future<bool> _send(String to, Map<String, dynamic> payload) {
    return _ref
        .read(nostrControllerProvider)
        .sendCallSignal(to: to, payload: payload);
  }

  Group? _groupById(String id) {
    final groups = _ref.read(appStateProvider).groups;
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  bool _isFriend(String pubkey) {
    // Friends aren't modeled on the native store yet; default false so the
    // 'friends' acceptCalls pref errs safe.
    // TODO(verify): wire to the engine's isFriend() once friends land natively.
    return false;
  }

  String _nymFor(String pubkey) {
    final users = _ref.read(usersProvider);
    final u = users[pubkey];
    if (u != null && u.nym.isNotEmpty) return u.nym;
    return pubkey.length >= 8 ? pubkey.substring(0, 8) : pubkey;
  }

  // ---------------------------------------------------------------------------
  // State publishing
  // ---------------------------------------------------------------------------

  void _publishIdle() {
    state.value = CallState.idle;
  }

  void _publish({String? statusText}) {
    final inc = _incoming;
    if (inc != null) {
      state.value = CallState(
        phase: CallPhase.incoming,
        callId: inc.callId,
        kind: inc.kind,
        isGroup: inc.isGroup,
        groupId: inc.groupId,
        peerPubkey: inc.from,
        peerNym: inc.nym,
      );
      return;
    }
    final ac = _active;
    if (ac == null) {
      _publishIdle();
      return;
    }

    final phase = ac.status == 'outgoing'
        ? CallPhase.ringing
        : ac.status == 'active'
            ? CallPhase.active
            : CallPhase.connecting;

    final participants = ac.peers.entries
        .map((e) => CallParticipant(
              pubkey: e.key,
              nym: e.value.nym,
              connected: e.value.connected,
              hasVideo: (e.value.stream?.getVideoTracks().isNotEmpty) ?? false,
              sharing: e.value.sharing,
            ))
        .toList();

    final elapsed = ac.startedAt == 0
        ? 0
        : (DateTime.now().millisecondsSinceEpoch - ac.startedAt) ~/ 1000;

    final peer = ac.isGroup
        ? null
        : ac.members.firstWhere((pk) => pk != _self, orElse: () => '');

    state.value = CallState(
      phase: phase,
      callId: ac.callId,
      kind: ac.kind,
      isGroup: ac.isGroup,
      groupId: ac.groupId,
      peerPubkey: peer != null && peer.isNotEmpty ? peer : null,
      peerNym: peer != null && peer.isNotEmpty ? _nymFor(peer) : null,
      participants: participants,
      muted: ac.muted,
      cameraOff: ac.cameraOff,
      sharing: ac.sharing,
      facingMode: ac.facingMode,
      statusText: statusText ??
          (phase == CallPhase.active
              ? _formatTimer(elapsed)
              : (phase == CallPhase.ringing
                  ? (ac.isGroup ? 'Ringing group…' : 'Calling…')
                  : 'Connecting…')),
      elapsedSeconds: elapsed,
      chatLog: List.of(ac.chatLog),
      chatUnread: ac.chatUnread,
    );
  }

  static String _formatTimer(int seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Lightweight JSON-map decode used by the signal handler when the engine hands
/// the payload as a raw JSON string rather than a decoded map.
Map<String, dynamic>? jsonDecodeMap(String s) {
  final decoded = jsonDecode(s);
  return decoded is Map<String, dynamic> ? decoded : null;
}
