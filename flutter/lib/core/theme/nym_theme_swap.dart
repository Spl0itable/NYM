import 'package:flutter/material.dart';

import 'nym_colors.dart';

class NymThemeSwap extends StatefulWidget {
  const NymThemeSwap({super.key, required this.colors, required this.child});

  final NymColors colors;
  final Widget child;

  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_NymThemeSwapScope>()?.active ??
      false;

  static Duration motion(BuildContext context, Duration duration) =>
      activeOf(context) ? Duration.zero : duration;

  static bool sameLook(NymColors a, NymColors b) =>
      identical(a, b) ||
      (a.brightness == b.brightness &&
          a.solidUi == b.solidUi &&
          a.primary == b.primary &&
          a.secondary == b.secondary &&
          a.warning == b.warning &&
          a.danger == b.danger &&
          a.purple == b.purple &&
          a.blue == b.blue &&
          a.lightning == b.lightning &&
          a.bg == b.bg &&
          a.bgSecondary == b.bgSecondary &&
          a.bgTertiary == b.bgTertiary &&
          a.text == b.text &&
          a.textDim == b.textDim &&
          a.textBright == b.textBright &&
          a.border == b.border &&
          a.glassBg == b.glassBg &&
          a.glassBorder == b.glassBorder &&
          a.bubbleSelfBg == b.bubbleSelfBg &&
          a.bubbleOtherBg == b.bubbleOtherBg &&
          a.fieldPlaceholder == b.fieldPlaceholder &&
          a.warningStrong == b.warningStrong);

  @override
  State<NymThemeSwap> createState() => _NymThemeSwapState();
}

class _NymThemeSwapState extends State<NymThemeSwap> {
  bool _active = false;
  int _seq = 0;

  @override
  void didUpdateWidget(NymThemeSwap old) {
    super.didUpdateWidget(old);
    if (NymThemeSwap.sameLook(old.colors, widget.colors)) return;
    _active = true;
    final seq = ++_seq;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || seq != _seq || !_active) return;
      setState(() => _active = false);
    });
  }

  ButtonStyle? _quick(ButtonStyle? style) => _active
      ? (style ?? const ButtonStyle()).copyWith(animationDuration: Duration.zero)
      : style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextButtonTheme(
      data: TextButtonThemeData(style: _quick(theme.textButtonTheme.style)),
      child: OutlinedButtonTheme(
        data: OutlinedButtonThemeData(
            style: _quick(theme.outlinedButtonTheme.style)),
        child: FilledButtonTheme(
          data:
              FilledButtonThemeData(style: _quick(theme.filledButtonTheme.style)),
          child: ElevatedButtonTheme(
            data: ElevatedButtonThemeData(
                style: _quick(theme.elevatedButtonTheme.style)),
            child: IconButtonTheme(
              data: IconButtonThemeData(style: _quick(theme.iconButtonTheme.style)),
              child: _NymThemeSwapScope(active: _active, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class _NymThemeSwapScope extends InheritedWidget {
  const _NymThemeSwapScope({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_NymThemeSwapScope oldWidget) =>
      oldWidget.active != active;
}
