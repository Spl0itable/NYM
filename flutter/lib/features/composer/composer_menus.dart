import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/anchored_popup.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'composer_model.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_tooltip.dart';

class ComposerIcons {
  const ComposerIcons._();

  static const String plus =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      '<line x1="12" y1="5" x2="12" y2="19"/>'
      '<line x1="5" y1="12" x2="19" y2="12"/></svg>';

  static const String paperPlane =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<line x1="22" y1="2" x2="11" y2="13"/>'
      '<polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>';

  static const String chevronUp =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="18 15 12 9 6 15"/></svg>';

  static const String location =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M12 21s7-6.2 7-12a7 7 0 0 0-14 0c0 5.8 7 12 7 12z"/>'
      '<circle cx="12" cy="9" r="2.5"/></svg>';

  static const String poll =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<line x1="6" y1="20" x2="6" y2="13"/>'
      '<line x1="12" y1="20" x2="12" y2="4"/>'
      '<line x1="18" y1="20" x2="18" y2="9"/></svg>';

  static const String event =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<rect x="3" y="4" width="18" height="18" rx="2" ry="2"/>'
      '<line x1="16" y1="2" x2="16" y2="6"/>'
      '<line x1="8" y1="2" x2="8" y2="6"/>'
      '<line x1="3" y1="10" x2="21" y2="10"/></svg>';

  static const String clock =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="9"/>'
      '<polyline points="12 7 12 12 15 14"/></svg>';

  static const String anon =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/>'
      '<circle cx="12" cy="12" r="3"/>'
      '<line x1="3" y1="21" x2="21" y2="3"/></svg>';

  static const Map<String, String> attach = {
    'photo': NymIcons.composerImage,
    'file': NymIcons.composerFile,
    'location': location,
    'videoNote': NymIcons.composerVideoNote,
    'poll': poll,
    'event': event,
  };

  static const Map<String, String> send = {'later': clock, 'anon': anon};
}

const Map<String, String> kAttachLabels = {
  'photo': 'Photo or video',
  'file': 'P2P file',
  'location': 'Location',
  'videoNote': 'Video note',
  'poll': 'Poll',
  'event': 'Event',
};

class ComposerMenuEntry {
  const ComposerMenuEntry({
    required this.id,
    required this.label,
    required this.svg,
    this.enabled = true,
    this.note = '',
    this.warn = false,
  });

  final String id;
  final String label;
  final String svg;
  final bool enabled;
  final String note;
  final bool warn;

  factory ComposerMenuEntry.attach(AttachItem it) => ComposerMenuEntry(
        id: it.id,
        label: tr(kAttachLabels[it.id] ?? it.id),
        svg: ComposerIcons.attach[it.id] ?? ComposerIcons.plus,
        enabled: it.enabled,
        note: it.note.isEmpty ? '' : tr(it.note),
        warn: it.enabled && it.warn.isNotEmpty,
      );

  factory ComposerMenuEntry.send(SendMenuItem it) => ComposerMenuEntry(
        id: it.id,
        label: tr(it.label),
        svg: ComposerIcons.send[it.id] ?? ComposerIcons.clock,
      );
}

