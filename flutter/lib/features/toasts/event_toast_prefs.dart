import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import '../settings/settings_widgets.dart' show SettingsToggleRow;
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
            SettingsToggleRow(
              key: const ValueKey('panel-eventToasts'),
              label: tr(EventToasts.strings['master']!),
              value: _s.enabled,
              spacing: 0,
              onChanged: (v) => _save(_s.copyWith(enabled: v)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Text(tr(EventToasts.strings['whileOpen']!).toUpperCase(),
                  style: TextStyle(
                    color: c.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  )),
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
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(tr(EventToasts.strings['typesHeading']!).toUpperCase(),
                  style: TextStyle(
                    color: c.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  )),
            ),
            Padding(
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
                        child: SettingsToggleRow(
                          key: ValueKey('panel-eventToastType.$k'),
                          label: tr(EventToasts.settingLabels[k]!),
                          value: _s.typeOn(k),
                          spacing: 0,
                          onChanged: typesOn
                              ? (v) => _save(_s.copyWith(types: {k: v}))
                              : null,
                        ),
                      ),
                  ],
                );
              }),
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
