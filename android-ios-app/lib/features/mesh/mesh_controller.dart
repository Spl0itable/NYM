import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/crypto/schnorr.dart' show signId;
import '../../services/mesh/mesh_avatar_registry.dart';
import '../../services/mesh/mesh_events.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/noise/noise_identity.dart';
import 'ghost_mode.dart';
import '../../services/mesh/noise/nostr_link.dart';
import '../../services/mesh/protocol/mesh_diagnostics_packets.dart';
import '../../services/mesh/protocol/mesh_profile.dart';
import '../../services/mesh/transport/ble_mesh_transport.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import 'mesh_bridge.dart';
import 'mesh_diagnostics.dart';

/// The state of one peer's echo probe, for the diagnostics list.
///
/// A peer list says who is out there. It cannot say whether they are in the
/// same room or three relays away — the echo can.
@immutable
class MeshPingState {
  const MeshPingState.waiting()
      : roundTripMs = null,
        hops = null,
        lost = false;
  const MeshPingState.lost()
      : roundTripMs = null,
        hops = null,
        lost = true;
  const MeshPingState.result({required this.roundTripMs, required this.hops})
      : lost = false;

  final int? roundTripMs;

  /// Null when the reply's TTL pair was impossible, which means the packet was
  /// rewritten rather than relayed. Better no hop count than a wrong one.
  final int? hops;
  final bool lost;

  bool get isWaiting => !lost && roundTripMs == null;
}

/// Immutable UI snapshot of the mesh radio status. Conversations themselves live
/// in the normal [AppState] stores (channels/PMs) and render through the
/// canonical ChatPane — this only carries radio/discovery status and the mesh
/// markers the sidebar uses to badge which conversations are Bluetooth-backed.
@immutable
class MeshUiState {
  const MeshUiState({
    this.enabled = false,
    this.running = false,
    this.availability = MeshTransportAvailability.unknown,
    this.myPeerID,
    this.linkCount = 0,
    this.peers = const [],
    this.pings = const {},
    this.meshChannelKeys = const {},
    this.meshPmPubkeys = const {},
    this.error,
  });

  final bool enabled;
  final bool running;
  final MeshTransportAvailability availability;
  final String? myPeerID;
  final int linkCount;
  final List<MeshPeer> peers;

  /// peerID -> the last probe's state. Only holds peers actually probed.
  final Map<String, MeshPingState> pings;

  /// Bare channel keys (lowercase) that are mesh-backed.
  final Set<String> meshChannelKeys;

  /// PM peer pubkeys that are mesh-backed.
  final Set<String> meshPmPubkeys;

  final String? error;

  bool isMeshChannelKey(String key) =>
      meshChannelKeys.contains(key.toLowerCase());
  bool isMeshPmPubkey(String pubkey) =>
      meshPmPubkeys.contains(pubkey.toLowerCase());

  MeshUiState copyWith({
    bool? enabled,
    bool? running,
    MeshTransportAvailability? availability,
    String? myPeerID,
    int? linkCount,
    List<MeshPeer>? peers,
    Map<String, MeshPingState>? pings,
    Set<String>? meshChannelKeys,
    Set<String>? meshPmPubkeys,
    String? error,
    bool clearError = false,
  }) {
    return MeshUiState(
      enabled: enabled ?? this.enabled,
      running: running ?? this.running,
      availability: availability ?? this.availability,
      myPeerID: myPeerID ?? this.myPeerID,
      linkCount: linkCount ?? this.linkCount,
      peers: peers ?? this.peers,
      pings: pings ?? this.pings,
      meshChannelKeys: meshChannelKeys ?? this.meshChannelKeys,
      meshPmPubkeys: meshPmPubkeys ?? this.meshPmPubkeys,
      error: clearError ? null : (error ?? this.error),
    );
  }

  MeshPeer? peerById(String peerID) {
    for (final p in peers) {
      if (p.peerID == peerID) return p;
    }
    return null;
  }
}

