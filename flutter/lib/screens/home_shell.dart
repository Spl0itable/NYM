import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/theme/nym_colors.dart';
import '../core/theme/nym_metrics.dart';
import '../features/calls/call_overlay.dart';
import '../features/calls/call_providers.dart';
import '../features/calls/incoming_call.dart';
import '../features/mesh/mesh_controller.dart'
    show MeshController, meshScreenOpenProvider;
import '../core/constants/storage_keys.dart';
import '../features/i18n/i18n.dart';
import '../features/layout/info_dock.dart';
import '../features/layout/info_dock_host.dart';
import '../features/layout/layout_model.dart';
import '../features/layout/slide_out_list.dart';
import '../features/mesh/mesh_screen.dart';
import '../features/nymbot/bot_credits_modal.dart';
import '../features/nymbot/nymbot_providers.dart'
    show BotBuyRequest, botBuyRequestProvider, botChatControllerProvider;
import '../features/onboarding/tutorial_overlay.dart';
import '../features/search/unified_search_panel.dart';
import '../features/settings/settings_screen.dart';
import '../features/shortcuts/escape_layers.dart';
import '../features/shortcuts/shortcuts.dart';
import '../models/channel.dart' show kDefaultChannel;
import '../services/location/geolocation.dart';
import '../state/app_state.dart';
import '../state/nostr_controller.dart';
import '../state/settings_provider.dart';
import '../state/view_history.dart';
import '../widgets/context_menu/interaction_hooks.dart';
import '../widgets/chat/chat_pane.dart';
import '../widgets/common/focus_rebuild_boundary.dart';
import '../widgets/common/key_resizer.dart';
import '../widgets/common/nym_sheet.dart' show kNymSheetCloseVelocity;
import '../widgets/sidebar/list_swipe_back.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/wallpaper/wallpaper_layer.dart';

final chatListLandingProvider = StateProvider<bool>((ref) => false);

const double _kMouseClickSlop = 4;

