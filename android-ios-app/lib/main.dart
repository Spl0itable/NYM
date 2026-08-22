import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import 'app.dart';
import 'core/constants/storage_keys.dart';
import 'core/theme/nym_theme.dart';
import 'features/identity/vault_settings_modal.dart' show identityVaultProvider;
import 'features/identity/vault_boot_unlock.dart';
import 'services/platform/background_refresh.dart';
import 'services/storage/key_value_store.dart';
import 'state/app_state.dart';
import 'state/nostr_controller.dart';
import 'state/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The web-of-trust spam gate is safe to enable now that channel sends carry
  // the NIP-13 PoW floor (so Nymchat-client messages self-attest) and the trust
  // graph persists across launches. Enabled in the real app only — widget tests
  // leave it off by default.
  nymVouchSpamGateEnabled = true;

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
    if (details.stack != null) debugPrint(details.stack.toString());
  };

  // Catch otherwise-fatal async errors (e.g. WebSocket DNS failures when the
  // emulator/device is offline) so they don’t terminate the app.
  await runZonedGuarded(() async {
    // Open the key/value store (mirrors the PWA's synchronous localStorage).
    final kv = await KeyValueStore.open();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Manual container so we can boot the Nostr controller (identity + relays)
    // here in the real app only — widget tests construct their own ProviderScope
    // and never touch networking / secure storage.
    final container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
    );

    runApp(
      UncontrolledProviderScope(
        container: container,
        // The boot-unlock gate mirrors `DOMContentLoaded → await
        // nym.unlockVaultAtBoot() BEFORE initialize()`: when the vault is enabled
        // it blocks until the user unlocks (decrypting the stored secrets) and
        // only THEN boots the controller. When the vault is off it boots
        // immediately, behaving exactly as before.
        child: const _BootUnlockGate(),
      ),
    );
  }, (error, stack) {
    debugPrint('[Zone] Unhandled async error: $error');
    debugPrint(stack.toString());
  });
}

/// Top-level gate enforcing the PWA's boot ordering: identity-vault unlock runs
/// before `nostrControllerProvider.init()` reads any identity secret.
///
/// * Vault not enabled → boot the controller immediately and show the app.
/// * Vault enabled → show [VaultBootUnlock]; only on success (or "forget") do
///   we boot the controller and proceed.
class _BootUnlockGate extends ConsumerStatefulWidget {
  const _BootUnlockGate();

  @override
  ConsumerState<_BootUnlockGate> createState() => _BootUnlockGateState();
}

class _BootUnlockGateState extends ConsumerState<_BootUnlockGate> {
  late bool _unlocked;

  /// Claims the background-refresh channel while locked; `app.dart` re-claims
  /// it with its own handler once the app tree mounts.
  final _bgRefresh = BackgroundRefreshService();

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    final vaultEnabled = kv.getBool(StorageKeys.vaultEnabled);
    _unlocked = !vaultEnabled;
    if (_unlocked) {
      // No vault: boot the identity + relays now (was main()'s fire-and-forget).
      _bootController();
    } else {
      _armBackgroundWake();
    }
  }

  /// A locked process boots nothing — the app tree below this gate never
  /// mounts, so no relays, no catch-up, and (because `app.dart` is where the
  /// `runRefresh` handler is registered) nothing even answers the OS.
  ///
  /// That is fine while a person is looking at the unlock screen. It is not
  /// fine when iOS relaunched us in the BACKGROUND for a `BGAppRefresh`
  /// window: nobody is there to type a password, so the window is wasted and
  /// the user gets no notifications until they next open the app by hand.
  ///
  /// So the handler is claimed here too. A wake arriving while locked unlocks
  /// from the escrowed key ([IdentityVault.unlockForBackgroundWake]) and boots
  /// exactly as a real unlock would. The wake itself is the signal that this is
  /// a background launch — no native probe needed, and a foreground launch is
  /// untouched and still prompts.
  void _armBackgroundWake() {
    if (!BackgroundRefreshService.isSupported) return;
    _bgRefresh.start(() async {
      if (!_unlocked) {
        final secrets =
            await ref.read(identityVaultProvider).unlockForBackgroundWake();
        // No escrow (or a stale one): nothing can run. Returning ends the
        // window promptly, which is what keeps iOS granting more of them.
        if (secrets == null) return;
        if (!mounted) return;
        _onUnlocked(secrets);
        // Let the freshly-mounted app finish wiring up before the catch-up
        // runs against it.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await ref.read(nostrControllerProvider).runBackgroundCatchUp();
    });
  }

  void _bootController({Map<String, String>? unlockedSecrets}) {
    ref.read(nostrControllerProvider).init(unlockedSecrets: unlockedSecrets);
  }

  void _onUnlocked(Map<String, String> secrets) {
    if (!mounted) return;
    // Decrypted secrets are held in memory (the native analogue of `_vaultMem`)
    // and handed to identity restore — never re-plaintexted at rest.
    _bootController(unlockedSecrets: secrets);
    setState(() => _unlocked = true);
  }

  void _onForget() {
    if (!mounted) return;
    // Vault + secrets discarded; boot proceeds to a clean ephemeral identity.
    _bootController();
    setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return const NymchatApp();
    // The unlock screen needs the theme too; wrap it in a minimal MaterialApp
    // so it matches the app's appearance (the PWA applies the saved color mode
    // before showing the unlock modal). Reuses the same colour provider the
    // full app does so the look is identical.
    final colors = ref.watch(nymColorsProvider);
    return MaterialApp(
      title: 'Nymchat',
      debugShowCheckedModeBanner: false,
      theme: buildNymThemeData(colors),
      home: VaultBootUnlock(
        onUnlocked: _onUnlocked,
        onForget: _onForget,
      ),
    );
  }
}
