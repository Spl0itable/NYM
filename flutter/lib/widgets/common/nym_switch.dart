import 'package:flutter/material.dart';

import '../../core/theme/nym_a11y.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

typedef NymSwitchPalette = ({
  Color track,
  Color border,
  Color knob,
  double borderWidth,
});

class NymSwitch extends StatelessWidget {
  const NymSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.focused = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool focused;

  static const Duration duration = Duration(milliseconds: 150);

  static NymSwitchPalette palette(NymColors c,
      {required bool on, required bool highContrast}) {
    final width = highContrast ? 2.0 : 1.5;
    if (on) {
      return (
        track: c.primary,
        border: c.primary,
        knob: c.isLight ? Colors.white : c.bg,
        borderWidth: width,
      );
    }
    if (c.isLight) {
      return highContrast
          ? (
              track: Colors.black.withValues(alpha: 0.08),
              border: const Color(0xFF3F3F46),
              knob: const Color(0xFF3F3F46),
              borderWidth: width,
            )
          : (
              track: Colors.black.withValues(alpha: 0.06),
              border: Colors.black.withValues(alpha: 0.45),
              knob: const Color(0xFF71717A),
              borderWidth: width,
            );
    }
    return highContrast
        ? (
            track: Colors.white.withValues(alpha: 0.12),
            border: const Color(0xFFD4D4D8),
            knob: const Color(0xFFE4E4E7),
            borderWidth: width,
          )
        : (
            track: Colors.white.withValues(alpha: 0.08),
            border: Colors.white.withValues(alpha: 0.40),
            knob: const Color(0xFFA1A1AA),
            borderWidth: width,
          );
  }

  static Color ringColor(NymColors c) =>
      c.isLight ? const Color(0xFF18181B) : const Color(0xFFE4E4E7);

  static Size sizeFor(BuildContext context) =>
      context.largeTouchTargets ? const Size(48, 28) : const Size(40, 22);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final p = palette(c, on: value, highContrast: context.highContrast);
    final size = sizeFor(context);
    final knob = context.largeTouchTargets ? 22.0 : 16.0;
    final gap = (size.height - knob) / 2;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final d = reduce ? Duration.zero : duration;
    final radius = BorderRadius.circular(size.height / 2);
    final pill = SizedBox.fromSize(
      size: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (focused)
            Positioned(
              left: -4,
              top: -4,
              right: -4,
              bottom: -4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size.height / 2 + 4),
                  border: Border.all(color: ringColor(c), width: 2),
                ),
              ),
            ),
          Positioned.fill(
            child: AnimatedContainer(
              duration: d,
              curve: NymMotion.curve,
              decoration: BoxDecoration(
                color: p.track,
                borderRadius: radius,
                border: Border.all(color: p.border, width: p.borderWidth),
              ),
            ),
          ),
          AnimatedPositionedDirectional(
            duration: d,
            curve: NymMotion.curve,
            top: gap,
            start: value ? size.width - size.height + gap : gap,
            width: knob,
            height: knob,
            child: AnimatedContainer(
              duration: d,
              curve: NymMotion.curve,
              decoration: BoxDecoration(shape: BoxShape.circle, color: p.knob),
            ),
          ),
        ],
      ),
    );
    final change = onChanged;
    if (change == null) return pill;
    return GestureDetector(
      onTap: () => change(!value),
      behavior: HitTestBehavior.opaque,
      child: pill,
    );
  }
}
