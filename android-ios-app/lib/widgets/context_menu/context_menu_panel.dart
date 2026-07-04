import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/translate/translate_language_prompt.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'context_menu_actions.dart';
import 'group_context_menu_panel.dart';
import 'interaction_hooks.dart';
import 'profile_badges.dart';
import 'report_modal.dart';

/// The right-side `#contextMenu` slide-in panel (styles `.context-menu`,
/// width 320, `translateX(100%)→0` over 150ms, dimmed overlay). Mirrors
/// ui-context.js `showContextMenu` / `closeContextMenu`: avatar header (avatar,
/// nym + suffix, status, full pubkey + copy, bio) then the action list built by
/// [buildContextMenuActions].
///
/// Open it with [ContextMenuPanel.show], passing a [CtxTarget]. Actions are
/// wired to the engine (toggleReaction, startPM), the zap modal, the report
/// modal, translation, and the mention/quote hook
/// ([pendingComposerActionProvider]).
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

  /// When set (or carried on [target]), a top-left "back" chevron returns to
  /// that group's context menu (PWA `ctxBackToGroup`, ui-context.js:369-373).
  final String? backToGroupId;

  /// The originating message (used to infer kind for reactions/zaps).
  final Message? message;

  /// Opens the reaction picker for this message (host supplies it).
  final VoidCallback? onReact;

  /// Requests an inline translation render below the message (host supplies it).
  /// The argument is the chosen target language code, or null to use the
  /// `settings.translateLanguage` default.
  final ValueChanged<String?>? onTranslateInline;

  /// Presents the panel in the root overlay with the slide-in transition.
  /// [backToGroupId] (or `target.backToGroupId`) makes the panel show a back
  /// chevron that returns to that group's context menu.
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
      barrierLabel: 'context menu',
      barrierColor: const Color(0x99000000), // rgba(0,0,0,0.6)
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (ctx, anim, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
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

  /// Re-derives the live friend / block / group-role flags from app_state so the
  /// action list + labels reflect current state without the caller (message_row)
  /// having to thread them through. Mirrors the flags ui-context.js
  /// `showContextMenu` computes (friends/blockedUsers + group owner/mod roles).
  CtxTarget _enrichTarget(WidgetRef ref) {
    final s = ref.read(appStateProvider);
    final self = s.selfPubkey;
    final inGroup = s.view.kind == ViewKind.group;
    final group = inGroup ? _groupById(s, s.view.id) : null;
    final iAmOwner = group != null && group.createdBy == self;
    final iAmMod = group != null && group.mods.contains(self);
    final targetIsMember = group != null && group.members.contains(target.pubkey);
    final targetIsOwner = group != null && group.createdBy == target.pubkey;
    final targetIsMod = group != null && group.mods.contains(target.pubkey);
    return CtxTarget(
      pubkey: target.pubkey,
      nym: target.nym,
      isSelf: target.isSelf,
      content: target.content,
      messageId: target.messageId,
      profileOnly: target.profileOnly,
      isFriend: s.isFriend(target.pubkey),
      isBlocked: s.isUserBlocked(target.pubkey),
      isBot: target.isBot,
      inGroup: inGroup,
      iAmOwner: iAmOwner,
      iAmMod: iAmMod,
      targetIsMember: targetIsMember,
      targetIsOwner: targetIsOwner,
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
    final fullNym = '${target.nym}#${getPubkeySuffix(target.pubkey)}';
    final cosmetics = ref.watch(userCosmeticsProvider(target.pubkey));
    final user = ref.watch(usersProvider)[target.pubkey];
    final about = user?.profile?.about ?? '';

    final panel = Material(
      // `.context-menu` is `var(--bg-tertiary)` by default, but `body.solid-ui`
      // (default ON) overrides it to `var(--glass-bg)` — the same opaque surface
      // as the sidebar / chat-header (#14141e dark, #ffffff light). The bg is
      // painted on the full-height outer Container below so it fills the whole
      // viewport (`.context-menu { height: 100vh }`); the Material itself stays
      // transparent and only provides ink/scroll for the (content-height) body.
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
                    .addSystemMessage('Copied pubkey to clipboard'),
              ),
              // Bio block (`.context-menu-bio`) — sibling below the header, its
              // own bottom border; collapses when empty (:empty).
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
              // `.context-menu-actions`: 6px padding + a 1px white@0.06 top
              // hairline separating the list from the header/bio.
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
                    for (final a in actions)
                      _ActionItem(
                        svg: ctxActionSvg(a),
                        label: ctxActionLabel(a, target),
                        color: _colorFor(a, c),
                        onTap: () => _invoke(context, ref, a, target, fullNym),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Width 320, clamped to 85vw on very narrow screens (`max-width:85vw`,
    // styles-shell.css:611). The active panel carries a `-4px 0 24px` drop
    // shadow for edge separation (F11).
    final screenW = MediaQuery.of(context).size.width;
    final panelW = math.min(320.0, screenW * 0.85);

    // translateX(100%) → 0 over 150ms (linear).
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
            // Opaque solid-ui surface filling the FULL viewport height (not just
            // the content), matching `.context-menu` + the normal sidebar.
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
              panel,
              // Back chevron (top-left) → return to the originating group menu
              // (`.context-menu-back`, ui-context.js:369-373). Hidden otherwise.
              // 28×28 at top/left 10, black 0.4 bg (hover 0.6), white chevron.
              //
              // Both floating buttons offset by the status-bar inset: the
              // PWA's `top:14px` is measured from a web viewport that already
              // starts BELOW the system chrome, while this Stack spans the full
              // screen — without the inset the buttons render under the status
              // bar (visibly misplaced AND un-tappable). The panel body handles
              // its own inset via SafeArea.
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
  ) {
    final bannerUrl = proxiedAvatarUrl(user?.profile?.banner);
    final hasBanner = bannerUrl != null && bannerUrl.isNotEmpty;
    final avatarUrl = user?.profile?.picture;
    final status = user?.effectiveStatus() ?? UserStatus.offline;
    final isDeveloper = controller.isVerifiedDeveloper(target.pubkey);
    final isBot = controller.isVerifiedBot(target.pubkey);
    final showFriendBadge = target.isFriend && !target.isSelf;
    // Owner/Mod label, only when viewing the target's group (ui-context.js:422).
    final String? ownerModLabel = target.inGroup
        ? (target.targetIsOwner
            ? 'Group Owner'
            : (target.targetIsMod ? 'Moderator' : null))
        : null;

    // Avatar — real picture (proxied/cached) with identicon fallback. With a
    // banner: a 3px rgba(20,20,35,0.95) ring, no glow (`.has-banner
    // .avatar-context`). Without a banner: a 2px `--glass-border` ring + a cyan
    // glow `0 0 15px rgba(0,255,255,0.15)` (`.avatar-context`,
    // styles-features.css:2621-2628).
    // With a banner: a 3px ring matching the surface (`rgba(20,20,35,0.95)`
    // dark; `body.light-mode .has-banner .avatar-context` → `rgba(255,255,255,
    // 0.95)`).
    final bannerRing = c.isLight
        ? const Color(0xF2FFFFFF) // rgba(255,255,255,0.95)
        : const Color(0xF2141423); // rgba(20,20,35,0.95)
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
                  color: Color(0x2600FFFF), // rgba(0,255,255,0.15)
                  blurRadius: 15,
                ),
              ],
            ),
      // The PWA avatar carries `data-action="expandImageFromSrcStop"` →
      // `expandImage(getAvatarUrl)` + `closeContextMenu` (inline-bindings.js:244).
      // Only a real (remote) picture is worth expanding; the identicon fallback
      // (`avatarUrl` null/empty) stays inert.
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
          // Without a banner the avatar sits at the top of the header; with a
          // banner it is hoisted into the Stack overlap below.
          if (!hasBanner) ...[
            avatar,
            const SizedBox(height: 6),
          ],
          // Nym row: base#suffix + flair/supporter + verified ✓ + friend badge.
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // base#suffix: base is secondary/13/w600; the `#suffix` is dimmed
              // (`.context-menu-avatar-nym .nym-suffix`: 0.9em / w100 / opacity
              // 0.7).
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
              // Verified ✓ badge — 20px (`.verified-badge`), left gap 4px (nm-ctx-1).
              if (isDeveloper || isBot) ...[
                const SizedBox(width: 4),
                const VerifiedBadge(size: 20),
              ],
              // Friend badge — 12px @ opacity 0.7, left gap 3px (nm-ctx-2 +
              // inline width/height=12 overriding the 20px standalone rule).
              if (showFriendBadge) ...[
                const SizedBox(width: 3),
                const Opacity(opacity: 0.7, child: FriendBadge(size: 12)),
              ],
            ],
          ),
          // Dev / Bot text label (`.context-menu-dev-label`).
          if (isDeveloper || isBot)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                isDeveloper ? 'Nymchat Developer' : 'Nymchat Bot',
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          // Group Owner / Moderator label (`.context-menu-owner-label`).
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
          // Status row (`.ctx-status-row`): dot + word, hidden when status is
          // hidden (ui-context.js:445-464).
          if (status != UserStatus.hidden) ...[
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
          // Full pubkey block — tap-to-select-all mono text (`.ctx-full-pubkey`,
          // user-select:all).
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: c.insetFill,
              border: Border.all(color: c.insetBorder),
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: SelectableText(
              target.pubkey,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
          // Copy Pubkey — confirm + close (F12); hover tint (`.context-menu-copy-pubkey`).
          _CopyPubkeyRow(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: target.pubkey));
              // System-message confirmation (displaySystemMessage) + close.
              onCopied();
              onClose();
            },
          ),
        ],
      ),
    );

    if (!hasBanner) return header;

    // Banner (`.context-menu-banner`: 140px, cover) with the avatar straddling
    // its bottom edge (`margin-top:-36px`): the avatar is hoisted into a Stack
    // so the header content below starts directly under it (no dead gap). The
    // header carries extra top padding to clear the avatar's lower half.
    const avatarBox = 70.0; // 64 + 3px ring on each side
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
            // The PWA banner also carries `expandImageFromSrcStop` → opens the
            // banner fullscreen + closes the menu (index.html:74).
            SizedBox(
              height: 140,
              width: double.infinity,
              child: _ExpandableProfileImage(
                imageUrl: bannerUrl,
                onClose: onClose,
                child: CachedNetworkImage(
                  imageUrl: bannerUrl,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            bannerHeader,
          ],
        ),
        // Avatar centered on the banner/header seam (140 - 36 from the top).
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
        return 'Online';
      case UserStatus.away:
        return 'Away';
      case UserStatus.offline:
      case UserStatus.hidden:
        return 'Offline';
    }
  }

  /// `.context-menu-back` chevron — pops this panel and re-opens the originating
  /// group context menu (PWA `ctxBackToGroup`: closeContextMenu →
  /// showGroupContextMenu(groupId)).
  void _onBack(BuildContext context, String groupId) {
    // Capture the root navigator's (stable) context before popping — this
    // panel's own context is defunct after onClose().
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
      case CtxAction.zap:
        return c.lightning;
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
    // Actions that need the BuildContext after an await (confirm dialogs / edit
    // prompt) close the panel themselves; the rest close immediately.
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
            // Build + sign + publish the NIP-56 kind-1984 report (F2). When
            // "report specific message" is checked we attach the `e` tag.
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
        // toggleFriend — label already reflects state (Add/Remove Friend).
        onClose();
        controller.toggleFriend(t.pubkey);
        break;
      case CtxAction.block:
        // Block/Unblock toggle (cmdBlock user path / unblockByPubkey).
        onClose();
        controller.toggleBlockUser(t.pubkey);
        break;
      case CtxAction.slap:
        // ui-context.js:153-159 → cmdSlap(pubkey). The PWA builds a full
        // @nym#suffix mention so the renderer attaches avatar/flair, then sends
        // the `/me …` line through the rate-limited action path. Routing the
        // built `/me …` text through sendCurrent re-enters the command
        // dispatcher, sharing the composer's action rate limiter — the same net
        // effect as cmdSlap.
        onClose();
        unawaited(controller.sendCurrent(
            '/me slaps @$fullNym around a bit with a large trout 🐟'));
        break;
      case CtxAction.hug:
        // ui-context.js:162-167 → cmdHug(pubkey).
        onClose();
        unawaited(controller.sendCurrent('/me gives @$fullNym a warm hug 🫂'));
        break;
      case CtxAction.addToGroup:
        // ui-context.js:575-580 "Create Group Chat" → startGroupFromPM. Here we
        // seed a new group with just this peer (createGroup mirrors the PWA's
        // group-from-context flow once a name is chosen; an empty name lets the
        // groups slice fall back to its default naming).
        onClose();
        unawaited(controller.createGroup('', [t.pubkey]));
        break;
      case CtxAction.giftCredits:
        // ui-context.js:102-107 "Gift Nymbot Credits" → showBotCreditsModal.
        // Post the recipient to the gift-credits mailbox; the nymbot slice opens
        // its gift-credit modal (CROSS-FILE NEED — see giftCreditsRequestProvider).
        onClose();
        ref
            .read(giftCreditsRequestProvider.notifier)
            .request(pubkey: t.pubkey, nym: t.nym);
        break;
      case CtxAction.editProfile:
        // ui-context.js:587-594 "Edit Profile" → editNick(). Open the nick/
        // profile editor modal directly (its public entry point).
        onClose();
        if (context.mounted) await NickEditModal.open(context);
        break;
      case CtxAction.edit:
        // Own message: seed the composer with the original content
        // (startEditMessage) so the next send publishes the edit.
        await _edit(context, ref, t);
        break;
      case CtxAction.delete:
        // Own → deletion request; mod/owner → group mod-delete. Both confirm.
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
      case CtxAction.transferOwner:
        await _confirmThen(
          context,
          'Transfer group ownership to this user? You will lose owner privileges.',
          okLabel: 'Transfer',
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
          'Ban this user from the group? They cannot be re-invited unless the owner unbans them.',
          okLabel: 'Ban',
          danger: true,
          action: () => controller.banFromGroup(_groupId(ref), t.pubkey),
        );
        break;
    }
  }

  String _groupId(WidgetRef ref) {
    final view = ref.read(currentViewProvider);
    return view.kind == ViewKind.group ? view.id : '';
  }

  /// Edit own message — seed the composer with the original content and enter
  /// pending-edit mode: the amber "Editing message" chip shows above the input
  /// and the NEXT send publishes the edit. Mirrors `ctxEditMessage` →
  /// `startEditMessage` (ui-context.js:261-266, messages.js:1861-1919), which
  /// populates `#messageInput` rather than opening a prompt. `startEditMessage`
  /// bails without messageId/content or on someone else's message.
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

  /// Delete — own messages send a kind-5 deletion (confirm); a mod/owner
  /// deleting another member's group message uses modDeleteGroupMessage.
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
        'Are you sure you want to delete this message? This will send a deletion request to relays.',
        okLabel: 'Delete',
        danger: true,
        action: () => controller.deleteMessage(messageId),
      );
    } else {
      await _confirmThen(
        context,
        "Delete this member's message for everyone in the group?",
        okLabel: 'Delete',
        danger: true,
        action: () =>
            controller.modDeleteGroupMessage(_groupId(ref), messageId, t.pubkey),
      );
    }
  }

  /// Shows the `.app-dialog` confirm (the PWA routes all context-menu
  /// confirmations through `showAppConfirm` with `{danger, okLabel}`,
  /// inline-bindings.js:479-520); on confirm, closes the panel and runs
  /// [action].
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
    final settings = ref.read(settingsProvider);
    String? chosenLang;
    if (settings.translateLanguage.isEmpty) {
      if (!context.mounted) return;
      chosenLang = await promptTranslateLanguage(context);
      if (chosenLang == null) return;
      // settings persistence is owned by another slice; pass the chosen lang to
      // the inline render directly (translate.js saves it to settings too).
    }
    onTranslateInline?.call(chosenLang);
  }

  Future<void> _zap(BuildContext context, WidgetRef ref) async {
    // Fresh LN-address resolve (cache-first, then kind-0 fetch) so a target
    // whose profile hasn't been ingested yet can still be zapped — consistent
    // with the quick-zap (+) button (zap_badge.dart:209). PWA: cmdZap awaits
    // fetchLightningAddressForUser (zaps.js:1955/2015) before deciding.
    final lnAddr =
        await ref.read(nostrControllerProvider).resolveLightningAddressForZap(
              target.pubkey,
            );
    if (lnAddr == null || lnAddr.isEmpty) {
      // No lightning address — mirror the PWA's "cannot receive zaps" notice
      // (zaps.js:1960/2021); a bare return left the user with zero feedback.
      ref.read(appStateProvider.notifier).addSystemMessage(
            '@${stripPubkeySuffix(target.nym)} cannot receive zaps '
            '(no lightning address set)',
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

/// `.context-menu-copy-pubkey`: 3×8 padding, radius 6, hover `rgba(255,255,255,
/// 0.08)` bg + primary text; copy glyph + label. Confirms + closes on tap (F12).
class _CopyPubkeyRow extends StatefulWidget {
  const _CopyPubkeyRow({required this.onTap});
  final Future<void> Function() onTap;

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
              Icon(Icons.copy, size: 12, color: color),
              const SizedBox(width: 2),
              Text('Copy Pubkey', style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.context-menu-item`: 10×14 padding, radius 8, hover tint, leading 16px icon.
class _ActionItem extends StatefulWidget {
  const _ActionItem({
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
    // Neutral rows show a dimmed icon; colored rows (danger/lightning/warning)
    // tint the icon to match the label (mirrors the PWA's `currentColor` SVGs).
    // On hover, a neutral row's label + icon shift to `--primary`
    // (`.context-menu-item:hover { color: var(--primary) }`); colored rows keep
    // their resting tint.
    final Color labelColor =
        isNeutral && _hover ? c.primary : widget.color;
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
            borderRadius: NymRadius.rxs,
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

/// The `.context-menu-close` ✕ button: 32×32 circle, white@0.05 bg + glassBorder
/// at rest; on hover turns danger-red (bg `rgba(255,68,68,0.12)`, icon
/// `--danger`, border `rgba(255,68,68,0.3)`) per styles-shell.css:674-678.
/// Shared by the user + group context panels.
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
            // Light: `body.light-mode .context-menu-close` → black@0.05 fill,
            // black@0.08 border, black@0.5 icon. Hover (both modes) → danger red.
            color: _hover
                ? const Color(0x1FFF4444) // rgba(255,68,68,0.12)
                : (c.isLight
                    ? const Color(0x0D000000) // black @ 0.05
                    : Colors.white.withValues(alpha: 0.05)),
            border: Border.all(
              color: _hover
                  ? const Color(0x4DFF4444) // rgba(255,68,68,0.3)
                  : (c.isLight ? const Color(0x14000000) : c.glassBorder),
            ),
          ),
          // `.context-menu-close` is a literal "✕" char (`&#x2715;`) — styled
          // text, not an SVG glyph.
          child: Text('✕',
              style: TextStyle(
                  fontSize: 16,
                  height: 1,
                  color: _hover
                      ? c.danger
                      : (c.isLight ? const Color(0x80000000) : c.textDim))),
        ),
      ),
    );
  }
}

