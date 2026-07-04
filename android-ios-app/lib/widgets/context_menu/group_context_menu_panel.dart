import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/channels/channel_share.dart' show kNymchatShareHost;
import '../../features/pms/new_pm_modal.dart' show resolveRecipientPubkey;
import '../../models/group.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'context_menu_actions.dart';
import 'context_menu_panel.dart';

/// The `#groupContextMenu` slide-in panel (PWA `showGroupContextMenu`,
/// groups.js:2987-3088). A right-side panel mirroring the user context menu's
/// chrome (width 320, `translateX(100%)→0` over 150ms, dimmed barrier) that:
///
///  * shows the group banner + icon + name + member count + description,
///  * renders the owner-gated metadata controls (Edit Name / Description,
///    Change/Remove Avatar+Banner, Transfer Ownership, the allow-member-invites
///    toggle, the allow-invite-join toggle + Reset Invite Link), the
///    Add-Members picker (owner or invite-allowed member), and the all-members
///    **Leave Group** danger row — wired to [NostrController]
///    (`updateGroupMetadata` / `setGroupAllowInvites` / `setGroupInviteEnabled`
///    / `rotateGroupInviteEpoch` / `addGroupMembers` / `transferOwner` /
///    `leaveGroup`),
///  * shows the owner/inviter invite-link block (selectable URL + Copy Invite
///    Link), built locally from group state (`buildGroupInviteLink`),
///  * lists the members (owner → mods → members) with a role badge; tapping a
///    member opens that user's context menu, which carries the group's
///    PM / kick / ban / promote / make-owner actions gated by role (via
///    `buildContextMenuActions` with the group context), and shows a back
///    chevron that returns here (`backToGroupId`).
///
/// Role gates are read-only from group state (`group.createdBy` / `group.mods`).
class GroupContextMenuPanel extends ConsumerStatefulWidget {
  const GroupContextMenuPanel({
    super.key,
    required this.groupId,
    required this.animation,
    required this.onClose,
  });

  final String groupId;
  final Animation<double> animation;
  final VoidCallback onClose;

  /// Presents the panel in the root overlay with the slide-in transition,
  /// mirroring [ContextMenuPanel.show].
  static Future<void> show(BuildContext context, String groupId) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'group context menu',
      barrierColor: const Color(0x99000000), // rgba(0,0,0,0.6)
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (ctx, anim, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) => Align(
        alignment: Alignment.centerRight,
        child: GroupContextMenuPanel(
          groupId: groupId,
          animation: anim,
          onClose: () => Navigator.of(ctx).maybePop(),
        ),
      ),
    );
  }

  @override
  ConsumerState<GroupContextMenuPanel> createState() =>
      _GroupContextMenuPanelState();
}

class _GroupContextMenuPanelState extends ConsumerState<GroupContextMenuPanel> {
  /// "Select a member to make owner" mode (PWA `_groupCtxTransferMode`,
  /// groups.js:3120). When on, member taps pick the new owner instead of opening
  /// the user menu.
  bool _transferMode = false;

