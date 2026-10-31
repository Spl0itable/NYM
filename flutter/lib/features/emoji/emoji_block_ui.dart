import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/user.dart';
import '../../state/app_state.dart' show liveCustomEmojiProvider, usersProvider;
import '../../state/nostr_controller.dart' show nostrControllerProvider;
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/hit_slop.dart';
import '../../widgets/common/nym_tooltip.dart';
import '../../widgets/context_menu/report_modal.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';
import '../settings/settings_widgets.dart' show DangerPillButton;
import 'custom_emoji.dart';
import 'emoji_block.dart';
import 'emoji_data.dart' show kEmojiPackFavoritesKey;

class EmojiPackBlockButton extends StatelessWidget {
  const EmojiPackBlockButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = tr('Block this pack');
    return HitSlop(
      child: NymTooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            key: const ValueKey('emoji-pack-block'),
            onTap: onTap,
            borderRadius: NymRadius.rxs,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: NymSvgIcon(NymIcons.ctxBlock, size: 14, color: c.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

String emojiPackAuthorLabel(Map<String, User> users, String pubkey) {
  final nym = users[pubkey]?.nym ?? '';
  if (nym.isNotEmpty) return nym;
  return pubkey.length > 8 ? '${pubkey.substring(0, 8)}…' : pubkey;
}

Future<void> _dropFavorite(String key) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kEmojiPackFavoritesKey);
    if (raw == null || raw.isEmpty) return;
    final list = jsonDecode(raw);
    if (list is! List || !list.contains(key)) return;
    await prefs.setString(
        kEmojiPackFavoritesKey, jsonEncode([...list.where((k) => k != key)]));
  } catch (_) {}
}

void _sync(WidgetRef ref) {
  try {
    ref.read(nostrControllerProvider).syncSettings();
  } catch (_) {}
}

Future<bool> blockEmojiPackNow(WidgetRef ref, CustomEmojiPack pack) async {
  if (!ref.read(blockedEmojiPacksProvider.notifier).block(pack)) return false;
  ref.read(liveCustomEmojiProvider.notifier).blocksChanged();
  await _dropFavorite(pack.key);
  _sync(ref);
  return true;
}

void unblockEmojiPack(WidgetRef ref, String coord) {
  ref.read(blockedEmojiPacksProvider.notifier).unblock(coord);
  ref.read(liveCustomEmojiProvider.notifier).unblocked(coord);
  _sync(ref);
}

Future<void> openEmojiPackReport(
    BuildContext context, WidgetRef ref, CustomEmojiPack pack) async {
  final coord = EmojiBlock.packCoord(pack);
  if (coord.isEmpty) return;
  final name = pack.title.isNotEmpty ? pack.title : pack.identifier;
  final author = emojiPackAuthorLabel(ref.read(usersProvider), pack.pubkey);
  await ReportModal.show(
    context,
    targetNym: '',
    pack: (name: name, author: author),
    onSubmit: (type, details, _) {
      ref
          .read(nostrControllerProvider)
          .submitEmojiPackReport(coord: coord, type: type, details: details);
    },
  );
}

Future<void> confirmBlockEmojiPack(
    BuildContext context, WidgetRef ref, CustomEmojiPack pack) async {
  final res = await showAppConfirmWithCheckbox(
    context,
    tr('Emoji from this pack will be hidden everywhere: the emoji picker, autocomplete, reactions and messages. You can unblock it in Settings.'),
    title: tr('Block emoji pack?'),
    okLabel: tr('Block'),
    checkboxLabel: tr('Also report this pack'),
    danger: true,
  );
  if (!res.confirmed) return;
  if (!await blockEmojiPackNow(ref, pack)) return;
  if (res.checked && context.mounted) {
    await openEmojiPackReport(context, ref, pack);
  }
}

class BlockedEmojiPacksList extends ConsumerWidget {
  const BlockedEmojiPacksList({super.key, this.frame, this.emptyFrame});

  final Widget Function(Widget child)? frame;
  final Widget Function(String text)? emptyFrame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final list = ref.watch(blockedEmojiPacksProvider);
    if (list.isEmpty) {
      final empty = tr('No blocked emoji packs');
      return emptyFrame?.call(empty) ??
          Text(empty, style: TextStyle(color: c.textDim, fontSize: 12));
    }
    final packs = ref.watch(liveCustomEmojiProvider.select((s) => s.packs));
    final users = ref.watch(usersProvider);
    final rows = <Widget>[];
    for (final e in list.reversed) {
      final key = e.coord.substring(6);
      CustomEmojiPack? pack;
      for (final p in packs) {
        if (p.key == key) {
          pack = p;
          break;
        }
      }
      final sample = e.sample.isNotEmpty
          ? [for (final s in e.sample) s.url]
          : [for (final x in (pack?.emojis ?? const []).take(4)) x.url];
      final name = e.name.isNotEmpty
          ? e.name
          : (pack != null && pack.title.isNotEmpty ? pack.title : e.d);
      rows.add(Padding(
        key: ValueKey('blocked-emoji-pack-${e.coord}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final url in sample.take(4))
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: InlineNetworkImage(
                        url: proxiedMedia(url, emoji: true),
                        width: 20,
                        height: 20,
                        fit: BoxFit.contain,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.text, fontSize: 13)),
                  Text(
                      tr('by {author}', {
                        'author': emojiPackAuthorLabel(users, e.author),
                      }),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textDim, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            DangerPillButton(
              label: tr('Unblock'),
              onPressed: () => unblockEmojiPack(ref, e.coord),
            ),
          ],
        ),
      ));
    }
    final body = Column(
      key: const ValueKey('blockedEmojiPacksList'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
    return frame?.call(body) ?? body;
  }
}
