import 'package:flutter/material.dart';

/// The six selectable color themes. Default is [bitchat].
/// (docs/specs/02 §3)
enum NymThemeKey {
  bitchat('bitchat', 'Bitchat'),
  matrix('matrix', 'Matrix Green'),
  amber('amber', 'Amber Terminal'),
  cyber('cyber', 'Cyberpunk'),
  hacker('hacker', 'Hacker Blue'),
  ghost('ghost', 'Ghost');

  const NymThemeKey(this.id, this.label);
  final String id;
  final String label;

  static NymThemeKey fromId(String? id) {
    return NymThemeKey.values.firstWhere(
      (t) => t.id == id,
      orElse: () => NymThemeKey.bitchat,
    );
  }
}

/// Resolved color tokens for the active theme/mode, mirroring the CSS custom
/// properties the PWA sets on `<body>`. Exposed as a [ThemeExtension] so any
/// widget can read `Theme.of(context).extension<NymColors>()`.
@immutable
class NymColors extends ThemeExtension<NymColors> {
  const NymColors({
    required this.primary,
    required this.secondary,
    required this.warning,
    required this.danger,
    required this.purple,
    required this.blue,
    required this.lightning,
    required this.bg,
    required this.bgSecondary,
    required this.bgTertiary,
    required this.text,
    required this.textDim,
    required this.textBright,
    required this.border,
    required this.glassBg,
    required this.glassBorder,
    required this.brightness,
  });

  final Color primary; // accent / brand
  final Color secondary; // links, author names
  final Color warning;
  final Color danger;
  final Color purple; // PM accent
  final Color blue; // standard-channel badge
  final Color lightning; // zaps / BTC
  final Color bg; // app background
  final Color bgSecondary; // sidebar / modal / header surfaces
  final Color bgTertiary; // context menu / skeletons
  final Color text; // primary body text
  final Color textDim; // muted text / timestamps
  final Color textBright; // emphasis text
  final Color border; // default border
  final Color glassBg; // translucent surface fill
  final Color glassBorder; // hairline border on glass
  final Brightness brightness;

  bool get isLight => brightness == Brightness.light;

  /// Recurring relative-color alphas off `--primary` in the CSS.
  Color primaryA(double alpha) => primary.withValues(alpha: alpha);
  Color secondaryA(double alpha) => secondary.withValues(alpha: alpha);

  // --- Mode-aware "overlay" tokens -----------------------------------------
  // The PWA layers translucent WHITE surfaces over the dark UI (hover fills,
  // hairlines, inset blocks). In light mode those same surfaces flip to
  // translucent BLACK (e.g. `body.light-mode .quick-context-item:hover`,
  // `.context-menu-copy-pubkey:hover`, `.ctx-full-pubkey`, `.icon-btn`). These
  // helpers return the correct value per mode so widgets stop hardcoding
  // `Colors.white.withValues(...)` (which is invisible on a light surface).

  /// Hover / selected fill for menu rows & list items
  /// (dark `white@0.08` → light `black@0.06`).
  Color get hoverOverlay => isLight
      ? const Color(0x0F000000) // black @ 0.06
      : const Color(0x14FFFFFF); // white @ 0.08

  /// Danger hover fill — `rgba(255,68,68,0.12)` in both modes
  /// (`.context-menu-item.danger:hover`).
  Color get dangerHoverOverlay => const Color(0x1FFF4444);

  /// A 1px hairline separator inside menus/cards
  /// (dark `white@0.06` → light `black@0.06`).
  Color get hairline => isLight
      ? const Color(0x0F000000) // black @ 0.06
      : const Color(0x0FFFFFFF); // white @ 0.06

  /// Fill of an inset read-only block (pubkey / invite-link / file-offer)
  /// (dark `white@0.04` → light `black@0.04`; `.ctx-full-pubkey`).
  Color get insetFill => isLight
      ? const Color(0x0A000000) // black @ 0.04
      : const Color(0x0AFFFFFF); // white @ 0.04

  /// Border of an inset read-only block
  /// (dark `white@0.08` → light `black@0.1`; `.ctx-full-pubkey`).
  Color get insetBorder => isLight
      ? const Color(0x1A000000) // black @ 0.1
      : const Color(0x14FFFFFF); // white @ 0.08

  /// Subtle control surface fill (`.icon-btn` / `.file-offer-icon`)
  /// (dark `white@0.05` → light `black@0.03`).
  Color get subtleFill => isLight
      ? const Color(0x08000000) // black @ 0.03
      : const Color(0x0DFFFFFF); // white @ 0.05

  @override
  NymColors copyWith({
    Color? primary,
    Color? secondary,
    Color? warning,
    Color? danger,
    Color? purple,
    Color? blue,
    Color? lightning,
    Color? bg,
    Color? bgSecondary,
    Color? bgTertiary,
    Color? text,
    Color? textDim,
    Color? textBright,
    Color? border,
    Color? glassBg,
    Color? glassBorder,
    Brightness? brightness,
  }) {
    return NymColors(
      primary: primary ?? this.primary,
      secondary: secondary ?? this.secondary,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      purple: purple ?? this.purple,
      blue: blue ?? this.blue,
      lightning: lightning ?? this.lightning,
      bg: bg ?? this.bg,
      bgSecondary: bgSecondary ?? this.bgSecondary,
      bgTertiary: bgTertiary ?? this.bgTertiary,
      text: text ?? this.text,
      textDim: textDim ?? this.textDim,
      textBright: textBright ?? this.textBright,
      border: border ?? this.border,
      glassBg: glassBg ?? this.glassBg,
      glassBorder: glassBorder ?? this.glassBorder,
      brightness: brightness ?? this.brightness,
    );
  }

  @override
  NymColors lerp(ThemeExtension<NymColors>? other, double t) {
    if (other is! NymColors) return this;
    return NymColors(
      primary: Color.lerp(primary, other.primary, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      lightning: Color.lerp(lightning, other.lightning, t)!,
      bg: Color.lerp(bg, other.bg, t)!,
      bgSecondary: Color.lerp(bgSecondary, other.bgSecondary, t)!,
      bgTertiary: Color.lerp(bgTertiary, other.bgTertiary, t)!,
      text: Color.lerp(text, other.text, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textBright: Color.lerp(textBright, other.textBright, t)!,
      border: Color.lerp(border, other.border, t)!,
      glassBg: Color.lerp(glassBg, other.glassBg, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      brightness: t < 0.5 ? brightness : other.brightness,
    );
  }
}

/// Convenience accessor.
extension NymColorsContext on BuildContext {
  NymColors get nym => Theme.of(this).extension<NymColors>()!;
}
