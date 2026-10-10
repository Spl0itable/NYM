import 'package:flutter/material.dart';

import '../../core/theme/nym_a11y.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart';
import 'hit_slop.dart';

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
  });

  const DialogButton.secondary({
    super.key,
    required this.label,
    required this.onTap,
    this.fullWidth = false,
    this.child,
  }) : role = DialogButtonRole.secondary;

  const DialogButton.danger({
    super.key,
    required this.label,
    required this.onTap,
    this.fullWidth = false,
    this.child,
  }) : role = DialogButtonRole.danger;

  final String label;
  final VoidCallback? onTap;
  final DialogButtonRole role;
  final bool fullWidth;
  final Widget? child;

  @override
  State<DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<DialogButton> {
  bool _hover = false;

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
    final btn = HitSlop(child: body);
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
