// Composer autocomplete dropdown for all four query types; the composer owns selection and splicing.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/user.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/profile_badges.dart';
import '../emoji/custom_emoji.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';
import '../shop/cosmetics.dart';
import '../shop/shop_widgets.dart';
import 'autocomplete_queries.dart';

/// Badge flags resolved by the host at render time; [verifiedTitle] is the tooltip, null when not verified.
typedef MentionBadges = ({bool verified, bool friend, String? verifiedTitle});

/// Which dropdown content to render and its flat selectable items.
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

  /// Selectable kaomoji strings; headers aren't selectable.
  List<String> get kaomojiItems =>
      [for (final s in kaomojiSections) ...s.items];

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

class AutocompleteDropdown extends StatefulWidget {
  const AutocompleteDropdown({
    super.key,
    required this.view,
    required this.selectedIndex,
    required this.onSelectMention,
    required this.onSelectChannel,
    required this.onSelectEmoji,
    required this.onSelectKaomoji,
    this.custom = CustomEmojiState.empty,
    this.badgesFor,
    this.cosmeticsFor,
  });

  final AutocompleteView view;
  final int selectedIndex;
  final void Function(MentionResult) onSelectMention;
  final void Function(ChannelResult) onSelectChannel;
  final void Function(EmojiResult) onSelectEmoji;
  final void Function(String kaomoji) onSelectKaomoji;
  final CustomEmojiState custom;

  /// Resolves badge flags for a mention row; null renders no badges.
  final MentionBadges Function(String pubkey)? badgesFor;

  /// Resolves flair for a mention row; null omits the glyph.
  final UserCosmetics Function(String pubkey)? cosmeticsFor;

  @override
  State<AutocompleteDropdown> createState() => _AutocompleteDropdownState();
}

class _AutocompleteDropdownState extends State<AutocompleteDropdown> {
  final ScrollController _scroll = ScrollController();
  // Key on the selected row so keyboard nav can scroll it into view.
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void didUpdateWidget(AutocompleteDropdown old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) _scrollSelectedIntoView();
  }

  void _scrollSelectedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !_scroll.hasClients) return;
      // Scroll only enough to reveal the row.
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  AutocompleteView get view => widget.view;
  int get selectedIndex => widget.selectedIndex;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Kaomoji palette is taller and padded; the others cap at 150 with no padding.
    final isKaomoji = view.kind == AutocompleteKind.kaomoji;
    return Container(
      constraints: BoxConstraints(maxHeight: isKaomoji ? 200 : 150),
      margin: const EdgeInsets.only(bottom: 8),
      padding: isKaomoji ? const EdgeInsets.all(6) : null,
      decoration: BoxDecoration(
        // Solid-ui (default) is detected by the fully opaque glass background token.
        color: c.glassBg.a == 1.0
            ? c.glassBg
            : isKaomoji
                ? (c.isLight
                    ? const Color(0xEBFFFFFF)
                    : const Color(0xE6141423))
                : c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color:
                c.isLight ? const Color(0x1F000000) : const Color(0x80000000),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      // Clip rows to the rounded top so the selected highlight can't poke past the corner.
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _rows(c),
          ),
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
      {required bool selected,
      required VoidCallback onTap,
      required Widget child}) {
    return Material(
      key: selected ? _selectedKey : null,
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? c.hoverOverlay : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: child,
        ),
      ),
    );
  }

  /// 18x18 avatar with a status dot, omitted for `hidden` users.
  Widget _mentionAvatar(NymColors c, MentionResult m) {
    final hidden = m.status == UserStatus.hidden;
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          NymAvatar(
              seed: m.pubkey,
              size: 18,
              imageUrl: m.avatarUrl,
              label: m.baseNym.isNotEmpty ? m.baseNym[0] : null),
          if (!hidden)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor(m.status),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.bg, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mentionRow(NymColors c, MentionResult m, bool selected) {
    if (m.isBroadcast) {
      return _selectable(
        c,
        selected: selected,
        onTap: () => widget.onSelectMention(m),
        child: Row(
          key: ValueKey('gtBroadcast-${m.baseNym}'),
          children: [
            Text('@${m.baseNym}',
                style: TextStyle(color: c.primary, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(m.broadcastHint!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ),
          ],
        ),
      );
    }
    final badges = widget.badgesFor?.call(m.pubkey);
    final cosmetics = widget.cosmeticsFor?.call(m.pubkey);
    // Flair only; the supporter pill never shows in this dropdown.
    final flairId = cosmetics?.flairId;
    final hasFlair = flairId != null && flairId.isNotEmpty;
    return _selectable(
      c,
      selected: selected,
      onTap: () => widget.onSelectMention(m),
      child: Row(
        children: [
          _mentionAvatar(c, m),
          const SizedBox(width: 4),
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
          if (hasFlair) ...[
            const SizedBox(width: 4),
            FlairBadge(
              flairId: flairId,
              edition: cosmetics?.genesisEdition,
              size: 20,
            ),
          ],
          if (badges != null && badges.verified) ...[
            const SizedBox(width: 4),
            VerifiedBadge(size: 20, tooltip: badges.verifiedTitle),
          ],
          if (badges != null && badges.friend) ...[
            const SizedBox(width: 2),
            const FriendBadge(size: 20),
          ],
        ],
      ),
    );
  }

  Widget _channelRow(NymColors c, ChannelResult ch, bool selected) {
    return _selectable(
      c,
      selected: selected,
      onTap: () => widget.onSelectChannel(ch),
      // Weighted children so the row never overflows; the count hugs the right edge.
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text('#${ch.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style:
                    TextStyle(color: c.primary, fontWeight: FontWeight.bold)),
          ),
          if (ch.isCurrent) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.primary,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Text(tr('current'),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: TextStyle(color: c.bg, fontSize: 10)),
            ),
          ],
          if (ch.location.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                ch.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ),
          ],
          if (ch.messageCount > 0) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                ch.messageCount != 1
                    ? tr('{n} msgs', {'n': ch.messageCount})
                    : tr('{n} msg', {'n': ch.messageCount}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                softWrap: false,
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emojiRow(NymColors c, EmojiResult e, bool selected) {
    // Custom-emoji images are 25px; unicode glyphs use the 23px font.
    final side = e.isCustom ? 25.0 : 23.0;
    final glyph = e.isCustom
        // Route through the media proxy and SVG-aware renderer; `Image.network` can't decode SVG and leaks the IP.
        ? InlineNetworkImage(
            url: proxiedMedia(e.customUrl!, emoji: true),
            width: 25,
            height: 25,
            memoryOnly: true,
            retryOnError: true,
            placeholder: const SizedBox(width: 25, height: 25),
            errorChild: const SizedBox(width: 25, height: 25),
          )
        : Text(e.emoji, style: const TextStyle(fontSize: 23));
    // `name` may already be `:shortcode:`; strip colons so it isn't shown doubled.
    final label = e.name.replaceAll(RegExp(r'^:+|:+$'), '');
    return _selectable(
      c,
      selected: selected,
      onTap: () => widget.onSelectEmoji(e),
      child: Row(
        children: [
          SizedBox(width: side, height: side, child: Center(child: glyph)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(':$label:',
                style: TextStyle(
                    color: selected ? c.text : c.textDim, fontSize: 12),
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
      onTap: () => widget.onSelectKaomoji(k),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(k, style: TextStyle(color: c.text, fontSize: 14)),
      ),
    );
  }

  Widget _header(NymColors c, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Text(
          tr(label).toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );
}
