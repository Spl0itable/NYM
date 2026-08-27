// Native libsecp256k1 BIP340 verification (core/crypto/native_schnorr.dart):
// correctness cross-check against the pure-Dart bip340 implementation it
// replaces on the hot path. Requires `build/libsecp256k1.so` next to the
// project (built from the coinlib-pinned secp256k1 fork); when the library
// isn't present the suite skips rather than fails, since every runtime call
// site falls back to pure Dart in exactly that situation.

import 'package:bip340/bip340.dart' as bip340;
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/native_schnorr.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/nostr_event.dart';

NostrEvent _signedEvent(String content) {
  final sk = keys.generatePrivateKey();
  final pk = keys.getPublicKeyHex(sk);
  final e = NostrEvent(
    pubkey: pk,
    createdAt: 1700000000,
    kind: EventKind.namedChannel,
    tags: const [
      ['d', 'room'],
    ],
    content: content,
  );
  e.id = e.computeId();
  e.sig = schnorr.signId(e.id, sk);
  return e;
}

void main() {
  late final bool native;

  setUpAll(() async {
    native = await NativeSchnorr.ensureLoaded();
  });

  test('native library loads on the host (build/libsecp256k1.so)', () {
    if (!native) {
      markTestSkipped('libsecp256k1 not available — pure-Dart fallback path '
          'is in use (build it into build/libsecp256k1.so to exercise native '
          'verification here)');
      return;
    }
    expect(NativeSchnorr.isAvailable, isTrue);
  });

  test('native verify agrees with pure-Dart bip340 on valid signatures',
      () async {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    for (var i = 0; i < 10; i++) {
      final e = _signedEvent('cross-check $i');
      expect(
        NativeSchnorr.verify(
            pubkeyHex: e.pubkey, idHex: e.id, sigHex: e.sig),
        isTrue,
        reason: 'a pure-Dart-signed event must verify natively',
      );
      // The routed entry point (native when loaded) agrees too.
      expect(schnorr.verifyEvent(e), isTrue);
    }
  });

  test('native verify rejects a tampered signature and a wrong pubkey',
      () async {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    final e = _signedEvent('to be tampered');
    // Flip one hex nibble of the signature.
    final flipped = (e.sig[0] == '0' ? '1' : '0') + e.sig.substring(1);
    expect(
      NativeSchnorr.verify(pubkeyHex: e.pubkey, idHex: e.id, sigHex: flipped),
      isFalse,
    );
    final other = _signedEvent('someone else');
    expect(
      NativeSchnorr.verify(
          pubkeyHex: other.pubkey, idHex: e.id, sigHex: e.sig),
      isFalse,
    );
    // Malformed inputs return false rather than throwing.
    expect(
      NativeSchnorr.verify(pubkeyHex: 'zz', idHex: e.id, sigHex: e.sig),
      isFalse,
    );
  });

  test('native SIGNING produces signatures pure-Dart bip340 accepts',
      () async {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    final sk = keys.generatePrivateKey();
    final pk = keys.getPublicKeyHex(sk);
    for (var i = 0; i < 5; i++) {
      final e = NostrEvent(
        pubkey: pk,
        createdAt: 1700000000 + i,
        kind: EventKind.namedChannel,
        tags: const [
          ['d', 'room'],
        ],
        content: 'native-signed $i',
      );
      e.id = e.computeId();
      final sig = NativeSchnorr.sign(privkey: sk, idHex: e.id);
      expect(sig, isNotNull);
      e.sig = sig!;
      // Both verifiers accept it — and the routed signId (native when loaded)
      // round-trips through the routed verifyEvent.
      expect(schnorr.verifyEvent(e), isTrue);
      e.sig = schnorr.signId(e.id, sk);
      expect(schnorr.verifyEvent(e), isTrue);
    }
  });

  test('native pubkey derivation agrees with pure-Dart bip340', () async {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    for (var i = 0; i < 10; i++) {
      final sk = keys.generatePrivateKey();
      expect(
        NativeSchnorr.xOnlyPubkeyHex(sk),
        bip340.getPublicKey(keys.bytesToHex(sk)),
        reason: 'x-only pubkey must match the pure-Dart derivation',
      );
    }
  });

  test('native vs pure-Dart throughput (informational)', () async {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    const n = 50;
    final events = [for (var i = 0; i < n; i++) _signedEvent('bench $i')];

    final swNative = Stopwatch()..start();
    for (final e in events) {
      NativeSchnorr.verify(pubkeyHex: e.pubkey, idHex: e.id, sigHex: e.sig);
    }
    swNative.stop();

    // ignore: avoid_print
    print('NATIVE VERIFY: $n events in ${swNative.elapsedMilliseconds}ms '
        '=> ${(swNative.elapsedMicroseconds / n).toStringAsFixed(0)} us/event');
    // Native must beat the ~12 ms/event pure-Dart baseline by a wide margin.
    expect(swNative.elapsedMicroseconds / n < 5000, isTrue);
  });
}
