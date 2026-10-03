import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class OnceSecret {
  const OnceSecret({required this.onceId, required this.key, required this.nonce});

  final String onceId;
  final String key;
  final String nonce;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String randomHex(int n, [Random? rng]) {
  final r = rng ?? Random.secure();
  return bytesToHex(List<int>.generate(n, (_) => r.nextInt(256)));
}

OnceSecret newOnceSecret([Random? rng]) => OnceSecret(
      onceId: randomHex(8, rng),
      key: randomHex(32, rng),
      nonce: randomHex(12, rng),
    );

final AesGcm _aes = AesGcm.with256bits();

Future<Uint8List> encryptOnce(
    List<int> bytes, String keyHex, String nonceHex) async {
  final box = await _aes.encrypt(
    bytes,
    secretKey: SecretKey(hexToBytes(keyHex)),
    nonce: hexToBytes(nonceHex),
  );
  final out = BytesBuilder(copy: false)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return out.toBytes();
}

Future<Uint8List> decryptOnce(
    List<int> bytes, String keyHex, String nonceHex) async {
  if (bytes.length < 16) throw const FormatException('too short');
  final body = bytes.sublist(0, bytes.length - 16);
  final mac = Mac(bytes.sublist(bytes.length - 16));
  final clear = await _aes.decrypt(
    SecretBox(body, nonce: hexToBytes(nonceHex), mac: mac),
    secretKey: SecretKey(hexToBytes(keyHex)),
  );
  return Uint8List.fromList(clear);
}
