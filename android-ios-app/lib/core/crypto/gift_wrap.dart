import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../models/nostr_event.dart';
import '../../services/nostr/event_signer.dart';
import 'bitchat.dart' as bitchat;
import 'keys.dart';
import 'nip44.dart' as nip44;
import 'pq.dart' as pq;
import 'schnorr.dart';

/// NIP-59 gift wrapping (matches nym-crypto.js `nip59Wrap`, `bitchatWrap`,
/// `unwrapGiftWrap`).

final Random _rng = Random.secure();

/// CSPRNG-jittered timestamp: `now_seconds - rand*7200` (±2h backdating for
/// NIP-59 metadata protection). Matches `randomNow()`.
int randomNow() {
  final r = _rng.nextDouble();
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return (now - r * 7200).round();
}

/// Builds an unsigned rumor with its id computed, as the inner sealed event.
Map<String, dynamic> _buildRumorMap(UnsignedEvent rumor, String senderPub) {
  final r = NostrEvent(
    pubkey: senderPub,
    createdAt: rumor.createdAt,
    kind: rumor.kind,
    tags: rumor.tags,
    content: rumor.content,
  );
  final id = r.computeId();
  // Rumor JSON: id + standard event fields, no sig (NIP-59).
  return {
    'id': id,
    'pubkey': senderPub,
    'created_at': r.createdAt,
    'kind': r.kind,
    'tags': r.tags,
    'content': r.content,
  };
}

/// Wraps [rumor] for [recipientPubkey] using NIP-44/NIP-59. Returns a signed
/// kind-1059 gift wrap.
NostrEvent nip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  int? expiration,
}) {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  // Seal (kind 13) signed by the real sender key.
  final ckSeal = nip44.getConversationKey(senderPrivkey, recipientPubkey);
  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: nip44.encrypt(jsonEncode(rumorMap), ckSeal),
    ),
    senderPrivkey,
  );

  // Wrap (kind 1059) signed by a fresh ephemeral key.
  final ephSk = generatePrivateKey();
  final ckWrap = nip44.getConversationKey(ephSk, recipientPubkey);
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: nip44.encrypt(jsonEncode(seal.toJson()), ckWrap),
    ),
    ephSk,
  );
}

/// Hybrid post-quantum NIP-59 gift wrap (matches nym-crypto.js `pqNip59Wrap`).
///
/// Structurally identical to [nip59Wrap] — same kinds, same tags, same
/// signatures, same +/-2h jitter — but BOTH the seal and the wrap derive their
/// NIP-44 conversation key from the hybrid ECDH + ML-KEM-768 combiner instead
/// of plain ECDH. [recipientKemPublicKey] is the recipient's announced ML-KEM
/// public key; callers only reach this path when they hold a valid one, so
/// there is no in-band negotiation and no downgrade surface.
///
/// Local-key only: the seal's classical leg is static-static ECDH from the
/// sender's identity key, and a NIP-46 remote signer returns a finished NIP-44
/// payload rather than a conversation key, leaving no way to inject a hybrid
/// one. Those logins stay on the classical path by construction.
NostrEvent pqNip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  required Uint8List recipientKemPublicKey,
  int? expiration,
}) {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  // Seal (kind 13), signed by the real sender key.
  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: pq.pqEncrypt(jsonEncode(rumorMap), senderPrivkey, recipientPubkey,
          recipientKemPublicKey),
    ),
    senderPrivkey,
  );

  // Wrap (kind 1059), signed by a fresh ephemeral key.
  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: pq.pqEncrypt(jsonEncode(seal.toJson()), ephSk, recipientPubkey,
          recipientKemPublicKey),
    ),
    ephSk,
  );
}

/// pq2 gift wrap: both NIP-59 layers, layered rather than combined.
Future<NostrEvent> pq2Nip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  required Uint8List recipientKemPublicKey,
  int? expiration,
}) async {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: await pq.pq2Encrypt(jsonEncode(rumorMap), senderPrivkey,
          recipientPubkey, recipientKemPublicKey),
    ),
    senderPrivkey,
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: await pq.pq2Encrypt(jsonEncode(seal.toJson()), ephSk,
          recipientPubkey, recipientKemPublicKey),
    ),
    ephSk,
  );
}

