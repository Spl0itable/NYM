import '../../models/group.dart';
import '../../state/nostr_controller.dart';
import 'deep_links.dart';

/// Adapts the real [NostrController] to the pure [DeepLinkTarget] surface used
/// by [DeepLinkService] / [dispatchNymLink]. Kept in its own file so the pure
/// link parser (deep_links.dart) never has to import the controller — that lets
/// the deep-link unit tests compile without pulling in networking/identity.
class NostrControllerDeepLinkTarget implements DeepLinkTarget {
  NostrControllerDeepLinkTarget(this._controller);
  final NostrController _controller;

  @override
  void switchChannel(String channel, {String geohash = ''}) =>
      _controller.switchChannel(channel, geohash: geohash);

  @override
  void startPM(String peerPubkey, {String? nym}) =>
      _controller.startPM(peerPubkey, nym: nym);

  @override
  Future<void> joinGroupViaInvite(GroupInviteToken token) =>
      _controller.joinGroupViaInvite(token);
}
