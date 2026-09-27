import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Password-protected channel (group) encryption for the mesh — a byte-for-byte
/// port of bitchat's `NoiseChannelEncryption`. This is how encrypted group chats
/// work over Bluetooth: members share a channel password, everyone derives the
/// same AES key, and channel broadcasts are sealed with AES-256-GCM. It is
/// independent of the 1:1 Noise sessions.
///
/// * Key: `PBKDF2-HMAC-SHA256(password, salt = utf8(channelName), 100000, 256)`.
/// * Message: `AES-256-GCM`, wire layout `IV(12) ‖ ciphertext ‖ tag(16)`.
class MeshChannelEncryption {
  MeshChannelEncryption();

  static const int pbkdf2Iterations = 100000;
  static const int _ivLength = 12;
  static const int _tagLength = 16;

  static final _aesGcm = AesGcm.with256bits();

  final Map<String, SecretKey> _channelKeys = {};
  final Map<String, String> _channelPasswords = {};

  /// Derives and stores the AES key for [channel] from [password].
  Future<void> setChannelPassword(String channel, String password) async {
    if (password.isEmpty) return;
    _channelKeys[channel] = await deriveKey(password, channel);
    _channelPasswords[channel] = password;
  }

  void removeChannel(String channel) {
    _channelKeys.remove(channel);
    _channelPasswords.remove(channel);
  }

  bool hasKey(String channel) => _channelKeys.containsKey(channel);
  String? passwordFor(String channel) => _channelPasswords[channel];

  /// Derives the 256-bit channel key. Exposed for tests/interop checks.
  static Future<SecretKey> deriveKey(String password, String channel) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: pbkdf2Iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: utf8.encode(channel), // channel name is the salt
    );
  }

  /// Encrypts [message] for [channel] → `IV(12) ‖ ciphertext ‖ tag(16)`.
  Future<Uint8List> encrypt(String channel, String message) async {
    final key = _channelKeys[channel];
    if (key == null) throw StateError('No key for channel $channel');
    final box = await _aesGcm.encrypt(
      utf8.encode(message),
      secretKey: key,
      nonce: _aesGcm.newNonce(),
    );
    final out = Uint8List(
        box.nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.nonce.length, box.nonce);
    out.setRange(box.nonce.length, box.nonce.length + box.cipherText.length,
        box.cipherText);
    out.setRange(
        box.nonce.length + box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Decrypts `IV(12) ‖ ciphertext ‖ tag(16)` for [channel].
  Future<String> decrypt(String channel, Uint8List data) async {
    final key = _channelKeys[channel];
    if (key == null) throw StateError('No key for channel $channel');
    if (data.length < _ivLength + _tagLength) {
      throw ArgumentError('Encrypted channel data too short');
    }
    final iv = Uint8List.sublistView(data, 0, _ivLength);
    final ct = Uint8List.sublistView(data, _ivLength, data.length - _tagLength);
    final mac = Uint8List.sublistView(data, data.length - _tagLength);
    final clear = await _aesGcm.decrypt(
      SecretBox(ct, nonce: iv, mac: Mac(mac)),
      secretKey: key,
    );
    return utf8.decode(clear);
  }
}
