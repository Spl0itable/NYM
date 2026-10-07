// Full-mesh WebRTC calling over NIP-17 gift-wrapped kind-25053 signaling; pure logic lives in call_signaling.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/relays.dart';
import '../../core/utils/nym_utils.dart';
import '../../core/utils/peer_connection_release.dart';
import '../../models/group.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../emoji/custom_emoji.dart';
import '../i18n/i18n.dart';
import '../notifications/notification_sounds.dart';
import '../group_tools/group_tools.dart';
import '../group_tools/group_tools_providers.dart';
import '../chat_lock/chat_lock_providers.dart';
import 'call_history.dart';
import 'call_history_providers.dart';
import 'call_nym.dart' show callPeerName;
import 'call_platform.dart';
import 'call_signaling.dart';
import 'call_state.dart';
import 'call_wake.dart';

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
  bool restarting = false;
  bool sharing = false; // peer is screen-sharing
  bool? videoOn;
  bool renegotiate = false;
}

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
  CallKind kind;
  bool isGroup;
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
  Timer? lostTimer;
  bool viaLink = false;
  final Map<String, List<RTCIceCandidate>> earlyIce = {};
  final List<CallChatMessage> chatLog = [];
  int chatUnread = 0;

  /// mid -> emoji -> reactor pubkeys.
  final Map<String, Map<String, Set<String>>> chatReactions = {};

  /// mid -> pubkey -> nym of peers that read our message.
  final Map<String, Map<String, String>> chatReaders = {};

  /// mids we've already sent a chat-read for.
  final Set<String> sentChatReads = {};

  /// pubkey -> typing-stop timer for incoming typers.
  final Map<String, Timer> chatTypers = {};

  bool shareRestricted = false;
  CallRecord? ch;
  String? presenter;
  final Set<String> presentRequests = {};

  int videoInputCount = 0;
  bool speakerOn = false;
  bool headset = false;
  bool speakerTouched = false;
  bool upgradingVideo = false;
  final Map<String, bool> peerVideo = {};
  final Set<String> declined = {};
}

class _LeftCall {
  _LeftCall({
    required this.callId,
    required this.groupId,
    required this.kind,
    required this.members,
    required this.remaining,
  });

  final String callId;
  final String groupId;
  final CallKind kind;
  final List<String> members;
  final Set<String> remaining;
  final int at = CallService.clock();
}

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
  final int chAt = CallService.clock();
  Timer? timeout;
  bool accepting = false;
}

class CallService {
  CallService(this._ref) {
    _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    _ref.read(nostrControllerProvider).setCallSignalHandler(handleSignal);
    try {
      final p = _ref.read(callPlatformProvider);
      p.onHangupRequest = end;
      p.onAnswer = (id) {
        if (_incoming?.callId == id) unawaited(answer());
      };
      p.onDecline = (id) {
        if (_incoming?.callId == id) reject();
      };
      p.onMute = (muted) {
        if (_active != null && _active!.muted != muted) toggleMute();
      };
      p.onRingCheck = ringCheck;
      p.onRingToken = (platform, token, env) async {
        await _ref
            .read(ringRegistrationProvider)
            .onToken(platform: platform, token: token, env: env);
      };
    } catch (_) {}
    // Hydrate seen calls so a call already handled or relay-replayed isn't re-rung.
    unawaited(_hydrateSeenCalls());
  }

  final Ref _ref;
  String _self = '';

  _ActiveCall? _active;
  _IncomingCall? _incoming;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _localRendererReady = false;

  /// Outgoing typing throttle and stop timers.
  int _callTypingThrottle = 0;
  Timer? _callTypingStopTimer;

  /// Monotonic id for floating reactions.
  int _flyReactionSeq = 0;

  /// Live floating reactions, each dropped after ~3.2s.
  final List<CallFlyReaction> _flyReactions = [];

  /// Ringtone loop (480 Hz beep every 2s), held on the service so every exit path stops it.
  Timer? _ringInterval;
  AudioPlayer? _ringPlayer;
  Uint8List? _ringWav;

  /// System-message sink for the centered in-chat pill.
  void Function(String message)? onSystemMessage;

  final ValueNotifier<CallState> state = ValueNotifier(CallState.idle);

  void _system(String message) => onSystemMessage?.call(message);

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  @visibleForTesting
  static int Function() clock = _wallClock;

  @visibleForTesting
  static Future<MediaStream?> Function(CallKind kind)? fakeMedia;

  @visibleForTesting
  static Future<RTCPeerConnection> Function(Map<String, dynamic> config)?
      peerConnectionFactory;

  @visibleForTesting
  static Duration callLostAfter = const Duration(seconds: 30);

  final Map<String, Future<void>> _connecting = {};
  bool _starting = false;

  @visibleForTesting
  set debugSelf(String pubkey) => _self = pubkey;

  @visibleForTesting
  void debugPeerConnected() => _onPeerConnected();

  Future<bool> Function()? ringCatchUp;

  Future<Map<String, dynamic>?> ringCheck() async {
    if (_incoming == null) {
      try {
        final catchUp = ringCatchUp ??
            () => _ref.read(nostrControllerProvider).runBackgroundCatchUp();
        await catchUp();
      } catch (_) {}
      for (var i = 0; i < 20 && _incoming == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final inc = _incoming;
    if (inc == null) return null;
    return {
      'callId': inc.callId,
      'name': _incomingName(inc),
      'video': inc.kind == CallKind.video,
      'group': inc.isGroup,
    };
  }

  String _incomingName(_IncomingCall inc) {
    var name = _peerLabel(inc.from, inc.nym);
    if (inc.isGroup && inc.groupId != null) {
      final g = _groupById(inc.groupId!);
      if (g != null && g.name.isNotEmpty) name = g.name;
    }
    try {
      final lock = _ref.read(chatLockProvider);
      if (lock.notificationIsLocked(
          'call', inc.isGroup ? (inc.groupId ?? '') : inc.from, inc.from)) {
        return lock.redact(name, '', true).title;
      }
    } catch (_) {}
    return name;
  }

  String? _shownIncoming;

  void _syncIncomingUi() {
    final inc = _incoming;
    final shown = _shownIncoming;
    if (inc?.callId == shown) return;
    final p = _platformOrNull();
    if (shown != null) {
      _shownIncoming = null;
      final answered = _active?.callId == shown;
      if (p != null) unawaited(p.endIncoming(shown, answered: answered));
    }
    if (inc != null && !inc.accepting) {
      _shownIncoming = inc.callId;
      if (p != null) {
        unawaited(p.showIncoming(
          callId: inc.callId,
          name: _incomingName(inc),
          body: inc.kind == CallKind.video
              ? tr('Incoming video call')
              : tr('Incoming audio call'),
          video: inc.kind == CallKind.video,
          group: inc.isGroup,
        ));
      }
    }
  }

  CallPlatform? _platformOrNull() {
    try {
      return _ref.read(callPlatformProvider);
    } catch (_) {
      return null;
    }
  }

  Future<void> _initAudioRoute(_ActiveCall ac) async {
    final p = _platformOrNull();
    if (p == null || !p.canRouteAudio) return;
    ac.speakerOn = ac.kind == CallKind.video;
    final headset = await p.headsetConnected();
    if (_active != ac) return;
    ac.headset = headset;
    if (headset) ac.speakerOn = false;
    await p.setSpeaker(ac.speakerOn);
    p.watchAudioDevices(() => unawaited(_onAudioDevicesChanged(ac)));
    if (_active == ac) _publish();
  }

  Future<void> _onAudioDevicesChanged(_ActiveCall ac) async {
    final p = _platformOrNull();
    if (p == null || _active != ac) return;
    final headset = await p.headsetConnected();
    if (_active != ac || headset == ac.headset) return;
    ac.headset = headset;
    ac.speakerOn = headset ? false : ac.kind == CallKind.video;
    await p.setSpeaker(ac.speakerOn);
    if (_active == ac) _publish();
  }

  Future<void> toggleSpeaker() async {
    final ac = _active;
    final p = _platformOrNull();
    if (ac == null || p == null || !p.canRouteAudio) return;
    ac.speakerOn = !ac.speakerOn;
    ac.speakerTouched = true;
    _publish();
    await p.setSpeaker(ac.speakerOn);
  }

  void _watchLocalTracks(_ActiveCall ac) {
    try {
      for (final t in ac.localStream.getTracks()) {
        _watchLocalTrack(ac, t);
      }
    } catch (_) {}
  }

  void _watchLocalTrack(_ActiveCall ac, MediaStreamTrack track) {
    try {
      track.onEnded = () => unawaited(_onLocalTrackEnded(ac, track));
    } catch (_) {}
  }

  Future<void> _onLocalTrackEnded(_ActiveCall ac, MediaStreamTrack track) async {
    if (_active != ac) return;
    try {
      if (!ac.localStream.getTracks().contains(track)) return;
    } catch (_) {
      return;
    }
    if (track.kind == 'audio') {
      _system(tr('Microphone access was lost, so the call ended'));
      end();
      return;
    }
    try {
      await ac.localStream.removeTrack(track);
    } catch (_) {}
    if (!ac.sharing) {
      for (final peer in ac.peers.values) {
        try {
          await peer.videoSender?.replaceTrack(null);
        } catch (_) {}
      }
    }
    if (_active != ac) return;
    ac.cameraOff = true;
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.video(callId: ac.callId, on: false));
    }
    _system(tr('Camera access was lost. The call continues with audio.'));
    _refreshOngoing(ac);
    _publish();
  }

