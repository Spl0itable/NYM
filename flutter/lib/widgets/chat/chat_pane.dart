import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/shortcuts/shortcuts.dart';
import '../../features/layout/info_dock.dart';
import '../../features/toasts/event_toast_area.dart';
import '../../features/layout/info_dock_host.dart';
import '../../features/group_tools/group_tools_ui.dart';
import '../../features/calls/call_history_providers.dart';
import '../../features/calls/call_history_ui.dart';
import '../../features/calls/call_providers.dart';
import '../../features/chat_tools/chat_tools_ui.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/channels/channel_share.dart';
import '../../features/emoji/emoji_prefetch.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/i18n/i18n.dart';
import '../../features/mesh/mesh_controller.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/nymbot/bot_chat_screen.dart' show BotChatScreen;
import '../../features/channels/geohash_place_cache.dart';
import '../../features/nymbot/nymbot_providers.dart'
    show BotChatState, botChatControllerProvider;
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_helpers.dart'
    show geohashLocationLabel;
import '../../features/settings/settings_screen.dart';
import '../../features/group_tools/group_tools.dart' show GroupTools;
import '../../features/layout/layout_model.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/shop/shop_catalog.dart';
import '../../features/shop/shop_widgets.dart' show FlairBadge, SupporterMark;
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../state/view_history.dart';
import '../common/hit_slop.dart';
import '../common/nym_action_sheet.dart';
import '../context_menu/group_context_menu_panel.dart' show showGroupMenuSheet;
import '../common/nym_avatar.dart';
import '../common/nym_label.dart';
import '../nym_icons.dart';
import '../context_menu/profile_badges.dart' show VerifiedBadge;
import '../../features/threads/thread_view.dart' show ThreadView;
import '../columns/columns_deck.dart';
import 'message_row.dart' show formatRelativeTime;
import 'composer.dart';
import '../sidebar/sidebar_chrome.dart';
import '../../features/composer/composer_model.dart';
import 'messages_list.dart';
import '../common/nym_focusable.dart';
import '../common/nym_tooltip.dart';
import '../../core/theme/nym_a11y.dart';

/// Call-start hook; [peer] is the PM peer pubkey, or '' for a channel/group.
typedef OnStartCall = void Function(String peer, {required bool video});

typedef OnStartGroupCall = void Function(String groupId, {required bool video});

/// The main chat column: header, messages list and composer.
class ChatPane extends ConsumerWidget {
  const ChatPane({
    super.key,
    this.onOpenSidebar,
    this.compact = false,
    this.onStartCall,
    this.onStartGroupCall,
    this.useColumns = false,
  });

  final VoidCallback? onOpenSidebar;

  /// Mobile/tablet chrome, driven by `width <= 1024`.
  final bool compact;

  /// Null means no calls.
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  /// Columns mode replaces only the messages region with the deck; the header and composer stay mounted.
  final bool useColumns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Capture the container, not `ref`, so the 3s-deferred emoji prefetch can't touch a disposed ref.
    final container = ProviderScope.containerOf(context, listen: false);
    ref.listen(liveCustomEmojiProvider,
        (_, _) => scheduleCustomEmojiPrefetch(container));
    kickCustomEmojiPrefetch(container);

    // The Nymbot PM always opens the paid bot surface; detection uses the bot pubkey constant, not an async list.
    final view = ref.watch(currentViewProvider);
    // Close a thread from a different conversation on view change, so the shared composer can't mis-thread a send.
    ref.listen(appStateProvider.select((s) => s.view), (_, next) {
      final at = ref.read(activeThreadProvider);
      if (at != null && at.view != next) {
        ref.read(activeThreadProvider.notifier).state = null;
      }
    });
    if (view.kind == ViewKind.pm && view.id.toLowerCase() == kNymbotPubkey) {
      // The bot chat keeps this shared header (preserving nav history) and swaps only the body.
      return Container(
        color: Colors.transparent,
        child: Column(
          children: [
            ReportExtent(
              onExtent: (h) =>
                  ref.read(chatHeaderExtentProvider.notifier).state = h,
              child: _ChatHeader(
                onOpenSidebar: onOpenSidebar,
                compact: compact,
                onStartCall: onStartCall,
                onStartGroupCall: onStartGroupCall,
                columnsMode: useColumns,
              ),
            ),
            Expanded(child: BotChatScreen(onOpenSidebar: onOpenSidebar)),
          ],
        ),
      );
    }

