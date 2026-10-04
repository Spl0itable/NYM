// The `/` command palette: filters by name or alias prefix, groups by category, and completes `"<command> "`.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'command_i18n.dart';
import 'command_registry.dart';

/// A flat, navigable palette row (category header or command).
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

/// Commands whose name or any alias starts with the needle, grouped in category order; empty hides the palette.
List<PaletteRow> buildPaletteRows(String input) {
  final needle = input.toLowerCase();
  final matching = visibleCommands().where((spec) {
    if (spec.name.startsWith(needle)) return true;
    if (localizedCommandToken(spec.name).startsWith(needle)) return true;
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

/// Selectable command rows only, for index math.
List<CommandSpec> paletteCommands(List<PaletteRow> rows) =>
    rows.whereType<PaletteCommand>().map((r) => r.spec).toList();

/// The parent owns selection and key handling so it can intercept keys before the TextField.
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.rows,
    required this.selectedIndex,
    required this.onSelect,
    this.docked = false,
  });

  final List<PaletteRow> rows;
  final bool docked;

  /// Index into the selectable commands, not the flat rows.
  final int selectedIndex;

  final void Function(CommandSpec spec) onSelect;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void didUpdateWidget(CommandPalette old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) {
      scrollPaletteSelectedIntoView(_scroll, _selectedKey);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    var cmdIndex = -1;

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: commandPaletteDecoration(c, docked: widget.docked),
      child: SingleChildScrollView(
        controller: _scroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in widget.rows)
              if (row is PaletteHeader)
                _header(c, row.label)
              else if (row is PaletteCommand)
                Builder(builder: (_) {
                  cmdIndex++;
                  return _commandItem(
                    c,
                    row.spec,
                    selected: cmdIndex == widget.selectedIndex,
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
          // Category labels are UI copy: localize before upper-casing.
          tr(label).toUpperCase(),
          style: TextStyle(
            color: c.textDim.withValues(alpha: 0.7),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );

  Widget _commandItem(NymColors c, CommandSpec spec, {required bool selected}) {
    return commandItemRow(
      c,
      name: localizedCommandDisplay(spec),
      desc: spec.desc,
      selected: selected,
      rowKey: selected ? _selectedKey : null,
      onTap: () => widget.onSelect(spec),
    );
  }
}

/// Public `?` Nymbot palette with the same chrome, flat (no headers), first row preselected; completes `"?<name> "`.
class BotCommandPalette extends StatefulWidget {
  const BotCommandPalette({
    super.key,
    required this.rows,
    required this.selectedIndex,
    required this.onSelect,
    this.docked = false,
  });

  final List<BotPaletteCommand> rows;
  final bool docked;

  final int selectedIndex;

  final void Function(BotPaletteCommand cmd) onSelect;

  @override
  State<BotCommandPalette> createState() => _BotCommandPaletteState();
}

class _BotCommandPaletteState extends State<BotCommandPalette> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void didUpdateWidget(BotCommandPalette old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) {
      scrollPaletteSelectedIntoView(_scroll, _selectedKey);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: commandPaletteDecoration(c, docked: widget.docked),
      child: SingleChildScrollView(
        controller: _scroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.rows.length; i++)
              commandItemRow(
                c,
                name: widget.rows[i].command,
                desc: widget.rows[i].desc,
                selected: i == widget.selectedIndex,
                rowKey: i == widget.selectedIndex ? _selectedKey : null,
                onTap: () => widget.onSelect(widget.rows[i]),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shared palette decoration; solid-ui is detected by its fully opaque glass background token.
BoxDecoration commandPaletteDecoration(NymColors c, {bool docked = false}) =>
    BoxDecoration(
      color: c.glassBg.a == 1.0
          ? c.glassBg
          : c.isLight
              ? const Color(0xEBFFFFFF)
              : const Color(0xE6141423),
      border: Border.all(color: c.glassBorder),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      boxShadow: docked
          ? null
          : [
              BoxShadow(
                color: c.isLight
                    ? const Color(0x1F000000)
                    : const Color(0x80000000),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
    );

/// Scrolls the selected row into view after the next frame.
void scrollPaletteSelectedIntoView(
    ScrollController controller, GlobalKey selectedKey) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = selectedKey.currentContext;
    if (ctx == null || !controller.hasClients) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  });
}

/// Shared command row for both palettes: bold primary name on the left, description on the right.
Widget commandItemRow(
  NymColors c, {
  required String name,
  required String desc,
  required bool selected,
  required VoidCallback onTap,
  Key? rowKey,
}) {
  return Material(
    key: rowKey,
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      // White overlays vanish on the light surface, so use the mode-aware overlay tokens.
      hoverColor: c.hoverOverlay,
      highlightColor:
          c.isLight ? const Color(0x14000000) : const Color(0x1FFFFFFF),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.hoverOverlay : null,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        // Top-aligned so a wrapped description keeps the name on the first line.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Command tokens are syntax and never localized; sized to content so the description gets the remaining width.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 175),
              child: Text(
                name,
                softWrap: false,
                style: TextStyle(
                  color: c.primary,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            // Description fills the remaining width and wraps; localized here since catalogs store English source.
            Expanded(
              child: Text(
                tr(desc),
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: selected ? c.text : c.textDim,
                  fontSize: 12,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Index navigation with wrap-around.
int wrapIndex(int index, int direction, int length) {
  if (length == 0) return -1;
  var next = index + direction;
  if (next < 0) next = length - 1;
  if (next >= length) next = 0;
  return next;
}
