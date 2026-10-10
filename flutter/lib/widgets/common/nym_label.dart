import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' show Bidi;

import '../../core/theme/nym_a11y.dart';
import '../../core/utils/nym_utils.dart';

TextStyle nymSuffixStyle(TextStyle base,
    {bool contrast = false, bool genesis = false}) {
  final color = base.color ?? const Color(0xFFFFFFFF);
  return base.copyWith(
    color: color.withValues(alpha: color.a * (contrast ? 1 : 0.7)),
    fontSize: (base.fontSize ?? 14) * 0.9,
    fontWeight: genesis ? FontWeight.w400 : FontWeight.w100,
  );
}

TextStyle resolvedNymStyle(BuildContext context, TextStyle? style) =>
    DefaultTextStyle.of(context).style.merge(style);

TextStyle nymSuffixStyleOf(BuildContext context, TextStyle? base,
        {bool genesis = false}) =>
    nymSuffixStyle(resolvedNymStyle(context, base),
        contrast: context.highContrast, genesis: genesis);

final RegExp _labelRe = RegExp(r'^([\s\S]*[^\s#])(#(?:[0-9a-f]{4}|\?{4}))$',
    caseSensitive: false);

final RegExp nymSuffixPattern = RegExp(
    r'''(?<=[^\s#@(\[{/\\"'`<>=?&:;,.!])#([0-9a-f]{4}|\?{4})(?![0-9a-z_])''',
    caseSensitive: false);

final RegExp _tailRe = RegExp(
    r'^(?:[\s\S]*#([0-9a-f]{4})|([0-9a-f]{4})|[0-9a-f]{60}([0-9a-f]{4}))$',
    caseSensitive: false);

String nymTail(String value) {
  final m = _tailRe.firstMatch(value);
  if (m == null) return '';
  return (m.group(1) ?? m.group(2) ?? m.group(3)!).toLowerCase();
}

bool Function(String hex) knownNymSuffix({String sender = ''}) {
  final own = nymTail(sender);
  return (hex) => hex == own || isSeenNymSuffix(hex);
}

({String base, String suffix}) splitNymLabel(String label) {
  final m = _labelRe.firstMatch(label);
  if (m == null) return (base: label, suffix: '');
  return (base: m.group(1)!, suffix: m.group(2)!);
}

String isolateNym(String base) =>
    Bidi.hasAnyRtl(base) ? '\u2068$base\u2069' : base;

String _hashed(String suffix) =>
    suffix.isEmpty || suffix.startsWith('#') ? suffix : '#$suffix';

List<List<int>> nymSuffixRanges(String text,
    {bool Function(String hex)? known}) {
  final out = <List<int>>[];
  for (final m in nymSuffixPattern.allMatches(text)) {
    if (known != null && !known(m.group(1)!.toLowerCase())) continue;
    var s = m.start;
    while (s > 0 && text[s - 1].trim().isNotEmpty) {
      s--;
    }
    if (text.substring(s, m.start).contains('/')) continue;
    out.add([m.start, m.end]);
  }
  return out;
}

List<List<int>> mergeNymRanges(List<List<int>> a, List<List<int>> b) {
  final all = [...a, ...b]..sort((x, y) => x[0].compareTo(y[0]));
  final out = <List<int>>[];
  for (final r in all) {
    if (out.isNotEmpty && r[0] < out.last[1]) {
      if (r[1] > out.last[1]) out.last[1] = r[1];
      continue;
    }
    out.add([r[0], r[1]]);
  }
  return out;
}

List<InlineSpan> nymRangeSpans(
    String text, List<List<int>> ranges, TextStyle dim) {
  final parts = <InlineSpan>[];
  var at = 0;
  for (final r in ranges) {
    if (r[0] < at || r[1] > text.length) continue;
    if (r[0] > at) parts.add(TextSpan(text: text.substring(at, r[0])));
    parts.add(TextSpan(text: text.substring(r[0], r[1]), style: dim));
    at = r[1];
  }
  if (at < text.length) parts.add(TextSpan(text: text.substring(at)));
  return parts;
}

