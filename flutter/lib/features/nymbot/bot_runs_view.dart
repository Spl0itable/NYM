import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/message.dart';
import '../../state/app_state.dart' show kNymbotPubkey;
import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import 'bot_runs.dart';
import 'nymbot_providers.dart';

const String kSvgBotRuns =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round">'
    '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>';

Widget? botRunTrailing(Message m, NymColors colors) {
  if (m.conversationPubkey != null && m.conversationPubkey != kNymbotPubkey) {
    return null;
  }
  if (!m.isOwn) {
    final to = m.replyTo;
    if (to == null || to.isEmpty) return null;
    return BotRunOfferView(id: to.toLowerCase(), colors: colors);
  }
  final id = m.nymMessageId;
  if (id == null || id.isEmpty) return null;
  return BotRunStatusView(id: id.toLowerCase(), colors: colors);
}

bool botRunHasStatus(BotRunsEngine engine, String? id) {
  if (id == null || id.isEmpty) return false;
  final key = id.toLowerCase();
  return engine.runs.containsKey(key) ||
      (engine.notes.containsKey(key) &&
          engine.notes[key]!.kind != BotRunNoteKind.steerOffer);
}

bool botRunHasOffer(BotRunsEngine engine, String? replyTo) {
  if (replyTo == null || replyTo.isEmpty) return false;
  return engine.notes[replyTo.toLowerCase()]?.kind == BotRunNoteKind.steerOffer;
}

String botRunAgeText(int startedAt, {int? nowMs}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final min = ((now - startedAt) / 60000).floor();
  return min < 1
      ? tr('Started just now')
      : tr('Started {n} min ago', {'n': min});
}

String botRunStateLine(BotRunState state) {
  switch (state) {
    case BotRunState.waiting:
    case BotRunState.capped:
      return tr('Waiting for a free slot');
    case BotRunState.claiming:
      return tr('Still working on that one…');
    case BotRunState.running:
      return tr('Nymbot is thinking');
  }
}

Future<void> openBotSteer(
    BuildContext context, WidgetRef ref, String id) async {
  final controller = ref.read(botChatControllerProvider.notifier);
  final text = await showAppPrompt(
    context,
    tr('Nymbot passes this to the running request at its next step. It does not change what the request can spend.'),
    title: tr('Add instructions'),
    placeholder: tr('For example: also cover the pricing'),
    okLabel: tr('Send to this request'),
    cancelLabel: tr('Cancel'),
    maxLength: kBotRunSteerChars,
    multiline: true,
  );
  if (text == null || text.trim().isEmpty) return;
  final thread = controller.runsEngine.threadFor(id);
  final out = await controller.steerRun(id, text);
  switch (out) {
    case BotSteerOutcome.ok:
      controller.botNotice('Passed on. It applies at the next step.');
    case BotSteerOutcome.tooLong:
      controller.botNotice(
          'That is too long. Instructions can be up to 2,000 characters.');
    case BotSteerOutcome.retry:
      controller.botNotice('Could not pass that on. Try again in a moment.');
    case BotSteerOutcome.finished:
    case BotSteerOutcome.answering:
      if (!context.mounted) return;
      final ok = await showAppConfirm(
        context,
        tr('Send your instructions as a new message instead?'),
        title: out == BotSteerOutcome.answering
            ? tr('That request is already writing its answer')
            : tr('That request has finished'),
        okLabel: tr('Send as a message'),
        cancelLabel: tr('Cancel'),
      );
      if (ok) await controller.sendAsMessage(text.trim(), thread);
    case BotSteerOutcome.empty:
      return;
  }
}

class BotRunStatusView extends ConsumerWidget {
  const BotRunStatusView({super.key, required this.id, required this.colors});

  final String id;
  final NymColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(botChatControllerProvider.select((s) => s.runsVersion));
    final controller = ref.read(botChatControllerProvider.notifier);
    final engine = controller.runsEngine;
    final key = id.toLowerCase();
    final run = engine.runs[key];
    final note = engine.notes[key];
    final c = colors;
    final children = <Widget>[];
    if (run != null) {
      final cap = run.cap;
      if (run.state == BotRunState.capped && cap != null) {
        final opts = engine.capOptions(key);
        children.add(Text(cap.error, style: _text(c)));
        children.add(_actions([
          if (opts.contains(BotRunCapOption.start))
            _btn(c, tr('Start anyway'), () => engine.capStart(key)),
          if (opts.contains(BotRunCapOption.always))
            _btn(c, tr('Always allow up to {n}', {'n': engine.capAlwaysN(cap)}),
                () => engine.capAlways(key)),
          if (opts.contains(BotRunCapOption.wait))
            _btn(c, tr('Wait'), () => engine.capWait(key)),
        ]));
      } else {
        children.add(Row(
          children: [
            _Dot(color: c.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                run.state == BotRunState.running && run.progress.isNotEmpty
                    ? '${botRunStateLine(run.state)} · ${run.progress}'
                    : botRunStateLine(run.state),
                style: _text(c),
              ),
            ),
          ],
        ));
        children.add(_actions([
          if (run.state != BotRunState.waiting)
            _btn(c, tr('Add instructions'),
                () => openBotSteer(context, ref, key)),
          _btn(c, tr('Stop'), () => controller.stopRun(key), danger: true),
        ]));
      }
    } else if (note != null) {
      switch (note.kind) {
        case BotRunNoteKind.stopped:
          children.add(Text(tr('Stopped.'), style: _text(c)));
        case BotRunNoteKind.failed:
          children.add(Text(
              tr('Nymbot could not finish that one. Try again; it will not be charged twice.'),
              style: _text(c, color: c.danger)));
          children.add(
              _actions([_btn(c, tr('Try again'), () => engine.retry(key))]));
        case BotRunNoteKind.steerLate:
          children.add(Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: tr('That request has finished'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(
                  text:
                      ' ${tr('Send your instructions as a new message instead?')}'),
            ]),
            style: _text(c),
          ));
          children.add(_actions([
            _btn(c, tr('Send as a message'),
                () => controller.sendSteerNote(key)),
          ]));
        case BotRunNoteKind.steerOffer:
          break;
        case BotRunNoteKind.error:
          children.add(Text(note.text, style: _text(c, color: c.danger)));
        case BotRunNoteKind.capFree:
          children.add(Text(note.text, style: _text(c)));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 6, bottom: 4),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: c.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
          border: Border(
              left: BorderSide(
                  color: c.primary.withValues(alpha: 0.5), width: 2)),
        ),
        child: Semantics(
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  static TextStyle _text(NymColors c, {Color? color}) =>
      TextStyle(color: color ?? c.textDim, fontSize: 12, height: 1.4);

  static Widget _actions(List<Widget> buttons) =>
      Wrap(spacing: 6, runSpacing: 6, children: buttons);

  static Widget _btn(NymColors c, String label, VoidCallback onTap,
      {bool danger = false}) {
    final fg = danger ? c.danger : c.primary;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: const BoxConstraints(minHeight: 28),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: danger ? Colors.transparent : fg.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: fg.withValues(alpha: 0.5)),
          ),
          child: ExcludeSemantics(
            child: Text(label, style: TextStyle(color: fg, fontSize: 12)),
          ),
        ),
      ),
    );
  }
}

