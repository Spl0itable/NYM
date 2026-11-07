import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../toasts/event_toast_center.dart';
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
  bool openGroup(String groupId) {
    if (appState.groupById(groupId) == null ||
        appState.isLeftGroup(groupId)) {
      return false;
    }
    appState.switchView(ChatView.group(groupId));
    return true;
  }

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

NotificationRoute notificationRouteOfEntry(NotificationEntry entry) {
  final stored = entry.source ?? '';
  final channel = entry.channel ?? '';
  return NotificationRoute(
    type: entry.type,
    route: entry.route ?? '',
    senderPubkey: entry.senderPubkey ?? '',
    threadRoot: entry.threadRoot ?? '',
    source: stored.isNotEmpty
        ? stored
        : (entry.type == 'reaction' && channel.isNotEmpty ? '#$channel' : ''),
  );
}

NotificationRoute notificationRouteOfToast(EventToastTarget target) =>
    NotificationRoute(
      type: target.type,
      route: target.route,
      senderPubkey: target.senderPubkey,
      threadRoot: target.threadRoot,
      source: target.source,
    );

NotificationRoute withHistorySource(
    NotificationRoute target, Iterable<NotificationEntry> entries) {
  if (target.source != kLockedNotificationSource) return target;
  if (target.type != 'reaction') return target.withSource('');
  NotificationEntry? best;
  for (final e in entries) {
    if (e.type != 'reaction' || !e.locked) continue;
    if ((e.route ?? '') != target.route) continue;
    if (target.senderPubkey.isNotEmpty &&
        (e.senderPubkey ?? '') != target.senderPubkey) {
      continue;
    }
    if (notificationRouteOfEntry(e).source.isEmpty) continue;
    if (best == null || e.ts > best.ts) best = e;
  }
  return target.withSource(
      best == null ? '' : notificationRouteOfEntry(best).source);
}

bool openNotificationTap(ProviderContainer container, String payload) {
  final target = decodeNotificationPayload(payload);
  if (target == null) return false;
  final controller = container.read(nostrControllerProvider);
  controller.notificationTaps.open(() {
    openNotificationRoute(
      withHistorySource(
          target, container.read(notificationHistoryProvider).entries),
      AppNotificationRouteTarget(
        controller: controller,
        appState: container.read(appStateProvider.notifier),
        container: container,
      ),
    );
  });
  return true;
}