  void _startOngoing(_ActiveCall ac) {
    if (_active != ac) return;
    _watchLocalTracks(ac);
    unawaited(_initAudioRoute(ac));
    _refreshOngoing(ac);
  }

  void _refreshOngoing(_ActiveCall ac) {
    if (_active != ac) return;
    try {
      unawaited(_ref.read(callPlatformProvider).startOngoing(
            video: _hasCamera(ac),
            title: tr('Call in progress'),
            text: tr('Tap to return to the call'),
            hangup: tr('Hang up'),
          ));
    } catch (_) {}
  }

  void _stopOngoing() {
    final p = _platformOrNull();
    if (p == null) return;
    p.watchAudioDevices(null);
    unawaited(p.stopOngoing());
  }

  void _chRecord(CallRecord r) {
    try {
      _ref.read(callHistoryProvider.notifier).record(r);
    } catch (_) {}
  }

  void _chBegin(_ActiveCall ac, String dir, String peer, [int? at]) {
    final r = CallRecord(
      id: ac.callId,
      peer: peer,
      group: ac.isGroup ? (ac.groupId ?? '') : '',
      kind: ac.kind.wire,
      dir: dir,
      at: at ?? clock(),
    );
    ac.ch = r;
    _chRecord(r);
  }

  void _chFinish(_ActiveCall ac) {
    final r = ac.ch;
    if (r == null) return;
    ac.ch = null;
    final dur = ac.startedAt > 0
        ? (clock() - ac.startedAt) ~/ 1000
        : 0;
    _chRecord(r.copyWith(dur: dur));
  }

  void _chMissed(String callId, String from, CallKind kind, bool isGroup,
      String? groupId, [int? whenMs]) {
    _chRecord(CallRecord(
      id: callId,
      peer: from,
      group: isGroup ? (groupId ?? '') : '',
      kind: kind.wire,
      dir: 'in',
      at: whenMs ?? clock(),
      missed: true,
    ));
  }

  void _chDeclined(_IncomingCall inc) {
    _chRecord(CallRecord(
      id: inc.callId,
      peer: inc.from,
      group: inc.isGroup ? (inc.groupId ?? '') : '',
      kind: inc.kind.wire,
      dir: 'in',
      at: inc.chAt,
    ));
  }

