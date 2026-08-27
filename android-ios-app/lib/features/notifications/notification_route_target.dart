import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'notification_routing.dart';

/// The live app's [NotificationRouteTarget]: opening a conversation is a
/// channel switch, a PM open, or a group view switch — and, when the
/// notification came from a thread, swapping that conversation to the thread.
class AppNotificationRouteTarget implements NotificationRouteTarget {
  const AppNotificationRouteTarget({
    required this.controller,
    required this.appState,
    this.container,
  });

  final NostrController controller;
  final AppStateNotifier appState;

  /// Used to open a thread once its conversation is showing. Optional so a
  /// caller with no container still routes conversations (thread taps then land
  /// on the flat conversation, which is the pre-thread behaviour).
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

/// Swaps the just-opened conversation to the thread rooted at [threadRoot].
///
/// The conversation open that precedes this sets the current view, so that view
/// IS the thread's conversation. Applied immediately AND post-frame, exactly
/// like `openMessageThread`: a view switch can fire listeners that clear the
/// active thread, and setting it in both orders wins either race.
///
/// Takes the container rather than a `WidgetRef` because the caller may pop its
/// route first — the bell modal does — and reading through a disposed ref
/// throws before the post-frame pass ever runs.
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