    return Container(
      // Transparent so the wallpaper layer behind the pane shows through.
      color: Colors.transparent,
      child: Column(
        children: [
          ReportExtent(
            onExtent: (h) =>
                ref.read(chatHeaderExtentProvider.notifier).state = h,
            child: _ChatHeader(
              onOpenSidebar: onOpenSidebar,
              compact: compact,
              onStartCall: onStartCall,
              onStartGroupCall: onStartGroupCall,
              columnsMode: useColumns,
            ),
          ),
          // The deck or an open thread replaces only the messages list, not the header or composer.
          Expanded(
            // Tap-outside dismisses the soft keyboard; interactive children still win the gesture arena.
            child: EventToastAreaReporter(
              target: eventToastRegion,
              child: ComposerOverhangInset(child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              excludeFromSemantics: true,
              onTap: () => FocusScope.of(context).unfocus(),
              child: KeyedSubtree(
                key: TutorialTargets.keyFor(TutorialTarget.messagesContainer),
                child: Consumer(builder: (context, paneRef, _) {
                  final at = paneRef.watch(activeThreadProvider);
                  final threadOpen =
                      at != null && at.view == view && appThreadsEnabled;
                  if (threadOpen && !useColumns) {
                    return ThreadView(key: ValueKey(at), thread: at);
                  }
                  return useColumns
                      ? const ColumnsDeck()
                      : const MessagesList();
                }),
              ),
            )),
            ),
          ),
          // The composer stays mounted in columns mode and sends to the focused column's conversation.
          const _AwaitingMeshRangeNotice(),
          EventToastAreaReporter(
            target: eventToastComposer,
            child: KeyedSubtree(
              key: TutorialTargets.keyFor(TutorialTarget.composer),
              child: Composer(compact: compact),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatHeader extends ConsumerStatefulWidget {
  const _ChatHeader({
    this.onOpenSidebar,
    required this.compact,
    this.onStartCall,
    this.onStartGroupCall,
    this.columnsMode = false,
  });
  final VoidCallback? onOpenSidebar;
  final bool compact;
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  /// Desktop columns mode pins the header to a fixed height so the deck starts at a stable y.
  final bool columnsMode;

  @override
  ConsumerState<_ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends ConsumerState<_ChatHeader>
    with WidgetsBindingObserver, _HeaderAppGroup<_ChatHeader> {
  // Failed [GeohashPlaceCache] lookups, so the header falls back to coordinates.
  final Set<String> _placeFailed = {};

  /// Local descriptions for cells the geocoder cannot name; a real name still wins.
  final Map<String, String> _placeRegions = {};
  // Monotonic token so a late response can't force a redundant rebuild after the view moved on.
  int _geocodeToken = 0;

  /// Retry timers per geohash, so switching channels doesn't cancel another header's retry.
  final Map<String, Timer> _placeRetries = {};

  final _TitleRoom _room = _TitleRoom('chat');

  bool get _canBack => ref.read(viewHistoryProvider).canBack;
  bool get _canForward => ref.read(viewHistoryProvider).canForward;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The deck may already focus the bot column at mount (restored layout), so activate for the initial view too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeActivateBotHeader(ref.read(currentViewProvider));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume is the natural moment to retry failed place names, including ones the backoff gave up on.
    if (state != AppLifecycleState.resumed) return;
    if (_placeFailed.isEmpty) return;
    for (final gh in _placeFailed.toList()) {
      _placeFailed.remove(gh);
      _resolvePlaceName(gh, force: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _placeRetries.values) {
      t.cancel();
    }
    _placeRetries.clear();
    super.dispose();
  }

  /// In columns mode, focusing the bot PM refreshes credit meta and runs the empty-thread intro like the PWA.
  void _maybeActivateBotHeader(ChatView view) {
    if (!widget.columnsMode) return;
    if (view.kind != ViewKind.pm) return;
    final nostr = ref.read(nostrControllerProvider);
    if (!nostr.isVerifiedBot(view.id)) return;
    nostr.bindBotChat();
    final engine = ref.read(botChatControllerProvider.notifier);
    engine.attachSigner(nostr.signer);
    engine.ensureIntro();
    unawaited(engine.refreshBalance());
  }

  void _step(int delta) {
    if (stepViewHistory(ProviderScope.containerOf(context, listen: false), delta) &&
        mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final compact = widget.compact;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    ref.watch(activeThreadProvider);
    ref.watch(meshScreenOpenProvider);

    ref.listen(currentViewProvider, (prev, next) {
      if (prev != next) _maybeActivateBotHeader(next);
    });

    final title = _titleFor(app, view);
    final meta = _metaFor(app, view);

    final isChannel = view.kind == ViewKind.channel;
    final channelKey = isChannel ? view.id.toLowerCase() : '';
    final isPinned = isChannel && app.pinnedChannels.contains(channelKey);
    final isDefault = channelKey == kDefaultChannel;

    final width = MediaQuery.of(context).size.width;
    final phone = width <= NymDimens.mobileBreakpoint;
    final drawer = !phone && compact;
    final titleSize = settings.textSize + 3.0;
    final double headerHeight = (widget.columnsMode && !phone)
        ? 37 + math.max(68.0, titleSize * 1.4 + 35) - 1
        : chatHeaderHeight(width);

    final rejoinId = ref.watch(currentCallStateProvider).rejoinGroupId;
    final actions = _chatActions(
      view: view,
      isChannel: isChannel,
      channelKey: channelKey,
      isPinned: isPinned,
      isDefault: isDefault,
      rejoin: view.kind == ViewKind.group && rejoinId == view.id,
    );
    final maxShown = phone ? actions.length : 3;
    final capped = {for (final a in actions.skip(maxShown)) a.id};
    final metrics =
        headerActionMetrics(phone: phone, targets: context.largeTouchTargets);
    final loc = isChannel
        ? _locationFor(app, view)
        : (text: '', dist: '', geohash: null);
    final badges = _titleBadges(app, view);
    final info = !isChannel || loc.geohash != null;
    final insets = MediaQuery.paddingOf(context);
    final side = phone ? 2.0 : NymSpace.s1;
    final plan = _room.plan(
      layout: '$phone:$drawer:${metrics.box}:${metrics.gap}',
      width: width - insets.left - insets.right,
      extra: badges.length * (_kBadgeGap + _kBadge) +
          (info ? _kInfoGap + _kInfo : 0),
      kind: switch (view.kind) {
        ViewKind.channel => 'channel',
        ViewKind.pm => 'pm',
        ViewKind.group => 'group',
      },
      actions: [
        for (final a in actions)
          if (!capped.contains(a.id)) a.id,
        'bell',
      ],
      step: metrics.pitch,
      phone: phone,
    );
    final shown = [
      for (final a in actions)
        if (!capped.contains(a.id) && !plan.moved.contains(a.id)) a,
    ];
    final overflow = [
      for (final a in actions)
        if (capped.contains(a.id) || plan.moved.contains(a.id)) a,
    ];

    return Container(
      key: const ValueKey('chatHeader'),
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: headerHeight - 1),
          child: Row(
              children: [
                SizedBox(width: phone ? NymSpace.s2 : NymSpace.s3),
                if (phone)
                  HitSlopLimit(
                    end: side,
                    child: _HeaderPill(
                      svg: NymIcons.menu,
                      label: tr('Menu'),
                      onTap: widget.onOpenSidebar ?? () {},
                    ),
                  )
                else ...[
                  _NavBtn(
                    key: const ValueKey('navBack'),
                    svg: NymIcons.chevronLeft,
                    tooltip: tr('Go back'),
                    onTap: _canBack ? () => _step(-1) : null,
                    disabled: !_canBack,
                  ),
                  const SizedBox(width: 2),
                  HitSlopLimit(
                    end: side,
                    child: _NavBtn(
                      key: const ValueKey('navForward'),
                      svg: NymIcons.chevronRight,
                      tooltip: tr('Go forward'),
                      onTap: _canForward ? () => _step(1) : null,
                      disabled: !_canForward,
                    ),
                  ),
                ],
                SizedBox(width: side),
                Expanded(
                    child: _headerMiddle(
                        c, app, view, title, meta, loc, badges, info)),
                SizedBox(width: side),
                if (phone)
                  _HeaderActionRow(lead: side, children: [
                    for (final a in shown) a.button,
                    _notificationsPill(),
                    if (plan.more) _moreMenu(view, overflow),
                  ])
                else ...[
                  _HeaderActionRow(
                      lead: side, children: [for (final a in shown) a.button]),
                  const _HeaderDivider(),
                  _HeaderActionRow(children: [
                    if (drawer) ...[
                      _notificationsPill(),
                      _HeaderPill(
                        svg: NymIcons.menu,
                        label: tr('Menu'),
                        onTap: widget.onOpenSidebar ?? () {},
                      ),
                    ] else
                      _appIcons(),
                    _moreMenu(view, overflow),
                  ]),
                ],
                SizedBox(width: phone ? NymSpace.s2 : NymSpace.s3),
              ],
            ),
        ),
      ),
    );
  }

  ({String text, String dist, String? geohash}) _locationFor(
      AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        final gh = ch.isGeohash ? ch.geohashKey : view.id;
        if (!isValidGeohash(gh)) {
          return (text: tr('Not a geohash'), dist: '', geohash: null);
        }
        // Place name when cached, "Loading location..." while in flight, coordinates only as fallback.
        final ghKey = gh.toLowerCase();
        final cached = ref.read(geohashPlaceCacheProvider).cached(ghKey);
        final String place;
        if (cached != null) {
          place = cached;
        } else if (_placeFailed.contains(ghKey)) {
          // Cells with no address (open ocean) get a region description from bundled map data.
          place = _placeRegions[ghKey] ?? geohashLocationLabel(ghKey);
        } else {
          _resolvePlaceName(ghKey);
          // Three-dot literal, as the PWA writes it.
          place = tr('Loading location...');
        }
        // Distance shown only with a known location and sortByProximity on.
        var dist = '';
        final settings = ref.watch(settingsProvider);
        final userLoc = ref.watch(userLocationProvider);
        if (settings.sortByProximity && userLoc != null) {
          try {
            final coords = decodeGeohash(gh);
            final km = calculateDistance(
                userLoc.lat, userLoc.lng, coords.lat, coords.lng);
            dist = ' (${km.toStringAsFixed(1)}km)';
          } catch (_) {}
        }
        // Opens our own geohash explorer rather than a third-party map site.
        return (text: place, dist: dist, geohash: ghKey);
      case ViewKind.pm:
        return (text: _pmLastSeenText(app, view.id), dist: '', geohash: null);
      case ViewKind.group:
        for (final g in app.groups) {
          if (g.id == view.id) {
            return (
              text: tr('{count} members',
                  {'count': _abbreviateCount(g.members.length)}),
              dist: '',
              geohash: null,
            );
          }
        }
        return (text: '', dist: '', geohash: null);
    }
  }

  /// Same contract as the sidebar's Discover entry point, so joins behave identically.
  Future<void> _openExplorerAt(String geohash) async {
    final gh = await Navigator.of(context).push<String>(
      GeohashExplorer.route(focusGeohash: geohash),
    );
    if (gh == null || gh.isEmpty || !mounted) return;
    ref.read(nostrControllerProvider).switchChannel(gh, geohash: gh);
  }

  /// The cache owns de-duplication, Nominatim rate limiting and persistence; this adds the rebuild and fallback.
  void _resolvePlaceName(String ghKey, {bool force = false}) {
    if (!isValidGeohash(ghKey)) return;
    final cache = ref.read(geohashPlaceCacheProvider);
    if (cache.cached(ghKey) != null) return;
    final token = ++_geocodeToken;
    cache.resolve(ghKey, force: force).then((place) {
      if (place.isEmpty) {
        _placeFailed.add(ghKey);
        if (!_placeRegions.containsKey(ghKey)) {
          cache.describeRegionFor(ghKey).then((desc) {
            if (!mounted || desc.isEmpty) return;
            setState(() => _placeRegions[ghKey] = desc);
          });
        }
        // Schedule the retry the cache's backoff allows; once attempts run out, app resume retries.
        final at = cache.retryAt(ghKey);
        if (at != null) {
          final wait = at.difference(DateTime.now());
          _placeRetries.remove(ghKey)?.cancel();
          _placeRetries[ghKey] = Timer(
            wait.isNegative ? const Duration(seconds: 1) : wait,
            () {
              _placeRetries.remove(ghKey);
              if (!mounted) return;
              _placeFailed.remove(ghKey);
              _resolvePlaceName(ghKey);
            },
          );
        }
      }
      // A resolved place repaints even if the token moved: every caller shares the same future.
      if (!mounted) return;
      if (place.isEmpty && token != _geocodeToken) return;
      setState(() {});
    });
  }

  /// Bot "Always at your service", hidden "", online "Active now", away "Away", else relative last seen.
  String _pmLastSeenText(AppState app, String pubkey) {
    if (ref.read(nostrControllerProvider).isVerifiedBot(pubkey)) {
      return tr('Always at your service');
    }
    final user = app.users[pubkey];
    final status = user?.effectiveStatus() ?? UserStatus.offline;
    if (status == UserStatus.hidden) return '';
    if (status == UserStatus.online) return tr('Active now');
    if (status == UserStatus.away) return tr('Away');
    final lastSeen = user?.lastSeen ?? 0;
    if (lastSeen > 0) {
      return tr('Last seen {time}', {
        'time':
            formatRelativeTime(DateTime.fromMillisecondsSinceEpoch(lastSeen))
      });
    }
    return tr('Last seen unknown');
  }

  List<({String id, Widget button, String label, String svg, VoidCallback? onTap})>
      _chatActions({
    required ChatView view,
    required bool isChannel,
    required String channelKey,
    required bool isPinned,
    required bool isDefault,
    bool rejoin = false,
  }) {
    final controller = ref.read(nostrControllerProvider);
    final out = <({String id, Widget button, String label, String svg, VoidCallback? onTap})>[];
    void add(String id, String svg, String label, VoidCallback? onTap,
        {Key? key, Color? active, bool disabled = false}) {
      out.add((
        id: id,
        button: _ActionBtn(
          key: key,
          svg: svg,
          tooltip: label,
          activeColor: active,
          disabled: disabled,
          onTap: onTap,
        ),
        label: label,
        svg: svg,
        onTap: disabled ? null : onTap,
      ));
    }

    if (isChannel) {
      add('share', NymIcons.shareNodes, tr('Share channel URL'),
          () => ShareChannelModal.open(context, channelKey),
          key: TutorialTargets.keyFor(TutorialTarget.shareButton));
      add(
        'favorite',
        isPinned ? NymIcons.starFilled : NymIcons.starOutline,
        isDefault
            ? tr('#nymchat is always at the top')
            : (isPinned ? tr('Unfavorite channel') : tr('Favorite channel')),
        isDefault ? null : () => controller.togglePin(channelKey),
        active: isPinned ? const Color(0xFFF5C518) : null,
        disabled: isDefault,
      );
    } else {
      if (rejoin) {
        add('rejoin', NymIcons.phoneRejoin, tr('Rejoin the call'),
            () => ref.read(callServiceProvider).rejoinGroupCall(view.id),
            key: const ValueKey('rejoinCallBtn'),
            active: context.nym.primary);
      }
      add('audio', NymIcons.phone, tr('Start audio call'),
          () => _startCall(view, video: false));
      add('video', NymIcons.video, tr('Start video call'),
          () => _startCall(view, video: true));
    }
    return out;
  }

  List<Widget> _titleBadges(AppState app, ChatView view) {
    if (view.kind != ViewKind.pm) return const [];
    final controller = ref.read(nostrControllerProvider);
    final cosmetics = ref.watch(userCosmeticsProvider(view.id));
    return [
      for (final id in cosmetics.flairIds)
        if (id.isNotEmpty && ShopCatalog.byId(id) != null)
          FlairBadge(
            flairId: id,
            edition: id == 'flair-genesis' ? cosmetics.genesisEdition : null,
            size: _kBadge,
            gap: 0,
          ),
      if (controller.isVerifiedDeveloper(view.id) ||
          controller.isVerifiedBot(view.id))
        const VerifiedBadge(size: _kBadge),
      if (cosmetics.supporter) const SupporterMark(size: _kBadge),
      if (app.friends.contains(view.id)) const _FriendBadge(size: _kBadge),
    ];
  }

  Widget _headerMiddle(
      NymColors c,
      AppState app,
      ChatView view,
      String title,
      ({String? svg, String text}) meta,
      ({String text, String dist, String? geohash}) loc,
      List<Widget> badges,
      bool info) {
    final controller = ref.read(nostrControllerProvider);
    final isBot = view.kind == ViewKind.pm && controller.isVerifiedBot(view.id);
    final geohash = loc.geohash;
    final titleStyle = TextStyle(
      color: c.primary,
      fontSize: NymType.lg,
      height: 20 / NymType.lg,
      fontWeight: FontWeight.w600,
    );

    Widget avatar;
    Widget titleText;
    String sub;
    var dot = false;
    switch (view.kind) {
      case ViewKind.channel:
        avatar = _AvatarTile(
            child: NymSvgIcon(channelGlyphSvg(geohash: geohash != null),
                size: 18, color: c.primary));
        titleText = Text(title,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle);
        sub = geohash != null
            ? [if (loc.text.isNotEmpty) '${loc.text}${loc.dist}', meta.text]
                .join(' · ')
            : meta.text;
      case ViewKind.pm:
        final user = app.users[view.id];
        final status = user?.effectiveStatus(isVerifiedBot: isBot) ??
            (isBot ? UserStatus.online : UserStatus.offline);
        avatar = SizedBox(
          width: 36,
          height: 36,
          child: NymAvatar(
              seed: view.id, size: 36, imageUrl: user?.profile?.picture),
        );
        final base = stripPubkeySuffix(title);
        final suffix = getPubkeySuffix(view.id);
        titleText = NymLabel(base, suffix: suffix, style: titleStyle);
        dot = status == UserStatus.online && !isBot;
        sub = isBot
            ? meta.text
            : [
                _pmLastSeenText(app, view.id),
                tr('end-to-end encrypted'),
              ].where((x) => x.isNotEmpty).join(' · ');
      case ViewKind.group:
        Group? g;
        for (final cand in app.groups) {
          if (cand.id == view.id) {
            g = cand;
            break;
          }
        }
        final custom = g?.avatar;
        avatar = custom != null && custom.isNotEmpty
            ? SizedBox(
                width: 36,
                height: 36,
                child: NymAvatar(seed: view.id, size: 36, imageUrl: custom))
            : _AvatarTile(
                child: NymSvgIcon(NymIcons.groupGlyph,
                    size: 18, color: c.primary));
        titleText = Text(title,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle);
        final desc = GroupTools.descriptionLine(g?.description);
        sub = [
          if (g != null)
            tr('{count} members',
                {'count': _abbreviateCount(g.members.length)}),
          desc.isNotEmpty ? desc : tr('end-to-end encrypted'),
        ].join(' · ');
    }

    final VoidCallback? onTap = switch (view.kind) {
      ViewKind.channel when geohash != null => () => _openExplorerAt(geohash),
      ViewKind.channel => null,
      _ => () => toggleConversationInfo(context, ref),
    };
    final label = view.kind == ViewKind.channel
        ? (geohash != null ? tr('Show this location on the map') : null)
        : tr('Conversation info');
    final open = view.kind != ViewKind.channel &&
        dockShowsView(ref.watch(infoDockProvider), view);

    final body = Row(
      children: [
        avatar,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: _RoomReport(
                      room: _room,
                      onRoom: _onTitleRoom,
                      child: KeyedSubtree(
                          key: const ValueKey('chatHeaderTitle'),
                          child: titleText),
                    ),
                  ),
                  for (final b in badges) ...[
                    const SizedBox(width: _kBadgeGap),
                    SizedBox(width: _kBadge, height: _kBadge, child: b),
                  ],
                  if (info) ...[
                    const SizedBox(width: _kInfoGap),
                    NymSvgIcon(NymIcons.info,
                        size: _kInfo, color: open ? c.primary : c.textDim),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              SizedBox(
                key: const ValueKey('chatHeaderSub'),
                height: MediaQuery.textScalerOf(context).scale(16),
                child: Row(
                  children: [
                    if (dot) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                            color: Color(0xFF22C55E), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                            color: context.highContrast
                                ? legibleOn(c.textDim, flattenOver(c.glassBg, c.bg))
                                : c.textDim,
                            fontSize: NymType.sm,
                            height: 16 / NymType.sm),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: body,
    );
    if (onTap == null || label == null) return padded;
    return NymFocusable(
      key: const ValueKey('infoPanelBtn'),
      onActivate: onTap,
      tooltip: label,
      radius: NymRadius.rsm,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          excludeFromSemantics: true,
          borderRadius: NymRadius.rsm,
          hoverColor: c.primaryA(0.08),
          child: padded,
        ),
      ),
    );
  }

  void _onTitleRoom(double room) {
    if (mounted && _room.report(room)) setState(() {});
  }

  Widget _moreMenu(ChatView view,
      List<({String id, Widget button, String label, String svg, VoidCallback? onTap})>
          overflow) {
    final chatItems = <({String id, String label, String svg, VoidCallback? onTap})>[
      for (final a in overflow)
        (id: 'chat-${a.id}', label: a.label, svg: a.svg, onTap: a.onTap),
    ];
    if (view.kind == ViewKind.channel) {
      final gh = _locationFor(ref.read(appStateProvider), view).geohash;
      if (gh != null) {
        chatItems.add((
          id: 'chat-explorer',
          label: tr('Open in explorer'),
          svg: NymIcons.globe,
          onTap: () => _openExplorerAt(gh),
        ));
      }
    }
    final head = switch (view.kind) {
      ViewKind.group => tr('Group'),
      ViewKind.pm => tr('Private message'),
      ViewKind.channel => tr('Channel'),
    };
    return _moreButton(chatItems, head,
        groupId: view.kind == ViewKind.group ? view.id : null);
  }

  void _startCall(ChatView view, {required bool video}) {
    switch (view.kind) {
      case ViewKind.pm:
        widget.onStartCall?.call(view.id, video: video);
      case ViewKind.group:
        widget.onStartGroupCall?.call(view.id, video: video);
      case ViewKind.channel:
        // Channel calls don't exist in the PWA.
        break;
    }
  }

  String _titleFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        return '#${ch.isGeohash ? ch.geohashKey : ch.channel}';
      case ViewKind.pm:
        return app.users[view.id]?.nym ?? tr('PM');
      case ViewKind.group:
        for (final g in app.groups) {
          if (g.id == view.id) return g.name;
        }
        return tr('Group');
    }
  }

  ({String? svg, String text}) _metaFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        // Channel-scoped count of recent (not strictly online) non-hidden users, excluding self.
        final now = DateTime.now().millisecondsSinceEpoch;
        final key = view.id.toLowerCase();
        final count = app.users.values.where((u) {
          if (u.pubkey == app.selfPubkey) return false;
          if (!u.channels.contains(key)) return false;
          if (app.isPersonHidden(u.pubkey, u.nym)) return false;
          // Unlike `activeCount`, this has no bot always-online bypass, so the recency check applies to bots too.
          if (u.effectiveStatus(
                  isVerifiedBot: kVerifiedBotPubkeys.contains(u.pubkey)) ==
              UserStatus.hidden) {
            return false;
          }
          return now - u.lastSeen < kActiveThresholdMs;
        }).length;
        return (
          svg: null,
          text: tr('{count} online nyms', {'count': _abbreviateCount(count)})
        );
      case ViewKind.pm:
        // Bot PM meta shows live credits; watching the bot controller keeps it current.
        if (ref.read(nostrControllerProvider).isVerifiedBot(view.id)) {
          final botState = ref.watch(botChatControllerProvider);
          return (
            svg: NymIcons.lock,
            text: tr(
                'E2E encrypted · {meta}', {'meta': _botCreditMeta(botState)}),
          );
        }
        return (
          svg: NymIcons.lock,
          text: tr('End-to-end encrypted private message'),
        );
      case ViewKind.group:
        return (
          svg: NymIcons.lock,
          text: tr('End-to-end encrypted group chat'),
        );
    }
  }

