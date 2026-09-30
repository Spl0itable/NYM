import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants/relays.dart';
import '../../core/crypto/bech32_codec.dart' show encodeNevent;
import 'event_details_sheet.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/commands/command_i18n.dart';
import '../../features/i18n/i18n.dart';
import '../../features/messages/flood_tracker.dart';
import '../../features/messages/format/message_content.dart';
import '../../features/messages/inline_network_image.dart';
import '../../features/settings/about_screen.dart';
import '../../features/p2p/p2p_models.dart';
import '../../features/p2p/p2p_service.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/reactions/quick_context_items.dart';
import '../../features/threads/thread_view.dart' show openMessageThread;
import '../../features/reactions/quick_react_popup.dart';
import '../../features/reactions/reaction_burst.dart';
import 'relative_time_ticker.dart';
import '../../features/reactions/reactors_modal.dart';
import '../../features/translate/translate_target.dart';
import '../../features/translate/message_translation.dart';
import '../../features/translate/translated_messages.dart';
import '../../features/zaps/zap_badge.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../services/storage/mesh_file_store.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'bitchat_user_color.dart';
import 'crypto_pq_badge.dart';
import 'crypto_verified_badge.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/interaction_hooks.dart';
import '../context_menu/profile_badges.dart';
import '../anchored_popup.dart';

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
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Full "date, time" label for a tapped timestamp, honoring the time and date format settings.
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

/// Port of the PWA `_formatRelativeTime`: `now`, `{m}m ago`, `{h}h ago`, `{d}d ago`, then a date.
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
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final mo = months[t.month - 1];
  return t.year == ref.year ? '$mo ${t.day}' : '$mo ${t.day}, ${t.year}';
}

/// Marks a `/groupinfo` system row whose content encodes a structured payload rendered by [MessageRow].
const String kGroupInfoSystemPrefix = '\u0000group-info\u0000';

/// Already ordered owner, mods, members (each alphabetized).
typedef GroupInfoMember = ({String pubkey, List<String> labels});

typedef GroupInfoPayload = ({
  String name,
  int count,
  List<GroupInfoMember> members,
});

String encodeGroupInfoSystemMessage(GroupInfoPayload info) {
  return kGroupInfoSystemPrefix +
      jsonEncode({
        'name': info.name,
        'count': info.count,
        'members': [
          for (final m in info.members) {'pk': m.pubkey, 'labels': m.labels},
        ],
      });
}

/// Null for any other content.
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

