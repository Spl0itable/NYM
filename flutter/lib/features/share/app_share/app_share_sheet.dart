import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_theme.dart' show kMonoFont;
import '../../../widgets/common/nym_sheet.dart';
import '../../i18n/i18n.dart';
import '../../identity/modal_chrome.dart';
import '../../../widgets/nym_icons.dart';
import '../../p2p/p2p_models.dart' show formatFileSize;
import '../branded_qr.dart';
import '../share_actions.dart';
import '../share_sheet.dart';
import 'app_share_logic.dart';

typedef AppFileSender = Future<void> Function(BuildContext context, String path);

Future<void> _sendApkFile(BuildContext context, String path) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile(path, mimeType: kApkMime)],
    sharePositionOrigin: shareOriginOf(context),
  ));
}

final appShareFileSenderProvider =
    Provider<AppFileSender>((ref) => _sendApkFile);

Future<void> openAppShare(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final platform = container.read(appSharePlatformProvider);
  ApkInfo? info;
  if (platform == 'android') {
    info = await container.read(appShareChannelProvider).apkInfo();
  }
  if (!context.mounted) return;
  final apk = info != null && info.mode == AppShareMode.apk;
  await ShareSheet.show(
    context,
    apk ? AppShareApkSheet(info: info) : AppShareQrSheet(platform: platform),
  );
}

Widget _frame(BuildContext context, NymColors c, List<Widget> content) {
  final body = Stack(
    children: [
      ModalChrome.box(
        c,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModalChrome.header(c, tr('Share Nymchat app')),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: content,
              ),
            ),
          ],
        ),
      ),
      ModalChrome.closeChip(c, () => Navigator.of(context).maybePop()),
    ],
  );
  return nymSheetOr(
    context,
    SingleChildScrollView(child: body),
    (body) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 820),
        child: SingleChildScrollView(child: body),
      ),
    ),
  );
}

class AppShareApkSheet extends ConsumerStatefulWidget {
  const AppShareApkSheet({super.key, required this.info});

  final ApkInfo info;

  @override
  ConsumerState<AppShareApkSheet> createState() => _AppShareApkSheetState();
}

class _AppShareApkSheetState extends ConsumerState<AppShareApkSheet> {
  bool _busy = false;

  Future<void> _send() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ch = ref.read(appShareChannelProvider);
    final sender = ref.read(appShareFileSenderProvider);
    try {
      final path = await ch.prepareCopy();
      if (path != null && mounted) await sender(context, path);
    } finally {
      await ch.clearCopies();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final i = widget.info;
    final fp = i.fingerprint;
    final dim = TextStyle(color: c.textDim, fontSize: 13, height: 1.4);
    return _frame(context, c, [
      Icon(Icons.android, size: 40, color: c.primary),
      const SizedBox(height: 12),
      Text(
        tr('Nymchat {version} ({build})',
            {'version': i.versionName, 'build': i.versionCode}),
        key: const ValueKey('app-share-version'),
        textAlign: TextAlign.center,
        style: TextStyle(
            color: c.text, fontSize: 17, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(formatFileSize(i.sizeBytes), textAlign: TextAlign.center, style: dim),
      if (fp != null) ...[
        const SizedBox(height: 16),
        Text(tr('Signing certificate SHA-256'),
            style: TextStyle(
                color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SelectableText(
          fp,
          key: const ValueKey('app-share-fingerprint'),
          style: TextStyle(
              color: c.text, fontSize: 12, height: 1.5, fontFamily: kMonoFont),
        ),
        const SizedBox(height: 6),
        Text(
            tr('Compare this fingerprint with the one Nymchat publishes before installing.'),
            style: dim),
      ],
      const SizedBox(height: 20),
      FilledButton(
        key: const ValueKey('app-share-send'),
        style: FilledButton.styleFrom(
            backgroundColor: c.primary, foregroundColor: c.bg),
        onPressed: _busy ? null : () => unawaited(_send()),
        child: Text(tr('Send app file')),
      ),
      const SizedBox(height: 20),
      Divider(height: 1, color: c.border),
      const SizedBox(height: 20),
      const AppLinkPicker(platform: 'android'),
    ]);
  }
}

class AppShareQrSheet extends StatelessWidget {
  const AppShareQrSheet({super.key, required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context) =>
      _frame(context, context.nym, [AppLinkPicker(platform: platform)]);
}

class AppLinkPicker extends StatefulWidget {
  const AppLinkPicker({super.key, required this.platform});

  final String platform;

  @override
  State<AppLinkPicker> createState() => _AppLinkPickerState();
}

class _AppLinkPickerState extends State<AppLinkPicker> {
  late final List<AppLinkChoice> _choices = appLinkChoices(widget.platform);
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final pick = _choices[_index];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFFFFFFFF),
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: BrandedQr(
              data: pick.url,
              semanticLabel:
                  tr('QR code for {title}', {'title': tr(pick.label)}),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          pick.url,
          key: const ValueKey('app-share-url'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, ch) in _choices.indexed)
              ChoiceChip(
                key: ValueKey('app-link-$i'),
                label: Text(tr(ch.label)),
                selected: i == _index,
                selectedColor: c.primary.withValues(alpha: 0.25),
                backgroundColor: c.bgSecondary,
                labelStyle: TextStyle(color: c.text),
                side: BorderSide(color: i == _index ? c.primary : c.border),
                showCheckmark: false,
                onSelected: (_) => setState(() => _index = i),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ShareActionRow(
          key: const ValueKey('app-share-link'),
          svg: NymIcons.shareNodes,
          label: tr('Share...'),
          onTap: () => unawaited(shareLinkWithSystem(context, pick.url)),
        ),
      ],
    );
  }
}
