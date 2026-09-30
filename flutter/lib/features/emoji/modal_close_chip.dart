import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// Header close chip shared by the emoji and GIF pickers: 28x28 circle that turns danger-red on hover.
class ModalCloseChip extends StatefulWidget {
  const ModalCloseChip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  State<ModalCloseChip> createState() => _ModalCloseChipState();
}

class _ModalCloseChipState extends State<ModalCloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? const Color(0x1FFF4444)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover
                  ? const Color(0x4DFF4444)
                  : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 14,
              height: 1,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