  /// Credit meta text for the bot header, matching the premium bot-chat screen's builder.
  String _botCreditMeta(BotChatState state) {
    final proModel = state.proModel;
    if (proModel != null) {
      final pro = state.balance.proBalance;
      final proText = state.balanceKnown ? '$pro' : '…';
      final proCredits = pro == 1
          ? tr('{n} Pro credit', {'n': proText})
          : tr('{n} Pro credits', {'n': proText});
      return '$proCredits · ${proModel.label}';
    }
    if (!state.balanceKnown) {
      return state.balanceUnavailable
          ? tr('credits unavailable')
          : tr('checking credits…');
    }
    final std = state.balance.balance;
    final pro = state.balance.proBalance;
    return pro > 0
        ? tr(
            '{std} standard · {pro} Pro credits left', {'std': std, 'pro': pro})
        : (std == 1
            ? tr('{n} credit left', {'n': std})
            : tr('{n} credits left', {'n': std}));
  }

  /// Port of the PWA `abbreviateNumber`: <1000 raw, then "N.Nk", then "N.NM".
  String _abbreviateCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

class _NavBtn extends StatefulWidget {
  const _NavBtn({
    super.key,
    required this.svg,
    this.onTap,
    this.tooltip,
    this.disabled = false,
  });
  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool disabled;

