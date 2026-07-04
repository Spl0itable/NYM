import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/messages/flood_tracker.dart';
import '../../features/messages/format/message_content.dart';
import '../../features/messages/inline_network_image.dart';
import '../../features/settings/about_screen.dart';
import '../../features/p2p/p2p_models.dart';
import '../../features/p2p/p2p_service.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/reactions/quick_context_items.dart';
import '../../features/reactions/quick_react_popup.dart';
import '../../features/reactions/reaction_burst.dart';
import '../../features/reactions/reactors_modal.dart';
import '../../features/translate/message_translation.dart';
import '../../features/zaps/zap_badge.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'bitchat_user_color.dart';
import 'crypto_verified_badge.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/interaction_hooks.dart';
import '../context_menu/profile_badges.dart';

/// Formats a [DateTime] per the user's time-format setting (docs/specs/02 §4).
String formatTime(DateTime t, String timeFormat) {
  final h24 = t.hour;
  final m = t.minute.toString().padLeft(2, '0');
  if (timeFormat == '24hr') {
    return '${h24.toString().padLeft(2, '0')}:$m';
  }
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  return '$h12:$m $ampm';
}

const List<String> _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The full "date, time" label shown when a message timestamp is tapped
/// (`_formatFullTimestamp`, messages.js:3328): seconds-precision time in the
/// user's 12/24h format, with the date per the `dateFormat` setting
/// (`mdy`/`dmy`/`ymd`, else "Mon D, YYYY").
String formatFullTimestamp(DateTime t, String timeFormat, String dateFormat) {
  final h24 = t.hour;
  final m = t.minute.toString().padLeft(2, '0');
  final s = t.second.toString().padLeft(2, '0');
  final String timeStr;
  if (timeFormat == '24hr') {
    timeStr = '${h24.toString().padLeft(2, '0')}:$m:$s';
  } else {
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    timeStr = '${h12.toString().padLeft(2, '0')}:$m:$s $ampm';
  }
  final y = t.year;
  final mo = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  final String dateStr;
  switch (dateFormat) {
    case 'mdy':
      dateStr = '$mo/$d/$y';
    case 'dmy':
      dateStr = '$d/$mo/$y';
    case 'ymd':
      dateStr = '$y-$mo-$d';
    default:
      dateStr = '${_shortMonths[t.month - 1]} ${t.day}, $y';
  }
  return '$dateStr, $timeStr';
}

/// Relative-time label for the in-bubble timestamp (a 1:1 port of
/// `_formatRelativeTime`, `messages.js:3308-3325`): `now` / `1m ago` /
/// `{m}m ago` / `{h}h ago` / `{d}d ago` / `Mon D[, YYYY]`.
String formatRelativeTime(DateTime t, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diffMs = ref.difference(t).inMilliseconds;
  final s = (diffMs < 0 ? 0 : diffMs) ~/ 1000;
  if (s < 45) return 'now';
  if (s < 90) return '1m ago';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ago';
  final h = m ~/ 60;
  if (h < 24) return '${h}h ago';
  final d = h ~/ 24;
  if (d < 7) return '${d}d ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final mo = months[t.month - 1];
  return t.year == ref.year ? '$mo ${t.day}' : '$mo ${t.day}, ${t.year}';
}

/// Sentinel prefix marking a `/groupinfo` rich system row. The PWA renders
/// `cmdGroupInfo` as an HTML `.group-info` block INSIDE a system pill
/// (`displaySystemMessage(html, 'system', {html:true})`, groups.js:3487-3525);
/// here the composer encodes the structured payload into the system message's
/// content via [encodeGroupInfoSystemMessage] and [MessageRow] decodes +
/// renders the block (title / count / avatar member rows / owner-mod-you
/// labels, styles-components.css:1050-1089).
const String kGroupInfoSystemPrefix = '\u0000group-info\u0000';

/// One `/groupinfo` member row: the pubkey plus its role labels
/// (`owner`/`mod`/`you`), already ordered owner → mods → members (each block
/// alphabetized) like `cmdGroupInfo`'s sort.
typedef GroupInfoMember = ({String pubkey, List<String> labels});

/// The decoded `/groupinfo` payload (group name, member count, ordered rows).
typedef GroupInfoPayload = ({
  String name,
  int count,
  List<GroupInfoMember> members,
});

/// Encodes a `/groupinfo` payload into a system-message content string (see
/// [kGroupInfoSystemPrefix]).
String encodeGroupInfoSystemMessage(GroupInfoPayload info) {
  return kGroupInfoSystemPrefix +
      jsonEncode({
        'name': info.name,
        'count': info.count,
        'members': [
          for (final m in info.members)
            {'pk': m.pubkey, 'labels': m.labels},
        ],
      });
}

/// Decodes a system-message content string produced by
/// [encodeGroupInfoSystemMessage]; null for any other content.
GroupInfoPayload? decodeGroupInfoSystemMessage(String content) {
  if (!content.startsWith(kGroupInfoSystemPrefix)) return null;
  try {
    final decoded =
        jsonDecode(content.substring(kGroupInfoSystemPrefix.length));
    if (decoded is! Map) return null;
    final rawMembers = decoded['members'];
    return (
      name: (decoded['name'] as String?) ?? '',
      count: (decoded['count'] as num?)?.toInt() ?? 0,
      members: <GroupInfoMember>[
        if (rawMembers is List)
          for (final m in rawMembers)
            if (m is Map && m['pk'] is String)
              (
                pubkey: m['pk'] as String,
                labels: <String>[
                  if (m['labels'] is List)
                    for (final l in m['labels'] as List)
                      if (l is String) l,
                ],
              ),
      ],
    );
  } catch (_) {
    return null;
  }
}

