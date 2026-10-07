import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import 'event_toast_settings_store.dart';
import 'event_toasts.dart';

class EventToastPrefsSection extends ConsumerStatefulWidget {
  const EventToastPrefsSection({super.key});

  @override
  ConsumerState<EventToastPrefsSection> createState() =>
      _EventToastPrefsSectionState();
}

class _EventToastPrefsSectionState
    extends ConsumerState<EventToastPrefsSection> {
  late EventToastSettings _s =
      readEventToastSettings(ref.read(keyValueStoreProvider));

  void _save(EventToastSettings next) {
    setState(() => _s = next);
    writeEventToastSettings(ref.read(keyValueStoreProvider), next);
    ref.read(settingsProvider.notifier).notifySyncedChange();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final typesOn = _s.enabled && _s.foreground != 'system';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.glassBorder)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Check(
              key: const ValueKey('eventToastsMaster'),
              label: tr(EventToasts.strings['master']!),
              value: _s.enabled,
              onChanged: (v) => _save(_s.copyWith(enabled: v)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(tr(EventToasts.strings['whileOpen']!),
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in EventToasts.foregroundModes)
                  _ModeChip(
                    key: ValueKey('eventToastMode-$m'),
                    label: tr(EventToasts.foregroundLabels[m]!),
                    selected: _s.foreground == m,
                    onTap: () => _save(_s.copyWith(foreground: m)),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text(tr(EventToasts.strings['typesHeading']!),
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ),
            Opacity(
              opacity: typesOn ? 1 : 0.5,
              child: Padding(
                padding: const EdgeInsets.only(left: 20),
                child: LayoutBuilder(builder: (context, box) {
                  const gap = 12.0;
                  final cols =
                      ((box.maxWidth + gap) / (190 + gap)).floor().clamp(1, 8);
                  final w = (box.maxWidth - gap * (cols - 1)) / cols;
                  return Wrap(
                    spacing: gap,
                    children: [
                      for (final k in EventToasts.types)
                        SizedBox(
                          width: w,
                          child: _Check(
                            key: ValueKey('eventToastType-$k'),
                            label: tr(EventToasts.settingLabels[k]!),
                            value: _s.typeOn(k),
                            indent: true,
                            onChanged: typesOn
                                ? (v) => _save(_s.copyWith(types: {k: v}))
                                : null,
                          ),
                        ),
                    ],
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.indent = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final cb = onChanged;
    return Padding(
      padding: EdgeInsets.only(top: indent ? 6 : 0),
      child: InkWell(
        onTap: cb == null ? null : () => cb(!value),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: cb == null ? null : (v) => cb(v ?? false),
                activeColor: c.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child:
                  Text(label, style: TextStyle(color: c.textDim, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? c.primaryA(0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? c.primary : c.glassBorder),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? c.primary : c.textDim,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
