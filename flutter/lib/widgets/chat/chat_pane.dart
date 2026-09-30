import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../features/shop/cosmetics.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import '../context_menu/context_menu_actions.dart' show CtxTarget;
import '../context_menu/context_menu_panel.dart' show ContextMenuPanel;
import '../context_menu/profile_badges.dart' show VerifiedBadge;
import '../context_menu/group_context_menu_panel.dart'
    show GroupContextMenuPanel;
import '../../features/threads/thread_view.dart' show ThreadView;
import '../columns/columns_deck.dart';
import 'message_row.dart' show formatRelativeTime;
import 'composer.dart';
import 'messages_list.dart';

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
        (_, __) => scheduleCustomEmojiPrefetch(container));
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
            _ChatHeader(
              onOpenSidebar: onOpenSidebar,
              compact: compact,
              onStartCall: onStartCall,
              onStartGroupCall: onStartGroupCall,
              columnsMode: useColumns,
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
          _ChatHeader(
            onOpenSidebar: onOpenSidebar,
            compact: compact,
            onStartCall: onStartCall,
            onStartGroupCall: onStartGroupCall,
            columnsMode: useColumns,
          ),
          // The deck or an open thread replaces only the messages list, not the header or composer.
          Expanded(
            // Tap-outside dismisses the soft keyboard; interactive children still win the gesture arena.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
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
            ),
          ),
          // The composer stays mounted in columns mode and sends to the focused column's conversation.
          const _AwaitingMeshRangeNotice(),
          KeyedSubtree(
            key: TutorialTargets.keyFor(TutorialTarget.composer),
            child: Composer(compact: compact),
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
    with WidgetsBindingObserver {
  // Back/forward history; entries carry an open thread's root so Back closes it and Forward reopens it.
  final List<({ChatView view, String? threadRoot})> _history = [];
  int _index = -1;
  bool _navigating = false;

  // Failed [GeohashPlaceCache] lookups, so the header falls back to coordinates.
  final Set<String> _placeFailed = {};

  /// Local descriptions for cells the geocoder cannot name; a real name still wins.
  final Map<String, String> _placeRegions = {};
  // Monotonic token so a late response can't force a redundant rebuild after the view moved on.
  int _geocodeToken = 0;

  /// Retry timers per geohash, so switching channels doesn't cancel another header's retry.
  final Map<String, Timer> _placeRetries = {};

  bool get _canBack => _index > 0;
  bool get _canForward => _index >= 0 && _index < _history.length - 1;

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

  void _recordView(ChatView view, {String? threadRoot}) {
    if (_navigating) return;
    if (_index >= 0 &&
        _history[_index].view == view &&
        _history[_index].threadRoot == threadRoot) {
      return;
    }
    if (_index < _history.length - 1) {
      _history.removeRange(_index + 1, _history.length);
    }
    _history.add((view: view, threadRoot: threadRoot));
    if (_history.length > 50) _history.removeAt(0);
    _index = _history.length - 1;
  }

  void _back() {
    if (!_canBack) return;
    _index--;
    _go(_history[_index]);
  }

  void _forward() {
    if (!_canForward) return;
    _index++;
    _go(_history[_index]);
  }

  void _go(({ChatView view, String? threadRoot}) entry) {
    _navigating = true;
    ref.read(appStateProvider.notifier).switchView(entry.view);
    // Post-frame so the thread host's view-change listener has already run and cannot clobber the reopen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = entry.threadRoot == null
          ? null
          : ActiveThread(view: entry.view, rootId: entry.threadRoot!);
      if (ref.read(activeThreadProvider) != target) {
        ref.read(activeThreadProvider.notifier).state = target;
      }
      _navigating = false;
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final compact = widget.compact;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    final activeThread = ref.watch(activeThreadProvider);
    _recordView(view,
        threadRoot:
            activeThread?.view == view ? activeThread?.rootId : null);

    ref.listen(currentViewProvider, (prev, next) {
      if (prev != next) _maybeActivateBotHeader(next);
    });

    final title = _titleFor(app, view);
    final meta = _metaFor(app, view);
    final metaText = meta.text;
    final titleSize = settings.textSize + 3.0;

    final isChannel = view.kind == ViewKind.channel;
    final channelKey = isChannel ? view.id.toLowerCase() : '';
    final isPinned = isChannel && app.pinnedChannels.contains(channelKey);
    final isDefault = channelKey == kDefaultChannel;

    // Margins key off the real 768px phone breakpoint, narrower than the 1024 `compact` chrome.
    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final titleLeftGap = 15.0 + (phone ? 10.0 : 20.0);
    final titleRightGap = phone ? 0.0 : 20.0;
    final headerMinHeight = titleSize * 1.4 + 19;
    // Inner box is the fixed height minus 16px vertical padding each side and the 1px hairline.
    final double? headerFixedHeight = (widget.columnsMode && !phone)
        ? 37 + math.max(68.0, titleSize * 1.4 + 35) - 32 - 1
        : null;

    // Only the 768px phone breakpoint shrinks the padding; tablets keep desktop padding.
    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: phone
          ? const EdgeInsets.fromLTRB(10, 12, 10, 15)
          : const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: headerFixedHeight != null
              ? BoxConstraints.tightFor(height: headerFixedHeight)
              : BoxConstraints(minHeight: headerMinHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Nav/action cluster left of the title at all widths; in columns mode it fills the fixed header slot.
              widget.columnsMode
                  ? Container(
                      constraints: const BoxConstraints(minHeight: 68),
                      alignment: Alignment.centerLeft,
                      child: _channelControls(
                        view: view,
                        isChannel: isChannel,
                        channelKey: channelKey,
                        isPinned: isPinned,
                        isDefault: isDefault,
                      ),
                    )
                  : _channelControls(
                      view: view,
                      isChannel: isChannel,
                      channelKey: channelKey,
                      isPinned: isPinned,
                      isDefault: isDefault,
                    ),
              SizedBox(width: titleLeftGap),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: titleRightGap),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _titleLine(c, app, view, title, titleSize),
                      _locationLine(c, app, view),
                      if (metaText.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (meta.svg != null) ...[
                              NymSvgIcon(meta.svg!, size: 12, color: c.textDim),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                metaText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    TextStyle(color: c.textDim, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              if (compact)
                _mobileActions()
              else
                // Bounded so the text pills wrap rather than overflow on narrow desktops.
                Flexible(child: _headerActionPills()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleLine(
    NymColors c,
    AppState app,
    ChatView view,
    String title,
    double titleSize,
  ) {
    final titleStyle = TextStyle(
      color: c.primary,
      fontSize: titleSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );

    switch (view.kind) {
      case ViewKind.channel:
        return titleText;

      case ViewKind.pm:
        final user = app.users[view.id];
        // A verified bot is forced online, so its header dot is green without presence.
        final viewIsBot =
            ref.read(nostrControllerProvider).isVerifiedBot(view.id);
        final status = user?.effectiveStatus(isVerifiedBot: viewIsBot) ??
            (viewIsBot ? UserStatus.online : UserStatus.offline);
        final base = stripPubkeySuffix(title);
        final suffix = getPubkeySuffix(view.id);
        final nameRich = Text.rich(
          TextSpan(
            style: titleStyle,
            children: [
              TextSpan(text: base),
              if (suffix.isNotEmpty)
                TextSpan(
                  text: '#$suffix',
                  style: titleStyle.copyWith(
                    color: c.primary.withValues(alpha: 0.7),
                    fontSize: titleSize * 0.9,
                    fontWeight: FontWeight.w100,
                  ),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

        final controller = ref.read(nostrControllerProvider);
        final isDev = controller.isVerifiedDeveloper(view.id);
        final isBot = !isDev && controller.isVerifiedBot(view.id);
        final isFriend = app.friends.contains(view.id);
        final cosmetics = ref.watch(userCosmeticsProvider(view.id));

        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                NymAvatar(
                  seed: view.id,
                  size: 26,
                  imageUrl: user?.profile?.picture,
                ),
                if (status != UserStatus.hidden)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    // CSS content-box: the 7px dot is the colored size and the 2px ring sits outside it.
                    child: Container(
                      width: 11,
                      height: 11,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: c.isLight
                            ? const Color(0xFFF5F5F2)
                            : const Color(0xFF0A0A0F),
                        shape: BoxShape.circle,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor(status),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Flexible(child: nameRich),
            // Badges stay 20px independent of the title text size.
            CosmeticNymBadges(
              cosmetics: cosmetics,
              flairSize: 20,
              supporterHeight: 20,
            ),
            if (isDev || isBot) ...[
              const SizedBox(width: 4),
              const VerifiedBadge(size: 20),
            ],
            if (isFriend) ...[
              const SizedBox(width: 4),
              const _FriendBadge(size: 20),
            ],
          ],
        );
        return _HeaderClickable(
          onTap: () => _openPMProfile(view.id, '$base#$suffix', isBot),
          child: row,
        );

      case ViewKind.group:
        Group? found;
        for (final cand in app.groups) {
          if (cand.id == view.id) {
            found = cand;
            break;
          }
        }
        if (found == null) return titleText;
        final g = found;
        final customAvatar = g.avatar;
        final hasCustom = customAvatar != null && customAvatar.isNotEmpty;
        final others =
            g.members.where((pk) => pk != app.selfPubkey).take(4).toList();

        if (hasCustom) {
          return _HeaderClickable(
            onTap: () => GroupContextMenuPanel.show(context, g.id),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NymAvatar(seed: g.id, size: 26, imageUrl: customAvatar),
                const SizedBox(width: 4),
                Flexible(child: titleText),
              ],
            ),
          );
        }

        // Drop trailing avatars that don't fit instead of overflowing, then ellipsize the name.
        return LayoutBuilder(
          builder: (context, constraints) {
            const double iconW = 18 + 5;
            const double avatarStep = 14;
            final avail =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 9999.0;
            final budget = avail - iconW - 40; // Minimum name slot.
            var fit = others.length;
            if (budget < fit * avatarStep) {
              fit = (budget / avatarStep).floor().clamp(0, others.length);
            }
            final shown = others.take(fit).toList();

            final prefix = <Widget>[
              NymSvgIcon(NymIcons.groupGlyph, size: 18, color: c.primary),
              const SizedBox(width: 5),
            ];
            for (var i = 0; i < shown.length; i++) {
              prefix.add(Transform.translate(
                offset: Offset(i == 0 ? 0 : -4.0 * i, 0),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // `--bg-primary` is undefined in the PWA, so the border falls back to `currentColor` (primary).
                    border: Border.all(color: c.primary, width: 1),
                  ),
                  child: NymAvatar(
                    seed: shown[i],
                    size: 18,
                    imageUrl: app.users[shown[i]]?.profile?.picture,
                  ),
                ),
              ));
            }
            // Offset by the cumulative overlap so the name doesn't drift right.
            if (shown.isNotEmpty) {
              prefix.add(SizedBox(
                  width: (8 - 4.0 * (shown.length - 1)).clamp(0.0, 8.0)));
            }
            return _HeaderClickable(
              onTap: () => GroupContextMenuPanel.show(context, g.id),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...prefix,
                  Flexible(child: titleText),
                ],
              ),
            );
          },
        );
    }
  }

  void _openPMProfile(String pubkey, String nym, bool isBot) {
    if (pubkey.isEmpty) return;
    final state = ref.read(appStateProvider);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: pubkey,
        nym: stripPubkeySuffix(nym),
        isSelf: pubkey == state.selfPubkey,
        isBot: isBot,
        profileOnly: true,
      ),
    );
  }

  /// Location line: geohash place name (+ distance), "Not a geohash", PM last seen, or group member count.
  Widget _locationLine(NymColors c, AppState app, ChatView view) {
    final loc = _locationFor(app, view);
    if (loc.text.isEmpty) return const SizedBox.shrink();
    // Only the tappable geohash place name keeps the link underline, as in the PWA.
    final style = TextStyle(
      color: c.textDim,
      fontSize: 12,
      decoration: loc.geohash != null ? TextDecoration.underline : null,
      decorationColor: c.textDim,
    );
    // Only the city half ellipsizes, so a narrow header keeps the country.
    final splitIdx = loc.geohash != null ? loc.text.lastIndexOf(', ') : -1;
    final Widget placeText;
    if (splitIdx > 0 && splitIdx < loc.text.length - 2) {
      placeText = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              loc.text.substring(0, splitIdx),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          Text(loc.text.substring(splitIdx), maxLines: 1, style: style),
        ],
      );
    } else {
      placeText = Text(
        loc.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            // The distance span stays outside the tap target, which opens the in-app geohash explorer.
            child: loc.geohash == null
                ? placeText
                : MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openExplorerAt(loc.geohash!),
                      child: placeText,
                    ),
                  ),
          ),
          if (loc.dist.isNotEmpty)
            Text(
              loc.dist,
              maxLines: 1,
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
        ],
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

  Widget _mobileActions() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    // The badge is hidden while notifications are disabled.
    final notifEnabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Fixed bell glyph; the PWA never swaps to bell-off.
          _MobileToggle(
            svg: NymIcons.bell,
            tooltip: tr('Notifications'),
            badge: notifEnabled ? unread : 0,
            onTap: _openNotifications,
          ),
          const SizedBox(width: 8),
          _MobileToggle(
            svg: NymIcons.menu,
            tooltip: tr('Menu'),
            onTap: widget.onOpenSidebar,
          ),
        ],
      ),
    );
  }

  /// Header controls as a 2-column grid: back/forward, then favorite/share (channel) or audio/video (PM/group).
  Widget _channelControls({
    required ChatView view,
    required bool isChannel,
    required String channelKey,
    required bool isPinned,
    required bool isDefault,
  }) {
    final controller = ref.read(nostrControllerProvider);
    final isCall = view.kind == ViewKind.pm || view.kind == ViewKind.group;

    final buttons = <Widget>[
      _NavBtn(
        svg: NymIcons.chevronLeft,
        tooltip: tr('Go back'),
        onTap: _canBack ? _back : null,
        disabled: !_canBack,
      ),
      _NavBtn(
        svg: NymIcons.chevronRight,
        tooltip: tr('Go forward'),
        onTap: _canForward ? _forward : null,
        disabled: !_canForward,
      ),
      if (isChannel) ...[
        _ActionBtn(
          svg: isPinned ? NymIcons.starFilled : NymIcons.starOutline,
          tooltip: isDefault
              ? tr('#nymchat is always favorited')
              : (isPinned ? tr('Unfavorite channel') : tr('Favorite channel')),
          activeColor: isPinned ? const Color(0xFFF5C518) : null,
          disabled: isDefault,
          onTap: isDefault ? null : () => controller.togglePin(channelKey),
        ),
        _ActionBtn(
          key: TutorialTargets.keyFor(TutorialTarget.shareButton),
          svg: NymIcons.shareNodes,
          tooltip: tr('Share channel URL'),
          onTap: () => ShareChannelModal.open(context, channelKey),
        ),
      ] else if (isCall) ...[
        _ActionBtn(
          svg: NymIcons.phone,
          tooltip: tr('Start audio call'),
          onTap: () => _startCall(view, video: false),
        ),
        _ActionBtn(
          svg: NymIcons.video,
          tooltip: tr('Start video call'),
          onTap: () => _startCall(view, video: true),
        ),
      ],
    ];

    // Explicit 2x2 grid of fixed 28px centered cells so the two rows' glyphs line up at every width.
    const cell = 28.0;
    Widget gridCell(Widget child) =>
        SizedBox(width: cell, child: Center(child: child));

    final rows = <Widget>[
      for (var i = 0; i < buttons.length; i += 2)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            gridCell(buttons[i]),
            if (i + 1 < buttons.length) ...[
              const SizedBox(width: 2),
              gridCell(buttons[i + 1]),
            ],
          ],
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          rows[i],
        ],
      ],
    );
  }

  Widget _headerActionPills() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    // The badge is hidden while notifications are disabled.
    final notifEnabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));
    return KeyedSubtree(
      key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
      child: Wrap(
        spacing: 5,
        runSpacing: 5,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // The notifications button is icon-only (16px bell plus badge).
          _HeaderPill(
            svg: NymIcons.bell,
            label: tr('Notifications'),
            iconOnly: true,
            iconSize: 16,
            badge: notifEnabled ? unread : 0,
            onTap: _openNotifications,
          ),
          _HeaderPill(
            svg: NymIcons.starFlair,
            label: tr('Flair'),
            onTap: () => ShopModal.open(context),
          ),
          _HeaderPill(
            svg: NymIcons.settings,
            label: tr('Settings'),
            onTap: () => SettingsScreen.open(context),
          ),
          _HeaderPill(
            svg: NymIcons.info,
            label: tr('About'),
            onTap: () => AboutScreen.open(context),
          ),
          _HeaderPill(
            svg: NymIcons.logout,
            label: tr('Logout'),
            // Sign-out clears the identity and bumps the boot generation so the first-run gate remounts.
            onTap: _confirmSignOut,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    final ok = await showAppConfirm(
      context,
      tr('Sign out and disconnect from Nymchat?'),
      okLabel: tr('Sign out'),
      danger: true,
    );
    if (!ok) return;
    await ref.read(nostrControllerProvider).signOut();
  }

  /// No bulk mark-viewed on open: a synced flip would silence other devices before items are seen.
  void _openNotifications() {
    showNotificationsPanel(context);
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
    // Only the 768px phone breakpoint shrinks it to 24x24.
    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final size = phone ? 24.0 : 28.0;

    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (_hover ? c.primary : c.textDim);

    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.disabled ? null : (widget.onTap ?? () {}),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: (_hover && !widget.disabled)
                ? c.hoverOverlay
                : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
          ),
          child: NymSvgIcon(widget.svg, size: 18, color: color),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

/// Boxless header action button; disabled rests dim and ignores taps (the always-favorited `#nymchat`).
class _ActionBtn extends StatefulWidget {
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
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // 28px footprint at every width; only the nav buttons shrink on phones.
    const pad = 5.0;

    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (widget.activeColor ?? (_hover ? c.primary : c.textDim));

    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.disabled ? null : widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: (_hover && !widget.disabled) ? 1.1 : 1.0,
          // CSS default `ease`, not the global `--transition` token.
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: NymSvgIcon(widget.svg, size: 18, color: color),
          ),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

@immutable
class _IconBtnStyle {
  const _IconBtnStyle({
    required this.fill,
    required this.border,
    required this.foreground,
  });
  final Color fill;
  final Color border;
  final Color foreground;
}

_IconBtnStyle _iconBtnStyle(NymColors c, bool hover) {
  if (c.isLight) {
    return _IconBtnStyle(
      fill: hover
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.03),
      border: hover ? c.primary : Colors.black.withValues(alpha: 0.1),
      foreground: c.primary,
    );
  }
  return _IconBtnStyle(
    fill: hover ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05),
    border: hover ? c.primaryA(0.30) : c.glassBorder,
    foreground: hover ? c.primary : c.text,
  );
}

