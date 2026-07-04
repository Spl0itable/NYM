// Platform-readiness smoke test.
//
// Validates that the native iOS/Android manifest, plist, gradle and
// entitlement files declare every permission/capability the app's features
// rely on. Runs without an Android SDK or macOS toolchain, so it guards the
// platform config in CI even where a full build can't.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: 'missing file: $relativePath');
  return file.readAsStringSync();
}

void main() {
  group('Android manifest', () {
    late final String manifest =
        _read('android/app/src/main/AndroidManifest.xml');

    const requiredPermissions = <String>[
      'android.permission.INTERNET',
      'android.permission.CAMERA',
      'android.permission.RECORD_AUDIO',
      'android.permission.MODIFY_AUDIO_SETTINGS',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.VIBRATE',
      'android.permission.ACCESS_FINE_LOCATION',
      'android.permission.USE_BIOMETRIC',
      'android.permission.WAKE_LOCK',
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
      'android.permission.READ_MEDIA_IMAGES',
    ];

    for (final perm in requiredPermissions) {
      test('declares $perm', () {
        expect(manifest, contains(perm));
      });
    }

    test('cleartext traffic disabled', () {
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
    });

    test('declares the nymchat custom scheme + universal-link hosts', () {
      expect(manifest, contains('android:scheme="nymchat"'));
      expect(manifest, contains('android:host="app.nymchat.app"'));
      expect(manifest, contains('android:host="app.nym.bar"'));
    });

    test('queries lightning + https for url_launcher', () {
      expect(manifest, contains('android:scheme="lightning"'));
      expect(manifest, contains('android:scheme="https"'));
    });
  });

  group('Android gradle', () {
    late final String appGradle = _read('android/app/build.gradle');

    test('applicationId + namespace are the real package', () {
      expect(appGradle, contains('applicationId "com.nym.bar"'));
      expect(appGradle, contains('namespace = "com.nym.bar"'));
    });

    test('minSdk satisfies flutter_webrtc/local_auth (>=23)', () {
      final match = RegExp(r'minSdk\s*=\s*(\d+)').firstMatch(appGradle);
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), greaterThanOrEqualTo(23));
    });

    test('core library desugaring enabled for flutter_local_notifications', () {
      expect(appGradle, contains('coreLibraryDesugaringEnabled = true'));
      expect(appGradle, contains('coreLibraryDesugaring '));
    });

    test('MainActivity lives in the real package', () {
      final kt = _read('android/app/src/main/kotlin/com/nym/bar/MainActivity.kt');
      expect(kt, contains('package com.nym.bar'));
    });
  });

  group('iOS Info.plist', () {
    late final String plist = _read('ios/Runner/Info.plist');

    const requiredKeys = <String>[
      'NSCameraUsageDescription',
      'NSMicrophoneUsageDescription',
      'NSLocationWhenInUseUsageDescription',
      'NSPhotoLibraryUsageDescription',
      'NSPhotoLibraryAddUsageDescription',
      'NSFaceIDUsageDescription',
      'ITSAppUsesNonExemptEncryption',
    ];

    for (final key in requiredKeys) {
      test('declares $key', () {
        expect(plist, contains('<key>$key</key>'));
      });
    }

    test('background modes cover calls + push', () {
      for (final mode in ['audio', 'voip', 'remote-notification']) {
        expect(plist, contains('<string>$mode</string>'));
      }
    });

    test('queries lightning + https schemes', () {
      expect(plist, contains('<string>lightning</string>'));
      expect(plist, contains('<string>https</string>'));
    });

    test('declares the nymchat custom URL scheme', () {
      expect(plist, contains('<string>nymchat</string>'));
    });
  });

  group('iOS entitlements + project', () {
    test('associated domains include the deep-link hosts', () {
      final ent = _read('ios/Runner/Runner.entitlements');
      expect(ent, contains('applinks:app.nymchat.app'));
      expect(ent, contains('keychain-access-groups'));
    });

    test('entitlements wired into the Xcode build settings', () {
      final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(pbx,
          contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'));
    });

    test('deployment target high enough for flutter_webrtc (>=13)', () {
      final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
      final matches = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = (\d+)')
          .allMatches(pbx)
          .map((m) => int.parse(m.group(1)!));
      expect(matches, isNotEmpty);
      expect(matches.every((v) => v >= 13), isTrue,
          reason: 'all targets must be >= iOS 13 for flutter_webrtc');
    });
  });

  group('pubspec assets', () {
    test('globe geodata + image assets declared', () {
      final pubspec = _read('pubspec.yaml');
      expect(pubspec, contains('assets/data/'));
      expect(pubspec, contains('assets/images/'));
      expect(File('assets/data/countries-110m.json').existsSync(), isTrue);
    });
  });
}
