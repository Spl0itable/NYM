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

class _InfoDockHostState extends ConsumerState<InfoDockHost> {
  @override
  void initState() {
    super.initState();
    InfoDock.attach();
  }

  @override
  void dispose() {
    InfoDock.detach();
    super.dispose();
  }

  void _close() => ref.read(infoDockProvider.notifier).state = null;

  void _dismiss() {
    _close();
    ref.read(settingsProvider.notifier).setInfoPanelOpen(false);
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(infoDockProvider);
    if (info == null ||
        infoPanelMode(MediaQuery.sizeOf(context).width) != 'docked') {
      return const SizedBox.shrink();
    }
    final Widget panel;
    if (info.isGroup) {
      panel = GroupContextMenuPanel(
        key: ValueKey('dock-group-${info.groupId}'),
        groupId: info.groupId!,
        animation: kAlwaysCompleteAnimation,
        onClose: _close,
        onDismiss: _dismiss,
        docked: true,
      );
    } else {
      panel = ContextMenuPanel(
        key: ValueKey('dock-user-${info.pubkey}-${info.target!.messageId}'),
        target: info.target!,
        message: info.message,
        animation: kAlwaysCompleteAnimation,
        onReact: info.onReact,
        onTranslateInline: info.onTranslateInline,
        backToGroupId: info.backToGroupId,
        onClose: _close,
        onDismiss: _dismiss,
        docked: true,
      );
    }
    return SizedBox(
      key: const ValueKey('infoDock'),
      width: kDockWidth.toDouble(),
      child: panel,
    );
  }
}