  @override
  State<_NavBtn> createState() => _NavBtnState();
}

class _NavBtnState extends State<_NavBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (_hover ? c.primary : c.textDim);

    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.disabled ? null : (widget.onTap ?? () {}),
        canRequestFocus: false,
        excludeFromSemantics: true,
        borderRadius: NymRadius.rsm,
        child: Container(
          width: _kNavBox,
          height: _kNavBox,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: (_hover && !widget.disabled)
                ? c.hoverOverlay
                : Colors.transparent,
            borderRadius: NymRadius.rsm,
          ),
          child: NymSvgIcon(widget.svg, size: 18, color: color),
        ),
      ),
    );
    return HitSlop(
      child: NymFocusable(
        onActivate: widget.disabled ? null : (widget.onTap ?? () {}),
        tooltip: widget.tooltip,
        radius: NymRadius.rsm,
        child: btn,
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    super.key,
    required this.svg,
    this.onTap,
    this.tooltip,
    this.activeColor,
    this.disabled = false,
  });
  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? activeColor;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final tap = disabled ? null : onTap;
    return HitSlop(
      child: NymFocusable(
        onActivate: tap,
        tooltip: tooltip,
        radius: NymRadius.rsm,
        child: GestureDetector(
          onTap: tap,
          behavior: HitTestBehavior.opaque,
          child: _HeaderIconBox(
            key: ValueKey('headerAction:$tooltip'),
            svg: svg,
            color: activeColor,
            disabled: disabled,
          ),
        ),
      ),
    );
  }
}

