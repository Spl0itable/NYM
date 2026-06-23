import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../chat/message_row.dart';
import '../wallpaper/wallpaper_layer.dart';

/// Fixed dimensions from `css/styles-columns.css`.
class _CvDimens {
  static const double column = 360; // .cv-column flex-basis/width
  static const double addColumn = 220; // .cv-add-column width
  static const double gap = 12; // .cv-strip gap
  static const double padding = 12; // .cv-strip padding
}

/// The deck / multi-column view (`#columnsStrip .cv-strip`), shown when
/// `settings.chatViewMode == 'columns'`.
///
/// A horizontally-scrollable strip of 360px-wide channel columns, each a header
/// (icon + title) over a compact reversed message list, ending in a 220px
/// dashed "+ Add column" affordance. Seeded from the registered channels. When
/// `settings.columnsWallpaper` is on, the per-column backgrounds go transparent
/// so the [WallpaperLayer] behind the deck shows through (`.columns-wallpaper`).
class ColumnsDeck extends ConsumerStatefulWidget {
  const ColumnsDeck({super.key});

  @override
  ConsumerState<ColumnsDeck> createState() => _ColumnsDeckState();
}

class _ColumnsDeckState extends ConsumerState<ColumnsDeck> {
  /// The set of channel keys currently shown as columns. Seeded from the
  /// registered channels on first build (matches `_cvSeedDefaults`).
  final List<String> _columnKeys = [];
  bool _seeded = false;

  void _seedIfNeeded(List<ChannelEntry> channels) {
    if (_seeded) return;
    _seeded = true;
    for (final ch in channels) {
      _columnKeys.add(ch.key);
    }
    if (_columnKeys.isEmpty && channels.isNotEmpty) {
      _columnKeys.add(channels.first.key);
    }
  }

  void _removeColumn(String key) {
    setState(() => _columnKeys.remove(key));
  }

  Future<void> _openAddColumn(List<ChannelEntry> channels) async {
    final available =
        channels.where((ch) => !_columnKeys.contains(ch.key)).toList();
    final picked = await showModalBottomSheet<ChannelEntry>(
      context: context,
      backgroundColor: context.nym.bgSecondary,
      builder: (ctx) {
        final c = ctx.nym;
        if (available.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No conversations',
                style: TextStyle(color: c.textDim, fontSize: 14)),
          );
        }
        return ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Add a column',
                  style: TextStyle(
                      color: c.textBright,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
            for (final ch in available)
              ListTile(
                title: Text('#${ch.isGeohash ? ch.geohash : ch.channel}',
                    style: TextStyle(color: c.text)),
                onTap: () => Navigator.of(ctx).pop(ch),
              ),
          ],
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _columnKeys.add(picked.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final channels = ref.watch(channelsProvider);
    final transparentColumns =
        ref.watch(settingsProvider.select((s) => s.columnsWallpaper));
    _seedIfNeeded(channels);

    final byKey = {for (final ch in channels) ch.key: ch};

    return Container(
      key: const Key('columnsStrip'),
      color: Colors.transparent,
      padding: const EdgeInsets.all(_CvDimens.padding),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final key in _columnKeys) ...[
              _ChannelColumn(
                entry: byKey[key] ??
                    ChannelEntry(channel: key, geohash: ''),
                transparent: transparentColumns,
                onClose: () => _removeColumn(key),
              ),
              const SizedBox(width: _CvDimens.gap),
            ],
            _AddColumnButton(
              c: c,
              onTap: () => _openAddColumn(channels),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single deck column (`.cv-column`): 360px wide, header + compact message
/// list for one channel.
class _ChannelColumn extends ConsumerWidget {
  const _ChannelColumn({
    required this.entry,
    required this.transparent,
    required this.onClose,
  });

  final ChannelEntry entry;
  final bool transparent;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final reactions = ref.watch(reactionsProvider);
    final messages = [...(app.messages[entry.storageKey] ?? const <Message>[])];
    messages.sort(compareMessages);

    final title = '#${entry.isGeohash ? entry.geohash : entry.channel}';

    return SizedBox(
      width: _CvDimens.column,
      child: Container(
        decoration: BoxDecoration(
          color: transparent ? Colors.transparent : c.bgSecondary,
          borderRadius: NymRadius.rmd,
          border: Border.all(color: c.glassBorder),
          // .cv-column box-shadow: --shadow-md (0 4px 16px black@0.4).
          boxShadow: transparent
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    offset: const Offset(0, 4),
                    blurRadius: 16,
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // .cv-column-header (padding 10/12, bottom border).
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: transparent ? Colors.transparent : c.glassBg,
                border: Border(bottom: BorderSide(color: c.glassBorder)),
              ),
              child: Row(
                children: [
                  Icon(Icons.tag, size: 18, color: c.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.secondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove column',
                    icon: Icon(Icons.close, size: 16, color: c.textDim),
                    onPressed: onClose,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // .cv-column-scroller / .cv-list (padding 10).
            Expanded(
              child: messages.isEmpty
                  ? Center(
                      child: Text('No messages yet',
                          style: TextStyle(color: c.textDim, fontSize: 12)),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(10),
                      itemCount: messages.length,
                      itemBuilder: (context, revIndex) {
                        final m = messages[messages.length - 1 - revIndex];
                        return MessageRow(
                          message: m,
                          settings: settings,
                          reactions: reactions[m.id] ?? const [],
                          showAvatar: false,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dashed "+ Add column" affordance (`.cv-add-column`): 220px wide.
class _AddColumnButton extends StatelessWidget {
  const _AddColumnButton({required this.c, required this.onTap});

  final NymColors c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _CvDimens.addColumn,
      child: InkWell(
        key: const Key('cvAddColumn'),
        onTap: onTap,
        borderRadius: NymRadius.rmd,
        child: DottedBorderBox(
          color: c.glassBorder,
          radius: NymRadius.md,
          child: Center(
            child: Text(
              '+ Add column',
              style: TextStyle(
                color: c.textDim,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 2px dashed rounded border (the CSS `border: 2px dashed var(--glass-border)`
/// on `.cv-add-column`).
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({
    super.key,
    required this.child,
    required this.color,
    required this.radius,
  });

  final Widget child;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 6.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(
          metric.extractPath(dist, dist + dash),
          paint,
        );
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
