import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/features/identity/vault_boot_unlock.dart';
import 'package:nym_bar/features/identity/vault_settings_modal.dart'
    show identityVaultProvider;
import 'package:nym_bar/features/notifications/notification_sounds.dart';
import 'package:nym_bar/features/notifications/notifications_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

void main() {
  // ===========================================================================
  // 1. Boot-unlock gate visibility — shown iff nym_vault_enabled == '1'.
  // ===========================================================================
  group('vault boot-unlock gate', () {
    Widget host(KeyValueStore kv, IdentityVault vault, Widget child) {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      return ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          identityVaultProvider.overrideWithValue(vault),
        ],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: child,
        ),
      );
    }

    testWidgets('shows the unlock screen when the vault is enabled',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        // PWA stores '1'; the gate checks getBool(vaultEnabled).
        StorageKeys.vaultEnabled: '1',
        StorageKeys.vaultMethod: 'password',
      });
      final kv = await KeyValueStore.open();
      final mem = _MemSecure();
      final vault = IdentityVault(kv, mem.asSecureStore());

      await tester.pumpWidget(host(
        kv,
        vault,
        VaultBootUnlock(onUnlocked: (_) {}, onForget: () {}),
      ));
      await tester.pump();

      // Modal chrome uppercases header + button labels (PWA `.modal-header` /
      // `.send-btn` / `.icon-btn` are `text-transform:uppercase`).
      expect(find.text('UNLOCK YOUR IDENTITY'), findsOneWidget);
      expect(find.text('UNLOCK'), findsOneWidget);
      expect(find.text('FORGET IDENTITY'), findsOneWidget);
      // Password method exposes a text field.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets(
        'mirrors the enabled check: gate logic hides unlock when disabled',
        (tester) async {
      // When disabled the top-level gate never constructs VaultBootUnlock; here
      // we assert the source-of-truth predicate the gate uses.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      expect(kv.getBool(StorageKeys.vaultEnabled), isFalse);

      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageKeys.vaultEnabled: '1',
      });
      final kv2 = await KeyValueStore.open();
      expect(kv2.getBool(StorageKeys.vaultEnabled), isTrue);
    });

    // The unlock-flow widget tests use a fast fake vault so the gesture →
    // setState → callback wiring is exercised without paying for (or hanging on)
    // the real PBKDF2 inside the fake-async testWidgets zone. The REAL crypto
    // (right token decrypts to 'nymchat-vault-ok', wrong one throws) is covered
    // by the 'vault check token' group below with the production IdentityVault.
    testWidgets('correct password drives unlock → onUnlocked', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageKeys.vaultEnabled: '1',
        StorageKeys.vaultMethod: 'password',
      });
      final kv = await KeyValueStore.open();
      final mem = _MemSecure();
      final vault = _FakeVault(kv, mem.asSecureStore(), correct: 'hunter2');

      var unlocked = false;
      Map<String, String>? receivedSecrets;
      await tester.pumpWidget(host(
        kv,
        vault,
        VaultBootUnlock(
          onUnlocked: (secrets) {
            unlocked = true;
            receivedSecrets = secrets;
          },
          onForget: () {},
          secureStore: mem.asSecureStore(),
        ),
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.tap(find.text('UNLOCK'));
      // On success the gate (in the real app) swaps this widget out, so it
      // intentionally leaves the busy spinner running — pump bounded frames
      // rather than pumpAndSettle (which would hang on that indefinite anim).
      for (var i = 0; i < 20 && !unlocked; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(unlocked, isTrue);
      // The decrypted secrets are handed to the caller IN MEMORY (not written
      // back to storage) — the native analogue of the PWA's `_vaultMem`.
      expect(receivedSecrets?[SecretKeys.sessionNsec], isNotNull);
    });

    testWidgets('wrong password shows the error, no onUnlocked',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageKeys.vaultEnabled: '1',
        StorageKeys.vaultMethod: 'password',
      });
      final kv = await KeyValueStore.open();
      final mem = _MemSecure();
      final vault = _FakeVault(kv, mem.asSecureStore(), correct: 'correcthorse');

      var unlocked = false;
      await tester.pumpWidget(host(
        kv,
        vault,
        VaultBootUnlock(
          onUnlocked: (_) => unlocked = true,
          onForget: () {},
          secureStore: mem.asSecureStore(),
        ),
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'wrongpassword');
      await tester.tap(find.text('UNLOCK'));
      await tester.pumpAndSettle();

      expect(unlocked, isFalse);
      expect(
        find.text('Wrong password/PIN or unrecognised passkey.'),
        findsOneWidget,
      );
    });
  });

  // ===========================================================================
  // 2. IdentityVault crypto round-trip (real PBKDF2/AES-GCM, in-memory store).
  // ===========================================================================
  group('vault check token', () {
    test('correct password decrypts check to nymchat-vault-ok', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final mem = _MemSecure();
      final vault = IdentityVault(kv, mem.asSecureStore());
      await vault.enable(method: 'password', password: 'pw1234');

      // The check token verifies the key (the PWA's 'nymchat-vault-ok').
      expect(await vault.verifyPassword('pw1234'), isTrue);
      // Unlock returns without throwing.
      await vault.unlock('pw1234');
    });

    test('wrong password throws on unlock', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final mem = _MemSecure();
      final vault = IdentityVault(kv, mem.asSecureStore());
      await vault.enable(method: 'password', password: 'pw1234');

      expect(await vault.verifyPassword('nope'), isFalse);
      await expectLater(vault.unlock('nope'), throwsA(anything));
    });
  });

  // ===========================================================================
  // 3. Notification sound resolution + playSound (mocked player, no audio).
  // ===========================================================================
  group('notification sounds', () {
    test('resolveSound: silent for none, descriptor for a real tone', () {
      expect(resolveSound('none'), isNull);
      expect(soundIsAudible('none'), isFalse);
      expect(resolveSound('beep'), isNotNull);
      expect(soundIsAudible('beep'), isTrue);
      // Legacy alias resolves.
      expect(resolveSound('msn'), isNotNull);
    });

    /// Builds a service whose player is the [_FakePlayer], via a real [Ref].
    Future<(NotificationsService, _FakePlayer)> buildSvc() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final player = _FakePlayer();
      final container = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          notificationsServiceProvider.overrideWith(
            (ref) => NotificationsService(ref, player: player),
          ),
        ],
      );
      addTearDown(container.dispose);
      return (container.read(notificationsServiceProvider), player);
    }

    test('playSound: silent is a no-op (player never invoked)', () async {
      final (svc, player) = await buildSvc();
      await svc.playSound('none');
      expect(player.played, isEmpty);
    });

    test('playSound: audible tone reaches the (mocked) player, no throw',
        () async {
      final (svc, player) = await buildSvc();
      await svc.playSound('beep');
      expect(player.played, contains('beep'));
      // WAV bytes were rendered and handed over.
      expect(player.lastWav, isNotNull);
      expect(player.lastWav!.isNotEmpty, isTrue);
    });

    test('playSound: 2s replay guard suppresses the second play', () async {
      final (svc, player) = await buildSvc();
      await svc.playSound('beep');
      await svc.playSound('beep'); // within 2s → suppressed
      expect(player.played.length, 1);
    });
  });
}

