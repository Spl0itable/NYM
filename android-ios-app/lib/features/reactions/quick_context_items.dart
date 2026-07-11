import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../features/zaps/zap_modal.dart';
import '../i18n/i18n.dart';
import 'quick_react_popup.dart';

/// Builds the gated [QuickContextItem] list for the long-press quick-context-menu
/// (F3), mirroring `ui-context.js:1358-1450`:
///
///  - Slap / Hug — other users (`!isSelf && targetPubkey`).
///  - Zap (lightning) — other-user + has message.
///  - Quote / Copy / Translate — any message with content.
///  - Edit — own + content.
///  - Delete (danger) — own.
///
/// Dispatch reuses the same engine paths as the full context menu (slap/hug via
/// the rate-limited `/me` command, quote via the composer mailbox, copy via the
/// clipboard + a system-message confirm, zap via the zap modal, delete via a
/// confirm + `deleteMessage`). [onTranslate] and [onEdit] integrate with the
/// host (message_row owns the inline translation render + the edit/compose
/// flow); the corresponding rows are only added when their callback is supplied.
///
/// All logic lives here so the only change the host must make is to call this
/// and pass the result to `showQuickReactPopup(contextItems: …)`.
List<QuickContextItem> buildQuickContextItems(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  VoidCallback? onTranslate,
  VoidCallback? onEdit,
}) {
  final controller = ref.read(nostrControllerProvider);
  final app = ref.read(appStateProvider);
  final self = app.selfPubkey;
  final pubkey = message.pubkey;
  final isSelf = message.isOwn || pubkey == self;
  final hasMessageId = message.id.isNotEmpty;
  final content = message.content;
  final hasContent = content.isNotEmpty;
  final baseNym = _baseNym(message.author);
  final fullNym = '$baseNym#${getPubkeySuffix(pubkey)}';

  final items = <QuickContextItem>[];

  if (!isSelf && pubkey.isNotEmpty) {
    items.add(QuickContextItem(
      label: tr('Slap with Trout'),
      svg: ctxActionSvg(CtxAction.slap),
      onTap: () => controller
          .sendCurrent('/me slaps @$fullNym around a bit with a large trout 🐟'),
    ));
    items.add(QuickContextItem(
      label: tr('Give warm Hug'),
      svg: ctxActionSvg(CtxAction.hug),
      onTap: () => controller.sendCurrent('/me gives @$fullNym a warm hug 🫂'),
    ));
  }

  if (!isSelf && hasMessageId && pubkey.isNotEmpty) {
    items.add(QuickContextItem(
      label: tr('Zap Bitcoin'),
      svg: ctxActionSvg(CtxAction.zap),
      color: QuickContextItemColor.lightning,
      onTap: () => _zap(context, ref, message, baseNym),
    ));
  }

  if (hasContent) {
    items.add(QuickContextItem(
      label: tr('Quote Message'),
      svg: ctxActionSvg(CtxAction.quote),
      onTap: () => ref
          .read(pendingComposerActionProvider.notifier)
          .requestQuote(fullNym: fullNym, content: content),
    ));
    items.add(QuickContextItem(
      label: tr('Copy Message'),
      svg: ctxActionSvg(CtxAction.copyMessage),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: content));
        ref
            .read(appStateProvider.notifier)
            .addSystemMessage(tr('Message copied to clipboard'));
      },
    ));
    if (onTranslate != null) {
      items.add(QuickContextItem(
        label: tr('Translate Message'),
        svg: ctxActionSvg(CtxAction.translate),
        onTap: onTranslate,
      ));
    }
  }

  if (isSelf && hasMessageId && hasContent && onEdit != null) {
    items.add(QuickContextItem(
      label: tr('Edit Message'),
      svg: ctxActionSvg(CtxAction.edit),
      onTap: onEdit,
    ));
  }

  if (isSelf && hasMessageId) {
    items.add(QuickContextItem(
      label: tr('Delete Message'),
      svg: ctxActionSvg(CtxAction.delete),
      color: QuickContextItemColor.danger,
      onTap: () => _confirmDelete(context, ref, message.id),
    ));
  }

  return items;
}

Future<void> _zap(
  BuildContext context,
  WidgetRef ref,
  Message message,
  String baseNym,
) async {
  final user = ref.read(usersProvider)[message.pubkey];
  final lnAddr = user?.profile?.lightningAddress;
  if (lnAddr == null || lnAddr.isEmpty) {
    ref.read(appStateProvider.notifier).addSystemMessage(tr(
        '@{user} cannot receive zaps (no lightning address set)',
        {'user': baseNym}));
    return;
  }
  if (!context.mounted) return;
  await ZapModal.show(
    context,
    recipientPubkey: message.pubkey,
    recipientNym: baseNym,
    lightningAddress: lnAddr,
    messageId: message.id,
    originalKind: inferOriginalKind(message, view: ref.read(currentViewProvider)),
  );
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  String messageId,
) async {
  final c = context.nym;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.bgTertiary,
      content: Text(
        tr('Are you sure you want to delete this message? This will send a deletion request to relays.'),
        style: TextStyle(color: c.text, fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(tr('Cancel'), style: TextStyle(color: c.textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(tr('Delete'), style: TextStyle(color: c.danger)),
        ),
      ],
    ),
  );
  if (ok == true) {
    await ref.read(nostrControllerProvider).deleteMessage(messageId);
  }
}

String _baseNym(String nym) => splitNymSuffix(nym).base;
