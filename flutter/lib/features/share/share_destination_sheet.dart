import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_field.dart';

class SharedPayload {
  const SharedPayload({this.text, this.filePaths = const []});
  final String? text;
  final List<String> filePaths;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) && filePaths.isEmpty;
}

/// Picks a channel, PM or group for a shared payload and drops it into that composer; nothing auto-sends.
Future<void> showShareDestinationSheet(
  BuildContext context,
  WidgetRef ref,
  SharedPayload payload,
) {
  if (payload.isEmpty) return Future.value();
  return showNymBottomSheet<void>(
    context,
    (_) => _ShareDestinationSheet(payload: payload),
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
    // Files first so an accompanying caption lands below them.
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

    final chanMatches = [
      for (final ch in channels)
        if (_matches(ch.isGeohash ? ch.geohashKey : ch.channel)) ch
    ];
    if (chanMatches.isNotEmpty) {
      section(tr('Channels'));
      for (final ch in chanMatches) {
        final label = '#${ch.isGeohash ? ch.geohashKey : ch.channel}';
        rows.add(_row(
            c,
            NymSvgIcon(channelGlyphSvg(geohash: ch.isGeohash),
                size: 18, color: c.primary),
            label,
            () => _deliverTo(ChatView.channel(ch.key))));
      }
    }

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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
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
            style: TextStyle(color: c.inputText),
            decoration: NymField.decoration(c,
              hint: tr('Search conversations'),
              radius: BorderRadius.circular(10),
              prefixIcon: Icon(Icons.search, size: 18, color: NymField.icon(c))),
          ),
        ),
        Flexible(
          child: ListView(
              padding: const EdgeInsets.only(bottom: 20), children: rows),
        ),
      ],
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
