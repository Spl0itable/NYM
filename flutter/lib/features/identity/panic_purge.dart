import 'dart:async';
import 'dart:typed_data';

import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/crypto/keys.dart' as keys;
import '../../services/api/api_client.dart';
import '../../services/api/storage_sync.dart';
import '../../services/nostr/event_signer.dart';
import '../accounts/account_host.dart';
import '../i18n/i18n.dart';

class PanicIdentity {
  const PanicIdentity({
    required this.id,
    required this.pubkey,
    required this.active,
    this.method = '',
  });

  final String id;
  final String pubkey;
  final bool active;
  final String method;
}

class PanicIdentityPurge {
  PanicIdentityPurge({
    required this.identities,
    required this.storedNsec,
    required this.send,
    this.purgeActive,
    this.beforePurge,
    this.activeKey,
    this.activeSigner,
    this.beforePurgeSigned,
    String Function()? url,
  }) : _url = url ?? StorageSync.storageUrl;

  factory PanicIdentityPurge.fromAccounts(
    AccountsController? accounts, {
    required Future<Map<String, dynamic>> Function(Map<String, dynamic> body)
        send,
    Future<bool> Function(String pubkey)? purgeActive,
    Future<void> Function(PanicIdentity identity, Uint8List sk)? beforePurge,
    Uint8List? Function()? activeKey,
    EventSigner? Function()? activeSigner,
    Future<void> Function(PanicIdentity identity, EventSigner signer)?
        beforePurgeSigned,
    String activePubkey = '',
  }) {
    if (accounts == null) {
      return PanicIdentityPurge(
        identities: [
          if (activePubkey.isNotEmpty)
            PanicIdentity(id: '', pubkey: activePubkey, active: true),
        ],
        storedNsec: (_) async => null,
        send: send,
        purgeActive: purgeActive,
        beforePurge: beforePurge,
        activeKey: activeKey,
        activeSigner: activeSigner,
        beforePurgeSigned: beforePurgeSigned,
      );
    }
    final index = accounts.changes.value;
    return PanicIdentityPurge(
      identities: [
        for (final a in index.accounts)
          PanicIdentity(
              id: a.id,
              pubkey: a.pubkey,
              active: a.id == index.active,
              method: a.method),
      ],
      storedNsec: accounts.storedNsec,
      send: send,
      purgeActive: purgeActive,
      beforePurge: beforePurge,
      activeKey: activeKey,
      activeSigner: activeSigner,
      beforePurgeSigned: beforePurgeSigned,
    );
  }

  final List<PanicIdentity> identities;
  final Future<String?> Function(String id) storedNsec;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body) send;

  final Future<bool> Function(String pubkey)? purgeActive;
  final Future<void> Function(PanicIdentity identity, Uint8List sk)?
      beforePurge;
  final Uint8List? Function()? activeKey;
  final EventSigner? Function()? activeSigner;
  final Future<void> Function(PanicIdentity identity, EventSigner signer)?
      beforePurgeSigned;
  final String Function() _url;

  Future<List<Future<bool>>> start() async {
    final launched = await Future.wait([
      for (final i in identities) _launch(i),
    ]);
    return [
      for (final l in launched)
        if (l != null) l.done,
    ];
  }

  int get expected => identities.where((i) => i.pubkey.isNotEmpty).length;

  Future<({Future<bool> done})?> _launch(PanicIdentity identity) async {
    if (!identity.active && identity.method == 'anonymous') {
      return identity.pubkey.isEmpty ? null : (done: Future.value(false));
    }
    Uint8List? sk;
    try {
      final nsec = await storedNsec(identity.id);
      if (nsec != null && nsec.startsWith('nsec1')) {
        sk = bech32.decodeNsec(nsec);
      }
    } catch (_) {}
    if (sk != null) {
      final Map<String, dynamic> body;
      try {
        final own = keys.getPublicKeyHex(sk);
        if (identity.pubkey.isNotEmpty &&
            own.toLowerCase() != identity.pubkey.toLowerCase()) {
          return (done: Future.value(false));
        }
        body = _signed(sk);
      } catch (_) {
        return (done: Future.value(false));
      }
      final key = sk;
      final hook = beforePurge;
      return (
        done: _guard(() async {
          if (hook != null) {
            try {
              await hook(identity, key);
            } catch (_) {}
          }
          return (await send(body))['ok'] == true;
        })
      );
    }
    if (identity.pubkey.isEmpty) return null;
    final viaSigner = purgeActive;
    if (identity.active && viaSigner != null) {
      final hook = beforePurge;
      final live = activeKey?.call();
      final signedHook = beforePurgeSigned;
      final remote = live == null ? activeSigner?.call() : null;
      return (
        done: _guard(() async {
          if (hook != null && live != null) {
            try {
              await hook(identity, live);
            } catch (_) {}
          } else if (signedHook != null && remote != null) {
            try {
              await signedHook(identity, remote);
            } catch (_) {}
          }
          return viaSigner(identity.pubkey);
        })
      );
    }
    return (done: Future.value(false));
  }

  Map<String, dynamic> _signed(Uint8List sk) {
    final pubkey = keys.getPublicKeyHex(sk);
    final body = <String, dynamic>{
      'action': 'account-purge',
      'app': 'nymchat',
      'pubkey': pubkey,
    };
    return {
      ...body,
      'auth': Nip98Auth.build(
        action: 'account-purge',
        url: _url(),
        privkey: sk,
        pubkey: pubkey,
        payload: Nip98Auth.payloadHashHex(body),
      ),
    };
  }

  static Future<bool> _guard(Future<bool> Function() run) async {
    try {
      return await run();
    } catch (_) {
      return false;
    }
  }
}

String? panicPurgeStatus(int unremoved) {
  if (unremoved <= 0) return null;
  if (unremoved == 1) {
    return tr("Server records for 1 identity couldn't be removed");
  }
  return tr("Server records for {n} identities couldn't be removed",
      {'n': unremoved});
}
