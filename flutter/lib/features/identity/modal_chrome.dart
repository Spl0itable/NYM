import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/common/dialog_button.dart';
import '../../widgets/common/hit_slop.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';
import '../../widgets/common/nym_sheet.dart';
import '../i18n/i18n.dart';
import '../../widgets/common/nym_focusable.dart';
import '../../widgets/common/nym_field.dart';

/// Shared modal chrome primitives matching the PWA's `.modal` CSS.
class ModalChrome {
  ModalChrome._();

  static const EdgeInsets sheetPadding = EdgeInsets.fromLTRB(24, 6, 24, 24);

  static Widget shell(
    BuildContext context, {
    required double maxWidth,
    double margin = 20,
    bool scroll = false,
    required Widget child,
  }) {
    if (NymSheetScope.of(context)) {
      return scroll ? SingleChildScrollView(child: child) : child;
    }
    return KeyboardInsetDialog(
      child: Padding(
        padding: EdgeInsets.all(margin),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }

  /// Outer modal card with no inner padding; [maxWidth] defaults to 500.
  static Widget box(NymColors c, {required Widget child}) {
    return Builder(
      builder: (context) =>
          NymSheetScope.of(context) ? child : _box(c, child),
    );
  }

  static Widget _box(NymColors c, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: c.bgSecondary,
        borderRadius: NymRadius.rxl,
        border: Border.all(color: c.glassBorder),
        boxShadow: c.isLight
            ? const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 40,
                  offset: Offset(0, 8),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: c.primary.withValues(alpha: 0.1),
                  blurRadius: 20,
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.05),
                  spreadRadius: 1,
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  /// Modal header: 22px primary uppercase with a 1px glass bottom rule.
  static Widget header(NymColors c, String title) {
    return Builder(builder: (context) => _header(c, title, NymSheetScope.of(context)));
  }

  static Widget _header(NymColors c, String title, bool sheet) {
    return Container(
      // Full width and left-aligned, even inside a centering Column.
      width: double.infinity,
      padding: sheet
          ? const EdgeInsets.fromLTRB(32, 12, 56, 14)
          : const EdgeInsets.fromLTRB(32, 32, 32, 14),
      margin: EdgeInsets.only(bottom: sheet ? 20 : 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: FitWordsText(
        title.toUpperCase(),
        style: TextStyle(
          color: c.primary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  /// 32x32 circular close chip at top-right with a danger hover.
  static Widget closeChip(NymColors c, VoidCallback onTap) {
    return Positioned(
      top: 14,
      right: 14,
      child: HitSlop(child: _CloseChip(c: c, onTap: onTap)),
    );
  }

  /// Translucent primary pill; [danger] swaps palettes, disabled drops to 0.35 opacity.
  static Widget sendButton(
    NymColors c,
    String label,
    VoidCallback? onTap, {
    bool danger = false,
    bool fullWidth = false,
    bool large = false,
    Widget? child,
  }) {
    if (!large) {
      return DialogButton(
        label: label,
        onTap: onTap,
        role: danger ? DialogButtonRole.danger : DialogButtonRole.primary,
        fullWidth: fullWidth,
        child: child,
      );
    }
    final btn = HitSlop(
      child: _SendButton(
        c: c,
        label: label,
        onTap: onTap,
        danger: danger,
        large: large,
        child: child,
      ),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  }

  static Widget iconButton(NymColors c, String label, VoidCallback? onTap) {
    return DialogButton.secondary(label: label, onTap: onTap);
  }

  static Widget formLabel(NymColors c, String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: c.textDim,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }

  static InputDecoration inputDecoration(NymColors c, String hint) =>
      NymField.decoration(c, hint: hint);

  /// Hard-edged 3px focus glow ring toggled by descendant focus.
  static Widget focusRing(NymColors c, {required Widget child}) {
    return _FocusRing(c: c, child: child);
  }

  /// Centered "or" divider with no flanking rules.
  static Widget orDivider(NymColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(tr('or'), style: TextStyle(color: c.textDim, fontSize: 12)),
      ),
    );
  }

  /// Opens [path], resolved against the live host, in the external browser.
  static TapGestureRecognizer linkTap(String path) {
    return TapGestureRecognizer()
      ..onTap = () {
        final uri = Uri.parse('https://web.nymchat.app/$path');
        launchUrl(uri, mode: LaunchMode.externalApplication);
      };
  }
}

/// Watches descendant focus and paints the 3px glow while focused.
class _FocusRing extends StatefulWidget {
  const _FocusRing({required this.c, required this.child});
  final NymColors c;
  final Widget child;

  @override
  State<_FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<_FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Focus(
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (f) => setState(() => _focused = f),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: NymRadius.rsm,
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: c.primaryA(c.isLight ? 0.1 : 0.06),
                    spreadRadius: 3,
                  ),
                ]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.c,
    required this.label,
    required this.onTap,
    required this.danger,
    this.large = false,
    this.child,
  });

  final NymColors c;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool large;
  final Widget? child;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final danger = widget.danger;
    final enabled = widget.onTap != null;
    final hovered = _hover && enabled;
    final fill = danger
        ? c.danger.withValues(alpha: hovered ? 0.18 : 0.1)
        : c.primaryA(hovered ? 0.18 : 0.1);
    final border = danger ? c.danger.withValues(alpha: 0.35) : c.primaryA(0.3);
    final fg = danger ? c.danger : c.primary;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            height: widget.large ? 52 : 42,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: widget.large ? NymRadius.rmd : NymRadius.rsm,
              border: Border.all(color: border),
              boxShadow: hovered
                  ? [
                      BoxShadow(
                        color: danger
                            ? c.danger.withValues(alpha: 0.15)
                            : c.primaryA(0.1),
                        blurRadius: 15,
                      ),
                    ]
                  : null,
            ),
            // Center with widthFactor keeps the pill shrink-wrapped instead of filling the row.
            child: Center(
              widthFactor: 1,
              child: widget.child ??
                  Text(
                    widget.label.toUpperCase(),
                    style: TextStyle(
                      color: fg,
                      fontSize: widget.large ? NymType.lg : 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: widget.large ? 2 : 1.5,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseChip extends StatefulWidget {
  const _CloseChip({required this.c, required this.onTap});
  final NymColors c;
  final VoidCallback onTap;

  @override
  State<_CloseChip> createState() => _CloseChipState();
}

class _CloseChipState extends State<_CloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return NymFocusable(
      onActivate: widget.onTap,
      tooltip: tr('Close'),
      excludeChildSemantics: true,
      radius: const BorderRadius.all(Radius.circular(16)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover
                  ? c.danger.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                color: _hover ? c.danger.withValues(alpha: 0.3) : c.glassBorder,
              ),
            ),
            child: Icon(
              Icons.close,
              size: 16,
              color: _hover ? c.danger : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

class FitWordsText extends StatelessWidget {
  const FitWordsText(this.text,
      {super.key, this.textKey, required this.style, this.textAlign});

  final String text;
  final Key? textKey;
  final TextAlign? textAlign;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final merged = DefaultTextStyle.of(context).style.merge(style);
      final dir = Directionality.of(context);
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      double widest(TextScaler scaler) {
        var most = 0.0;
        for (final w in words) {
          final tp = TextPainter(
            text: TextSpan(text: w, style: merged),
            textDirection: dir,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          if (tp.width > most) most = tp.width;
          tp.dispose();
        }
        return most;
      }

      var fitted = MediaQuery.textScalerOf(context);
      if (box.maxWidth.isFinite) {
        final size = merged.fontSize ?? 14;
        for (var i = 0; i < 4; i++) {
          final w = widest(fitted);
          if (w <= box.maxWidth) break;
          fitted = TextScaler.linear(
              fitted.scale(size) / size * box.maxWidth / w * 0.98);
        }
      }
      return Text(text,
          key: textKey, style: style, textAlign: textAlign, textScaler: fitted);
    });
  }
}
