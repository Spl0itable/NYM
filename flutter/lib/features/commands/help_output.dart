// `/help` output as structured data, plain text for the system-message sink, and a styled block.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'command_i18n.dart';
import 'command_registry.dart';

/// One `/help` category: its header label and commands in registry order.
class HelpCategoryGroup {
  const HelpCategoryGroup(this.label, this.commands);

  /// Title-case label; uppercased visually only.
  final String label;

  final List<CommandSpec> commands;
}

/// Visible commands grouped by category in fixed order, dropping empty categories.
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

String get kHelpTitle => tr('Available commands');

/// The five footer lines, separated by blank lines.
List<String> get kHelpFooterLines => [
      tr('Markdown supported: **bold**, *italic*, ~~strikethrough~~, `code`, > quote'),
      tr('Type : to quickly pick an emoji'),
      tr('Type \\ to pick a kaomoji like ¯\\_(ツ)_/¯'),
      tr('Nyms are shown as name#xxxx where xxxx is the last 4 characters of their '
          'pubkey'),
      tr('Click on users for more options'),
    ];

/// One help line: `"/name, /alias — desc"`.
String helpCommandLine(CommandSpec spec) =>
    '${localizedCommandDisplay(spec)} — ${spec.desc}';

/// Plain-text `/help`: title, category headers with command lines, then footer lines separated by blank lines.
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

/// Styled help block inside the system-message pill; [fontSize] is the pill's inherited size.
class HelpOutputBlock extends StatelessWidget {
  const HelpOutputBlock({super.key, required this.fontSize});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Pill text style (w500 ≈ CSS 450, height 1.3).
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
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(kHelpTitle,
              textAlign: TextAlign.left,
              style: base.copyWith(fontWeight: FontWeight.w700)),
        ),
        for (final group in buildHelpGroups()) ...[
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text.rich(
                TextSpan(
                  style: base.copyWith(height: 1.4),
                  children: [
                    TextSpan(
                      text: localizedCommandDisplay(spec),
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
        // Both the top rule and the text sit inside the 0.85-opacity footer.
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
