import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The exact PWA inline-SVG icons (feather-style + a couple of custom paths),
/// reproduced verbatim from `index.html` so the Flutter chrome matches the web
/// app pixel-for-pixel instead of approximating with Material glyphs.
///
/// Each entry is the raw `<svg>` markup the PWA ships. They are rendered through
/// [NymSvgIcon], which tints the whole drawing to a single colour with a
/// `srcIn` filter — so the same string works whether the path is stroked
/// (feather icons: `fill:none; stroke:currentColor`) or filled (the share /
/// filled-star glyphs).
class NymIcons {
  NymIcons._();

  /// `#channelBackBtn` — feather chevron-left (stroke).
  static const String chevronLeft =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="15 18 9 12 15 6"/></svg>';

  /// `#channelForwardBtn` — feather chevron-right (stroke).
  static const String chevronRight =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="9 6 15 12 9 18"/></svg>';

  /// `#favoriteChannelBtn` inactive — the custom 5-point star, OUTLINE only
  /// (`.favorite-channel-btn svg { fill:none; stroke:currentColor }`).
  static const String starOutline =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linejoin="round">'
      '<path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 '
      'L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>';

  /// `#favoriteChannelBtn.active` — the SAME star, FILLED
  /// (`.favorite-channel-btn.active svg { fill:currentColor; stroke:currentColor }`,
  /// tinted gold by the caller).
  static const String starFilled =
      '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" '
      'stroke-width="2" stroke-linejoin="round">'
      '<path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 '
      'L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>';

  /// `#shareChannelBtn` — the filled "share nodes" glyph (NOT the iOS share box).
  static const String shareNodes =
      '<svg viewBox="0 0 24 24" fill="currentColor">'
      '<path d="M18 16.08c-.76 0-1.44.3-1.96.77L8.91 12.7c.05-.23.09-.46.09-.7s-.04-.47-.09-.7l7.05-4.11c.54.5 1.25.81 2.04.81 1.66 0 3-1.34 3-3s-1.34-3-3-3-3 1.34-3 3c0 .24.04.47.09.7L8.04 9.81C7.5 9.31 6.79 9 6 9c-1.66 0-3 1.34-3 3s1.34 3 3 3c.79 0 1.5-.31 2.04-.81l7.12 4.16c-.05.21-.08.43-.08.65 0 1.61 1.31 2.92 2.92 2.92 1.61 0 2.92-1.31 2.92-2.92s-1.31-2.92-2.92-2.92z"/></svg>';

  /// `#audioCallBtn` — feather phone (stroke).
  static const String phone =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/></svg>';

  /// `#videoCallBtn` — feather video (stroke).
  static const String video =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polygon points="23 7 16 12 23 17 23 7"/>'
      '<rect x="1" y="5" width="15" height="14" rx="2" ry="2"/></svg>';

  /// `.notifications-btn` — feather bell (stroke).
  static const String bell =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/>'
      '<path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>';

  /// `data-action="openShop"` ("Flair") — the feather star POLYGON (distinct from
  /// the favorite button's custom star path).
  static const String starFlair =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>';

  /// `data-action="showSettings"` — feather gear (stroke).
  static const String settings =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="3"/>'
      '<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>';

  /// `data-action="showAbout"` — feather info (stroke).
  static const String info =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="10"/>'
      '<line x1="12" y1="16" x2="12" y2="12"/>'
      '<line x1="12" y1="8" x2="12.01" y2="8"/></svg>';

  /// `data-action="signOut"` — feather log-out (stroke).
  static const String logout =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>'
      '<polyline points="16 17 21 12 16 7"/>'
      '<line x1="21" y1="12" x2="9" y2="12"/></svg>';

  /// `.mobile-menu-toggle` — feather menu (hamburger, stroke).
  static const String menu =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<line x1="3" y1="6" x2="21" y2="6"/>'
      '<line x1="3" y1="12" x2="21" y2="12"/>'
      '<line x1="3" y1="18" x2="21" y2="18"/></svg>';

