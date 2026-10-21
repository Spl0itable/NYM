import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/bech32_codec.dart' show encodeNpub;
import '../../models/channel.dart' show kDefaultChannel;
import '../../models/group.dart';
import '../channels/channel_share.dart' show kNymchatShareHost;
import '../group_tools/group_tools.dart';
import '../groups/group_logic.dart' show kMaxGroupMembers;

const List<String> kShareHosts = ['web.nymchat.app'];
const int kShareMaxInputBytes = 4096;
const int kShareMaxTokenChars = 4000;
const int kShareMaxChannelChars = 64;
const int kShareMaxNprofileChars = 1000;
const int kShareCodeMaxBytes = 382;

class ShareAppLinks {
  const ShareAppLinks._();
  static const String downloadPage = 'https://nymchat.app/';
  static const String webApp = 'https://web.nymchat.app/';
  static const String iosTestFlight =
      'https://testflight.apple.com/join/k8FS8Mm3';
  static const String googlePlay =
      'https://play.google.com/store/apps/details?id=com.nym.bar';
  static const String zapstore = 'https://zapstore.dev/apps/com.nym.bar';
  static const List<String> exact = [
    downloadPage,
    webApp,
    'https://web.nymchat.app',
    iosTestFlight,
    googlePlay,
    zapstore,
  ];
}

enum ShareParseKind { profile, groupInvite, channel, appLink, invalid }

class ShareParseResult {
  const ShareParseResult._(
    this.kind, {
    this.reason,
    this.pubkey = '',
    this.groupId = '',
    this.approver = '',
    this.epoch = 0,
    this.name = '',
    this.hasSummary = false,
    this.token = '',
    this.channel = '',
    this.geohash = false,
    this.refPrefix = '',
    this.url = '',
  });

  const ShareParseResult.invalid(String reason)
      : this._(ShareParseKind.invalid, reason: reason);

  const ShareParseResult.profile(String pubkey)
      : this._(ShareParseKind.profile, pubkey: pubkey);

  const ShareParseResult.appLink(String url)
      : this._(ShareParseKind.appLink, url: url);

  const ShareParseResult.channel(String channel,
      {required bool geohash, String refPrefix = ''})
      : this._(ShareParseKind.channel,
            channel: channel, geohash: geohash, refPrefix: refPrefix);

  const ShareParseResult.groupInvite({
    required String token,
    required String groupId,
    required String approver,
    required int epoch,
    required String name,
    required bool hasSummary,
  }) : this._(ShareParseKind.groupInvite,
            token: token,
            groupId: groupId,
            approver: approver,
            epoch: epoch,
            name: name,
            hasSummary: hasSummary);

  final ShareParseKind kind;
  final String? reason;
  final String pubkey;
  final String groupId;
  final String approver;
  final int epoch;
  final String name;
  final bool hasSummary;
  final String token;
  final String channel;
  final bool geohash;
  final String refPrefix;
  final String url;

  bool get isValid => kind != ShareParseKind.invalid;

  Map<String, Object?> toJson() {
    switch (kind) {
      case ShareParseKind.invalid:
        return {'kind': 'invalid', 'reason': reason};
      case ShareParseKind.profile:
        return {'kind': 'profile', 'pubkey': pubkey};
      case ShareParseKind.appLink:
        return {'kind': 'appLink', 'url': url};
      case ShareParseKind.channel:
        return {
          'kind': 'channel',
          'channel': channel,
          'geohash': geohash,
          'refPrefix': refPrefix,
        };
      case ShareParseKind.groupInvite:
        return {
          'kind': 'groupInvite',
          'groupId': groupId,
          'approver': approver,
          'epoch': epoch,
          'name': name,
          'hasSummary': hasSummary,
        };
    }
  }
}

const String _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
final RegExp _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');
final RegExp _token = RegExp(r'^[A-Za-z0-9_-]{1,4000}$');
final RegExp _npubFragment = RegExp(r'^npub1[02-9ac-hj-np-z]{58}$');
final RegExp _ref = RegExp(r'^([egcEGC]):(.*)$', dotAll: true);
final RegExp _channelName = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);
final RegExp _hex2 = RegExp(r'^[0-9A-Fa-f]{2}$');
final RegExp _geohash = RegExp(r'^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$');

bool _isAsciiSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x0B;

bool _isForbidden(int c) =>
    c <= 0x1F ||
    (c >= 0x7F && c <= 0x9F) ||
    (c >= 0x200B && c <= 0x200F) ||
    (c >= 0x2028 && c <= 0x202E) ||
    (c >= 0x2060 && c <= 0x2069) ||
    c == 0xFEFF;

int _polymod(List<int> values) {
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((b >> i) & 1 == 1) chk ^= gen[i];
    }
  }
  return chk;
}

