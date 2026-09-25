import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum PopupAlign { start, end, center }

EdgeInsets popupInsetsOf(BuildContext context) {
  final mq = MediaQuery.of(context);
  final p = mq.padding;
  return EdgeInsets.fromLTRB(
      p.left, p.top, p.right, math.max(p.bottom, mq.viewInsets.bottom));
}

Rect popupBoundsFor(Size size, EdgeInsets insets, double margin) {
  final left = insets.left + margin;
  final top = insets.top + margin;
  return Rect.fromLTRB(
    left,
    top,
    math.max(left, size.width - insets.right - margin),
    math.max(top, size.height - insets.bottom - margin),
  );
}

Offset clampPopup(Rect bounds, Offset desired, Size childSize) {
  final maxLeft = math.max(bounds.left, bounds.right - childSize.width);
  final maxTop = math.max(bounds.top, bounds.bottom - childSize.height);
  return Offset(
    desired.dx.clamp(bounds.left, maxLeft),
    desired.dy.clamp(bounds.top, maxTop),
  );
}

class AnchoredPopupLayout extends SingleChildLayoutDelegate {
  AnchoredPopupLayout({
    required this.anchor,
    required this.insets,
    this.align = PopupAlign.start,
    this.preferAbove = true,
    this.gap = 6,
    this.margin = 10,
  });

  final Rect anchor;
  final EdgeInsets insets;
  final PopupAlign align;
  final bool preferAbove;
  final double gap;
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final b = popupBoundsFor(constraints.biggest, insets, margin);
    return BoxConstraints.loose(Size(b.width, b.height));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final b = popupBoundsFor(size, insets, margin);
    final above = anchor.top - gap - childSize.height;
    final below = anchor.bottom + gap;
    final fitsAbove = above >= b.top;
    final fitsBelow = below + childSize.height <= b.bottom;
    final roomAbove = anchor.top - b.top;
    final roomBelow = b.bottom - anchor.bottom;
    final double top;
    if (preferAbove) {
      top = fitsAbove
          ? above
          : fitsBelow
              ? below
              : (roomAbove >= roomBelow ? above : below);
    } else {
      top = fitsBelow
          ? below
          : fitsAbove
              ? above
              : (roomBelow >= roomAbove ? below : above);
    }
    final left = switch (align) {
      PopupAlign.start => anchor.left,
      PopupAlign.end => anchor.right - childSize.width,
      PopupAlign.center => anchor.center.dx - childSize.width / 2,
    };
    return clampPopup(b, Offset(left, top), childSize);
  }

  @override
  bool shouldRelayout(AnchoredPopupLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.insets != insets ||
      oldDelegate.align != align ||
      oldDelegate.preferAbove != preferAbove ||
      oldDelegate.gap != gap ||
      oldDelegate.margin != margin;
}

class PointPopupLayout extends SingleChildLayoutDelegate {
  PointPopupLayout({
    required this.anchor,
    required this.insets,
    this.offset = Offset.zero,
    this.centerX = false,
    this.margin = 10,
  });

  final Offset anchor;
  final EdgeInsets insets;
  final Offset offset;
  final bool centerX;
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final b = popupBoundsFor(constraints.biggest, insets, margin);
    return BoxConstraints.loose(Size(b.width, b.height));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final b = popupBoundsFor(size, insets, margin);
    final left =
        (centerX ? anchor.dx - childSize.width / 2 : anchor.dx) + offset.dx;
    return clampPopup(b, Offset(left, anchor.dy + offset.dy), childSize);
  }

  @override
  bool shouldRelayout(PointPopupLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.insets != insets ||
      oldDelegate.offset != offset ||
      oldDelegate.centerX != centerX ||
      oldDelegate.margin != margin;
}

class AnchoredPopup extends StatelessWidget {
  const AnchoredPopup({
    super.key,
    required this.anchor,
    required this.child,
    this.align = PopupAlign.start,
    this.preferAbove = true,
    this.gap = 6,
    this.margin = 10,
  });

  final Rect anchor;
  final Widget child;
  final PopupAlign align;
  final bool preferAbove;
  final double gap;
  final double margin;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: AnchoredPopupLayout(
          anchor: anchor,
          insets: popupInsetsOf(context),
          align: align,
          preferAbove: preferAbove,
          gap: gap,
          margin: margin,
        ),
        child: child,
      ),
    );
  }
}