  /// Notifications-disabled variant — feather bell-off (stroke). The PWA header
  /// always shows the plain bell; this keeps the native "muted" affordance using
  /// the matching feather glyph rather than a Material substitute.
  static const String bellOff =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M13.73 21a2 2 0 0 1-3.46 0"/>'
      '<path d="M18.63 13A17.89 17.89 0 0 1 18 8"/>'
      '<path d="M6.26 6.26A5.86 5.86 0 0 0 6 8c0 7-3 9-3 9h14"/>'
      '<path d="M18 8a6 6 0 0 0-9.33-5"/>'
      '<line x1="1" y1="1" x2="23" y2="23"/></svg>';

  /// `.group-header-svg` (groups.js:2910): the three-figure group glyph, drawn in
  /// a 24×24 viewBox at stroke-width 1.75. Verbatim PWA path data.
  static const String groupGlyph =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="7" r="2.75"/>'
      '<path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/>'
      '<circle cx="4.5" cy="9.5" r="2"/>'
      '<path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/>'
      '<circle cx="19.5" cy="9.5" r="2"/>'
      '<path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>';

  /// `.friend-badge` (users.js:1923): a person-with-plus glyph in a 16×16 viewBox
  /// (filled head/body + stroked plus). Verbatim PWA markup; tinted to the friend
  /// colour by the caller.
  static const String friendBadge =
      '<svg viewBox="0 0 16 16" fill="currentColor">'
      '<circle cx="6" cy="5" r="2.5"/>'
      '<path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14"/>'
      '<line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>'
      '<line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';

  /// `#channelMeta` E2E notice prefix for PMs/groups — feather lock (`lockSvg` /
  /// `lockSvgPM`, identical paths; stroke).
  static const String lock =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>'
      '<path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>';

  /// Generic close "✕" — two crossed lines (the PWA's `quote-preview-close` /
  /// `upload-progress-close` SVG; stroke).
  static const String close =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<line x1="18" y1="6" x2="6" y2="18"/>'
      '<line x1="6" y1="6" x2="18" y2="18"/></svg>';

  /// `.input-btn` "Upload Image/Video" (`selectImage`) — feather image (stroke).
  static const String composerImage =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<rect x="3" y="3" width="18" height="18" rx="2" ry="2"/>'
      '<circle cx="8.5" cy="8.5" r="1.5"/>'
      '<polyline points="21 15 16 10 5 21"/></svg>';

  /// `.input-btn` "Share File (P2P)" (`selectP2PFile`) — feather file-out (stroke).
  static const String composerFile =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/>'
      '<polyline points="13 2 13 9 20 9"/>'
      '<line x1="12" y1="18" x2="12" y2="12"/>'
      '<polyline points="9 15 12 12 15 15"/></svg>';

  /// `.input-btn` "Emoji" (`toggleEmojiPicker`) — feather smile (stroke).
  static const String composerEmoji =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="10"/>'
      '<path d="M8 14s1.5 2 4 2 4-2 4-2"/>'
      '<circle cx="9" cy="9" r="1"/>'
      '<circle cx="15" cy="9" r="1"/></svg>';

  /// `.translate-input-btn` (`translateInputBtn`) — the filled translate glyph.
  static const String translate =
      '<svg viewBox="0 0 24 24" fill="currentColor">'
      '<path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/></svg>';

  /// The native-only "Transfers" pill (no PWA header equivalent) — feather repeat
  /// (stroke), keeping the chrome consistent with the feather icon family.
  static const String transfers =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="17 1 21 5 17 9"/>'
      '<path d="M3 11V9a4 4 0 0 1 4-4h14"/>'
      '<polyline points="7 23 3 19 7 15"/>'
      '<path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>';

  // ===========================================================================
  // Sidebar nav-title icons (index.html:470-567). Their `<svg>` tags carry no
  // inline fill/stroke — `.search-icon/.discover-icon/.collapse-icon svg` set
  // `fill:none; stroke:--text-dim; stroke-width:2` (styles-shell.css:205-213),
  // so those attributes are baked in here for the srcIn tint.
  // ===========================================================================

  /// `.discover-icon` (index.html:472) — the globe/geohash explorer glyph.
  static const String globe =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<circle cx="12" cy="12" r="10"/>'
      '<path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>';

  /// `.search-icon` (index.html:480) — the magnifier toggle.
  static const String search =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<circle cx="11" cy="11" r="8"/>'
      '<path d="m21 21-4.35-4.35"/></svg>';

