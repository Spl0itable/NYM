import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/nym_icons.dart';
import '../dm_polls/dm_polls.dart';
import '../group_tools/group_tools.dart';
import '../i18n/i18n.dart';
import '../media_notes/media_notes.dart' as notes;
import '../messages/format/message_content.dart';
import '../messages/inline_network_image.dart';
import 'quick_react_popup.dart';

final RegExp _imageUrl = RegExp(
    r'(https?://[^\s#]+\.(?:png|jpe?g|gif|webp|avif)(?:\?[^\s#]*)?)(?:#\S*)?(?=\s|$)',
    caseSensitive: false);
final RegExp _videoUrl = RegExp(
    r'(https?://[^\s#]+\.(?:mp4|webm|mov|m4v)(?:\?[^\s#]*)?)(?:#\S*)?(?=\s|$)',
    caseSensitive: false);

({String text, String? thumb}) messageSheetPreview(
  String content, [
  String Function(String)? translate,
]) {
  String t(String s) => translate == null ? s : translate(s);
  var text = content;
  text = DmPolls.previewText(text);
  final loc = GroupTools.previewText(text);
  if (loc == 'Location' || loc == 'Live location') {
    return (text: t(loc), thumb: null);
  }
  text = loc;
  final unquoted = text
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('>'))
      .join('\n')
      .trim();
  if (unquoted.isNotEmpty) text = unquoted;
  text = notes.previewText(text, translate);
  final thumb = _imageUrl.firstMatch(text)?.group(1);
  text = text
      .replaceAll(_imageUrl, t('Photo'))
      .replaceAll(_videoUrl, t('Video'))
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .trim();
  return (text: text, thumb: thumb);
}

class MessageSheetPreview {
  const MessageSheetPreview({
    required this.pubkey,
    required this.nym,
    required this.suffix,
    required this.time,
    required this.content,
    this.avatarUrl,
  });

  final String pubkey;
  final String nym;
  final String suffix;
  final String time;
  final String content;
  final String? avatarUrl;
}

Future<void> showMessageActionSheet(
  BuildContext context, {
  required MessageSheetPreview preview,
  required List<String> emojis,
  required ValueChanged<String> onReact,
  VoidCallback? onMore,
  required List<QuickContextItem> items,
}) {
  return showNymBottomSheet<void>(
    context,
    (ctx) => MessageActionSheet(
      preview: preview,
      emojis: emojis,
      onReact: onReact,
      onMore: onMore,
      items: items,
    ),
  );
}

class MessageActionSheet extends StatelessWidget {
  const MessageActionSheet({
    super.key,
    required this.preview,
    required this.emojis,
    required this.onReact,
    required this.items,
    this.onMore,
  });

  final MessageSheetPreview preview;
  final List<String> emojis;
  final ValueChanged<String> onReact;
  final VoidCallback? onMore;
  final List<QuickContextItem> items;

  void _then(BuildContext context, VoidCallback run) {
    Navigator.of(context).pop();
    run();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final summary = messageSheetPreview(preview.content, tr);
    final more = onMore;
    return Semantics(
      container: true,
      label: tr('Message actions'),
      child: SingleChildScrollView(
        key: const ValueKey('messageActionSheet'),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Preview(preview: preview, text: summary.text, thumb: summary.thumb),
            const SizedBox(height: 10),
            MediaQuery.withNoTextScaling(
              child: Container(
              key: const ValueKey('messageSheetReactRow'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: c.insetFill,
                border: Border.all(color: c.insetBorder),
                borderRadius: const BorderRadius.all(Radius.circular(24)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final e in emojis)
                    Expanded(
                      child: _SheetEmoji(
                        emoji: e,
                        onTap: () => _then(context, () => onReact(e)),
                      ),
                    ),
                  if (more != null)
                    Expanded(
                      child: Semantics(
                      button: true,
                      label: tr('More reactions'),
                      child: InkResponse(
                        key: const ValueKey('messageSheetMoreReactions'),
                        onTap: () => _then(context, more),
                        radius: 22,
                        child: SizedBox(
                          height: 44,
                          child: Center(
                            child: Container(
                              width: 36,
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: c.hoverOverlay,
                              ),
                              child: NymSvgIcon(NymIcons.plus,
                                  size: 16, color: c.textDim),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ),
                ],
              ),
              ),
            ),
            const SizedBox(height: 8),
            for (final it in items)
              _SheetAction(
                key: it.id == null ? null : ValueKey('msg-action-${it.id}'),
                item: it,
                onTap: () => _then(context, it.onTap),
              ),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.preview, required this.text, this.thumb});

  final MessageSheetPreview preview;
  final String text;
  final String? thumb;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final url = thumb;
    return Container(
      key: const ValueKey('messageSheetPreview'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.insetFill,
        border: Border.all(color: c.insetBorder),
        borderRadius: NymRadius.rsm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NymAvatar(seed: preview.pubkey, size: 32, imageUrl: preview.avatarUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: preview.nym,
                            style: TextStyle(
                                color: c.secondary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13),
                          ),
                          if (preview.suffix.isNotEmpty)
                            TextSpan(
                              text: '#${preview.suffix}',
                              style: TextStyle(
                                  color: c.secondaryA(0.6), fontSize: 12),
                            ),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(preview.time,
                        style: TextStyle(color: c.textDim, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  key: const ValueKey('messageSheetPreviewText'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 13, height: 1.35),
                ),
              ],
            ),
          ),
          if (url != null) ...[
            const SizedBox(width: 10),
            ClipRRect(
              key: const ValueKey('messageSheetThumb'),
              borderRadius: NymRadius.rxs,
              child: InlineNetworkImage(
                url: proxiedMedia(url),
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorChild: const SizedBox(width: 44, height: 44),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SheetEmoji extends StatelessWidget {
  const _SheetEmoji({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      key: ValueKey('messageSheetEmoji-$emoji'),
      onTap: onTap,
      radius: 22,
      child: SizedBox(
        height: 44,
        child: Center(
          child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: InlineEmojiText(
          text: emoji,
          style: const TextStyle(fontSize: 26, height: 1),
          wholeStringOnly: true,
          emojiSize: 28,
          emojiMargin: EdgeInsets.zero,
          emojiAlignment: PlaceholderAlignment.middle,
        ),
      ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({super.key, required this.item, required this.onTap});

  final QuickContextItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final tone = quickItemTone(item.color);
    final fg = menuToneColor(tone, c);
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              NymSvgIcon(item.svg, size: 18, color: tone == MenuTone.normal ? c.textDim : fg),
              const SizedBox(width: 14),
              Expanded(
                child: Text(item.label,
                    style: TextStyle(
                        color: fg, fontSize: 15, fontWeight: FontWeight.w500)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
