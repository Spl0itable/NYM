import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/nym_colors.dart';
import '../core/theme/nym_metrics.dart';
import '../features/calls/call_overlay.dart';
import '../features/calls/call_providers.dart';
import '../features/calls/incoming_call.dart';
import '../state/settings_provider.dart';
import '../widgets/chat/chat_pane.dart';
import '../widgets/columns/columns_deck.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/wallpaper/wallpaper_layer.dart';

/// The responsive root of the app shell (`.container`, docs/specs/02 §1.1–1.2).
///
/// Desktop (width >= 769): a Row of [Sidebar 290px, Expanded(ChatPane)].
/// Mobile/tablet (< 769): the ChatPane fills the width with an off-canvas
/// 300px drawer sidebar that slides in over 150ms behind a dim 0.5 black
/// backdrop; the chat-header hamburger opens it.
///
/// The call overlay + incoming-call modal are mounted above everything, and
/// the CallService is read on mount so inbound call signals are handled even
/// before any call UI appears.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    // Constructing the CallService registers the inbound call-signal handler.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(callServiceProvider);
    });
  }

  void _startCall(String peer, {required bool video}) {
    ref.read(callServiceProvider).startCall(peer, video: video);
  }

  void _startGroupCall(String groupId, {required bool video}) {
    ref.read(callServiceProvider).startGroupCall(groupId, video: video);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final width = MediaQuery.of(context).size.width;
    final isDesktop = width > NymDimens.mobileBreakpoint;

    // Deck (multi-column) vs single chat view (`nym_chat_view_mode`).
    final useColumns =
        ref.watch(settingsProvider.select((s) => s.useColumns));

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          // `#wallpaperLayer` — fixed, behind all content, pointer-events:none.
          const Positioned.fill(child: WallpaperLayer()),
          Positioned.fill(
            child: isDesktop
                ? _desktop(context, useColumns)
                : _mobile(context, useColumns),
          ),
          // Active-call UI and incoming-call modal render nothing when idle.
          const Positioned.fill(child: CallOverlay()),
          const Positioned.fill(child: IncomingCallModal()),
        ],
      ),
    );
  }

  /// The main content region: the single ChatPane, or the columns deck when
  /// `chatViewMode == 'columns'`.
  Widget _content(BuildContext context, bool useColumns, {bool compact = false}) {
    if (useColumns) return const ColumnsDeck();
    return ChatPane(
      compact: compact,
      onOpenSidebar:
          compact ? () => setState(() => _drawerOpen = true) : null,
      onStartCall: _startCall,
      onStartGroupCall: _startGroupCall,
    );
  }

  Widget _desktop(BuildContext context, bool useColumns) {
    return Row(
      children: [
        const SizedBox(width: NymDimens.sidebarWidth, child: Sidebar()),
        Expanded(child: _content(context, useColumns)),
      ],
    );
  }

  Widget _mobile(BuildContext context, bool useColumns) {
    return Stack(
      children: [
        Positioned.fill(
          child: _content(context, useColumns, compact: true),
        ),

        // Dim backdrop (`.mobile-overlay`, black @0.5), tap to close.
        IgnorePointer(
          ignoring: !_drawerOpen,
          child: AnimatedOpacity(
            duration: NymMotion.slide,
            opacity: _drawerOpen ? 1 : 0,
            child: GestureDetector(
              onTap: () => setState(() => _drawerOpen = false),
              child: Container(color: Colors.black.withValues(alpha: 0.5)),
            ),
          ),
        ),

        // Off-canvas drawer: translateX(-100%) → 0 over 150ms linear.
        AnimatedSlide(
          duration: NymMotion.slide,
          curve: Curves.linear,
          offset: _drawerOpen ? Offset.zero : const Offset(-1, 0),
          child: SizedBox(
            width: NymDimens.sidebarDrawerWidth,
            height: double.infinity,
            child: Material(
              elevation: _drawerOpen ? 16 : 0,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              child: Sidebar(
                onItemSelected: () => setState(() => _drawerOpen = false),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
