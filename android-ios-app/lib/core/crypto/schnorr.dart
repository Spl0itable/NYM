import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;

import '../../models/nostr_event.dart';
import 'keys.dart';
import 'native_schnorr.dart';

/// BIP340 Schnorr signing/verification for Nostr events.

String _privHex(Uint8List privkey) => bytesToHex(privkey).padLeft(64, '0');

/// Signs the 32-byte event id [idHex] with [privkey], returning a 64-byte
/// (128-char hex) Schnorr signature. Native libsecp256k1 when loaded in this
/// isolate (deterministic BIP340, self-verified, ~50 µs); otherwise the
/// pure-Dart bip340 path with fresh aux randomness (~10–20 ms of BigInt
/// math — which the CPU profile showed as main-thread jank per send).
String signId(String idHex, Uint8List privkey) {
  final native = NativeSchnorr.sign(privkey: privkey, idHex: idHex);
  if (native != null) return native;
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
///
/// Uses native libsecp256k1 when it is loaded in this isolate (~100× faster
/// than the pure-Dart path — see [NativeSchnorr]); otherwise the pure-Dart
/// bip340 implementation. Both are BIP340 and agree on every verdict.
bool verifyEvent(NostrEvent event) {
  if (event.sig.length != 128 || event.pubkey.length != 64) return false;
  final computedId = event.computeId();
  if (event.id.isNotEmpty && event.id != computedId) return false;
  if (NativeSchnorr.isAvailable) {
    return NativeSchnorr.verify(
      pubkeyHex: event.pubkey,
      idHex: computedId,
      sigHex: event.sig,
    );
  }
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
