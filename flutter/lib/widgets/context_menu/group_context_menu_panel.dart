import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/chat_tools/chat_tools_ui.dart';
import '../../features/groups/group_logic.dart';
import '../../features/group_tools/group_tools_providers.dart';
import '../../features/group_tools/group_tools_ui.dart';
import '../../features/i18n/i18n.dart';
import '../../features/share/share_links.dart' show groupInviteLink;
import '../../features/share/share_sheet.dart';
import '../../features/pms/new_pm_modal.dart' show resolveRecipientPubkey;
import '../../features/settings/settings_widgets.dart' show SettingsToggleRow;
import '../../features/toasts/toast_center.dart';
import '../../models/group.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/app_dialog.dart';
import '../common/nym_label.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'context_menu_actions.dart';
import '../../features/layout/info_dock.dart';
import '../../features/layout/layout_model.dart';
import 'context_menu_panel.dart';
import 'menu_layer.dart';
import '../common/nym_action_sheet.dart';
import '../common/nym_sheet.dart';
import '../common/nym_field.dart';
import '../common/nym_tooltip.dart';
import '../common/hit_slop.dart';
import '../common/dialog_button.dart';
import '../../core/theme/nym_a11y.dart';
import '../../features/media_notes/profile_image.dart';

/// Right-side group context-menu panel: header, role-gated owner/member controls, invite link, and member list.
class GroupContextMenuPanel extends ConsumerStatefulWidget {
  const GroupContextMenuPanel({
    super.key,
    required this.groupId,
    required this.animation,
    required this.onClose,
    this.onDismiss,
    this.docked = false,
  });

  final String groupId;
  final Animation<double> animation;
  final VoidCallback onClose;
  final VoidCallback? onDismiss;
  final bool docked;

  static Future<void> show(BuildContext context, String groupId) {
    if (InfoDock.tryDock(context, DockedInfo.group(groupId))) {
      return Future<void>.value();
    }
    final page = MediaQuery.sizeOf(context).width <= kPhoneMax;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr('group context menu'),
      barrierColor: page ? Colors.transparent : const Color(0x99000000),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (ctx, anim, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, _) => Align(
        alignment: Alignment.centerRight,
        child: GroupContextMenuPanel(
          groupId: groupId,
          animation: anim,
          onClose: () => closeMenuRoute(ctx),
        ),
      ),
    );
  }

  @override
  ConsumerState<GroupContextMenuPanel> createState() =>
      _GroupContextMenuPanelState();
}