/// Owns the [MeshService] lifecycle and the [MeshBridge] that feeds mesh traffic
/// into the app's normal chat stores. Reacts to the `meshEnabled` setting to
/// power the radio on/off.
class MeshController extends StateNotifier<MeshUiState> {
  MeshController({
    required Ref ref,
    required String Function() nickname,
    String? Function()? nostrPubkey,
    String? Function(String messageHex)? signSchnorr,
    String? Function(String pubkey)? avatarUrlOf,
    String? Function(String pubkey)? bannerUrlOf,
  })  : _ref = ref,
        _nickname = nickname,
        _nostrPubkey = nostrPubkey,
        _signSchnorr = signSchnorr,
        _avatarUrlOf = avatarUrlOf,
        _bannerUrlOf = bannerUrlOf,
        super(const MeshUiState());

  final Ref _ref;
  final String Function() _nickname;
  final String? Function()? _nostrPubkey;
  final String? Function(String messageHex)? _signSchnorr;
  final String? Function(String pubkey)? _avatarUrlOf;
  final String? Function(String pubkey)? _bannerUrlOf;

  Uint8List? _nostrLink;

  MeshService? _service;
  MeshBridge? _bridge;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _busy = false;

  /// The active bridge, used by [NostrController] to route mesh sends and by the
  /// sidebar to badge mesh conversations. Null while the mesh is off.
  MeshBridge? get bridge => _bridge;

  /// Mesh runs only where BLE central+peripheral are available.
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Tears the mesh down and brings it back up on the current identity. Ghost
  /// Mode calls this on every rotation: MeshService binds its Noise manager to
  /// one identity at construction, so a new identity means a new service.
  Future<void>? _restartChain;

  Future<void> restart() {
    if (!state.enabled) return Future.value();
    // Serialised: _stop and _start both bail out while _busy, so two overlapping
    // restarts could tear the mesh down and then skip bringing it back up,
    // leaving the radio silently off until the next toggle.
    final prev = _restartChain ?? Future<void>.value();
    return _restartChain = prev.then((_) async {
      if (!state.enabled) return;
      await _stop();
      await _start();
    }).catchError((_) {});
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled == state.enabled && (!enabled || _service != null)) return;
    state = state.copyWith(enabled: enabled, clearError: true);
    if (enabled) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _start() async {
    if (_busy || _service != null) return;
    _busy = true;
    try {
      if (!isSupportedPlatform) {
        state = state.copyWith(
          availability: MeshTransportAvailability.unsupported,
          running: false,
        );
        return;
      }
      // A persisted Ghost Mode session must be re-armed BEFORE we choose an
      // identity, or boot would announce the real one and only ghost a moment
      // later — the one announce that would deanonymise the whole session.
      await _ref.read(ghostModeProvider.notifier).ensureRestored();
      final ghost = _ref.read(ghostModeProvider);
      final identity = ghost.enabled && ghost.current != null
          ? ghost.current!.meshIdentity
          : await NoiseIdentity.loadOrCreate();
      _nostrLink = _computeNostrLink(identity);
      // Route low-level radio lifecycle (power state, scanning, advertising,
      // links) into the same on-screen mesh diagnostics panel the receive
      // pipeline uses, so an iOS device with no Console access can see whether
      // the transport actually came up.
      BleMeshTransport.debugLog = MeshDiagnostics.instance.log;
      final transport = BleMeshTransport(identity.peerID);
      final service = MeshService(
        identity: identity,
        transport: transport,
        nicknameProvider: _nickname,
        nostrLinkProvider: () => _nostrLink,
        profileProvider: _buildMyProfile,
      );
      _service = service;

      final bridge = MeshBridge(
        ref: _ref,
        service: service,
        selfNym: _nickname,
      );
      _bridge = bridge;

      // Peer discovery drives avatar hydration + the marker refresh; the bridge
      // owns the actual message/receipt/file ingest.
      _subs.add(service.peersStream.listen((peers) {
        for (final p in peers) {
          final pubkey = p.nostrPubkey;
          if (pubkey != null) {
            p.avatarUrl ??= _avatarUrlOf?.call(pubkey);
            p.bannerUrl ??= _bannerUrlOf?.call(pubkey);
          }
          unawaited(_hydratePeerAvatar(service, p));
        }
        state = state.copyWith(
          peers: List.of(peers),
          linkCount: service.connectedLinkCount,
          meshChannelKeys: Set.of(bridge.meshChannelKeys),
          meshPmPubkeys: Set.of(bridge.meshPmPubkeys),
        );
      }));
      _subs.add(service.onProfile.listen(_onProfile));
      _subs.add(service.onPingResult.listen(_onPingResult));
      // Keep the UI availability live: the BLE radio reports `unknown` at start
      // and only becomes `ready` a beat later when the adapter powers on, so a
      // one-shot read would leave the status stuck on "Starting…".
      _subs.add(transport.availabilityChanged.listen((availability) {
        state = state.copyWith(availability: availability);
      }));

      bridge.start();

      await service.start();
      state = state.copyWith(
        running: true,
        // Read the LIVE availability, not start()'s return value: on iOS the
        // radio flips unknown→ready while start() is still awaiting (announce
        // broadcast etc.), so the availabilityChanged listener above may have
        // already pushed `ready` — and the stale captured value would clobber
        // it right back to `unknown`, pinning the UI on "Starting…".
        availability: service.availability,
        myPeerID: service.myPeerID,
        meshChannelKeys: Set.of(bridge.meshChannelKeys),
        clearError: true,
      );
    } catch (e) {
      // Drop the peer list with the radio, exactly as _stop does: a start that
      // failed leaves whatever was discovered last time on screen, and every
      // row in it is a peer nothing can reach — including its ping button.
      await _teardown();
      state = state.copyWith(
          error: '$e',
          running: false,
          linkCount: 0,
          peers: const [],
          pings: const {});
    } finally {
      _busy = false;
    }
  }