Uint8List? _bech32Decode(String input, String hrp, int maxLen) {
  if (input.length > maxLen) return null;
  final lower = input.toLowerCase();
  if (input != lower && input != input.toUpperCase()) return null;
  final pos = lower.lastIndexOf('1');
  if (pos < 1 || pos + 7 > lower.length) return null;
  if (lower.substring(0, pos) != hrp) return null;
  final data = <int>[];
  for (final ch in lower.substring(pos + 1).split('')) {
    final d = _bech32Charset.indexOf(ch);
    if (d < 0) return null;
    data.add(d);
  }
  final hrpx = [
    for (final c in hrp.codeUnits) c >> 5,
    0,
    for (final c in hrp.codeUnits) c & 31,
  ];
  if (_polymod([...hrpx, ...data]) != 1) return null;
  final words = data.sublist(0, data.length - 6);
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  for (final w in words) {
    acc = (acc << 5) | w;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xff);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits >= 5 || acc != 0) return null;
  return Uint8List.fromList(out);
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String? strictNpubPubkey(String s) {
  final b = _bech32Decode(s, 'npub', 63);
  if (b == null || b.length != 32) return null;
  return _hex(b);
}

String? strictNprofilePubkey(String s) {
  final b = _bech32Decode(s, 'nprofile', kShareMaxNprofileChars);
  if (b == null) return null;
  String? pubkey;
  var i = 0;
  while (i < b.length) {
    if (i + 2 > b.length) return null;
    final type = b[i];
    final len = b[i + 1];
    if (i + 2 + len > b.length) return null;
    if (type == 0 && pubkey == null) {
      if (len != 32) return null;
      pubkey = _hex(b.sublist(i + 2, i + 2 + len));
    }
    i += 2 + len;
  }
  return pubkey;
}

String? _strictPercentDecode(String s) {
  final bytes = <int>[];
  final cps = s.runes.toList();
  var i = 0;
  while (i < cps.length) {
    final cp = cps[i];
    if (cp == 0x25) {
      if (i + 2 >= cps.length) return null;
      final h = String.fromCharCodes(cps.sublist(i + 1, i + 3));
      if (!_hex2.hasMatch(h)) return null;
      bytes.add(int.parse(h, radix: 16));
      i += 3;
    } else {
      bytes.addAll(utf8.encode(String.fromCharCode(cp)));
      i++;
    }
  }
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } catch (_) {
    return null;
  }
}

ShareParseResult _channel(String name, String refPrefix) {
  var n = name;
  if (n.contains('%')) {
    final d = _strictPercentDecode(n);
    if (d == null) return const ShareParseResult.invalid('bad_fragment');
    n = d;
  }
  n = n.toLowerCase();
  if (!_channelName.hasMatch(n) || n.runes.length > kShareMaxChannelChars) {
    return const ShareParseResult.invalid('bad_fragment');
  }
  return ShareParseResult.channel(n,
      geohash: _geohash.hasMatch(n), refPrefix: refPrefix);
}

ShareParseResult _fragment(String f) {
  if (f.startsWith('gjoin=')) {
    final token = f.substring(6);
    if (!_token.hasMatch(token)) {
      return const ShareParseResult.invalid('bad_invite');
    }
    final p = GroupTools.parseInviteInput(token);
    if (p == null) return const ShareParseResult.invalid('bad_invite');
    return ShareParseResult.groupInvite(
      token: token,
      groupId: p.g,
      approver: p.a,
      epoch: p.e,
      name: p.n,
      hasSummary: p.s != null,
    );
  }
  if (f.startsWith('p=')) {
    final npub = f.substring(2);
    final pk = _npubFragment.hasMatch(npub) ? strictNpubPubkey(npub) : null;
    return pk == null
        ? const ShareParseResult.invalid('bad_profile')
        : ShareParseResult.profile(pk);
  }
  if (f.startsWith('call=')) {
    return const ShareParseResult.invalid('unsupported_link');
  }
  final ref = _ref.firstMatch(f);
  if (ref != null) return _channel(ref.group(2)!, ref.group(1)!.toLowerCase());
  return _channel(f, '');
}

