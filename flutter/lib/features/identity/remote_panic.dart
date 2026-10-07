import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/gift_wrap.dart' as gw;
import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';
import '../../services/nostr/event_signer.dart';
import '../../services/storage/key_value_store.dart';
import '../accounts/account_logic.dart';
import 'panic_purge.dart';
import 'remote_panic_logic.dart';

final remotePanicRevisionProvider = StateProvider<int>((ref) => 0);

class RemotePanicSignals {
  RemotePanicSignals._();

  static int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Map<String, dynamic> marker(Uint8List sk,
      {int? at, bool deleted = false}) {
    final t = RemotePanic.template(at ?? nowSec(), deleted: deleted);
    final ev = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: keys.getPublicKeyHex(sk),
        createdAt: t['created_at'] as int,
        kind: RemotePanic.kind,
        tags: [
          ['d', deleted ? RemotePanic.deleteDTag : RemotePanic.dTag]
        ],
        content: '',
      ),
      sk,
    );
    return ev.toJson();
  }

  static Map<String, dynamic> markBody(
      Uint8List sk, Map<String, dynamic> marker, String url) {
    final pubkey = keys.getPublicKeyHex(sk);
    final body = <String, dynamic>{
      'action': 'panic-mark',
      'pubkey': pubkey,
      'at': marker['created_at'],
      'id': marker['id'],
      'sig': marker['sig'],
    };
    return {
      ...body,
      'auth': Nip98Auth.build(
        action: 'panic-mark',
        url: url,
        privkey: sk,
        pubkey: pubkey,
        payload: Nip98Auth.payloadHashHex(body),
      ),
    };
  }

  static Future<Map<String, dynamic>?> markerVia(EventSigner signer,
      {int? at, bool deleted = false}) async {
    final t = RemotePanic.template(at ?? nowSec(), deleted: deleted);
    final ev = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: t['created_at'] as int,
      kind: RemotePanic.kind,
      tags: [
        ['d', deleted ? RemotePanic.deleteDTag : RemotePanic.dTag]
      ],
      content: '',
    ));
    final m = ev.toJson();
    return RemotePanic.markerValid(m, signer.pubkey, verify) ? m : null;
  }

  static Future<Map<String, dynamic>?> markBodyVia(
      EventSigner signer, Map<String, dynamic> marker, String url) async {
    final body = <String, dynamic>{
      'action': 'panic-mark',
      'pubkey': signer.pubkey,
      'at': marker['created_at'],
      'id': marker['id'],
      'sig': marker['sig'],
    };
    final auth = await Nip98Auth.buildWrite(
      action: 'panic-mark',
      url: url,
      signer: signer,
      payload: Nip98Auth.payloadHashHex(body),
    );
    if (auth == null || auth['pubkey'] != signer.pubkey) return null;
    return {...body, 'auth': auth};
  }

  static NostrEvent wrap(Uint8List sk, Map<String, dynamic> marker) {
    final pubkey = keys.getPublicKeyHex(sk);
    final r = RemotePanic.rumor(marker);
    return gw.nip59Wrap(
      rumor: UnsignedEvent(
        pubkey: pubkey,
        createdAt: r['created_at'] as int,
        kind: RemotePanic.kind,
        tags: [
          [
            'd',
            RemotePanic.isDeletion(marker)
                ? RemotePanic.deleteDTag
                : RemotePanic.dTag
          ]
        ],
        content: r['content'] as String,
      ),
      senderPrivkey: sk,
      recipientPubkey: pubkey,
      extraTags: const [
        ['k', 'nym-sync']
      ],
    );
  }

  static bool verify(Map<String, dynamic> ev) {
    try {
      return schnorr.verifyEvent(NostrEvent.fromJson(ev));
    } catch (_) {
      return false;
    }
  }
}

class RemotePanicSender {
  RemotePanicSender({
    required this.enabled,
    required this.send,
    required this.url,
    this.publish,
    this.deleting = false,
  });

  factory RemotePanicSender.fromStore(
    KeyValueStore kv, {
    required Future<Map<String, dynamic>> Function(Map<String, dynamic> body)
        send,
    required String Function() url,
    bool Function(NostrEvent wrap)? publish,
    bool deleting = false,
  }) =>
      RemotePanicSender(
        enabled: (i) => RemotePanicPrefs.enabledFor(kv, i),
        send: send,
        url: url,
        publish: publish,
        deleting: deleting,
      );

  final bool Function(PanicIdentity identity) enabled;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body) send;
  final String Function() url;
  final bool Function(NostrEvent wrap)? publish;
  final bool deleting;

  final List<String> marked = [];

  Future<void> call(PanicIdentity identity, Uint8List sk) async {
    if (!RemotePanic.shouldSend(
        deleting || enabled(identity), sk.length == 32)) {
      return;
    }
    if (identity.pubkey.isNotEmpty &&
        keys.getPublicKeyHex(sk) != identity.pubkey.toLowerCase()) {
      return;
    }
    final m = RemotePanicSignals.marker(sk, deleted: deleting);
    final pub = publish;
    if (identity.active && pub != null) {
      try {
        pub(RemotePanicSignals.wrap(sk, m));
      } catch (_) {}
    }
    final res = await send(RemotePanicSignals.markBody(sk, m, url()));
    if (res['ok'] == true) marked.add(m['pubkey'] as String);
  }

  Future<void> viaSigner(PanicIdentity identity, EventSigner signer) async {
    final pubkey = identity.pubkey.toLowerCase();
    if (!identity.active || pubkey.isEmpty) return;
    if (signer is! Nip46SignerAdapter || !signer.connected) return;
    if (signer.pubkey != pubkey) return;
    if (!RemotePanic.shouldSend(deleting || enabled(identity), true)) return;
    final m = await RemotePanicSignals.markerVia(signer, deleted: deleting);
    if (m == null) return;
    final body = await RemotePanicSignals.markBodyVia(signer, m, url());
    if (body == null) return;
    final res = await send(body);
    if (res['ok'] == true) marked.add(pubkey);
  }
}

class RemotePanicPrefs {
  RemotePanicPrefs._();

  static bool enabledFor(KeyValueStore kv, PanicIdentity identity) {
    final key = identity.active || identity.id.isEmpty
        ? StorageKeys.remotePanic
        : AccountLogic.nsKey(identity.id, StorageKeys.remotePanic);
    return kv.getBool(key);
  }

  static int? loginAt(KeyValueStore kv) {
    final v = kv.getInt(StorageKeys.panicLoginAt, defaultValue: 0);
    return v > 0 ? v : null;
  }

  static Future<void> ensureLoginAt(KeyValueStore kv) async {
    if (loginAt(kv) != null) return;
    await kv.setInt(StorageKeys.panicLoginAt, RemotePanicSignals.nowSec());
  }

  static Future<void> noteLogin(KeyValueStore kv) async {
    await kv.setInt(StorageKeys.panicLoginAt, RemotePanicSignals.nowSec());
    await kv.setBool(StorageKeys.panicClearPending, true);
  }
}
