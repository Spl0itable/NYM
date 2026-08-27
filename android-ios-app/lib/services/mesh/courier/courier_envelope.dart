// courier_envelope.dart - Store-and-forward envelopes carried by other peers.
//
// A DM to someone who is not in radio range has nowhere to go. The sender's
// outbox will publish it to Nostr when the internet returns, but with no
// internet on either side that never happens — and the message waits forever
// for a radio encounter that may never occur.
//
// A courier envelope is the other answer: seal the message to the recipient's
// Noise static key and hand the sealed copy to peers who are nearby NOW, who
// carry it and deliver it if they meet the recipient. Physical mail, over a
// crowd. bitchat's `CourierEnvelope` + `sealCourierPayload`, wire-for-wire, so
// a bitchat device carries our mail and we carry theirs.
//
// Two properties do the work:
//
//  * The envelope is OPAQUE to the courier. The only routing information is a
//    recipient tag that ROTATES DAILY and is computable only by someone who
//    already knows the recipient's static key — so envelopes to the same peer
//    on different days do not correlate for an observer who does not.
//  * The seal is a one-way `Noise_X_25519_ChaChaPoly_SHA256` handshake message.
//    The sender's identity rides inside it, authenticated by the `ss` DH, so
//    the recipient learns who wrote it while the courier learns nothing.
//
// The cost, which is real and deliberate: handing an envelope to a courier
// tells that courier a message for SOMEBODY exists and that we are the one
// sending it. Never the content, never the recipient — but the fact. That is
// why depositing is gated (see `courier_store.dart`) and why a ghost-mode
// conversation never deposits at all: the whole point of a ghost identity is
// that nothing links it to the real one, and asking a stranger to carry mail
// for you is a link.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Hmac, SecretKey;

import '../noise/noise_crypto.dart';
import '../noise/noise_handshake.dart';

/// The Noise protocol name for the one-way courier seal. Distinct from the
/// interactive `Noise_XX_…` our sessions use, so an X transcript can never be
/// confused with an XX one.
const String kCourierNoiseProtocolName = 'Noise_X_25519_ChaChaPoly_SHA256';

/// Domain separation for the static-sealed (v1) seal — bitchat's
/// `courierPrologue`.
final Uint8List kCourierPrologue =
    Uint8List.fromList(utf8.encode('bitchat-courier-v1'));

/// Domain separation for a PREKEY-sealed (v2) envelope. Distinct from both the
/// interactive XX transcripts and the static-sealed courier prologue, and bound
/// to the specific prekey id — so a ciphertext cannot be replayed against a
/// different prekey than the one it was sealed to.
Uint8List courierPrekeyPrologue(int prekeyId) {
  final id = Uint8List(4);
  ByteData.view(id.buffer).setUint32(0, prekeyId, Endian.big);
  return Uint8List.fromList([
    ...utf8.encode('bitchat-prekey-v1'),
    ...id,
  ]);
}

/// Domain separation for the rotating recipient tag.
final Uint8List _kTagContext =
    Uint8List.fromList(utf8.encode('bitchat-courier-tag-v1'));

/// A sealed message in transit, carried by a peer who cannot read it.
class CourierEnvelope {
  CourierEnvelope({
    required this.recipientTag,
    required this.expiryMs,
    required this.ciphertext,
    int copies = 1,
    this.prekeyId,
  }) : copies = copies < 1 ? 1 : (copies > maxCopies ? maxCopies : copies);

  /// 16-byte rotating hint: `HMAC-SHA256(recipient static key, context || day)`
  /// truncated. Lets a holder test "is this for me / for someone I just met"
  /// without the envelope naming anybody.
  final Uint8List recipientTag;

  /// Milliseconds since epoch after which the envelope must be discarded.
  final int expiryMs;

  /// The opaque one-way Noise X ciphertext.
  final Uint8List ciphertext;

  /// Spray-and-wait copy budget: how many further couriers this holder may
  /// hand it to. Halved on each spray (binary split), so a message spreads to
  /// a bounded number of carriers rather than the whole mesh. 1 means
  /// carry-only — deliver to the recipient, never re-spray.
  final int copies;

  /// Seal-format discriminator. Null means v1: the ciphertext is one-way Noise
  /// X to the recipient's long-lived STATIC key, and is therefore not forward
  /// secret. A value means v2: sealed to the recipient's one-time prekey with
  /// this id, which they delete after use — so a later compromise of their
  /// identity key cannot open an envelope captured in transit.
  ///
  /// Carried as an optional TLV so a v1 decoder skips it as unknown: an older
  /// client still carries and hands over v2 envelopes opaquely, and when one is
  /// addressed to it the static-key open simply fails and it is dropped
  /// quietly.
  final int? prekeyId;

  static const int tagLength = 16;

  /// Couriered messages are text-sized; media is out of scope for mail a
  /// stranger carries.
  static const int maxCiphertextBytes = 16 * 1024;

