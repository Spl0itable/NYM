// `/help` output — a 1:1 port of `showHelp()` (commands.js:522-546) and the
// `.help-output` component styles (styles-components.css:879-915).
//
// The PWA posts a rich `displaySystemMessage(html)` block:
//   <div class="help-output">
//     <div class="help-title">Available commands</div>
//     <div class="help-category">…</div>       (one per non-empty category)
//     <div class="help-cmd"><span class="help-cmd-name">/name, /alias</span>
//       — desc</div>                            (one per visible command)
//     <div class="help-footer">line<br><br>line…</div>
//   </div>
//
// This file provides both forms:
//  * [buildHelpGroups] + [kHelpFooterLines] — the structured data (exact PWA
//    strings, category order, alias folding via [formatCommandDisplay]);
//  * [buildHelpMessageText] — the plain-text rendering the dispatcher hands to
//    `engine.systemMessage` (the string sink);
//  * [HelpOutputBlock] — the styled widget for the system-message pill, with
//    parameter parity to the `.help-output` CSS in both themes (all colors are
//    mode-aware [NymColors] tokens; the CSS has no light-mode overrides for
//    `.help-*` beyond the `--primary`/`--glass-border` variable swaps).

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import 'command_registry.dart';

/// One `/help` category section: the verbatim header label plus its commands
/// in registry order (`_groupCommandsByCategory`, commands.js:357-363).
class HelpCategoryGroup {
  const HelpCategoryGroup(this.label, this.commands);

  /// Display label from `commandCategories` (e.g. 'Public Channels'). The CSS
  /// uppercases it visually (`text-transform: uppercase`) — the content stays
  /// title-case.
  final String label;

  final List<CommandSpec> commands;
}

/// Groups the visible commands by category in the fixed PWA order, dropping
/// empty categories — `_groupCommandsByCategory(_visibleCommandEntries())`.
List<HelpCategoryGroup> buildHelpGroups() {
  return [
    for (final cat in kCommandCategoryOrder)
      if (visibleCommands().any((s) => s.category == cat))
        HelpCategoryGroup(
          kCommandCategoryLabels[cat]!,
          visibleCommands().where((s) => s.category == cat).toList(),
        ),
  ];
}

/// `.help-title` text (commands.js:534).
const String kHelpTitle = 'Available commands';

/// The five `.help-footer` lines, verbatim (commands.js:531-537). Joined with
/// `<br><br>` in the PWA — i.e. one blank line between each.
const List<String> kHelpFooterLines = [
  'Markdown supported: **bold**, *italic*, ~~strikethrough~~, `code`, > quote',
  'Type : to quickly pick an emoji',
  'Type \\ to pick a kaomoji like ¯\\_(ツ)_/¯',
  'Nyms are shown as name#xxxx where xxxx is the last 4 characters of their '
      'pubkey',
  'Click on users for more options',
];

/// One `.help-cmd` line: `"/name, /alias — desc"` (commands.js:526).
String helpCommandLine(CommandSpec spec) =>
    '${formatCommandDisplay(spec)} — ${spec.desc}';

/// The full `/help` output as plain text for the system-message sink: title,
/// blank line, each category header followed by its command lines, then the
/// footer lines separated by blank lines (the `<br><br>` joins). Content is
/// identical to the PWA block; the `.help-output` STYLING lives in
/// [HelpOutputBlock].
String buildHelpMessageText() {
  final buf = StringBuffer(kHelpTitle);
  for (final group in buildHelpGroups()) {
    buf.write('\n\n${group.label}');
    for (final spec in group.commands) {
      buf.write('\n${helpCommandLine(spec)}');
    }
  }
  for (final line in kHelpFooterLines) {
    buf.write('\n\n$line');
  }
  return buf.toString();
}

/// The styled `.help-output` block (styles-components.css:879-915), rendered
/// inside the `.system-message` pill:
///  * `.help-output` — left-aligned, shrink-wrapped (`display: inline-block`
///    overriding the pill's centered text);
///  * `.help-title` — w700, 8px bottom margin;
///  * `.help-category` — 10px w700 UPPERCASE, letter-spacing 0.06em (0.6px),
///    `--primary` @0.85 opacity, 10px top / 3px bottom margins;
///  * `.help-cmd` — 1px vertical padding, line-height 1.4; the
///    `.help-cmd-name` span is `--primary` w600, then " — desc" in the
///    inherited pill color;
///  * `.help-footer` — 12px top margin, 10px top padding, 1px `--glass-border`
///    top rule, the whole footer (rule included) @0.85 opacity, lines
///    separated by blank lines.
///
/// [fontSize] is the pill's inherited size (`settings.textSize - 3`); the base
/// color/weight/line-height mirror `.system-message` (text-dim, w500 for the
/// CSS 450, height 1.3) so unstyled runs inherit exactly what the pill shows.
class HelpOutputBlock extends StatelessWidget {
  const HelpOutputBlock({super.key, required this.fontSize});

  /// Inherited `.system-message` font size.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Inherited `.system-message` text style (w500 ≈ CSS 450, height 1.3).
    final base = TextStyle(
      color: c.textDim,
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // `.help-title` — bold, 8px below.
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(kHelpTitle,
              textAlign: TextAlign.left,
              style: base.copyWith(fontWeight: FontWeight.w700)),
        ),
        for (final group in buildHelpGroups()) ...[
          // `.help-category` — 10px uppercase w700 primary @0.85, ls 0.06em.
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 3),
            child: Text(
              group.label.toUpperCase(),
              textAlign: TextAlign.left,
              style: TextStyle(
                color: c.primary.withValues(alpha: 0.85),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                height: 1.3,
              ),
            ),
          ),
          for (final spec in group.commands)
            // `.help-cmd` — primary w600 name + " — " + desc, lh 1.4.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text.rich(
                TextSpan(
                  style: base.copyWith(height: 1.4),
                  children: [
                    TextSpan(
                      text: formatCommandDisplay(spec),
                      style: TextStyle(
                        color: c.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: ' — ${spec.desc}'),
                  ],
                ),
                textAlign: TextAlign.left,
              ),
            ),
        ],
        // `.help-footer` — the 1px glass top rule and the text both sit inside
        // the 0.85-opacity element.
        Opacity(
          opacity: 0.85,
          child: Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.glassBorder)),
            ),
            child: Text(
              kHelpFooterLines.join('\n\n'),
              textAlign: TextAlign.left,
              style: base,
            ),
          ),
        ),
      ],
    );
  }
}
