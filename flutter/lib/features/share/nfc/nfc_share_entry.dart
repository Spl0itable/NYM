import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/nym_icons.dart';
import '../share_actions.dart';
import 'nfc_channel.dart';
import 'nfc_read.dart';
import 'nfc_sticker_writer.dart';
import 'tap_to_share_screen.dart';

final ShareAction kTapToShareAction = ShareAction(
  id: 'tap',
  order: kShareOrderTap,
  label: 'Tap to share',
  icon: NymIcons.phone,
  isAvailable: (ref, t) => t.hasCode,
  run: openTapToShare,
);

final ShareAction kStickerShareAction = ShareAction(
  id: 'sticker',
  order: kShareOrderSticker,
  label: 'Write to NFC sticker',
  icon: NymIcons.upload,
  isAvailable: (ref, t) => t.hasCode,
  run: writeShareSticker,
);

List<ShareAction> nfcShareActions(Ref ref) {
  final caps = ref.watch(nfcCapsProvider).valueOrNull ?? NfcCaps.none;
  return [
    if (caps.hce) kTapToShareAction,
    if (caps.write) kStickerShareAction,
  ];
}

Future<void> Function(BuildContext)? nfcReadLauncher(Ref ref) {
  final caps = ref.watch(nfcCapsProvider).valueOrNull ?? NfcCaps.none;
  return caps.read ? readNfcShare : null;
}
