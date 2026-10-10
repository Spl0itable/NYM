import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/nym_label.dart';
import '../../widgets/context_menu/profile_badges.dart';
import '../i18n/i18n.dart';

String callPeerName(AppState app, String pubkey, [String? hint]) {
  for (final c in app.pmConversations) {
    if (c.pubkey == pubkey) return pickDisplayNym(app.users[pubkey]?.nym, c.nym);
  }
  return pickDisplayNym(app.users[pubkey]?.nym, hint);
}

/// Decorated call nym (suffix, flair, verified and friend badges); [self] renders a plain "You".
class CallNym extends ConsumerWidget {
  const CallNym({
    super.key,
    required this.pubkey,
    this.nym,
    this.self = false,
    this.baseColor,
    this.baseStyle,
    this.badgeSize = 14,
  });

  final String pubkey;

  /// Optional already-known nym; falls back to `usersProvider` or the pubkey prefix.
  final String? nym;

  final bool self;

  final Color? baseColor;

  /// Base-nym text style override; color comes from [baseColor].
  final TextStyle? baseStyle;

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
      return Text(tr('You'),
          style: base, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    final users = ref.watch(usersProvider);
    final user = users[pubkey];
    final rawNym = !isPlaceholderNym(user?.nym)
        ? user!.nym
        : ((nym != null && nym!.isNotEmpty)
            ? nym!
            : (user?.nym.isNotEmpty == true ? user!.nym : pubkey));
    final baseNym = stripPubkeySuffix(rawNym);
    final suffix = getPubkeySuffix(pubkey);

    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = !isDev && controller.isVerifiedBot(pubkey);
    final isFriend = ref.watch(appStateProvider).friends.contains(pubkey);
    final cosmetics = ref.watch(userCosmeticsProvider(pubkey));

    // Genesis holders bold the base nym; the suffix stays weight 400.
    final genesis = hasGenesisFlair(cosmetics);

    final nameRun = NymLabel(
      baseNym,
      suffix: suffix,
      genesis: genesis,
      style: base.copyWith(
        fontWeight: genesis ? FontWeight.w700 : base.fontWeight,
      ),
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

/// Highlights `@name#suffix` mentions in call-chat text.
TextSpan callChatTextSpans(
    BuildContext context, String text, TextStyle base, Color mentionColor) {
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
    final mention =
        base.copyWith(color: mentionColor, fontWeight: FontWeight.w600);
    spans.add(TextSpan(text: '@$name', style: mention));
    if (sfx.isNotEmpty) {
      spans.add(
          TextSpan(text: sfx, style: nymSuffixStyleOf(context, mention)));
    }
    last = m.end;
  }
  if (last < raw.length) {
    spans.add(TextSpan(text: raw.substring(last), style: base));
  }
  return TextSpan(children: spans);
}
