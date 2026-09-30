import '../../services/notification_service.dart' show NotificationKind;

/// Where a notification came from, carried in the tap payload; PMs and existing groups have no `nymchat://` URL form.
class NotificationRoute {
  const NotificationRoute({
    required this.type,
    this.route = '',
    this.senderPubkey = '',
    this.threadRoot = '',
  });

  /// Bell-history category: pm, group, channel, geohash, mention, reaction or call.
  final String type;

  /// Tap target: peer pubkey, group id, or bare channel name.
  final String route;

  /// Sender, the fallback target for reactions and mentions.
  final String senderPubkey;

  /// Originating thread root, or empty for an ordinary message.
  final String threadRoot;
}

/// Minimal conversation-opening surface so routing is testable without a NostrController.
abstract class NotificationRouteTarget {
  void openChannel(String channel);
  void openPM(String pubkey);
  void openGroup(String groupId);

  /// Called only after an open above, so the thread's conversation is already current.
  void openThread(String threadRoot);
}

/// Distinguishes tap payloads from deep-link URLs sent to the same handler.
const String _kPayloadScheme = 'nymnotif:';

/// Pipe-joined; no field can contain a pipe.
String encodeNotificationPayload({
  required String type,
  String? route,
  String? senderPubkey,
  String? threadRoot,
}) =>
    '$_kPayloadScheme$type|${route ?? ''}|${senderPubkey ?? ''}'
    '|${threadRoot ?? ''}';

/// Decodes a payload from [encodeNotificationPayload], or null so the caller falls through to URL handling.
NotificationRoute? decodeNotificationPayload(String payload) {
  if (!payload.startsWith(_kPayloadScheme)) return null;
  final parts = payload.substring(_kPayloadScheme.length).split('|');
  if (parts.isEmpty || parts.first.isEmpty) return null;
  return NotificationRoute(
    type: parts[0],
    route: parts.length > 1 ? parts[1] : '',
    senderPubkey: parts.length > 2 ? parts[2] : '',
    // Read positionally because older payloads lack the thread root.
    threadRoot: parts.length > 3 ? parts[3] : '',
  );
}

/// True when [value] looks like a hex pubkey.
bool isPubkeyRoute(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

/// Android channel for a history category, so reactions can be silenced separately from PMs.
NotificationKind notificationKindFor(String historyType) {
  switch (historyType) {
    case 'reaction':
      return NotificationKind.activity;
    case 'channel':
    case 'geohash':
    case 'mention':
      return NotificationKind.mention;
    default:
      return NotificationKind.message;
  }
}

/// Groups a conversation's notifications so new ones replace old and opening it can dismiss them.
String notificationConversationKey({
  required String historyType,
  required String route,
}) =>
    '$historyType:$route';

/// Opens the originating conversation for both bell rows and OS taps; returns whether it routed anywhere.
bool openNotificationRoute(
  NotificationRoute target,
  NotificationRouteTarget into,
) {
  final route = target.route;
  final sender = target.senderPubkey;
  // Thread-reply notifications land in the thread once the conversation has opened.
  bool opened(bool ok) {
    if (ok && target.threadRoot.isNotEmpty) into.openThread(target.threadRoot);
    return ok;
  }

  switch (target.type) {
    case 'group':
      if (route.isEmpty) return false;
      into.openGroup(route);
      return opened(true);
    case 'channel':
    case 'geohash':
      // Route is the bare channel name; switchChannel detects geohashes.
      if (route.isEmpty) return false;
      into.openChannel(route);
      return opened(true);
    case 'call':
      // Call routes carry a group id or a 1:1 pubkey.
      if (isPubkeyRoute(route)) {
        into.openPM(route);
        return true;
      }
      if (route.isNotEmpty) {
        into.openGroup(route);
        return true;
      }
      if (sender.isNotEmpty) {
        into.openPM(sender);
        return true;
      }
      return false;
    case 'pm':
    case 'mention':
    case 'reaction':
    default:
      // These route to the sender's PM.
      final peer =
          sender.isNotEmpty ? sender : (isPubkeyRoute(route) ? route : '');
      if (peer.isEmpty) return false;
      into.openPM(peer);
      return opened(true);
  }
}
