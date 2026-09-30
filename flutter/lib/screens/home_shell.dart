import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/theme/nym_colors.dart';
import '../core/theme/nym_metrics.dart';
import '../features/calls/call_overlay.dart';
import '../features/calls/call_providers.dart';
import '../features/calls/incoming_call.dart';
import '../features/mesh/mesh_controller.dart' show meshScreenOpenProvider;
import '../features/mesh/mesh_screen.dart';
import '../features/nymbot/bot_credits_modal.dart';
import '../features/nymbot/nymbot_providers.dart'
    show BotBuyRequest, botBuyRequestProvider, botChatControllerProvider;
import '../features/onboarding/tutorial_overlay.dart';
import '../services/location/geolocation.dart';
import '../widgets/context_menu/context_menu_actions.dart';
import '../widgets/context_menu/context_menu_panel.dart';
import '../widgets/context_menu/group_context_menu_panel.dart';
import '../core/utils/nym_utils.dart';
import '../state/app_state.dart';
import '../state/nostr_controller.dart';
import '../state/settings_provider.dart';
import '../widgets/context_menu/interaction_hooks.dart';
import '../widgets/chat/chat_pane.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/wallpaper/wallpaper_layer.dart';

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

  /// Dedicated edge-swipe threshold, not the user-tunable message `swipeThreshold`.
  static const double _sidebarSwipeThreshold = 50;

  /// Pointer armed by a touch within 50px of an edge, or null.
  int? _edgeSwipePointer;

  double _edgeSwipeStartX = 0;

  /// The right edge drives the thread.
  bool _edgeSwipeFromRight = false;

  /// The thread last closed, so a right-edge swipe can step back into it.
  ActiveThread? _lastThread;

  @override
  void initState() {
    super.initState();
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
    // Right edge, traveling left: step back into the thread just left.
    if (_edgeSwipeFromRight) {
      if (_edgeSwipeStartX - e.position.dx > _sidebarSwipeThreshold) {
        _edgeSwipePointer = null;
        _reopenLastThread();
      }
      return;
    }
    if (e.position.dx - _edgeSwipeStartX > _sidebarSwipeThreshold) {
      _edgeSwipePointer = null;
      // An open drawer closes first, then a thread backs out, and only then does the drawer open.
      if (_drawerOpen) {
        setState(() => _drawerOpen = false);
        return;
      }
      if (ref.read(activeThreadProvider) != null) {
        ref.read(activeThreadProvider.notifier).state = null;
        return;
      }
      setState(() => _drawerOpen = true);
    }
  }

  /// Back into the thread just left, else the PM/group header's menu.
  void _reopenLastThread() {
    if (_drawerOpen) return;
    if (ref.read(activeThreadProvider) != null) return;
    final app = ref.read(appStateProvider);
    final thread = _lastThread;
    if (appThreadsEnabled && thread != null && thread.view == app.view) {
      if (threadRootMessage(app, thread.view.storageKey, thread.rootId) != null) {
        ref.read(activeThreadProvider.notifier).state = thread;
        return;
      }
      _lastThread = null;
    }
    _openConversationMenu(app);
  }

  /// Channels have no header menu, so the swipe does nothing there.
  void _openConversationMenu(AppState app) {
    final view = app.view;
    if (view.kind == ViewKind.group) {
      GroupContextMenuPanel.show(context, view.id);
      return;
    }
    if (view.kind != ViewKind.pm || view.id.isEmpty) return;
    final controller = ref.read(nostrControllerProvider);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: view.id,
        nym: stripPubkeySuffix(app.users[view.id]?.nym ?? ''),
        isSelf: view.id == app.selfPubkey,
        isBot: controller.isVerifiedBot(view.id),
        profileOnly: true,
      ),
    );
  }

  /// Any touch lift disarms.
  void _edgePointerEnd(PointerEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _edgeSwipePointer = null;
    _edgeSwipeFromRight = false;
  }

  @override
  Widget build(BuildContext context) {
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

    // A real view change closes the mobile drawer; a closed thread is remembered for the right-edge swipe.
    ref.listen(activeThreadProvider, (prev, next) {
      if (prev != null && next == null) _lastThread = prev;
      if (next != null) _lastThread = null;
    });

    ref.listen(appStateProvider.select((s) => s.view), (prev, next) {
      if (prev != next && _narrow && _drawerOpen && mounted) {
        setState(() => _drawerOpen = false);
      }
      // Switching conversations also dismisses the mesh overlay.
      if (prev != next && ref.read(meshScreenOpenProvider)) {
        ref.read(meshScreenOpenProvider.notifier).state = false;
      }
    });

    final c = context.nym;
    final width = MediaQuery.of(context).size.width;
    // The drawer governs the 0–1024 range; two panes only above 1024.
    final isWide = width > NymDimens.tabletBreakpoint;
    _narrow = !isWide;

    final useColumns = ref.watch(settingsProvider.select((s) => s.useColumns));
    final isGhost =
        ref.watch(settingsProvider.select((s) => s.theme == NymThemeKey.ghost));

    // Back unwinds thread, mesh screen and drawer in swipe order, leaving the app only when nothing is open.
    final canLeave = !(_drawerOpen ||
        ref.watch(meshScreenOpenProvider) ||
        ref.watch(activeThreadProvider) != null);
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _popInApp();
      },
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
    ));
  }

  /// Closes the innermost open thing, one per press.
  void _popInApp() {
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

  Widget _wide(BuildContext context, bool useColumns) {
    // The mesh screen swaps in like any view; the persistent sidebar needs no hamburger.
    final meshOpen = ref.watch(meshScreenOpenProvider);
    return Row(
      children: [
        const SizedBox(width: NymDimens.sidebarWidth, child: Sidebar()),
        Expanded(
          child: meshOpen ? const MeshScreen() : _content(context, useColumns),
        ),
      ],
    );
  }

  Widget _mobile(BuildContext context, bool useColumns) {
    // The edge swipe is phone-only (≤768px).
    final phone = MediaQuery.of(context).size.width <= 768;
    // A raw Listener over the whole shell, drawer included, so the swipe never loses to scrollables.
    final stack = Stack(
      children: [
        Positioned.fill(
          child: _content(context, useColumns, compact: true),
        ),

        // Mesh overlay beneath the scrim and drawer, so the sidebar opens over it.
        if (ref.watch(meshScreenOpenProvider))
          Positioned.fill(
            child: MeshScreen(
              onOpenSidebar: () => setState(() => _drawerOpen = true),
            ),
          ),

        // Snapping dim backdrop (no fade); 0.35 in solid-ui light mode, else 0.6. Tap to close.
        if (_drawerOpen)
          GestureDetector(
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
          duration: MediaQuery.of(context).disableAnimations
              ? Duration.zero
              : NymMotion.slide,
          curve: Curves.linear,
          offset: _drawerOpen ? Offset.zero : const Offset(-1, 0),
          child: SizedBox(
            width: NymDimens.sidebarDrawerWidth,
            height: double.infinity,
            // Rightward-only drop shadow, not a Material elevation.
            child: DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: _drawerOpen
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
                  border: Border(
                    left: BorderSide(color: context.nym.glassBorder),
                  ),
                ),
                child: Sidebar(
                  compact: true,
                  onItemSelected: () => setState(() => _drawerOpen = false),
                ),
              ),
            ),
          ),
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
