import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// Shimmer placeholder while a conversation loads history (bubble and IRC variants).
class MessageSkeleton extends StatefulWidget {
  const MessageSkeleton({super.key, required this.useBubbles, this.rowCount});

  final bool useBubbles;

  /// Null sizes to the viewport like the PWA: `min(50, max(8, ceil(vh / rowH) + 3))`.
  final int? rowCount;

  @override
  State<MessageSkeleton> createState() => _MessageSkeletonState();
}

class _MessageSkeletonState extends State<MessageSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _rowCount(BuildContext context) {
    final explicit = widget.rowCount;
    if (explicit != null) return explicit;
    final vh = MediaQuery.sizeOf(context).height;
    final rowH = widget.useBubbles ? 56 : 40;
    return math.min(50, math.max(8, (vh / rowH).ceil() + 3));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final rowCount = _rowCount(context);

    // Rows are built once and shapes repaint off `_t`, so a shimmer tick is paint-only.
    final rows =
        widget.useBubbles ? _bubbleRows(c, rowCount) : _ircRows(c, rowCount);
    return RepaintBoundary(
      child: ClipRect(
        child: SingleChildScrollView(
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
    );
  }

  /// Per-shape highlight translated -100% to +100% and clipped to the shape, so all shapes shimmer in lockstep.
  Widget _shimmer(NymColors c, {BoxShape shape = BoxShape.rectangle}) {
    return CustomPaint(
      painter: _ShimmerPainter(
        t: _t,
        base: c.bgTertiary,
        highlight: c.glassBorder,
        circle: shape == BoxShape.circle,
      ),
    );
  }

  List<Widget> _ircRows(NymColors c, int rowCount) {
    // Verbatim from the PWA pattern.
    const pattern = <List<Object>>[
      [
        2,
        ['skl-3']
      ],
      [
        1,
        ['skl-4', 'skl-2']
      ],
      [
        3,
        ['skl-2']
      ],
      [
        2,
        ['skl-3', 'skl-3', 'skl-1']
      ],
      [
        1,
        ['skl-2']
      ],
      [
        2,
        ['skl-4']
      ],
      [
        3,
        ['skl-1']
      ],
      [
        1,
        ['skl-3', 'skl-2']
      ],
      [
        2,
        ['skl-2']
      ],
      [
        2,
        ['skl-4', 'skl-3']
      ],
      [
        1,
        ['skl-1']
      ],
      [
        3,
        ['skl-3']
      ],
      [
        2,
        ['skl-2', 'skl-1']
      ],
      [
        1,
        ['skl-4']
      ],
    ];
    return [
      for (var i = 0; i < rowCount; i++)
        _ircRow(
          c,
          authorWidth: _skAuthorWidth(pattern[i % pattern.length][0] as int),
          lineFractions: [
            for (final cls in pattern[i % pattern.length][1] as List<String>)
              _sklFraction(cls),
          ],
        ),
    ];
  }

  Widget _ircRow(
    NymColors c, {
    required double authorWidth,
    required List<double> lineFractions,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            child: _bar(c, width: 34, height: 10),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 120,
            child: _bar(c, width: authorWidth, height: 10),
          ),
          const SizedBox(width: 10),
          // `.sk-line { margin: 5px 0 }` collapses to 5px between lines.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var j = 0; j < lineFractions.length; j++)
                        Padding(
                          padding: EdgeInsets.only(top: j == 0 ? 0 : 5),
                          child:
                              _bar(c, width: w * lineFractions[j], height: 9),
                        ),
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

  List<Widget> _bubbleRows(NymColors c, int rowCount) {
    // Verbatim from the PWA pattern.
    const pattern = <_BubbleGroup>[
      _BubbleGroup(false, [
        [3, 3],
        [1, 1]
      ]),
      _BubbleGroup(true, [
        [2, 2]
      ]),
      _BubbleGroup(false, [
        [1, 1]
      ]),
      _BubbleGroup(true, [
        [1, 1],
        [3, 2],
        [1, 1]
      ]),
      _BubbleGroup(false, [
        [4, 4]
      ]),
      _BubbleGroup(true, [
        [2, 1]
      ]),
      _BubbleGroup(false, [
        [3, 2],
        [1, 1]
      ]),
      _BubbleGroup(true, [
        [3, 3]
      ]),
      _BubbleGroup(false, [
        [2, 1]
      ]),
    ];
    return [
      for (var i = 0; i < rowCount; i++)
        _bubbleGroup(c, pattern[i % pattern.length]),
    ];
  }

  Widget _bubbleGroup(NymColors c, _BubbleGroup g) {
    final stack = <Widget>[];
    for (var idx = 0; idx < g.bubbles.length; idx++) {
      stack.add(
        Padding(
          // Reproduces the live list's 2px in-group rhythm after CSS margin collapsing.
          padding: EdgeInsets.only(top: idx == 0 ? 2 : 4),
          child: _bubbleBox(
            c,
            self: g.self,
            grouped: idx > 0,
            base: g.bubbles[idx][0],
            lineCount: g.bubbles[idx][1],
          ),
        ),
      );
    }

    final stackColumn = Column(
      crossAxisAlignment:
          g.self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: stack,
    );

    final row = Row(
      mainAxisAlignment:
          g.self ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!g.self) ...[
          _avatar(c, 32),
          const SizedBox(width: 6),
        ],
        Flexible(child: stackColumn),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(g.self ? 14 : 6, 0, 14, 6),
      child: row,
    );
  }

  Widget _bubbleBox(
    NymColors c, {
    required bool self,
    required bool grouped,
    required int base,
    required int lineCount,
  }) {
    // The PWA skeleton reuses the real bubble classes, so placeholders carry the live bubble fill.
    final fill = self ? c.bubbleSelfBg : c.bubbleOtherBg;
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    final BorderRadius radius;
    if (grouped) {
      radius = const BorderRadius.all(r);
    } else if (self) {
      radius = const BorderRadius.only(
          topLeft: r, topRight: tail, bottomLeft: r, bottomRight: r);
    } else {
      radius = const BorderRadius.only(
          topLeft: tail, topRight: r, bottomLeft: r, bottomRight: r);
    }
    final lines = <Widget>[
      for (var j = 0; j < lineCount; j++)
        Padding(
          padding: EdgeInsets.only(top: 5, bottom: j == lineCount - 1 ? 5 : 0),
          child: _bar(
            c,
            width: _skbWidth((base - j).clamp(1, 4)),
            height: 9,
          ),
        ),
    ];
    return ConstrainedBox(
      // The live bubble's 180px min-width is zeroed for skeletons, so placeholders shrink-wrap their line.
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.85,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: lines,
        ),
      ),
    );
  }

  Widget _bar(NymColors c, {required double width, required double height}) {
    return SizedBox(
      width: width,
      height: height,
      child: _shimmer(c),
    );
  }

  Widget _avatar(NymColors c, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: _shimmer(c, shape: BoxShape.circle),
    );
  }

  double _skAuthorWidth(int n) => const {1: 52.0, 2: 78.0, 3: 104.0}[n] ?? 78.0;

  double _sklFraction(String cls) =>
      const {'skl-1': 0.35, 'skl-2': 0.55, 'skl-3': 0.72, 'skl-4': 0.88}[cls] ??
      0.55;

  double _skbWidth(int n) =>
      const {1: 110.0, 2: 160.0, 3: 210.0, 4: 260.0}[n] ?? 160.0;
}

class _BubbleGroup {
  const _BubbleGroup(this.self, this.bubbles);
  final bool self;
  final List<List<int>> bubbles;
}

/// Paint-only shimmer: `repaint: t` invalidates paint each tick with no rebuild or layout.
class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter({
    required this.t,
    required this.base,
    required this.highlight,
    required this.circle,
  }) : super(repaint: t);

  final Animation<double> t;
  final Color base;
  final Color highlight;
  final bool circle;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = circle
        ? Radius.circular(size.height / 2)
        : const Radius.circular(6);
    canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
    canvas.drawRect(rect, Paint()..color = base);
    final dx = (t.value * 2 - 1) * size.width;
    final band = Rect.fromLTWH(dx, 0, size.width, size.height);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.transparent, highlight, Colors.transparent],
        ).createShader(band),
    );
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) =>
      old.base != base || old.highlight != highlight || old.circle != circle;
}
