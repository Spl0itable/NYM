import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/crypto/key_format.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/chat_tools/chat_tools_providers.dart';
import '../../features/chat_tools/chat_tools_ui.dart';
import '../../features/i18n/i18n.dart';
import '../../features/mesh/mesh_controller.dart';
import '../../features/messages/inline_network_image.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'context_menu_actions.dart';
import 'group_context_menu_panel.dart';
import 'interaction_hooks.dart';
import 'profile_badges.dart';
import 'report_modal.dart';

/// Right-side profile context-menu panel: avatar header then the actions from [buildContextMenuActions].
class ContextMenuPanel extends ConsumerWidget {
  const ContextMenuPanel({
    super.key,
    required this.target,
    required this.animation,
    required this.onClose,
    this.message,
    this.onReact,
    this.onTranslateInline,
    this.backToGroupId,
  });

  final CtxTarget target;
  final Animation<double> animation;
  final VoidCallback onClose;

  /// When set (or on [target]), a back chevron returns to that group's context menu.
  final String? backToGroupId;

  /// Used to infer the kind for reactions and zaps.
  final Message? message;

  final VoidCallback? onReact;

  /// Receives the chosen target language code, or null for the default.
  final ValueChanged<String?>? onTranslateInline;

  static Future<void> show(
    BuildContext context, {
    required CtxTarget target,
    Message? message,
    VoidCallback? onReact,
    ValueChanged<String?>? onTranslateInline,
    String? backToGroupId,
  }) {
    final backGroup = backToGroupId ?? target.backToGroupId;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr('context menu'),
      barrierColor: const Color(0x99000000),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (ctx, anim, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, _) {
        return Consumer(
          builder: (ctx, ref, _) => Align(
            alignment: Alignment.centerRight,
            child: ContextMenuPanel(
              target: target,
              message: message,
              animation: anim,
              onReact: onReact,
              onTranslateInline: onTranslateInline,
              backToGroupId: backGroup,
              onClose: () => Navigator.of(ctx).maybePop(),
            ),
          ),
        );
      },
    );
  }

  /// Re-derives live friend/block/group-role flags so callers need not thread them through.
  CtxTarget _enrichTarget(WidgetRef ref) {
    final s = ref.read(appStateProvider);
    final self = s.selfPubkey;
    final inGroup = s.view.kind == ViewKind.group;
    final group = inGroup ? _groupById(s, s.view.id) : null;
    final iAmOwner = group != null && group.createdBy == self;
    final iAmAdmin = group != null && group.admins.contains(self);
    final iAmMod = group != null && group.mods.contains(self);
    final targetIsMember =
        group != null && group.members.contains(target.pubkey);
    final targetIsOwner = group != null && group.createdBy == target.pubkey;
    final targetIsAdmin = group != null && group.admins.contains(target.pubkey);
    final targetIsMod = group != null && group.mods.contains(target.pubkey);
    return CtxTarget(
      pubkey: target.pubkey,
      nym: pickDisplayNym(s.users[target.pubkey]?.nym, target.nym),
      isSelf: target.isSelf,
      content: target.content,
      messageId: target.messageId,
      profileOnly: target.profileOnly,
      isFriend: s.isFriend(target.pubkey),
      isBlocked: s.isUserBlocked(target.pubkey),
      isBot: target.isBot,
      inGroup: inGroup,
      iAmOwner: iAmOwner,
      iAmAdmin: iAmAdmin,
      iAmMod: iAmMod,
      targetIsMember: targetIsMember,
      targetIsOwner: targetIsOwner,
      targetIsAdmin: targetIsAdmin,
      targetIsMod: targetIsMod,
      backToGroupId: target.backToGroupId,
    );
  }

  Group? _groupById(AppState s, String id) {
    for (final g in s.groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    final target = _enrichTarget(ref);
    final actions = buildContextMenuActions(target);
    final tools = _chatTools(ref, target);
    var toolsAt = actions.length;
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].index > CtxAction.copyMessage.index) {
        toolsAt = i;
        break;
      }
    }
    final fullNym = '${target.nym}#${getPubkeySuffix(target.pubkey)}';
    final cosmetics = ref.watch(userCosmeticsProvider(target.pubkey));
    final user = ref.watch(usersProvider)[target.pubkey];
    final about = user?.profile?.about ?? '';
    // A mesh peer's presence is "Mesh" (Bluetooth), not a Nostr status.
    final isMeshPeer = ref.watch(meshControllerProvider
        .select((s) => s.meshPmPubkeys.contains(target.pubkey)));

    final panel = Material(
      // The opaque bg is painted on the full-height Container below; this Material only provides ink.
      type: MaterialType.transparency,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(
                context,
                c,
                target,
                fullNym,
                cosmetics,
                user,
                controller,
                () => ref
                    .read(appStateProvider.notifier)
                    .addSystemMessage(tr('Copied pubkey to clipboard')),
                isMeshPeer,
              ),
              if (about.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: c.hairline),
                    ),
                  ),
                  child: Text(
                    about,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 13,
                      height: 1.5,
                    ),
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
                  children: [
                    for (var i = 0; i <= actions.length; i++) ...[
                      if (i == toolsAt)
                        for (final t in tools.actions)
                          _ActionItem(
                            key: ValueKey('chat-tool-${t.name}'),
                            svg: chatToolSvg(t),
                            label: chatToolLabel(t),
                            color: c.text,
                            onTap: () => _invokeTool(context, ref, t, tools),
                          ),
                      if (i < actions.length)
                        _ActionItem(
                          svg: ctxActionSvg(actions[i]),
                          label: ctxActionLabel(actions[i], target),
                          color: _colorFor(actions[i], c),
                          onTap: () =>
                              _invoke(context, ref, actions[i], target, fullNym),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Width 320, clamped to 85% of narrow screens.
    final screenW = MediaQuery.of(context).size.width;
    final panelW = math.min(320.0, screenW * 0.85);

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.linear)),
      child: SizedBox(
        width: panelW,
        height: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            color: c.glassBg,
            border: Border(left: BorderSide(color: c.glassBorder)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 24,
                offset: Offset(-4, 0),
              ),
            ],
          ),
          child: Stack(
            children: [
              panel,
              // Floating buttons are offset by the status-bar inset, since this Stack spans the full screen.
              if (backToGroupId != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  left: 10,
                  child: _BackButton(
                    onTap: () => _onBack(context, backToGroupId!),
                  ),
                ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 14,
                right: 14,
                child: CtxCloseButton(onTap: onClose),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    NymColors c,
    CtxTarget target,
    String fullNym,
    UserCosmetics cosmetics,
    User? user,
    NostrController controller,
    VoidCallback onCopied,
    bool isMeshPeer,
  ) {
    final bannerUrl = proxiedAvatarUrl(user?.profile?.banner);
    final hasBanner = bannerUrl != null && bannerUrl.isNotEmpty;
    final avatarUrl = user?.profile?.picture;
    final status = user?.effectiveStatus() ?? UserStatus.offline;
    final isDeveloper = controller.isVerifiedDeveloper(target.pubkey);
    final isBot = controller.isVerifiedBot(target.pubkey);
    final showFriendBadge = target.isFriend && !target.isSelf;
    // Owner/Mod label only when viewing the target's group.
    final String? ownerModLabel = target.inGroup
        ? (target.targetIsOwner
            ? tr('Group Owner')
            : (target.targetIsMod ? tr('Moderator') : null))
        : null;

    final bannerRing = c.isLight
        ? const Color(0xF2FFFFFF)
        : const Color(0xF2141423);
    final avatar = Container(
      decoration: hasBanner
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.fromBorderSide(
                BorderSide(color: bannerRing, width: 3),
              ),
            )
          : BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.glassBorder, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x2600FFFF),
                  blurRadius: 15,
                ),
              ],
            ),
      // Only a real remote picture expands; the identicon fallback stays inert.
      child: _ExpandableProfileImage(
        imageUrl: proxiedAvatarUrl(avatarUrl),
        onClose: onClose,
        child: NymAvatar(seed: target.pubkey, size: 64, imageUrl: avatarUrl),
      ),
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
          if (!hasBanner) ...[
            avatar,
            const SizedBox(height: 6),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      color: c.secondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    children: [
                      TextSpan(text: target.nym),
                      TextSpan(
                        text: '#${getPubkeySuffix(target.pubkey)}',
                        style: TextStyle(
                          color: c.secondary.withValues(alpha: 0.7),
                          fontSize: 13 * 0.9,
                          fontWeight: FontWeight.w100,
                        ),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              CosmeticNymBadges(
                cosmetics: cosmetics,
                flairSize: 15,
                supporterHeight: 15,
              ),
              if (isDeveloper || isBot) ...[
                const SizedBox(width: 4),
                const VerifiedBadge(size: 20),
              ],
              if (showFriendBadge) ...[
                const SizedBox(width: 3),
                const Opacity(opacity: 0.7, child: FriendBadge(size: 12)),
              ],
            ],
          ),
          if (isDeveloper || isBot)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                isDeveloper ? tr('Nymchat Developer') : tr('Nymchat Bot'),
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          if (ownerModLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                ownerModLabel,
                style: TextStyle(
                  color: c.secondary.withValues(alpha: 0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          if (isMeshPeer) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StatusDot(status: UserStatus.online, size: 8),
                const SizedBox(width: 6),
                Text(
                  tr('Mesh'),
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
              ],
            ),
          ] else if (status != UserStatus.hidden) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StatusDot(status: status, size: 8),
                const SizedBox(width: 6),
                Text(
                  _statusLabel(status),
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          // npub by default with a switch to hex, since bitchat speaks hex only over the mesh.
          _PubkeyBlock(
            pubkey: target.pubkey,
            onCopied: onCopied,
            onClose: onClose,
          ),
        ],
      ),
    );

    if (!hasBanner) return header;

    // Banner with the avatar straddling its bottom edge, hoisted into a Stack so no gap opens below.
    const avatarBox = 70.0; // 64 + 3px ring on each side.
    final bannerHeader = Padding(
      padding: EdgeInsets.only(top: avatarBox - 36),
      child: header,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 140,
              width: double.infinity,
              child: _ExpandableProfileImage(
                imageUrl: bannerUrl,
                onClose: onClose,
                child: isAssetImageUrl(bannerUrl)
                    ? Image.asset(
                        bannerUrl,
                        fit: BoxFit.cover,
                        cacheWidth:
                            (480 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                      )
                    : CachedNetworkImage(
                        imageUrl: bannerUrl,
                        fit: BoxFit.cover,
                        // Banners are often multi-MB; decode at strip width (fullscreen loads its own copy).
                        memCacheWidth:
                            (480 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                      ),
              ),
            ),
            bannerHeader,
          ],
        ),
        Positioned(
          top: 140 - 36,
          left: 0,
          right: 0,
          child: Center(child: avatar),
        ),
      ],
    );
  }

  String _statusLabel(UserStatus status) {
    switch (status) {
      case UserStatus.online:
        return tr('Online');
      case UserStatus.away:
        return tr('Away');
      case UserStatus.offline:
      case UserStatus.hidden:
        return tr('Offline');
    }
  }

  void _onBack(BuildContext context, String groupId) {
    // Capture the root navigator's context before popping; this panel's context is defunct after onClose().
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    onClose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (rootContext.mounted) {
        GroupContextMenuPanel.show(rootContext, groupId);
      }
    });
  }

  Color _colorFor(CtxAction a, NymColors c) {
    switch (a) {
      case CtxAction.report:
        return c.warning;
      case CtxAction.delete:
      case CtxAction.kick:
      case CtxAction.ban:
      case CtxAction.block:
        return c.danger;
      default:
        return c.text;
    }
  }

  Future<void> _invoke(
    BuildContext context,
    WidgetRef ref,
    CtxAction a,
    CtxTarget t,
    String fullNym,
  ) async {
    final controller = ref.read(nostrControllerProvider);
    final hooks = ref.read(pendingComposerActionProvider.notifier);
    // Actions needing the context after an await close the panel themselves; the rest close immediately.
    switch (a) {
      case CtxAction.mention:
        onClose();
        hooks.requestMention(fullNym);
        break;
      case CtxAction.quote:
        onClose();
        if (t.content != null) {
          hooks.requestQuote(fullNym: fullNym, content: t.content!);
        }
        break;
      case CtxAction.privateMessage:
        onClose();
        controller.startPM(t.pubkey, nym: t.nym);
        break;
      case CtxAction.react:
        onClose();
        onReact?.call();
        break;
      case CtxAction.copyMessage:
        onClose();
        if (t.content != null) {
          await Clipboard.setData(ClipboardData(text: t.content!));
        }
        break;
      case CtxAction.translate:
        onClose();
        await _translate(context, ref);
        break;
      case CtxAction.zap:
        onClose();
        await _zap(context, ref);
        break;
      case CtxAction.report:
        onClose();
        if (context.mounted) {
          await ReportModal.show(
            context,
            targetNym: fullNym,
            hasMessage: t.messageId != null,
            // Publishes the NIP-56 kind-1984 report, with an `e` tag when a specific message is reported.
            onSubmit: (type, details, reportMessage) {
              controller.submitReport(
                pubkey: t.pubkey,
                messageId: reportMessage ? t.messageId : null,
                type: type,
                details: details,
              );
            },
          );
        }
        break;
      case CtxAction.friend:
        onClose();
        controller.toggleFriend(t.pubkey);
        break;
      case CtxAction.block:
        onClose();
        controller.toggleBlockUser(t.pubkey);
        break;
      case CtxAction.slap:
        // Sending the `/me …` line through sendCurrent shares the composer's action rate limiter, like `cmdSlap`.
        onClose();
        unawaited(controller.sendCurrent(
            '/me slaps @$fullNym around a bit with a large trout 🐟'));
        break;
      case CtxAction.hug:
        onClose();
        unawaited(controller.sendCurrent('/me gives @$fullNym a warm hug 🫂'));
        break;
      case CtxAction.addToGroup:
        // An empty name lets the groups slice fall back to its default naming.
        onClose();
        unawaited(controller.createGroup('', [t.pubkey]));
        break;
      case CtxAction.giftCredits:
        onClose();
        ref
            .read(giftCreditsRequestProvider.notifier)
            .request(pubkey: t.pubkey, nym: t.nym);
        break;
      case CtxAction.editProfile:
        onClose();
        if (context.mounted) await NickEditModal.open(context);
        break;
      case CtxAction.edit:
        await _edit(context, ref, t);
        break;
      case CtxAction.delete:
        // Own message sends a deletion request; mod/owner uses group mod-delete. Both confirm.
        await _delete(context, ref, t);
        break;
      case CtxAction.makeMod:
        onClose();
        await controller.promoteModerator(_groupId(ref), t.pubkey);
        break;
      case CtxAction.revokeMod:
        onClose();
        await controller.revokeModerator(_groupId(ref), t.pubkey);
        break;
      case CtxAction.makeAdmin:
        onClose();
        await controller.promoteAdmin(_groupId(ref), t.pubkey);
        break;
      case CtxAction.revokeAdmin:
        onClose();
        await controller.revokeAdmin(_groupId(ref), t.pubkey);
        break;
      case CtxAction.transferOwner:
        await _confirmThen(
          context,
          tr('Transfer group ownership to this user? You will lose owner privileges.'),
          okLabel: tr('Transfer'),
          danger: true,
          action: () => controller.transferOwner(_groupId(ref), t.pubkey),
        );
        break;
      case CtxAction.kick:
        onClose();
        await controller.kickFromGroup(_groupId(ref), t.pubkey);
        break;
      case CtxAction.ban:
        await _confirmThen(
          context,
          tr('Ban this user from the group? They cannot be re-invited unless an owner or moderator unbans them.'),
          okLabel: tr('Ban'),
          danger: true,
          action: () => controller.banFromGroup(_groupId(ref), t.pubkey),
        );
        break;
    }
  }

  ({List<ChatToolAction> actions, Message? msg, String? key}) _chatTools(
      WidgetRef ref, CtxTarget target) {
    final s = ref.read(appStateProvider);
    ref.watch(chatToolsRevisionProvider);
    final tools = ref.read(chatToolsProvider);
    final m = message;
    ({Message msg, String key})? found;
    if (m != null && !target.profileOnly) {
      found = findMessageAnywhere(s, m.nymMessageId ?? m.id) ??
          findMessageAnywhere(s, m.id);
    } else if (!target.profileOnly && target.messageId != null) {
      found = findMessageAnywhere(s, target.messageId!);
    }
    final view = s.view;
    final dmHeader = target.profileOnly &&
        m == null &&
        view.kind == ViewKind.pm &&
        view.id == target.pubkey;
    final msg = found?.msg;
    final actions = chatToolActionsFor(
      message: msg,
      storageKey: found?.key,
      self: s.selfPubkey,
      saved: msg != null && tools.isMessageSaved(msg),
      kept: msg != null && tools.isMessageKept(msg),
      keepOffered: msg != null && tools.keepAvailableFor(msg, found!.key),
      dmHeader: dmHeader,
    );
    return (
      actions: actions,
      msg: msg,
      key: dmHeader ? view.storageKey : found?.key,
    );
  }

  Future<void> _invokeTool(BuildContext context, WidgetRef ref,
      ChatToolAction a,
      ({List<ChatToolAction> actions, Message? msg, String? key}) t) async {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    final read = ProviderScope.containerOf(context).read;
    onClose();
    final msg = t.msg;
    final key = t.key;
    switch (a) {
      case ChatToolAction.save:
      case ChatToolAction.unsave:
        if (msg != null) ChatToolsActions.toggleSave(read, msg);
      case ChatToolAction.replyPrivately:
        if (msg != null) ChatToolsActions.replyPrivately(read, msg);
      case ChatToolAction.keep:
      case ChatToolAction.unkeep:
        if (msg != null) await ChatToolsActions.toggleKeep(read, msg);
      case ChatToolAction.media:
        if (key != null && rootContext.mounted) {
          await ChatMediaPanel.open(rootContext, key);
        }
      case ChatToolAction.export:
        if (key != null && rootContext.mounted) {
          await ExportChatPanel.open(rootContext, key);
        }
    }
  }

  String _groupId(WidgetRef ref) {
    final view = ref.read(currentViewProvider);
    return view.kind == ViewKind.group ? view.id : '';
  }

  /// Seeds the composer with the original content and enters pending-edit mode, so the next send publishes the edit.
  Future<void> _edit(BuildContext context, WidgetRef ref, CtxTarget t) async {
    final messageId = t.messageId;
    final content = t.content ?? '';
    if (messageId != null && content.isNotEmpty && t.isSelf) {
      ref.read(pendingEditProvider.notifier).request(
            messageId: messageId,
            content: content,
          );
    }
    onClose();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, CtxTarget t) async {
    final messageId = t.messageId;
    if (messageId == null) {
      onClose();
      return;
    }
    final controller = ref.read(nostrControllerProvider);
    if (t.isSelf) {
      await _confirmThen(
        context,
        tr('Are you sure you want to delete this message? This will send a deletion request to relays.'),
        okLabel: tr('Delete'),
        danger: true,
        action: () => controller.deleteMessage(messageId),
      );
    } else {
      await _confirmThen(
        context,
        tr("Delete this member's message for everyone in the group?"),
        okLabel: tr('Delete'),
        danger: true,
        action: () => controller.modDeleteGroupMessage(
            _groupId(ref), messageId, t.pubkey),
      );
    }
  }

  /// Confirms via `.app-dialog`, then closes the panel and runs [action].
  Future<void> _confirmThen(
    BuildContext context,
    String message, {
    required String okLabel,
    required bool danger,
    required FutureOr<void> Function() action,
  }) async {
    final ok = await showAppConfirm(
      context,
      message,
      okLabel: okLabel,
      danger: danger,
    );
    onClose();
    if (ok) await action();
  }

  Future<void> _translate(BuildContext context, WidgetRef ref) async {
    final content = target.content;
    if (content == null) return;
    // No language prompt; null lets the inline render resolve the target language chosen at first run.
    onTranslateInline?.call(null);
  }

  Future<void> _zap(BuildContext context, WidgetRef ref) async {
    // Fresh LN-address resolve so a target whose profile isn't ingested yet can still be zapped.
    final lnAddr =
        await ref.read(nostrControllerProvider).resolveLightningAddressForZap(
              target.pubkey,
            );
    if (lnAddr == null || lnAddr.isEmpty) {
      // Tell the user the target cannot receive zaps rather than failing silently.
      ref.read(appStateProvider.notifier).addSystemMessage(
            tr('@{nym} cannot receive zaps (no lightning address set)',
                {'nym': stripPubkeySuffix(target.nym)}),
          );
      return;
    }
    if (!context.mounted) return;
    final kind = message != null
        ? inferOriginalKind(message!, view: ref.read(currentViewProvider))
        : null;
    await ZapModal.show(
      context,
      recipientPubkey: target.pubkey,
      recipientNym: target.nym,
      lightningAddress: lnAddr,
      messageId: target.messageId,
      originalKind: kind,
    );
  }
}

