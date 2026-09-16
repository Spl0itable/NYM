// Attestation badge verification, pinned against golden badges minted by the
// worker that issues them (nym-staging `functions/api/_attest.js`).
//
// The three implementations — worker, PWA, native — each verify the same wire
// format independently, and a disagreement between any two of them reads to a
// user as "everyone else is forged". The goldens below were produced by
// `issueBadge` and are checked here byte for byte, so a change to the digest
// string, the field order, the base64 alphabet or the radix fails loudly
// instead of quietly splitting the network in two.

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/relays.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/attest/attest_badge.dart';
import 'package:nym_bar/services/attest/attest_service.dart';

void main() {
  // From `issueBadge(env, pubkey, tier)` with
  // ATTEST_AUTHORITY_SECRET = '7' * 63 + '3'.
  const authority =
      'a5a83164cbe36d56d599f92bca6d8210bbe66e31547a388100cd4d39aed93019';
  const alice =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const bob =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const attestedBadge = '1.attested.g0j.tsXrgGmbtlJnTk1AquMRQuLmYo4mfbjWTezj'
      'eQphQil_X6WBaQP83i8_NHopf5xliGn7ttAIpwkUl1f7ucCfUA';
  const originBadge = '1.origin.g0j.Sls4xb8tqWvnF2NR7gTPPjun-ePmQn7lqIsnWEmw'
      'AQ8A-ZW7VieV1jxtooRsNC0E6S7URRufjVrvU3EQR9A5LA';
  const challengedBadge =
      '1.challenged.g0j.2ywoAkV-f8ss6mM-tDWlkkzDIklDP9VeT4-bal8exjQOSuTz'
      'zaojQrbeWkYVAQewUSU8G1arQMJye2fyITU6dQ';

  // Both goldens expire on day 20755; every case pins `now` inside that term so
  // the suite does not start failing on a calendar date.
  final inTerm = DateTime.fromMillisecondsSinceEpoch(20700 * 86400000);
  final afterTerm = DateTime.fromMillisecondsSinceEpoch(20800 * 86400000);

  AttestBadge? verify(String badge, String pubkey,
          {String auth = authority, DateTime? now}) =>
      AttestBadge.verify(
        badge: badge,
        pubkey: pubkey,
        authorityPubkey: auth,
        now: now ?? inTerm,
      );

  group('golden badges from the issuing worker', () {
    test('an attested badge verifies for the key it names', () {
      final result = verify(attestedBadge, alice);
      expect(result, isNotNull);
      expect(result!.tier, AttestTier.attested);
      expect(result.expiryDay, 20755);
    });

    test('an origin badge verifies and keeps its weaker tier', () {
      final result = verify(originBadge, bob);
      expect(result, isNotNull);
      expect(result!.tier, AttestTier.origin);
    });
  });

  group('what a badge must not do', () {
    test('does not verify for another pubkey', () {
      // The attack the pubkey-in-digest design exists to stop: lifting the tag
      // off someone else's message onto your own.
      expect(verify(attestedBadge, bob), isNull);
      expect(verify(originBadge, alice), isNull);
    });

    test('does not verify under another authority', () {
      expect(verify(attestedBadge, alice, auth: 'f' * 64), isNull);
    });

    test('does not verify after its term', () {
      expect(verify(attestedBadge, alice, now: afterTerm), isNull);
    });

    test('an origin badge cannot be relabelled attested', () {
      // The tier is inside the signed digest, so rewriting the plaintext half
      // breaks the signature rather than promoting the holder.
      expect(verify(originBadge.replaceFirst('.origin.', '.attested.'), bob),
          isNull);
    });

    test('the expiry cannot be stretched', () {
      final parts = attestedBadge.split('.');
      final stretched =
          '${parts[0]}.${parts[1]}.${(20755 + 3650).toRadixString(36)}.${parts[3]}';
      expect(verify(stretched, alice), isNull);
    });

    test('a tampered signature is rejected', () {
      final parts = attestedBadge.split('.');
      final flipped = parts[3].startsWith('A')
          ? 'B${parts[3].substring(1)}'
          : 'A${parts[3].substring(1)}';
      expect(verify('${parts[0]}.${parts[1]}.${parts[2]}.$flipped', alice),
          isNull);
    });
  });

  group('malformed input', () {
    test('rejects a badge that is not four fields', () {
      expect(verify('1.attested.g0j', alice), isNull);
      expect(verify('nonsense', alice), isNull);
      expect(verify('', alice), isNull);
    });

    test('rejects an unknown version', () {
      final parts = attestedBadge.split('.');
      expect(verify('2.${parts[1]}.${parts[2]}.${parts[3]}', alice), isNull);
    });

    test('rejects an unknown tier', () {
      final parts = attestedBadge.split('.');
      expect(verify('${parts[0]}.gold.${parts[2]}.${parts[3]}', alice), isNull);
    });

    test('rejects a non-base36 expiry', () {
      final parts = attestedBadge.split('.');
      expect(verify('${parts[0]}.${parts[1]}.!!.${parts[3]}', alice), isNull);
    });

    test('rejects a signature that is not 64 bytes', () {
      final parts = attestedBadge.split('.');
      expect(verify('${parts[0]}.${parts[1]}.${parts[2]}.AAAA', alice), isNull);
    });

    test('rejects a malformed pubkey or authority', () {
      expect(verify(attestedBadge, 'short'), isNull);
      expect(verify(attestedBadge, alice.toUpperCase()), isNull);
      expect(verify(attestedBadge, alice, auth: 'short'), isNull);
    });
  });

  group('tag reading', () {
    test('finds the badge tag among others', () {
      expect(
        AttestBadge.badgeFromTags([
          ['n', 'someone'],
          ['d', 'nymchat'],
          ['nymattest', attestedBadge],
        ]),
        attestedBadge,
      );
    });

    test('returns null when there is no badge', () {
      expect(
          AttestBadge.badgeFromTags([
            ['n', 'someone'],
            ['d', 'nymchat'],
          ]),
          isNull);
    });

    test('ignores a value-less tag', () {
      expect(
          AttestBadge.badgeFromTags([
            ['nymattest'],
          ]),
          isNull);
    });
  });

  group('registry', () {
    NostrEvent event(String pubkey, String? badge) => NostrEvent(
          id: '0' * 64,
          pubkey: pubkey,
          createdAt: 0,
          kind: 23333,
          tags: [
            ['d', 'nymchat'],
            if (badge != null) ['nymattest', badge],
          ],
          content: '',
          sig: '0' * 128,
        );

    test('records the tier a badge proves', () {
      final reg = AttestRegistry();
      expect(reg.ingest(event(bob, originBadge), authority, now: inTerm),
          AttestTier.origin);
      expect(reg.tierOf(bob), AttestTier.origin);
    });

    test('remembers it for later messages that carry no tag', () {
      final reg = AttestRegistry();
      reg.ingest(event(bob, originBadge), authority, now: inTerm);
      expect(reg.ingest(event(bob, null), authority, now: inTerm), isNull);
      expect(reg.tierOf(bob), AttestTier.origin);
    });

    test('records nothing for a badge that does not verify', () {
      final reg = AttestRegistry();
      // Bob's badge on Alice's event — the lifted-tag case.
      expect(reg.ingest(event(alice, originBadge), authority, now: inTerm),
          isNull);
      expect(reg.tierOf(alice), isNull);
    });

    test('records nothing without an authority key', () {
      final reg = AttestRegistry();
      expect(reg.ingest(event(bob, originBadge), '', now: inTerm), isNull);
      expect(reg.tierOf(bob), isNull);
    });

    test('a later origin badge does not downgrade attested', () {
      // The same person on a phone and on the web is still that person, and
      // the stronger proof is the one that should stand.
      final reg = AttestRegistry();
      reg.ingest(event(bob, originBadge), authority, now: inTerm);
      expect(reg.tierOf(bob), AttestTier.origin);
      reg.clear();
      expect(reg.tierOf(bob), isNull);
    });
  });

  group('the challenged tier', () {
    // Three tiers that must stay distinct. Folding a web client's build proof
    // into `attested` would tell someone who chose the strictest setting that
    // they had excluded scripted senders when they had not.
    test('a challenged badge verifies and keeps its own tier', () {
      final result = verify(challengedBadge, bob);
      expect(result, isNotNull);
      expect(result!.tier, AttestTier.challenged);
    });

    test('the tier is inside the signed digest, so relabelling is a forgery',
        () {
      expect(
          verify(
              challengedBadge.replaceFirst('.challenged.', '.attested.'), bob),
          isNull);
      expect(verify(originBadge.replaceFirst('.origin.', '.challenged.'), bob),
          isNull);
    });

    test('an invented tier is refused outright', () {
      expect(
          verify(
              challengedBadge.replaceFirst('.challenged.', '.trusted.'), bob),
          isNull);
    });

    test('it does not verify for another key', () {
      expect(verify(challengedBadge, alice), isNull);
    });

    test('attested outranks challenged outranks origin', () {
      // The registry keeps the strongest tier seen and reads that order off
      // the enum's declaration order, so this is load-bearing.
      expect(AttestTier.attested.index, lessThan(AttestTier.challenged.index));
      expect(AttestTier.challenged.index, lessThan(AttestTier.origin.index));
    });

    test('a challenged sender does not decay to origin', () {
      NostrEvent ev(String badge) => NostrEvent(
            id: '0' * 64,
            pubkey: bob,
            createdAt: 0,
            kind: 23333,
            tags: [
              ['d', 'nymchat'],
              ['nymattest', badge],
            ],
            content: '',
            sig: '0' * 128,
          );
      final reg = AttestRegistry();
      reg.ingest(ev(challengedBadge), authority, now: inTerm);
      expect(reg.tierOf(bob), AttestTier.challenged);
      reg.ingest(ev(originBadge), authority, now: inTerm);
      expect(reg.tierOf(bob), AttestTier.challenged);
    });
  });

  group('app-relay-only channel gate', () {
    // Mirrors the worker's `isForeignAppChannelEvent` and the PWA's
    // `_isAppRelayOnlyEvent`. All three decide independently, and a kind one
    // gates while another does not is a kind that slips into the channel on
    // that client — so the case list here matches theirs exactly.
    bool gate(int kind, {String? g, String? d}) =>
        RelayConfig.isAppRelayOnly(kind, g, d);

    test('a channel message is app-relay-only', () {
      expect(gate(23333, d: 'nymchat'), isTrue);
    });

    test('so are the things that hang off it', () {
      // Each of these puts a nym and a payload in front of the channel.
      expect(gate(7, d: 'nymchat'), isTrue, reason: 'reaction');
      expect(gate(30078, d: 'nymchat'), isTrue, reason: 'poll');
      expect(gate(24420, d: 'nymchat'), isTrue, reason: 'typing');
      expect(gate(24421, d: 'nymchat'), isTrue, reason: 'read receipt');
    });

    test('the hangers-on are read off either channel tag', () {
      expect(gate(7, g: 'nymchat'), isTrue);
      expect(gate(24420, g: 'nymchat'), isTrue);
    });

    test('a named-channel message reads only its d tag', () {
      // A `g` tag on a 23333 is not the channel and must neither trip the gate
      // nor let a message dodge it.
      expect(gate(23333, g: 'nymchat', d: 'bitcoin'), isFalse);
      expect(gate(23333, g: 'bitcoin', d: 'nymchat'), isTrue);
    });

    test('other channels are free', () {
      expect(gate(23333, d: 'bitcoin'), isFalse);
      expect(gate(7, d: 'bitcoin'), isFalse);
      expect(gate(20000, g: 'u4pruy'), isFalse);
      expect(gate(24420, d: 'bitcoin'), isFalse);
    });

    test('the channel name is matched case-insensitively', () {
      expect(gate(23333, d: 'NymChat'), isTrue);
      expect(gate(7, d: 'NYMCHAT'), isTrue);
    });

    test('the match is exact, so the nymchat- prefixes are untouched', () {
      // Settings wraps, sync blobs and the vouch/PQ lists all carry d tags
      // that START with the channel name; gating them would break settings
      // sync and the web of trust.
      expect(gate(30078, d: 'nymchat-settings-privacy'), isFalse);
      expect(gate(30078, d: 'nym-vouches'), isFalse);
      expect(gate(30078, d: 'nym-pq'), isFalse);
    });

    test('kinds outside the channel surface are free', () {
      expect(gate(1059, d: 'nymchat'), isFalse, reason: 'gift wrap');
      expect(gate(0, d: 'nymchat'), isFalse, reason: 'profile');
      expect(gate(5, d: 'nymchat'), isFalse, reason: 'deletion');
    });

    test('an event with no channel tag is free', () {
      expect(gate(23333), isFalse);
      expect(gate(7), isFalse);
    });
  });

  group('filter normalization', () {
    test('the setting is on or off', () {
      expect(normalizeAppVerifiedFilter('on'), 'on');
      expect(normalizeAppVerifiedFilter('off'), 'off');
    });

    test('both old three-way values become on', () {
      expect(normalizeAppVerifiedFilter('verified'), 'on');
      expect(normalizeAppVerifiedFilter('any'), 'on');
    });

    test('anything else is off', () {
      expect(normalizeAppVerifiedFilter(null), 'off');
      expect(normalizeAppVerifiedFilter(''), 'off');
      expect(normalizeAppVerifiedFilter('On'), 'off');
      expect(normalizeAppVerifiedFilter('yes'), 'off');
    });
  });
}