/// Async, signer-driven NIP-59 wrap. The **seal (kind 13)** is signed by
/// [senderSigner] and its content encrypted via `senderSigner.nip44Encrypt`
/// (so it works for a NIP-46 *remote* signer, not just a local key); the
/// **wrap (kind 1059)** is built with a fresh LOCAL ephemeral key (local NIP-44
/// + `finalizeEvent`) exactly as the sync [nip59Wrap].
///
/// This mirrors the PWA's remote gift-wrap path (groups.js `_sendGiftWrapsAsync`
/// extension/NIP-46 branch): the seal content is `nip44_encrypt(recipient,
/// rumorJson)` + `sign_event(seal)` on the remote signer, then the wrap is
/// finalized locally with an ephemeral key.
///
/// For a [LocalSigner] this produces output indistinguishable from [nip59Wrap]
/// (same seal author = sender pubkey, same NIP-44 conversation key), so the
/// existing sync callers and tests are unaffected.
/// [recipientKemPublicKey], when non-null, makes the WRAP layer hybrid.
///
/// The seal cannot be: a signer returns a finished NIP-44 payload rather than a
/// conversation key, so there is nowhere to mix the KEM secret in. The wrap's
/// ephemeral key is ours, generated here, so that layer can be — and it is the
/// layer that matters. What a recorder stores is the wrap; reaching the seal at
/// all means breaking it first, so a hybrid wrap already defeats
/// harvest-now-decrypt-later. The seal's classical encryption is only reachable
/// by someone who has ALREADY broken the post-quantum layer.
///
/// unwrapGiftWrap accepts a hybrid wrap around a classical seal, so this is
/// readable by every shipped build with no version gate.
Future<NostrEvent> nip59WrapAsync({
  required UnsignedEvent rumor,
  required EventSigner senderSigner,
  required String recipientPubkey,
  int? expiration,
  Uint8List? recipientKemPublicKey,
}) async {
  final senderPub = senderSigner.pubkey;
  final rumorMap = _buildRumorMap(rumor, senderPub);

  // Seal (kind 13) — signed + encrypted by the (possibly remote) sender signer.
  final sealContent =
      await senderSigner.nip44Encrypt(recipientPubkey, jsonEncode(rumorMap));
  final seal = await senderSigner.sign(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: sealContent,
    ),
  );

  // Wrap (kind 1059) — fresh local ephemeral key (local NIP-44 + schnorr).
  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  final sealJson = jsonEncode(seal.toJson());
  final content = recipientKemPublicKey != null
      ? pq.pqEncrypt(sealJson, ephSk, recipientPubkey, recipientKemPublicKey)
      : nip44.encrypt(sealJson, nip44.getConversationKey(ephSk, recipientPubkey));
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: content,
    ),
    ephSk,
  );
}

/// Async, signer-driven bitchat wrap. Mirrors [bitchatWrap] but seals via the
/// active [senderSigner] for the seal signature. The seal *content* still uses
/// `encryptBitchat` keyed by the sender pubkey, so this requires a local key
/// for the seal-content step; remote bitchat sealing is not part of the PWA
/// flow (bitchat receipts use the local-key fast path). Provided for parity
/// with the sync API.
Future<NostrEvent> bitchatWrapAsync({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required EventSigner senderSigner,
  required String recipientPubkey,
  int? expiration,
}) async {
  // bitchat seal content is keyed by the sender's local key; the seal signature
  // goes through the signer for parity with the publish path.
  final senderPub = senderSigner.pubkey;
  final rumorMap = _buildRumorMap(rumor, senderPub);

  final seal = await senderSigner.sign(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: await bitchat.encryptBitchat(
          jsonEncode(rumorMap), senderPrivkey, recipientPubkey),
    ),
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: await bitchat.encryptBitchat(
          jsonEncode(seal.toJson()), ephSk, recipientPubkey),
    ),
    ephSk,
  );
}

/// Wraps [rumor] for [recipientPubkey] using the bitchat transport. Both the
/// seal and wrap content use `encryptBitchat`.
Future<NostrEvent> bitchatWrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  int? expiration,
}) async {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: await bitchat.encryptBitchat(
          jsonEncode(rumorMap), senderPrivkey, recipientPubkey),
    ),
    senderPrivkey,
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: await bitchat.encryptBitchat(
          jsonEncode(seal.toJson()), ephSk, recipientPubkey),
    ),
    ephSk,
  );
}

