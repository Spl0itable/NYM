import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/channel.dart';

/// The canonical web host for the PWA (`https://app.nymchat.app`). The PWA's
/// `shareChannel()` uses `window.location.origin + pathname`; in the native app
/// we mirror the production share host so links resolve to the web PWA.
// TODO(verify): the PWA builds the share URL from the runtime
// `window.location` (origin + pathname), not a hard-coded host. The task spec
// pins `https://app.nymchat.app/#<channel>`, so we use that constant here.
const String kNymchatShareHost = 'https://app.nymchat.app';

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
/// COPY button (channels.js `copyShareUrl`), the share hint, plus a QR code so
/// the link can be scanned on another device.
class ShareChannelModal extends StatefulWidget {
  const ShareChannelModal({super.key, required this.channelKey});

  /// The channel name / geohash to share.
  final String channelKey;

  static Future<void> open(BuildContext context, String channelKey) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
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
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rmd,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header row with title + close.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Share Channel',
                        style: TextStyle(
                          color: c.textBright,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: Icon(Icons.close, size: 18, color: c.textDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Channel URL',
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // `.share-url-container`: readonly input + COPY button.
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 11),
                            decoration: BoxDecoration(
                              color: c.glassBg,
                              border: Border.all(color: c.glassBorder),
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(8),
                                bottomLeft: Radius.circular(8),
                              ),
                            ),
                            child: Text(
                              url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.text, fontSize: 13),
                            ),
                          ),
                        ),
                        _CopyButton(
                          copied: _copied,
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: url));
                            if (!mounted) return;
                            setState(() => _copied = true);
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) setState(() => _copied = false);
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Share this URL to invite others to this channel',
                      style: TextStyle(color: c.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.copy-url-btn` — toggles to "COPIED!" for 2s after a copy.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.copied, required this.onTap});
  final bool copied;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      color: copied ? c.primaryA(0.18) : c.primaryA(0.10),
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(8),
        bottomRight: Radius.circular(8),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          alignment: Alignment.center,
          child: Text(
            copied ? 'COPIED!' : 'COPY',
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
    );
  }
}
