import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import '../identity/modal_chrome.dart';
import 'ghost_mode.dart';
import 'mesh_sheets.dart';

Future<void> toggleGhostMode(BuildContext context, WidgetRef ref) async {
  final ghost = ref.read(ghostModeProvider.notifier);
  if (ref.read(ghostModeProvider).enabled) {
    await ghost.disable();
    return;
  }
  final ok = await showMeshSheet<bool>(context, (ctx) {
    final c = ctx.nym;
    return MeshSheetFrame(
      title: tr('Enable Ghost Mode?'),
      actions: [
        ModalChrome.iconButton(
            c, tr('Cancel'), () => Navigator.of(ctx).pop(false)),
        KeyedSubtree(
          key: const ValueKey('meshGhostConfirm'),
          child: ModalChrome.sendButton(
              c, tr('Enable'), () => Navigator.of(ctx).pop(true)),
        ),
      ],
      children: [
        Text(
          tr('Ghost Mode hides who you are on the Bluetooth mesh.\n\n'
              'Your device stops advertising your nym and your Nostr identity. '
              'It presents a throwaway name and key instead, and replaces them '
              'every few minutes, so nearby devices cannot recognize you or '
              'follow you between places.\n\n'
              'You can still send and receive messages. Anyone you talk to '
              'while it is on sees an anonymous identity, not your usual one, '
              'and will not be able to tell it was you. Turning it off restores '
              'your normal identity.'),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.4),
        ),
      ],
    );
  });
  if (ok == true) await ghost.enable();
}
