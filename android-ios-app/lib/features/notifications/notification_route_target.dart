import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'notification_routing.dart';

/// The live app's [NotificationRouteTarget]: opening a conversation is a
/// channel switch, a PM open, or a group view switch.
class AppNotificationRouteTarget implements NotificationRouteTarget {
  const AppNotificationRouteTarget({
    required this.controller,
    required this.appState,
  });

  final NostrController controller;
  final AppStateNotifier appState;

  @override
  void openChannel(String channel) => controller.switchChannel(channel);

  @override
  void openPM(String pubkey) => controller.startPM(pubkey);

  @override
  void openGroup(String groupId) =>
      appState.switchView(ChatView.group(groupId));
}
