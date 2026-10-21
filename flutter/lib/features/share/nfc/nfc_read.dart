import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../widgets/common/app_dialog.dart';
import '../../i18n/i18n.dart';
import '../share_inbound.dart';
import 'ndef.dart';
import 'nfc_channel.dart';

String nfcHoldText() => tr('Hold your phone near the NFC tag.');

Future<NfcCaps?> readyNfcCaps(
    BuildContext context, NfcPlatform nfc, String title) async {
  final caps = await nfc.caps();
  if (!context.mounted) return null;
  if (caps.enabled) return caps;
  if (caps.nfc && !caps.systemUi) {
    final go = await showAppConfirm(
      context,
      tr('NFC is turned off on this phone.'),
      title: title,
      okLabel: tr('Turn on NFC'),
    );
    if (go) await nfc.openSettings();
  }
  return null;
}

Future<T> runNfcSession<T>(BuildContext context, NfcPlatform nfc,
    NfcCaps caps, Future<T> Function() op) async {
  if (caps.systemUi) return op();
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => NfcWaitDialog(onCancel: () => unawaited(nfc.cancel())),
  ).then((_) => open = false));
  try {
    return await op();
  } finally {
    if (open) nav.pop();
  }
}

class NfcWaitDialog extends StatelessWidget {
  const NfcWaitDialog({super.key, required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onCancel();
      },
      child: AlertDialog(
        key: const ValueKey('nfc-wait'),
        backgroundColor: c.bgSecondary,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.nfc, size: 44, color: c.primary),
            const SizedBox(height: 12),
            Text(nfcHoldText(),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.text, fontSize: 15, height: 1.4)),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('nfc-wait-cancel'),
            onPressed: onCancel,
            child: Text(tr('Cancel'), style: TextStyle(color: c.text)),
          ),
        ],
      ),
    );
  }
}

Future<void> readNfcShare(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final nfc = container.read(nfcPlatformProvider);
  final caps = await readyNfcCaps(context, nfc, tr('Read NFC'));
  if (caps == null || !caps.read || !context.mounted) return;
  final raw = await runNfcSession(context, nfc, caps,
      () => nfc.read(alert: nfcHoldText(), timeout: kNfcSessionTimeout));
  if (raw == null || !context.mounted) return;
  final uri = firstNdefUri(ndefRecordsFromChannel(raw)) ?? '';
  await container
      .read(inboundShareProvider)
      .handle(context, uri, source: InboundSource.nfc);
}