/// Full public key with Copy and an npub/hex switch; the format is an app-wide preference shared with the PWA.
class _PubkeyBlock extends StatefulWidget {
  const _PubkeyBlock({
    required this.pubkey,
    required this.onCopied,
    required this.onClose,
  });

  final String pubkey;
  final VoidCallback onCopied;
  final VoidCallback onClose;

  @override
  State<_PubkeyBlock> createState() => _PubkeyBlockState();
}

class _PubkeyBlockState extends State<_PubkeyBlock> {
  PubkeyFormat _format = PubkeyFormat.npub;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final stored = readPubkeyFormat(prefs);
      if (stored != _format) setState(() => _format = stored);
    });
  }

  Future<void> _toggle() async {
    final next =
        _format == PubkeyFormat.npub ? PubkeyFormat.hex : PubkeyFormat.npub;
    setState(() => _format = next);
    final prefs = await SharedPreferences.getInstance();
    await writePubkeyFormat(prefs, next);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isNpub = _format == PubkeyFormat.npub;
    final shown = formatPubkeyForDisplay(widget.pubkey, _format);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: c.insetFill,
              border: Border.all(color: c.insetBorder),
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: SelectableText(
              shown,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _CopyPubkeyRow(
              icon: Icons.copy,
              label: isNpub ? tr('Copy npub') : tr('Copy hex pubkey'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: shown));
                widget.onCopied();
                widget.onClose();
              },
            ),
            const SizedBox(width: 4),
            _CopyPubkeyRow(
              icon: Icons.swap_horiz,
              label: isNpub ? tr('Show hex') : tr('Show npub'),
              onTap: _toggle,
            ),
          ],
        ),
      ],
    );
  }
}

