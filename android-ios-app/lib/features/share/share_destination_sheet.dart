import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../i18n/i18n.dart';

/// What the OS share sheet handed us: some text/URL, and/or local media paths.
class SharedPayload {
  const SharedPayload({this.text, this.filePaths = const []});
  final String? text;
  final List<String> filePaths;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) && filePaths.isEmpty;
}

/// A bottom sheet that lets the user pick where a shared payload should go —
/// a channel, a private message, or a group — then routes there and drops the
/// payload into that conversation's composer (text is appended for review;
/// media runs through the normal upload pipeline). Nothing is sent
/// automatically: the user reviews and hits send.
Future<void> showShareDestinationSheet(
  BuildContext context,
  WidgetRef ref,
  SharedPayload payload,
) {
  if (payload.isEmpty) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ShareDestinationSheet(payload: payload),
  );
}

class _ShareDestinationSheet extends ConsumerStatefulWidget {
  const _ShareDestinationSheet({required this.payload});
  final SharedPayload payload;

  @override
  ConsumerState<_ShareDestinationSheet> createState() =>
      _ShareDestinationSheetState();
}

class _ShareDestinationSheetState
    extends ConsumerState<_ShareDestinationSheet> {
  String _query = '';

  void _deliverTo(ChatView view) {
    final notifier = ref.read(appStateProvider.notifier);
    final hooks = ref.read(pendingComposerActionProvider.notifier);
    notifier.switchView(view);
    // Post the payload to the (now-active) conversation's composer. Files first
    // so an accompanying caption ends up below them, matching how a user would
    // type after attaching.
    if (widget.payload.filePaths.isNotEmpty) {
      hooks.requestShareFiles(widget.payload.filePaths);
    }
    final text = widget.payload.text?.trim();
    if (text != null && text.isNotEmpty) {
      hooks.requestInsertText(text);
    }
    Navigator.of(context).maybePop();
  }

  bool _matches(String label) =>
      _query.isEmpty || label.toLowerCase().contains(_query.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final channels = ref.watch(channelsProvider);
    final pms = ref.watch(pmListProvider);
    final groups = ref.watch(groupsProvider);

    final rows = <Widget>[];
    void section(String title) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
        child: Text(title.toUpperCase(),
            style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
      ));
    }

    // Channels
    final chanMatches = [
      for (final ch in channels)
        if (_matches(ch.isGeohash ? ch.geohash : ch.channel)) ch
    ];
    if (chanMatches.isNotEmpty) {
      section(tr('Channels'));
      for (final ch in chanMatches) {
        final label = '#${ch.isGeohash ? ch.geohash : ch.channel}';
        rows.add(_row(
            c,
            Text('#',
                style:
                    TextStyle(color: c.primary, fontWeight: FontWeight.w700)),
            label,
            () => _deliverTo(ChatView.channel(ch.key))));
      }
    }

    // Private messages
    final pmMatches = [
      for (final pm in pms)
        if (_matches(getNymFromPubkey(pm.nym, pm.pubkey))) pm
    ];
    if (pmMatches.isNotEmpty) {
      section(tr('Private messages'));
      for (final pm in pmMatches) {
        rows.add(_row(
            c,
            Icon(Icons.person, size: 18, color: c.primary),
            getNymFromPubkey(pm.nym, pm.pubkey),
            () => _deliverTo(ChatView.pm(pm.pubkey))));
      }
    }

    // Groups
    final groupMatches = [
      for (final g in groups)
        if (_matches(g.name.isEmpty ? tr('Group') : g.name)) g
    ];
    if (groupMatches.isNotEmpty) {
      section(tr('Groups'));
      for (final g in groupMatches) {
        rows.add(_row(
            c,
            Icon(Icons.group, size: 18, color: c.primary),
            g.name.isEmpty ? tr('Group') : g.name,
            () => _deliverTo(ChatView.group(g.id))));
      }
    }

    if (rows.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Text(tr('No conversations match'),
              style: TextStyle(color: c.textDim)),
        ),
      ));
    }

    final preview = widget.payload.filePaths.isNotEmpty
        ? tr('{n} file(s)', {'n': '${widget.payload.filePaths.length}'})
        : (widget.payload.text ?? '');

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border.all(color: c.glassBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: c.textDim.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Share to…'),
                      style: TextStyle(
                          color: c.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  if (preview.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: c.text),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18, color: c.textDim),
                  hintText: tr('Search conversations'),
                  hintStyle: TextStyle(color: c.textDim),
                  filled: true,
                  fillColor: c.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.glassBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.glassBorder),
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                  padding: const EdgeInsets.only(bottom: 20), children: rows),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(NymColors c, Widget leading, String label, VoidCallback onTap) {
    return ListTile(
      dense: true,
      leading: SizedBox(width: 24, child: Center(child: leading)),
      title: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c.text)),
      onTap: onTap,
    );
  }
}
