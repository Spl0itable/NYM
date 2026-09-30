import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import 'enhanced_emoji_modal.dart';
import 'reaction_burst.dart';

/// Breakpoint at or below which the picker centers.
const double _kReactionPickerMobileMax = 768;

/// Opens the emoji picker as a reaction picker, anchored to [anchorRect] on wide windows and centered otherwise.
void showReactionPicker(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  Rect? anchorRect,
}) {
  final recents = ref.read(recentEmojisProvider);
  final screen = MediaQuery.of(context).size;
  final anchored =
      anchorRect != null && screen.width > _kReactionPickerMobileMax;

  showDialog<void>(
    context: context,
    // No backdrop; an outside tap closes it.
    barrierColor: Colors.transparent,
    builder: (dialogCtx) {
      // Mobile caps it at 90% width and 80% height.
      final card = EnhancedEmojiModal(
        width: anchored ? 350 : math.min(350, screen.width * 0.9),
        height: anchored ? 400 : screen.height * 0.8,
        recents: recents,
        onClose: () => Navigator.of(dialogCtx).maybePop(),
        onSelect: (emoji) async {
          Navigator.of(dialogCtx).maybePop();
          ref.read(recentEmojisProvider.notifier).record(emoji);
          final controller = ref.read(nostrControllerProvider);
          final view = ref.read(currentViewProvider);
          final already = (ref.read(reactionsProvider)[message.id] ??
                  const <MessageReaction>[])
              .any((r) => r.emoji == emoji && r.userReacted);
          final ok = await controller.toggleReaction(
            message.id,
            emoji,
            target: reactionTargetFor(message),
            kind: inferOriginalKind(message, view: view),
          );
          if (ok && !already) {
            HapticFeedback.mediumImpact();
            if (context.mounted) {
              // Anchor at the message's reaction badge, which mounts this frame from the optimistic add.
              ReactionBurst.playAtBadge(context, message.id, emoji);
            }
          }
        },
      );

      if (!anchored) {
        return Center(child: card);
      }
      return _AnchoredPicker(
          anchorRect: anchorRect, screen: screen, child: card);
    },
  );
}

/// Below the trigger when there is room, else above; right-aligned past mid-screen.
class _AnchoredPicker extends StatelessWidget {
  const _AnchoredPicker({
    required this.anchorRect,
    required this.screen,
    required this.child,
  });

  final Rect anchorRect;
  final Size screen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spaceBelow = screen.height - anchorRect.bottom;
    final spaceAbove = anchorRect.top;
    final openBelow = spaceBelow > 450 || spaceBelow > spaceAbove;
    final rightAlign = anchorRect.left > screen.width * 0.5;

    final double? top = openBelow ? anchorRect.bottom + 10 : null;
    final double? bottom =
        openBelow ? null : (screen.height - anchorRect.top + 10);
    final double? left = rightAlign ? null : math.max(anchorRect.left, 10.0);
    final double? right =
        rightAlign ? math.min(screen.width - anchorRect.right, 10.0) : null;

    return Stack(
      children: [
        Positioned(
            top: top, bottom: bottom, left: left, right: right, child: child),
      ],
    );
  }
}