  /// `.new-pm-btn` (index.html:522) — the plus glyph (new message).
  static const String plus =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<line x1="12" y1="5" x2="12" y2="19"/>'
      '<line x1="5" y1="12" x2="19" y2="12"/></svg>';

  /// `.collapse-icon` open state (index.html:486) — the down chevron
  /// (`stroke-linecap/linejoin:round` per styles-shell.css:216-218). The
  /// collapsed state rotates this -90° → reuse [chevronRight].
  static const String chevronDown =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="6 9 12 15 18 9"/></svg>';

  /// `.section-reorder-btn` up (index.html:463) — stroke-width 3 chevron-up.
  static const String reorderUp =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="18 15 12 9 6 15"/></svg>';

  /// `.section-reorder-btn` down (index.html:466) — stroke-width 3 chevron-down.
  static const String reorderDown =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="6 9 12 15 18 9"/></svg>';

  // ===========================================================================
  // Message/user context-menu glyphs (`#ctxXxx`, index.html:94-266; Slap/Hug
  // injected at ui-context.js:504/524). All 16×16 unless noted, stroke 1.5.
  // ===========================================================================

  /// `#ctxReact` — a smiley face (outlined circle + dot eyes + smile).
  static const String ctxReact =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="8" r="6"/>'
      '<circle cx="6" cy="7" r="0.5" fill="currentColor"/>'
      '<circle cx="10" cy="7" r="0.5" fill="currentColor"/>'
      '<path d="M 5.5 9.5 Q 8 11.5 10.5 9.5" stroke-linecap="round"/></svg>';

  /// `#ctxMention` — the "@" glyph rendered as text (fill, no stroke).
  static const String ctxMention =
      '<svg viewBox="0 0 16 16" fill="currentColor" stroke="none">'
      '<text x="8" y="12.5" font-size="14" font-family="Arial, sans-serif" '
      'text-anchor="middle" font-weight="600">@</text></svg>';

  /// `#ctxPM` — an envelope (Private Message).
  static const String ctxPm =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<rect x="2" y="4" width="12" height="9" rx="1"/>'
      '<path d="M 2 5 L 8 9 L 14 5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  /// `#ctxSlap` ("Slap with Trout", ui-context.js:504) — a fish glyph
  /// (stroke-width 1.3).
  static const String ctxSlap =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3">'
      '<path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none"/>'
      '<circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none"/>'
      '<path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round"/></svg>';

  /// `#ctxHug` ("Give warm Hug", ui-context.js:524) — two heads + arms.
  static const String ctxHug =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="6" cy="5" r="2"/>'
      '<circle cx="10" cy="5" r="2"/>'
      '<path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round"/>'
      '<path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round"/></svg>';

  /// `#ctxAddToGroup` ("Create Group Chat") — a person + plus.
  static const String ctxAddToGroup =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="6" cy="6" r="2.5"/>'
      '<path d="M 1.5 13 C 1.5 10 3.5 8.5 6 8.5 C 7 8.5 7.9 8.7 8.6 9.1" stroke-linecap="round"/>'
      '<line x1="12" y1="7" x2="12" y2="13" stroke-linecap="round"/>'
      '<line x1="9" y1="10" x2="15" y2="10" stroke-linecap="round"/></svg>';

  /// `#ctxZap` ("Zap Bitcoin") — a filled lightning bolt.
  static const String ctxZap =
      '<svg viewBox="0 0 16 16" fill="currentColor">'
      '<path d="M 9 2 L 4 9 H 7 L 7 14 L 12 7 H 9 Z"/></svg>';

  /// `#ctxGiftCredits` ("Gift Nymbot Credits") — a wrapped gift box.
  static const String ctxGiftCredits =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<rect x="2" y="7" width="12" height="7" rx="1"/>'
      '<path d="M 2 7 L 8 7 L 8 14 M 8 7 L 14 7"/>'
      '<path d="M 8 7 C 8 4 6 3 5 4 C 4 5 6 7 8 7 C 8 4 10 3 11 4 C 12 5 10 7 8 7 Z"/></svg>';