  /// Joins/creates a mesh group [name]. A non-empty [password] makes it an
  /// encrypted group (only members with the same password can read it). The
  /// channel is registered as an app channel; the caller opens it via
  /// `switchView(ChatView.channel(name))`.
  Future<void> joinChannel(String name, {String password = ''}) async {
    final channel = name.startsWith('#') ? name : '#$name';
    if (password.isNotEmpty) {
      await _service?.setChannelPassword(channel, password);
    }
    _bridge?.registerChannel(channel);
    refreshMarkers();
  }

  bool hasChannelKey(String channel) =>
      _service?.hasChannelKey(channel) ?? false;

  /// Re-copies the bridge's mesh markers into the UI state so the sidebar can
  /// badge newly-seen mesh channels/PMs. Called by the bridge as traffic lands.
  void refreshMarkers() {
    final b = _bridge;
    if (b == null) return;
    state = state.copyWith(
      meshChannelKeys: Set.of(b.meshChannelKeys),
      meshPmPubkeys: Set.of(b.meshPmPubkeys),
    );
  }

  Uint8List? _computeNostrLink(NoiseIdentity identity) {
    final pubkey = _nostrPubkey?.call();
    final signer = _signSchnorr;
    if (pubkey == null || pubkey.length != 64 || signer == null) return null;
    final sigHex = signer(NostrLink.messageHex(identity.staticPublic));
    if (sigHex == null || sigHex.isEmpty) return null;
    return NostrLink.build(pubkey, sigHex);
  }

  // ---- Mesh profile (avatar/banner) transfer --------------------------------

  static const int _maxAvatarBytes = 96 * 1024;
  static const int _maxBannerBytes = 384 * 1024;

  final Set<String> _profileAsked = {};

