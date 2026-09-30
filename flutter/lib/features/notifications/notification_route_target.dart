import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'notification_routing.dart';

/// Opens the notified conversation and, for thread notifications, swaps it to the thread.
class AppNotificationRouteTarget implements NotificationRouteTarget {
  const AppNotificationRouteTarget({
    required this.controller,
    required this.appState,
    this.container,
  });

  final NostrController controller;
  final AppStateNotifier appState;

  /// Optional; without it thread taps land on the flat conversation.
  final ProviderContainer? container;

  @override
  void openChannel(String channel) => controller.switchChannel(channel);

  @override
  void openPM(String pubkey) => controller.startPM(pubkey);

  @override
  void openGroup(String groupId) =>
      appState.switchView(ChatView.group(groupId));

  @override
  void openThread(String threadRoot) {
    final c = container;
    if (c != null) openNotificationThread(c, threadRoot);
  }
}

/// Set immediately and post-frame to win the race with view-switch listeners; takes a container since the ref may be disposed.
void openNotificationThread(ProviderContainer container, String threadRoot) {
  if (!appThreadsEnabled || threadRoot.isEmpty) return;
  final threads = container.read(activeThreadProvider.notifier);
  void apply() {
    threads.state = ActiveThread(
      view: container.read(appStateProvider).view,
      rootId: threadRoot,
    );
  }

  apply();
  WidgetsBinding.instance.addPostFrameCallback((_) => apply());
}
