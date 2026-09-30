import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../../models/channel.dart';
import '../../models/group.dart';

/// Deep-link routing mirroring the PWA's URL-fragment routing (`#gjoin=`, `#<e|g|c>:<id>`, `#<channel>`).
// TODO(verify): the PWA has no PM deep-link form (`#pm:`), so none is implemented.

/// Accepted deep-link hosts; keep in sync with the Android intent filter and iOS associated domains.
const Set<String> kNymLinkHosts = {
  'web.nymchat.app',
  'nymchat.app',
  'app.nymchat.app',
  'app.nym.bar',
};

enum NymLinkKind {
  /// Named channel; [NymLink.channel] is sanitized and lowercased.
  channel,

  geohash,

  /// `#<e|g|c>:<id>` chip; only the legacy `g:` prefix is stripped, as in the PWA.
  channelRef,

  /// `#gjoin=<token>` invite with the raw token and its parsed payload.
  groupInvite,
}

@immutable
class NymLink {
  const NymLink._({
    required this.kind,
    this.channel = '',
    this.refPrefix = '',
    this.inviteToken = '',
    this.invite,
  });

  factory NymLink.channel(String channel) =>
      NymLink._(kind: NymLinkKind.channel, channel: channel);

  factory NymLink.geohash(String geohash) =>
      NymLink._(kind: NymLinkKind.geohash, channel: geohash);

  factory NymLink.channelRef(String prefix, String channel) => NymLink._(
        kind: NymLinkKind.channelRef,
        refPrefix: prefix,
        channel: channel,
      );

  factory NymLink.groupInvite(String token, GroupInviteToken? invite) =>
      NymLink._(
        kind: NymLinkKind.groupInvite,
        inviteToken: token,
        invite: invite,
      );

  final NymLinkKind kind;

  /// Channel name, geohash or resolved ref key, depending on [kind].
  final String channel;

  final String refPrefix;

  final String inviteToken;

  /// Parsed invite payload, or null if the token failed validation.
  final GroupInviteToken? invite;

  @override
  String toString() =>
      'NymLink(${kind.name}, channel: "$channel", refPrefix: "$refPrefix", '
      'inviteToken: "${inviteToken.isEmpty ? '' : '…'}")';

  @override
  bool operator ==(Object other) =>
      other is NymLink &&
      other.kind == kind &&
      other.channel == channel &&
      other.refPrefix == refPrefix &&
      other.inviteToken == inviteToken;

  @override
  int get hashCode => Object.hash(kind, channel, refPrefix, inviteToken);
}

/// Lowercases, then rejects (returns '') anything with non-letter/digit characters, as the PWA does.
String sanitizeChannelName(String name) {
  if (name.isEmpty) return '';
  final lower = name.toLowerCase();
  if (!RegExp(r'^[\p{L}\p{N}]+$', unicode: true).hasMatch(lower)) return '';
  return lower;
}

/// Parses an invite token (v1, 64-hex/UUID group, 64-hex approver) as the PWA does; null on failure.
GroupInviteToken? parseGroupInvite(String tokenOrInput) {
  if (tokenOrInput.isEmpty) return null;
  var token = tokenOrInput.trim();
  // Accept a full `…#gjoin=<token>` URL or a bare token.
  final m = RegExp(r'[#&?]gjoin=([A-Za-z0-9_-]+)').firstMatch(token);
  if (m != null) {
    token = m.group(1)!;
  } else if (token.startsWith('gjoin=')) {
    token = token.substring(6);
  }
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) return null;
  try {
    var b64 = token.replaceAll('-', '+').replaceAll('_', '/');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    final obj = jsonDecode(utf8.decode(base64.decode(b64)));
    if (obj is! Map) return null;
    if (obj['v'] != 1) return null;
    final g = (obj['g'] ?? '').toString();
    if (!RegExp(r'^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$',
            caseSensitive: false)
        .hasMatch(g)) {
      return null;
    }
    final a = (obj['a'] ?? '').toString();
    if (!RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(a)) {
      return null;
    }
    return GroupInviteToken(
      v: 1,
      groupId: g,
      approver: a,
      epoch: (obj['e'] is num)
          ? (obj['e'] as num).toInt()
          : int.tryParse('${obj['e']}') ?? 0,
      name: (obj['n'] ?? '').toString(),
    );
  } catch (_) {
    return null;
  }
}