Rect? globalRectOf(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

Future<String?> showComposerMenu(
  BuildContext context, {
  required String kind,
  required String label,
  required List<ComposerMenuEntry> entries,
  Rect? anchor,
}) {
  if (entries.isEmpty) return Future.value();
  final width = MediaQuery.sizeOf(context).width;
  final list = ComposerMenuList(kind: kind, label: label, entries: entries);
  if (menuPresentation(width) == 'sheet' || anchor == null) {
    return showNymBottomSheet<String>(
      context,
      (_) => Padding(
        key: ValueKey('$kind-menu-sheet'),
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: list,
      ),
      useRootNavigator: true,
      barrierColor: const Color(0x73000000),
    );
  }
  return Navigator.of(context, rootNavigator: true).push<String>(
    _ComposerPopoverRoute(
      anchor: anchor,
      align: kind == 'send' ? PopupAlign.end : PopupAlign.start,
      child: KeyedSubtree(key: ValueKey('$kind-menu-popover'), child: list),
    ),
  );
}

class _ComposerPopoverRoute extends PopupRoute<String> {
  _ComposerPopoverRoute({
    required this.anchor,
    required this.align,
    required this.child,
  });

  final Rect anchor;
  final PopupAlign align;
  final Widget child;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final c = context.nym;
    return CustomSingleChildLayout(
      delegate: AnchoredPopupLayout(
        anchor: anchor,
        insets: popupInsetsOf(context),
        align: align,
        gap: 8,
        margin: 8,
      ),
      child: FadeTransition(
        opacity: animation,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
          child: Material(
            color: c.bgSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: NymRadius.rmd,
              side: BorderSide(color: c.glassBorder),
            ),
            elevation: 12,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: IntrinsicWidth(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class ComposerMenuList extends StatefulWidget {
  const ComposerMenuList({
    super.key,
    required this.kind,
    required this.label,
    required this.entries,
  });

  final String kind;
  final String label;
  final List<ComposerMenuEntry> entries;

  @override
  State<ComposerMenuList> createState() => _ComposerMenuListState();
}

class _ComposerMenuListState extends State<ComposerMenuList> {
  late final List<FocusNode> _nodes = [
    for (final e in widget.entries) FocusNode(debugLabel: e.id),
  ];

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  int get _firstEnabled {
    final i = widget.entries.indexWhere((e) => e.enabled);
    return i < 0 ? 0 : i;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape ||
        e.logicalKey == LogicalKeyboardKey.tab) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final key = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowDown => 'ArrowDown',
      LogicalKeyboardKey.arrowUp => 'ArrowUp',
      LogicalKeyboardKey.home => 'Home',
      LogicalKeyboardKey.end => 'End',
      _ => '',
    };
    final index = _nodes.indexWhere((n) => n.hasFocus);
    final next = menuStep(_nodes.length, index, key);
    if (next < 0) return KeyEventResult.ignored;
    _nodes[next].requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final first = _firstEnabled;
    return Semantics(
      label: widget.label,
      explicitChildNodes: true,
      child: Focus(
        onKeyEvent: _onKey,
        skipTraversal: true,
        child: Column(
          key: ValueKey('${widget.kind}Menu'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.entries.length; i++)
              _ComposerMenuRow(
                key: ValueKey('${widget.kind}-item-${widget.entries[i].id}'),
                entry: widget.entries[i],
                focusNode: _nodes[i],
                autofocus: i == first,
              ),
          ],
        ),
      ),
    );
  }
}

class _ComposerMenuRow extends StatelessWidget {
  const _ComposerMenuRow({
    super.key,
    required this.entry,
    required this.focusNode,
    required this.autofocus,
  });

  final ComposerMenuEntry entry;
  final FocusNode focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final e = entry;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          NymSvgIcon(e.svg, size: 20, color: c.text),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.label, style: TextStyle(color: c.text, fontSize: 14)),
                if (e.note.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    e.note,
                    style: TextStyle(
                      color: e.warn ? c.warning : c.textDim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: e.enabled,
      child: Opacity(
        opacity: e.enabled ? 1 : 0.45,
        child: InkWell(
          focusNode: focusNode,
          autofocus: autofocus,
          borderRadius: NymRadius.rsm,
          hoverColor: e.enabled ? c.primaryA(0.12) : Colors.transparent,
          focusColor: c.primaryA(0.12),
          mouseCursor: e.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.forbidden,
          onTap: () => Navigator.of(context).pop(e.id),
          child: row,
        ),
      ),
    );
  }
}

class EmojiInputButton extends StatefulWidget {
  const EmojiInputButton({
    super.key,
    required this.enabled,
    required this.open,
    required this.onTap,
  });

  final bool enabled;
  final bool open;
  final VoidCallback onTap;

  @override
  State<EmojiInputButton> createState() => _EmojiInputButtonState();
}

class _EmojiInputButtonState extends State<EmojiInputButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final lit = widget.open || (_hover && widget.enabled);
    return Opacity(
      opacity: widget.enabled ? (lit ? 1.0 : 0.6) : 0.4,
      child: NymTooltip(
        message: tr('Emoji and GIFs'),
        child: Semantics(
          button: true,
          expanded: widget.open,
          child: MouseRegion(
            cursor: widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.enabled ? widget.onTap : null,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _hover && widget.enabled
                      ? (c.isLight
                          ? Colors.black.withValues(alpha: 0.06)
                          : Colors.white.withValues(alpha: 0.08))
                      : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: NymSvgIcon(NymIcons.composerEmoji,
                    size: 16, color: lit ? c.primary : c.textDim),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PickerTabs extends StatelessWidget {
  const PickerTabs({super.key, required this.active, required this.onSelect});

  static const List<(String, String)> tabs = [('emoji', 'Emoji'), ('gif', 'GIF')];

  final String active;
  final ValueChanged<String> onSelect;

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final i = tabs.indexWhere((t) => t.$1 == active);
    final n = tabs.length;
    final int j;
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      j = (i - 1 + n) % n;
    } else if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      j = (i + 1) % n;
    } else if (e.logicalKey == LogicalKeyboardKey.home) {
      j = 0;
    } else if (e.logicalKey == LogicalKeyboardKey.end) {
      j = n - 1;
    } else {
      return KeyEventResult.ignored;
    }
    onSelect(tabs[j].$1);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Focus(
      onKeyEvent: _onKey,
      skipTraversal: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Row(
          children: [
            for (final (id, label) in tabs)
              Expanded(
                child: Semantics(
                  selected: id == active,
                  button: true,
                  child: InkWell(
                    key: ValueKey('picker-tab-$id'),
                    onTap: () => onSelect(id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: id == active
                                ? c.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Text(
                        tr(label),
                        style: TextStyle(
                          color: id == active ? c.primary : c.textDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
