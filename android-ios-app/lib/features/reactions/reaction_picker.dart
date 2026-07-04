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

/// Breakpoint below which the picker centres (PWA `window.innerWidth <= 768`).
const double _kReactionPickerMobileMax = 768;

/// Opens the enhanced emoji picker as a reaction picker for [message]
/// (reactions.js `showEnhancedReactionPicker`). Picking an emoji toggles the
/// reaction via [NostrController.toggleReaction] with the inferred original
/// kind, records the pick into recents, and plays the add burst.
///
/// Recents (F7): the picker's "Recently Used" section is sourced from
/// [recentEmojisProvider] (read here, not passed by the caller) and the chosen
/// emoji is recorded back to it on pick.
///
/// Positioning (F10): on a wide window (> 768px) with an [anchorRect] (the
/// add-reaction trigger's global bounds) the picker is anchored next to the
/// trigger (below if there is room, else above; right-aligned past mid-screen),
/// mirroring the PWA desktop branch. Otherwise it is centred (the PWA mobile
/// branch).
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
    // The PWA appends the `.enhanced-emoji-modal` straight to <body> with no
    // backdrop; an outside click closes it (ui-context.js:1106-1112).
    barrierColor: Colors.transparent,
    builder: (dialogCtx) {
      // `.enhanced-emoji-modal`: width 350, max-height 400
      // (styles-components.css:1203-1217); the mobile branch overrides via
      // inline style to max-width 90% / max-height 80vh (reactions.js:834-836;
      // the inline max-height wins over the class's 400px).
      final card = EnhancedEmojiModal(
        width: anchored ? 350 : math.min(350, screen.width * 0.9),
        height: anchored ? 400 : screen.height * 0.8,
        recents: recents,
        onClose: () => Navigator.of(dialogCtx).maybePop(),
        onSelect: (emoji) async {
          Navigator.of(dialogCtx).maybePop();
          // Record the pick into the shared recents store (F7) so the
          // "Recently Used" section reflects it next time.
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
            // Every add path buzzes: `sendReaction` fires `nymHapticTap` (the
            // shared 30ms vibrate) right after the optimistic add
            // (reactions.js:968) — including picks from this enhanced picker.
            HapticFeedback.mediumImpact();
            if (context.mounted) {
              // Anchor at the message's reaction badge for this emoji (it
              // mounts this frame from the optimistic add) — the PWA's
              // `_burstOnBadge(messageId, emoji, messageEl)` from the toggle
              // path (reactions.js:977), not at the picker cell.
              ReactionBurst.playAtBadge(context, message.id, emoji);
            }
          }
        },
      );

      if (!anchored) {
        // Mobile: `top:50%;left:50%;transform:translate(-50%,-50%)`.
        return Center(child: card);
      }
      return _AnchoredPicker(anchorRect: anchorRect, screen: screen, child: card);
    },
  );
}

/// Positions [child] next to [anchorRect] on desktop, mirroring the PWA's
/// `showEnhancedReactionPicker` desktop math (reactions.js:838-846): below when
/// `spaceBelow > 450 || spaceBelow > spaceAbove`, else above; when the trigger
/// sits past mid-screen `right: min(innerWidth - rect.right, 10)`, else
/// `left: max(rect.left, 10)`.
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
    final double? left =
        rightAlign ? null : math.max(anchorRect.left, 10.0);
    final double? right = rightAlign
        ? math.min(screen.width - anchorRect.right, 10.0)
        : null;

    return Stack(
      children: [
        Positioned(top: top, bottom: bottom, left: left, right: right, child: child),
      ],
    );
  }
}
