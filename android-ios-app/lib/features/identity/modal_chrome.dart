import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// Shared `.modal` chrome primitives — the exact CSS the PWA applies to every
/// standard modal (audit2/11 §"SHARED MODAL CHROME", lines 21-37). Used by the
/// identity modals so their buttons/headers/inputs/close-chip match the web 1:1.
///
/// References (default bitchat dark theme):
///  * `.modal-content`  — bg `--bg-secondary`, 1px glass, radius 24, padding 32,
///    shadow-lg + glow + `0 0 0 1px white/0.05`.
///  * `.modal-header`   — 22px `--primary`, UPPERCASE, ls1.5, w700, bottom rule.
///  * `.modal-close`    — 32×32 circular glass ✕ (top-right 14,14), danger hover.
///  * `.send-btn`       — translucent primary/0.1 fill, primary/0.3 border,
///    primary text, radius 12, h42, padding 10/22, 12px UPPERCASE ls1.5 w600.
///  * `.icon-btn`       — white/0.05 fill, glass border, radius 8, `--text`,
///    padding 7/14, 12px UPPERCASE ls0.8 w500.
///  * `.form-input`     — white/0.05 fill, glass border, radius 12, padding
///    11/14, font 15, `--text-bright`, focus glow `0 0 0 3px primary/0.06`.
///  * `.form-label`     — 11px textDim UPPERCASE ls1.2 w600, mb8.
class ModalChrome {
  ModalChrome._();

