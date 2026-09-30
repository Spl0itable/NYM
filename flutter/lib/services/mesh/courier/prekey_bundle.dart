// PREKEY_BUNDLE (0x24): signed one-time X25519 prekeys that give couriered mail forward secrecy (bitchat port).

import 'dart:convert';
import 'dart:typed_data';

class Prekey {
  const Prekey({required this.id, required this.publicKey});

  final int id;

  /// X25519 public key (32 bytes).
  final Uint8List publicKey;
}

class PrekeyBundle {
  const PrekeyBundle({
    required this.noiseStaticPublicKey,
    required this.prekeys,
    required this.generatedAtMs,
    required this.signature,
  });

  /// Owner's Noise static key (32 bytes).
  final Uint8List noiseStaticPublicKey;

  final List<Prekey> prekeys;

  /// A newer bundle replaces an older one, so senders stop using deleted keys.
  final int generatedAtMs;

  /// Ed25519 over [signableBytes] by the owner's announce-bound signing key.
  final Uint8List signature;

  static const int keyLength = 32;
  static const int signatureLength = 64;
  static const int maxPrekeys = 8;
  static const int _prekeyEntryLength = 4 + keyLength;

  /// Domain separation from announce and packet signatures.
  static final Uint8List _signingContext =
      Uint8List.fromList(utf8.encode('bitchat-prekey-bundle-v1'));

  /// The canonical signed bytes; encoders and verifiers must derive them identically.
  Uint8List signableBytes() {
    final out = BytesBuilder();
    out.addByte(_signingContext.length > 255 ? 255 : _signingContext.length);
    out.add(_signingContext.length > 255
        ? Uint8List.sublistView(_signingContext, 0, 255)
        : _signingContext);
    out.add(_padded(noiseStaticPublicKey));
    out.addByte(prekeys.length > 255 ? 255 : prekeys.length);
    for (final p in prekeys.take(255)) {
      out.add(_beU32(p.id));
      out.add(_padded(p.publicKey));
    }
    out.add(_beU64(generatedAtMs));
    return out.toBytes();
  }

  /// TLV (type, len16 BE, value) 0x01 owner, 0x02 prekeys, 0x03 generatedAt, 0x04 sig; null if malformed.
  Uint8List? encode() {
    if (noiseStaticPublicKey.length != keyLength) return null;
    if (signature.length != signatureLength) return null;
    if (prekeys.isEmpty || prekeys.length > maxPrekeys) return null;
    if (prekeys.any((p) => p.publicKey.length != keyLength)) return null;

    final entries = BytesBuilder();
    for (final p in prekeys) {
      entries.add(_beU32(p.id));
      entries.add(p.publicKey);
    }

    final out = BytesBuilder();
    void tlv(int t, List<int> v) {
      out.addByte(t);
      out.addByte((v.length >> 8) & 0xFF);
      out.addByte(v.length & 0xFF);
      out.add(v);
    }

    tlv(0x01, noiseStaticPublicKey);
    tlv(0x02, entries.toBytes());
    tlv(0x03, _beU64(generatedAtMs));
    tlv(0x04, signature);
    return out.toBytes();
  }

  static PrekeyBundle? decode(Uint8List data) {
    var off = 0;
    Uint8List? owner;
    List<Prekey>? prekeys;
    int? generatedAt;
    Uint8List? signature;

    while (off < data.length) {
      final t = data[off];
      off += 1;
      if (off + 2 > data.length) return null;
      final len = (data[off] << 8) | data[off + 1];
      off += 2;
      if (off + len > data.length) return null;
      final v = Uint8List.sublistView(data, off, off + len);
      off += len;
      switch (t) {
        case 0x01:
          if (len != keyLength) return null;
          owner = Uint8List.fromList(v);
        case 0x02:
          if (len == 0 || len % _prekeyEntryLength != 0) return null;
          if (len ~/ _prekeyEntryLength > maxPrekeys) return null;
          final parsed = <Prekey>[];
          for (var i = 0; i < len; i += _prekeyEntryLength) {
            var id = 0;
            for (var j = 0; j < 4; j++) {
              id = (id << 8) | v[i + j];
            }
            parsed.add(Prekey(
              id: id,
              publicKey: Uint8List.fromList(
                  Uint8List.sublistView(v, i + 4, i + _prekeyEntryLength)),
            ));
          }
          prekeys = parsed;
        case 0x03:
          if (len != 8) return null;
          var g = 0;
          for (final b in v) {
            g = (g << 8) | b;
          }
          generatedAt = g;
        case 0x04:
          if (len != signatureLength) return null;
          signature = Uint8List.fromList(v);
        default:
        // Unknown TLV: skipped for forward compatibility.
      }
    }
    if (owner == null ||
        prekeys == null ||
        generatedAt == null ||
        signature == null) {
      return null;
    }
    if (prekeys.isEmpty) return null;
    // Duplicate ids could steer a sender onto a prekey the owner already deleted.
    final ids = prekeys.map((p) => p.id).toSet();
    if (ids.length != prekeys.length) return null;
    return PrekeyBundle(
      noiseStaticPublicKey: owner,
      prekeys: prekeys,
      generatedAtMs: generatedAt,
      signature: signature,
    );
  }

  static Uint8List _padded(Uint8List key) {
    if (key.length >= keyLength) {
      return Uint8List.fromList(Uint8List.sublistView(key, 0, keyLength));
    }
    final out = Uint8List(keyLength);
    out.setRange(0, key.length, key);
    return out;
  }

  static Uint8List _beU32(int v) {
    final out = Uint8List(4);
    ByteData.view(out.buffer).setUint32(0, v, Endian.big);
    return out;
  }

  static Uint8List _beU64(int v) {
    final out = Uint8List(8);
    ByteData.view(out.buffer).setUint64(0, v, Endian.big);
    return out;
  }
}
