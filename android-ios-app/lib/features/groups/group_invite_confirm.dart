import 'package:flutter/widgets.dart';

import '../../models/group.dart';
import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';

String groupInviteDisplayName(GroupInviteToken token) {
  final collapsed = token.name
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return collapsed.length > 40 ? collapsed.substring(0, 40) : collapsed;
}

String groupInviteConfirmMessage(GroupInviteToken token) {
  final name = groupInviteDisplayName(token);
  if (name.isEmpty) {
    return tr(
        'Join this group? A join request will be sent to a group member.');
  }
  return tr('Join "{name}"? A join request will be sent to a group member.',
      {'name': name});
}

Future<bool> confirmGroupInviteJoin(
    BuildContext context, GroupInviteToken token) {
  return showAppConfirm(
    context,
    groupInviteConfirmMessage(token),
    title: tr('Join Group'),
    okLabel: tr('Join'),
  );
}
