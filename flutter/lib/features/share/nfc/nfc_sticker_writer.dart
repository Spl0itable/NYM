import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common/app_dialog.dart';
import '../../i18n/i18n.dart';
import '../share_target.dart';
import 'ndef.dart';
import 'nfc_channel.dart';
import 'nfc_read.dart';

String stickerWarningText(ShareTarget t) => [
      tr('Anyone who taps or scans this sticker can read the link.'),
      if (t.kind == ShareKind.group)
        tr('Anyone who sees or scans this code can ask to join and will see the group’s name.'),
    ].join('\n\n');

String? stickerWriteMessage(NfcWriteResult r) => switch (r.status) {
      NfcWriteStatus.ok => tr('Sticker written'),
      NfcWriteStatus.cancelled => null,
      NfcWriteStatus.tooSmall => tr(
          'This sticker is too small for this link ({need} bytes, {have} available).',
          {'need': r.need, 'have': r.have}),
      NfcWriteStatus.readOnly =>
        tr('This sticker is locked and cannot be changed.'),
      NfcWriteStatus.notNdef => tr('This tag cannot hold a Nymchat link.'),
      _ => tr('Could not write to the sticker. Try again.'),
    };

String? stickerLockMessage(NfcWriteResult r) => switch (r.status) {
      NfcWriteStatus.ok => tr('Sticker locked'),
      NfcWriteStatus.cancelled => null,
      NfcWriteStatus.mismatch =>
        tr('This is not the sticker you just wrote.'),
      NfcWriteStatus.readOnly =>
        tr('This sticker is locked and cannot be changed.'),
      _ => tr('Could not lock the sticker.'),
    };

Future<void> writeShareSticker(
    BuildContext context, WidgetRef ref, ShareTarget t) async {
  if (!t.hasCode) return;
  final nfc = ref.read(nfcPlatformProvider);
  final title = tr('Write to NFC sticker');
  final go = await showAppConfirm(context, stickerWarningText(t),
      title: title, okLabel: tr('Continue'));
  if (!go || !context.mounted) return;
  final caps = await readyNfcCaps(context, nfc, title);
  if (caps == null || !caps.write || !context.mounted) return;
  final link = t.codeLink;
  final message = ndefUriMessage(link);
  final payload = ndefUriRecordPayload(link);
  final r = await runNfcSession(
      context,
      nfc,
      caps,
      () => nfc.write(
          message: message,
          payload: payload,
          uri: link,
          alert: nfcHoldText(),
          done: tr('Sticker written'),
          timeout: kNfcSessionTimeout));
  if (!context.mounted) return;
  final text = stickerWriteMessage(r);
  if (text == null) return;
  if (r.status != NfcWriteStatus.ok) {
    await showAppAlert(context, text, title: title, okLabel: tr('Close'));
    return;
  }
  final wantLock = await showAppConfirm(context, text,
      title: title, okLabel: tr('Lock sticker'), cancelLabel: tr('Done'));
  if (!wantLock || !context.mounted) return;
  final sure = await showAppConfirm(
    context,
    tr('Lock this sticker so it can never be changed? This cannot be undone.'),
    title: title,
    okLabel: tr('Lock sticker'),
    danger: true,
  );
  if (!sure || !context.mounted) return;
  final l = await runNfcSession(
      context,
      nfc,
      caps,
      () => nfc.lock(
          message: message,
          payload: payload,
          alert: nfcHoldText(),
          done: tr('Sticker locked'),
          timeout: kNfcSessionTimeout));
  if (!context.mounted) return;
  final lockText = stickerLockMessage(l);
  if (lockText == null) return;
  await showAppAlert(context, lockText, title: title, okLabel: tr('Close'));
}
