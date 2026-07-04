import '../../models/message.dart';
import '../nym_icons.dart';

/// The identity of a context-menu action (mirrors the `#ctxXxx` items in
/// index.html's `#contextMenu`). Order matches the PWA's markup.
enum CtxAction {
  react, // #ctxReact
  mention, // #ctxMention
  privateMessage, // #ctxPM
  slap, // #ctxSlap ("Slap with Trout") — injected after PM (ui-context.js:507)
  hug, // #ctxHug ("Give warm Hug") — injected after Slap (ui-context.js:526)
  addToGroup, // #ctxAddToGroup ("Create Group Chat")
  zap, // #ctxZap (lightning)
  giftCredits, // #ctxGiftCredits ("Gift Nymbot Credits")
  quote, // #ctxQuote
  copyMessage, // #ctxCopyMessage
  translate, // #ctxTranslate
  friend, // #ctxFriend (Add/Remove Friend)
  report, // #ctxReport
  edit, // #ctxEditMessage (own only)
  delete, // #ctxDeleteMessage (own / mod)
  // group moderation (shown only when applicable)
  makeMod, // #ctxAddMod
  revokeMod, // #ctxRemoveMod
  transferOwner, // #ctxTransferOwner
  kick, // #ctxKickMember
  ban, // #ctxBanMember
  block, // #ctxBlock (Block/Unblock)
  editProfile, // #ctxEditProfile (own only) — appears last (index.html:260)
}

/// Target metadata for a context-menu invocation, mirroring the PWA's
/// `this.contextMenuData` plus the role flags `showContextMenu` derives.
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
    // group context (null when not viewing a group):
    this.inGroup = false,
    this.iAmOwner = false,
    this.iAmMod = false,
    this.targetIsMember = false,
    this.targetIsOwner = false,
    this.targetIsMod = false,
    this.backToGroupId,
  });

  final String pubkey;
  final String nym; // base nym (no suffix)
  final bool isSelf;

  /// Message body (null for mention/sidebar profile clicks).
  final String? content;

  /// Real event id of the message (null for profile clicks).
  final String? messageId;

  /// Profile-only mode (nyms sidebar): only PM / Report / Block.
  final bool profileOnly;

  final bool isFriend;
  final bool isBlocked;
  final bool isBot;

  final bool inGroup;
  final bool iAmOwner;
  final bool iAmMod;
  final bool targetIsMember;
  final bool targetIsOwner;
  final bool targetIsMod;

  /// When this profile was opened from a group's member list, the originating
  /// group id — the user context menu then shows a top-left "back" chevron that
  /// returns to that group's context menu (PWA `backToGroupId`,
  /// ui-context.js:354/371). Null for every other entry point.
  final String? backToGroupId;

  bool get iCanModerate => iAmOwner || iAmMod;
}

