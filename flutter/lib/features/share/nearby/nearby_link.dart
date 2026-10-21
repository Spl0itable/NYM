import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/mesh/mesh_peer.dart';
import '../../../services/mesh/mesh_service.dart';
import '../../../services/mesh/protocol/nym_share_payload.dart';
import '../../../state/app_state.dart';
import '../../mesh/ghost_mode.dart';
import '../../mesh/mesh_controller.dart';

abstract class NearbyLink {
  Future<bool> sendShare(String peerID, String link);

  Future<bool> sendNiToken(String peerID, Uint8List token,
      {bool replyRequested = false});
}

class MeshNearbyLink implements NearbyLink {
  MeshNearbyLink(this.service);

  final MeshService service;

  @override
  Future<bool> sendShare(String peerID, String link) =>
      service.sendNymShare(peerID, link);

  @override
  Future<bool> sendNiToken(String peerID, Uint8List token,
          {bool replyRequested = false}) =>
      service.sendNiToken(peerID, token, replyRequested: replyRequested);
}

class NearbySender {
  const NearbySender({
    required this.peerID,
    required this.nick,
    this.pubkey,
    this.verified = false,
  });

  final String peerID;
  final String nick;
  final String? pubkey;
  final bool verified;

  static NearbySender? fromPeer(MeshPeer? peer) {
    if (peer == null) return null;
    final nick = peer.nickname?.trim() ?? '';
    return NearbySender(
      peerID: peer.peerID,
      nick: nick.isEmpty ? peer.peerID : nick,
      pubkey: peer.nostrPubkey,
      verified: peer.nostrLinkVerified,
    );
  }
}

class NearbyMeshRouter {
  NearbyMeshRouter({
    required this.peerLookup,
    required this.onShare,
    required this.onToken,
  });

  final NearbySender? Function(String peerID) peerLookup;
  final void Function(NearbySender from, String link) onShare;
  final void Function(MeshNiToken token) onToken;

  final List<StreamSubscription<Object>> _subs = [];

  void attach(MeshService? service) {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    if (service == null) return;
    _subs.add(service.onNymShare.listen((e) {
      final from = peerLookup(e.senderPeerID);
      if (from != null) onShare(from, e.link);
    }));
    _subs.add(service.onNiToken.listen((t) {
      if (peerLookup(t.senderPeerID) != null) onToken(t);
    }));
  }

  void dispose() => attach(null);
}

final nearbyMeshRunningProvider = Provider<bool>((ref) =>
    MeshController.isSupportedPlatform &&
    ref.watch(meshControllerProvider.select((s) => s.running)));

final nearbyRawPeersProvider = Provider<List<MeshPeer>>(
    (ref) => ref.watch(meshControllerProvider.select((s) => s.peers)));

final nearbyLinkProvider = Provider<NearbyLink?>((ref) {
  if (!ref.watch(nearbyMeshRunningProvider)) return null;
  final service = ref.watch(meshControllerProvider.notifier).service;
  return service == null ? null : MeshNearbyLink(service);
});

final nearbyBlockedProvider = Provider<bool Function(String pubkey)>((ref) {
  return (pubkey) {
    final app = ref.read(appStateProvider);
    final key = pubkey.toLowerCase();
    return app.isUserBlocked(key) || app.isPersonHidden(key);
  };
});

final nearbyClockProvider = Provider<int Function()>(
    (ref) => () => DateTime.now().millisecondsSinceEpoch);

final nearbyIdentityProvider = Provider<String>(
    (ref) => ref.watch(appStateProvider.select((s) => s.selfPubkey)));

final nearbyNymOfProvider = Provider<String? Function(String pubkey)>((ref) {
  return (pubkey) {
    final nym = ref.read(appStateProvider).users[pubkey]?.nym.trim() ?? '';
    return nym.isEmpty ? null : nym;
  };
});

final nearbyGhostActiveProvider = Provider<bool>((ref) => ref.watch(
    ghostModeProvider.select((g) => g.enabled && g.current != null)));
