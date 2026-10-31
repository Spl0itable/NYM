import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'explorer_lists.dart';
import 'geo_explore.dart';
import 'geo_places.dart';
import '../../widgets/chat/message_row.dart'
    show HoverBarFocus, hoverBarFill, hoverBarLit, hoverBarLitFill;
import '../../widgets/common/nym_tooltip.dart';

const double kGeoTouch = 44;

class GeoControlButton extends StatefulWidget {
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
  State<GeoControlButton> createState() => _GeoControlButtonState();
}

class _GeoControlButtonState extends State<GeoControlButton> {
  final _states = WidgetStatesController();
  late final _lit = Listenable.merge([_states, HoverBarFocus.instance]);

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final radius = BorderRadius.circular(12);
    final label = widget.label;
    final badge = widget.badge;
    final active = widget.active;
    final expanded = widget.expanded;
    final hasLabel = label != null && label.isNotEmpty;
    final hasBadge = badge != null && badge.isNotEmpty;
    return Semantics(
      button: true,
      toggled: expanded == null && active ? true : null,
      expanded: expanded,
      label: widget.tooltip,
      onTap: widget.onTap,
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
                  key: widget.badgeKey,
                  constraints:
                      const BoxConstraints(minWidth: 18, minHeight: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: nym.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    badge,
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
    final active = widget.active;
    final label = widget.label;
    return NymTooltip(
      message: widget.tooltip,
      child: ListenableBuilder(
        listenable: _lit,
        builder: (context, child) {
          final lit = hoverBarLit(_states.value);
          final Color fill;
          if (lit) {
            fill = active
                ? Color.alphaBlend(nym.primaryA(0.22), hoverBarFill(nym))
                : hoverBarLitFill(nym);
          } else {
            fill = active
                ? nym.primaryA(0.22)
                : (nym.isLight
                    ? const Color(0xF2FFFFFF)
                    : const Color(0xD9000000));
          }
          final side = active
              ? nym.primaryA(0.6)
              : (lit ? nym.primaryA(0.3) : nym.glassBorder);
          return Material(
            color: fill,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: side),
            ),
            child: child,
          );
        },
        child: InkWell(
          borderRadius: radius,
          onTap: widget.onTap,
          focusNode: widget.focusNode,
          statesController: _states,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
                minWidth: kGeoTouch, minHeight: kGeoTouch),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: hasLabel ? 12 : 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon,
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
    this.street = false,
    this.onStreet,
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
  final bool street;
  final VoidCallback? onStreet;
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
      child: SingleChildScrollView(
        key: const ValueKey('geo-layers-scroll'),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            toggle('heat', tr('Heat'), heat, onHeat, autofocus: true),
            toggle('daynight', tr('Day / Night'), daynight, onDaynight),
            toggle('grid', tr('Geohash grid'), grid, onGrid),
            if (onStreet != null) _streetSwitch(nym, onStreet!),
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
                  legend(const Color(0xFFF5C518), tr('Saved'), ring: true),
                  if (showLocationLegend)
                    legend(nym.warning, tr('Your Location')),
                  if (showClusterLegend)
                    _swatchRow(
                      nym,
                      const GeoClusterSwatch(
                          key: ValueKey('geo-legend-cluster-swatch')),
                      tr('Number = channels grouped together'),
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
            Divider(height: 12, color: nym.glassBorder),
            Semantics(
              key: const ValueKey('geo-map-data'),
              container: true,
              explicitChildNodes: true,
              label: tr('Map data'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ExcludeSemantics(
                      child: Text(tr('Map data'),
                          style: TextStyle(
                              fontSize: 10,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: nym.text)),
                    ),
                    for (final line in kGeoMapCredits)
                      Text(line,
                          style: TextStyle(
                              fontSize: 10, height: 1.4, color: nym.textDim)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _streetSwitch(NymColors nym, VoidCallback tap) {
    final label = tr('Street detail');
    return Semantics(
      toggled: street,
      label: label,
      onTap: tap,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('geo-layer-street'),
        onTap: tap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kGeoTouch),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(street ? Icons.toggle_on : Icons.toggle_off,
                  size: 24, color: street ? nym.primary : nym.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 13, color: nym.text)),
              ),
            ],
          ),
        ),
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
