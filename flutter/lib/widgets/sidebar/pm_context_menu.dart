
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/haptics.dart';
import '../../features/chat_tools/chat_tools_ui.dart';
import '../../features/group_tools/group_tools_ui.dart';
import '../../features/i18n/i18n.dart';
import '../../features/pms/pm_logic.dart';
import '../../features/toasts/toast_center.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_action_sheet.dart';
import '../context_menu/group_context_menu_panel.dart' show showGroupMenuSheet;
import '../../features/chat_nav/chat_nav_ui.dart';
import '../../features/chat_lock/chat_lock_ui.dart';
import '../nym_icons.dart';
import '../anchored_popup.dart';

class SidebarQuickMenuItem {
  const SidebarQuickMenuItem({
    required this.label,
    required this.svg,
    required this.onSelected,
    this.danger = false,
  });
  final String label;

  final String svg;
  final VoidCallback onSelected;
  final bool danger;
}

List<SidebarQuickMenuItem> chatToolSidebarItems(
    BuildContext context, String storageKey) {
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  return [
    SidebarQuickMenuItem(
      label: tr('Media, files & links'),
      svg: ChatToolIcons.media,
      onSelected: () {
        if (rootContext.mounted) ChatMediaPanel.open(rootContext, storageKey);
      },
    ),
    SidebarQuickMenuItem(
      label: tr('Export chat'),
      svg: ChatToolIcons.exportChat,
      onSelected: () {
        if (rootContext.mounted) ExportChatPanel.open(rootContext, storageKey);
      },
    ),
    for (final item in gtSidebarItems(storageKey))
      SidebarQuickMenuItem(
        label: item.label,
        svg: item.svg,
        onSelected: () {
          if (rootContext.mounted) item.onTap(rootContext);
        },
      ),
  ];
}

/// Shows the sidebar `.quick-context-menu` at [globalPosition] with a haptic tap on open.
Future<void> showSidebarQuickMenu(
  BuildContext context,
  Offset globalPosition,
  List<SidebarQuickMenuItem> items, {
  String? groupId,
}) async {
  if (items.isEmpty) return;
  Haptics.selection();

  if (useNymActionSheet(context)) {
    final entries = [
      for (final a in items)
        NymActionEntry<SidebarQuickMenuItem>(
            label: a.label, svg: a.svg, value: a, danger: a.danger),
    ];
    final picked = groupId != null
        ? await showGroupMenuSheet<SidebarQuickMenuItem>(
            context, groupId, entries)
        : await showNymActionSheet<SidebarQuickMenuItem>(context, entries);
    picked?.onSelected();
    return;
  }

  final selected = await Navigator.of(context, rootNavigator: true)
      .push<SidebarQuickMenuItem>(
    _QuickMenuRoute(anchor: globalPosition, items: items),
  );
  selected?.onSelected();
}

/// Barrier-less popup route: outside presses dismiss after a 400ms grace and also reach what lies beneath.
class _QuickMenuRoute extends PopupRoute<SidebarQuickMenuItem> {
  _QuickMenuRoute({
    required this.anchor,
    required this.items,
  });

  final Offset anchor;
  final List<SidebarQuickMenuItem> items;

  /// Outside presses within 400ms are ignored so the tap after the long-press can't dismiss the menu.
  final DateTime _openedAt = DateTime.now();

  @override
  Color? get barrierColor => null;

  // Outside-press dismissal is handled by the Listener in [buildPage], not the stock barrier.
  @override
  bool get barrierDismissible => false;

  // The stock [ModalBarrier] eats every pointer; a non-hit-testable filler lets presses fall through.
  @override
  Widget buildModalBarrier() => const IgnorePointer(child: SizedBox.expand());

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  // The PWA menu vanishes instantly, with no exit transition.
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
        // Dismiss on pointer-down; translucent so the press also hits whatever lies under it.
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
        // Layout delegate measures the rendered menu before clamping it on-screen.
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: PointPopupLayout(
                anchor: anchor, insets: popupInsetsOf(context)),
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
      child;
}

class _QuickMenu extends ConsumerWidget {
  const _QuickMenu({required this.animation, required this.items});

  final Animation<double> animation;
  final List<SidebarQuickMenuItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final transparency =
        ref.watch(settingsProvider.select((s) => s.transparencyEnabled));
    final curve = CurvedAnimation(parent: animation, curve: Curves.ease);
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) {
        final t = curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, -6 * (1 - t)),
            child: Transform.scale(
              scale: 0.9 + 0.1 * t,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: Material(
        type: MaterialType.transparency,
        // Shrink-to-fit width of max(200, widest item); IntrinsicWidth stops the stretch Column filling the screen.
        child: IntrinsicWidth(
          child: Container(
            constraints: const BoxConstraints(minWidth: 200),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: transparency
                  ? (c.isLight
                      ? const Color(0xF5FFFFFF)
                      : const Color(0xEB141423))
                  : c.glassBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: c.isLight ? const Color(0x1A000000) : c.glassBorder,
              ),
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
                for (final a in items) _QuickMenuRow(item: a),
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
    // In light mode, danger rows get the same neutral hover/active fills as regular rows (CSS specificity).
    final Color bg;
    if (c.isLight) {
      bg = _pressed
          ? Colors.black.withValues(alpha: 0.1)
          : _hover
              ? Colors.black.withValues(alpha: 0.06)
              : Colors.transparent;
    } else if (a.danger && _hover) {
      bg = c.dangerHoverOverlay;
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
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.ease,
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

/// PM quick menu with Block/Unblock and Leave conversation (the PWA `deletePM` flow).
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
    ...chatNavSidebarItems(ref, 'pm-${pubkey.toLowerCase()}'),
    ...chatLockSidebarItems(ref, 'pm-${pubkey.toLowerCase()}'),
    ...chatToolSidebarItems(context, PmLogic.pmStorageKey(pubkey)),
    SidebarQuickMenuItem(
      label: isBlocked ? tr('Unblock user') : tr('Block user'),
      svg: NymIcons.sidebarBlock,
      danger: !isBlocked,
      onSelected: () => controller.toggleBlockUser(pubkey),
    ),
    SidebarQuickMenuItem(
      label: tr('Leave conversation'),
      svg: NymIcons.logout,
      danger: true,
      onSelected: () async {
        if (!context.mounted) return;
        final ok = await showAppConfirm(
          context,
          tr('Delete this PM conversation?'),
          danger: true,
          okLabel: tr('Delete'),
        );
        if (!ok || !context.mounted) return;
        final notifier = ref.read(appStateProvider.notifier);
        // Mark read and drop the unread count so no stale badge survives.
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        notifier.markChannelRead(pubkey, nowSec);
        notifier.markChannelRead(PmLogic.pmStorageKey(pubkey), nowSec);
        ref.read(appStateProvider).unreadCounts
          ..remove(pubkey)
          ..remove(PmLogic.pmStorageKey(pubkey));
        final view = ref.read(appStateProvider).view;
        final wasViewing = view.kind == ViewKind.pm && view.id == pubkey;
        notifier.closePM(pubkey);
        if (wasViewing) controller.switchChannel(kDefaultChannel);
        showToast(tr('PM conversation deleted'));
      },
    ),
  ];

  await showSidebarQuickMenu(context, globalPosition, items);
}