/// Parses in the PWA's order: invite first (case-sensitive token), then channel-ref chip, then plain channel.
NymLink? parseNymLink(String url) {
  Uri uri;
  try {
    uri = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }

  // Only http(s) links to a known Nymchat host carry deep links.
  final host = uri.host.toLowerCase();
  if (!kNymLinkHosts.contains(host)) return null;

  final fragment = uri.fragment;
  if (fragment.isEmpty) return null;

  // 1) Group invite: case-sensitive token, matched first.
  final invite = RegExp(r'^gjoin=([A-Za-z0-9_-]+)').firstMatch(fragment);
  if (invite != null) {
    final token = invite.group(1)!;
    return NymLink.groupInvite(token, parseGroupInvite(token));
  }

  // 2) Channel-ref chip `#<e|g|c>:<id>`.
  final ref =
      RegExp(r'^([egc]):(.+)$', caseSensitive: false).firstMatch(fragment);
  if (ref != null) {
    final prefix = ref.group(1)!.toLowerCase();
    final channel = sanitizeChannelName(ref.group(2)!);
    if (channel.isEmpty) return null;
    return NymLink.channelRef(prefix, channel);
  }

  // 3) Plain channel or geohash.
  var channelInput = fragment.toLowerCase();
  if (channelInput.startsWith('g:')) {
    channelInput = channelInput.substring(2);
  }
  final channel = sanitizeChannelName(channelInput);
  if (channel.isEmpty) return null;
  return isValidGeohash(channel)
      ? NymLink.geohash(channel)
      : NymLink.channel(channel);
}

/// Controller surface [DeepLinkService] dispatches into; tests pass a fake.
abstract class DeepLinkTarget {
  void switchChannel(String channel, {String geohash});
  void startPM(String peerPubkey, {String? nym});
  Future<bool> confirmGroupInvite(GroupInviteToken token);
  Future<void> joinGroupViaInvite(GroupInviteToken token);
}

Future<bool> confirmAndJoinGroupInvite(
    DeepLinkTarget target, GroupInviteToken invite) async {
  if (!await target.confirmGroupInvite(invite)) return false;
  await target.joinGroupViaInvite(invite);
  return true;
}

/// Routes a parsed [NymLink]; false when it could not be dispatched.
bool dispatchNymLink(NymLink link, DeepLinkTarget target) {
  switch (link.kind) {
    case NymLinkKind.geohash:
      target.switchChannel(link.channel, geohash: link.channel);
      return true;
    case NymLinkKind.channel:
    case NymLinkKind.channelRef:
      // A geohash-shaped ref still registers its geohash, as handleChannelLink does.
      final geohash = isValidGeohash(link.channel) ? link.channel : '';
      target.switchChannel(link.channel, geohash: geohash);
      return true;
    case NymLinkKind.groupInvite:
      final invite = link.invite;
      if (invite == null) return false;
      unawaited(confirmAndJoinGroupInvite(target, invite));
      return true;
  }
}

/// Listens for initial and live deep links via `app_links` and dispatches them.
class DeepLinkService {
  DeepLinkService(this._target, {AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final DeepLinkTarget _target;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;
  bool _started = false;

  /// Idempotent; no-ops where the plugin is unavailable.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (kIsWeb) return;
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleUri(initial);
    } catch (e) {
      if (kDebugMode) debugPrint('[DeepLinkService] initial link failed: $e');
    }
    try {
      _sub = _appLinks.uriLinkStream.listen(
        _handleUri,
        onError: (Object e) {
          if (kDebugMode) debugPrint('[DeepLinkService] stream error: $e');
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[DeepLinkService] stream listen failed: $e');
    }
  }

  /// Routes a raw URL string, e.g. from a notification tap; true if handled.
  bool handleUrl(String url) {
    final link = parseNymLink(url);
    if (link == null) return false;
    return dispatchNymLink(link, _target);
  }

  void _handleUri(Uri uri) {
    final link = parseNymLink(uri.toString());
    if (link == null) {
      if (kDebugMode) debugPrint('[DeepLinkService] ignored: $uri');
      return;
    }
    dispatchNymLink(link, _target);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }
}