class _GroupContextMenuPanelState extends ConsumerState<GroupContextMenuPanel> {
  /// While on, member taps pick the new owner instead of opening the user menu.
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
            child: Text(tr('Group unavailable'),
                style: TextStyle(color: c.textDim, fontSize: 13)),
          )
        : _content(c, s, group);

    final screenW = MediaQuery.of(context).size.width;
    final page = !widget.docked && screenW <= kPhoneMax;
    final panelW = widget.docked
        ? kDockWidth.toDouble()
        : page
            ? screenW
            : (screenW * 0.85).clamp(0.0, 320.0);

    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(
              CurvedAnimation(parent: widget.animation, curve: Curves.linear)),
      child: SizedBox(
        width: panelW,
        height: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            color: page ? c.bg : c.glassBg,
            border: page ? null : Border(left: BorderSide(color: c.glassBorder)),
            boxShadow: widget.docked || page
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x66000000),
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
              // Offset by the status-bar inset, or the ✕ sits under the status bar and can't be tapped.
              Positioned(
                top: MediaQuery.of(context).padding.top + 14,
                right: 14,
                child: CtxCloseButton(onTap: widget.onDismiss ?? widget.onClose),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(NymColors c, AppState s, Group group) {
    final self = s.selfPubkey;
    final iAmOwner = group.createdBy == self;
    final iCanAdminister = GroupLogic.canAdminister(group, self);
    final iCanModerate = GroupLogic.canModerate(group, self);

    final sorted = (iCanModerate
        ? List<String>.of(group.members)
        : s.groupVisibleMembers(group))
      ..sort((a, b) => _roleRank(group, a).compareTo(_roleRank(group, b)));

    final description = s.groupDescription(group).trim();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(c, group),
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
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: c.hairline),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _actionRows(c, group, iAmOwner, iCanAdminister),
            ),
          ),
          if (_transferMode) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: c.hairline),
                ),
              ),
              child: Text(
                tr('Select a member to make owner').toUpperCase(),
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 12,
                  letterSpacing: 0.48,
                ),
              ),
            ),
            for (final pk in sorted)
              if (pk != self) _memberRow(c, group, pk, self, iCanModerate),
          ] else
            ..._memberSections(c, group, sorted, self, iCanModerate),
          if (!_transferMode && iCanModerate && group.banned.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.hairline)),
              ),
              child: Text(
                tr('Banned · {count}', {'count': group.banned.length})
                    .toUpperCase(),
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 12,
                  letterSpacing: 0.48,
                ),
              ),
            ),
            for (final pk in group.banned) _bannedRow(c, group, pk),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _header(NymColors c, Group group) {
    final app = ref.read(appStateProvider);
    final bannerUrl = proxiedAvatarUrl(app.groupBanner(group));
    final hasBanner = bannerUrl != null && bannerUrl.isNotEmpty;
    final avatarUrl = proxiedAvatarUrl(app.groupAvatar(group));

    // The PWA group menu always has a banner: the custom image, else a default gradient.
    final icon = SizedBox(
      width: 64,
      height: 64,
      child: (avatarUrl != null && avatarUrl.isNotEmpty)
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: avatarUrl,
                fit: BoxFit.cover,
                memCacheWidth:
                    (64 * MediaQuery.devicePixelRatioOf(context) * 1.5).ceil(),
                errorWidget: (_, _, _) => _defaultGroupIcon(c),
              ),
            )
          : _defaultGroupIcon(c),
    );

    final banner = SizedBox(
      height: 140,
      width: double.infinity,
      child: hasBanner
          ? CachedNetworkImage(
              imageUrl: bannerUrl,
              fit: BoxFit.cover,
              // Group banners are user photos; decode at the menu-width strip.
              memCacheWidth:
                  (480 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              errorWidget: (_, _, _) => _defaultBanner(c),
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
          Text(
            ref.read(appStateProvider).groupLabel(group),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.secondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            tr('{n}/{max} members', {'n': group.members.length, 'max': kMaxGroupMembers}) +
                (group.members.length >= kMaxGroupMembers ? ' · ${tr('Full')}' : ''),
            style: TextStyle(
              color: group.members.length >= kMaxGroupMembers ? c.warning : c.textDim,
              fontSize: 12,
            ),
          ),
          ..._inviteLinkRows(c, group),
        ],
      ),
    );

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

  Color _bannerRing(NymColors c) =>
      c.isLight ? const Color(0xF2FFFFFF) : const Color(0xF2141423);

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

  /// Shown only when self can add members and invite links are enabled.
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
        full: group.members.length >= kMaxGroupMembers,
        onTap: () async {
          await ref.read(groupToolsProvider).ensureSummary(group.id);
          if (!mounted) return;
          final fresh = _buildInviteLink(group, self) ?? link;
          await Clipboard.setData(ClipboardData(text: fresh));
          showToast(tr('Copied group invite link to clipboard'));
          widget.onClose();
        },
      ),
    ];
  }

  String? _buildInviteLink(Group group, String self) => groupInviteLink(
      group, self, ref.read(groupToolsProvider).cachedSummary(group.id));

  void _shareGroup(Group group) {
    final nav = Navigator.of(context, rootNavigator: true);
    widget.onClose();
    unawaited(ShareSheet.openGroup(nav.context, group.id));
  }

  Widget _defaultGroupIcon(NymColors c) {
    // Transparent so the banner ring's dark disc shows behind the glyph.
    return Container(
      alignment: Alignment.center,
      child: NymSvgIcon(NymIcons.groupGlyph, size: 34, color: c.primary),
    );
  }

  List<Widget> _actionRows(
      NymColors c, Group group, bool iAmOwner, bool iCanAdminister) {
    final self = ref.read(appStateProvider).selfPubkey;
    final canAdd = group.canAddMembers(self);
    final rows = <Widget>[];

    rows.add(_ActionRow(
      svg: NymIcons.shareNodes,
      label: tr('Share group'),
      color: c.text,
      onTap: () => _shareGroup(group),
    ));

    if (iCanAdminister) {
      rows.add(_ActionRow(
        svg: NymIcons.ctxEdit,
        label: tr('Edit Group Name'),
        color: c.text,
        onTap: () => _editName(group),
      ));
      rows.add(_ActionRow(
        svg: NymIcons.groupEditDescription,
        label: tr('Edit Description'),
        color: c.text,
        onTap: () => _editDescription(group),
      ));
      rows.add(_ActionRow(
        svg: NymIcons.groupChangeAvatar,
        label: tr('Change Avatar'),
        color: c.text,
        onTap: () => _changeImage(group, avatar: true),
      ));
      if ((group.avatar ?? '').isNotEmpty) {
        rows.add(_ActionRow(
          svg: NymIcons.groupRemoveAvatar,
          label: tr('Remove Avatar'),
          color: c.text,
          onTap: () => _removeImage(group, avatar: true),
        ));
      }
      rows.add(_ActionRow(
        svg: NymIcons.groupChangeBanner,
        label: tr('Change Banner'),
        color: c.text,
        onTap: () => _changeImage(group, avatar: false),
      ));
      if ((group.banner ?? '').isNotEmpty) {
        rows.add(_ActionRow(
          svg: NymIcons.groupRemoveBanner,
          label: tr('Remove Banner'),
          color: c.text,
          onTap: () => _removeImage(group, avatar: false),
        ));
      }
    }

    if (iAmOwner && group.members.length > 1) {
      rows.add(_ActionRow(
        svg: NymIcons.ctxTransferOwner,
        label: tr('Transfer Ownership'),
        color: c.text,
        onTap: () => setState(() => _transferMode = true),
      ));
    }

    if (iCanAdminister) {
      rows.add(_switchRow(
        'inviteEnabled',
        tr('Allow joining via invite link'),
        group.inviteEnabled,
        (_) => _toggleInviteJoin(group),
      ));
      // Reset Invite Link shows only when invite joining is on.
      if (group.inviteEnabled) {
        rows.add(_ActionRow(
          svg: NymIcons.groupResetInvite,
          label: tr('Reset Invite Link'),
          color: c.text,
          onTap: () => _resetInviteLink(group),
        ));
      }
    }

    if (iCanAdminister) {
      rows.add(_switchRow(
        'allowMemberInvites',
        tr('Allow members to add others'),
        group.allowMemberInvites,
        (_) => _toggleAllowInvites(group),
      ));
      rows.add(_switchRow(
        'shareHistory',
        tr('Share history with new members'),
        group.shareHistory,
        (_) => _toggleShareHistory(group),
      ));
    }

    // Owner, or any member when member invites are allowed.
    if (canAdd) {
      rows.add(_ActionRow(
        svg: NymIcons.groupAddMembers,
        label: tr('Add Members'),
        color: c.text,
        onTap: () => _addMembers(group),
      ));
    }

    for (final item in gtGroupMenuItems(ref, group)) {
      final toggled = item.toggled;
      final toggleKey = item.toggleKey;
      if (toggled != null && toggleKey != null) {
        rows.add(KeyedSubtree(
          key: ValueKey(item.key),
          child: _switchRow(
            toggleKey,
            item.label,
            toggled,
            item.disabled
                ? null
                : (_) => item.onTap(
                    Navigator.of(context, rootNavigator: true).context),
            tooltip: item.disabledReason,
          ),
        ));
        continue;
      }
      rows.add(_ActionRow(
        key: ValueKey(item.key),
        svg: item.svg,
        label: item.label,
        trailing: item.trailing,
        color: item.disabled ? c.textDim : c.text,
        onTap: () {
          final rootContext = Navigator.of(context, rootNavigator: true).context;
          final sheet = item.openSheet;
          if (sheet != null) {
            openOverMenu(widget.onClose, () => sheet(rootContext));
            return;
          }
          widget.onClose();
          if (rootContext.mounted) item.onTap(rootContext);
        },
      ));
    }

    rows.add(_ActionRow(
      svg: ChatToolIcons.media,
      label: tr('Media, files & links'),
      color: c.text,
      onTap: () => _openChatTool(group, media: true),
    ));
    rows.add(_ActionRow(
      svg: ChatToolIcons.exportChat,
      label: tr('Export chat'),
      color: c.text,
      onTap: () => _openChatTool(group, media: false),
    ));

    rows.add(_ActionRow(
      svg: NymIcons.groupLeave,
      label: tr('Leave Group'),
      color: c.danger,
      onTap: () => _leaveGroup(group),
    ));

    return rows;
  }

  Future<void> _editName(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final name = await showAppPrompt(
      context,
      tr('Enter a new group name:'),
      title: tr('Rename Group'),
      okLabel: tr('Save'),
      defaultValue: ref.read(appStateProvider).groupLabel(group, '') == group.name
          ? group.name
          : '',
      maxLength: 40,
    );
    if (name == null) return;
    widget.onClose();
    await controller.updateGroupMetadata(group.id, name: name);
  }

  Future<void> _editDescription(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final desc = await showAppPrompt(
      context,
      tr('Enter a group description:'),
      title: tr('Group Description'),
      okLabel: tr('Save'),
      defaultValue: ref.read(appStateProvider).groupDescription(group),
      maxLength: 150,
      multiline: true,
    );
    if (desc == null) return;
    widget.onClose();
    await controller.updateGroupMetadata(group.id, description: desc);
  }

  Future<void> _changeImage(Group group, {required bool avatar}) async {
    final controller = ref.read(nostrControllerProvider);
    Uint8List? bytes;
    String contentType = 'image/jpeg';
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null) return;
      bytes = await File(file.path).readAsBytes();
      contentType = profileImageContentType(bytes,
          path: file.path, declared: file.mimeType ?? '');
    } catch (_) {
      // Picker unavailable (tests/desktop).
      return;
    }
    final cap = profileImageMaxBytes(avatar: avatar);
    if (bytes.length > cap) {
      if (!mounted) return;
      await showAppAlert(
        context,
        tr('{label} must be under {cap}MB (this image is {actual}MB).', {
          'label': avatar ? tr('Avatar') : tr('Banner'),
          'cap': cap ~/ (1024 * 1024),
          'actual': (bytes.length / (1024 * 1024)).toStringAsFixed(1),
        }),
      );
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

  Future<void> _removeImage(Group group, {required bool avatar}) async {
    final controller = ref.read(nostrControllerProvider);
    if (avatar) {
      await controller.updateGroupMetadata(group.id, avatar: '');
    } else {
      await controller.updateGroupMetadata(group.id, banner: '');
    }
  }

  Widget _switchRow(
    String key,
    String label,
    bool value,
    ValueChanged<bool>? onChanged, {
    String? tooltip,
  }) =>
      SettingsToggleRow(
        key: ValueKey('panel-group.$key'),
        label: label,
        value: value,
        spacing: 0,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        tooltip: tooltip,
        onChanged: onChanged,
      );

  Future<void> _toggleAllowInvites(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    await controller.setGroupAllowInvites(group.id, !group.allowMemberInvites);
  }

  Future<void> _toggleShareHistory(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    await controller.setGroupShareHistory(group.id, !group.shareHistory);
  }

  Future<void> _toggleInviteJoin(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    await controller.setGroupInviteEnabled(group.id, !group.inviteEnabled);
  }

  /// Rotates the invite epoch so previously shared links stop working.
  Future<void> _resetInviteLink(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final ok = await showAppConfirm(
      context,
      tr('Reset the invite link? Every link shared so far will stop working.'),
      title: tr('Reset Invite Link'),
      okLabel: tr('Reset'),
      danger: true,
    );
    if (!ok) return;
    widget.onClose();
    await controller.rotateGroupInviteEpoch(group.id);
  }

  Future<void> _addMembers(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final picked = await _AddMembersDialog.show(context, group);
    if (picked == null || picked.isEmpty) return;
    widget.onClose();
    await controller.addGroupMembers(group.id, picked);
  }

  Future<void> _openChatTool(Group group, {required bool media}) async {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    final key = 'group-${group.id}';
    await openOverMenu(
      widget.onClose,
      () => media
          ? ChatMediaPanel.open(rootContext, key)
          : ExportChatPanel.open(rootContext, key),
    );
  }

  /// Closes the panel first so it isn't left over the departed group.
  Future<void> _leaveGroup(Group group) async {
    final controller = ref.read(nostrControllerProvider);
    final shown = ref.read(appStateProvider).groupLabel(group, '');
    final name = shown.isEmpty ? tr('this group') : '"$shown"';
    final ok = await showAppConfirm(
      context,
      tr("Leave {name}? You'll stop receiving messages from this group.",
          {'name': name}),
      title: tr('Leave Group'),
      okLabel: tr('Leave'),
      danger: true,
    );
    if (!ok) return;
    widget.onClose();
    await controller.leaveGroup(group.id);
  }


  int _roleRank(Group group, String pubkey) =>
      GroupLogic.roleRank(group, pubkey);

  Widget _bannedRow(NymColors c, Group group, String pubkey) {
    final mask = ref.watch(appStateProvider).personMaskLabel(pubkey);
    final user = mask.isNotEmpty ? null : ref.watch(usersProvider)[pubkey];
    final base = mask.isNotEmpty ? mask : stripPubkeySuffix(user?.nym ?? '');
    return _MemberTile(
      colors: c,
      avatar: NymAvatar(
        seed: pubkey,
        size: 30,
        imageUrl: user?.profile?.picture,
        label: mask.isEmpty && base.isNotEmpty ? base[0] : null,
      ),
      base: base.isEmpty ? tr('(unknown)') : base,
      suffix: '#${getPubkeySuffix(pubkey)}',
      isSelf: false,
      dimmed: true,
      trailing: _UnbanButton(
        colors: c,
        onTap: () => unawaited(ref
            .read(nostrControllerProvider)
            .unbanFromGroup(group.id, pubkey)),
      ),
      onTap: null,
    );
  }

  List<Widget> _memberSections(NymColors c, Group group, List<String> sorted,
      String self, bool canModerate) {
    String roleOf(String pk) {
      if (group.createdBy == pk) return 'owner';
      if (group.admins.contains(pk)) return 'admin';
      if (group.mods.contains(pk)) return 'mod';
      return 'member';
    }

    const titles = {
      'owner': 'Owner',
      'admins': 'Admins',
      'mods': 'Mods',
      'members': 'Members',
    };
    final out = <Widget>[];
    final sections = memberSections([for (final pk in sorted) roleOf(pk)]);
    for (var i = 0; i < sections.length; i++) {
      final sec = sections[i];
      out.add(Container(
        key: ValueKey('memberSection-${sec.key}'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(
            NymSpace.s4, NymSpace.s3, NymSpace.s4, NymSpace.s1),
        decoration: i == 0
            ? BoxDecoration(border: Border(top: BorderSide(color: c.hairline)))
            : null,
        child: Text(
          '${tr(titles[sec.key]!)} · ${sec.items.length}'.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: NymType.xs,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.44,
          ),
        ),
      ));
      for (final idx in sec.items) {
        out.add(_memberRow(c, group, sorted[idx], self, canModerate));
      }
    }
    return out;
  }

  Widget _memberRow(NymColors c, Group group, String pubkey, String self,
      [bool canModerate = false]) {
    final mask = pubkey == self
        ? ''
        : ref.watch(appStateProvider).personMaskLabel(pubkey);
    final user = mask.isNotEmpty ? null : ref.watch(usersProvider)[pubkey];
    final base = mask.isNotEmpty ? mask : stripPubkeySuffix(user?.nym ?? '');
    final suffix = getPubkeySuffix(pubkey);
    final isSelf = pubkey == self;
    final isOwner = group.createdBy == pubkey;
    final isAdmin = !isOwner && group.admins.contains(pubkey);
    final isMod = !isOwner && !isAdmin && group.mods.contains(pubkey);

    final presence = mask.isNotEmpty
        ? ''
        : user == null
        ? 'offline'
        : presenceClass(user
            .effectiveStatus(
                isVerifiedBot:
                    ref.read(nostrControllerProvider).isVerifiedBot(pubkey))
            .name);
    final avatar = NymAvatar(
      seed: pubkey,
      size: 30,
      imageUrl: user?.profile?.picture,
      label: mask.isEmpty && base.isNotEmpty ? base[0] : null,
    );
    return _MemberTile(
      colors: c,
      avatar: presence.isEmpty
          ? avatar
          : Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    key: ValueKey('presence-$presence-$pubkey'),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: presence == 'online'
                          ? const Color(0xFF22C55E)
                          : presence == 'away'
                              ? c.warning
                              : c.textDim,
                      border: Border.all(color: c.bgTertiary, width: 2),
                    ),
                  ),
                ),
              ],
            ),
      trailing: canModerate && !isSelf && !_transferMode
          ? NymTooltip(
              message: tr('Member actions'),
              child: InkWell(
                key: ValueKey('memberMore-$pubkey'),
                borderRadius: NymRadius.rxs,
                onTap: () => _onMemberTap(group, pubkey, base, isSelf),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: Center(
                    child: NymSvgIcon(NymIcons.rowMenu, size: 16, color: c.textDim),
                  ),
                ),
              ),
            )
          : null,
      base: base.isEmpty ? tr('(unknown)') : base,
      suffix: '#$suffix',
      isSelf: isSelf,
      roleBadge:
          isOwner ? 'Owner' : (isAdmin ? 'Admin' : (isMod ? 'Mod' : null)),
      onTap: () => _onMemberTap(group, pubkey, base, isSelf),
    );
  }

  void _onMemberTap(Group group, String pubkey, String base, bool isSelf) {
    if (_transferMode) {
      // Confirm runs on this still-mounted panel; only on confirm do we pop and transfer, so `ref` stays valid.
      setState(() => _transferMode = false);
      _confirmTransfer(group.id, pubkey, base);
      return;
    }
    // Open the member's menu with this group as back target; capture the root navigator before popping.
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
    final ok = await showAppConfirm(
      context,
      tr('Transfer group ownership to {name}? You will lose owner privileges.',
          {'name': base}),
      okLabel: tr('Transfer'),
      danger: true,
    );
    if (ok) {
      // The captured controller is safe even after this panel disposes.
      widget.onClose();
      await controller.transferOwner(groupId, pubkey);
    }
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({
    super.key,
    required this.svg,
    required this.label,
    required this.color,
    required this.onTap,
    this.trailing,
  });
  final String svg;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final String? trailing;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isNeutral = widget.color == c.text;
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
          constraints: context.largeTouchTargets
              ? const BoxConstraints(minHeight: kMinTouchTarget)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _hover
                ? (widget.color == c.danger
                    ? c.dangerHoverOverlay
                    : c.hoverOverlay)
                : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            children: [
              NymSvgIcon(widget.svg, size: 16, color: iconColor),
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
              if (widget.trailing != null) ...[
                const SizedBox(width: 12),
                Text(widget.trailing!,
                    style: TextStyle(color: c.textDim, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyInviteRow extends StatefulWidget {
  const _CopyInviteRow({required this.onTap, this.full = false});
  final Future<void> Function() onTap;
  final bool full;

  @override
  State<_CopyInviteRow> createState() => _CopyInviteRowState();
}

class _CopyInviteRowState extends State<_CopyInviteRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    if (widget.full) {
      return Padding(
        key: const ValueKey('groupInviteFull'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(tr('Group is full'),
            style: TextStyle(color: c.warning, fontSize: 11)),
      );
    }
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
              NymSvgIcon(NymIcons.ctxCopy, size: 12, color: color),
              const SizedBox(width: 4),
              Text(tr('Copy Invite Link'),
                  style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnbanButton extends StatelessWidget {
  const _UnbanButton({required this.colors, required this.onTap});

  final NymColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: const BorderRadius.all(Radius.circular(10)),
        ),
        child: Text(
          tr('Unban'),
          style: TextStyle(
            color: c.primary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MemberTile extends StatefulWidget {
  const _MemberTile({
    required this.colors,
    required this.avatar,
    required this.base,
    required this.suffix,
    required this.isSelf,
    this.roleBadge,
    this.trailing,
    this.dimmed = false,
    required this.onTap,
  });

  final NymColors colors;
  final Widget avatar;
  final String base;
  final String suffix;
  final bool isSelf;
  final String? roleBadge;
  final Widget? trailing;
  final bool dimmed;
  final VoidCallback? onTap;

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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          color: _hover ? c.hoverOverlay : null,
          child: Row(
            children: [
              widget.avatar,
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: NymLabel(
                        widget.base,
                        suffix: widget.suffix,
                        style: TextStyle(
                            color: widget.dimmed ? c.textDim : c.text,
                            fontSize: 14),
                      ),
                    ),
                    if (widget.isSelf) ...[
                      const SizedBox(width: 6),
                      Text(
                        tr('you'),
                        style: TextStyle(color: c.textDim, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.roleBadge != null) ...[
                const SizedBox(width: 8),
                _RoleBadge(label: widget.roleBadge!, colors: c),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.colors});
  final String label;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final isOwner = label == 'Owner';
    final isAdmin = label == 'Admin';
    final Color fg =
        isOwner ? c.lightning : (isAdmin ? c.primary : c.secondary);
    final Color bg = isOwner
        ? const Color(0x1FF7931A)
        : (isAdmin ? c.primary.withValues(alpha: 0.12) : c.hoverOverlay);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: Text(
        tr(label).toUpperCase(),
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3, // 0.03em at 10px.
        ),
      ),
    );
  }
}

/// Add-Members picker resolving nym/hex/npub tokens to pubkeys, excluding existing members; null on cancel.
class _AddMembersDialog extends ConsumerStatefulWidget {
  const _AddMembersDialog({required this.group});

  final Group group;

  static Future<List<String>?> show(BuildContext context, Group group) {
    return showNymSheet<List<String>>(
      context,
      (_) => _AddMembersDialog(group: group),
      barrierColor: Colors.black.withValues(alpha: 0.7),
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

  int get _spotsLeft {
    final left =
        kMaxGroupMembers - widget.group.members.length - _picked.length;
    return left > 0 ? left : 0;
  }

  void _add() {
    if (_spotsLeft <= 0) return;
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
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Text(tr('Add Members'),
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
                          onRemove: () => setState(() =>
                              _picked.removeWhere(
                                  (x) => x.pubkey == r.pubkey)),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  tr('{n} spots left', {'n': '$_spotsLeft'}),
                  key: const ValueKey('addMembersSpotsLeft'),
                  style: TextStyle(
                    color: _spotsLeft > 0 ? c.textDim : c.warning,
                    fontSize: 12,
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: _spotsLeft > 0,
                      style: TextStyle(color: c.inputText, fontSize: 14),
                      onSubmitted: (_) => _add(),
                      decoration: NymField.decoration(c,
                        hint: tr('nym, pubkey, or npub'),
                        radius: NymRadius.rxs,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 11)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _spotsLeft > 0 ? _add : null,
                    child: Text(tr('Add'),
                        style: TextStyle(color: c.primary)),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
          child: DialogActions(
            alignment: WrapAlignment.end,
            children: [
              DialogButton.secondary(
                label: tr('Cancel'),
                onTap: () => Navigator.of(context).pop(),
              ),
              DialogButton(
                label: tr('Add'),
                onTap: _picked.isEmpty
                    ? null
                    : () => Navigator.of(context)
                        .pop(_picked.map((r) => r.pubkey).toList()),
              ),
            ],
          ),
        ),
      ],
    );
    return NymDiscardGuard(
      isDirty: () => _picked.isNotEmpty || _controller.text.trim().isNotEmpty,
      child: nymSheetOr(
        context,
        SingleChildScrollView(child: body),
        (body) => Center(
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
                  child: body,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
            child: Icon(Icons.close, size: 14, color: c.textDim),
          ),
        ],
      ),
    );
  }
}


Future<T?> showGroupMenuSheet<T>(
  BuildContext context,
  String groupId,
  List<NymActionEntry<T>> entries, {
  String label = 'Conversation menu',
}) {
  return showNymActionSheet<T>(
    context,
    entries,
    label: label,
    header: GroupSheetHeader(groupId: groupId),
    expandable: true,
    rowBuilder: (ctx, e, pick) {
      final c = ctx.nym;
      return CtxSheetActionRow(
        key: e.key,
        svg: e.svg,
        label: e.label,
        color: !e.enabled
            ? c.textDim
            : e.danger
                ? c.danger
                : c.text,
        onTap: e.enabled ? pick : () {},
      );
    },
  );
}

class GroupSheetHeader extends ConsumerWidget {
  const GroupSheetHeader({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    Group? group;
    for (final g in ref.watch(appStateProvider).groups) {
      if (g.id == groupId) group = g;
    }
    if (group == null) return const SizedBox.shrink();
    final avatarUrl =
        proxiedAvatarUrl(ref.watch(appStateProvider).groupAvatar(group));
    final glyph = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.06),
      ),
      child: NymSvgIcon(NymIcons.groupGlyph, size: 34, color: c.primary),
    );
    final icon = SizedBox(
      width: 64,
      height: 64,
      child: (avatarUrl != null && avatarUrl.isNotEmpty)
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: avatarUrl,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => glyph,
              ),
            )
          : glyph,
    );
    final count = group.members.length;
    final labels = ref.read(appStateProvider);
    final description = labels.groupDescription(group).trim();
    return Column(
      key: const ValueKey('groupSheetHeader'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.hairline)),
          ),
          child: Column(
            children: [
              icon,
              const SizedBox(height: 6),
              Text(
                labels.groupLabel(group),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.secondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                tr('{n}/{max} members', {'n': count, 'max': kMaxGroupMembers}) +
                    (count >= kMaxGroupMembers ? ' · ${tr('Full')}' : ''),
                style: TextStyle(
                  color: count >= kMaxGroupMembers ? c.warning : c.textDim,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        if (description.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.hairline)),
            ),
            child: Text(
              description,
              style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
            ),
          ),
        const SizedBox(height: 6),
      ],
    );
  }
}
