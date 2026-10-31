import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../widgets/nym_icons.dart';
import 'branded_qr.dart';
import 'qr_decoder_channel.dart';
import 'share_origin.dart';
import 'share_scanner.dart';
import 'app_share/app_share_entry.dart';
import 'nearby/nearby_share_entry.dart';
import 'nfc/nfc_share_entry.dart';
import 'share_target.dart';

export 'share_origin.dart';

const int kShareOrderSystem = 10;
const int kShareOrderNearby = 20;
const int kShareOrderTap = 30;
const int kShareOrderSticker = 40;
const int kShareOrderSave = 50;
const int kShareOrderScan = 60;
const int kShareOrderApp = 70;

typedef ShareAvailability = bool Function(WidgetRef ref, ShareTarget target);
typedef ShareRun = Future<void> Function(
    BuildContext context, WidgetRef ref, ShareTarget target);

class ShareAction {
  const ShareAction({
    required this.id,
    required this.order,
    required this.label,
    required this.icon,
    required this.isAvailable,
    required this.run,
  });

  final String id;
  final int order;
  final String label;
  final String icon;
  final ShareAvailability isAvailable;
  final ShareRun run;
}

Future<void> shareLinkWithSystem(BuildContext context, String link) async {
  await SharePlus.instance.share(
      ShareParams(text: link, sharePositionOrigin: shareOriginOf(context)));
}

final List<ShareAction> kCoreShareActions = [
  ShareAction(
    id: 'share',
    order: kShareOrderSystem,
    label: 'Share...',
    icon: NymIcons.shareNodes,
    isAvailable: (ref, t) => t.hasCode,
    run: (context, ref, t) => shareLinkWithSystem(context, t.link),
  ),
  ShareAction(
    id: 'save',
    order: kShareOrderSave,
    label: 'Save QR image',
    icon: NymIcons.composerImage,
    isAvailable: (ref, t) => t.hasCode,
    run: saveQrImage,
  ),
  ShareAction(
    id: 'scan',
    order: kShareOrderScan,
    label: 'Scan a code',
    icon: NymIcons.qrScan,
    isAvailable: (ref, t) => ref.watch(qrScannerAvailableProvider),
    run: (context, ref, t) => openShareScanner(context),
  ),
];

Future<void> saveQrImage(
    BuildContext context, WidgetRef ref, ShareTarget t) async {
  final png = await brandedQrPng(t.codeLink);
  if (png == null || !context.mounted) return;
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(png, mimeType: 'image/png')],
    fileNameOverrides: const ['nymchat-qr.png'],
    sharePositionOrigin: shareOriginOf(context),
  ));
}

final extraCoreShareActionsProvider =
    Provider<List<ShareAction>>((ref) => const []);

final shareActionsProvider = Provider<List<ShareAction>>((ref) {
  final all = <ShareAction>[
    ...kCoreShareActions,
    ...ref.watch(extraCoreShareActionsProvider),
    ...nearbyShareActions(ref),
    ...nfcShareActions(ref),
  ];
  all.sort((a, b) => a.order.compareTo(b.order));
  return List.unmodifiable(all);
});

final nfcReadLauncherProvider =
    Provider<Future<void> Function(BuildContext)?>(nfcReadLauncher);

final appShareLauncherProvider =
    Provider<Future<void> Function(BuildContext)?>(appShareLauncher);
