import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/i18n/i18n.dart';

const String kPmOnlyNoSelection = 'No conversation selected';
const String kPmOnlyEmptyTitle = 'No conversations yet';
const String kPmOnlyEmptyHint =
    'Click the {plus} button in the Private Messages section to start a new group chat or private message.';

class PmOnlyEmptyState extends StatelessWidget {
  const PmOnlyEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hint = tr(kPmOnlyEmptyHint).split('{plus}');
    return SizedBox.expand(
      key: const ValueKey('pmOnlyEmptyState'),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: 0.5,
                child: Text('+',
                    style: TextStyle(color: c.textDim, fontSize: 48)),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(tr(kPmOnlyEmptyTitle),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textDim, fontSize: 16)),
              ),
              Opacity(
                opacity: 0.7,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: hint.first),
                    for (final part in hint.skip(1)) ...[
                      const TextSpan(
                          text: '+',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: part),
                    ],
                  ]),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textDim, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
