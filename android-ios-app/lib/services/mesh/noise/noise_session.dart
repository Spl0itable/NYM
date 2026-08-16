import 'dart:typed_data';

import 'noise_handshake.dart';

/// Lifecycle state of a [NoiseSession].
enum NoiseSessionState { uninitialized, handshaking, established, failed }

/// A single Noise `XX` session with one peer: it drives the three-message
/// handshake and then provides authenticated transport encryption.
///
/// Transport framing matches bitchat exactly: each encrypted message is
/// `<4-byte big-endian counter><ciphertext||tag>`, and the receiver validates
/// the counter against a 1024-entry sliding replay window before decrypting.
class NoiseSession {
  NoiseSession({
    required this.peerID,
    required this.isInitiator,
    required Uint8List staticPrivate,
    required Uint8List staticPublic,
  })  : _staticPrivate = staticPrivate,
        _staticPublic = staticPublic;

  final String peerID;
  final bool isInitiator;
  final Uint8List _staticPrivate;
  final Uint8List _staticPublic;

  static const int _nonceSizeBytes = 4;
  static const int _replayWindowSize = 1024;
  static const int _replayWindowBytes = _replayWindowSize ~/ 8;
  static const int _uint32Max = 0xFFFFFFFF;

  NoiseHandshakeState? _handshake;
  NoiseCipherState? _sendCipher;
  NoiseCipherState? _receiveCipher;
  Uint8List? _remoteStaticPublicKey;
  Uint8List? _handshakeHash;

  NoiseSessionState _state = NoiseSessionState.uninitialized;
  int _messagesSent = 0;
  int _highestReceivedNonce = 0;
  Uint8List _replayWindow = Uint8List(_replayWindowBytes);

  final DateTime _createdAt = DateTime.now();

  NoiseSessionState get state => _state;
  bool get isEstablished => _state == NoiseSessionState.established;
  Uint8List? get remoteStaticPublicKey => _remoteStaticPublicKey;
  Uint8List? get handshakeHash => _handshakeHash;
  DateTime get createdAt => _createdAt;

  /// Starts the handshake as initiator and returns the first message (`-> e`).
  Future<Uint8List> startHandshake() async {
    if (!isInitiator) {
      throw StateError('Only the initiator can start a handshake');
    }
    if (_state != NoiseSessionState.uninitialized) {
      throw StateError('Handshake already started');
    }
    _handshake = NoiseHandshakeState.xx(
      initiator: true,
      staticPrivate: _staticPrivate,
      staticPublic: _staticPublic,
    );
    _state = NoiseSessionState.handshaking;
    return _handshake!.writeMessage();
  }

  /// Processes an incoming handshake message. Returns the response to send back,
  /// or null when no response is required (handshake complete on our side).
  Future<Uint8List?> processHandshakeMessage(Uint8List message) async {
    try {
      if (_state == NoiseSessionState.uninitialized && !isInitiator) {
        _handshake = NoiseHandshakeState.xx(
          initiator: false,
          staticPrivate: _staticPrivate,
          staticPublic: _staticPublic,
        );
        _state = NoiseSessionState.handshaking;
      }
      if (_state != NoiseSessionState.handshaking) {
        throw StateError('Invalid state for handshake: $_state');
      }
      final hs = _handshake!;
      await hs.readMessage(message);

      if (hs.isComplete) {
        _completeHandshake();
        return null;
      }

      final response = await hs.writeMessage();
      if (hs.isComplete) {
        _completeHandshake();
      }
      return response;
    } catch (e) {
      _state = NoiseSessionState.failed;
      rethrow;
    }
  }

  void _completeHandshake() {
    final hs = _handshake!;
    _remoteStaticPublicKey = hs.remoteStaticPublicKey;
    _handshakeHash = hs.handshakeHash;
    final (c1, c2) = hs.split();
    // Initiator sends on c1 / receives on c2; responder is mirrored.
    _sendCipher = isInitiator ? c1 : c2;
    _receiveCipher = isInitiator ? c2 : c1;
    _messagesSent = 0;
    _highestReceivedNonce = 0;
    _replayWindow = Uint8List(_replayWindowBytes);
    _handshake = null;
    _state = NoiseSessionState.established;
  }

