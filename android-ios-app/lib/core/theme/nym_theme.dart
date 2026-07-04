import 'package:flutter/material.dart';

import 'nym_colors.dart';

/// Parses `#rrggbb` / `#rgb`.
Color _hex(String h) {
  var s = h.replaceFirst('#', '');
  if (s.length == 3) {
    s = s.split('').map((c) => '$c$c').join();
  }
  return Color(int.parse('ff$s', radix: 16));
}

/// rgba() with 0..1 alpha.
Color _rgba(int r, int g, int b, double a) =>
    Color.fromRGBO(r, g, b, a);

/// Per-theme accent tokens: [primary, secondary, text, textDim, textBright,
/// lightning] for dark and light. (docs/specs/02 §3.1–3.6)
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
  // Ghost: applyTheme() sets these six tokens as inline body styles, which win
  // over the `body.theme-ghost` CSS class. Dark text-dim is therefore #cccccc
  // (the inline JS value) — not the class's #999999 — and lightning is #dddddd.
  // (js/modules/settings.js applyTheme ghost.dark/light)
  NymThemeKey.ghost: _Accents(
    ['#ffffff', '#cccccc', '#ffffff', '#cccccc', '#ffffff', '#dddddd'],
    ['#333333', '#555555', '#222222', '#777777', '#000000', '#999999'],
  ),
};

/// Builds the resolved [NymColors] for a theme + mode, applying the same
/// override order the PWA uses: base → light-mode → theme accents → ghost bg →
/// solid-ui. (docs/specs/02 §2–3)
NymColors resolveNymColors({
  required NymThemeKey theme,
  required Brightness brightness,
  required bool solidUi,
}) {
  final isLight = brightness == Brightness.light;
  final accents = _themeAccents[theme]!;
  final a = isLight ? accents.light : accents.dark;

  // --- backgrounds + neutral accents (shared across color themes) ---
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
    border = _hex(a[0]).withValues(alpha: 0.2); // primary @20%
    glassBg = _rgba(15, 15, 30, 0.6);
    glassBorder = _rgba(255, 255, 255, 0.08);
    warning = _hex('#ffff00');
    danger = _hex('#ff4444');
    purple = _hex('#ff00ff');
    blue = _hex('#0080ff');
  }

  // --- ghost overrides backgrounds (dark variant only) ---
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

  // --- ghost LIGHT non-accent greys (`body.light-mode.theme-ghost`,
  // styles-themes-responsive.css:652-675). The class wins over the generic
  // `.light-mode` block above: warning is set to #666666 then overridden to
  // #555555 (:673), danger #888888, purple #777777, blue #666666, border
  // #999999. (primary/secondary/text/textDim/textBright/lightning already come
  // from the correct ghost-light `_themeAccents` entry.)
  if (theme == NymThemeKey.ghost && isLight) {
    warning = _hex('#555555');
    danger = _hex('#888888');
    purple = _hex('#777777');
    blue = _hex('#666666');
    border = _hex('#999999');
  }

  // --- solid-ui (opaque surfaces; default ON) ---
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
  );
}

/// The monospace stack the PWA uses (`--font-mono`).
const String kMonoFont = 'monospace';

/// The primary UI sans (`--font-sans`). BUNDLED as an asset (`pubspec.yaml`), so
/// unlike the bare system name 'Roboto' it ALWAYS resolves — even on de-Googled
/// images — which is what keeps line metrics correct. A null / unresolved primary
/// lets Flutter promote the emoji fallback to primary, inflating every line and
/// degrading Latin glyphs to boxes (the "all the text is fucked up" regression).
const String kSansFont = 'Roboto';

/// The color-emoji family for unicode emoji (😀 🔥 ❤ 🇺 …). NOT bundled — left to
/// the OS native color-emoji font (Apple Color Emoji on iOS, Noto Color Emoji on
/// Android), which is what the PWA renders too and avoids a ~11MB binary bump.
/// Kept in the fallback chain as an (unresolved) hint; Flutter skips the unknown
/// family and lands on the OS emoji font for these codepoints.
const String kEmojiFont = 'Noto Color Emoji';

/// Bundled broad text sans (`pubspec.yaml`): the catch-all for the codepoints
/// Roboto lacks but which are NOT colour emoji — the bitcoin sign ₿ (U+20BF),
/// extra currency / punctuation / dashes, Greek / Cyrillic — so they render
/// instead of tofu. Deliberately a TEXT sans with NO emoji-range glyphs: a
/// monochrome symbol font here (e.g. Noto Sans Symbols 2) would shadow the OS
/// COLOUR emoji for codepoints like ⚡ ★ ☂ ❤ (they have both a text outline and
/// an emoji presentation), rendering them as black outlines instead of colour.
const String kSansSymFont = 'Noto Sans';

/// The glyph-coverage fallback chain appended after the real [kSansFont] primary.
/// Because the primary is a bundled, always-resolved sans, the line strut comes
/// from IT — not these fallbacks — so Latin metrics stay correct. Order:
/// [kEmojiFont] is an UNRESOLVED hint that Flutter skips, so colour-emoji
/// codepoints fall through to the OS native emoji font (Apple Color Emoji on iOS),
/// matching the PWA; [kSansSymFont] then catches the non-emoji text symbols Roboto
/// lacks (₿). It carries NO emoji-range glyphs, so it never shadows colour emoji.
const List<String> kEmojiFontFallback = [
  kEmojiFont,
  kSansSymFont,
];

/// Builds Flutter [ThemeData] wrapping a [NymColors]. Most custom widgets read
/// tokens via `context.nym`; this provides sensible Material defaults +
/// the [NymColors] extension.
ThemeData buildNymThemeData(NymColors c) {
  final base = c.isLight
      ? ThemeData.light(useMaterial3: true)
      : ThemeData.dark(useMaterial3: true);
  final scheme = (c.isLight ? const ColorScheme.light() : const ColorScheme.dark())
      .copyWith(
    brightness: c.brightness,
    primary: c.primary,
    onPrimary: c.bg,
    secondary: c.secondary,
    surface: c.bgSecondary,
    onSurface: c.text,
    error: c.danger,
  );

  // Every text style gets the bundled [kSansFont] primary + the emoji/symbol
  // [kEmojiFontFallback]. The primary is a real, always-resolved sans, so the
  // line strut is driven by Roboto (correct metrics) while emoji / enclosed
  // letters / symbols in nyms, labels, and chrome still resolve to colour /
  // symbol glyphs via the fallback — the PWA's `--font-sans` behaviour. This is
  // a pure value assignment (no font is loaded here), so binding-less unit tests
  // stay green.
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
      // The caret matches the input TEXT color (white on dark / black on light),
      // exactly like the PWA — which sets no `caret-color`, so the browser draws
      // the caret in the input's `--text-bright` color (#fff dark / #000 light).
      // Using the accent (`c.primary`) instead left the caret low-contrast on a
      // light field ("no visible cursor"); the text color is always legible.
      cursorColor: c.isLight ? Colors.black : Colors.white,
      selectionColor: c.primary.withValues(alpha: 0.3),
      selectionHandleColor: c.primary,
    ),
    extensions: [c],
  );
}