const double _kHeaderActionGlyph = 18;
const double _kNavBox = 32;
const double _kBadge = 18;
const double _kBadgeGap = 4;
const double _kInfo = 16;
const double _kInfoGap = 6;

({double box, double gap, double pitch}) _headerMetrics(BuildContext context) =>
    headerActionMetrics(
        phone: MediaQuery.sizeOf(context).width <= NymDimens.mobileBreakpoint,
        targets: context.largeTouchTargets);

double _headerActionGap(BuildContext context) => _headerMetrics(context).gap;

class _TitleRoom {
  _TitleRoom(this.scope);

  final String scope;
  static final Map<String, double> _fixed = {};
  String _laidSig = '';
  String _laidKey = '';
  double _laidWidth = 0;
  double _laidExtra = 0;
  String _laidKind = '';
  List<String> _laidActions = const [];
  List<String> _laidMoved = const [];
  bool _laidMore = false;
  double _laidStep = 0;
  bool _laidPhone = false;

  ({List<String> moved, double room, bool more}) plan({
    required String layout,
    required double width,
    required double extra,
    required String kind,
    required List<String> actions,
    required double step,
    required bool phone,
  }) {
    final key = '$scope:$layout';
    final fixed = _fixed[key];
    final out = fixed == null
        ? (moved: const <String>[], room: 0.0, more: false)
        : headerOverflow(
            kind: kind,
            actions: actions,
            base: (width + fixed - extra - actions.length * step)
                .roundToDouble(),
            step: step,
            more: !phone);
    _laidKey = key;
    _laidWidth = width;
    _laidExtra = extra;
    _laidKind = kind;
    _laidActions = actions;
    _laidMoved = out.moved;
    _laidMore = phone && out.more;
    _laidStep = step;
    _laidPhone = phone;
    _laidSig =
        '$key:$width:$extra:$kind:${actions.join(',')}:${out.moved.join(',')}';
    return (moved: out.moved, room: out.room, more: _laidMore);
  }