/// Port of the PWA `abbreviateNumber`: <1000 verbatim, then `1.2k`/`12k`, `1.2M`.
String abbreviateNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return '${v.toStringAsFixed(n < 10000 ? 1 : 0)}k';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// Renders one message in IRC or bubble layout, with reactions, context menu and quick-react interactions.
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
    this.scrollKey,
    this.showThreadAffordances = true,
  });

  final Message message;
  final Settings settings;
  final List<MessageReaction> reactions;
  final bool mentioned;

  /// False inside the thread panel, which must not render thread links or entries for its own rows.
  final bool showThreadAffordances;

  /// Storage key of the hosting list so a quote tap jumps that list; null in the single-chat view.
  final String? scrollKey;

  /// Columns-deck variant: IRC rows stack vertically and hover buttons stack.
  final bool columnsMode;

  /// Set on a group's last message to key the bubble, so the gliding avatar aligns to it, not the group foot.
  final GlobalKey? bubbleAnchorKey;

  final bool grouped;

  final bool showAvatar;

  final bool showName;

  /// Inside a [MessageGroup], which owns the horizontal padding and sticky avatar; emit only the content stack.
  final bool inGroup;

  /// Null makes the add-reaction affordances no-ops.
  final ValueChanged<Message>? onReactionPicker;

  /// Swipe offset for the group's sticky avatar, supplied for an others' group's last bubble only.
  final ValueNotifier<double>? swipeAvatarDx;

  @override
  ConsumerState<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends ConsumerState<MessageRow> {
  /// Held in app state because lazy list rows don't keep State across scrolling or inserts.
  String get _translateKey =>
      widget.message.nymMessageId ?? widget.message.id;

  bool get _showTranslation =>
      ref.watch(translatedMessagesProvider).containsKey(_translateKey);

  String? get _translateLangOverride =>
      ref.watch(translatedMessagesProvider)[_translateKey];

  void _showTranslated({String? lang}) => ref
      .read(translatedMessagesProvider.notifier)
      .show(_translateKey, lang: lang);

  /// Desktop hover state; only set on hover-capable platforms.
  bool _hovered = false;

  /// Whether subscribed to the shared 30s [RelativeTimeTicker].
  bool _relativeTickerSubscribed = false;

  /// Snap-in plays only for live-appended grouped messages (created in the last few seconds); latched on first build.
  late final bool _snapIn = widget.grouped &&
      widget.settings.useBubbles &&
      !widget.message.isHistorical &&
      DateTime.now().difference(widget.message.dateTime).inMilliseconds < 5000;

  @override
  void dispose() {
    if (_relativeTickerSubscribed) {
      RelativeTimeTicker.instance.removeListener(_onRelativeTick);
      _relativeTickerSubscribed = false;
    }
    super.dispose();
  }

  void _onRelativeTick() {
    if (mounted) setState(() {});
  }

  Message get message => widget.message;
  Settings get settings => widget.settings;
  List<MessageReaction> get reactions => widget.reactions;

  /// Null gives the identicon fallback.
  String? get _authorPicture =>
      ref.watch(usersProvider)[message.pubkey]?.profile?.picture;

  bool get _isVerified {
    final controller = ref.read(nostrControllerProvider);
    return controller.isVerifiedDeveloper(message.pubkey) ||
        controller.isVerifiedBot(message.pubkey);
  }

  /// Selects only this author's friend flag so ambient app-state emits don't rebuild every row.
  bool get _isFriendAuthor =>
      !message.isOwn &&
      ref.watch(appStateProvider.select((s) => s.isFriend(message.pubkey)));

  /// Post-quantum shield state, or null; separate from [_cryptoState] (confidentiality vs authentication).
  PqBadgeState? get _pqState {
    if (!message.isPM && !message.isGroup) return null;
    return pqBadgeStateFor(
      pqEncrypted: message.pqEncrypted,
      pqRoot: message.pqRoot,
      pqCoverage: message.pqCoverage,
      isGroup: message.isGroup,
    );
  }

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

  static final RegExp _htmlTagRe = RegExp(r'<[^>]*>');

  static final RegExp _dupSuffixRe =
      RegExp(r'@([^@#\s]+)#([0-9a-f]{4})#\2\b', caseSensitive: false);

  /// `.mentioned` highlight: port of the PWA's case-insensitive `isMentioned`; never for self or PM/group rows.
  bool _isMentionedRow() {
    if (message.isOwn || message.isPM) return false;
    if (widget.mentioned) return true;
    final cleanNym = stripPubkeySuffix(ref.read(appStateProvider).selfNym);
    if (cleanNym.isEmpty) return false;
    final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
    final rawSuffix = selfPubkey != null ? getPubkeySuffix(selfPubkey) : '';
    // `????` means a non-hex tail, so no suffix.
    final sfx = rawSuffix == '????' ? '' : RegExp.escape(rawSuffix);
    final esc = RegExp.escape(cleanNym);
    var clean = message.content
        .replaceAll(_htmlTagRe, '')
        .replaceAllMapped(_dupSuffixRe, (m) => '@${m[1]}#${m[2]}');
    // A `> @me:` quote-reply addressed to us still counts.
    final quoteToMe = RegExp('^\\s*>+\\s*@$esc(?:#$sfx)?\\s*:',
        caseSensitive: false, multiLine: true);
    if (quoteToMe.hasMatch(clean)) return true;
    // Mentions inside quoted lines don't highlight.
    clean = clean
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('>'))
        .join('\n');
    // `@nym` followed by our suffix, or by anything that is not another 4-hex suffix.
    final tail = sfx.isNotEmpty
        ? '(?:#$sfx\\b|(?!#[0-9a-f]{4})(?:\\b|\$))'
        : '(?!#[0-9a-f]{4})(?:\\b|\$)';
    return RegExp('@$esc$tail', caseSensitive: false).hasMatch(clean);
  }

  /// Reply count for a thread root (0 hides the link).
  int get _threadReplyCount {
    if (!appThreadsEnabled || !widget.showThreadAffordances) return 0;
    final m = message;
    if (m.threadRoot != null || m.isSystemRow || m.isMeAction) return 0;
    final key =
        widget.scrollKey ?? ref.read(appStateProvider).view.storageKey;
    final counts = ref.watch(threadCountsProvider(key));
    return counts[threadKeyForMessage(m)] ?? 0;
  }

  bool get _threadTapEligible =>
      appThreadsEnabled &&
      widget.showThreadAffordances &&
      (message.threadRoot != null || threadEligibleRoot(message));

  Widget _threadIndicator(BuildContext context, int count) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () =>
            openMessageThread(ref, message, storageKey: widget.scrollKey),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: c.primaryA(0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.primaryA(0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NymSvgIcon(NymIcons.thread, size: 14, color: c.primary),
              const SizedBox(width: 6),
              Text(
                count == 1
                    ? tr('1 reply')
                    : tr('{n} replies', {'n': abbreviateNumber(count)}),
                style: TextStyle(
                  color: c.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasZaps {
    final z = ref.watch(zapsProvider)[message.id];
    return z != null && z.totalSats > 0;
  }

  /// Only above the mobile breakpoint and for messages with a usable reaction id.
  bool _hoverButtonsEligible(BuildContext context) {
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return false;
    }
    if (message.isPM && (message.nymMessageId?.isNotEmpty ?? false)) {
      return true;
    }
    return RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(message.id);
  }

  void _ensureRelativeTimer() {
    if (_relativeTickerSubscribed) return;
    _relativeTickerSubscribed = true;
    RelativeTimeTicker.instance.addListener(_onRelativeTick);
  }

  /// Resolved from the shop controller (self) or presence.
  UserCosmetics get _cosmetics =>
      ref.watch(userCosmeticsProvider(message.pubkey));

  /// The supporter gold treatment composes over an active style, as the PWA applies both classes.
  MessageStyleDecoration? _styleDecoration(BuildContext context) {
    final cos = _cosmetics;
    final c = context.nym;
    final isLight = c.isLight;
    final solidUi = c.solidUi;
    final styled =
        messageStyleDecoration(cos.styleId, isLight: isLight, solidUi: solidUi);
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

  /// Aura cosmetics resolved for the current brightness and solid-ui.
  List<CosmeticAura> _resolveAuras(BuildContext context) =>
      resolveCosmeticAuras(_cosmetics,
          isLight: context.nym.isLight, solidUi: context.nym.solidUi);

  /// Raw `style-…` classes trip the CSS `:not([class*="style-"])` gates; `supporter-style` does not.
  bool get _styleClassActive =>
      _cosmetics.styleId?.startsWith('style-') ?? false;

  Widget _nymBadges(BuildContext context, {double flairSize = 16}) {
    return CosmeticNymBadges(
      cosmetics: _cosmetics,
      flairSize: flairSize,
      supporterHeight: flairSize,
    );
  }

  /// Author label for both layouts: nym with dimmed `#suffix` (brackets IRC-only) then badges.
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
    // Genesis holders' suffix is raised to weight 400.
    final suffixWeight =
        hasGenesisFlair(_cosmetics) ? FontWeight.w400 : FontWeight.w100;
    // Prefer the live profile nym over the one frozen at ingest; watched so rows repaint when it lands.
    final liveNym = ref.watch(
        usersProvider.select((u) => u[message.pubkey]?.nym));
    // Strip the suffix so the canonical one isn't appended twice.
    final baseNym = pickDisplayNym(liveNym, message.author);
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
        if (_isVerified) ...[
          const SizedBox(width: 4),
          VerifiedBadge(size: flairSize),
        ],
        if (_isFriendAuthor) ...[
          const SizedBox(width: 4),
          FriendBadge(size: flairSize),
        ],
        if (brackets)
          Text('>', style: TextStyle(color: bracketColor, fontSize: size)),
      ],
    );
  }

  /// Bolds Genesis holders only; supporter gold never applies to the author nym.
  TextStyle _authorStyle(NymColors c,
      {required bool self, required double size}) {
    final genesis = hasGenesisFlair(_cosmetics);
    // The redacted cosmetic dims the author nym too; light mode uses a dark nym.
    final color = _cosmetics.isRedacted
        ? (c.isLight
            ? const Color(0xFF1A1A1A).withValues(alpha: 0.75)
            : Colors.white.withValues(alpha: 0.8))
        : (self ? c.primary : (_bitchatColor(c) ?? c.secondary));
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: genesis ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0.2,
    );
  }

  /// Per-user color for a non-self author in the Bitchat theme only; applied to both nym and body.
  Color? _bitchatColor(NymColors c) {
    if (message.isOwn) return null;
    if (settings.theme != NymThemeKey.bitchat) return null;
    return bitchatUserColor(message.pubkey, isLight: c.isLight);
  }

  /// Body: a P2P file-offer card, a redacted block, or rich content tinted by the active style.
  Widget _bodyContent(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
    bool bubble = false,
  }) {
    if (message.isFileOffer && message.fileOffer != null) {
      final p2p = ref.read(p2pServiceProvider);
      // Stop broadcasts with the open channel's wire tag (`g` or `d`), like the PWA.
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
    // Locally stored mesh media renders inline in place of the text body.
    if (message.hasLocalMedia) {
      return _LocalMediaBody(
        path: message.localMediaPath!,
        mime: message.localMediaMime,
        name: message.localMediaName,
        colors: context.nym,
      );
    }
    // Redacted cosmetic: real text for 10s, then a translucent bar.
    final Widget body;
    if (_cosmetics.isRedacted) {
      body = _RedactedReveal(
        fontSize: fontSize,
        child: _content(context, color, fontSize, deco: deco, bubble: bubble),
      );
    } else {
      body = _content(context, color, fontSize, deco: deco, bubble: bubble);
    }
    // A bot reply's reasoning section is prepended inside the content.
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
    if (message.isSystemRow) return _buildSystemMessage(context);
    if (message.isMeAction) return _buildActionMessage(context);
    Widget row =
        settings.useBubbles ? _buildBubble(context) : _buildIrc(context);
    // Hover-capable devices track row hover and overlay the quick-react/translate buttons at top-right.
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
                    onTranslate: _showTranslated,
                    onThread: appThreadsEnabled &&
                            widget.showThreadAffordances &&
                            (message.threadRoot != null ||
                                threadEligibleRoot(message))
                        ? () => openMessageThread(ref, message,
                            storageKey: widget.scrollKey)
                        : null,
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
    // Dim live flooding senders only; PMs and historical backlog are never dimmed.
    if (!message.isOwn &&
        !message.isPM &&
        !message.isHistorical &&
        ref.watch(floodTrackerProvider).isFlooding(message.pubkey)) {
      row = Opacity(opacity: 0.2, child: row);
    }
    // IRC rows take a whole-row thread tap; in bubble mode only the bubble is the target.
    if (!settings.useBubbles && _threadTapEligible) {
      final tappableRow = row;
      row = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () =>
            openMessageThread(ref, message, storageKey: widget.scrollKey, silent: true),
        child: tappableRow,
      );
    }
    // Pulse the highlight when a quote tap scrolls to this message.
    final flashing = ref.watch(flashedMessageProvider) == message.id;
    return _ScrollFlashOverlay(active: flashing, child: row);
  }

  /// Centered system pill; `.action-message` is a bare left-aligned italic line; optional action button below.
  Widget _buildSystemMessage(BuildContext context) {
    final c = context.nym;
    final isAction = message.kind == MessageKind.action;
    final size = settings.textSize.toDouble() - 3;
    // Action messages replace the `.system-message` class, so no pill or centering.
    final text = Text(
      message.content,
      textAlign: isAction ? TextAlign.start : TextAlign.center,
      style: TextStyle(
        color: isAction ? c.purple : c.textDim,
        // Action text inherits a fixed 14px; only system pills scale with text size.
        fontSize: isAction ? 14 : size,
        fontStyle: isAction ? FontStyle.italic : FontStyle.normal,
        // CSS weight 450; w500 is nearest.
        fontWeight: isAction ? FontWeight.w400 : FontWeight.w500,
        height: 1.3,
      ),
    );
    final action = message.systemAction;
    final groupInfo =
        isAction ? null : decodeGroupInfoSystemMessage(message.content);
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

  /// `/groupinfo` block; nyms and avatars resolve live so late profiles fill in.
  Widget _groupInfoBlock(
      BuildContext context, GroupInfoPayload info, double size) {
    final c = context.nym;
    final users = ref.watch(usersProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Group: "{name}"', {'name': info.name}),
          style: TextStyle(
            color: c.textDim,
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          tr('Members ({count})', {'count': info.count}),
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

  Widget _groupInfoMemberRow(
    BuildContext context,
    Map<String, User> users,
    GroupInfoMember member,
    double size,
  ) {
    final c = context.nym;
    final pk = member.pubkey;
    final baseNym = pickDisplayNym(users[pk]?.nym, null);
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
        CosmeticNymBadges(
          cosmetics: ref.watch(userCosmeticsProvider(pk)),
          flairSize: 20,
          supporterHeight: 20,
        ),
        if (member.labels.isNotEmpty) ...[
          const SizedBox(width: 6),
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

  /// The spam false-positive action opens the About contact form prefilled with the message.
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

  /// `/me` emote as an italic `* author action *` line in a pill.
  Widget _buildActionMessage(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble() - 3;
    final action = message.content.startsWith('/me ')
        ? message.content.substring(4)
        : message.content;
    final suffix = getPubkeySuffix(message.pubkey);
    // Cap both parts to the pill's content width so long nyms ellipsize and actions wrap.
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
            // A Wrap lets the action flow to the next line instead of overflowing.
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: GestureDetector(
                    onTap: () => _openContextMenu(context),
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
                                text: pickDisplayNym(
                                    ref.watch(usersProvider.select(
                                        (u) => u[message.pubkey]?.nym)),
                                    message.author),
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
                        _nymBadges(context, flairSize: 20),
                      ],
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: MessageContent(
                          content: action,
                          fontSize: fontSize,
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

  Widget _buildIrc(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;

    final deco = _styleDecoration(context);
    final mentioned = _isMentionedRow();

    Color? bg;
    Color? barColor;
    Color? barGlow = mentioned ? c.secondaryA(0.4) : null;
    if (self) {
      bg = c.secondaryA(0.05);
      barColor = c.isLight
          ? const Color(0x40000000)
          : const Color(0x4DFFFFFF);
    } else if (mentioned) {
      bg = c.isLight
          ? const Color(0x08000000)
          : c.secondaryA(0.06);
      barColor = c.secondary;
    }
    // The hover tint replaces self/mention fills (it follows them in the CSS); bubble mode has none.
    if (_hovered) {
      bg = c.isLight
          ? Colors.black.withValues(alpha: 0.03)
          : (message.isPM
              ? const Color(0x0AFF00FF)
              : Colors.white.withValues(alpha: 0.03));
      if (message.isPM) {
        barColor = c.purple;
        barGlow = const Color(0x4DFF00FF);
      }
    }
    List<Color>? bgGradient;
    // IRC paints supporter accents on the row; style content plates belong to the content box.
    if (deco?.borderAccent != null) {
      barColor = deco!.borderAccent;
      bgGradient = deco.backgroundGradient ?? bgGradient;
    }
    // Gold/neon/phoenix/cosmic auras are row-scoped in IRC; frost/rainbow/hologram decorate the content box.
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
    // The cosmic starfield tiles the whole IRC row.
    final CosmeticAura? rowWatermarkAura = rowAuras
        .where((a) => a.watermark != null)
        .fold<CosmeticAura?>(null, (prev, a) => prev ?? a);

    // PWA order: time, author, content; the 50px time column keeps left edges aligned.
    final Widget? timeItem = settings.showTimestamps
        ? ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 50),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TimestampText(
                  label: formatTime(message.dateTime, settings.timeFormat),
                  fullTimestamp: formatFullTimestamp(message.dateTime,
                      settings.timeFormat, settings.dateFormat),
                  fontSize: 12,
                  powEventId: message.id,
                  powTarget: message.powTarget,
                  copyPubkey: message.pubkey,
                  // Public channel messages only; PM/group rows carry no mined work.
                  powApplies: !message.isPM && !message.isGroup,
                  detailNym: message.author,
                  detailChannel: message.geohash ?? message.channel,
                  detailCreatedAt: message.dateTime,
                ),
                if (_cryptoState != null)
                  CryptoVerifiedBadge(state: _cryptoState!),
                if (_pqState != null)
                  CryptoPqBadge(
                      state: _pqState!, coverage: message.pqCoverage),
                if (message.viaMesh) _MeshBadge(color: context.nym.primary),
              ],
            ),
          )
        : null;
    final authorItem = ConstrainedBox(
      // No max-width: the author grows naturally and the row reflows around it.
      constraints: const BoxConstraints(minWidth: 120),
      child: GestureDetector(
        onTap: () => _openContextMenu(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NymAvatar(seed: message.pubkey, size: 18, imageUrl: _authorPicture),
            const SizedBox(width: 4),
            Flexible(
              child: _authorLine(
                c,
                self: self,
                size: fontSize,
                flairSize: 20,
                brackets: true,
              ),
            ),
          ],
        ),
      ),
    );
    // Content-targeted styles, watermarks and cosmetics decorate this box, not the row; reactions sit outside it.
    Widget contentBody =
        _bodyContent(context, _bitchatColor(c) ?? c.text, fontSize, deco: deco);
    // Frost's icy fill applies only when no message style is active.
    Color? contentFill = deco?.contentBackgroundFor(bubble: false);
    if (contentFill == null && !_styleClassActive) {
      contentFill = contentAuras
          .where((a) => a.background != null)
          .fold<Color?>(null, (prev, a) => prev ?? a.background);
    }
    final styleWatermark = deco?.watermark;
    final CosmeticAura? contentWatermarkAura = styleWatermark != null
        ? null
        : contentAuras
            .where((a) => a.watermark != null)
            .fold<CosmeticAura?>(null, (prev, a) => prev ?? a);
    final contentWatermark = styleWatermark ?? contentWatermarkAura?.watermark;
    final contentEdgeWatermark = contentWatermarkAura?.edgeWatermark ?? false;
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
                      radius: BorderRadius.zero,
                      bubble: false,
                      // Hologram fill and sheen drop when a style class is active; the ring and glow stay.
                      styleActive: _styleClassActive,
                    ),
                  ),
                ),
              ),
          ],
        );
      }
      contentBody = Container(
        width: widget.columnsMode ? double.infinity : null,
        padding: deco?.contentPadding,
        decoration: BoxDecoration(
          color: contentFill,
          boxShadow: contentShadows.isEmpty ? null : contentShadows,
        ),
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
        // Reactions row only when reactions or zaps exist; the add button appears only with existing reactions.
        if (reactions.isNotEmpty || _hasZaps)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _reactionsRow(context),
          ),
        if (_threadReplyCount > 0)
          _threadIndicator(context, _threadReplyCount),
      ],
    );

    // Full-width siblings (translation, readers) are hoisted out so they span the message; columns mode stacks the row.
    final Widget messageRow;
    if (widget.columnsMode) {
      messageRow = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (timeItem != null) ...[
            timeItem,
            const SizedBox(height: 5),
          ],
          authorItem,
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: contentColumn),
        ],
      );
    } else {
      messageRow = Wrap(
        crossAxisAlignment: WrapCrossAlignment.start,
        // CSS single-value gap applies to both axes.
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

    final rowChildren = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        messageRow,
        // Top-level sibling after the content, so it right-aligns across the whole row.
        if (message.isEdited)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                tr('(edited)'),
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.7),
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        if (_showReaderAvatars) _readerAvatars(context),
        if (self && message.isPM && !message.isGroup) _deliveryTicks(context),
      ],
    );

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
    // Row-aura inset rings are approximated by a 1px border; content rings are painted above.
    final rowRing = rowAura?.insetColor;
    final rowGlowColor = rowAura?.glowColorFor(bubble: false);
    final rowGlowBlur = rowAura?.glowBlurFor(bubble: false) ?? 0;
    final hasBg = bg != null || bgGradient != null;
    final content = Container(
      // Full-width so translation and reader rows line up across the message.
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgGradient == null ? bg : null,
        gradient: bgGradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bgGradient,
              )
            : null,
        borderRadius: hasBg ? NymRadius.rsm : null,
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
    // Prism/hologram/frost overlays are content-scoped and painted by the content box, not the row.
    return _SwipeToAct(
      settings: settings,
      onAction: (a) => _dispatchSwipeAction(context, a),
      onDoubleTap: _quoteReply,
      // Quick-react popup anchored to the press point.
      onLongPressStart: (d) => _onMessageLongPress(context, d.globalPosition),
      onSecondaryTap: () => _openContextMenu(context),
      swipeReactEmojiUrl: _swipeReactEmojiUrl,
      child: content,
    );
  }

  Widget _buildBubble(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;
    final deco = _styleDecoration(context);
    final mentioned = _isMentionedRow();

    final auras = _resolveAuras(context);
    final lastAura = auras.isNotEmpty ? auras.last : null;
    // Only gold's aura fills the bubble, and only without a style; ghost + solid-ui flattens translucent washes.
    final ghostSolid = c.solidUi && settings.theme == NymThemeKey.ghost;
    final bubbleGradient = (!ghostSolid &&
            lastAura != null &&
            lastAura.bubblePaintsGradient &&
            !_styleClassActive)
        ? lastAura.bubbleFillGradient
        : null;
    // Style fill wins via its bubble-layout resolution; self fire/ice (and rainbow under solid-ui) keep the self fill.
    final selfFireIce = self &&
        (_cosmetics.styleId == 'style-fire' ||
            _cosmetics.styleId == 'style-ice' ||
            (c.solidUi && _cosmetics.styleId == 'style-rainbow'));
    // Solid-ui gold-aura plate applies to styled messages too; unstyled ones take it via [bubbleGradient].
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
      // Only an unstyled or fire/ice/rainbow self bubble keeps the self gray under ghost-solid.
      final flattenedToOther = _cosmetics.styleId == 'style-satoshi' ||
          _cosmetics.supporter ||
          auras.any((a) => a.id == 'cosmetic-aura-gold');
      bubbleColor =
          (self && !flattenedToOther) ? c.bubbleSelfBg : c.bubbleOtherBg;
    } else if (selfFireIce) {
      bubbleColor = c.solidUi ? c.bubbleSelfBg : c.primaryA(0.25);
    } else if (_styleClassActive && auraStyledFill != null) {
      bubbleColor = auraStyledFill;
    } else {
      bubbleColor = deco?.contentBackgroundFor(bubble: true) ??
          (_styleClassActive || self ? null : lastAura?.background) ??
          (self ? c.bubbleSelfBg : c.bubbleOtherBg);
    }
    final radius = _bubbleRadius(self);

    // Interior: body then the in-bubble time line; delivery ticks and translation are siblings below the bubble.
    final timeLine = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isEdited)
          Text(
            '${tr('(edited)')} ',
            style: TextStyle(
                color: c.textDim.withValues(alpha: 0.7),
                fontSize: 10,
                fontStyle: FontStyle.italic),
          ),
        // Relative time, not clock; tapping opens the timestamp popup.
        _TimestampText(
          powEventId: message.id,
          powTarget: message.powTarget,
          copyPubkey: message.pubkey,
          powApplies: !message.isPM && !message.isGroup,
          detailNym: message.author,
          detailChannel: message.geohash ?? message.channel,
          detailCreatedAt: message.dateTime,
          label: formatRelativeTime(message.dateTime),
          fullTimestamp: formatFullTimestamp(
              message.dateTime, settings.timeFormat, settings.dateFormat),
          fontSize: 10,
          height: 1,
        ),
        if (_cryptoState != null) CryptoVerifiedBadge(state: _cryptoState!),
        if (_pqState != null)
          CryptoPqBadge(state: _pqState!, coverage: message.pqCoverage),
        if (message.viaMesh) _MeshBadge(color: context.nym.primary),
      ],
    );
    // A hidden copy of the time line reserves space; the visible one is pinned so the bubble shrink-wraps.
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

    _ensureRelativeTimer();

    final bubble = LayoutBuilder(builder: (context, box) {
      // Bubble min 180px, max 85% (90% at <=768px) of the row, not the screen; the min wins.
      final screenW = MediaQuery.of(context).size.width;
      final availW = box.maxWidth.isFinite ? box.maxWidth : screenW;
      final pct = screenW <= NymDimens.mobileBreakpoint ? 0.90 : 0.85;
      final capW = (availW * pct).clamp(180.0, double.infinity);
      return ConstrainedBox(
        constraints: BoxConstraints(minWidth: 180, maxWidth: capW),
        child: _decorateBubble(
          radius: radius,
          bubbleColor: bubbleColor,
          gradient: bubbleGradient,
          auras: auras,
          // Mention ring as a 1px inner border; solid-ui strokes the full secondary color.
          mentionRing: mentioned
              ? (c.solidUi ? c.secondary : c.secondaryA(c.isLight ? 0.2 : 0.25))
              : null,
          child: Padding(
            // A style's own content padding (satoshi 10/15) outranks the bubble default.
            padding:
                deco?.contentPadding ?? const EdgeInsets.fromLTRB(12, 8, 12, 6),
            // Re-assert the 180px floor on the interior so the pinned time hugs the right padding edge.
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  minWidth: 180 - (deco?.contentPadding?.horizontal ?? 24)),
              child: innerContent,
            ),
          ),
        ),
      );
    });

    // The stack stretches so translation/readers span it; shrink-wrapped items are re-aligned per side.
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
                child: _authorLine(
                  c,
                  self: self,
                  size: 11,
                  flairSize: 20,
                ),
              ),
            ),
          ),
        Align(
          alignment: sideAlign,
          // Key the bubble itself so the group avatar aligns to it; in bubble mode only the bubble opens the thread.
          child: KeyedSubtree(
            key: widget.bubbleAnchorKey,
            child: _threadTapEligible
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => openMessageThread(ref, message,
                        storageKey: widget.scrollKey, silent: true),
                    child: bubble,
                  )
                : bubble,
          ),
        ),
        // Delivery ticks sit on their own right-aligned line below the bubble, as in IRC.
        if (self && message.isPM && !message.isGroup) _deliveryTicks(context),
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        if (_showReaderAvatars) _readerAvatars(context),
        if (reactions.isNotEmpty || _hasZaps)
          Align(
            alignment: sideAlign,
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: _reactionsRow(context),
            ),
          ),
        if (_threadReplyCount > 0)
          Align(
            alignment: sideAlign,
            child: _threadIndicator(context, _threadReplyCount),
          ),
      ],
    );

    // Bubble mode also paints a faint gold wash across the whole row for gold-aura users, in both themes.
    Widget rowStack = stack;
    if (auras.any((a) => a.id == 'cosmetic-aura-gold')) {
      rowStack = DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0x0DFFD700),
              Color(0x00FFD700),
            ],
          ),
        ),
        child: stack,
      );
    }

    // The whole row (name, bubble, extras) slides with a swipe, like the PWA.
    final swiped = _SwipeToAct(
      settings: settings,
      onAction: (a) => _dispatchSwipeAction(context, a),
      onDoubleTap: _quoteReply,
      // Quick-react popup anchored to the press point.
      onLongPressStart: (d) => _onMessageLongPress(context, d.globalPosition),
      onSecondaryTap: () => _openContextMenu(context),
      avatarDx: widget.swipeAvatarDx,
      swipeReactEmojiUrl: _swipeReactEmojiUrl,
      child: rowStack,
    );

    // Snap-in overshoot entrance for a newly appended grouped bubble; disabled under reduced motion.
    Widget rowBody = swiped;
    if (_snapIn && !MediaQuery.of(context).disableAnimations) {
      rowBody = _BubbleSnapIn(self: self, child: rowBody);
    }

    // Negative CSS margins can't be expressed between list items, so gaps are driven from the top edge.
    final vPad = EdgeInsets.only(top: widget.grouped ? 2 : 6);

    // Inside a [MessageGroup], emit only the content stack; the group owns padding and the avatar.
    if (widget.inGroup) {
      return Padding(padding: vPad, child: rowBody);
    }

    // Standalone path (not via [MessageGroup]) with its own 32px avatar.
    final row = Row(
      mainAxisAlignment: self ? MainAxisAlignment.end : MainAxisAlignment.start,
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
      padding:
          EdgeInsets.fromLTRB(self ? 14 : 6, widget.grouped ? 2 : 6, 14, 0),
      child: row,
    );
  }

  /// Aura shadows, gradient, watermark and overlays around the bubble, clipped to [radius].
  Widget _decorateBubble({
    required BorderRadius radius,
    required Color bubbleColor,
    required List<Color>? gradient,
    required List<CosmeticAura> auras,
    required Widget child,
    Color? mentionRing,
  }) {
    // No box-shadow from the style: its glow is a text-shadow, and a BoxShadow bleeds through the fill.
    final shadows = <BoxShadow>[];
    for (final a in auras) {
      final blur = a.glowBlurFor(bubble: true);
      final glowColor = a.glowColorFor(bubble: true);
      if (glowColor != null && blur > 0) {
        shadows.add(BoxShadow(color: glowColor, blurRadius: blur));
      }
    }
    // Skip the border when the overlay painter already strokes the ring, or it doubles.
    final lastAura = auras.isNotEmpty ? auras.last : null;
    final inset = (lastAura != null &&
            lastAura.insetColor != null &&
            !lastAura.hasOverlay)
        ? lastAura
        : null;

    // The cosmic starfield tiles only without a style; frost's edge snowflakes have no such gate.
    final styleWatermark = _styleDecoration(context)?.watermark;
    final CosmeticAura? auraWatermark = styleWatermark != null
        ? null
        : auras
            .where((a) =>
                a.watermark != null && (a.edgeWatermark || !_styleClassActive))
            .fold<CosmeticAura?>(null, (prev, a) => prev ?? a);
    final watermark = styleWatermark ?? auraWatermark?.watermark;
    final edgeWatermark = auraWatermark?.edgeWatermark ?? false;

    final overlays = auras.where((a) => a.hasOverlay).toList();
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
                      // Hologram fill and sheen drop when a style class is active; the ring and glow stay.
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

  /// Own channel or group message with readers shows reader avatars instead of the PM tick.
  bool get _showReaderAvatars =>
      message.isOwn &&
      !message.isPM &&
      (message.isGroup || _isChannelMessage) &&
      message.readers.isNotEmpty;

  /// Named channels also carry read receipts natively, so they qualify alongside geohash channels.
  bool get _isChannelMessage {
    if (message.isPM || message.isGroup) return false;
    if ((message.geohash ?? '').isEmpty && (message.channel ?? '').isEmpty) {
      return false;
    }
    return RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(message.id);
  }

  /// Up to 3 overlapping reader avatars plus `+N`; long-press opens a "seen by" modal.
  Widget _readerAvatars(BuildContext context) {
    const maxVisible = 3;
    final entries = message.readers.entries.toList();
    final visible = entries.take(maxVisible).toList();
    final overflow = entries.length - visible.length;
    final c = context.nym;
    final users = ref.watch(usersProvider);
    // The Builder wraps only the avatars, since the modal anchors to its context's render box.
    return Padding(
      padding: const EdgeInsets.only(top: 3, right: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.max,
        children: [
          Builder(
            builder: (avatarContext) => GestureDetector(
              onLongPress: () {
                // A solid 30ms pulse, so mediumImpact.
                HapticFeedback.mediumImpact();
                _showSeenBy(avatarContext);
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
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
          ),
        ],
      ),
    );
  }

  void _showSeenBy(BuildContext context) {
    final users = ref.read(usersProvider);
    final reactors = <ReactorEntry>[
      for (final e in message.readers.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: pickDisplayNym(users[e.key]?.nym, e.value),
          suffix: getPubkeySuffix(e.key),
          imageUrl: users[e.key]?.profile?.picture,
        ),
    ];
    showReactorsModal(
      context,
      anchorRect: _globalRectOfContext(context) ?? Rect.zero,
      emoji: '',
      title:
          tr('Seen by {count}', {'count': abbreviateNumber(reactors.length)}),
      reactors: reactors,
      onTapReactor: (r) => _openReactorContextMenu(context, r),
    );
  }

  Widget _reactionsRow(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ZapBadge(message: message),
        for (final r in reactions)
          _ReactionBadge(
            messageId: message.id,
            reaction: r,
            onTap: (rect) => _toggleReaction(context, r),
            onLongPress: (rect) => _showReactors(context, r, rect),
          ),
        // The add-reaction button appears only on rows that already have reactions.
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
    // The optimistic local update is synchronous; publishing continues unawaited.
    unawaited(controller.toggleReaction(
      message.id,
      r.emoji,
      target: reactionTargetFor(message),
      kind: kind,
    ));
    // Buzz and burst on add as soon as it lands locally; a rate-limited toggle stays silent.
    if (!wasReacted && _selfReactedLocally(r.emoji)) {
      HapticFeedback.mediumImpact();
      // Post-frame so the badge is laid out; falls back to the message center.
      ReactionBurst.playAtBadge(context, message.id, r.emoji,
          fallbackCenter: _globalCenterOfContext(context));
    }
  }

  bool _selfReactedLocally(String emoji) {
    final list = ref.read(appStateProvider).reactions[message.id] ?? const [];
    return list.any((x) => x.emoji == emoji && x.userReacted);
  }

  void _showReactors(BuildContext context, MessageReaction r, Rect rect) {
    HapticFeedback.mediumImpact();
    final app = ref.read(appStateProvider);
    final users = ref.read(usersProvider);
    final map =
        ref.read(appStateProvider.notifier).reactorsFor(message.id, r.emoji) ??
            const {};
    // Resolve missing reactor avatars; faces fill in on the next open.
    ref.read(nostrControllerProvider).ensureProfiles(map.keys);
    final reactors = <ReactorEntry>[
      for (final e in map.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: pickDisplayNym(users[e.key]?.nym, e.value),
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
      onTapReactor: (entry) => _openReactorContextMenu(context, entry),
    );
  }

  /// Opens a reactor/reader's user context menu, not profile-only and without a message.
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
    HapticFeedback.mediumImpact();
    // Zero-size anchor at the press point reproduces the PWA's `clientX - w/2, clientY - 55` placement.
    final rect = Rect.fromCenter(center: at, width: 0, height: 0);
    // Recents first, padded with the defaults, deduped.
    final recents = ref.read(recentEmojisProvider);
    showQuickReactPopup(
      context,
      anchorRect: rect,
      // Spotlight the pressed message's bounds, distinct from the press-point anchor.
      spotlightRect: _globalRectOfContext(context),
      emojis: quickReactEmojis(recents),
      onReact: (emoji) => _quickReact(context, emoji),
      onMore: () => widget.onReactionPicker?.call(message),
      contextItems: buildQuickContextItems(
        context,
        ref,
        message,
        onTranslate: _showTranslated,
        onEdit: () => ref.read(pendingEditProvider.notifier).request(
              messageId: message.id,
              content: message.content,
            ),
        onThread: appThreadsEnabled &&
                widget.showThreadAffordances &&
                (message.threadRoot != null || threadEligibleRoot(message))
            ? () =>
                openMessageThread(ref, message, storageKey: widget.scrollKey)
            : null,
      ),
    );
  }

  void _quickReact(BuildContext context, String emoji) {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final already = reactions.any((r) => r.emoji == emoji && r.userReacted);
    ref.read(recentEmojisProvider.notifier).record(emoji);
    unawaited(controller.toggleReaction(
      message.id,
      emoji,
      target: reactionTargetFor(message),
      kind: inferOriginalKind(message, view: view),
    ));
    // Buzz and burst with the optimistic add, before any publish.
    if (!already && _selfReactedLocally(emoji)) {
      HapticFeedback.mediumImpact();
      ReactionBurst.playAtBadge(context, message.id, emoji,
          fallbackCenter: _globalCenterOfContext(context));
    }
  }

  /// Custom-emoji image URL for a known `:shortcode:` swipe emoji; null uses the text glyph.
  String? get _swipeReactEmojiUrl {
    final m =
        RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(settings.swipeReactEmoji);
    if (m == null) return null;
    final code = m.group(1)!;
    return ref.watch(liveCustomEmojiProvider.select((s) => s.codeToUrl[code]));
  }

  /// Runs the committed swipe action through the same paths as the long-press menu.
  void _dispatchSwipeAction(BuildContext context, String action) {
    final controller = ref.read(nostrControllerProvider);
    // Use the displayed nym, not the one frozen on the message.
    final baseNym = _baseNym(_displayNym());
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
        _showTranslated();
        return;
      case 'copy':
        if (message.content.isEmpty) return;
        Clipboard.setData(ClipboardData(text: message.content));
        ref
            .read(appStateProvider.notifier)
            .addSystemMessage(tr('Message copied to clipboard'));
        return;
      case 'react':
        _quickReact(context, settings.swipeReactEmoji);
        return;
      case 'zap':
        if (message.pubkey.isEmpty) return;
        // Zapping your own message prints a notice instead of silently no-opping.
        if (message.isOwn) {
          ref
              .read(appStateProvider.notifier)
              .addSystemMessage(tr('Cannot zap your own message'));
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

  /// Posts a checking note, resolves the LN address fresh (not just cache), then opens the modal or reports failure.
  Future<void> _zapMessage(BuildContext context, String baseNym) async {
    final notifier = ref.read(appStateProvider.notifier);
    notifier.addSystemMessage(
        tr('Checking if @{nym} can receive zaps...', {'nym': baseNym}));
    final String? lnAddr;
    try {
      lnAddr = await ref
          .read(nostrControllerProvider)
          .resolveLightningAddressForZap(message.pubkey);
    } catch (_) {
      notifier.addSystemMessage(
          tr('Failed to check if @{nym} can receive zaps', {'nym': baseNym}));
      return;
    }
    if (lnAddr == null || lnAddr.isEmpty) {
      notifier.addSystemMessage(tr(
          '@{nym} cannot receive zaps (no lightning address set)',
          {'nym': baseNym}));
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

  /// Shared by desktop double-click and the swipe `quote` action.
  void _quoteReply() {
    if (message.content.isEmpty) return;
    final baseNym = _baseNym(_displayNym());
    final fullNym = '$baseNym#${getPubkeySuffix(message.pubkey)}';
    ref
        .read(pendingComposerActionProvider.notifier)
        .requestQuote(fullNym: fullNym, content: message.content);
  }

  void _openContextMenu(BuildContext context) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(message,
        selfPubkey: app.selfPubkey, liveNym: app.users[message.pubkey]?.nym);
    ContextMenuPanel.show(
      context,
      target: target,
      message: message,
      onReact: () => widget.onReactionPicker?.call(message),
      onTranslateInline: (lang) => _showTranslated(lang: lang),
    );
  }

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

  // Only a trailing `#xxxx` is stripped; a `#` inside the name belongs to it.
  String _baseNym(String nym) => splitNymSuffix(nym).base;

  /// Read, not watched, so action paths can call it outside build.
  String _displayNym() {
    final live = ref.read(appStateProvider).users[message.pubkey]?.nym;
    return pickDisplayNym(live, message.author);
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

  /// Never for own messages; otherwise per `blurOthersImages` (always, or only non-friends).
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
    var displayContent = message.content;
    // Only the synthetic Nymbot welcome row is app copy and gets translated; everything else renders as authored.
    if (message.id.startsWith(kNymbotWelcomeIdPrefix)) {
      displayContent = localizeBotWelcome(message.id, displayContent);
    }
    // Show bot command names in the vocabulary this device accepts.
    if (message.isBot ||
        ref.read(nostrControllerProvider).isVerifiedBot(message.pubkey)) {
      displayContent = localizeCommandTokensIn(displayContent);
    }
    final body = MessageContent(
      content: displayContent,
      baseColor: deco?.textColorFor(bubble: bubble) ?? color,
      fontSize: fontSize,
      blurImages: blur,
      glyphShadows: deco?.textShadows,
      monospace: deco?.monospace ?? false,
      // Lets a tapped blockquote exclude the host message when finding its source.
      hostMessageId: message.id,
      scrollKey: widget.scrollKey,
    );
    final gradient = deco?.gradient;
    if (gradient != null && gradient.length >= 2) {
      // srcIn would clip a glyph shadow away, so the aurora glow is a separate shadow-only copy underneath.
      final clipped = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          begin: const Alignment(-0.87, 0.5),
          end: const Alignment(0.87, -0.5),
          colors: gradient,
        ).createShader(rect),
        child: MessageContent(
          content: displayContent,
          baseColor: Colors.white,
          fontSize: fontSize,
          blurImages: blur,
          hostMessageId: message.id,
          scrollKey: widget.scrollKey,
        ),
      );
      final glow = deco?.gradientGlow;
      if (glow == null) return clipped;
      return Stack(
        children: [
          MessageContent(
            content: displayContent,
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
    // PWA delivery glyphs: read ✓✓ blue, delivered ✓ green, sent ✓ dim, failed ! red.
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
        // The failed `!` is a tap-to-retry affordance.
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _retryFailedPm,
            child: Tooltip(
              message: tr('Failed to send - click to retry'),
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

  /// Drops the failed bubble and sends a fresh copy to the stored peer (or the active PM peer).
  void _retryFailedPm() {
    final content = message.content;
    if (content.trim().isEmpty) return;
    final view = ref.read(currentViewProvider);
    final peer = message.conversationPubkey ??
        (view.kind == ViewKind.pm ? view.id : null);
    if (peer == null || peer.isEmpty) return;
    final appState = ref.read(appStateProvider.notifier);
    final controller = ref.read(nostrControllerProvider);
    // Remove first so the retry produces a single fresh echo.
    appState.removeMessage(message.id);
    // `sendCurrent` publishes to the current view, so switch to the PM thread first.
    controller.startPM(peer);
    controller.sendCurrent(content);
  }
}

/// A reaction badge: tap toggles, long-press shows reactors; no hover tooltip, as in the PWA.
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

  /// Registered with [ReactionBurst] so bursts anchor at this badge.
  final GlobalKey _anchorKey = GlobalKey();

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
    // Burst when another user's live reaction increments the badge; own adds burst from the toggle paths.
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

  /// Only a whole-string `:shortcode:` can render as a custom-emoji image.
  static final RegExp _rxWholeToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final r = widget.reaction;
    return RawGestureDetector(
      key: _anchorKey,
      // Cancel the hold on the first move, not the framework's ~18px slop, so scrolls from a badge don't pop the modal.
      gestures: <Type, GestureRecognizerFactory>{
        _TightLongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
            _TightLongPressGestureRecognizer>(
          () => _TightLongPressGestureRecognizer(debugOwner: this),
          (rec) =>
              rec..onLongPressStart = (_) => widget.onLongPress(_rect(context)),
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
            scale: _pressed ? 0.95 : (_hover ? 1.05 : 1.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.ease,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.ease,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                // `.user-reacted` follows `:hover` at equal specificity, so its fill wins while hovered.
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
              // Only an exact `:shortcode:` renders as an image (count 3px apart); plain text is one "emoji count" run.
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

/// Add-reaction pill opening the full picker; touch surfaces the CSS hover as a press state.
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
        // The 0.6 rest opacity is folded into each color's alpha, avoiding a per-frame saveLayer on every row.
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _pressed
                ? c.primaryA(0.08)
                : Colors.white.withValues(alpha: 0.04 * 0.6),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(
              color: _pressed
                  ? c.primaryA(0.3)
                  : c.glassBorder
                      .withValues(alpha: c.glassBorder.a * 0.6),
            ),
          ),
          child: NymSvgIcon(
            NymIcons.addReaction,
            size: 16,
            color: _pressed ? c.text : c.text.withValues(alpha: c.text.a * 0.6),
          ),
        ),
      ),
    );
  }
}

/// Inline action button for a system pill.
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

/// Shows the real message for 10 seconds, then a translucent redacted bar.
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
    final isLight = context.nym.isLight;
    return Container(
      constraints: BoxConstraints(
        minWidth: 120,
        minHeight: widget.fontSize * 1.2,
      ),
      decoration: BoxDecoration(
        color: isLight
            ? const Color(0x1F000000)
            : Colors.white.withValues(alpha: 0.15),
        borderRadius: NymRadius.rxs,
      ),
    );
  }
}

/// Collapsible "Reasoning" block a bot reply prepends inside its content.
class _BotThinkSection extends StatefulWidget {
  const _BotThinkSection({
    required this.reasoning,
    required this.fontSize,
  });

  final String reasoning;

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
              decoration: _expanded
                  ? BoxDecoration(border: Border(bottom: side))
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.fastOutSlowIn,
                    turns: _expanded ? 0.25 : 0,
                    child: Text('▸',
                        style: TextStyle(color: c.textDim, fontSize: fs)),
                  ),
                  const SizedBox(width: 6),
                  Text(tr('💭 Reasoning'),
                      style: TextStyle(
                          color: c.textDim,
                          fontSize: fs,
                          fontWeight: FontWeight.w400)),
                ],
              ),
            ),
          ),
          if (_expanded)
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

/// Non-interactive highlight pulse over 1.8s, played each time [active] rises after a quote jump.
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
    duration: const Duration(milliseconds: 1800),
    vsync: this,
  );

  // Keyframe opacity: 0 at 0%, 1 from 8% to 45%, 0 at 100%.
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
      tween:
          Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)),
      weight: 8,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 37),
    TweenSequenceItem(
      tween:
          Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeOut)),
      weight: 55,
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

