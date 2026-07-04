import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// Animated shimmer placeholder shown while a conversation loads its history,
/// a 1:1 port of the PWA `.msg-skeleton` (`messages.js:_buildMessageSkeleton`,
/// `styles-chat.css:1980-2043`).
///
/// The PWA builds N placeholder rows (`Math.max(8, ceil(vh / rowH) + 3)`, capped
/// at 50) using the real message/bubble classes so the layout matches the live
/// list exactly, then runs a single synchronized `@keyframes sk-shimmer`
/// (`1.4s ease-in-out infinite`) on every shape: a `linear-gradient(90deg,
/// transparent, var(--glass-border), transparent)` highlight that translates
/// from `translateX(-100%)` to `translateX(100%)`. Each shape's base fill is
/// `var(--bg-tertiary)` with `border-radius: 6px` (avatars 50%).
///
/// Here the moving highlight is reproduced PER SHAPE (matching the CSS `::after`
/// on every `.sk-*`): each placeholder paints its `bg-tertiary` base plus a
/// full-width `glassBorder`-cored gradient translated `-100% → +100%` and clipped
/// to itself, all ticked by one shared [AnimationController] (`_t`) so every shape
/// — narrow or wide — shimmers in lockstep like the CSS (rather than a single
/// narrow band crossing the whole column, which lit shapes one region at a time).
/// There are distinct bubble vs IRC variants matching the two chat layouts.
class MessageSkeleton extends StatefulWidget {
  const MessageSkeleton({super.key, required this.useBubbles, this.rowCount});

  /// Bubble layout when true (`body.chat-bubbles`), IRC layout otherwise.
  final bool useBubbles;

  /// Number of placeholder rows to render. Null (the default) sizes to the
  /// window like the PWA: `min(50, max(8, ceil(vh / (bubble ? 56 : 40)) + 3))`
  /// (`_buildMessageSkeleton`, messages.js:2953-2957) — so the shimmer fills
  /// the pane on any viewport height.
  final int? rowCount;

  @override
  State<MessageSkeleton> createState() => _MessageSkeletonState();
}