  bool report(double room) {
    final base =
        room - _laidMoved.length * _laidStep + (_laidMore ? _laidStep : 0);
    final fixed =
        base + _laidExtra + _laidActions.length * _laidStep - _laidWidth;
    final known = _fixed[_laidKey];
    if (known != null && (fixed - known).abs() < 0.5) return false;
    _fixed[_laidKey] = fixed;
    final again = headerOverflow(
        kind: _laidKind,
        actions: _laidActions,
        base: base,
        step: _laidStep,
        more: !_laidPhone);
    return again.moved.join(',') != _laidMoved.join(',') ||
        (_laidPhone && again.more) != _laidMore;
  }
}

class _RoomReport extends SingleChildRenderObjectWidget {
  const _RoomReport({required this.room, required this.onRoom, super.child});

  final _TitleRoom room;
  final ValueChanged<double> onRoom;

  @override
  _RenderRoomReport createRenderObject(BuildContext context) =>
      _RenderRoomReport(onRoom, room._laidSig);

  @override
  void updateRenderObject(BuildContext context, _RenderRoomReport renderObject) {
    renderObject
      ..onRoom = onRoom
      ..sig = room._laidSig;
  }
}

class _RenderRoomReport extends RenderProxyBox {
  _RenderRoomReport(this.onRoom, this._sig);

  ValueChanged<double> onRoom;
  String _sig;
  set sig(String v) {
    if (v == _sig) return;
    _sig = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    final w = constraints.maxWidth.roundToDouble();
    if (!w.isFinite) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onRoom(w);
    });
  }
}

class _HeaderActionRow extends StatelessWidget {
  const _HeaderActionRow({super.key, required this.children, this.lead});
  final List<Widget> children;
  final double? lead;

  @override
  Widget build(BuildContext context) {
    final gap = _headerActionGap(context);
    final lead = this.lead;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          if (i == 0 && lead != null)
            HitSlopLimit(start: lead, child: children[i])
          else
            children[i],
        ],
      ],
    );
  }
}

class _HeaderDivider extends StatelessWidget {
  const _HeaderDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: NymSpace.s2),
      color: context.nym.glassBorder,
    );
  }
}

class _HeaderPill extends StatefulWidget {
  const _HeaderPill({
    super.key,
    required this.svg,
    required this.label,
    required this.onTap,
    this.badge = 0,
    this.keys,
  });
  final String svg;
  final String label;
  final String? keys;
  final VoidCallback onTap;
  final int badge;

  @override
  State<_HeaderPill> createState() => _HeaderPillState();
}

class _HeaderPillState extends State<_HeaderPill> {
  @override
  Widget build(BuildContext context) {
    final box = _HeaderIconBox(svg: widget.svg);
    return HitSlop(
      child: NymFocusable(
        onActivate: widget.onTap,
        tooltip: widget.label,
        tooltipKeys: widget.keys,
        excludeChildSemantics: true,
        radius: NymRadius.rsm,
        child: InkWell(
          onTap: widget.onTap,
          canRequestFocus: false,
          excludeFromSemantics: true,
          borderRadius: NymRadius.rsm,
          child: widget.badge > 0 ? _withBadge(box, widget.badge) : box,
        ),
      ),
    );
  }
}

class _HeaderIconBox extends StatefulWidget {
  const _HeaderIconBox({
    super.key,
    required this.svg,
    this.color,
    this.disabled = false,
  });
  final String svg;
  final Color? color;
  final bool disabled;

  @override
  State<_HeaderIconBox> createState() => _HeaderIconBoxState();
}

class _HeaderIconBoxState extends State<_HeaderIconBox> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hover = _hover && !widget.disabled;
    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (widget.color ?? (hover ? c.primary : c.textDim));
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        width: _headerMetrics(context).box,
        height: _headerMetrics(context).box,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hover
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : c.primaryA(0.1))
              : Colors.transparent,
          borderRadius: NymRadius.rsm,
        ),
        child: NymSvgIcon(widget.svg, size: _kHeaderActionGlyph, color: color),
      ),
    );
  }
}

Widget _withBadge(Widget child, int count) {
  return Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      Positioned(
        top: -4,
        right: -4,
        child: _CountBadge(count: count),
      ),
    ],
  );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: badgeFill(context, c.danger),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

