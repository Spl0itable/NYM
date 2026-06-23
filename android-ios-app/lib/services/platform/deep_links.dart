import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../../models/channel.dart';
import '../../models/group.dart';

/// Deep-link routing for the native app, mirroring the PWA's URL hash routing
/// (`parseUrlChannel` in app.js + `handleChannelLink` in channels.js).
///
/// The PWA encodes everything in the URL *fragment* (`#…`):
///   * `#gjoin=<base64url token>` — a group invite (app.js `parseUrlChannel`).
///   * `#<e|g|c>:<id>`            — a channel-ref chip (message-format.js /
///                                  `handleChannelLink(data-channel-ref)`).
///   * `#<channel-or-geohash>`    — a plain channel / geohash join.
///
/// There is no `#pm:` form in the PWA — `parseUrlChannel` never inspects a `pm:`
/// fragment and no formatter emits one. We therefore do NOT invent one.
// TODO(verify): the PWA has no PM deep-link form (`#pm:`); confirmed absent in
// app.js `parseUrlChannel` and js/modules/message-format.js. Not implemented.

/// The hosts the PWA serves deep links from. `shareChannel()` builds links on
/// the runtime origin (`app.nymchat.app` in production); the message formatter
/// recognizes `app.nym.bar/#<e|g|c>:<id>` chips. We accept both.
// TODO(verify): the canonical production host(s). The Flutter share path
// (channel_share.dart) pins `app.nymchat.app`; the formatter regex pins
// `app.nym.bar`. Both are honoured here.
const Set<String> kNymLinkHosts = {
  'app.nymchat.app',
  'app.nym.bar',
};

/// The kind of deep link a [parseNymLink] call resolved to.
enum NymLinkKind {
  /// A plain channel join (named channel). [NymLink.channel] holds the
  /// sanitized, lowercased channel name.
  channel,

  /// A geohash channel join. [NymLink.channel] holds the geohash.
  geohash,

  /// A `#<e|g|c>:<id>` channel-ref chip. [NymLink.refPrefix] is `e`, `g` or `c`;
  /// [NymLink.channel] is the resolved channel key (the PWA strips only the
  /// legacy `g:` prefix before joining — see `handleChannelLink`).
  channelRef,

  /// A `#gjoin=<token>` group invite. [NymLink.inviteToken] holds the raw
  /// base64url token; [NymLink.invite] holds the parsed payload.
  groupInvite,
}

/// A parsed Nymchat deep link. Pure data — no side effects.
@immutable
class NymLink {
  const NymLink._({
    required this.kind,
    this.channel = '',
    this.refPrefix = '',
    this.inviteToken = '',
    this.invite,
  });

  /// Plain channel join (`#<name>`), already sanitized + lowercased.
  factory NymLink.channel(String channel) =>
      NymLink._(kind: NymLinkKind.channel, channel: channel);

  /// Geohash channel join (`#<geohash>`).
  factory NymLink.geohash(String geohash) =>
      NymLink._(kind: NymLinkKind.geohash, channel: geohash);

  /// Channel-ref chip (`#<e|g|c>:<id>`).
  factory NymLink.channelRef(String prefix, String channel) => NymLink._(
        kind: NymLinkKind.channelRef,
        refPrefix: prefix,
        channel: channel,
      );

  /// Group invite (`#gjoin=<token>`).
  factory NymLink.groupInvite(String token, GroupInviteToken? invite) =>
      NymLink._(
        kind: NymLinkKind.groupInvite,
        inviteToken: token,
        invite: invite,
      );

  final NymLinkKind kind;

  /// Channel name / geohash / resolved ref key (depending on [kind]).
  final String channel;

  /// `e`, `g` or `c` for [NymLinkKind.channelRef]; empty otherwise.
  final String refPrefix;

  /// Raw base64url token for [NymLinkKind.groupInvite]; empty otherwise.
  final String inviteToken;