  /// `#ctxQuote` — two filled quotation marks.
  static const String ctxQuote =
      '<svg viewBox="0 0 16 16" fill="currentColor">'
      '<path d="M 3 6 C 3 4.5 4 3 6 3 C 6 4.5 5 5 4 5.5 C 3.5 5.8 3 6.3 3 7 L 3 9 L 6 9 L 6 6 Z"/>'
      '<path d="M 9 6 C 9 4.5 10 3 12 3 C 12 4.5 11 5 10 5.5 C 9.5 5.8 9 6.3 9 7 L 9 9 L 12 9 L 12 6 Z"/></svg>';

  /// `#ctxCopyMessage` — two stacked sheets (copy).
  static const String ctxCopy =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<rect x="5" y="5" width="8" height="9" rx="1"/>'
      '<path d="M 3 10 L 3 4 C 3 3.45 3.45 3 4 3 L 9 3" stroke-linecap="round"/></svg>';

  /// `#ctxFriend` ("Add/Remove Friend") — a person + plus (24px friendBadge is a
  /// 16px filled variant; this is the stroked context-menu glyph).
  static const String ctxFriend =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="6" cy="5" r="2.5"/>'
      '<path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" stroke-linecap="round"/>'
      '<line x1="13" y1="6" x2="13" y2="10" stroke-linecap="round" stroke-width="1.5"/>'
      '<line x1="11" y1="8" x2="15" y2="8" stroke-linecap="round" stroke-width="1.5"/></svg>';

  /// `#ctxReport` — a circled "!" (report).
  static const String ctxReport =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="8" r="6"/>'
      '<path d="M 8 5 L 8 8.5" stroke-linecap="round" stroke-width="2"/>'
      '<circle cx="8" cy="10.5" r="0.8" fill="currentColor" stroke="none"/></svg>';

  /// `#ctxEditMessage` — a pencil (also `groupCtxEditName`, groups.js:3047).
  static const String ctxEdit =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 11.5 2.5 L 13.5 4.5 L 5 13 L 2 14 L 3 11 Z" stroke-linejoin="round"/>'
      '<path d="M 10 4 L 12 6" stroke-linecap="round"/></svg>';

  /// `#ctxDeleteMessage` — a trash can.
  static const String ctxDelete =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 3 5 L 13 5" stroke-linecap="round"/>'
      '<path d="M 5 5 L 5 13 C 5 13.55 5.45 14 6 14 L 10 14 C 10.55 14 11 13.55 11 13 L 11 5" stroke-linejoin="round"/>'
      '<path d="M 6.5 2 L 9.5 2" stroke-linecap="round"/>'
      '<path d="M 7 7 L 7 11.5" stroke-linecap="round"/>'
      '<path d="M 9 7 L 9 11.5" stroke-linecap="round"/></svg>';

  /// `#ctxAddMod` ("Make Moderator") — a star.
  static const String ctxMakeMod =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 8 1.5 L 10 5.5 L 14 6 L 11 9 L 12 13.5 L 8 11 L 4 13.5 L 5 9 L 2 6 L 6 5.5 Z" stroke-linejoin="round"/></svg>';

  /// `#ctxRemoveMod` ("Revoke Moderator") — a star with a strike-through.
  static const String ctxRevokeMod =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 8 1.5 L 10 5.5 L 14 6 L 11 9 L 12 13.5 L 8 11 L 4 13.5 L 5 9 L 2 6 L 6 5.5 Z" stroke-linejoin="round"/>'
      '<line x1="3" y1="3" x2="13" y2="13" stroke-linecap="round"/></svg>';

  /// `#ctxTransferOwner` ("Transfer Ownership") — a person + transfer arrow
  /// (also `groupCtxTransferOwner`, groups.js:3055).
  static const String ctxTransferOwner =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="5" r="2.5"/>'
      '<path d="M 2 14 C 2 10 4 9 8 9 C 12 9 14 10 14 14" stroke-linecap="round"/>'
      '<path d="M 12 4 L 15 4 L 13.5 2 M 15 4 L 13.5 6" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  /// `#ctxKickMember` ("Remove from Group") — a person + left arrow.
  static const String ctxKick =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 6 8 L 2 8" stroke-linecap="round"/>'
      '<path d="M 4 6 L 2 8 L 4 10" stroke-linecap="round" stroke-linejoin="round"/>'
      '<circle cx="10" cy="5.5" r="2.5"/>'
      '<path d="M 5.5 14 C 5.5 11.5 7.5 10 10 10 C 12.5 10 14.5 11.5 14.5 14" stroke-linecap="round"/></svg>';

