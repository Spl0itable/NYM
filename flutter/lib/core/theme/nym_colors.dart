import 'package:flutter/material.dart';

/// The six selectable color themes; default is [bitchat].
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

/// Resolved color tokens mirroring the PWA's CSS custom properties, as a [ThemeExtension].
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
    this.solidUi = false,
    this._bubbleSelfBg,
    this._bubbleOtherBg,
    this._fieldPlaceholder,
    this._warningStrong,
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

  /// Solid UI (the default, transparency off) repaints glass surfaces opaque.
  final bool solidUi;

  /// Solid-UI bubble fills; null in glass mode, where the getters use translucent bases.
  final Color? _bubbleSelfBg;
  final Color? _bubbleOtherBg;
  final Color? _fieldPlaceholder;

  bool get isLight => brightness == Brightness.light;

  Color get fieldPlaceholder => _fieldPlaceholder ?? textDim;

  final Color? _warningStrong;

  Color get warningStrong => _warningStrong ?? warning;

  NymColors get gate => copyWith(warning: warningStrong);

  Color get messageText =>
      isLight ? const Color(0xFF4A4A4A) : const Color(0xFFCCCCCC);

  /// Typed-input text color: pure white/black, not [text], which is accent-tinted in some themes.
  Color get inputText => isLight ? const Color(0xFF000000) : const Color(0xFFFFFFFF);

  /// Self bubble fill: translucent primary in glass mode, else the resolved solid-UI color.
  Color get bubbleSelfBg =>
      _bubbleSelfBg ?? primary.withValues(alpha: isLight ? 0.20 : 0.25);

  /// Others' bubble fill: translucent in glass mode, else the resolved solid-UI color.
  Color get bubbleOtherBg =>
      _bubbleOtherBg ??
      (isLight
          ? const Color(0x1A000000) // black @ 0.10
          : const Color(0x24FFFFFF)); // white @ 0.14

  Color primaryA(double alpha) => primary.withValues(alpha: alpha);
  Color secondaryA(double alpha) => secondary.withValues(alpha: alpha);

  // Mode-aware overlays: translucent white on dark flips to translucent black on light.

  /// Hover / selected fill for menu rows and list items.
  Color get hoverOverlay => isLight
      ? const Color(0x0F000000) // black @ 0.06
      : const Color(0x14FFFFFF); // white @ 0.08

  /// Danger hover fill, `rgba(255,68,68,0.12)` in both modes.
  Color get dangerHoverOverlay => const Color(0x1FFF4444);

  /// 1px hairline separator inside menus and cards.
  Color get hairline => isLight
      ? const Color(0x0F000000) // black @ 0.06
      : const Color(0x0FFFFFFF); // white @ 0.06

  /// Fill of an inset read-only block (pubkey, invite link, file offer).
  Color get insetFill => isLight
      ? const Color(0x0A000000) // black @ 0.04
      : const Color(0x0AFFFFFF); // white @ 0.04

  /// Border of an inset read-only block.
  Color get insetBorder => isLight
      ? const Color(0x1A000000) // black @ 0.1
      : const Color(0x14FFFFFF); // white @ 0.08

  /// Subtle control surface fill (`.icon-btn`).
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
    bool? solidUi,
    Color? bubbleSelfBg,
    Color? bubbleOtherBg,
    Color? fieldPlaceholder,
    Color? warningStrong,
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
      solidUi: solidUi ?? this.solidUi,
      bubbleSelfBg: bubbleSelfBg ?? _bubbleSelfBg,
      bubbleOtherBg: bubbleOtherBg ?? _bubbleOtherBg,
      fieldPlaceholder: fieldPlaceholder ?? _fieldPlaceholder,
      warningStrong: warningStrong ?? _warningStrong,
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
      solidUi: t < 0.5 ? solidUi : other.solidUi,
      bubbleSelfBg: t < 0.5 ? _bubbleSelfBg : other._bubbleSelfBg,
      bubbleOtherBg: t < 0.5 ? _bubbleOtherBg : other._bubbleOtherBg,
      fieldPlaceholder: Color.lerp(fieldPlaceholder, other.fieldPlaceholder, t),
      warningStrong: Color.lerp(warningStrong, other.warningStrong, t),
    );
  }
}

extension NymColorsContext on BuildContext {
  NymColors get nym => Theme.of(this).extension<NymColors>()!;
}
