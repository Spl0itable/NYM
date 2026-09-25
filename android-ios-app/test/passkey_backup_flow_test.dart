import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart' show encodeNpub;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_service.dart' show shortNpub;
import 'package:nym_bar/features/identity/key_backup/key_backup_store.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_ui.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_service.dart';
import 'package:nym_bar/features/identity/setup_modal.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

import 'passkey_fakes.dart';

void main() {
  final prf = hexToBytes('a1' * 32);
  late KeyValueStore kv;
  late FakePasskeyPlatform platform;
  late FakeRelays relays;
  late PasskeyBackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${StorageKeys.uiLanguageChosen}': 'true',
    });
    kv = await KeyValueStore.open();
    platform = FakePasskeyPlatform(prf: prf);
    relays = FakeRelays();
    service = fakePasskeyService(platform, relays);
  });

  List<Override> overrides({bool available = true}) => [
        keyValueStoreProvider.overrideWithValue(kv),
        keyBackupStoresProvider.overrideWithValue(const []),
        passkeyBackupServiceProvider.overrideWithValue(available ? service : null),
      ];

  Widget host(Widget child, {bool available = true}) {
    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );
    return ProviderScope(
      overrides: overrides(available: available),
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

  String? backedUpSecret() {
    if (relays.published.isEmpty) return null;
    return PasskeyBackupKeys.fromPrf(prf)
        .decrypt(relays.published.last.content)
        ?.secretHex;
  }

  Future<void> seedBackup(String secret) => service.backUp(
      secretHex: secret, pubkeyHex: getPublicKeyHex(hexToBytes(secret)));

  group('buttons', () {
    testWidgets('login offers only Continue with a passkey', (tester) async {
      await tester.pumpWidget(
          host(KeyBackupSignInButtons(onSecret: (_) async {})));
      await tester.pump();
      expect(find.text('Continue with a passkey'), findsOneWidget);
      expect(find.text('Sign up with a passkey'), findsNothing);
      expect(find.byKey(const Key('keyBackupContinue_passkeyCreate')),
          findsNothing);
    });

    testWidgets('sign-up offers only Sign up with a passkey', (tester) async {
      await tester.pumpWidget(host(
          KeyBackupSignInButtons(onSecret: (_) async {}, signUp: true)));
      await tester.pump();
      expect(find.text('Sign up with a passkey'), findsOneWidget);
      expect(find.text('Continue with a passkey'), findsNothing);
      expect(
          find.text('Your new key is backed up with a passkey. The backup is '
              'encrypted, and only your passkey can unlock it.'),
          findsOneWidget);
      expect(find.byKey(const Key('keyBackupContinue_passkey')), findsNothing);
    });

    testWidgets('hidden when passkeys are unavailable', (tester) async {
      await tester.pumpWidget(host(
          KeyBackupSignInButtons(onSecret: (_) async {}, signUp: true),
          available: false));
      await tester.pump();
      expect(find.text('Continue with a passkey'), findsNothing);
      expect(find.text('Sign up with a passkey'), findsNothing);
    });

    testWidgets('hidden when the platform reports no passkey support',
        (tester) async {
      platform.available = false;
      await tester.pumpWidget(
          host(KeyBackupSignInButtons(onSecret: (_) async {})));
      await tester.pump();
      expect(find.text('Continue with a passkey'), findsNothing);
      expect(find.text('Sign up with a passkey'), findsNothing);
    });
  });

  group('continue with a passkey', () {
    testWidgets('restores the backed-up key and signs in', (tester) async {
      tall(tester);
      final secret = bytesToHex(generatePrivateKey());
      await seedBackup(secret);
      platform.calls.clear();
      final got = <String>[];
      await tester.pumpWidget(host(
          KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkey')));
      await settle(tester);
      expect(got, [secret]);
      expect(platform.calls, ['get']);
    });

    testWidgets('no passkey chosen offers a new key, which is backed up',
        (tester) async {
      tall(tester);
      platform.getError = PasskeyBackupError.canceled;
      final got = <String>[];
      await tester.pumpWidget(host(
          KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkey')));
      await settle(tester);
      expect(
          find.text('No passkey was chosen. Create a new key and back it up '
              'with a passkey?'),
          findsOneWidget);
      platform.getError = null;
      await tester.tap(find.text('CREATE NEW KEY'));
      await settle(tester);
      expect(got, hasLength(1));
      expect(platform.calls, ['get', 'create']);
      expect(backedUpSecret(), got.single);
      expect(
          platform.lastCreate!['userName'] as String,
          'Nymchat key backup · ${shortNpubFor(getPublicKeyHex(hexToBytes(got.single)))}');
    });

    testWidgets('no backup found offers a new key; declining does nothing',
        (tester) async {
      tall(tester);
      platform.hasCredential = true;
      final got = <String>[];
      await tester.pumpWidget(host(
          KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkey')));
      await settle(tester);
      expect(
          find.text('No key backup is linked to this passkey. Create a new '
              'key and back it up with a passkey?'),
          findsOneWidget);
      await tester.tap(find.text('CANCEL'));
      await settle(tester);
      expect(got, isEmpty);
      expect(platform.calls, ['get']);
    });

    testWidgets('other errors are explained', (tester) async {
      tall(tester);
      platform.getError = PasskeyBackupError.rp;
      final got = <String>[];
      await tester.pumpWidget(host(
          KeyBackupSignInButtons(onSecret: (s) async => got.add(s.secretHex))));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkey')));
      await settle(tester);
      expect(find.text("Passkeys aren't set up for this app yet."),
          findsOneWidget);
      expect(got, isEmpty);
    });
  });

  group('create a new key with a passkey', () {
    testWidgets('creates, backs up, then signs in', (tester) async {
      tall(tester);
      final got = <String>[];
      await tester.pumpWidget(host(KeyBackupSignInButtons(
          onSecret: (s) async => got.add(s.secretHex), signUp: true)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkeyCreate')));
      await settle(tester);
      expect(got, hasLength(1));
      expect(platform.calls, ['create']);
      expect(backedUpSecret(), got.single);
    });

    testWidgets('uses the largeBlob fallback without PRF', (tester) async {
      tall(tester);
      platform
        ..prf = null
        ..prfEnabled = false
        ..largeBlob = true;
      final got = <String>[];
      await tester.pumpWidget(host(KeyBackupSignInButtons(
          onSecret: (s) async => got.add(s.secretHex), signUp: true)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkeyCreate')));
      await settle(tester);
      expect(got, hasLength(1));
      expect(decodeLargeBlob(platform.storedBlob)?.secretHex, got.single);
      expect(relays.published, isEmpty);
    });

    testWidgets('a failed backup still signs in and points to the Nym details',
        (tester) async {
      tall(tester);
      relays.accept = false;
      final got = <String>[];
      await tester.pumpWidget(host(KeyBackupSignInButtons(
          onSecret: (s) async => got.add(s.secretHex), signUp: true)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkeyCreate')));
      await settle(tester);
      expect(find.textContaining('Back up with a passkey'), findsOneWidget);
      expect(got, isEmpty);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(got, hasLength(1));
      expect(got.single, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    testWidgets('canceling the passkey sheet creates nothing', (tester) async {
      tall(tester);
      platform.createError = PasskeyBackupError.canceled;
      final got = <String>[];
      await tester.pumpWidget(host(KeyBackupSignInButtons(
          onSecret: (s) async => got.add(s.secretHex), signUp: true)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_passkeyCreate')));
      await settle(tester);
      expect(got, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('settings', () {
    Widget action(Future<void> Function(BuildContext) run) => Builder(
          builder: (context) => TextButton(
            onPressed: () => run(context),
            child: const Text('go'),
          ),
        );

    testWidgets('back up with a passkey confirms success', (tester) async {
      tall(tester);
      final secret = bytesToHex(generatePrivateKey());
      await tester.pumpWidget(host(action((context) => runPasskeyBackup(
          context, service,
          secretHex: secret,
          pubkeyHex: getPublicKeyHex(hexToBytes(secret))))));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('BACKED UP'), findsOneWidget);
      expect(backedUpSecret(), secret);
    });

    testWidgets('an unsupported provider is explained', (tester) async {
      tall(tester);
      platform
        ..prf = null
        ..prfEnabled = false;
      final secret = bytesToHex(generatePrivateKey());
      await tester.pumpWidget(host(action((context) => runPasskeyBackup(
          context, service,
          secretHex: secret,
          pubkeyHex: getPublicKeyHex(hexToBytes(secret))))));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.textContaining("can't hold a key backup"), findsOneWidget);
    });
  });

  group('setup modal', () {
    Widget modal() {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      return ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: SetupModal(onComplete: () {}),
        ),
      );
    }

    testWidgets('sign-up shows only Sign up, login only Continue',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(modal());
      await tester.pump();
      await tester.pump();
      expect(find.text('Sign up with a passkey'), findsOneWidget);
      expect(find.text('Continue with a passkey'), findsNothing);
      await tester.tap(find.text('Login'));
      await tester.pump();
      expect(find.text('Continue with a passkey'), findsOneWidget);
      expect(find.text('Sign up with a passkey'), findsNothing);
      await tester.tap(find.text('Sign up'));
      await tester.pump();
      expect(find.text('Sign up with a passkey'), findsOneWidget);
      expect(find.text('Continue with a passkey'), findsNothing);
    });
  });

  test('the passkey copy is in the sweep catalog', () {
    for (final s in const [
      'Continue with a passkey',
      'Sign up with a passkey',
      'Your new key is backed up with a passkey. The backup is encrypted, '
          'and only your passkey can unlock it.',
      'Back up with a passkey',
      'No key backup is linked to this passkey.',
      'Create new key',
    ]) {
      expect(kAppStringsCatalog, contains(s), reason: s);
    }
  });
}

String shortNpubFor(String pubkey) => shortNpub(encodeNpub(pubkey));
