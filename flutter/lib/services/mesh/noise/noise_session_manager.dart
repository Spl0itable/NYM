import 'dart:typed_data';

import 'noise_identity.dart';
import 'noise_session.dart';

/// One Noise XX session per peer; simultaneous initiation is tie-broken by peerID as in bitchat.
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

  /// Starts a handshake as initiator, replacing any session, and returns message 1.
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

  /// Handles a handshake payload; returns the response to broadcast, or null.
  Future<Uint8List?> handleHandshake(String peerID, Uint8List data) async {
    final existing = _sessions[peerID];

    // Collision: both sides sent message 1; pick a deterministic winner.
    if (existing != null &&
        existing.isInitiator &&
        existing.state == NoiseSessionState.handshaking &&
        data.length == 32) {
      final weWin = identity.peerID.compareTo(peerID) > 0;
      if (weWin) {
        // Ignore their message 1; they will accept ours.
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

    // The remote static key must hash to the claimed peerID, or the session is dropped.
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
