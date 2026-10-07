import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/i18n/i18n.dart';
import '../../features/search/unified_search_panel.dart' show nymSuffixStyle;
import '../../features/toasts/event_toast_center.dart';
import '../../features/toasts/event_toasts.dart';

final RegExp _suffixRe = RegExp(r'^(.*\S)(#[0-9a-f]{4})$', caseSensitive: false);

TextSpan _titleSpan(String title, String sender, TextStyle style) {
  final m = _suffixRe.firstMatch(sender);
  final at = m == null ? -1 : title.lastIndexOf(sender);
  if (m == null || at < 0) return TextSpan(text: title, style: style);
  final cut = at + m.group(1)!.length;
  final suffix = m.group(2)!;
  return TextSpan(style: style, children: [
    TextSpan(text: title.substring(0, cut)),
    TextSpan(text: suffix, style: nymSuffixStyle(style)),
    if (cut + suffix.length < title.length)
      TextSpan(text: title.substring(cut + suffix.length)),
  ]);
}

class EventToastCard extends StatefulWidget {
  const EventToastCard({super.key, required this.toast, required this.center});

  final EventToast toast;
  final EventToastCenter center;

  @override
  State<EventToastCard> createState() => _EventToastCardState();
}

class _EventToastCardState extends State<EventToastCard> {
  double _dx = 0;
  bool _hovered = false;
  bool _focused = false;
  bool _shown = false;
  late final FocusNode _focus = FocusNode(debugLabel: 'eventToast');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _hold(bool hovered, bool focused) {
    final wasHeld = _hovered || _focused;
    _hovered = hovered;
    _focused = focused;
    final held = _hovered || _focused;
    if (held == wasHeld) return;
    if (held) {
      widget.center.pause(widget.toast.id);
    } else {
      widget.center.resume(widget.toast.id);
    }
  }

  void _dismiss() => widget.center.dismiss(widget.toast.id);
  void _open() => widget.center.open(widget.toast.id);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter ||
        e.logicalKey == LogicalKeyboardKey.space) {
      _open();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.toast;
    final text = widget.center.textFor(t);
    final c = Theme.of(context).extension<NymColors>();
    final scheme = Theme.of(context).colorScheme;
    final accent = t.isSummary
        ? (c?.secondary ?? scheme.secondary)
        : t.locked
            ? (c?.textDim ?? scheme.onSurfaceVariant)
            : (c?.primary ?? scheme.primary);
    final bg = c == null
        ? scheme.surfaceContainerHighest
        : Color.alphaBlend(c.bgTertiary, c.bg);
    final fg = c?.text ?? scheme.onSurface;
    final dim = c?.textDim ?? scheme.onSurfaceVariant;
    final border = c?.border ?? scheme.outlineVariant;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final motion = still ? Duration.zero : const Duration(milliseconds: 200);
    final dragging = _dx != 0;
    final label = tr('Dismiss');

    final lines = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          _titleSpan(text.title,
              t.locked ? '' : (t.last?.sender ?? ''),
              TextStyle(
                  color: fg,
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w700)),
          key: ValueKey('eventToastTitle-${t.id}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (text.meta.isNotEmpty)
          Text(
            text.meta,
            key: ValueKey('eventToastMeta-${t.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: dim, fontSize: 11, height: 1.4),
          ),
        if (text.body.isNotEmpty)
          Text(
            text.body,
            key: ValueKey('eventToastBody-${t.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg, fontSize: 13, height: 1.4),
          ),
      ],
    );

    final card = Container(
      key: ValueKey('eventToastCard-${t.kind}'),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: _focused ? (c?.primary ?? scheme.primary) : border,
            width: _focused ? 2 : 1),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(11, 10, 4, 10),
                  child: ExcludeSemantics(child: lines),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Semantics(
                    button: true,
                    label: label,
                    excludeSemantics: true,
                    child: InkResponse(
                      key: ValueKey('eventToastClose-${t.id}'),
                      onTap: _dismiss,
                      radius: 14,
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: Icon(Icons.close, size: 14, color: dim),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final spoken = [text.title, text.meta, text.body]
        .where((s) => s.isNotEmpty)
        .join('. ');

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _hold(_hovered, f)),
      child: Semantics(
        key: ValueKey('eventToast-${t.id}'),
        container: true,
        button: true,
        focusable: true,
        label: spoken,
        onTap: _open,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _hold(true, _focused),
          onExit: (_) => _hold(false, _focused),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
            onHorizontalDragCancel: () => setState(() => _dx = 0),
            onHorizontalDragEnd: (_) {
              if (_dx.abs() >= EventToastConfig.swipeDismissPx) {
                _dismiss();
              } else {
                setState(() => _dx = 0);
              }
            },
            child: AnimatedOpacity(
              opacity: _shown
                  ? (1 - _dx.abs() / 200).clamp(0.2, 1.0).toDouble()
                  : 0,
              duration: dragging ? Duration.zero : motion,
              child: AnimatedSlide(
                offset: _shown ? Offset.zero : const Offset(0, -0.15),
                duration: motion,
                child: Transform.translate(
                  offset: Offset(_dx, 0),
                  child: Material(
                    type: MaterialType.transparency,
                    child: card,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
