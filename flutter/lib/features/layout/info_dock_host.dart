import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/context_menu/group_context_menu_panel.dart';
import 'info_dock.dart';
import 'layout_model.dart';

void openConversationInfo(BuildContext context, WidgetRef ref) {
  final app = ref.read(appStateProvider);
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

bool dockShowsView(DockedInfo? info, ChatView view) {
  if (info == null) return false;
  if (view.kind == ViewKind.group) return info.groupId == view.id;
  if (view.kind == ViewKind.pm) return info.pubkey == view.id;
  return false;
}

void toggleConversationInfo(BuildContext context, WidgetRef ref) {
  final view = ref.read(appStateProvider).view;
  final dock = ref.read(infoDockProvider);
  final settings = ref.read(settingsProvider.notifier);
  if (dockShowsView(dock, view)) {
    ref.read(infoDockProvider.notifier).state = null;
    settings.setInfoPanelOpen(false);
    return;
  }
  openConversationInfo(context, ref);
  if (InfoDock.canDock(context)) settings.setInfoPanelOpen(true);
}

void followConversationInfo(BuildContext context, WidgetRef ref) {
  if (!InfoDock.canDock(context)) return;
  if (!ref.read(settingsProvider).infoPanelOpen) return;
  final view = ref.read(appStateProvider).view;
  if (view.kind == ViewKind.group || view.kind == ViewKind.pm) {
    if (!dockShowsView(ref.read(infoDockProvider), view)) {
      openConversationInfo(context, ref);
    }
  } else {
    ref.read(infoDockProvider.notifier).state = null;
  }
}

class InfoDockHost extends ConsumerStatefulWidget {
  const InfoDockHost({super.key});

  @override
  ConsumerState<InfoDockHost> createState() => _InfoDockHostState();
}

class _InfoDockHostState extends ConsumerState<InfoDockHost>
    with TickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 150));
  late final AnimationController _out = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 150));
  DockedInfo? _shown;
  DockedInfo? _leaving;
  final Map<String, GlobalKey> _slots = {};

  @override
  void initState() {
    super.initState();
    InfoDock.attach();
    _shown = ref.read(infoDockProvider);
    if (_shown != null) _slide.value = 1;
  }

  @override
  void dispose() {
    _slide.dispose();
    _out.dispose();
    InfoDock.detach();
    super.dispose();
  }

  void _close() => ref.read(infoDockProvider.notifier).state = null;

  void _dismiss() {
    _close();
    ref.read(settingsProvider.notifier).setInfoPanelOpen(false);
  }

  void _follow(DockedInfo? next) {
    if (!mounted) return;
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (next != null) {
      final prev = _shown;
      final opening = prev == null || _slide.status == AnimationStatus.reverse;
      _shown = next;
      if (still) {
        _slide.value = 1;
        _leaving = null;
      } else if (opening) {
        _slide.forward();
      } else if (prev.isGroup != next.isGroup) {
        _crossSlide(prev);
      }
      return;
    }
    _leaving = null;
    _out.stop();
    if (still || _shown == null) {
      _slide.value = 0;
      _shown = null;
      return;
    }
    _slide.reverse().whenCompleteOrCancel(() {
      if (!mounted || ref.read(infoDockProvider) != null) return;
      setState(() => _shown = null);
    });
  }

  void _crossSlide(DockedInfo prev) {
    _leaving = prev;
    _out.value = _slide.value;
    _slide.value = 0;
    _slide.forward();
    _out.reverse().whenCompleteOrCancel(() {
      if (!mounted || !identical(_leaving, prev)) return;
      setState(() => _leaving = null);
    });
  }

  Widget _panelFor(DockedInfo info, Animation<double> animation) {
    if (info.isGroup) {
      return GroupContextMenuPanel(
        key: ValueKey('dock-group-${info.groupId}'),
        groupId: info.groupId!,
        animation: animation,
        onClose: _close,
        onDismiss: _dismiss,
        docked: true,
      );
    }
    return ContextMenuPanel(
      key: ValueKey('dock-user-${info.pubkey}-${info.target!.messageId}'),
      target: info.target!,
      message: info.message,
      animation: animation,
      onReact: info.onReact,
      onTranslateInline: info.onTranslateInline,
      backToGroupId: info.backToGroupId,
      onClose: _close,
      onDismiss: _dismiss,
      docked: true,
    );
  }

  String _idOf(DockedInfo info) => info.isGroup
      ? 'group-${info.groupId}'
      : 'user-${info.pubkey}-${info.target!.messageId}';

  Widget _slot(DockedInfo info, Animation<double> animation,
          {required bool ignoring}) =>
      KeyedSubtree(
        key: _slots.putIfAbsent(_idOf(info), () => GlobalKey()),
        child: IgnorePointer(
          ignoring: ignoring,
          child: _panelFor(info, animation),
        ),
      );

  @override
  Widget build(BuildContext context) {
    ref.listen<DockedInfo?>(infoDockProvider, (_, next) => _follow(next));
    final live = ref.watch(infoDockProvider);
    final info = live ?? _shown;
    if (info == null ||
        infoPanelMode(MediaQuery.sizeOf(context).width) != 'docked') {
      return const SizedBox.shrink();
    }
    final leaving = live != null &&
            _leaving != null &&
            _leaving!.isGroup != info.isGroup
        ? _leaving
        : null;
    final kept = {_idOf(info), if (leaving != null) _idOf(leaving)};
    _slots.removeWhere((id, _) => !kept.contains(id));
    if (live == null) {
      return SizedBox(
        width: 0,
        child: OverflowBox(
          alignment: Alignment.centerRight,
          minWidth: kDockWidth.toDouble(),
          maxWidth: kDockWidth.toDouble(),
          child: _slot(info, _slide, ignoring: true),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('infoDock'),
      width: kDockWidth.toDouble(),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          _slot(info, _slide, ignoring: false),
          if (leaving != null) _slot(leaving, _out, ignoring: true),
        ],
      ),
    );
  }
}
