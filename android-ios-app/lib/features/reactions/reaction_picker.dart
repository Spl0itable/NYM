import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../emoji/emoji_picker.dart';
import 'reaction_burst.dart';

/// Opens the enhanced emoji picker as a reaction picker for [message]
/// (reactions.js `showEnhancedReactionPicker`). Picking an emoji toggles the
/// reaction via [NostrController.toggleReaction] with the inferred original
/// kind and plays the add burst.
///
/// The PWA anchors this to the add-reaction button; natively we present it
/// centred (mirroring the PWA's mobile branch which centres the picker).
void showReactionPicker(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  List<String> recents = const [],
}) {
  showDialog<void>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (dialogCtx) => Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
        width: MediaQuery.of(context).size.width * 0.9,
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.nym.bgSecondary,
          border: Border.all(color: context.nym.glassBorder),
          borderRadius: NymRadius.rmd,
        ),
        clipBehavior: Clip.antiAlias,
        child: EmojiPicker(
          recents: recents,
          onSelect: (emoji) async {
            Navigator.of(dialogCtx).maybePop();
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
            if (ok && !already && context.mounted) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null && box.hasSize) {
                ReactionBurst.play(
                    context, box.localToGlobal(box.size.center(Offset.zero)), emoji);
              }
            }
          },
        ),
      ),
    ),
  );
}