  /// `#ctxBanMember` ("Ban from Group") — a circle with a slash.
  static const String ctxBan =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="8" r="6.5"/>'
      '<line x1="3.5" y1="3.5" x2="12.5" y2="12.5" stroke-linecap="round"/></svg>';

  /// `#ctxBlock` ("Block/Unblock User") — a smaller circle-with-slash (no-entry).
  static const String ctxBlock =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="8" r="6"/>'
      '<line x1="3.75" y1="3.75" x2="12.25" y2="12.25" stroke-width="1.5" stroke-linecap="round"/></svg>';

  /// `#ctxEditProfile` ("Edit Profile") — a head-and-shoulders bust.
  static const String ctxEditProfile =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="5.5" r="2.5"/>'
      '<path d="M 3 14 C 3 11 5 9.5 8 9.5 C 11 9.5 13 11 13 14" stroke-linecap="round"/></svg>';

  // ===========================================================================
  // Group context-menu owner/member controls (groups.js:3046-3072). The `icon()`
  // helper wraps each path set in a 16×16 stroke-1.5 `<svg>`; reproduced here.
  // ===========================================================================

  /// `groupCtxEditDescription` (groups.js:3048) — three text lines.
  static const String groupEditDescription =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<line x1="3" y1="4" x2="13" y2="4" stroke-linecap="round"/>'
      '<line x1="3" y1="8" x2="13" y2="8" stroke-linecap="round"/>'
      '<line x1="3" y1="12" x2="9" y2="12" stroke-linecap="round"/></svg>';

  /// `groupCtxChangeAvatar` (groups.js:3049) — a head-and-shoulders bust.
  static const String groupChangeAvatar =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="8" cy="6" r="3"/>'
      '<path d="M 2.5 14 C 2.5 10.5 5 9 8 9 C 11 9 13.5 10.5 13.5 14" stroke-linecap="round"/></svg>';

  /// `groupCtxChangeBanner` (groups.js:3051) — a landscape/image glyph.
  static const String groupChangeBanner =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<rect x="2" y="3" width="12" height="10" rx="1"/>'
      '<circle cx="5.5" cy="6.5" r="1"/>'
      '<path d="M 2 11 L 6 8 L 9 10 L 12 7 L 14 9" stroke-linejoin="round"/></svg>';

  /// `groupCtxResetInviteLink` (groups.js:3063) — a refresh/rotate arrow.
  static const String groupResetInvite =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 13 8 A 5 5 0 1 1 11.5 4.5" stroke-linecap="round"/>'
      '<path d="M 11.5 2 L 11.5 5 L 8.5 5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  /// `groupCtxAddMembers` (groups.js:3070) — a person + plus.
  static const String groupAddMembers =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<circle cx="6" cy="5.5" r="2.5"/>'
      '<path d="M 2 14 C 2 11 4 9.5 6 9.5 C 7 9.5 8 9.8 8.7 10.4" stroke-linecap="round"/>'
      '<line x1="12" y1="6" x2="12" y2="12" stroke-linecap="round"/>'
      '<line x1="9" y1="9" x2="15" y2="9" stroke-linecap="round"/></svg>';

  /// `groupCtxLeave` ("Leave Group", groups.js:3072) — a door + exit arrow
  /// (16×16 variant of the feather log-out).
  static const String groupLeave =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 6 2 L 3 2 C 2.5 2 2 2.5 2 3 L 2 13 C 2 13.5 2.5 14 3 14 L 6 14" stroke-linecap="round" stroke-linejoin="round"/>'
      '<path d="M 10 11 L 13 8 L 10 5" stroke-linecap="round" stroke-linejoin="round"/>'
      '<line x1="13" y1="8" x2="6" y2="8" stroke-linecap="round"/></svg>';

