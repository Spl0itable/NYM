import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;

import '../../models/nostr_event.dart';
import 'keys.dart';
import 'native_schnorr.dart';

String _privHex(Uint8List privkey) => bytesToHex(privkey).padLeft(64, '0');

/// Signs [idHex] with BIP340, via native libsecp256k1 when loaded in this isolate, else pure Dart.
String signId(String idHex, Uint8List privkey) {
  final native = NativeSchnorr.sign(privkey: privkey, idHex: idHex);
  if (native != null) return native;
  final aux = bytesToHex(randomBytes(32));
  return bip340.sign(_privHex(privkey), idHex, aux);
}

String signEvent(UnsignedEvent event, Uint8List privkey) {
  return signId(event.computeId(), privkey);
}

/// Recomputes the id and checks the BIP340 signature; false on any mismatch or malformed input.
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

/// Sets the signer pubkey, id and signature on [rumorLike], like nostr-tools `finalizeEvent`.
NostrEvent finalizeEvent(UnsignedEvent rumorLike, Uint8List privkey) {
  final pubkey = getPublicKeyHex(privkey);
  // Rebuild with the signer's pubkey so the id binds to it.
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
