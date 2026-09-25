import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_pq_restore.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_service.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_store.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_service.dart';
import 'package:nym_bar/features/identity/nick_edit_modal.dart';
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/features/identity/setup_modal.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';

import 'key_backup_flow_test.dart' show FakeStore, fastDerive;
import 'passkey_fakes.dart';

class FakeController extends NostrController {
  FakeController(super.ref);

  Identity? fakeIdentity;
  String? code;
  bool linkNeeded = false;
  bool linkAccepts = true;
  final List<String> logins = [];
  final List<String> links = [];
  final List<String> notices = [];

  @override
  Identity? get identity => fakeIdentity;

  @override
  String? get pqRootCode => code;

  @override
  bool get pqRootHeld => code != null;

  @override
  bool get pqRootLinkNeeded => linkNeeded;

  @override
  Future<bool> linkPqRootFromCode(String code) async {
    links.add(code);
    if (!linkAccepts) return false;
    this.code = code;
    linkNeeded = false;
    return true;
  }

  final List<({String? pqRootCode, bool newKey})> loginArgs = [];

  @override
  Future<void> loginWithNsec(String nsec,
      {String? pqRootCode, bool newKey = false}) async {
    logins.add(nsec);
    loginArgs.add((pqRootCode: pqRootCode, newKey: newKey));
    if (newKey && pqRootCode != null) {
      code = pqRootCode;
    } else {
      linkNeeded = true;
    }
  }

  @override
  void showSystemNotice(String text) => notices.add(text);
}

String realCode() => pqRootToCode(randomBytes(32));

String newSecret() => bytesToHex(generatePrivateKey());

Future<Uint8List> keyFor(FakeStore store, String pin) =>
    fastDerive(pin, backupSalt(store.cloud, store.accountId));

Future<void> seedPlain(FakeStore store, String pin, String plaintext) async {
  await store.write(nip44.encrypt(plaintext, await keyFor(store, pin)));
}

Future<BackupSecret?> openBackup(FakeStore store, String pin) async {
  final key = await keyFor(store, pin);
  for (final p in store.files.values) {
    final s = decryptBackupSecret(p, key);
    if (s != null) return s;
  }
  return null;
}

