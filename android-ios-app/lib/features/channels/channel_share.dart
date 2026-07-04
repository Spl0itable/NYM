import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/identity/modal_chrome.dart';
import '../../models/channel.dart';
import '../../state/settings_provider.dart';

/// The canonical web host for the PWA (`https://web.nymchat.app`). The PWA's
/// `shareChannel()` uses `window.location.origin + pathname` (channels.js:413),
/// which in production resolves to `web.nymchat.app` — the only OFFICIAL_HOST
/// (`build-verify.js:10`). The native app mirrors that production host so shared
/// links open the live web PWA. (`app.nymchat.app` does not exist.)
const String kNymchatShareHost = 'https://web.nymchat.app';

/// Builds the share URL for a channel (`shareChannel`, channels.js): the base
/// host with a `#<channel>` fragment. [channel] is the channel name (or geohash
/// for a geohash channel) — i.e. the same value the PWA stores in
/// `currentChannel`. Falls back to `nymchat` for an empty value.
String buildChannelShareUrl(String channel, {String host = kNymchatShareHost}) {
  final ch = channel.isEmpty ? kDefaultChannel : channel;
  return '$host/#$ch';
}

/// Convenience: the share URL for a [ChannelEntry] (uses its key — geohash or
/// name).
String channelEntryShareUrl(ChannelEntry entry,
        {String host = kNymchatShareHost}) =>
    buildChannelShareUrl(entry.key, host: host);

/// `#shareModal` — "Share Channel": the channel URL in a readonly field with a
/// COPY button (channels.js `copyShareUrl`) and the share hint. Mirrors the PWA
/// `#shareModal` (index.html:2097-2114) exactly — it has no QR code.
class ShareChannelModal extends StatefulWidget {
  const ShareChannelModal({super.key, required this.channelKey});

  /// The channel name / geohash to share.
  final String channelKey;

  static Future<void> open(BuildContext context, String channelKey) {
    // `.modal` barrier: glass `rgba(0,0,0,0.7)` (styles-chat.css:1974);
    // `body.solid-ui .modal { rgba(0,0,0,0.75) }` and
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1636).
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: !solidUi
          ? Colors.black.withValues(alpha: 0.7)
          : isLight
              ? const Color(0x73000000) // black @ 0.45
              : const Color(0xBF000000), // black @ 0.75
      builder: (_) => ShareChannelModal(channelKey: channelKey),
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

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        // `.share-modal { max-width: 500px }`.
        constraints: const BoxConstraints(maxWidth: 500),
        child: Stack(
          children: [
            // `.modal-content` card with the shared chrome: a title-only
            // `.modal-header` (22px UPPERCASE primary ls1.5 + bottom rule) over
            // the body. The close ✕ is a separate, absolutely-positioned glass
            // chip (added below), not an inline Row child.
            ModalChrome.box(
              c,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ModalChrome.header(c, 'Share Channel'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // `.form-label` — 11px UPPERCASE ls1.2 w600 textDim.
                        ModalChrome.formLabel(c, 'Channel URL'),
                        // `.share-url-container` margin: 20px 0 (its 20px top
                        // margin collapses over the label's 8px bottom margin).
                        const SizedBox(height: 20),
                        // `.share-url-container`: flex, gap 10, align stretch —
                        // readonly input + a separate bordered COPY button.
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // `.share-url-input`: white/0.05 fill (light:
                              // black/0.04 + black/0.1 border), 1px glass
                              // border, radius-sm 12, padding 10 14, 13px
                              // font-mono, forced #fff/#000 text (the global
                              // `input { color }` !important overrides).
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
                        // Container margin-bottom 20 (collapses over the
                        // hint's 5px top margin).
                        const SizedBox(height: 20),
                        // `.form-hint`: 11px textDim.
                        Text(
                          'Share this URL to invite others to this channel',
                          style: TextStyle(color: c.textDim, fontSize: 11),
                        ),
                        // `.form-group` / `.modal-body` margin-bottom 20.
                        const SizedBox(height: 20),
                        // `.modal-actions`: centered row with a Close
                        // `.icon-btn` (index.html:2106).
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ModalChrome.iconButton(c, 'Close',
                                () => Navigator.of(context).maybePop()),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // `.modal-close`: the 32×32 glass ✕ chip at top-right (14,14).
            ModalChrome.closeChip(c, () => Navigator.of(context).maybePop()),
          ],
        ),
      ),
    );
  }
}

/// `.copy-url-btn` — primary/0.1 fill, 1px primary/0.3 border, radius-sm 12,
/// padding 10 20, 12px w500 UPPERCASE ls1px primary text. Hover brightens the
/// fill to 0.18 (+ 0 0 15px primary/0.1 glow); the 2s `.copied` state uses
/// fill 0.2 / border 0.5 while the label reads "COPIED!" (copyShareUrl,
/// channels.js:429-446).
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
            border: Border.all(
                color: copied ? c.primaryA(0.5) : c.primaryA(0.3)),
            boxShadow: _hover && !copied
                ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 15)]
                : null,
          ),
          child: Text(
            copied ? 'COPIED!' : 'COPY',
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
