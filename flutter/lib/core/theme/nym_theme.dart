import 'package:flutter/material.dart';

import 'nym_colors.dart';

Color _hex(String h) {
  var s = h.replaceFirst('#', '');
  if (s.length == 3) {
    s = s.split('').map((c) => '$c$c').join();
  }
  return Color(int.parse('ff$s', radix: 16));
}

Color _rgba(int r, int g, int b, double a) => Color.fromRGBO(r, g, b, a);

/// Per-theme [primary, secondary, text, textDim, textBright, lightning] for dark and light.
class _Accents {
  const _Accents(this.dark, this.light);
  final List<String> dark;
  final List<String> light;
}

const Map<NymThemeKey, _Accents> _themeAccents = {
  NymThemeKey.bitchat: _Accents(
    ['#00ff00', '#00ffff', '#00ff00', '#cccccc', '#00ffaa', '#f7931a'],
    ['#007a00', '#007a7a', '#006600', '#666666', '#004d00', '#c47a15'],
  ),
  NymThemeKey.matrix: _Accents(
    ['#00ff00', '#00ffff', '#00ff00', '#00BD00', '#00ffaa', '#f7931a'],
    ['#007a00', '#007a7a', '#006600', '#558855', '#004d00', '#c47a15'],
  ),
  NymThemeKey.amber: _Accents(
    ['#ffb000', '#ffd700', '#ffb000', '#cc8800', '#ffcc00', '#ffa500'],
    ['#9a6a00', '#8a7200', '#7a5500', '#8a7a55', '#5a3a00', '#b87300'],
  ),
  NymThemeKey.cyber: _Accents(
    ['#ff00ff', '#00ffff', '#ff00ff', '#DB16DB', '#ff66ff', '#ffaa00'],
    ['#990099', '#007a7a', '#880088', '#885588', '#660066', '#b87300'],
  ),
  NymThemeKey.hacker: _Accents(
    ['#00ffff', '#00ff00', '#00ffff', '#01c2c2', '#66ffff', '#00ff88'],
    ['#007a7a', '#007a00', '#006666', '#558888', '#004d4d', '#009955'],
  ),
  // Ghost uses applyTheme()'s inline values, which beat the CSS class (dark textDim #cccccc).
  NymThemeKey.ghost: _Accents(
    ['#ffffff', '#cccccc', '#ffffff', '#cccccc', '#ffffff', '#dddddd'],
    ['#333333', '#555555', '#222222', '#777777', '#000000', '#999999'],
  ),
};

