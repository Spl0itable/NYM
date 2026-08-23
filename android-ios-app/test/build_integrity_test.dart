// The Android build-integrity check: hash the installed APK, compare against
// the hash in the publisher's signed Zapstore release event.
//
// The states that must NOT read as failures are the point of these tests. A
// Play install can never match a published hash — Play re-signs the upload and
// builds a separate APK per device — and an unreachable relay establishes
// nothing either way. Both were easy to render as "unverified" and scare every
// ordinary user, so each has its own state and its own copy.
//
// The other load-bearing rule is that the publisher key is pinned. Zapstore's
// relay is a public one: anyone can publish a kind-3063 event claiming any
// hash, so an event from the wrong key has to be dropped rather than read.
//
// Everything here drives the pure verdict function and the event parser
// directly; no device, no relay.

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/settings/about_screen.dart';
import 'package:nym_bar/features/settings/build_integrity.dart';
import 'package:nym_bar/models/nostr_event.dart';

const _apkHash =
    'aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899';
const _otherHash =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _signer =
    'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

NativeBuildInfo _sideload({
  String? apk = _apkHash,
  String version = '3.74.533',
  int code = 238,
}) =>
    NativeBuildInfo(
      packageName: 'com.nym.bar',
      apkSha256: apk,
      splitCount: 0,
      signerSha256: _signer,
      installer: 'com.nymchat.sideload',
      versionName: version,
      versionCode: code,
    );

const _published = PublishedBuild(
  version: '3.74.533',
  versionCode: 238,
  apkSha256: _apkHash,
  certSha256: _signer,
);

