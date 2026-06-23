// The composer autocomplete dropdown (`.autocomplete-dropdown` /
// `#emojiAutocomplete` / `#channelAutocomplete` / `#kaomojiAutocomplete`). One
// widget renders whichever of the four query types is active, anchored above
// the input. Selection + keyboard nav are owned by the parent (the composer),
// which holds the selected index and splices the chosen token into the field.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../emoji/custom_emoji.dart';
import '../../models/user.dart';
import 'autocomplete_queries.dart';

/// Which dropdown content to render + its flat selectable items.
class AutocompleteView {
  const AutocompleteView.mentions(this.mentions)
      : kind = AutocompleteKind.mention,
        channels = const [],
        emoji = const [],
        kaomojiSections = const [];
  const AutocompleteView.channels(this.channels)
      : kind = AutocompleteKind.channel,
        mentions = const [],
        emoji = const [],
        kaomojiSections = const [];
  const AutocompleteView.emoji(this.emoji)
      : kind = AutocompleteKind.emoji,
        mentions = const [],
        channels = const [],
        kaomojiSections = const [];
  const AutocompleteView.kaomoji(this.kaomojiSections)
      : kind = AutocompleteKind.kaomoji,
        mentions = const [],
        channels = const [],
        emoji = const [];

  final AutocompleteKind kind;
  final List<MentionResult> mentions;
  final List<ChannelResult> channels;
  final List<EmojiResult> emoji;
  final List<KaomojiSection> kaomojiSections;

  /// Flat list of the selectable kaomoji strings (headers are not selectable).
  List<String> get kaomojiItems =>
      [for (final s in kaomojiSections) ...s.items];

  /// Number of navigable items.
  int get itemCount {
    switch (kind) {
      case AutocompleteKind.mention:
        return mentions.length;
      case AutocompleteKind.channel:
        return channels.length;
      case AutocompleteKind.emoji:
        return emoji.length;
      case AutocompleteKind.kaomoji:
        return kaomojiItems.length;
    }
  }

  bool get isEmpty => itemCount == 0;
}

enum AutocompleteKind { mention, channel, emoji, kaomoji }

class AutocompleteDropdown extends StatelessWidget {
  const AutocompleteDropdown({
    super.key,
    required this.view,
    required this.selectedIndex,
    required this.onSelectMention,
    required this.onSelectChannel,
    required this.onSelectEmoji,
    required this.onSelectKaomoji,
    this.custom = CustomEmojiState.empty,
  });

  final AutocompleteView view;
  final int selectedIndex;
  final void Function(MentionResult) onSelectMention;
  final void Function(ChannelResult) onSelectChannel;
  final void Function(EmojiResult) onSelectEmoji;
  final void Function(String kaomoji) onSelectKaomoji;
  final CustomEmojiState custom;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        // `.autocomplete-dropdown`: bg-tertiary, glass border, top-rounded.
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _rows(c),
        ),
      ),
    );
  }

  List<Widget> _rows(NymColors c) {
    switch (view.kind) {
      case AutocompleteKind.mention:
        return [
          for (var i = 0; i < view.mentions.length; i++)
            _mentionRow(c, view.mentions[i], i == selectedIndex),
        ];
      case AutocompleteKind.channel:
        return [
          for (var i = 0; i < view.channels.length; i++)
            _channelRow(c, view.channels[i], i == selectedIndex),
        ];
      case AutocompleteKind.emoji:
        return [
          for (var i = 0; i < view.emoji.length; i++)
            _emojiRow(c, view.emoji[i], i == selectedIndex),
        ];
      case AutocompleteKind.kaomoji:
        var idx = -1;
        final widgets = <Widget>[];
        for (final section in view.kaomojiSections) {
          widgets.add(_header(c, section.label));
          for (final k in section.items) {
            idx++;
            widgets.add(_kaomojiRow(c, k, idx == selectedIndex));
          }
        }
        return widgets;
    }
  }

  Widget _selectable(NymColors c,
      {required bool selected, required VoidCallback onTap, required Widget child}) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.white.withValues(alpha: 0.08) : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _statusDot(NymColors c, UserStatus status) {
    final color = switch (status) {
      UserStatus.online => const Color(0xFF22C55E),
      UserStatus.away => const Color(0xFFEAB308),
      _ => c.textDim,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _mentionRow(NymColors c, MentionResult m, bool selected) {
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectMention(m),
      child: Row(
        children: [
          _statusDot(c, m.status),
          const SizedBox(width: 8),
          Flexible(
            child: RichText(
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: TextStyle(color: c.primary, fontWeight: FontWeight.bold),
                children: [
                  TextSpan(text: '@${m.baseNym}'),
                  TextSpan(
                    text: '#${m.suffix}',
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w100,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _channelRow(NymColors c, ChannelResult ch, bool selected) {
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectChannel(ch),
      child: Row(
        children: [
          Text('#${ch.name}',
              style: TextStyle(color: c.primary, fontWeight: FontWeight.bold)),
          if (ch.isCurrent) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.primary,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Text('current',
                  style: TextStyle(color: c.bg, fontSize: 10)),
            ),
          ],
          if (ch.messageCount > 0) ...[
            const Spacer(),
            Text(
              '${ch.messageCount} msg${ch.messageCount != 1 ? 's' : ''}',
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emojiRow(NymColors c, EmojiResult e, bool selected) {
    final glyph = e.isCustom
        ? Image.network(
            proxiedEmojiUrl(e.customUrl!, null),
            width: 23,
            height: 23,
            errorBuilder: (_, __, ___) => const SizedBox(width: 23, height: 23),
          )
        : Text(e.emoji, style: const TextStyle(fontSize: 23));
    // For custom emoji the label strips wrapping colons (the PWA shows
    // `:shortcode:` once).
    final label = e.isCustom ? e.name : e.name;
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectEmoji(e),
      child: Row(
        children: [
          SizedBox(width: 23, height: 23, child: Center(child: glyph)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(':$label:',
                style: TextStyle(color: c.textDim, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _kaomojiRow(NymColors c, String k, bool selected) {
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectKaomoji(k),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(k, style: TextStyle(color: c.text, fontSize: 14)),
      ),
    );
  }

  Widget _header(NymColors c, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );
}