/// A decrypt candidate identity: a secret key, whether to try the bitchat
/// transport for it, and optionally the ML-KEM keypair that lets it open hybrid
/// post-quantum wraps. A candidate with null KEM material simply cannot match a
/// `pq1.` payload and falls through to the next one, so mixed-capability key
/// sets (e.g. rotating group ephemeral keys, only some of which are PQ) are
/// safe.
typedef UnwrapCandidate = ({
  Uint8List sk,
  bool bitchat,
  Uint8List? kemSk,
  Uint8List? kemPk,
});

/// Builds a classical-only candidate. Convenience for the many call sites that
/// have no ML-KEM material.
UnwrapCandidate classicalCandidate(Uint8List sk, {bool bitchat = false}) =>
    (sk: sk, bitchat: bitchat, kemSk: null, kemPk: null);

bool _isV2(String? content) => content != null && content.startsWith('v2:');

/// Attempts to decrypt + parse a kind-1059 gift [wrap] against ordered
/// [candidates]. Returns the recovered seal event, the rumor map, and which
/// transport was used, or null if no candidate succeeds.
///
/// The transport is chosen by inspecting the payload, never by trusting a tag:
/// `pq1.` selects the hybrid post-quantum path, `v2:` bitchat, and anything
/// else plain NIP-44.
Future<
    ({
      NostrEvent seal,
      Map<String, dynamic> rumor,
      bool isBitchat,
      bool isPq
    })?> unwrapGiftWrap(
    NostrEvent wrap, List<UnwrapCandidate> candidates) async {
  for (final cand in candidates) {
    final sk = cand.sk;
    try {
      NostrEvent seal;
      Map<String, dynamic> rumor;
      var isBitchat = false;
      var isPq = false;

      if (pq.isPq2Payload(wrap.content)) {
        final kemSk = cand.kemSk, kemPk = cand.kemPk;
        if (kemSk == null || kemPk == null) continue;
        final self =
            pq.PqIdentity(privkey: sk, kemSecretKey: kemSk, kemPublicKey: kemPk);
        seal = NostrEvent.fromJson(
            jsonDecode(await pq.pq2Decrypt(wrap.content, wrap.pubkey, self))
                as Map<String, dynamic>);
        // A NIP-44 seal stays readable, as in the pq1 branch.
        final rumorJson = pq.isPq2Payload(seal.content)
            ? await pq.pq2Decrypt(seal.content, seal.pubkey, self)
            : nip44.decrypt(
                seal.content, nip44.getConversationKey(sk, seal.pubkey));
        rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
        isPq = true;
      } else if (pq.isPqPayload(wrap.content)) {
        final kemSk = cand.kemSk, kemPk = cand.kemPk;
        if (kemSk == null || kemPk == null) continue;
        final self =
            pq.PqIdentity(privkey: sk, kemSecretKey: kemSk, kemPublicKey: kemPk);
        seal = NostrEvent.fromJson(
            jsonDecode(pq.pqDecrypt(wrap.content, wrap.pubkey, self))
                as Map<String, dynamic>);
        // The seal is expected to be PQ too (pqNip59Wrap writes both layers),
        // but accept a NIP-44 seal so a future wrap-only variant stays readable.
        final rumorJson = pq.isPqPayload(seal.content)
            ? pq.pqDecrypt(seal.content, seal.pubkey, self)
            : nip44.decrypt(
                seal.content, nip44.getConversationKey(sk, seal.pubkey));
        rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
        isPq = true;
      } else if (cand.bitchat && _isV2(wrap.content)) {
        final sealJson =
            await bitchat.decryptBitchat(wrap.content, wrap.pubkey, sk);
        seal =
            NostrEvent.fromJson(jsonDecode(sealJson) as Map<String, dynamic>);
        final rumorJson = _isV2(seal.content)
            ? await bitchat.decryptBitchat(seal.content, seal.pubkey, sk)
            : nip44.decrypt(
                seal.content,
                nip44.getConversationKey(sk, seal.pubkey),
              );
        rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
        isBitchat = true;
      } else {
        final ckWrap = nip44.getConversationKey(sk, wrap.pubkey);
        seal = NostrEvent.fromJson(
            jsonDecode(nip44.decrypt(wrap.content, ckWrap))
                as Map<String, dynamic>);
        final ckSeal = nip44.getConversationKey(sk, seal.pubkey);
        rumor = jsonDecode(nip44.decrypt(seal.content, ckSeal))
            as Map<String, dynamic>;
      }

      return (seal: seal, rumor: rumor, isBitchat: isBitchat, isPq: isPq);
    } catch (_) {
      // try next candidate
    }
  }
  return null;
}