/// Abbreviates a count for badges/footers (a 1:1 port of `abbreviateNumber`,
/// `users.js:2069-2073`): `<1000` verbatim, `1.2k` / `12k`, `1.2M`.
String abbreviateNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return '${v.toStringAsFixed(n < 10000 ? 1 : 0)}k';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// Renders a single message in either IRC or bubble layout.
///
/// IRC (`!useBubbles`): a wrapping row of [author 120w] [time 50w] [content],
/// with self/mentioned tints + left accent bars. Bubble (`useBubbles`): a
/// name-above-bubble stack, the content boxed with a tail corner, right-aligned
/// for self, with an in-bubble time. (docs/specs/02 §6, docs/specs/03 §2.7)
///
/// Interactions (docs/specs/02 §5.8): reaction badges toggle via
/// [NostrController.toggleReaction] (kind inferred from the message), an
/// "add reaction" affordance opens the picker, long-pressing a badge shows the
/// reactor list, and long-pressing the message (or tapping the author/avatar)
/// opens the quick-react popup / context menu.
class MessageRow extends ConsumerStatefulWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.settings,
    required this.reactions,
    this.mentioned = false,
    this.grouped = false,
    this.showAvatar = true,
    this.showName = true,
    this.inGroup = false,
    this.columnsMode = false,
    this.onReactionPicker,
    this.bubbleAnchorKey,
    this.swipeAvatarDx,
  });

  final Message message;
  final Settings settings;
  final List<MessageReaction> reactions;
  final bool mentioned;

  /// This row renders inside a columns-deck `.cv-list` (`body.columns-mode`,
  /// styles-columns.css). IRC rows stack vertically (`.cv-list .message
  /// { flex-direction: column; gap: 5px }` — flex children are blockified, so
  /// time / author / content each take their own line, the content full-width
  /// with an extra 5px `margin-top`, :27-49), and the desktop hover-button
  /// pair stacks vertically (`.msg-hover-buttons { flex-direction: column }`,
  /// :80-82). The single-chat view never sets this.
  final bool columnsMode;

  /// Bubble layout: when set (the LAST message of a [MessageGroup]), keys the
  /// rounded bubble container so the group's gliding avatar can bottom-align to
  /// the bubble — NOT to the full group foot, which would drop it onto the
  /// reactions / translation / receipt rows that sit BELOW the bubble. Null for
  /// every other row.
  final GlobalKey? bubbleAnchorKey;

  /// Bubble layout: this message is part of a consecutive same-author group.
  final bool grouped;

  /// Bubble layout: render the 32px sticky avatar (others only).
  final bool showAvatar;

  /// Bubble layout: render the name above the bubble.
  final bool showName;

  /// Bubble layout: this row is rendered INSIDE a [MessageGroup], which owns the
  /// group's horizontal padding and the single sticky [_StickyGroupAvatar]. When
  /// true, [_buildBubble] emits just the content stack (name / bubble /
  /// translation / readers / reactions) plus the per-row vertical rhythm — no
  /// avatar gutter, no self-contained row — so the group can lay the bubbles in
  /// one column beside the gliding avatar (PWA `.message-group-stack`).
  final bool inGroup;

  /// Opens the full emoji reaction picker for this message (host supplies it).
  /// When null the add-reaction / "more" affordances are no-ops.
  final ValueChanged<Message>? onReactionPicker;

  /// Bubble layout: live swipe-translation channel for the group's sticky
  /// avatar. [MessageGroup] supplies it for the LAST bubble of an others'
  /// group only — the PWA slides the `.message-group-avatar` together with
  /// that message during a swipe (`findGroupAvatar`, messages.js:2151-2160 +
  /// 2216-2219). Null everywhere else.
  final ValueNotifier<double>? swipeAvatarDx;

  @override
  ConsumerState<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends ConsumerState<MessageRow> {
  bool _showTranslation = false;
  String? _translateLangOverride;

  /// Desktop row hover (`@media(hover:hover) .message:hover`, styles-chat.css
  /// :124-132): drives the IRC row hover tint and the `.msg-hover-buttons`
  /// opacity. Only ever set on hover-capable (non-touch) platforms.
  bool _hovered = false;

  /// Refreshes the in-bubble relative time ("2m ago") on a cadence, mirroring
  /// `_ensureBubbleRelativeTimer` / `_refreshBubbleRelativeTimes`
  /// (`messages.js:1051,3347`).
  Timer? _relativeTimer;

  /// Whether this row plays the `bubble-snap-in` entrance when it mounts. The
  /// PWA adds `.bubble-snap` to a LIVE-appended message that bubble-groups onto
  /// the previous one — never while bulk-appending or for historical restores
  /// (`messages.js:1043-1048`). Flutter list rows also mount when old history
  /// scrolls into view, so "live append" is approximated as a message created
  /// within the last few seconds. Latched on the FIRST build so later rebuilds
  /// (or the 30s relative-time tick) can't replay it.
  late final bool _snapIn = widget.grouped &&
      widget.settings.useBubbles &&
      !widget.message.isHistorical &&
      DateTime.now().difference(widget.message.dateTime).inMilliseconds < 5000;

  @override
  void dispose() {
    _relativeTimer?.cancel();
    super.dispose();
  }

  Message get message => widget.message;
  Settings get settings => widget.settings;
  List<MessageReaction> get reactions => widget.reactions;

  /// The author's kind-0 profile picture (`profile.picture`) for [NymAvatar];
  /// null → identicon fallback (Rule 4).
  String? get _authorPicture =>
      ref.watch(usersProvider)[message.pubkey]?.profile?.picture;

  /// True when this message's author is the verified developer or the Nymbot
  /// (`isVerifiedDeveloper` / `isVerifiedBot`) — the blue ✓ badge.
  bool get _isVerified {
    final controller = ref.read(nostrControllerProvider);
    return controller.isVerifiedDeveloper(message.pubkey) ||
        controller.isVerifiedBot(message.pubkey);
  }

  /// True when the author is a (non-self) friend — the cyan friend glyph.
  bool get _isFriendAuthor =>
      !message.isOwn && ref.watch(appStateProvider).isFriend(message.pubkey);

  /// The cryptographic-verification lock state for this message, or null when no
  /// lock should render. The PWA only shows the `.crypto-verified-badge` on
  /// sealed (NIP-17/NIP-59) PM/group messages (`messages.js:752` gates on
  /// `message.isPM`); public channel messages carry no seal and show nothing.
  /// Within sealed messages: `senderVerified == true` → verified, `false` →
  /// unverified, `null` → unknown (seal unavailable, e.g. restored history).
  CryptoVerifyState? get _cryptoState {
    if (!message.isPM && !message.isGroup) return null;
    switch (message.senderVerified) {
      case true:
        return CryptoVerifyState.verified;
      case false:
        return CryptoVerifyState.unverified;
      case null:
        return CryptoVerifyState.unknown;
    }
  }

  /// `_RX_HTML_TAG` — strip markup before mention matching (messages.js:410).
  static final RegExp _htmlTagRe = RegExp(r'<[^>]*>');

  /// `_RX_DUP_SUFFIX` — collapse a doubled `@nym#abcd#abcd` to one suffix
  /// before matching (messages.js:5 / :411).
  static final RegExp _dupSuffixRe =
      RegExp(r'@([^@#\s]+)#([0-9a-f]{4})#\2\b', caseSensitive: false);

  /// Whether this row renders the PWA `.message.mentioned` highlight. The
  /// caller's [MessageRow.mentioned] flag (a fast case-SENSITIVE `contains`
  /// probe) is OR'ed with a faithful port of the PWA `isMentioned`
  /// (messages.js:400-425): a CASE-INSENSITIVE `@nym` match with an optional
  /// `#suffix` tail (`_getMentionPattern`, :12-22), HTML stripped and doubled
  /// suffixes deduped first, quoted `>` lines dropped — though a quote-reply
  /// addressed to us (`> @me[#sfx]:`, `_getQuoteToMePattern`) still counts.
  /// The bare `contains` missed real mentions (e.g. an iOS-auto-capitalised
  /// "@Nym" against the lowercase self nym), leaving the highlight off.
  ///
  /// Self and PM/group rows never highlight — the PWA class chain is an
  /// else-if (`self` / `pm` win over `mentioned`, messages.js:686-692), so a
  /// PM or group message never gets the `.mentioned` treatment. The guard runs
  /// BEFORE the caller's fast flag so it can't be bypassed.
  bool _isMentionedRow() {
    if (message.isOwn || message.isPM) return false;
    if (widget.mentioned) return true;
    final cleanNym = stripPubkeySuffix(ref.read(appStateProvider).selfNym);
    if (cleanNym.isEmpty) return false;
    final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
    final rawSuffix = selfPubkey != null ? getPubkeySuffix(selfPubkey) : '';
    // `getPubkeySuffix` yields '????' for a non-hex tail — treat as no suffix.
    final sfx = rawSuffix == '????' ? '' : RegExp.escape(rawSuffix);
    final esc = RegExp.escape(cleanNym);
    var clean = message.content
        .replaceAll(_htmlTagRe, '')
        .replaceAllMapped(_dupSuffixRe, (m) => '@${m[1]}#${m[2]}');
    // "> @ourNym[#sfx]: …" quote-reply addressed to us counts even though the
    // line is itself a blockquote (messages.js:414-416, `^\s*>+\s*@nym(?:#sfx)?\s*:`).
    final quoteToMe = RegExp('^\\s*>+\\s*@$esc(?:#$sfx)?\\s*:',
        caseSensitive: false, multiLine: true);
    if (quoteToMe.hasMatch(clean)) return true;
    // Strip the remaining blockquoted lines so mentions inside quoted text
    // don't highlight (messages.js:418-420).
    clean = clean
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('>'))
        .join('\n');
    // `@nym` followed by our `#suffix` (word-bounded) or by anything that is
    // NOT some other 4-hex suffix (messages.js:15-18).
    final tail = sfx.isNotEmpty
        ? '(?:#$sfx\\b|(?!#[0-9a-f]{4})(?:\\b|\$))'
        : '(?!#[0-9a-f]{4})(?:\\b|\$)';
    return RegExp('@$esc$tail', caseSensitive: false).hasMatch(clean);
  }

  /// True when this message has accrued zaps (`zapsProvider`), so the reactions
  /// row must render to host the `⚡ N` zap badge even without reactions.
  bool get _hasZaps {
    final z = ref.watch(zapsProvider)[message.id];
    return z != null && z.totalSats > 0;
  }

  /// Whether the `.msg-hover-buttons` pair renders for this message: only above
  /// the mobile breakpoint (`isMobile = innerWidth <= 768`, messages.js:768)
  /// and only for messages with a usable reaction id (`isValidEventId`: a PM's
  /// `nymMessageId`, else a canonical 64-hex event id — messages.js:764-767).
  bool _hoverButtonsEligible(BuildContext context) {
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return false;
    }
    if (message.isPM && (message.nymMessageId?.isNotEmpty ?? false)) {
      return true;
    }
    return RegExp(r'^[0-9a-f]{64}$', caseSensitive: false)
        .hasMatch(message.id);
  }

  /// Starts (once) a low-frequency timer that re-renders the in-bubble relative
  /// time. Recent messages tick every ~10s; older ones drift slowly, so a 30s
  /// cadence is plenty (the PWA refreshes on a similar interval).
  void _ensureRelativeTimer() {
    _relativeTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  /// The author's active flair-shop cosmetics (style / flair / supporter),
  /// resolved from the shop controller (self) or presence (`usersProvider`).
  UserCosmetics get _cosmetics =>
      ref.watch(userCosmeticsProvider(message.pubkey));

  /// The author's active message-style decoration. The supporter badge also
  /// adds a gold "supporter-style" treatment to the message body
  /// (`.message.supporter-style`) — and the PWA applies BOTH classes when a
  /// style is active too (`_applyShopClassesToMessage`, shop.js:485-495), so
  /// the two cascade together: supporter's gold text/row wash composes over
  /// the style per [composeSupporterStyle].
  MessageStyleDecoration? _styleDecoration(BuildContext context) {
    final cos = _cosmetics;
    final c = context.nym;
    final isLight = c.isLight;
    // solid-ui swaps the translucent satoshi/supporter washes for the opaque
    // `body.solid-ui` plates (styles-themes-responsive.css:1714-1776).
    final solidUi = c.solidUi;
    final styled = messageStyleDecoration(cos.styleId,
        isLight: isLight, solidUi: solidUi);
    if (styled != null) {
      return cos.supporter
          ? composeSupporterStyle(styled, cos.styleId!,
              isLight: isLight, solidUi: solidUi)
          : styled;
    }
    if (cos.supporter) {
      return supporterStyleDecorationFor(isLight: isLight, solidUi: solidUi);
    }
    return null;
  }

  /// The active special-cosmetic auras (gold/neon/prism/frost/phoenix/cosmic/
  /// hologram) composed onto the bubble/row, resolved for the current brightness
  /// (the PWA swaps gold — and a derived tone for the rest — in `light-mode`)
  /// and for solid-ui (which flattens gold's translucent washes to opaque
  /// plates, styles-themes-responsive.css:1722-1776).
  List<CosmeticAura> _resolveAuras(BuildContext context) =>
      resolveCosmeticAuras(_cosmetics,
          isLight: context.nym.isLight, solidUi: context.nym.solidUi);

  /// True when the message element carries a `style-…` class — the PWA adds the
  /// RAW active style id as a class (`messageEl.classList.add(activeStyle)`), so
  /// any active `style-…` item trips the `:not([class*="style-"])` cosmetic
  /// gates (hologram fill/sheen, frost fill, cosmic bubble starfield, gold
  /// bubble wash — styles-features.css:1163/1192/1203/3699). `supporter-style`
  /// does NOT match `[class*="style-"]` (no trailing hyphen).
  bool get _styleClassActive =>
      _cosmetics.styleId?.startsWith('style-') ?? false;

  /// The flair + supporter badges that follow the author nym.
  Widget _nymBadges(BuildContext context, {double flairSize = 16}) {
    return CosmeticNymBadges(
      cosmetics: _cosmetics,
      flairSize: flairSize,
      supporterHeight: flairSize,
    );
  }

  /// The author label rendered in BOTH layouts: `<` nym `#suffix` `>` (brackets
  /// IRC-only) followed by the flair, verified ✓, and friend badges. The nym is
  /// ellipsized; the `#suffix` is dimmed (`.nym-suffix` opacity 0.7 / 0.9em /
  /// weight 100), and the `<…>` brackets inherit the author (secondary) color.
  /// (`messages.js:803,937`; `styles-chat.css:706-710`.)
  Widget _authorLine(
    NymColors c, {
    required bool self,
    required double size,
    required double flairSize,
    bool brackets = false,
  }) {
    final style = _authorStyle(c, self: self, size: size);
    final bracketColor = style.color;
    final suffix = getPubkeySuffix(message.pubkey);
    // `.nym-suffix` base weight is 100 (styles-chat.css:706-709), but a
    // Genesis holder's suffix is raised to 400 (`.message-author
    // .has-genesis-flair .nym-suffix { font-weight: 400 }`,
    // styles-features.css:1224-1227) alongside the 700 nym bolding.
    final suffixWeight =
        hasGenesisFlair(_cosmetics) ? FontWeight.w400 : FontWeight.w100;
    // `message.author` carries the stored nym which already includes its
    // `#suffix` (User.nym / the `anon#xxxx` fallback). Strip it so the canonical
    // suffix below isn't appended twice (PWA renders the base nym + a separate
    // `.nym-suffix` span — `parseNymFromDisplay`, `messages.js:1781`).
    final baseNym = stripPubkeySuffix(message.author);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (brackets)
          Text('<', style: TextStyle(color: bracketColor, fontSize: size)),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: baseNym, style: style),
              if (suffix.isNotEmpty)
                TextSpan(
                  text: '#$suffix',
                  style: style.copyWith(
                    color: style.color?.withValues(alpha: 0.7),
                    fontSize: size * 0.9,
                    fontWeight: suffixWeight,
                  ),
                ),
            ]),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _nymBadges(context, flairSize: flairSize),
        // Blue ✓ for the verified developer / Nymbot (after flair/supporter).
        if (_isVerified) ...[
          const SizedBox(width: 4),
          VerifiedBadge(size: flairSize),
        ],
        // Cyan friend glyph for non-self friends.
        if (_isFriendAuthor) ...[
          const SizedBox(width: 4),
          FriendBadge(size: flairSize),
        ],
        if (brackets)
          Text('>', style: TextStyle(color: bracketColor, fontSize: size)),
      ],
    );
  }

  /// The author-name [TextStyle], bolding Genesis holders (`.has-genesis-flair`)
  /// The PWA only bold-weights the Genesis author line; supporters get gold on
  /// the `.message-content`, NOT the author nym — `.message.supporter-style
  /// .message-header` (styles-features.css:1478) is a DEAD selector (no JS ever
  /// emits `.message-header`; the author element is `.message-author`), so the
  /// author nym keeps the normal self/other color.
  TextStyle _authorStyle(NymColors c, {required bool self, required double size}) {
    final genesis = hasGenesisFlair(_cosmetics);
    // `.message-author.cosmetic-redacted { color:#fff; opacity:0.8 }`
    // (styles-features.css:1419-1422) — the redacted privacy cosmetic dims the
    // author nym as well as blanking the body. Light mode swaps to a dark nym
    // (`body.light-mode … .message-author.cosmetic-redacted { color:#1a1a1a;
    // opacity:0.75 }`, styles-themes-responsive.css:949), since white@0.8 is
    // invisible on a light surface.
    final color = _cosmetics.isRedacted
        ? (c.isLight
            ? const Color(0xFF1A1A1A).withValues(alpha: 0.75)
            : Colors.white.withValues(alpha: 0.8))
        : (self ? c.primary : (_bitchatColor(c) ?? c.secondary));
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: genesis ? FontWeight.w700 : FontWeight.w600,
      // `.message-author { letter-spacing: 0.2px }` (styles-chat.css:697).
      letterSpacing: 0.2,
    );
  }

  /// The per-user "bitchat-user" color for a NON-self author, or null when it
  /// doesn't apply. The PWA only assigns the deterministic 1-of-1000 hue when
  /// `settings.theme === 'bitchat'` and the author isn't self (`getUserColorClass`,
  /// `users.js:11-18`); in every other theme `.message-author` keeps `--secondary`.
  /// The same class is applied to the author span AND `.message-content`
  /// (`messages.js:937-938`), so the body uses this too. (C06-1/2.)
  Color? _bitchatColor(NymColors c) {
    if (message.isOwn) return null;
    if (settings.theme != NymThemeKey.bitchat) return null;
    return bitchatUserColor(message.pubkey, isLight: c.isLight);
  }

  /// The message body: a P2P file-offer card when this is an offer, a redacted
  /// block when the redacted cosmetic is active, else the rich-formatted content
  /// tinted by the active style.
  Widget _bodyContent(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
    bool bubble = false,
  }) {
    if (message.isFileOffer && message.fileOffer != null) {
      final p2p = ref.read(p2pServiceProvider);
      // Resolve the channel currently open so the inline Stop broadcasts the
      // unseeded event with the matching wire tag — `g` for a geohash channel,
      // `d` for a named one — like the PWA's `stopSeeding`, which reads
      // `this.currentGeohash` regardless of where Stop fires (p2p.js:828). F06-B3.
      final app = ref.read(appStateProvider);
      final v = app.view;
      final isGeoChannel = v.kind == ViewKind.channel &&
          app.channels
              .any((ch) => ch.key == v.id.toLowerCase() && ch.isGeohash);
      final isNamedChannel = v.kind == ViewKind.channel && !isGeoChannel;
      return FileOfferCard(
        offer: FileOffer.fromJson(message.fileOffer!),
        isOwn: message.isOwn,
        service: p2p,
        seedGeohash: isGeoChannel ? v.id : null,
        seedChannelName: isNamedChannel ? v.id : null,
      );
    }
    // cosmetic-redacted (`shop.js:498-512`): the REAL text shows for 10s, then a
    // `.cosmetic-redacted-message` translucent bar replaces it (bg white@0.15,
    // radius-xs, min-width 120, min-height 1.2em, content hidden).
    final Widget body;
    if (_cosmetics.isRedacted) {
      body = _RedactedReveal(
        fontSize: fontSize,
        child: _content(context, color, fontSize, deco: deco, bubble: bubble),
      );
    } else {
      body = _content(context, color, fontSize, deco: deco, bubble: bubble);
    }
    // A bot reply whose model exposed its chain of thought PREPENDS the
    // collapsed `.bot-think` "💭 Reasoning" section INSIDE `.message-content`,
    // before the formatted body (`formattedContent =
    // _renderBotThinkingHtml(message.thinking) + formattedContent`,
    // messages.js:796-797) — gated on `message.isBot ||
    // isVerifiedBot(message.pubkey)`.
    final thinking = message.thinking;
    if (thinking != null &&
        thinking.trim().isNotEmpty &&
        (message.isBot ||
            ref.read(nostrControllerProvider).isVerifiedBot(message.pubkey))) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _BotThinkSection(
            reasoning: thinking,
            // `.bot-think { font-size: 0.88em }` of the user text size.
            fontSize: settings.textSize.toDouble() * 0.88,
          ),
          body,
        ],
      );
    }
    return body;
  }

  @override
  Widget build(BuildContext context) {
    // Centered system / action pill (`displaySystemMessage`).
    if (message.isSystemRow) return _buildSystemMessage(context);
    // `/me …` emote → italic "* author action *" line.
    if (message.isMeAction) return _buildActionMessage(context);
    Widget row =
        settings.useBubbles ? _buildBubble(context) : _buildIrc(context);
    // Hover-capable (non-touch) devices: track `.message:hover` for the IRC row
    // tint (read by [_buildIrc]) and overlay the `.msg-hover-buttons` pair —
    // quick-react + translate — at the row's top-right (`right:10; top:5`,
    // styles-chat.css:357-364; the buttons resolve against the positioned
    // `.message` row since `.message-content` is static). The buttons render
    // only above the mobile breakpoint and for messages with a usable reaction
    // id (`isValidEventId && !isMobile`, messages.js:764-779); they fade with
    // the row hover (opacity 0→1 over --transition).
    final p = Theme.of(context).platform;
    final touchPlatform =
        p == TargetPlatform.android || p == TargetPlatform.iOS;
    if (!touchPlatform) {
      final withButtons = _hoverButtonsEligible(context);
      Widget hoverChild = row;
      if (withButtons) {
        hoverChild = Stack(
          clipBehavior: Clip.none,
          children: [
            row,
            Positioned(
              top: 5,
              right: 10,
              child: IgnorePointer(
                ignoring: !_hovered,
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: NymMotion.transition,
                  curve: NymMotion.curve,
                  child: _MsgHoverButtons(
                    onReact: widget.onReactionPicker == null
                        ? null
                        : () => widget.onReactionPicker!.call(message),
                    onTranslate: () =>
                        setState(() => _showTranslation = true),
                    // `body.columns-mode .msg-hover-buttons { flex-direction:
                    // column }` (styles-columns.css:80-82) — the pair stacks
                    // vertically to fit the 360px column.
                    vertical: widget.columnsMode,
                  ),
                ),
              ),
            ),
          ],
        );
      }
      row = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: hoverChild,
      );
    }
    // `.message.flooded { opacity: 0.2 }` — a flooding (others') pubkey in the
    // current conversation is dimmed (`messages.js:652-656`). Own messages are
    // never flooded.
    if (!message.isOwn &&
        ref.watch(floodTrackerProvider).isFlooding(message.pubkey)) {
      row = Opacity(opacity: 0.2, child: row);
    }
    // `.message-scroll-flash`: a tapped blockquote scrolls to its quoted source
    // and flashes it (`_scrollToQuotedMessage`, messages.js:2775). Watch the
    // transient flash signal and pulse this row's highlight halo when it targets
    // us (the `::after` primary-tinted overlay, styles-chat.css:1285-1306).
    final flashing = ref.watch(flashedMessageProvider) == message.id;
    return _ScrollFlashOverlay(active: flashing, child: row);
  }

  /// A centered `.system-message` pill injected into the conversation flow
  /// (`styles-chat.css:1334-1349`). Text-dim, rounded-20, `white@0.03` bg,
  /// glass border, `textSize-3`. The `.action-message` variant is a bare
  /// left-aligned purple-italic line — no pill, no centering
  /// (`styles-chat.css:1357-1360`). When the row carries a
  /// [Message.systemAction] (e.g. the spam
  /// false-positive notice) an inline action button is rendered under the text.
  Widget _buildSystemMessage(BuildContext context) {
    final c = context.nym;
    final isAction = message.kind == MessageKind.action;
    final size = settings.textSize.toDouble() - 3;
    // `.action-message` is BARE purple-italic text — no pill bg/border/radius,
    // no centering and no `margin: 10px auto` (`styles-chat.css:1357-1360`):
    // `displaySystemMessage(msg,'action')` REPLACES the className, dropping
    // the `.system-message` base, so an action row is a plain full-width
    // left-aligned block (messages.js:1515).
    final text = Text(
      message.content,
      textAlign: isAction ? TextAlign.start : TextAlign.center,
      style: TextStyle(
        color: isAction ? c.purple : c.textDim,
        // `.action-message` sets no font-size, so it inherits the container's
        // fixed 14px (`.messages-container`, styles-shell.css:943); only
        // `.system-message` scales with the user text size.
        fontSize: isAction ? 14 : size,
        fontStyle: isAction ? FontStyle.italic : FontStyle.normal,
        // `.system-message { font-weight: 450 }` (w500 is the nearest weight).
        fontWeight: isAction ? FontWeight.w400 : FontWeight.w500,
        height: 1.3,
      ),
    );
    final action = message.systemAction;
    // A `/groupinfo` row carries a structured payload instead of plain text —
    // render the PWA's `.group-info` block inside the pill (groups.js:3520-3523
    // emits it via `displaySystemMessage(html, 'system', {html:true})`).
    final groupInfo =
        isAction ? null : decodeGroupInfoSystemMessage(message.content);
    // The pill body: the group-info block, just the text, or text + an inline
    // action button (the `.spam-false-positive-btn` of messages.js:645).
    final Widget pillChild = groupInfo != null
        ? _groupInfoBlock(context, groupInfo, size)
        : action == null
            ? text
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  text,
                  const SizedBox(height: 8),
                  _SystemActionButton(
                    label: action.label,
                    onTap: () => _runSystemAction(context, action),
                  ),
                ],
              );
    // `.action-message` has no padding/margin of its own — a bare block div
    // in the message flow, left-aligned at full width.
    if (isAction) {
      return Align(alignment: Alignment.centerLeft, child: text);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: c.glassBorder),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: pillChild,
        ),
      ),
    );
  }

  /// The `/groupinfo` `.group-info` block (styles-components.css:1050-1089 +
  /// groups.js:3487-3525): a `Group: "name"` title (w600, 2px below-gap), a
  /// `Members (N)` count line (12px text-dim, 6px gap), then one row per
  /// member — 22px avatar, base nym + muted `#suffix`, flair badges, and a
  /// 10px primary@0.8 `owner`/`mod`/`you` label — the rows 5px apart
  /// (`.group-info-members { gap: 5px }`). Nyms/avatars resolve live from
  /// `usersProvider` so late-arriving profiles fill in (the PWA's
  /// `ensureListProfiles`).
  Widget _groupInfoBlock(
      BuildContext context, GroupInfoPayload info, double size) {
    final c = context.nym;
    final users = ref.watch(usersProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // `.group-info-title { font-weight: 600; margin-bottom: 2px }` —
        // inherits the pill's text-dim + `textSize − 3`.
        Text(
          'Group: "${info.name}"',
          style: TextStyle(
            color: c.textDim,
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 2),
        // `.group-info-count { color: --text-dim; font-size: 12px;
        // margin-bottom: 6px }`.
        Text(
          'Members (${info.count})',
          style: TextStyle(color: c.textDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < info.members.length; i++) ...[
          if (i > 0) const SizedBox(height: 5),
          _groupInfoMemberRow(context, users, info.members[i], size),
        ],
      ],
    );
  }

  /// One `.group-info-member` row: 22px `.avatar-message`, then the
  /// `.group-info-nym` (base nym + `.nym-suffix` + flair) and the optional
  /// `.group-info-label`, 6px apart.
  Widget _groupInfoMemberRow(
    BuildContext context,
    Map<String, User> users,
    GroupInfoMember member,
    double size,
  ) {
    final c = context.nym;
    final pk = member.pubkey;
    final nym = users[pk]?.nym;
    final baseNym = (nym != null && nym.isNotEmpty)
        ? stripPubkeySuffix(nym)
        : 'nym';
    final suffix = getPubkeySuffix(pk);
    final nymStyle = TextStyle(color: c.textDim, fontSize: size, height: 1.3);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NymAvatar(
          seed: pk,
          size: 22,
          imageUrl: users[pk]?.profile?.picture,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: baseNym, style: nymStyle),
              if (suffix.isNotEmpty)
                TextSpan(
                  text: '#$suffix',
                  // `.nym-suffix`: opacity 0.7, 0.9em, weight 100.
                  style: nymStyle.copyWith(
                    color: c.textDim.withValues(alpha: 0.7),
                    fontSize: size * 0.9,
                    fontWeight: FontWeight.w100,
                  ),
                ),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Flair / supporter badges follow the nym (`getFlairForUser`); the
        // in-chat `.flair-badge` is 20px.
        CosmeticNymBadges(
          cosmetics: ref.watch(userCosmeticsProvider(pk)),
          flairSize: 20,
          supporterHeight: 20,
        ),
        if (member.labels.isNotEmpty) ...[
          const SizedBox(width: 6),
          // `.group-info-label { font-size: 10px; color: --primary;
          // opacity: 0.8 }`.
          Text(
            member.labels.join(', '),
            style: TextStyle(
              color: c.primary.withValues(alpha: 0.8),
              fontSize: 10,
            ),
          ),
        ],
      ],
    );
  }

  /// Dispatches a system-row [SystemAction]. For the spam false-positive notice
  /// this opens the About contact form pre-filled with topic 'Spam false
  /// positive' and the flagged message in a code block — a 1:1 port of
  /// `reportSpamFalsePositive(content)` (app.js:4399-4404).
  void _runSystemAction(BuildContext context, SystemAction action) {
    switch (action.kind) {
      case SystemActionKind.reportSpamFalsePositive:
        final content = action.payload;
        final body = content.isNotEmpty
            ? 'The following message was incorrectly flagged by the spam '
                'filter:\n\n```\n$content\n```'
            : 'A message was incorrectly flagged by the spam filter.';
        AboutScreen.open(
          context,
          initialTopic: 'Spam false positive',
          initialMessage: body,
        );
    }
  }

  /// A `/me` emote rendered as a centered italic `* author#suffix action *` line
  /// over the system-message pill (`.system-message.me-message`,
  /// `messages.js:662-683`). The author uses the purple/secondary accent.
  Widget _buildActionMessage(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble() - 3;
    final action = message.content.startsWith('/me ')
        ? message.content.substring(4)
        : message.content;
    final suffix = getPubkeySuffix(message.pubkey);
    // The pill's usable content width = screen − outer padding (8·2) − pill
    // padding (16·2). Both the author header and the action are capped to it so
    // a long nym ellipsises and a long action wraps onto its own line (the PWA
    // renders `* author flair action *` as inline text in a wrapping pill) —
    // never overflowing the centered `.me-message` pill.
    final maxW =
        (MediaQuery.of(context).size.width - 48).clamp(120.0, double.infinity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: c.glassBorder),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              color: c.textDim,
              fontSize: fontSize,
              fontStyle: FontStyle.italic,
              height: 1.3,
            ),
            // `.me-message` is inline text in a wrapping pill (`* author flair
            // action *`). A `Wrap` reproduces that: the author header is one
            // width-capped unit (a long nym ellipsises) and the action flows
            // onto the next line when the two can't sit together — so neither
            // the fixed flair/supporter badges nor a long action can overflow.
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: GestureDetector(
                    onTap: () => _openContextMenu(context),
                    // The whole `/me` line (incl. the nym + suffix) is italic
                    // (`.system-message.me-message { font-style: italic }`); the
                    // author keeps secondary/600 but inherits the italic.
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text('* '),
                        NymAvatar(
                            seed: message.pubkey,
                            size: fontSize + 2,
                            imageUrl: _authorPicture),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                text: stripPubkeySuffix(message.author),
                                style: TextStyle(
                                  color: c.secondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (suffix.isNotEmpty)
                                TextSpan(
                                  text: '#$suffix',
                                  style: TextStyle(color: c.secondaryA(0.6)),
                                ),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // `.flair-badge { font-size: 20px }` applies in the main
                        // chat including `/me` lines (only call surfaces scale it
                        // down) — match the IRC/bubble author lines at 20px.
                        _nymBadges(context, flairSize: 20),
                      ],
                    ),
                  ),
                ),
                // The action text (formatted), capped so it wraps within the
                // pill; the closing star trails it.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        // `/me` action mentions get inline avatars + flair
                        // (PWA `_enrichActionMentions`, messages.js:1369-1403):
                        // each `@nym#xxxx` inside the emote is decorated with the
                        // mentioned user's avatar. `enrichMentionAvatars` threads
                        // through `MessageContent` to `_MentionChip(withAvatar:)`.
                        child: MessageContent(
                          content: action,
                          fontSize: fontSize,
                          enrichMentionAvatars: true,
                        ),
                      ),
                      const Text(' *'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- IRC layout ----
  Widget _buildIrc(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;

    final deco = _styleDecoration(context);
    final mentioned = _isMentionedRow();

    Color? bg;
    Color? barColor;
    // The accent bar's glow (`::before` box-shadow) — secondary@0.4 for a
    // mention (`.message.mentioned::before { box-shadow: 0 0 8px … }`,
    // styles-chat.css:71-80, no light override), magenta for the PM-hover bar
    // below.
    Color? barGlow = mentioned ? c.secondaryA(0.4) : null;
    if (self) {
      bg = c.secondaryA(0.05);
      // `.message.self::before` accent bar: white@0.3 dark; light-mode →
      // black@0.25.
      barColor = c.isLight
          ? const Color(0x40000000) // black @ 0.25
          : const Color(0x4DFFFFFF); // white @ 0.30
    } else if (mentioned) {
      // `.message.mentioned { background: rgb(from var(--secondary) r g b /
      // 0.06) }` (styles-chat.css:65-69); light mode flattens the tint to
      // `rgba(0,0,0,0.03)` (`body.light-mode .message.mentioned`,
      // styles-themes-responsive.css:1145-1147). The 3px secondary bar +
      // glow stay in both themes.
      bg = c.isLight
          ? const Color(0x08000000) // rgba(0,0,0,0.03)
          : c.secondaryA(0.06);
      barColor = c.secondary;
    }
    // `@media(hover:hover) .message:hover { background: rgba(255,255,255,0.03) }`
    // (styles-chat.css:124-127) — it sits AFTER `.message.self`/`.mentioned` in
    // the sheet, so the hover tint REPLACES those fills while hovered. A PM row
    // hovers magenta (`.message.pm:hover`, :105-107, higher specificity); light
    // mode flips everything to black@0.03 (`body.light-mode .message:hover`,
    // styles-themes-responsive.css:555-559, loaded last). Bubble mode paints no
    // hover tint (`body.chat-bubbles .message:hover { background: none }`).
    // Aura/style backgrounds below still win (styles-features.css loads later).
    if (_hovered) {
      bg = c.isLight
          ? Colors.black.withValues(alpha: 0.03)
          : (message.isPM
              ? const Color(0x0AFF00FF) // rgba(255,0,255,0.04)
              : Colors.white.withValues(alpha: 0.03));
      // `.message.pm:hover::before` (styles-chat.css:111-122): a 3px × 60%
      // rounded `--purple` accent bar with a `0 0 8px rgba(255,0,255,0.3)`
      // glow. Its specificity beats `.self`/`.mentioned`'s ::before bars, and
      // no light-mode rule overrides the pseudo-element, so it applies in both
      // themes (only the hover BACKGROUND flips to black@0.03 in light mode).
      if (message.isPM) {
        barColor = c.purple;
        barGlow = const Color(0x4DFF00FF); // rgba(255,0,255,0.3)
      }
    }
    // A 135deg gradient painted on the IRC row (supporter's gold wash + the
    // gold/neon/phoenix/cosmic aura gradients). Takes precedence over the flat
    // [bg] in the row decoration below.
    List<Color>? bgGradient;
    // IRC layout paints the SUPPORTER accents on the row itself
    // (`body:not(.chat-bubbles) .message.supporter-style { background; border-left }`).
    // The style CONTENT plates (satoshi/eclipse/crt `.message-content`
    // backgrounds) belong to the content box below, never the row.
    if (deco?.borderAccent != null) {
      barColor = deco!.borderAccent;
      bgGradient = deco.backgroundGradient ?? bgGradient;
    }
    // Special cosmetic auras split by scope. gold/neon/phoenix/cosmic are
    // ROW-scoped in IRC — `body:not(.chat-bubbles) .message.cosmetic-aura-*`
    // paints the 3px left bar, inset ring, glow and 135deg gradient on the
    // whole row (styles-features.css:1099-1186). frost/rainbow/hologram target
    // `.message-content` in EVERY layout (:1121-1139, :1141-1167, :1197-1211),
    // so they decorate the content box below — never the time/author columns.
    // The IRC border-left is the discriminator: exactly the row-scoped four
    // carry one.
    final auras = _resolveAuras(context);
    final rowAuras = [
      for (final a in auras)
        if (a.borderAccent != null) a,
    ];
    final contentAuras = [
      for (final a in auras)
        if (a.borderAccent == null) a,
    ];
    final rowAura = rowAuras.isNotEmpty ? rowAuras.last : null;
    if (rowAura != null) {
      barColor = rowAura.borderAccent;
      bgGradient = rowAura.gradient ?? bgGradient;
    }
    // The cosmic starfield is part of the IRC ROW background
    // (`body:not(.chat-bubbles) .message.cosmetic-aura-cosmic { background:
    // gradient, url(starfield) }`, :1179-1186, no style gate) — it tiles the
    // whole row, unlike the content-scoped `--style-pattern` textures.
    final CosmeticAura? rowWatermarkAura = rowAuras
        .where((a) => a.watermark != null)
        .fold<CosmeticAura?>(null, (prev, a) => prev ?? a);

    // The three `.message` flex items, in PWA HTML order (messages.js:936-938):
    // `.message-time` (FIRST), `.message-author`, `.message-content`.
    // `.message-time { color:--text-dim; font-size:12px; min-width:50px }` —
    // the clock reserves a 50px column so author/content left-edges line up.
    final Widget? timeItem = settings.showTimestamps
        ? ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 50),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // `data-action="showFullTimestamp"`: tapping the clock opens
                // the styled `.timestamp-popup` (messages.js:936-938,
                // showTimestampPopup); hovering tints it `--primary` and shows
                // the glass `.message-time:hover::after` tooltip.
                _TimestampText(
                  label: formatTime(message.dateTime, settings.timeFormat),
                  fullTimestamp: formatFullTimestamp(message.dateTime,
                      settings.timeFormat, settings.dateFormat),
                  fontSize: 12,
                ),
                // `.crypto-lock-irc`: the verification lock sits inside
                // `.message-time` after the clock (PM/group only).
                if (_cryptoState != null)
                  CryptoVerifiedBadge(state: _cryptoState!),
              ],
            ),
          )
        : null;
    final authorItem = ConstrainedBox(
      // `.message-author { min-width: 120px }` and NO max-width — the author
      // flex item grows to its natural width and the wrapping `.message` row
      // reflows the content around it (styles-chat.css:691-698). The Wrap
      // bounds it at the row width, matching the flex container.
      constraints: const BoxConstraints(minWidth: 120),
      child: GestureDetector(
        onTap: () => _openContextMenu(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // IRC author leads with an 18px inline avatar (`.avatar-message`,
            // hidden in bubble mode). 4px gap, then `<nym#suffix flair…>`.
            NymAvatar(
                seed: message.pubkey, size: 18, imageUrl: _authorPicture),
            const SizedBox(width: 4),
            Flexible(
              child: _authorLine(
                c,
                self: self,
                size: fontSize,
                // `.flair-badge { font-size: 20px }` — in-chat flair is 20px.
                flairSize: 20,
                brackets: true,
              ),
            ),
          ],
        ),
      ),
    );
    // ---- The `.message-content` box ----
    // Everything that targets `.message-content` decorates THIS box, not the
    // row: the satoshi/eclipse/crt background plates (+ satoshi's own
    // `padding: 10px 15px`), the tiled `--style-pattern` watermark
    // (`.message-content::before` at `inset: 0` of the CONTENT element,
    // styles-features.css:966-990) and the content-scoped cosmetics. The
    // reactions row is a `.message` sibling (reactions.js:475), so it sits
    // OUTSIDE the plate.
    Widget contentBody = _bodyContent(
        context, _bitchatColor(c) ?? c.text, fontSize,
        deco: deco);
    // The style plate (`.message.style-X .message-content { background }` —
    // satoshi orange@.2 / light rgba(196,122,21,.1); eclipse rgba(18,14,28,.72)
    // and crt rgba(10,8,2,.82) in BOTH themes, :545-552 + :1289-1299 +
    // themes:899-901). Supporter's wash is bubble-only, so it returns null
    // here. The frost icy fill applies ONLY when no message style is active
    // (`.message:not([class*="style-"]).cosmetic-frost .message-content`,
    // :1163-1166).
    Color? contentFill = deco?.contentBackgroundFor(bubble: false);
    if (contentFill == null && !_styleClassActive) {
      contentFill = contentAuras
          .where((a) => a.background != null)
          .fold<Color?>(null, (prev, a) => prev ?? a.background);
    }
    // The content watermark: the style `--style-pattern` tile, else a
    // content-scoped aura texture (frost's 18px edge snowflakes, :1149-1161).
    final styleWatermark = deco?.watermark;
    final CosmeticAura? contentWatermarkAura = styleWatermark != null
        ? null
        : contentAuras.where((a) => a.watermark != null).fold<CosmeticAura?>(
            null, (prev, a) => prev ?? a);
    final contentWatermark = styleWatermark ?? contentWatermarkAura?.watermark;
    final contentEdgeWatermark = contentWatermarkAura?.edgeWatermark ?? false;
    // Content-scoped aura glows (frost 10px / rainbow 16px / hologram 18px)
    // sit on the content box, as does the overlay painter for the prism ring,
    // hologram sheen and frost/hologram inset rings — the same painter the
    // bubble path uses.
    final contentShadows = <BoxShadow>[
      for (final a in contentAuras)
        if (a.glowColorFor(bubble: false) != null &&
            a.glowBlurFor(bubble: false) > 0)
          BoxShadow(
            color: a.glowColorFor(bubble: false)!,
            blurRadius: a.glowBlurFor(bubble: false),
          ),
    ];
    final contentOverlays = contentAuras.where((a) => a.hasOverlay).toList();
    final contentOverlayAura =
        contentOverlays.isNotEmpty ? contentOverlays.first : null;
    if (contentFill != null ||
        contentWatermark != null ||
        contentShadows.isNotEmpty ||
        contentOverlayAura != null ||
        deco?.contentPadding != null) {
      Widget inner = contentBody;
      if (contentWatermark != null || contentOverlayAura != null) {
        inner = Stack(
          children: [
            if (contentWatermark != null)
              Positioned.fill(
                  child: StyleWatermarkLayer(
                      watermark: contentWatermark,
                      edgeOnly: contentEdgeWatermark)),
            contentBody,
            if (contentOverlayAura != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: CosmeticOverlayPainter(
                      aura: contentOverlayAura,
                      // `.message-content` has no border-radius in IRC (the
                      // `::before`/`::after` `border-radius: inherit` resolves
                      // to 0), so the box is square.
                      radius: BorderRadius.zero,
                      bubble: false,
                      // Drops the hologram iridescent fill + sheen when a
                      // `style-…` class is active (`:not([class*="style-"])
                      // .cosmetic-bubble-hologram`, styles-features.css:
                      // 1203-1211) — the ring/glow stay.
                      styleActive: _styleClassActive,
                    ),
                  ),
                ),
              ),
          ],
        );
      }
      contentBody = Container(
        // Columns mode stretches the content to the column
        // (`.cv-list .message-content { width: 100% }`); in the wrap row the
        // box hugs the content like the PWA's shrink-wrapped satoshi plate.
        width: widget.columnsMode ? double.infinity : null,
        padding: deco?.contentPadding,
        decoration: BoxDecoration(
          color: contentFill,
          boxShadow: contentShadows.isEmpty ? null : contentShadows,
        ),
        // Clip the tiled watermark / painted overlays to the box.
        clipBehavior: (contentWatermark != null || contentOverlayAura != null)
            ? Clip.antiAlias
            : Clip.none,
        child: inner,
      );
    }
    final contentColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        contentBody,
        // Reactions row renders only when reactions OR zaps exist (the PWA
        // `updateMessageReactions` early-returns on an empty reaction set,
        // removing the row entirely unless zaps remain). The zap badge sits
        // at its front; the `.add-reaction-btn` (smiley-plus) is appended at
        // the end but ONLY on rows that already carry reactions — the first
        // react on a bare message is still via long-press quick-react.
        if (reactions.isNotEmpty || _hasZaps)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _reactionsRow(context),
          ),
      ],
    );

    // The `.message` flex-wrap row: time, author, content flow inline
    // (messages.js:936-938). Full-width siblings that the PWA wraps onto their
    // own lines (`.message-translation` width:100%, `.group-readers`/
    // `.channel-readers` flex-basis:100%) are hoisted OUT of the content column
    // into the outer Column below so they span the whole message, right-aligned,
    // rather than being clamped to the content's width.
    //
    // COLUMNS MODE (`body.columns-mode:not(.chat-bubbles) .cv-list .message
    // { flex-direction: column; gap: 5px }`, styles-columns.css:27-49): the
    // flex children are blockified (`display:inline` on time/author computes
    // to block for a flex item), so the row STACKS — time, then author 5px
    // below, then the content 10px below the author (the 5px column gap plus
    // `.message-content { margin-top: 5px }`) at `width: 100%` of the column.
    final Widget messageRow;
    if (widget.columnsMode) {
      messageRow = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (timeItem != null) ...[
            timeItem,
            const SizedBox(height: 5), // `gap: 5px`
          ],
          authorItem,
          // `gap: 5px` + `.message-content { margin-top: 5px }`.
          const SizedBox(height: 10),
          // `.message-content { width: 100% }` — full column width.
          SizedBox(width: double.infinity, child: contentColumn),
        ],
      );
    } else {
      messageRow = Wrap(
        crossAxisAlignment: WrapCrossAlignment.start,
        // `.message { gap: 10px }` — the single-value CSS gap applies to BOTH
        // axes, so wrapped runs are also 10px apart.
        spacing: 10,
        runSpacing: 10,
        children: [
          if (timeItem != null) timeItem,
          authorItem,
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width - 220,
            ),
            child: contentColumn,
          ),
        ],
      );
    }

    // The message body + the full-width siblings the PWA wraps below it. The
    // `.message-translation` (`width:100%`) and `.group-readers`/
    // `.channel-readers` (`flex-basis:100%; justify-content:flex-end`) each take
    // a full-message-width line UNDER the content, right-aligned — not clamped
    // to the content column.
    final rowChildren = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        messageRow,
        // `.edited-indicator-irc { display:block; text-align:right; margin-left:
        // auto }` — the PWA appends `editedIRC` as a TOP-LEVEL sibling AFTER
        // `.message-content` (messages.js:939), so it right-aligns across the
        // WHOLE message row, not just the (possibly short) content column.
        if (message.isEdited)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '(edited)',
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.7),
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        // `.message-translation`: full-width left-primary-bordered block BELOW
        // the message content (a sibling after `.message-content`, width:100%).
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        // `.channel-readers`/`.group-readers`: a FULL-WIDTH, right-aligned row
        // of 14px reader avatars BELOW the message.
        if (_showReaderAvatars) _readerAvatars(context),
        // PM delivery ticks (`.delivery-status`, right-aligned).
        if (self && message.isPM && !message.isGroup) _deliveryTicks(context),
      ],
    );

    // `.message` is radius-12; a self/mention/style-tinted row is a 12px-rounded
    // block. The accent is a `::before` bar 3px × 60% height, vertically
    // centered, `border-radius:0 3px 3px 0`; mentions add a secondary glow.
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: rowWatermarkAura != null
          ? Stack(
              children: [
                Positioned.fill(
                    child: StyleWatermarkLayer(
                        watermark: rowWatermarkAura.watermark!,
                        edgeOnly: rowWatermarkAura.edgeWatermark)),
                rowChildren,
              ],
            )
          : rowChildren,
    );
    // The row-scoped auras' inset ring (gold/neon/phoenix/cosmic — `inset 0 0 0
    // 1px <ring>` on the row) is approximated by a 1px border; the
    // content-scoped rings (frost/hologram) are stroked by the content box's
    // painter above.
    final rowRing = rowAura?.insetColor;
    final rowGlowColor = rowAura?.glowColorFor(bubble: false);
    final rowGlowBlur = rowAura?.glowBlurFor(bubble: false) ?? 0;
    final hasBg = bg != null || bgGradient != null;
    final content = Container(
      // `.message` is a block-level flex row filling `.messages-container` (no
      // shrink-wrap), so it spans the full list width. A full-width row is what
      // lets `.message-translation` (`width:100%`) and the `.group-readers`
      // (`flex-basis:100%`, right-aligned) line up across the whole message
      // rather than clamping to the (possibly short) content.
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgGradient == null ? bg : null,
        // The 135deg gold/aura gradient on the row (`linear-gradient(135deg,…)`).
        gradient: bgGradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bgGradient,
              )
            : null,
        borderRadius: hasBg ? NymRadius.rsm : null,
        // IRC-layout auras add an inset 1px ring + an outer glow on the whole
        // row (`body:not(.chat-bubbles) .message.cosmetic-aura-* { box-shadow:
        // inset 0 0 0 1px <ring>, 0 0 Npx <glow> }`, styles-features.css:1099+).
        // The bubble path routes these through CosmeticOverlayPainter/_decorate
        // Bubble; here we approximate the inset ring with a 1px border.
        border: rowRing != null ? Border.all(color: rowRing, width: 1) : null,
        boxShadow: (rowGlowColor != null && rowGlowBlur > 0)
            ? [BoxShadow(color: rowGlowColor, blurRadius: rowGlowBlur)]
            : null,
      ),
      clipBehavior: hasBg ? Clip.antiAlias : Clip.none,
      child: barColor != null
          ? Stack(
              children: [
                body,
                // 3px × ~60%-height rounded accent bar, vertically centered.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: FractionallySizedBox(
                      heightFactor: 0.6,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                          boxShadow: barGlow != null
                              ? [BoxShadow(color: barGlow, blurRadius: 8)]
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : body,
    );
    // The prism ring / hologram sheen / frost ring are CONTENT-scoped in every
    // layout (`.message.cosmetic-* .message-content`, styles-features.css:
    // 1121-1211) — they're painted by the content box above, so the row itself
    // carries no overlay painter.
    return _SwipeToAct(
      settings: settings,
      onAction: (a) => _dispatchSwipeAction(context, a),
      // Desktop double-click → quote-reply (setupDoubleClickToReply).
      onDoubleTap: _quoteReply,
      // Quick-react popup anchored to the PRESS POINT (ui-context.js:1330).
      onLongPressStart: (d) => _onMessageLongPress(context, d.globalPosition),
      // Desktop right-click → context menu (PWA `contextmenu` handler).
      onSecondaryTap: () => _openContextMenu(context),
      swipeReactEmojiUrl: _swipeReactEmojiUrl,
      child: content,
    );
  }

  // ---- Bubble layout ----
  Widget _buildBubble(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;
    final deco = _styleDecoration(context);
    final mentioned = _isMentionedRow();

    // In bubble mode the CSS applies the message style to `.message-content`
    // (the bubble): a translucent style background plus a soft glow halo.
    final auras = _resolveAuras(context);
    final lastAura = auras.isNotEmpty ? auras.last : null;
    // The aura gradient is painted as the bubble FILL only for auras whose PWA
    // bubble actually has a background (gold). neon/phoenix/cosmic are
    // box-shadow-only in the bubble (their gradient is the IRC row's only), so
    // they must NOT over-paint a fill here (P1#4) — and even gold's wash is
    // gated on NO active message style (`body.chat-bubbles .message:not(
    // [class*="style-"]).cosmetic-aura-gold .message-content`,
    // styles-features.css:3699-3701): a styled bubble keeps only the ring/glow.
    // Ghost + solid-ui flattens EVERY translucent bubble wash — fire/ice/
    // rainbow/satoshi/supporter/aura-gold all go `#2a2a2a !important`
    // (self fire/ice/rainbow `#444444 !important`; light `#dddddd`/`#bbbbbb`)
    // via `body.solid-ui.theme-ghost.chat-bubbles …` (styles-themes-
    // responsive.css:1777-1806), and the (0,4,1) ghost-solid base fill
    // (:1686-1700) also buries frost's (0,4,0) icy wash. Only eclipse/crt's
    // plates and aurora's transparent fill survive: their last-loaded
    // features-sheet rules tie the ghost base at (0,4,1) / carry !important.
    final ghostSolid = c.solidUi && settings.theme == NymThemeKey.ghost;
    final bubbleGradient = (!ghostSolid &&
            lastAura != null &&
            lastAura.bubblePaintsGradient &&
            !_styleClassActive)
        ? lastAura.bubbleFillGradient
        : null;
    // `.message-content` bubble fill. Dark mode: self primary@0.25, others
    // white@0.14. Light mode (`body.light-mode.chat-bubbles`): self primary@0.20,
    // others/PM black@0.10 — a translucent *white* over a light surface is
    // invisible, so the PWA flips others to a dark wash. The style background
    // takes precedence via its BUBBLE-layout resolution (`contentBackgroundFor`):
    // light satoshi's rgba(247,147,26,.12) bubble override
    // (styles-themes-responsive.css:1417-1419) and aurora's fully TRANSPARENT
    // replacement fill (styles-features.css:3675-3686, the gradient clips to the
    // text over a `linear-gradient(transparent, transparent)` border-box layer).
    // The frost flat wash applies only when no message style is active
    // (`.message:not([class*="style-"]).cosmetic-frost`, :1163-1166) — and
    // only on OTHERS' bubbles: the frost rule's specificity (0,4,0, no
    // !important) LOSES to `body.chat-bubbles .message.self .message-content`
    // (0,4,1, styles-features.css:3642-3647), so a SELF frost bubble keeps the
    // primary self fill in both themes. (Gold's wash and hologram's fill carry
    // !important and do apply to self — those flow through [bubbleGradient] /
    // the overlay painter, not here.)
    //
    // SELF + fire/ice: `body.chat-bubbles .message.self.style-fire/.style-ice
    // .message-content { background: rgb(from var(--primary) r g b / 0.25)
    // !important }` (styles-features.css:3708-3711) — five class selectors in
    // the LAST-loaded stylesheet, so it beats the light-mode rgba(0,0,0,.08)
    // fill (themes:1412-1415) and the supporter bubble wash: a self fire/ice
    // bubble keeps primary@0.25 in BOTH themes; only other users' bubbles get
    // the style override.
    //
    // solid-ui widens the self override to RAINBOW and swaps the fill for the
    // opaque `color-mix(in srgb, var(--primary) 22%, #2a2a3a)` plate
    // (`body.solid-ui.chat-bubbles .message.self.style-fire/.style-ice/
    // .style-rainbow .message-content { … !important }`, themes:1708-1711 —
    // 0,6,1, so it even beats the solid gold-aura plate) = `c.bubbleSelfBg`.
    final selfFireIce = self &&
        (_cosmetics.styleId == 'style-fire' ||
            _cosmetics.styleId == 'style-ice' ||
            (c.solidUi && _cosmetics.styleId == 'style-rainbow'));
    // solid-ui gold-aura plate on a STYLED message: `body.solid-ui
    // [.light-mode].chat-bubbles .message.cosmetic-aura-gold .message-content
    // { background: #38311e / #f0e3ad !important }` (themes:1722/:1746) has no
    // `:not([class*="style-"])` gate and outcascades every solid style plate
    // (satoshi/supporter declared earlier at equal specificity; eclipse/crt
    // not !important). Unstyled messages take it via [bubbleGradient] instead
    // (dark keeps the glass wash there — see `_cosmeticAurasSolid`).
    Color? auraStyledFill;
    for (final a in auras) {
      auraStyledFill = a.bubbleStyledFill ?? auraStyledFill;
    }
    final Color bubbleColor;
    if (ghostSolid &&
        !selfFireIce &&
        !(deco?.transparentBubble ?? false) &&
        _cosmetics.styleId != 'style-eclipse' &&
        _cosmetics.styleId != 'style-crt') {
      // Ghost-solid flatten (see [ghostSolid] above): the satoshi/supporter/
      // gold `#2a2a2a !important` group rule (themes:1781-1785, 0,6,1) beats
      // the non-important self `#444444` (:1690), so ONLY an unstyled or
      // fire/ice/rainbow self bubble keeps the self grey.
      final flattenedToOther = _cosmetics.styleId == 'style-satoshi' ||
          _cosmetics.supporter ||
          auras.any((a) => a.id == 'cosmetic-aura-gold');
      bubbleColor =
          (self && !flattenedToOther) ? c.bubbleSelfBg : c.bubbleOtherBg;
    } else if (selfFireIce) {
      // Glass keeps primary@0.25 in BOTH themes (features:3708-3711); solid
      // resolves to the opaque color-mix plate via the theme token.
      bubbleColor = c.solidUi ? c.bubbleSelfBg : c.primaryA(0.25);
    } else if (_styleClassActive && auraStyledFill != null) {
      bubbleColor = auraStyledFill;
    } else {
      // Base fills come from the theme tokens: glass = self primary@0.25/0.20,
      // others white@0.14 / black@0.10; solid-ui = the opaque `#2a2a3a` /
      // `#e6e6e0` (+ color-mix self) plates (themes:1660-1684).
      bubbleColor = deco?.contentBackgroundFor(bubble: true) ??
          (_styleClassActive || self ? null : lastAura?.background) ??
          (self ? c.bubbleSelfBg : c.bubbleOtherBg);
    }
    final radius = _bubbleRadius(self);

    // The bubble interior = the body, THEN the `.bubble-time-inner` (the
    // timestamp sits at the BOTTOM-RIGHT, INSIDE the bubble background, below the
    // content — followed by the crypto lock). The PM `.delivery-status` ticks are
    // NOT here: the PWA emits them as a TOP-LEVEL sibling AFTER `.message-content`
    // (`messages.js:940`, `flex-basis:100%; text-align:right`), so they render as
    // a full-width right-aligned line BELOW the bubble — see [stack] below. The
    // `.message-translation` is likewise a sibling after `.message-content`.
    // The `.bubble-time-inner` line: `(edited)` + relative time + crypto lock.
    // Shrink-wrapped (`width:fit-content`); instantiated twice below — a ghost
    // in the flow and the visible pinned copy.
    final timeLine = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isEdited)
          Text(
            '(edited) ',
            // `.edited-indicator` base (styles-chat.css:1549-1554): 10px
            // italic text-dim AT OPACITY 0.7 — the in-bubble variant
            // (`.bubble-time-inner .edited-indicator`) inherits it.
            style: TextStyle(
                color: c.textDim.withValues(alpha: 0.7),
                fontSize: 10,
                fontStyle: FontStyle.italic),
          ),
        // `.bubble-time-text`: RELATIVE time ("now"/"2m ago"), not clock.
        // Tapping it opens the styled `.timestamp-popup`
        // (showTimestampPopup); hover tints it `--primary`
        // (`.clickable-timestamp:hover`).
        _TimestampText(
          label: formatRelativeTime(message.dateTime),
          fullTimestamp: formatFullTimestamp(
              message.dateTime, settings.timeFormat, settings.dateFormat),
          fontSize: 10,
          height: 1,
        ),
        // `.crypto-lock-bubble`: the verification lock follows the in-bubble
        // time (PM/group only).
        if (_cryptoState != null) CryptoVerifiedBadge(state: _cryptoState!),
      ],
    );
    // `.bubble-time-inner { display:block; width:fit-content; margin-left:
    // auto; margin-top:4px; text-align:right }` — the relative time sits 4px
    // below the body, pinned to the bottom-RIGHT INSIDE the bubble. The bubble
    // itself is `display:inline-block`, i.e. it SHRINK-WRAPS to its content
    // between the 180px floor and the 85%/90% cap — so the time's right-edge
    // pin must not widen it. A bare [Align] would expand to the incoming max
    // cap (stretching every bubble to full width), and [IntrinsicWidth] is off
    // the table because the media gallery's shrink-wrapped [GridView] viewport
    // rejects intrinsic queries. Instead the column flow carries an INVISIBLE
    // ghost of the time line — reserving its exact height, its width joining
    // the shrink-wrap like the PWA's fit-content block — while the visible
    // copy is [Positioned] on the (now content-sized) bubble's bottom-right.
    final innerContent = Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _bodyContent(context, _bitchatColor(c) ?? c.text, fontSize,
                deco: deco, bubble: true),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: IgnorePointer(
                child: Opacity(opacity: 0, child: timeLine),
              ),
            ),
          ],
        ),
        Positioned(right: 0, bottom: 0, child: timeLine),
      ],
    );

    // Re-render the relative time on a cadence (cheap; matches the PWA timer).
    _ensureRelativeTimer();

    final bubble = LayoutBuilder(builder: (context, box) {
      // `.message-content` bubble (`body.chat-bubbles`, styles-features.css:
      // 3603-3615): `min-width: 180px; max-width: 85%` — the ≤768px viewport
      // raises the cap to 90% (styles-themes-responsive.css:1452-1455). The
      // percentage resolves against the `.message` row (the group-stack width
      // this LayoutBuilder sees), NOT the screen — columns mode adds no
      // override of its own, so a column's bubbles cap at 85%/90% of the
      // COLUMN. CSS min-width beats max-width, so a container narrower than
      // the floor never squeezes the cap below 180.
      final screenW = MediaQuery.of(context).size.width;
      final availW = box.maxWidth.isFinite ? box.maxWidth : screenW;
      final pct = screenW <= NymDimens.mobileBreakpoint ? 0.90 : 0.85;
      final capW = (availW * pct).clamp(180.0, double.infinity);
      return ConstrainedBox(
        constraints: BoxConstraints(minWidth: 180, maxWidth: capW),
        child: _decorateBubble(
          radius: radius,
          bubbleColor: bubbleColor,
          // Only gold paints its gradient as the bubble fill; neon/phoenix/
          // cosmic are box-shadow-only in the bubble (gradient is IRC-only).
          gradient: bubbleGradient,
          auras: auras,
          // `.message.mentioned .message-content`: `box-shadow: inset 0 0 0 1px
          // rgb(from var(--secondary) r g b / 0.25)` (styles-features.css:3657)
          // — light mode strokes .2 (themes:1404) — rendered as a 1px inner
          // border on the bubble. solid-ui strokes the FULL secondary
          // (`body.solid-ui[.light-mode].chat-bubbles .message.mentioned
          // .message-content { box-shadow: inset 0 0 0 1px var(--secondary) }`,
          // themes:1669/:1682 — higher specificity than both glass rules).
          mentionRing: mentioned
              ? (c.solidUi
                  ? c.secondary
                  : c.secondaryA(c.isLight ? 0.2 : 0.25))
              : null,
          child: Padding(
            // Default bubble padding 8px 12px 6px (styles-features.css:3607).
            // A style's own `.message-content` padding OUTRANKS it — satoshi's
            // `padding: 10px 15px` (specificity 0,3,0, styles-features.css:
            // 548-549) beats the chat-bubbles rule (0,2,1), so a satoshi
            // bubble is padded 10/15 in BOTH layouts.
            padding: deco?.contentPadding ??
                const EdgeInsets.fromLTRB(12, 8, 12, 6),
            // The 180px floor above lands on the DECORATED box, but the loose
            // Stack inside [_decorateBubble] would let the interior (and the
            // time's right-edge pin) collapse to the body's width. Re-assert
            // the floor on the interior — 180 minus the horizontal padding —
            // so the Positioned time hugs the true right padding edge of a
            // min-width bubble, exactly like `margin-left: auto`.
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  minWidth: 180 - (deco?.contentPadding?.horizontal ?? 24)),
              child: innerContent,
            ),
          ),
        ),
      );
    });

    // `.message-group-stack` (`flex:1 1 auto; min-width:0`, a flex column). It
    // holds the name, the content bubble, then the full-width siblings the PWA
    // wraps below `.message-content`: `.message-translation` (`width:100%`) and
    // `.group-readers`/`.channel-readers` (`flex-basis:100%; justify-content:
    // flex-end`). The column STRETCHES so those span its full width; the
    // shrink-wrapped items (name / bubble / reactions) are re-aligned per side
    // via [sideAlign] (start, or end for self).
    final sideAlign = self ? Alignment.centerRight : Alignment.centerLeft;
    final stack = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showName && !widget.grouped)
          Align(
            alignment: sideAlign,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 2, right: 2),
              child: GestureDetector(
                onTap: () => _openContextMenu(context),
                // Name above the bubble: nym `#suffix` + flair/verified/friend,
                // no `<…>` brackets (bubble hides them).
                child: _authorLine(
                  c,
                  self: self,
                  size: 11,
                  // `.flair-badge { font-size: 20px }` — in-chat flair is 20px.
                  flairSize: 20,
                ),
              ),
            ),
          ),
        Align(
          alignment: sideAlign,
          // Key the rounded bubble (NOT the trailing reactions/translation/
          // receipt rows) so the group avatar can bottom-align to it.
          child: KeyedSubtree(key: widget.bubbleAnchorKey, child: bubble),
        ),
        // PM sent/delivered/read receipt (`.delivery-status`). The PWA emits it as
        // a TOP-LEVEL sibling AFTER `.message-content` (`messages.js:940`), and the
        // base rule `flex-basis:100%; text-align:right; padding-right:4px`
        // (styles-chat.css:665-671) wraps it onto its OWN full-width line BELOW the
        // bubble, right-aligned — NOT inside the bubble next to the time. Identical
        // placement to the IRC layout (which also appends it as a sibling).
        if (self && message.isPM && !message.isGroup) _deliveryTicks(context),
        // `.message-translation`: a full-width left-primary-bordered block BELOW
        // the bubble (a sibling after `.message-content`, NOT inside it).
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        // `.group-readers`/`.channel-readers`: a FULL-WIDTH, right-aligned row of
        // 14px reader avatars below the message.
        if (_showReaderAvatars) _readerAvatars(context),
        if (reactions.isNotEmpty || _hasZaps)
          Align(
            alignment: sideAlign,
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: _reactionsRow(context),
            ),
          ),
      ],
    );

    // `body.chat-bubbles .message.cosmetic-aura-gold { box-shadow: none;
    // background: linear-gradient(135deg, rgba(255,215,0,0.05), transparent) }`
    // (styles-themes-responsive.css:1551-1554): bubble mode ADDITIONALLY paints
    // a faint 135deg gold wash across the whole `.message` ROW behind a
    // gold-aura user's bubble. The rule carries no theme gate and has no light
    // override, so it applies in both themes.
    Widget rowStack = stack;
    if (auras.any((a) => a.id == 'cosmetic-aura-gold')) {
      rowStack = DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0x0DFFD700), // rgba(255,215,0,.05)
              Color(0x00FFD700), // transparent
            ],
          ),
        ),
        child: stack,
      );
    }

    // The swipe / long-press / double-tap surface is the whole `.message` row:
    // the PWA binds `setupSwipeToReply` to `.message` and translates the FULL
    // row — name + bubble + translation + readers + reactions all slide with
    // the finger (messages.js:2165-2214) — not just the rounded bubble. The
    // `.swipe-reply-indicator` chip is likewise positioned off this row's edge.
    final swiped = _SwipeToAct(
      settings: settings,
      onAction: (a) => _dispatchSwipeAction(context, a),
      // Desktop double-click → quote-reply (setupDoubleClickToReply).
      onDoubleTap: _quoteReply,
      // Quick-react popup anchored to the PRESS POINT (ui-context.js:1330).
      onLongPressStart: (d) => _onMessageLongPress(context, d.globalPosition),
      // Desktop right-click → context menu (PWA `contextmenu` handler).
      onSecondaryTap: () => _openContextMenu(context),
      avatarDx: widget.swipeAvatarDx,
      swipeReactEmojiUrl: _swipeReactEmojiUrl,
      child: rowStack,
    );

    // `bubble-snap-in` (styles-features.css:3453-3471): a newly-appended
    // consecutive bubble enters with a 240ms cubic-bezier(0.34,1.56,0.64,1)
    // overshoot — translateY(-6px)/scale(0.94)/opacity 0 → an over-shot
    // +2px/1.02 at 55% → settle. Transform-origin bottom-left, bottom-right for
    // self; disabled under `prefers-reduced-motion: reduce`.
    Widget rowBody = swiped;
    if (_snapIn && !MediaQuery.of(context).disableAnimations) {
      rowBody = _BubbleSnapIn(self: self, child: rowBody);
    }

    // Per-message vertical rhythm. The PWA tightly stacks a group's bubbles and
    // separates groups by ~6px: `.message { margin-bottom: 6px }` for a group
    // lead, while a `.bubble-grouped` member uses `margin-top: -4px` (the first
    // grouped after the lead `-8px`) for a ~2px in-group gap. Flutter list items
    // can't carry negative inter-item margins, so the equivalent EFFECTIVE gaps
    // are driven from the top edge only (bottom 0): a group lead opens 6px of
    // air above it; a continuation member sits 2px below the previous bubble.
    final vPad = EdgeInsets.only(top: widget.grouped ? 2 : 6);

    // Rendered inside a [MessageGroup]: emit ONLY the content stack with its
    // vertical rhythm. The group owns the `.message-group` horizontal padding
    // and the single gliding [_StickyGroupAvatar], laying every bubble of the
    // run in one `.message-group-stack` column beside it.
    if (widget.inGroup) {
      return Padding(padding: vPad, child: rowBody);
    }

    // Legacy standalone path (direct [MessageRow] use, not via [MessageGroup]):
    // a self-contained `.message-group` row carrying its own 32px avatar.
    // Horizontal inset mirrors `.message-group` padding: an others' group is
    // `padding: 0 14px 0 6px` (the 32px avatar starts 6px from the edge), a
    // self group is `padding: 0 14px` (`group-self`, row-reversed, no avatar).
    final row = Row(
      mainAxisAlignment:
          self ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!self) ...[
          SizedBox(
            width: 32,
            child: widget.showAvatar
                ? GestureDetector(
                    onTap: () => _openContextMenu(context),
                    child: NymAvatar(
                        seed: message.pubkey,
                        size: 32,
                        imageUrl: _authorPicture),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(child: rowBody),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(self ? 14 : 6, widget.grouped ? 2 : 6, 14, 0),
      child: row,
    );
  }

  /// Wraps the bubble [child] with the style glow + cosmetic-aura box-shadows,
  /// an optional aura background gradient, a tiled watermark behind the content,
  /// and the prism-ring / hologram overlays painted above it. Everything is
  /// clipped to the bubble [radius].
  Widget _decorateBubble({
    required BorderRadius radius,
    required Color bubbleColor,
    required List<Color>? gradient,
    required List<CosmeticAura> auras,
    required Widget child,
    Color? mentionRing,
  }) {
    // NOTE: no bubble box-shadow is derived from the message STYLE. The PWA
    // style glow is a `text-shadow` on the glyphs only (`.message.style-X
    // .message-content { text-shadow }`, styles-features.css) — no
    // `.message-content` box-shadow exists for any style, in either theme.
    // Painting `deco.glow` here as a BoxShadow bled the (high-alpha, e.g.
    // fire's rgba(255,160,0,.8)) shadow rect through the translucent bubble
    // fill, turning the whole dark-mode bubble into an opaque orange blob
    // with a huge halo. The glyph glow renders via [MessageStyleDecoration.
    // textShadows] in `_content`. Only cosmetic AURAS cast bubble box-shadows.
    final shadows = <BoxShadow>[];
    for (final a in auras) {
      // Inset ring (approximated as a tight 0-blur spread inside the box via a
      // border below) + the outer glow at the bubble's colour + blur (light
      // gold: 10px rgba(180,140,0,.15), themes:929-932 — not the IRC .12/12px).
      final blur = a.glowBlurFor(bubble: true);
      final glowColor = a.glowColorFor(bubble: true);
      if (glowColor != null && blur > 0) {
        shadows.add(BoxShadow(color: glowColor, blurRadius: blur));
      }
    }
    // The strongest inset ring (last aura) is drawn as a hairline inner border
    // ONLY when the overlay painter isn't already stroking it: `insetRing` auras
    // route through `CosmeticOverlayPainter` (via `hasOverlay`), so drawing the
    // border here too would double the ring (gold/neon/phoenix/cosmic/frost).
    final lastAura = auras.isNotEmpty ? auras.last : null;
    final inset =
        (lastAura != null && lastAura.insetColor != null && !lastAura.hasOverlay)
            ? lastAura
            : null;

    // Watermark from the active style or a frost/cosmic aura — and whether that
    // watermark tiles edge-only (frost) rather than across the whole box. The
    // cosmic BUBBLE starfield only tiles when no message style is active
    // (`body.chat-bubbles .message:not([class*="style-"]).cosmetic-aura-cosmic
    // .message-content`, styles-features.css:1192-1195); frost's edge snowflakes
    // (`.cosmetic-frost .message-content::after`, :1149-1161) carry no such gate.
    final styleWatermark = _styleDecoration(context)?.watermark;
    final CosmeticAura? auraWatermark = styleWatermark != null
        ? null
        : auras
            .where((a) =>
                a.watermark != null &&
                (a.edgeWatermark || !_styleClassActive))
            .fold<CosmeticAura?>(null, (prev, a) => prev ?? a);
    final watermark = styleWatermark ?? auraWatermark?.watermark;
    final edgeWatermark = auraWatermark?.edgeWatermark ?? false;

    final overlays =
        auras.where((a) => a.hasOverlay).toList();
    final overlayAura = overlays.isNotEmpty ? overlays.first : null;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? bubbleColor : null,
        gradient: gradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient,
              )
            : null,
        borderRadius: radius,
        // The aura inset ring takes precedence; otherwise a @-mention bubble
        // gets a 1px secondary@0.25 inner ring.
        border: inset?.insetColor != null
            ? Border.all(color: inset!.insetColor!, width: inset.insetWidth)
            : (mentionRing != null
                ? Border.all(color: mentionRing, width: 1)
                : null),
        boxShadow: shadows.isEmpty ? null : shadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            if (watermark != null)
              Positioned.fill(
                  child: StyleWatermarkLayer(
                      watermark: watermark, edgeOnly: edgeWatermark)),
            child,
            if (overlayAura != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: CosmeticOverlayPainter(
                      aura: overlayAura,
                      radius: radius,
                      // Drops the hologram iridescent fill + sheen when a
                      // `style-…` class is active (`:not([class*="style-"])
                      // .cosmetic-bubble-hologram`, styles-features.css:
                      // 1203-1211) — only the ring/glow remain.
                      styleActive: _styleClassActive,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// True when this own message should show the stacked reader-avatar delivery
  /// indicator (own channel or own group message with readers) instead of the
  /// PM tick glyph. (`messages.js:824-847`.)
  bool get _showReaderAvatars =>
      message.isOwn &&
      !message.isPM &&
      (message.isGroup || _isChannelMessage) &&
      message.readers.isNotEmpty;

  /// A channel message: not a PM, not a group, with a geohash set and a
  /// canonical 64-hex EVENT id (the PWA gate `message.geohash && message.id &&
  /// /^[0-9a-f]{64}$/i.test(message.id)`, messages.js:826-828).
  bool get _isChannelMessage {
    if (message.isPM || message.isGroup) return false;
    if ((message.geohash ?? '').isEmpty) return false;
    return RegExp(r'^[0-9a-f]{64}$', caseSensitive: false)
        .hasMatch(message.id);
  }

  /// A right-aligned row of up to 3 overlapping 14px reader avatars + a `+N`
  /// overflow, mirroring `_buildGroupReadersHtmlFromMap` (`groups.js:2624-2641`)
  /// and `.group-readers`/`.group-reader-avatar` (`styles-chat.css:612-654`).
  /// Long-press opens a "seen by" modal.
  Widget _readerAvatars(BuildContext context) {
    const maxVisible = 3;
    final entries = message.readers.entries.toList();
    final visible = entries.take(maxVisible).toList();
    final overflow = entries.length - visible.length;
    final c = context.nym;
    final users = ref.watch(usersProvider);
    return GestureDetector(
      onLongPress: () {
        // The PWA buzzes (nymHapticTap = 30ms vibrate) as the 500ms reader
        // long-press fires (groups.js:2759-2763, 2806-2810). A real 30ms
        // motor pulse reads as a solid tap — mediumImpact, not the barely
        // perceptible lightImpact.
        HapticFeedback.mediumImpact();
        _showSeenBy(context);
      },
      child: Padding(
        padding: const EdgeInsets.only(top: 3, right: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.max,
          children: [
            for (var i = 0; i < visible.length; i++)
              Transform.translate(
                offset: Offset(i == 0 ? 0 : -5.0 * i, 0),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 1.5),
                  ),
                  child: Opacity(
                    opacity: 0.85,
                    child: NymAvatar(
                      seed: visible[i].key,
                      size: 14,
                      imageUrl: users[visible[i].key]?.profile?.picture,
                    ),
                  ),
                ),
              ),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(
                  '+${abbreviateNumber(overflow)}',
                  style: TextStyle(
                      color: c.textDim, fontSize: 9, height: 14 / 9),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showSeenBy(BuildContext context) {
    final users = ref.read(usersProvider);
    final reactors = <ReactorEntry>[
      for (final e in message.readers.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: _baseNym(e.value),
          suffix: getPubkeySuffix(e.key),
          imageUrl: users[e.key]?.profile?.picture,
        ),
    ];
    // Reuse the reactors modal as the "seen by" list (mirror the PWA's readers
    // modal); the 👁 glyph in the header reads as "seen by N".
    showReactorsModal(
      context,
      anchorRect: _globalRectOfContext(context) ?? Rect.zero,
      emoji: '👁',
      reactors: reactors,
      // "Click user row to open their context menu" (`_showReadersModalFromMap`,
      // groups.js:2861-2869): close the modal, then
      // `showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, false)`.
      onTapReactor: (r) => _openReactorContextMenu(context, r),
    );
  }

  // ---- reactions row ----
  Widget _reactionsRow(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // The `⚡ N` zap badge + quick-zap button are inserted at the FRONT of
        // the row (`updateMessageZaps` insertBefore firstChild). Renders nothing
        // until the message has zaps.
        ZapBadge(message: message),
        for (final r in reactions)
          _ReactionBadge(
            messageId: message.id,
            reaction: r,
            onTap: (rect) => _toggleReaction(context, r),
            onLongPress: (rect) => _showReactors(context, r, rect),
          ),
        // The `.add-reaction-btn` (a smiley-plus glyph) is appended at the END
        // of the row, AFTER the reaction badges (`reactions.js:569-581`). The
        // PWA only renders it on rows that already carry reactions — its
        // `updateMessageReactions` early-returns and strips the button when the
        // reaction set is empty (`reactions.js:440-453`), so it is NOT drawn for
        // zero-reaction or zap-only rows. Clicking it opens the full emoji
        // picker (`showEnhancedReactionPicker`) → `widget.onReactionPicker`.
        if (reactions.isNotEmpty && widget.onReactionPicker != null)
          _AddReactionButton(
            onTap: () => widget.onReactionPicker?.call(message),
          ),
      ],
    );
  }

  void _toggleReaction(BuildContext context, MessageReaction r) {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final kind = inferOriginalKind(message, view: view);
    final wasReacted = r.userReacted;
    // toggleReaction applies its optimistic local update synchronously (before
    // its first await); the signing/encryption/publish continues unawaited.
    unawaited(controller.toggleReaction(
      message.id,
      r.emoji,
      target: reactionTargetFor(message),
      kind: kind,
    ));
    // Buzz + burst on add (not removal) the INSTANT the reaction lands in
    // local state — the PWA fires `nymHapticTap` and `_burstOnBadge` right
    // after the optimistic add, BEFORE any network publish (reactions.js:
    // 955-977). Re-reading state confirms the add went through (a rate-limited
    // toggle skips the local update and stays silent, reactions.js:946).
    if (!wasReacted && _selfReactedLocally(r.emoji)) {
      HapticFeedback.mediumImpact();
      // Anchor at the reaction badge for this emoji once the optimistic add
      // has laid it out (post-frame), falling back to the message centre —
      // `_burstOnBadge(messageId, emoji, messageEl)`, reactions.js:977.
      ReactionBurst.playAtBadge(context, message.id, r.emoji,
          fallbackCenter: _globalCenterOfContext(context));
    }
  }

  /// True when local state now carries our own [emoji] reaction on this
  /// message — i.e. `toggleReaction`'s optimistic add actually happened.
  bool _selfReactedLocally(String emoji) {
    final list = ref.read(appStateProvider).reactions[message.id] ?? const [];
    return list.any((x) => x.emoji == emoji && x.userReacted);
  }

  void _showReactors(BuildContext context, MessageReaction r, Rect rect) {
    // Long-press on a reaction badge buzzes before the reactors modal opens
    // (`nymHapticTap` = a 30ms vibrate, reactions.js:526).
    HapticFeedback.mediumImpact();
    // The real reactor map (`reactorsFor` → pubkey → nym), each row carrying its
    // avatar picture so the modal loads faces (mirrors `showReactorsModal`).
    final app = ref.read(appStateProvider);
    final users = ref.read(usersProvider);
    final map =
        ref.read(appStateProvider.notifier).reactorsFor(message.id, r.emoji) ??
            const {};
    // Resolve any reactor we lack an avatar for (e.g. reactions restored from
    // cache, never seen live) — the PWA's `ensureListProfiles` on the reactor
    // list. Debounced/guarded; faces fill in on the next open.
    ref.read(nostrControllerProvider).ensureProfiles(map.keys);
    final reactors = <ReactorEntry>[
      for (final e in map.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: _baseNym(e.value),
          suffix: getPubkeySuffix(e.key),
          isYou: e.key == app.selfPubkey,
          imageUrl: users[e.key]?.profile?.picture,
        ),
    ];
    showReactorsModal(
      context,
      anchorRect: rect,
      emoji: r.emoji,
      reactors: reactors,
      // "Click user row to open their context menu" (`showReactorsModal`,
      // reactions.js:656-663): the modal closes itself, then the PWA calls
      // `showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, false)`.
      onTapReactor: (entry) => _openReactorContextMenu(context, entry),
    );
  }

  /// Opens a reactor/reader row's user context menu — the PWA's
  /// `showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, false)`
  /// (reactions.js:656-663, groups.js:2861-2869): no message/content attached
  /// and NOT profile-only.
  void _openReactorContextMenu(BuildContext context, ReactorEntry r) {
    final app = ref.read(appStateProvider);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: r.pubkey,
        nym: r.nym,
        isSelf: r.pubkey == app.selfPubkey,
      ),
    );
  }

  void _onMessageLongPress(BuildContext context, Offset at) {
    // The PWA buzzes as the quick-react popup is built (`nymHapticTap` = a
    // 30ms vibrate, ui-context.js:1279); a raw long-press is otherwise silent.
    HapticFeedback.mediumImpact();
    // The popup centers on the PRESS POINT (clientX/clientY), 55px above the
    // finger (ui-context.js:1330-1347) — NOT on the message rect. A zero-size
    // anchor at the touch point reproduces `left = clientX - w/2, top =
    // clientY - 55` exactly.
    final rect = Rect.fromCenter(center: at, width: 0, height: 0);
    // Quick-react row = recents-first, padded with the six defaults
    // (`_messageQuickReactDefaults`), deduped (ctx-menu F7).
    final recents = ref.read(recentEmojisProvider);
    showQuickReactPopup(
      context,
      anchorRect: rect,
      // The dim-scrim spotlight cutout is the PRESSED MESSAGE's bounds (the
      // `.long-press-highlight` row stays bright while the scroller dims,
      // styles-features.css:2848-2863) — distinct from the press-point anchor
      // the pill positions against.
      spotlightRect: _globalRectOfContext(context),
      emojis: quickReactEmojis(recents),
      onReact: (emoji) => _quickReact(context, emoji),
      onMore: () => widget.onReactionPicker?.call(message),
      // The PWA long-press surface also carries the labelled quick actions
      // (Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete) below the emoji pill.
      contextItems: buildQuickContextItems(
        context,
        ref,
        message,
        onTranslate: () => setState(() => _showTranslation = true),
        onEdit: () => ref.read(pendingEditProvider.notifier).request(
              messageId: message.id,
              content: message.content,
            ),
      ),
    );
  }

  void _quickReact(BuildContext context, String emoji) {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final already = reactions.any((r) => r.emoji == emoji && r.userReacted);
    // Record the pick into the shared recents store (reactions.js bump).
    ref.read(recentEmojisProvider.notifier).record(emoji);
    unawaited(controller.toggleReaction(
      message.id,
      emoji,
      target: reactionTargetFor(message),
      kind: inferOriginalKind(message, view: view),
    ));
    // Buzz + burst with the optimistic local add, BEFORE any signing/publish
    // (`nymHapticTap` + `_burstOnBadge`, reactions.js:955-977).
    if (!already && _selfReactedLocally(emoji)) {
      HapticFeedback.mediumImpact();
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, emoji);
    }
  }

  /// Resolves `settings.swipeReactEmoji` to a custom-emoji image URL when it
  /// is a known `:shortcode:` — the swipe ACTIONS 'react' icon renders the
  /// custom-emoji IMAGE in that case (messages.js:2066-2074). Null → the text
  /// glyph. Exact-case lookup, like the PWA's `customEmojis.has(m[1])`.
  String? get _swipeReactEmojiUrl {
    final m =
        RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(settings.swipeReactEmoji);
    if (m == null) return null;
    final code = m.group(1)!;
    return ref.watch(liveCustomEmojiProvider.select((s) => s.codeToUrl[code]));
  }

  /// Runs the committed swipe action (`_getSwipeActionConfig(action).run`,
  /// messages.js:2031-2126). Mirrors the long-press quick-context dispatch
  /// (`buildQuickContextItems`) so swipe and menu share identical engine paths:
  /// `quote` → composer mailbox, `translate` → inline render, `copy` → clipboard
  /// + system confirm, `react` → the configured swipe emoji, `zap` → zap modal,
  /// `slap`/`hug` → the rate-limited `/me` command, `none` → no-op.
  void _dispatchSwipeAction(BuildContext context, String action) {
    final controller = ref.read(nostrControllerProvider);
    final baseNym = _baseNym(message.author);
    final fullNym = '$baseNym#${getPubkeySuffix(message.pubkey)}';
    switch (action) {
      case 'quote':
        if (message.content.isEmpty) return;
        ref
            .read(pendingComposerActionProvider.notifier)
            .requestQuote(fullNym: fullNym, content: message.content);
        return;
      case 'translate':
        if (message.content.isEmpty) return;
        setState(() => _showTranslation = true);
        return;
      case 'copy':
        if (message.content.isEmpty) return;
        Clipboard.setData(ClipboardData(text: message.content));
        ref
            .read(appStateProvider.notifier)
            .addSystemMessage('Message copied to clipboard');
        return;
      case 'react':
        _quickReact(context, settings.swipeReactEmoji);
        return;
      case 'zap':
        if (message.pubkey.isEmpty) return;
        // Zapping your own message prints a system notice rather than
        // silently no-opping (messages.js:2090-2093).
        if (message.isOwn) {
          ref
              .read(appStateProvider.notifier)
              .addSystemMessage('Cannot zap your own message');
          return;
        }
        _zapMessage(context, baseNym);
        return;
      case 'slap':
        if (message.isOwn || message.pubkey.isEmpty) return;
        controller.sendCurrent(
            '/me slaps @$fullNym around a bit with a large trout 🐟');
        return;
      case 'hug':
        if (message.isOwn || message.pubkey.isEmpty) return;
        controller.sendCurrent('/me gives @$fullNym a warm hug 🫂');
        return;
      case 'none':
      default:
        return;
    }
  }

  /// Opens the zap modal for this message's author (the swipe `zap` action,
  /// messages.js:2086-2106): posts the PWA's "Checking if @X can receive
  /// zaps..." system note, does a FRESH lightning-address resolve
  /// (`fetchLightningAddressForUser` — cache first, then a kind-0 profile
  /// fetch awaited up to 4s) rather than trusting the local cache, then either
  /// opens the modal, reports "cannot receive zaps", or — on a resolve error —
  /// "Failed to check if @X can receive zaps".
  Future<void> _zapMessage(BuildContext context, String baseNym) async {
    final notifier = ref.read(appStateProvider.notifier);
    notifier.addSystemMessage('Checking if @$baseNym can receive zaps...');
    final String? lnAddr;
    try {
      lnAddr = await ref
          .read(nostrControllerProvider)
          .resolveLightningAddressForZap(message.pubkey);
    } catch (_) {
      notifier.addSystemMessage('Failed to check if @$baseNym can receive zaps');
      return;
    }
    if (lnAddr == null || lnAddr.isEmpty) {
      notifier.addSystemMessage(
          '@$baseNym cannot receive zaps (no lightning address set)');
      return;
    }
    if (!context.mounted || !mounted) return;
    await ZapModal.show(
      context,
      recipientPubkey: message.pubkey,
      recipientNym: baseNym,
      lightningAddress: lnAddr,
      messageId: message.id,
      originalKind:
          inferOriginalKind(message, view: ref.read(currentViewProvider)),
    );
  }

  /// The quote-reply dispatch shared by double-tap-to-reply (desktop,
  /// `setupDoubleClickToReply`, messages.js:2280-2307) and the swipe `quote`
  /// action — sets the composer quote preview to this message.
  void _quoteReply() {
    if (message.content.isEmpty) return;
    final baseNym = _baseNym(message.author);
    final fullNym = '$baseNym#${getPubkeySuffix(message.pubkey)}';
    ref
        .read(pendingComposerActionProvider.notifier)
        .requestQuote(fullNym: fullNym, content: message.content);
  }

  void _openContextMenu(BuildContext context) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(message, selfPubkey: app.selfPubkey);
    ContextMenuPanel.show(
      context,
      target: target,
      message: message,
      onReact: () => widget.onReactionPicker?.call(message),
      onTranslateInline: (lang) => setState(() {
        _translateLangOverride = lang;
        _showTranslation = true;
      }),
    );
  }

  // ---- helpers ----
  Rect? _globalRectOfContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  Offset? _globalCenterOfContext(BuildContext context) {
    final r = _globalRectOfContext(context);
    return r?.center;
  }

  String _baseNym(String nym) {
    final hash = nym.indexOf('#');
    return hash > 0 ? nym.substring(0, hash) : nym;
  }

  BorderRadius _bubbleRadius(bool self) {
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    if (widget.grouped) return const BorderRadius.all(r);
    if (self) {
      return const BorderRadius.only(
        topLeft: r,
        topRight: tail,
        bottomLeft: r,
        bottomRight: r,
      );
    }
    return const BorderRadius.only(
      topLeft: tail,
      topRight: r,
      bottomLeft: r,
      bottomRight: r,
    );
  }

  /// Renders the message body through the rich formatter pipeline, tinted by the
  /// author's active message style ([deco]) when present.
  ///
  /// The style's glyph colour is threaded via [MessageContent.baseColor]; a
  /// gradient style (aurora) clips the text with a `ShaderMask`. The per-glyph
  /// `text-shadow` glow can't be pushed through `MessageContent`, so the glow is
  /// rendered as the bubble/row halo instead (see TODO(verify) in the report).
  /// Whether to blur this message's images: never for own messages; otherwise
  /// per the `blurOthersImages` setting (`true` → always, `friends` → only when
  /// the sender isn't a friend). Mirrors `messages.js:1267-1274`.
  bool _shouldBlurImages() {
    if (message.isOwn) return false;
    final setting = ref.read(settingsProvider.notifier).blurImages;
    if (setting == 'true') return true;
    if (setting == 'friends') {
      return !ref.read(appStateProvider).isFriend(message.pubkey);
    }
    return false;
  }

  Widget _content(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
    bool bubble = false,
  }) {
    final blur = _shouldBlurImages();
    final body = MessageContent(
      content: message.content,
      // fire/ice paint a brighter glyph in the bubble than IRC (`#ff6600`/
      // `#00ccff` vs `#ffaa00`/`#00ccee`) — `textColorFor` returns the override.
      baseColor: deco?.textColorFor(bubble: bubble) ?? color,
      fontSize: fontSize,
      blurImages: blur,
      glyphShadows: deco?.textShadows,
      monospace: deco?.monospace ?? false,
    );
    final gradient = deco?.gradient;
    if (gradient != null && gradient.length >= 2) {
      // `.message.style-aurora .message-content` clips a gradient to the text,
      // at 120deg (diagonal, lower-left → upper-right), with a blue glow behind
      // it (`text-shadow 0 0 10px rgba(91,140,255,.3)`). srcIn would clip a glyph
      // shadow away, so the glow is a separate shadow-only copy painted under it.
      final clipped = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          // 120deg ≈ lower-left → upper-right diagonal.
          begin: const Alignment(-0.87, 0.5),
          end: const Alignment(0.87, -0.5),
          colors: gradient,
        ).createShader(rect),
        child: MessageContent(
          content: message.content,
          baseColor: Colors.white,
          fontSize: fontSize,
          blurImages: blur,
        ),
      );
      final glow = deco?.gradientGlow;
      if (glow == null) return clipped;
      return Stack(
        children: [
          // The blue glow halo: transparent glyphs whose only paint is the
          // shadow, sitting behind the gradient-clipped text.
          MessageContent(
            content: message.content,
            baseColor: const Color(0x00000000),
            fontSize: fontSize,
            blurImages: false,
            glyphShadows: [glow],
          ),
          clipped,
        ],
      );
    }
    return body;
  }

  /// The full-width PM `.delivery-status` line below the message: right-aligned,
  /// `margin-top:2px; padding-right:4px` (styles-chat.css:665-671). Shared by the
  /// IRC and bubble layouts (both append it as a sibling after the content).
  Widget _deliveryTicks(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, right: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: _ticksGlyph(context),
      ),
    );
  }

  Widget _ticksGlyph(BuildContext context) {
    final c = context.nym;
    // Glyphs + colors are a 1:1 port of messages.js:837-844 and the
    // `.delivery-status` rules in styles-chat.css:673-686 (those colors are
    // hard-coded hex, not theme vars):
    //   read      → "✓✓" #2196F3 (blue)
    //   delivered → "✓"  #4CAF50 (green)   ← single tick, not double
    //   sent      → "✓"  --text-dim
    //   failed    → "!"  #f44336 (danger)
    // The PWA renders nothing for any other status (e.g. a pending "sending"),
    // so we emit an empty widget rather than an ellipsis.
    String glyph;
    Color color;
    switch (message.deliveryStatus) {
      case DeliveryStatus.read:
        glyph = '✓✓';
        color = const Color(0xFF2196F3);
        break;
      case DeliveryStatus.delivered:
        glyph = '✓';
        color = const Color(0xFF4CAF50);
        break;
      case DeliveryStatus.sent:
        glyph = '✓';
        color = c.textDim;
        break;
      case DeliveryStatus.failed:
        // `.delivery-status.failed { color:#f44336; cursor:pointer; font-weight:
        // bold }` (styles-chat.css:685-689); the PWA renders the `!` as a
        // clickable retry affordance (`<span … nm-pointer title="Failed to send
        // - click to retry" data-retry-event-id>`, messages.js:842) wired to
        // `manualRetryDM(message.id)` (ui-context.js:851-855). Tap drops the
        // failed bubble and re-sends a fresh copy — see [_retryFailedPm].
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _retryFailedPm,
            child: Tooltip(
              message: 'Failed to send - click to retry',
              child: Text(
                '!',
                style: TextStyle(
                  color: c.danger,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        );
      case DeliveryStatus.sending:
        return const SizedBox.shrink();
    }
    return Text(
      glyph,
      style: TextStyle(color: color, fontSize: 10, height: 1),
    );
  }

  /// Manually re-sends a failed PM (PWA `manualRetryDM`, pms.js:179-196): drop
  /// the failed bubble, ensure the PM thread with the original recipient is the
  /// active view, then send a fresh copy of its content. The recipient is the
  /// message's stored peer (`conversationPubkey`, populated for own PMs at
  /// app_state.dart:2481), falling back to the active PM view's peer (the PWA's
  /// `msg.conversationPubkey || this.currentPM`).
  void _retryFailedPm() {
    final content = message.content;
    if (content.trim().isEmpty) return;
    final view = ref.read(currentViewProvider);
    final peer = message.conversationPubkey ??
        (view.kind == ViewKind.pm ? view.id : null);
    if (peer == null || peer.isEmpty) return;
    final appState = ref.read(appStateProvider.notifier);
    final controller = ref.read(nostrControllerProvider);
    // Remove the failed bubble before re-sending so the retry produces a single
    // fresh optimistic echo (mirrors the PWA splice + re-`sendPM`).
    appState.removeMessage(message.id);
    // Make the recipient's PM thread the active view, then send — `sendCurrent`
    // publishes to whatever view is current (nostr_controller.dart:2113), and
    // `startPM` opens/switches to it (nostr_controller.dart:2720).
    controller.startPM(peer);
    controller.sendCurrent(content);
  }
}

/// A single `.reaction-badge` pill. Tappable (toggle) with a long-press to show
/// the reactor list; reports its global bounds to the callbacks for anchoring.
/// User-reacted badges get a soft glow halo (`box-shadow 0 0 10px primary@0.1`)
/// and the pill presses/pops on tap (`active scale(0.95)`). Desktop hover lifts
/// it (`.reaction-badge:hover`, styles-chat.css:429-433: primary@0.08 bg,
/// primary@0.3 border, scale 1.05); the later-in-sheet `.user-reacted` rule
/// keeps its own bg/border on hover, so only the lift applies then. No hover
/// tooltip: the `[title]:hover::after` reactor-names rule is dead CSS — the PWA
/// never sets a `title` on badges ("No tooltip — long-press shows reactors
/// modal instead", reactions.js:512).
class _ReactionBadge extends StatefulWidget {
  const _ReactionBadge({
    required this.messageId,
    required this.reaction,
    required this.onTap,
    required this.onLongPress,
  });
  final String messageId;
  final MessageReaction reaction;
  final void Function(Rect) onTap;
  final void Function(Rect) onLongPress;

  @override
  State<_ReactionBadge> createState() => _ReactionBadgeState();
}

class _ReactionBadgeState extends State<_ReactionBadge> {
  bool _pressed = false;
  bool _hover = false;

  /// Registered with [ReactionBurst] so bursts anchor at THIS badge — the
  /// PWA's `_burstOnBadge` badge query (reactions.js:50-52).
  final GlobalKey _anchorKey = GlobalKey();

  /// Last seen count/own-flag, for the live-increment self-burst below.
  int _lastCount = -1;
  bool _lastUserReacted = false;

  @override
  void initState() {
    super.initState();
    ReactionBurst.registerBadge(
        widget.messageId, widget.reaction.emoji, _anchorKey);
    _lastCount = widget.reaction.count;
    _lastUserReacted = widget.reaction.userReacted;
  }

  @override
  void didUpdateWidget(covariant _ReactionBadge old) {
    super.didUpdateWidget(old);
    if (old.messageId != widget.messageId ||
        old.reaction.emoji != widget.reaction.emoji) {
      ReactionBurst.unregisterBadge(
          old.messageId, old.reaction.emoji, _anchorKey);
      ReactionBurst.registerBadge(
          widget.messageId, widget.reaction.emoji, _anchorKey);
      _lastCount = widget.reaction.count;
      _lastUserReacted = widget.reaction.userReacted;
      return;
    }
    // Burst when ANOTHER user's live reaction ticks this badge up while it is
    // mounted (the PWA bursts on the badge for live inbound reactions,
    // reactions.js:328-332). Our OWN adds are excluded (userReacted flips in
    // the same update) — those burst from the toggle call sites, which anchor
    // here via the registry.
    final r = widget.reaction;
    if (_lastCount >= 0 &&
        r.count > _lastCount &&
        r.userReacted == _lastUserReacted) {
      ReactionBurst.playAtBadge(context, widget.messageId, r.emoji);
    }
    _lastCount = r.count;
    _lastUserReacted = r.userReacted;
  }

  @override
  void dispose() {
    ReactionBurst.unregisterBadge(
        widget.messageId, widget.reaction.emoji, _anchorKey);
    super.dispose();
  }

  Rect _rect(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Whole-string `:shortcode:` — only this shape can become a custom-emoji
  /// image in a badge (`renderReactionEmoji`, emoji.js:342-351).
  static final RegExp _rxWholeToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final r = widget.reaction;
    return RawGestureDetector(
      key: _anchorKey,
      // The PWA cancels the badge's pending 500ms reactors-modal hold on the
      // FIRST `touchmove` (reactions.js:543-549) — the same tight pre-fire
      // slop as the message quick-react hold — so a slow scroll started on a
      // badge never pops the modal. A plain `onLongPress` would tolerate the
      // framework's ~18px kTouchSlop drift instead.
      gestures: <Type, GestureRecognizerFactory>{
        _TightLongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
            _TightLongPressGestureRecognizer>(
          () => _TightLongPressGestureRecognizer(debugOwner: this),
          (rec) => rec
            ..onLongPressStart = (_) => widget.onLongPress(_rect(context)),
        ),
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => widget.onTap(_rect(context)),
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            // `:active scale(0.95)` beats `:hover scale(1.05)` (later in sheet).
            // `.reaction-badge { transition: all 0.2s }` — 200ms CSS-default
            // `ease`, and the bg/border animate too (AnimatedContainer below).
            scale: _pressed ? 0.95 : (_hover ? 1.05 : 1.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.ease,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.ease,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                // `.user-reacted` (439-443) sits AFTER `:hover` (429-433) at
                // equal specificity, so its bg/border win while hovered.
                color: r.userReacted
                    ? c.primaryA(0.12)
                    : (_hover
                        ? c.primaryA(0.08)
                        : Colors.white.withValues(alpha: 0.05)),
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                border: Border.all(
                  color: r.userReacted
                      ? c.primaryA(0.35)
                      : (_hover ? c.primaryA(0.3) : c.glassBorder),
                ),
                boxShadow: r.userReacted
                    ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 10)]
                    : null,
              ),
              // Count abbreviated (`abbreviateNumber`, e.g. `1.2k`). The badge label
              // stays `--text` even when user-reacted (only bg/border/glow change —
              // `styles-chat.css:439-443`). The emoji goes through the PWA's
              // `renderReactionEmoji` semantics (emoji.js:342-351): ONLY an exact
              // `:shortcode:` reaction can render as its custom-emoji image, at the
              // `.custom-emoji-reaction` size of 1.45em of the 12px badge font
              // (styles-chat.css:854-859, margin 0). The pill lays out as
              // `display:flex; align-items:center; gap:3px` — with an image the
              // count is a separate flex item 3px away; with plain text the PWA's
              // text nodes merge into one `"emoji count"` run, so render that as a
              // single Text.
              child: _rxWholeToken.hasMatch(r.emoji)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InlineEmojiText(
                          text: r.emoji,
                          style: TextStyle(color: c.text, fontSize: 12),
                          wholeStringOnly: true,
                          emojiSize: 12 * 1.45,
                          emojiMargin: EdgeInsets.zero,
                          // The badge pill is `display: flex; align-items: center`
                          // (styles-chat.css:414-426), so the img is a flex-
                          // centered item — `.custom-emoji-reaction`'s
                          // `vertical-align` is inert here.
                          emojiAlignment: PlaceholderAlignment.middle,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          abbreviateNumber(r.count),
                          style: TextStyle(color: c.text, fontSize: 12),
                        ),
                      ],
                    )
                  : Text(
                      '${r.emoji} ${abbreviateNumber(r.count)}',
                      style: TextStyle(color: c.text, fontSize: 12),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The `.add-reaction-btn` pill (`styles-chat.css:463-488`, `reactions.js:569`):
/// a 16px smiley-plus glyph in a rounded-20 pill (bg white@0.04, 1px glass
/// border, `4px 8px` padding) resting at `opacity: 0.6`. Tapping it opens the
/// full emoji reaction picker for the message (the PWA's
/// `showEnhancedReactionPicker`). The CSS `:hover` brightens it to opacity 1
/// with a primary-tinted border/background; since touch has no hover, we surface
/// that as a press state (opacity 1 + primary tint while held) and a slight
/// scale-down, mirroring the `.reaction-badge:active` feel.
class _AddReactionButton extends StatefulWidget {
  const _AddReactionButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddReactionButton> createState() => _AddReactionButtonState();
}

class _AddReactionButtonState extends State<_AddReactionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Opacity(
          // `.add-reaction-btn { opacity: 0.6 }`, `:hover { opacity: 1 }`.
          opacity: _pressed ? 1.0 : 0.6,
          child: Container(
            // `padding: 4px 8px`.
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              // bg white@0.04; `:hover` → primary@0.08.
              color: _pressed
                  ? c.primaryA(0.08)
                  : Colors.white.withValues(alpha: 0.04),
              // `border-radius: 20px`.
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              // 1px glass border; `:hover` → primary@0.3.
              border: Border.all(
                color: _pressed ? c.primaryA(0.3) : c.glassBorder,
              ),
            ),
            // `.add-reaction-btn svg { width:16px; height:16px; fill:var(--text) }`
            // (reactions.js:570) — the smiley-with-plus glyph, tinted --text.
            child: NymSvgIcon(
              NymIcons.addReaction,
              size: 16,
              color: c.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// A small inline action button for a system-message pill (the PWA's
/// `.spam-false-positive-btn`, messages.js:645): a primary-tinted rounded pill
/// with a subtle press-state, sized for the muted system row.
class _SystemActionButton extends StatefulWidget {
  const _SystemActionButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_SystemActionButton> createState() => _SystemActionButtonState();
}

class _SystemActionButtonState extends State<_SystemActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _pressed ? c.primaryA(0.16) : c.primaryA(0.10),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: c.primaryA(_pressed ? 0.5 : 0.3)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// The cosmetic-redacted body (`shop.js:498-512`): shows the real message
/// [child] for 10 seconds, then swaps to a `.cosmetic-redacted-message`
/// translucent bar (bg white@0.15, radius-xs, min-width 120, min-height 1.2em,
/// content hidden / unselectable).
class _RedactedReveal extends StatefulWidget {
  const _RedactedReveal({required this.child, required this.fontSize});
  final Widget child;
  final double fontSize;

  @override
  State<_RedactedReveal> createState() => _RedactedRevealState();
}

class _RedactedRevealState extends State<_RedactedReveal> {
  Timer? _timer;
  bool _blanked = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _blanked = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_blanked) return widget.child;
    // `.cosmetic-redacted-message { background: rgba(255,255,255,.15) }`; light
    // mode → `rgba(0,0,0,.12)` (styles-themes-responsive.css:954), since a
    // translucent white bar is invisible on a light surface.
    final isLight = context.nym.isLight;
    return Container(
      constraints: BoxConstraints(
        minWidth: 120,
        minHeight: widget.fontSize * 1.2,
      ),
      decoration: BoxDecoration(
        color: isLight
            ? const Color(0x1F000000) // black @ 0.12
            : Colors.white.withValues(alpha: 0.15),
        borderRadius: NymRadius.rxs,
      ),
    );
  }
}

/// The collapsed "💭 Reasoning" details block a bot reply prepends inside its
/// bubble/content (`.bot-think`, styles-chat.css:1193-1237 + messages.js
/// :796-797, 1415-1418): margin 2px 0 8px, bg secondary@0.08, a 1px glass
/// border with a 3px primary@0.45 left accent, radius-xs (8); the summary row
/// (5px 10px, text-dim, a ▸ that rotates 90° while open over `--transition`)
/// grows a 1px glass-border bottom divider while open; the body is 8px 10px
/// italic text-dim at line-height 1.5, capped at 320px with its own scroll.
/// The whole block renders at 0.88em of the user text size.
class _BotThinkSection extends StatefulWidget {
  const _BotThinkSection({
    required this.reasoning,
    required this.fontSize,
  });

  final String reasoning;

  /// 0.88 × the user text-size setting (`.bot-think { font-size: 0.88em }`).
  final double fontSize;

  @override
  State<_BotThinkSection> createState() => _BotThinkSectionState();
}

class _BotThinkSectionState extends State<_BotThinkSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fs = widget.fontSize;
    final side = BorderSide(color: c.glassBorder);
    return Container(
      // `.bot-think { margin: 2px 0 8px }`.
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      decoration: BoxDecoration(
        color: c.secondaryA(0.08),
        borderRadius: NymRadius.rxs,
        border: Border(
          top: side,
          right: side,
          bottom: side,
          left: BorderSide(color: c.primaryA(0.45), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              // `[open] summary { border-bottom: 1px solid var(--glass-border) }`.
              decoration: _expanded
                  ? BoxDecoration(border: Border(bottom: side))
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // `summary::before` ▸ marker (rotates 90° when open;
                  // `--transition`: 0.25s cubic-bezier(0.4,0,0.2,1)).
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.fastOutSlowIn,
                    turns: _expanded ? 0.25 : 0,
                    child: Text('▸',
                        style: TextStyle(color: c.textDim, fontSize: fs)),
                  ),
                  const SizedBox(width: 6),
                  // `.bot-think summary` has no font-weight (normal/w400).
                  Text('💭 Reasoning',
                      style: TextStyle(
                          color: c.textDim,
                          fontSize: fs,
                          fontWeight: FontWeight.w400)),
                ],
              ),
            ),
          ),
          if (_expanded)
            // `.bot-think-body`: italic dim, capped at 320px with its own scroll.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Text(
                  widget.reasoning,
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: fs,
                      height: 1.5,
                      fontStyle: FontStyle.italic),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The `.message-scroll-flash` highlight pulse (`styles-chat.css:1285-1306`): a
