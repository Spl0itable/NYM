// incoming_call.dart - #incomingCallModal port. Auto-shows when an inbound
// call offer arrives (callStateProvider phase == incoming) and offers
// Accept / Reject, honoring the acceptCalls preference (the gate itself lives
// in CallService._onInvite — by the time this renders, ringing was allowed).

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

/// Drop this once near the app root (e.g. in a Stack over the main scaffold).
/// It renders nothing unless an incoming call is being presented.
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
    // Identicon seed is the caller PUBKEY (stable across nym changes, matches
    // the PWA `generateAvatarSvg(pubkey)`); fall back to the nym only when no
    // pubkey is known for the inbound call.
    final avatarSeed = hasPubkey ? call.peerPubkey! : nym;
    // Real caller avatar (Rule 4).
    final picture = hasPubkey
        ? ref.watch(usersProvider)[call.peerPubkey!]?.profile?.picture
        : null;
    final kind = call.kind == CallKind.video ? tr('video') : tr('audio');
    final label = call.isGroup
        ? tr('Incoming {kind} call (group)', {'kind': kind})
        : tr('Incoming {kind} call', {'kind': kind});

    return Material(
      // `.modal` backdrop: solid-ui (default) dark `rgba(0,0,0,0.75)` →
      // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
      // (styles-themes-responsive.css:1630-1635). This Material IS the overlay
      // fill (not a barrier), so gate it on the resolved mode.
      color: c.isLight
          ? const Color(0x73000000) // black @ 0.45
          : const Color(0xBF000000), // black @ 0.75
      child: Center(
        child: Container(
          // `.incoming-call-content`: max-width 320, padding 28/24, over
          // `.modal-content` (radius 24 + shadow-lg + shadow-glow + 1px ring).
          width: 320,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.glassBorder),
            // `body.light-mode .modal-content { box-shadow: 0 8px 40px
            // rgba(0,0,0,0.12) }` — one soft shadow, no glow, no white ring in
            // light (styles-themes-responsive.css:1050-1052).
            boxShadow: c.isLight
                ? const [
                    BoxShadow(
                      color: Color(0x1F000000), // black @ 0.12
                      blurRadius: 40,
                      offset: Offset(0, 8),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x80000000), // shadow-lg 0 8 32 black/0.5
                      blurRadius: 32,
                      offset: Offset(0, 8),
                    ),
                    BoxShadow(
                      color: c.primary.withValues(alpha: 0.1), // shadow-glow
                      blurRadius: 20,
                    ),
                    BoxShadow(
                      color:
                          Colors.white.withValues(alpha: 0.05), // 1px white ring
                      spreadRadius: 1,
                    ),
                  ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pulsing avatar ring (`.incoming-call-avatar` incomingCallPulse:
              // a 1.6s primary box-shadow ring expanding 0→12px).
              // `.incoming-call-avatar-wrap { margin-bottom: 14px }`.
              _PulsingAvatar(
                  seed: avatarSeed, primary: c.primary, imageUrl: picture),
              const SizedBox(height: 14),
              // Decorated caller name (#suffix + badges/flair), `_callNymHtml`.
              // `.incoming-call-name`: 1.2rem (19.2px), weight 600,
              // margin-bottom 4.
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
              // `.incoming-call-sub`: 0.85rem (13.6px), margin-bottom 22.
              Text(label, style: TextStyle(color: c.textDim, fontSize: 13.6)),
              const SizedBox(height: 22),
              // Buttons: 58px, fixed 36px gap, decline=danger (icon rotated
              // 135°), accept=primary bg with bg-coloured icon (PWA, not green).
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundActionButton(
                    color: c.danger,
                    iconColor: Colors.white,
                    // `.incoming-call-btn.decline` — feather phone rotated 135°.
                    svg: NymIcons.phone,
                    rotation: 0.375,
                    tooltip: tr('Decline'),
                    onTap: service.reject,
                  ),
                  const SizedBox(width: 36),
                  _RoundActionButton(
                    color: c.primary,
                    iconColor: c.bg,
                    // `.incoming-call-btn.accept` — feather phone, primary bg.
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

/// The 88px avatar wrapped in a repeating primary box-shadow ring that expands
/// 0→12px and fades over 1.6s (`@keyframes incomingCallPulse`).
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
        // CSS keyframe: 0/100% → spread 0 @ alpha .4; 50% → spread 12 @ alpha 0.
        final t = _ctrl.value;
        // Triangular 0→1→0 envelope so the ring grows then resets each cycle.
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

  /// Glyph rotation in turns (`.incoming-call-btn.decline svg` is rotated 135°
  /// in the PWA: 135/360 = 0.375).
  final double rotation;

  @override
  State<_RoundActionButton> createState() => _RoundActionButtonState();
}

class _RoundActionButtonState extends State<_RoundActionButton> {
  bool _hover = false;

  /// CSS `filter: brightness(1.1)` — multiply the RGB channels by 1.1.
  Color _brighten(Color color) => Color.from(
        alpha: color.a,
        red: math.min(1, color.r * 1.1),
        green: math.min(1, color.g * 1.1),
        blue: math.min(1, color.b * 1.1),
      );

  @override
  Widget build(BuildContext context) {
    // `.incoming-call-btn:hover { transform: scale(1.08); filter:
    // brightness(1.1); }` with `transition: transform 0.15s, filter 0.15s`.
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