void main() {
  late KeyValueStore kv;
  late FakeController ctrl;

  setUp(() async {
    PinThrottle.resetAll();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${StorageKeys.uiLanguageChosen}': 'true',
    });
    kv = await KeyValueStore.open();
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget app(Widget home, List<KeyBackupStore> stores,
      {PasskeyBackupService? passkey}) {
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
        nostrControllerProvider.overrideWith((ref) {
          ctrl = FakeController(ref);
          return ctrl;
        }),
        if (passkey != null) ...[
          passkeyBackupServiceProvider.overrideWithValue(passkey),
          passkeyBackupAvailableProvider.overrideWith((ref) async => true),
        ] else
          passkeyBackupAvailableProvider.overrideWith((ref) async => false),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: Consumer(
              builder: (context, ref, child) {
                ref.read(nostrControllerProvider);
                return child!;
              },
              child: home),
        ),
      ),
    );
  }

  Widget touch() => Consumer(builder: (context, ref, _) {
        ref.read(nostrControllerProvider);
        return const SizedBox();
      });

  Widget details(void Function() setup) {
    var ready = false;
    return Consumer(builder: (context, ref, _) {
      ref.read(nostrControllerProvider);
      if (!ready) {
        ready = true;
        setup();
      }
      return const NickEditModal();
    });
  }

  void signedIn(String secret, {String? loginMethod = 'nsec', String? code}) {
    final sk = hexToBytes(secret);
    ctrl
      ..fakeIdentity = Identity(
        pubkey: getPublicKeyHex(sk),
        privkey: loginMethod == 'nip46' ? null : sk,
        nym: 'tester#abcd',
        loginMethod: loginMethod,
      )
      ..code = code;
  }

  group('restoring through the setup modal', () {
    Future<void> continueWithGoogle(WidgetTester tester, String pin) async {
      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), pin);
      await tester.tap(find.text('UNLOCK'));
      await settle(tester);
    }

    testWidgets('restores the key, then links the backed-up recovery code',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      final code = realCode();
      await store.write(encryptBackupSecret(secret, await keyFor(store, '2468'),
          pqCode: code));
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();

      await continueWithGoogle(tester, '2468');

      expect(ctrl.logins, [secret]);
      expect(ctrl.loginArgs.single, (pqRootCode: code, newKey: false));
      expect(ctrl.links, [code]);
      expect(ctrl.code, code);
      expect(ctrl.notices, isEmpty);
    });

    testWidgets('a legacy bare-hex backup restores without a code',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seedPlain(store, '2468', secret);
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();

      await continueWithGoogle(tester, '2468');

      expect(ctrl.logins, [secret]);
      expect(ctrl.links, isEmpty);
      expect(find.text('RECOVERY CODE SKIPPED'), findsNothing);
    });

    testWidgets('a bad code is skipped with a note and never blocks sign-in',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seedPlain(
          store, '2468', '{"v":1,"sk":"$secret","pq":"nympq1notarealcode"}');
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();

      await continueWithGoogle(tester, '2468');

      expect(find.text('RECOVERY CODE SKIPPED'), findsOneWidget);
      expect(ctrl.logins, isEmpty);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(ctrl.logins, [secret]);
      expect(ctrl.links, isEmpty);
    });

    testWidgets('a passkey backup restores the code too', (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final platform = FakePasskeyPlatform(prf: prf);
      final relays = FakeRelays();
      final service = fakePasskeyService(platform, relays);
      final secret = newSecret();
      final code = realCode();
      await service.backUp(
          secretHex: secret,
          pubkeyHex: getPublicKeyHex(hexToBytes(secret)),
          pqCode: code);
      await tester.pumpWidget(
          app(SetupModal(onComplete: () {}), const [], passkey: service));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Login'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('keyBackupContinue_passkey')));
      await settle(tester);

      expect(ctrl.logins, [secret]);
      expect(ctrl.links, [code]);
    });
  });

  group('restoreBackupPqCode', () {
    testWidgets('waits for the account state, then links', (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      final code = realCode();
      var done = false;
      restoreBackupPqCode(
              ctrl, BackupSecret(secretHex: newSecret(), pqCode: code))
          .then((_) => done = true);
      await tester.pump(const Duration(seconds: 1));
      expect(ctrl.links, isEmpty);
      expect(done, isFalse);
      ctrl.linkNeeded = true;
      await tester.pump(const Duration(seconds: 1));
      expect(ctrl.links, [code]);
      expect(done, isTrue);
    });

    testWidgets('does nothing when this device already holds that code',
        (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      final code = realCode();
      ctrl.code = code;
      final result = await restoreBackupPqCode(
          ctrl, BackupSecret(secretHex: newSecret(), pqCode: code));
      expect(result, BackupPqRestore.alreadyHeld);
      expect(ctrl.links, isEmpty);
    });

    testWidgets('a code the account rejects leaves a note', (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      ctrl
        ..linkNeeded = true
        ..linkAccepts = false;
      final result = await restoreBackupPqCode(
          ctrl, BackupSecret(secretHex: newSecret(), pqCode: realCode()));
      expect(result, BackupPqRestore.rejected);
      expect(ctrl.notices, hasLength(1));
      expect(ctrl.notices.single, contains('does not match this account'));
    });

    testWidgets('no code means nothing to do', (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      final result =
          await restoreBackupPqCode(ctrl, BackupSecret(secretHex: newSecret()));
      expect(result, BackupPqRestore.none);
      expect(ctrl.links, isEmpty);
    });
  });

  group("View or Edit Nym's Details", () {
    Future<void> openReveal(WidgetTester tester) async {
      await tester
          .tap(find.text("Reveal this nym's private key and recovery code"));
      await settle(tester);
    }

    testWidgets('holds the backup buttons beside the nsec and recovery code',
        (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final service =
          fakePasskeyService(FakePasskeyPlatform(prf: prf), FakeRelays());
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        [FakeStore(BackupCloud.google), FakeStore(BackupCloud.apple)],
        passkey: service,
      ));
      await tester.pump();
      expect(find.byKey(const Key('keyBackupActions')), findsNothing);
      await openReveal(tester);

      expect(find.byKey(const Key('keyBackupActions')), findsOneWidget);
      expect(find.text('Cloud Key Backup'), findsOneWidget);
      expect(find.byKey(const Key('keyBackupBackUp_google')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupBackUp_apple')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupBackUp_passkey')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupRemove_google')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupRemove_apple')), findsOneWidget);
      expect(find.text('Post-quantum recovery code'), findsOneWidget);
    });

    testWidgets('backing up to Google includes the recovery code',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        [store],
      ));
      await tester.pump();
      await openReveal(tester);
      await tester.tap(find.byKey(const Key('keyBackupBackUp_google')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), '4444');
      await tester.enterText(
          find.byKey(const Key('keyBackupPinConfirm')), '4444');
      await tester.tap(find.text('BACK UP'));
      await settle(tester);

      expect(find.text('BACKUP COMPLETE'), findsOneWidget);
      final back = await openBackup(store, '4444');
      expect(back!.secretHex, secret);
      expect(back.pqCode, code);
    });

    testWidgets('backing up with a passkey includes the recovery code',
        (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final relays = FakeRelays();
      final service = fakePasskeyService(FakePasskeyPlatform(prf: prf), relays);
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        const [],
        passkey: service,
      ));
      await tester.pump();
      await openReveal(tester);
      await tester.tap(find.byKey(const Key('keyBackupBackUp_passkey')));
      await settle(tester);

      expect(find.text('BACKED UP'), findsOneWidget);
      final back = PasskeyBackupKeys.fromPrf(prf)
          .decrypt(relays.published.single.content)!;
      expect(back.secretHex, secret);
      expect(back.pqCode, code);
    });

    testWidgets('an account without a code backs up the key alone',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.apple);
      final secret = newSecret();
      await tester.pumpWidget(app(
        details(() => signedIn(secret)),
        [store],
      ));
      await tester.pump();
      await openReveal(tester);
      await tester.tap(find.byKey(const Key('keyBackupBackUp_apple')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), '4444');
      await tester.enterText(
          find.byKey(const Key('keyBackupPinConfirm')), '4444');
      await tester.tap(find.text('BACK UP'));
      await settle(tester);
      final key = await keyFor(store, '4444');
      expect(nip44.decrypt(store.files.values.single, key),
          '{"v":1,"sk":"$secret"}');
    });

    testWidgets('remote signers get no backup buttons', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        details(() =>
            signedIn(newSecret(), loginMethod: 'nip46', code: realCode())),
        [FakeStore(BackupCloud.google)],
      ));
      await tester.pump();
      await openReveal(tester);
      expect(find.byKey(const Key('keyBackupActions')), findsNothing);
      expect(find.byKey(const Key('keyBackupBackUp_google')), findsNothing);
    });
  });

  group('a brand-new key gets its recovery code at once', () {
    testWidgets('Continue with Google on a new account backs up both',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), '2468');
      await tester.enterText(
          find.byKey(const Key('keyBackupPinConfirm')), '2468');
      await tester.tap(find.text('CREATE AND BACK UP'));
      await settle(tester);

      final backup = (await openBackup(store, '2468'))!;
      expect(backup.pqCode, isNotNull);
      expect(pqRootFromCode(backup.pqCode!), isNotNull);
      expect(ctrl.logins, [backup.secretHex]);
      expect(ctrl.loginArgs.single, (pqRootCode: backup.pqCode, newKey: true));
      expect(ctrl.code, backup.pqCode);
      expect(ctrl.links, isEmpty);
    });

    testWidgets('creating a key with a passkey backs up both', (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final relays = FakeRelays();
      final service = fakePasskeyService(FakePasskeyPlatform(prf: prf), relays);
      await tester.pumpWidget(
          app(SetupModal(onComplete: () {}), const [], passkey: service));
      await tester.pump();
      await tester.pump();
      await tester
          .tap(find.byKey(const Key('keyBackupContinue_passkeyCreate')));
      await settle(tester);

      final backup = PasskeyBackupKeys.fromPrf(prf)
          .decrypt(relays.published.single.content)!;
      expect(pqRootFromCode(backup.pqCode!), isNotNull);
      expect(ctrl.logins, [backup.secretHex]);
      expect(ctrl.loginArgs.single, (pqRootCode: backup.pqCode, newKey: true));
      expect(ctrl.links, isEmpty);
    });

    testWidgets('the largeBlob fallback carries the new code too',
        (tester) async {
      tall(tester);
      final platform = FakePasskeyPlatform()
        ..prfEnabled = false
        ..largeBlob = true;
      final service = fakePasskeyService(platform, FakeRelays());
      await tester.pumpWidget(
          app(SetupModal(onComplete: () {}), const [], passkey: service));
      await tester.pump();
      await tester.pump();
      await tester
          .tap(find.byKey(const Key('keyBackupContinue_passkeyCreate')));
      await settle(tester);

      final backup = decodeLargeBlob(platform.storedBlob)!;
      expect(pqRootFromCode(backup.pqCode!), isNotNull);
      expect(ctrl.loginArgs.single, (pqRootCode: backup.pqCode, newKey: true));
    });

    testWidgets('the reveal then shows the nsec and the code together',
        (tester) async {
      tall(tester);
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        [FakeStore(BackupCloud.google)],
      ));
      await tester.pump();
      await tester
          .tap(find.text("Reveal this nym's private key and recovery code"));
      await settle(tester);
      expect(find.text('nsec (Nostr Private Key)'), findsOneWidget);
      expect(find.text('Post-quantum recovery code'), findsOneWidget);
      expect(
          find.text('This device has no recovery code yet. Paste the one '
              'from a device that already has it — you will find it in this '
              'same panel there — so both can read the same quantum-resistant '
              'messages.'),
          findsNothing);
    });
  });

  group('seeding the root for a key', () {
    PqRootSeed seed({
      bool hold = false,
      bool local = true,
      bool throwaway = false,
      bool pending = false,
      bool fresh = false,
    }) =>
        pqRootSeedForKey(
          holdRoot: hold,
          localKey: local,
          throwawayKeypair: throwaway,
          pendingForThisKey: pending,
          freshKey: fresh,
        );

    test('a freshly generated key gets a root right away', () {
      expect(seed(fresh: true), PqRootSeed.generate);
    });

    test('a new key signed in with its code adopts that code', () {
      expect(seed(pending: true), PqRootSeed.pending);
      expect(seed(pending: true, fresh: true), PqRootSeed.pending);
    });

    test('existing accounts are left to the usual record check', () {
      expect(seed(), PqRootSeed.none);
      expect(seed(hold: true, fresh: true), PqRootSeed.none);
      expect(seed(hold: true, pending: true), PqRootSeed.none);
    });

    test('remote signers and throwaway keys get none', () {
      expect(seed(local: false, fresh: true), PqRootSeed.none);
      expect(seed(throwaway: true, fresh: true), PqRootSeed.none);
      expect(seed(throwaway: true, pending: true), PqRootSeed.none);
    });
  });

  group('controller wiring', () {
    final src = File('lib/state/nostr_controller.dart').readAsStringSync();

    test('the root is seeded right after it is loaded at boot', () {
      final load = src.indexOf('await _loadPqRoot(unlockedSecrets');
      final seed = src.indexOf('await _seedNewKeyPqRoot(identity');
      expect(load, greaterThan(-1));
      expect(seed, greaterThan(load));
      expect(src.substring(load, seed).split('\n').length, lessThan(4));
    });

    test('generating adopts a backed-up code before minting a new one', () {
      final branch = src.substring(src.indexOf('case PqRootAction.generate:'));
      final body =
          branch.substring(0, branch.indexOf('Future<void> _armPqRoot'));
      expect(body.contains('_createPqRoot(sync, existing: candidate)'), isTrue);
      expect(body.contains('existing ?? pq.pqGenerateRoot()'), isTrue);
      expect(body.indexOf('_persistPqRoot(root)'),
          lessThan(body.indexOf('pqRootRecordSet(')));
      expect(body.contains('publishPqAnnouncement(force: true)'), isTrue);
    });

    test('a held but unrecorded root is recorded and announced', () {
      final branch =
          src.substring(src.indexOf('case PqRootAction.publishRecord:'));
      final body =
          branch.substring(0, branch.indexOf('case PqRootAction.awaitLink:'));
      expect(body.contains('_createPqRoot(sync, existing: held)'), isTrue);
    });

    test('login keeps a new key\'s code apart from a restored one', () {
      final login = src.substring(src.indexOf('Future<void> loginWithNsec('));
      final body = login.substring(0, login.indexOf('await init();'));
      expect(
          body.contains('_pqRootForNewKey = (pubkey: loggedIn.pubkey'), isTrue);
      expect(body.contains('_pqRootCandidate = root;'), isTrue);
    });
  });

  test('the new copy is in the sweep catalog', () {
    for (final s in const [
      'Recovery code skipped',
      'The backup also holds your post-quantum recovery code when this '
          'device has it.',
      'The backup options are in View or Edit Nym’s Details, beside '
          'your private key and recovery code.',
    ]) {
      expect(kAppStringsCatalog, contains(s), reason: s);
    }
  });
}
