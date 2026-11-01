import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show compute, kIsWeb, visibleForTesting;

import '../../models/nostr_event.dart';
import 'keys.dart';
import 'schnorr.dart';

/// Minimum PoW bits on every Nymchat channel message; other clients treat it as a Nymchat self-attestation.
const int kNymchatPowFloor = 16;

/// Clamps a stored inbound PoW filter onto the UI options; retired 8/12-bit values lift to 16.
int normalizePowDifficulty(int? raw) {
  final n = raw ?? 0;
  if (n <= 0) return 0; // Disabled.
  if (n <= 16) return 16;
  if (n <= 20) return 20;
  return 24;
}

/// Leading zero bits of the event id [idHex].
int getPow(String idHex) {
  var count = 0;
  for (var i = 0; i < idHex.length; i += 2) {
    final nibblePair = int.parse(idHex.substring(i, i + 2), radix: 16);
    if (nibblePair == 0) {
      count += 8;
      continue;
    }
    count += _clz8(nibblePair);
    break;
  }
  return count;
}

int _clz8(int b) {
  var n = 0;
  for (var mask = 0x80; mask > 0; mask >>= 1) {
    if ((b & mask) != 0) break;
    n++;
  }
  return n;
}

/// NIP-13 proven work: the committed nonce-tag target when the id meets it, else 0.
int validatedPowBits(List<List<String>> tags, String id) {
  for (final t in tags) {
    if (t.isEmpty || t[0] != 'nonce' || t.length < 3) continue;
    final target = int.tryParse(t[2]);
    if (target == null || target <= 0 || target > 256) return 0;
    return getPow(id) >= target ? target : 0;
  }
  return 0;
}

/// Mines a NIP-13 `['nonce', n, difficulty]` tag onto [ev] and signs it with [privkey].
NostrEvent minePow(UnsignedEvent ev, int difficulty, Uint8List privkey) {
  final pubkey = getPublicKeyHex(privkey);

  final tags = <List<String>>[
    for (final t in ev.tags)
      if (t.isEmpty || t[0] != 'nonce') List<String>.from(t),
  ];
  final nonceIndex = tags.length;
  tags.add(['nonce', '0', '$difficulty']);

  if (difficulty <= 0) {
    final event = NostrEvent(
      pubkey: pubkey,
      createdAt: ev.createdAt,
      kind: ev.kind,
      tags: tags,
      content: ev.content,
    );
    event.id = event.computeId();
    event.sig = signId(event.id, privkey);
    return event;
  }

  var nonce = 0;
  while (true) {
    tags[nonceIndex] = ['nonce', '$nonce', '$difficulty'];
    final event = NostrEvent(
      pubkey: pubkey,
      createdAt: ev.createdAt,
      kind: ev.kind,
      tags: tags,
      content: ev.content,
    );
    final id = event.computeId();
    if (getPow(id) >= difficulty) {
      event.id = id;
      event.sig = signId(id, privkey);
      return event;
    }
    nonce++;
  }
}

/// Grinds a NIP-13 nonce in a `compute` isolate without the private key, so remote signers can use it.
Future<UnsignedEvent> mineNonce(UnsignedEvent ev, int difficulty,
    {int? lanes, bool Function()? abort}) async {
  if (difficulty <= 0) return ev;
  final args = <String, Object?>{
    'pubkey': ev.pubkey,
    'createdAt': ev.createdAt,
    'kind': ev.kind,
    'tags': ev.tags,
    'content': ev.content,
    'difficulty': difficulty,
  };
  final width = lanes ?? powLanes();
  const chunk = 1 << 18;
  var next = 0;
  final found = Completer<List<List<String>>>();
  Future<void> lane() async {
    while (!found.isCompleted) {
      if (abort != null && abort()) {
        if (!found.isCompleted) found.completeError(StateError('mine aborted'));
        return;
      }
      final start = next;
      next += chunk;
      final hit = await compute(_powGrindRange, <String, Object?>{
        ...args,
        'start': start,
        'count': chunk,
      });
      if (hit != null && !found.isCompleted) found.complete(hit);
    }
  }

  for (var i = 0; i < width; i++) {
    unawaited(lane().catchError((Object e, StackTrace st) {
      if (!found.isCompleted) found.completeError(e, st);
    }));
  }
  final tags = await found.future;
  return UnsignedEvent(
    pubkey: ev.pubkey,
    createdAt: ev.createdAt,
    kind: ev.kind,
    tags: tags,
    content: ev.content,
  );
}

int powLanes() {
  if (kIsWeb) return 1;
  final spare = Platform.numberOfProcessors - 1;
  return spare < 1 ? 1 : (spare > 4 ? 4 : spare);
}

