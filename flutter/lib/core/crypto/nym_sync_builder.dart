// Off-main-isolate builders for self-addressed `nym-sync` publishes; must match the inline paths byte for byte.

import 'dart:convert';
import 'dart:typed_data';

import '../constants/event_kinds.dart';
import 'gift_wrap.dart' as giftwrap;
import 'keys.dart' as keys;
import 'native_schnorr.dart';
import 'nip44.dart' as nip44;
import 'pq.dart' as pq;
import 'schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

/// Job keys: `sk`, `self`, `rumorJson`, `outerD`, `kemPk` (optional); null when both forms exceed size gates.
Future<Map<String, dynamic>?> buildNymSyncWrapIsolate(
    Map<String, dynamic> job) async {
  await NativeSchnorr.ensureLoaded();
  final sk = keys.hexToBytes(job['sk'] as String);
  final self = job['self'] as String;
  final rumorJson = job['rumorJson'] as String;
  final outerD = job['outerD'] as String;
  final kemPk = job['kemPk'] as Uint8List?;

  // Same `build` closure as publishNymSyncWrap, with the local signer inlined.
  Future<Map<String, dynamic>?> build(
    Future<String> Function(String plaintext) seal,
    Future<String> Function(String plaintext, Uint8List ephSk) wrap,
  ) async {
    final sealed = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: self,
        createdAt: giftwrap.randomNow(),
        kind: 13,
        tags: const [],
        content: await seal(rumorJson),
      ),
      sk,
    );
    final sealJson = jsonEncode(sealed.toJson());
    if (utf8.encode(sealJson).length > 65535) return null;
    final ephSk = keys.generatePrivateKey();
    final wrapped = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: keys.getPublicKeyHex(ephSk),
        createdAt: giftwrap.randomNow(),
        kind: EventKind.giftWrap,
        tags: [
          ['p', self],
          ['d', outerD],
          ['k', 'nym-sync'],
        ],
        content: await wrap(sealJson, ephSk),
      ),
      ephSk,
    );
    final json = wrapped.toJson();
    if (jsonEncode(['EVENT', json]).length > 65000) return null;
    return json;
  }

  String nip44ToSelf(String pt) =>
      nip44.encrypt(pt, nip44.getConversationKey(sk, self));

  if (kemPk != null) {
    final wrapped = await build(
      (pt) async => pq.pq2Seal(nip44ToSelf(pt), self, self, kemPk),
      (pt, ephSk) => pq.pq2Encrypt(pt, ephSk, self, kemPk),
    );
    if (wrapped != null) return wrapped;
    // Oversized hybrid falls back to classical, as in the inline path.
  }
  return build(
    (pt) async => nip44ToSelf(pt),
    (pt, ephSk) async =>
        nip44.encrypt(pt, nip44.getConversationKey(ephSk, self)),
  );
}

/// Wrap layer only, for remote-signer seals; job keys `sealJson`, `self`, `outerD`, `kemPk`; null if over the relay gate.
Future<Map<String, dynamic>?> wrapNymSyncSealIsolate(
    Map<String, dynamic> job) async {
  await NativeSchnorr.ensureLoaded();
  final sealJson = job['sealJson'] as String;
  final self = job['self'] as String;
  final outerD = job['outerD'] as String;
  final kemPk = job['kemPk'] as Uint8List?;
  final ephSk = keys.generatePrivateKey();
  final content = kemPk != null
      ? await pq.pq2Encrypt(sealJson, ephSk, self, kemPk)
      : nip44.encrypt(sealJson, nip44.getConversationKey(ephSk, self));
  final wrapped = schnorr.finalizeEvent(
    UnsignedEvent(
      pubkey: keys.getPublicKeyHex(ephSk),
      createdAt: giftwrap.randomNow(),
      kind: EventKind.giftWrap,
      tags: [
        ['p', self],
        ['d', outerD],
        ['k', 'nym-sync'],
      ],
      content: content,
    ),
    ephSk,
  );
  final json = wrapped.toJson();
  if (jsonEncode(['EVENT', json]).length > 65000) return null;
  return json;
}

/// Local-key `_encryptToSelf`; job keys `sk`, `self`, `plaintext`, `kemPk` (optional); null on failure.
Future<String?> encryptToSelfIsolate(Map<String, dynamic> job) async {
  await NativeSchnorr.ensureLoaded();
  try {
    final sk = keys.hexToBytes(job['sk'] as String);
    final self = job['self'] as String;
    final plaintext = job['plaintext'] as String;
    final kemPk = job['kemPk'] as Uint8List?;
    final inner = nip44.encrypt(
        plaintext, nip44.getConversationKey(sk, self));
    if (kemPk != null) {
      try {
        return await pq.pq2Seal(inner, self, self, kemPk);
      } catch (_) {
        // Fall through to NIP-44 rather than losing the write, as _encryptToSelf does.
      }
    }
    return inner;
  } catch (_) {
    return null;
  }
}
