import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart' show formatFullTimestamp;
import '../../widgets/chat/messages_list.dart' show messageListScrollerProvider;
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../media_notes/media_notes.dart' show parseMeshFileName;
import '../messages/format/message_content.dart';
import '../messages/inline_network_image.dart';
import '../toasts/toast_center.dart';
import 'chat_tools.dart';
import 'chat_tools_providers.dart';
import 'chat_tools_service.dart';

class ChatToolIcons {
  const ChatToolIcons._();

  static const String _open =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">';
  static const String save = '$_open<path d="M4 2.5h8v11l-4-3-4 3z"/></svg>';
  static const String unsave =
      '$_open<path d="M4 2.5h8v11l-4-3-4 3z"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/></svg>';
  static const String replyPrivately =
      '$_open<path d="M6 4 2 8l4 4"/><path d="M2 8h6.5a5 5 0 0 1 5 5"/><rect x="10" y="2" width="4" height="3.5" rx="0.6"/><path d="M10.8 2V1.4a1.2 1.2 0 0 1 2.4 0V2"/></svg>';
  static const String keep =
      '$_open<path d="M6 2h4l-.8 4 2.8 3H4l2.8-3z"/><line x1="8" y1="9" x2="8" y2="14"/></svg>';
  static const String unkeep =
      '$_open<path d="M6 2h4l-.8 4 2.8 3H4l2.8-3z"/><line x1="8" y1="9" x2="8" y2="14"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/></svg>';
  static const String media =
      '$_open<rect x="2" y="3" width="12" height="10" rx="1"/><circle cx="6" cy="6.8" r="1.2"/><path d="M2 11.5l3.5-3 3 2.5 2-1.8 3.5 3"/></svg>';
  static const String exportChat =
      '$_open<path d="M8 2v8"/><path d="M5 7l3 3 3-3"/><path d="M3 11.5V14h10v-2.5"/></svg>';
  static const String saved =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h12v18l-6-4.5L6 21z"/></svg>';
}

const List<String> kChatToolsStrings = <String>[
  ChatToolsStrings.onceNotSaved,
  ChatToolsStrings.onceExported,
  ChatToolsStrings.localMedia,
  ChatToolsStrings.exportTitle,
  ChatToolsStrings.exportedAt,
  ChatToolsStrings.voice,
  ChatToolsStrings.round,
  'Saved',
  'Saved messages',
  'Save message',
  'Remove from Saved',
  'Reply privately',
  'Keep in chat',
  'Unkeep',
  'Kept',
  'Kept in chat: this message will not disappear',
  'Media, files & links',
  'Export chat',
  'Media',
  'Files',
  'Links',
  'Video',
  'Spoiler',
  'Spoiler, tap to reveal',
  'Jump to original',
  'Remove',
  'Synced across your devices',
  'Will sync when online',
  'Saved on this device only',
  'Saved. It will sync to your other devices when you are back online.',
  'Saved to Saved messages.',
  'No saved messages yet. Use Save message on any message to keep a private copy here.',
  "The original message isn't loaded on this device anymore.",
  'Group: {name}',
  'DM with {name}',
  'Edit history',
  "Earlier versions aren't available on this device.",
  "Earlier versions couldn't be found.",
  'Loading...',
  'Current, edited {time}',
  "Kept here. Others will see it once you're back online.",
  "Unkept here. Others will see it once you're back online.",
  'Kept. Sent over the Bluetooth mesh.',
  'Unkept. Sent over the Bluetooth mesh.',
  "You're offline. Your reply will need the internet or this person in Bluetooth range.",
  'Export {count} messages from {chat} that are on this device.',
  'The .zip adds media already downloaded to this device. View-once media is never exported.',
  'Text transcript (.txt)',
  'Transcript and media (.zip)',
  'Exported {count} messages and {media} media files.',
  "Couldn't open the share sheet: {error}",
  'No media in this chat yet.',
  'No files in this chat yet.',
  'No links in this chat yet.',
  'Load older from archive',
  'This message is no longer available.',
];

