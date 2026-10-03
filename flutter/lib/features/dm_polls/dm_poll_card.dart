import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../polls/poll_card.dart';
import 'dm_polls.dart';
import 'dm_polls_providers.dart';
import 'dm_polls_service.dart';

bool dmPollHasCard(Message m) => DmPollsService.isPollMessage(m);

class DmPollCard extends ConsumerWidget {
  const DmPollCard({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(dmPollsRevisionProvider);
    final app = ref.watch(appStateProvider);
    final users = ref.watch(usersProvider);
    final svc = ref.read(dmPollsProvider);
    final v = svc.viewFor(message);
    if (v == null) return const SizedBox.shrink();
    final c = context.nym;
    final poll = svc.asPoll(message, v);
    final t = v.tally;
    final header = Row(
      children: [
        Text(
          '📊 ${tr(DmPollStrings.header)}',
          style: TextStyle(
            color: c.textDim,
            fontSize: 11,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (t.closed) ...[
          const SizedBox(width: 8),
          Container(
            key: ValueKey('dmPollClosed-${v.pollId}'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rxs,
            ),
            child: Text(
              tr(DmPollStrings.closed),
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ),
        ],
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Container(
        key: ValueKey('dmPoll-${v.pollId}'),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.isLight
              ? const Color(0x08000000)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(padding: const EdgeInsets.only(bottom: 8), child: header),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                v.poll.question,
                style: TextStyle(
                  color: c.textBright,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ),
            for (var i = 0; i < poll.options.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              PollOptionTile(
                key: ValueKey('dmPollOption-${v.pollId}-$i'),
                poll: poll,
                option: poll.options[i],
                total: t.total,
                selected: v.mine == i,
                avatarFor: (pk) => users[pk]?.profile?.picture,
                onTap: v.canVote ? () => unawaited(svc.vote(v.pollId, i)) : null,
              ),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  PollVotesFooter(
                    total: t.total,
                    onTap: (rect) {
                      if (poll.votes.isEmpty) return;
                      showPollVotersModal(
                        context,
                        anchorRect: rect,
                        poll: poll,
                        selfPubkey: app.selfPubkey,
                        onOpenPM: (pk) =>
                            ref.read(nostrControllerProvider).startPM(pk),
                      );
                    },
                  ),
                  const Spacer(),
                  if (v.canClose)
                    TextButton(
                      key: ValueKey('dmPollClose-${v.pollId}'),
                      onPressed: () => unawaited(svc.close(v.pollId)),
                      style: TextButton.styleFrom(
                        foregroundColor: c.textDim,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        minimumSize: const Size(0, 28),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: Text(tr(DmPollStrings.closePoll)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
