// prekey_bundle.dart - PREKEY_BUNDLE (0x24): forward secrecy for carried mail.
//
// A courier envelope is sealed to the recipient's long-lived Noise static key,
// because that is the only key a sender has for someone who is not there to
// handshake. The cost is that it is NOT forward secret: whoever later obtains
// that static key can open every envelope they captured in transit.
//
// A prekey bundle removes that. Each device publishes a small batch of one-time
// X25519 public keys, signed by the same Ed25519 key its announce is signed
// with, and lets them spread by gossip sync. A sender seals to ONE of those
// prekeys instead of the static key; the recipient deletes the private half
// once it is used, and the envelope becomes unopenable to everyone, including
// its own recipient's future self.
//
// The signature is what lets a bundle travel. Anyone holding the owner's
// announce-verified signing key can check a bundle offline, so bundles keep
// spreading mesh-wide while the owner is away — which is exactly when their
// mail is being couriered.
//
// A port of bitchat's `PrekeyBundle`.

import 'dart:convert';
import 'dart:typed_data';

/// One unused key, and the id a sealed envelope names it by.
class Prekey {
  const Prekey({required this.id, required this.publicKey});

  final int id;

  /// X25519 public key (32 bytes).
  final Uint8List publicKey;
}

/// A signed batch of one-time prekeys belonging to one device.
class PrekeyBundle {
  const PrekeyBundle({
    required this.noiseStaticPublicKey,
    required this.prekeys,
    required this.generatedAtMs,
    required this.signature,
  });

  /// Whose prekeys these are (32 bytes).
  final Uint8List noiseStaticPublicKey;

  final List<Prekey> prekeys;

  /// When the bundle was made. A newer bundle replaces an older one for the
  /// same device — a peer that has rotated should not keep being sealed to
  /// keys it has already deleted.
  final int generatedAtMs;

  /// Ed25519 over [signableBytes] by the owner's announce-bound signing key.
  final Uint8List signature;

  static const int keyLength = 32;
  static const int signatureLength = 64;
  static const int maxPrekeys = 8;
  static const int _prekeyEntryLength = 4 + keyLength;

  /// Domain separation, so a bundle signature can never be mistaken for an
  /// announce or packet signature.
  static final Uint8List _signingContext =
      Uint8List.fromList(utf8.encode('bitchat-prekey-bundle-v1'));

  /// The canonical bytes the signature covers. Encoders and verifiers must
  /// derive these identically or every bundle looks forged.
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

  /// TLV (type, length16 BE, value): `0x01` owner key, `0x02` packed prekey
  /// entries, `0x03` generatedAt, `0x04` signature. Null when a field is the
  /// wrong shape — an unsignable bundle is worse than none.
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
    // Duplicate ids would let one consumed key shadow another, so a sender
    // could be steered onto a prekey the owner has already thrown away.
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