enum ChatToolAction { save, unsave, replyPrivately, keep, unkeep, media, export }

List<ChatToolAction> chatToolActionsFor({
  Message? message,
  String? storageKey,
  required String self,
  bool saved = false,
  bool kept = false,
  bool keepOffered = false,
  bool dmHeader = false,
}) {
  final out = <ChatToolAction>[];
  if (message != null && storageKey != null && message.content.isNotEmpty) {
    out.add(saved ? ChatToolAction.unsave : ChatToolAction.save);
    if (replyPrivatelyAllowed(
      surface: chatSurfaceForKey(storageKey),
      pubkey: message.pubkey,
      self: self,
      system: message.isSystemRow,
    )) {
      out.add(ChatToolAction.replyPrivately);
    }
    if (keepOffered) out.add(kept ? ChatToolAction.unkeep : ChatToolAction.keep);
  }
  if (dmHeader) {
    out
      ..add(ChatToolAction.media)
      ..add(ChatToolAction.export);
  }
  return out;
}

String chatToolLabel(ChatToolAction a) {
  switch (a) {
    case ChatToolAction.save:
      return tr('Save message');
    case ChatToolAction.unsave:
      return tr('Remove from Saved');
    case ChatToolAction.replyPrivately:
      return tr('Reply privately');
    case ChatToolAction.keep:
      return tr('Keep in chat');
    case ChatToolAction.unkeep:
      return tr('Unkeep');
    case ChatToolAction.media:
      return tr('Media, files & links');
    case ChatToolAction.export:
      return tr('Export chat');
  }
}

String chatToolSvg(ChatToolAction a) {
  switch (a) {
    case ChatToolAction.save:
      return ChatToolIcons.save;
    case ChatToolAction.unsave:
      return ChatToolIcons.unsave;
    case ChatToolAction.replyPrivately:
      return ChatToolIcons.replyPrivately;
    case ChatToolAction.keep:
      return ChatToolIcons.keep;
    case ChatToolAction.unkeep:
      return ChatToolIcons.unkeep;
    case ChatToolAction.media:
      return ChatToolIcons.media;
    case ChatToolAction.export:
      return ChatToolIcons.exportChat;
  }
}

String chatDisplayNym(AppState s, String pubkey, [String? fallback]) {
  if (pubkey.isEmpty) return fallback ?? '';
  final base = stripPubkeySuffix(pickDisplayNym(s.users[pubkey]?.nym, fallback));
  final name = base.isEmpty ? 'nym' : base;
  if (!RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(pubkey)) {
    return name;
  }
  return '$name#${getPubkeySuffix(pubkey)}';
}

Map<String, String> chatInfoFor(AppState s, String key, {Message? from}) {
  final t = chatSurfaceForKey(key);
  if (t == 'dm') {
    final peer = key.substring(3);
    String? fallback;
    for (final p in s.pmConversations) {
      if (p.pubkey == peer && p.nym.isNotEmpty) fallback = p.nym;
    }
    if (fallback == null && from != null && from.pubkey == peer) {
      fallback = from.author;
    }
    return {'t': t, 'k': key, 'n': chatDisplayNym(s, peer, fallback)};
  }
  if (t == 'group') {
    final gid = key.substring(6);
    String name = '';
    for (final g in s.groups) {
      if (g.id == gid) name = g.name;
    }
    return {'t': t, 'k': key, 'n': name.isEmpty ? tr('Group') : name};
  }
  final name = key.startsWith('#') ? key.substring(1) : key;
  return {'t': t, 'k': '#$name', 'n': '#$name'};
}

class ChatMediaSource {
  ChatMediaSource(this.messages, this.localPaths);
  final List<ChatToolsMessage> messages;
  final Map<String, String> localPaths;
}

