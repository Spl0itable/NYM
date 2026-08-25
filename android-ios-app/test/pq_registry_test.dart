// Discovery contract: the announcement format, expiry, and policy rules that
// decide which peers get post-quantum messages.
//
// The announcement fixtures come from test/pq-vectors.json, which the PWA emits
// from its own implementation — including the malformed variants, which BOTH
// clients must reject identically. A parser that is merely lenient in different
// places would leave the two apps disagreeing about who is post-quantum
// capable, which shows up as undeliverable messages rather than a test failure.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/ml_kem.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_registry.dart';
import 'package:nym_bar/features/identity/pq_root.dart';

Uint8List unhex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/pq-vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final a = v['announcement'] as Map<String, dynamic>;
  final author = a['authorPubkey'] as String;
  const before = 1900000000; // well inside the fixture's expiry
  const after = 2100000000; // past it

  group('PWA-produced announcement', () {
    test('parses, with the exact announced key', () {
      final ann = PqAnnouncement.parse(a['content'] as String);
      expect(ann, isNotNull);
      expect(hex(ann!.publicKey!), a['kemPublicKey']);
      expect(ann.publicKey!.length, mlKemPublicKeyLength);
      expect(ann.expiresAt, a['expiresAt']);
      expect(ann.epoch, a['epoch']);
      expect(ann.retracted, isFalse);
    });

    test('carries the device roster', () {
      final ann = PqAnnouncement.parse(a['content'] as String)!;
      expect(ann.devices.length, 2);
      expect(ann.devices.first.id, 'a1b2c3d4');
      // From the fixture, not pinned here: the emitter stamps the current
      // app version, so a hardcoded copy goes stale on every release.
      final roster = (jsonDecode(a['content'] as String)
          as Map<String, dynamic>)['devices'] as List<dynamic>;
      expect(ann.devices.first.version,
          (roster.first as Map<String, dynamic>)['ver']);
    });

    test('a retraction parses as retracted with no key', () {
      final ann = PqAnnouncement.parse(a['retractionContent'] as String);
      expect(ann, isNotNull);
      expect(ann!.retracted, isTrue);
      expect(ann.publicKey, isNull);
    });

    group('rejects malformed announcements', () {
      final invalid = a['invalid'] as Map<String, dynamic>;
      for (final entry in invalid.entries) {
        test(entry.key, () {
          final ann = PqAnnouncement.parse(entry.value as String);
          // 'expired' parses but must not survive registry ingest; the rest
          // must not parse at all.
          if (entry.key == 'expired') {
            final r = PqRegistry()
              ..ingest(author, entry.value as String, nowSec: before);
            expect(r.keyFor(author, nowSec: before, enabled: true), isNull);
          } else {
            expect(ann, isNull, reason: entry.key);
          }
        });
      }
    });
  });

  group('registry', () {
    PqRegistry freshRegistry() =>
        PqRegistry()..ingest(author, a['content'] as String, nowSec: before);

    test('ingests and returns the key', () {
      final key = freshRegistry().keyFor(author, nowSec: before, enabled: true);
      expect(key, isNotNull);
      expect(hex(key!), a['kemPublicKey']);
    });

    test('an unknown peer yields null, so sends fall back to classical', () {
      expect(freshRegistry().keyFor('f' * 64, nowSec: before, enabled: true),
          isNull);
    });

    test('an expired entry yields null and is evicted', () {
      final r = freshRegistry();
      expect(r.keyFor(author, nowSec: after, enabled: true), isNull);
      expect(r.knownPeers(nowSec: before), isEmpty);
    });

    test('disabled yields null even when a key is held', () {
      expect(freshRegistry().keyFor(author, nowSec: before, enabled: false),
          isNull);
    });

    test('a retraction drops the peer', () {
      final r = freshRegistry()
        ..ingest(author, a['retractionContent'] as String, nowSec: before);
      expect(r.keyFor(author, nowSec: before, enabled: true), isNull);
    });

    test('malformed content leaves an existing key untouched', () {
      final r = freshRegistry()..ingest(author, 'not json', nowSec: before);
      expect(r.keyFor(author, nowSec: before, enabled: true), isNotNull);
    });

    test('knownPeers lists only live entries', () {
      expect(freshRegistry().knownPeers(nowSec: before), [author]);
      expect(freshRegistry().knownPeers(nowSec: after), isEmpty);
    });

    test('evicts oldest past the cap', () {
      final r = PqRegistry(maxEntries: 2);
      final pk = unhex(a['kemPublicKey'] as String);
      for (var i = 0; i < 4; i++) {
        r.record(i.toString().padLeft(64, '0'), pk, after, 0);
      }
      expect(r.knownPeers(nowSec: before).length, lessThanOrEqualTo(2));
    });
  });

  // Persistence: a relaunch must not start cold. A cold registry fails
  // SILENTLY — every peer's next message goes out classical while discovery
  // re-runs — so the round-trip is asserted key-for-key rather than by count.
  group('persistence round-trip', () {
    Map<String, dynamic> encoded(PqRegistry r) =>
        jsonDecode(jsonEncode(r.toJson(nowSec: before))) as Map<String, dynamic>;

    test('a restored registry answers exactly like the original', () {
      final src = PqRegistry()..ingest(author, a['content'] as String, nowSec: before);
      final restored = PqRegistry()..hydrate(encoded(src), nowSec: before);
      final key = restored.keyFor(author, nowSec: before, enabled: true);
      expect(key, isNotNull);
      expect(hex(key!), a['kemPublicKey']);
    });

    test('a KEM-less entry survives as a Nymchat claim with no key', () {
      final src = PqRegistry()..record(author, null, after, 0);
      final restored = PqRegistry()..hydrate(encoded(src), nowSec: before);
      expect(restored.isKnownNymchatClient(author, nowSec: before), isTrue);
      expect(restored.keyFor(author, nowSec: before, enabled: true), isNull);
    });

    test('the epoch survives, so rotation windows still line up', () {
      final pk = unhex(a['kemPublicKey'] as String);
      final src = PqRegistry()..record(author, pk, after, 7);
      final json = encoded(src);
      expect((json[author] as List)[2], 7);
    });

    // The bound that matters most: a peer who moved from an nsec to a remote
    // signer holds no ML-KEM secret at all, so encapsulating to their stale key
    // makes the message UNREADABLE rather than merely classical.
    test('an expired entry is neither written nor restored', () {
      final pk = unhex(a['kemPublicKey'] as String);
      final src = PqRegistry()..record(author, pk, before - 1, 0);
      expect(src.toJson(nowSec: before), isEmpty);
      final restored = PqRegistry()
        ..hydrate({
          author: [pq.b64uEncode(pk), before - 1, 0]
        }, nowSec: before);
      expect(restored.keyFor(author, nowSec: before, enabled: true), isNull);
    });

    test('a fresher announcement supersedes what was restored', () {
      final stale = Uint8List(mlKemPublicKeyLength)..fillRange(0, mlKemPublicKeyLength, 9);
      final r = PqRegistry()
        ..hydrate({
          author: [pq.b64uEncode(stale), after, 0]
        }, nowSec: before)
        ..ingest(author, a['content'] as String, nowSec: before);
      expect(hex(r.keyFor(author, nowSec: before, enabled: true)!),
          a['kemPublicKey']);
    });

    // One bad row must not cost the whole cache: the surrounding entries are
    // the difference between a warm registry and a silently classical session.
    test('malformed rows are skipped individually', () {
      final pk = unhex(a['kemPublicKey'] as String);
      final r = PqRegistry()
        ..hydrate({
          'a' * 64: 'not a list',
          'b' * 64: [pq.b64uEncode(pk), 'not an int', 0],
          'c' * 64: [pq.b64uEncode(pk)], // too short
          'd' * 64: [pq.b64uEncode(Uint8List(32)), after, 0], // wrong length
          'e' * 64: [12345, after, 0], // pk not a string
          author: [pq.b64uEncode(pk), after, 0],
        }, nowSec: before);
      expect(r.knownPeers(nowSec: before), [author]);
    });

    test('an empty registry round-trips to an empty map', () {
      expect(PqRegistry().toJson(nowSec: before), isEmpty);
      expect(
          (PqRegistry()..hydrate({}, nowSec: before)).knownPeers(nowSec: before),
          isEmpty);
    });
  });

  group('policy', () {
    final sk = unhex('1' * 64);

    test('a local key is required to RECEIVE', () {
      expect(PqPolicy.capable(privkey: sk), isTrue);
      // Extension / NIP-46: no local secret key, so no ML-KEM keypair to
      // decapsulate with. Sending is a separate question — see the
      // 'send vs receive capability' group below.
      expect(PqPolicy.capable(privkey: null), isFalse);
      expect(PqPolicy.selfEnabled(privkey: null, mode: PqMode.on), isFalse);
    });

    test('enabled requires both capability and the mode', () {
      expect(PqPolicy.enabled(privkey: sk, mode: PqMode.on), isTrue);
      expect(PqPolicy.enabled(privkey: sk, mode: PqMode.off), isFalse);
    });

    test('post-quantum is on with no setting to enable', () {
      expect(PqPolicy.initialMode(seenBefore: false), PqMode.on);
      expect(PqPolicy.initialMode(seenBefore: true), PqMode.on);
    });

    test('only an upgrade raises the one-time notice', () {
      // An upgrade might have an older device on the same nsec that would
      // quietly stop receiving messages; that device publishes nothing, so it
      // is invisible to us and the user has to be told rather than detected.
      expect(PqPolicy.upgradeNoticeNeeded(seenBefore: true), isTrue);
      expect(PqPolicy.upgradeNoticeNeeded(seenBefore: false), isFalse);
    });

    test('device roster merges this device and drops stale ones', () {
      const now = 1800000000;
      final stale = PqDevice(
          id: 'old', version: 'v1', seenAt: now - pqDeviceStale.inSeconds - 1);
      final live = PqDevice(id: 'live', version: 'v2', seenAt: now - 100);
      final merged = PqPolicy.mergeDeviceRoster(
          [stale, live], 'me', 'v3', nowSec: now);
      expect(merged.map((d) => d.id), containsAll(<String>['me', 'live']));
      expect(merged.map((d) => d.id), isNot(contains('old')));
      expect(merged.first.id, 'me', reason: 'newest first');
    });

    test('re-merging replaces this device rather than duplicating it', () {
      const now = 1800000000;
      var roster = PqPolicy.mergeDeviceRoster([], 'me', 'v3', nowSec: now);
      roster = PqPolicy.mergeDeviceRoster(roster, 'me', 'v4', nowSec: now + 60);
      expect(roster.where((d) => d.id == 'me').length, 1);
      expect(roster.first.version, 'v4');
    });

    test('roster is capped', () {
      const now = 1800000000;
      var roster = <PqDevice>[];
      for (var i = 0; i < 40; i++) {
        roster = PqPolicy.mergeDeviceRoster(roster, 'd$i', 'v', nowSec: now + i);
      }
      expect(roster.length, lessThanOrEqualTo(16));
    });
  });

  // A self-addressed blob is encapsulated to a key derived from the nsec. A
  // device signed in with an extension or a NIP-46 signer holds no secret to
  // derive from, so a hybrid blob locks it out of its own settings and the sync
  // ping -- silently, and for good.
  group('all-devices gate', () {
    const now = 1800000000;
    PqDevice dev(String id, {required bool pq, int? seenAt}) => PqDevice(
        id: id, version: 'v1', seenAt: seenAt ?? now, postQuantumCapable: pq);

    test('an empty roster is no evidence of a second device', () {
      // The single-device account is the common case and must not be
      // downgraded by the absence of an answer.
      expect(PqPolicy.allDevicesCapable(const [], 'me', nowSec: now), isTrue);
    });

    test('all-capable devices allow the hybrid', () {
      expect(
          PqPolicy.allDevicesCapable(
              [dev('me', pq: true), dev('other', pq: true)], 'me',
              nowSec: now),
          isTrue);
    });

    test('one signer-only device closes the gate', () {
      expect(
          PqPolicy.allDevicesCapable(
              [dev('me', pq: true), dev('extension', pq: false)], 'me',
              nowSec: now),
          isFalse);
    });

    test('our own entry never gates us', () {
      expect(PqPolicy.allDevicesCapable([dev('me', pq: false)], 'me', nowSec: now),
          isTrue);
    });

    test('a stale device stops holding the account back', () {
      expect(
          PqPolicy.allDevicesCapable(
              [dev('gone', pq: false, seenAt: now - pqDeviceStale.inSeconds - 1)],
              'me',
              nowSec: now),
          isTrue);
    });

    test('a device from a build without the flag counts as incapable', () {
      // Guessing "capable" is what locks a device out of its own settings; the
      // cost of guessing the other way is the encryption these blobs had
      // before the hybrid, and it heals as devices update.
      final old = PqDevice.fromJson({'id': 'old', 'ver': 'v3.74.500', 'ts': now});
      expect(old!.postQuantumCapable, isFalse);
      expect(PqPolicy.allDevicesCapable([old], 'me', nowSec: now), isFalse);
    });

    test('the capability flag survives a roster round-trip', () {
      final roster = PqPolicy.mergeDeviceRoster([], 'me', 'v3',
          nowSec: now, capable: true);
      final back = PqDevice.fromJson(roster.single.toJson());
      expect(back!.postQuantumCapable, isTrue);
      expect(
          PqDevice.fromJson(
                  PqPolicy.mergeDeviceRoster([], 'me', 'v3', nowSec: now)
                      .single
                      .toJson())!
              .postQuantumCapable,
          isFalse);
    });
  });

  group('send-path routing (PqPmPlan)', () {
    // The rule both PM send paths share, and the PWA's pqPmPlan must agree with
    // it. Getting this wrong is how a message ends up ALSO sent classically,
    // silently voiding the post-quantum guarantee while the UI still claims it.
    final key = unhex(a['kemPublicKey'] as String);

    PqPmPlan plan({Uint8List? kem, bool bitchat = false, bool nym = false}) =>
        PqPmPlan.decide(
            recipientKemKey: kem, knownBitchat: bitchat, knownNym: nym);

    test('unknown peer, no key: bitchat + classical nym (today\'s behaviour)', () {
      final p = plan();
      expect(p.pq, isFalse);
      expect(p.bitchat, isTrue);
      expect(p.nym, isTrue);
    });

    test('known bitchat peer: bitchat only, never post-quantum', () {
      final p = plan(bitchat: true);
      expect(p.pq, isFalse);
      expect(p.bitchat, isTrue);
      expect(p.nym, isFalse);
    });

    test('known nym peer without a key: classical nym only', () {
      final p = plan(nym: true);
      expect(p.pq, isFalse);
      expect(p.bitchat, isFalse);
      expect(p.nym, isTrue);
    });

    test('unknown peer WITH a key: post-quantum, no bitchat copy', () {
      final p = plan(kem: key);
      expect(p.pq, isTrue);
      expect(p.nym, isTrue);
      expect(p.bitchat, isFalse);
    });

    test('a bitchat-flagged peer WITH a key gets no classical copy alongside', () {
      // The dangerous case: sending both would leak the same plaintext to the
      // weaker copy, handing a future quantum attacker the easier target.
      final p = plan(kem: key, bitchat: true);
      expect(p.pq, isTrue);
      expect(p.bitchat, isFalse);
    });

    test('known nym peer with a key: post-quantum, no bitchat copy', () {
      final p = plan(kem: key, nym: true);
      expect(p.pq, isTrue);
      expect(p.nym, isTrue);
      expect(p.bitchat, isFalse);
    });

    test('the plan carries the key it decided with', () {
      expect(hex(plan(kem: key).kemPublicKey!), a['kemPublicKey']);
    });

    test('with no key, routing is exactly the pre-existing behaviour', () {
      // Post-quantum off is modelled as "no key" — PqRegistry.keyFor already
      // returns null when disabled, so this is the disabled path too.
      for (final combo in [
        (false, false),
        (true, false),
        (false, true),
      ]) {
        final withPq = plan(kem: null, bitchat: combo.$1, nym: combo.$2);
        expect(withPq.pq, isFalse);
      }
    });
  });

  group('capability announcements without a key', () {
    // The case that motivates splitting the signals: a Nymchat user who has
    // post-quantum off, or is on an extension login that cannot do it at all.
    // They are provably not on Bitchat, so the Bitchat wrap is waste.
    final kemLess = jsonEncode({
      'v': 1,
      'alg': 'mlkem768',
      'nym': 1,
      'epoch': 0,
      'exp': 2000000000,
    });

    test('parses as a valid announcement, not a retraction', () {
      final ann = PqAnnouncement.parse(kemLess);
      expect(ann, isNotNull);
      expect(ann!.retracted, isFalse);
      expect(ann.publicKey, isNull);
    });

    test('proves the peer runs Nymchat but offers no key', () {
      final r = PqRegistry()..ingest(author, kemLess, nowSec: before);
      expect(r.isKnownNymchatClient(author, nowSec: before), isTrue);
      expect(r.keyFor(author, nowSec: before, enabled: true), isNull);
    });

    test('does not count as a post-quantum peer', () {
      final r = PqRegistry()..ingest(author, kemLess, nowSec: before);
      expect(r.knownPeers(nowSec: before), isEmpty);
    });

    test('a KEM-bearing announcement counts as both', () {
      final r = PqRegistry()
        ..ingest(author, a['content'] as String, nowSec: before);
      expect(r.isKnownNymchatClient(author, nowSec: before), isTrue);
      expect(r.knownPeers(nowSec: before), [author]);
    });

    test('expiry drops the Nymchat claim too', () {
      final r = PqRegistry()..ingest(author, kemLess, nowSec: before);
      expect(r.isKnownNymchatClient(author, nowSec: after), isFalse);
    });

    test('a retraction still withdraws everything', () {
      final r = PqRegistry()
        ..ingest(author, kemLess, nowSec: before)
        ..ingest(author, a['retractionContent'] as String, nowSec: before);
      expect(r.isKnownNymchatClient(author, nowSec: before), isFalse);
    });

    test('capability is not gated on our own post-quantum setting', () {
      // It answers "which client is this?", not "should we use post-quantum?".
      final r = PqRegistry()..ingest(author, kemLess, nowSec: before);
      expect(r.isKnownNymchatClient(author, nowSec: before), isTrue);
      expect(r.keyFor(author, nowSec: before, enabled: false), isNull);
    });
  });

  group('Bitchat wrap suppression', () {
    // No setting: a live announcement proves the peer is not on Bitchat, so
    // the extra copy is dropped. Anyone we cannot prove gets exactly what they
    // got before post-quantum existed.
    final key = unhex(a['kemPublicKey'] as String);

    PqPmPlan plan({
      Uint8List? kem,
      bool bitchat = false,
      bool nym = false,
      bool proven = false,
    }) =>
        PqPmPlan.decide(
          recipientKemKey: kem,
          knownBitchat: bitchat,
          knownNym: nym,
          provenNymchat: proven,
        );

    test('a proven Nymchat peer gets no Bitchat wrap', () {
      expect(plan(proven: true).bitchat, isFalse);
    });

    test('a post-quantum wrap is never paired with a Bitchat copy', () {
      final p = plan(kem: key);
      expect(p.pq, isTrue);
      expect(p.bitchat, isFalse);
    });

    test('a known Bitchat peer with no announcement still gets one', () {
      expect(plan(bitchat: true).bitchat, isTrue);
    });

    test('an announcement overrides a stale bitchat flag', () {
      expect(plan(bitchat: true, proven: true).bitchat, isFalse);
    });

    test('an unknown peer keeps the pre-existing dual-send', () {
      final p = plan();
      expect(p.bitchat, isTrue);
      expect(p.nym, isTrue);
    });

    test('a KEM key implies a proven Nymchat client', () {
      // Callers cannot pass an inconsistent pair.
      expect(plan(kem: key).provenNym, isTrue);
    });

    test('every peer state produces at least one transport', () {
      // A silent no-send is the worst failure here: no error, no retry, the
      // message simply never exists.
      for (final setup in [
        () => plan(),
        () => plan(bitchat: true),
        () => plan(nym: true),
        () => plan(proven: true),
        () => plan(kem: key),
      ]) {
        final p = setup();
        expect(p.bitchat || p.nym, isTrue);
      }
    });
  });

  group('group coverage', () {
    test('only full coverage counts as post-quantum', () {
      expect(groupIsProtected((pq: 10, total: 10)), isTrue);
    });
    test('partial coverage does NOT count', () {
      // One classical copy of the same plaintext is enough for an attacker, so
      // "8 of 10" must not render as protected.
      expect(groupIsProtected((pq: 8, total: 10)), isFalse);
      expect(groupIsProtected((pq: 9, total: 10)), isFalse);
    });
    test('zero coverage does not count', () {
      expect(groupIsProtected((pq: 0, total: 10)), isFalse);
    });
    test('an empty group is not protected', () {
      expect(groupIsProtected((pq: 0, total: 0)), isFalse);
    });
    test('unknown coverage is not protected', () {
      expect(groupIsProtected(null), isFalse);
    });
  });

  group('self candidates', () {
    final sk = unhex('2' * 64);

    test('current epoch first, then a bounded window of previous ones', () {
      final cands = pqSelfCandidates(sk, 5);
      expect(cands.length, pqPreviousEpochs + 1);
      expect(hex(cands.first.kemPk), hex(pq.pqKeypairFromPrivkey(sk, 5).publicKey));
      expect(hex(cands.last.kemPk), hex(pq.pqKeypairFromPrivkey(sk, 2).publicKey));
    });

    test('does not run past epoch 0', () {
      expect(pqSelfCandidates(sk, 1).length, 2);
      expect(pqSelfCandidates(sk, 0).length, 1);
    });

    test('a wrap to the previous epoch still opens after rotation', () {
      final oldKp = pq.pqKeypairFromPrivkey(sk, 0);
      final senderSk = unhex('3' * 64);
      final payload = pq.pqEncrypt('pre-rotation', senderSk,
          getPublicKeyHex(sk), oldKp.publicKey);
      final cands = pqSelfCandidates(sk, 1);
      String? recovered;
      for (final c in cands) {
        try {
          recovered = pq.pqDecrypt(payload, getPublicKeyHex(senderSk),
              pq.PqIdentity(privkey: sk, kemSecretKey: c.kemSk, kemPublicKey: c.kemPk));
          break;
        } catch (_) {/* try the next epoch */}
      }
      expect(recovered, 'pre-rotation');
    });
  });

  group('send vs receive capability', () {
    // The two are different questions, and the difference is exactly what an
    // extension / NIP-46 login can and cannot do.
    //
    // A NIP-17 message is a SEAL under the identity key inside a WRAP under a
    // throwaway key the client generates itself. Only the seal needs the
    // signer, so such a login can still hybridize the wrap — and the wrap is
    // what a recorder stores, so that already defeats harvest-now-decrypt-later.
    // Receiving is another matter: the ML-KEM keypair derives from the nsec,
    // and opening a message means decapsulating with its secret half.
    final nsec = Uint8List.fromList(List.generate(32, (i) => i + 1));

    test('an nsec login does both', () {
      expect(PqPolicy.capable(privkey: nsec), isTrue);
      expect(PqPolicy.sendCapable(), isTrue);
      expect(PqPolicy.enabled(privkey: nsec, mode: PqMode.on), isTrue);
      expect(PqPolicy.selfEnabled(privkey: nsec, mode: PqMode.on), isTrue);
    });

    test('a signer login sends but cannot receive', () {
      expect(PqPolicy.capable(privkey: null), isFalse);
      expect(PqPolicy.enabled(privkey: null, mode: PqMode.on), isTrue);
    });

    test('and never encrypts its own copies post-quantum', () {
      // Self-wraps, the archive and synced settings are addressed to US, so
      // encapsulating to a key we cannot decapsulate with would lock this
      // device out of its own history — permanently.
      expect(PqPolicy.selfEnabled(privkey: null, mode: PqMode.on), isFalse);
    });

    test('the escape hatch still turns everything off', () {
      expect(PqPolicy.enabled(privkey: nsec, mode: PqMode.off), isFalse);
      expect(PqPolicy.enabled(privkey: null, mode: PqMode.off), isFalse);
      expect(PqPolicy.selfEnabled(privkey: nsec, mode: PqMode.off), isFalse);
    });
  });

  // PQ-ROOT-SPEC §3. `src` is the only thing separating a key an adversary can
  // reconstruct from the npub from one they cannot, so leniency here is a bug.
  group('announcement v2 (src)', () {
    final pk = pq.pqKeypairFromRoot(unhex('5a' * 32), 0).publicKey;

    String encoded({required bool rootSeeded}) => PqAnnouncement.encode(
          publicKey: pk,
          expiresAt: 2000000000,
          epoch: 0,
          devices: const [],
          rootSeeded: rootSeeded,
        );

    test('a root-seeded announcement is v:2 with src:"root"', () {
      final json =
          jsonDecode(encoded(rootSeeded: true)) as Map<String, dynamic>;
      expect(json['v'], 2);
      expect(json['src'], 'root');
      expect(json['alg'], 'mlkem768');
      expect(json['nym'], 1);
      final ann = PqAnnouncement.parse(encoded(rootSeeded: true))!;
      expect(ann.rootSeeded, isTrue);
      expect(hex(ann.publicKey!), hex(pk));
    });

    // An unlinked device must keep emitting exactly what it emitted before.
    test('a legacy announcement stays v:1 and carries no src', () {
      final json =
          jsonDecode(encoded(rootSeeded: false)) as Map<String, dynamic>;
      expect(json['v'], 1);
      expect(json.containsKey('src'), isFalse);
      expect(PqAnnouncement.parse(encoded(rootSeeded: false))!.rootSeeded,
          isFalse);
    });

    test('the PWA fixture, which predates v2, reads as legacy', () {
      expect(PqAnnouncement.parse(a['content'] as String)!.rootSeeded, isFalse);
    });

    // "Parsers MUST treat an unknown `src` as legacy, never as root."
    for (final variant in <String, dynamic>{
      'src omitted': null,
      'src is another word': 'nsec',
      'src is a future value': 'kyber-root-v3',
      'src is the empty string': '',
      'src is not a string': 1,
      'src is a list': ['root'],
      'src is capitalised': 'Root',
      'src has whitespace': ' root',
    }.entries) {
      test('v:2 but ${variant.key} → legacy', () {
        final content = jsonEncode({
          'v': 2,
          'alg': 'mlkem768',
          'nym': 1,
          'epoch': 0,
          'pk': pq.b64uEncode(pk),
          'exp': 2000000000,
          if (variant.value != null) 'src': variant.value,
          'devices': const [],
        });
        final ann = PqAnnouncement.parse(content);
        expect(ann, isNotNull, reason: 'it is still a valid announcement');
        expect(ann!.rootSeeded, isFalse, reason: variant.key);
      });
    }

    test('v:1 claiming src:"root" is still legacy', () {
      final content = jsonEncode({
        'v': 1,
        'alg': 'mlkem768',
        'nym': 1,
        'epoch': 0,
        'pk': pq.b64uEncode(pk),
        'exp': 2000000000,
        'src': 'root',
        'devices': const [],
      });
      expect(PqAnnouncement.parse(content)!.rootSeeded, isFalse,
          reason: 'both halves are required: v:2 AND src=="root"');
    });

    test('a v:2 announcement keeps parsing everything v:1 did', () {
      final content = PqAnnouncement.encode(
        publicKey: pk,
        expiresAt: 2000000000,
        epoch: 4,
        devices: const [
          PqDevice(id: 'aa11bb22', version: 'v9', seenAt: 1700000000,
              postQuantumCapable: true)
        ],
        rootSeeded: true,
      );
      final ann = PqAnnouncement.parse(content)!;
      expect(ann.epoch, 4);
      expect(ann.expiresAt, 2000000000);
      expect(ann.devices.single.id, 'aa11bb22');
      expect(ann.devices.single.postQuantumCapable, isTrue);
      expect(ann.rootSeeded, isTrue);
    });

    test('a retraction is never root-seeded', () {
      final ann = PqAnnouncement.parse(PqAnnouncement.encodeRetraction(1))!;
      expect(ann.retracted, isTrue);
      expect(ann.rootSeeded, isFalse);
    });
  });

  // A record whose fingerprint the other app cannot reproduce reads there as
  // NO record — and a device that believes there is no record generates a
  // second root, splitting the account.
  group('root fingerprint parity with the PWA', () {
    final vectors = (jsonDecode(File('test/pq-vectors.json').readAsStringSync())
        as Map<String, dynamic>)['v2']['rootFingerprint'] as List<dynamic>;

    test('every vector reproduces byte for byte', () {
      expect(vectors, isNotEmpty);
      for (final v in vectors) {
        final m = v as Map<String, dynamic>;
        expect(pq.pqRootFingerprint(unhex(m['root'] as String)), m['fp'],
            reason: m['root'] as String);
      }
    });

    test('different roots do not collide', () {
      final seen = <String>{};
      for (final v in vectors) {
        seen.add(pq.pqRootFingerprint(unhex((v as Map)['root'] as String)));
      }
      expect(seen.length, vectors.length);
    });

    test('a wrong-length root is refused rather than fingerprinted', () {
      expect(() => pq.pqRootFingerprint(Uint8List(31)), throwsArgumentError);
    });

    test('a published record carries the fingerprint', () {
      final root = unhex((vectors.first as Map)['root'] as String);
      final json = PqRootRecord.forRoot(root).toJson();
      expect(json['fp'], (vectors.first as Map)['fp']);
      expect(json['v'], 2);
      expect(json['ts'], isA<int>());
    });

    test('and the round trip keeps it', () {
      final root = unhex((vectors.first as Map)['root'] as String);
      final back = PqRootRecord.fromJson(PqRootRecord.forRoot(root).toJson())!;
      expect(back.isValid, isTrue);
      expect(back.matches(root), isTrue);
      expect(back.matches(unhex((vectors[1] as Map)['root'] as String)),
          isFalse);
    });

    test('adding a wrap does not drop the fingerprint', () {
      final root = unhex((vectors.first as Map)['root'] as String);
      final rec = PqRootRecord.forRoot(root)
          .withWrap(const PqRootWrap(type: pqRootWrapPasskey, blob: 'enc:v1:aa:bb'));
      expect(rec.fp, (vectors.first as Map)['fp']);
      expect(rec.isValid, isTrue);
    });

    // This is the shape the PWA rejects outright.
    test('a record with no fingerprint is not valid', () {
      expect(const PqRootRecord().isValid, isFalse);
      expect(PqRootRecord.fromJson({'v': 2, 'wraps': []})!.isValid, isFalse);
    });
  });

  // The badge is only as honest as what the registry remembers. Losing the
  // flag anywhere along here turns a legacy key into a full shield, or a
  // root-seeded one into a needless downgrade.
  group('the registry carries root-seeded through', () {
    final pk = pq.pqKeypairFromRoot(unhex('5a' * 32), 0).publicKey;
    final peer = 'ab' * 32;
    const now = 1700000000;
    const exp = 2000000000;

    String content({required bool rootSeeded}) => PqAnnouncement.encode(
          publicKey: pk,
          expiresAt: exp,
          epoch: 0,
          devices: const [],
          rootSeeded: rootSeeded,
        );

    test('ingest keeps the flag rather than dropping it at the door', () {
      final r = PqRegistry()
        ..ingest(peer, content(rootSeeded: true), nowSec: now);
      expect(r.isRootSeeded(peer, nowSec: now, enabled: true), isTrue);
    });

    test('a legacy announcement stays legacy', () {
      final r = PqRegistry()
        ..ingest(peer, content(rootSeeded: false), nowSec: now);
      expect(r.isRootSeeded(peer, nowSec: now, enabled: true), isFalse);
    });

    test('an unknown peer is not root-seeded', () {
      expect(PqRegistry().isRootSeeded(peer, nowSec: now, enabled: true),
          isFalse);
    });

    test('an expired entry is not root-seeded', () {
      final r = PqRegistry()
        ..ingest(peer, content(rootSeeded: true), nowSec: now);
      expect(r.isRootSeeded(peer, nowSec: exp + 1, enabled: true), isFalse);
    });

    test('post-quantum off answers no, like keyFor', () {
      final r = PqRegistry()
        ..ingest(peer, content(rootSeeded: true), nowSec: now);
      expect(r.isRootSeeded(peer, nowSec: now, enabled: false), isFalse);
    });

    test('a KEM-less entry is never root-seeded', () {
      final r = PqRegistry()..record(peer, null, exp, 0, rootSeeded: true);
      expect(r.isRootSeeded(peer, nowSec: now, enabled: true), isFalse,
          reason: 'there is no key to protect');
    });

    // Without this a restart reads every peer as legacy and downgrades their
    // shields until a fresh announcement lands.
    test('the flag survives the cache round trip', () {
      final r = PqRegistry()
        ..ingest(peer, content(rootSeeded: true), nowSec: now);
      final back = PqRegistry()..hydrate(r.toJson(nowSec: now), nowSec: now);
      expect(back.isRootSeeded(peer, nowSec: now, enabled: true), isTrue);
    });

    test('and a legacy peer is not resurrected as root-seeded', () {
      final r = PqRegistry()
        ..ingest(peer, content(rootSeeded: false), nowSec: now);
      final back = PqRegistry()..hydrate(r.toJson(nowSec: now), nowSec: now);
      expect(back.isRootSeeded(peer, nowSec: now, enabled: true), isFalse);
    });

    test('a row written before the flag existed reads as legacy', () {
      final legacyRow = {
        peer: [pq.b64uEncode(pk), exp, 0]
      };
      final back = PqRegistry()..hydrate(legacyRow, nowSec: now);
      expect(back.keyFor(peer, nowSec: now, enabled: true), isNotNull);
      expect(back.isRootSeeded(peer, nowSec: now, enabled: true), isFalse);
    });
  });
}

// Group coverage: a group message is post-quantum only when EVERY member got a
// post-quantum wrap. Partial coverage must not read as protected — one
// classical copy of the same plaintext is all an attacker needs.
bool groupIsProtected(({int pq, int total})? coverage) =>
    coverage != null && coverage.total > 0 && coverage.pq == coverage.total;
