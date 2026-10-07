import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/i18n/i18n.dart';
import '../../features/layout/layout_model.dart';
import '../nym_icons.dart';
import 'nym_focusable.dart';
import 'nym_sheet.dart';

bool useNymActionSheet(BuildContext context) =>
    MediaQuery.sizeOf(context).width <= kPhoneMax;

class NymActionEntry<T> {
  const NymActionEntry({
    required this.label,
    this.svg = '',
    this.value,
    this.danger = false,
    this.enabled = true,
    this.key,
  })  : heading = false,
        divider = false;

  const NymActionEntry.heading(this.label)
      : svg = '',
        value = null,
        danger = false,
        enabled = false,
        key = null,
        heading = true,
        divider = false;

  const NymActionEntry.divider()
      : label = '',
        svg = '',
        value = null,
        danger = false,
        enabled = false,
        key = null,
        heading = false,
        divider = true;

  final String label;
  final String svg;
  final T? value;
  final bool danger;
  final bool enabled;
  final Key? key;
  final bool heading;
  final bool divider;
}

typedef NymActionRowBuilder<T> = Widget Function(
    BuildContext context, NymActionEntry<T> entry, VoidCallback pick);

Future<T?> showNymActionSheet<T>(
  BuildContext context,
  List<NymActionEntry<T>> entries, {
  String label = 'Conversation menu',
  Widget? header,
  NymActionRowBuilder<T>? rowBuilder,
  bool expandable = false,
}) {
  return showNymBottomSheet<T>(
    context,
    (ctx) => NymActionSheet<T>(
      entries: entries,
      label: label,
      header: header,
      rowBuilder: rowBuilder,
    ),
    useRootNavigator: true,
    expandable: expandable,
  );
}

class NymActionSheet<T> extends StatelessWidget {
  const NymActionSheet({
    super.key,
    required this.entries,
    required this.label,
    this.header,
    this.rowBuilder,
  });

  final List<NymActionEntry<T>> entries;
  final String label;
  final Widget? header;
  final NymActionRowBuilder<T>? rowBuilder;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      container: true,
      label: tr(label),
      child: SingleChildScrollView(
        key: const ValueKey('nymActionSheet'),
        padding: header == null
            ? const EdgeInsets.fromLTRB(12, 0, 12, 12)
            : const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?header,
            for (final e in entries)
              if (e.heading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Text(
                    e.label.toUpperCase(),
                    style: TextStyle(
                        color: c.textDim, fontSize: 10, letterSpacing: 0.8),
                  ),
                )
              else if (e.divider)
                Divider(height: 9, thickness: 1, color: c.glassBorder)
              else if (rowBuilder != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: rowBuilder!(
                      context, e, () => Navigator.of(context).pop(e.value)),
                )
              else
                _ActionRow<T>(entry: e),
          ],
        ),
      ),
    );
  }
}

class _ActionRow<T> extends StatelessWidget {
  const _ActionRow({required this.entry});

  final NymActionEntry<T> entry;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final e = entry;
    final fg = !e.enabled
        ? c.textDim
        : e.danger
            ? c.danger
            : c.text;
    final icon = e.danger && e.enabled ? c.danger : c.textDim;
    void pick() => Navigator.of(context).pop(e.value);
    return NymFocusable(
      key: e.key,
      onActivate: e.enabled ? pick : null,
      label: e.label,
      excludeChildSemantics: true,
      child: InkWell(
        onTap: e.enabled ? pick : null,
        canRequestFocus: false,
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (e.svg.isNotEmpty) ...[
                  NymSvgIcon(e.svg, size: 18, color: icon),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Text(
                    e.label,
                    style: TextStyle(
                        color: fg, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