ChatMediaSource chatMessagesFor(AppState s, String key) {
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final list = [
    for (final m in s.messages[key] ?? const <Message>[])
      if (!s.isMessageFiltered(m) && !chatToolsHidden(m, nowSec)) m,
  ]..sort(compareMessages);
  final local = <String, String>{};
  final out = <ChatToolsMessage>[];
  for (final m in list) {
    if (m.isSystemRow) continue;
    var content = m.content;
    final path = m.localMediaPath;
    if (path != null && path.isNotEmpty) {
      final lid = _localId(path);
      local['nymlocal:$lid'] = path;
      final mime = m.localMediaMime ?? 'application/octet-stream';
      final note = parseMeshFileName(m.localMediaName ?? '', mime);
      final kind = note?.kind ??
          (mime.startsWith('image/')
              ? 'photo'
              : mime.startsWith('video/')
                  ? 'video'
                  : '');
      final once = note != null && note.once ? ';o=${note.onceId}' : '';
      final token =
          'nymlocal:$lid#nym:v=1${kind.isEmpty ? '' : ';k=$kind'};m=$mime$once';
      content = content.isEmpty ? token : '$content $token';
    }
    out.add(chatToolsMessageOf(m,
            author: m.pubkey.isEmpty ? m.author : chatDisplayNym(s, m.pubkey, m.author))
        .copyWithContent(content));
  }
  return ChatMediaSource(out, local);
}

String _localId(String path) {
  var h = 0;
  for (final c in path.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return 'f${h.toRadixString(36)}';
}

extension on ChatToolsMessage {
  ChatToolsMessage copyWithContent(String content) => ChatToolsMessage(
        id: id,
        nid: nid,
        pubkey: pubkey,
        author: author,
        content: content,
        at: at,
        edited: edited,
        system: system,
        fileOfferName: fileOfferName,
        fileOfferSize: fileOfferSize,
      );
}

typedef ChatToolsReader = T Function<T>(ProviderListenable<T> provider);

void jumpToMessage(ChatToolsReader read, String id) {
  final app = read(appStateProvider.notifier);
  final found = findMessageAnywhere(read(appStateProvider), id);
  if (found == null) {
    showToast(
        tr("The original message isn't loaded on this device anymore."));
    return;
  }
  final key = found.key;
  final ChatView target = key.startsWith('pm-')
      ? ChatView.pm(key.substring(3))
      : key.startsWith('group-')
          ? ChatView.group(key.substring(6))
          : ChatView.channel(key.startsWith('#') ? key.substring(1) : key);
  if (target != read(appStateProvider).view) app.switchView(target);
  final scroller = read(messageListScrollerProvider(target.storageKey));
  final flash = read(flashedMessageProvider.notifier);
  var attempts = 8;
  void tryJump(Duration _) {
    if (scroller.scrollToMessage(found.msg.id)) {
      flash.flash(found.msg.id);
      return;
    }
    if (--attempts > 0) {
      SchedulerBinding.instance.addPostFrameCallback(tryJump);
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  SchedulerBinding.instance.addPostFrameCallback(tryJump);
  SchedulerBinding.instance.scheduleFrame();
}

class ChatToolsActions {
  const ChatToolsActions._();

  static void toggleSave(ChatToolsReader read, Message m) {
    final tools = read(chatToolsProvider);
    final s = read(appStateProvider);
    final found = findMessageAnywhere(s, m.nymMessageId ?? m.id) ??
        findMessageAnywhere(s, m.id);
    if (found == null) {
      showToast(tr('This message is no longer available.'));
      return;
    }
    if (tools.isMessageSaved(found.msg)) {
      tools.removeSavedEntry(found.msg.nymMessageId ?? found.msg.id);
      return;
    }
    tools.saveMessage(found.msg, chatInfoFor(s, found.key, from: found.msg),
        author: chatDisplayNym(s, found.msg.pubkey, found.msg.author));
  }

  static Future<void> toggleKeep(ChatToolsReader read, Message m) async {
    final s = read(appStateProvider);
    final found = findMessageAnywhere(s, m.nymMessageId ?? m.id);
    if (found == null) return;
    await read(chatToolsProvider).toggleKeep(found.msg, found.key);
  }

  static bool replyPrivately(ChatToolsReader read, Message m) {
    final s = read(appStateProvider);
    final found = findMessageAnywhere(s, m.nymMessageId ?? m.id) ??
        findMessageAnywhere(s, m.id);
    final key = found?.key ?? m.conversationKey ?? '#${m.geohash ?? m.channel ?? ''}';
    if (!replyPrivatelyAllowed(
      surface: chatSurfaceForKey(key),
      pubkey: m.pubkey,
      self: s.selfPubkey,
      system: m.isSystemRow,
    )) {
      return false;
    }
    final nym = chatDisplayNym(s, m.pubkey, m.author);
    read(nostrControllerProvider)
        .startPM(m.pubkey, nym: stripPubkeySuffix(nym));
    final hooks = read(pendingComposerActionProvider.notifier);
    final content = m.content;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      hooks.requestQuote(fullNym: nym, content: content);
    });
    SchedulerBinding.instance.scheduleFrame();
    final bridgePeer = read(chatToolsProvider).hooks.meshPeerFor?.call(m.pubkey);
    if (s.connectedRelays == 0 && bridgePeer == null) {
      showToast(tr(
          "You're offline. Your reply will need the internet or this person in Bluetooth range."));
    }
    return true;
  }
}

Future<bool?> _showPanel(BuildContext context, Widget child) {
  final isLight = context.nym.isLight;
  return showDialog<bool>(
    context: context,
    barrierColor: isLight ? const Color(0x73000000) : const Color(0xBF000000),
    builder: (_) => child,
  );
}

class _PanelShell extends StatelessWidget {
  const _PanelShell({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = MediaQuery.of(context).size;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: size.width * 0.92,
          constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height * 0.88),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            border: Border.all(color: c.glassBorder),
          ),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Close'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.close, size: 18, color: c.textDim),
                  ),
                ],
              ),
              Divider(color: c.glassBorder, height: 16),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton(
      {super.key, required this.label, required this.onTap, this.danger = false});

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: danger ? c.danger : c.text,
        side: BorderSide(color: c.glassBorder),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        textStyle: const TextStyle(fontSize: 13),
      ),
      child: Text(label),
    );
  }
}

