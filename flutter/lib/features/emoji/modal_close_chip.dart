// The composer pickers' shared `.modal-close` ✕ chip. The PWA styles the
// emoji + GIF variants with ONE rule (`.emoji-modal-close, .gif-modal-close`,
// styles-components.css:1234-1243) overriding the `.modal-close` base
// (styles-components.css:91-115), so both Flutter pickers share this widget.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// The header `.modal-close.emoji-modal-close` / `.gif-modal-close` chip:
/// 28×28 (the `.modal-close` base 32×32 is overridden,
/// styles-components.css:1234-1243), circular, white@0.05 fill, 1px glass
/// border, 14px ✕ in `--text-dim`; hover swaps to the danger palette
/// (`.modal-close:hover`, styles-components.css:111-115).
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
                ? const Color(0x1FFF4444) // rgba(255,68,68,0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover
                  ? const Color(0x4DFF4444) // rgba(255,68,68,0.3)
                  : c.glassBorder,
            ),
          ),
          // Both PWA buttons are a literal "✕" char (`&#x2715;`,
          // reactions.js:710 / ui-context.js:2009) — styled text.
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
