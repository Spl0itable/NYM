// bitchat courier envelopes: mail sealed to a recipient and carried by nearby peers; opaque to couriers, tag rotates daily.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Hmac, SecretKey;

import '../noise/noise_crypto.dart';
import '../noise/noise_handshake.dart';

/// One-way courier seal, distinct from the interactive `Noise_XX_…` so transcripts can't be confused.
const String kCourierNoiseProtocolName = 'Noise_X_25519_ChaChaPoly_SHA256';

/// Domain separation for the static-sealed (v1) seal, bitchat's `courierPrologue`.
final Uint8List kCourierPrologue =
    Uint8List.fromList(utf8.encode('bitchat-courier-v1'));

/// Prekey-sealed (v2) prologue bound to [prekeyId], so a ciphertext can't be replayed against another prekey.
Uint8List courierPrekeyPrologue(int prekeyId) {
  final id = Uint8List(4);
  ByteData.view(id.buffer).setUint32(0, prekeyId, Endian.big);
  return Uint8List.fromList([
    ...utf8.encode('bitchat-prekey-v1'),
    ...id,
  ]);
}

final Uint8List _kTagContext =
    Uint8List.fromList(utf8.encode('bitchat-courier-tag-v1'));

class CourierEnvelope {
  CourierEnvelope({
    required this.recipientTag,
    required this.expiryMs,
    required this.ciphertext,
    int copies = 1,
    this.prekeyId,
  }) : copies = copies < 1 ? 1 : (copies > maxCopies ? maxCopies : copies);

  /// 16-byte daily hint `HMAC-SHA256(recipient static key, context || day)`, naming nobody.
  final Uint8List recipientTag;

  /// Milliseconds since epoch after which the envelope must be discarded.
  final int expiryMs;

  final Uint8List ciphertext;

  /// Spray-and-wait copy budget, halved per spray; 1 means carry-only.
  final int copies;

  /// Null for v1 (static-key seal, not forward secret); else the one-time prekey id for v2, an optional TLV.
  final int? prekeyId;

  static const int tagLength = 16;

  /// Couriered mail is text-sized; media is out of scope.
  static const int maxCiphertextBytes = 16 * 1024;

  /// Matches the sender outbox's retention.
  static const int maxLifetimeMs = 24 * 60 * 60 * 1000;

  /// Caps a depositor's claimed budget so the courier network can't be an amplifier.
  static const int maxCopies = 8;

  bool isExpiredAt(int nowMs) => nowMs >= expiryMs;

  CourierEnvelope withCopies(int next) => CourierEnvelope(
        recipientTag: recipientTag,
        expiryMs: expiryMs,
        ciphertext: ciphertext,
        copies: next,
        prekeyId: prekeyId,
      );

  /// TLV (type, len16 BE, value): 0x01 tag, 0x02 expiry, 0x03 ciphertext, 0x04 copies (omitted when 1).
  Uint8List? encode() {
    if (recipientTag.length != tagLength) return null;
    if (ciphertext.isEmpty || ciphertext.length > maxCiphertextBytes) {
      return null;
    }
    final out = BytesBuilder();
    void tlv(int t, List<int> v) {
      out.addByte(t);
      out.addByte((v.length >> 8) & 0xFF);
      out.addByte(v.length & 0xFF);
      out.add(v);
    }

    tlv(0x01, recipientTag);
    final exp = Uint8List(8);
    ByteData.view(exp.buffer).setUint64(0, expiryMs, Endian.big);
    tlv(0x02, exp);
    tlv(0x03, ciphertext);
    if (copies > 1) tlv(0x04, [copies]);
    // Omitted for v1 so it stays byte-identical to the pre-prekey wire form.
    final pk = prekeyId;
    if (pk != null) {
      final id = Uint8List(4);
      ByteData.view(id.buffer).setUint32(0, pk, Endian.big);
      tlv(0x05, id);
    }
    return out.toBytes();
  }

  /// Null for anything malformed; unknown TLVs are skipped for forward compatibility.
  static CourierEnvelope? decode(Uint8List data) {
    var off = 0;
    Uint8List? tag;
    int? expiry;
    Uint8List? ciphertext;
    var copies = 1;
    int? prekeyId;
    while (off < data.length) {
      final t = data[off];
      off += 1;
      if (off + 2 > data.length) return null;
      final len = (data[off] << 8) | data[off + 1];
      off += 2;
      if (off + len > data.length) return null;
      final v = Uint8List.fromList(
          Uint8List.sublistView(data, off, off + len));
      off += len;
      switch (t) {
        case 0x01:
          if (len != tagLength) return null;
          tag = v;
        case 0x02:
          if (len != 8) return null;
          var e = 0;
          for (final b in v) {
            e = (e << 8) | b;
          }
          expiry = e;
        case 0x03:
          if (len == 0 || len > maxCiphertextBytes) return null;
          ciphertext = v;
        case 0x04:
          if (len != 1) return null;
          copies = v[0];
        case 0x05:
          if (len != 4) return null;
          var id = 0;
          for (final b in v) {
            id = (id << 8) | b;
          }
          prekeyId = id;
        default:
        // Forward compatible.
      }
    }
    if (tag == null || expiry == null || ciphertext == null) return null;
    return CourierEnvelope(
      recipientTag: tag,
      expiryMs: expiry,
      ciphertext: ciphertext,
      copies: copies,
      prekeyId: prekeyId,
    );
  }

