import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/services/attest/attest_badge.dart';
import 'package:nym_bar/services/attest/attest_service.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AttestService.channelName);
  final signer = LocalSigner(Uint8List.fromList(List<int>.filled(32, 7)));

  late List<Map<String, dynamic>> posts;
  late bool manifestUp;

  void nativeAnswers(Map<String, dynamic>? answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => answer);
  }

  var platformAnswer = <String, dynamic>{};
  var platformStatus = 200;

  MockClient fakeApi() => MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/build-manifest.json') {
          if (!manifestUp) return http.Response('gone', 404);
          return http.Response(
              jsonEncode({
                'files': {
                  '/a.js': 'sha256-A',
                  '/b.js': 'sha256-B',
                  '/c.js': 'sha256-C'
                }
              }),
              200);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        posts.add(body);
        if (body['action'] == 'challenge') {
          return http.Response(
              jsonEncode({
                'challenge': 'c1.1700000000000.mac',
                'powBits': 8,
                'buildProbe': ['/a.js', '/b.js'],
              }),
              200);
        }
        final hasProof =
            body.containsKey('token') || body.containsKey('attestation');
        if (hasProof && platformStatus != 200) {
          return http.Response(jsonEncode(platformAnswer), platformStatus);
        }
        return http.Response(
            jsonEncode({
              'badge': '1.challenged.x.y',
              'tier': hasProof ? 'attested' : 'challenged',
              'expiresAt':
                  DateTime.now().millisecondsSinceEpoch + 45 * 86400000,
              'authority': AttestService.pinnedAuthority,
            }),
            200);
      });

  Future<AttestService> fresh(String platform) async {
    SharedPreferences.setMockInitialValues({});
    final kv = KeyValueStore(await SharedPreferences.getInstance());
    return AttestService(
        kv: kv, client: fakeApi(), channel: channel, platform: platform);
  }

  List<List<String>> authTags(Map<String, dynamic> enroll) =>
      ((enroll['auth'] as Map)['tags'] as List)
          .map((t) => (t as List).cast<String>())
          .toList();

  setUp(() {
    posts = [];
    manifestUp = true;
    platformStatus = 200;
    platformAnswer = {};
  });

  tearDown(() => nativeAnswers(null));

  group('enrollment', () {
    test('a device that cannot attest falls back to the build proof as itself',
        () async {
      nativeAnswers(null);
      final svc = await fresh('ios');
      await svc.ensureBadge(signer);
      final enroll = posts.singleWhere((b) => b['action'] == 'enroll');
      expect(enroll['platform'], 'ios',
          reason: 'a phone without a platform proof is still a phone');
      expect(enroll['refusal'], 'no-platform-proof');
      expect(enroll['build'], {'/a.js': 'sha256-A', '/b.js': 'sha256-B'});
      final nonce = authTags(enroll).firstWhere((t) => t[0] == 'nonce');
      expect(nonce[2], '8', reason: 'the fallback pays the work');
      expect(svc.badge, '1.challenged.x.y');
      expect(svc.tier, AttestTier.challenged);
      expect(svc.tagsForEvent(), [
        [AttestBadge.tagName, '1.challenged.x.y']
      ]);
    });

    test('an App Attest proof enrolls as ios and mines nothing', () async {
      nativeAnswers({'keyId': 'kid', 'attestation': 'att'});
      final svc = await fresh('ios');
      await svc.ensureBadge(signer);
      final enroll = posts.singleWhere((b) => b['action'] == 'enroll');
      expect(enroll['platform'], 'ios');
      expect(enroll['keyId'], 'kid');
      expect(enroll['attestation'], 'att');
      expect(authTags(enroll).any((t) => t[0] == 'nonce'), isFalse);
      expect(svc.tier, AttestTier.attested);
    });

    test('a Play Integrity failure is reported by name', () async {
      nativeAnswers({'reason': 'PLAY_SERVICES_NOT_FOUND(-6)'});
      final svc = await fresh('android');
      await svc.ensureBadge(signer);
      final enroll = posts.singleWhere((b) => b['action'] == 'enroll');
      expect(enroll['platform'], 'android');
      expect(enroll['refusal'], 'play-integrity: PLAY_SERVICES_NOT_FOUND(-6)');
      expect(svc.lastPlatformRefusal,
          'play-integrity: PLAY_SERVICES_NOT_FOUND(-6)');
      expect(svc.tier, AttestTier.challenged);
    });

    test('an unsupported App Attest device says so', () async {
      nativeAnswers({'reason': 'app-attest-unsupported'});
      final svc = await fresh('ios');
      await svc.ensureBadge(signer);
      final enroll = posts.singleWhere((b) => b['action'] == 'enroll');
      expect(enroll['refusal'], 'app-attest-unsupported');
      expect(svc.tier, AttestTier.challenged);
    });

    test('an Android install without Play Integrity falls back the same way',
        () async {
      nativeAnswers(null);
      final svc = await fresh('android');
      await svc.ensureBadge(signer);
      final enroll = posts.singleWhere((b) => b['action'] == 'enroll');
      expect(enroll['platform'], 'android');
      expect(enroll['refusal'], 'no-platform-proof');
      expect(enroll['build'], {'/a.js': 'sha256-A', '/b.js': 'sha256-B'});
      expect(authTags(enroll).any((t) => t[0] == 'nonce'), isTrue);
      expect(svc.tier, AttestTier.challenged);
    });

    test('a Play Integrity token still carries the work', () async {
      nativeAnswers({'token': 'tok'});
      final svc = await fresh('android');
      await svc.ensureBadge(signer);
      final enroll = posts.singleWhere((b) => b['action'] == 'enroll');
      expect(enroll['platform'], 'android');
      expect(enroll['token'], 'tok');
      expect(authTags(enroll).any((t) => t[0] == 'nonce'), isTrue);
    });

    test('a platform proof the server refuses falls back to the build proof',
        () async {
      nativeAnswers({'keyId': 'kid', 'attestation': 'att'});
      platformStatus = 403;
      platformAnswer = {
        'error': 'Attestation failed',
        'reason': 'environment-mismatch'
      };
      final svc = await fresh('ios');
      await svc.ensureBadge(signer);
      final enrolls = posts.where((b) => b['action'] == 'enroll').toList();
      expect(enrolls.map((b) => b['platform']), ['ios', 'ios'],
          reason: 'the fallback is still an iOS install');
      expect(
          enrolls[1]['refusal'], 'Attestation failed (environment-mismatch)');
      expect(enrolls[1].containsKey('attestation'), isFalse);
      expect(posts.where((b) => b['action'] == 'challenge').length, 2,
          reason: 'the fallback enrolls under a fresh challenge');
      expect(authTags(enrolls[1]).any((t) => t[0] == 'nonce'), isTrue);
      expect(svc.tier, AttestTier.challenged);
      expect(
          svc.lastPlatformRefusal, 'Attestation failed (environment-mismatch)');
      expect(svc.lastError, isNull);
    });

    test('a device cap is reported and not retried as web', () async {
      nativeAnswers({'keyId': 'kid', 'attestation': 'att'});
      platformStatus = 429;
      platformAnswer = {'error': 'Device enrollment cap'};
      final svc = await fresh('ios');
      await svc.ensureBadge(signer);
      expect(posts.where((b) => b['action'] == 'enroll').length, 1);
      expect(svc.badge, isNull);
      expect(svc.lastError, 'Device enrollment cap');
      expect(svc.lastAttemptAt, isNotNull);
    });

    test('no proof and no manifest means no enrollment call', () async {
      nativeAnswers(null);
      manifestUp = false;
      final svc = await fresh('ios');
      await svc.ensureBadge(signer);
      expect(posts.where((b) => b['action'] == 'enroll'), isEmpty);
      expect(svc.badge, isNull);
      expect(svc.lastError, 'no proof');
    });
  });
}