  /// Encrypts a transport [data] frame: `<4-byte BE counter><ciphertext>`.
  Future<Uint8List> encrypt(Uint8List data) async {
    if (!isEstablished || _sendCipher == null) {
      throw StateError('Session not established');
    }
    if (_messagesSent >= _uint32Max) {
      throw StateError('Nonce exhausted; rekey required');
    }
    final nonce = _messagesSent;
    _sendCipher!.setNonce(nonce);
    final ciphertext = await _sendCipher!.encryptWithAd(Uint8List(0), data);
    _messagesSent++;
    final out = Uint8List(_nonceSizeBytes + ciphertext.length);
    _writeBe32(out, 0, nonce);
    out.setRange(_nonceSizeBytes, out.length, ciphertext);
    return out;
  }

  /// Decrypts a transport frame produced by [encrypt] on the peer.
  Future<Uint8List> decrypt(Uint8List payload) async {
    if (!isEstablished || _receiveCipher == null) {
      throw StateError('Session not established');
    }
    if (payload.length < _nonceSizeBytes) {
      throw ArgumentError('Transport frame too small');
    }
    final nonce = _readBe32(payload, 0);
    final ciphertext =
        Uint8List.sublistView(payload, _nonceSizeBytes, payload.length);
    if (!_isValidNonce(nonce)) {
      throw StateError('Replay detected: nonce $nonce rejected');
    }
    _receiveCipher!.setNonce(nonce);
    final plaintext = await _receiveCipher!
        .decryptWithAd(Uint8List(0), Uint8List.fromList(ciphertext));
    _markNonceAsSeen(nonce);
    return plaintext;
  }

  bool needsRekey({
    Duration timeLimit = const Duration(hours: 1),
    int messageLimit = 10000,
  }) {
    if (!isEstablished) return false;
    final overTime = DateTime.now().difference(_createdAt) > timeLimit;
    final overCount = _messagesSent > messageLimit;
    return overTime || overCount;
  }

  // ---- Sliding-window replay protection (bitchat-compatible) ----------------

  bool _isValidNonce(int nonce) {
    if (nonce + _replayWindowSize <= _highestReceivedNonce) return false;
    if (nonce > _highestReceivedNonce) return true;
    final offset = _highestReceivedNonce - nonce;
    final byteIndex = offset ~/ 8;
    final bitIndex = offset % 8;
    return (_replayWindow[byteIndex] & (1 << bitIndex)) == 0;
  }

  void _markNonceAsSeen(int nonce) {
    if (nonce > _highestReceivedNonce) {
      final shift = nonce - _highestReceivedNonce;
      if (shift >= _replayWindowSize) {
        _replayWindow = Uint8List(_replayWindowBytes);
      } else {
        final next = Uint8List(_replayWindowBytes);
        for (var i = _replayWindowBytes - 1; i >= 0; i--) {
          final sourceByteIndex = i - shift ~/ 8;
          var newByte = 0;
          if (sourceByteIndex >= 0) {
            newByte = (_replayWindow[sourceByteIndex] & 0xFF) >> (shift % 8);
            if (sourceByteIndex > 0 && shift % 8 != 0) {
              newByte |= (_replayWindow[sourceByteIndex - 1] & 0xFF) <<
                  (8 - shift % 8);
            }
          }
          next[i] = newByte & 0xFF;
        }
        _replayWindow = next;
      }
      _highestReceivedNonce = nonce;
      _replayWindow[0] = _replayWindow[0] | 1;
    } else {
      final offset = _highestReceivedNonce - nonce;
      final byteIndex = offset ~/ 8;
      final bitIndex = offset % 8;
      _replayWindow[byteIndex] = _replayWindow[byteIndex] | (1 << bitIndex);
    }
  }

  static void _writeBe32(Uint8List out, int off, int value) {
    out[off] = (value >> 24) & 0xFF;
    out[off + 1] = (value >> 16) & 0xFF;
    out[off + 2] = (value >> 8) & 0xFF;
    out[off + 3] = value & 0xFF;
  }

  static int _readBe32(Uint8List data, int off) {
    return ((data[off] & 0xFF) << 24) |
        ((data[off + 1] & 0xFF) << 16) |
        ((data[off + 2] & 0xFF) << 8) |
        (data[off + 3] & 0xFF);
  }
}
