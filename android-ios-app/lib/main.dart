import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/constants/storage_keys.dart';
import 'core/theme/nym_theme.dart';
import 'features/identity/vault_boot_unlock.dart';
import 'services/storage/key_value_store.dart';
import 'state/nostr_controller.dart';
import 'state/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    final vaultEnabled = kv.getBool(StorageKeys.vaultEnabled);
    _unlocked = !vaultEnabled;
    if (_unlocked) {
      // No vault: boot the identity + relays now (was main()'s fire-and-forget).
      _bootController();
    }
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