/// Responsive shell: two panes above 1024px, else a 300px off-canvas drawer; call UI mounts above everything.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  /// Stable key BootGate reads back as the [TutorialSidebarDriver].
  static final GlobalKey<HomeShellState> tutorialKey =
      GlobalKey<HomeShellState>();

  @override
  ConsumerState<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends ConsumerState<HomeShell>
    implements TutorialSidebarDriver {
  bool _drawerOpen = false;

  /// True while a narrow layout is mounted, so the tutorial driver knows the drawer matters.
  bool _narrow = false;

  bool _phone = false;

  /// Dedicated edge-swipe threshold, not the user-tunable message `swipeThreshold`.
  static const double _sidebarSwipeThreshold = 50;

  /// Pointer armed by a touch within 50px of an edge, or null.
  int? _edgeSwipePointer;

  double _edgeSwipeStartX = 0;

  /// The right edge drives the thread.
  bool _edgeSwipeFromRight = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
    _viewSwitches = ref.read(appStateProvider.notifier).viewSwitches
      ..addListener(_onViewSwitch);
    // Fresh target keys so a disposed shell's GlobalKeys can't reparent here.
    TutorialTargets.reset();
    // Constructing the CallService registers the inbound call-signal handler.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(callServiceProvider);
      _maybeBootProximityLocation();
      // For an identity ready before mount; the selfPubkey listener covers later logins.
      _bindBotEngine();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _sideWindow?.cancel();
    _viewSwitches?.removeListener(_onViewSwitch);
    super.dispose();
  }

  ValueNotifier<int>? _viewSwitches;

  void _onViewSwitch() {
    _lastPageMesh = false;
    if (_phone && _drawerOpen && mounted) setState(() => _drawerOpen = false);
  }

  bool _lastPageMesh = false;

  double? _listDrag;

  bool _landingChecked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_landingChecked) return;
    _landingChecked = true;
    if (!ref.read(chatListLandingProvider)) return;
    if (MediaQuery.sizeOf(context).width <= kPhoneMax) _drawerOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(chatListLandingProvider.notifier).state = false;
    });
  }

  void _closeChatList() {
    if (_lastPageMesh && MeshController.isSupportedPlatform) {
      ref.read(meshScreenOpenProvider.notifier).state = true;
      return;
    }
    final app = ref.read(appStateProvider.notifier);
    if (app.viewSwitchCount == 0 &&
        app.currentView != const ChatView.channel(kDefaultChannel)) {
      app.switchChannel(kDefaultChannel);
    }
    if (_drawerOpen && mounted) setState(() => _drawerOpen = false);
  }

  void _recordCurrentView() {
    ref.read(viewHistoryProvider).record(
        chatViewEntry(ref.read(currentViewProvider), ref.read(activeThreadProvider)));
  }

  bool _stepHistory(int delta) =>
      stepViewHistory(ProviderScope.containerOf(context, listen: false), delta);

  bool _goChat(String dir) {
    final order = ref.read(sidebarNavOrderProvider);
    if (order.isEmpty) return false;
    final unread = ref.read(unreadCountsProvider);
    final keys = [for (final v in order) shortcutNavKey(v)];
    final want = shortcutNavTarget(
      keys,
      shortcutNavKey(ref.read(currentViewProvider)),
      dir,
      [
        for (final v in order)
          if (shortcutUnreadFor(unread, v) > 0) shortcutNavKey(v),
      ],
    );
    if (want == null) return false;
    ref.read(appStateProvider.notifier).switchView(order[keys.indexOf(want)]);
    return true;
  }

  bool _onGlobalKey(KeyEvent e) =>
      !(e.logicalKey == LogicalKeyboardKey.escape &&
          FocusManager.instance.primaryFocus != null) &&
      _onKey(e);

  KeyEventResult _onEarlyKey(KeyEvent e) =>
      e.logicalKey == LogicalKeyboardKey.escape && _onKey(e)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;

  bool _onKey(KeyEvent e) {
    if (!mounted || e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.browserBack ||
        e.logicalKey == LogicalKeyboardKey.browserForward) {
      if (_routeAbove()) return false;
      _sideStep(e.logicalKey == LogicalKeyboardKey.browserBack ? -1 : 1,
          byKey: true);
      return true;
    }
    final focus = FocusManager.instance.primaryFocus;
    final focusCtx = focus?.context;
    final inText = focusCtx != null &&
        (focusCtx.widget is EditableText ||
            focusCtx.findAncestorWidgetOfExactType<EditableText>() != null);
    final composer = ComposerShortcutHooks.focus;
    final inComposer = composer != null && identical(focus, composer);
    final hk = HardwareKeyboard.instance;
    final action = shortcutAction(
      key: shortcutKeyName(e) ?? '',
      ctrl: hk.isControlPressed,
      meta: hk.isMetaPressed,
      alt: hk.isAltPressed,
      shift: hk.isShiftPressed,
      mac: shortcutsUseMac,
      inText: inText,
      inComposer: inComposer,
      composerEmpty: inComposer,
    );
    if (action == null || action == 'editLast') return false;
    if (action == 'search') {
      UnifiedSearchPanel.open(context);
      return true;
    }
    if (_routeAbove()) {
      return action == 'escape' &&
          EscapeLayers.closeTop(minRank: EscapeRank.quickReact);
    }
    switch (action) {
      case 'settings':
        SettingsScreen.open(context);
        return true;
      case 'help':
        showShortcutSheet(context);
        return true;
      case 'prevChat':
        return _goChat('prev');
      case 'nextChat':
        return _goChat('next');
      case 'nextUnread':
        return _goChat('nextUnread');
      case 'back':
        return _stepHistory(-1);
      case 'forward':
        return _stepHistory(1);
      case 'escape':
        if (inComposer) {
          return !EscapeLayers.textBusy(focus) && _closeTopLayer();
        }
        if (inText) return EscapeLayers.closeTop();
        return _closeTopLayer();
    }
    return false;
  }

  bool _routeAbove() =>
      Navigator.of(context).canPop() ||
      !(ModalRoute.of(context)?.isCurrent ?? true);

  bool _closeTopLayer() {
    if (EscapeLayers.closeTop()) return true;
    if (ref.read(infoDockProvider) != null) {
      _dismissDock();
      return true;
    }
    if (ref.read(activeThreadProvider) != null) {
      ref.read(activeThreadProvider.notifier).state = null;
      return true;
    }
    return false;
  }

  int _sideButtons = 0;

  void _sideButtonDown(PointerDownEvent e) {
    _sideButtons = e.kind == PointerDeviceKind.mouse
        ? e.buttons & (kBackMouseButton | kForwardMouseButton)
        : 0;
  }

  void _sideButtonUp(PointerUpEvent e) {
    final b = _sideButtons;
    _sideButtons = 0;
    if (b == 0 || !mounted || _routeAbove()) return;
    _sideStep(b & kBackMouseButton != 0 ? -1 : 1, byKey: false);
  }

  Timer? _sideWindow;
  int _sideDelta = 0;
  bool _sideByKey = false;

  void _sideStep(int delta, {required bool byKey}) {
    final twin = (_sideWindow?.isActive ?? false) &&
        _sideDelta == delta &&
        _sideByKey != byKey;
    _sideWindow?.cancel();
    _sideWindow = null;
    if (twin) return;
    _sideWindow = Timer(const Duration(milliseconds: 400), () {});
    _sideDelta = delta;
    _sideByKey = byKey;
    _stepHistory(delta);
  }

  /// Keeps the Nymbot engine alive from boot, binds it to the identity, and sends the one-time welcome PM.
  void _bindBotEngine() {
    if (ref.read(appStateProvider).selfPubkey.isEmpty) return;
    final engine = ref.read(botChatControllerProvider.notifier);
    final nostr = ref.read(nostrControllerProvider);
    nostr.bindBotChat();
    // Sign paid actions through the active signer (local or NIP-46) per request.
    engine.attachSigner(nostr.signer);
    unawaited(engine.maybeSendBotWelcomePM());
  }

  /// If proximity sort was already on and location is still granted, fetch a fix at boot; silent on failure.
  Future<void> _maybeBootProximityLocation() async {
    if (!ref.read(settingsProvider).sortByProximity) return;
    if (ref.read(userLocationProvider) != null) return; // already located
    final status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) return;
    final loc = await fetchCurrentUserLocation();
    if (loc != null && mounted) {
      ref.read(userLocationProvider.notifier).state = loc;
    }
  }

  void _startCall(String peer, {required bool video}) {
    ref.read(callServiceProvider).startCall(peer, video: video);
  }

  void _startGroupCall(String groupId, {required bool video}) {
    ref.read(callServiceProvider).startGroupCall(groupId, video: video);
  }

  /// Drawer state to restore once the tour ends.
  bool? _drawerStateBeforeTour;

  void _rememberDrawerState() {
    _drawerStateBeforeTour ??= _drawerOpen;
  }

  @override
  Future<void> openSidebar() async {
    if (!_narrow) return;
    _rememberDrawerState();
    if (!_drawerOpen && mounted) setState(() => _drawerOpen = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<void> closeSidebar() async {
    if (!_narrow) return;
    _rememberDrawerState();
    if (_drawerOpen && mounted) setState(() => _drawerOpen = false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  void restore() {
    final prev = _drawerStateBeforeTour;
    _drawerStateBeforeTour = null;
    if (prev == null || !mounted) return;
    if (prev != _drawerOpen) setState(() => _drawerOpen = prev);
  }

  // Raw pointer listeners, not arena recognizers, so the swipe fires on any touch and never steals events underneath.

  /// Only a touch landing within 50px of an edge arms the gesture.
  void _edgePointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    if (_edgeSwipePointer != null) return;
    final width = MediaQuery.of(context).size.width;
    final fromRight = e.position.dx > width - 50;
    if (e.position.dx >= 50 && !fromRight) return;
    _edgeSwipePointer = e.pointer;
    _edgeSwipeStartX = e.position.dx;
    _edgeSwipeFromRight = fromRight;
  }

  /// Past the 50px threshold the drawer toggles (so it also closes), then tracking stops for this touch.
  void _edgePointerMove(PointerMoveEvent e) {
    if (e.pointer != _edgeSwipePointer) return;
    if (_edgeSwipeFromRight) {
      if (_edgeSwipeStartX - e.position.dx > _sidebarSwipeThreshold) {
        _edgeSwipePointer = null;
        _swipeForward();
      }
      return;
    }
    if (e.position.dx - _edgeSwipeStartX > _sidebarSwipeThreshold) {
      _edgeSwipePointer = null;
      if (_phone && _meshShown) {
        _meshBackToList();
        return;
      }
      // An open drawer closes first, then a thread backs out, and only then does the drawer open.
      if (_drawerOpen) {
        if (!_phone) setState(() => _drawerOpen = false);
        return;
      }
      if (ref.read(activeThreadProvider) != null) {
        ref.read(activeThreadProvider.notifier).state = null;
        return;
      }
      setState(() => _drawerOpen = true);
    }
  }

  void _swipeForward() {
    if (_drawerOpen) return;
    if (_stepHistory(1)) return;
    if (ref.read(activeThreadProvider) != null) return;
    _openConversationMenu(ref.read(appStateProvider));
  }

  void _openConversationMenu(AppState app) => openConversationInfo(context, ref);

  /// Any touch lift disarms.
  void _edgePointerEnd(PointerEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _edgeSwipePointer = null;
    _edgeSwipeFromRight = false;
  }

  @override
  Widget build(BuildContext context) {
    if (ref.read(viewHistoryProvider).isEmpty) _recordCurrentView();
    ref.listen<int>(slideOutListCloseProvider, (_, _) {
      if (!_phone && _drawerOpen && mounted) setState(() => _drawerOpen = false);
    });
    ref.listen<ChatView>(currentViewProvider, (_, next) => _recordCurrentView());
    ref.listen<ActiveThread?>(activeThreadProvider, (_, next) => _recordCurrentView());
    ref.listen<bool>(meshScreenOpenProvider, (prev, next) {
      if (prev == next) return;
      if (next) {
        _lastPageMesh = true;
        ref.read(viewHistoryProvider).record(const ViewHistoryEntry.mesh());
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ref.read(meshScreenOpenProvider)) return;
          if (ref.read(viewHistoryProvider).current?.mesh ?? false) {
            _recordCurrentView();
          }
        });
      }
    });
    // Always-mounted gift listener: bind the bot chat, open the prefilled gift modal, consume the request.
    ref.listen<GiftCreditsRequest?>(giftCreditsRequestProvider, (prev, next) {
      if (next == null) return;
      // Consume immediately so a rebuild can't reopen the modal.
      ref.read(giftCreditsRequestProvider.notifier).consume();
      final nostr = ref.read(nostrControllerProvider);
      nostr.bindBotChat();
      ref.read(botChatControllerProvider.notifier).attachSigner(nostr.signer);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        BotCreditsModal.show(
          context,
          colors: context.nym,
          giftRecipientPubkey: next.pubkey,
          giftRecipientNym: next.nym,
        );
      });
    });

    // Always-mounted `?buy` listener opening the shared credits modal with the right tier.
    ref.listen<BotBuyRequest?>(botBuyRequestProvider, (prev, next) {
      if (next == null) return;
      ref.read(botBuyRequestProvider.notifier).consume();
      final nostr = ref.read(nostrControllerProvider);
      nostr.bindBotChat();
      ref.read(botChatControllerProvider.notifier).attachSigner(nostr.signer);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        BotCreditsModal.show(
          context,
          colors: context.nym,
          initialTier: next.tier,
        );
      });
    });

    // Bind the bot engine once an identity lands after mount.
    ref.listen<String>(appStateProvider.select((s) => s.selfPubkey),
        (prev, next) {
      if (next.isEmpty || next == prev) return;
      _bindBotEngine();
    });

    ref.listen(appStateProvider.select((s) => s.view), (prev, next) {
      if (prev != next && _narrow && _drawerOpen && mounted) {
        setState(() => _drawerOpen = false);
      }
      // Switching conversations also dismisses the mesh overlay.
      if (prev != next && ref.read(meshScreenOpenProvider)) {
        ref.read(meshScreenOpenProvider.notifier).state = false;
      }
      if (prev != next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) followConversationInfo(context, ref);
        });
      }
    });

    final c = context.nym;
    final width = MediaQuery.of(context).size.width;
    // The drawer governs the 0–1024 range; two panes only above 1024.
    final isWide = width > NymDimens.tabletBreakpoint;
    _narrow = !isWide;
    _phone = width <= kPhoneMax;

    final useColumns = ref.watch(settingsProvider.select((s) => s.useColumns));
    final isGhost =
        ref.watch(settingsProvider.select((s) => s.theme == NymThemeKey.ghost));

    // Back unwinds thread, mesh screen and drawer in swipe order, leaving the app only when nothing is open.
    final canLeave = _phone
        ? _drawerOpen && !_meshShown
        : !(_drawerOpen ||
            _meshShown ||
            ref.watch(activeThreadProvider) != null);
    return Listener(
      onPointerDown: _sideButtonDown,
      onPointerUp: _sideButtonUp,
      child: PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _popInApp();
      },
      child: FocusRebuildBoundary(
      child: Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          // Ambient glow and wallpaper are repaint-isolated so animations elsewhere don't re-raster them.
          Positioned.fill(
            child: RepaintBoundary(child: _AmbientGlow(c: c, isGhost: isGhost)),
          ),
          const Positioned.fill(child: RepaintBoundary(child: WallpaperLayer())),
          Positioned.fill(
            child: isWide
                ? _wide(context, useColumns)
                : _mobile(context, useColumns),
          ),
          // Call UI renders nothing when idle.
          const Positioned.fill(child: CallOverlay()),
          const Positioned.fill(child: IncomingCallModal()),
        ],
      ),
    ))));
  }

  void _meshBackToList() {
    ref.read(meshScreenOpenProvider.notifier).state = false;
    if (!_drawerOpen && mounted) setState(() => _drawerOpen = true);
  }

  bool get _meshShown =>
      MeshController.isSupportedPlatform && ref.watch(meshScreenOpenProvider);

  /// Closes the innermost open thing, one per press.
  void _popInApp() {
    if (_phone) {
      if (ref.read(meshScreenOpenProvider)) {
        _meshBackToList();
        return;
      }
      if (_drawerOpen) return;
      if (_stepHistory(-1)) return;
      if (ref.read(activeThreadProvider) != null) {
        ref.read(activeThreadProvider.notifier).state = null;
        return;
      }
      if (mounted) setState(() => _drawerOpen = true);
      return;
    }
    if (_drawerOpen) {
      if (mounted) setState(() => _drawerOpen = false);
      return;
    }
    if (ref.read(meshScreenOpenProvider)) {
      ref.read(meshScreenOpenProvider.notifier).state = false;
      return;
    }
    if (ref.read(activeThreadProvider) != null) {
      ref.read(activeThreadProvider.notifier).state = null;
    }
  }

  /// Always the ChatPane; in columns mode the deck replaces only the message list inside it.
  Widget _content(BuildContext context, bool useColumns,
      {bool compact = false}) {
    return ChatPane(
      compact: compact,
      useColumns: useColumns,
      onOpenSidebar: compact ? () => setState(() => _drawerOpen = true) : null,
      onStartCall: _startCall,
      onStartGroupCall: _startGroupCall,
    );
  }

  double? _sidebarW;

  DockedInfo? _dockAtDown;
  int? _dockPointer;
  Offset _dockDownAt = Offset.zero;
  double _dockSlop = kTouchSlop;
  int? _resizerPointer;

  void _dismissDock() {
    ref.read(infoDockProvider.notifier).state = null;
    ref.read(settingsProvider.notifier).setInfoPanelOpen(false);
  }

  void _outsideDockDown(PointerDownEvent e) {
    final dock = ref.read(infoDockProvider);
    final primary =
        e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryMouseButton;
    final onResizer = _resizerPointer == e.pointer;
    _resizerPointer = null;
    _dockAtDown = dock != null && primary && !onResizer ? dock : null;
    _dockPointer = _dockAtDown == null ? null : e.pointer;
    _dockDownAt = e.position;
    _dockSlop = e.kind == PointerDeviceKind.mouse ? _kMouseClickSlop : kTouchSlop;
  }

  void _outsideDockMove(PointerMoveEvent e) {
    if (_dockPointer != e.pointer) return;
    if ((e.position - _dockDownAt).distance <= _dockSlop) return;
    _dockAtDown = null;
    _dockPointer = null;
  }

  void _outsideDockUp(PointerUpEvent e) {
    final at = _dockAtDown;
    if (at == null || _dockPointer != e.pointer) return;
    _dockAtDown = null;
    _dockPointer = null;
    scheduleMicrotask(() {
      if (!mounted || !identical(ref.read(infoDockProvider), at)) return;
      _dismissDock();
    });
  }

  void _outsideDockCancel(PointerCancelEvent e) {
    if (_dockPointer != e.pointer) return;
    _dockAtDown = null;
    _dockPointer = null;
  }

  Widget _wide(BuildContext context, bool useColumns) {
    // The mesh screen swaps in like any view; the persistent sidebar needs no hamburger.
    final meshOpen = _meshShown;
    final kv = ref.read(keyValueStoreProvider);
    final sidebarW = _sidebarW ??=
        clampSidebarWidth(kv.getString(StorageKeys.sidebarWidth)).toDouble();
    return Row(
      children: [
        Expanded(
          child: Listener(
            key: const ValueKey('outsideInfoDock'),
            behavior: HitTestBehavior.translucent,
            onPointerDown: _outsideDockDown,
            onPointerMove: _outsideDockMove,
            onPointerUp: _outsideDockUp,
            onPointerCancel: _outsideDockCancel,
            child: Row(
              children: [
        SizedBox(
          width: sidebarW,
          child: Stack(
            children: [
              const Positioned.fill(child: Sidebar()),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: 6,
                child: Semantics(
                  label: tr('Resize sidebar'),
                  value: '${sidebarW.round()}',
                  slider: true,
                  child: KeyResizer(
                    onStep: (dx) {
                      final w = clampSidebarWidth((_sidebarW ?? sidebarW) + dx);
                      setState(() => _sidebarW = w.toDouble());
                      kv.setString(StorageKeys.sidebarWidth, '$w');
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: Listener(
                        onPointerDown: (e) => _resizerPointer = e.pointer,
                        child: GestureDetector(
                          key: const ValueKey('sidebarResizer'),
                          behavior: HitTestBehavior.opaque,
                          dragStartBehavior: DragStartBehavior.down,
                          onHorizontalDragUpdate: (d) => setState(() => _sidebarW =
                              clampSidebarWidth((_sidebarW ?? sidebarW) + d.delta.dx)
                                  .toDouble()),
                          onHorizontalDragEnd: (_) => kv.setString(
                              StorageKeys.sidebarWidth, '${(_sidebarW ?? sidebarW).round()}'),
                          onDoubleTap: () {
                            setState(() => _sidebarW = kSidebarDefault.toDouble());
                            kv.setString(StorageKeys.sidebarWidth, '$kSidebarDefault');
                          },
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: meshOpen ? const MeshScreen() : _content(context, useColumns),
        ),
              ],
            ),
          ),
        ),
        const InfoDockHost(),
      ],
    );
  }

  Widget _mobile(BuildContext context, bool useColumns) {
    // The edge swipe is phone-only (≤768px).
    final width = MediaQuery.of(context).size.width;
    final phone = width <= kPhoneMax;
    final hideChat = phone && _drawerOpen;
    // A raw Listener over the whole shell, drawer included, so the swipe never loses to scrollables.
    final stack = Stack(
      children: [
        Positioned.fill(
          child: ExcludeSemantics(
            key: const ValueKey('phoneChatPage'),
            excluding: hideChat,
            child: _content(context, useColumns, compact: true),
          ),
        ),

        // Mesh overlay beneath the scrim and drawer, so the sidebar opens over it.
        if (!phone && _meshShown)
          Positioned.fill(
            child: ExcludeSemantics(
              excluding: hideChat,
              child: MeshScreen(
                onOpenSidebar: () => setState(() => _drawerOpen = true),
              ),
            ),
          ),

        // Snapping dim backdrop (no fade); 0.35 in solid-ui light mode, else 0.6. Tap to close.
        if (_drawerOpen && !phone)
          GestureDetector(
            key: const ValueKey('drawerScrim'),
            onTap: () => setState(() => _drawerOpen = false),
            child: Container(
              color: Colors.black.withValues(
                alpha: ref.watch(settingsProvider.select((s) => s.solidUi)) &&
                        context.nym.isLight
                    ? 0.35
                    : 0.6,
              ),
            ),
          ),

        // 150ms linear slide, instant under reduce-motion.
        AnimatedSlide(
          duration: MediaQuery.of(context).disableAnimations ||
                  _listDrag != null
              ? Duration.zero
              : NymMotion.slide,
          curve: Curves.linear,
          offset: _drawerOpen
              ? Offset(phone ? (_listDrag ?? 0) / width : 0, 0)
              : const Offset(-1, 0),
          child: SizedBox(
            width: phone ? width : NymDimens.sidebarDrawerWidth,
            height: double.infinity,
            // Rightward-only drop shadow, not a Material elevation.
            child: DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: _drawerOpen && !phone
                    ? [
                        BoxShadow(
                          offset: const Offset(10, 0),
                          blurRadius: 40,
                          color: Colors.black.withValues(alpha: 0.5),
                        ),
                      ]
                    : const [],
              ),
              // Foreground hairline, since the Sidebar paints its own background.
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: phone
                      ? null
                      : Border(
                          left: BorderSide(color: context.nym.glassBorder),
                        ),
                ),
                child: ListSwipeBack(
                  enabled: phone && _drawerOpen && !_meshShown,
                  distance: _sidebarSwipeThreshold,
                  velocity: kNymSheetCloseVelocity,
                  onDrag: (v) {
                    if (mounted) setState(() => _listDrag = v);
                  },
                  onBack: _closeChatList,
                  child: ExcludeFocus(
                    excluding: !_drawerOpen && _listDrag == null,
                    child: Sidebar(
                      hidden: !_drawerOpen && _listDrag == null,
                      compact: true,
                      onItemSelected: phone
                          ? null
                          : () => setState(() => _drawerOpen = false),
                      onClose: phone ? _closeChatList : null,
                      closeShown: _drawerOpen,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (phone && _meshShown)
          Positioned.fill(
            child: MeshScreen(onBackToList: _meshBackToList),
          ),
      ],
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: phone ? _edgePointerDown : null,
      onPointerMove: phone ? _edgePointerMove : null,
      onPointerUp: phone ? _edgePointerEnd : null,
      onPointerCancel: phone ? _edgePointerEnd : null,
      child: stack,
    );
  }
}

/// Ambient corner glows plus a center vignette; ghost uses white tints and light drops the vignette.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.c, required this.isGhost});
  final NymColors c;
  final bool isGhost;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _AmbientGlowPainter(c: c, isGhost: isGhost),
      ),
    );
  }
}

class _AmbientGlowPainter extends CustomPainter {
  _AmbientGlowPainter({required this.c, required this.isGhost});
  final NymColors c;
  final bool isGhost;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    // Light first (it wins for ghost-light by CSS source order), then ghost-dark white, then dark.
    final Color glow20, glow80;
    if (c.isLight) {
      glow20 = c.primary.withValues(alpha: 0.03);
      glow80 = c.secondary.withValues(alpha: 0.02);
    } else if (isGhost) {
      glow20 = Colors.white.withValues(alpha: 0.02);
      glow80 = Colors.white.withValues(alpha: 0.015);
    } else {
      glow20 = c.primary.withValues(alpha: 0.04);
      glow80 = c.secondary.withValues(alpha: 0.03);
    }

    // CSS farthest-corner ellipse: a circular shader stretched by a y-scale matrix about the center.
    void ellipseGradient(double f, List<Color> colors, List<double> stops) {
      final center = Offset(size.width * f, size.height * f);
      final m = math.max(f, 1 - f);
      final rx = math.sqrt2 * m * size.width;
      final ry = math.sqrt2 * m * size.height;
      // Non-mutating constructors work across the whole supported SDK range.
      final matrix = Matrix4.translationValues(center.dx, center.dy, 0.0) *
          Matrix4.diagonal3Values(1.0, ry / rx, 1.0) *
          Matrix4.translationValues(-center.dx, -center.dy, 0.0);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            rx,
            colors,
            stops,
            TileMode.clamp,
            matrix.storage,
          ),
      );
    }

    // Fade ends halfway to the farthest-corner ellipse.
    ellipseGradient(0.2, [glow20, glow20.withValues(alpha: 0)], const [0, 0.5]);
    ellipseGradient(0.8, [glow80, glow80.withValues(alpha: 0)], const [0, 0.5]);

    // Dark non-ghost only: full vignette strength only at the corners.
    if (!isGhost && !c.isLight) {
      ellipseGradient(
        0.5,
        [const Color(0x00000000), Colors.black.withValues(alpha: 0.2)],
        const [0, 1],
      );
    }
  }

  @override
  bool shouldRepaint(_AmbientGlowPainter old) =>
      old.c.primary != c.primary ||
      old.c.secondary != c.secondary ||
      old.c.isLight != c.isLight ||
      old.isGhost != isGhost;
}