/// Desktop hover quick-action buttons at a message's top-right; the host fades them with row hover.
class _MsgHoverButtons extends StatelessWidget {
  const _MsgHoverButtons({
    required this.onReact,
    required this.onTranslate,
    this.onThread,
    this.vertical = false,
  });

  /// Null leaves the button rendered but inert.
  final VoidCallback? onReact;
  final VoidCallback onTranslate;

  /// Null hides the button (threads disabled, or already inside a thread view).
  final VoidCallback? onThread;

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final children = [
      _HoverActionButton(svg: NymIcons.addReaction, onTap: onReact),
      SizedBox(width: vertical ? 0 : 4, height: vertical ? 4 : 0),
      if (onThread != null) ...[
        _HoverActionButton(
          svg: NymIcons.thread,
          onTap: onThread,
          tooltip: tr('Reply in thread'),
        ),
        SizedBox(width: vertical ? 0 : 4, height: vertical ? 4 : 0),
      ],
      _HoverActionButton(
        svg: NymIcons.translate,
        onTap: onTranslate,
        tooltip: tr('Translate'),
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
        ? const Color(0xD9FFFFFF)
        : const Color(0xCC141423);
    final restBorder =
        c.isLight ? Colors.black.withValues(alpha: 0.08) : c.glassBorder;
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
            color: _hover ? Colors.white.withValues(alpha: 0.08) : restFill,
            borderRadius: NymRadius.rxs,
            border: Border.all(color: _hover ? c.primaryA(0.3) : restBorder),
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

/// Copies an event reference and confirms in place for a moment.
class _CopyRefButton extends StatefulWidget {
  const _CopyRefButton({required this.label, required this.value});
  final String label;
  final String value;

  @override
  State<_CopyRefButton> createState() => _CopyRefButtonState();
}

class _CopyRefButtonState extends State<_CopyRefButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: _copy,
      borderRadius: NymRadius.rsm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          _copied ? tr('Copied') : widget.label,
          softWrap: false,
          style: TextStyle(
              color: _copied ? c.primary : c.text, fontSize: 11),
        ),
      ),
    );
  }
}