  /// PWA `checkbox(true)` (groups.js:3058) — a checked rounded box (toggle on).
  static const String checkboxChecked =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/>'
      '<path d="M 5 8 L 7 10 L 11 5.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  /// PWA `checkbox(false)` (groups.js:3059) — an empty rounded box (toggle off).
  static const String checkboxUnchecked =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/></svg>';

  /// Sidebar quick-menu `blockSvg` (sidebar-sections.js:165) — a 24×24
  /// circle-with-slash (no-entry). Distinct from the 16px [ctxBlock]; used for
  /// Block/Unblock user and Block channel in the sidebar row menus.
  static const String sidebarBlock =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<circle cx="12" cy="12" r="9"/>'
      '<line x1="5.6" y1="5.6" x2="18.4" y2="18.4"/></svg>';

  /// Sidebar channel-menu `favSvg` (sidebar-sections.js:163) — the filled custom
  /// 5-point star (fill-only; the PWA uses this for both favorite + unfavorite).
  static const String sidebarFavorite =
      '<svg viewBox="0 0 24 24" fill="currentColor">'
      '<path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 '
      'L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>';

  /// Sidebar channel-menu `hideSvg` (sidebar-sections.js:164) — a filled
  /// eye-with-slash (the PWA uses this for both hide + unhide).
  static const String sidebarHide =
      '<svg viewBox="0 0 24 24" fill="currentColor">'
      '<path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46A11.8 11.8 0 0 0 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>';

  // ===========================================================================
  // Call controls (#callXxxBtn, index.html:929-990) — feather glyphs, stroke 2.
  // ===========================================================================

  /// `#callMuteBtn` (index.html:944) — a microphone (mic on).
  static const String callMic =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/>'
      '<path d="M19 10v2a7 7 0 0 1-14 0v-2"/>'
      '<line x1="12" y1="19" x2="12" y2="23"/></svg>';

  /// Muted-mic variant — the PWA toggles `.active` (red) on the same mic glyph,
  /// so the muted control reuses [callMic]; this feather mic-off is kept for any
  /// surface that wants the explicit slashed glyph. (feather "mic-off")
  static const String callMicOff =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<line x1="1" y1="1" x2="23" y2="23"/>'
      '<path d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6"/>'
      '<path d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2a7 7 0 0 1-.11 1.23"/>'
      '<line x1="12" y1="19" x2="12" y2="23"/></svg>';

  /// `#callShareBtn` (index.html:956) — a monitor with an up-arrow (screen share).
  static const String callScreenShare =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<rect x="2" y="3" width="20" height="14" rx="2" ry="2"/>'
      '<line x1="8" y1="21" x2="16" y2="21"/>'
      '<line x1="12" y1="17" x2="12" y2="21"/>'
      '<polyline points="9 10 12 7 15 10"/>'
      '<line x1="12" y1="7" x2="12" y2="13"/></svg>';

  /// `#callReactBtn` (index.html:965) — a feather smile (React).
  static const String callReact =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="10"/>'
      '<path d="M8 14s1.5 2 4 2 4-2 4-2"/>'
      '<line x1="9" y1="9" x2="9.01" y2="9"/>'
      '<line x1="15" y1="9" x2="15.01" y2="9"/></svg>';

  /// `#callChatBtn` (index.html:973) — a speech bubble (Chat).
  static const String callChat =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>';

  /// `#callPresenterBtn` (index.html:979) — a person with a check (presenter).
  static const String callPresenter =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/>'
      '<circle cx="9" cy="7" r="4"/>'
      '<path d="M22 11l-3 3-2-2"/></svg>';

  /// `#callSwitchCamBtn` (index.html:930) — a camera with rotate arrows.
  static const String callSwitchCam =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>'
      '<path d="M15.5 12.5a3.5 3.5 0 0 1-5.6 2.8M8.5 11.5a3.5 3.5 0 0 1 5.6-2.8"/>'
      '<polyline points="14.5 6 14.1 8.7 11.5 8.3"/>'
      '<polyline points="9.5 19 9.9 16.3 12.5 16.7"/></svg>';

  /// `.call-chat-send` (index.html:925) — a filled paper-plane (Send).
  static const String send =
      '<svg viewBox="0 0 24 24" fill="currentColor">'
      '<path d="M2 21l21-9L2 3v7l15 2-15 2z"/></svg>';

