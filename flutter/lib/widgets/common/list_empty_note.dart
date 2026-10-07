import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

class ListEmptyNote extends StatelessWidget {
  const ListEmptyNote({
    super.key,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = actionLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(color: c.textDim, fontSize: 12.5, height: 1.4),
          ),
          if (label != null && onAction != null) ...[
            const SizedBox(height: 8),
            Semantics(
              button: true,
              label: label,
              excludeSemantics: true,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: const ValueKey('list-empty-action'),
                  onTap: onAction,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.primary),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