  Group? _group(AppState s) {
    for (final g in s.groups) {
      if (g.id == widget.groupId) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final s = ref.watch(appStateProvider);
    final group = _group(s);

    final body = group == null
        ? Center(
            child: Text('Group unavailable',
                style: TextStyle(color: c.textDim, fontSize: 13)),
          )
        : _content(c, s, group);

    final screenW = MediaQuery.of(context).size.width;
    final panelW = (screenW * 0.85).clamp(0.0, 320.0);

    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(
              CurvedAnimation(parent: widget.animation, curve: Curves.linear)),
      child: SizedBox(
        width: panelW,
        height: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            // `.context-menu` under `body.solid-ui` (default) → `var(--glass-bg)`
            // opaque surface (matches the sidebar/chat-header), painted on the
            // full-height Container so it fills the whole viewport
            // (`.context-menu { height: 100vh }`), not just the content.
            color: c.glassBg,
            border: Border(left: BorderSide(color: c.glassBorder)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000), // rgba(0,0,0,0.4)
                blurRadius: 24,
                offset: Offset(-4, 0),
              ),
            ],
          ),
          child: Stack(
            children: [
              Material(
                type: MaterialType.transparency,
                child: SafeArea(child: body),
              ),
              Positioned(top: 14, right: 14, child: CtxCloseButton(onTap: widget.onClose)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(NymColors c, AppState s, Group group) {
    final self = s.selfPubkey;
    final iAmOwner = group.createdBy == self;

    // Sort members: owner → mods → members (PWA `_memberRoleRank`).
    final sorted = [...group.members]
      ..sort((a, b) => _roleRank(group, a).compareTo(_roleRank(group, b)));

    final description = (group.description ?? '').trim();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(c, group),
          // `.context-menu-bio`: a separate, left-aligned block below the header
          // with its own bottom hairline; collapses when empty (:empty).
          if (description.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: c.hairline),
                ),
              ),
              child: Text(
                description,
                style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
              ),
            ),
          // Owner/member management rows (role-gated). `.context-menu-actions`:
          // 6px padding + a 1px white@0.06 top hairline.
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: c.hairline),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _actionRows(c, group, iAmOwner),
            ),
          ),
          // `.group-ctx-members-title`: 12px uppercase, 0.04em tracking,
          // text-dim, padding 10/16/4, with a 1px white@0.06 top hairline.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: c.hairline),
              ),
            ),
            child: Text(
              _transferMode
                  ? 'Select a member to make owner'.toUpperCase()
                  : 'Members · ${group.members.length}'.toUpperCase(),
              style: TextStyle(
                color: c.textDim,
                fontSize: 12,
                letterSpacing: 0.48,
              ),
            ),
          ),
          for (final pk in sorted)
            // In transfer mode the owner can't pick themselves.
            if (!_transferMode || pk != self)
              _memberRow(c, group, pk, self),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header (banner + icon + name + member count + invite link)
  // ---------------------------------------------------------------------------

  Widget _header(NymColors c, Group group) {
    final bannerUrl = proxiedAvatarUrl(group.banner);
    final hasBanner = bannerUrl != null && bannerUrl.isNotEmpty;
    final avatarUrl = proxiedAvatarUrl(group.avatar);

    // The PWA group menu *always* carries `has-banner` (groups.js:3001): a
    // custom banner image when set, else a default gradient banner. The icon
    // gets a 3px rgba(20,20,35,0.95) ring + bg and overlaps the banner by -36px.
    final icon = SizedBox(
      width: 64,
      height: 64,
      child: (avatarUrl != null && avatarUrl.isNotEmpty)
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: avatarUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => _defaultGroupIcon(c),
              ),
            )
          : _defaultGroupIcon(c),
    );

    // The 140px banner: custom image, else the default 135° primary→secondary
    // gradient (both at 0.45 alpha) — `.group-ctx-default-banner`.
    final banner = SizedBox(
      height: 140,
      width: double.infinity,
      child: hasBanner
          ? CachedNetworkImage(
              imageUrl: bannerUrl,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _defaultBanner(c),
            )
          : _defaultBanner(c),
    );

    final header = Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.hairline),
        ),
      ),
      child: Column(
        children: [
          // Group name (`.context-menu-avatar-nym`): 13px / w600 / secondary.
          Text(
            group.name.isEmpty ? 'Group' : group.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.secondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${group.members.length} member${group.members.length == 1 ? '' : 's'}',
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          // Invite-link row + Copy (owner/inviter only) — fills the same slot as
          // the user menu's pubkey block (groups.js:3031-3041).
          ..._inviteLinkRows(c, group),
        ],
      ),
    );

    // Banner with the icon straddling its bottom edge (`margin-top:-36px`),
    // mirroring the user menu's banner overlap. The icon carries a 3px ring.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            banner,
            Padding(padding: const EdgeInsets.only(top: 34), child: header),
          ],
        ),
        Positioned(
          top: 140 - 36,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // `.has-banner .group-ctx-icon` ring/disc: rgba(20,20,35,0.95)
                // dark; light-mode flips it to rgba(255,255,255,0.95).
                color: _bannerRing(c),
                border: Border.fromBorderSide(
                  BorderSide(color: _bannerRing(c), width: 3),
                ),
              ),
              child: icon,
            ),
          ),
        ),
      ],
    );
  }

  /// The banner-avatar ring/disc colour (`.has-banner .group-ctx-icon`):
  /// `rgba(20,20,35,0.95)` dark; `rgba(255,255,255,0.95)` light.
  Color _bannerRing(NymColors c) => c.isLight
      ? const Color(0xF2FFFFFF)
      : const Color(0xF2141423);

  /// The `.group-ctx-default-banner`: a 135° gradient from `--primary`@0.45 to
  /// `--secondary`@0.45.
  Widget _defaultBanner(NymColors c) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.primary.withValues(alpha: 0.45),
            c.secondary.withValues(alpha: 0.45),
          ],
        ),
      ),
    );
  }

  /// The header invite-link block: a selectable `.ctx-full-pubkey`-style URL +
  /// a "Copy Invite Link" `.context-menu-copy-pubkey` row, both shown only when
  /// the self user can add members AND invite links are enabled
  /// (groups.js `buildGroupInviteLink`: returns null otherwise).
  List<Widget> _inviteLinkRows(NymColors c, Group group) {
    final self = ref.read(appStateProvider).selfPubkey;
    final link = _buildInviteLink(group, self);
    if (link == null) return const [];
    return [
      Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: c.insetFill,
          border: Border.all(color: c.insetBorder),
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        child: SelectableText(
          link,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.textDim,
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.35,
          ),
        ),
      ),
      _CopyInviteRow(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: link));
          ref
              .read(appStateProvider.notifier)
              .addSystemMessage('Copied group invite link to clipboard');
          widget.onClose();
        },
      ),
    ];
  }

  /// Builds the `#gjoin=<token>` invite URL exactly as the PWA
  /// `buildGroupInviteLink` does: null unless invites are enabled AND the self
  /// user can add members; payload `{v,g,n,a,e}` base64url-encoded onto the
  /// canonical web host.
  String? _buildInviteLink(Group group, String self) {
    if (!group.inviteEnabled) return null;
    if (!group.canAddMembers(self)) return null;
    final name = group.name.isEmpty ? 'Group' : group.name;
    final payload = <String, dynamic>{
      'v': 1,
      'g': group.id,
      'n': name.length > 80 ? name.substring(0, 80) : name,
      'a': self,
      'e': group.inviteEpoch,
    };
    final json = jsonEncode(payload);
    final token = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    return '$kNymchatShareHost/#gjoin=$token';
  }

  Widget _defaultGroupIcon(NymColors c) {
    // `.group-ctx-icon`: `--primary` (green) 34px glyph. The base rule fills
    // white@0.06, but the live group menu always has a banner, so
    // `.has-banner .group-ctx-icon` overrides the bg to rgba(20,20,35,0.95)
    // (supplied by the surrounding ring Container) — keep this transparent so
    // that dark disc shows through behind the glyph.
    return Container(
      alignment: Alignment.center,
      child: NymSvgIcon(NymIcons.groupGlyph, size: 34, color: c.primary),
    );
  }

  // ---------------------------------------------------------------------------
  // Action rows (role-gated owner/member controls)
  // ---------------------------------------------------------------------------

  List<Widget> _actionRows(NymColors c, Group group, bool iAmOwner) {
    final self = ref.read(appStateProvider).selfPubkey;
    final canAdd = group.canAddMembers(self);
    final rows = <Widget>[];

    // Owner metadata controls (groups.js:3046-3083). Role-gated to the owner.
    if (iAmOwner) {
      rows.add(_ActionRow(
        svg: NymIcons.ctxEdit,
        label: 'Edit Group Name',
        color: c.text,
        onTap: () => _editName(group),
      ));
      rows.add(_ActionRow(
        svg: NymIcons.groupEditDescription,
        label: 'Edit Description',
        color: c.text,
        onTap: () => _editDescription(group),
      ));
      rows.add(_ActionRow(
        svg: NymIcons.groupChangeAvatar,
        label: 'Change Avatar',
        color: c.text,
        onTap: () => _changeImage(group, avatar: true),
      ));
      if ((group.avatar ?? '').isNotEmpty) {
        // No distinct PWA glyph for "Remove Avatar" (the PWA only offers the
        // change rows); reuse the avatar glyph so the row stays on-brand.
        rows.add(_ActionRow(
          svg: NymIcons.groupChangeAvatar,
          label: 'Remove Avatar',
          color: c.text,
          onTap: () => _removeImage(group, avatar: true),
        ));
      }
      rows.add(_ActionRow(
        svg: NymIcons.groupChangeBanner,
        label: 'Change Banner',
        color: c.text,
        onTap: () => _changeImage(group, avatar: false),
      ));
      if ((group.banner ?? '').isNotEmpty) {
        rows.add(_ActionRow(
          svg: NymIcons.groupChangeBanner,
          label: 'Remove Banner',
          color: c.text,
          onTap: () => _removeImage(group, avatar: false),
        ));
      }
    }

    // Transfer Ownership — enters member-pick mode (PWA `groupCtxTransferOwner`).
    if (iAmOwner && group.members.length > 1) {
      rows.add(_ActionRow(
        svg: NymIcons.ctxTransferOwner,
        label: 'Transfer Ownership',
        color: c.text,
        onTap: () => setState(() => _transferMode = true),
      ));
    }

    // Allow joining via invite link (owner-only checkbox row,
    // groups.js `groupCtxToggleInviteJoin`).
    if (iAmOwner) {
      rows.add(_ActionRow(
        svg: group.inviteEnabled
            ? NymIcons.checkboxChecked
            : NymIcons.checkboxUnchecked,
        label: 'Allow joining via invite link',
        color: c.text,
        onTap: () => _toggleInviteJoin(group),
      ));
      // Reset Invite Link — owner-only, shown only when invite joining is on
      // (groups.js `groupCtxResetInviteLink`).
      if (group.inviteEnabled) {
        rows.add(_ActionRow(
          svg: NymIcons.groupResetInvite,
          label: 'Reset Invite Link',
          color: c.text,
          onTap: () => _resetInviteLink(group),
        ));
      }
    }

    // Allow members to add others (owner-only checkbox row,
    // groups.js `groupCtxToggleInvites`).
    if (iAmOwner) {
      rows.add(_ActionRow(
        svg: group.allowMemberInvites
            ? NymIcons.checkboxChecked
            : NymIcons.checkboxUnchecked,
        label: 'Allow members to add others',
        color: c.text,
        onTap: () => _toggleAllowInvites(group),
      ));
    }

    // Add Members — owner, or a member when member-invites are allowed.
    if (canAdd) {
      rows.add(_ActionRow(
        svg: NymIcons.groupAddMembers,
        label: 'Add Members',
        color: c.text,
        onTap: () => _addMembers(group),
      ));
    }

    // Leave Group — available to every member (danger, confirmed).
    rows.add(_ActionRow(
      svg: NymIcons.groupLeave,
      label: 'Leave Group',
      color: c.danger,
      onTap: () => _leaveGroup(group),
    ));

    return rows;
  }

  // ---------------------------------------------------------------------------
  // Owner / membership action handlers (wired to NostrController).
  // ---------------------------------------------------------------------------

  /// Owner: prompt for a new name → `updateGroupMetadata(name:)`
  /// (groups.js `groupCtxEditName`).
  Future<void> _editName(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final name = await showAppPrompt(
      context,
      'Enter a new group name:',
      title: 'Rename Group',
      okLabel: 'Save',
      defaultValue: group.name,
      maxLength: 40,
    );
    if (name == null) return;
    await controller.updateGroupMetadata(group.id, name: name);
  }

  /// Owner: prompt for a description → `updateGroupMetadata(description:)`
  /// (groups.js `groupCtxEditDescription`).
  Future<void> _editDescription(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final desc = await showAppPrompt(
      context,
      'Enter a group description:',
      title: 'Group Description',
      okLabel: 'Save',
      defaultValue: group.description ?? '',
      maxLength: 150,
      multiline: true,
    );
    if (desc == null) return;
    await controller.updateGroupMetadata(group.id, description: desc);
  }

  /// Owner: pick an image, upload it (Blossom), then set it as the group
  /// avatar/banner via `updateGroupMetadata` (groups.js `_setGroupImage`).
  Future<void> _changeImage(Group group, {required bool avatar}) async {
    final controller = ref.read(nostrControllerProvider);
    Uint8List? bytes;
    String contentType = 'image/jpeg';
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null) return;
      bytes = await File(file.path).readAsBytes();
      contentType = _contentTypeFor(file.path);
    } catch (_) {
      // Picker unavailable (tests / desktop) — nothing to do.
      return;
    }
    final url = await controller.uploadImage(bytes, contentType: contentType);
    if (url == null || url.isEmpty) return;
    if (avatar) {
      await controller.updateGroupMetadata(group.id, avatar: url);
    } else {
      await controller.updateGroupMetadata(group.id, banner: url);
    }
  }

  /// Owner: clear the avatar/banner via `updateGroupMetadata('')`
  /// (groups.js `_clearGroupImage`).
  Future<void> _removeImage(Group group, {required bool avatar}) async {
    final controller = ref.read(nostrControllerProvider);
    if (avatar) {
      await controller.updateGroupMetadata(group.id, avatar: '');
    } else {
      await controller.updateGroupMetadata(group.id, banner: '');
    }
  }

  /// Owner: flip the "members can add others" permission → `setGroupAllowInvites`
  /// (groups.js `groupCtxToggleInvites`).
  Future<void> _toggleAllowInvites(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    await controller.setGroupAllowInvites(group.id, !group.allowMemberInvites);
  }

  /// Owner: flip "allow joining via invite link" → `setGroupInviteEnabled`
  /// (groups.js `groupCtxToggleInviteJoin`). Closes the menu first, mirroring
  /// the PWA which closes then toggles. The controller mutates the group,
  /// bumps `metaUpdatedAt`, and rebroadcasts the metadata.
  Future<void> _toggleInviteJoin(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final next = !group.inviteEnabled;
    widget.onClose();
    await controller.setGroupInviteEnabled(group.id, next);
  }

  /// Owner: rotate the invite epoch so previously-shared links stop working
  /// (groups.js `groupCtxResetInviteLink`). Confirms first, then rotates.
  Future<void> _resetInviteLink(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final ok = await showAppConfirm(
      context,
      'Reset the invite link? Every link shared so far will stop working.',
      title: 'Reset Invite Link',
      okLabel: 'Reset',
      danger: true,
    );
    if (!ok) return;
    widget.onClose();
    await controller.rotateGroupInviteEpoch(group.id);
  }

  /// Add Members: pick recipients (nym / pubkey / npub) → `addGroupMembers`
  /// (groups.js `groupCtxAddMembers` → `openAddMembersModal`).
  Future<void> _addMembers(Group group) async {
    final picked = await _AddMembersDialog.show(context, group);
    if (picked == null || picked.isEmpty) return;
    await ref.read(nostrControllerProvider).addGroupMembers(group.id, picked);
  }

  /// Leave Group: danger confirm → `leaveGroup` (groups.js `groupCtxLeave`).
  /// Closes the panel first so it isn't left over the (now-gone) group.
  Future<void> _leaveGroup(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final name = group.name.isEmpty ? 'this group' : '"${group.name}"';
    final ok = await showAppConfirm(
      context,
      "Leave $name? You'll stop receiving messages from this group.",
      title: 'Leave Group',
      okLabel: 'Leave',
      danger: true,
    );
    if (!ok) return;
    widget.onClose();
    await controller.leaveGroup(group.id);
  }

  static String _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  // ---------------------------------------------------------------------------
  // Member rows
  // ---------------------------------------------------------------------------

  int _roleRank(Group group, String pubkey) {
    if (group.createdBy == pubkey) return 0;
    if (group.mods.contains(pubkey)) return 1;
    return 2;
  }

  Widget _memberRow(NymColors c, Group group, String pubkey, String self) {
    final user = ref.watch(usersProvider)[pubkey];
    final base = stripPubkeySuffix(user?.nym ?? '');
    final suffix = getPubkeySuffix(pubkey);
    final isSelf = pubkey == self;
    final isOwner = group.createdBy == pubkey;
    final isMod = !isOwner && group.mods.contains(pubkey);

    // PWA `.group-ctx-member-avatar` is a bare 30×30 `<img>` — no status dot
    // (the live member row is avatar + name + role badge only).
    return _MemberTile(
      colors: c,
      avatar: NymAvatar(
        seed: pubkey,
        size: 30,
        imageUrl: user?.profile?.picture,
        label: base.isNotEmpty ? base[0] : null,
      ),
      base: base.isEmpty ? '(unknown)' : base,
      suffix: '#$suffix',
      isSelf: isSelf,
      roleBadge: isOwner ? 'Owner' : (isMod ? 'Mod' : null),
      onTap: () => _onMemberTap(group, pubkey, base, isSelf),
    );
  }

  void _onMemberTap(Group group, String pubkey, String base, bool isSelf) {
    if (_transferMode) {
      // Pick the new owner (PWA `_openMemberFromGroupCtx` transfer branch). The
      // confirm dialog runs on THIS (still-mounted) panel; only on confirm do we
      // pop + transfer, so `ref` stays valid.
      setState(() => _transferMode = false);
      _confirmTransfer(group.id, pubkey, base);
      return;
    }
    // Open the user's context menu carrying this group as the back target so it
    // shows a "back" chevron and the group kick/ban/mod actions stay visible
    // (PWA `_openMemberFromGroupCtx`: showContextMenu(..., backToGroupId)).
    // Capture the root navigator context before popping (ours is then defunct).
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    widget.onClose();
    final target = CtxTarget(
      pubkey: pubkey,
      nym: base,
      isSelf: isSelf,
      backToGroupId: group.id,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (rootContext.mounted) {
        ContextMenuPanel.show(rootContext, target: target);
      }
    });
  }

  Future<void> _confirmTransfer(
      String groupId, String pubkey, String base) async {
    final controller = ref.read(nostrControllerProvider);
    // `.app-dialog` confirm — the PWA member-transfer branch runs
    // `showAppConfirm(\`Transfer group ownership to ${nym}? You will lose owner
    // privileges.\`, { danger: true, okLabel: 'Transfer' })` (groups.js:3136).
    final ok = await showAppConfirm(
      context,
      'Transfer group ownership to $base? You will lose owner privileges.',
      okLabel: 'Transfer',
      danger: true,
    );
    if (ok) {
      // Close the group menu, then run the transfer with the captured
      // controller (safe even after this panel disposes).
      widget.onClose();
      await controller.transferOwner(groupId, pubkey);
    }
  }

}