/// non-interactive primary-tinted overlay (`::after`, primary@0.18 fill + 1px
/// primary@0.5 border, radius-sm) that fades in then out over the
/// `messageScrollFlash` keyframes (0→1 at 8%, hold to 45%, →0 at 100%) across
/// 1.8s. Wraps a message row and plays once each time [active] rises (the row's
/// `flashedMessageProvider` match), mirroring the class the PWA adds to a
/// jumped-to message after `_scrollToQuotedMessage`.
class _ScrollFlashOverlay extends StatefulWidget {
  const _ScrollFlashOverlay({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_ScrollFlashOverlay> createState() => _ScrollFlashOverlayState();
}

class _ScrollFlashOverlayState extends State<_ScrollFlashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    // `animation: messageScrollFlash 1.8s ease-out forwards`.
    duration: const Duration(milliseconds: 1800),
    vsync: this,
  );

  // The `@keyframes messageScrollFlash` opacity curve: 0% → 0, 8% → 1, 45% → 1,
  // 100% → 0 (ease-out). A TweenSequence reproduces the in/hold/out timeline.
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 8,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 37), // 8% → 45%
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 55, // 45% → 100%
    ),
  ]).animate(_controller);

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(_ScrollFlashOverlay old) {
    super.didUpdateWidget(old);
    // Re-trigger the pulse each time the flash newly targets this row.
    if (widget.active && !old.active) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Stack(
      children: [
        widget.child,
        // `position: absolute; inset: 0; pointer-events: none; z-index: 5`.
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _opacity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.primaryA(0.18),
                  border: Border.all(color: c.primaryA(0.5)),
                  borderRadius: NymRadius.rsm,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// `.msg-hover-buttons` (styles-chat.css:357-402, messages.js:771-779): the
/// two quick-action buttons shown at a message's top-right while the row is
/// hovered on a hover-capable device — a smiley reaction-picker button
/// (`reactionShowPicker`) and a translate button (`translateHoverMessage`),
/// 4px apart. The host fades the pair with the row hover.
class _MsgHoverButtons extends StatelessWidget {
  const _MsgHoverButtons({
    required this.onReact,
    required this.onTranslate,
    this.vertical = false,
  });

  /// Opens the full reaction picker; null (no picker host) leaves the button
  /// rendered but inert, like a PWA row whose picker action can't resolve.
  final VoidCallback? onReact;
  final VoidCallback onTranslate;

  /// Columns mode stacks the pair vertically (`body.columns-mode
  /// .msg-hover-buttons { flex-direction: column }`, styles-columns.css:80-82).
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final children = [
      // `.reaction-btn` — the 20×20 smiley-plus glyph (same path as the
      // add-reaction pill's icon).
      _HoverActionButton(svg: NymIcons.addReaction, onTap: onReact),
      // `.msg-hover-buttons { gap: 4px }`.
      SizedBox(width: vertical ? 0 : 4, height: vertical ? 4 : 0),
      // `.translate-msg-btn` (`title="Translate"`).
      _HoverActionButton(
        svg: NymIcons.translate,
        onTap: onTranslate,
        tooltip: 'Translate',
      ),
    ];
    return vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: children,
          )
        : Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// One `.reaction-btn` / `.translate-msg-btn` (styles-chat.css:366-402): bg
/// rgba(20,20,35,0.8), 1px `--glass-border`, radius-xs, padding 4px 8px,
/// 16px glyph filled `--text`; hover → bg white@0.08 + border primary@0.3.
/// Light mode flips the rest fill to white@0.85 with a black@0.08 border
/// (styles-themes-responsive.css:1184-1187).
class _HoverActionButton extends StatefulWidget {
  const _HoverActionButton({
    required this.svg,
    required this.onTap,
    this.tooltip,
  });
  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<_HoverActionButton> createState() => _HoverActionButtonState();
}

class _HoverActionButtonState extends State<_HoverActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final restFill = c.isLight
        ? const Color(0xD9FFFFFF) // rgba(255,255,255,0.85)
        : const Color(0xCC141423); // rgba(20,20,35,0.8)
    final restBorder = c.isLight
        ? Colors.black.withValues(alpha: 0.08)
        : c.glassBorder;
    final btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color:
                _hover ? Colors.white.withValues(alpha: 0.08) : restFill,
            borderRadius: NymRadius.rxs,
            border: Border.all(
                color: _hover ? c.primaryA(0.3) : restBorder),
          ),
          child: NymSvgIcon(widget.svg, size: 16, color: c.text),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

/// The tappable message timestamp (`.clickable-timestamp`, messages.js:936-938).
/// Hover tints it `--primary` over 120ms (`.clickable-timestamp:hover`,
/// styles-chat.css:596-604) and shows the glass full-timestamp tooltip
/// (`.message-time:hover::after`, styles-components.css:1637-1657: bg
/// rgba(20,20,35,0.9) dark / white@0.92 light, glass / black@0.08 border,
/// radius-xs, padding 5px 10px, 11px, shadow-sm, 6px above). Tapping opens the
/// anchored `.timestamp-popup` (`showTimestampPopup`, messages.js:3367-3390):
/// a `.reactors-modal`-chromed panel whose `.timestamp-popup-body` is 13px
/// `--text` at 10px 14px, nowrap — right-aligned to the timestamp and flipped
/// above/below by available head-room, dismissed on the next tap.
class _TimestampText extends StatefulWidget {
  const _TimestampText({
    required this.label,
    required this.fullTimestamp,
    required this.fontSize,
    this.height,
  });

  final String label;
  final String fullTimestamp;
  final double fontSize;
  final double? height;

  @override
  State<_TimestampText> createState() => _TimestampTextState();
}

class _TimestampTextState extends State<_TimestampText> {
  bool _hover = false;
  OverlayEntry? _popup;

  @override
  void dispose() {
    _popup?.remove();
    _popup = null;
    super.dispose();
  }

  void _closePopup() {
    _popup?.remove();
    _popup = null;
  }

  /// `showTimestampPopup` placement (messages.js:3377-3384): right-aligned to
  /// the timestamp (`right = max(4, innerWidth - rect.right)`), 6px ABOVE it
  /// when there is head-room (`rect.top > approxHeight(90) + 20`), else 6px
  /// below. The PWA closes it on outside click / scroll; here the full-screen
  /// barrier closes it on the next tap or drag.
  void _openPopup() {
    _closePopup();
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final overlay = Overlay.of(context);
    final screen = MediaQuery.of(context).size;
    final right =
        (screen.width - rect.right).clamp(4.0, double.infinity);
    final above = rect.top > 110;
    final entry = OverlayEntry(
      builder: (ctx) {
        final c = ctx.nym;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closePopup,
                onPanStart: (_) => _closePopup(),
              ),
            ),
            Positioned(
              right: right,
              top: above ? null : rect.bottom + 6,
              bottom: above ? screen.height - rect.top + 6 : null,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  // `.reactors-modal { min-width:160; max-width:240 }`.
                  constraints:
                      const BoxConstraints(minWidth: 160, maxWidth: 240),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: c.bgSecondary,
                    borderRadius: NymRadius.rmd,
                    border: Border.all(
                      color: c.isLight
                          ? Colors.black.withValues(alpha: 0.08)
                          : c.glassBorder,
                    ),
                    // dark: shadow-lg + shadow-glow + a 1px white@0.05 ring;
                    // light: `0 8px 32px rgba(0,0,0,0.12)`.
                    boxShadow: c.isLight
                        ? const [
                            BoxShadow(
                                color: Color(0x1F000000),
                                offset: Offset(0, 8),
                                blurRadius: 32),
                          ]
                        : [
                            const BoxShadow(
                                color: Color(0x80000000),
                                offset: Offset(0, 8),
                                blurRadius: 32),
                            BoxShadow(
                                color: c.primaryA(0.1), blurRadius: 20),
                            const BoxShadow(
                                color: Color(0x0DFFFFFF), spreadRadius: 1),
                          ],
                  ),
                  // `.timestamp-popup-body`: 13px --text, nowrap.
                  child: Text(
                    widget.fullTimestamp,
                    softWrap: false,
                    style: TextStyle(color: c.text, fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    _popup = entry;
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openPopup,
        child: Tooltip(
          message: widget.fullTimestamp,
          // Hover-only (mouse): tap opens the styled popup instead, and
          // long-press belongs to the message quick-react hold.
          triggerMode: TooltipTriggerMode.manual,
          waitDuration: Duration.zero,
          preferBelow: false,
          verticalOffset: 14,
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.isLight
                ? const Color(0xEBFFFFFF) // rgba(255,255,255,0.92)
                : const Color(0xE6141423), // rgba(20,20,35,0.9)
            borderRadius: NymRadius.rxs,
            border: Border.all(
              color: c.isLight
                  ? Colors.black.withValues(alpha: 0.08)
                  : c.glassBorder,
            ),
            // `--shadow-sm: 0 2px 8px rgba(0,0,0,0.3)`.
            boxShadow: const [
              BoxShadow(
                  color: Color(0x4D000000),
                  offset: Offset(0, 2),
                  blurRadius: 8),
            ],
          ),
          // The ::after inherits `.message-time`'s text-dim (dark); light
          // pins `color: var(--text)`.
          textStyle: TextStyle(
              fontSize: 11, color: c.isLight ? c.text : c.textDim),
          child: AnimatedDefaultTextStyle(
            // `.clickable-timestamp { transition: color 120ms ease }`.
            duration: const Duration(milliseconds: 120),
            curve: Curves.ease,
            style: TextStyle(
              color: _hover ? c.primary : c.textDim,
              fontSize: widget.fontSize,
              height: widget.height,
            ),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}

/// The in-message P2P file-offer card (`.file-offer`, `messages.js:851-917`,
/// `styles-features.css:2087-2290`). Header = category-coloured doc icon + name
/// + meta (`size • type • Torrent?`); status block flips between
/// seeding/unseeded (own) and Download / inline-progress / "No longer available"
/// (peer). Driven live by [P2PService] (a [ChangeNotifier]) keyed by offerId.
///
/// Stateful because the PWA's DOM persists across status flips: a peer card
/// rendered while the offer was still seeded KEEPS its `.file-offer-btn`, so
/// when the offer goes unseeded mid-view the existing button flips to
/// "Unavailable" with `.unavailable` (`updateFileOfferUI`, p2p.js:858-874);
/// only a fresh render of an already-unseeded offer shows the bare
/// `.file-offer-unseeded` dot row (messages.js:876-882).
class FileOfferCard extends StatefulWidget {
  const FileOfferCard({
    super.key,
    required this.offer,
    required this.isOwn,
    required this.service,
    this.seedGeohash,
    this.seedChannelName,
  });

  final FileOffer offer;
  final bool isOwn;
  final P2PService service;

  /// Wire key of the channel currently open, so the inline Stop broadcasts the
  /// unseeded event with the right channel tag — `['g', geohash]` for a geohash
  /// channel via [seedGeohash], `['d', name]` for a named channel via
  /// [seedChannelName] — exactly like the PWA's `stopSeeding`, which reads
  /// `this.currentGeohash` regardless of where Stop was clicked (p2p.js:828).
  /// Both null (PM/group/no channel) → no tag. F06-B3.
  final String? seedGeohash;
  final String? seedChannelName;

  @override
  State<FileOfferCard> createState() => _FileOfferCardState();
}

class _FileOfferCardState extends State<FileOfferCard> {
  FileOffer get offer => widget.offer;
  bool get isOwn => widget.isOwn;
  P2PService get service => widget.service;

  /// True once this mounted card has rendered the offer in a SEEDED state —
  /// the analogue of the PWA card whose actions div already exists when the
  /// unseeded status arrives (`updateFileOfferUI` mutates the button in place
  /// rather than swapping to the dot row).
  bool _sawSeeded = false;

  /// Category → icon stroke colour (`.file-offer-icon.audio/video/archive/…`).
  /// The PWA uses ONE generic file glyph and only re-tints the stroke per
  /// category (default → `--primary`), so this returns the colour alone.
  static Color _category(NymColors c, FileOffer o) {
    final ext = o.name.contains('.') ? o.name.split('.').last.toLowerCase() : '';
    final mime = o.type.toLowerCase();
    bool any(List<String> exts) => exts.contains(ext);
    if (any(['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma']) ||
        mime.startsWith('audio/')) {
      return c.purple; // `.file-offer-icon.audio`
    }
    if (any(['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm']) ||
        mime.startsWith('video/')) {
      return c.danger; // `.file-offer-icon.video`
    }
    if (any(['zip', 'rar', '7z', 'tar', 'gz', 'bz2'])) {
      return c.warning; // `.file-offer-icon.archive`
    }
    if (any(['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'])) {
      return c.secondary; // `.file-offer-icon.document`
    }
    return c.primary; // default `.file-offer-icon svg { stroke: var(--primary) }`
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final iconColor = _category(c, offer);
        final isTorrent = offer.isTorrent;
        final unseeded = service.isUnseeded(offer.offerId);
        // The active transfer for this offer, if any.
        P2PTransfer? transfer;
        for (final t in service.transfers) {
          if (t.offerId == offer.offerId) transfer = t;
        }
        // Latch the "rendered while seeded" state (the PWA card whose actions
        // div pre-exists an unseeded flip). Internal flag only — the same
        // build reads it, so no setState needed.
        if (!unseeded) _sawSeeded = true;

        return Container(
          // `.file-offer { max-width: 350px; margin: 8px 0 }`
          // (styles-features.css:2048-2055).
          constraints: const BoxConstraints(maxWidth: 350),
          margin: const EdgeInsets.symmetric(vertical: 8),
          // `.file-offer { padding: 14px; border-radius: var(--radius-md)=16 }`
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: const BorderRadius.all(Radius.circular(16)),
            border: Border.all(
              color: isTorrent ? c.secondaryA(0.3) : c.glassBorder,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // `.file-offer-icon`: a 40×40 boxed icon (white@0.05 bg, 1px
                  // glass border, radius-xs=8) wrapping the 24px generic file
                  // glyph (styles-features.css:2064-2080). The category re-tints
                  // the stroke (audio/video/archive/document, else --primary).
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      border: Border.all(color: c.glassBorder),
                      borderRadius: NymRadius.rxs,
                    ),
                    child: NymSvgIcon(NymIcons.fileOffer,
                        color: iconColor, size: 24),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          offer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${formatFileSize(offer.size)} • '
                          '${offer.type.isEmpty ? 'Unknown type' : offer.type}'
                          '${isTorrent ? ' • Torrent' : ''}',
                          style: TextStyle(color: c.textDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              _status(context, c, unseeded: unseeded, transfer: transfer),
            ],
          ),
        );
      },
    );
  }

  Widget _status(
    BuildContext context,
    NymColors c, {
    required bool unseeded,
    required P2PTransfer? transfer,
  }) {
    // Own offer: seeding (pulsing primary dot + Stop) or no-longer-seeding.
    if (isOwn) {
      if (unseeded) {
        return _dotRow(c, 'No longer seeding');
      }
      // `.file-offer-seeding`: gap 6, --primary 11px, margin-top 8; the dot
      // pulses opacity 1↔0.5 on a 1.5s loop (`animation: pulse 1.5s infinite`,
      // styles-features.css:2204-2226).
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            _SeedingDot(color: c.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Seeding - available for download',
                  style: TextStyle(color: c.primary, fontSize: 11)),
            ),
            _StopBtn(
                onTap: () => service.stopSeeding(offer.offerId,
                    geohash: widget.seedGeohash,
                    channelName: widget.seedChannelName)),
          ],
        ),
      );
    }
    // Peer offer first rendered ALREADY unseeded → the bare dot row
    // (messages.js:876-882). A card that saw the offer seeded keeps its
    // button and flips it to "Unavailable" below (`updateFileOfferUI`).
    if (unseeded && !_sawSeeded) {
      return _dotRow(c, 'No longer available');
    }

    // Peer offer: the `.file-offer-btn` stays visible through the WHOLE
    // lifecycle (p2p.js:238-247, 632-646, 858-874) —
    //   rest      → "Download" / "Download (Torrent)"
    //   request   → "Connecting..." + `.downloading` (secondary border/text,
    //               inert) with the progress block appearing BELOW it
    //   complete  → "Downloaded" (base tint restored, inert); the progress
    //               block (with its final status line) STAYS
    //   error     → "Retry" (base tint, re-requests); progress line = message
    //   unseeded  → "Unavailable" + `.unavailable` (opacity 0.4, text-dim)
    final active = transfer != null &&
        (transfer.status == P2PStatus.connecting ||
            transfer.status == P2PStatus.transferring);
    // Base tint: primary, or secondary for `.torrent-btn`.
    final base = offer.isTorrent ? c.secondary : c.primary;
    final Widget button;
    if (unseeded) {
      button = _OfferBtn(
        label: 'Unavailable',
        textColor: c.textDim,
        borderColor: c.textDim,
        fillColor: base.withValues(alpha: 0.08),
        opacity: 0.4,
        onTap: null,
      );
    } else if (active) {
      // `.file-offer-btn.downloading`: border + text --secondary (the fill
      // keeps the base class tint), default cursor.
      button = _OfferBtn(
        label: 'Connecting...',
        textColor: c.secondary,
        borderColor: c.secondary,
        fillColor: base.withValues(alpha: 0.08),
        onTap: null,
      );
    } else if (transfer != null && transfer.status == P2PStatus.complete) {
      button = _OfferBtn(
        label: 'Downloaded',
        textColor: base,
        borderColor: base.withValues(alpha: 0.25),
        fillColor: base.withValues(alpha: 0.08),
        onTap: null,
      );
    } else if (transfer != null && transfer.status == P2PStatus.error) {
      button = _OfferBtn(
        label: 'Retry',
        textColor: base,
        borderColor: base.withValues(alpha: 0.25),
        fillColor: base.withValues(alpha: 0.08),
        onTap: () => service.requestFile(offer.offerId),
      );
    } else {
      button = _OfferBtn(
        label: offer.isTorrent ? 'Download (Torrent)' : 'Download',
        textColor: base,
        borderColor: base.withValues(alpha: 0.25),
        fillColor: base.withValues(alpha: 0.08),
        onTap: () => service.requestFile(offer.offerId),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `.file-offer-actions { margin-top: 10px }`.
        Padding(padding: const EdgeInsets.only(top: 10), child: button),
        // `.file-offer-progress { margin-top: 10px }` — revealed on request
        // and never re-hidden (its final status line stays after completion).
        if (transfer != null) ...[
          const SizedBox(height: 10),
          // `.file-offer-progress-bar`: 5px track white@0.05, radius 10;
          // `.file-offer-progress-fill`: `linear-gradient(90deg, secondary,
          // primary)`, radius 10 (styles-features.css:2139-2152). A
          // LinearProgressIndicator can't gradient, so paint a Stack +
          // FractionallySizedBox like p2p_transfers_modal `_TransferRow`.
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            child: SizedBox(
              height: 5,
              child: Stack(
                children: [
                  Container(color: Colors.white.withValues(alpha: 0.05)),
                  FractionallySizedBox(
                    widthFactor: (transfer.progress / 100).clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius:
                            const BorderRadius.all(Radius.circular(10)),
                        gradient: LinearGradient(
                          colors: [c.secondary, c.primary],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // `.file-offer-progress-text`: centered text-dim 11px, 4px below.
          // Mid-transfer it reads `<pct>% • <speed>/s` (updateTransferProgress,
          // p2p.js:606-622: pct at 1 decimal, speed = bytesReceived/elapsed);
          // any other status shows the last status message.
          const SizedBox(height: 4),
          Text(
            _progressText(transfer),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ],
      ],
    );
  }

  /// The `.file-offer-progress-text` line: `"<pct>% • <speed>/s"` while
  /// chunks flow (`updateTransferProgress`), else the transfer's last status
  /// message (`updateTransferStatus`), defaulting to "Connecting...".
  String _progressText(P2PTransfer transfer) {
    if (transfer.status == P2PStatus.transferring) {
      final elapsed = (DateTime.now().millisecondsSinceEpoch -
              transfer.startTime) /
          1000;
      final speed = elapsed > 0
          ? (transfer.bytesReceived / elapsed).round()
          : 0;
      return '${transfer.progress.toStringAsFixed(1)}% • '
          '${formatFileSize(speed)}/s';
    }
    return transfer.message ?? 'Connecting...';
  }

  /// `.file-offer-unseeded` (styles-features.css:2228-2244): text-dim 11px row
  /// at opacity 0.7, 8px below the header, led by an 8px danger dot at
  /// opacity 0.6.
  Widget _dotRow(NymColors c, String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Opacity(
        opacity: 0.7,
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: c.textDim, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// `.file-offer-seeding-dot` — an 8px `--primary` dot pulsing opacity 1↔0.5 on
/// a 1.5s loop (`animation: pulse 1.5s infinite`, keyframes at
/// styles-features.css:2214-2226; default `ease` timing per segment).
class _SeedingDot extends StatefulWidget {
  const _SeedingDot({required this.color});
  final Color color;

  @override
  State<_SeedingDot> createState() => _SeedingDotState();
}

class _SeedingDotState extends State<_SeedingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  // `@keyframes pulse { 0%,100% → 1; 50% → 0.5 }` with CSS `ease` per segment.
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
      tween:
          Tween(begin: 1.0, end: 0.5).chain(CurveTween(curve: Curves.ease)),
      weight: 50,
    ),
    TweenSequenceItem(
      tween:
          Tween(begin: 0.5, end: 1.0).chain(CurveTween(curve: Curves.ease)),
      weight: 50,
    ),
  ]).animate(_ctrl);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// `.file-offer-btn` — a full-width action pill (Download / Connecting... /
/// Downloaded / Retry / Unavailable): 12px w500 label, 8px 12px padding,
/// radius-xs (styles-features.css:2106-2118), tinted per state. A null [onTap]
/// renders an inert state (the PWA nulls `onclick` + default cursor).
class _OfferBtn extends StatelessWidget {
  const _OfferBtn({
    required this.label,
    required this.textColor,
    required this.borderColor,
    required this.fillColor,
    this.opacity = 1,
    this.onTap,
  });
  final String label;
  final Color textColor;
  final Color borderColor;
  final Color fillColor;

  /// `.file-offer-btn.unavailable { opacity: 0.4 }`.
  final double opacity;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: opacity,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(color: borderColor),
            // `.file-offer-btn { border-radius: var(--radius-xs)=8 }` (:2110).
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.file-offer-stop-btn` — a small danger-outlined "Stop" pill (own seeding).
class _StopBtn extends StatelessWidget {
  const _StopBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.danger),
          // `.file-offer-btn { border-radius: var(--radius-xs)=8 }` (:2110).
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Text('Stop',
            style: TextStyle(color: c.danger, fontSize: 10)),
      ),
    );
  }
}

/// Folds a chronological (oldest-first) [messages] list into the PWA's
/// `.message-group` runs: consecutive same-author bubble messages share one
/// gliding avatar. In IRC mode ([useBubbles] false) every message is its own
/// group; system / `/me` rows always stand alone, and an author or >5min time
/// break splits a run. Mirrors [MessagesList]'s inline fold so the single-chat
/// and columns views group — and so render avatars — identically (the columns
/// view previously rendered a flat row list with no avatars at all).
List<List<MessageGroupEntry>> buildMessageGroups(
  List<Message> messages, {
  required Map<String, List<MessageReaction>> reactions,
  required bool useBubbles,
  String mentionToken = '',
}) {
  // Same predicate as messages_list `_groupsWith` (5-minute window).
  bool groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= 300;
  final groups = <List<MessageGroupEntry>>[];
  for (final m in messages) {
    final entry = MessageGroupEntry(
      message: m,
      reactions: reactions[m.id] ?? const [],
      // PWA `.mentioned` never applies to self or PM/group rows (else-if class
      // chain, messages.js:686-692), and `isMentioned` bails while the self nym
      // is unknown (`if (!content || !this.nym) return false`, messages.js:400)
      // — a bare '@' token (empty nym at boot) must not flag every '@'.
      mentioned: mentionToken.length > 1 &&
          !m.isOwn &&
          !m.isPM &&
          m.content.contains(mentionToken),
    );
    if (useBubbles &&
        groups.isNotEmpty &&
        groupsWith(groups.last.last.message, m)) {
      groups.last.add(entry);
    } else {
      groups.add([entry]);
    }
  }
  return groups;
}

/// One message inside a [MessageGroup]: the message plus its already-resolved
/// reactions and mention flag (computed once by [MessagesList] so the row needn't
/// re-watch them).
class MessageGroupEntry {
  const MessageGroupEntry({
    required this.message,
    required this.reactions,
    required this.mentioned,
  });

  final Message message;
  final List<MessageReaction> reactions;
  final bool mentioned;
}

/// A `.message-group`: a run of consecutive same-author bubble messages laid out
/// in one `.message-group-stack` column beside a SINGLE avatar — the PWA's
/// `.message-group-avatar` (32px, `align-self: flex-end`, `position: sticky;
/// bottom: 8px`). Grouping consecutive messages into one widget is what lets that
/// avatar span the whole run and GLIDE up the left edge as a tall group scrolls
/// (each message is otherwise its own list item, so a per-row avatar can't move
/// past its row). The glide itself lives in [_StickyGroupAvatar].
///
/// In IRC mode — and for standalone system / `/me` rows — a "group" is always a
/// single entry and renders bare (no avatar gutter, no group chrome), so those
/// paths are byte-for-byte what [MessageRow] produced before grouping existed.
class MessageGroup extends ConsumerStatefulWidget {
  const MessageGroup({
    super.key,
    required this.entries,
    required this.settings,
    this.columnsMode = false,
    this.onReactionPicker,
  });

  final List<MessageGroupEntry> entries;
  final Settings settings;

  /// This group renders inside a columns-deck `.cv-list` (`body.columns-mode`).
  /// Forwarded to every [MessageRow] (IRC rows stack vertically, hover buttons
  /// stack) and — on desktop (>768px) — drops the self group's 14px right
  /// padding so own bubbles sit flush with the column scroller's 10px padding
  /// (`@media (min-width: 769px) body.columns-mode.chat-bubbles .message-group.
  /// group-self { padding-right: 0 }`, styles-columns.css:58-62).
  final bool columnsMode;
  final ValueChanged<Message>? onReactionPicker;

  @override
  ConsumerState<MessageGroup> createState() => _MessageGroupState();
}

class _MessageGroupState extends ConsumerState<MessageGroup> {
  /// Anchors the gliding avatar to the LAST bubble (kept stable across rebuilds
  /// so the keyed bubble subtree isn't torn down each frame).
  final GlobalKey _bubbleKey = GlobalKey();

  /// Live swipe translation of the group's LAST bubble. The PWA slides the
  /// `.message-group-avatar` together with that message while it is swiped
  /// (`findGroupAvatar` — the stack's last child — messages.js:2151-2160, then
  /// `avatarEl.style.transform = translateX(...)`, :2216-2219, springing back
  /// over the same 0.25s ease-out).
  final ValueNotifier<double> _avatarDx = ValueNotifier<double>(0);

  @override
  void dispose() {
    _avatarDx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final settings = widget.settings;
    final onReactionPicker = widget.onReactionPicker;
    final useBubbles = settings.useBubbles;
    final first = entries.first.message;
    final self = first.isOwn;

    // The `.message-group-stack` rows. `grouped`/`showName` track position in the
    // run (only the lead carries a name); `inGroup` strips each row to its content
    // stack so the group can host the one shared avatar.
    List<Widget> buildRows() => [
          for (var i = 0; i < entries.length; i++)
            MessageRow(
              key: ValueKey(entries[i].message.id),
              message: entries[i].message,
              settings: settings,
              reactions: entries[i].reactions,
              mentioned: entries[i].mentioned,
              columnsMode: widget.columnsMode,
              grouped: useBubbles && i > 0,
              showName: !(useBubbles && i > 0),
              showAvatar: false,
              inGroup: useBubbles,
              onReactionPicker: onReactionPicker,
              // The LAST bubble anchors the gliding avatar (others-bubble path).
              bubbleAnchorKey: i == entries.length - 1 ? _bubbleKey : null,
              // …and drags that avatar along while it is swiped (the swiped
              // message must be the stack's LAST child, `findGroupAvatar`).
              swipeAvatarDx: useBubbles && !self && i == entries.length - 1
                  ? _avatarDx
                  : null,
            ),
        ];

    // IRC layout, or a standalone system / `/me` row → no grouping chrome.
    if (!useBubbles || first.isSystemRow || first.isMeAction) {
      final rows = buildRows();
      return rows.length == 1
          ? rows.first
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    }

    // `width: double.infinity` forces the column to fill the group's width under
    // the loose constraints a [Padding]/[Stack] hands it — without it a
    // `CrossAxisAlignment.stretch` column shrink-wraps to its widest bubble,
    // collapsing the full-width translation / read-receipt rows and breaking the
    // self side's right-alignment (the old `Flexible`-in-`Row` gave it a tight
    // width). The `.message-group-stack` is `flex: 1 1 auto`, i.e. full width.
    final stack = SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: buildRows(),
      ),
    );

    // Self group: `group-self` is `padding: 0 14px`, row-reversed, no avatar —
    // each row already right-aligns its own content. Desktop columns mode drops
    // the RIGHT padding so own bubbles sit flush with the column scroller's
    // 10px padding (`@media (min-width: 769px) body.columns-mode.chat-bubbles
    // .message-group.group-self { padding-right: 0 }`, styles-columns.css:58-62).
    if (self) {
      final flushRight = widget.columnsMode &&
          MediaQuery.of(context).size.width > NymDimens.mobileBreakpoint;
      return Padding(
        padding: EdgeInsets.only(left: 14, right: flushRight ? 0 : 14),
        child: stack,
      );
    }

    // Others group: `.message-group { padding: 0 14px 0 6px; gap: 6px }`. The
    // 32px avatar lives in a Positioned overlay pinned to the left gutter; the
    // stack is inset 38px (32 avatar + 6 gap) to sit where `.message-group-stack`
    // does. The overlay (full group height) lets the avatar glide within the
    // group's bounds without disturbing the bubble column's layout.
    final last = entries.last.message;
    final picture = ref.watch(
        usersProvider.select((m) => m[first.pubkey]?.profile?.picture));
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
      child: Stack(
        // The PWA clips a swiped row (and its off-edge indicator chip) only at
        // the SCROLLER (`.messages-container { overflow-x: hidden }`), never at
        // the group box — so the chip may paint over the group's padding.
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: stack,
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 32,
            // Swiping the group's LAST bubble slides the avatar with it
            // (messages.js:2216-2219); only the 32px gutter re-renders.
            child: ValueListenableBuilder<double>(
              valueListenable: _avatarDx,
              builder: (context, dx, child) => Transform.translate(
                offset: Offset(dx, 0),
                child: child,
              ),
              child: _StickyGroupAvatar(
                pubkey: first.pubkey,
                imageUrl: picture,
                bubbleKey: _bubbleKey,
                onTap: () => _openAvatarMenu(context, ref, last),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Tapping the group avatar opens the context menu for the group's LAST message
  /// (PWA `_createMessageGroupWrapper`: the avatar click resolves
  /// `stack.lastElementChild` and calls `showContextMenu`).
  void _openAvatarMenu(BuildContext context, WidgetRef ref, Message last) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(last, selfPubkey: app.selfPubkey);
    ContextMenuPanel.show(
      context,
      target: target,
      message: last,
      onReact: () => widget.onReactionPicker?.call(last),
    );
  }
}

/// The single per-group avatar reproducing the PWA's `.message-group-avatar`
/// (`position: sticky; bottom: 8px; align-self: flex-end`). It fills the group's
/// left gutter (a full-height, 32px-wide track) and positions a 32px avatar that:
///   * rests at the group's foot (bottom of the stack) when the group sits above
///     the viewport's bottom edge, and
///   * GLIDES up to stay pinned 8px above the scroll viewport's bottom edge while
///     a tall group spans that edge — clamped to the group's own bounds, exactly
///     like CSS `position: sticky` constrained to its containing block. So a long
///     monologue's avatar tracks the screen bottom as you scroll, then settles
///     once the group's end scrolls into view.
///
/// The glide reads the previous frame's render geometry (the build runs before
/// layout); mid-scroll that one-frame lag is imperceptible, and a post-frame
/// recompute settles the initial (un-scrolled) position. Only this 32px box
/// rebuilds per scroll tick — the [NymAvatar] is hoisted via the builder's
/// `child` so it is built once.
class _StickyGroupAvatar extends StatefulWidget {
  const _StickyGroupAvatar({
    required this.pubkey,
    required this.imageUrl,
    required this.onTap,
    this.bubbleKey,
  });

  final String pubkey;
  final String? imageUrl;
  final VoidCallback onTap;

  /// Keys the LAST bubble in the group so the avatar's resting position bottom-
  /// aligns to the bubble — not to the group foot, which includes the reactions /
  /// translation / receipt rows BELOW the bubble (PWA keeps the avatar by the
  /// last bubble). Null → fall back to the group foot.
  final GlobalKey? bubbleKey;

  @override
  State<_StickyGroupAvatar> createState() => _StickyGroupAvatarState();
}

class _StickyGroupAvatarState extends State<_StickyGroupAvatar> {
  /// CSS `bottom: 8px` — the avatar floats 8px above the viewport's bottom edge.
  static const double _stickyGap = 8;
  static const double _avatar = 32;

  /// Bumped on every scroll tick to recompute the glide offset (the value is
  /// unused — it only drives the [ValueListenableBuilder] rebuild).
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    // Settle the initial (un-scrolled) position once the first layout exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tick.value++;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scrollable.maybeOf(context)?.position;
    if (!identical(p, _position)) {
      _position?.removeListener(_onScroll);
      _position = p;
      _position?.addListener(_onScroll);
    }
  }

  void _onScroll() {
    if (mounted) _tick.value++;
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    _tick.dispose();
    super.dispose();
  }

  /// The avatar's bottom-most resting top: aligned to the LAST bubble's bottom
  /// (via [_StickyGroupAvatar.bubbleKey]) rather than the full group foot, so a
  /// trailing reactions / translation / receipt row doesn't drop the avatar below
  /// the bubble. Falls back to [trackHeight] - avatar when the bubble can't be
  /// measured yet (first frame; the post-frame tick settles it).
  double _restingTop(double trackHeight) {
    final fallback = (trackHeight - _avatar).clamp(0.0, double.infinity);
    final track = context.findRenderObject();
    final bubble = widget.bubbleKey?.currentContext?.findRenderObject();
    if (track is RenderBox &&
        track.hasSize &&
        bubble is RenderBox &&
        bubble.hasSize) {
      // Bubble bottom in the track's coordinate space.
      final bubbleBottom = bubble
          .localToGlobal(Offset(0, bubble.size.height), ancestor: track)
          .dy;
      return (bubbleBottom - _avatar).clamp(0.0, fallback);
    }
    return fallback;
  }

  /// The avatar's top within its [maxTop]-bounded track — `clamp(desired, 0,
  /// maxTop)` is precisely CSS sticky bounded to the containing block, where
  /// `desired` places the avatar 8px above the viewport bottom.
  double _computeTop(double maxTop) {
    final scrollable = Scrollable.maybeOf(context);
    final track = context.findRenderObject();
    if (scrollable != null && track is RenderBox && track.hasSize) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        final trackTop =
            track.localToGlobal(Offset.zero, ancestor: viewport).dy;
        final desired =
            viewport.size.height - _stickyGap - _avatar - trackTop;
        return desired.clamp(0.0, maxTop);
      }
    }
    return maxTop; // resting at the group's foot
  }

  @override
  Widget build(BuildContext context) {
    final avatar = GestureDetector(
      onTap: widget.onTap,
      child: NymAvatar(
        seed: widget.pubkey,
        size: _avatar,
        imageUrl: widget.imageUrl,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        return ValueListenableBuilder<int>(
          valueListenable: _tick,
          // Recompute BOTH the resting bound (bubble anchor) and the glide on
          // every tick — the bubble's render box only exists from the 2nd frame,
          // so the post-frame tick is what settles the avatar onto the bubble.
          builder: (context, _, child) {
            final maxTop = _restingTop(trackHeight);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  top: _computeTop(maxTop),
                  width: _avatar,
                  height: _avatar,
                  child: child!,
                ),
              ],
            );
          },
          child: avatar,
        );
      },
    );
  }
}

/// The `bubble-snap-in` entrance a live consecutive bubble plays as it lands
/// (`body.chat-bubbles .message.bubble-snap { animation: bubble-snap-in 240ms
/// cubic-bezier(0.34, 1.56, 0.64, 1) both; transform-origin: bottom left }`,
/// self → `bottom right`; styles-features.css:3453-3471). Keyframes:
///   0%   translateY(-6px) scale(0.94) opacity 0
///   55%  translateY(2px)  scale(1.02) opacity 1
///   80%  translateY(-1px) scale(0.995)
///   100% identity
/// CSS eases each keyframe segment with the animation's timing function, so
/// every tween below chains the same overshoot cubic.
class _BubbleSnapIn extends StatefulWidget {
  const _BubbleSnapIn({required this.self, required this.child});

  /// Self bubbles snap from the bottom-RIGHT corner (`.bubble-snap.self`).
  final bool self;
  final Widget child;

  @override
  State<_BubbleSnapIn> createState() => _BubbleSnapInState();
}

class _BubbleSnapInState extends State<_BubbleSnapIn>
    with SingleTickerProviderStateMixin {
  /// `cubic-bezier(0.34, 1.56, 0.64, 1)` — the overshoot ease.
  static const Cubic _overshoot = Cubic(0.34, 1.56, 0.64, 1);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..forward();

  late final Animation<double> _dy = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: -6.0, end: 2.0).chain(CurveTween(curve: _overshoot)),
      weight: 55,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 2.0, end: -1.0).chain(CurveTween(curve: _overshoot)),
      weight: 25, // 55% → 80%
    ),
    TweenSequenceItem(
      tween: Tween(begin: -1.0, end: 0.0).chain(CurveTween(curve: _overshoot)),
      weight: 20, // 80% → 100%
    ),
  ]).animate(_c);

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.94, end: 1.02).chain(CurveTween(curve: _overshoot)),
      weight: 55,
    ),
    TweenSequenceItem(
      tween:
          Tween(begin: 1.02, end: 0.995).chain(CurveTween(curve: _overshoot)),
      weight: 25,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.995, end: 1.0).chain(CurveTween(curve: _overshoot)),
      weight: 20,
    ),
  ]).animate(_c);

  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: _overshoot)),
      weight: 55,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 45),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Opacity(
        // The overshoot cubic exceeds 1.0 mid-segment; opacity must clamp.
        opacity: _opacity.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, _dy.value),
          child: Transform.scale(
            scale: _scale.value,
            alignment: widget.self
                ? Alignment.bottomRight // `.bubble-snap.self`
                : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Swipe-to-act wrapper around a message row (`setupSwipeToReply`,
/// messages.js:2129-2278). A dominantly-horizontal TOUCH drag follows the
/// finger (the content slides up to 100px, all travel measured from the
/// touch-down point), reveals the directional `.swipe-reply-indicator` chip
/// riding 40px off the row's edge, fires a threshold haptic, and on release
/// past the threshold runs the action locked in at claim time; a short swipe
/// springs back over 0.25s ease-out with the chip lingering 250ms. Also hosts
/// long-press → quick-react (press-point anchored) and DESKTOP double-click →
/// quote-reply (`setupDoubleClickToReply` bails on touch devices,
/// messages.js:2284-2285).
///
/// Mirrors the PWA constants: SWIPE_START 16px, EDGE_ZONE 50px (a right-swipe
/// starting near the left screen edge is abandoned so the drawer-open gesture
/// wins), follow cap 100px, threshold clamped 30-120. The drag recognizer
/// accepts TOUCH pointers only — the PWA binds `touchstart`/`touchmove`, so
/// any touch screen gets the gesture and mouse drags never do — and is gated
/// on `gesturesEnabled` (messages.js:2141-2148, 2163-2164).
class _SwipeToAct extends StatefulWidget {
  const _SwipeToAct({
    required this.settings,
    required this.onAction,
    required this.onDoubleTap,
    required this.onLongPressStart,
    required this.onSecondaryTap,
    this.avatarDx,
    this.swipeReactEmojiUrl,
    required this.child,
  });

  final Settings settings;

  /// Runs the committed action string ('quote'/'translate'/'copy'/'react'/
  /// 'zap'/'slap'/'hug').
  final ValueChanged<String> onAction;
  final VoidCallback onDoubleTap;

  /// Long-press with the press point (`details.globalPosition`) — the PWA
  /// anchors the quick-react pill to the touch coordinates (ui-context.js:1330).
  final GestureLongPressStartCallback onLongPressStart;
  final VoidCallback onSecondaryTap;

  /// When this row is the LAST bubble of an others' group, the group's
  /// `.message-group-avatar` translation channel: written with the live signed
  /// dx so the avatar slides with the message (messages.js:2151-2160,
  /// 2216-2219). Its presence also selects the `-past-avatar` indicator inset
  /// (left -86px) for right swipes (messages.js:2221-2225).
  final ValueNotifier<double>? avatarDx;

  /// Resolved custom-emoji image URL for the 'react' indicator when
  /// `swipeReactEmoji` is a known `:shortcode:` (messages.js:2066-2074);
  /// null → the emoji text glyph.
  final String? swipeReactEmojiUrl;
  final Widget child;

  @override
  State<_SwipeToAct> createState() => _SwipeToActState();
}

class _SwipeToActState extends State<_SwipeToAct>
    with SingleTickerProviderStateMixin {
  static const double _swipeStart = 16; // SWIPE_START_THRESHOLD
  static const double _edgeZone = 50; // EDGE_ZONE
  static const double _followCap = 100; // max |translateX|

  /// The actions `_getSwipeActionConfig` knows (messages.js:2031-2126). At
  /// claim time a direction resolving to anything else — including 'none' —
  /// abandons the gesture outright (messages.js:2202-2206): the row never
  /// moves, no indicator, no haptic.
  static const Set<String> _knownActions = {
    'quote', 'translate', 'copy', 'react', 'zap', 'slap', 'hug',
  };

  // Created in initState (NOT a lazy `late final = …`): a row that is never
  // swiped would otherwise first touch `_settle` in dispose(), lazily creating
  // a ticker during teardown and throwing. (Caught by `flutter test`.)
  late final AnimationController _settle;

  double _dx = 0; // applied translation (signed by the locked direction)
  double _travel = 0; // raw finger dx accumulated since touch-down
  int _dir = 0; // LOCKED at claim (messages.js:2195): -1 left, +1 right
  String _action = 'none'; // resolved once at claim for the locked direction
  bool _active = false; // the gesture has been claimed
  bool _abandoned = false; // edge zone / action 'none' — gesture given up
  bool _thresholdFired = false; // threshold haptic latch (re-arms below)
  bool _indicatorLit = false; // `.visible` — frozen at release for the linger
  double _startX = 0; // global x of the touch-down (for EDGE_ZONE)
  double _startY = 0; // global y of the touch-down (for the axis test)

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      // `transition: transform 0.25s ease-out` on release (messages.js:2253);
      // the indicator lingers this long too (`setTimeout(remove, 250)`).
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    widget.avatarDx?.value = 0;
    _settle.dispose();
    super.dispose();
  }

  /// `threshold = clamp(parseInt(swipeThreshold||60), 30, 120)` (messages.js:2147).
  double get _threshold =>
      widget.settings.swipeThreshold.clamp(30, 120).toDouble();

  void _setDx(double v) {
    setState(() => _dx = v);
    // The group avatar slides in lockstep (messages.js:2216-2219).
    widget.avatarDx?.value = v;
  }

  void _onStart(DragStartDetails d) {
    _active = false;
    _abandoned = false;
    _thresholdFired = false;
    _indicatorLit = false;
    _dir = 0;
    _action = 'none';
    _travel = 0;
    // DragStartBehavior.down → this IS the touch-down point (PWA startX/startY).
    _startX = d.globalPosition.dx;
    _startY = d.globalPosition.dy;
    _settle.stop();
    if (_dx != 0) _setDx(0);
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_abandoned) return;
    // All travel is measured from the touch-down point — the PWA's
    // `dx = clientX - startX` (messages.js:2189). DragStartBehavior.down
    // delivers the pre-arena-slop travel too, so no hidden ~18px is added on
    // top of SWIPE_START/threshold.
    _travel += d.delta.dx;
    if (!_active) {
      if (_travel.abs() <= _swipeStart) return;
      // Axis-dominance test: the PWA only claims when horizontal travel
      // dominates vertical by 1.5x — `absDx > dy * 1.5` — re-evaluated on
      // every move until claimed (messages.js:2194), so a diagonal drag is
      // left to the scroller rather than starting a swipe.
      final dy = (d.globalPosition.dy - _startY).abs();
      if (_travel.abs() <= dy * 1.5) return;
      // Direction is locked HERE and never re-derived — dragging back across
      // the origin cannot flip the indicator/action (messages.js:2194-2202).
      final dir = _travel < 0 ? -1 : 1;
      // Defer to the sidebar-open gesture: right swipes that began within
      // EDGE_ZONE of the left edge (messages.js:2196-2201).
      if (dir > 0 && _startX < _edgeZone) {
        _abandoned = true;
        return;
      }
      final action = dir < 0
          ? widget.settings.swipeLeftAction
          : widget.settings.swipeRightAction;
      // 'none' (or unknown) → abandon: no translation, no haptic
      // (messages.js:2202-2206).
      if (!_knownActions.contains(action)) {
        _abandoned = true;
        return;
      }
      _dir = dir;
      _action = action;
      _active = true;
    }
    // Follow the finger: `swipeDistance = min(|dx|, 100)`, signed by the
    // LOCKED direction (messages.js:2212-2213).
    final double dist = _travel.abs().clamp(0.0, _followCap);
    final past = dist >= _threshold;
    if (past && !_thresholdFired) {
      // Threshold haptic — `nymHapticTap` = a 30ms vibrate
      // (messages.js:2239-2241, inline-bindings.js:106-115).
      HapticFeedback.mediumImpact();
      _thresholdFired = true;
    } else if (!past) {
      _thresholdFired = false; // re-arms if the finger retreats (:2242-2244)
    }
    _indicatorLit = past;
    _setDx(_dir * dist);
  }

  void _onEnd(DragEndDetails d) {
    // Commit when the (capped) travel sits past the threshold at release
    // (messages.js:2249-2253); the action is the one locked at claim.
    if (_active && !_abandoned && _dx.abs() >= _threshold) {
      widget.onAction(_action);
    }
    _springBack();
  }

  void _onCancel() => _springBack();

  void _springBack() {
    _active = false;
    _abandoned = false;
    _thresholdFired = false;
    final from = _dx;
    if (from == 0) {
      setState(() {
        _dir = 0;
        _indicatorLit = false;
      });
      return;
    }
    final anim = CurvedAnimation(parent: _settle, curve: Curves.easeOut);
    void tick() => _setDx(from * (1 - anim.value));
    anim.addListener(tick);
    _settle.forward(from: 0).whenCompleteOrCancel(() {
      anim.removeListener(tick);
      if (!mounted) return;
      // The chip lingered through the 250ms spring-back — remove it now
      // (`setTimeout(() => indicator.remove(), 250)`, messages.js:2257-2259).
      setState(() {
        _dx = 0;
        _dir = 0;
        _indicatorLit = false;
      });
      widget.avatarDx?.value = 0;
    });
  }

  String? _actionSvg(String action) {
    switch (action) {
      case 'quote':
        return ctxActionSvg(CtxAction.quote);
      case 'translate':
        return ctxActionSvg(CtxAction.translate);
      case 'copy':
        return ctxActionSvg(CtxAction.copyMessage);
      case 'react':
        return null; // emoji glyph, rendered as text below
      case 'zap':
        return ctxActionSvg(CtxAction.zap);
      case 'slap':
        return ctxActionSvg(CtxAction.slap);
      case 'hug':
        return ctxActionSvg(CtxAction.hug);
      default:
        return null;
    }
  }

  /// The `.swipe-reply-indicator` chip (styles-chat.css:1592-1667): a 32px
  /// `primary@0.15` circle holding the action glyph — SVG icons 16px tinted
  /// `--primary`, the react emoji 23px text, a custom-emoji image 28px. It is
  /// a CHILD of the translated row, positioned 40px OUTSIDE the edge the row
  /// is leaving (`right:-40px` for left swipes, `left:-40px` for right swipes,
  /// `left:-86px` past the group avatar), vertically centered — so it FOLLOWS
  /// the finger. Opacity 0 until the drag passes the threshold, then 1 over
  /// 0.15s ease (`.visible`).
  Widget _buildIndicator(BuildContext context) {
    final c = context.nym;
    Widget glyph;
    if (_action == 'react') {
      final fallback = Text(
        widget.settings.swipeReactEmoji,
        style: const TextStyle(fontSize: 23, height: 1),
      );
      final url = widget.swipeReactEmojiUrl;
      // `.swipe-react-emoji-img` custom emoji render at 28px, contain-fit.
      glyph = url == null
          ? fallback
          : InlineNetworkImage(
              url: proxiedMedia(url, emoji: true),
              width: 28,
              height: 28,
              fit: BoxFit.contain,
              retryOnError: true,
              errorChild: fallback,
            );
    } else {
      final svg = _actionSvg(_action);
      glyph = svg == null
          ? const SizedBox.shrink()
          : NymSvgIcon(svg, size: 16, color: c.primary);
    }
    // Right swipes on a bubble that sits beside the group avatar park the chip
    // PAST the avatar (`swipe-reply-indicator-past-avatar`, left:-86px).
    final pastAvatar = _dir > 0 && widget.avatarDx != null;
    return Positioned(
      top: 0,
      bottom: 0,
      right: _dir < 0 ? -40 : null,
      left: _dir < 0 ? null : (pastAvatar ? -86 : -40),
      child: Center(
        child: AnimatedOpacity(
          opacity: _indicatorLit ? 1 : 0,
          // `transition: opacity 0.15s ease`.
          duration: const Duration(milliseconds: 150),
          curve: Curves.ease,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // `background: rgb(from var(--primary) r g b / 0.15)`.
              color: c.primaryA(0.15),
            ),
            child: glyph,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The chip exists from the moment the gesture is claimed until 250ms after
    // release (transparent below the threshold), riding INSIDE the translated
    // subtree so it moves with the finger.
    Widget body = widget.child;
    if (_dir != 0) {
      body = Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          _buildIndicator(context),
        ],
      );
    }

    final p = Theme.of(context).platform;
    final touchPlatform =
        p == TargetPlatform.android || p == TargetPlatform.iOS;
    Widget result = GestureDetector(
      // The PWA's long-press / dblclick surface is the whole `.message` row —
      // including the blank run beside a narrow bubble — so empty areas must
      // hit-test too.
      behavior: HitTestBehavior.translucent,
      // dblclick quote-reply is DESKTOP-ONLY: the PWA bails on touch devices
      // (`if ('ontouchstart' in window) return`, messages.js:2284-2285). Not
      // registering it on touch also spares every tap the double-tap
      // disambiguation delay.
      onDoubleTap: touchPlatform ? null : widget.onDoubleTap,
      onSecondaryTap: widget.onSecondaryTap,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: body,
      ),
    );

    // The 500ms quick-react hold, with the PWA's tight cancel slop: ANY
    // `touchmove` / a >5px mouse move kills the pending hold
    // (`MSG_LONG_PRESS_MOVE_THRESHOLD = 5` + the unconditional touchmove
    // cancel, ui-context.js:1600-1650) — NOT the framework's default ~18px
    // kTouchSlop drift, which would still pop the menu on a slow scroll.
    result = RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _TightLongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
            _TightLongPressGestureRecognizer>(
          () => _TightLongPressGestureRecognizer(debugOwner: this),
          (r) => r..onLongPressStart = widget.onLongPressStart,
        ),
      },
      child: result,
    );

    // The swipe claims TOUCH pointers only (the PWA binds touchstart/touchmove
    // — any touch screen gets it, mouse drags never do), with travel measured
    // from the touch-down point (DragStartBehavior.down) so SWIPE_START and
    // the action threshold match the PWA's finger distances exactly.
    if (widget.settings.gesturesEnabled) {
      result = RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(
              supportedDevices: const {PointerDeviceKind.touch},
            ),
            (r) => r
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = _onStart
              ..onUpdate = _onUpdate
              ..onEnd = _onEnd
              ..onCancel = _onCancel,
          ),
        },
        child: result,
      );
    }
    return result;
  }
}

