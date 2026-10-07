import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/nym_icons.dart';
import '../chat_tools/chat_tools_ui.dart';
import '../i18n/i18n.dart';

enum MsgAction {
  reply('reply'),
  replyPrivately('replyPrivately'),
  thread('thread'),
  copy('copy'),
  translate('translate'),
  save('save'),
  unsave('unsave'),
  keep('keep'),
  unkeep('unkeep'),
  zap('zap'),
  edit('edit'),
  delete('delete'),
  editHistory('editHistory'),
  eventDetails('eventDetails'),
  report('report');

  const MsgAction(this.id);

  final String id;
}

class MsgActionFacts {
  const MsgActionFacts({
    this.isSelf = false,
    this.hasId = false,
    this.hasContent = false,
    this.hasAuthor = false,
    this.threadable = false,
    this.stored = false,
    this.replyPrivately = false,
    this.saved = false,
    this.keepOffered = false,
    this.kept = false,
    this.modDelete = false,
    this.edited = false,
    this.hexId = false,
    this.bot = false,
  });

  factory MsgActionFacts.fromJson(Map<String, dynamic> j) {
    bool b(String k) => j[k] == true;
    return MsgActionFacts(
      isSelf: b('self'),
      hasId: b('id'),
      hasContent: b('content'),
      hasAuthor: b('author'),
      threadable: b('threadable'),
      stored: b('stored'),
      replyPrivately: b('replyPrivately'),
      saved: b('saved'),
      keepOffered: b('keepOffered'),
      kept: b('kept'),
      modDelete: b('modDelete'),
      edited: b('edited'),
      hexId: b('hexId'),
      bot: b('bot'),
    );
  }

  final bool isSelf;
  final bool hasId;
  final bool hasContent;
  final bool hasAuthor;
  final bool threadable;
  final bool stored;
  final bool replyPrivately;
  final bool saved;
  final bool keepOffered;
  final bool kept;
  final bool modDelete;
  final bool edited;
  final bool hexId;
  final bool bot;
}

List<MsgAction> buildMessageActions(MsgActionFacts f) {
  final tools = f.stored && f.hasContent;
  return [
    if (f.hasContent) MsgAction.reply,
    if (tools && f.replyPrivately && !f.isSelf) MsgAction.replyPrivately,
    if (f.threadable && f.hasId) MsgAction.thread,
    if (f.hasContent) MsgAction.copy,
    if (f.hasContent) MsgAction.translate,
    if (tools) f.saved ? MsgAction.unsave : MsgAction.save,
    if (tools && f.keepOffered) f.kept ? MsgAction.unkeep : MsgAction.keep,
    if (!f.isSelf && f.hasId && f.hasAuthor) MsgAction.zap,
    if (f.isSelf && f.hasId && f.hasContent) MsgAction.edit,
    if (f.hasId && (f.isSelf || f.modDelete)) MsgAction.delete,
    if (f.edited && f.hasId) MsgAction.editHistory,
    if (f.hexId) MsgAction.eventDetails,
    if (!f.isSelf && f.hasAuthor) MsgAction.report,
  ];
}

MenuTone msgActionTone(MsgAction a) {
  switch (a) {
    case MsgAction.report:
      return MenuTone.report;
    case MsgAction.delete:
      return MenuTone.danger;
    default:
      return MenuTone.normal;
  }
}

String msgActionLabel(MsgAction a) {
  switch (a) {
    case MsgAction.reply:
      return tr('Reply');
    case MsgAction.replyPrivately:
      return chatToolLabel(ChatToolAction.replyPrivately);
    case MsgAction.thread:
      return tr('Reply in Thread');
    case MsgAction.copy:
      return tr('Copy text');
    case MsgAction.translate:
      return tr('Translate');
    case MsgAction.save:
      return chatToolLabel(ChatToolAction.save);
    case MsgAction.unsave:
      return chatToolLabel(ChatToolAction.unsave);
    case MsgAction.keep:
      return chatToolLabel(ChatToolAction.keep);
    case MsgAction.unkeep:
      return chatToolLabel(ChatToolAction.unkeep);
    case MsgAction.zap:
      return tr('Zap Bitcoin');
    case MsgAction.edit:
      return tr('Edit Message');
    case MsgAction.delete:
      return tr('Delete Message');
    case MsgAction.editHistory:
      return tr('Edit history');
    case MsgAction.eventDetails:
      return tr('Event details');
    case MsgAction.report:
      return tr('Report');
  }
}

const String kMsgHistoryIcon =
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M 2.5 8 A 5.5 5.5 0 1 0 4.1 4.1"/><path d="M 2 2.5 L 2 5 L 4.5 5"/><path d="M 8 5 L 8 8 L 10 9.5"/></svg>';

const String kMsgEventDetailsIcon =
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="6"/><path d="M8 7.2v3.8"/><circle cx="8" cy="5" r="0.6" fill="currentColor" stroke="none"/></svg>';

String msgActionSvg(MsgAction a) {
  switch (a) {
    case MsgAction.reply:
      return ctxActionSvg(CtxAction.quote);
    case MsgAction.replyPrivately:
      return chatToolSvg(ChatToolAction.replyPrivately);
    case MsgAction.thread:
      return NymIcons.thread;
    case MsgAction.copy:
      return ctxActionSvg(CtxAction.copyMessage);
    case MsgAction.translate:
      return ctxActionSvg(CtxAction.translate);
    case MsgAction.save:
      return chatToolSvg(ChatToolAction.save);
    case MsgAction.unsave:
      return chatToolSvg(ChatToolAction.unsave);
    case MsgAction.keep:
      return chatToolSvg(ChatToolAction.keep);
    case MsgAction.unkeep:
      return chatToolSvg(ChatToolAction.unkeep);
    case MsgAction.zap:
      return ctxActionSvg(CtxAction.zap);
    case MsgAction.edit:
      return ctxActionSvg(CtxAction.edit);
    case MsgAction.delete:
      return ctxActionSvg(CtxAction.delete);
    case MsgAction.editHistory:
      return kMsgHistoryIcon;
    case MsgAction.eventDetails:
      return kMsgEventDetailsIcon;
    case MsgAction.report:
      return ctxActionSvg(CtxAction.report);
  }
}

const double kSwipeFollowCap = 100;

double swipeThresholdPx(int setting) =>
    setting.clamp(30, kSwipeFollowCap.toInt()).toDouble();

bool swipeActionApplies(String action, MsgActionFacts f) {
  switch (action) {
    case 'quote':
    case 'copy':
    case 'translate':
      return f.hasContent;
    case 'react':
      return f.hasId;
    case 'zap':
      return f.hasId && f.hasAuthor;
    case 'slap':
    case 'hug':
      return f.hasAuthor && !f.isSelf;
  }
  return false;
}