/// A `.context-menu-item` management row (icon + label + optional trailing).
class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.svg,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String svg;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isNeutral = widget.color == c.text;
    // Neutral rows shift label + icon to `--primary` on hover
    // (`.context-menu-item:hover { color: var(--primary) }`); colored rows keep
    // their resting tint.
    final Color labelColor = isNeutral && _hover ? c.primary : widget.color;
    final Color iconColor =
        isNeutral ? (_hover ? c.primary : c.textDim) : widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _hover
                ? (widget.color == c.danger ? c.dangerHoverOverlay : c.hoverOverlay)
                : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            children: [
              NymSvgIcon(widget.svg, size: 16, color: iconColor),
              // `.nm-ico8` → margin-right:8px on the leading SVG.
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.context-menu-copy-pubkey` row reading "Copy Invite Link" (groups.js
/// `grpCtxCopyInvite`): 3×8 padding, radius 6, hover white@0.08 bg + primary
/// text; copy glyph + label. Copies the link + closes on tap.
class _CopyInviteRow extends StatefulWidget {
  const _CopyInviteRow({required this.onTap});
  final Future<void> Function() onTap;

  @override
  State<_CopyInviteRow> createState() => _CopyInviteRowState();
}

class _CopyInviteRowState extends State<_CopyInviteRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = _hover ? c.primary : c.textDim;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onTap(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _hover ? c.hoverOverlay : null,
            borderRadius: const BorderRadius.all(Radius.circular(6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy, size: 12, color: color),
              const SizedBox(width: 2),
              Text('Copy Invite Link',
                  style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A `.group-ctx-member` row: avatar, base nym + suffix (+ "you"), and a role
/// badge (Owner/Mod). Tapping opens the member's menu.
class _MemberTile extends StatefulWidget {
  const _MemberTile({
    required this.colors,
    required this.avatar,
    required this.base,
    required this.suffix,
    required this.isSelf,
    required this.roleBadge,
    required this.onTap,
  });

  final NymColors colors;
  final Widget avatar;
  final String base;
  final String suffix;
  final bool isSelf;
  final String? roleBadge;
  final VoidCallback onTap;

  @override
  State<_MemberTile> createState() => _MemberTileState();
}

class _MemberTileState extends State<_MemberTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // `.group-ctx-member`: padding 7px 16px, gap 10px.
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          color: _hover ? c.hoverOverlay : null,
          child: Row(
            children: [
              widget.avatar,
              const SizedBox(width: 10),
              Expanded(
                child: RichText(
                  overflow: TextOverflow.ellipsis,
                  // `.group-ctx-member-name`: 14px, color `--text` (full green).
                  text: TextSpan(
                    style: TextStyle(color: c.text, fontSize: 14),
                    children: [
                      TextSpan(text: widget.base),
                      // Generic `.nym-suffix`: `--text` @ opacity 0.7, 0.9em,
                      // w100 (no dedicated group-member override).
                      TextSpan(
                        text: widget.suffix,
                        style: TextStyle(
                          color: c.text.withValues(alpha: 0.7),
                          fontSize: 14 * 0.9,
                          fontWeight: FontWeight.w100,
                        ),
                      ),
                      // `.group-ctx-you`: 6px left margin, 11px text-dim.
                      if (widget.isSelf) ...[
                        const WidgetSpan(child: SizedBox(width: 6)),
                        TextSpan(
                          text: 'you',
                          style: TextStyle(color: c.textDim, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (widget.roleBadge != null) ...[
                const SizedBox(width: 8),
                _RoleBadge(label: widget.roleBadge!, colors: c),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `.group-ctx-role`: a small chip. Owner = lightning orange `#f7931a` text on
/// `rgba(247,147,26,0.12)`; Mod = `--secondary` text on `rgba(255,255,255,0.08)`.
/// 10px/w600 uppercase, 0.03em tracking, padding 2px 7px, radius 10, no border.
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.colors});
  final String label;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final isOwner = label == 'Owner';
    final Color fg = isOwner ? c.lightning : c.secondary;
    // Owner chip: lightning on rgba(247,147,26,0.12). Mod chip: secondary on a
    // subtle fill (white@0.08 dark; mode-aware so it stays visible in light).
    final Color bg = isOwner
        ? const Color(0x1FF7931A) // rgba(247,147,26,0.12)
        : c.hoverOverlay;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3, // 0.03em ≈ 0.3px at 10px
        ),
      ),
    );
  }
}