  // ===========================================================================
  // Modal-internal glyphs (settings / identity / wallpaper). Append-only.
  // ===========================================================================

  /// `#revealPrivkeyArrow` collapsed state (index.html:1232; app.js:2959) — a
  /// filled right-pointing triangle (the nick-edit "Reveal private key" toggle
  /// when the slideout is hidden). The PWA swaps to [revealArrowDown] when open
  /// (no CSS rotation — it rewrites the SVG markup).
  static const String revealArrowRight =
      '<svg viewBox="0 0 16 16" fill="currentColor">'
      '<path d="M 6 3 L 11 8 L 6 13 Z"/></svg>';

  /// `#revealPrivkeyArrow` open state (app.js:2959) — a filled down-pointing
  /// triangle (the nick-edit reveal toggle when the slideout is shown).
  static const String revealArrowDown =
      '<svg viewBox="0 0 16 16" fill="currentColor">'
      '<path d="M 3 6 L 8 11 L 13 6 Z"/></svg>';

  /// `data-action="toggleNsecVisibility"` (index.html:1242) — an eye (show/hide
  /// the revealed nsec). The PWA shows the SAME eye regardless of password/text
  /// state (it never swaps to an eye-off glyph; `toggleNsecVisibility` only flips
  /// the input `type`), so both visibility states reuse this one glyph.
  static const String nsecEye =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 1 8 C 3 4 6 3 8 3 C 10 3 13 4 15 8 C 13 12 10 13 8 13 C 6 13 3 12 1 8 Z"/>'
      '<circle cx="8" cy="8" r="2.5"/></svg>';

  /// The nsec-warning triangle (index.html:1237) — a warning sign with an
  /// exclamation, shown above the revealed private key.
  static const String warningTriangle =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">'
      '<path d="M 8 1 L 15 14 L 1 14 Z" stroke-linejoin="round"/>'
      '<path d="M 8 6 L 8 9.5" stroke-linecap="round" stroke-width="2"/>'
      '<circle cx="8" cy="11.5" r="0.8" fill="currentColor" stroke="none"/></svg>';

  /// `.wallpaper-custom` "Upload" tile (index.html:1464) — feather upload (an
  /// up-arrow into a tray). The wallpaper "None" tile reuses the two-line
  /// [close]; the pattern tiles render a CSS preview with no glyph.
  static const String upload =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>'
      '<polyline points="17 8 12 3 7 8"/>'
      '<line x1="12" y1="3" x2="12" y2="15"/></svg>';

  /// `.file-offer-icon` (messages.js:904) — the generic feather "file" glyph the
  /// PWA shows for EVERY P2P file offer (the category only re-tints the stroke;
  /// the shape never changes). Stroke 2, no download arrow (distinct from the
  /// composer's `composerFile`).
  static const String fileOffer =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/>'
      '<polyline points="13 2 13 9 20 9"/></svg>';

  /// `.add-reaction-btn` (reactions.js:570) — a filled smiley face with a "+"
  /// (add a reaction). 20×20 `fill-rule:evenodd` path, tinted `--text`.
  static const String addReaction =
      '<svg viewBox="0 0 20 20" fill="currentColor">'
      '<path fill-rule="evenodd" clip-rule="evenodd" d="M15.5 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 15.5 1m-13 10a6.5 6.5 0 0 1 7.166-6.466.75.75 0 0 0 .152-1.493 8 8 0 1 0 7.14 7.139.75.75 0 0 0-1.492.152A7 7 0 0 1 15.5 11a6.5 6.5 0 1 1-13 0m4.25-.5a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5m4.5 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5M9 15c1.277 0 2.553-.724 3.06-2.173.148-.426-.209-.827-.66-.827H6.6c-.452 0-.808.4-.66.827C6.448 14.276 7.724 15 9 15"/></svg>';
}

/// Renders one of the [NymIcons] SVG strings at [size], tinted to [color] with a
/// `srcIn` filter (so a single colour drives both stroked and filled glyphs,
/// matching the PWA's `currentColor` behaviour).
class NymSvgIcon extends StatelessWidget {
  const NymSvgIcon(
    this.svg, {
    super.key,
    required this.size,
    required this.color,
  });

  final String svg;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
