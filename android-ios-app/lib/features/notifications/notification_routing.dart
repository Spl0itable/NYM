import '../../services/notification_service.dart' show NotificationKind;

/// Where a notification came from, so tapping it can open that conversation.
///
/// This rides in the OS notification's tap payload. It is deliberately NOT a
/// `nymchat://` deep link: `parseNymLink` only understands channels, geohashes
/// and group invites, so a PM or an existing group conversation has no URL form
/// — a tapped PM notification would open the app and land nowhere. The payload
/// below carries what the bell history already stores (`type` / `route` /
/// sender), which is exactly what the routing switch needs.
class NotificationRoute {
  const NotificationRoute({
    required this.type,
    this.route = '',
    this.senderPubkey = '',
  });

  /// Bell-history category: 'pm' | 'group' | 'channel' | 'geohash' | 'mention'
  /// | 'reaction' | 'call'.
  final String type;

  /// Tap target: peer pubkey, group id, or bare channel name.
  final String route;

  /// The sender, used as the fallback target for reactions/mentions.
  final String senderPubkey;
}

/// The conversation-opening surface [openNotificationRoute] needs. Kept to
/// three calls (rather than taking the controller directly) so the routing is
/// unit-testable without a live NostrController.
abstract class NotificationRouteTarget {
  void openChannel(String channel);
  void openPM(String pubkey);
  void openGroup(String groupId);
}

/// Payload prefix, so a tap payload can be told apart from the deep-link URLs
/// the same handler also receives.
const String _kPayloadScheme = 'nymnotif:';

/// Encodes a notification's origin into its tap payload. Fields are pipe-joined
/// because none of them can contain a pipe (they are hex pubkeys, group ids and
/// sanitized channel names).
String encodeNotificationPayload({
  required String type,
  String? route,
  String? senderPubkey,
}) =>
    '$_kPayloadScheme$type|${route ?? ''}|${senderPubkey ?? ''}';

/// Decodes a tap payload written by [encodeNotificationPayload]. Returns null
/// for anything else (e.g. a deep-link URL), so the caller can fall through to
/// its URL handler.
NotificationRoute? decodeNotificationPayload(String payload) {
  if (!payload.startsWith(_kPayloadScheme)) return null;
  final parts = payload.substring(_kPayloadScheme.length).split('|');
  if (parts.isEmpty || parts.first.isEmpty) return null;
  return NotificationRoute(
    type: parts[0],
    route: parts.length > 1 ? parts[1] : '',
    senderPubkey: parts.length > 2 ? parts[2] : '',
  );
}

/// True when [value] looks like a hex pubkey (the bell panel's `_isPubkey`).
bool isPubkeyRoute(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

/// The Android channel / alert weight a bell-history category posts under, so
/// a user can silence reactions without silencing private messages.
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

/// The key that groups a conversation's notifications together, so a second
/// message replaces the first instead of stacking, and opening the conversation
/// can dismiss them ([NotificationService.cancelConversation]).
String notificationConversationKey({
  required String historyType,
  required String route,
}) =>
    '$historyType:$route';

/// Opens the conversation a notification came from.
///
/// Shared by the notifications modal (tapping a bell row) and the OS
/// notification tap handler, so both land in the same place — mirrors the PWA's
/// `notifications.js:559-585` (pm → `openUserPM`, group → `openGroup`,
/// reaction/mention → the reactor's/author's PM, call → PM or group).
///
/// Returns whether it could route anywhere.
bool openNotificationRoute(
  NotificationRoute target,
  NotificationRouteTarget into,
) {
  final route = target.route;
  final sender = target.senderPubkey;
  switch (target.type) {
    case 'group':
      if (route.isEmpty) return false;
      into.openGroup(route);
      return true;
    case 'channel':
    case 'geohash':
      // A channel/geohash mention switches to that channel (the route is the
      // bare channel name; switchChannel auto-detects geohash).
      if (route.isEmpty) return false;
      into.openChannel(route);
      return true;
    case 'call':
      // Call routes carry a group id (group call) or a pubkey (1:1 call).
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
      // These route to the sender's PM (the avatar pubkey).
      final peer =
          sender.isNotEmpty ? sender : (isPubkeyRoute(route) ? route : '');
      if (peer.isEmpty) return false;
      into.openPM(peer);
      return true;
  }
}