ShareParseResult parseShareInput(Object? raw,
    {List<String> extraHosts = const []}) {
  if (raw is! String) return const ShareParseResult.invalid('empty');
  var s = raw.startsWith('﻿') ? raw.substring(1) : raw;
  var a = 0;
  var b = s.length;
  while (a < b && _isAsciiSpace(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && _isAsciiSpace(s.codeUnitAt(b - 1))) {
    b--;
  }
  s = s.substring(a, b);
  if (s.isEmpty) return const ShareParseResult.invalid('empty');
  if (utf8.encode(s).length > kShareMaxInputBytes) {
    return const ShareParseResult.invalid('too_long');
  }
  if (s.runes.any(_isForbidden)) {
    return const ShareParseResult.invalid('control_chars');
  }
  if (ShareAppLinks.exact.contains(s)) return ShareParseResult.appLink(s);

  var rest = s;
  final hadNostr = rest.toLowerCase().startsWith('nostr:');
  if (hadNostr) rest = rest.substring(6);
  final lower = rest.toLowerCase();
  if (lower.startsWith('nsec1') || lower.startsWith('ncryptsec1')) {
    return const ShareParseResult.invalid('secret');
  }
  if (lower.startsWith('npub1')) {
    final pk = strictNpubPubkey(rest);
    return pk == null
        ? const ShareParseResult.invalid('bad_profile')
        : ShareParseResult.profile(pk);
  }
  if (lower.startsWith('nprofile1')) {
    final pk = strictNprofilePubkey(rest);
    return pk == null
        ? const ShareParseResult.invalid('bad_profile')
        : ShareParseResult.profile(pk);
  }
  if (hadNostr) return const ShareParseResult.invalid('not_nymchat');

  final hosts = {...kShareHosts, for (final h in extraHosts) h.toLowerCase()};
  final scheme = _scheme.firstMatch(s);
  if (scheme == null) return const ShareParseResult.invalid('not_nymchat');
  final schemeName = scheme.group(0)!.toLowerCase();
  if (schemeName != 'https:') {
    if (schemeName == 'http:' && s.length > 7 && s.substring(5, 7) == '//') {
      final auth = _authority(s.substring(7)).toLowerCase();
      if (hosts.contains(auth)) {
        return const ShareParseResult.invalid('not_https');
      }
    }
    return const ShareParseResult.invalid('not_nymchat');
  }
  if (!s.toLowerCase().startsWith('https://')) {
    return const ShareParseResult.invalid('not_nymchat');
  }
  final afterScheme = s.substring(8);
  final authority = _authority(afterScheme);
  if (!hosts.contains(authority.toLowerCase())) {
    return const ShareParseResult.invalid('other_host');
  }
  final tail = afterScheme.substring(authority.length);
  final hash = tail.indexOf('#');
  final beforeHash = hash < 0 ? tail : tail.substring(0, hash);
  final q = beforeHash.indexOf('?');
  final path = q < 0 ? beforeHash : beforeHash.substring(0, q);
  if (q >= 0 || !(path.isEmpty || path == '/' || path == '/index.html')) {
    return const ShareParseResult.invalid('bad_path');
  }
  if (hash < 0 || hash == tail.length - 1) {
    return const ShareParseResult.invalid('bad_fragment');
  }
  return _fragment(tail.substring(hash + 1));
}

String _authority(String s) {
  var end = s.length;
  for (final stop in const ['/', '?', '#']) {
    final i = s.indexOf(stop);
    if (i >= 0 && i < end) end = i;
  }
  return s.substring(0, end);
}

String profileShareLink(String pubkeyHex) =>
    '$kNymchatShareHost/#p=${encodeNpub(pubkeyHex.toLowerCase())}';

String channelShareLink(String channel) {
  final ch = channel.isEmpty ? kDefaultChannel : channel;
  return '$kNymchatShareHost/#${Uri.encodeComponent(ch)}';
}

class GroupShareLinks {
  const GroupShareLinks(this.link, this.codeLink);
  final String link;
  final String codeLink;
}

int _bytes(String s) => utf8.encode(s).length;

String _inviteUrl(InvitePayload p) =>
    '$kNymchatShareHost/#gjoin=${GroupTools.encodeInvite(p)}';

GroupShareLinks groupShareLinks(InvitePayload payload) {
  final full = _inviteUrl(payload);
  if (_bytes(full) <= kShareCodeMaxBytes) return GroupShareLinks(full, full);
  final base = payload.n.isEmpty ? 'Group' : payload.n;
  final cps = base.runes.take(80).toList();
  while (true) {
    final code = _inviteUrl(InvitePayload(
      g: payload.g,
      n: String.fromCharCodes(cps),
      a: payload.a,
      e: payload.e,
    ));
    if (_bytes(code) <= kShareCodeMaxBytes || cps.length <= 1) {
      return GroupShareLinks(full, code);
    }
    cps.removeLast();
  }
}

InvitePayload? groupInvitePayload(
    Group group, String self, InviteSignedSummary? summary) {
  if (!group.inviteEnabled) return null;
  if (!group.canAddMembers(self)) return null;
  return InvitePayload(
    g: group.id,
    n: group.name.isEmpty ? 'Group' : group.name,
    a: self,
    e: group.inviteEpoch,
    s: summary,
  );
}

String? groupInviteLink(
    Group group, String self, InviteSignedSummary? summary) {
  final p = groupInvitePayload(group, self, summary);
  return p == null ? null : _inviteUrl(p);
}

class GroupCodeOffer {
  const GroupCodeOffer.offered()
      : offered = true,
        reason = null;
  const GroupCodeOffer.refused(String this.reason) : offered = false;
  final bool offered;
  final String? reason;
}

GroupCodeOffer groupCodeOffer({
  required bool inviteEnabled,
  required bool canAddMembers,
  required int memberCount,
}) {
  if (!inviteEnabled) return const GroupCodeOffer.refused('disabled');
  if (!canAddMembers) return const GroupCodeOffer.refused('not_allowed');
  if (memberCount >= kMaxGroupMembers) {
    return const GroupCodeOffer.refused('full');
  }
  return const GroupCodeOffer.offered();
}

GroupCodeOffer groupCodeOfferFor(Group group, String self) => groupCodeOffer(
      inviteEnabled: group.inviteEnabled,
      canAddMembers: group.canAddMembers(self),
      memberCount: group.members.length,
    );
