import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/mesh/ghost_mode.dart';

void main() {
  group('GhostModeController', () {
    test('enabling mints an identity with every field fresh', () async {
      final g = GhostModeController();
      expect(g.state.enabled, isFalse);
      expect(g.state.current, isNull);

      await g.enable();
      final e = g.state.current!;
      expect(g.state.enabled, isTrue);
      expect(e.pubkey.length, 64);
      expect(e.privkey.length, 32);
      expect(e.nickname, startsWith('ghost#'));
      expect(e.meshIdentity.peerID.length, 16);
      g.dispose();
    });

    test('rotation changes the peerID, the key and the name together',
        () async {
      final g = GhostModeController();
      await g.enable();
      final a = g.state.current!;
      await g.rotateNow();
      final b = g.state.current!;

      expect(b.pubkey, isNot(a.pubkey),
          reason: 'a repeated Nostr key would link the two epochs');
      expect(b.meshIdentity.peerID, isNot(a.meshIdentity.peerID),
          reason: 'the peerID is the physically trackable identifier');
      expect(b.meshIdentity.fingerprint, isNot(a.meshIdentity.fingerprint));
      expect(b.meshIdentity.signingPublic, isNot(a.meshIdentity.signingPublic));
      // Rotating the key while keeping the name would defeat the whole thing.
      expect(b.nickname, isNot(a.nickname));
      g.dispose();
    });

    test('retired epochs stay decryptable so late replies still land',
        () async {
      final g = GhostModeController();
      await g.enable();
      final first = g.state.current!.pubkey;
      await g.rotateNow();
      await g.rotateNow();

      expect(g.state.epochs.length, 3);
      expect(g.state.pubkeys, contains(first),
          reason: 'the gift-wrap #p filter must still cover the old key');
      expect(g.state.secretKeys.length, 3,
          reason: 'unwrap needs a candidate key per live epoch');
      expect(g.state.pubkeys.first, g.state.current!.pubkey,
          reason: 'newest first');
      g.dispose();
    });

    test('the retained trail is bounded', () async {
      final g = GhostModeController();
      await g.enable();
      for (var i = 0; i < GhostModeController.maxEpochs + 4; i++) {
        await g.rotateNow();
      }
      expect(g.state.epochs.length, GhostModeController.maxEpochs);
      g.dispose();
    });

    test('disabling drops every key', () async {
      final g = GhostModeController();
      await g.enable();
      await g.rotateNow();
      expect(g.state.secretKeys, isNotEmpty);

      await g.disable();
      expect(g.state.enabled, isFalse);
      expect(g.state.epochs, isEmpty);
      expect(g.state.secretKeys, isEmpty,
          reason: 'Ghost Mode must not leave a trail behind it');
      expect(g.state.current, isNull);
      g.dispose();
    });

    test('rotation is a no-op while disabled', () async {
      final g = GhostModeController();
      await g.rotateNow();
      expect(g.state.epochs, isEmpty);
      g.dispose();
    });

    test('the on/off choice persists, the keys never do', () async {
      final written = <bool>[];
      final g = GhostModeController(persist: written.add);
      await g.enable();
      expect(written, [true], reason: 'enabling must survive a restart');
      await g.disable();
      expect(written, [true, false]);
      g.dispose();

      // A restart: the flag comes back, a BRAND NEW identity is minted.
      final g2 = GhostModeController();
      await g2.restore(wasEnabled: true);
      expect(g2.state.enabled, isTrue);
      expect(g2.state.current, isNotNull);
      expect(g2.state.epochs.length, 1,
          reason: 'the previous session left nothing behind to restore');
      g2.dispose();
    });

    test('restore is a no-op when the flag was off', () async {
      final g = GhostModeController();
      await g.restore(wasEnabled: false);
      expect(g.state.enabled, isFalse);
      expect(g.state.epochs, isEmpty);
      g.dispose();
    });

    test('ensureRestored settles before the identity is read', () async {
      final g = GhostModeController();
      final pending = g.restore(wasEnabled: true);
      await g.ensureRestored();
      expect(g.state.current, isNotNull,
          reason: 'the mesh must never read a half-restored ghost state');
      await pending;
      g.dispose();
    });

    test('restore does NOT fire onRotate', () async {
      var calls = 0;
      final g = GhostModeController(onRotate: () async => calls++);
      await g.restore(wasEnabled: true);
      expect(calls, 0,
          reason: 'the mesh awaits restore, so calling back would re-enter it');
      g.dispose();
    });

    test('onRotate fires for each identity change and for disable', () async {
      var calls = 0;
      final g = GhostModeController(onRotate: () async => calls++);
      await g.enable();
      expect(calls, 1);
      await g.rotateNow();
      expect(calls, 2);
      await g.disable();
      expect(calls, 3, reason: 'the mesh must restart onto the real identity');
      g.dispose();
    });
  });
}
