import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/api.dart' show KeyParameter;

import 'keys.dart';

/// bitchat interop transport (matches the PWA `encryptBitchat`/`decryptBitchat`
/// in nym-crypto.js).
///
/// Layout: shared point = secp256k1.getSharedSecret(sk, '02'+recipientPub),
/// i.e. the **33-byte compressed** encoding of `sk * liftEven(recipientPub)`.
/// prk = HKDF-Extract(SHA256, ikm = sharedPoint(33), salt = empty);
/// key = HKDF-Expand(prk, info = utf8('nip44-v2'), 32);
/// XChaCha20-Poly1305 with a 24-byte random nonce;
/// output `v2:<base64url(nonce || ciphertext_with_tag)>`.

final _secp = ECCurve_secp256k1();
final _xchacha = Xchacha20.poly1305Aead();

Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return mac.process(data);
}

Uint8List _hkdfExtract(Uint8List salt, Uint8List ikm) =>
    _hmacSha256(salt, ikm);

Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  const hashLen = 32;
  final n = (length + hashLen - 1) ~/ hashLen;
  final okm = Uint8List(n * hashLen);
  var prev = Uint8List(0);
  var pos = 0;
  for (var i = 1; i <= n; i++) {
    final input = Uint8List(prev.length + info.length + 1)
      ..setRange(0, prev.length, prev)
      ..setRange(prev.length, prev.length + info.length, info)
      ..[prev.length + info.length] = i;
    prev = _hmacSha256(prk, input);
    okm.setRange(pos, pos + hashLen, prev);
    pos += hashLen;
  }
  return okm.sublist(0, length);
}

/// Returns the 33-byte compressed shared point: `sk * liftEven(pubkeyHex)`
/// where [parityPrefix] is '02' or '03' applied to the recipient pubkey before
/// lifting. nostr-tools/noble defaults to lifting with even y ('02').
Uint8List _sharedPointCompressed(
    Uint8List sk, String pubkeyHex, String parityPrefix) {
  final compressed = hexToBytes('$parityPrefix${pubkeyHex.padLeft(64, '0')}');
  final point = _secp.curve.decodePoint(compressed);
  if (point == null) {
    throw FormatException('Invalid public key: $pubkeyHex');
  }
  final d = _bytesToBigInt(sk);
  final shared = (point * d)!;
  // Encode result as compressed (33 bytes) — getEncoded(true).
  return Uint8List.fromList(shared.getEncoded(true));
}

Uint8List _deriveKey(Uint8List sharedPoint) {
  final prk = _hkdfExtract(Uint8List(0), sharedPoint);
  return _hkdfExpand(
    prk,
    Uint8List.fromList(utf8.encode('nip44-v2')),
    32,
  );
}

