import 'dart:typed_data';

import 'package:bech32/bech32.dart' as b32;

import 'keys.dart';

/// NIP-19 bech32 encoding for simple (non-TLV) Nostr entities:
/// `npub` (pubkey), `nsec` (secret key), `note` (event id).
///
/// All three wrap a single 32-byte payload, so they share the 8->5 bit
/// conversion and bech32 framing.

const int _maxLen = 1000; // generous; npub/nsec are ~63 chars.

/// Converts a stream of [from]-bit groups to [to]-bit groups.
/// When [pad] is true, the final group is zero-padded (used for encoding).
List<int> _convertBits(List<int> data, int from, int to, {required bool pad}) {
  var acc = 0;
  var bits = 0;
  final result = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    if (value < 0 || (value >> from) != 0) {
      throw FormatException('Invalid value for bit conversion: $value');
    }
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      result.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) {
      result.add((acc << (to - bits)) & maxv);
    }
  } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
    throw const FormatException('Invalid padding in bit conversion');
  }
  return result;
}

String _encode(String hrp, List<int> data8) {
  final data5 = _convertBits(data8, 8, 5, pad: true);
  return b32.bech32.encode(b32.Bech32(hrp, data5), _maxLen);
}

({String hrp, Uint8List data}) _decode(String input) {
  final decoded = b32.bech32.decode(input, _maxLen);
  final data8 = _convertBits(decoded.data, 5, 8, pad: false);
  return (hrp: decoded.hrp, data: Uint8List.fromList(data8));
}

/// Encodes a 64-char hex x-only pubkey as an `npub`.
String encodeNpub(String hexPubkey) => _encode('npub', hexToBytes(hexPubkey));

/// Decodes an `npub` to its 64-char hex pubkey.
String decodeNpub(String npub) {
  final r = _decode(npub);
  if (r.hrp != 'npub') {
    throw FormatException('Expected npub, got ${r.hrp}');
  }
  return bytesToHex(r.data);
}

/// Encodes a 64-char hex private key as an `nsec`.
String encodeNsec(String hexPrivkey) => _encode('nsec', hexToBytes(hexPrivkey));

/// Encodes raw 32 private-key bytes as an `nsec`.
String encodeNsecBytes(Uint8List privkey) => _encode('nsec', privkey);

/// Decodes an `nsec` to its 32 raw private-key bytes.
Uint8List decodeNsec(String nsec) {
  final r = _decode(nsec);
  if (r.hrp != 'nsec') {
    throw FormatException('Expected nsec, got ${r.hrp}');
  }
  return r.data;
}

/// Encodes a 64-char hex event id as a `note`.
String encodeNote(String hexId) => _encode('note', hexToBytes(hexId));

/// Decodes a `note` to its 64-char hex event id.
String decodeNote(String note) {
  final r = _decode(note);
  if (r.hrp != 'note') {
    throw FormatException('Expected note, got ${r.hrp}');
  }
  return bytesToHex(r.data);
}
