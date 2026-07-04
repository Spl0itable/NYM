import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../../models/nostr_event.dart';
import 'keys.dart';
import 'schnorr.dart';

/// NIP-13 proof of work.

/// The Nymchat channel-message PoW floor in leading-zero bits (`nymchatPowFloor`,
/// app.js:556). Every channel message carries at least this much work, which is
/// what lets other clients treat the sender as a Nymchat client (the web-of-trust
/// self-attestation) and gate un-attested spam.
const int kNymchatPowFloor = 16;

/// Counts the number of leading zero bits in the 32-byte event id [idHex].
int getPow(String idHex) {
  var count = 0;
  for (var i = 0; i < idHex.length; i += 2) {
    final nibblePair = int.parse(idHex.substring(i, i + 2), radix: 16);
    if (nibblePair == 0) {
      count += 8;
      continue;
    }
    // Leading zeros within this byte.
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

/// Mines a `['nonce', n, difficulty]` tag onto [ev], incrementing the nonce
/// until the event id has at least [difficulty] leading zero bits, then
/// finalizes (signs) the event with [privkey].
///
/// Mirrors nym-crypto.js `minePow`: a `nonce` tag is appended (or replaced),
/// the second element grinds, the third holds the target difficulty as a
/// commitment.
NostrEvent minePow(UnsignedEvent ev, int difficulty, Uint8List privkey) {
  final pubkey = getPublicKeyHex(privkey);

  // Copy tags, dropping any existing nonce tag, then append a fresh one.
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

/// Grinds a `['nonce', n, difficulty]` tag onto [ev] until its id has at least
/// [difficulty] leading zero bits, returning the UnsignedEvent ready to sign.
/// Unlike [minePow] this does NOT need the private key — it grinds purely from
/// the event's own [UnsignedEvent.pubkey], so it works for remote (NIP-46)
/// signers too: mine here, then hand the result to the signer. The grind runs in
/// a `compute` isolate so a 16-bit floor doesn't hitch the UI on send.
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

/// `compute` entry point for [mineNonce] — pure, isolate-safe nonce grind.
List<List<String>> _powGrind(Map<String, Object?> args) {
  final pubkey = args['pubkey'] as String;
  final createdAt = args['createdAt'] as int;
  final kind = args['kind'] as int;
  final content = args['content'] as String;
  final difficulty = args['difficulty'] as int;
  final base = (args['tags'] as List)
      .map((t) => (t as List).cast<String>())
      .toList();
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

/// Validates that [ev]'s id meets [minDifficulty] leading zero bits and that
/// the committed difficulty in its `nonce` tag is at least [minDifficulty].
bool validatePow(NostrEvent ev, int minDifficulty) {
  if (ev.id.length != 64) return false;
  if (getPow(ev.id) < minDifficulty) return false;
  // The committed target (3rd nonce element) must also meet the requirement
  // to prevent claiming accidental leading zeros (NIP-13).
  for (final t in ev.tags) {
    if (t.isNotEmpty && t[0] == 'nonce' && t.length >= 3) {
      final committed = int.tryParse(t[2]);
      if (committed == null || committed < minDifficulty) return false;
      return true;
    }
  }
  // No commitment tag: fall back to raw leading-zero check already passed.
  return true;
}
