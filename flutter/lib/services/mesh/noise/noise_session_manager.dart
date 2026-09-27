import 'dart:typed_data';

import 'noise_identity.dart';
import 'noise_session.dart';

/// Manages one Noise `XX` session per peer and drives the handshake state
/// machine. It never touches the radio — the owner ([MeshService]) broadcasts
/// the handshake bytes this manager produces and feeds it the bytes that arrive.
///
/// Simultaneous-initiation collisions (both peers send message 1 at once) are
/// resolved deterministically by peerID comparison, so exactly one side ends up
/// the initiator — matching bitchat's tie-break.
class NoiseSessionManager {
  NoiseSessionManager(this.identity);

  final NoiseIdentity identity;
  final Map<String, NoiseSession> _sessions = {};

  bool isEstablished(String peerID) =>
      _sessions[peerID]?.isEstablished ?? false;

  NoiseSession? session(String peerID) => _sessions[peerID];

  bool isHandshaking(String peerID) =>
      _sessions[peerID]?.state == NoiseSessionState.handshaking;

  void remove(String peerID) => _sessions.remove(peerID);

  /// Begins a handshake with [peerID] as initiator and returns message 1 to
  /// broadcast. If a session already exists it is replaced.
  Future<Uint8List> initiateHandshake(String peerID) async {
    final s = NoiseSession(
      peerID: peerID,
      isInitiator: true,
      staticPrivate: identity.staticPrivate,
      staticPublic: identity.staticPublic,
    );
    _sessions[peerID] = s;
    return s.startHandshake();
  }

  /// Feeds an incoming [MeshMessageType.noiseHandshake] payload from [peerID].
  /// Returns the response to broadcast, or null when nothing must be sent.
  Future<Uint8List?> handleHandshake(String peerID, Uint8List data) async {
    final existing = _sessions[peerID];

    // Collision: we already opened as initiator (awaiting message 2) but the
    // peer sent their own message 1 (32 bytes). Deterministically pick a winner.
    if (existing != null &&
        existing.isInitiator &&
        existing.state == NoiseSessionState.handshaking &&
        data.length == 32) {
      final weWin = identity.peerID.compareTo(peerID) > 0;
      if (weWin) {
        // Ignore their message 1; they will accept our in-flight message 1.
        return null;
      }
      // Yield: drop our initiator attempt and answer as responder.
      _sessions.remove(peerID);
    }

    final s = _sessions[peerID] ??
        NoiseSession(
          peerID: peerID,
          isInitiator: false,
          staticPrivate: identity.staticPrivate,
          staticPublic: identity.staticPublic,
        );
    _sessions[peerID] = s;

    final response = await s.processHandshakeMessage(data);

    // Bind the established session to the claimed peerID: the remote static key
    // must hash to the peerID we've been talking to, or we drop the session.
    if (s.isEstablished) {
      final remoteKey = s.remoteStaticPublicKey;
      if (remoteKey == null ||
          !NoiseIdentity.matchesClaimedPeerID(peerID, remoteKey)) {
        _sessions.remove(peerID);
        throw StateError('Noise peerID binding failed for $peerID');
      }
    }
    return response;
  }

  /// True once [handleHandshake]/[initiateHandshake] produced an established
  /// session bound to [peerID].
  Uint8List? remoteStaticKey(String peerID) =>
      _sessions[peerID]?.remoteStaticPublicKey;

  Future<Uint8List> encrypt(String peerID, Uint8List plaintext) {
    final s = _sessions[peerID];
    if (s == null || !s.isEstablished) {
      throw StateError('No established session for $peerID');
    }
    return s.encrypt(plaintext);
  }

  Future<Uint8List> decrypt(String peerID, Uint8List payload) {
    final s = _sessions[peerID];
    if (s == null || !s.isEstablished) {
      throw StateError('No established session for $peerID');
    }
    return s.decrypt(payload);
  }

  void clear() => _sessions.clear();
}
