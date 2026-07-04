import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/pms/pm_logic.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../nym_icons.dart';

/// One entry in a sidebar row's `.quick-context-menu` (sidebar-sections.js
/// `_buildSidebarMenuItems`).
class SidebarQuickMenuItem {
  const SidebarQuickMenuItem({
    required this.label,
    required this.svg,
    required this.onSelected,
    this.danger = false,
  });
  final String label;

  /// The leading glyph as a [NymIcons] SVG string.
  final String svg;
  final VoidCallback onSelected;
  final bool danger;
}

/// Shows the PWA `.quick-context-menu` at [globalPosition] with [items], styled
/// exactly per `styles-features.css:2778-2846`: bg `rgba(20,20,35,0.92)`, radius
/// 14, padding 4, min-width 200, shadow `0 8 32 rgba(0,0,0,.4)`; items padding
/// 8/12, gap 10, radius 8, font 14, icon `--text-dim` (danger → `--danger`),
/// with a 150ms `scale(0.9→1) + translateY(-6→0) + opacity` entrance. Fires a
/// haptic tap when opened (PWA `window.nymHapticTap`). Returns the chosen item's
/// callback result after dismissal.
Future<void> showSidebarQuickMenu(
  BuildContext context,
  Offset globalPosition,
  List<SidebarQuickMenuItem> items,
) async {
  if (items.isEmpty) return;
  // `nymHapticTap` = a 30ms vibrate (sidebar-sections.js:258) — a solid motor
  // pulse, so mediumImpact rather than the faint lightImpact.
  HapticFeedback.mediumImpact();

  final selected = await Navigator.of(context, rootNavigator: true)
      .push<SidebarQuickMenuItem>(
    _QuickMenuRoute(anchor: globalPosition, items: items),
  );
  selected?.onSelected();
}

/// A transparent route that positions the animated `.quick-context-menu`
/// near the press point and clamps it on-screen. Outside presses dismiss it
/// instantly (no exit animation) after a 400ms opening grace period,
/// mirroring the PWA's `_showSidebarActionMenu` close handling
/// (sidebar-sections.js:137-146) — and, like the PWA's `onOutside` (which
/// never preventDefaults/stopPropagates), they ALSO reach whatever sits under
/// them, so tapping another sidebar row while the menu is open closes the menu
/// AND opens that conversation in one tap.
class _QuickMenuRoute extends PopupRoute<SidebarQuickMenuItem> {
  _QuickMenuRoute({
    required this.anchor,
    required this.items,
  });

  final Offset anchor;
  final List<SidebarQuickMenuItem> items;

  /// Wall-clock open time: outside presses within 400ms of opening are
  /// ignored (`if (Date.now() - openedAt < 400) return`,
  /// sidebar-sections.js:142-146), so the tap that follows the long-press
  /// can't immediately dismiss the menu.
  final DateTime _openedAt = DateTime.now();

  @override
  Color? get barrierColor => null;

  // Outside-press dismissal is handled by the Listener in [buildPage] (with
  // the PWA's 400ms grace period), not the stock barrier.
  @override
  bool get barrierDismissible => false;

  // The PWA has NO barrier: its outside-close handler is a document-level
  // `mousedown`/`touchstart` listener that only removes the menu, so the
  // press also activates the element under it (sidebar-sections.js:142-159).
  // The stock (even colorless) [ModalBarrier] eats every pointer; replace it
  // with a non-hit-testable filler so presses fall through to the routes
  // below.
  @override
  Widget buildModalBarrier() => const IgnorePointer(child: SizedBox.expand());

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  // The PWA's `close()` is a plain `menu.remove()` (sidebar-sections.js:138)
  // — the menu vanishes instantly, no exit transition.
  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Stack(
      children: [
        // Outside presses dismiss on pointer-DOWN (the PWA listens on
        // `mousedown`/`touchstart`), but presses within 400ms of opening are
        // ignored (sidebar-sections.js:142-146). TRANSLUCENT: the press is
        // observed, never consumed — like the PWA's `onOutside`, it also hits
        // whatever lies under it (a row tap opens that conversation, a new
        // 500ms hold starts immediately).
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              if (DateTime.now().difference(_openedAt) <
                  const Duration(milliseconds: 400)) {
                return;
              }
              Navigator.of(context).pop();
            },
            child: const SizedBox.expand(),
          ),
        ),
        // The PWA measures the REAL rendered menu (appended hidden, then
        // `offsetWidth`/`offsetHeight`, sidebar-sections.js:121-126) before
        // clamping; a layout delegate gets the same measured size.
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _QuickMenuLayout(anchor: anchor),
            child: _QuickMenu(animation: animation, items: items),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child; // entrance handled inside _QuickMenu via the animation.
}