/// The `.context-menu-back` chevron: 28×28 circle at top/left 10, black 0.4 bg
/// (hover 0.6), border-none, white chevron (styles-features.css:5393-5411).
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
                ? const Color(0x99000000) // rgba(0,0,0,0.6)
                : const Color(0x66000000), // rgba(0,0,0,0.4)
          ),
          // `.context-menu-back` — feather chevron-left (index.html:71).
          child: const NymSvgIcon(NymIcons.chevronLeft,
              size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

/// Wraps the profile-card avatar / banner so a tap opens the image fullscreen
/// and closes the context menu — the PWA's `data-action="expandImageFromSrcStop"`
/// (inline-bindings.js:244 → `expandImage(src)` + `closeContextMenu()`).
///
/// When [imageUrl] is null/empty (e.g. the identicon-only avatar) the child is
/// rendered inert, matching the PWA which only expands a real remote image.
/// A self-contained fullscreen viewer is used here because the message-format
/// viewer (`_FullscreenImageViewer`) is private to that file; the behavior
/// (rootNavigator push, black@0.92 barrier, pinch-zoom, tap-to-close) mirrors it.
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
        // Capture the root navigator before closing this panel (its own context
        // is defunct after onClose()).
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

/// Self-contained fullscreen image viewer for the profile card's avatar/banner.
/// Mirrors `_FullscreenImageViewer` (message_content.dart:1345 — `expandImage`):
/// opaque:false route over the root navigator, black@0.92 barrier, pinch-zoom
/// via [InteractiveViewer], tap the backdrop or the ✕ to close.
class _ProfileImageViewer extends StatelessWidget {
  const _ProfileImageViewer({required this.url});
  final String url;

  static Future<void> open(BuildContext context, String url) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        pageBuilder: (_, __, ___) => _ProfileImageViewer(url: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tap anywhere on the backdrop to dismiss.
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
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          Positioned(
            top: 14,
            right: 14,
            child: SafeArea(child: CtxCloseButton(onTap: () => Navigator.of(context).maybePop())),
          ),
        ],
      ),
    );
  }
}
