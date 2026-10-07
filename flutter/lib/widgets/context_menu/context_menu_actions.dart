import 'package:flutter/painting.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../nym_icons.dart';

/// Context-menu actions, in the PWA's `#contextMenu` markup order.
enum CtxAction {
  react,
  mention,
  privateMessage,
  slap,
  hug,
  addToGroup,
  zap,
  giftCredits,
  quote,
  copyMessage,
  translate,
  friend,
  report,
  edit, // Own messages only.
  delete, // Own messages, or moderators.
  // Group moderation, shown only when applicable.
  makeMod,
  revokeMod,
  makeAdmin,
  revokeAdmin,
  transferOwner,
  kick,
  ban,
  block,
  editProfile, // Own profile only.
}

/// Target of a context-menu invocation plus derived role flags.
class CtxTarget {
  const CtxTarget({
    required this.pubkey,
    required this.nym,
    required this.isSelf,
    this.content,
    this.messageId,
    this.profileOnly = false,
    this.isFriend = false,
    this.isBlocked = false,
    this.isBot = false,
    this.inGroup = false,
    this.iAmOwner = false,
    this.iAmAdmin = false,
    this.iAmMod = false,
    this.targetIsMember = false,
    this.targetIsOwner = false,
    this.targetIsAdmin = false,
    this.targetIsMod = false,
    this.backToGroupId,
  });

  final String pubkey;
  final String nym; // Base nym, no suffix.
  final bool isSelf;

  final String? content;

  final String? messageId;

  /// Profile-only mode (nyms sidebar).
  final bool profileOnly;

  final bool isFriend;
  final bool isBlocked;
  final bool isBot;

  final bool inGroup;
  final bool iAmOwner;
  final bool iAmAdmin;
  final bool iAmMod;
  final bool targetIsMember;
  final bool targetIsOwner;
  final bool targetIsAdmin;
  final bool targetIsMod;

  /// Group id when opened from a group's member list, enabling a back chevron to that group's menu.
  final String? backToGroupId;

  bool get iCanAdminister => iAmOwner || iAmAdmin;
  bool get iCanModerate => iCanAdminister || iAmMod;

  int get _myRank => iAmOwner ? 0 : (iAmAdmin ? 1 : (iAmMod ? 2 : 3));
  int get _targetRank =>
      targetIsOwner ? 0 : (targetIsAdmin ? 1 : (targetIsMod ? 2 : 3));
  bool get iOutrankTarget => iAmOwner || _myRank < _targetRank;
}

/// Visible, ordered action list for [t], following the PWA `showContextMenu` visibility rules.
List<CtxAction> buildContextMenuActions(CtxTarget t) {
  final hasContent = t.content != null && t.content!.isNotEmpty;
  final hasMessage = t.messageId != null && t.messageId!.isNotEmpty;

  // Add-to-group requires not already viewing a group.
  final showAddToGroup = !t.isSelf && !t.isBot && !t.inGroup;
  final showGiftCredits = !t.isSelf && !t.isBot;

  // Profile-only hides Mention, Translate, Slap, Hug, mod items and Edit Message; Edit Profile stays for self.
  if (t.profileOnly) {
    return [
      if (!t.isSelf) CtxAction.privateMessage,
      if (showAddToGroup) CtxAction.addToGroup,
      if (showGiftCredits) CtxAction.giftCredits,
      if (!t.isSelf) CtxAction.friend,
      if (!t.isSelf) CtxAction.report,
      if (!t.isSelf) CtxAction.block,
      if (t.isSelf) CtxAction.editProfile,
    ];
  }

  final other = t.inGroup && t.targetIsMember && !t.isSelf;
  final showKickOrBan = other && t.iCanModerate && t.iOutrankTarget;
  final showAddMod = other &&
      t.iCanAdminister &&
      t.iOutrankTarget &&
      !t.targetIsMod &&
      !t.targetIsAdmin;
  final showRemoveMod =
      other && t.iCanAdminister && t.iOutrankTarget && t.targetIsMod;
  final showAddAdmin = other && t.iAmOwner && !t.targetIsAdmin;
  final showRemoveAdmin = other && t.iAmOwner && t.targetIsAdmin;
  final showTransfer = other && t.iAmOwner;

  final canDeleteOwn = t.isSelf && hasMessage;
  final canModDelete = !canDeleteOwn && hasMessage && canModDeleteMessage(t);

  // Mention is not self-gated in the PWA, so it shows on your own messages too.
  return [
    if (hasMessage) CtxAction.react,
    CtxAction.mention,
    if (!t.isSelf) CtxAction.privateMessage,
    if (!t.isSelf) CtxAction.slap,
    if (!t.isSelf) CtxAction.hug,
    if (showAddToGroup) CtxAction.addToGroup,
    if (!t.isSelf && hasMessage) CtxAction.zap,
    if (showGiftCredits) CtxAction.giftCredits,
    if (hasContent) CtxAction.quote,
    if (hasContent) CtxAction.copyMessage,
    if (hasContent) CtxAction.translate,
    if (!t.isSelf) CtxAction.friend,
    if (!t.isSelf && !showKickOrBan) CtxAction.report,
    if (t.isSelf && hasMessage && hasContent) CtxAction.edit,
    if (canDeleteOwn || (canModDelete && !showKickOrBan)) CtxAction.delete,
    if (showAddMod) CtxAction.makeMod,
    if (showRemoveMod) CtxAction.revokeMod,
    if (showAddAdmin) CtxAction.makeAdmin,
    if (showRemoveAdmin) CtxAction.revokeAdmin,
    if (showTransfer) CtxAction.transferOwner,
    if (showKickOrBan) CtxAction.report,
    if (canModDelete && showKickOrBan) CtxAction.delete,
    if (showKickOrBan) CtxAction.kick,
    if (showKickOrBan) CtxAction.ban,
    if (!t.isSelf) CtxAction.block,
    if (t.isSelf) CtxAction.editProfile,
  ];
}

