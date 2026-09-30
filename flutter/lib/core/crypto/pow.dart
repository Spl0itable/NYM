import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

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
Future<UnsignedEvent> mineNonce(UnsignedEvent ev, int difficulty) async {
  if (difficulty <= 0) return ev;
  final minedTags = await compute(_powGrind, <String, Object?>{
    'pubkey': ev.pubkey,
    'createdAt': ev.createdAt,
    'kind': ev.kind,
    'tags': ev.tags,
    'content': ev.content,
    'difficulty': difficulty,
  });
  return UnsignedEvent(
    pubkey: ev.pubkey,
    createdAt: ev.createdAt,
    kind: ev.kind,
    tags: minedTags,
    content: ev.content,
  );
}

List<List<String>> _powGrind(Map<String, Object?> args) {
  final pubkey = args['pubkey'] as String;
  final createdAt = args['createdAt'] as int;
  final kind = args['kind'] as int;
  final content = args['content'] as String;
  final difficulty = args['difficulty'] as int;
  final base =
      (args['tags'] as List).map((t) => (t as List).cast<String>()).toList();
  final tags = <List<String>>[
    for (final t in base)
      if (t.isEmpty || t[0] != 'nonce') List<String>.from(t),
  ];
  final nonceIndex = tags.length;
  tags.add(['nonce', '0', '$difficulty']);
  var nonce = 0;
  while (true) {
    tags[nonceIndex] = ['nonce', '$nonce', '$difficulty'];
    final ev = NostrEvent(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    if (getPow(ev.computeId()) >= difficulty) {
      return [for (final t in tags) List<String>.from(t)];
    }
    nonce++;
  }
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
