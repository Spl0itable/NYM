import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/call_providers.dart';
import '../layout/chat_covered.dart';

class RingTickerGate extends ConsumerWidget {
  const RingTickerGate({
    super.key,
    this.underCallLayer = true,
    required this.child,
  });

  final bool underCallLayer;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inCall = underCallLayer &&
        ref.watch(currentCallStateProvider.select((s) => s.isActiveCall));
    final uncovered = !inCall &&
        !ChatCoveredScope.of(context) &&
        (ModalRoute.isCurrentOf(context) ?? true);
    return TickerMode(enabled: uncovered, child: child);
  }
}