/// Full width below the copy buttons, as in the PWA.
class _DetailsButton extends StatelessWidget {
  const _DetailsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          tr('Show all event details'),
          softWrap: false,
          style: TextStyle(color: c.text, fontSize: 11),
        ),
      ),
    );
  }
}

/// Tappable timestamp: hover tints and shows a tooltip; tap opens the anchored timestamp popup.
class _TimestampText extends StatefulWidget {
  const _TimestampText({
    required this.label,
    required this.fullTimestamp,
    required this.fontSize,
    this.height,
    this.powEventId,
    this.powTarget,
    this.powApplies = false,
    this.copyPubkey = '',
    this.detailNym,
    this.detailChannel,
    this.detailCreatedAt,
  });

  final String label;
  final String fullTimestamp;
  final double fontSize;
  final double? height;

  /// Included so the copied `nevent` carries the author.
  final String copyPubkey;

  final String? powEventId;

  /// NIP-13 target from the `nonce` tag; null means no tag.
  final int? powTarget;

  /// PMs and group messages are gift-wrapped and never mined, so PoW is omitted rather than shown as "none".
  final bool powApplies;

  /// Fallback data for the details panel when no signed event is held.
  final String? detailNym;
  final String? detailChannel;
  final DateTime? detailCreatedAt;

  @override
  State<_TimestampText> createState() => _TimestampTextState();
}