  /// Matches the sender outbox's retention.
  static const int maxLifetimeMs = 24 * 60 * 60 * 1000;

  /// Cap on the budget a depositor can claim, so a malicious envelope cannot
  /// turn the courier network into an amplifier.
  static const int maxCopies = 8;

  bool isExpiredAt(int nowMs) => nowMs >= expiryMs;

  /// The same envelope with a different remaining budget.
  CourierEnvelope withCopies(int next) => CourierEnvelope(
        recipientTag: recipientTag,
        expiryMs: expiryMs,
        ciphertext: ciphertext,
        copies: next,
        prekeyId: prekeyId,
      );

  /// TLV (type, length16 BE, value): `0x01` tag, `0x02` expiry, `0x03`
  /// ciphertext, `0x04` copies. Copies is omitted when 1 so a carry-only
  /// envelope stays byte-identical to the pre-spray wire form.
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
    // Omitted for a v1 static-sealed envelope so it stays byte-identical to
    // the pre-prekey wire form.
    final pk = prekeyId;
    if (pk != null) {
      final id = Uint8List(4);
      ByteData.view(id.buffer).setUint32(0, pk, Endian.big);
      tlv(0x05, id);
    }
    return out.toBytes();
  }

  /// Returns null for anything malformed. An unknown TLV is skipped so a newer
  /// bitchat can extend the envelope without our refusing to carry it.
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

  /// The rotating hint for one day. Computable only by a party that already
  /// knows [noiseStaticKey] — which is exactly the point: a courier holding
  /// the envelope cannot work out who it is for.
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

  /// The tags to test when asking "is this envelope for this peer?".
  ///
  /// Covers the adjacent days as well as today, so an envelope sealed just
  /// before midnight — or under modest clock skew between two phones that have
  /// never synchronised with anything — still matches while it is being
  /// carried.
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

/// The one-way `Noise_X` seal: `-> e, es, s, ss` plus the payload, in a single
/// message. The sender's static key is transmitted ENCRYPTED and authenticated
/// by the `ss` DH, so the recipient learns who wrote the envelope and nobody
/// in between learns anything.
///
/// Deliberately NOT forward secret — that is what makes it usable at all: the
/// sender has no session with an offline peer to derive keys from, only their
/// long-term static key. A later compromise of the recipient's static key
/// exposes envelopes captured in transit, which is why an established session
/// is always preferred when the peer is actually reachable.
class CourierSeal {
  const CourierSeal._();

  /// Seals [payload] to [recipientStaticKey].
  ///
  /// [prologue] selects the seal format: [kCourierPrologue] for a v1 envelope
  /// sealed to the recipient's long-lived static key, or
  /// [courierPrekeyPrologue] for a v2 envelope sealed to a one-time prekey —
  /// in which case [recipientStaticKey] is that PREKEY's public half, not the
  /// identity key.
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
    // e
    final (ePriv, ePub) = await NoiseCrypto.x25519Generate();
    out.add(ePub);
    sym.mixHash(ePub);
    // es
    sym.mixKey(await NoiseCrypto.dh(ePriv, recipientStaticKey));
    // s (encrypted)
    out.add(await sym.encryptAndHash(senderStaticPublic));
    // ss
    sym.mixKey(await NoiseCrypto.dh(senderStaticPrivate, recipientStaticKey));
    // payload
    out.add(await sym.encryptAndHash(payload));
    return out.toBytes();
  }

  /// Opens an envelope addressed to our static key, returning the plaintext and
  /// the sender's AUTHENTICATED static public key.
  ///
  /// Throws when the ciphertext is not ours (or is malformed) — which is the
  /// normal case for a courier testing an envelope it merely carries, so
  /// callers treat a throw as "not for me", never as an error.
  ///
  /// [prologue] must match what the sender used, and for a v2 envelope
  /// [localStaticPrivate]/[localStaticPublic] are the PREKEY's halves rather
  /// than the identity key's.
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
    // Pre-message: the responder mixes its OWN static key.
    sym.mixHash(localStaticPublic);

    var off = 0;
    final re = Uint8List.fromList(
        Uint8List.sublistView(ciphertext, off, off + 32));
    off += 32;
    sym.mixHash(re);
    // es
    sym.mixKey(await NoiseCrypto.dh(localStaticPrivate, re));
    // s
    final encStatic = Uint8List.fromList(
        Uint8List.sublistView(ciphertext, off, off + 48));
    off += 48;
    final rs = await sym.decryptAndHash(encStatic);
    // ss
    sym.mixKey(await NoiseCrypto.dh(localStaticPrivate, rs));
    // payload
    final encPayload = Uint8List.fromList(
        Uint8List.sublistView(ciphertext, off, ciphertext.length));
    final payload = await sym.decryptAndHash(encPayload);
    return (payload, rs);
  }
}
