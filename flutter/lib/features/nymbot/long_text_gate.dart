import 'package:flutter/widgets.dart';

import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import 'long_text.dart';
import 'nymbot_models.dart';

class BotLongPlan {
  const BotLongPlan({
    required this.cost,
    required this.check,
    required this.label,
    required this.chunks,
    this.longer,
  });

  final int cost;
  final ContextCheck check;
  final String label;
  final List<String> chunks;
  final ProModel? longer;
}

typedef BotLongChoice = ({bool go, ProModel? switchTo, List<String>? chunks});

typedef BotLongConfirm = Future<bool> Function(String message,
    {required String title, required String okLabel, required String cancelLabel});

class BotLongGate {
  static const int standardContext = 128000;
  static const int standardOut = 8192;

  static BotLongConfirm? confirm;

  static BotLongPlan? plan(String content, ProModelCatalog catalog, ProModel? pro) {
    final cost = LongText.bodyCost(content);
    if (cost <= LongText.bodyMax) return null;
    ProModel? row;
    if (pro != null) {
      for (final m in catalog.models) {
        if (m.key == pro.key) row = m;
      }
    }
    final context = row != null ? (row.context ?? 0) : standardContext;
    final out = row != null ? (row.outTokens ?? 0) : standardOut;
    final got = LongText.contextCheck(cost, context, out);
    if (got.ok) return null;
    final fitting = [
      for (final m in catalog.models)
        if ((m.context ?? 0) > 0 &&
            LongText.contextCheck(cost, m.context!, m.outTokens ?? 0).ok)
          m
    ]..sort((a, b) => a.context!.compareTo(b.context!));
    return BotLongPlan(
      cost: cost,
      check: got,
      label: row?.label ?? pro?.label ?? tr('the standard model'),
      chunks: LongText.chunksFor(content, got.limit),
      longer: fitting.isEmpty ? null : fitting.first,
    );
  }

  static Future<BotLongChoice> ask(BotLongPlan plan) async {
    final ask = confirm;
    if (ask == null) return (go: false, switchTo: null, chunks: null);
    final body = tr(
        'This message is about {kb} KB (about {tokens} tokens), and {model} reads at most about {limit} tokens at once. Nothing has been sent or charged yet.',
        {
          'kb': (plan.cost / 1024).round().clamp(1, 1 << 30),
          'tokens': plan.check.tokens,
          'model': plan.label,
          'limit': plan.check.limit,
        });
    final title = tr('Too long for this model');
    final longer = plan.longer;
    if (longer != null &&
        await ask(body,
            title: title,
            okLabel: tr('Switch to {model}', {'model': longer.label}),
            cancelLabel: tr('Other options'))) {
      return (go: true, switchTo: longer, chunks: null);
    }
    final n = plan.chunks.length;
    if (await ask(
        tr('It can go as {n} separate questions, each charged as it is sent.', {'n': n}),
        title: title,
        okLabel: tr('Send in {n} parts', {'n': n}),
        cancelLabel: tr('Cancel'))) {
      return (go: false, switchTo: null, chunks: plan.chunks);
    }
    return (go: false, switchTo: null, chunks: null);
  }
}

void registerBotLongGatePrompter(GlobalKey<NavigatorState> navKey) {
  BotLongGate.confirm = (message, {required title, required okLabel, required cancelLabel}) async {
    final ctx = navKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    return showAppConfirm(ctx, message, title: title, okLabel: okLabel, cancelLabel: cancelLabel);
  };
}