class _TimestampTextState extends State<_TimestampText> {
  bool _hover = false;
  OverlayEntry? _popup;

  /// App sends are always mined (16-bit floor), so no nonce tag means no work; chance zeros don't count.
  List<Widget> _powRows(NymColors c) {
    if (!widget.powApplies) return const [];
    final target = widget.powTarget;
    final label = Text(
      tr('Proof-of-work'),
      softWrap: false,
      style: TextStyle(color: c.textDim, fontSize: 12),
    );

    late final Widget value;
    if (target == null) {
      value = Text(
        tr('None'),
        softWrap: false,
        style: TextStyle(color: c.primary, fontSize: 12),
      );
    } else {
      final bits = powBitsForId(widget.powEventId);
      final short = target > 0 && bits < target;
      final text = target > 0
          ? (short
              ? tr('{bits} bits · target {target} (below target)',
                  {'bits': bits, 'target': target})
              : tr('{bits} bits · target {target}',
                  {'bits': bits, 'target': target}))
          : tr('{bits} bits', {'bits': bits});
      value = Text(
        text,
        softWrap: false,
        style: TextStyle(
          // A message short of its own target is shown as such, not rounded up.
          color: short ? c.textDim : c.primary,
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }

    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Divider(height: 1, thickness: 1, color: c.glassBorder),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [label, const SizedBox(width: 8), value],
        ),
      ),
    ];
  }

  /// Nothing for rows without a real event id (optimistic echo, system line, poll).
  List<Widget> _copyRows(NymColors c) {
    final id = widget.powEventId ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(id)) {
      return const [];
    }
    final nevent = encodeNevent(id,
        author: widget.copyPubkey,
        relays: RelayConfig.defaultRelays.take(3).toList());
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Divider(height: 1, thickness: 1, color: c.glassBorder),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (nevent.isNotEmpty) ...[
              _CopyRefButton(label: tr('Copy nevent'), value: nevent),
              const SizedBox(width: 6),
            ],
            _CopyRefButton(label: tr('Copy event ID'), value: id),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _DetailsButton(
          onTap: () {
            _closePopup();
            showEventDetails(
              context,
              eventId: id,
              pubkey: widget.copyPubkey,
              nym: widget.detailNym,
              channel: widget.detailChannel,
              createdAt: widget.detailCreatedAt,
              powTarget: widget.powTarget,
            );
          },
        ),
      ),
    ];
  }

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

  /// Right-aligned to the timestamp, 6px above when there is room, else below; the barrier closes it.
  void _openPopup() {
    _closePopup();
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final overlay = Overlay.of(context);
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
            AnchoredPopup(
              anchor: rect,
              align: PopupAlign.end,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 160, maxWidth: 280),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: c.bgSecondary,
                    borderRadius: NymRadius.rmd,
                    border: Border.all(
                      color: c.isLight
                          ? Colors.black.withValues(alpha: 0.08)
                          : c.glassBorder,
                    ),
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
                            BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                            const BoxShadow(
                                color: Color(0x0DFFFFFF), spreadRadius: 1),
                          ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.fullTimestamp,
                        softWrap: false,
                        style: TextStyle(color: c.text, fontSize: 13),
                      ),
                      ..._powRows(c),
                      ..._copyRows(c),
                    ],
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
          // Hover-only: tap opens the popup and long-press belongs to quick-react.
          triggerMode: TooltipTriggerMode.manual,
          waitDuration: Duration.zero,
          preferBelow: false,
          verticalOffset: 14,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.isLight
                ? const Color(0xEBFFFFFF)
                : const Color(0xE6141423),
            borderRadius: NymRadius.rxs,
            border: Border.all(
              color: c.isLight
                  ? Colors.black.withValues(alpha: 0.08)
                  : c.glassBorder,
            ),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x4D000000),
                  offset: Offset(0, 2),
                  blurRadius: 8),
            ],
          ),
          textStyle:
              TextStyle(fontSize: 11, color: c.isLight ? c.text : c.textDim),
          child: AnimatedDefaultTextStyle(
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

/// P2P file-offer card; stateful because a card seen seeded keeps its button and flips it to "Unavailable".
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

  /// Open channel's wire key so Stop broadcasts with `g` or `d`; both null for PM/group.
  final String? seedGeohash;
  final String? seedChannelName;

  @override
  State<FileOfferCard> createState() => _FileOfferCardState();
}

