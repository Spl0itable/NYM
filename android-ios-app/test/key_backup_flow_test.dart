import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_config.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_service.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_store.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_ui.dart';
import 'package:nym_bar/features/identity/setup_modal.dart';
import 'package:nym_bar/widgets/common/brand_buttons.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

class FakeStore implements KeyBackupStore {
  FakeStore(this.cloud, {this.accountId = '109876543210987654321'});

  @override
  final BackupCloud cloud;
  final String accountId;
  final Map<String, String> files = {};
  var _next = 0;
  var signIns = 0;
  bool cancel = false;

  @override
  Future<String> signIn() async {
    signIns++;
    if (cancel) throw const KeyBackupCanceled();
    return accountId;
  }

  @override
  Future<List<BackupEntry>> list() async =>
      [for (final id in files.keys) BackupEntry(id: id)];

  @override
  Future<String> read(BackupEntry entry) async => files[entry.id]!;

  @override
  Future<void> write(String payload) async {
    files['f${_next++}'] = payload;
  }

  @override
  Future<void> delete(BackupEntry entry) async {
    files.remove(entry.id);
  }
}

Future<Uint8List> fastDerive(String pin, Uint8List salt) async {
  if (!isValidBackupPin(pin)) throw ArgumentError('pin');
  return backupSaltFor(pin, bytesToHex(salt));
}

Future<void> seed(FakeStore store, String pin, String secretHex) async {
  final key = await fastDerive(pin, backupSalt(store.cloud, store.accountId));
  await store.write(encryptBackupSecret(secretHex, key));
}

Future<String?> openWith(FakeStore store, String pin) async {
  final key = await fastDerive(pin, backupSalt(store.cloud, store.accountId));
  for (final p in store.files.values) {
    final s = decryptBackupSecret(p, key);
    if (s != null) return s.secretHex;
  }
  return null;
}

String newSecret() => bytesToHex(generatePrivateKey());

