import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../groups/group_logic.dart';
import '../i18n/i18n.dart';

class ShortcutRow {
  const ShortcutRow(this.action, this.label, this.mac, this.other);
  final String action;
  final String label;
  final List<String> mac;
  final List<String> other;
}

const List<ShortcutRow> kShortcutSheet = [
  ShortcutRow('search', 'Search and switch chats', ['⌘', 'K'], ['Ctrl', 'K']),
  ShortcutRow('prevChat', 'Previous chat', ['⌥', 'up'], ['Alt', 'up']),
  ShortcutRow('nextChat', 'Next chat', ['⌥', 'down'], ['Alt', 'down']),
  ShortcutRow('nextUnread', 'Next unread chat', ['⌥', 'shift', 'down'],
      ['Alt', 'Shift', 'down']),
  ShortcutRow('back', 'Go back', ['⌥', 'left'], ['Alt', 'left']),
  ShortcutRow('forward', 'Go forward', ['⌥', 'right'], ['Alt', 'right']),
  ShortcutRow('editLast', 'Edit your last message (empty composer)', ['up'],
      ['up']),
  ShortcutRow('escape', 'Close the top layer', ['Esc'], ['Esc']),
  ShortcutRow('settings', 'Open Settings', ['⌘', ','], ['Ctrl', ',']),
  ShortcutRow('help', 'Show keyboard shortcuts', ['?'], ['?']),
];

String? shortcutAction({
  required String key,
  bool ctrl = false,
  bool meta = false,
  bool alt = false,
  bool shift = false,
  bool mac = false,
  bool inText = false,
  bool inComposer = false,
  bool composerEmpty = false,
}) {
  final k = key.length == 1 ? key.toLowerCase() : key;
  if (k == 'Escape') return !ctrl && !meta && !alt && !shift ? 'escape' : null;
  final primary = mac ? meta : ctrl;
  final secondary = mac ? ctrl : meta;
  if (secondary) return null;
  if (primary) {
    if (alt || shift) return null;
    if (k == 'k') return 'search';
    if (k == ',' && !inText) return 'settings';
    return null;
  }
  if (alt) {
    if (inText) return null;
    if (k == 'ArrowDown') return shift ? 'nextUnread' : 'nextChat';
    if (shift) return null;
    if (k == 'ArrowUp') return 'prevChat';
    if (k == 'ArrowLeft') return 'back';
    if (k == 'ArrowRight') return 'forward';
    return null;
  }
  if (k == 'ArrowUp') {
    return !shift && inText && inComposer && composerEmpty ? 'editLast' : null;
  }
  if (k == '?' && !inText) return 'help';
  return null;
}

String? shortcutNavTarget(
    List<String> order, String? current, String dir, List<String> unread) {
  final n = order.length;
  if (n == 0) return null;
  final i = current == null ? -1 : order.indexOf(current);
  if (dir == 'nextUnread') {
    for (var s = 1; s <= n; s++) {
      final k = order[i < 0 ? (s - 1) % n : (i + s) % n];
      if (k != current && unread.contains(k)) return k;
    }
    return null;
  }
  if (i < 0) return dir == 'next' ? order.first : order.last;
  if (n < 2) return null;
  return order[(i + (dir == 'next' ? 1 : -1) + n) % n];
}

bool get shortcutsUseMac =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

String shortcutKeyLabel(String action, {bool? mac}) {
  final m = mac ?? shortcutsUseMac;
  for (final r in kShortcutSheet) {
    if (r.action == action) {
      final keys = [for (final k in m ? r.mac : r.other) _kKeyNames[k] ?? k];
      return m ? keys.join() : keys.join('+');
    }
  }
  return '';
}

