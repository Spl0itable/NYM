// Incoming-call modal with Accept/Reject; the acceptCalls gate already ran in CallService._onInvite.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'call_nym.dart';
import 'call_providers.dart';
import 'call_signaling.dart';

/// Mount once near the app root; renders nothing unless an incoming call is presented.
class IncomingCallModal extends ConsumerWidget {
  const IncomingCallModal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(currentCallStateProvider);
    if (!call.isIncoming) return const SizedBox.shrink();

    final c = context.nym;
    final service = ref.read(callServiceProvider);
    final nym = call.peerNym ?? tr('Someone');
    final hasPubkey = call.peerPubkey != null && call.peerPubkey!.isNotEmpty;
    // Seed by pubkey so the identicon is stable across nym changes; nym only when no pubkey is known.
    final avatarSeed = hasPubkey ? call.peerPubkey! : nym;
    final picture = hasPubkey
        ? ref.watch(usersProvider)[call.peerPubkey!]?.profile?.picture
        : null;
    final kind = call.kind == CallKind.video ? tr('video') : tr('audio');
    final label = call.isGroup
        ? tr('Incoming {kind} call (group)', {'kind': kind})
        : tr('Incoming {kind} call', {'kind': kind});

    return Material(
      // This Material is the overlay fill, not a barrier, so it is gated on the resolved light/dark mode.
      color: c.isLight
          ? const Color(0x73000000)
          : const Color(0xBF000000),
      child: Center(
        child: Container(
          width: 320,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.glassBorder),
            boxShadow: c.isLight
                ? const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 40,
                      offset: Offset(0, 8),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 32,
                      offset: Offset(0, 8),
                    ),
                    BoxShadow(
                      color: c.primary.withValues(alpha: 0.1),
                      blurRadius: 20,
                    ),
                    BoxShadow(
                      color: Colors.white
                          .withValues(alpha: 0.05),
                      spreadRadius: 1,
                    ),
                  ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PulsingAvatar(
                  seed: avatarSeed, primary: c.primary, imageUrl: picture),
              const SizedBox(height: 14),
              DefaultTextStyle(
                style: TextStyle(
                  color: c.textBright,
                  fontSize: 19.2,
                  fontWeight: FontWeight.w600,
                ),
                child: (call.peerPubkey != null && call.peerPubkey!.isNotEmpty)
                    ? CallNym(
                        pubkey: call.peerPubkey!,
                        nym: call.peerNym,
                        baseColor: c.textBright,
                        baseStyle: const TextStyle(
                          fontSize: 19.2,
                          fontWeight: FontWeight.w600,
                        ),
                        badgeSize: 16,
                      )
                    : Text(
                        nym,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(color: c.textDim, fontSize: 13.6)),
              const SizedBox(height: 22),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundActionButton(
                    color: c.danger,
                    iconColor: Colors.white,
                    svg: NymIcons.phone,
                    rotation: 0.375,
                    tooltip: tr('Decline'),
                    onTap: service.reject,
                  ),
                  const SizedBox(width: 36),
                  _RoundActionButton(
                    color: c.primary,
                    iconColor: c.bg,
                    svg: NymIcons.phone,
                    tooltip: tr('Accept'),
                    onTap: () => service.answer(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulsingAvatar extends StatefulWidget {
  const _PulsingAvatar({
    required this.seed,
    required this.primary,
    this.imageUrl,
  });
  final String seed;
  final Color primary;
  final String? imageUrl;

  @override
  State<_PulsingAvatar> createState() => _PulsingAvatarState();
}

class _PulsingAvatarState extends State<_PulsingAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        // Keyframes: spread 0 at alpha .4 at 0/100%, spread 12 at alpha 0 at 50%.
        final t = _ctrl.value;
        final p = t < 0.5 ? t * 2 : (1 - t) * 2;
        final spread = 12.0 * p;
        final alpha = 0.4 * (1 - p);
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: widget.primary, width: 2),
            boxShadow: [
              BoxShadow(
                color: widget.primary.withValues(alpha: alpha),
                spreadRadius: spread,
                blurRadius: 0,
              ),
            ],
          ),
          child: child,
        );
      },
      child: NymAvatar(seed: widget.seed, size: 88, imageUrl: widget.imageUrl),
    );
  }
}

class _RoundActionButton extends StatefulWidget {
  const _RoundActionButton({
    required this.color,
    required this.svg,
    required this.tooltip,
    required this.onTap,
    this.iconColor = Colors.white,
    this.rotation = 0,
  });

  final Color color;
  final Color iconColor;
  final String svg;
  final String tooltip;
  final VoidCallback onTap;

  /// Glyph rotation in turns (0.375 = 135°).
  final double rotation;

  @override
  State<_RoundActionButton> createState() => _RoundActionButtonState();
}

class _RoundActionButtonState extends State<_RoundActionButton> {
  bool _hover = false;

  /// CSS `brightness(1.1)`: multiply RGB channels by 1.1.
  Color _brighten(Color color) => Color.from(
        alpha: color.a,
        red: math.min(1, color.r * 1.1),
        green: math.min(1, color.g * 1.1),
        blue: math.min(1, color.b * 1.1),
      );

  @override
  Widget build(BuildContext context) {
    final bg = _hover ? _brighten(widget.color) : widget.color;
    final fg = _hover ? _brighten(widget.iconColor) : widget.iconColor;
    Widget glyph = NymSvgIcon(widget.svg, color: fg, size: 26);
    if (widget.rotation != 0) {
      glyph =
          Transform.rotate(angle: widget.rotation * 2 * math.pi, child: glyph);
    }
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover ? 1.08 : 1,
          duration: const Duration(milliseconds: 150),
          child: Material(
            color: bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onTap,
              child: SizedBox(
                width: 58,
                height: 58,
                child: Center(child: glyph),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
