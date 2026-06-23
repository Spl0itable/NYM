// incoming_call.dart - #incomingCallModal port. Auto-shows when an inbound
// call offer arrives (callStateProvider phase == incoming) and offers
// Accept / Reject, honoring the acceptCalls preference (the gate itself lives
// in CallService._onInvite — by the time this renders, ringing was allowed).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/common/nym_avatar.dart';
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
    final nym = call.peerNym ?? 'Someone';
    final label =
        'Incoming ${call.kind == CallKind.video ? 'video' : 'audio'} call'
        '${call.isGroup ? ' (group)' : ''}';

    return Material(
      color: Colors.black.withValues(alpha: 0.75),
      child: Center(
        child: Container(
          width: 320,
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.glassBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pulsing avatar ring.
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.primary, width: 2),
                ),
                child: NymAvatar(seed: nym, size: 88),
              ),
              const SizedBox(height: 16),
              Text(
                nym,
                style: TextStyle(
                  color: c.textBright,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(color: c.textDim, fontSize: 14)),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundActionButton(
                    color: c.danger,
                    icon: Icons.call_end,
                    tooltip: 'Decline',
                    onTap: service.reject,
                  ),
                  _RoundActionButton(
                    color: const Color(0xFF22C55E),
                    icon: Icons.call,
                    tooltip: 'Accept',
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

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.color,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}
