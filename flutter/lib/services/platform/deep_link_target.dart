import '../../models/group.dart';
import '../../state/nostr_controller.dart';
import 'deep_links.dart';

/// Adapts [NostrController] to [DeepLinkTarget]; separate so deep_links.dart never imports the controller.
class NostrControllerDeepLinkTarget implements DeepLinkTarget {
  NostrControllerDeepLinkTarget(this._controller,
      {required this._confirmInvite});
  final NostrController _controller;
  final Future<bool> Function(GroupInviteToken token) _confirmInvite;

  @override
  void switchChannel(String channel, {String geohash = ''}) =>
      _controller.switchChannel(channel, geohash: geohash);

  @override
  void startPM(String peerPubkey, {String? nym}) =>
      _controller.startPM(peerPubkey, nym: nym);

  @override
  Future<bool> confirmGroupInvite(GroupInviteToken token) =>
      _confirmInvite(token);

  @override
  Future<void> joinGroupViaInvite(GroupInviteToken token) =>
      _controller.joinGroupViaInvite(token);
}
