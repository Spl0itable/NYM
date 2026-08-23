// The key we seal our OWN copies to — settings, the archive, self-wraps.
//
// It used to be read out of the registry, which holds whatever epoch was last
// announced, possibly by another device on the same nsec at an epoch this one
// has never held. Decryption only ever walks OUR epoch and the few before it,
// so a device could seal its own settings to a key it could never open. Silent
// and permanent: the blob is simply unreadable ever after.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_registry.dart';

void main() {
  final controller = File('lib/state/nostr_controller.dart').readAsStringSync();

  test('pqSelfKey derives from our own epoch, not the registry', () {
    final start = controller.indexOf('Uint8List? pqSelfKey() {');
    expect(start, greaterThan(-1));
    // The function alone — a wider window runs into _pqGroupKeyFor, which uses
    // the registry for exactly the right reason (a PEER's announced key).
    final body = controller.substring(start, controller.indexOf('\n  }', start));
    expect(body.contains('_pqSelfKeys()?.publicKey'), isTrue);
    expect(body.contains('_pqRegistry.keyFor'), isFalse,
        reason: 'the registry can hold another device\'s epoch');
    expect(body.contains('if (!pqSelfEnabled) return null;'), isTrue,
        reason: 'a login that cannot decapsulate must still get null');
  });

  test('the derived key is one pqSelfCandidates holds the secret half of', () {
    final priv = generatePrivateKey();
    const epoch = 0;
    final self = pq.pqKeypairFromPrivkey(priv, epoch);
    final candidates = pqSelfCandidates(priv, epoch);
    expect(
      candidates.any((c) => _eq(c.kemPk, self.publicKey)),
      isTrue,
    );
  });

  test('a foreign epoch is NOT something we can open', () {
    final priv = generatePrivateKey();
    final foreign = pq.pqKeypairFromPrivkey(priv, 9);
    final candidates = pqSelfCandidates(priv, 0);
    expect(
      candidates.any((c) => _eq(c.kemPk, foreign.publicKey)),
      isFalse,
      reason: 'which is exactly why sealing to an announced epoch was unsafe',
    );
  });
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
