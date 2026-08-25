// The post-quantum root secret (docs/PQ-ROOT-SPEC.md §1-§7).
//
// The derivation is checked against an INDEPENDENT HKDF built here from
// package:crypto, so it is a real known-answer test of the pinned salt and
// info strings rather than a restatement of the implementation.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_registry.dart';
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';

Uint8List _bytes(int fill, [int n = 32]) =>
    Uint8List.fromList(List<int>.filled(n, fill));

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// RFC 5869 HKDF-SHA256, independent of the code under test.
Uint8List _hkdf(String salt, List<int> ikm, String info, int length) {
  final prk = c.Hmac(c.sha256, utf8.encode(salt)).convert(ikm).bytes;
  final out = <int>[];
  var t = <int>[];
  var counter = 1;
  while (out.length < length) {
    t = c.Hmac(c.sha256, prk)
        .convert([...t, ...utf8.encode(info), counter])
        .bytes;
    out.addAll(t);
    counter++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

void main() {
  final root = _bytes(0x5a);
  final privkey = _bytes(0x11);

  group('§2 derivation', () {
    test('the seed is HKDF over the pinned salt and info', () {
      for (final epoch in [0, 1, 7]) {
        expect(
          _hex(pq.pqRootDeriveSeed(root, epoch)),
          _hex(_hkdf('nym-pq-root-v2', root, 'mlkem768/epoch/$epoch', 64)),
          reason: 'epoch $epoch',
        );
      }
    });

    test('the salt is exactly the spec\'s, not v1\'s', () {
      expect(pq.pqRootSeedSalt, 'nym-pq-root-v2');
      expect(pq.pqSeedSalt, 'nym-pq-v1');
    });

    test('the seed is 64 bytes, which is what ML-KEM keygen takes', () {
      expect(pq.pqRootDeriveSeed(root, 0).length, 64);
    });

    // The salts differ so a root and an nsec can never derive the same key.
    test('the same 32 bytes as root and as nsec derive different keys', () {
      expect(_hex(pq.pqRootDeriveSeed(root, 0)),
          isNot(_hex(pq.pqDeriveSeed(root, 0))));
      expect(_hex(pq.pqKeypairFromRoot(root, 0).publicKey),
          isNot(_hex(pq.pqKeypairFromPrivkey(root, 0).publicKey)));
    });

    test('the keypair is deterministic and epoch-scoped', () {
      expect(_hex(pq.pqKeypairFromRoot(root, 3).publicKey),
          _hex(pq.pqKeypairFromRoot(root, 3).publicKey));
      expect(_hex(pq.pqKeypairFromRoot(root, 3).publicKey),
          isNot(_hex(pq.pqKeypairFromRoot(root, 4).publicKey)));
    });

    test('a wrong-length root is refused rather than silently padded', () {
      expect(() => pq.pqRootDeriveSeed(_bytes(1, 31), 0), throwsArgumentError);
      expect(() => pq.pqRootDeriveSeed(_bytes(1, 33), 0), throwsArgumentError);
    });

    test('a generated root is 32 CSPRNG bytes, not a constant', () {
      final a = pq.pqGenerateRoot();
      final b = pq.pqGenerateRoot();
      expect(a.length, pq.pqRootLength);
      expect(pq.pqRootLength, 32);
      expect(_hex(a), isNot(_hex(b)));
    });
  });

  group('§1 display form', () {
    test('round-trips through bech32 with the nympq HRP', () {
      final code = pqRootToCode(root);
      expect(code.startsWith('nympq1'), isTrue, reason: code);
      expect(_hex(pqRootFromCode(code)!), _hex(root));
      expect(_hex(decodeNymPq(code)), _hex(root));
    });

    test('an nsec is not accepted as a root', () {
      expect(pqRootFromCode(encodeNsecBytes(privkey)), isNull);
    });

    test('garbage, truncation and a flipped character are all refused', () {
      final code = pqRootToCode(root);
      expect(pqRootFromCode('not a code'), isNull);
      expect(pqRootFromCode(''), isNull);
      expect(pqRootFromCode(code.substring(0, code.length - 2)), isNull);
      final flipped = code.substring(0, code.length - 1) +
          (code.endsWith('q') ? 'p' : 'q');
      expect(pqRootFromCode(flipped), isNull,
          reason: 'the bech32 checksum is what makes a mistyped code safe');
    });

    test('a well-formed nympq of the wrong length is refused', () {
      final short = encodeNymPq(_bytes(2, 16));
      expect(short.startsWith('nympq1'), isTrue);
      expect(pqRootFromCode(short), isNull);
    });

    test('surrounding whitespace from a paste is tolerated', () {
      expect(_hex(pqRootFromCode('  ${pqRootToCode(root)}\n')!), _hex(root));
    });
  });

  group('the record', () {
    test('an empty record is meaningful and round-trips', () {
      const rec = PqRootRecord();
      expect(rec.isEmpty, isTrue);
      final back = PqRootRecord.decode(rec.encode());
      expect(back, isNotNull,
          reason: 'the record\'s existence is what stops a rival root');
      expect(back!.isEmpty, isTrue);
    });

    test('wraps round-trip through JSON', () async {
      const wrap = PqRootWrap(type: pqRootWrapPasskey, salt: 'c2FsdA', blob: 'enc:v1:AAAA:BBBB');
      final rec = const PqRootRecord().withWrap(wrap);
      final back = PqRootRecord.decode(rec.encode())!;
      final w = back.wrapOfType(pqRootWrapPasskey)!;
      expect(w.blob, wrap.blob);
      expect(w.salt, wrap.salt);
      expect(w.iterations, wrap.iterations);
      expect(w.blob, wrap.blob);
    });

    // Dropping another client's wrap silently loses a way into the account.
    test('a wrap type this build does not understand survives a rewrite',
        () async {
      // A type no build understands yet: it must survive our rewrite intact.
      const foreign = PqRootWrap(
        type: 'some-future-path',
        blob: 'enc:v1:AAAA:BBBB',
        extra: {'credId': 'abc'},
      );
      final rec = const PqRootRecord().withWrap(foreign);
      const wrap = PqRootWrap(type: pqRootWrapPasskey, salt: 'c2FsdA', blob: 'enc:v1:AAAA:BBBB');
      final rewritten =
          PqRootRecord.decode(rec.encode())!.withWrap(wrap);
      final back = PqRootRecord.decode(rewritten.encode())!;
      expect(back.wraps.length, 2);
      final kept = back.wrapOfType('some-future-path')!;
      expect(kept.blob, 'enc:v1:AAAA:BBBB');
      expect(kept.extra['credId'], 'abc');
    });

    test('replacing a wrap of the same type does not duplicate it', () async {
      const a = PqRootWrap(type: pqRootWrapPasskey, blob: 'enc:v1:AAAA:1111');
      const b = PqRootWrap(type: pqRootWrapPasskey, blob: 'enc:v1:AAAA:2222');
      final rec = const PqRootRecord().withWrap(a).withWrap(b);
      expect(rec.wraps.length, 1);
      expect(rec.wrapOfType(pqRootWrapPasskey)!.blob, b.blob);
    });

    test('junk does not parse as a record', () {
      expect(PqRootRecord.decode('not json'), isNull);
      expect(PqRootRecord.decode('[]'), isNull);
      expect(PqRootRecord.decode('{"nope":1}'), isNull);
    });
  });

  group('verifying a pasted code against the announcement', () {
    test('the right root reproduces the announced key', () {
      final pk = pq.pqKeypairFromRoot(root, 2).publicKey;
      expect(pqRootMatchesAnnouncedKey(root, pk, 2), isTrue);
    });

    test('a slightly stale announcement still verifies', () {
      final pk = pq.pqKeypairFromRoot(root, 1).publicKey;
      expect(pqRootMatchesAnnouncedKey(root, pk, 3), isTrue);
    });

    test('a different root does not', () {
      final pk = pq.pqKeypairFromRoot(root, 0).publicKey;
      expect(pqRootMatchesAnnouncedKey(_bytes(0x5b), pk, 0), isFalse);
    });

    test('an nsec-derived announcement is not mistaken for the root', () {
      final pk = pq.pqKeypairFromPrivkey(privkey, 0).publicKey;
      expect(pqRootMatchesAnnouncedKey(root, pk, 0), isFalse);
    });
  });

  // Two devices generating independent roots is the failure this prevents.
  group('§6 generation and adoption ordering', () {
    PqRootAction decide({
      bool throwaway = false,
      bool loaded = true,
      bool present = false,
      bool hold = false,
      bool matches = true,
    }) =>
        pqRootDecide(
          throwawayKeypair: throwaway,
          recordLoadSucceeded: loaded,
          recordPresent: present,
          holdRoot: hold,
          recordMatchesHeldRoot: matches,
        );

    test('§6.4 no record → generate', () {
      expect(decide(), PqRootAction.generate);
    });

    test('§6.2 record present and we hold the root → ready', () {
      expect(decide(present: true, hold: true), PqRootAction.ready);
    });

    // THE one to get wrong. A record we cannot open is still a record.
    test('§6.3 record present and we cannot open it → await link, NOT generate',
        () {
      expect(decide(present: true, hold: false), PqRootAction.awaitLink);
    });

    test('a read that never completed is not evidence of absence', () {
      expect(decide(loaded: false), PqRootAction.wait,
          reason: 'an offline boot that generated here creates a rival root');
      expect(decide(loaded: false, present: true), PqRootAction.wait);
    });

    test('we hold the root but the account has no record → republish it', () {
      expect(decide(hold: true, present: false), PqRootAction.publishRecord,
          reason: 'without the record another device generates a rival root');
    });

    // THE bug this signature change exists for. The standard onboarding does
    // not log anyone in — it persists a nick and boots the auto-ephemeral
    // identity — so loginMethod is null for almost every account, even though
    // the keypair is kept across launches. Gating on a "durable login" meant
    // those accounts never generated a root and silently stayed on the
    // nsec-derived key, while the PWA (which has no such gate) generated one.
    test('an account created through onboarding generates a root', () {
      expect(decide(), PqRootAction.generate,
          reason: 'no durable-login gate: the decision must not ask how the '
              'identity was created');
    });

    // The one identity that genuinely has nothing to carry forward.
    test('a per-session throwaway keypair never generates', () {
      expect(decide(throwaway: true), PqRootAction.wait);
      expect(decide(throwaway: true, present: true), PqRootAction.wait);
    });

    // For a signer login the root is what makes the account post-quantum at
    // all, so requiring one first would be a deadlock. The PWA gates on
    // support, not capability, for exactly this reason.
    test('a signer login generates too — no nsec is required', () {
      expect(decide(), PqRootAction.generate,
          reason: 'the decision must not ask whether an nsec is held');
    });

    // Holding *a* root is not holding *this account's* root.
    test('a stale root that does not open the record → await link', () {
      expect(decide(present: true, hold: true, matches: false),
          PqRootAction.awaitLink);
      expect(decide(present: true, hold: true, matches: true),
          PqRootAction.ready);
    });
  });

  // §7: a device that cannot open the root must publish no announcement.
  group('§7 silence, as wired in the controller', () {
    final controller =
        File('lib/state/nostr_controller.dart').readAsStringSync();

    test('publishPqAnnouncement returns early when the root is locked', () {
      final start =
          controller.indexOf('Future<void> publishPqAnnouncement({bool force');
      expect(start, greaterThan(-1));
      final end = controller.indexOf('\n  }', start);
      final body = controller.substring(start, end);
      expect(body.contains('if (_pqRootLocked) return;'), isTrue,
          reason: 'the announcement is replaceable, so a v1 republish here '
              'clobbers the account\'s v2 one');
      // Before the throttle and before anything is signed.
      expect(body.indexOf('_pqRootLocked'),
          lessThan(body.indexOf('service.publishPqAnnouncement')));
    });

    test('the awaitLink branch is what sets the lock, and it generates nothing',
        () {
      final start = controller.indexOf('case PqRootAction.awaitLink:');
      expect(start, greaterThan(-1));
      final end = controller.indexOf('case PqRootAction.generate:', start);
      final branch = controller.substring(start, end);
      expect(branch.contains('_pqRootLocked = true;'), isTrue);
      expect(branch.contains('pqGenerateRoot'), isFalse);
      expect(branch.contains('publishPqAnnouncement'), isFalse);
    });
  });

  group('§4 decrypt candidates', () {
    test('root-derived first, then nsec-derived', () {
      final withRoot = pqSelfCandidates(privkey, 0, root: root);
      final legacy = pqSelfCandidates(privkey, 0);
      expect(withRoot.length, legacy.length * 2);
      expect(_hex(withRoot.first.kemPk),
          _hex(pq.pqKeypairFromRoot(root, 0).publicKey));
      expect(_hex(withRoot[legacy.length].kemPk), _hex(legacy.first.kemPk));
    });

    test('the nsec-derived tail is kept in full, not trimmed', () {
      final withRoot = pqSelfCandidates(privkey, 9, root: root);
      final legacy = pqSelfCandidates(privkey, 9);
      expect(legacy.length, pqPreviousEpochs + 1);
      for (var i = 0; i < legacy.length; i++) {
        expect(_hex(withRoot[legacy.length + i].kemPk),
            _hex(legacy[i].kemPk),
            reason: 'dropping the v1 candidates is data loss, not cleanup');
      }
    });

    // A root-holding device must still open a v1 wrap, permanently.
    test('a v1 gift wrap still opens on a root-holding device', () async {
      final legacy = pq.pqKeypairFromPrivkey(privkey, 0);
      final senderSk = Uint8List.fromList(List<int>.filled(32, 0x33));
      final wrap = await nip59WrapAsync(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1735689600,
          kind: 14,
          tags: [
            ['p', getPublicKeyHex(privkey)]
          ],
          content: 'sealed under v1',
        ),
        senderSigner: LocalSigner(senderSk),
        recipientPubkey: getPublicKeyHex(privkey),
        recipientKemPublicKey: legacy.publicKey,
      );
      expect(pq.isPqPayload(wrap.content), isTrue);

      final candidates = [
        for (final k in pqSelfCandidates(privkey, 0, root: root))
          (sk: privkey, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk),
        classicalCandidate(privkey, bitchat: true),
      ];
      final opened = await unwrapGiftWrap(wrap, candidates);
      expect(opened, isNotNull,
          reason: 'every message ever sent under v1 would be unreadable');
      expect(opened!.rumor['content'], 'sealed under v1');
      expect(opened.isPq, isTrue);
    });

    test('a root-sealed gift wrap opens from the same list', () async {
      final rootKem = pq.pqKeypairFromRoot(root, 0);
      final senderSk = Uint8List.fromList(List<int>.filled(32, 0x34));
      final wrap = await nip59WrapAsync(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1735689600,
          kind: 14,
          tags: [
            ['p', getPublicKeyHex(privkey)]
          ],
          content: 'sealed under v2',
        ),
        senderSigner: LocalSigner(senderSk),
        recipientPubkey: getPublicKeyHex(privkey),
        recipientKemPublicKey: rootKem.publicKey,
      );
      final candidates = [
        for (final k in pqSelfCandidates(privkey, 0, root: root))
          (sk: privkey, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk),
        classicalCandidate(privkey, bitchat: true),
      ];
      final opened = await unwrapGiftWrap(wrap, candidates);
      expect(opened?.rumor['content'], 'sealed under v2');
    });

    test('without a root the list is byte-identical to v1', () {
      final a = pqSelfCandidates(privkey, 4);
      final b = pqSelfCandidates(privkey, 4, root: null);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(_hex(a[i].kemPk), _hex(b[i].kemPk));
      }
    });
  });
}