class _FileOfferCardState extends State<FileOfferCard> {
  FileOffer get offer => widget.offer;
  bool get isOwn => widget.isOwn;
  P2PService get service => widget.service;

  /// True once rendered seeded, so a later unseeded flip keeps the button.
  bool _sawSeeded = false;

  /// The PWA uses one file glyph and only re-tints the stroke per category.
  static Color _category(NymColors c, FileOffer o) {
    final ext =
        o.name.contains('.') ? o.name.split('.').last.toLowerCase() : '';
    final mime = o.type.toLowerCase();
    bool any(List<String> exts) => exts.contains(ext);
    if (any(['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma']) ||
        mime.startsWith('audio/')) {
      return c.purple;
    }
    if (any(['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm']) ||
        mime.startsWith('video/')) {
      return c.danger;
    }
    if (any(['zip', 'rar', '7z', 'tar', 'gz', 'bz2'])) {
      return c.warning;
    }
    if (any(
        ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'])) {
      return c.secondary;
    }
    return c
        .primary;
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
        P2PTransfer? transfer;
        for (final t in service.transfers) {
          if (t.offerId == offer.offerId) transfer = t;
        }
        // Read in the same build, so no setState needed.
        if (!unseeded) _sawSeeded = true;

        return Container(
          constraints: const BoxConstraints(maxWidth: 350),
          margin: const EdgeInsets.symmetric(vertical: 8),
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
                          '${offer.type.isEmpty ? tr('Unknown type') : offer.type}'
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
    if (isOwn) {
      if (unseeded) {
        return _dotRow(c, tr('No longer seeding'));
      }
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            _SeedingDot(color: c.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(tr('Seeding - available for download'),
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
    // A peer offer first rendered unseeded shows the bare dot row.
    if (unseeded && !_sawSeeded) {
      return _dotRow(c, tr('No longer available'));
    }

    // The peer button stays through the lifecycle: Download, Connecting..., Downloaded, Retry, or Unavailable.
    final active = transfer != null &&
        (transfer.status == P2PStatus.connecting ||
            transfer.status == P2PStatus.transferring);
    final base = offer.isTorrent ? c.secondary : c.primary;
    final Widget button;
    if (unseeded) {
      button = _OfferBtn(
        label: tr('Unavailable'),
        textColor: c.textDim,
        borderColor: c.textDim,
        fillColor: base.withValues(alpha: 0.08),
        opacity: 0.4,
        onTap: null,
      );
    } else if (active) {
      button = _OfferBtn(
        label: tr('Connecting...'),
        textColor: c.secondary,
        borderColor: c.secondary,
        fillColor: base.withValues(alpha: 0.08),
        onTap: null,
      );
    } else if (transfer != null && transfer.status == P2PStatus.complete) {
      button = _OfferBtn(
        label: tr('Downloaded'),
        textColor: base,
        borderColor: base.withValues(alpha: 0.25),
        fillColor: base.withValues(alpha: 0.08),
        onTap: null,
      );
    } else if (transfer != null && transfer.status == P2PStatus.error) {
      button = _OfferBtn(
        label: tr('Retry'),
        textColor: base,
        borderColor: base.withValues(alpha: 0.25),
        fillColor: base.withValues(alpha: 0.08),
        onTap: () => service.requestFile(offer.offerId),
      );
    } else {
      button = _OfferBtn(
        label: offer.isTorrent ? tr('Download (Torrent)') : tr('Download'),
        textColor: base,
        borderColor: base.withValues(alpha: 0.25),
        fillColor: base.withValues(alpha: 0.08),
        onTap: () => service.requestFile(offer.offerId),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.only(top: 10), child: button),
        // Revealed on request and never re-hidden.
        if (transfer != null) ...[
          const SizedBox(height: 10),
          // LinearProgressIndicator can't paint a gradient, so use a Stack.
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
          // Mid-transfer shows `<pct>% • <speed>/s`; otherwise the last status.
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

  String _progressText(P2PTransfer transfer) {
    if (transfer.status == P2PStatus.transferring) {
      final elapsed =
          (DateTime.now().millisecondsSinceEpoch - transfer.startTime) / 1000;
      final speed =
          elapsed > 0 ? (transfer.bytesReceived / elapsed).round() : 0;
      return '${transfer.progress.toStringAsFixed(1)}% • '
          '${formatFileSize(speed)}/s';
    }
    return transfer.message ?? tr('Connecting...');
  }

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

  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.5).chain(CurveTween(curve: Curves.ease)),
      weight: 50,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.5, end: 1.0).chain(CurveTween(curve: Curves.ease)),
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

/// A null [onTap] renders an inert state.
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
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child:
            Text(tr('Stop'), style: TextStyle(color: c.danger, fontSize: 10)),
      ),
    );
  }
}

/// Folds oldest-first messages into same-author bubble runs; shared by the single-chat and columns views.
List<List<MessageGroupEntry>> buildMessageGroups(
  List<Message> messages, {
  required Map<String, List<MessageReaction>> reactions,
  required bool useBubbles,
  String mentionToken = '',
}) {
  // Same predicate as messages_list `_groupsWith`.
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
      // Mention flags never apply to self or PM/group rows, nor while the self nym is unknown.
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

/// Reactions and mention flag are resolved once by the list.
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

/// Same-author bubble run beside one gliding avatar; IRC and system/`/me` rows render bare.
class MessageGroup extends ConsumerStatefulWidget {
  const MessageGroup({
    super.key,
    required this.entries,
    required this.settings,
    this.columnsMode = false,
    this.onReactionPicker,
    this.scrollKey,
  });

  final List<MessageGroupEntry> entries;
  final Settings settings;

  /// Forwarded so a quote tap jumps this list; null in the single-chat view.
  final String? scrollKey;

  /// Columns-deck variant; on desktop the self group drops its 14px right padding.
  final bool columnsMode;
  final ValueChanged<Message>? onReactionPicker;

  @override
  ConsumerState<MessageGroup> createState() => _MessageGroupState();
}

class _MessageGroupState extends ConsumerState<MessageGroup> {
  /// Kept stable so the keyed bubble subtree isn't torn down each frame.
  final GlobalKey _bubbleKey = GlobalKey();

  /// Live swipe offset of the last bubble, so the group avatar slides with it.
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

    // Only the lead carries a name; `inGroup` strips rows so the group hosts one avatar.
    List<Widget> buildRows() => [
          for (var i = 0; i < entries.length; i++)
            MessageRow(
              key: ValueKey(entries[i].message.id),
              message: entries[i].message,
              settings: settings,
              reactions: entries[i].reactions,
              mentioned: entries[i].mentioned,
              columnsMode: widget.columnsMode,
              scrollKey: widget.scrollKey,
              grouped: useBubbles && i > 0,
              showName: !(useBubbles && i > 0),
              showAvatar: false,
              inGroup: useBubbles,
              onReactionPicker: onReactionPicker,
              bubbleAnchorKey: i == entries.length - 1 ? _bubbleKey : null,
              swipeAvatarDx: useBubbles && !self && i == entries.length - 1
                  ? _avatarDx
                  : null,
            ),
        ];

    if (!useBubbles || first.isSystemRow || first.isMeAction) {
      final rows = buildRows();
      return rows.length == 1
          ? rows.first
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    }

    // Force full width; a stretch column would otherwise shrink-wrap and break full-width rows and right alignment.
    final stack = SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: buildRows(),
      ),
    );

    // Desktop columns mode drops the right padding for self groups.
    if (self) {
      final flushRight = widget.columnsMode &&
          MediaQuery.of(context).size.width > NymDimens.mobileBreakpoint;
      return Padding(
        padding: EdgeInsets.only(left: 14, right: flushRight ? 0 : 14),
        child: stack,
      );
    }

    // The avatar is a Positioned overlay in the left gutter so it can glide without affecting the bubble column.
    final last = entries.last.message;
    final picture = ref
        .watch(usersProvider.select((m) => m[first.pubkey]?.profile?.picture));
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
      child: Stack(
        // Swipes are clipped only at the scroller, so the indicator chip may paint over group padding.
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

  /// Opens the context menu for the group's last message.
  void _openAvatarMenu(BuildContext context, WidgetRef ref, Message last) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(last,
        selfPubkey: app.selfPubkey, liveNym: app.users[last.pubkey]?.nym);
    ContextMenuPanel.show(
      context,
      target: target,
      message: last,
      onReact: () => widget.onReactionPicker?.call(last),
    );
  }
}

/// Sticky group avatar: rests at the group's foot, or pins 8px above the viewport bottom while the group spans it.
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

  /// Aligns the resting avatar to the last bubble rather than the reactions/translation rows; null uses the foot.
  final GlobalKey? bubbleKey;

  @override
  State<_StickyGroupAvatar> createState() => _StickyGroupAvatarState();
}

class _StickyGroupAvatarState extends State<_StickyGroupAvatar> {
  static const double _stickyGap = 8;
  static const double _avatar = 32;

