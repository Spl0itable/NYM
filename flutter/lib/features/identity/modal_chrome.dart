import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../i18n/i18n.dart';

/// Shared modal chrome primitives matching the PWA's `.modal` CSS.
class ModalChrome {
  ModalChrome._();

  /// Outer modal card with no inner padding; [maxWidth] defaults to 500.
  static Widget box(NymColors c, {required Widget child}) {
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
    return Container(
      // Full width and left-aligned, even inside a centering Column.
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 14),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
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
      child: _CloseChip(c: c, onTap: onTap),
    );
  }

  /// Translucent primary pill; [danger] swaps palettes, disabled drops to 0.35 opacity.
  static Widget sendButton(
    NymColors c,
    String label,
    VoidCallback? onTap, {
    bool danger = false,
    bool fullWidth = false,
    Widget? child,
  }) {
    final btn = _SendButton(
      c: c,
      label: label,
      onTap: onTap,
      danger: danger,
      child: child,
    );
    return fullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  }

  /// Bordered translucent uppercase pill; [height] pins it to match the 42px send button beside it.
  static Widget iconButton(NymColors c, String label, VoidCallback? onTap,
      {double? height}) {
    return _IconButton(c: c, label: label, onTap: onTap, height: height);
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

  /// Form input decoration; wrap the field in [focusRing] for the outer glow.
  static InputDecoration inputDecoration(NymColors c, String hint) {
    final baseBorder = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    return InputDecoration(
      isDense: true,
      hintText: hint.isEmpty ? null : hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      filled: true,
      // Light mode forces the fill with `!important`, so the focus bump never applies.
      fillColor: WidgetStateColor.resolveWith(
        (states) => c.isLight
            ? const Color(0x0A000000)
            : Colors.white.withValues(
                alpha: states.contains(WidgetState.focused) ? 0.07 : 0.05),
      ),
      border: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: baseBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: baseBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.primaryA(0.3)),
      ),
    );
  }

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
    this.child,
  });

  final NymColors c;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
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
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: NymRadius.rsm,
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
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatefulWidget {
  const _IconButton(
      {required this.c, required this.label, required this.onTap, this.height});

  final NymColors c;
  final String label;
  final VoidCallback? onTap;
  final double? height;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final Color fill;
    final Color border;
    final Color fg;
    if (_hover) {
      fill = c.isLight ? const Color(0x0F000000) : c.primaryA(0.12);
      border = c.isLight ? c.primary : c.primaryA(0.3);
      fg = c.primary;
    } else {
      fill = c.subtleFill;
      border = c.isLight ? const Color(0x1A000000) : c.glassBorder;
      fg = c.isLight ? c.primary : c.text;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: NymRadius.rxs,
            border: Border.all(color: border),
            boxShadow: _hover
                ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 15)]
                : null,
          ),
          // Center with widthFactor centers the label vertically while staying shrink-wrapped.
          child: widget.height == null
              ? _label(fg)
              : Center(widthFactor: 1, child: _label(fg)),
        ),
      ),
    );
  }

  Text _label(Color fg) {
    return Text(
      widget.label.toUpperCase(),
      style: TextStyle(
        color: fg,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.8,
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
    return MouseRegion(
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
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
