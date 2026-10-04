import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'app.dart';
import 'core/constants/storage_keys.dart';
import 'core/theme/nym_theme.dart';
import 'features/accounts/account_host.dart';
import 'features/accounts/account_runtime.dart';
import 'features/accounts/inactive_probe.dart';
import 'features/identity/vault_settings_modal.dart' show identityVaultProvider;
import 'features/identity/vault_boot_unlock.dart';
import 'services/platform/background_refresh.dart';
import 'services/storage/secure_store.dart';
import 'state/nostr_controller.dart';
import 'state/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
    if (details.stack != null) debugPrint(details.stack.toString());
  };

  // Catch otherwise-fatal async errors (e.g. offline WebSocket DNS failures) so they don't kill the app.
  await runZonedGuarded(() async {
    final prefs = await SharedPreferences.getInstance();
    await SecureStore.settleInstall(prefs);
    final runtime = AccountRuntime(prefs: prefs);
    await runtime.boot();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    runApp(
      AccountHost(
        session: AccountSession(
          runtime: runtime,
          probe: InactiveProbe(prefs: prefs),
        ),
        builder: () => const _BootUnlockGate(),
      ),
    );
  }, (error, stack) {
    debugPrint('[Zone] Unhandled async error: $error');
    debugPrint(stack.toString());
  });
}

/// Runs identity-vault unlock before `nostrControllerProvider.init()` reads any secret.
class _BootUnlockGate extends ConsumerStatefulWidget {
  const _BootUnlockGate();

  @override
  ConsumerState<_BootUnlockGate> createState() => _BootUnlockGateState();
}

class _BootUnlockGateState extends ConsumerState<_BootUnlockGate> {
  late bool _unlocked;
  bool _wakeUnlocked = false;
  final GlobalKey _appKey = GlobalKey();

  /// Claims the background-refresh channel while locked; `app.dart` re-claims it once mounted.
  final _bgRefresh = BackgroundRefreshService();

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    final vaultEnabled = kv.getBool(StorageKeys.vaultEnabled);
    _unlocked = !vaultEnabled;
    if (_unlocked) {
      _bootController();
    }
    _armBackgroundWake();
  }

  /// A background iOS refresh while locked unlocks from the escrowed key, since nobody can type a password.
  void _armBackgroundWake() {
    if (!BackgroundRefreshService.isSupported) return;
    _bgRefresh.start(() async {
      if (!_unlocked) {
        final secrets =
            await ref.read(identityVaultProvider).unlockForBackgroundWake();
        // No usable escrow; returning ends the window promptly so iOS keeps granting them.
        if (secrets == null) return false;
        if (!mounted) return false;
        _wakeUnlocked = true;
        _onUnlocked(secrets);
        // Let the freshly mounted app finish wiring before the catch-up runs.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return ref.read(nostrControllerProvider).runBackgroundCatchUp();
    });
  }

  void _bootController({Map<String, String>? unlockedSecrets}) {
    ref.read(nostrControllerProvider).init(unlockedSecrets: unlockedSecrets);
  }

  void _onUnlocked(Map<String, String> secrets) {
    if (!mounted) return;
    // Decrypted secrets stay in memory and are never re-plaintexted at rest.
    _bootController(unlockedSecrets: secrets);
    setState(() => _unlocked = true);
  }

  void _onForget() {
    if (!mounted) return;
    // Vault and secrets discarded; boot a clean ephemeral identity.
    _bootController();
    setState(() => _unlocked = true);
  }

  Future<void> _onWakeForget() async {
    try {
      await ref.read(nostrControllerProvider).signOut();
    } finally {
      if (mounted) setState(() => _wakeUnlocked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) {
      final app = KeyedSubtree(key: _appKey, child: const NymchatApp());
      if (!_wakeUnlocked) return app;
      return VaultLockedApp(app: app, lock: _unlockScreen(resumed: true));
    }
    return _unlockScreen();
  }

  Widget _unlockScreen({bool resumed = false}) {
    // Minimal themed MaterialApp so the unlock screen matches the app's saved appearance.
    final colors = ref.watch(nymColorsProvider);
    return MaterialApp(
      title: 'Nymchat',
      debugShowCheckedModeBanner: false,
      theme: buildNymThemeData(colors),
      home: VaultBootUnlock(
        onUnlocked: resumed
            ? (_) => setState(() => _wakeUnlocked = false)
            : _onUnlocked,
        onForget: resumed ? () => unawaited(_onWakeForget()) : _onForget,
      ),
    );
  }
}
