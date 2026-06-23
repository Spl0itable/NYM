import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/reactions/reaction_picker.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import 'message_row.dart';

/// The scrolling message list (`.messages-container`, column-reverse). Renders
/// `messagesForCurrentViewProvider` newest-at-bottom via a reversed ListView,
/// supporting both IRC and bubble layouts. Bubble mode groups consecutive
/// same-author messages within 5 minutes (collapse name + tail). (docs/specs/02
/// §6, docs/specs/03 §2.7)
class MessagesList extends ConsumerWidget {
  const MessagesList({super.key});

  static const int _groupWindowSec = 300; // 5 min

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final messages = ref.watch(messagesForCurrentViewProvider);
    final reactions = ref.watch(reactionsProvider);

    // `.messages-container`: bg rgba(0,0,0,0.15), padding 8px 20px 16px.
    final containerColor = Colors.black.withValues(alpha: 0.15);

    if (messages.isEmpty) {
      return ColoredBox(
        color: containerColor,
        child: Center(
          child: Text(
            'No messages yet',
            style: TextStyle(color: c.textDim, fontSize: 13),
          ),
        ),
      );
    }

    // Precompute bubble grouping flags (in chronological order).
    final groupedWithPrev = List<bool>.filled(messages.length, false);
    final hasNextSameGroup = List<bool>.filled(messages.length, false);
    for (var i = 1; i < messages.length; i++) {
      final prev = messages[i - 1];
      final cur = messages[i];
      final same = prev.pubkey == cur.pubkey &&
          (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;
      groupedWithPrev[i] = same;
      if (same) hasNextSameGroup[i - 1] = true;
    }

    final mentionToken = '@${_baseNym(app.selfNym)}';

    // Reversed list: index 0 = newest at the bottom.
    return ColoredBox(
      color: containerColor,
      child: ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      itemCount: messages.length,
      itemBuilder: (context, revIndex) {
        final i = messages.length - 1 - revIndex;
        final m = messages[i];
        final grouped = settings.useBubbles && groupedWithPrev[i];
        // In a bubble group, the avatar sits with the LAST bubble (sticky
        // bottom); show it when the next message starts a new group/author.
        final showAvatar = !hasNextSameGroup[i];
        final mentioned = !m.isOwn && m.content.contains(mentionToken);

        return MessageRow(
          message: m,
          settings: settings,
          reactions: reactions[m.id] ?? const [],
          mentioned: mentioned,
          grouped: grouped,
          showAvatar: showAvatar,
          showName: !grouped,
          onReactionPicker: (msg) => showReactionPicker(context, ref, msg),
        );
      },
      ),
    );
  }

  String _baseNym(String nym) {
    final hash = nym.indexOf('#');
    return hash > 0 ? nym.substring(0, hash) : nym;
  }
}