TextSpan nymTextSpan(BuildContext context, String text,
    {TextStyle? style, List<List<int>> extra = const [], bool bare = true}) {
  final ranges =
      mergeNymRanges(bare ? nymSuffixRanges(text) : const [], extra);
  if (ranges.isEmpty) return TextSpan(text: text, style: style);
  return TextSpan(
      style: style,
      children: nymRangeSpans(text, ranges, nymSuffixStyleOf(context, style)));
}

List<InlineSpan> nymLabelSpans(
    BuildContext context, String base, String suffix, TextStyle style,
    {bool genesis = false}) {
  final s = _hashed(suffix);
  return [
    TextSpan(text: isolateNym(base), style: style),
    if (s.isNotEmpty)
      TextSpan(
          text: s, style: nymSuffixStyleOf(context, style, genesis: genesis)),
  ];
}

class NymText extends StatelessWidget {
  const NymText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.softWrap,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool? softWrap;

  @override
  Widget build(BuildContext context) => Text.rich(
        nymTextSpan(context, text, style: style),
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
        softWrap: softWrap,
      );
}

class NymLabel extends StatelessWidget {
  const NymLabel(
    this.nym, {
    super.key,
    this.pubkey,
    this.suffix,
    this.style,
    this.genesis = false,
    this.maxLines = 1,
    this.textAlign,
  });

  final String nym;
  final String? pubkey;
  final String? suffix;
  final TextStyle? style;
  final bool genesis;
  final int? maxLines;
  final TextAlign? textAlign;

  ({String base, String suffix}) get parts {
    if (suffix != null) return (base: nym, suffix: _hashed(suffix!));
    if (pubkey != null) {
      return (
        base: stripPubkeySuffix(nym),
        suffix: '#${getPubkeySuffix(pubkey!)}'
      );
    }
    return splitNymLabel(nym);
  }

  @override
  Widget build(BuildContext context) {
    final p = parts;
    if (p.suffix.isEmpty) {
      return Text(p.base,
          style: style,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
          textAlign: textAlign);
    }
    final dim = nymSuffixStyleOf(context, style, genesis: genesis);
    if (maxLines != 1) {
      return Text.rich(
        TextSpan(style: style, children: [
          TextSpan(text: isolateNym(p.base)),
          TextSpan(text: p.suffix, style: dim),
        ]),
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        textAlign: textAlign,
      );
    }
    return _NymLabelRow(
      label: '${p.base}${p.suffix}',
      full: Text.rich(
        TextSpan(style: style, children: [
          TextSpan(text: isolateNym(p.base)),
          TextSpan(text: p.suffix, style: dim),
        ]),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
      base: Text(p.base,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis),
      suffix: Text(p.suffix, style: dim, maxLines: 1, softWrap: false),
    );
  }
}

class _NymLabelRow extends MultiChildRenderObjectWidget {
  _NymLabelRow(
      {required this.label,
      required Widget full,
      required Widget base,
      required Widget suffix})
      : super(children: <Widget>[full, base, suffix]);

  final String label;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNymLabelRow(Directionality.of(context), label);

  @override
  void updateRenderObject(
      BuildContext context, _RenderNymLabelRow renderObject) {
    renderObject
      ..textDirection = Directionality.of(context)
      ..label = label;
  }
}

class _NymLabelParentData extends ContainerBoxParentData<RenderBox> {}

typedef _Placement = ({
  bool whole,
  Size size,
  Offset base,
  Offset suffix,
  double baseline,
});

class _RenderNymLabelRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _NymLabelParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _NymLabelParentData> {
  _RenderNymLabelRow(this._textDirection, this._label);

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  String _label;
  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsSemanticsUpdate();
  }

