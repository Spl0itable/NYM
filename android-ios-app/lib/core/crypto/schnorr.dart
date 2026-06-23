import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;

import '../../models/nostr_event.dart';
import 'keys.dart';

/// BIP340 Schnorr signing/verification for Nostr events.

String _privHex(Uint8List privkey) => bytesToHex(privkey).padLeft(64, '0');

/// Signs the 32-byte event id [idHex] with [privkey], returning a 64-byte
/// (128-char hex) Schnorr signature. Uses fresh aux randomness per signature.
String signId(String idHex, Uint8List privkey) {
  final aux = bytesToHex(randomBytes(32));
  return bip340.sign(_privHex(privkey), idHex, aux);
}

/// Signs an unsigned event: computes its id and returns the signature hex.
String signEvent(UnsignedEvent event, Uint8List privkey) {
  return signId(event.computeId(), privkey);
}

/// Verifies a fully-populated [event]: recomputes the id from its content and
/// checks the Schnorr signature against the event pubkey. Returns false on any
/// mismatch or malformed input.
bool verifyEvent(NostrEvent event) {
  if (event.sig.length != 128 || event.pubkey.length != 64) return false;
  final computedId = event.computeId();
  if (event.id.isNotEmpty && event.id != computedId) return false;
  try {
    return bip340.verify(event.pubkey, computedId, event.sig);
  } catch (_) {
    return false;
  }
}

/// Finalizes a rumor-like unsigned event with [privkey]: sets the pubkey
/// (derived from the key), computes the id, signs it, and returns a signed
/// [NostrEvent]. Mirrors nostr-tools `finalizeEvent`.
NostrEvent finalizeEvent(UnsignedEvent rumorLike, Uint8List privkey) {
  final pubkey = getPublicKeyHex(privkey);
  // Rebuild with the correct pubkey so the id binds to the signer.
  final event = NostrEvent(
    pubkey: pubkey,
    createdAt: rumorLike.createdAt,
    kind: rumorLike.kind,
    tags: rumorLike.tags,
    content: rumorLike.content,
  );
  event.id = event.computeId();
  event.sig = signId(event.id, privkey);
  return event;
}
