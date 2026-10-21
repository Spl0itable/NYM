import '../../models/group.dart';
import '../group_tools/group_tools.dart';
import '../i18n/i18n.dart';
import 'share_links.dart';

enum ShareKind { profile, group, channel }

class ShareTarget {
  const ShareTarget({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.link,
    required this.codeLink,
    this.refusal,
    this.refusalCode,
    this.isOwnProfile = false,
    this.pubkey = '',
    this.groupId = '',
    this.channel = '',
  });

  factory ShareTarget.profile({
    required String pubkey,
    required String displayName,
    bool isOwnProfile = false,
  }) {
    final link = profileShareLink(pubkey);
    return ShareTarget(
      kind: ShareKind.profile,
      title: displayName,
      subtitle: tr('Anyone who scans this code can open this profile.'),
      link: link,
      codeLink: link,
      isOwnProfile: isOwnProfile,
      pubkey: pubkey.toLowerCase(),
    );
  }

  factory ShareTarget.group({
    required Group group,
    required String self,
    InviteSignedSummary? summary,
  }) {
    final title = group.name.isEmpty ? tr('Group') : group.name;
    final offer = groupCodeOfferFor(group, self);
    final payload = groupInvitePayload(group, self, summary);
    if (!offer.offered || payload == null) {
      final code = offer.reason ?? 'not_allowed';
      return ShareTarget(
        kind: ShareKind.group,
        title: title,
        subtitle: '',
        link: '',
        codeLink: '',
        refusal: groupRefusalText(code),
        refusalCode: code,
        groupId: group.id,
      );
    }
    final links = groupShareLinks(payload);
    return ShareTarget(
      kind: ShareKind.group,
      title: title,
      subtitle: tr(
          'Anyone who sees or scans this code can ask to join and will see the group’s name.'),
      link: links.link,
      codeLink: links.codeLink,
      groupId: group.id,
    );
  }

  factory ShareTarget.channel(String channel) {
    final link = channelShareLink(channel);
    final parsed = parseShareInput(link);
    final name = parsed.channel.isEmpty ? channel : parsed.channel;
    return ShareTarget(
      kind: ShareKind.channel,
      title: '#$name',
      subtitle: parsed.geohash ? tr('Location channel') : '',
      link: link,
      codeLink: link,
      channel: name,
    );
  }

  final ShareKind kind;
  final String title;
  final String subtitle;
  final String link;
  final String codeLink;
  final String? refusal;
  final String? refusalCode;
  final bool isOwnProfile;
  final String pubkey;
  final String groupId;
  final String channel;

  bool get hasCode => refusal == null && codeLink.isNotEmpty;

  String get header {
    switch (kind) {
      case ShareKind.profile:
        return tr('Share profile');
      case ShareKind.group:
        return tr('Share group');
      case ShareKind.channel:
        return tr('Share channel');
    }
  }
}

String groupRefusalText(String code) {
  switch (code) {
    case 'disabled':
      return tr('Invite links are disabled for this group.');
    case 'full':
      return tr('This group is full (100 members).');
    default:
      return tr('Only members who can add people can share this group.');
  }
}