void main() {
  group('verdict', () {
    test('a published hash that matches verifies', () {
      final r = describeBuildIntegrity(
          info: _sideload(), provenanceOk: true, builds: const [_published]);
      expect(r.state, BuildIntegrityState.verified);
      expect(r.isVerified, isTrue);
      expect(r.published?.version, '3.74.533');
    });

    test('a hash the manifest does not publish is a mismatch', () {
      final r = describeBuildIntegrity(
          info: _sideload(apk: _otherHash),
          provenanceOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.mismatch);
    });

    test('a version not published yet is its own state, not a mismatch', () {
      // The ordinary case for a build newer than the listing. Calling that
      // "unrecognised" would accuse every early updater of running a tampered
      // app.
      final r = describeBuildIntegrity(
          info: _sideload(apk: _otherHash, version: '9.9.9', code: 999),
          provenanceOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.notPublished);
    });

    test('a published version whose bytes differ IS a mismatch', () {
      final r = describeBuildIntegrity(
          info: _sideload(apk: _otherHash),
          provenanceOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.mismatch);
      expect(r.published?.version, '3.74.533');
    });

    test('the hash decides, whatever the version tag says', () {
      // A publisher's `version` tag is what they typed; the hash is what the
      // bytes are. A cosmetic difference must not turn a good build red.
      final r = describeBuildIntegrity(
          info: _sideload(version: 'v3.74.533'),
          provenanceOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.verified);
    });

    test('an unreachable manifest is not a failure', () {
      final r = describeBuildIntegrity(
          info: _sideload(), provenanceOk: false, builds: const []);
      expect(r.state, BuildIntegrityState.provenanceUnreachable);
    });

    test('nothing measured is unsupported, not a mismatch', () {
      expect(
        describeBuildIntegrity(
                info: null, provenanceOk: true, builds: const [_published])
            .state,
        BuildIntegrityState.unsupported,
      );
      expect(
        describeBuildIntegrity(
                info: _sideload(apk: null),
                provenanceOk: true,
                builds: const [_published])
            .state,
        BuildIntegrityState.unsupported,
      );
    });
  });

  group('Google Play', () {
    test('an install by Play is never a mismatch', () {
      // The bytes on the device are not the published file, so a hash that
      // fails to match says nothing about tampering.
      const play = NativeBuildInfo(
        apkSha256: _otherHash,
        installer: kPlayInstaller,
        versionName: '3.74.533',
        versionCode: 238,
      );
      final r = describeBuildIntegrity(
          info: play, provenanceOk: true, builds: const [_published]);
      expect(r.state, BuildIntegrityState.storeRepackaged);
    });

    test('split APKs alone mark a store install', () {
      // Play delivers per-ABI/density/language splits even where the installer
      // package is missing (restored backups, some OEM flows).
      const split = NativeBuildInfo(
        apkSha256: _otherHash,
        splitCount: 3,
        versionName: '3.74.533',
      );
      expect(split.isStoreRepackaged, isTrue);
      expect(
        describeBuildIntegrity(
                info: split, provenanceOk: true, builds: const [_published])
            .state,
        BuildIntegrityState.storeRepackaged,
      );
    });

    test('a store install reports the same way when the manifest is down', () {
      // The network could not have changed the answer, so saying "provenance
      // unreachable" would imply a check that was never going to run.
      const play = NativeBuildInfo(
          apkSha256: _otherHash, installer: kPlayInstaller, splitCount: 4);
      expect(
        describeBuildIntegrity(info: play, provenanceOk: false, builds: const [])
            .state,
        BuildIntegrityState.storeRepackaged,
      );
    });

    test('a direct install is not treated as a store one', () {
      expect(_sideload().isStoreRepackaged, isFalse);
    });
  });

  group('release events', () {
    late final sk = randomBytes(32);
    late final pk = getPublicKeyHex(sk);

    /// A signed kind-3063 Software Asset event, the shape `zsp publish` emits.
    NostrEvent asset({
      String hash = _apkHash,
      String version = '3.74.533',
      int code = 238,
      String appId = kAndroidAppId,
      String? cert = _signer,
      List<String>? sk2,
    }) {
      return schnorr.finalizeEvent(
        UnsignedEvent(
          pubkey: pk,
          createdAt: 1735689600,
          kind: kZapstoreAssetKind,
          tags: [
            ['i', appId],
            ['x', hash],
            ['version', version],
            ['version_code', '$code'],
            ['m', 'application/vnd.android.package-archive'],
            ['f', 'android-arm64-v8a'],
            if (cert != null) ['apk_certificate_hash', cert],
          ],
          content: '',
        ),
        sk,
      );
    }

    test('an asset event yields the published hash and certificate', () {
      final builds = zapstoreAssets([asset()], publisherPubkey: pk);
      expect(builds, hasLength(1));
      expect(builds.single.apkSha256, _apkHash);
      expect(builds.single.certSha256, _signer);
      expect(builds.single.version, '3.74.533');
      expect(builds.single.versionCode, 238);
      expect(builds.single.platform, 'android-arm64-v8a');
    });

    test('an event from another key is dropped', () {
      // The relay is public. Without the pin, anyone could publish a hash and
      // have this panel bless whatever they had installed.
      final other = getPublicKeyHex(randomBytes(32));
      expect(zapstoreAssets([asset()], publisherPubkey: other), isEmpty);
    });

    test('a tampered event is dropped', () {
      final good = asset();
      final forged = NostrEvent.fromJson({
        ...good.toJson(),
        'tags': [
          ['i', kAndroidAppId],
          ['x', _otherHash],
          ['version', '3.74.533'],
        ],
      });
      expect(zapstoreAssets([forged], publisherPubkey: pk), isEmpty);
    });

    test('an asset for another app is dropped', () {
      expect(
        zapstoreAssets([asset(appId: 'com.other.app')], publisherPubkey: pk),
        isEmpty,
      );
    });

    test('an asset with no hash is dropped', () {
      expect(zapstoreAssets([asset(hash: '')], publisherPubkey: pk), isEmpty);
    });

    test('a release with one APK per ABI verifies whichever is installed', () {
      final builds = zapstoreAssets(
        [asset(hash: _otherHash), asset()],
        publisherPubkey: pk,
      );
      expect(builds, hasLength(2));
      expect(
        describeBuildIntegrity(
                info: _sideload(), provenanceOk: true, builds: builds)
            .state,
        BuildIntegrityState.verified,
      );
    });

    test('hex case does not matter', () {
      final builds =
          zapstoreAssets([asset(hash: _apkHash.toUpperCase())], publisherPubkey: pk);
      final info = NativeBuildInfo.fromMap({
        'apkSha256': _apkHash.toUpperCase(),
        'splitCount': 0,
        'versionName': '3.74.533',
        'versionCode': 238,
      });
      expect(
        describeBuildIntegrity(info: info, provenanceOk: true, builds: builds)
            .state,
        BuildIntegrityState.verified,
      );
    });

    test('an unverifiable lookup reads as unreachable, not as a pass', () {
      // One state on purpose: a claim that cannot be checked is worth exactly
      // as much as one that never arrived.
      final r = describeBuildIntegrity(
          info: _sideload(), provenanceOk: false, builds: const []);
      expect(r.state, BuildIntegrityState.provenanceUnreachable);
      expect(r.isVerified, isFalse);
    });

    test('garbage in the list is skipped, not fatal', () {
      final builds = zapstoreAssets([
        NostrEvent.fromJson({
          ...asset().toJson(),
          'sig': '0' * 128,
        }),
        asset(),
      ], publisherPubkey: pk);
      expect(builds, hasLength(1));
    });
  });

  group('copy', () {
    test('every state has its own status and note', () {
      final seen = <String>{};
      for (final state in BuildIntegrityState.values) {
        final (status, note) = buildIntegrityCopy(state);
        expect(status, isNotEmpty, reason: '$state');
        expect(note, isNotEmpty, reason: '$state');
        expect(seen.add(status), isTrue, reason: 'duplicate status for $state');
      }
    });

    test('every literal is in the sweep catalog', () {
      for (final s in kBuildIntegrityStrings) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('only a real check claims a verdict', () {
      // The states that compared nothing must not say "verified" or imply the
      // app was found wanting.
      for (final state in [
        BuildIntegrityState.storeRepackaged,
        BuildIntegrityState.provenanceUnreachable,
        BuildIntegrityState.notPublished,
        BuildIntegrityState.unsupported,
      ]) {
        final (status, _) = buildIntegrityCopy(state);
        expect(status.toLowerCase(), isNot(contains('verified official')));
      }
    });
  });
}