class SavedMessagesPanel extends ConsumerWidget {
  const SavedMessagesPanel({super.key});

  static Future<void> open(BuildContext context) {
    final tools = ProviderScope.containerOf(context).read(chatToolsProvider);
    unawaited(tools.syncSaved());
    return _showPanel(context, const SavedMessagesPanel());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatToolsRevisionProvider);
    final c = context.nym;
    final tools = ref.read(chatToolsProvider);
    final settings = ref.watch(settingsProvider);
    final items = tools.savedItems;
    final status = tools.savedStatus;
    final statusText = status == SavedStatus.local
        ? tr('Saved on this device only')
        : status == SavedStatus.pending
            ? tr('Will sync when online')
            : tr('Synced across your devices');
    return _PanelShell(
      title: tr('Saved messages'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey('savedStatus'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rxs,
              border: Border.all(
                  color: status == SavedStatus.pending ? c.warning : c.glassBorder),
            ),
            child: Text(statusText,
                style: TextStyle(
                    fontSize: 12,
                    color: status == SavedStatus.pending ? c.warning : c.textDim)),
          ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                tr('No saved messages yet. Use Save message on any message to keep a private copy here.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textDim, fontStyle: FontStyle.italic),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final e = items[i];
                  final chat = e['chat'] as Map;
                  final a = e['a'] as Map;
                  final chatLabel = chat['t'] == 'channel'
                      ? '${chat['n']}'
                      : chat['t'] == 'group'
                          ? tr('Group: {name}', {'name': '${chat['n']}'})
                          : tr('DM with {name}', {'name': '${chat['n']}'});
                  final when = formatFullTimestamp(
                      DateTime.fromMillisecondsSinceEpoch(
                          ((e['at'] as num?)?.toInt() ?? 0) * 1000),
                      settings.timeFormat,
                      settings.dateFormat);
                  return Container(
                    key: ValueKey('saved-${e['id']}'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      borderRadius: NymRadius.rxs,
                      border: Border.all(color: c.glassBorder),
                      color: c.primaryA(0.03),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(spacing: 8, children: [
                          Text('${a['n']}',
                              style: TextStyle(
                                  color: c.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          Text(chatLabel,
                              style: TextStyle(color: c.textDim, fontSize: 12)),
                          Text(when,
                              style: TextStyle(color: c.textDim, fontSize: 12)),
                        ]),
                        const SizedBox(height: 6),
                        MessageContent(content: '${e['text']}', nostrRefCards: false),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, children: [
                          _ToolButton(
                            label: tr('Jump to original'),
                            onTap: () {
                              Navigator.of(context).maybePop();
                              final nid = '${e['nid'] ?? ''}';
                              jumpToMessage(ref.read, nid.isNotEmpty ? nid : '${e['mid']}');
                            },
                          ),
                          _ToolButton(
                            label: tr('Remove'),
                            danger: true,
                            onTap: () => tools.removeSavedEntry('${e['id']}'),
                          ),
                        ]),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class EditHistorySheet extends ConsumerStatefulWidget {
  const EditHistorySheet({super.key, required this.message});

  final Message message;

  static Future<void> open(BuildContext context, Message message) =>
      _showPanel(context, EditHistorySheet(message: message));

  @override
  ConsumerState<EditHistorySheet> createState() => _EditHistorySheetState();
}

class _EditHistorySheetState extends ConsumerState<EditHistorySheet> {
  late String _view;

  @override
  void initState() {
    super.initState();
    final tools = ref.read(chatToolsProvider);
    final plan = tools.editHistoryPlanFor(widget.message);
    _view = plan.view;
    if (plan.fetch) {
      tools.fetchEditHistory(widget.message).then((view) {
        if (mounted) setState(() => _view = view);
      });
    }
  }

  Widget _note(BuildContext context, String text) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Text(tr(text),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, fontStyle: FontStyle.italic)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final message = widget.message;
    String when(int at) => formatFullTimestamp(
        DateTime.fromMillisecondsSinceEpoch(at * 1000),
        settings.timeFormat,
        settings.dateFormat);
    if (_view == 'loading') {
      return _PanelShell(
          title: tr('Edit history'), child: _note(context, 'Loading...'));
    }
    if (_view == 'notFound') {
      return _PanelShell(
          title: tr('Edit history'),
          child: _note(context, "Earlier versions couldn't be found."));
    }
    final rec = ref.read(chatToolsProvider).editHistoryFor(chatDomId(message));
    if (_view != 'versions' || rec == null || rec.versions.isEmpty) {
      return _PanelShell(
          title: tr('Edit history'),
          child: _note(context, "Earlier versions aren't available on this device."));
    }
    final timeline = editTimeline(rec, message.content);
    return _PanelShell(
      title: tr('Edit history'),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: timeline.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final v = timeline[i];
          return Container(
            key: ValueKey('version-$i'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rxs,
              border: Border.all(
                  color: v.current ? c.primaryA(0.4) : c.glassBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.current
                      ? tr('Current, edited {time}', {'time': when(v.at)})
                      : when(v.at),
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
                const SizedBox(height: 4),
                MessageContent(content: v.text, nostrRefCards: false),
              ],
            ),
          );
        },
      ),
    );
  }
}

class EditedLabel extends StatelessWidget {
  const EditedLabel({super.key, required this.message, required this.style, this.trailingSpace = false});

  final Message message;
  final TextStyle style;
  final bool trailingSpace;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => EditHistorySheet.open(context, message),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Text('${tr('(edited)')}${trailingSpace ? ' ' : ''}',
              style: style.copyWith(decoration: TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted)),
        ),
      ),
    );
  }
}

