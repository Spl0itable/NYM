import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/keys.dart';
import '../../../core/theme/nym_colors.dart';
import '../../../state/nostr_controller.dart';
import '../../../state/settings_provider.dart';
import '../../../widgets/common/brand_buttons.dart';
import '../../i18n/i18n.dart';
import '../../settings/settings_widgets.dart';
import 'key_backup_crypto.dart';
import 'key_backup_store.dart';
import 'key_backup_ui.dart';
import 'passkey_backup_service.dart';

bool hasLocalBackupKey(WidgetRef ref) {
  final identity = ref.read(nostrControllerProvider).identity;
  if (identity?.privkey == null) return false;
  final method = identity?.loginMethod;
  if (method == 'nsec') return true;
  return method == null &&
      ref.read(settingsProvider.notifier).keypairMode == 'persistent';
}

PasskeyBackupService? watchPasskeyBackup(WidgetRef ref) =>
    ref.watch(passkeyBackupAvailableProvider).valueOrNull == true
        ? ref.watch(passkeyBackupServiceProvider)
        : null;

bool canShowKeyBackup(WidgetRef ref) =>
    (ref.watch(keyBackupStoresProvider).isNotEmpty ||
        watchPasskeyBackup(ref) != null) &&
    hasLocalBackupKey(ref);

String keyBackupHint({required bool passkeyOnly}) => passkeyOnly
    ? tr('Back up your key with a passkey so you can restore it on '
        'another device. Your key stays yours: the backup is encrypted, '
        'and only your passkey can unlock it.')
    : tr('Back up your key, encrypted with a PIN, to your own cloud '
        'account so you can restore it on another device. Your key stays '
        "yours: Google and Apple only store an encrypted copy that they "
        "can't read without your PIN.");

class KeyBackupActions extends ConsumerWidget {
  const KeyBackupActions({super.key});

  ({String secretHex, String pubkeyHex, String? pqCode})? _material(
      WidgetRef ref) {
    final ctrl = ref.read(nostrControllerProvider);
    final identity = ctrl.identity;
    final sk = identity?.privkey;
    if (identity == null || sk == null) return null;
    return (
      secretHex: bytesToHex(sk),
      pubkeyHex: identity.pubkey,
      pqCode: ctrl.pqRootCode,
    );
  }

  Future<void> _backUp(
      BuildContext context, WidgetRef ref, KeyBackupStore store) async {
    final m = _material(ref);
    if (m == null) return;
    await runKeyBackupCreate(context, ref, store,
        secretHex: m.secretHex, pubkeyHex: m.pubkeyHex, pqCode: m.pqCode);
  }

  Future<void> _backUpWithPasskey(
      BuildContext context, WidgetRef ref, PasskeyBackupService service) async {
    final m = _material(ref);
    if (m == null) return;
    await runPasskeyBackup(context, service,
        secretHex: m.secretHex, pubkeyHex: m.pubkeyHex, pqCode: m.pqCode);
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, KeyBackupStore store) async {
    final identity = ref.read(nostrControllerProvider).identity;
    if (identity == null) return;
    await runKeyBackupRemove(context, ref, store, pubkeyHex: identity.pubkey);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canShowKeyBackup(ref)) return const SizedBox.shrink();
    final stores = ref.watch(keyBackupStoresProvider);
    final passkey = watchPasskeyBackup(ref);
    final c = context.nym;
    return Column(
      key: const Key('keyBackupActions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Cloud Key Backup'),
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          '${keyBackupHint(passkeyOnly: stores.isEmpty)} '
          '${tr('The backup also holds your post-quantum recovery code when '
              'this device has it.')}',
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
        for (final store in stores) ...[
          const SizedBox(height: 8),
          KeyedSubtree(
            key: Key('keyBackupBackUp_${store.cloud.name}'),
            child: switch (store.cloud) {
              BackupCloud.apple =>
                AppleButton(onPressed: () => _backUp(context, ref, store)),
              BackupCloud.google =>
                GoogleButton(onPressed: () => _backUp(context, ref, store)),
            },
          ),
        ],
        if (stores.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final store in stores)
                NymOutlineButton(
                  key: Key('keyBackupRemove_${store.cloud.name}'),
                  label: keyBackupRemoveLabel(store.cloud),
                  danger: true,
                  onPressed: () => _remove(context, ref, store),
                ),
            ],
          ),
        ],
        if (passkey != null) ...[
          SizedBox(height: stores.isEmpty ? 8 : brandPasskeyGap),
          KeyedSubtree(
            key: const Key('keyBackupBackUp_passkey'),
            child: PasskeyButton(
              label: tr('Back up with a passkey'),
              onPressed: () => _backUpWithPasskey(context, ref, passkey),
            ),
          ),
        ],
      ],
    );
  }
}