class _CopyPubkeyRow extends StatefulWidget {
  const _CopyPubkeyRow({
    required this.onTap,
    required this.icon,
    required this.label,
  });
  final Future<void> Function() onTap;
  final IconData icon;
  final String label;

  @override
  State<_CopyPubkeyRow> createState() => _CopyPubkeyRowState();
}

class _CopyPubkeyRowState extends State<_CopyPubkeyRow> {
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
              Icon(widget.icon, size: 12, color: color),
              const SizedBox(width: 2),
              Text(widget.label,
                  style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionItem extends StatefulWidget {
  const _ActionItem({
    super.key,
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
  State<_ActionItem> createState() => _ActionItemState();
}

class _ActionItemState extends State<_ActionItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isNeutral = widget.color == c.text;
    // Neutral rows dim the icon and hover to primary; colored rows keep their tint.
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
                ? (widget.color == c.danger
                    ? c.dangerHoverOverlay
                    : c.hoverOverlay)
                : null,
            borderRadius: NymRadius.rxs,
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
            ],
          ),
        ),
      ),
    );
  }
}

/// The ✕ close button shared by the user and group context panels; turns danger-red on hover.
class CtxCloseButton extends StatefulWidget {
  const CtxCloseButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  State<CtxCloseButton> createState() => _CtxCloseButtonState();
}

