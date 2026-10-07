import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/identity/modal_chrome.dart';
import '../../models/channel.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import '../../widgets/common/nym_sheet.dart';

/// Canonical PWA host for shared links; `app.nymchat.app` does not exist.
const String kNymchatShareHost = 'https://web.nymchat.app';

/// Share URL for a channel name or geohash as a `#<channel>` fragment; empty falls back to `nymchat`.
String buildChannelShareUrl(String channel, {String host = kNymchatShareHost}) {
  final ch = channel.isEmpty ? kDefaultChannel : channel;
  return '$host/#$ch';
}

String channelEntryShareUrl(ChannelEntry entry,
        {String host = kNymchatShareHost}) =>
    buildChannelShareUrl(entry.key, host: host);

/// "Share Channel" modal: readonly URL field with a COPY button and a hint; no QR code.
class ShareChannelModal extends StatefulWidget {
  const ShareChannelModal({super.key, required this.channelKey});

  /// The channel name or geohash to share.
  final String channelKey;

  static Future<void> open(BuildContext context, String channelKey) {
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return showNymSheet<void>(
      context,
      (_) => ShareChannelModal(channelKey: channelKey),
      barrierColor: !solidUi
          ? Colors.black.withValues(alpha: 0.7)
          : isLight
              ? const Color(0x73000000)
              : const Color(0xBF000000),
    );
  }

  @override
  State<ShareChannelModal> createState() => _ShareChannelModalState();
}

class _ShareChannelModalState extends State<ShareChannelModal> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final url = buildChannelShareUrl(widget.channelKey);

    final body = Stack(
      children: [
        ModalChrome.box(
          c,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ModalChrome.header(c, tr('Share Channel')),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ModalChrome.formLabel(c, tr('Channel URL')),
                    const SizedBox(height: 20),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: c.isLight
                                    ? const Color(0x0A000000)
                                    : const Color(0x0DFFFFFF),
                                border: Border.all(
                                    color: c.isLight
                                        ? const Color(0x1A000000)
                                        : c.glassBorder),
                                borderRadius: NymRadius.rsm,
                              ),
                              child: Text(
                                url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.isLight
                                      ? const Color(0xFF000000)
                                      : const Color(0xFFFFFFFF),
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _CopyButton(
                            copied: _copied,
                            onTap: () async {
                              await Clipboard.setData(
                                  ClipboardData(text: url));
                              if (!mounted) return;
                              setState(() => _copied = true);
                              Future.delayed(const Duration(seconds: 2),
                                  () {
                                if (mounted) {
                                  setState(() => _copied = false);
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      tr('Share this URL to invite others to this channel'),
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ModalChrome.iconButton(c, tr('Close'),
                            () => Navigator.of(context).maybePop()),
                      ],
                    ),
                  ],
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
          constraints: const BoxConstraints(maxWidth: 500),
          child: body,
        ),
      ),
    );
  }
}

/// Copy button that shows "COPIED!" for 2s after a copy.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.copied, required this.onTap});
  final bool copied;
  final VoidCallback onTap;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final copied = widget.copied;
    final fill = copied
        ? c.primaryA(0.2)
        : (_hover ? c.primaryA(0.18) : c.primaryA(0.1));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: NymRadius.rsm,
            border:
                Border.all(color: copied ? c.primaryA(0.5) : c.primaryA(0.3)),
            boxShadow: _hover && !copied
                ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 15)]
                : null,
          ),
          child: Text(
            copied ? tr('COPIED!') : tr('COPY'),
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }
}
