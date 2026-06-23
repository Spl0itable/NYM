import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/translate/translate_language_prompt.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import 'context_menu_actions.dart';
import 'interaction_hooks.dart';
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
  });

  final CtxTarget target;
  final Animation<double> animation;
  final VoidCallback onClose;

  /// The originating message (used to infer kind for reactions/zaps).
  final Message? message;

  /// Opens the reaction picker for this message (host supplies it).
  final VoidCallback? onReact;

  /// Requests an inline translation render below the message (host supplies it).
  /// The argument is the chosen target language code, or null to use the
  /// `settings.translateLanguage` default.
  final ValueChanged<String?>? onTranslateInline;

  /// Presents the panel in the root overlay with the slide-in transition.
  static Future<void> show(
    BuildContext context, {
    required CtxTarget target,
    Message? message,
    VoidCallback? onReact,
    ValueChanged<String?>? onTranslateInline,
  }) {
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
    final target = _enrichTarget(ref);
    final actions = buildContextMenuActions(target);
    final fullNym = '${target.nym}#${getPubkeySuffix(target.pubkey)}';
    final cosmetics = ref.watch(userCosmeticsProvider(target.pubkey));

    final panel = Material(
      color: c.bgTertiary,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, c, fullNym, cosmetics),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final a in actions)
                      _ActionItem(
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

    // translateX(100%) → 0 over 150ms (linear).
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.linear)),
      child: SizedBox(
        width: 320,
        height: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.glassBorder)),
          ),
          child: Stack(
            children: [
              panel,
              Positioned(
                top: 14,
                right: 14,
                child: _closeBtn(c),
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
    String fullNym,
    UserCosmetics cosmetics,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        children: [
          NymAvatar(seed: target.pubkey, size: 64),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  fullNym,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.secondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CosmeticNymBadges(
                cosmetics: cosmetics,
                flairSize: 15,
                supporterHeight: 15,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Full pubkey block + Copy Pubkey.
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: Text(
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
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: target.pubkey));
            },
            borderRadius: const BorderRadius.all(Radius.circular(6)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.copy, size: 12, color: c.textDim),
                  const SizedBox(width: 4),
                  Text('Copy Pubkey',
                      style: TextStyle(color: c.textDim, fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _closeBtn(NymColors c) {
    return InkWell(
      onTap: onClose,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.glassBorder),
        ),
        child: Icon(Icons.close, size: 16, color: c.textDim),
      ),
    );
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
        // The bot-credits modal is owned by another slice and has no controller
        // entry point reachable here yet; close the menu (documented deferral in
        // docs/audit/05-commands-format-interactions.md).
        onClose();
        break;
      case CtxAction.editProfile:
        // ui-context.js:587-594 "Edit Profile" → editNick(). The profile editor
        // is owned by another slice; close the menu (documented deferral).
        onClose();
        break;
      case CtxAction.edit:
        // Own message: prompt for the new content, then editMessage.
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

  /// Edit own message — prompt for new content (seeded with the original) then
  /// call editMessage. Mirrors startEditMessage populating the input.
  Future<void> _edit(BuildContext context, WidgetRef ref, CtxTarget t) async {
    final messageId = t.messageId;
    if (messageId == null) {
      onClose();
      return;
    }
    final newText = await _promptEdit(context, t.content ?? '');
    onClose();
    if (newText == null) return;
    final trimmed = newText.trim();
    if (trimmed.isEmpty || trimmed == (t.content ?? '')) return;
    await ref.read(nostrControllerProvider).editMessage(messageId, trimmed);
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

  /// Shows a confirm dialog (showAppConfirm equivalent); on confirm, closes the
  /// panel and runs [action].
  Future<void> _confirmThen(
    BuildContext context,
    String message, {
    required String okLabel,
    required bool danger,
    required FutureOr<void> Function() action,
  }) async {
    final c = context.nym;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.bgTertiary,
        content: Text(message, style: TextStyle(color: c.text, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(okLabel,
                style: TextStyle(color: danger ? c.danger : c.text)),
          ),
        ],
      ),
    );
    onClose();
    if (ok == true) await action();
  }

  /// Prompts for edited message text, returning the new value or null on cancel.
  Future<String?> _promptEdit(BuildContext context, String original) async {
    final c = context.nym;
    final controller = TextEditingController(text: original);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.bgTertiary,
        title: Text('Edit Message', style: TextStyle(color: c.text, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          style: TextStyle(color: c.text),
          decoration: InputDecoration(
            hintText: 'Edit your message…',
            hintStyle: TextStyle(color: c.textDim),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text('Save', style: TextStyle(color: c.text)),
          ),
        ],
      ),
    );
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
    final lnAddr = _lightningAddressFor(ref, target.pubkey);
    if (lnAddr == null || lnAddr.isEmpty) {
      // No lightning address — mirror the PWA's "cannot receive zaps" notice.
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

  String? _lightningAddressFor(WidgetRef ref, String pubkey) {
    final user = ref.read(usersProvider)[pubkey];
    return user?.profile?.lightningAddress;
  }
}

/// `.context-menu-item`: 10×14 padding, radius 8, hover tint.
class _ActionItem extends StatefulWidget {
  const _ActionItem({
    required this.label,
    required this.color,
    required this.onTap,
  });
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
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _hover ? Colors.white.withValues(alpha: 0.08) : null,
            borderRadius: NymRadius.rxs,
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