/// `.icon-btn` text pill; [iconOnly] drops the label, which then only feeds the tooltip.
class _HeaderPill extends StatefulWidget {
  const _HeaderPill({
    required this.svg,
    required this.label,
    required this.onTap,
    this.badge = 0,
    this.iconOnly = false,
    this.iconSize = 14,
  });
  final String svg;
  final String label;
  final VoidCallback onTap;
  final int badge;
  final bool iconOnly;
  final double iconSize;

  @override
  State<_HeaderPill> createState() => _HeaderPillState();
}

class _HeaderPillState extends State<_HeaderPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = _iconBtnStyle(c, _hover);
    final fg = style.foreground;
    final pill = AnimatedContainer(
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: style.fill,
        borderRadius: NymRadius.rxs,
        border: Border.all(color: style.border),
        boxShadow: _hover
            ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NymSvgIcon(widget.svg, size: widget.iconSize, color: fg),
          if (!widget.iconOnly) ...[
            const SizedBox(width: 5),
            Text(
              widget.label.toUpperCase(),
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.label,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: widget.badge > 0 ? _withBadge(pill, widget.badge) : pill,
        ),
      ),
    );
  }
}

/// 40x40 mobile header toggle with an optional unread [badge].
class _MobileToggle extends StatelessWidget {
  const _MobileToggle({
    required this.svg,
    this.tooltip,
    this.onTap,
    this.badge = 0,
  });
  final String svg;
  final String? tooltip;
  final VoidCallback? onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final box = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.isLight
            ? const Color(0xD9FFFFFF)
            : const Color(0xCC141423),
        borderRadius: NymRadius.rsm,
        border: Border.all(
          color:
              c.isLight ? Colors.black.withValues(alpha: 0.08) : c.glassBorder,
        ),
      ),
      child: NymSvgIcon(svg, size: 20, color: c.primary),
    );
    final child = InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: badge > 0 ? _withBadge(box, badge) : box,
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: child) : child;
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
        color: c.danger,
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

/// Bare tap wrapper so the row's intrinsic layout is preserved.
class _HeaderClickable extends StatelessWidget {
  const _HeaderClickable({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
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
