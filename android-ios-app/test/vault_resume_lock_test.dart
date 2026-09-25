import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/identity/biometric_secret_store.dart';
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/features/identity/vault_boot_unlock.dart';
import 'package:nym_bar/features/identity/vault_settings_modal.dart'
    show identityVaultProvider;
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemSecure implements SecureStoreLike {
  final Map<String, String> map = {};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
  @override
  Future<void> wipeAll() async => map.clear();
}

class _Bio implements BiometricSecretStore {
  String? stored;
  int deletes = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String secret) async => stored = secret;

  @override
  Future<void> delete() async {
    deletes++;
    stored = null;
  }

  @override
  Future<bool> confirmPresence() async => true;
}

Future<KeyValueStore> _kv() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('where no background wake exists the vault key is not escrowed',
      () async {
    final secure = _MemSecure();
    await secure.set('nym_session_nsec', 'the-secret');
    secure.map['nym_vault_bg_key'] = 'left-by-an-older-version';
    final vault = IdentityVault(await _kv(), secure, escrow: false);

    await vault.enable(method: 'password', password: 'hunter2');
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
    expect(await vault.unlockForBackgroundWake(), isNull);

    await vault.unlock('hunter2');
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
  });

  testWidgets('an app woken in the background stays behind the lock',
      (tester) async {
    await tester.pumpWidget(const VaultLockedApp(
      app: Directionality(
          textDirection: TextDirection.ltr, child: Text('private chats')),
      lock: Directionality(
          textDirection: TextDirection.ltr, child: Text('unlock')),
    ));
    expect(find.text('unlock'), findsOneWidget);
    expect(find.text('private chats'), findsNothing);
    expect(find.text('private chats', skipOffstage: false), findsOneWidget);
  });

  Widget host(KeyValueStore kv, IdentityVault vault, Widget child) {
    return ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        identityVaultProvider.overrideWithValue(vault),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(resolveNymColors(
          theme: NymThemeKey.bitchat,
          brightness: Brightness.dark,
          solidUi: true,
        )),
        home: child,
      ),
    );
  }

  Future<(KeyValueStore, IdentityVault, _MemSecure, _Bio)>
      biometricVault() async {
    final kv = await _kv();
    final secure = _MemSecure();
    await secure.set('nym_session_nsec', 'the-secret');
    final bio = _Bio();
    final vault = IdentityVault(kv, secure, escrow: true, biometric: bio);
    await vault.enableBiometric();
    return (kv, vault, secure, bio);
  }

  void expectWiped(IdentityVault vault, _MemSecure secure, _Bio bio) {
    expect(vault.isEnabled, isFalse);
    expect(bio.stored, isNull);
    expect(bio.deletes, greaterThan(0));
    expect(secure.map.containsKey('nym_session_nsec'), isFalse);
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
  }

  testWidgets(
      'the lock over a woken app can forget the identity after a confirmation',
      (tester) async {
    final (kv, vault, secure, bio) = (await tester.runAsync(biometricVault))!;
    expect(secure.map.containsKey('nym_vault_bg_key'), isTrue);
    var forgotten = 0;
    await tester.pumpWidget(host(
      kv,
      vault,
      VaultLockedApp(
        app: const Text('private chats'),
        lock: VaultBootUnlock(
          onUnlocked: (_) {},
          onForget: () => forgotten++,
        ),
      ),
    ));

    await tester.tap(find.text('FORGET IDENTITY'));
    await tester.pumpAndSettle();
    expect(find.textContaining('permanently deletes the encrypted identity'),
        findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(forgotten, 0);
    expect(vault.isEnabled, isTrue);

    await tester.tap(find.text('FORGET IDENTITY'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FORGET'));
    await tester.pumpAndSettle();

    expect(forgotten, 1);
    expectWiped(vault, secure, bio);
  });

  testWidgets(
      'a changed biometric enrollment can be forgotten from the lock over a '
      'woken app', (tester) async {
    final (kv, vault, secure, bio) = (await tester.runAsync(biometricVault))!;
    bio.stored = null;
    var forgotten = 0;
    var unlocked = 0;
    await tester.pumpWidget(host(
      kv,
      vault,
      VaultLockedApp(
        app: const Text('private chats'),
        lock: VaultBootUnlock(
          onUnlocked: (_) => unlocked++,
          onForget: () => forgotten++,
        ),
      ),
    ));

    await tester.tap(find.text('UNLOCK'));
    await tester.pumpAndSettle();
    expect(unlocked, 0);
    expect(
      find.text(const BiometricVaultException(BiometricVaultFailure.invalidated)
          .message),
      findsOneWidget,
    );

    await tester.tap(find.text('FORGET IDENTITY'));
    await tester.pumpAndSettle();

    expect(forgotten, 1);
    expectWiped(vault, secure, bio);
  });
}