/// The Add-Members recipient picker (PWA `openAddMembersModal` → New PM modal in
/// add-members mode). Accepts nym / hex pubkey / npub tokens, resolving each
/// against the user directory into chips, and returns the picked pubkeys (or
/// null on cancel). Existing members are excluded.
class _AddMembersDialog extends ConsumerStatefulWidget {
  const _AddMembersDialog({required this.group});

  final Group group;

  static Future<List<String>?> show(BuildContext context, Group group) {
    return showDialog<List<String>>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _AddMembersDialog(group: group),
    );
  }

  @override
  ConsumerState<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends ConsumerState<_AddMembersDialog> {
  final _controller = TextEditingController();
  final List<({String pubkey, String nym})> _picked = [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final users = ref.read(usersProvider);
    final pk = resolveRecipientPubkey(_controller.text, users);
    if (pk == null) return;
    final self = ref.read(appStateProvider).selfPubkey;
    if (pk == self || widget.group.members.contains(pk)) {
      _controller.clear();
      setState(() {});
      return;
    }
    if (_picked.any((r) => r.pubkey == pk)) {
      _controller.clear();
      setState(() {});
      return;
    }
    final nym = stripPubkeySuffix(users[pk]?.nym ?? 'nym');
    setState(() {
      _picked.add((pubkey: pk, nym: nym));
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                    child: Text('Add Members',
                        style: TextStyle(
                            color: c.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_picked.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final r in _picked)
                                  _RecipientChip(
                                    nym: r.nym,
                                    onRemove: () => setState(() => _picked
                                        .removeWhere(
                                            (x) => x.pubkey == r.pubkey)),
                                  ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                style:
                                    TextStyle(color: c.text, fontSize: 14),
                                onSubmitted: (_) => _add(),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: 'nym, pubkey, or npub',
                                  hintStyle: TextStyle(color: c.textDim),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 11),
                                  filled: true,
                                  // `body.light-mode input` → black@0.04 fill.
                                  fillColor: c.insetFill,
                                  border: OutlineInputBorder(
                                    borderRadius: NymRadius.rxs,
                                    borderSide:
                                        BorderSide(color: c.glassBorder),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: NymRadius.rxs,
                                    borderSide:
                                        BorderSide(color: c.glassBorder),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: NymRadius.rxs,
                                    borderSide:
                                        BorderSide(color: c.primaryA(0.3)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _add,
                              child: Text('Add',
                                  style: TextStyle(color: c.primary)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text('Cancel',
                              style: TextStyle(color: c.textDim)),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: c.primary,
                            foregroundColor: c.bg,
                          ),
                          onPressed: _picked.isEmpty
                              ? null
                              : () => Navigator.of(context).pop(
                                  _picked.map((r) => r.pubkey).toList()),
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A picked-recipient chip: nym pill with a remove button.
class _RecipientChip extends StatelessWidget {
  const _RecipientChip({required this.nym, required this.onRemove});
  final String nym;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.primaryA(0.12),
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        border: Border.all(color: c.primaryA(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(nym, style: TextStyle(color: c.text, fontSize: 13)),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            // Member-pick chip remove — a literal "✕" char in the PWA.
            child: Text('✕',
                style: TextStyle(color: c.textDim, fontSize: 14, height: 1)),
          ),
        ],
      ),
    );
  }
}
