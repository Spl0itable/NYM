// The verified-app filter must be able to verify a badge from the very first
// inbound event. The authority key is pinned, so nothing about it should wait
// on enrollment: a boot that seeds `appAttestAuthority` only after the badge
// round-trip drops every stranger's message that arrives meanwhile, and the
// seen-id gate then keeps them dropped for the session.

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/attest/attest_badge.dart';
import 'package:nym_bar/services/attest/attest_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Golden badge from attest_badge_test.dart: issued for alice by the
  // authority whose secret is '7' * 63 + '3', expiring on day 20755.
  const authority =
      'a5a83164cbe36d56d599f92bca6d8210bbe66e31547a388100cd4d39aed93019';
  const alice =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const self =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const attestedBadge = '1.attested.g0j.tsXrgGmbtlJnTk1AquMRQuLmYo4mfbjWTezj'
      'eQphQil_X6WBaQP83i8_NHopf5xliGn7ttAIpwkUl1f7ucCfUA';
  final inTerm = DateTime.fromMillisecondsSinceEpoch(20700 * 86400000);

  NostrEvent attestedEvent() => NostrEvent(
        id: '1' * 64,
        pubkey: alice,
        createdAt: 0,
        kind: 23333,
        tags: [
          ['d', 'nymchat'],
          ['nymattest', attestedBadge],
        ],
        content: 'hello',
        sig: '0' * 128,
      );

  setUp(() {
    appVerifiedFilter = 'on';
    appAttestRegistry = AttestRegistry();
    appAttestAuthority = '';
  });

  tearDown(() {
    appVerifiedFilter = 'off';
    appAttestRegistry = AttestRegistry();
    appAttestAuthority = '';
  });

  test('the authority is known before any enrollment or stored value',
      () async {
    SharedPreferences.setMockInitialValues({});
    final kv = KeyValueStore(await SharedPreferences.getInstance());
    final attest = AttestService(kv: kv);
    expect(attest.authorityPubkey, AttestService.pinnedAuthority);
    expect(attest.authorityPubkey.length, 64);
  });

  test('an attested stranger is dropped while the authority is unset', () {
    appAttestRegistry.ingest(attestedEvent(), appAttestAuthority, now: inTerm);
    expect(appAttestRegistry.tierOf(alice), isNull);
    expect(
        passesVerifiedFilter(alice, selfPubkey: self, friends: const <String>{}),
        isFalse);
  });

  test('the same event passes once the authority is seeded', () {
    appAttestAuthority = authority;
    appAttestRegistry.ingest(attestedEvent(), appAttestAuthority, now: inTerm);
    expect(appAttestRegistry.tierOf(alice), AttestTier.attested);
    expect(
        passesVerifiedFilter(alice, selfPubkey: self, friends: const <String>{}),
        isTrue);
  });
}
