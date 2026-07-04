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
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/relays.dart';
import '../../models/group.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../emoji/custom_emoji.dart';
import '../notifications/notification_sounds.dart';
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
  bool switchingCamera = false;
  MediaStream? screenStream;
  int startedAt = 0;
  Timer? ringTimeout;
  Timer? timerInterval;
  final List<CallChatMessage> chatLog = [];
  int chatUnread = 0;

  // --- chat reactions / receipts / typing (calls.js _initCallExtras) --------
  /// mid → emoji → set of reactor pubkeys.
  final Map<String, Map<String, Set<String>>> chatReactions = {};

  /// mid → pubkey → nym (peers that read our self message).
  final Map<String, Map<String, String>> chatReaders = {};

  /// mids we've already sent a chat-read for (dedupe).
  final Set<String> sentChatReads = {};

  /// pubkey → typing-stop timer (incoming typers).
  final Map<String, Timer> chatTypers = {};

  // --- presenter / screen-share moderation ----------------------------------
  bool shareRestricted = false;
  String? presenter;
  final Set<String> presentRequests = {};

  // --- video device gating --------------------------------------------------
  int videoInputCount = 0;
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
    // Hydrate the seen-calls cache from SharedPreferences so a call already
    // answered/declined/missed here (or replayed by a relay) isn't re-rung
    // after a reload (calls.js `_getSeenCalls`). Fire-and-forget; the in-memory
    // map starts empty and fills in once prefs load.
    unawaited(_hydrateSeenCalls());
  }

  final Ref _ref;
  String _self = '';

  _ActiveCall? _active;
  _IncomingCall? _incoming;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _localRendererReady = false;

  /// Outgoing-typing throttle/stop timers (calls.js `_callTypingThrottle` /
  /// `_callTypingStopTimer`).
  int _callTypingThrottle = 0;
  Timer? _callTypingStopTimer;

  /// Monotonic id for floating reactions (overlay keys them).
  int _flyReactionSeq = 0;

  /// Live floating reactions (self + incoming); each is dropped after ~3.2s.
  final List<CallFlyReaction> _flyReactions = [];

  /// Incoming-call ringtone loop (calls.js `_ringInterval` / `_ringCtx`). A
  /// 480 Hz beep replayed every 2 s while a call rings; `null` when silent. The
  /// WAV is synthesized once and reused (synthesis is deterministic). Held on
  /// the service (not the modal) so it stops in every exit path even if the
  /// overlay never mounted, mirroring calls.js where `_startRingtone` /
  /// `_stopRingtone` are owned by the call module.
  Timer? _ringInterval;
  AudioPlayer? _ringPlayer;
  Uint8List? _ringWav;

  /// In-chat / toast system-message sink. Routed by [call_providers] to
  /// `appStateProvider.addSystemMessage` (the centered `.system-message` pill);
  /// mirrors calls.js `displaySystemMessage`. P2P has the same sink shape.
  void Function(String message)? onSystemMessage;

  /// The published snapshot.
  final ValueNotifier<CallState> state = ValueNotifier(CallState.idle);

  /// Emits the centered system-message pill (calls.js `displaySystemMessage`).
  void _system(String message) => onSystemMessage?.call(message);

  /// Pushes a missed-call entry into the notification history (calls.js
  /// `_recordMissedCall`). [callerNym] is the decorated-or-base caller name.
  /// [whenMs] timestamps the entry (defaults to now); a stale-invite missed call
  /// stamps it with the invite's own `created_at * 1000` so the notification
  /// reflects when the call actually came in (calls.js:328 passes
  /// `createdAt * 1000`). [callId] keys the entry with a stable dedup id
  /// `missed-call-$callId` (calls.js:296-307 `eventId: 'missed-call-'+callId`) so
  /// the cancel-path and timeout-path can't double-record and a cross-device
  /// retract has a target.
  void _recordMissedCall({
    required String callId,
    required String callerPubkey,
    required String callerNym,
    required CallKind kind,
    bool isGroup = false,
    String? groupId,
    int? whenMs,
  }) {
    if (callerPubkey.isEmpty) return;
    final niceKind = kind == CallKind.video ? 'video' : 'audio';
    var body = 'Missed $niceKind call';
    if (isGroup && groupId != null) {
      final g = _groupById(groupId);
      if (g != null && g.name.isNotEmpty) body += ' in ${g.name}';
    }
    try {
      _ref.read(notificationHistoryProvider.notifier).record(
            type: 'call',
            title: callerNym.isNotEmpty ? callerNym : _nymFor(callerPubkey),
            body: body,
            route: isGroup ? (groupId ?? '') : callerPubkey,
            ts: whenMs,
            eventId: callId.isNotEmpty ? 'missed-call-$callId' : null,
          );
    } catch (_) {
      // History store may be unavailable in a teardown; best-effort.
    }
  }

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
    if (_self.isEmpty) {
      _system('Must be connected to start a call');
      return;
    }
    if (_active != null || _incoming != null) {
      _system('Already in a call');
      return;
    }
    // Calling a verified bot is intercepted with a joke instead of dialing
    // (calls.js:83-88 startCall PM branch). The bot never answers a real call.
    if (_ref.read(nostrControllerProvider).isVerifiedBot(peer)) {
      _system(video
          ? 'You wish you could see my sexy body ദ്ദി(ᵔᗜᵔ)'
          : 'You wish you could hear my sexy voice ദ്ദി(ᵔᗜᵔ)');
      return;
    }
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
    if (_self.isEmpty) {
      _system('Must be connected to start a call');
      return;
    }
    if (_active != null || _incoming != null) {
      _system('Already in a call');
      return;
    }
    final group = _groupById(groupId);
    if (group == null) return;
    final targets = group.members.where((pk) => pk != _self).toList();
    if (targets.isEmpty) {
      _system('No one to call in this group');
      return;
    }
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
    // Silence the ringtone the moment we accept (calls.js:384 `_stopRingtone`).
    _stopRingtone();
    // Remember we answered so a stale re-delivery (or another device's sync)
    // doesn't re-ring or record a missed call (calls.js:386).
    _markCallSeen(inc.callId, 'answered');

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
    // Stop the ringtone on decline (calls.js:429 `_stopRingtone`).
    _stopRingtone();
    // Remember the decline so a re-delivery / cross-device sync doesn't re-ring
    // it (calls.js:431).
    _markCallSeen(inc.callId, 'declined');
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

  /// React to [pubkey] being blocked while a call is live — calls.js
  /// `_onUserBlockedForCall` (calls.js:1960-1991). For a 1:1 call with that
  /// peer the call ends outright ("Left the call — you blocked X"); for a group
  /// call the peer is dropped (connection closed, removed from members) and the
  /// grid re-published. Their typing state is cleared and their chat rows fall
  /// out of the published log via the blocked-sender filter, mirroring the
  /// PWA's `_hideCallChatFrom` / `_clearCallChatTyping`.
  ///
  // wire from: the shared block path (the user-block action in
  // ContextMenuPanel / app_state). Exposed publicly so blocking from anywhere
  // (including the call's own nym context menu) updates the live call without
  // this file reaching across into the block sites.
  void onUserBlocked(String pubkey) {
    final ac = _active;
    if (ac == null || pubkey.isEmpty) return;
    _clearTyping(pubkey);
    final inCall = ac.members.contains(pubkey) || ac.peers.containsKey(pubkey);
    if (!inCall) {
      // Still drop any of their buffered chat rows from the published log.
      _publish();
      return;
    }
    if (!ac.isGroup) {
      _system('Left the call — you blocked ${_nymFor(pubkey)}');
      end();
      return;
    }
    // Drop them from the group call: close their connection, stop addressing
    // chat/reactions to them, and remove their tile.
    _removePeer(pubkey);
    ac.members = ac.members.where((pk) => pk != pubkey).toList();
    _publish();
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
    if (ac.switchingCamera) return;
    final track = ac.localStream.getVideoTracks().isNotEmpty
        ? ac.localStream.getVideoTracks().first
        : null;
    if (track == null) return;
    ac.switchingCamera = true;
    _publish();
    try {
      await Helper.switchCamera(track);
      ac.facingMode = ac.facingMode == 'environment' ? 'user' : 'environment';
    } catch (_) {
      // ignore — camera may not support switching
    } finally {
      ac.switchingCamera = false;
      _publish();
    }
  }

  /// Start/stop screen share. calls.js `toggleScreenShare` (no group
  /// presenter restriction here — 1:1 + open group).
  Future<void> toggleScreenShare() async {
    final ac = _active;
    if (ac == null) return;
    if (ac.sharing) {
      await _stopScreenShare();
      return;
    }
    // Restricted group call + not the presenter → request to present instead
    // (calls.js `toggleScreenShare`).
    if (!_canShareScreen(ac)) {
      requestToPresent();
      return;
    }
    await _startScreenShare();
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

  /// Send a floating reaction. calls.js `sendCallReaction`: broadcasts the emoji
  /// AND surfaces a local self-fly.
  void sendReaction(String emoji) {
    final ac = _active;
    if (ac == null || emoji.isEmpty) return;
    // Bump the shared recents so the bar surfaces this emoji next time.
    try {
      _ref.read(recentEmojisProvider.notifier).record(emoji);
    } catch (_) {}
    // Attach `emojiTags` for a custom `:shortcode:` so a peer that lacks the
    // pack can still resolve+render the image (calls.js:1153-1155).
    final tags = _emojiTagsFor(emoji);
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.reaction(callId: ac.callId, emoji: emoji, emojiTags: tags));
    }
    _pushFly(emoji, who: 'You');
  }

  void _onReaction(String sender, Map<String, dynamic> data) {
    final ac = _active;
    final emoji = data['emoji'];
    if (ac == null || ac.callId != data['callId'] || emoji is! String) return;
    if (emoji.isEmpty) return;
    // Register any custom-emoji defs the sender included so the shortcode
    // resolves to an image locally (calls.js:1165 `ingestEmojiTags`).
    _ingestEmojiTags(data['emojiTags']);
    _pushFly(emoji, pubkey: sender);
  }

  /// Appends a floating reaction (self or incoming) and schedules its removal
  /// after ~3.2s (calls.js `_showFlyReaction`). Random horizontal 8–82%.
  void _pushFly(String emoji, {String? who, String? pubkey}) {
    final id = _flyReactionSeq++;
    final left = 8 + _rng.nextDouble() * 74;
    _flyReactions.add(CallFlyReaction(
      id: id,
      emoji: emoji.length > 64 ? emoji.substring(0, 64) : emoji,
      leftPercent: left,
      who: who,
      pubkey: pubkey,
    ));
    _publish();
    Timer(const Duration(milliseconds: 3200), () {
      _flyReactions.removeWhere((f) => f.id == id);
      if (_active != null) _publish();
    });
  }

  /// Mark in-call chat as read (clears the unread badge) and flush read receipts
  /// for every received message (calls.js `toggleCallChat` open branch +
  /// `_flushCallChatReads`).
  void markChatRead() {
    final ac = _active;
    if (ac == null) return;
    ac.chatUnread = 0;
    _flushChatReads();
    _publish();
  }

  // ---------------------------------------------------------------------------
  // In-call chat reactions (calls.js _toggleCallChatReaction / _onCallChatReaction)
  // ---------------------------------------------------------------------------

  /// Toggle our reaction [emoji] on chat message [mid]; broadcasts add/remove.
  void toggleChatReaction(String mid, String emoji) {
    final ac = _active;
    if (ac == null || mid.isEmpty || emoji.isEmpty) return;
    final map = ac.chatReactions.putIfAbsent(mid, () => {});
    final set = map.putIfAbsent(emoji, () => <String>{});
    final String op;
    if (set.contains(_self)) {
      set.remove(_self);
      if (set.isEmpty) map.remove(emoji);
      op = 'remove';
    } else {
      set.add(_self);
      op = 'add';
      try {
        _ref.read(recentEmojisProvider.notifier).record(emoji);
      } catch (_) {}
    }
    // Custom `:shortcode:` chat-reactions carry their `emojiTags` too
    // (calls.js:1645-1646), so a peer without the pack resolves the badge image.
    final tags = _emojiTagsFor(emoji);
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(
          pk,
          CallSignal.chatReaction(
              callId: ac.callId, mid: mid, emoji: emoji, op: op, emojiTags: tags));
    }
    _publish();
  }

  void _onChatReaction(String sender, Map<String, dynamic> data) {
    final ac = _active;
    final mid = data['mid'];
    final emoji = data['emoji'];
    if (ac == null ||
        ac.callId != data['callId'] ||
        mid is! String ||
        emoji is! String) {
      return;
    }
    // A blocked user's chat reactions are dropped (calls.js:1655).
    if (_isBlocked(sender)) return;
    // Register any custom-emoji defs the sender included (calls.js:1656).
    _ingestEmojiTags(data['emojiTags']);
    final map = ac.chatReactions.putIfAbsent(mid, () => {});
    final set = map.putIfAbsent(emoji, () => <String>{});
    if (data['op'] == 'remove') {
      set.remove(sender);
      if (set.isEmpty) map.remove(emoji);
    } else {
      set.add(sender);
    }
    _publish();
  }

  // ---------------------------------------------------------------------------
  // Typing indicator (calls.js _sendCallTypingSignal / _onCallChatTyping)
  // ---------------------------------------------------------------------------

  /// Notify peers we're typing in call chat (throttled to 3s, auto-stop after
  /// 4s), respecting the typing-indicator privacy pref.
  void sendTyping() {
    final ac = _active;
    if (ac == null) return;
    if (!_typingAllowed(ac)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _callTypingThrottle < 3000) {
      _armTypingStop();
      return;
    }
    _callTypingThrottle = now;
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.chatTyping(callId: ac.callId, status: 'start'));
    }
    _armTypingStop();
  }

  void _armTypingStop() {
    _callTypingStopTimer?.cancel();
    _callTypingStopTimer = Timer(const Duration(seconds: 4), _sendTypingStop);
  }

  void _sendTypingStop() {
    _callTypingStopTimer?.cancel();
    _callTypingStopTimer = null;
    _callTypingThrottle = 0;
    final ac = _active;
    if (ac == null) return;
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.chatTyping(callId: ac.callId, status: 'stop'));
    }
  }

  void _onChatTyping(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId'] || sender == _self) return;
    if (!_typingAllowed(ac)) return;
    if (data['status'] == 'stop') {
      ac.chatTypers.remove(sender)?.cancel();
    } else {
      ac.chatTypers.remove(sender)?.cancel();
      ac.chatTypers[sender] = Timer(const Duration(seconds: 5), () {
        ac.chatTypers.remove(sender);
        if (_active == ac) _publish();
      });
    }
    _publish();
  }

  void _clearTyping(String pubkey) {
    final ac = _active;
    if (ac == null) return;
    ac.chatTypers.remove(pubkey)?.cancel();
  }

  // ---------------------------------------------------------------------------
  // Read receipts (calls.js _sendCallChatRead / _onCallChatRead)
  // ---------------------------------------------------------------------------

  void _sendChatRead(String senderPubkey, String mid) {
    final ac = _active;
    if (ac == null || mid.isEmpty || senderPubkey.isEmpty || senderPubkey == _self) {
      return;
    }
    if (!_readReceiptAllowed(ac)) return;
    if (ac.sentChatReads.contains(mid)) return;
    ac.sentChatReads.add(mid);
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.chatRead(callId: ac.callId, mid: mid));
    }
  }

  void _flushChatReads() {
    final ac = _active;
    if (ac == null) return;
    for (final m in ac.chatLog) {
      if (!m.isSelf && m.pubkey.isNotEmpty && m.mid.isNotEmpty) {
        _sendChatRead(m.pubkey, m.mid);
      }
    }
  }

  void _onChatRead(String sender, Map<String, dynamic> data) {
    final ac = _active;
    final mid = data['mid'];
    if (ac == null || ac.callId != data['callId'] || mid is! String) return;
    if (sender == _self) return;
    final idx = ac.chatLog.indexWhere((m) => m.mid == mid && m.isSelf);
    if (idx < 0) return;
    final readers = ac.chatReaders.putIfAbsent(mid, () => {});
    readers[sender] = _nymFor(sender);
    // Mirror readers + delivery state onto the chat-log entry for the UI.
    ac.chatLog[idx] = ac.chatLog[idx].copyWith(
      readers: Map.of(readers),
      delivery: CallChatDelivery.read,
    );
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

    // 45s ring timeout — cancel the call if nobody answered (calls.js
    // `startCall`: broadcasts cancel, surfaces "No answer", then ends).
    active.ringTimeout = Timer(kCallRingTimeout, () {
      if (_active == active && active.status == 'outgoing') {
        for (final pk in targets) {
          _send(pk, CallSignal.cancel(callId));
        }
        _system('No answer');
        _endCall();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Inbound signaling — calls.js handleCallSignalingEvent dispatch
  // ---------------------------------------------------------------------------

  /// Entry point registered via NostrController.setCallSignalHandler. [rumor]
  /// is the decoded kind-25053 rumor: { pubkey, created_at, content(JSON
  /// payload)... }.
  void handleSignal(Map<String, dynamic> rumor) {
    final sender = rumor['pubkey'] as String?;
    if (sender == null || sender == _self) return;
    // A blocked user can't ring, join, or signal into a call at all
    // (calls.js `handleCallSignalingEvent` line 172).
    if (_isBlocked(sender)) return;
    final data = _decodePayload(rumor);
    if (data == null) return;
    // The invite's freshness is judged from the rumor's own created_at — the
    // signaling payload (`content` JSON) carries no timestamp, so calls.js
    // threads `event.created_at` into `_onCallInvite(sender, data, event)`
    // (calls.js:176/310). The decoded gift-wrap rumor preserves created_at, so
    // we read it here and hand it to `_onInvite`.
    final createdAt = (rumor['created_at'] as num?)?.toInt() ?? 0;
    switch (data['type']) {
      case 'invite':
        _onInvite(sender, data, createdAt);
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
      case 'present-state':
        _onPresentState(sender, data);
        break;
      case 'present-request':
        _onPresentRequest(sender, data);
        break;
      case 'reaction':
        _onReaction(sender, data);
        break;
      case 'chat':
        _onChat(sender, data);
        break;
      case 'chat-reaction':
        _onChatReaction(sender, data);
        break;
      case 'chat-typing':
        _onChatTyping(sender, data);
        break;
      case 'chat-read':
        _onChatRead(sender, data);
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming-call ringtone (calls.js `_startRingtone` / `_stopRingtone`)
  // ---------------------------------------------------------------------------
  //
  // The PWA loops a 480 Hz beep (gain 0.07, 0.4 s) every 2 s while an incoming
  // call rings (calls.js:897-920). We synthesize the same tone with the shared
  // [renderSoundWav] path and replay it on a 2 s [Timer.periodic] through an
  // audioplayers instance — the native equivalent of the Web Audio oscillator.
  // Best-effort throughout: a failed render/playback must never break ringing
  // (the PWA wraps `_startRingtone` in try/catch and ignores errors).

  /// Begin looping the incoming-call ringtone (calls.js `_startRingtone`). Plays
  /// the beep immediately, then every 2 s until [_stopRingtone]. Idempotent: a
  /// second call while already ringing is a no-op. Silent on web (audioplayers
  /// has no byte-source playback there, matching [AudioPlayersTonePlayer]).
  void _startRingtone() {
    if (kIsWeb) return;
    if (_ringInterval != null) return; // already ringing
    _playRingBeep();
    _ringInterval =
        Timer.periodic(const Duration(seconds: 2), (_) => _playRingBeep());
  }

  /// Stop the ringtone loop and release the player (calls.js `_stopRingtone`:
  /// `clearInterval` + `ctx.close()`). Safe to call when not ringing.
  void _stopRingtone() {
    _ringInterval?.cancel();
    _ringInterval = null;
    final player = _ringPlayer;
    _ringPlayer = null;
    if (player != null) {
      // stop() then dispose() — fire-and-forget; never throw from teardown.
      unawaited(() async {
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }());
    }
  }

  /// Render-once + play one beep through the (lazily created) ring player.
  void _playRingBeep() {
    try {
      final wav = _ringWav ??= renderSoundWav(kIncomingCallRingtone);
      final player = _ringPlayer ??=
          (AudioPlayer()..setReleaseMode(ReleaseMode.stop));
      // Restart from the top each beep so the 2 s cadence is crisp.
      unawaited(() async {
        try {
          await player.stop();
          await player.play(BytesSource(wav, mimeType: 'audio/wav'));
        } catch (_) {}
      }());
    } catch (_) {
      // Synthesis/playback unavailable — ring silently rather than crash.
    }
  }

  // ---------------------------------------------------------------------------
  // Seen-calls persistence (calls.js `_getSeenCalls` … `_markCallSeen`)
  // ---------------------------------------------------------------------------
  //
  // A 24h-TTL'd `{callId: {t, s}}` map persisted under the SAME key the PWA uses
  // (`nym_seen_calls`) so a call already pending/answered/declined/missed here —
  // or replayed by a relay on reconnect — isn't re-rung. Status rank lets a
  // resolution win over a weaker state (calls.js `_CALL_STATUS_RANK`).
  //
  // Held in-memory (`_seenCalls`) as the synchronous source of truth (the ring
  // gate in `_onInvite` is sync); hydrated once at construction and persisted
  // after each mark. Cross-device merge + missed-call retract (`_mergeSeenCalls`
  // / `_retractMissedCallNotification`, F06-A3) is DEFERRED — it needs the
  // controller's encrypted-settings sync and an app_state history-removal helper
  // (neither owned here). `_seenCallsForSync` below is provided so the serial
  // controller owner can include the map in the synced blob without re-deriving.

  /// Status precedence on merge/mark — higher wins (calls.js
  /// `_CALL_STATUS_RANK`, calls.js:200).
  static const Map<String, int> _callStatusRank = {
    'seen': 0,
    'pending': 1,
    'missed': 2,
    'declined': 3,
    'answered': 4,
  };

  /// In-memory mirror of the persisted seen-calls map (`callId → {t, s}`); `t`
  /// is unix-seconds, `s` is the status string. Null until first hydrated.
  Map<String, _SeenCall>? _seenCalls;
  SharedPreferences? _seenPrefs;

  static const String _seenCallsKey = 'nym_seen_calls';

  Future<void> _hydrateSeenCalls() async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _seenPrefs = prefs;
      // Merge anything marked before prefs finished loading (don't clobber).
      final loaded = _decodeSeenCalls(prefs.getString(_seenCallsKey));
      final pending = _seenCalls;
      if (pending != null) loaded.addAll(pending);
      _seenCalls = loaded;
    } catch (_) {
      _seenCalls ??= <String, _SeenCall>{};
    }
  }

  Map<String, _SeenCall> _decodeSeenCalls(String? raw) {
    final out = <String, _SeenCall>{};
    if (raw == null || raw.isEmpty) return out;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          final r = _SeenCall.fromWire(v);
          if (r != null && k is String) out[k] = r;
        });
      }
    } catch (_) {}
    return out;
  }

  /// calls.js `_getSeenCalls` — the live map, created lazily.
  Map<String, _SeenCall> _seenMap() => _seenCalls ??= <String, _SeenCall>{};

  /// calls.js `_hasSeenCall` — has this call already been recorded here?
  bool _hasSeenCall(String? callId) {
    if (callId == null || callId.isEmpty) return false;
    return _seenMap().containsKey(callId);
  }

  /// The recorded seen-status for [callId] (`seen | pending | missed |
  /// declined | answered`), or null when unknown — the PWA's `_callStatus`
  /// read. Used by the synced notification-history merge to skip re-adding a
  /// missed-call entry for a call answered elsewhere (app.js:5860-5862).
  String? seenCallStatus(String callId) => _seenMap()[callId]?.s;

  /// calls.js `_markCallSeen` — record [callId] with [status], keeping the
  /// higher-ranked status if one already exists, then persist (TTL-pruned).
  void _markCallSeen(String? callId, String status) {
    if (callId == null || callId.isEmpty) return;
    final map = _seenMap();
    final next = status.isEmpty ? 'pending' : status;
    final existing = map[callId];
    final keep = (existing != null &&
            (_callStatusRank[existing.s] ?? 0) > (_callStatusRank[next] ?? 0))
        ? existing.s
        : next;
    map[callId] =
        _SeenCall(DateTime.now().millisecondsSinceEpoch ~/ 1000, keep);
    _persistSeenCalls(map);
    // Cross-device sync (F06-A3): republish the seen-call map inside the
    // encrypted settings blob so a call answered/declined/missed here is
    // reflected on our other devices (calls.js:256 `_debouncedNostrSettingsSave()`).
    // `syncSettings` is the 5s-debounced publish; it reads `seenCallsForSync()`
    // when it flushes (nostr_controller `_flushSettingsSync`).
    try {
      _ref.read(nostrControllerProvider).syncSettings();
    } catch (_) {}
  }

  /// Merges a synced seen-call map received from another device (calls.js
  /// `_mergeSeenCalls`, calls.js:261) so a call already handled or answered
  /// elsewhere isn't re-rung or left showing as missed here. TTL-expired entries
  /// are skipped; on a per-call basis the higher-ranked status wins and the
  /// newer timestamp is kept. Any call that transitions to `answered` via the
  /// merge retracts a missed-call notification we already surfaced for it (the
  /// `missed-call-<callId>` history id), via the [retract] callback the
  /// controller wires to `NotificationHistoryNotifier.removeByEventId`.
  void mergeSeenCalls(dynamic incoming,
      {void Function(String eventId)? retract}) {
    if (incoming is! Map) return;
    final map = _seenMap();
    final cutoff =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _callSeenTtlSec;
    final nowAnswered = <String>[];
    incoming.forEach((key, value) {
      if (key is! String) return;
      final r = _SeenCall.fromWire(value);
      if (r == null || r.t < cutoff) return;
      final cur = map[key];
      if (cur == null) {
        map[key] = _SeenCall(r.t, r.s);
        if (r.s == 'answered') nowAnswered.add(key);
        return;
      }
      final s = (_callStatusRank[r.s] ?? 0) > (_callStatusRank[cur.s] ?? 0)
          ? r.s
          : cur.s;
      map[key] = _SeenCall(cur.t > r.t ? cur.t : r.t, s);
      if (s == 'answered' && cur.s != 'answered') nowAnswered.add(key);
    });
    _persistSeenCalls(map);
    // A call answered elsewhere retracts any missed-call we already surfaced
    // (calls.js:282-284 → `missed-call-<callId>` notification id).
    if (retract != null) {
      for (final id in nowAnswered) {
        retract('missed-call-$id');
      }
    }
  }

  /// calls.js `_persistSeenCalls` — TTL-prune then write back (best-effort; the
  /// in-memory map is authoritative even if the disk write is unavailable).
  void _persistSeenCalls(Map<String, _SeenCall> map) {
    final cutoff =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _callSeenTtlSec;
    map.removeWhere((_, r) => r.t < cutoff);
    final prefs = _seenPrefs;
    if (prefs == null) return; // not hydrated yet — will persist on next mark
    try {
      prefs.setString(_seenCallsKey, jsonEncode(_encodeSeenCalls(map)));
    } catch (_) {}
  }

  Map<String, dynamic> _encodeSeenCalls(Map<String, _SeenCall> map) =>
      {for (final e in map.entries) e.key: e.value.toWire()};

  /// Top-100-by-recency seen-call map for cross-device sync (calls.js
  /// `_seenCallsForSync`). Exposed for the serial controller owner that will
  /// include it in the synced settings blob (F06-A3, DEFERRED here).
  Map<String, dynamic> seenCallsForSync() {
    final map = _seenMap();
    final ids = map.keys.toList()
      ..sort((a, b) => (map[b]?.t ?? 0) - (map[a]?.t ?? 0));
    final out = <String, dynamic>{};
    for (final id in ids.take(100)) {
      final r = map[id];
      if (r != null) out[id] = r.toWire();
    }
    return out;
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

  /// Seconds a missed/answered call record stays relevant — matches the 24h
  /// notification window so a stale invite older than this is dropped silently
  /// rather than surfaced (calls.js `_CALL_SEEN_TTL_SEC = 86400`).
  static const int _callSeenTtlSec = 86400;

  void _onInvite(String sender, Map<String, dynamic> data, [int createdAtSec = 0]) {
    final callId = (data['callId'] as String?) ?? '';
    // Skip a call already handled here or answered/seen on another device — this
    // is what stops a relay-replayed invite from re-ringing (calls.js:312).
    if (_hasSeenCall(callId)) return;

    // Accept-calls preference gate (calls.js _onCallInvite).
    final pref = _ref.read(settingsProvider).acceptCalls;
    final friend = _isFriend(sender);
    if (!shouldRingForInvite(acceptCalls: pref, isFriend: friend)) return;

    // Stale-invite handling (calls.js:320-331): an invite that arrived while the
    // app was closed can't be answered. If it's older than 60s, don't ring —
    // instead log it as a missed call so it surfaces in notifications on reopen
    // (but only while still within the seen-call window; beyond that it's
    // dropped). A fresh invite (createdAt == 0, e.g. tests/engine without a ts,
    // or ≤60s old) rings normally.
    if (createdAtSec > 0) {
      final ageSec =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - createdAtSec;
      if (ageSec > 60) {
        if (ageSec <= _callSeenTtlSec) {
          // Remember it as missed so a re-delivery doesn't re-record it
          // (calls.js:327).
          _markCallSeen(callId, 'missed');
          _recordMissedCall(
            callId: callId,
            callerPubkey: sender,
            callerNym: (data['nym'] as String?) ?? _nymFor(sender),
            kind: CallKind.fromWire(data['kind']),
            isGroup: data['isGroup'] == true,
            groupId: data['groupId'] as String?,
            whenMs: createdAtSec * 1000,
          );
        }
        return;
      }
    }

    // A fresh ring is recorded pending; a relay replay then short-circuits at the
    // `_hasSeenCall` gate above (calls.js:332).
    _markCallSeen(callId, 'pending');

    if (_active != null || _incoming != null) {
      // We're busy — mark missed and bounce the caller (calls.js:335).
      _markCallSeen(callId, 'missed');
      _send(sender, CallSignal.reject(callId, 'busy'));
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
    // Loop the ringtone while this call rings (calls.js:367 `_startRingtone`).
    // Only reached on a fresh ring — the stale-missed / busy / pref-gated
    // branches above all return before here, so no silent call ever rings.
    _startRingtone();
    inc.timeout = Timer(kCallRingTimeout, () {
      if (_incoming == inc) {
        _incoming = null;
        // The ring is over — stop the tone (calls.js:371 `_stopRingtone`).
        _stopRingtone();
        // calls.js: surfaces "Missed call from X" + records it to history.
        _markCallSeen(inc.callId, 'missed'); // calls.js:374
        _system('Missed call from ${inc.nym}');
        _recordMissedCall(
          callId: inc.callId,
          callerPubkey: inc.from,
          callerNym: inc.nym,
          kind: inc.kind,
          isGroup: inc.isGroup,
          groupId: inc.groupId,
        );
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
      // calls.js `_onCallReject`: busy peer vs explicit decline.
      _system(data['reason'] == 'busy' ? 'User is busy' : 'Call declined');
      _endCall();
    }
  }

  void _onCancel(String sender, Map<String, dynamic> data) {
    final inc = _incoming;
    if (inc != null && inc.callId == data['callId'] && sender == inc.from) {
      inc.timeout?.cancel();
      _incoming = null;
      // The caller withdrew — stop ringing (calls.js:471 `_stopRingtone`).
      _stopRingtone();
      // calls.js `_onCallCancel`: a cancelled ring is a missed call.
      _markCallSeen(inc.callId, 'missed'); // calls.js:473
      _system('Missed call from ${inc.nym}');
      _recordMissedCall(
        callId: inc.callId,
        callerPubkey: inc.from,
        callerNym: inc.nym,
        kind: inc.kind,
        isGroup: inc.isGroup,
        groupId: inc.groupId,
      );
      _publishIdle();
    }
  }

  void _onHangup(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    _removePeer(sender);
    if (!ac.isGroup || ac.peers.isEmpty) {
      _system('Call ended');
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
    // A duplicate / late answer on an already-stable connection would throw
    // InvalidStateError from setRemoteDescription and abort the candidate flush,
    // wedging ICE at CONNECTING→FAILED. Ignore it, exactly like calls.js:584
    // (`if (entry.pc.signalingState === 'stable') return;`).
    if (peer.pc.signalingState ==
        RTCSignalingState.RTCSignalingStateStable) {
      return;
    }
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
    // calls.js `_onCallIce` requires `data.candidate`; ignore an empty
    // end-of-gathering marker so it can't wedge the add-candidate path.
    final candStr = c['candidate'] as String?;
    if (candStr == null || candStr.isEmpty) return;
    final candidate = RTCIceCandidate(
      candStr,
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
    if (_isBlocked(sender)) return;
    // An inbound message ends that peer's "typing…" state (calls.js
    // `_clearCallChatTyping`).
    _clearTyping(sender);
    ac.chatLog.add(CallChatMessage(
      pubkey: sender,
      text: text.length > 2000 ? text.substring(0, 2000) : text,
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

    // If we're already sharing our screen, push that track to the new peer and
    // tell them we're presenting (calls.js `_connectToPeer` 512-520).
    if (ac.sharing && ac.screenStream != null) {
      final st = ac.screenStream!.getVideoTracks().isNotEmpty
          ? ac.screenStream!.getVideoTracks().first
          : null;
      if (st != null) {
        try {
          if (peer.videoSender != null) {
            await peer.videoSender!.replaceTrack(st);
          } else {
            peer.videoSender = await pc.addTrack(st, ac.screenStream!);
          }
        } catch (_) {}
      }
      _send(peerPubkey, CallSignal.share(callId: ac.callId, on: true));
    }
    // As a mod, sync the presenter/restriction state to the new peer (calls.js
    // `_connectToPeer` 522-524).
    if (_isCallMod(ac) && (ac.shareRestricted || ac.presenter != null)) {
      _send(
          peerPubkey,
          CallSignal.presentState(
            callId: ac.callId,
            restricted: ac.shareRestricted,
            presenter: ac.presenter,
          ));
    }

    pc.onIceCandidate = (candidate) {
      if (_active != ac) return;
      // calls.js `onicecandidate` guards `if (e.candidate ...)`: only trickle a
      // real candidate. flutter_webrtc fires a final event with an empty
      // candidate string at end-of-gathering; forwarding it would make the peer
      // `addIceCandidate` an empty candidate (a no-op at best, an error at worst).
      final c = candidate.candidate;
      if (c == null || c.isEmpty) return;
      _send(
          peerPubkey,
          CallSignal.ice(
            callId: ac.callId,
            candidate: c,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ));
    };
    pc.onTrack = (event) {
      // A track event can arrive after the call ended (peer renderer disposed)
      // or after this peer was removed — touching a disposed renderer keeps the
      // EglRenderer alive churning "Frames received: 0". Drop stale events.
      if (_active != ac || ac.peers[peerPubkey] != peer) return;
      if (event.streams.isNotEmpty) {
        peer.stream = event.streams.first;
        peer.renderer.srcObject = peer.stream;
      }
      _publish();
    };
    pc.onConnectionState = (s) {
      if (_active != ac || ac.peers[peerPubkey] != peer) return;
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
      for (final t in ac.chatTypers.values) {
        t.cancel();
      }
      ac.chatTypers.clear();
      _callTypingStopTimer?.cancel();
      _callTypingStopTimer = null;
      _callTypingThrottle = 0;
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
    _flyReactions.clear();
    // Unconditional safety net: every teardown path silences the ring, exactly
    // like calls.js:653 `_stopRingtone()` at the tail of `_endCall`. Covers the
    // media-failure answer path, outgoing-ring timeout, and remote hangup/reject.
    _stopRingtone();
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
      // calls.js `_getLocalMedia` surfaces a media-error system message.
      _system(
        'Could not access ${kind == CallKind.video ? 'camera/microphone' : 'microphone'}: $e',
      );
      return null;
    }
  }

  Future<void> _attachLocalPreview(MediaStream stream) async {
    if (!_localRendererReady) {
      await _localRenderer.initialize();
      _localRendererReady = true;
    }
    _localRenderer.srcObject = stream;
    // Gate the switch-camera button on multi-camera availability (calls.js
    // `_updateCameraSwitchBtn`). Fire-and-forget; updates state when it lands.
    unawaited(_refreshVideoInputCount());
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
    // Friends now live on the shared app store (Foundations).
    return _ref.read(appStateProvider).friends.contains(pubkey);
  }

  bool _isBlocked(String pubkey) =>
      _ref.read(appStateProvider).blockedUsers.contains(pubkey);

  String _nymFor(String pubkey) {
    final users = _ref.read(usersProvider);
    final u = users[pubkey];
    if (u != null && u.nym.isNotEmpty) return u.nym;
    return pubkey.length >= 8 ? pubkey.substring(0, 8) : pubkey;
  }

  /// Builds the `['emoji', code, url]` tag tuples for any custom `:shortcode:`
  /// in [content] (calls.js `customEmojiTagsForContent`), so a reaction sent to a
  /// peer without the pack still resolves to its image. Empty for unicode-only
  /// content. Best-effort: returns `null` if the store is unavailable so the
  /// payload simply omits the field.
  List<List<String>>? _emojiTagsFor(String content) {
    try {
      final tags = _ref.read(liveCustomEmojiProvider.notifier)
          .emojiTagsForContent(content);
      return tags.isEmpty ? null : tags;
    } catch (_) {
      return null;
    }
  }

  /// Registers inbound custom-emoji defs carried on a reaction payload (calls.js
  /// `ingestEmojiTags`), so a `:shortcode:` from a peer renders locally. Accepts
  /// the loosely-typed wire value (`List<dynamic>` of `List<dynamic>`).
  void _ingestEmojiTags(Object? raw) {
    if (raw is! List) return;
    final tags = <List<String>>[];
    for (final t in raw) {
      if (t is List) tags.add(t.map((e) => e.toString()).toList());
    }
    if (tags.isEmpty) return;
    try {
      _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(tags);
    } catch (_) {}
  }

  /// Random source for floating-reaction positions (seedable in tests).
  final Random _rng = Random();

  // ---------------------------------------------------------------------------
  // Privacy gates — mirror settings.js isIndicatorAllowedFor(scope, context)
  // ---------------------------------------------------------------------------

  bool _typingAllowed(_ActiveCall ac) =>
      _indicatorAllowed(_ref.read(settingsProvider).typingIndicatorsScope, ac.isGroup);

  bool _readReceiptAllowed(_ActiveCall ac) =>
      _indicatorAllowed(_ref.read(settingsProvider).readReceiptsScope, ac.isGroup);

  /// scope ∈ disabled|everywhere|pms|groups|pms-groups; context = group|pm.
  static bool _indicatorAllowed(String scope, bool isGroup) {
    switch (scope) {
      case 'disabled':
        return false;
      case 'everywhere':
        return true;
      case 'pms':
        return !isGroup;
      case 'groups':
        return isGroup;
      case 'pms-groups':
        return true;
      default:
        return true;
    }
  }

  // ---------------------------------------------------------------------------
  // Presenter / screen-share moderation (calls.js 1033-1099)
  // ---------------------------------------------------------------------------

  /// True when we can moderate this group call (owner/mod of the group).
  bool _isCallMod([_ActiveCall? call]) {
    final ac = call ?? _active;
    if (ac == null || !ac.isGroup || ac.groupId == null) return false;
    final g = _groupById(ac.groupId!);
    return g != null && g.canModerate(_self);
  }

  bool _peerCanModerate(_ActiveCall ac, String pubkey) {
    if (!ac.isGroup || ac.groupId == null) return false;
    final g = _groupById(ac.groupId!);
    return g != null && g.canModerate(pubkey);
  }

  /// Whether the local user may screen-share right now (calls.js
  /// `canShareScreen`).
  bool _canShareScreen([_ActiveCall? call]) {
    final ac = call ?? _active;
    if (ac == null) return false;
    if (!ac.isGroup) return true;
    if (_isCallMod(ac)) return true;
    if (!ac.shareRestricted) return true;
    return ac.presenter == _self;
  }

  /// A non-mod taps share when restricted → request to present instead.
  void requestToPresent() {
    final ac = _active;
    if (ac == null || !ac.isGroup) return;
    final mods = ac.members
        .where((pk) => pk != _self && _peerCanModerate(ac, pk))
        .toList();
    if (mods.isEmpty) {
      _system('No moderator available to grant presenting');
      return;
    }
    for (final pk in mods) {
      _send(pk, CallSignal.presentRequest(ac.callId));
    }
    _system('Requested to present');
  }

  void _onPresentRequest(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId'] || !_isCallMod(ac)) return;
    ac.presentRequests.add(sender);
    _system('${_nymFor(sender)} requested to present');
    _publish();
  }

  void _broadcastPresentState() {
    final ac = _active;
    if (ac == null) return;
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(
          pk,
          CallSignal.presentState(
            callId: ac.callId,
            restricted: ac.shareRestricted,
            presenter: ac.presenter,
          ));
    }
  }

  void _onPresentState(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId'] || !ac.isGroup) return;
    if (!_peerCanModerate(ac, sender)) return;
    final wasPresenter = ac.presenter == _self;
    ac.shareRestricted = data['restricted'] == true;
    ac.presenter = data['presenter'] as String?;
    _enforceShareRestriction();
    if (!wasPresenter && ac.presenter == _self) {
      _system('You can now share your screen');
    }
    _publish();
  }

  /// Mod toggles "only the presenter can share".
  void setScreenShareRestricted(bool on) {
    final ac = _active;
    if (ac == null || !_isCallMod(ac)) return;
    ac.shareRestricted = on;
    _broadcastPresentState();
    _enforceShareRestriction();
    _publish();
  }

  /// Mod assigns (or clears, with null) the presenter.
  void assignPresenter(String? pubkey) {
    final ac = _active;
    if (ac == null || !_isCallMod(ac)) return;
    ac.presenter = pubkey;
    if (pubkey != null) ac.presentRequests.remove(pubkey);
    _broadcastPresentState();
    _publish();
  }

  void _enforceShareRestriction() {
    final ac = _active;
    if (ac != null && ac.sharing && !_canShareScreen(ac)) {
      unawaited(_stopScreenShare());
    }
  }

  /// Re-enumerates video input devices and updates the switch-cam gating count
  /// (calls.js `_updateCameraSwitchBtn`). Best-effort; keeps the prior count on
  /// failure.
  Future<void> _refreshVideoInputCount() async {
    final ac = _active;
    if (ac == null || ac.kind != CallKind.video) return;
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final n = devices.where((d) => d.kind == 'videoinput').length;
      if (_active == ac) {
        ac.videoInputCount = n;
        _publish();
      }
    } catch (_) {
      // Keep showing — enumerate may be unavailable on some platforms.
    }
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

    // Blocked peers are filtered out of the grid, matching `_renderCallGrid`
    // (calls.js:798-808): a blocked pubkey's tile is never rendered.
    final participants = ac.peers.entries
        .where((e) => !_isBlocked(e.key))
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

    // Merge per-mid reactions (kept separately on `ac.chatReactions`) into each
    // chat-log entry so the overlay renders the count badges per message.
    // Blocked senders' rows are hidden, mirroring `_hideCallChatFrom`
    // (calls.js:1985-1991) so blocking mid-call drops their messages too.
    final chatLog = ac.chatLog
        .where((m) => m.isSelf || !_isBlocked(m.pubkey))
        .map((m) {
      final r = ac.chatReactions[m.mid];
      if (r == null || r.isEmpty) return m;
      return m.copyWith(
        reactions: {for (final e in r.entries) e.key: Set<String>.of(e.value)},
      );
    }).toList();

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
      switchingCamera: ac.switchingCamera,
      videoInputCount: ac.videoInputCount,
      facingMode: ac.facingMode,
      statusText: statusText ??
          (phase == CallPhase.active
              ? _formatTimer(elapsed)
              : (phase == CallPhase.ringing
                  ? (ac.isGroup ? 'Ringing group…' : 'Calling…')
                  : 'Connecting…')),
      elapsedSeconds: elapsed,
      chatLog: chatLog,
      chatUnread: ac.chatUnread,
      typingPubkeys: ac.chatTypers.keys.toList(),
      flyReactions: List.of(_flyReactions),
      shareRestricted: ac.shareRestricted,
      presenter: ac.presenter,
      presentRequests: Set.of(ac.presentRequests),
      isMod: _isCallMod(ac),
      canShareScreen: _canShareScreen(ac),
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

/// A single persisted seen-call record (calls.js stored shape `{t, s}`): unix
/// seconds [t] + status [s] ∈ seen|pending|missed|declined|answered. Tolerates
/// the PWA's legacy bare-number value (`_normCallRecord`, calls.js:211).
class _SeenCall {
  const _SeenCall(this.t, this.s);

  final int t;
  final String s;

  Map<String, dynamic> toWire() => {'t': t, 's': s};

  static _SeenCall? fromWire(Object? v) {
    if (v is num) return _SeenCall(v.toInt(), 'seen');
    if (v is Map) {
      final t = v['t'];
      if (t is num) {
        final s = v['s'];
        return _SeenCall(t.toInt(), s is String && s.isNotEmpty ? s : 'seen');
      }
    }
    return null;
  }
}
