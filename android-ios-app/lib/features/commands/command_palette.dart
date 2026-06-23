// Command palette (`#commandPalette`) — the `/` autocomplete. Ports
// `showCommandPalette` (commands.js:364): filters visible commands by the typed
// `/needle` (canonical name OR alias prefix), groups them by category in the
// fixed order, and renders a scrollable dropdown anchored above the input with
// arrow-nav + Enter/Tab to complete. Completion inserts `"<command> "`
// (selectCommand, commands.js:489) — i.e. the canonical name plus a space.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import 'command_registry.dart';

/// A flat, navigable palette row (either a category header or a command).
sealed class PaletteRow {
  const PaletteRow();
}

class PaletteHeader extends PaletteRow {
  const PaletteHeader(this.label);
  final String label;
}

class PaletteCommand extends PaletteRow {
  const PaletteCommand(this.spec);
  final CommandSpec spec;
}

/// Filters + groups commands for [input] (the raw `/needle`). Mirrors
/// showCommandPalette: a command matches when its canonical name OR any alias
/// starts with the needle. Returns the grouped rows (headers + commands) in the
/// fixed category order, or an empty list when nothing matches (hide palette).
List<PaletteRow> buildPaletteRows(String input) {
  final needle = input.toLowerCase();
  final matching = visibleCommands().where((spec) {
    if (spec.name.startsWith(needle)) return true;
    return spec.aliases.any((a) => a.startsWith(needle));
  }).toList();

  if (matching.isEmpty) return const [];

  final rows = <PaletteRow>[];
  for (final cat in kCommandCategoryOrder) {
    final items = matching.where((s) => s.category == cat).toList();
    if (items.isEmpty) continue;
    rows.add(PaletteHeader(kCommandCategoryLabels[cat]!));
    rows.addAll(items.map(PaletteCommand.new));
  }
  return rows;
}

/// The selectable command rows only (for index math / Enter selection).
List<CommandSpec> paletteCommands(List<PaletteRow> rows) =>
    rows.whereType<PaletteCommand>().map((r) => r.spec).toList();

/// The `#commandPalette` dropdown. Stateless render; the parent owns the
/// selected index and key handling so it can intercept arrows/Enter/Tab/Esc
/// before the TextField.
class CommandPalette extends StatelessWidget {
  const CommandPalette({
    super.key,
    required this.rows,
    required this.selectedIndex,
    required this.onSelect,
  });

  /// Grouped rows from [buildPaletteRows].
  final List<PaletteRow> rows;

  /// Index into the SELECTABLE commands (not the flat rows).
  final int selectedIndex;

  /// Completes the chosen command.
  final void Function(CommandSpec spec) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    var cmdIndex = -1;

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        // `.command-palette`: rgba(20,20,35,.9) bg, glass border, top-rounded.
        color: const Color(0xE6141423),
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in rows)
              if (row is PaletteHeader)
                _header(c, row.label)
              else if (row is PaletteCommand)
                Builder(builder: (_) {
                  cmdIndex++;
                  return _commandItem(
                    c,
                    row.spec,
                    selected: cmdIndex == selectedIndex,
                  );
                }),
          ],
        ),
      ),
    );
  }

  Widget _header(NymColors c, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );

  Widget _commandItem(NymColors c, CommandSpec spec, {required bool selected}) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onSelect(spec),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.white.withValues(alpha: 0.08) : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  formatCommandDisplay(spec),
                  style: TextStyle(
                    color: c.primary,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  spec.desc,
                  style: TextStyle(color: c.textDim, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Index navigation with wrap-around (navigateCommandPalette).
int wrapIndex(int index, int direction, int length) {
  if (length == 0) return -1;
  var next = index + direction;
  if (next < 0) next = length - 1;
  if (next >= length) next = 0;
  return next;
}
