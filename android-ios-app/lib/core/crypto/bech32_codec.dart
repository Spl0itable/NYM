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

/// Pulls the pubkey out of an `nprofile`. Unlike npub/nsec/note, nprofile wraps
/// a TLV payload — a run of (type, length, value) records — where type 0 is the
/// 32-byte pubkey and the rest are relay hints we don't need here. Supported so
/// that anywhere the app accepts a public key, a pasted nprofile works too.
String decodeNprofilePubkey(String nprofile) {
  final r = _decode(nprofile);
  if (r.hrp != 'nprofile') {
    throw FormatException('Expected nprofile, got ${r.hrp}');
  }
  final data = r.data;
  var i = 0;
  while (i + 2 <= data.length) {
    final type = data[i];
    final len = data[i + 1];
    final start = i + 2;
    if (start + len > data.length) break;
    if (type == 0) {
      if (len != 32) {
        throw const FormatException('nprofile pubkey must be 32 bytes');
      }
      return bytesToHex(data.sublist(start, start + len));
    }
    i = start + len;
  }
  throw const FormatException('nprofile has no pubkey record');
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

/// HRP for a post-quantum root secret (PQ-ROOT-SPEC §1), matching the PWA's
/// `nip19.encodeBytes('nympq', bytes)`.
const String nymPqHrp = 'nympq';

/// Encodes a 32-byte post-quantum root secret as `nympq1…`.
String encodeNymPq(Uint8List root) => _encode(nymPqHrp, root);

/// Decodes a `nympq1…` string. Throws on a wrong HRP or checksum failure.
Uint8List decodeNymPq(String code) {
  final r = _decode(code.trim());
  if (r.hrp != nymPqHrp) {
    throw FormatException('Expected $nymPqHrp, got ${r.hrp}');
  }
  return r.data;
}

/// What a NIP-19 reference points at, once decoded.
enum NostrRefKind { event, profile, addr }

/// A decoded NIP-19 reference (or a bare 64-hex event id).
class NostrRef {
  const NostrRef({
    required this.kind,
    this.id = '',
    this.pubkey = '',
    this.eventKind,
    this.identifier = '',
    this.relays = const [],
  });

  final NostrRefKind kind;

  /// Event id, for [NostrRefKind.event].
  final String id;

  /// Author (nevent), subject (npub/nprofile) or addressable author (naddr).
  final String pubkey;

  /// Event kind, when the reference carries one (nevent's optional hint, or
  /// naddr's required one).
  final int? eventKind;

  /// naddr's `d` tag.
  final String identifier;

  /// Relay hints the reference travelled with.
  final List<String> relays;

  /// The cache/lookup identity of this reference.
  String get key => switch (kind) {
        NostrRefKind.event => 'e:$id',
        NostrRefKind.profile => 'p:$pubkey',
        NostrRefKind.addr => 'a:$eventKind:$pubkey:$identifier',
      };
}

/// Walks a NIP-19 TLV payload into (type, value) records.
List<({int type, Uint8List value})> _tlv(Uint8List data) {
  final out = <({int type, Uint8List value})>[];
  var i = 0;
  while (i + 2 <= data.length) {
    final type = data[i];
    final len = data[i + 1];
    final start = i + 2;
    if (start + len > data.length) break;
    out.add((type: type, value: data.sublist(start, start + len)));
    i = start + len;
  }
  return out;
}

int _int32(Uint8List b) {
  var v = 0;
  for (final byte in b) {
    v = (v << 8) | byte;
  }
  return v;
}

/// Decodes any NIP-19 entity this app renders a card for — `nevent`, `note`,
/// `naddr`, `npub`, `nprofile` — plus a bare 64-hex event id. Returns null for
/// anything else (an `nsec` included: a secret key is never a reference).
NostrRef? decodeNostrRef(String token) {
  var raw = token.trim();
  if (raw.toLowerCase().startsWith('nostr:')) raw = raw.substring(6);
  if (raw.isEmpty) return null;
  if (RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(raw)) {
    return NostrRef(kind: NostrRefKind.event, id: raw.toLowerCase());
  }
  ({String hrp, Uint8List data}) r;
  try {
    r = _decode(raw);
  } catch (_) {
    return null;
  }
  try {
    switch (r.hrp) {
      case 'note':
        if (r.data.length != 32) return null;
        return NostrRef(kind: NostrRefKind.event, id: bytesToHex(r.data));
      case 'npub':
        if (r.data.length != 32) return null;
        return NostrRef(kind: NostrRefKind.profile, pubkey: bytesToHex(r.data));
      case 'nevent':
        var id = '';
        var author = '';
        int? kind;
        final relays = <String>[];
        for (final rec in _tlv(r.data)) {
          switch (rec.type) {
            case 0 when rec.value.length == 32:
              id = bytesToHex(rec.value);
            case 1:
              relays.add(String.fromCharCodes(rec.value));
            case 2 when rec.value.length == 32:
              author = bytesToHex(rec.value);
            case 3 when rec.value.length == 4:
              kind = _int32(rec.value);
          }
        }
        if (id.isEmpty) return null;
        return NostrRef(
            kind: NostrRefKind.event,
            id: id,
            pubkey: author,
            eventKind: kind,
            relays: relays);
      case 'nprofile':
        var pubkey = '';
        final relays = <String>[];
        for (final rec in _tlv(r.data)) {
          if (rec.type == 0 && rec.value.length == 32) {
            pubkey = bytesToHex(rec.value);
          } else if (rec.type == 1) {
            relays.add(String.fromCharCodes(rec.value));
          }
        }
        if (pubkey.isEmpty) return null;
        return NostrRef(
            kind: NostrRefKind.profile, pubkey: pubkey, relays: relays);
      case 'naddr':
        var identifier = '';
        var pubkey = '';
        int? kind;
        final relays = <String>[];
        for (final rec in _tlv(r.data)) {
          switch (rec.type) {
            case 0:
              identifier = String.fromCharCodes(rec.value);
            case 1:
              relays.add(String.fromCharCodes(rec.value));
            case 2 when rec.value.length == 32:
              pubkey = bytesToHex(rec.value);
            case 3 when rec.value.length == 4:
              kind = _int32(rec.value);
          }
        }
        if (pubkey.isEmpty || kind == null) return null;
        return NostrRef(
            kind: NostrRefKind.addr,
            pubkey: pubkey,
            eventKind: kind,
            identifier: identifier,
            relays: relays);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

/// Encodes an `nevent`: TLV 0 = 32-byte event id, TLV 1 = each relay hint,
/// TLV 2 = author pubkey. Returns the bare hex id if [hexId] is not one.
String encodeNevent(String hexId,
    {String author = '', List<String> relays = const []}) {
  if (!RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(hexId)) {
    return '';
  }
  final data = <int>[];
  void tlv(int type, List<int> value) {
    data
      ..add(type)
      ..add(value.length)
      ..addAll(value);
  }

  tlv(0, hexToBytes(hexId.toLowerCase()));
  for (final relay in relays.take(3)) {
    tlv(1, relay.codeUnits);
  }
  if (RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(author)) {
    tlv(2, hexToBytes(author.toLowerCase()));
  }
  return _encode('nevent', data);
}
