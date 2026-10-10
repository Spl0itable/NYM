import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/chat/event_details_sheet.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/context_menu/report_modal.dart';
import '../chat_tools/chat_tools_providers.dart';
import '../chat_tools/chat_tools_ui.dart';
import '../i18n/i18n.dart';
import '../zaps/zap_modal.dart';
import '../toasts/toast_center.dart';
import 'message_actions.dart';
import 'quick_react_popup.dart';

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

({MsgActionFacts facts, Message? stored, bool modDelete}) messageActionFactsFor(
  WidgetRef ref,
  Message message, {
  bool threadable = false,
}) {
  final app = ref.read(appStateProvider);
  final self = app.selfPubkey;
  final pubkey = message.pubkey;
  final isSelf = message.isOwn || (pubkey.isNotEmpty && pubkey == self);
  final found = findMessageAnywhere(app, message.nymMessageId ?? message.id) ??
      (message.id.isEmpty ? null : findMessageAnywhere(app, message.id));
  final tools = ref.read(chatToolsProvider);
  final stored = found?.msg;
  final toolActions = chatToolActionsFor(
    message: stored,
    storageKey: found?.key,
    self: self,
    saved: stored != null && tools.isMessageSaved(stored),
    kept: stored != null && tools.isMessageKept(stored),
    keepOffered: stored != null && tools.keepAvailableFor(stored, found!.key),
  );
  final target = enrichCtxTarget(
    app,
    ctxTargetForMessage(message, selfPubkey: self),
  );
  final modDelete = !isSelf && canModDeleteMessage(target);
  final facts = MsgActionFacts(
    isSelf: isSelf,
    hasId: message.id.isNotEmpty,
    hasContent: message.content.isNotEmpty,
    hasAuthor: pubkey.isNotEmpty,
    threadable: threadable,
    stored: stored != null,
    replyPrivately: toolActions.contains(ChatToolAction.replyPrivately),
    saved: toolActions.contains(ChatToolAction.unsave),
    keepOffered: toolActions.contains(ChatToolAction.keep) ||
        toolActions.contains(ChatToolAction.unkeep),
    kept: toolActions.contains(ChatToolAction.unkeep),
    modDelete: modDelete,
    edited: message.isEdited,
    hexId: _hex64.hasMatch(message.id),
    bot: message.isBot,
  );
  return (facts: facts, stored: stored, modDelete: modDelete);
}

List<QuickContextItem> buildQuickContextItems(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  VoidCallback? onTranslate,
  VoidCallback? onEdit,
  VoidCallback? onThread,
}) {
  final info = messageActionFactsFor(ref, message, threadable: onThread != null);
  final read = ProviderScope.containerOf(context, listen: false).read;
  final app = ref.read(appStateProvider);
  final baseNym = pickDisplayNym(app.users[message.pubkey]?.nym, message.author);
  final fullNym = '${stripPubkeySuffix(baseNym)}#${getPubkeySuffix(message.pubkey)}';
  final stored = info.stored ?? message;

  VoidCallback? run(MsgAction a) {
    switch (a) {
      case MsgAction.reply:
        return () => ref
            .read(pendingComposerActionProvider.notifier)
            .requestQuote(
                fullNym: fullNym,
                content: message.content,
                messageId: message.id);
      case MsgAction.replyPrivately:
        return () => ChatToolsActions.replyPrivately(read, stored);
      case MsgAction.thread:
        return onThread;
      case MsgAction.copy:
        return () async {
          await Clipboard.setData(ClipboardData(text: message.content));
          showToast(tr('Message copied to clipboard'));
        };
      case MsgAction.translate:
        return onTranslate;
      case MsgAction.save:
      case MsgAction.unsave:
        return () => ChatToolsActions.toggleSave(read, stored);
      case MsgAction.keep:
      case MsgAction.unkeep:
        return () => ChatToolsActions.toggleKeep(read, stored);
      case MsgAction.zap:
        return () => _zap(context, ref, message, stripPubkeySuffix(baseNym));
      case MsgAction.edit:
        return onEdit;
      case MsgAction.delete:
        return () => _confirmDelete(context, ref, message, mod: info.modDelete);
      case MsgAction.editHistory:
        return () => EditHistorySheet.open(context, message);
      case MsgAction.eventDetails:
        return () => showEventDetails(
              context,
              eventId: message.id,
              pubkey: message.pubkey,
              nym: message.author,
              channel: message.geohash ?? message.channel,
              createdAt: message.dateTime,
              powTarget: message.powTarget,
            );
      case MsgAction.report:
        return () => _report(context, ref, message, fullNym);
    }
  }

  return [
    for (final a in buildMessageActions(info.facts))
      if (run(a) case final onTap?)
        QuickContextItem(
          id: a.id,
          label: msgActionLabel(a),
          svg: msgActionSvg(a),
          color: quickItemColorFor(msgActionTone(a)),
          onTap: onTap,
        ),
  ];
}

Future<void> _report(
  BuildContext context,
  WidgetRef ref,
  Message message,
  String fullNym,
) async {
  final controller = ref.read(nostrControllerProvider);
  await ReportModal.show(
    context,
    targetNym: fullNym,
    hasMessage: message.id.isNotEmpty,
    onSubmit: (type, details, reportMessage) {
      controller.submitReport(
        pubkey: message.pubkey,
        messageId: reportMessage ? message.id : null,
        type: type,
        details: details,
      );
    },
  );
}

Future<void> _zap(
  BuildContext context,
  WidgetRef ref,
  Message message,
  String baseNym,
) async {
  showToast(tr('Checking if @{nym} can receive zaps...', {'nym': baseNym}));
  final String? lnAddr;
  try {
    lnAddr = await ref
        .read(nostrControllerProvider)
        .resolveLightningAddressForZap(message.pubkey);
  } catch (_) {
    showToast(
        tr('Failed to check if @{nym} can receive zaps', {'nym': baseNym}));
    return;
  }
  if (lnAddr == null || lnAddr.isEmpty) {
    showToast(tr(
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
    originalKind:
        inferOriginalKind(message, view: ref.read(currentViewProvider)),
  );
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  required bool mod,
}) async {
  final controller = ref.read(nostrControllerProvider);
  final view = ref.read(currentViewProvider);
  final ok = await showAppConfirm(
    context,
    mod
        ? tr("Delete this member's message for everyone in the group?")
        : tr('Are you sure you want to delete this message? This will send a deletion request to relays.'),
    okLabel: tr('Delete'),
    danger: true,
  );
  if (!ok) return;
  if (mod) {
    await controller.modDeleteGroupMessage(
        view.kind == ViewKind.group ? view.id : '', message.id, message.pubkey);
  } else {
    await controller.deleteMessage(message.id);
  }
}