/// Places the menu at the press point, clamped on-screen from its MEASURED
/// size — the PWA math (sidebar-sections.js:128-131):
/// `left = max(10, min(x, vw - w - 10))`; top only clamps when overflowing the
/// bottom: `top = max(10, vh - h - 10)`.
class _QuickMenuLayout extends SingleChildLayoutDelegate {
  _QuickMenuLayout({required this.anchor});

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = math.max(
        10.0, math.min(anchor.dx, size.width - childSize.width - 10));
    double top = anchor.dy;
    if (top + childSize.height > size.height - 10) {
      top = math.max(10.0, size.height - childSize.height - 10);
    }
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_QuickMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

class _QuickMenu extends ConsumerWidget {
  const _QuickMenu({required this.animation, required this.items});

  final Animation<double> animation;
  final List<SidebarQuickMenuItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final transparency = ref
        .watch(settingsProvider.select((s) => s.transparencyEnabled));
    // `transition: opacity 0.15s ease, transform 0.15s ease` — CSS `ease`
    // is cubic-bezier(0.25, 0.1, 0.25, 1) == [Curves.ease].
    final curve = CurvedAnimation(parent: animation, curve: Curves.ease);
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) {
        final t = curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            // translateY(-6 → 0)
            offset: Offset(0, -6 * (1 - t)),
            child: Transform.scale(
              // scale(0.9 → 1); no `transform-origin` is set on
              // `.quick-context-menu`, so the CSS default (50% 50%) applies.
              scale: 0.9 + 0.1 * t,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: Material(
        type: MaterialType.transparency,
        // The CSS menu is a fixed-position flex column with `min-width: 200px`
        // and NO max-width — shrink-to-fit, so its width is
        // max(200, widest item), never the viewport. IntrinsicWidth gives the
        // same sizing (the Column's stretch alignment would otherwise inflate
        // to the loose screen-wide constraint from the layout delegate).
        child: IntrinsicWidth(
          child: Container(
            constraints: const BoxConstraints(minWidth: 200),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              // `.quick-context-menu` bg: with Transparency ON (no `solid-ui`
              // body class) the PWA paints translucent rgba(20,20,35,0.92)
              // dark (styles-features.css:2783) / rgba(255,255,255,0.96)
              // light (styles-themes-responsive.css:1340); with Transparency
              // OFF (`solid-ui`, the default) it's the opaque
              // `var(--glass-bg)` (styles-themes-responsive.css:1590-1600).
              color: transparency
                  ? (c.isLight
                      ? const Color(0xF5FFFFFF) // rgba(255,255,255,0.96)
                      : const Color(0xEB141423)) // rgba(20,20,35,0.92)
                  : c.glassBg,
              borderRadius: BorderRadius.circular(14),
              // Border: `var(--glass-border)` dark; light mode overrides to
              // rgba(0,0,0,0.1) (styles-themes-responsive.css:1341).
              border: Border.all(
                color: c.isLight ? const Color(0x1A000000) : c.glassBorder,
              ),
              // Shadow: 0 8 32 rgba(0,0,0,0.4) dark / rgba(0,0,0,0.15) light.
              boxShadow: [
                BoxShadow(
                  color: c.isLight
                      ? const Color(0x26000000)
                      : const Color(0x66000000),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in items)
                  _QuickMenuRow(item: a),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickMenuRow extends StatefulWidget {
  const _QuickMenuRow({required this.item});
  final SidebarQuickMenuItem item;

  @override
  State<_QuickMenuRow> createState() => _QuickMenuRowState();
}

class _QuickMenuRowState extends State<_QuickMenuRow> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final a = widget.item;
    final fg = a.danger ? c.danger : c.text;
    final iconColor = a.danger ? c.danger : c.textDim;
    // Background per the CSS cascade (styles-features.css:2819-2846 + light
    // overrides styles-themes-responsive.css:1346-1352):
    //  - dark: `.quick-context-item.danger:hover` (0,3,0) red@0.12 outranks
    //    the equal-specificity `:hover` white@0.08 and `:active` white@0.12
    //    (0,2,0 each, `:active` declared last so it wins over `:hover`);
    //  - light: `body.light-mode .quick-context-item:hover/:active` (0,3,1)
    //    black@0.06 / black@0.1 outrank `.danger:hover`, so danger rows get
    //    the SAME neutral fills as regular rows.
    final Color bg;
    if (c.isLight) {
      bg = _pressed
          ? Colors.black.withValues(alpha: 0.1)
          : _hover
              ? Colors.black.withValues(alpha: 0.06)
              : Colors.transparent;
    } else if (a.danger && _hover) {
      bg = c.dangerHoverOverlay; // rgba(255,68,68,0.12)
    } else if (_pressed) {
      bg = Colors.white.withValues(alpha: 0.12);
    } else if (_hover) {
      bg = Colors.white.withValues(alpha: 0.08);
    } else {
      bg = Colors.transparent;
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(a),
        // `:active` pressed feedback while the pointer is down.
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          // `transition: background 0.12s ease` (styles-features.css:2811).
          duration: const Duration(milliseconds: 120),
          curve: Curves.ease,
          // `.quick-context-item`: padding 8/12, gap 10, radius 8, font 14.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              NymSvgIcon(a.svg, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Text(
                a.label,
                style: TextStyle(color: fg, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the PM `.quick-context-menu` at [globalPosition] with Block/Unblock
/// user + Leave conversation, mirroring the PWA's `_buildSidebarMenuItems`
/// pm-item branch (sidebar-sections.js:216-235). Block toggles via
/// [NostrController.toggleBlockUser]; Leave runs the PWA's `deletePM` flow
/// (pms.js:2849-2879): confirm → stamp read + drop unread → close (records
/// `closedPMs`) → switch away if viewing → "PM conversation deleted".
Future<void> showPmContextMenu(
  BuildContext context,
  WidgetRef ref,
  String pubkey,
  Offset globalPosition,
) async {
  if (pubkey.isEmpty) return;
  final controller = ref.read(nostrControllerProvider);
  final isBlocked = ref.read(appStateProvider).blockedUsers.contains(pubkey);

  final items = <SidebarQuickMenuItem>[
    SidebarQuickMenuItem(
      label: isBlocked ? 'Unblock user' : 'Block user',
      // PWA uses the same `blockSvg` for both block + unblock states.
      svg: NymIcons.sidebarBlock,
      danger: !isBlocked,
      onSelected: () => controller.toggleBlockUser(pubkey),
    ),
    SidebarQuickMenuItem(
      label: 'Leave conversation',
      // PWA `leaveSvg` is the feather log-out (== NymIcons.logout).
      svg: NymIcons.logout,
      danger: true,
      onSelected: () async {
        if (!context.mounted) return;
        // `deletePM` (pms.js:2849): danger confirm before anything happens.
        final ok = await showAppConfirm(
          context,
          'Delete this PM conversation?',
          danger: true,
          okLabel: 'Delete',
        );
        if (!ok || !context.mounted) return;
        final notifier = ref.read(appStateProvider.notifier);
        // `channelLastRead.set(conversationKey, now)` + delete the
        // conversation's `unreadCounts` entry so no stale badge survives.
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        notifier.markChannelRead(pubkey, nowSec);
        notifier.markChannelRead(PmLogic.pmStorageKey(pubkey), nowSec);
        ref.read(appStateProvider).unreadCounts
          ..remove(pubkey)
          ..remove(PmLogic.pmStorageKey(pubkey));
        final view = ref.read(appStateProvider).view;
        final wasViewing = view.kind == ViewKind.pm && view.id == pubkey;
        notifier.closePM(pubkey);
        // "If currently viewing this PM, switch to bar":
        // `switchChannel('nymchat','nymchat')`.
        if (wasViewing) controller.switchChannel(kDefaultChannel);
        notifier.addSystemMessage('PM conversation deleted');
      },
    ),
  ];

  await showSidebarQuickMenu(context, globalPosition, items);
}