/// Builds the visible, ordered action list for [t], mirroring the visibility
/// rules in ui-context.js `showContextMenu` (lines 354-661). Edit is own-only;
/// zap/report/friend/block/PM/mention are hidden for self; moderation items
/// appear only when the role rules permit; translate/quote/copy need content.
List<CtxAction> buildContextMenuActions(CtxTarget t) {
  final hasContent = t.content != null && t.content!.isNotEmpty;
  final hasMessage = t.messageId != null && t.messageId!.isNotEmpty;

  // "Create Group Chat" / "Gift Nymbot Credits" gates (ui-context.js:575-584).
  // AddToGroup also requires we're NOT already viewing a group.
  final showAddToGroup = !t.isSelf && !t.isBot && !t.inGroup;
  final showGiftCredits = !t.isSelf && !t.isBot;

  // Profile-only mode (nyms sidebar): the PWA explicitly hides Mention,
  // Translate, Slap, Hug, mod items and Edit *Message* (`editOption`); everything
  // else stays subject to its own gate. With no messageId/content present,
  // React/Zap/Quote/Copy/Delete fall away too — leaving PM, AddToGroup,
  // GiftCredits, Friend, Report, Block, and (for self) Edit *Profile*, which the
  // PWA keeps visible (`ctxEditProfile` is shown when pubkey === self, and the
  // profile-only block never hides it) (ui-context.js:586-594, 640-654).
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

  // Group moderation visibility (ui-context.js lines 477-484).
  final showKickOrBan = t.inGroup &&
      t.targetIsMember &&
      !t.isSelf &&
      t.iCanModerate &&
      (t.iAmOwner || (!t.targetIsOwner && !t.targetIsMod));
  final showAddMod = t.inGroup &&
      t.targetIsMember &&
      !t.isSelf &&
      t.iAmOwner &&
      !t.targetIsOwner &&
      !t.targetIsMod;
  final showRemoveMod = t.inGroup &&
      t.targetIsMember &&
      !t.isSelf &&
      t.iAmOwner &&
      t.targetIsMod;
  final showTransfer =
      t.inGroup && t.targetIsMember && !t.isSelf && t.iAmOwner;

  // Mod/owner can delete another member's message in the current group.
  final canDeleteOwn = t.isSelf && hasMessage;
  final canModDelete = !canDeleteOwn &&
      hasMessage &&
      t.inGroup &&
      !t.isSelf &&
      (t.iAmOwner || (t.iAmMod && !t.targetIsOwner));

  // Order mirrors the runtime DOM (index.html:94-260) with Slap/Hug injected
  // right after PM (ui-context.js:507-530): React, Mention, PM, Slap, Hug,
  // AddToGroup, Zap, GiftCredits, Quote, Copy, Translate, Friend, Report, Edit,
  // Delete, AddMod, RemoveMod, TransferOwner, Kick, Ban, Block, EditProfile.
  // Note: Mention is NOT self-gated in the PWA (only hidden in profileOnly) — it
  // shows on your own messages too.
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
    if (!t.isSelf) CtxAction.report,
    if (t.isSelf && hasMessage && hasContent) CtxAction.edit,
    if (canDeleteOwn || canModDelete) CtxAction.delete,
    if (showAddMod) CtxAction.makeMod,
    if (showRemoveMod) CtxAction.revokeMod,
    if (showTransfer) CtxAction.transferOwner,
    if (showKickOrBan) CtxAction.kick,
    if (showKickOrBan) CtxAction.ban,
    if (!t.isSelf) CtxAction.block,
    if (t.isSelf) CtxAction.editProfile,
  ];
}

/// The visible label for an action given the target (handles Add/Remove Friend
/// and Block/Unblock toggles, ui-context.js lines 555-569).
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

/// The leading 16px glyph (a [NymIcons] SVG string) for an action row,
/// reproducing the PWA's per-item inline SVGs verbatim (index.html:94-266; the
/// injected Slap/Hug glyphs at ui-context.js:504/524). Reused by the
/// quick-context-menu (F3) for the shared items. Rendered through [NymSvgIcon].
String ctxActionSvg(CtxAction a) {
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
      return NymIcons.ctxFriend;
    case CtxAction.report:
      return NymIcons.ctxReport;
    case CtxAction.edit:
      return NymIcons.ctxEdit;
    case CtxAction.delete:
      return NymIcons.ctxDelete;
    case CtxAction.makeMod:
      return NymIcons.ctxMakeMod;
    case CtxAction.revokeMod:
      return NymIcons.ctxRevokeMod;
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

/// Builds a [CtxTarget] from a [Message] and the local pubkey, deriving
/// self/group flags. Group role flags default false (the seeded store has no
/// public mod accessor; pass overrides when richer group data is available).
CtxTarget ctxTargetForMessage(
  Message message, {
  required String selfPubkey,
  bool isFriend = false,
  bool isBlocked = false,
}) {
  return CtxTarget(
    pubkey: message.pubkey,
    nym: _baseNym(message.author),
    isSelf: message.pubkey == selfPubkey || message.isOwn,
    content: message.content,
    messageId: message.id,
    isFriend: isFriend,
    isBlocked: isBlocked,
    isBot: message.isBot,
    inGroup: message.isGroup || message.groupId != null,
  );
}

String _baseNym(String nym) {
  final hash = nym.indexOf('#');
  return hash > 0 ? nym.substring(0, hash) : nym;
}