  bool _whole = true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _NymLabelParentData) {
      child.parentData = _NymLabelParentData();
    }
  }

  RenderBox get _full => firstChild!;
  RenderBox get _base => childAfter(firstChild!)!;
  RenderBox get _suffix => lastChild!;

  _NymLabelParentData _pd(RenderBox child) =>
      child.parentData! as _NymLabelParentData;

  @override
  double computeMinIntrinsicWidth(double height) =>
      _suffix.getMaxIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _full.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      getDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      getDryLayout(BoxConstraints(maxWidth: width)).height;

  _Placement _place(
    BoxConstraints c,
    Size Function(RenderBox child, BoxConstraints c) sizeOf,
    double? Function(RenderBox child, BoxConstraints c) baselineOf,
  ) {
    final fc = BoxConstraints(maxWidth: c.maxWidth, maxHeight: c.maxHeight);
    final f = sizeOf(_full, fc);
    final sc = BoxConstraints(maxWidth: c.maxWidth, maxHeight: c.maxHeight);
    final s = sizeOf(_suffix, sc);
    final bc = BoxConstraints(
        maxWidth: c.maxWidth.isFinite
            ? math.max(0.0, c.maxWidth - s.width)
            : double.infinity,
        maxHeight: c.maxHeight);
    final b = sizeOf(_base, bc);
    final whole = !c.maxWidth.isFinite ||
        _full.getMaxIntrinsicWidth(double.infinity) <= c.maxWidth + 0.01;
    final rtl = _textDirection == TextDirection.rtl;
    if (whole) {
      final size = c.constrain(f);
      return (
        whole: true,
        size: size,
        base: Offset(rtl ? math.max(0.0, size.width - f.width) : 0, 0),
        suffix: Offset.zero,
        baseline: baselineOf(_full, fc) ?? f.height,
      );
    }
    final ba = baselineOf(_base, bc) ?? b.height;
    final sa = baselineOf(_suffix, sc) ?? s.height;
    final top = math.max(ba, sa);
    final bTop = top - ba;
    final sTop = top - sa;
    final w = b.width + s.width;
    final size =
        c.constrain(Size(w, math.max(bTop + b.height, sTop + s.height)));
    final shift = rtl ? math.max(0.0, size.width - w) : 0.0;
    return (
      whole: false,
      size: size,
      base: Offset(rtl ? shift + s.width : 0, bTop),
      suffix: Offset(rtl ? shift : b.width, sTop),
      baseline: top,
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _place(
        constraints,
        (child, c) => child.getDryLayout(c),
        (child, c) => child.getDryBaseline(c, TextBaseline.alphabetic),
      ).size;

  @override
  double? computeDryBaseline(
          BoxConstraints constraints, TextBaseline baseline) =>
      _place(
        constraints,
        (child, c) => child.getDryLayout(c),
        (child, c) => child.getDryBaseline(c, baseline),
      ).baseline;

  @override
  void performLayout() {
    final p = _place(
      constraints,
      (child, c) {
        child.layout(c, parentUsesSize: true);
        return child.size;
      },
      (child, c) => child.getDistanceToBaseline(TextBaseline.alphabetic),
    );
    _whole = p.whole;
    _pd(_full).offset = p.whole ? p.base : Offset.zero;
    _pd(_base).offset = p.whole ? Offset.zero : p.base;
    _pd(_suffix).offset = p.whole ? Offset.zero : p.suffix;
    size = p.size;
  }

  List<RenderBox> get _shown => _whole ? [_full] : [_base, _suffix];

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final child = _whole ? _full : _base;
    final d = child.getDistanceToActualBaseline(baseline);
    if (d == null) return null;
    return d + _pd(child).offset.dy;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _shown) {
      context.paintChild(child, offset + _pd(child).offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _shown.reversed) {
      final hit = result.addWithPaintOffset(
        offset: _pd(child).offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _label
      ..textDirection = _textDirection;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {}
}

class NymBareSuffixScope extends InheritedWidget {
  const NymBareSuffixScope(
      {super.key, required super.child, this.enabled = true});

  final bool enabled;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NymBareSuffixScope>()
          ?.enabled ??
      false;

  @override
  bool updateShouldNotify(NymBareSuffixScope oldWidget) =>
      oldWidget.enabled != enabled;
}
