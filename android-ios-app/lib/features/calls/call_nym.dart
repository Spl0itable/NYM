// call_nym.dart - Decorated display name for the call UI (overlay tiles, chat
// from-line, call title, fly-reaction "who" pill, incoming-call name, mention
// rows). Native port of `calls.js:19-36 _callNymHtml`:
//
//   base nym + `#suffix` + purchased flair/supporter badges + verified ✓ badge
//   (developer/bot) + friend icon.
//
// `self` renders a plain "You" with no decorations (calls.js line 21).
//
// The verified ✓ and friend badges are the shared [VerifiedBadge] /
// [FriendBadge] widgets — the PWA reuses the global `.verified-badge` /
// `.friend-badge` classes in `_callNymHtml`, so the unscoped light-mode
// darkening (`#1a8cd8` / `#0288d1`, styles-themes-responsive.css:76-78 +
// 1300-1307) applies in the call UI too. Flair/supporter reuse the shared shop
// [CosmeticNymBadges] so the glyphs match the rest of the app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/context_menu/profile_badges.dart';
import '../i18n/i18n.dart';

/// A decorated call nym: `base` + dim `#suffix` + flair/supporter + verified ✓ +
/// friend badge. Pass [self] (or a pubkey equal to the local identity) to render
/// a plain "You" with no decorations.
class CallNym extends ConsumerWidget {
  const CallNym({
    super.key,
    required this.pubkey,
    this.nym,
    this.self = false,
    this.baseColor,
    this.baseStyle,
    this.suffixOpacity = 0.7,
    this.badgeSize = 14,
  });

  /// The participant's pubkey (drives suffix + verified/friend/cosmetics).
  final String pubkey;

  /// Optional already-known nym (falls back to `usersProvider`/pubkey prefix).
  final String? nym;

  /// Render a plain "You" with no decorations (calls.js `opts.self`).
  final bool self;

  /// Base-nym colour (defaults to the surrounding text colour).
  final Color? baseColor;

  /// Base-nym text style override (size/weight). Colour comes from [baseColor].
  final TextStyle? baseStyle;

  final double suffixOpacity;
  final double badgeSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.watch(nostrControllerProvider);
    final selfPubkey = controller.identity?.pubkey ?? '';

    final base = (baseStyle ?? const TextStyle()).copyWith(
      color: baseColor ?? c.textBright,
    );

    if (self || (pubkey.isNotEmpty && pubkey == selfPubkey)) {
      return Text(tr('You'), style: base, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    final users = ref.watch(usersProvider);
    final user = users[pubkey];
    final rawNym = (nym != null && nym!.isNotEmpty)
        ? nym!
        : (user?.nym.isNotEmpty == true ? user!.nym : pubkey);
    final baseNym = stripPubkeySuffix(rawNym);
    final suffix = getPubkeySuffix(pubkey);

    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = !isDev && controller.isVerifiedBot(pubkey);
    final isFriend = ref.watch(appStateProvider).friends.contains(pubkey);
    final cosmetics = ref.watch(userCosmeticsProvider(pubkey));

    // Genesis holders bold the base nym; the suffix stays weight 400.
    final genesis = hasGenesisFlair(cosmetics);

    // The base + dim suffix as a single ellipsizing run. Sized to content in
    // unbounded parents (Wrap / min-size Row) and ellipsized in bounded ones
    // (tile / pill with a maxWidth) — so no `Flexible` is needed, which keeps
    // this safe to drop anywhere in the call UI.
    final nameRun = Text.rich(
      TextSpan(children: [
        TextSpan(
          text: baseNym,
          style: base.copyWith(
            fontWeight: genesis ? FontWeight.w700 : base.fontWeight,
          ),
        ),
        TextSpan(
          text: '#$suffix',
          style: base.copyWith(
            fontWeight: FontWeight.w400,
            color: (baseColor ?? c.textBright).withValues(alpha: suffixOpacity),
          ),
        ),
      ]),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Flexible(child: nameRun),
        CosmeticNymBadges(
          cosmetics: cosmetics,
          flairSize: badgeSize,
          supporterHeight: badgeSize,
        ),
        if (isDev || isBot) ...[
          const SizedBox(width: 3),
          VerifiedBadge(size: badgeSize),
        ],
        if (isFriend) ...[
          const SizedBox(width: 3),
          FriendBadge(size: badgeSize),
        ],
      ],
    );
  }
}

/// Inline `@mention` highlighting for call-chat text (calls.js
/// `_formatCallChatText`, lines 1457-1472): `@name#suffix` segments rendered in
/// the primary colour, weight 600. Returns a [TextSpan] tree to drop into a
/// `Text.rich`.
TextSpan callChatTextSpans(String text, TextStyle base, Color mentionColor) {
  final raw = text;
  final re = RegExp(r'(^|\s)@([^\s#@]+)(#[0-9a-fA-F]{4})?');
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in re.allMatches(raw)) {
    if (m.start > last) {
      spans.add(TextSpan(text: raw.substring(last, m.start), style: base));
    }
    final pre = m.group(1) ?? '';
    final name = m.group(2) ?? '';
    final sfx = m.group(3) ?? '';
    if (pre.isNotEmpty) spans.add(TextSpan(text: pre, style: base));
    spans.add(TextSpan(
      text: '@$name$sfx',
      style: base.copyWith(color: mentionColor, fontWeight: FontWeight.w600),
    ));
    last = m.end;
  }
  if (last < raw.length) {
    spans.add(TextSpan(text: raw.substring(last), style: base));
  }
  return TextSpan(children: spans);
}
