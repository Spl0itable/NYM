import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/platform/background_refresh.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../accounts/account_host.dart';
import '../i18n/localization_service.dart';
import '../identity/vault_settings_modal.dart' show identityVaultProvider;
import 'background_catch_up.dart';

class BackgroundWake {
  const BackgroundWake._();

  static Future<bool> run({
    required KeyValueStore kv,
    required Future<Map<String, String>?> Function() unlock,
    required void Function(Map<String, String>? secrets) boot,
    required Future<bool> Function() catchUp,
    Future<void> Function()? probes,
  }) async {
    if (!hasChosenIdentity(kv)) return false;
    Map<String, String>? secrets;
    if (kv.getBool(StorageKeys.vaultEnabled)) {
      secrets = await unlock();
      if (secrets == null) return false;
    }
    boot(secrets);
    final caught = await catchUp();
    if (probes != null) {
      try {
        await probes();
      } catch (_) {}
    }
    return caught;
  }

  static Future<bool> runIn(ProviderContainer container) {
    final kv = container.read(keyValueStoreProvider);
    return run(
      kv: kv,
      unlock: () =>
          container.read(identityVaultProvider).unlockForBackgroundWake(),
      boot: (secrets) {
        try {
          LocalizationService.instance.configure(
            kv: kv,
            language: container.read(settingsProvider).uiLanguage,
          );
        } catch (_) {}
        unawaited(container
            .read(nostrControllerProvider)
            .init(unlockedSecrets: secrets));
      },
      catchUp: () => container.read(nostrControllerProvider).runBackgroundCatchUp(),
      probes: container.read(accountsProvider)?.runInactiveProbes,
    );
  }
}

Duration wakeBudget(Duration elapsed) {
  final left = BackgroundRefreshService.runBudget - elapsed;
  return left.isNegative ? Duration.zero : left;
}

Future<void> serveBackgroundWake(
  BackgroundRefreshService service,
  Future<bool> Function() wake, {
  Duration elapsed = Duration.zero,
}) async {
  service.start(wake, budget: wakeBudget(elapsed));
  await service.ready();
}