class KeptBadge extends ConsumerWidget {
  const KeptBadge({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatToolsRevisionProvider);
    if (!ref.read(chatToolsProvider).isMessageKept(message)) {
      return const SizedBox.shrink();
    }
    final c = context.nym;
    return Tooltip(
      message: tr('Kept in chat: this message will not disappear'),
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          border: Border.all(color: c.primaryA(0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(tr('Kept'), style: TextStyle(color: c.primary, fontSize: 10)),
      ),
    );
  }
}

class ChatMediaPanel extends ConsumerStatefulWidget {
  const ChatMediaPanel({super.key, required this.storageKey});

  final String storageKey;

  static Future<bool?> open(BuildContext context, String storageKey) =>
      _showPanel(context, ChatMediaPanel(storageKey: storageKey));

  @override
  ConsumerState<ChatMediaPanel> createState() => _ChatMediaPanelState();
}

class _ChatMediaPanelState extends ConsumerState<ChatMediaPanel> {
  String _tab = 'media';
  final Set<String> _revealed = <String>{};
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final app = ref.watch(appStateProvider);
    final settings = ref.watch(settingsProvider);
    final src = chatMessagesFor(app, widget.storageKey);
    final gallery = galleryItems(src.messages);
    final items = gallery.tab(_tab);
    final canOlder = ref.read(nostrControllerProvider).canLoadOlderArchive(widget.storageKey);
    String when(int at) => formatFullTimestamp(
        DateTime.fromMillisecondsSinceEpoch(at * 1000),
        settings.timeFormat,
        settings.dateFormat);
    Widget tabButton(String id, String label) {
      final active = _tab == id;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: TextButton(
          key: ValueKey('tab-$id'),
          onPressed: () => setState(() {
            _tab = id;
            _revealed.clear();
          }),
          style: TextButton.styleFrom(
            foregroundColor: active ? c.primary : c.textDim,
            side: BorderSide(color: active ? c.primaryA(0.4) : Colors.transparent),
          ),
          child: Text('$label ${gallery.tab(id).length}'),
        ),
      );
    }