void main() {
  late KeyValueStore kv;

  setUp(() async {
    PinThrottle.resetAll();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${StorageKeys.uiLanguageChosen}': 'true',
    });
    kv = await KeyValueStore.open();
  });

  Widget host(List<KeyBackupStore> stores, Widget child) {
    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );
    return ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        keyBackupStoresProvider.overrideWithValue(stores),
        keyBackupDeriverProvider.overrideWithValue(fastDerive),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> enterPin(WidgetTester tester, String pin,
      {String? confirm}) async {
    await tester.enterText(find.byKey(const Key('keyBackupPin')), pin);
    if (confirm != null) {
      await tester.enterText(
          find.byKey(const Key('keyBackupPinConfirm')), confirm);
    }
  }

  group('config', () {
    test('everything is hidden without configuration', () {
      const empty = KeyBackupConfig();
      for (final p in TargetPlatform.values) {
        expect(defaultKeyBackupStores(config: empty, platform: p), isEmpty);
      }
    });

    test('Google needs the platform client id, Apple needs the flag on iOS',
        () {
      const cfg = KeyBackupConfig(
        googleIosClientId: 'ios.apps.googleusercontent.com',
        appleBackup: true,
      );
      expect(cfg.googleEnabledOn(TargetPlatform.iOS, web: false), isTrue);
      expect(cfg.googleEnabledOn(TargetPlatform.android, web: false), isFalse);
      expect(cfg.appleEnabledOn(TargetPlatform.iOS, web: false), isTrue);
      expect(cfg.appleEnabledOn(TargetPlatform.android, web: false), isFalse);
      expect(cfg.appleEnabledOn(TargetPlatform.iOS, web: true), isFalse);
      const android = KeyBackupConfig(googleServerClientId: 'web-client');
      expect(android.googleEnabledOn(TargetPlatform.android, web: false),
          isTrue);
      expect(
          defaultKeyBackupStores(
                  config: android, platform: TargetPlatform.android)
              .map((s) => s.cloud),
          [BackupCloud.google]);
      expect(
          defaultKeyBackupStores(config: cfg, platform: TargetPlatform.iOS)
              .map((s) => s.cloud),
          [BackupCloud.apple, BackupCloud.google]);
    });

    test('the backup copy is in the sweep catalog', () {
      for (final s in const [
        'Continue with Google',
        'Continue with Apple',
        'Remove Google backups',
        'Remove Apple backups',
        'Cloud Key Backup',
        'Wrong PIN',
        'Unlocking…',
        'Encrypting…',
      ]) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('the environment defaults carry the shipped Google ids, Apple group and passkeys', () {
      const env = KeyBackupConfig.environment;
      expect(env.googleIosClientId, kGoogleIosClientId);
      expect(env.googleServerClientId, kGoogleWebClientId);
      expect(env.appleBackup, isTrue);
      expect(env.appleKeychainGroup, 'KJ6U2Y9B2M.com.nym.shared');
      expect(env.passkeyBackup, isTrue);
      expect(env.passkeyRpId, 'web.nymchat.app');
      expect(env.googleEnabledOn(TargetPlatform.iOS, web: false), isTrue);
      expect(env.googleEnabledOn(TargetPlatform.android, web: false), isTrue);
      expect(env.googleEnabledOn(TargetPlatform.iOS, web: true), isFalse);
    });
  });

  group('sign-in buttons', () {
    testWidgets('render nothing when no provider is configured',
        (tester) async {
      await tester.pumpWidget(
          host(const [], KeyBackupSignInButtons(onSecret: (_) async {})));
      expect(find.text('Continue with Google'), findsNothing);
      expect(find.text('Continue with Apple'), findsNothing);
    });

    testWidgets('show one button per configured provider', (tester) async {
      await tester.pumpWidget(host(
        [FakeStore(BackupCloud.google), FakeStore(BackupCloud.apple)],
        KeyBackupSignInButtons(onSecret: (_) async {}),
      ));
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
    });

    testWidgets('restores the backed-up key with the right PIN',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seed(store, '2468', secret);
      final got = <String>[];
      await tester.pumpWidget(host(
          [store], KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));

      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      expect(find.byKey(const Key('keyBackupPin')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupPinConfirm')), findsNothing);

      await enterPin(tester, '2468');
      await tester.tap(find.text('UNLOCK'));
      await settle(tester);

      expect(got, [secret]);
      expect(find.byKey(const Key('keyBackupPin')), findsNothing);
    });

    testWidgets('a wrong PIN says so, then locks out with a growing delay',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      await seed(store, '2468', newSecret());
      final got = <String>[];
      await tester.pumpWidget(host(
          [store], KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));

      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      await enterPin(tester, '1111');
      await tester.tap(find.text('UNLOCK'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Wrong PIN'), findsOneWidget);
      expect(find.byKey(const Key('keyBackupPinWait')), findsOneWidget);
      expect(PinThrottle.forCloud(BackupCloud.google).failures, 1);
      expect(PinThrottle.forCloud(BackupCloud.google).remaining,
          greaterThan(Duration.zero));
      expect(got, isEmpty);

      await tester.tap(find.text('CANCEL'));
      await settle(tester);
      expect(got, isEmpty);
    });

    testWidgets('an invalid PIN is rejected before any derivation',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      await seed(store, '2468', newSecret());
      await tester.pumpWidget(host(
          [store], KeyBackupSignInButtons(onSecret: (_) async {})));
      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      await enterPin(tester, '12');
      await tester.tap(find.text('UNLOCK'));
      await tester.pump();
      expect(find.text('The PIN must be 4 to 8 digits.'), findsOneWidget);
      expect(PinThrottle.forCloud(BackupCloud.google).failures, 0);
    });

    testWidgets('several matching backups offer a picker', (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.apple);
      final a = newSecret();
      final b = newSecret();
      await seed(store, '12345678', a);
      await seed(store, '12345678', b);
      await seed(store, '12345678', b);
      await seed(store, '99999999', newSecret());
      final got = <String>[];
      await tester.pumpWidget(host(
          [store], KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));

      await tester.tap(find.byKey(const Key('keyBackupContinue_apple')));
      await settle(tester);
      await enterPin(tester, '12345678');
      await tester.tap(find.text('UNLOCK'));
      await settle(tester);

      expect(find.byKey(const Key('keyBackupCandidate0')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupCandidate1')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupCandidate2')), findsNothing);
      final npubB = shortNpub(BackupCandidate(
              secretHex: b,
              pubkeyHex: getPublicKeyHex(hexToBytes(b)),
              entries: [])
          .npub);
      await tester.tap(find.text(npubB));
      await settle(tester);
      expect(got, [b]);
    });

    testWidgets('a new account sets a PIN twice, uploads, then signs in',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final got = <String>[];
      await tester.pumpWidget(host(
          [store], KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));

      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      expect(find.byKey(const Key('keyBackupPinConfirm')), findsOneWidget);
      final warning = tester
          .widget<Text>(find.byKey(const Key('keyBackupPinWarning')))
          .data!;
      expect(warning, contains("can't be recovered"));
      expect(warning, contains('Anyone who has both your Google account'));

      await enterPin(tester, '2468', confirm: '2469');
      await tester.tap(find.text('CREATE AND BACK UP'));
      await tester.pump();
      expect(find.text('The two PINs do not match.'), findsOneWidget);
      expect(store.files, isEmpty);

      await enterPin(tester, '2468', confirm: '2468');
      await tester.tap(find.text('CREATE AND BACK UP'));
      await settle(tester);

      expect(got, hasLength(1));
      expect(store.files, hasLength(1));
      expect(await openWith(store, '2468'), got.single);
      expect(got.single, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    testWidgets('canceling the provider sign-in does nothing', (tester) async {
      final store = FakeStore(BackupCloud.google)..cancel = true;
      final got = <String>[];
      await tester.pumpWidget(host(
          [store], KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));
      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      expect(store.signIns, 1);
      expect(find.byKey(const Key('keyBackupPin')), findsNothing);
      expect(got, isEmpty);
    });
  });

  group('settings flows', () {
    Widget action(Future<void> Function(BuildContext, WidgetRef) run) =>
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () => run(context, ref),
            child: const Text('go'),
          ),
        );

    testWidgets('backing up replaces an existing backup of the same key',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      final pubkey = getPublicKeyHex(hexToBytes(secret));
      final other = newSecret();
      await seed(store, '5555', secret);
      await seed(store, '5555', other);
      await tester.pumpWidget(host(
        [store],
        action((context, ref) => runKeyBackupCreate(context, ref, store,
            secretHex: secret, pubkeyHex: pubkey)),
      ));

      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.byKey(const Key('keyBackupPinWarning')), findsOneWidget);
      await enterPin(tester, '5555', confirm: '5555');
      await tester.tap(find.text('BACK UP'));
      await settle(tester);

      expect(find.text('REPLACE BACKUP?'), findsOneWidget);
      await tester.tap(find.text('REPLACE'));
      await settle(tester);

      expect(find.text('BACKUP COMPLETE'), findsOneWidget);
      expect(store.files, hasLength(2));
      expect(store.files.containsKey('f0'), isFalse);
      expect(store.files.containsKey('f1'), isTrue);
      final key =
          await fastDerive('5555', backupSalt(store.cloud, store.accountId));
      expect(decryptBackupSecret(store.files['f2']!, key)?.secretHex, secret);
    });

    testWidgets('backing up with no existing copy uploads one file',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.apple);
      final secret = newSecret();
      await tester.pumpWidget(host(
        [store],
        action((context, ref) => runKeyBackupCreate(context, ref, store,
            secretHex: secret,
            pubkeyHex: getPublicKeyHex(hexToBytes(secret)))),
      ));
      await tester.tap(find.text('go'));
      await settle(tester);
      await enterPin(tester, '0000', confirm: '0000');
      await tester.tap(find.text('BACK UP'));
      await settle(tester);
      expect(find.text('REPLACE BACKUP?'), findsNothing);
      expect(store.files, hasLength(1));
      expect(await openWith(store, '0000'), secret);
    });

    testWidgets('remove deletes only this key\'s backups for that PIN',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seed(store, '4321', secret);
      await seed(store, '4321', newSecret());
      await seed(store, '4321', secret);
      await tester.pumpWidget(host(
        [store],
        action((context, ref) => runKeyBackupRemove(context, ref, store,
            pubkeyHex: getPublicKeyHex(hexToBytes(secret)))),
      ));
      await tester.tap(find.text('go'));
      await settle(tester);
      await enterPin(tester, '4321');
      await tester.tap(find.text('CONTINUE'));
      await settle(tester);
      await tester.tap(find.text('DELETE'));
      await settle(tester);
      expect(store.files.keys, ['f1']);
    });

    testWidgets('remove with a wrong PIN deletes nothing', (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seed(store, '4321', secret);
      await tester.pumpWidget(host(
        [store],
        action((context, ref) => runKeyBackupRemove(context, ref, store,
            pubkeyHex: getPublicKeyHex(hexToBytes(secret)))),
      ));
      await tester.tap(find.text('go'));
      await settle(tester);
      await enterPin(tester, '1234');
      await tester.tap(find.text('CONTINUE'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Wrong PIN, or no backup of this key uses it.'),
          findsOneWidget);
      expect(store.files, hasLength(1));
      await tester.tap(find.text('CANCEL'));
      await settle(tester);
    });
  });

  group('setup modal', () {
    Widget modalHost(List<KeyBackupStore> stores) {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      return ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          keyBackupStoresProvider.overrideWithValue(stores),
        ],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: SetupModal(onComplete: () {}),
        ),
      );
    }

    testWidgets('shows Continue with Google on both tabs when configured',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(modalHost([FakeStore(BackupCloud.google)]));
      await tester.pump();
      expect(find.text('Continue with Google'), findsOneWidget);
      await tester.tap(find.text('Login'));
      await tester.pump();
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('puts Apple before Google, well apart from Enter',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(modalHost(
          [FakeStore(BackupCloud.apple), FakeStore(BackupCloud.google)]));
      await tester.pump();
      final enter = tester.getRect(find.byKey(const Key('setupEnterBtn')));
      final apple =
          tester.getRect(find.byKey(const Key('keyBackupContinue_apple')));
      final google =
          tester.getRect(find.byKey(const Key('keyBackupContinue_google')));
      expect(apple.top - enter.bottom, greaterThanOrEqualTo(brandGroupGap));
      expect(apple.bottom, lessThan(google.top));
    });

    testWidgets('hides the buttons when nothing is configured',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(modalHost(const []));
      await tester.pump();
      expect(find.text('Continue with Google'), findsNothing);
      expect(find.text('Continue with Apple'), findsNothing);
    });
  });
}
