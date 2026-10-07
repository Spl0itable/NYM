import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'explorer_lists.dart';
import 'geo_explore.dart';
import '../../widgets/common/nym_tooltip.dart';

const double kGeoTouch = 44;

class GeoControlButton extends StatelessWidget {
  const GeoControlButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.label,
    this.focusNode,
    this.badge,
    this.badgeKey,
    this.expanded,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final String? label;
  final FocusNode? focusNode;
  final String? badge;
  final Key? badgeKey;
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final radius = BorderRadius.circular(12);
    final hasLabel = label != null && label!.isNotEmpty;
    final hasBadge = badge != null && badge!.isNotEmpty;
    return Semantics(
      button: true,
      toggled: expanded == null && active ? true : null,
      expanded: expanded,
      label: tooltip,
      onTap: onTap,
      excludeSemantics: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _body(context, nym, radius, hasLabel),
          if (hasBadge)
            Positioned(
              top: -5,
              right: -5,
              child: IgnorePointer(
                child: Container(
                  key: badgeKey,
                  constraints:
                      const BoxConstraints(minWidth: 18, minHeight: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: nym.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: nym.bg,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(
      BuildContext context, NymColors nym, BorderRadius radius, bool hasLabel) {
    return NymTooltip(
      message: tooltip,
      child: Material(
        color: active
            ? nym.primaryA(0.22)
            : (nym.isLight ? const Color(0xF2FFFFFF) : const Color(0xD9000000)),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
              color: active ? nym.primaryA(0.6) : nym.glassBorder),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          focusNode: focusNode,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
                minWidth: kGeoTouch, minHeight: kGeoTouch),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: hasLabel ? 12 : 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: 20, color: active ? nym.primary : nym.text),
                  if (hasLabel) ...[
                    const SizedBox(width: 6),
                    Text(
                      label!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: active ? nym.primary : nym.text,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GeoLayersMenu extends StatelessWidget {
  const GeoLayersMenu({
    super.key,
    required this.heat,
    required this.daynight,
    required this.grid,
    required this.windowHours,
    required this.showLocationLegend,
    required this.onHeat,
    required this.onDaynight,
    required this.onGrid,
    required this.onWindow,
    this.onClose,
    this.showClusterLegend = false,
    this.showPulseLegend = false,
    this.reduceMotion = false,
  });

  final bool heat;
  final bool daynight;
  final bool grid;
  final int windowHours;
  final bool showLocationLegend;
  final VoidCallback onHeat;
  final VoidCallback onDaynight;
  final VoidCallback onGrid;
  final void Function(int hours) onWindow;
  final VoidCallback? onClose;
  final bool showClusterLegend;
  final bool showPulseLegend;
  final bool reduceMotion;

  static void _edge(BuildContext context, bool last) {
    final scope = FocusScope.of(context);
    final policy =
        FocusTraversalGroup.maybeOf(context) ?? ReadingOrderTraversalPolicy();
    final target = last
        ? policy.findLastFocus(scope, ignoreCurrentFocus: true)
        : policy.findFirstFocus(scope, ignoreCurrentFocus: true);
    target?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: Builder(
        builder: (inner) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                FocusScope.of(inner).nextFocus(),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                FocusScope.of(inner).previousFocus(),
            const SingleActivator(LogicalKeyboardKey.home): () =>
                _edge(inner, false),
            const SingleActivator(LogicalKeyboardKey.end): () =>
                _edge(inner, true),
            const SingleActivator(LogicalKeyboardKey.escape): ?onClose,
          },
          child: _menu(inner),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final nym = context.nym;
    Widget toggle(String key, String label, bool on, VoidCallback tap,
            {bool autofocus = false}) =>
        Semantics(
          checked: on,
          label: label,
          onTap: tap,
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('geo-layer-$key'),
            autofocus: autofocus,
            onTap: tap,
            child: Container(
              constraints: const BoxConstraints(minHeight: kGeoTouch),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 20, color: on ? nym.primary : nym.textDim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(label,
                        style: TextStyle(fontSize: 13, color: nym.text)),
                  ),
                ],
              ),
            ),
          ),
        );
    Widget legend(Color c, String label, {bool ring = false}) => Semantics(
          label: label,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ring ? Colors.transparent : c,
                    border: ring ? Border.all(color: c, width: 2) : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(label, style: TextStyle(fontSize: 11, color: nym.text)),
              ],
            ),
          ),
        );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: tr('Layers'),
      child: _panel(nym, toggle, legend),
    );
  }

  Widget _panel(
    NymColors nym,
    Widget Function(String, String, bool, VoidCallback, {bool autofocus})
        toggle,
    Widget Function(Color, String, {bool ring}) legend,
  ) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: nym.isLight ? const Color(0xFAFFFFFF) : const Color(0xF2000000),
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toggle('heat', tr('Heat'), heat, onHeat, autofocus: true),
          toggle('daynight', tr('Day / Night'), daynight, onDaynight),
          toggle('grid', tr('Geohash grid'), grid, onGrid),
          Divider(height: 12, color: nym.glassBorder),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(tr('Activity'),
                        style: TextStyle(fontSize: 12, color: nym.textDim)),
                  ),
                ),
                GeoWindowControl(
                    hours: windowHours, onChanged: onWindow, radio: true),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: tr('Legend'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                legend(nym.primary, tr('Active')),
                legend(const Color(0xFF28E07A), tr('Joined')),
                legend(const Color(0xFFF5C518), tr('Saved'), ring: true),
                if (showLocationLegend)
                  legend(nym.warning, tr('Your Location')),
                if (showClusterLegend)
                  _swatchRow(
                    nym,
                    const GeoClusterSwatch(
                        key: ValueKey('geo-legend-cluster-swatch')),
                    tr('Number = rooms grouped together'),
                  ),
                if (showPulseLegend)
                  _swatchRow(
                    nym,
                    GeoPulseSwatch(
                      key: const ValueKey('geo-legend-pulse-swatch'),
                      animate: !reduceMotion,
                    ),
                    tr('Pulsing = active in the last {n} minutes',
                        {'n': kGeoPulseWindowMs ~/ 60000}),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _swatchRow(NymColors nym, Widget swatch, String label) {
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          children: [
            Transform.translate(
              offset: const Offset(-3, 0),
              child: SizedBox(width: 16, height: 16, child: swatch),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 11, color: nym.text)),
            ),
          ],
        ),
      ),
    );
  }
}

class GeoClusterSwatch extends StatelessWidget {
  const GeoClusterSwatch({super.key});

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: nym.primary.withValues(alpha: 0.9),
        border: Border.all(color: const Color(0x8C000000), width: 1.5),
      ),
      child: Text(
        '3',
        style: TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w700,
          color: nym.bg,
        ),
      ),
    );
  }
}

class GeoPulseSwatch extends StatefulWidget {
  const GeoPulseSwatch({super.key, required this.animate});

  final bool animate;

  @override
  State<GeoPulseSwatch> createState() => _GeoPulseSwatchState();
}

class _GeoPulseSwatchState extends State<GeoPulseSwatch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(GeoPulseSwatch old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) _c.repeat();
    if (!widget.animate && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = widget.animate ? Curves.easeOut.transform(_c.value) : 1.0;
        final scale = widget.animate ? 0.4 + 0.6 * t : 1.0;
        final opacity = widget.animate ? 0.7 * (1 - t) : 0.6;
        return Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: nym.primary, width: 1.5),
                  ),
                ),
              ),
            ),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: nym.primary,
              ),
            ),
          ],
        );
      },
    );
  }
}