List<List<String>>? _powGrindRange(Map<String, Object?> args) {
  final base =
      (args['tags'] as List).map((t) => (t as List).cast<String>()).toList();
  return powGrindRange(
    pubkey: args['pubkey'] as String,
    createdAt: args['createdAt'] as int,
    kind: args['kind'] as int,
    tags: base,
    content: args['content'] as String,
    difficulty: args['difficulty'] as int,
    start: args['start'] as int,
    count: args['count'] as int,
  );
}

const String _powMark = 'nympowmark7f3a91';

@visibleForTesting
int powGrindsHere = 0;

List<List<String>>? powGrindRange({
  required String pubkey,
  required int createdAt,
  required int kind,
  required List<List<String>> tags,
  required String content,
  required int difficulty,
  required int start,
  required int count,
}) {
  powGrindsHere++;
  final out = <List<String>>[
    for (final t in tags)
      if (t.isEmpty || t[0] != 'nonce') List<String>.from(t),
  ];
  final nonceIndex = out.length;
  out.add(['nonce', _powMark, '$difficulty']);
  final ser = jsonEncode([0, pubkey, createdAt, kind, out, content]);
  final at = ser.indexOf(_powMark);
  _Midstate? plan;
  if (at >= 0 && ser.indexOf(_powMark, at + 1) < 0) {
    plan = _Midstate(utf8.encode(ser.substring(0, at)),
        utf8.encode(ser.substring(at + _powMark.length)));
  }
  final end = start + count;
  for (var n = start; n < end; n++) {
    final digits = '$n';
    if (plan != null && plan.zeroBits(digits) < difficulty) continue;
    out[nonceIndex] = ['nonce', digits, '$difficulty'];
    final id = NostrEvent(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: out,
      content: content,
    ).computeId();
    if (getPow(id) >= difficulty) {
      return [for (final t in out) List<String>.from(t)];
    }
    plan = null;
  }
  return null;
}

const List<int> _k256 = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

class _Midstate {
  _Midstate(List<int> prefix, List<int> tail)
      : _prefixLen = prefix.length,
        _tail = Uint8List.fromList(tail) {
    final full = prefix.length - prefix.length % 64;
    final bytes = Uint8List.fromList(prefix);
    for (var off = 0; off < full; off += 64) {
      _compress(_mid, bytes, off);
    }
    _rest = Uint8List.sublistView(bytes, full);
    _buf = Uint8List(_rest.length + 24 + _tail.length + 72);
    _buf.setRange(0, _rest.length, _rest);
  }

  final int _prefixLen;
  final Uint8List _tail;
  late final Uint8List _rest;
  late final Uint8List _buf;
  final Uint32List _mid = Uint32List.fromList(const [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final Uint32List _h = Uint32List(8);
  final Uint32List _w = Uint32List(64);

  int zeroBits(String digits) {
    var p = _rest.length;
    for (var i = 0; i < digits.length; i++) {
      _buf[p++] = digits.codeUnitAt(i);
    }
    _buf.setRange(p, p + _tail.length, _tail);
    p += _tail.length;
    final bitLen = (_prefixLen + digits.length + _tail.length) * 8;
    _buf[p++] = 0x80;
    while (p % 64 != 56) {
      _buf[p++] = 0;
    }
    for (var i = 7; i >= 0; i--) {
      _buf[p++] = (bitLen >> (i * 8)) & 0xff;
    }
    _h.setAll(0, _mid);
    for (var off = 0; off < p; off += 64) {
      _compress(_h, _buf, off);
    }
    var bits = 0;
    for (var i = 0; i < 8; i++) {
      final v = _h[i];
      if (v == 0) {
        bits += 32;
        continue;
      }
      return bits + 32 - v.bitLength;
    }
    return bits;
  }

  void _compress(Uint32List h, Uint8List b, int off) {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      w[i] = (b[j] << 24) | (b[j + 1] << 16) | (b[j + 2] << 8) | b[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var a = h[0], bb = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & 0xffffffff & g);
      final t1 = (hh + s1 + ch + _k256[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & bb) ^ (a & c) ^ (bb & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = bb;
      bb = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] += a;
    h[1] += bb;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }

  static int _rotr(int x, int n) =>
      ((x >> n) | (x << (32 - n))) & 0xffffffff;
}

/// True when the id and the committed `nonce` target both meet [minDifficulty].
bool validatePow(NostrEvent ev, int minDifficulty) {
  if (ev.id.length != 64) return false;
  if (getPow(ev.id) < minDifficulty) return false;
  // The committed target must also meet the requirement, so accidental zeros don't count (NIP-13).
  for (final t in ev.tags) {
    if (t.isNotEmpty && t[0] == 'nonce' && t.length >= 3) {
      final committed = int.tryParse(t[2]);
      if (committed == null || committed < minDifficulty) return false;
      return true;
    }
  }
  // No commitment tag: the raw leading-zero check already passed.
  return true;
}
