import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/messages/trust_graph.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

// Deterministic 64-hex pubkeys for the trust-graph tests.
const _self = '0000000000000000000000000000000000000000000000000000000000001a2b';
const _stranger =
    '11111111111111111111111111111111111111111111111111111111deadbeef';
const _vouchedA =
    '2222222222222222222222222222222222222222222222222222222222223c4d';
const _vouchedB =
    '33333333333333333333333333333333333333333333333333333333000099ff';
const _friend =
    '4444444444444444444444444444444444444444444444444444444444445e6f';

Message _chanMsg(String pubkey, {String id = 'x', bool isOwn = false}) => Message(
      id: id,
      pubkey: pubkey,
      author: 'nym#${pubkey.substring(pubkey.length - 4)}',
      content: 'hello',
      createdAt: 1000,
      isOwn: isOwn,
      channel: 'nymchat',
    );

void main() {
  // These tests exercise the spam-gate logic directly; the gate is OFF by
  // default in production (held pending PoW-on-send + persistence), so enable it
  // for the file and reset after.
  setUp(() => nymVouchSpamGateEnabled = true);
  tearDown(() => nymVouchSpamGateEnabled = false);

  group('nym-vouch protocol shape (PWA parity)', () {
    test('vouch event uses kind 30078 + the nym-vouches topic', () {
      // nostr-core.js publishNymchatVouches: kind 30078, tags
      // [['d','nym-vouches'],['t','nym-vouches']].
      expect(EventKind.appData, 30078);
      expect(AppDataTopic.vouches, 'nym-vouches');
    });

    test('content is a JSON array of pubkeys, parsed back by parseVouchList', () {
      // Round-trip the exact content shape publishVouches writes
      // (jsonEncode(list)) through the ingest parser.
      final content = jsonEncode([_vouchedA, _vouchedB]);
      final parsed = TrustGraph.parseVouchList(jsonDecode(content));
      expect(parsed, [_vouchedA, _vouchedB]);
    });
  });

  group('TrustGraph (pure helpers)', () {
    test('isHex64 accepts 64-hex (any case), rejects everything else', () {
      expect(TrustGraph.isHex64(_stranger), isTrue);
      expect(TrustGraph.isHex64(_stranger.toUpperCase()), isTrue);
      expect(TrustGraph.isHex64('abc'), isFalse); // too short
      expect(TrustGraph.isHex64('${_stranger}00'), isFalse); // too long
      expect(TrustGraph.isHex64('z' * 64), isFalse); // non-hex
      expect(TrustGraph.isHex64(''), isFalse);
    });

    test('add returns true only on first insert; never adds self', () {
      final set = <String>{};
      expect(TrustGraph.add(set, _stranger, selfPubkey: _self), isTrue);
      expect(TrustGraph.add(set, _stranger, selfPubkey: _self), isFalse);
      expect(TrustGraph.add(set, _self, selfPubkey: _self), isFalse);
      expect(TrustGraph.add(set, '', selfPubkey: _self), isFalse);
      expect(set, {_stranger});
    });

    test('add trims oldest-first once over the cap', () {
      final set = <String>{};
      // Insert maxEntries + 1 distinct keys; the set should trim to trimEntries.
      for (var i = 0; i <= TrustGraph.maxEntries; i++) {
        final pk = i.toRadixString(16).padLeft(64, '0');
        TrustGraph.add(set, pk);
      }
      expect(set.length, TrustGraph.trimEntries);
      // The earliest-inserted key (index 0) was dropped; the last survives.
      expect(set.contains('0'.padLeft(64, '0')), isFalse);
      expect(
        set.contains(TrustGraph.maxEntries.toRadixString(16).padLeft(64, '0')),
        isTrue,
      );
    });

    test('parseVouchList keeps valid non-self hex64, drops the rest', () {
      final list = TrustGraph.parseVouchList(
        [_vouchedA, 'not-hex', 123, _self, _vouchedB.toUpperCase()],
        selfPubkey: _self,
      );
      expect(list, [_vouchedA, _vouchedB.toUpperCase()]);
    });

    test('parseVouchList on non-array content yields empty', () {
      expect(TrustGraph.parseVouchList('nope'), isEmpty);
      expect(TrustGraph.parseVouchList(<String, dynamic>{}), isEmpty);
      expect(TrustGraph.parseVouchList(null), isEmpty);
    });
  });

  group('AppState.isSpamGated (gating predicate)', () {
    // A live store seeds only the dev/bot roots into the trust graph.
    AppState live() {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      return n.state;
    }

    test('un-vouched stranger is gated', () {
      expect(live().isSpamGated(_chanMsg(_stranger)), isTrue);
    });

    test('own message is never gated', () {
      expect(live().isSpamGated(_chanMsg(_self, isOwn: true)), isFalse);
    });

    test('a sender in the trust graph (nymchatPubkeys) is not gated', () {
      final s = live();
      s.nymchatPubkeys.add(_stranger);
      expect(s.isSpamGated(_chanMsg(_stranger)), isFalse);
    });

    test('a friend is not gated', () {
      final s = live();
      s.friends.add(_friend);
      expect(s.isSpamGated(_chanMsg(_friend)), isFalse);
    });

    test('an earned-trust sender (trustedPubkeys) is not gated', () {
      final s = live();
      s.trustedPubkeys.add(_stranger);
      expect(s.isSpamGated(_chanMsg(_stranger)), isFalse);
    });

    test('the verified developer + bot roots are exempt', () {
      final s = live();
      expect(s.isSpamGated(_chanMsg(kVerifiedDeveloperPubkey)), isFalse);
      expect(s.isSpamGated(_chanMsg(kNymbotPubkey)), isFalse);
    });

    test('isMessageFiltered hides a gated stranger but not the dev root', () {
      final s = live();
      expect(s.isMessageFiltered(_chanMsg(_stranger)), isTrue);
      expect(s.isMessageFiltered(_chanMsg(kVerifiedDeveloperPubkey)), isFalse);
    });
  });

  group('AppStateNotifier — vouch ingest (rooted web of trust)', () {
    test('a vouch from an UN-rooted author is rejected', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      final added = n.ingestVouchList(
        authorPubkey: _stranger, // not in nymchatPubkeys
        vouchedPubkeys: [_vouchedA],
      );
      expect(added, isFalse);
      expect(n.state.nymchatPubkeys.contains(_vouchedA), isFalse);
    });

    test('a vouch from a ROOTED author (dev) adds its pubkeys to the graph', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      final added = n.ingestVouchList(
        authorPubkey: kVerifiedDeveloperPubkey, // a seeded root
        vouchedPubkeys: [_vouchedA, _vouchedB, _self], // self is skipped
      );
      expect(added, isTrue);
      expect(n.state.nymchatPubkeys.contains(_vouchedA), isTrue);
      expect(n.state.nymchatPubkeys.contains(_vouchedB), isTrue);
      expect(n.state.nymchatPubkeys.contains(_self), isFalse);
    });

    test('transitive expansion: a newly-trusted author can then vouch', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      // Root vouches for A → A becomes trusted.
      n.ingestVouchList(
        authorPubkey: kNymbotPubkey,
        vouchedPubkeys: [_vouchedA],
      );
      // A (now rooted) vouches for B → B is accepted (one hop out).
      final added = n.ingestVouchList(
        authorPubkey: _vouchedA,
        vouchedPubkeys: [_vouchedB],
      );
      expect(added, isTrue);
      expect(n.state.nymchatPubkeys.contains(_vouchedB), isTrue);
    });

    test('re-ingesting the same vouch list reports no new additions', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      n.ingestVouchList(
        authorPubkey: kVerifiedDeveloperPubkey,
        vouchedPubkeys: [_vouchedA],
      );
      final again = n.ingestVouchList(
        authorPubkey: kVerifiedDeveloperPubkey,
        vouchedPubkeys: [_vouchedA],
      );
      expect(again, isFalse);
    });

    test('ingesting a vouch reveals the now-trusted sender messages', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      // A stranger's message is gated.
      expect(n.state.isMessageFiltered(_chanMsg(_vouchedA)), isTrue);
      // The dev root vouches for them → no longer filtered.
      n.ingestVouchList(
        authorPubkey: kVerifiedDeveloperPubkey,
        vouchedPubkeys: [_vouchedA],
      );
      expect(n.state.isMessageFiltered(_chanMsg(_vouchedA)), isFalse);
    });
  });

  group('AppStateNotifier — observe + earned trust', () {
    test('observeNymchatPubkey records into our own vouch list', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      expect(n.observeNymchatPubkey(_stranger), isTrue);
      expect(n.observeNymchatPubkey(_stranger), isFalse); // dup
      expect(n.observeNymchatPubkey(_self), isFalse); // never self
      expect(n.state.nymchatVouches, {_stranger});
    });

    test('markNymchatPubkey adds to the graph and ungates the sender', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      expect(n.state.isMessageFiltered(_chanMsg(_stranger)), isTrue);
      expect(n.markNymchatPubkey(_stranger), isTrue);
      expect(n.state.isMessageFiltered(_chanMsg(_stranger)), isFalse);
    });

    test('trackPubkeyMessage trusts a sender after >=2 distinct messages', () {
      final n = AppStateNotifier()..goLive(_self, 'you#1a2b');
      // First message: not yet trusted.
      expect(n.trackPubkeyMessage(_stranger, 'evt1'), isFalse);
      expect(n.state.trustedPubkeys.contains(_stranger), isFalse);
      // A duplicate id doesn't advance the count.
      expect(n.trackPubkeyMessage(_stranger, 'evt1'), isFalse);
      // Second distinct message: crosses into trust.
      expect(n.trackPubkeyMessage(_stranger, 'evt2'), isTrue);
      expect(n.state.trustedPubkeys.contains(_stranger), isTrue);
      // Now ungated.
      expect(n.state.isMessageFiltered(_chanMsg(_stranger)), isFalse);
    });
  });
}