  Future<MeshProfile?> _buildMyProfile(MeshProfileRequest request) async {
    // An avatar or banner is a far stronger fingerprint than any of the keys
    // Ghost Mode rotates — the same picture across two epochs relinks them
    // instantly. Refuse outright rather than relying on the ghost pubkey
    // happening to have no profile to look up.
    if (_ref.read(ghostModeProvider).enabled) return null;
    final pubkey = _nostrPubkey?.call();
    (Uint8List, String?)? avatar;
    (Uint8List, String?)? banner;
    if (request.wantAvatar && pubkey != null) {
      avatar = await _fetchCapped(_avatarUrlOf?.call(pubkey), _maxAvatarBytes);
    }
    if (request.wantBanner && pubkey != null) {
      banner = await _fetchCapped(_bannerUrlOf?.call(pubkey), _maxBannerBytes);
    }
    return MeshProfile(
      nickname: _nickname(),
      nostrPubkey: pubkey,
      avatar: avatar?.$1,
      avatarMime: avatar?.$2,
      banner: banner?.$1,
      bannerMime: banner?.$2,
    );
  }

  Future<(Uint8List, String?)?> _fetchCapped(String? url, int maxBytes) async {
    if (url == null || url.isEmpty) return null;
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.length > maxBytes) {
        return null;
      }
      return (resp.bodyBytes, resp.headers['content-type']);
    } catch (_) {
      return null;
    }
  }

  Future<void> _onProfile(MeshProfileReceived event) async {
    final profile = event.profile;
    final avatar = profile.avatar;
    if (avatar == null || avatar.isEmpty) return;
    _publishAvatar(event.peerID, avatar);
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}'
          '/mesh_avatars');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/${event.peerID}.img');
      await file.writeAsBytes(avatar, flush: true);
      final peers = List.of(state.peers);
      for (final p in peers) {
        if (p.peerID == event.peerID) p.avatarFilePath = file.path;
      }
      state = state.copyWith(peers: peers);
    } catch (_) {
      // Non-fatal: the registry still holds the in-memory bytes.
    }
  }

  void _publishAvatar(String peerID, Uint8List bytes) {
    // Register under every seed a message/DM row for this peer might use: the
    // raw peerID, the canonical conversation pubkey (the bridge's Noise-key /
    // Nostr-link resolution — the seed rows actually key on), and the transient
    // padded-peerID pseudo-pubkey used before the Noise key is known, so the
    // peer's real avatar renders in all cases.
    final seeds = <String>{peerID, meshStablePubkeyForPeerId(peerID)};
    final peer = state.peerById(peerID);
    if (peer != null) {
      seeds.add(
          _bridge?.pubkeyForPeer(peer) ?? meshStablePubkeyForPeerId(peerID));
      if (peer.nostrLinkVerified && peer.nostrPubkey != null) {
        seeds.add(peer.nostrPubkey!);
      }
    }
    MeshAvatarRegistry.instance.register(seeds.toList(), bytes);
  }

  Future<void> _hydratePeerAvatar(MeshService service, MeshPeer peer) async {
    if (peer.avatarUrl != null ||
        peer.avatarFilePath != null ||
        _profileAsked.contains(peer.peerID)) {
      return;
    }
    _profileAsked.add(peer.peerID);
    try {
      final path = '${(await getApplicationDocumentsDirectory()).path}'
          '/mesh_avatars/${peer.peerID}.img';
      final file = File(path);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        _publishAvatar(peer.peerID, bytes);
        final peers = List.of(state.peers);
        for (final p in peers) {
          if (p.peerID == peer.peerID) p.avatarFilePath = path;
        }
        state = state.copyWith(peers: peers);
        return;
      }
    } catch (_) {
      // fall through to a fresh request
    }
    unawaited(service.requestProfile(peer.peerID));
  }

  /// How long a probe waits before the row says so. A peer is in the list
  /// because we heard an announce, which may have been minutes and several
  /// moves ago; silence is an answer, not a hang.
  static const Duration pingTimeout = Duration(seconds: 10);

  final Map<String, Timer> _pingTimeouts = <String, Timer>{};

  /// Probes [peerID]: are you there, and how many links away?
  Future<void> ping(String peerID) async {
    final service = _service;
    // A radio that is not running cannot measure anything — but returning in
    // silence made the button look dead: no "pinging…", no result, nothing at
    // all for a tap that landed. Say it the same way an unanswered ping is
    // said, so the row always reacts to being pressed.
    if (service == null || !state.running) {
      _setPing(peerID, const MeshPingState.lost());
      return;
    }
    _setPing(peerID, const MeshPingState.waiting());
    _pingTimeouts.remove(peerID)?.cancel();
    _pingTimeouts[peerID] = Timer(pingTimeout, () {
      _pingTimeouts.remove(peerID);
      // Reading `state` after dispose throws, and a timer outlives it.
      if (!mounted) return;
      if (state.pings[peerID]?.isWaiting ?? false) {
        _setPing(peerID, const MeshPingState.lost());
      }
    });
    if (await service.ping(peerID)) return;
    _pingTimeouts.remove(peerID)?.cancel();
    _setPing(peerID, const MeshPingState.lost());
  }

  void _onPingResult(MeshPingResult result) {
    _pingTimeouts.remove(result.peerID)?.cancel();
    _setPing(
      result.peerID,
      MeshPingState.result(roundTripMs: result.roundTripMs, hops: result.hops),
    );
  }

  void _setPing(String peerID, MeshPingState value) {
    if (!mounted) return;
    state = state.copyWith(
        pings: {...state.pings, peerID: value});
  }

  Future<void> _stop() async {
    if (_busy) return;
    _busy = true;
    try {
      await _teardown();
      // A round trip measured to a peer we can no longer reach is a stale
      // number, not a reading. (_teardown cancelled the timers.)
      state = state.copyWith(
          running: false, linkCount: 0, peers: const [], pings: const {});
    } finally {
      _busy = false;
    }
  }

  Future<void> _teardown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final t in _pingTimeouts.values) {
      t.cancel();
    }
    _pingTimeouts.clear();
    await _bridge?.dispose();
    _bridge = null;
    final service = _service;
    _service = null;
    _profileAsked.clear();
    if (service != null) {
      await service.stop();
      service.dispose();
    }
  }

  /// Opens the OS settings page so the user can grant Bluetooth permission.
  Future<void> openSystemSettings() async => _service?.openSystemSettings();

  Future<void> shutdown() async => _teardown();
}