String? shortcutKeyName(KeyEvent e) {
  final k = e.logicalKey;
  if (k == LogicalKeyboardKey.escape) return 'Escape';
  if (k == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
  if (k == LogicalKeyboardKey.arrowDown) return 'ArrowDown';
  if (k == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
  if (k == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
  if (k == LogicalKeyboardKey.comma) return ',';
  if (k == LogicalKeyboardKey.question) return '?';
  if (e.character == '?') return '?';
  if (k == LogicalKeyboardKey.slash && HardwareKeyboard.instance.isShiftPressed) {
    return '?';
  }
  final label = k.keyLabel;
  return label.length == 1 ? label.toLowerCase() : null;
}

String shortcutNavKey(ChatView v) => switch (v.kind) {
      ViewKind.channel => 'c:${v.id}',
      ViewKind.pm => 'p:${v.id}',
      ViewKind.group => 'g:${v.id}',
    };

int shortcutUnreadFor(Map<String, int> unread, ChatView v) => switch (v.kind) {
      ViewKind.channel => unread[v.storageKey] ?? 0,
      ViewKind.pm => unread[v.id] ?? 0,
      ViewKind.group => unread[GroupLogic.groupStorageKey(v.id)] ?? 0,
    };

final sidebarNavOrderProvider =
    StateProvider<List<ChatView>>((ref) => const []);

class ComposerShortcutHooks {
  static FocusNode? focus;
}

InlineSpan keycapTooltip(BuildContext context, String label, String keys) {
  final c = context.nym;
  return TextSpan(
    text: label,
    children: [
      const TextSpan(text: '  '),
      TextSpan(
        text: keys,
        style: TextStyle(
          fontFamily: 'monospace',
          color: c.textDim,
          backgroundColor: c.glassBorder,
        ),
      ),
    ],
  );
}

const Map<String, IconData> kShortcutKeyIcons = {
  'up': Icons.arrow_upward,
  'down': Icons.arrow_downward,
  'left': Icons.arrow_back,
  'right': Icons.arrow_forward,
};

const Map<String, String> _kKeyNames = {
  'up': 'Up',
  'down': 'Down',
  'left': 'Left',
  'right': 'Right',
  'shift': 'Shift',
};

Widget _keyCapFace(String k, Color color) {
  final icon = kShortcutKeyIcons[k];
  if (icon != null) {
    return Icon(icon,
        key: ValueKey('keycap-$k'),
        size: 14,
        color: color,
        semanticLabel: _kKeyNames[k]);
  }
  if (k == 'shift') {
    return Semantics(
      key: const ValueKey('keycap-shift'),
      label: _kKeyNames[k],
      child: SizedBox(
        width: 12,
        height: 14,
        child: CustomPaint(painter: _ShiftKeyPainter(color)),
      ),
    );
  }
  return Text(k,
      style: TextStyle(color: color, fontSize: 12, fontFamily: 'monospace'));
}

class _ShiftKeyPainter extends CustomPainter {
  _ShiftKeyPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.12)
      ..lineTo(w * 0.95, h * 0.56)
      ..lineTo(w * 0.7, h * 0.56)
      ..lineTo(w * 0.7, h * 0.9)
      ..lineTo(w * 0.3, h * 0.9)
      ..lineTo(w * 0.3, h * 0.56)
      ..lineTo(w * 0.05, h * 0.56)
      ..close();
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_ShiftKeyPainter oldDelegate) =>
      oldDelegate.color != color;
}

Future<void> showShortcutSheet(BuildContext context) {
  final mac = shortcutsUseMac;
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final c = ctx.nym;
      return Dialog(
        key: const ValueKey('shortcutSheet'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('Keyboard shortcuts'),
                    style: TextStyle(
                        color: c.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                for (final r in kShortcutSheet)
                  Padding(
                    key: ValueKey('shortcut-${r.action}'),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(tr(r.label),
                              style: TextStyle(color: c.text, fontSize: 14)),
                        ),
                        for (final k in mac ? r.mac : r.other)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              border: Border.all(color: c.glassBorder),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: _keyCapFace(k, c.text),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
