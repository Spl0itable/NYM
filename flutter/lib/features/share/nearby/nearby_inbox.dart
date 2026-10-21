import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/key_format.dart';
import '../../../core/theme/nym_colors.dart';
import '../../../widgets/common/dialog_button.dart';
import '../../i18n/i18n.dart';
import '../share_inbound.dart';
import '../share_links.dart';
import '../share_preview.dart';
import 'nearby_link.dart';
import 'nearby_rate_limit.dart';

class NearbyCard {
  const NearbyCard({
    required this.id,
    required this.peerID,
    required this.nick,
    required this.link,
    required this.parsed,
  });

  final int id;
  final String peerID;
  final String nick;
  final String link;
  final ShareParseResult parsed;
}

class NearbyInbox extends Notifier<List<NearbyCard>> {
  final NearbyRateLimit _limiter = NearbyRateLimit();
  final Map<int, Timer> _timers = {};
  int _seq = 0;

  @override
  List<NearbyCard> build() {
    ref.watch(nearbyIdentityProvider);
    _cancelTimers();
    ref.onDispose(_cancelTimers);
    return const [];
  }

  void _cancelTimers() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  bool receive(NearbySender from, String link) {
    if (ref.read(nearbyIdentityProvider).isEmpty) return false;
    final pubkey = from.pubkey?.toLowerCase() ?? '';
    if (pubkey.isEmpty || !from.verified) return false;
    if (ref.read(nearbyBlockedProvider)(pubkey)) return false;
    final parsed = parseShareInput(link);
    switch (parsed.kind) {
      case ShareParseKind.profile:
      case ShareParseKind.groupInvite:
      case ShareParseKind.channel:
        break;
      case ShareParseKind.appLink:
      case ShareParseKind.invalid:
        return false;
    }
    if (state.length >= kNearbyMaxPendingCards) return false;
    if (!_limiter.accept(from.peerID, link, ref.read(nearbyClockProvider)())) {
      return false;
    }
    final card = NearbyCard(
      id: ++_seq,
      peerID: from.peerID,
      nick: from.nick,
      link: link,
      parsed: parsed,
    );
    state = [...state, card];
    _timers[card.id] = Timer(
        const Duration(milliseconds: kNearbyCardTtlMs), () => remove(card.id));
    return true;
  }

  void remove(int id) {
    _timers.remove(id)?.cancel();
    if (state.any((c) => c.id == id)) {
      state = [
        for (final c in state)
          if (c.id != id) c,
      ];
    }
  }
}

final nearbyInboxProvider =
    NotifierProvider<NearbyInbox, List<NearbyCard>>(NearbyInbox.new);

class NearbyInboxHost extends ConsumerWidget {
  const NearbyInboxHost({
    super.key,
    required this.navigatorContext,
    required this.child,
  });

  final BuildContext? Function() navigatorContext;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(nearbyInboxProvider);
    final pad = MediaQuery.paddingOf(context);
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        child,
        if (cards.isNotEmpty)
          Positioned(
            left: 12 + pad.left,
            right: 12 + pad.right,
            bottom: 12 + pad.bottom,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in cards)
                        Padding(
                          key: ValueKey('nearby-card-${c.id}'),
                          padding: const EdgeInsets.only(top: 8),
                          child: _NearbyCardView(
                            card: c,
                            onOpen: () => _open(ref, c),
                            onDismiss: () => ref
                                .read(nearbyInboxProvider.notifier)
                                .remove(c.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _open(WidgetRef ref, NearbyCard card) {
    ref.read(nearbyInboxProvider.notifier).remove(card.id);
    final ctx = navigatorContext();
    if (ctx == null || !ctx.mounted) return;
    unawaited(ref.read(inboundShareProvider).handle(ctx, card.link,
        source: InboundSource.nearby, fromLabel: card.nick));
  }
}

class _NearbyCardView extends ConsumerWidget {
  const _NearbyCardView({
    required this.card,
    required this.onOpen,
    required this.onDismiss,
  });

  final NearbyCard card;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<NymColors>();
    final scheme = Theme.of(context).colorScheme;
    final fg = c?.text ?? scheme.onSurface;
    final dim = c?.textDim ?? scheme.onSurfaceVariant;
    final bg = c == null
        ? scheme.surfaceContainerHighest
        : Color.alphaBlend(c.bgTertiary, c.bg);
    final border = c?.border ?? scheme.outlineVariant;
    final p = card.parsed;
    final (String title, List<String> lines, String action) = switch (p.kind) {
      ShareParseKind.profile => (
          tr('{nick} wants to share a profile', {'nick': card.nick}),
          [
            ?ref.read(nearbyNymOfProvider)(p.pubkey),
            shortNpub(npubOrHex(p.pubkey)),
          ],
          tr('Open'),
        ),
      ShareParseKind.groupInvite => (
          tr('{nick} wants to share a group', {'nick': card.nick}),
          [if (p.name.trim().isNotEmpty) p.name.trim()],
          tr('Ask to join'),
        ),
      _ => (
          tr('{nick} wants to share a channel', {'nick': card.nick}),
          ['#${p.channel}', if (p.geohash) tr('Location channel')],
          tr('Open'),
        ),
    };
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: fg, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          for (final line in lines) ...[
            const SizedBox(height: 3),
            Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: dim, fontSize: 13),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              DialogButton.secondary(label: tr('Dismiss'), onTap: onDismiss),
              DialogButton(
                key: const ValueKey('nearby-card-open'),
                label: action,
                onTap: onOpen,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