/// Whether the mesh screen overlay is showing inside the home shell. The mesh
/// screen is NOT a pushed route: it renders in the shell's content area beneath
/// the off-canvas drawer, so the sidebar opens over it like on any other screen
/// and a conversation switch (sidebar tap, peer tap, notification tap) closes
/// it to reveal the chat.
final meshScreenOpenProvider = StateProvider<bool>((ref) => false);

/// The mesh controller, reacting to the `meshEnabled` setting.
final meshControllerProvider =
    StateNotifierProvider<MeshController, MeshUiState>((ref) {
  final controller = MeshController(
    ref: ref,
    nickname: () {
      final ghost = ref.read(ghostModeProvider);
      if (ghost.enabled && ghost.current != null) return ghost.current!.nickname;
      final nym = ref.read(appStateProvider).selfNym;
      return nym.isNotEmpty ? nym : 'nym';
    },
    // Ghost Mode advertises a REAL nostrLink, just an ephemeral one: peers can
    // still reach this device over Nostr, but the link resolves to a throwaway
    // key rather than the user's npub.
    nostrPubkey: () {
      final ghost = ref.read(ghostModeProvider);
      if (ghost.enabled && ghost.current != null) return ghost.current!.pubkey;
      return ref.read(nostrControllerProvider).identity?.pubkey;
    },
    signSchnorr: (messageHex) {
      final ghost = ref.read(ghostModeProvider);
      final priv = ghost.enabled && ghost.current != null
          ? ghost.current!.privkey
          : ref.read(nostrControllerProvider).identity?.privkey;
      return priv == null ? null : signId(messageHex, priv);
    },
    avatarUrlOf: (pubkey) =>
        ref.read(appStateProvider).users[pubkey]?.profile?.picture,
    bannerUrlOf: (pubkey) =>
        ref.read(appStateProvider).users[pubkey]?.profile?.banner,
  );
  ref.listen<bool>(
    settingsProvider.select((s) => s.meshEnabled),
    (_, next) => controller.setEnabled(next),
    fireImmediately: true,
  );
  ref.onDispose(controller.shutdown);
  return controller;
});
