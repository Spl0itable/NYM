import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/i18n/i18n.dart';
import '../../features/layout/layout_model.dart';
import '../../features/messages/format/nym_format.dart';
import '../../features/notifications/notifications_service.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import 'sidebar_chrome.dart';

final rowClockProvider = StateProvider<int>((ref) => 0);

typedef RowLast = ({String id, String author, String content, bool own, int ts});

RowLast? lastPreviewable(List<Message>? list) {
  if (list == null) return null;
  for (var i = list.length - 1; i >= 0; i--) {
    final m = list[i];
    if (m.isSystemRow || m.blocked || m.spamGated) continue;
    final ts = m.ms > 0 ? m.ms : m.createdAt * 1000;
    return (
      id: m.id,
      author: m.author,
      content: m.content,
      own: m.isOwn,
      ts: ts,
    );
  }
  return null;
}

String _ui(String s, [Map<String, Object?>? vars]) => tr(s);

String previewBody(String content) =>
    NymFormat.stripForPreview(notificationBodyFor(content));

({String text, String time, int ts}) sidebarRowPreview(
    WidgetRef ref, String storageKey, String kind) {
  final last = ref.watch(
      appStateProvider.select((s) => lastPreviewable(s.messages[storageKey])));
  final hide = ref.watch(settingsProvider.select((s) => s.hidePreviews));
  ref.watch(chatLockRevisionProvider);
  ref.watch(rowClockProvider);
  if (last == null) return (text: '', time: '', ts: 0);
  final lock = ref.read(chatLockProvider);
  final locked = lock.isConversationLocked(storageKey);
  final text = rowPreview(
    kind: kind,
    author: stripPubkeySuffix(last.author),
    self: last.own,
    text: previewBody(last.content),
    hide: hide,
    locked: locked,
    redacted: locked ? lock.redact('', '', true).body : '',
    t: _ui,
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  return (text: text, time: relativeTime(now, last.ts, _ui), ts: last.ts);
}

Widget rowPreviewLine(BuildContext context, String text, String kind) {
  final c = context.nym;
  return Padding(
    padding: const EdgeInsets.only(top: 1),
    child: Text(
      text,
      key: ValueKey('rowPreview-$kind'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: TextStyle(
          color: c.textDim,
          fontSize: NymType.sm,
          height: kSidebarSubLine / NymType.sm),
    ),
  );
}

Widget rowTimeLabel(BuildContext context, String time) {
  if (time.isEmpty) return const SizedBox.shrink();
  final c = context.nym;
  return Padding(
    padding: const EdgeInsets.only(left: NymSpace.s1),
    child: Text(
      time,
      key: const ValueKey('rowTime'),
      style: TextStyle(
        color: c.textDim,
        fontSize: NymType.xs,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