  /// Parsed invite payload (may be null if the token failed validation).
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

/// Sanitizes a channel name the way the PWA's `sanitizeChannelName` does:
/// lowercase, then **reject** (return '') if it contains anything other than
/// Unicode letters or digits. Note: this rejects rather than strips — matching
/// channels.js `sanitizeChannelName`.
String sanitizeChannelName(String name) {
  if (name.isEmpty) return '';
  final lower = name.toLowerCase();
  if (!RegExp(r'^[\p{L}\p{N}]+$', unicode: true).hasMatch(lower)) return '';
  return lower;
}

/// Parses a `#gjoin=…`-style token (or a bare token) into a [GroupInviteToken],
/// mirroring `parseGroupInvite` (message-format.js) / `parseGroupInviteInput`
/// (groups.js): base64url-decode, require `v == 1`, a 64-hex / UUID group id,
/// and a 64-hex approver pubkey. Returns null on any failure.
GroupInviteToken? parseGroupInvite(String tokenOrInput) {
  if (tokenOrInput.isEmpty) return null;
  var token = tokenOrInput.trim();
  // Accept a full `…#gjoin=<token>` (or `&`/`?` separator) or a bare token.
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
    if (!RegExp(
            r'^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$',
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

/// Parses a Nymchat deep-link [url] into a typed [NymLink], or null if the URL
/// is not a recognized Nymchat link.
///
/// Mirrors app.js `parseUrlChannel` ordering: the `#gjoin=` invite is matched
/// first (its token is case-sensitive and must never be lowercased), then the
/// `#<e|g|c>:<id>` channel-ref chip, then a plain `#<channel>` / `#<geohash>`.
NymLink? parseNymLink(String url) {
  Uri uri;
  try {
    uri = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }

  // Only http(s) links to a known Nymchat host carry deep links. (A custom
  // scheme could be added later; the PWA only uses https.)
  final host = uri.host.toLowerCase();
  if (!kNymLinkHosts.contains(host)) return null;

  // The PWA routes entirely on the URL fragment.
  final fragment = uri.fragment;
  if (fragment.isEmpty) return null;

  // 1) Group invite — case-sensitive base64url token, matched first.
  final invite = RegExp(r'^gjoin=([A-Za-z0-9_-]+)').firstMatch(fragment);
  if (invite != null) {
    final token = invite.group(1)!;
    return NymLink.groupInvite(token, parseGroupInvite(token));
  }

  // 2) Channel-ref chip `#<e|g|c>:<id>` (message-format.js formatter +
  //    handleChannelLink). `handleChannelLink` strips only the legacy `g:`
  //    prefix before sanitizing; `e:`/`c:` ids fall through as channel names.
  final ref = RegExp(r'^([egc]):(.+)$', caseSensitive: false).firstMatch(fragment);
  if (ref != null) {
    final prefix = ref.group(1)!.toLowerCase();
    // The fragment regex already split the `<prefix>:` off; the id after it is
    // the channel input. `handleChannelLink` only strips the legacy `g:`, which
    // is exactly what we did here, so no further stripping is needed.
    final channel = sanitizeChannelName(ref.group(2)!);
    if (channel.isEmpty) return null;
    return NymLink.channelRef(prefix, channel);
  }

  // 3) Plain channel / geohash (`parseUrlChannel`: lowercase the fragment, then
  //    `routeToUrlChannel`/`handleChannelLink` strip a legacy `g:` prefix and
  //    sanitize).
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

/// Minimal surface of the controller a [DeepLinkService] dispatches into. The
/// real `NostrController` already satisfies this; tests pass a fake.
abstract class DeepLinkTarget {
  void switchChannel(String channel, {String geohash});
  void startPM(String peerPubkey, {String? nym});
  Future<void> joinGroupViaInvite(GroupInviteToken token);
}

/// Routes a parsed [NymLink] to the right controller call. Pure decision logic
/// (no `app_links`), so it is unit-testable with a fake [DeepLinkTarget].
///
/// Returns true if the link was dispatched, false if it could not be (e.g. an
/// invite whose token failed to parse).
bool dispatchNymLink(NymLink link, DeepLinkTarget target) {
  switch (link.kind) {
    case NymLinkKind.geohash:
      target.switchChannel(link.channel, geohash: link.channel);
      return true;
    case NymLinkKind.channel:
    case NymLinkKind.channelRef:
      // Named channel join. A geohash-shaped ref still registers its geohash
      // (channelWire decides the wire kind); mirror handleChannelLink.
      final geohash = isValidGeohash(link.channel) ? link.channel : '';
      target.switchChannel(link.channel, geohash: geohash);
      return true;
    case NymLinkKind.groupInvite:
      final invite = link.invite;
      if (invite == null) return false;
      target.joinGroupViaInvite(invite);
      return true;
  }
}

/// Listens for incoming deep links (initial launch + live stream) via
/// `app_links` and dispatches them into the controller. Wired from `app.dart`'s
/// root so it runs without touching `main.dart`.
class DeepLinkService {
  DeepLinkService(this._target, {AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final DeepLinkTarget _target;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;
  bool _started = false;

  /// Begins listening. Idempotent. No-ops on web / unsupported platforms or if
  /// the plugin throws (e.g. in a test environment without a platform channel).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (kIsWeb) return;
    try {
      // Cold-start link: the URL that launched the app (if any).
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

  /// Routes a raw URL string (used by the notification-tap path, which carries a
  /// deep-link payload). Returns true if handled.
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