class _FriendBadge extends StatelessWidget {
  const _FriendBadge({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final color =
        context.nym.isLight ? const Color(0xFF0288D1) : const Color(0xFF4FC3F7);
    return NymSvgIcon(NymIcons.friendBadge, size: size, color: color);
  }
}


/// Explains a stalled send: Ghost Mode refuses to fall back to Nostr, which would unmask the ghost.
class _AwaitingMeshRangeNotice extends ConsumerWidget {
  const _AwaitingMeshRangeNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch mesh state so the notice clears when the peer comes back into range.
    ref.watch(meshControllerProvider);
    final view = ref.watch(currentViewProvider);
    final bridge = ref.read(meshControllerProvider.notifier).bridge;
    if (bridge == null || !bridge.isAwaitingMeshRange(view)) {
      return const SizedBox.shrink();
    }
    final c = context.nym;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: c.bgSecondary,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.bluetooth_searching,
                size: 15, color: c.textDim),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('Waiting for Bluetooth range. This chat stays on Bluetooth '
                  'because you met over Ghost Mode, so messages send when '
                  'they are nearby.'),
              style: TextStyle(color: c.textDim, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.primaryA(0.14),
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: child,
    );
  }
}

mixin _HeaderAppGroup<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Widget _notificationsPill() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    final notifEnabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));
    return _HeaderPill(
      key: const ValueKey('menu-notifications'),
      svg: NymIcons.bell,
      label: tr('Notifications'),
      badge: notifEnabled ? unread : 0,
      onTap: _openNotifications,
    );
  }

  Widget _appIcons({bool tutorial = true}) {
    final menu = mainMenuRows('desktop');
    Widget pill(String id) => switch (id) {
          'notifications' => _notificationsPill(),
          'shop' => _HeaderPill(
              key: const ValueKey('menu-shop'),
              svg: NymIcons.store,
              label: tr('Shop'),
              onTap: () => ShopModal.open(context),
            ),
          'settings' => _HeaderPill(
              key: const ValueKey('menu-settings'),
              svg: NymIcons.settings,
              label: tr('Settings'),
              keys: shortcutKeyLabel('settings'),
              onTap: () => SettingsScreen.open(context),
            ),
          _ => _HeaderPill(
              key: const ValueKey('menu-about'),
              svg: NymIcons.info,
              label: tr('About'),
              onTap: () => AboutScreen.open(context),
            ),
        };
    final group = Semantics(
        label: tr('Main menu'),
        container: true,
        child: _HeaderActionRow(
          key: const ValueKey('menu-row-0'),
          children: [for (final id in menu.grid.first) pill(id)],
        ),
      );
    if (!tutorial) return group;
    return KeyedSubtree(
      key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
      child: group,
    );
  }

  Widget _moreButton(
      List<({String id, String label, String svg, VoidCallback? onTap})> chatItems,
      String head,
      {String? groupId}) {
    final c = context.nym;
    final menu = mainMenuRows('desktop');
    final missedCalls = ref.watch(callHistoryMissedProvider);
    Widget row(String svg, String label, {Key? key, int badge = 0}) => Row(
          key: key,
          children: [
            NymSvgIcon(svg, size: 16, color: c.text),
            const SizedBox(width: NymSpace.s3),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: NymType.md)),
            ),
            if (badge > 0) ...[
              const Spacer(),
              Container(
                key: const ValueKey('menu-calls-badge'),
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.danger,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(badge > 99 ? '99+' : '$badge',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1)),
              ),
            ],
          ],
        );
    PopupMenuEntry<String> heading(String t) => PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(t.toUpperCase(),
              style: TextStyle(
                  color: c.textDim, fontSize: 10, letterSpacing: 0.8)),
        );
    void pick(String? id) {
      if (id == null) return;
      if (id == 'saved') {
        SavedMessagesPanel.open(context);
      } else if (id == 'calls') {
        showCallsScreen(context);
      } else if (id == 'about') {
        AboutScreen.open(context);
      } else {
        for (final it in chatItems) {
          if (it.id == id) it.onTap?.call();
        }
      }
    }

    if (useNymActionSheet(context)) {
      return HitSlop(
        child: NymFocusable(
          key: const ValueKey('menu-more'),
          onActivate: () => _openMoreSheet(chatItems, head, menu.overflow, pick, groupId),
          tooltip: tr('More'),
          excludeChildSemantics: true,
          radius: NymRadius.rsm,
          child: InkWell(
            onTap: () => _openMoreSheet(chatItems, head, menu.overflow, pick, groupId),
            canRequestFocus: false,
            excludeFromSemantics: true,
            borderRadius: NymRadius.rsm,
            child: _HeaderIconBox(svg: NymIcons.rowMenuOutline),
          ),
        ),
      );
    }
    return HitSlop(
      child: NymTooltip(
      message: tr('More'),
      child: PopupMenuButton<String>(
      key: const ValueKey('menu-more'),
      tooltip: '',
      color: c.bgTertiary,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rsm,
        side: BorderSide(color: c.glassBorder),
      ),
      onSelected: pick,
      itemBuilder: (context) => [
        if (chatItems.isNotEmpty) ...[
          heading(head),
          for (final it in chatItems)
            PopupMenuItem<String>(
              value: it.id,
              enabled: it.onTap != null,
              height: 40,
              child: row(it.svg, it.label, key: ValueKey('menu-${it.id}')),
            ),
          const PopupMenuDivider(height: 9),
          heading(tr('More')),
        ],
        for (final id in menu.overflow)
          PopupMenuItem<String>(
            value: id,
            height: 40,
            child: switch (id) {
              'saved' => row(ChatToolIcons.saved, tr('Saved'),
                  key: const ValueKey('menu-saved')),
              'calls' => row(GroupToolIcons.callLink, tr('Calls'),
                  key: const ValueKey('menu-calls'), badge: missedCalls),
              _ => row(NymIcons.info, tr('About'), key: ValueKey('menu-$id')),
            },
          ),
      ],
      child: _HeaderIconBox(svg: NymIcons.rowMenuOutline),
      ),
      ),
    );
  }

  Future<void> _openMoreSheet(
    List<({String id, String label, String svg, VoidCallback? onTap})> chatItems,
    String head,
    List<String> overflow,
    void Function(String? id) pick,
    String? groupId,
  ) async {
    final entries = <NymActionEntry<String>>[
        if (chatItems.isNotEmpty) ...[
          NymActionEntry<String>.heading(head),
          for (final it in chatItems)
            NymActionEntry<String>(
              label: it.label,
              svg: it.svg,
              value: it.id,
              enabled: it.onTap != null,
              key: ValueKey('menu-${it.id}'),
            ),
          const NymActionEntry<String>.divider(),
          NymActionEntry<String>.heading(tr('More')),
        ],
        for (final o in overflow)
          NymActionEntry<String>(
            label: switch (o) {
              'saved' => tr('Saved'),
              'calls' => tr('Calls'),
              _ => tr('About'),
            },
            svg: switch (o) {
              'saved' => ChatToolIcons.saved,
              'calls' => GroupToolIcons.callLink,
              _ => NymIcons.info,
            },
            value: o,
            key: ValueKey('menu-$o'),
          ),
    ];
    final id = groupId != null
        ? await showGroupMenuSheet<String>(context, groupId, entries,
            label: 'More')
        : await showNymActionSheet<String>(context, entries, label: 'More');
    pick(id);
  }

  void _openNotifications() {
    showNotificationsPanel(context);
  }

}