    void open(GalleryItem it, String key) {
      if (it.spoiler && !_revealed.contains(key)) {
        setState(() => _revealed.add(key));
        return;
      }
      if (_tab == 'media') {
        final viewer = <ViewerItem>[];
        for (var i = 0; i < items.length; i++) {
          final m = items[i];
          final path = src.localPaths[m.url];
          viewer.add(ViewerItem(
            url: m.url,
            isVideo: m.kind == 'video',
            spoiler: m.spoiler,
            revealed: _revealed.contains('$i:${m.url}'),
            image: path != null && m.kind == 'image' ? FileImage(File(path)) : null,
            id: i,
          ));
        }
        final at = viewer.indexWhere((v) => '${v.id}:${v.url}' == key);
        if (at >= 0) {
          openMediaViewer(context, viewer, at, onReveal: (v) {
            if (mounted) setState(() => _revealed.add('${v.id}:${v.url}'));
          });
          return;
        }
      }
      Navigator.of(context).pop(true);
      jumpToMessage(ref.read, it.nid.isNotEmpty ? it.nid : it.mid);
    }

    String label(GalleryItem it) => it.kind == 'audio' && it.name == 'voice'
        ? tr(ChatToolsStrings.voice)
        : it.name == 'round'
            ? tr(ChatToolsStrings.round)
            : it.name;