/// Fast [IdentityVault] stand-in for the unlock-flow widget tests: matches a
/// single [correct] password (returning a decrypted secret) and throws on any
/// other, without running real PBKDF2. Behaves as an enabled password vault.
class _FakeVault extends IdentityVault {
  _FakeVault(super.kv, super.secure, {required this.correct});
  final String correct;

  @override
  bool get isEnabled => true;

  @override
  String get method => 'password';

  @override
  Future<Map<String, String>> unlock(String password) async {
    if (password != correct) {
      throw StateError('Wrong password/PIN.');
    }
    return {SecretKeys.sessionNsec: 'decrypted-nsec'};
  }

  @override
  Future<void> reset() async {}
}

/// In-memory [SecureStoreLike] (same shape as the identity test's fake).
class _MemSecure {
  final Map<String, String> map = {};
  Future<String?> get(String key) async => map[key];
  Future<void> set(String key, String value) async => map[key] = value;
  Future<void> remove(String key) async => map.remove(key);
  Future<void> wipeAll() async => map.clear();
  _MemSecureStore asSecureStore() => _MemSecureStore(this);
}

class _MemSecureStore implements SecureStoreLike {
  _MemSecureStore(this._mem);
  final _MemSecure _mem;
  @override
  Future<String?> get(String key) => _mem.get(key);
  @override
  Future<void> set(String key, String value) => _mem.set(key, value);
  @override
  Future<void> remove(String key) => _mem.remove(key);
  @override
  Future<void> wipeAll() => _mem.wipeAll();
}

/// No-op [TonePlayer] that records calls — proves the wiring without audio.
class _FakePlayer implements TonePlayer {
  final List<String> played = [];
  Uint8List? lastWav;
  @override
  Future<void> play(String name, Uint8List wav) async {
    played.add(name);
    lastWav = wav;
  }
}