class _CtxCloseButtonState extends State<CtxCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? const Color(0x1FFF4444)
                : (c.isLight
                    ? const Color(0x0D000000)
                    : Colors.white.withValues(alpha: 0.05)),
            border: Border.all(
              color: _hover
                  ? const Color(0x4DFF4444)
                  : (c.isLight ? const Color(0x14000000) : c.glassBorder),
            ),
          ),
          // Outside the card's Material, so explicit `decoration: none` avoids the debug yellow underline.
          child: Text('✕',
              style: TextStyle(
                  fontSize: 16,
                  height: 1,
                  decoration: TextDecoration.none,
                  color: _hover
                      ? c.danger
                      : (c.isLight ? const Color(0x80000000) : c.textDim))),
        ),
      ),
    );
  }
}

class _BackButton extends StatefulWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? const Color(0x99000000)
                : const Color(0x66000000),
          ),
          child: const NymSvgIcon(NymIcons.chevronLeft,
              size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

/// Tap opens the image fullscreen and closes the menu; inert when [imageUrl] is empty.
class _ExpandableProfileImage extends StatelessWidget {
  const _ExpandableProfileImage({
    required this.imageUrl,
    required this.onClose,
    required this.child,
  });

  final String? imageUrl;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Capture the root navigator before closing; this panel's context is defunct after onClose().
        final rootContext = Navigator.of(context, rootNavigator: true).context;
        onClose();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (rootContext.mounted) _ProfileImageViewer.open(rootContext, url);
        });
      },
      child: MouseRegion(cursor: SystemMouseCursors.click, child: child),
    );
  }
}

/// Fullscreen viewer for the profile avatar/banner, since the message viewer is private to its file.
class _ProfileImageViewer extends StatelessWidget {
  const _ProfileImageViewer({required this.url});
  final String url;

  static Future<void> open(BuildContext context, String url) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        pageBuilder: (_, _, _) => _ProfileImageViewer(url: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: isAssetImageUrl(url)
                  ? Image.asset(url, fit: BoxFit.contain)
                  : CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.contain,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
            ),
          ),
          Positioned(
            top: 14,
            right: 14,
            child: SafeArea(
                child: CtxCloseButton(
                    onTap: () => Navigator.of(context).maybePop())),
          ),
        ],
      ),
    );
  }
}