    Widget body;
    if (items.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _tab == 'media'
              ? tr('No media in this chat yet.')
              : _tab == 'files'
                  ? tr('No files in this chat yet.')
                  : tr('No links in this chat yet.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, fontStyle: FontStyle.italic),
        ),
      );
    } else if (_tab == 'media') {
      body = GridView.builder(
        shrinkWrap: true,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 110, mainAxisSpacing: 6, crossAxisSpacing: 6),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final it = items[i];
          final key = '$i:${it.url}';
          final hidden = it.spoiler && !_revealed.contains(key);
          Widget thumb;
          if (it.kind == 'image') {
            final path = src.localPaths[it.url];
            thumb = path != null
                ? Image.file(File(path), fit: BoxFit.cover)
                : InlineNetworkImage(url: proxiedMedia(it.url), fit: BoxFit.cover);
          } else {
            thumb = Center(
                child: Text(it.name == 'round' ? tr(ChatToolsStrings.round) : tr('Video'),
                    style: TextStyle(color: c.textDim, fontSize: 12)));
          }
          if (hidden) {
            thumb = Stack(fit: StackFit.expand, children: [
              ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: thumb),
              Container(
                color: const Color(0x59000000),
                alignment: Alignment.center,
                child: Text(tr('Spoiler'),
                    style: TextStyle(color: c.text, fontSize: 12)),
              ),
            ]);
          }
          return Semantics(
            button: true,
            label: hidden ? tr('Spoiler, tap to reveal') : label(it),
            child: GestureDetector(
              key: ValueKey('media-$i'),
              onTap: () => open(it, key),
              child: ClipRRect(
                borderRadius: NymRadius.rxs,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.glassBorder),
                    color: c.primaryA(0.05),
                  ),
                  child: thumb,
                ),
              ),
            ),
          );
        },
      );
    } else {
      body = ListView.separated(
        shrinkWrap: true,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, i) {
          final it = items[i];
          final key = '$i:${it.url}:${it.name}';
          final hidden = it.spoiler && !_revealed.contains(key);
          final main = hidden
              ? tr('Spoiler, tap to reveal')
              : (_tab == 'links' ? it.url : label(it));
          return InkWell(
            key: ValueKey('row-$i'),
            onTap: () => open(it, key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rxs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(main,
                      style: TextStyle(
                          color: hidden ? c.textDim : c.text,
                          fontStyle: hidden ? FontStyle.italic : FontStyle.normal,
                          fontSize: 13)),
                  Text('${it.author} · ${when(it.at)}',
                      style: TextStyle(color: c.textDim, fontSize: 11)),
                ],
              ),
            ),
          );
        },
      );
    }

    return _PanelShell(
      title: tr('Media, files & links'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            tabButton('media', tr('Media')),
            tabButton('files', tr('Files')),
            tabButton('links', tr('Links')),
          ]),
          const SizedBox(height: 8),
          Flexible(child: body),
          if (canOlder)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _ToolButton(
                  label: tr('Load older from archive'),
                  onTap: () async {
                    if (_loading) return;
                    setState(() => _loading = true);
                    try {
                      await ref
                          .read(nostrControllerProvider)
                          .loadOlderArchive(widget.storageKey);
                    } finally {
                      if (mounted) setState(() => _loading = false);
                    }
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ExportChatPanel extends ConsumerWidget {
  const ExportChatPanel({super.key, required this.storageKey});

  final String storageKey;

  static Future<bool?> open(BuildContext context, String storageKey) =>
      _showPanel(context, ExportChatPanel(storageKey: storageKey));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final app = ref.watch(appStateProvider);
    final info = chatInfoFor(app, storageKey);
    final count = chatMessagesFor(app, storageKey).messages.where((m) => !m.system).length;
    return _PanelShell(
      title: tr('Export chat'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Export {count} messages from {chat} that are on this device.',
                  {'count': count, 'chat': info['n']}),
              style: TextStyle(color: c.textDim, fontSize: 13)),
          const SizedBox(height: 6),
          Text(tr('The .zip adds media already downloaded to this device. View-once media is never exported.'),
              style: TextStyle(color: c.textDim, fontSize: 13)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _ToolButton(
              key: const ValueKey('exportTxt'),
              label: tr('Text transcript (.txt)'),
              onTap: () async {
                Navigator.of(context).pop(true);
                await ChatExporter(ref.read).exportText(storageKey);
              },
            ),
            _ToolButton(
              key: const ValueKey('exportZip'),
              label: tr('Transcript and media (.zip)'),
              onTap: () async {
                Navigator.of(context).pop(true);
                await ChatExporter(ref.read).exportZip(storageKey);
              },
            ),
          ]),
        ],
      ),
    );
  }
}