class NymPageAction {
  const NymPageAction({
    this.id = '',
    required this.key,
    required this.svg,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.disabled = false,
  });
  final String id;
  final Key key;
  final String svg;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool disabled;
}

class NymPageHeader extends ConsumerStatefulWidget {
  const NymPageHeader({
    super.key,
    required this.tile,
    required this.title,
    required this.subtitle,
    required this.onBack,
    this.onBackToList,
    this.onOpenSidebar,
    this.actions = const [],
    this.kind = '',
  });

  final String kind;
  final Widget tile;
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback? onBackToList;
  final VoidCallback? onOpenSidebar;
  final List<NymPageAction> actions;

  @override
  ConsumerState<NymPageHeader> createState() => _NymPageHeaderState();
}

class _NymPageHeaderState extends ConsumerState<NymPageHeader>
    with _HeaderAppGroup<NymPageHeader> {
  final _TitleRoom _room = _TitleRoom('page');

  void _onTitleRoom(double room) {
    if (mounted && _room.report(room)) setState(() {});
  }

  void _step(int delta) {
    if (stepViewHistory(ProviderScope.containerOf(context, listen: false), delta) &&
        mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final history = ref.watch(viewHistoryProvider);
    final width = MediaQuery.of(context).size.width;
    final phone = width <= NymDimens.mobileBreakpoint;
    final drawer = !phone && widget.onOpenSidebar != null;
    final metrics =
        headerActionMetrics(phone: phone, targets: context.largeTouchTargets);
    final insets = MediaQuery.paddingOf(context);
    final side = phone ? 2.0 : NymSpace.s1;
    final plan = _room.plan(
      layout: '$phone:$drawer:${metrics.box}:${metrics.gap}',
      width: width - insets.left - insets.right,
      extra: 0,
      kind: widget.kind,
      actions: [for (final a in widget.actions) a.id, 'bell'],
      step: metrics.pitch,
      phone: phone,
    );
    final moved = [
      for (final a in widget.actions)
        if (plan.moved.contains(a.id))
          (
            id: 'chat-${a.id}',
            label: a.tooltip,
            svg: a.svg,
            onTap: a.disabled ? null : a.onTap,
          ),
    ];
    final actions = [
      for (final a in widget.actions)
        if (!plan.moved.contains(a.id))
        HitSlop(
          child: Semantics(
            button: true,
            toggled: a.active,
            enabled: !a.disabled,
            child: _ActionBtn(
              key: a.key,
              svg: a.svg,
              tooltip: a.tooltip,
              onTap: a.onTap,
              disabled: a.disabled,
              activeColor: a.active ? c.primary : null,
            ),
          ),
        ),
    ];
    final titleStyle = TextStyle(
      color: c.primary,
      fontSize: NymType.lg,
      height: 20 / NymType.lg,
      fontWeight: FontWeight.w600,
    );
    return Container(
      key: const ValueKey('meshHeader'),
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: chatHeaderHeight(width) - 1),
          child: Row(
              children: [
                SizedBox(width: phone ? NymSpace.s2 : NymSpace.s3),
                if (phone)
                  HitSlopLimit(
                    end: side,
                    child: _HeaderPill(
                      key: const ValueKey('meshBack'),
                      svg: NymIcons.chevronLeft,
                      label: tr('Back to chats'),
                      onTap: widget.onBackToList ?? widget.onBack,
                    ),
                  )
                else ...[
                  _NavBtn(
                    key: const ValueKey('meshNavBack'),
                    svg: NymIcons.chevronLeft,
                    tooltip: tr('Go back'),
                    onTap: history.canBack ? () => _step(-1) : null,
                    disabled: !history.canBack,
                  ),
                  const SizedBox(width: 2),
                  HitSlopLimit(
                    end: side,
                    child: _NavBtn(
                      key: const ValueKey('meshNavForward'),
                      svg: NymIcons.chevronRight,
                      tooltip: tr('Go forward'),
                      onTap: history.canForward ? () => _step(1) : null,
                      disabled: !history.canForward,
                    ),
                  ),
                ],
                SizedBox(width: side),
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        KeyedSubtree(
                            key: const ValueKey('meshHeaderTile'),
                            child: _AvatarTile(child: widget.tile)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _RoomReport(
                                room: _room,
                                onRoom: _onTitleRoom,
                                child: Text(widget.title,
                                    key: const ValueKey('meshHeaderTitle'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle),
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                key: const ValueKey('meshHeaderSub'),
                                height: MediaQuery.textScalerOf(context).scale(16),
                                child: Text(
                                  widget.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false,
                                  style: TextStyle(
                                      color: c.textDim,
                                      fontSize: NymType.sm,
                                      height: 16 / NymType.sm),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: side),
                if (phone)
                  _HeaderActionRow(lead: side, children: [
                    ...actions,
                    _notificationsPill(),
                    if (plan.more) _moreButton(moved, tr('Bluetooth mesh')),
                  ])
                else ...[
                  _HeaderActionRow(lead: side, children: actions),
                  const _HeaderDivider(),
                  _HeaderActionRow(children: [
                    if (drawer) ...[
                      _notificationsPill(),
                      _HeaderPill(
                        key: const ValueKey('meshMenu'),
                        svg: NymIcons.menu,
                        label: tr('Menu'),
                        onTap: widget.onOpenSidebar!,
                      ),
                    ] else
                      _appIcons(tutorial: false),
                    _moreButton(moved, tr('Bluetooth mesh')),
                  ]),
                ],
                SizedBox(width: phone ? NymSpace.s2 : NymSpace.s3),
              ],
            ),
        ),
      ),
    );
  }
}
