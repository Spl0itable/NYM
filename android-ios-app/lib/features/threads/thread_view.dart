import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart';
import '../../widgets/chat/typing_indicator.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../reactions/reaction_picker.dart';

/// Opens the thread view for [m]'s thread (its own thread, or its root's when
/// [m] is already a reply). The conversation is focused first so the shared
/// composer — which attaches the thread root to every send while a thread is
/// open — always targets the right conversation; the message area then swaps
/// to the thread in place (PWA `openThreadView`).
void openMessageThread(WidgetRef ref, Message m,
    {String? storageKey, bool silent = false}) {
  if (!appThreadsEnabled) return;
  final app = ref.read(appStateProvider);
  final key = storageKey ?? app.view.storageKey;
  var root = m;
  final rootRef = m.threadRoot;
  if (rootRef != null) {
    root = threadRootMessage(app, key, rootRef) ?? m;
  }
  if (!threadEligibleRoot(root)) {
    if (!silent) {
      ref.read(appStateProvider.notifier).addSystemMessage(tr(
          'This message cannot start a thread yet — try again once it has '
          'finished sending.'));
    }
    return;
  }
  final view = _viewForStorageKey(key) ?? app.view;
  if (view != app.view) {
    ref.read(appStateProvider.notifier).switchView(view);
  }
  // Post-frame: the view switch above may fire listeners that clear the
  // active thread; setting it afterwards wins either order.
  final target = ActiveThread(view: view, rootId: threadKeyForMessage(root));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(activeThreadProvider.notifier).state = target;
  });
  ref.read(activeThreadProvider.notifier).state = target;
}

ChatView? _viewForStorageKey(String key) {
  if (key.startsWith('#')) return ChatView.channel(key.substring(1));
  if (key.startsWith('pm-')) return ChatView.pm(key.substring(3));
  if (key.startsWith('group-')) return ChatView.group(key.substring(6));
  return null;
}

/// The in-place thread view: replaces the conversation's messages list while a
/// thread is open — back bar, the root message, a reply divider, then the
/// replies — with the same composer below it (the controller attaches the
/// thread root to sends while [activeThreadProvider] is set). The chat
/// header's back/forward buttons step in and out of it.
class ThreadView extends ConsumerStatefulWidget {
  const ThreadView({super.key, required this.thread});
  final ActiveThread thread;

  @override
  ConsumerState<ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends ConsumerState<ThreadView> {
  final ScrollController _scroll = ScrollController();
  int _lastReplyCount = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    ref.read(activeThreadProvider.notifier).state = null;
  }

  String _contextLabel(AppState app) {
    final view = widget.thread.view;
    switch (view.kind) {
      case ViewKind.channel:
        return '#${view.id}';
      case ViewKind.group:
        final g = ref.read(appStateProvider.notifier).groupById(view.id);
        final name = g?.name ?? '';
        return name.isNotEmpty ? name : tr('Group chat');
      case ViewKind.pm:
        final root =
            threadRootMessage(app, view.storageKey, widget.thread.rootId);
        final peerNym = app.users[view.id]?.nym ?? '';
        if (peerNym.isNotEmpty) return '@$peerNym';
        return root != null ? '@${root.author}' : tr('Private message');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    // Re-render on every display revision (new replies, edits, reactions).
    ref.watch(appStateProvider.select((s) => s.displayRev));
    final app = ref.read(appStateProvider);
    final storageKey = widget.thread.view.storageKey;
    final root = threadRootMessage(app, storageKey, widget.thread.rootId);
    final replies = threadRepliesFor(app, storageKey, widget.thread.rootId);
    final reactions = ref.watch(reactionsProvider);

    // Pin to the newest reply when one arrives while the thread is open.
    if (replies.length != _lastReplyCount) {
      _lastReplyCount = replies.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    Widget row(Message m) => MessageRow(
          key: ValueKey('thread_${m.id}'),
          message: m,
          settings: settings,
          reactions: reactions[m.id] ?? const [],
          scrollKey: storageKey,
          onReactionPicker: (msg) => showReactionPicker(context, ref, msg),
          showThreadAffordances: false,
        );

    // Same translucent wash as `.messages-container` so the thread view reads
    // as the same surface the conversation list uses.
    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF) // white @ 0.3
        : const Color(0x26000000); // black @ 0.15

    return ColoredBox(
      color: containerColor,
      child: Column(
        children: [
          // In-view thread bar (`.thread-view-bar`): back chevron, thread
          // icon + title, the conversation label.
          Container(
            margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: c.primaryA(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.glassBorder),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: _close,
                  tooltip: tr('Back'),
                  visualDensity: VisualDensity.compact,
                  icon: NymSvgIcon(NymIcons.chevronLeft,
                      size: 16, color: c.text),
                ),
                NymSvgIcon(NymIcons.thread, size: 14, color: c.primary),
                const SizedBox(width: 6),
                Text(
                  tr('Thread'),
                  style: TextStyle(
                    color: c.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _contextLabel(app),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              children: [
                if (root != null)
                  row(root)
                else
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      tr('Original message unavailable'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textDim, fontSize: 12),
                    ),
                  ),
                // `.thread-replies-divider`
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                  child: Row(
                    children: [
                      NymSvgIcon(NymIcons.thread, size: 14, color: c.textDim),
                      const SizedBox(width: 6),
                      Text(
                        replies.isEmpty
                            ? tr('No replies yet')
                            : replies.length == 1
                                ? tr('1 reply')
                                // Abbreviated like reaction badges.
                                : tr('{n} replies',
                                    {'n': abbreviateNumber(replies.length)}),
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: 11,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Divider(color: c.glassBorder, height: 1)),
                    ],
                  ),
                ),
                for (final m in replies) ...[
                  row(m),
                  const SizedBox(height: 3),
                ],
              ],
            ),
          ),
          const TypingIndicatorRow(),
        ],
      ),
    );
  }
}