typedef ChatExportSink = Future<void> Function(String fileName, Uint8List bytes, String mime);

class ChatExporter {
  ChatExporter(this._read, {this.sink, this.cachedBytes, this.nowMs});

  final T Function<T>(ProviderListenable<T>) _read;
  final ChatExportSink? sink;
  final Future<Uint8List?> Function(String url, String? localPath)? cachedBytes;
  final int Function()? nowMs;

  int get _now => nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
  int get _offsetMin => DateTime.fromMillisecondsSinceEpoch(_now).timeZoneOffset.inMinutes;

  String transcript(String storageKey, [Map<String, String>? names]) {
    final app = _read(appStateProvider);
    final info = chatInfoFor(app, storageKey);
    return exportTranscript(
      title: info['n']!,
      messages: chatMessagesFor(app, storageKey).messages,
      exportedAtMs: _now,
      offsetMin: _offsetMin,
      t: tr,
      mediaNames: names,
    );
  }

  Future<String> exportText(String storageKey) async {
    final app = _read(appStateProvider);
    final info = chatInfoFor(app, storageKey);
    final text = transcript(storageKey);
    final name = exportFileName(info['n']!, _now, _offsetMin, 'txt');
    await _deliver(name, Uint8List.fromList(utf8.encode(text)), 'text/plain');
    return name;
  }

  Future<({String name, List<String> entries})> exportZip(String storageKey) async {
    final app = _read(appStateProvider);
    final info = chatInfoFor(app, storageKey);
    final src = chatMessagesFor(app, storageKey);
    final plan = exportMediaPlan(src.messages);
    final names = <String, String>{};
    final entries = <ZipEntry>[];
    for (final p in plan) {
      final bytes = await (cachedBytes ?? _defaultCachedBytes)(p.url, src.localPaths[p.url]);
      if (bytes == null) continue;
      names[p.url] = p.name;
      entries.add(ZipEntry('media/${p.name}', bytes));
    }
    final text = transcript(storageKey, names);
    entries.insert(0, ZipEntry('transcript.txt', utf8.encode(text)));
    final zip = zipStore(entries, _now, _offsetMin);
    final name = exportFileName(info['n']!, _now, _offsetMin, 'zip');
    await _deliver(name, zip, 'application/zip');
    showToast(tr(
        'Exported {count} messages and {media} media files.',
        {'count': src.messages.where((m) => !m.system).length, 'media': entries.length - 1}));
    return (name: name, entries: [for (final e in entries) e.name]);
  }

  static Future<Uint8List?> _defaultCachedBytes(String url, String? localPath) async {
    try {
      if (localPath != null) return await File(localPath).readAsBytes();
      if (!url.startsWith('http')) return null;
      return await InlineNetworkImage.resolveBytes(proxiedMedia(url), fetchIfMissing: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _deliver(String name, Uint8List bytes, String mime) async {
    final out = sink;
    if (out != null) return out(name, bytes, mime);
    try {
      final desktop = !kIsWeb && (Platform.isLinux || Platform.isWindows);
      if (desktop) {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await File(loc.path).writeAsBytes(bytes, flush: true);
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$name';
      await File(path).writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(path, mimeType: mime)], subject: name));
    } catch (e) {
      showToast(
          tr("Couldn't open the share sheet: {error}", {'error': '$e'}));
    }
  }
}

class SavedMessagesButtonIcon extends StatelessWidget {
  const SavedMessagesButtonIcon({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      NymSvgIcon(ChatToolIcons.saved, size: size, color: color);
}
