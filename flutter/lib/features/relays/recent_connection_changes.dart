import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../services/relay/connection_changes.dart';
import '../i18n/i18n.dart';

String connectionChangeText(ConnectionChangeReason reason) => switch (reason) {
      ConnectionChangeReason.proxyDown =>
        tr('Direct: the proxy was unreachable'),
      ConnectionChangeReason.proxyBack => tr('Proxy: reachable again'),
      ConnectionChangeReason.chosenDirect => tr('Direct: chosen by you'),
      ConnectionChangeReason.chosenProxy => tr('Proxy: chosen by you'),
    };

String connectionChangeTime(DateTime at) {
  final t = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

class RecentConnectionChanges extends StatelessWidget {
  const RecentConnectionChanges({super.key, this.log});

  final ConnectionChangeLog? log;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final source = log ?? connectionChanges;
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final items = source.items;
        return Column(
          key: const ValueKey('recent-connection-changes'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                tr('Recent connection changes').toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.textDim,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            if (items.isEmpty)
              Text(
                tr('No connection changes yet'),
                style: TextStyle(color: c.textDim, fontSize: 12),
              )
            else
              for (final e in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connectionChangeTime(e.at),
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          connectionChangeText(e.reason),
                          style: TextStyle(
                            color: e.direct ? c.text : c.primary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }
}