  /// The UTC day number tags rotate on.
  static int epochDayFor(int nowMs) => nowMs ~/ 86400000;

  /// The day's rotating hint, computable only by someone who knows [noiseStaticKey].
  static Future<Uint8List> recipientTagFor({
    required Uint8List noiseStaticKey,
    required int epochDay,
  }) async {
    final message = BytesBuilder()..add(_kTagContext);
    final day = Uint8List(4);
    ByteData.view(day.buffer).setUint32(0, epochDay, Endian.big);
    message.add(day);
    final mac = await Hmac.sha256()
        .calculateMac(message.toBytes(), secretKey: SecretKey(noiseStaticKey));
    return Uint8List.fromList(mac.bytes.sublist(0, tagLength));
  }

  /// Tags for today and adjacent days, tolerating midnight sealing and clock skew.
  static Future<List<Uint8List>> candidateTagsFor({
    required Uint8List noiseStaticKey,
    required int nowMs,
  }) async {
    final day = epochDayFor(nowMs);
    return [
      for (final d in [day == 0 ? 0 : day - 1, day, day + 1])
        await recipientTagFor(noiseStaticKey: noiseStaticKey, epochDay: d),
    ];
  }
}

/// One-way `Noise_X` seal (`-> e, es, s, ss`): authenticates the sender, but is not forward secret.
class CourierSeal {
  const CourierSeal._();

  /// Seals [payload]; for a v2 [prologue], [recipientStaticKey] is the prekey's public half.
  static Future<Uint8List> seal({
    required Uint8List payload,
    required Uint8List recipientStaticKey,
    required Uint8List senderStaticPrivate,
    required Uint8List senderStaticPublic,
    Uint8List? prologue,
  }) async {
    if (recipientStaticKey.length != NoiseCrypto.dhLen) {
      throw ArgumentError('recipient static key must be 32 bytes');
    }
    final sym = NoiseSymmetricState.initialize(kCourierNoiseProtocolName);
    sym.mixHash(prologue ?? kCourierPrologue);
    // Pre-message: the initiator knows the responder's static key.
    sym.mixHash(recipientStaticKey);

    final out = BytesBuilder();
    final (ePriv, ePub) = await NoiseCrypto.x25519Generate();
    out.add(ePub);
    sym.mixHash(ePub);
    sym.mixKey(await NoiseCrypto.dh(ePriv, recipientStaticKey));
    out.add(await sym.encryptAndHash(senderStaticPublic));
    sym.mixKey(await NoiseCrypto.dh(senderStaticPrivate, recipientStaticKey));
    out.add(await sym.encryptAndHash(payload));
    return out.toBytes();
  }

  /// Opens an envelope, returning plaintext and the authenticated sender key; a throw means not for us.
  static Future<(Uint8List payload, Uint8List senderStaticKey)> open({
    required Uint8List ciphertext,
    required Uint8List localStaticPrivate,
    required Uint8List localStaticPublic,
    Uint8List? prologue,
  }) async {
    // e (32) + encrypted static (32 + 16 tag) + encrypted payload (>= 16 tag).
    if (ciphertext.length < 32 + 48 + 16) {
      throw ArgumentError('courier ciphertext too short');
    }
    final sym = NoiseSymmetricState.initialize(kCourierNoiseProtocolName);
    sym.mixHash(prologue ?? kCourierPrologue);
    // Pre-message: the responder mixes its own static key.
    sym.mixHash(localStaticPublic);

    var off = 0;
    final re = Uint8List.fromList(
        Uint8List.sublistView(ciphertext, off, off + 32));
    off += 32;
    sym.mixHash(re);
    sym.mixKey(await NoiseCrypto.dh(localStaticPrivate, re));
    final encStatic = Uint8List.fromList(
        Uint8List.sublistView(ciphertext, off, off + 48));
    off += 48;
    final rs = await sym.decryptAndHash(encStatic);
    sym.mixKey(await NoiseCrypto.dh(localStaticPrivate, rs));
    final encPayload = Uint8List.fromList(
        Uint8List.sublistView(ciphertext, off, ciphertext.length));
    final payload = await sym.decryptAndHash(encPayload);
    return (payload, rs);
  }
}