  /// Records a missed call keyed `missed-call-$callId` so it is never recorded twice; [whenMs] defaults to now.
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
    _chMissed(callId, callerPubkey, kind, isGroup, groupId, whenMs);
    final niceKind = kind == CallKind.video ? tr('video') : tr('audio');
    var body = tr('Missed {kind} call', {'kind': niceKind});
    if (isGroup && groupId != null) {
      final g = _groupById(groupId);
      if (g != null && g.name.isNotEmpty) {
        body += tr(' in {group}', {'group': g.name});
      }
    }
    var title = _peerLabel(callerPubkey, callerNym);
    try {
      final lock = _ref.read(chatLockProvider);
      if (lock.notificationIsLocked(
          'call', isGroup ? (groupId ?? '') : callerPubkey, callerPubkey)) {
        final r = lock.redact(title, body, true);
        title = r.title;
        body = r.body;
      }
    } catch (_) {}
    try {
      _ref.read(notificationHistoryProvider.notifier).record(
            type: 'call',
            title: title,
            body: body,
            route: isGroup ? (groupId ?? '') : callerPubkey,
            ts: whenMs,
            eventId: callId.isNotEmpty ? 'missed-call-$callId' : null,
          );
    } catch (_) {
      // The history store may be gone during teardown; best-effort.
    }
  }

  /// Local self-preview renderer.
  RTCVideoRenderer get localRenderer => _localRenderer;

  /// Remote participant's renderer by pubkey.
  RTCVideoRenderer? rendererFor(String pubkey) =>
      _active?.peers[pubkey]?.renderer;

  /// Starts a 1:1 call to [peer].
  Future<void> startCall(String peer, {bool video = false}) async {
    if (_self.isEmpty) {
      _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    }
    if (_self.isEmpty) {
      _system(tr('Must be connected to start a call'));
      return;
    }
    if (_active != null || _incoming != null) {
      _system(tr('Already in a call'));
      return;
    }
    // Calling a verified bot gets a joke instead of dialing.
    if (_ref.read(nostrControllerProvider).isVerifiedBot(peer)) {
      _system(video
          ? tr('You wish you could see my sexy body ദ്ദി(ᵔᗜᵔ)')
          : tr('You wish you could hear my sexy voice ദ്ദി(ᵔᗜᵔ)'));
      return;
    }
    await _begin(
      kind: video ? CallKind.video : CallKind.audio,
      isGroup: false,
      groupId: null,
      targets: [peer],
    );
  }

  /// Starts a mesh call to [groupId]'s members minus self.
  Future<void> startGroupCall(String groupId, {bool video = false}) async {
    if (_self.isEmpty) {
      _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    }
    if (_self.isEmpty) {
      _system(tr('Must be connected to start a call'));
      return;
    }
    if (_active != null || _incoming != null) {
      _system(tr('Already in a call'));
      return;
    }
    final group = _groupById(groupId);
    if (group == null) return;
    final targets = group.members.where((pk) => pk != _self).toList();
    if (targets.isEmpty) {
      _system(tr('No one to call in this group'));
      return;
    }
    await _begin(
      kind: video ? CallKind.video : CallKind.audio,
      isGroup: true,
      groupId: groupId,
      targets: targets,
    );
  }

  Future<bool> probeMedia(String kind) async {
    final stream =
        await _getLocalMedia(kind == 'video' ? CallKind.video : CallKind.audio);
    if (stream == null) return false;
    for (final t in stream.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
    return true;
  }

  Future<void> admitViaLink(CallLink link, String joiner) async {
    if (_self.isEmpty) {
      _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
    }
    final ac = _active;
    if (ac != null) {
      if (!ac.members.contains(joiner)) ac.members = [...ac.members, joiner];
      ac.isGroup = true;
      for (final pk in ac.members.where((pk) => pk != _self && pk != joiner)) {
        _send(pk, {
          'type': GroupToolsCallSignals.memberAdd,
          'callId': ac.callId,
          'pubkey': joiner,
        });
      }
      _send(joiner, {
        ...CallSignal.invite(
          callId: ac.callId,
          kind: ac.kind,
          isGroup: true,
          groupId: null,
          members: List.of(ac.members),
        ),
        'link': link.id,
      });
      return;
    }
    final kind = link.kind == 'video' ? CallKind.video : CallKind.audio;
    final stream = await _getLocalMedia(kind);
    if (stream == null) return;
    final callId = genCallId();
    final active = _ActiveCall(
      callId: callId,
      kind: kind,
      isGroup: false,
      groupId: null,
      members: [_self, joiner],
      localStream: stream,
      status: 'outgoing',
    )..viaLink = true;
    _active = active;
    _chBegin(active, 'out', joiner);
    _startOngoing(active);
    await _attachLocalPreview(stream);
    _send(joiner, {
      ...CallSignal.invite(
        callId: callId,
        kind: kind,
        isGroup: false,
        groupId: null,
        members: List.of(active.members),
      ),
      'link': link.id,
    });
    _publish(statusText: tr('Connecting…'));
    active.ringTimeout = Timer(kCallRingTimeout, () {
      if (_active == active && active.status == 'outgoing') {
        _send(joiner, CallSignal.cancel(callId));
        _endCall();
      }
    });
  }

  /// Accepts the current incoming call.
  Future<void> answer() async {
    final inc = _incoming;
    if (inc == null || inc.accepting) return;
    inc.accepting = true;
    inc.timeout?.cancel();
    _stopRingtone();

    final stream = await _getLocalMedia(inc.kind);
    if (_incoming != inc) {
      if (stream != null) _releaseStream(stream);
      return;
    }
    _markCallSeen(inc.callId, stream != null ? 'answered' : 'declined');
    if (stream == null) {
      _send(inc.from, CallSignal.reject(inc.callId, 'media'));
      _chDeclined(inc);
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
    _chBegin(active, 'in', inc.from, inc.chAt);
    _startOngoing(active);
    _incoming = null;
    _armWatchdog(active);
    await _attachLocalPreview(stream);

    // Broadcast accept to the other members, then connect.
    for (final pk in active.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.accept(active.callId));
    }
    await _connectToPeer(inc.from);
    for (final pk in early) {
      if (pk != _self && pk != inc.from) await _connectToPeer(pk);
    }
    _publish();
  }

  /// Rejects the current incoming call.
  void reject() {
    final inc = _incoming;
    if (inc == null) return;
    inc.timeout?.cancel();
    // Stop the ringtone on decline.
    _stopRingtone();
    // Remember the decline so re-deliveries don't re-ring.
    _markCallSeen(inc.callId, 'declined');
    _send(inc.from, CallSignal.reject(inc.callId, 'declined'));
    _chDeclined(inc);
    _incoming = null;
    _publishIdle();
  }

  _LeftCall? _left;

  static const Duration rejoinWindow = Duration(hours: 3);

  bool canRejoinGroupCall(String groupId) {
    final l = _left;
    if (l == null || l.groupId != groupId) return false;
    if (_active != null || _incoming != null) return false;
    if (l.remaining.isEmpty) return false;
    return clock() - l.at <= rejoinWindow.inMilliseconds;
  }

  void _onLeftCallHangup(String sender, Map<String, dynamic> data) {
    final l = _left;
    if (l == null || l.callId != data['callId']) return;
    l.remaining.remove(sender);
    if (l.remaining.isEmpty) {
      _left = null;
      if (_active == null && _incoming == null) _publishIdle();
    }
  }

  Future<void> rejoinGroupCall(String groupId) async {
    if (!canRejoinGroupCall(groupId) || _starting) return;
    final l = _left!;
    _starting = true;
    MediaStream? stream;
    try {
      stream = await _getLocalMedia(l.kind);
    } finally {
      _starting = false;
    }
    if (stream == null) return;
    if (_active != null || _incoming != null || _left != l) {
      _releaseStream(stream);
      return;
    }
    _left = null;
    final active = _ActiveCall(
      callId: l.callId,
      kind: l.kind,
      isGroup: true,
      groupId: l.groupId,
      members: List.of(l.members),
      localStream: stream,
      status: 'connecting',
    );
    _active = active;
    _startOngoing(active);
    await _attachLocalPreview(stream);
    for (final pk in active.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.accept(active.callId));
    }
    _publish();
    for (final pk in l.remaining) {
      await _connectToPeer(pk);
    }
    _publish();
  }

  /// Ends the active call.
  void end() {
    final ac = _active;
    if (ac != null &&
        ac.isGroup &&
        ac.groupId != null &&
        ac.status != 'outgoing' &&
        ac.peers.isNotEmpty) {
      _left = _LeftCall(
        callId: ac.callId,
        groupId: ac.groupId!,
        kind: ac.kind,
        members: List.of(ac.members),
        remaining: ac.peers.keys.toSet(),
      );
    }
    if (ac != null) {
      for (final pk in ac.members.where((pk) => pk != _self)) {
        if (ac.status == 'outgoing') _send(pk, CallSignal.cancel(ac.callId));
        _send(pk, CallSignal.hangup(ac.callId));
      }
    }
    _endCall();
  }

  /// Blocking [pubkey] mid-call ends a 1:1 call or drops them from a group call and hides their chat.
  // Public so blocking from anywhere updates the live call.
  void onUserBlocked(String pubkey) {
    final ac = _active;
    if (ac == null || pubkey.isEmpty) return;
    _clearTyping(pubkey);
    final inCall = ac.members.contains(pubkey) || ac.peers.containsKey(pubkey);
    if (!inCall) {
      // Still drop their buffered chat rows.
      _publish();
      return;
    }
    if (!ac.isGroup) {
      _system(
          tr('Left the call — you blocked {name}', {'name': _nymFor(pubkey)}));
      end();
      return;
    }
    // Close their connection and remove their tile.
    _removePeer(pubkey);
    ac.members = ac.members.where((pk) => pk != pubkey).toList();
    _publish();
  }

  /// Toggles microphone mute.
  void toggleMute() {
    final ac = _active;
    if (ac == null) return;
    ac.muted = !ac.muted;
    for (final t in ac.localStream.getAudioTracks()) {
      t.enabled = !ac.muted;
    }
    _publish();
  }

  Future<void> toggleCamera() async {
    final ac = _active;
    if (ac == null) return;
    if (!_hasCamera(ac)) {
      await _upgradeToVideo(ac);
      return;
    }
    ac.cameraOff = !ac.cameraOff;
    for (final t in ac.localStream.getVideoTracks()) {
      t.enabled = !ac.cameraOff;
    }
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.video(callId: ac.callId, on: !ac.cameraOff));
    }
    _publish();
  }

  static bool _hasCamera(_ActiveCall ac) {
    try {
      return ac.localStream.getVideoTracks().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<MediaStreamTrack?> _getCameraTrack() async {
    final fake = fakeMedia;
    MediaStream? stream;
    if (fake != null) {
      stream = await fake(CallKind.video);
    } else {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
            'facingMode': 'user',
          },
        });
      } catch (e) {
        _system(tr('Could not access {device}: {error}',
            {'device': tr('camera'), 'error': e}));
        return null;
      }
    }
    if (stream == null) return null;
    final videos = stream.getVideoTracks();
    final track = videos.isNotEmpty ? videos.first : null;
    for (final t in stream.getTracks()) {
      if (t != track) {
        try {
          await t.stop();
        } catch (_) {}
      }
    }
    return track;
  }

  Future<void> _upgradeToVideo(_ActiveCall ac) async {
    if (ac.upgradingVideo) return;
    ac.upgradingVideo = true;
    MediaStreamTrack? track;
    try {
      track = await _getCameraTrack();
    } finally {
      ac.upgradingVideo = false;
    }
    if (track == null) return;
    if (_active != ac) {
      try {
        await track.stop();
      } catch (_) {}
      return;
    }
    _watchLocalTrack(ac, track);
    try {
      await ac.localStream.addTrack(track);
    } catch (_) {}
    ac.kind = CallKind.video;
    ac.cameraOff = false;
    ac.facingMode = 'user';
    for (final entry in ac.peers.entries.toList()) {
      final peer = entry.value;
      try {
        if (peer.videoSender != null) {
          if (!ac.sharing) await peer.videoSender!.replaceTrack(track);
          continue;
        }
        peer.videoSender = await peer.pc.addTrack(track, ac.localStream);
        await _makeOffer(entry.key);
      } catch (_) {}
    }
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.video(callId: ac.callId, on: true));
    }
    await _attachLocalPreview(ac.localStream);
    _refreshOngoing(ac);
    await _videoSpeakerDefault(ac);
    _publish();
  }

  Future<void> _videoSpeakerDefault(_ActiveCall ac) async {
    final p = _platformOrNull();
    if (p == null || !p.canRouteAudio) return;
    if (ac.headset || ac.speakerTouched || ac.speakerOn) return;
    ac.speakerOn = true;
    await p.setSpeaker(true);
  }

  void _onVideo(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    final on = data['on'] == true;
    ac.peerVideo[sender] = on;
    ac.peers[sender]?.videoOn = on;
    if (on && ac.kind != CallKind.video) {
      ac.kind = CallKind.video;
      unawaited(_videoSpeakerDefault(ac).then((_) {
        if (_active == ac) _publish();
      }));
      unawaited(_refreshVideoInputCount());
    }
    _publish();
  }

  /// Switches front/rear camera.
  Future<void> switchCamera() async {
    final ac = _active;
    if (ac == null || ac.kind != CallKind.video || ac.sharing) return;
    if (ac.switchingCamera) return;
    final track = _hasCamera(ac)
        ? ac.localStream.getVideoTracks().first
        : null;
    if (track == null) return;
    ac.switchingCamera = true;
    _publish();
    try {
      await Helper.switchCamera(track);
      ac.facingMode = ac.facingMode == 'environment' ? 'user' : 'environment';
    } catch (_) {
      // The camera may not support switching.
    } finally {
      ac.switchingCamera = false;
      _publish();
    }
  }

  /// Starts or stops screen sharing.
  Future<void> toggleScreenShare() async {
    final ac = _active;
    if (ac == null) return;
    if (ac.sharing) {
      await _stopScreenShare();
      return;
    }
    // Restricted and not the presenter: request to present instead.
    if (!_canShareScreen(ac)) {
      requestToPresent();
      return;
    }
    await _startScreenShare();
  }

  /// Sends an in-call chat message.
  void sendChat(String text) {
    final ac = _active;
    final trimmed = text.trim();
    if (ac == null || trimmed.isEmpty) return;
    final mid = genCallId();
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(pk, CallSignal.chat(callId: ac.callId, text: trimmed, mid: mid));
    }
    ac.chatLog.add(
        CallChatMessage(pubkey: _self, text: trimmed, isSelf: true, mid: mid));
    _publish();
  }

  /// Broadcasts a floating reaction and shows it locally.
  void sendReaction(String emoji) {
    final ac = _active;
    if (ac == null || emoji.isEmpty) return;
    // Bump shared recents.
    try {
      _ref.read(recentEmojisProvider.notifier).record(emoji);
    } catch (_) {}
    // Attach `emojiTags` so peers without the pack can render custom emoji.
    final tags = _emojiTagsFor(emoji);
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(
          pk,
          CallSignal.reaction(
              callId: ac.callId, emoji: emoji, emojiTags: tags));
    }
    _pushFly(emoji, who: tr('You'));
  }

  void _onReaction(String sender, Map<String, dynamic> data) {
    final ac = _active;
    final emoji = data['emoji'];
    if (ac == null || ac.callId != data['callId'] || emoji is! String) return;
    if (emoji.isEmpty || !ac.members.contains(sender)) return;
    // Register the sender's custom emoji defs so the shortcode resolves.
    _ingestEmojiTags(data['emojiTags']);
    _pushFly(emoji, pubkey: sender);
  }

  /// Adds a floating reaction at a random 8–82% position, removed after ~3.2s.
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

  /// Clears the unread badge and flushes read receipts.
  void markChatRead() {
    final ac = _active;
    if (ac == null) return;
    ac.chatUnread = 0;
    _flushChatReads();
    _publish();
  }

  /// Toggles our [emoji] reaction on chat message [mid] and broadcasts it.
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
    // Custom chat reactions carry `emojiTags` too.
    final tags = _emojiTagsFor(emoji);
    for (final pk in ac.members.where((pk) => pk != _self)) {
      _send(
          pk,
          CallSignal.chatReaction(
              callId: ac.callId,
              mid: mid,
              emoji: emoji,
              op: op,
              emojiTags: tags));
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
        emoji is! String ||
        !ac.members.contains(sender)) {
      return;
    }
    // Drop blocked users' chat reactions.
    if (_isBlocked(sender)) return;
    // Register the sender's custom emoji defs.
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

  /// Typing signal throttled to 3s, auto-stopping after 4s, honoring the privacy setting.
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
    if (!ac.members.contains(sender)) return;
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

  void _sendChatRead(String senderPubkey, String mid) {
    final ac = _active;
    if (ac == null ||
        mid.isEmpty ||
        senderPubkey.isEmpty ||
        senderPubkey == _self) {
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
    if (sender == _self || !ac.members.contains(sender)) return;
    final idx = ac.chatLog.indexWhere((m) => m.mid == mid && m.isSelf);
    if (idx < 0) return;
    final readers = ac.chatReaders.putIfAbsent(mid, () => {});
    readers[sender] = _nymFor(sender);
    // Mirror readers and delivery state onto the chat entry for the UI.
    ac.chatLog[idx] = ac.chatLog[idx].copyWith(
      readers: Map.of(readers),
      delivery: CallChatDelivery.read,
    );
    _publish();
  }

  void dispose() {
    // The container may be tearing down; best-effort.
    try {
      _ref.read(nostrControllerProvider).setCallSignalHandler(null);
    } catch (_) {}
    _endCall();
    _localRenderer.dispose();
    state.dispose();
  }

  Future<void> _begin({
    required CallKind kind,
    required bool isGroup,
    String? groupId,
    required List<String> targets,
  }) async {
    if (_starting) {
      _system(tr('Already in a call'));
      return;
    }
    _starting = true;
    MediaStream? stream;
    try {
      stream = await _getLocalMedia(kind);
    } finally {
      _starting = false;
    }
    if (stream == null) return;
    if (_active != null || _incoming != null) {
      _releaseStream(stream);
      return;
    }

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
    _chBegin(active, 'out', isGroup ? '' : targets.first);
    _startOngoing(active);
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
    _ringWakes(targets);
    _publish(statusText: isGroup ? tr('Ringing group…') : tr('Calling…'));

    // No answer within 45s: cancel and say "No answer".
    active.ringTimeout = Timer(kCallRingTimeout, () {
      if (_active == active && active.status == 'outgoing') {
        for (final pk in targets) {
          _send(pk, CallSignal.cancel(callId));
        }
        _system(tr('No answer'));
        _endCall();
      }
    });
  }

  /// Entry point for decoded kind-25053 rumors.
  void handleSignal(Map<String, dynamic> rumor) {
    if (_self.isEmpty) {
      try {
        _self = _ref.read(nostrControllerProvider).identity?.pubkey ?? '';
      } catch (_) {}
    }
    final sender = rumor['pubkey'] as String?;
    if (sender == null || sender == _self) return;
    // Blocked users can't ring, join or signal.
    if (_isBlocked(sender)) return;
    if (callSignalExpired(
        rumor['tags'], DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
      return;
    }
    final data = _decodePayload(rumor);
    if (data == null) return;
    if (data.containsKey('wake')) {
      try {
        _ref.read(callWakeBookProvider).remember(_self, sender, data['wake']);
      } catch (_) {}
    }
    // Invite freshness comes from the rumor's created_at; the payload has no timestamp.
    final createdAt = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final type = data['type'];
    if (type == GroupToolsCallSignals.join ||
        type == GroupToolsCallSignals.refused) {
      unawaited(_ref.read(groupToolsProvider).onCallSignal(sender, data,
          busyFor: (kind) =>
              _incoming != null ||
              (_active != null && _active!.kind.wire != kind)));
      return;
    }
    if (type == GroupToolsCallSignals.memberAdd) {
      final ac = _active;
      final pk = data['pubkey'];
      if (ac == null || ac.callId != data['callId']) return;
      if (!ac.members.contains(sender)) return;
      if (pk is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(pk) &&
          !ac.members.contains(pk)) {
        ac.members = [...ac.members, pk];
      }
      return;
    }
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
      case 'video':
        _onVideo(sender, data);
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

  // Ringtone: the shared synthesized 480 Hz beep replayed every 2s; best-effort.

  /// Plays a beep now and every 2s; idempotent; silent on web.
  void _startRingtone() {
    if (kIsWeb) return;
    if (_ringInterval != null) return; // already ringing
    _playRingBeep();
    _ringInterval =
        Timer.periodic(const Duration(seconds: 2), (_) => _playRingBeep());
  }

  /// Stops the loop and releases the player; safe when not ringing.
  void _stopRingtone() {
    _ringInterval?.cancel();
    _ringInterval = null;
    final player = _ringPlayer;
    _ringPlayer = null;
    if (player != null) {
      // Fire-and-forget; never throw from teardown.
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

  /// Render once and play one beep.
  void _playRingBeep() {
    try {
      final wav = _ringWav ??= renderSoundWav(kIncomingCallRingtone);
      final player =
          _ringPlayer ??= (AudioPlayer()..setReleaseMode(ReleaseMode.stop));
      // Restart each beep so the cadence is crisp.
      unawaited(() async {
        try {
          await player.stop();
          await player.play(BytesSource(wav, mimeType: 'audio/wav'));
        } catch (_) {}
      }());
    } catch (_) {
      // Synthesis or playback unavailable: ring silently.
    }
  }

  // Seen calls persisted as a 24h-TTL `{callId: {t, s}}` map under `nym_seen_calls` so handled calls aren't re-rung.

  /// Status precedence; higher wins.
  static const Map<String, int> _callStatusRank = {
    'seen': 0,
    'pending': 1,
    'missed': 2,
    'declined': 3,
    'answered': 4,
  };

  /// In-memory seen-call map (`t` unix seconds, `s` status); null until hydrated.
  Map<String, _SeenCall>? _seenCalls;
  SharedPreferences? _seenPrefs;

  static const String _seenCallsKey = 'nym_seen_calls';

  Future<void> _hydrateSeenCalls() async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _seenPrefs = prefs;
      // Merge marks made before prefs loaded.
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

  /// The live map, created lazily.
  Map<String, _SeenCall> _seenMap() => _seenCalls ??= <String, _SeenCall>{};

  /// Whether this call was already recorded here.
  bool _hasSeenCall(String? callId) {
    if (callId == null || callId.isEmpty) return false;
    return _seenMap().containsKey(callId);
  }

  /// Recorded status for [callId], or null; used to skip missed entries for calls answered elsewhere.
  String? seenCallStatus(String callId) => _seenMap()[callId]?.s;

  /// Records [status], keeping any higher-ranked one, then persists.
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
    // Republish via the debounced settings sync so other devices see the result.
    try {
      _ref.read(nostrControllerProvider).syncSettings();
    } catch (_) {}
  }

  /// Merges another device's seen calls (higher rank wins); a newly answered call retracts its missed notification via [retract].
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
    for (final id in nowAnswered) {
      try {
        _ref.read(callHistoryProvider.notifier).answeredElsewhere(id);
      } catch (_) {}
    }
    // Retract any missed-call notification already surfaced.
    if (retract != null) {
      for (final id in nowAnswered) {
        retract('missed-call-$id');
      }
    }
  }

  /// TTL-prune and write back; the in-memory map is authoritative.
  void _persistSeenCalls(Map<String, _SeenCall> map) {
    final cutoff =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _callSeenTtlSec;
    map.removeWhere((_, r) => r.t < cutoff);
    final prefs = _seenPrefs;
    if (prefs == null) return; // Not hydrated yet; persists on the next mark.
    try {
      prefs.setString(_seenCallsKey, jsonEncode(_encodeSeenCalls(map)));
    } catch (_) {}
  }

  Map<String, dynamic> _encodeSeenCalls(Map<String, _SeenCall> map) =>
      {for (final e in map.entries) e.key: e.value.toWire()};

  /// 100 most recent seen calls for settings sync.
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
    // The payload may be on the rumor or nested under 'content'; support both.
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

  /// A stale invite older than 24h is dropped silently.
  static const int _callSeenTtlSec = 86400;

  void _onInvite(String sender, Map<String, dynamic> data,
      [int createdAtSec = 0]) {
    final callId = (data['callId'] as String?) ?? '';
    // Skip calls already handled here or elsewhere, stopping relay replays from re-ringing.
    if (_hasSeenCall(callId)) return;
    final linkJoin = _ref.read(groupToolsProvider).linkJoinMatches(sender, data);
    final ac0 = _active;
    final glare = callGlare(
      self: _self,
      sender: sender,
      activeCallId: ac0?.callId,
      activeStatus: ac0?.status,
      activeIsGroup: ac0?.isGroup ?? false,
      activeIsLink: ac0?.viaLink ?? false,
      activeMembers: ac0?.members ?? const [],
      inviteCallId: callId,
      inviteIsGroup: data['isGroup'] == true,
      inviteIsLink: data['link'] != null,
    );

    // acceptCalls preference gate.
    final pref = _ref.read(settingsProvider).acceptCalls;
    final friend = _isFriend(sender);
    if (!linkJoin &&
        glare == null &&
        !shouldRingForInvite(acceptCalls: pref, isFriend: friend)) {
      return;
    }

    // An invite older than 60s can't be answered: record a missed call (within the TTL) instead of ringing.
    if (createdAtSec > 0) {
      final ageSec =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - createdAtSec;
      if (ageSec > 60) {
        if (ageSec <= _callSeenTtlSec) {
          // Remember it as missed so re-deliveries don't re-record it.
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

    // Record a fresh ring as pending so relay replays short-circuit.
    _markCallSeen(callId, 'pending');

    if (glare == 'keep') return;
    if (glare == 'yield') _endCall();

    if (_active != null || _incoming != null) {
      // Busy: mark missed and bounce the caller.
      _markCallSeen(callId, 'missed');
      _send(sender, CallSignal.reject(callId, 'busy'));
      final busyNym = (data['nym'] as String?) ?? _nymFor(sender);
      _missedToast(sender, busyNym, data['isGroup'] == true,
          data['groupId'] as String?);
      _recordMissedCall(
        callId: callId,
        callerPubkey: sender,
        callerNym: busyNym,
        kind: CallKind.fromWire(data['kind']),
        isGroup: data['isGroup'] == true,
        groupId: data['groupId'] as String?,
      );
      return;
    }

    final kind = CallKind.fromWire(data['kind']);
    final isGroup = data['isGroup'] == true;
    final groupId = data['groupId'] as String?;
    final members = <String>[sender, _self];
    if (isGroup && (groupId != null || linkJoin)) {
      // Only add claimed members the real roster contains, or all when no roster is known.
      final group = groupId == null ? null : _groupById(groupId);
      final roster =
          (group != null && group.members.isNotEmpty) ? group.members : null;
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
    if (linkJoin || glare == 'yield') {
      if (linkJoin) _ref.read(groupToolsProvider).consumeLinkJoin();
      unawaited(answer());
      return;
    }
    // Only fresh rings reach here, so no silent call rings.
    _startRingtone();
    inc.timeout = Timer(kCallRingTimeout, () {
      if (_incoming == inc) {
        _incoming = null;
        // The ring is over; stop the tone.
        _stopRingtone();
        // Surface "Missed call from X" and record it.
        _markCallSeen(inc.callId, 'missed');
        _missedToast(inc.from, inc.nym, inc.isGroup, inc.groupId);
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
        _armWatchdog(ac);
        _publish(statusText: tr('Connecting…'));
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
      // Busy peer vs explicit decline.
      _system(
          data['reason'] == 'busy' ? tr('User is busy') : tr('Call declined'));
      _endCall();
      return;
    }
    ac.declined.add(sender);
    if (ac.status != 'outgoing') return;
    final others = ac.members.where((pk) => pk != _self).toList();
    if (others.isNotEmpty && others.every(ac.declined.contains)) {
      _system(tr('Everyone declined the call'));
      _endCall();
    }
  }

  void _onCancel(String sender, Map<String, dynamic> data) {
    final inc = _incoming;
    if (inc != null && inc.callId == data['callId'] && sender == inc.from) {
      inc.timeout?.cancel();
      _incoming = null;
      // The caller withdrew; stop ringing.
      _stopRingtone();
      // A cancelled ring is a missed call.
      _markCallSeen(inc.callId, 'missed');
      _missedToast(inc.from, inc.nym, inc.isGroup, inc.groupId);
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
    _onLeftCallHangup(sender, data);
    final inc = _incoming;
    if (inc != null &&
        inc.callId == data['callId'] &&
        !inc.isGroup &&
        sender == inc.from) {
      _onCancel(sender, data);
      return;
    }
    final ac = _active;
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    _removePeer(sender);
    if (!ac.isGroup || ac.peers.isEmpty) {
      _system(tr('Call ended'));
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
    final collision = offerCollision(
      selfPubkey: _self,
      peerPubkey: sender,
      signalingState: _signalingName(peer.pc.signalingState),
    );
    if (collision == 'ignore') return;
    try {
      if (collision == 'rollback') {
        await peer.pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        peer.renegotiate = true;
      }
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
      if (peer.renegotiate) {
        peer.renegotiate = false;
        unawaited(_makeOffer(sender));
      }
    } catch (e) {
      debugPrint('CallService offer error: $e');
    }
  }

  static String _signalingName(RTCSignalingState? s) {
    switch (s) {
      case RTCSignalingState.RTCSignalingStateStable:
        return 'stable';
      case RTCSignalingState.RTCSignalingStateHaveLocalOffer:
        return 'have-local-offer';
      case RTCSignalingState.RTCSignalingStateHaveRemoteOffer:
        return 'have-remote-offer';
      case RTCSignalingState.RTCSignalingStateHaveLocalPrAnswer:
        return 'have-local-pranswer';
      case RTCSignalingState.RTCSignalingStateHaveRemotePrAnswer:
        return 'have-remote-pranswer';
      case RTCSignalingState.RTCSignalingStateClosed:
        return 'closed';
      case null:
        return 'stable';
    }
  }

  Future<void> _onAnswer(String sender, Map<String, dynamic> data) async {
    final ac = _active;
    if (ac == null || !ac.members.contains(sender)) return;
    final peer = ac.peers[sender];
    if (peer == null) return;
    // A late answer on a stable connection would throw and wedge ICE; ignore it.
    if (peer.pc.signalingState == RTCSignalingState.RTCSignalingStateStable) {
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
    if (ac == null || ac.callId != data['callId']) return;
    if (!ac.members.contains(sender)) return;
    final peer = ac.peers[sender];
    final c = data['candidate'];
    if (c is! Map) return;
    // Ignore the empty end-of-gathering marker.
    final candStr = c['candidate'] as String?;
    if (candStr == null || candStr.isEmpty) return;
    final candidate = RTCIceCandidate(
      candStr,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (peer == null) {
      final list = ac.earlyIce.putIfAbsent(sender, () => []);
      if (list.length < 64) list.add(candidate);
      return;
    }
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
    if (!ac.members.contains(sender)) return;
    final peer = ac.peers[sender];
    if (peer != null) peer.sharing = data['on'] == true;
    _publish();
  }

  void _onChat(String sender, Map<String, dynamic> data) {
    final ac = _active;
    final text = data['text'];
    if (ac == null || ac.callId != data['callId'] || text is! String) return;
    if (!ac.members.contains(sender) || _isBlocked(sender)) return;
    // An inbound message ends that peer's typing state.
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

  Future<void> _connectToPeer(String peerPubkey) {
    final ac = _active;
    if (ac == null || peerPubkey == _self) return Future.value();
    if (ac.peers.containsKey(peerPubkey)) return Future.value();
    final key = '${ac.callId}/$peerPubkey';
    final pending = _connecting[key];
    if (pending != null) return pending;
    final f = _openPeer(ac, peerPubkey).whenComplete(() {
      _connecting.remove(key);
    });
    _connecting[key] = f;
    return f;
  }

  Future<void> _openPeer(_ActiveCall ac, String peerPubkey) async {
    if (fakeMedia != null && peerConnectionFactory == null) return;

    final config = <String, dynamic>{'iceServers': IceServers.servers};
    final factory = peerConnectionFactory;
    final pc = factory != null
        ? await factory(config)
        : await createPeerConnection(config);
    final peer = _Peer(pc: pc, nym: _nymFor(peerPubkey));
    await peer.renderer.initialize();
    if (_active != ac) {
      await releasePeerConnection(pc);
      peer.renderer.dispose();
      return;
    }
    ac.peers[peerPubkey] = peer;
    peer.videoOn = ac.peerVideo[peerPubkey];
    final early = ac.earlyIce.remove(peerPubkey);
    if (early != null) peer.pendingCandidates.addAll(early);

    for (final track in ac.localStream.getTracks()) {
      final sender = await pc.addTrack(track, ac.localStream);
      if (track.kind == 'video') peer.videoSender = sender;
    }

    // Already sharing: push the screen track to the new peer.
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
    if (ac.kind == CallKind.video &&
        _hasCamera(ac)) {
      _send(peerPubkey, CallSignal.video(callId: ac.callId, on: !ac.cameraOff));
    }
    // As a mod, sync presenter state to the new peer.
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
      // Only trickle real candidates, not flutter_webrtc's empty end-of-gathering event.
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
      // Drop track events after the call ended or the peer left, which would keep a disposed renderer alive.
      if (_active != ac || ac.peers[peerPubkey] != peer) return;
      if (event.streams.isNotEmpty) {
        peer.stream = event.streams.first;
        if (event.track.kind == 'video') peer.renderer.srcObject = null;
        peer.renderer.srcObject = peer.stream;
      }
      _publish();
    };
    pc.onConnectionState = (s) {
      if (_active != ac || ac.peers[peerPubkey] != peer) return;
      if (!ac.isGroup) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          peer.restarting = false;
          ac.lostTimer?.cancel();
          ac.lostTimer = null;
        } else if (s ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _armWatchdog(ac);
          if (!peer.restarting &&
              isOfferer(selfPubkey: _self, peerPubkey: peerPubkey)) {
            peer.restarting = true;
            unawaited(_makeOffer(peerPubkey, iceRestart: true));
          }
        }
      }
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

    // Glare guard: the smaller pubkey offers.
    if (isOfferer(selfPubkey: _self, peerPubkey: peerPubkey)) {
      await _makeOffer(peerPubkey);
    }
  }

  Future<void> _makeOffer(String peerPubkey, {bool iceRestart = false}) async {
    final ac = _active;
    final peer = ac?.peers[peerPubkey];
    if (ac == null || peer == null) return;
    if (iceRestart &&
        peer.pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
      return;
    }
    try {
      final offer = iceRestart
          ? await peer.pc.createOffer({'iceRestart': true})
          : await peer.pc.createOffer();
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
      unawaited(releasePeerConnection(peer.pc));
      peer.renderer.srcObject = null;
      peer.renderer.dispose();
    }
  }

  void _armWatchdog(_ActiveCall ac) {
    if (ac.isGroup || ac.lostTimer != null) return;
    ac.lostTimer = Timer(callLostAfter, () {
      ac.lostTimer = null;
      if (_active != ac) return;
      if (ac.peers.values.any((p) =>
          p.pc.connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected)) {
        return;
      }
      _system(tr('Call connection lost'));
      end();
    });
  }

  void _onPeerConnected() {
    final ac = _active;
    if (ac == null) return;
    if (ac.status != 'active') {
      ac.status = 'active';
      ac.startedAt = clock();
      ac.timerInterval?.cancel();
      ac.timerInterval = Timer.periodic(const Duration(seconds: 1), (_) {
        _publish();
      });
      _publish();
    }
  }

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
    final cam = _hasCamera(ac)
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

  void _endCall() {
    final ac = _active;
    if (ac != null) {
      _chFinish(ac);
      ac.ringTimeout?.cancel();
      ac.timerInterval?.cancel();
      ac.lostTimer?.cancel();
      ac.lostTimer = null;
      for (final t in ac.chatTypers.values) {
        t.cancel();
      }
      ac.chatTypers.clear();
      _callTypingStopTimer?.cancel();
      _callTypingStopTimer = null;
      _callTypingThrottle = 0;
      for (final peer in ac.peers.values) {
        unawaited(releasePeerConnection(peer.pc));
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
    _stopOngoing();
    _flyReactions.clear();
    // Every teardown path silences the ring.
    _stopRingtone();
    if (_localRendererReady) _localRenderer.srcObject = null;
    _publishIdle();
  }

  void _releaseStream(MediaStream stream) {
    for (final t in stream.getTracks()) {
      try {
        t.stop();
      } catch (_) {}
    }
  }

  Future<MediaStream?> _getLocalMedia(CallKind kind) async {
    final fake = fakeMedia;
    if (fake != null) return fake(kind);
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
      // Surface a media-error system message.
      _system(
        tr('Could not access {device}: {error}', {
          'device': kind == CallKind.video
              ? tr('camera/microphone')
              : tr('microphone'),
          'error': e,
        }),
      );
      return null;
    }
  }

  Future<void> _attachLocalPreview(MediaStream stream) async {
    if (fakeMedia != null) return;
    if (!_localRendererReady) {
      await _localRenderer.initialize();
      _localRendererReady = true;
    }
    _localRenderer.srcObject = stream;
    // Gate the switch-camera button on multiple cameras.
    unawaited(_refreshVideoInputCount());
  }

  Future<bool> _send(String to, Map<String, dynamic> payload) {
    final wake = _ownWakeFor(to);
    return _ref
        .read(nostrControllerProvider)
        .sendCallSignal(
            to: to,
            payload: wake == null ? payload : {...payload, 'wake': wake},
            groupId: _signalGroupId(payload['callId']));
  }

  String? _ownWakeFor(String peer) {
    try {
      final own = _ref.read(ringRegistrationProvider).wakeFor(_self);
      if (own == null) return null;
      final share = shouldShareWake(
        acceptCalls: _ref.read(settingsProvider).acceptCalls,
        isFriend: _isFriend(peer),
        registered: true,
      );
      return share ? own : null;
    } catch (_) {
      return null;
    }
  }

  void _ringWakes(List<String> targets) {
    try {
      final book = _ref.read(callWakeBookProvider);
      final client = _ref.read(ringClientProvider);
      for (final pk in targets) {
        final wake = book.wakeFor(_self, pk);
        if (wake != null) unawaited(client.ring(wake));
      }
    } catch (_) {}
  }

  String? _signalGroupId(Object? callId) {
    final ac = _active;
    if (ac != null &&
        ac.isGroup &&
        ac.groupId != null &&
        (callId == null || ac.callId == callId)) {
      return ac.groupId;
    }
    final inc = _incoming;
    if (inc != null &&
        inc.isGroup &&
        inc.groupId != null &&
        (callId == null || inc.callId == callId)) {
      return inc.groupId;
    }
    return null;
  }

  Group? _groupById(String id) {
    final groups = _ref.read(appStateProvider).groups;
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  bool _isFriend(String pubkey) {
    return _ref.read(appStateProvider).friends.contains(pubkey);
  }

  bool _isBlocked(String pubkey) =>
      _ref.read(appStateProvider).blockedUsers.contains(pubkey);

  String _peerLabel(String pubkey, [String? hint]) {
    var name = hint != null && hint.isNotEmpty ? stripPubkeySuffix(hint) : 'nym';
    try {
      name = callPeerName(_ref.read(appStateProvider), pubkey, hint);
    } catch (_) {}
    return '$name#${getPubkeySuffix(pubkey)}';
  }

  void _missedToast(String pubkey, String? hint,
      [bool isGroup = false, String? groupId]) {
    try {
      final lock = _ref.read(chatLockProvider);
      if (lock.notificationIsLocked(
          'call', isGroup ? (groupId ?? '') : pubkey, pubkey)) {
        _system(lock.redact('', '', true).body);
        return;
      }
    } catch (_) {}
    _system(tr('Missed call from {name}', {'name': _peerLabel(pubkey, hint)}));
  }

  String _nymFor(String pubkey) {
    final users = _ref.read(usersProvider);
    final u = users[pubkey];
    if (u != null && u.nym.isNotEmpty) return u.nym;
    return pubkey.length >= 8 ? pubkey.substring(0, 8) : pubkey;
  }

  /// `['emoji', code, url]` tags for custom shortcodes in [content]; null if the store is unavailable.
  List<List<String>>? _emojiTagsFor(String content) {
    try {
      final tags = _ref
          .read(liveCustomEmojiProvider.notifier)
          .emojiTagsForContent(content);
      return tags.isEmpty ? null : tags;
    } catch (_) {
      return null;
    }
  }

  /// Registers inbound custom emoji defs from a reaction payload.
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

  /// Random source for reaction positions (seedable in tests).
  final Random _rng = Random();

  bool _typingAllowed(_ActiveCall ac) => _indicatorAllowed(
      _ref.read(settingsProvider).typingIndicatorsScope, ac.isGroup);

  bool _readReceiptAllowed(_ActiveCall ac) => _indicatorAllowed(
      _ref.read(settingsProvider).readReceiptsScope, ac.isGroup);

  /// scope: disabled|everywhere|pms|groups|pms-groups; context: group or pm.
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

  /// True when we own or moderate this group call.
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

  /// Whether the local user may screen-share now.
  bool _canShareScreen([_ActiveCall? call]) {
    final ac = call ?? _active;
    if (ac == null) return false;
    if (!ac.isGroup) return true;
    if (_isCallMod(ac)) return true;
    if (!ac.shareRestricted) return true;
    return ac.presenter == _self;
  }

  /// Restricted non-mod: request to present instead.
  void requestToPresent() {
    final ac = _active;
    if (ac == null || !ac.isGroup) return;
    final mods = ac.members
        .where((pk) => pk != _self && _peerCanModerate(ac, pk))
        .toList();
    if (mods.isEmpty) {
      _system(tr('No moderator available to grant presenting'));
      return;
    }
    for (final pk in mods) {
      _send(pk, CallSignal.presentRequest(ac.callId));
    }
    _system(tr('Requested to present'));
  }

  void _onPresentRequest(String sender, Map<String, dynamic> data) {
    final ac = _active;
    if (ac == null || ac.callId != data['callId'] || !_isCallMod(ac)) return;
    if (!ac.members.contains(sender)) return;
    ac.presentRequests.add(sender);
    _system(tr('{name} requested to present', {'name': _nymFor(sender)}));
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
      _system(tr('You can now share your screen'));
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

  /// Mod assigns or clears the presenter.
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

  /// Re-counts video inputs for switch-camera gating; keeps the prior count on failure.
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
      // Enumeration may be unavailable on some platforms.
    }
  }

  void _publishIdle() {
    _syncIncomingUi();
    final l = _left;
    state.value = l != null && canRejoinGroupCall(l.groupId)
        ? CallState(rejoinGroupId: l.groupId)
        : CallState.idle;
  }

  void _publish({String? statusText}) {
    _syncIncomingUi();
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

    // Blocked peers never get a tile.
    final participants = ac.peers.entries
        .where((e) => !_isBlocked(e.key))
        .map((e) => CallParticipant(
              pubkey: e.key,
              nym: e.value.nym,
              connected: e.value.connected,
              hasVideo: e.value.videoOn != false &&
                  ((e.value.stream?.getVideoTracks().isNotEmpty) ?? false),
              sharing: e.value.sharing,
            ))
        .toList();

    final elapsed = ac.startedAt == 0
        ? 0
        : (DateTime.now().millisecondsSinceEpoch - ac.startedAt) ~/ 1000;

    final peer = ac.isGroup
        ? null
        : ac.members.firstWhere((pk) => pk != _self, orElse: () => '');

    // Merge per-message reactions into chat entries; hide blocked senders' rows.
    final chatLog =
        ac.chatLog.where((m) => m.isSelf || !_isBlocked(m.pubkey)).map((m) {
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
      cameraOff: ac.cameraOff || !_hasCamera(ac),
      hasCamera: _hasCamera(ac),
      sharing: ac.sharing,
      switchingCamera: ac.switchingCamera,
      videoInputCount: ac.videoInputCount,
      facingMode: ac.facingMode,
      statusText: statusText ??
          (phase == CallPhase.active
              ? _formatTimer(elapsed)
              : (phase == CallPhase.ringing
                  ? (ac.isGroup ? tr('Ringing group…') : tr('Calling…'))
                  : tr('Connecting…'))),
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
      speakerOn: ac.speakerOn,
      headset: ac.headset,
      canRouteAudio: _platformOrNull()?.canRouteAudio ?? false,
      ringing: phase == CallPhase.ringing
          ? ac.members
              .where((pk) =>
                  pk != _self && !ac.peers.containsKey(pk) && !_isBlocked(pk))
              .toList()
          : const [],
    );
  }

  static String _formatTimer(int seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Decodes a raw JSON string payload into a map.
Map<String, dynamic>? jsonDecodeMap(String s) {
  final decoded = jsonDecode(s);
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// Persisted seen-call record `{t, s}`; tolerates the legacy bare-number form.
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
