import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

class NymField {
  NymField._();

  static Color fill(NymColors c, {bool focused = false}) => c.isLight
      ? const Color(0x0A000000)
      : Color.fromRGBO(255, 255, 255, focused ? 0.07 : 0.05);

  static Color overlayFill(NymColors c) =>
      c.isLight ? const Color(0xF5FFFFFF) : const Color(0xE6000000);

  static Color border(NymColors c) =>
      c.isLight ? const Color(0x1A000000) : c.glassBorder;

  static Color focusBorder(NymColors c) => c.primaryA(0.3);

  static Color placeholder(NymColors c) => c.fieldPlaceholder;

  static Color icon(NymColors c) => c.textDim;

  static List<BoxShadow>? ring(NymColors c, bool focused) => focused
      ? [BoxShadow(color: c.primaryA(c.isLight ? 0.1 : 0.06), spreadRadius: 3)]
      : null;

  static InputDecoration decoration(
    NymColors c, {
    String? hint,
    double fontSize = 15,
    BorderRadius radius = NymRadius.rsm,
    EdgeInsetsGeometry contentPadding =
        const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    Widget? prefixIcon,
    BoxConstraints? prefixIconConstraints,
    Widget? suffixIcon,
    BoxConstraints? suffixIconConstraints,
    Widget? suffix,
    bool isDense = true,
    bool alignLabelWithHint = false,
  }) {
    OutlineInputBorder side(Color color) => OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: color),
        );
    return InputDecoration(
      isDense: isDense,
      hintText: hint == null || hint.isEmpty ? null : hint,
      hintStyle: TextStyle(color: placeholder(c), fontSize: fontSize),
      contentPadding: contentPadding,
      filled: true,
      fillColor: WidgetStateColor.resolveWith(
          (s) => fill(c, focused: s.contains(WidgetState.focused))),
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      prefixIcon: prefixIcon,
      prefixIconConstraints: prefixIconConstraints,
      prefixIconColor: icon(c),
      suffixIcon: suffixIcon,
      suffixIconConstraints: suffixIconConstraints,
      suffixIconColor: icon(c),
      suffix: suffix,
      alignLabelWithHint: alignLabelWithHint,
      border: side(border(c)),
      enabledBorder: side(border(c)),
      disabledBorder: side(border(c)),
      focusedBorder: side(focusBorder(c)),
    );
  }

  static InputDecoration bare(NymColors c,
      {String? hint,
      double fontSize = 15,
      EdgeInsetsGeometry? contentPadding}) {
    return InputDecoration(
      isDense: true,
      hintText: hint == null || hint.isEmpty ? null : hint,
      hintStyle: TextStyle(color: placeholder(c), fontSize: fontSize),
      contentPadding: contentPadding,
      filled: false,
      fillColor: Colors.transparent,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
    );
  }
}

class NymFieldBox extends StatefulWidget {
  const NymFieldBox({
    super.key,
    required this.child,
    this.focusNode,
    this.overlay = false,
    this.radius = NymRadius.rsm,
    this.height,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final FocusNode? focusNode;
  final bool overlay;
  final BorderRadius radius;
  final double? height;
  final EdgeInsetsGeometry padding;

  @override
  State<NymFieldBox> createState() => _NymFieldBoxState();
}

class _NymFieldBoxState extends State<NymFieldBox> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<NymColors>()!;
    final fill =
        widget.overlay ? NymField.overlayFill(c) : NymField.fill(c, focused: _focused);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      child: Container(
        height: widget.height,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: widget.radius,
          border: Border.all(
              color: _focused ? NymField.focusBorder(c) : NymField.border(c)),
          boxShadow: widget.overlay ? null : NymField.ring(c, _focused),
        ),
        child: widget.child,
      ),
    );
  }
}
