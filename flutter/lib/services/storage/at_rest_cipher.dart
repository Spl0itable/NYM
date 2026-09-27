import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secure_store.dart';

abstract class AtRestKeyStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class SecureAtRestKeyStore implements AtRestKeyStore {
  SecureAtRestKeyStore([SecureStore? store]) : _store = store ?? SecureStore();

  static const String keyName = 'nym_at_rest_key';

  final SecureStore _store;

  @override
  Future<String?> read() => _store.get(keyName);

  @override
  Future<void> write(String value) => _store.set(keyName, value);

  @override
  Future<void> delete() => _store.remove(keyName);
}

class AtRestKeyUnavailable implements Exception {
  const AtRestKeyUnavailable();
}

class AtRestCipher {
  AtRestCipher(this._keys);

  static AtRestCipher instance = AtRestCipher(SecureAtRestKeyStore());

  static const String stringPrefix = 'nymenc:v1:';
  static const List<int> _magic = [78, 89, 77, 69, 78, 67, 1, 0];
  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static final AesGcm _aes = AesGcm.with256bits();

  final AtRestKeyStore _keys;
  Future<SecretKey>? _key;

  static bool isEncryptedBytes(List<int> data) {
    if (data.length < _magic.length + _nonceLength + _macLength) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) return false;
    }
    return true;
  }

  static bool isEncryptedString(String value) => value.startsWith(stringPrefix);

  Future<SecretKey> _loadKey() async {
    final existing = _key;
    if (existing != null) return existing;
    final pending = _readOrCreate();
    _key = pending;
    try {
      return await pending;
    } catch (_) {
      if (identical(_key, pending)) _key = null;
      rethrow;
    }
  }

  Future<SecretKey> _readOrCreate() async {
    try {
      return await _readOrCreateKey();
    } catch (_) {
      throw const AtRestKeyUnavailable();
    }
  }

  Future<SecretKey> _readOrCreateKey() async {
    final stored = await _keys.read();
    if (stored != null && stored.isNotEmpty) {
      final bytes = base64.decode(stored);
      if (bytes.length != 32) {
        throw const FormatException('bad at-rest key');
      }
      return SecretKey(bytes);
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    await _keys.write(base64.encode(bytes));
    return SecretKey(bytes);
  }

  Future<Uint8List> encryptBytes(List<int> plain) async {
    final key = await _loadKey();
    final box = await _aes.encrypt(plain, secretKey: key);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.takeBytes();
  }

  Future<Uint8List> decryptBytes(List<int> sealed) async {
    if (!isEncryptedBytes(sealed)) {
      throw const FormatException('not at-rest ciphertext');
    }
    final key = await _loadKey();
    final nonceEnd = _magic.length + _nonceLength;
    final macStart = sealed.length - _macLength;
    final clear = await _aes.decrypt(
      SecretBox(
        sealed.sublist(nonceEnd, macStart),
        nonce: sealed.sublist(_magic.length, nonceEnd),
        mac: Mac(sealed.sublist(macStart)),
      ),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  }

  Future<String> encryptString(String plain) async =>
      stringPrefix + base64.encode(await encryptBytes(utf8.encode(plain)));

  Future<String> decryptString(String sealed) async {
    if (!isEncryptedString(sealed)) {
      throw const FormatException('not at-rest ciphertext');
    }
    final bytes = base64.decode(sealed.substring(stringPrefix.length));
    return utf8.decode(await decryptBytes(bytes));
  }

  void forgetCachedKey() => _key = null;

  Future<void> destroyKey() async {
    _key = null;
    await _keys.delete();
  }
}