class _MessageSkeletonState extends State<MessageSkeleton>
    with SingleTickerProviderStateMixin {
  // `sk-shimmer 1.4s ease-in-out infinite`.
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

  /// The PWA's viewport-sized row count (`window.innerHeight`-driven), with
  /// an explicit [MessageSkeleton.rowCount] taking precedence.
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

    // The PWA runs the sweep PER SHAPE: every `.sk-bar/.sk-line/.sk-avatar` has
    // its own `::after` (a full-WIDTH `linear-gradient(90deg, transparent,
    // glass-border, transparent)`) that slides `translateX(-100%) → 100%`, all
    // driven by the one shared `sk-shimmer` clock — so every placeholder, narrow
    // or wide, lights up in lockstep (not a single narrow band crossing the
    // column). We mirror that exactly: each shape paints its own clipped, moving
    // full-width highlight (see `_bar`/`_avatar`). The whole row tree is rebuilt
    // inside this AnimatedBuilder each tick so every shape re-reads `_t.value`.
    return ClipRect(
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          // `.msg-skeleton { justify-content: flex-end }` — rows settle at the
          // bottom, newest-style at the foot, like the reversed live list. The
          // viewport-sized count deliberately overfills the pane (+3 rows), so
          // the column is hosted in an inert reversed scrollable: bottom-
          // anchored, top overflow clipped, no layout overflow.
          final rows =
              widget.useBubbles ? _bubbleRows(c, rowCount) : _ircRows(c, rowCount);
          return SingleChildScrollView(
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          );
        },
      ),
    );
  }

  /// The per-shape moving highlight, a 1:1 port of the skeleton `::after`:
  /// a full-WIDTH `linear-gradient(90deg, transparent, glass-border,
  /// transparent)` (stops 0 / .5 / 1) translated horizontally from
  /// `translateX(-100%)` to `translateX(100%)` as `_t` runs 0→1, clipped to the
  /// shape. Painted over the shape's `bg-tertiary` base.
  Widget _shimmer(NymColors c, {required double width, required double height, BoxShape shape = BoxShape.rectangle}) {
    // -1 → +1 of the shape width == translateX(-100%) → translateX(100%).
    final dx = (_t.value * 2 - 1) * width;
    final radius = shape == BoxShape.circle
        ? BorderRadius.circular(height / 2) // 50%
        : const BorderRadius.all(Radius.circular(6));
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: [
          // base fill: `var(--bg-tertiary)`.
          Positioned.fill(child: ColoredBox(color: c.bgTertiary)),
          // moving highlight band, the width of the shape, offset by dx.
          Positioned(
            left: dx,
            top: 0,
            width: width,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Colors.transparent, c.glassBorder, Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- IRC variant ----
  // Reuses the live IRC row metrics: leading author column (min 120 incl. the
  // 18px avatar + bracketed nym), a 50px time column, then content lines.
  // Bar widths/line patterns mirror the PWA `_ircSkeletonHtml` arrays
  // (`messages.js:2965-2981`): `ska-{1,2,3}` author widths, `skl-{1..4}` line
  // widths (as % of the content column), repeated over `rowCount`.
  List<Widget> _ircRows(NymColors c, int rowCount) {
    // [authorWidthClass, [lineWidthClasses…]] — verbatim from the PWA pattern.
    const pattern = <List<Object>>[
      [2, ['skl-3']],
      [1, ['skl-4', 'skl-2']],
      [3, ['skl-2']],
      [2, ['skl-3', 'skl-3', 'skl-1']],
      [1, ['skl-2']],
      [2, ['skl-4']],
      [3, ['skl-1']],
      [1, ['skl-3', 'skl-2']],
      [2, ['skl-2']],
      [2, ['skl-4', 'skl-3']],
      [1, ['skl-1']],
      [3, ['skl-3']],
      [2, ['skl-2', 'skl-1']],
      [1, ['skl-4']],
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
    // `.message` padding: 14/10 (matches MessageRow._buildIrc).
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `.message-time` — `sk-time` is 34×10, in a 50px-min column.
          SizedBox(
            width: 50,
            child: _bar(c, width: 34, height: 10),
          ),
          const SizedBox(width: 10),
          // `.message-author` — `sk-author ska-N` (52/78/104 wide, 10 tall).
          SizedBox(
            width: 120,
            child: _bar(c, width: authorWidth, height: 10),
          ),
          const SizedBox(width: 10),
          // `.message-content` — one or more `sk-line skl-N` (height 9,
          // `margin: 5px 0` → 5px above the first line, 5px collapsed between
          // lines, 5px below the last; styles-chat.css:2022), widths as a
          // fraction of the remaining content column.
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

  // ---- Bubble variant ----
  // Mirrors the PWA `_bubbleSkeletonHtml` (`messages.js:2985-3012`): grouped
  // bubbles alternating other/self — self bubbles primary-GREEN and
  // right-aligned with no avatar, others gray and left-aligned behind a 32px
  // avatar circle — each bubble holding `skb-{1..4}` lines (110/160/210/260
  // wide) that step DOWN per line (`base - j`), exactly like the real grouped
  // bubble layout.
  List<Widget> _bubbleRows(NymColors c, int rowCount) {
    // {self, bubbles:[[baseWidthClass, lineCount], …]} — verbatim from the PWA.
    const pattern = <_BubbleGroup>[
      _BubbleGroup(false, [[3, 3], [1, 1]]),
      _BubbleGroup(true, [[2, 2]]),
      _BubbleGroup(false, [[1, 1]]),
      _BubbleGroup(true, [[1, 1], [3, 2], [1, 1]]),
      _BubbleGroup(false, [[4, 4]]),
      _BubbleGroup(true, [[2, 1]]),
      _BubbleGroup(false, [[3, 2], [1, 1]]),
      _BubbleGroup(true, [[3, 3]]),
      _BubbleGroup(false, [[2, 1]]),
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
          // `.message { padding: 2px 14px }` (a group drops the horizontal
          // padding, the skeleton drops the bottom) opens 2px above a group
          // lead; a `.bubble-grouped` continuation's collapsed `6px/-4px`
          // margins add another 2px, so it sits 4px below the previous bubble
          // box — the same 2px in-group rhythm the live MessageRow renders.
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

    // `.message-group`: align-end row; others lead with a 32px avatar.
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

    // `.message-group { padding: 0 14px 0 6px; margin-bottom: 6px }` (self
    // groups `padding: 0 14px`, styles-features.css:3506-3525) — the 6px
    // inter-group air hangs BELOW each group, like the live list.
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
    // The PWA skeleton reuses the REAL `.message`/`.message-content` classes
    // (`_bubbleSkeletonHtml`, messages.js:2985-3012), so the placeholder
    // bubble carries the LIVE bubble fill — a self bubble is the primary GREEN
    // (`rgb(from var(--primary) r g b / 0.25)` dark / `.20` light,
    // styles-features.css:3642 / themes:1400) and an others' bubble the
    // translucent gray (`rgba(255,255,255,0.14)` dark / `rgba(0,0,0,0.10)`
    // light, :3602 / themes:1408) — and, being real bubble classes, the
    // `body.solid-ui` opaque plates (`#2a2a3a`/color-mix self, themes:
    // 1660-1700) too. All of that is what the theme's resolved
    // `bubbleSelfBg`/`bubbleOtherBg` tokens carry. Only the `sk-line` bars
    // inside use the `bg-tertiary` shimmer fill.
    final fill = self ? c.bubbleSelfBg : c.bubbleOtherBg;
    // A group lead keeps the 4px tail corner; a `.bubble-grouped` continuation
    // is fully rounded-16 (`body.chat-bubbles .message.bubble-grouped
    // .message-content`, styles-features.css:3493-3500).
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
    // `skb-N` lines stepping down per line (`base - j`), each with the
    // `.sk-line { margin: 5px 0 }` rhythm: 5px above the first, 5px collapsed
    // between lines, 5px below the last (styles-chat.css:2022).
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
      // The live bubble's 180px floor is deliberately ZEROED for skeletons
      // (`body.chat-bubbles .msg-skeleton .message-content { min-width: 0 }`,
      // styles-chat.css:2040), so narrow placeholder bubbles shrink-wrap to
      // their line and the shimmer groups keep their varied widths. Only the
      // `max-width: 85%` cap applies (styles-features.css:3602-3616).
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.85,
      ),
      child: Container(
        // `body.chat-bubbles .message-content { padding: 8px 12px 6px }`.
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

  // ---- shared shapes ----
  // Base placeholder fill (`var(--bg-tertiary)`, `border-radius: 6px`) with the
  // per-shape moving highlight (`::after`) painted over it.
  Widget _bar(NymColors c, {required double width, required double height}) {
    return SizedBox(
      width: width,
      height: height,
      child: _shimmer(c, width: width, height: height),
    );
  }

  // `.sk-avatar { border-radius: 50% }` — same moving highlight, circular clip.
  Widget _avatar(NymColors c, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: _shimmer(c, width: size, height: size, shape: BoxShape.circle),
    );
  }

  // `ska-1/2/3` author bar widths (52 / 78 / 104).
  double _skAuthorWidth(int n) => const {1: 52.0, 2: 78.0, 3: 104.0}[n] ?? 78.0;

  // `skl-1/2/3/4` content-line widths as fractions (35% / 55% / 72% / 88%).
  double _sklFraction(String cls) =>
      const {'skl-1': 0.35, 'skl-2': 0.55, 'skl-3': 0.72, 'skl-4': 0.88}[cls] ??
      0.55;

  // `skb-1/2/3/4` bubble-line widths (110 / 160 / 210 / 260).
  double _skbWidth(int n) =>
      const {1: 110.0, 2: 160.0, 3: 210.0, 4: 260.0}[n] ?? 160.0;
}

/// One bubble-skeleton group: [self] side + a list of `[baseWidthClass, lines]`
/// bubbles (verbatim from the PWA `_bubbleSkeletonHtml` pattern).
class _BubbleGroup {
  const _BubbleGroup(this.self, this.bubbles);
  final bool self;
  final List<List<int>> bubbles;
}