  /// The `.modal-content` outer card (no inner padding — callers add header /
  /// body / actions). [maxWidth] defaults to the shared 500.
  static Widget box(NymColors c, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: c.bgSecondary,
        borderRadius: NymRadius.rxl,
        border: Border.all(color: c.glassBorder),
        // `body.light-mode .modal-content { box-shadow: 0 8px 40px
        // rgba(0,0,0,0.12) }` — a single soft shadow, no glow/white ring
        // (styles-themes-responsive.css:1050-1052).
        boxShadow: c.isLight
            ? const [
                BoxShadow(
                  color: Color(0x1F000000), // black @ 0.12
                  blurRadius: 40,
                  offset: Offset(0, 8),
                ),
              ]
            : [
                // shadow-lg
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
                // shadow-glow (primary/0.1)
                BoxShadow(
                  color: c.primary.withValues(alpha: 0.1),
                  blurRadius: 20,
                ),
                // 0 0 0 1px white/0.05 ring
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

  /// The `.modal-header`: 22px primary UPPERCASE ls1.5 w700 with a 1px glass
  /// bottom rule (padding-bottom 14, margin-bottom 24).
  static Widget header(NymColors c, String title) {
    return Container(
      // `.modal-header` is a block element: full width, LEFT-aligned text —
      // never centered, even when the host Column defaults to center.
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

  /// The `.modal-close` — a 32×32 circular glass ✕ chip positioned at top-right
  /// (14,14), with a danger hover (web/desktop).
  static Widget closeChip(NymColors c, VoidCallback onTap) {
    return Positioned(
      top: 14,
      right: 14,
      child: _CloseChip(c: c, onTap: onTap),
    );
  }

  /// The `.send-btn` translucent primary pill. [danger] swaps to the
  /// `.send-btn.danger` palette (danger/0.1 fill, danger/0.35 border, danger
  /// text). [enabled] false → opacity 0.35. Hover (`:hover:not(:disabled)`,
  /// styles-chat.css:1936-1938) lifts the fill to primary/0.18 + a `0 0 15px
  /// primary/0.1` glow (danger: 0.18 / 0.15, styles-components.css:2386-2389;
  /// light mode uses the same palette, styles-themes-responsive.css:617-625).
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

  /// The `.icon-btn`: bordered translucent uppercase pill. Light mode flips to
  /// bg black/0.03, border black/0.1 and a `--primary` label
  /// (styles-themes-responsive.css:595-599); hover is primary/0.12 fill +
  /// primary/0.3 border + primary label + glow in dark
  /// (styles-shell.css:930-935), black/0.06 fill + solid primary border in
  /// light (styles-themes-responsive.css:601-605).
  /// [height] pins the pill to a fixed height with the label centered — the
  /// `.modal-actions` flex row has no `align-items`, so its default `stretch`
  /// makes an `.icon-btn` match the 42px `.send-btn` beside it (`.icon-btn` is
  /// `inline-flex; align-items: center`, so the text stays centered).
  static Widget iconButton(NymColors c, String label, VoidCallback? onTap,
      {double? height}) {
    return _IconButton(c: c, label: label, onTap: onTap, height: height);
  }

  /// The `.form-label`: 11px textDim UPPERCASE ls1.2 w600.
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

  /// The `.form-input` decoration (styles-components.css:229-255): white/0.05
  /// fill, glass border, radius 12, padding 11/14; focus keeps a 1px border at
  /// primary/0.3 and lifts the fill to white/0.07. Light mode forces bg
  /// black/0.04 + border black/0.1 `!important` (no focus lift), while the
  /// light `:focus` rule still wins the border back to primary/0.3
  /// (styles-themes-responsive.css:561-568, 1087-1092). Wrap the field in
  /// [focusRing] for the outer `0 0 0 3px` glow.
  static InputDecoration inputDecoration(NymColors c, String hint) {
    final baseBorder = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    return InputDecoration(
      isDense: true,
      hintText: hint.isEmpty ? null : hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 15),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      filled: true,
      // Dark: white@.05 → .07 on focus; light: black@.04 `!important`, so the
      // focus bump never applies.
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

  /// Wraps a `.form-input`/`.form-select` field with the `:focus` outer glow
  /// ring — `box-shadow: 0 0 0 3px primary/0.06` (light mode: primary/0.1;
  /// styles-components.css:253, styles-themes-responsive.css:1087-1092). A
  /// hard-edged ring (spread 3, no blur), toggled by descendant focus.
  static Widget focusRing(NymColors c, {required Widget child}) {
    return _FocusRing(c: c, child: child);
  }

  /// A plain centered "or" divider (`.nm-h-25`): 12px text-dim, margin 16 0, NO
  /// flanking rules.
  static Widget orDivider(NymColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text('or', style: TextStyle(color: c.textDim, fontSize: 12)),
      ),
    );
  }

  /// A tap recognizer that opens [path] (resolved against the live host) in the
  /// external browser, matching the ToS/Privacy `<a target="_blank">` links.
  static TapGestureRecognizer linkTap(String path) {
    return TapGestureRecognizer()
      ..onTap = () {
        final uri = Uri.parse('https://web.nymchat.app/$path');
        launchUrl(uri, mode: LaunchMode.externalApplication);
      };
  }
}

/// The `.form-input:focus` glow ring host: watches descendant focus (the
/// wrapped TextField / dropdown) and paints `0 0 0 3px primary/0.06` (light
/// `primary/0.1`) around it while focused.
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

/// `.send-btn` host with the desktop hover treatment
/// (`transition: all var(--transition)`, styles-chat.css:1920-1943).
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
    // `:hover:not(:disabled)` — 0.1 → 0.18 fill; border stays put.
    final hovered = _hover && enabled;
    final fill = danger
        ? c.danger.withValues(alpha: hovered ? 0.18 : 0.1)
        : c.primaryA(hovered ? 0.18 : 0.1);
    final border = danger ? c.danger.withValues(alpha: 0.35) : c.primaryA(0.3);
    final fg = danger ? c.danger : c.primary;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: MouseRegion(
        // `.send-btn:disabled { cursor: not-allowed }`.
        cursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.forbidden,
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
              // `0 0 15px primary/0.1` (danger: danger/0.15).
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
            // Center + widthFactor centers the label in the 42px pill while
            // keeping it shrink-wrapped (a bare `alignment:` would expand the
            // Container to fill any bounded row width — CSS buttons never do).
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

/// `.icon-btn` host — dark/light rest + hover palettes
/// (styles-shell.css:911-935, styles-themes-responsive.css:595-605).
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
    // Rest: white/0.05 fill + glass border + `--text` label in dark;
    // black/0.03 fill + black/0.1 border + `--primary` label in light.
    // Hover: primary/0.12 fill + primary/0.3 border in dark; black/0.06 fill
    // + solid primary border in light — label is primary either way, and the
    // base `.icon-btn:hover` glow (`0 0 15px primary/0.1`) applies in both.
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
          // With a pinned [height] the label centers vertically like the CSS
          // `inline-flex; align-items: center` (Center + widthFactor keeps the
          // pill shrink-wrapped instead of expanding to the row width).
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
              color: _hover
                  ? c.danger.withValues(alpha: 0.3)
                  : c.glassBorder,
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
