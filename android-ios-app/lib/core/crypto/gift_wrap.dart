import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../models/nostr_event.dart';
import '../../services/nostr/event_signer.dart';
import 'bitchat.dart' as bitchat;
import 'keys.dart';
import 'nip44.dart' as nip44;
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
Future<NostrEvent> nip59WrapAsync({
  required UnsignedEvent rumor,
  required EventSigner senderSigner,
  required String recipientPubkey,
  int? expiration,
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

/// A decrypt candidate identity: a secret key and whether to try the bitchat
/// transport for it.
typedef UnwrapCandidate = ({Uint8List sk, bool bitchat});

bool _isV2(String? content) =>
    content != null && content.startsWith('v2:');

/// Attempts to decrypt + parse a kind-1059 gift [wrap] against ordered
/// [candidates]. Tries bitchat (`v2:`) first when enabled, then NIP-44. Returns
/// the recovered seal event, the rumor map, and whether bitchat was used, or
/// null if no candidate succeeds.
Future<({NostrEvent seal, Map<String, dynamic> rumor, bool isBitchat})?>
    unwrapGiftWrap(NostrEvent wrap, List<UnwrapCandidate> candidates) async {
  for (final cand in candidates) {
    final sk = cand.sk;
    try {
      NostrEvent seal;
      Map<String, dynamic> rumor;
      var isBitchat = false;

      if (cand.bitchat && _isV2(wrap.content)) {
        final sealJson = await bitchat.decryptBitchat(
            wrap.content, wrap.pubkey, sk);
        seal = NostrEvent.fromJson(
            jsonDecode(sealJson) as Map<String, dynamic>);
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

      return (seal: seal, rumor: rumor, isBitchat: isBitchat);
    } catch (_) {
      // try next candidate
    }
  }
  return null;
}