class BotRunOfferView extends ConsumerWidget {
  const BotRunOfferView({super.key, required this.id, required this.colors});

  final String id;
  final NymColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(botChatControllerProvider.select((s) => s.runsVersion));
    final controller = ref.read(botChatControllerProvider.notifier);
    final key = id.toLowerCase();
    if (!botRunHasOffer(controller.runsEngine, key)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: KeyedSubtree(
          key: const ValueKey('bot-steer-offer-send'),
          child: BotRunStatusView._btn(colors, tr('Send as a message'),
              () => controller.sendSteerNote(key)),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (reduce) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
      child: dot,
    );
  }
}

Future<void> showBotRunsSheet(
    BuildContext context, WidgetRef ref, NymColors colors,
    {void Function(String id)? onOpen}) {
  final controller = ref.read(botChatControllerProvider.notifier);
  controller.runsSheetOpen = true;
  controller.pollRuns();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.bgSecondary,
    builder: (sheetContext) => _BotRunsSheet(colors: colors, onOpen: onOpen),
  ).whenComplete(() => controller.runsSheetOpen = false);
}

class _BotRunsSheet extends ConsumerWidget {
  const _BotRunsSheet({required this.colors, this.onOpen});

  final NymColors colors;
  final void Function(String id)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(botChatControllerProvider.select((s) => s.runsVersion));
    final controller = ref.read(botChatControllerProvider.notifier);
    final rows = controller.runsEngine.rows();
    final c = colors;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(tr('Running now'),
                    style: TextStyle(
                        color: c.textBright,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 12),
              _limitSetting(ref),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(tr('Nothing is running right now.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textDim, fontSize: 13)),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _row(context, ref, rows[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _limitSetting(WidgetRef ref) {
    final c = colors;
    final controller = ref.read(botChatControllerProvider.notifier);
    final value = effectiveBotMaxRuns(controller.maxRuns);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Requests at once'),
            style: TextStyle(
                color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        DropdownButton<int>(
          key: const ValueKey('botMaxRunsSelect'),
          value: value,
          dropdownColor: c.bgSecondary,
          style: TextStyle(color: c.text, fontSize: 13),
          items: [
            for (var i = 1; i <= kBotRunCeiling; i++)
              DropdownMenuItem<int>(value: i, child: Text('$i')),
          ],
          onChanged: (v) {
            if (v != null) controller.setMaxRuns(v);
          },
        ),
        const SizedBox(height: 4),
        Text(
            tr('How many requests can run at the same time across your chats. Each running request holds its credits until it finishes.'),
            style: TextStyle(color: c.textDim, fontSize: 12)),
      ],
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, BotRunRow r) {
    final c = colors;
    final controller = ref.read(botChatControllerProvider.notifier);
    final meta = [
      if (r.remote) tr('On another device'),
      botRunAgeText(r.startedAt),
    ].join(' · ');
    final stateLine =
        r.state == BotRunState.running ? '' : botRunStateLine(r.state);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: c.glassBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.text, fontSize: 13)),
          if (r.progress.isNotEmpty)
            Text(r.progress, style: TextStyle(color: c.textDim, fontSize: 12)),
          if (stateLine.isNotEmpty)
            Text(stateLine, style: TextStyle(color: c.textDim, fontSize: 12)),
          Text(meta, style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            BotRunStatusView._btn(c, tr('Open'), () {
              Navigator.of(context).pop();
              onOpen?.call(r.id);
            }),
            if (r.state == BotRunState.running ||
                r.state == BotRunState.claiming)
              BotRunStatusView._btn(c, tr('Add instructions'),
                  () => openBotSteer(context, ref, r.id)),
            BotRunStatusView._btn(c, tr('Stop'), () => controller.stopRun(r.id),
                danger: true),
          ]),
        ],
      ),
    );
  }
}