/// Resolves colors in the PWA's order: base, light mode, theme accents, ghost bg, solid UI.
NymColors resolveNymColors({
  required NymThemeKey theme,
  required Brightness brightness,
  required bool solidUi,
}) {
  final isLight = brightness == Brightness.light;
  final accents = _themeAccents[theme]!;
  final a = isLight ? accents.light : accents.dark;

  Color bg, bgSecondary, bgTertiary, border, glassBg, glassBorder;
  Color warning, danger, purple, blue;

  if (isLight) {
    bg = _hex('#f5f5f2');
    bgSecondary = _rgba(255, 255, 255, 0.85);
    bgTertiary = _rgba(240, 240, 237, 0.9);
    border = _rgba(0, 0, 0, 0.1);
    glassBg = _rgba(255, 255, 255, 0.6);
    glassBorder = _rgba(0, 0, 0, 0.08);
    warning = _hex('#8a6d00');
    danger = _hex('#cc0000');
    purple = _hex('#880088');
    blue = _hex('#0060cc');
  } else {
    bg = _hex('#0a0a0f');
    bgSecondary = _rgba(15, 15, 25, 0.85);
    bgTertiary = _rgba(20, 20, 35, 0.9);
    border = _hex(a[0]).withValues(alpha: 0.2); // Primary at 20%.
    glassBg = _rgba(15, 15, 30, 0.6);
    glassBorder = _rgba(255, 255, 255, 0.08);
    warning = _hex('#ffff00');
    danger = _hex('#ff4444');
    purple = _hex('#ff00ff');
    blue = _hex('#0080ff');
  }

  if (theme == NymThemeKey.ghost && !isLight) {
    bg = _hex('#080808');
    bgSecondary = _rgba(15, 15, 15, 0.85);
    bgTertiary = _rgba(20, 20, 20, 0.9);
    border = _rgba(255, 255, 255, 0.1);
    glassBorder = _rgba(255, 255, 255, 0.06);
    warning = _hex('#888888');
    danger = _hex('#cccccc');
    purple = _hex('#999999');
    blue = _hex('#bbbbbb');
  }

  // Ghost light-mode greys from `body.light-mode.theme-ghost`, which wins over `.light-mode`.
  if (theme == NymThemeKey.ghost && isLight) {
    warning = _hex('#555555');
    danger = _hex('#888888');
    purple = _hex('#777777');
    blue = _hex('#666666');
    border = _hex('#999999');
  }

  // Solid UI (opaque surfaces, default on).
  Color? bubbleSelfBg, bubbleOtherBg;
  if (solidUi) {
    if (isLight) {
      glassBg = _hex('#ffffff');
      bgSecondary = _hex('#ffffff');
      bgTertiary = _hex('#f0f0ed');
    } else {
      glassBg = _hex('#14141e');
      bgSecondary = _hex('#14141e');
      bgTertiary = _hex('#1c1c2c');
    }
    // Opaque bubble plates as in the PWA's solid-ui CSS; glass mode leaves them null for translucent fallbacks.
    if (theme == NymThemeKey.ghost) {
      bubbleOtherBg = isLight ? _hex('#dddddd') : _hex('#2a2a2a');
      bubbleSelfBg = isLight ? _hex('#bbbbbb') : _hex('#444444');
    } else {
      bubbleOtherBg = isLight ? _hex('#e6e6e0') : _hex('#2a2a3a');
      bubbleSelfBg = Color.lerp(bubbleOtherBg, _hex(a[0]), 0.22)!;
    }
  }

  return NymColors(
    primary: _hex(a[0]),
    secondary: _hex(a[1]),
    text: _hex(a[2]),
    textDim: _hex(a[3]),
    textBright: _hex(a[4]),
    lightning: _hex(a[5]),
    warning: warning,
    danger: danger,
    purple: purple,
    blue: blue,
    bg: bg,
    bgSecondary: bgSecondary,
    bgTertiary: bgTertiary,
    border: border,
    glassBg: glassBg,
    glassBorder: glassBorder,
    brightness: brightness,
    solidUi: solidUi,
    bubbleSelfBg: bubbleSelfBg,
    bubbleOtherBg: bubbleOtherBg,
  );
}

const String kMonoFont = 'monospace';

/// Bundled so it always resolves; an unresolved primary lets the emoji font skew line metrics.
const String kSansFont = 'Roboto';

/// Unbundled hint so Flutter falls through to the OS color-emoji font.
const String kEmojiFont = 'Noto Color Emoji';

/// Bundled text sans for non-emoji glyphs Roboto lacks (₿); must have no emoji-range glyphs.
const String kSansSymFont = 'Noto Sans';

/// Fallbacks after [kSansFont]: the emoji hint, then [kSansSymFont] for non-emoji symbols.
const List<String> kEmojiFontFallback = [
  kEmojiFont,
  kSansSymFont,
];

/// Material [ThemeData] carrying the [NymColors] extension.
ThemeData buildNymThemeData(NymColors c) {
  final base = c.isLight
      ? ThemeData.light(useMaterial3: true)
      : ThemeData.dark(useMaterial3: true);
  final scheme =
      (c.isLight ? const ColorScheme.light() : const ColorScheme.dark())
          .copyWith(
    brightness: c.brightness,
    primary: c.primary,
    onPrimary: c.bg,
    secondary: c.secondary,
    surface: c.bgSecondary,
    onSurface: c.text,
    error: c.danger,
  );

  // Bundled primary drives the line metrics; the fallback covers emoji and symbols.
  final textTheme = base.textTheme
      .apply(fontFamily: kSansFont, fontFamilyFallback: kEmojiFontFallback);
  final primaryTextTheme = base.primaryTextTheme
      .apply(fontFamily: kSansFont, fontFamilyFallback: kEmojiFontFallback);

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    dividerColor: c.glassBorder,
    splashFactory: InkRipple.splashFactory,
    textTheme: textTheme,
    primaryTextTheme: primaryTextTheme,
    textSelectionTheme: TextSelectionThemeData(
      // Caret uses the text color, as the PWA does, so it stays visible on light fields.
      cursorColor: c.isLight ? Colors.black : Colors.white,
      selectionColor: c.primary.withValues(alpha: 0.3),
      selectionHandleColor: c.primary,
    ),
    extensions: [c],
  );
}