  /// Value unused; bumps only drive the rebuild.
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
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

  /// Falls back to the track bottom until the bubble can be measured.
  double _restingTop(double trackHeight) {
    final fallback = (trackHeight - _avatar).clamp(0.0, double.infinity);
    final track = context.findRenderObject();
    final bubble = widget.bubbleKey?.currentContext?.findRenderObject();
    if (track is RenderBox &&
        track.hasSize &&
        bubble is RenderBox &&
        bubble.hasSize) {
      final bubbleBottom = bubble
          .localToGlobal(Offset(0, bubble.size.height), ancestor: track)
          .dy;
      return (bubbleBottom - _avatar).clamp(0.0, fallback);
    }
    return fallback;
  }

  /// Clamping to `[0, maxTop]` is CSS sticky bounded by the containing block.
  double _computeTop(double maxTop) {
    final scrollable = Scrollable.maybeOf(context);
    final track = context.findRenderObject();
    if (scrollable != null && track is RenderBox && track.hasSize) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        final trackTop =
            track.localToGlobal(Offset.zero, ancestor: viewport).dy;
        final desired = viewport.size.height - _stickyGap - _avatar - trackTop;
        return desired.clamp(0.0, maxTop);
      }
    }
    return maxTop;
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
          // Recompute both bounds every tick; the bubble box exists only from the second frame.
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

/// 240ms overshoot snap-in for a live consecutive bubble; each keyframe segment uses the same cubic.
class _BubbleSnapIn extends StatefulWidget {
  const _BubbleSnapIn({required this.self, required this.child});

