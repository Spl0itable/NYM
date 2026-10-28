import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import 'nymbot_models.dart';

class BotChipView {
  const BotChipView({
    this.label,
    this.n,
    this.figure,
    required this.tip,
    this.at,
  });

  final String? label;
  final int? n;
  final double? figure;
  final String tip;
  final int? at;
}

class BotChipText {
  const BotChipText(this.label, this.tip);

  final String label;
  final String tip;
}

BotChipView botChipView({
  required bool pro,
  required double? balance,
  required BotFreeAllowance? free,
  required int now,
  required bool purchasesDisabled,
}) {
  final buyTip = purchasesDisabled ? 'Nymbot credits' : 'Buy Nymbot credits';
  final bal = balance != null && balance.isFinite ? balance : null;
  if (bal != null && bal > 0) return BotChipView(figure: bal, tip: buyTip);
  if (!pro && free != null) {
    final f = free.at(now);
    final at = f.resetsAt;
    if (f.left > 0) {
      return at != null
          ? BotChipView(
              label: '{n} free',
              n: f.left,
              tip: 'Free replies left today. Resets at {time}',
              at: at)
          : BotChipView(
              label: '{n} free', n: f.left, tip: 'Free replies left today');
    }
    if (!purchasesDisabled) return BotChipView(label: 'Buy', tip: buyTip);
    return at != null
        ? BotChipView(
            label: '{n} free',
            n: 0,
            tip: 'Free replies reset at {time}',
            at: at)
        : const BotChipView(
            label: '{n} free', n: 0, tip: 'Free replies left today');
  }
  if (pro && bal != null) {
    return purchasesDisabled
        ? BotChipView(figure: 0, tip: buyTip)
        : BotChipView(label: 'Buy', tip: buyTip);
  }
  return BotChipView(label: purchasesDisabled ? 'Free' : 'Buy', tip: buyTip);
}

BotChipText botChipText(BotChipView v, String Function(int at) time) {
  final String label;
  switch (v.label) {
    case '{n} free':
      label = tr('{n} free', {'n': '${v.n ?? 0}'});
    case 'Free':
      label = tr('Free');
    case 'Buy':
      label = tr('Buy');
    default:
      label = creditFigure(v.figure);
  }
  final at = v.at;
  final String tip;
  switch (v.tip) {
    case 'Free replies left today. Resets at {time}':
      tip = tr('Free replies left today. Resets at {time}',
          {'time': at == null ? '' : time(at)});
    case 'Free replies reset at {time}':
      tip = tr('Free replies reset at {time}',
          {'time': at == null ? '' : time(at)});
    case 'Free replies left today':
      tip = tr('Free replies left today');
    case 'Nymbot credits':
      tip = tr('Nymbot credits');
    default:
      tip = tr('Buy Nymbot credits');
  }
  return BotChipText(label, tip);
}

String botResetTime(BuildContext context, int at) {
  final t = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(at));
  return MaterialLocalizations.of(context).formatTimeOfDay(t,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
}
