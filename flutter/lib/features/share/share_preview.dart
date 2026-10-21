import 'package:flutter/widgets.dart';

import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import 'share_links.dart';

String shortNpub(String npub) => npub.length <= 17
    ? npub
    : '${npub.substring(0, 9)}...${npub.substring(npub.length - 4)}';

String? _fromTitle(ShareParseKind kind, String? fromLabel) {
  if (fromLabel == null || fromLabel.isEmpty) return null;
  switch (kind) {
    case ShareParseKind.profile:
      return tr('{nick} wants to share a profile', {'nick': fromLabel});
    case ShareParseKind.groupInvite:
      return tr('{nick} wants to share a group', {'nick': fromLabel});
    case ShareParseKind.channel:
      return tr('{nick} wants to share a channel', {'nick': fromLabel});
    default:
      return null;
  }
}

Future<bool> showProfileSharePreview(
  BuildContext context, {
  required String label,
  String? fromLabel,
}) =>
    showAppConfirm(
      context,
      label,
      title: _fromTitle(ShareParseKind.profile, fromLabel) ?? tr('Open profile'),
      okLabel: tr('Open profile'),
      cancelLabel: tr('Cancel'),
    );

Future<bool> showChannelSharePreview(
  BuildContext context,
  ShareParseResult r, {
  String? fromLabel,
}) =>
    showAppConfirm(
      context,
      r.geohash
          ? '#${r.channel}\n${tr('Location channel')}'
          : '#${r.channel}',
      title: _fromTitle(ShareParseKind.channel, fromLabel) ?? tr('Open channel'),
      okLabel: tr('Open channel'),
      cancelLabel: tr('Cancel'),
    );

Future<void> showAppLinkNotice(BuildContext context) => showAppAlert(
      context,
      tr('This code links to Nymchat downloads.'),
      title: tr('Get Nymchat'),
      okLabel: tr('Close'),
    );

Future<void> showNotNymchatCode(BuildContext context) => showAppAlert(
      context,
      tr('Not a Nymchat code'),
      title: tr('Scan a code'),
      okLabel: tr('Close'),
    );
