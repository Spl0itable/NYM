import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/zaps/zap_archive.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/nostr/verified_rows.dart';

NostrEvent _signed(int kind, String content,
    {List<List<String>> tags = const []}) {
  final sk = generatePrivateKey();
  return schnorr.finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(sk),
      createdAt: 1700000000,
      kind: kind,
      tags: tags,
      content: content,
    ),
    sk,
  );
}

Map<String, dynamic> _forged(NostrEvent real, {required String pubkey}) =>
    {...real.toJson(), 'pubkey': pubkey};

Future<bool> _verify(NostrEvent e) async => schnorr.verifyEvent(e);

class _Sync implements StorageSync {
  _Sync(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> zapGet(
          String scope, List<String> ids) async =>
      rows;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final victim = getPublicKeyHex(generatePrivateKey());

  test('archive rows keep only events their author signed', () async {
    final good = _signed(20000, 'real');
    final impostor = _forged(_signed(20000, 'fake'), pubkey: victim);
    final rows = [
      good.toJson(),
      impostor,
      <String, dynamic>{'junk': true}
    ];

    final kept = await verifiedRows(rows, _verify);

    expect(kept.map((e) => e.id), [good.id]);
  });

  test('a zap receipt from the archive is only handed on when signed',
      () async {
    final real = _signed(9735, '', tags: const [
      ['bolt11', 'lnbc210n1x']
    ]);
    final fake = _forged(
        _signed(9735, '', tags: const [
          ['bolt11', 'lnbc100000u1x']
        ]),
        pubkey: victim);
    final archive = ZapArchive(_Sync([fake, real.toJson()]));
    final seen = <NostrEvent>[];

    await archive.backfill([victim], 'profile', seen.add);
    archive.dispose();

    expect(seen.map((e) => e.id), [real.id]);
  });
}