String _b64UrlNoPad(Uint8List bytes) {
  return base64.encode(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

Uint8List _b64UrlDecode(String s) {
  var t = s.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64.decode(t);
}

/// Encrypts [plaintext] to [recipientPub] using [sk]. Returns a `v2:` payload.
Future<String> encryptBitchat(
    String plaintext, Uint8List sk, String recipientPub) async {
  final sharedPoint = _sharedPointCompressed(sk, recipientPub, '02');
  final key = _deriveKey(sharedPoint);
  final nonce = randomBytes(24);
  final secretBox = await _xchacha.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  // concatenation() => nonce || cipherText || mac, matching JS nonce||ct(+tag).
  final payload = secretBox.concatenation();
  return 'v2:${_b64UrlNoPad(payload)}';
}

/// Decrypts a bitchat `v2:` payload from [senderPub] using [sk]. Tries both the
/// even ('02') and odd ('03') lift of the sender pubkey, matching the PWA.
Future<String> decryptBitchat(
    String content, String senderPub, Uint8List sk) async {
  var c = content;
  if (c.startsWith('v2:')) c = c.substring(3);
  final payload = _b64UrlDecode(c);
  if (payload.length < 24 + 16) {
    throw FormatException('bitchat payload too short');
  }
  final secretBox = SecretBox.fromConcatenation(
    payload,
    nonceLength: 24,
    macLength: 16,
  );
  for (final prefix in const ['02', '03']) {
    try {
      final sharedPoint = _sharedPointCompressed(sk, senderPub, prefix);
      final key = _deriveKey(sharedPoint);
      final clear = await _xchacha.decrypt(
        secretBox,
        secretKey: SecretKey(key),
      );
      return utf8.decode(clear);
    } catch (_) {
      // try next parity
    }
  }
  throw FormatException('bitchat decrypt failed');
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var r = BigInt.zero;
  for (final b in bytes) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

/// A decoded bitchat `bitchat1:` payload (a NoisePayload inside a BitchatPacket).
///
/// [type] is the NoisePayloadType: 0x01 = PRIVATE_MESSAGE, 0x02 = READ_RECEIPT,
/// 0x03 = DELIVERED. For a private message, [content] is the decoded text and
/// [messageId] the bitchat UUID; for receipts, [content] is null and
/// [messageId] identifies the original message.
class BitchatPacket {
  const BitchatPacket({required this.type, this.content, this.messageId});

  final int type;
  final String? content;
  final String? messageId;

  bool get isPrivateMessage => type == privateMessage;

  static const int privateMessage = 0x01;
  static const int readReceipt = 0x02;
  static const int delivered = 0x03;
}

/// True when [content] is a bitchat-app message envelope (`bitchat1:` prefix).
/// The actual text/receipt is extracted with [decodeBitchatPacket]; without it
/// a bitchat PM would render as the raw `bitchat1:…` blob.
bool isBitchatPacket(String content) => content.startsWith('bitchat1:');

/// Decodes a `bitchat1:<base64url>` BitchatPacket into its NoisePayload.
///
/// Mirrors the PWA `parseBitchatMessage` (pms.js): strip the prefix, base64url-
/// decode, read the 14-byte header (version, type, TTL, 8-byte timestamp, flags,
/// 2-byte payload length), skip the 8-byte sender id and optional 8-byte
/// recipient id (HAS_RECIPIENT = flags & 0x01), then read the NoisePayloadType.
///
/// For PRIVATE_MESSAGE the payload is a TLV stream: `[type][len][value]` where
/// a value > 255 bytes sets the high bit of the type byte (0x80) and uses a
/// 2-byte big-endian length. Type 0x00 = MESSAGE_ID, 0x01 = CONTENT. For
/// receipts (type != 0x01) the payload is `[type][raw UUID string]` (or a single
/// `[0x00][len][id]` TLV). Trailing 0xBE padding is stripped before parsing.
///
/// Returns null when [content] is not `bitchat1:` or is too short/malformed.
BitchatPacket? decodeBitchatPacket(String content) {
  if (!isBitchatPacket(content)) return null;
  Uint8List bytes;
  try {
    bytes = _b64UrlDecode(content.substring(9));
  } catch (_) {
    return null;
  }
  // Header(14) + senderId(8) at minimum; payload byte must exist.
  if (bytes.length < 14) return null;
  final flags = bytes[11];
  final hasRecipient = (flags & 0x01) != 0;
  final payloadStart = 14 + 8 + (hasRecipient ? 8 : 0);
  if (payloadStart >= bytes.length) return null;
  final type = bytes[payloadStart];

  // Strip trailing 0xBE padding for bounds checking.
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0xBE) {
    end--;
  }

  if (type != BitchatPacket.privateMessage) {
    // Receipt: [type][raw UUID] or [type][0x00][len][id].
    var pos = payloadStart + 1;
    String? messageId;
    if (pos < end && bytes[pos] == 0x00 && pos + 2 < end) {
      final idLen = bytes[pos + 1];
      if (pos + 2 + idLen <= end) {
        messageId = _tryUtf8(bytes, pos + 2, pos + 2 + idLen);
      }
    } else if (pos < end) {
      final raw = _tryUtf8(bytes, pos, pos + 36 <= end ? pos + 36 : end);
      if (raw != null && _looksLikeUuid(raw)) messageId = raw;
    }
    return BitchatPacket(type: type, content: null, messageId: messageId);
  }

  // PRIVATE_MESSAGE: parse TLV fields after the NoisePayloadType byte.
  var pos = payloadStart + 1;
  String? messageContent;
  String? messageId;
  while (pos < end - 1) {
    final rawType = bytes[pos];
    final fieldType = rawType & 0x7F;
    final isExtended = (rawType & 0x80) != 0;
    int fieldLen;
    int valueStart;
    if (isExtended) {
      if (pos + 3 > end) break;
      fieldLen = (bytes[pos + 1] << 8) | bytes[pos + 2];
      valueStart = pos + 3;
    } else {
      if (pos + 2 > end) break;
      fieldLen = bytes[pos + 1];
      valueStart = pos + 2;
    }
    if (valueStart + fieldLen > end) break;
    if (fieldType == 0x00) {
      messageId = _tryUtf8(bytes, valueStart, valueStart + fieldLen);
    } else if (fieldType == 0x01) {
      messageContent = _tryUtf8(bytes, valueStart, valueStart + fieldLen);
    }
    pos = valueStart + fieldLen;
  }
  return BitchatPacket(
    type: type,
    content: messageContent ?? '',
    messageId: messageId,
  );
}

String? _tryUtf8(Uint8List bytes, int start, int end) {
  if (start < 0 || end > bytes.length || start >= end) return null;
  try {
    return utf8.decode(bytes.sublist(start, end));
  } catch (_) {
    return null;
  }
}

bool _looksLikeUuid(String s) => RegExp(
        r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
        caseSensitive: false)
    .hasMatch(s);

/// Encodes [content] as a bitchat `bitchat1:` PRIVATE_MESSAGE packet — the
/// inverse of [decodeBitchatPacket] and a 1:1 port of the PWA's
/// `encodeBitchatMessage` (nostr-core.js:1024). The returned `content` is an
/// UNENCRYPTED BitchatPacket (base64url); the encryption to the recipient
/// happens in the gift wrap ([bitchatWrap]). `messageId` is a fresh UUID used
/// for bitchat-native delivery/read receipt matching.
///
/// [senderPubkey] / [recipientPubkey] are 64-hex. When [recipientPubkey] is
/// non-empty the HAS_RECIPIENT flag is set and its first 8 bytes ride the
/// header (bitchat routing). [messageId] and [nowMs] are injectable for tests.
({String content, String messageId}) encodeBitchatMessage(
  String content,
  String senderPubkey, {
  String? recipientPubkey,
  String? messageId,
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final msgId = messageId ?? _uuidV4();
  final messageBytes = utf8.encode(content);
  final messageIdBytes = utf8.encode(msgId);

  // TLV fields use a 1-byte length when value <= 255 bytes; longer values set
  // the high bit of the type byte (0x80) and use a 2-byte big-endian length.
  final tlv = <int>[];
  void pushTlv(int type, List<int> value) {
    if (value.length <= 0xFF) {
      tlv
        ..add(type)
        ..add(value.length);
    } else {
      tlv
        ..add(type | 0x80)
        ..add((value.length >> 8) & 0xFF)
        ..add(value.length & 0xFF);
    }
    tlv.addAll(value);
  }

  pushTlv(0x00, messageIdBytes); // MESSAGE_ID
  pushTlv(0x01, messageBytes); // CONTENT

  final noisePayload = <int>[0x01, ...tlv]; // 0x01 = PRIVATE_MESSAGE

  final parts = <int>[
    0x01, // version 1
    0x11, // type = NOISE_ENCRYPTED
    0x07, // TTL 7
  ];

  // Timestamp: 8 bytes big-endian milliseconds.
  final ts = BigInt.from(now);
  for (var i = 7; i >= 0; i--) {
    parts.add(((ts >> (i * 8)) & BigInt.from(0xFF)).toInt());
  }

  final hasRecipient = recipientPubkey != null && recipientPubkey.isNotEmpty;
  parts.add(hasRecipient ? 0x01 : 0x00); // flags: 0x01 = HAS_RECIPIENT

  final payloadLen = noisePayload.length;
  parts
    ..add((payloadLen >> 8) & 0xFF)
    ..add(payloadLen & 0xFF);

  // Sender id: first 8 bytes of our pubkey.
  for (var i = 0; i < 8; i++) {
    parts.add(int.parse(senderPubkey.substring(i * 2, i * 2 + 2), radix: 16));
  }
  // Recipient id: first 8 bytes of their pubkey (when HAS_RECIPIENT).
  if (hasRecipient) {
    for (var i = 0; i < 8; i++) {
      parts.add(
          int.parse(recipientPubkey.substring(i * 2, i * 2 + 2), radix: 16));
    }
  }

  parts.addAll(noisePayload);

  // Pad to the next block size (256/512/1024/2048) with 0xBE.
  const blockSizes = [256, 512, 1024, 2048];
  var target = 2048;
  for (final s in blockSizes) {
    if (s >= parts.length) {
      target = s;
      break;
    }
  }
  while (parts.length < target) {
    parts.add(0xBE);
  }

  return (
    content: 'bitchat1:${_b64UrlNoPad(Uint8List.fromList(parts))}',
    messageId: msgId,
  );
}

/// A random v4 UUID (bitchat message id). Uses [randomBytes] so no extra
/// dependency is pulled into this crypto module.
String _uuidV4() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  String hex(int start, int end) {
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
