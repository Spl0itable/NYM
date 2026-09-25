import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/nostr_controller.dart';

NostrEvent _decode(String header) {
  expect(header, startsWith('Nostr '));
  return NostrEvent.fromJson(
      jsonDecode(utf8.decode(base64.decode(header.substring(6))))
          as Map<String, dynamic>);
}

void main() {
  test('each upload is authorised by a fresh key, not the account', () {
    final hash = 'ab' * 32;
    final a = _decode(NostrController.blossomAuthHeader(hash, 1700000000));
    final b = _decode(NostrController.blossomAuthHeader(hash, 1700000000));

    expect(schnorr.verifyEvent(a), isTrue);
    expect(schnorr.verifyEvent(b), isTrue);
    expect(a.pubkey, isNot(b.pubkey));
    expect(a.kind, 24242);
    expect(a.tagValue('t'), 'upload');
    expect(a.tagValue('x'), hash);
    expect(a.tagValue('expiration'), '1700000600');
  });
}