  final bool self;
  final Widget child;

  @override
  State<_BubbleSnapIn> createState() => _BubbleSnapInState();
}

class _BubbleSnapInState extends State<_BubbleSnapIn>
    with SingleTickerProviderStateMixin {
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
      weight: 25,
    ),
    TweenSequenceItem(
      tween: Tween(begin: -1.0, end: 0.0).chain(CurveTween(curve: _overshoot)),
      weight: 20,
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
        // The overshoot cubic exceeds 1.0 mid-segment, so opacity must clamp.
        opacity: _opacity.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, _dy.value),
          child: Transform.scale(
            scale: _scale.value,
            alignment: widget.self
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Touch-only swipe-to-act; also hosts long-press quick-react and desktop double-click quote.
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

  final ValueChanged<String> onAction;
  final VoidCallback onDoubleTap;

  final GestureLongPressStartCallback onLongPressStart;
  final VoidCallback onSecondaryTap;

  /// Group avatar offset channel for an others' group's last bubble; also selects the past-avatar indicator inset.
  final ValueNotifier<double>? avatarDx;

  /// Null uses the emoji text glyph.
  final String? swipeReactEmojiUrl;
  final Widget child;

  @override
  State<_SwipeToAct> createState() => _SwipeToActState();
}

class _SwipeToActState extends State<_SwipeToAct>
    with SingleTickerProviderStateMixin {
  static const double _swipeStart = 16;
  static const double _edgeZone = 50;
  static const double _followCap = 100;

  /// A direction resolving to anything else (including 'none') abandons the gesture.
  static const Set<String> _knownActions = {
    'quote',
    'translate',
    'copy',
    'react',
    'zap',
    'slap',
    'hug',
  };

  // Created in initState: a lazy field would create a ticker during dispose for never-swiped rows.
  late final AnimationController _settle;

  double _dx = 0;
  double _travel = 0; // Raw finger dx since touch-down.
  int _dir = 0; // Locked at claim: -1 left, +1 right.
  String _action = 'none';
  bool _active = false;
  bool _abandoned = false; // Edge zone or 'none' action.
  bool _thresholdFired = false; // Re-arms below the threshold.
  bool _indicatorLit = false; // Frozen at release for the linger.
  double _startX = 0;
  double _startY = 0;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      // The indicator lingers for the same 250ms spring-back.
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    widget.avatarDx?.value = 0;
    _settle.dispose();
    super.dispose();
  }

  double get _threshold =>
      widget.settings.swipeThreshold.clamp(30, 120).toDouble();

  void _setDx(double v) {
    setState(() => _dx = v);
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
    // DragStartBehavior.down makes this the touch-down point.
    _startX = d.globalPosition.dx;
    _startY = d.globalPosition.dy;
    _settle.stop();
    if (_dx != 0) _setDx(0);
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_abandoned) return;
    // Travel is measured from touch-down, including pre-arena slop, so the thresholds match finger distance.
    _travel += d.delta.dx;
    if (!_active) {
      if (_travel.abs() <= _swipeStart) return;
      // Claim only when horizontal travel exceeds 1.5x vertical; diagonals stay with the scroller.
      final dy = (d.globalPosition.dy - _startY).abs();
      if (_travel.abs() <= dy * 1.5) return;
      // Locked here; dragging back across the origin can't flip the action.
      final dir = _travel < 0 ? -1 : 1;
      // Right swipes from the left edge defer to the sidebar-open gesture.
      if (dir > 0 && _startX < _edgeZone) {
        _abandoned = true;
        return;
      }
      final action = dir < 0
          ? widget.settings.swipeLeftAction
          : widget.settings.swipeRightAction;
      if (!_knownActions.contains(action)) {
        _abandoned = true;
        return;
      }
      _dir = dir;
      _action = action;
      _active = true;
    }
    final double dist = _travel.abs().clamp(0.0, _followCap);
    final past = dist >= _threshold;
    if (past && !_thresholdFired) {
      HapticFeedback.mediumImpact();
      _thresholdFired = true;
    } else if (!past) {
      _thresholdFired = false;
    }
    _indicatorLit = past;
    _setDx(_dir * dist);
  }

  void _onEnd(DragEndDetails d) {
    // Commit at release past the threshold with the action locked at claim.
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
        return null;
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

  /// Swipe indicator chip riding 40px outside the leaving edge inside the translated row; visible past the threshold.
  Widget _buildIndicator(BuildContext context) {
    final c = context.nym;
    Widget glyph;
    if (_action == 'react') {
      final fallback = Text(
        widget.settings.swipeReactEmoji,
        style: const TextStyle(fontSize: 23, height: 1),
      );
      final url = widget.swipeReactEmojiUrl;
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
    // Right swipes beside the group avatar park the chip past it.
    final pastAvatar = _dir > 0 && widget.avatarDx != null;
    return Positioned(
      top: 0,
      bottom: 0,
      right: _dir < 0 ? -40 : null,
      left: _dir < 0 ? null : (pastAvatar ? -86 : -40),
      child: Center(
        child: AnimatedOpacity(
          opacity: _indicatorLit ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.ease,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
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
    // The chip rides inside the translated subtree so it follows the finger.
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
      // The whole row, including blank space beside a bubble, must hit-test.
      behavior: HitTestBehavior.translucent,
      // Desktop-only double-click, which also spares touch taps the double-tap delay.
      onDoubleTap: touchPlatform ? null : widget.onDoubleTap,
      onSecondaryTap: widget.onSecondaryTap,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: body,
      ),
    );

    // 500ms hold cancelled by any move over 5px, tighter than the framework's ~18px slop.
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

    // Touch pointers only, with travel from touch-down so thresholds match the PWA.
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

/// Rejects the pending hold on >5px movement before the deadline, tighter than the default slop.
class _TightLongPressGestureRecognizer extends LongPressGestureRecognizer {
  _TightLongPressGestureRecognizer({super.debugOwner});

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
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    super.handleEvent(event);
  }
}

/// Bluetooth glyph for a message delivered over the mesh.
class _MeshBadge extends StatelessWidget {
  const _MeshBadge({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 3),
      child: NymSvgIcon(NymIcons.bluetooth, size: 11, color: color),
    );
  }
}

/// Body for a mesh-received local file: images inline (fullscreen on tap), others as a shareable file card.
class _LocalMediaBody extends StatelessWidget {
  const _LocalMediaBody({
    required this.path,
    required this.mime,
    required this.name,
    required this.colors,
  });

  final String path;
  final String? mime;
  final String? name;
  final NymColors colors;

  bool get _isImage => mime?.startsWith('image/') ?? false;

  /// Memoized reads so rebuilds don't restart `readAsBytes()` and flicker the image.
  static final Map<String, Future<Uint8List>> _bytesCache = {};

  static Future<Uint8List> _read(String path) {
    final cached = _bytesCache[path];
    if (cached != null) return cached;
    // Soft cap so a long session can't grow the cache unbounded.
    if (_bytesCache.length > 80) _bytesCache.clear();
    return _bytesCache[path] = MeshFileStore.instance.read(path);
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) {
      return FutureBuilder<Uint8List>(
        future: _read(path),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _placeholder();
          }
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) return _fileCard(context);
          return GestureDetector(
            onTap: () => _openFullscreen(context, bytes),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxWidth: 260, maxHeight: 320, minWidth: 80),
                child: Image.memory(bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    // Decode at tile size; the full bytes are kept for fullscreen.
                    cacheWidth: (260 *
                            MediaQuery.devicePixelRatioOf(context) *
                            1.5)
                        .ceil()),
              ),
            ),
          );
        },
      );
    }
    return _fileCard(context);
  }

  Widget _placeholder() => Container(
        width: 160,
        height: 120,
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: colors.textDim),
          ),
        ),
      );

  Widget _fileCard(BuildContext context) {
    final label = (name != null && name!.isNotEmpty) ? name! : 'File';
    return GestureDetector(
      onTap: () => _shareFile(),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NymSvgIcon(NymIcons.fileOffer, size: 20, color: colors.primary),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(color: colors.text, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
            NymSvgIcon(NymIcons.shareNodes, size: 16, color: colors.textDim),
          ],
        ),
      ),
    );
  }

  Future<void> _shareFile() async {
    try {
      final bytes = await _read(path);
      await Share.shareXFiles(
        [XFile.fromData(bytes, mimeType: mime, name: name)],
      );
    } catch (_) {
      // Sharing unavailable (desktop/test).
    }
  }

  void _openFullscreen(BuildContext context, Uint8List bytes) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, __, ___) => _FullscreenImage(
        bytes: bytes,
        onShare: _shareFile,
        colors: colors,
      ),
    ));
  }
}

class _FullscreenImage extends StatelessWidget {
  const _FullscreenImage({
    required this.bytes,
    required this.onShare,
    required this.colors,
  });

  final Uint8List bytes;
  final Future<void> Function() onShare;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: Image.memory(bytes)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.share, color: Colors.white),
                  onPressed: () => onShare(),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
