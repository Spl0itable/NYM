import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'geo_explore.dart';
import '../../widgets/common/nym_tooltip.dart';

class GeoPrecisionPath extends StatelessWidget {
  const GeoPrecisionPath({
    super.key,
    required this.geohash,
    required this.onStep,
  });

  final String geohash;
  final void Function(String prefix) onStep;

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final steps = geohashPrecisionSteps(geohash);
    if (steps.isEmpty) return const SizedBox.shrink();
    final current = geohash.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            tr('Precision'),
            style: TextStyle(
                fontSize: 12, color: nym.text, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 2,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0)
                ExcludeSemantics(
                  child: Icon(Icons.chevron_right, size: 14, color: nym.textDim),
                ),
              _step(steps[i], steps[i].geohash == current, nym),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          tr('A shorter geohash shares less about where you are.'),
          style: TextStyle(fontSize: 11, color: nym.textDim),
        ),
      ],
    );
  }

  Widget _step(GeoPrecisionStep s, bool selected, NymColors nym) {
    final label = tr(s.label);
    return Semantics(
      button: true,
      selected: selected,
      label: tr('#{geohash}, {label}, about {size}',
          {'geohash': s.geohash, 'label': label, 'size': s.size}),
      excludeSemantics: true,
      child: NymTooltip(
        message: '$label · ~${s.size}',
        child: Material(
          color: selected ? nym.primaryA(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: ValueKey('geo-step-${s.geohash}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => onStep(s.geohash),
            child: Container(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: selected ? nym.primaryA(0.5) : nym.glassBorder),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    s.geohash,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? nym.primary : nym.text,
                    ),
                  ),
                  Text(
                    label,
                    style: TextStyle(fontSize: 9, color: nym.textDim),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