bool canModDeleteMessage(CtxTarget t) =>
    t.inGroup &&
    !t.isSelf &&
    (t.iAmOwner || (t.iCanModerate && t.iOutrankTarget));

const Set<CtxAction> kMessageScopedCtxActions = {
  CtxAction.react,
  CtxAction.quote,
  CtxAction.copyMessage,
  CtxAction.translate,
  CtxAction.edit,
  CtxAction.delete,
};

List<CtxAction> buildUserSheetActions(CtxTarget t) => [
      for (final a in buildContextMenuActions(t))
        if (!kMessageScopedCtxActions.contains(a)) a,
    ];

enum MenuTone { normal, report, danger }

MenuTone ctxActionTone(CtxAction a) {
  switch (a) {
    case CtxAction.report:
      return MenuTone.report;
    case CtxAction.delete:
    case CtxAction.kick:
    case CtxAction.ban:
    case CtxAction.block:
      return MenuTone.danger;
    default:
      return MenuTone.normal;
  }
}

Color menuToneColor(MenuTone t, NymColors c) {
  switch (t) {
    case MenuTone.report:
      return c.warning;
    case MenuTone.danger:
      return c.danger;
    case MenuTone.normal:
      return c.text;
  }
}

String ctxActionLabel(CtxAction a, CtxTarget t) {
  switch (a) {
    case CtxAction.react:
      return 'React';
    case CtxAction.mention:
      return 'Mention';
    case CtxAction.privateMessage:
      return 'Private Message';
    case CtxAction.slap:
      return 'Slap with Trout';
    case CtxAction.hug:
      return 'Give warm Hug';
    case CtxAction.addToGroup:
      return 'Create Group Chat';
    case CtxAction.zap:
      return 'Zap Bitcoin';
    case CtxAction.giftCredits:
      return 'Gift Nymbot Credits';
    case CtxAction.quote:
      return 'Quote Message';
    case CtxAction.copyMessage:
      return 'Copy Message';
    case CtxAction.translate:
      return 'Translate Message';
    case CtxAction.friend:
      return t.isFriend ? 'Remove Friend' : 'Add Friend';
    case CtxAction.report:
      return 'Report';
    case CtxAction.edit:
      return 'Edit Message';
    case CtxAction.delete:
      return 'Delete Message';
    case CtxAction.makeAdmin:
      return 'Make Admin';
    case CtxAction.revokeAdmin:
      return 'Revoke Admin';
    case CtxAction.makeMod:
      return 'Make Moderator';
    case CtxAction.revokeMod:
      return 'Revoke Moderator';
    case CtxAction.transferOwner:
      return 'Transfer Ownership';
    case CtxAction.kick:
      return 'Remove from Group';
    case CtxAction.ban:
      return 'Ban from Group';
    case CtxAction.block:
      return t.isBlocked ? 'Unblock User' : 'Block User';
    case CtxAction.editProfile:
      return 'Edit Profile';
  }
}

String ctxActionSvg(CtxAction a, [CtxTarget? t]) {
  switch (a) {
    case CtxAction.react:
      return NymIcons.ctxReact;
    case CtxAction.mention:
      return NymIcons.ctxMention;
    case CtxAction.privateMessage:
      return NymIcons.ctxPm;
    case CtxAction.slap:
      return NymIcons.ctxSlap;
    case CtxAction.hug:
      return NymIcons.ctxHug;
    case CtxAction.addToGroup:
      return NymIcons.ctxAddToGroup;
    case CtxAction.zap:
      return NymIcons.ctxZap;
    case CtxAction.giftCredits:
      return NymIcons.ctxGiftCredits;
    case CtxAction.quote:
      return NymIcons.ctxQuote;
    case CtxAction.copyMessage:
      return NymIcons.ctxCopy;
    case CtxAction.translate:
      return NymIcons.translate;
    case CtxAction.friend:
      return t != null && t.isFriend ? NymIcons.ctxUnfriend : NymIcons.ctxFriend;
    case CtxAction.report:
      return NymIcons.ctxReport;
    case CtxAction.edit:
      return NymIcons.ctxEdit;
    case CtxAction.delete:
      return NymIcons.ctxDelete;
    case CtxAction.makeMod:
      return NymIcons.ctxMakeMod;
    case CtxAction.makeAdmin:
      return NymIcons.ctxMakeAdmin;
    case CtxAction.revokeMod:
      return NymIcons.ctxRevokeMod;
    case CtxAction.revokeAdmin:
      return NymIcons.ctxRevokeAdmin;
    case CtxAction.transferOwner:
      return NymIcons.ctxTransferOwner;
    case CtxAction.kick:
      return NymIcons.ctxKick;
    case CtxAction.ban:
      return NymIcons.ctxBan;
    case CtxAction.block:
      return NymIcons.ctxBlock;
    case CtxAction.editProfile:
      return NymIcons.ctxEditProfile;
  }
}

/// Group role flags default to false; pass overrides when richer group data is available.
CtxTarget ctxTargetForMessage(
  Message message, {
  required String selfPubkey,
  bool isFriend = false,
  bool isBlocked = false,
  String? liveNym,
}) {
  return CtxTarget(
    pubkey: message.pubkey,
    nym: pickDisplayNym(liveNym, message.author),
    isSelf: message.pubkey == selfPubkey || message.isOwn,
    content: message.content,
    messageId: message.id,
    isFriend: isFriend,
    isBlocked: isBlocked,
    isBot: message.isBot,
    inGroup: message.isGroup || message.groupId != null,
  );
}
