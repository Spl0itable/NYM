import 'dart:typed_data';

import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/nip44.dart' as nip44;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../features/identity/nip46_service.dart';
import '../../models/nostr_event.dart';

/// Signs and runs NIP-44 for the active identity, locally or via a NIP-46 remote signer.
abstract class EventSigner {
  /// The author pubkey, 64-char hex.
  String get pubkey;

  Future<NostrEvent> sign(UnsignedEvent unsigned);

  Future<String> nip44Encrypt(String peerPubkey, String plaintext);

  Future<String> nip44Decrypt(String peerPubkey, String ciphertext);

  /// True when signing is delegated to a NIP-46 remote signer.
  bool get isRemote;
}

class LocalSigner implements EventSigner {
  LocalSigner(this._privkey) : _pubkey = keys.getPublicKeyHex(_privkey);

  final Uint8List _privkey;
  final String _pubkey;

  /// Exposed so the wrap path can use the local key directly, as the PWA does.
  Uint8List get privkey => _privkey;

  @override
  String get pubkey => _pubkey;

  @override
  bool get isRemote => false;

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) async =>
      schnorr.finalizeEvent(unsigned, _privkey);

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) async {
    final ck = nip44.getConversationKey(_privkey, peerPubkey);
    return nip44.encrypt(plaintext, ck);
  }

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) async {
    final ck = nip44.getConversationKey(_privkey, peerPubkey);
    return nip44.decrypt(ciphertext, ck);
  }
}

/// Adapts a connected NIP-46 [Nip46Signer] to [EventSigner].
class Nip46SignerAdapter implements EventSigner {
  Nip46SignerAdapter(this._remote);

  final Nip46Signer _remote;

  @override
  String get pubkey => _remote.pubkey;

  @override
  bool get isRemote => true;

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) =>
      _remote.signEvent(unsigned);

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) =>
      _remote.nip44Encrypt(peerPubkey, plaintext);

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) =>
      _remote.nip44Decrypt(peerPubkey, ciphertext);
}
