import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_a11y.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart';
import 'hit_slop.dart';
import 'nym_focusable.dart';

enum DialogButtonRole { primary, secondary, danger }

class DialogButtonMetrics {
  DialogButtonMetrics._();

  static const double height = 42;
  static const double largeHeight = 44;

  static double heightOf(BuildContext context) =>
      context.largeTouchTargets ? largeHeight : height;
  static const double padX = 22;
  static const double borderWidth = 1;
  static const BorderRadius radius = NymRadius.rsm;
  static const double fontSize = 12;
  static const FontWeight fontWeight = FontWeight.w600;
  static const double letterSpacing = 1.5;
  static const double gap = 10;
}

class DialogButton extends StatefulWidget {
  const DialogButton({
    super.key,
    required this.label,
    required this.onTap,
    this.role = DialogButtonRole.primary,
    this.fullWidth = false,
    this.child,
    this.focusNode,
    this.autofocus = false,
  });

  const DialogButton.secondary({
    super.key,
    required this.label,
    required this.onTap,
    this.fullWidth = false,
    this.child,
    this.focusNode,
    this.autofocus = false,
  }) : role = DialogButtonRole.secondary;

  const DialogButton.danger({
    super.key,
    required this.label,
    required this.onTap,
    this.fullWidth = false,
    this.child,
    this.focusNode,
    this.autofocus = false,
  }) : role = DialogButtonRole.danger;

  final String label;
  final VoidCallback? onTap;
  final DialogButtonRole role;
  final bool fullWidth;
  final Widget? child;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<DialogButton> {
  bool _hover = false;
  bool _ring = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocus);
    if (widget.focusNode != null) {
      FocusManager.instance.addHighlightModeListener(_onMode);
    }
  }

  @override
  void didUpdateWidget(DialogButton old) {
    super.didUpdateWidget(old);
    if (old.focusNode == widget.focusNode) return;
    old.focusNode?.removeListener(_onFocus);
    widget.focusNode?.addListener(_onFocus);
    if (old.focusNode == null) {
      FocusManager.instance.addHighlightModeListener(_onMode);
    } else if (widget.focusNode == null) {
      FocusManager.instance.removeHighlightModeListener(_onMode);
    }
    _onFocus();
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocus);
    if (widget.focusNode != null) {
      FocusManager.instance.removeHighlightModeListener(_onMode);
    }
    super.dispose();
  }

  bool _ringNow() =>
      (widget.focusNode?.hasPrimaryFocus ?? false) &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  void _onFocus() {
    final ring = _ringNow();
    if (ring != _ring && mounted) setState(() => _ring = ring);
  }

  void _onMode(FocusHighlightMode _) => _onFocus();

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final act = widget.onTap;
    if (act == null || !NymFocusable.isActivateKey(e.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) act();
    return KeyEventResult.handled;
  }

  ({Color fill, Color border, Color fg, Color? glow}) _palette(
      NymColors c, bool hovered) {
    switch (widget.role) {
      case DialogButtonRole.primary:
        return (
          fill: c.primaryA(hovered ? 0.18 : 0.1),
          border: c.primaryA(0.3),
          fg: c.primary,
          glow: hovered ? c.primaryA(0.1) : null,
        );
      case DialogButtonRole.danger:
        return (
          fill: c.danger.withValues(alpha: hovered ? 0.18 : 0.1),
          border: c.danger.withValues(alpha: 0.35),
          fg: c.danger,
          glow: hovered ? c.danger.withValues(alpha: 0.15) : null,
        );
      case DialogButtonRole.secondary:
        if (hovered) {
          return (
            fill: c.isLight ? const Color(0x0F000000) : c.primaryA(0.12),
            border: c.isLight ? c.primary : c.primaryA(0.3),
            fg: c.primary,
            glow: c.primaryA(0.1),
          );
        }
        return (
          fill: c.subtleFill,
          border: c.isLight ? const Color(0x1A000000) : c.glassBorder,
          fg: c.isLight ? c.primary : c.text,
          glow: null,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.extension<NymColors>() ??
        resolveNymColors(
            theme: NymThemeKey.bitchat,
            brightness: theme.brightness,
            solidUi: false);
    final enabled = widget.onTap != null;
    final p = _palette(c, _hover && enabled);
    final label = widget.child ??
        Text(
          widget.label.toUpperCase(),
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: p.fg,
            fontSize: DialogButtonMetrics.fontSize,
            fontWeight: DialogButtonMetrics.fontWeight,
            letterSpacing: DialogButtonMetrics.letterSpacing,
            height: 1.2,
          ),
        );
    final body = Semantics(
      button: true,
      enabled: enabled,
      label: widget.child == null ? null : widget.label,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: MouseRegion(
          cursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: NymMotion.transition,
              curve: NymMotion.curve,
              constraints: BoxConstraints(
                  minHeight: DialogButtonMetrics.heightOf(context)),
              padding: const EdgeInsets.symmetric(
                  horizontal: DialogButtonMetrics.padX),
              decoration: BoxDecoration(
                color: p.fill,
                borderRadius: DialogButtonMetrics.radius,
                border: Border.all(
                    color: p.border, width: DialogButtonMetrics.borderWidth),
                boxShadow: p.glow == null
                    ? null
                    : [BoxShadow(color: p.glow!, blurRadius: 15)],
              ),
              child: Center(
                widthFactor: widget.fullWidth ? null : 1,
                heightFactor: 1,
                child: label,
              ),
            ),
          ),
        ),
      ),
    );
    Widget btn = HitSlop(child: body);
    final node = widget.focusNode;
    if (node != null) {
      btn = Focus(
        focusNode: node,
        autofocus: widget.autofocus,
        canRequestFocus: enabled,
        onKeyEvent: _onKey,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: _ring
              ? BoxDecoration(
                  borderRadius: DialogButtonMetrics.radius,
                  border: Border.all(
                    color: c.secondary,
                    width: NymFocusable.ringWidth,
                  ),
                )
              : const BoxDecoration(),
          child: btn,
        ),
      );
    }
    return widget.fullWidth
        ? SizedBox(width: double.infinity, child: btn)
        : btn;
  }
}

class DialogActions extends StatelessWidget {
  const DialogActions({
    super.key,
    required this.children,
    this.alignment = WrapAlignment.center,
  });

  final List<Widget> children;
  final WrapAlignment alignment;

  static bool _leads(Widget w) {
    final inner = w is KeyedSubtree ? w.child : w;
    return inner is! DialogButton || inner.role == DialogButtonRole.secondary;
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: DialogButtonMetrics.gap,
      runSpacing: DialogButtonMetrics.gap,
      children: [
        ...children.where(_leads),
        ...children.where((w) => !_leads(w)),
      ],
    );
  }
}