/// A [LongPressGestureRecognizer] with the PWA's tighter pre-fire cancel slop
/// for the message quick-react hold (ui-context.js:1598-1650): the PWA cancels
/// the pending 500ms timer on ANY `touchmove` and on a mouse move past
/// `MSG_LONG_PRESS_MOVE_THRESHOLD = 5` px — far tighter than the framework's
/// default ~18px kTouchSlop drift. Browsers only emit a `touchmove` once the
/// touch actually moves, so the same 5px displacement reads as "the finger
/// moved" for touch too (and stays robust against sub-pixel sensor jitter).
/// Movement AFTER the 500ms deadline no longer matters (the popup is already
/// up), so the check applies only before the deadline elapses.
class _TightLongPressGestureRecognizer extends LongPressGestureRecognizer {
  _TightLongPressGestureRecognizer({super.debugOwner});

  /// `MSG_LONG_PRESS_MOVE_THRESHOLD` (ui-context.js:1600).
  static const double _moveThreshold = 5;

  Offset _downPosition = Offset.zero;
  Duration _downTime = Duration.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (event.pointer == primaryPointer) {
      _downPosition = event.position;
      _downTime = event.timeStamp;
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent &&
        event.pointer == primaryPointer &&
        state == GestureRecognizerState.possible &&
        event.timeStamp - _downTime < (deadline ?? kLongPressTimeout) &&
        (event.position - _downPosition).distance > _moveThreshold) {
      // Same rejection path the built-in pre-accept slop check takes.
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    super.handleEvent(event);
  }
}
