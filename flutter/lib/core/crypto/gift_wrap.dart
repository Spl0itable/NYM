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

final Random _rng = Random.secure();

/// `now - rand*7200` seconds, NIP-59 timestamp backdating.
int randomNow() {
  final r = _rng.nextDouble();
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return (now - r * 7200).round();
}

Map<String, dynamic> _buildRumorMap(UnsignedEvent rumor, String senderPub) {
  final r = NostrEvent(
    pubkey: senderPub,
    createdAt: rumor.createdAt,
    kind: rumor.kind,
    tags: rumor.tags,
    content: rumor.content,
  );
  final id = r.computeId();
  // Rumor JSON: id and standard fields, no sig (NIP-59).
  return {
    'id': id,
    'pubkey': senderPub,
    'created_at': r.createdAt,
    'kind': r.kind,
    'tags': r.tags,
    'content': r.content,
  };
}

/// NIP-59 wraps [rumor] for [recipientPubkey] into a signed kind-1059 event.
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

/// Hybrid PQ NIP-59: both layers key off ECDH + ML-KEM-768; local keys only, since signers can't inject a hybrid key.
NostrEvent pqNip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  required Uint8List recipientKemPublicKey,
  int? expiration,
}) {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

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

/// Signer-driven wrap for local or remote signers; [recipientKemPublicKey] makes only the wrap layer hybrid.
Future<NostrEvent> nip59WrapAsync({
  required UnsignedEvent rumor,
  required EventSigner senderSigner,
  required String recipientPubkey,
  int? expiration,
  Uint8List? recipientKemPublicKey,
  bool layered = false,
}) async {
  final senderPub = senderSigner.pubkey;
  final rumorMap = _buildRumorMap(rumor, senderPub);

  // Seal signed and encrypted by the possibly remote signer.
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

  // Wrap uses a fresh local ephemeral key.
  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  final sealJson = jsonEncode(seal.toJson());
  final content = recipientKemPublicKey == null
      ? nip44.encrypt(sealJson, nip44.getConversationKey(ephSk, recipientPubkey))
      : layered
          ? await pq.pq2Encrypt(
              sealJson, ephSk, recipientPubkey, recipientKemPublicKey)
          : pq.pqEncrypt(sealJson, ephSk, recipientPubkey, recipientKemPublicKey);
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

/// Signer-driven [bitchatWrap]; seal content still needs a local key.
Future<NostrEvent> bitchatWrapAsync({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required EventSigner senderSigner,
  required String recipientPubkey,
  int? expiration,
}) async {
  // bitchat seal content is keyed by the local key; only the signature goes through the signer.
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

/// Decrypt candidate; null KEM material just never matches a `pq1.` payload.
typedef UnwrapCandidate = ({
  Uint8List sk,
  bool bitchat,
  Uint8List? kemSk,
  Uint8List? kemPk,
});

UnwrapCandidate classicalCandidate(Uint8List sk, {bool bitchat = false}) =>
    (sk: sk, bitchat: bitchat, kemSk: null, kemPk: null);

bool _isV2(String? content) => content != null && content.startsWith('v2:');

/// Unwraps [wrap] with ordered [candidates]; the payload prefix, never a tag, picks the transport.
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
        // Accept a NIP-44 seal too, so a wrap-only variant stays readable.
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
      // Try the next candidate.
    }
  }
  return null;
}
