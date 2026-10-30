import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/common/nym_label.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart';
import '../../widgets/anchored_popup.dart';

class ReactorEntry {
  const ReactorEntry({
    required this.pubkey,
    required this.nym,
    this.suffix = '',
    this.isYou = false,
    this.imageUrl,
    this.subtitle,
  });

  final String pubkey;

  /// Base nym without the `#suffix`.
  final String nym;

  /// 4-hex pubkey suffix shown dimmed after the nym.
  final String suffix;

  final bool isYou;

  /// Profile picture; identicon fallback when null.
  final String? imageUrl;

  /// Optional secondary line, e.g. a poll voter's chosen option.
  final String? subtitle;
}

/// Reactor-list popup anchored above a badge, capped at 50 rows with a "+N more" line.
class ReactorsModal extends ConsumerWidget {
  const ReactorsModal({
    super.key,
    required this.emoji,
    required this.reactors,
    this.onTapReactor,
    this.title,
  });

  static const int maxRows = 50;

  final String emoji;
  final List<ReactorEntry> reactors;
  final void Function(ReactorEntry)? onTapReactor;

  /// Optional header title replacing the emoji and count header (e.g. "Seen by").
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final shown = reactors.take(maxRows).toList();
    final overflow = reactors.length - shown.length;
    // Watch users so avatars that arrive after opening fill in; [ReactorEntry.imageUrl] is the fallback.
    final users = ref.watch(usersProvider);

    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(
          minWidth: 160,
          maxWidth: 240,
          maxHeight: 260,
        ),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
          boxShadow: c.isLight
              ? const [
                  BoxShadow(
                      color: Color(0x1F000000),
                      offset: Offset(0, 8),
                      blurRadius: 32),
                ]
              : [
                  const BoxShadow(
                      color: Color(0x80000000),
                      offset: Offset(0, 8),
                      blurRadius: 32),
                  BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                  const BoxShadow(color: Color(0x0DFFFFFF), spreadRadius: 1),
                ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.glassBorder)),
              ),
              child: title != null
                  ? Text(
                      title!,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.text,
                      ),
                    )
                  : Row(
                      children: [
                        // Only an exact `:shortcode:` reaction renders as a custom emoji image; unicode stays text.
                        InlineEmojiText(
                          text: emoji,
                          style: const TextStyle(fontSize: 40, height: 1),
                          wholeStringOnly: true,
                          emojiSize: 40 * 1.45,
                          emojiMargin: EdgeInsets.zero,
                          emojiAlignment: PlaceholderAlignment.middle,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${reactors.length}',
                          style: TextStyle(fontSize: 12, color: c.textDim),
                        ),
                      ],
                    ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                children: [
                  for (final r in shown)
                    _row(context, r,
                        users[r.pubkey]?.profile?.picture ?? r.imageUrl),
                  if (overflow > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Text(
                        tr('+{n} more', {'n': overflow}),
                        style: TextStyle(
                          fontSize: 12,
                          color: c.textDim,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ReactorEntry r, String? imageUrl) {
    final c = context.nym;
    return InkWell(
      onTap: onTapReactor == null ? null : () => onTapReactor!(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            NymAvatar(seed: r.pubkey, size: 22, imageUrl: imageUrl),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  NymLabel(
                    r.nym,
                    suffix: r.suffix,
                    style: TextStyle(fontSize: 13, color: c.text),
                  ),
                  if (r.subtitle != null && r.subtitle!.isNotEmpty)
                    Text(
                      r.subtitle!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.textDim),
                    ),
                ],
              ),
            ),
            if (r.isYou) ...[
              const SizedBox(width: 6),
              Text(
                tr('you'),
                style: TextStyle(
                  fontSize: 10,
                  color: c.primary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows the popup just above [anchorRect], clamped to the viewport and dismissed on outside tap.
ReactorsModalHandle showReactorsModal(
  BuildContext context, {
  required Rect anchorRect,
  required String emoji,
  required List<ReactorEntry> reactors,
  void Function(ReactorEntry)? onTapReactor,
  String? title,
  ValueChanged<bool>? onPointerInside,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final hover = ValueNotifier<bool>(false);
  late OverlayEntry entry;

  void close() {
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: hover,
            builder: (_, hovered, _) => hovered
                ? Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) {
                      if (!anchorRect.contains(e.position)) close();
                    },
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: close,
                  ),
          ),
        ),
        AnchoredPopup(
          anchor: anchorRect,
          child: MouseRegion(
            onEnter: (_) => onPointerInside?.call(true),
            onExit: (_) => onPointerInside?.call(false),
            child: ReactorsModal(
              emoji: emoji,
              reactors: reactors,
              title: title,
              onTapReactor: onTapReactor == null
                  ? null
                  : (r) {
                      close();
                      onTapReactor(r);
                    },
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
  return ReactorsModalHandle._(close, () => entry.mounted, hover);
}

class ReactorsModalHandle {
  ReactorsModalHandle._(this._close, this._mounted, this._hover);

  final VoidCallback _close;
  final bool Function() _mounted;
  final ValueNotifier<bool> _hover;

  bool get hover => _hover.value;
  set hover(bool value) => _hover.value = value;

  bool get isOpen => _mounted();

  void close() => _close();
}

class HoverOpenRegion extends StatefulWidget {
  const HoverOpenRegion({super.key, required this.open, required this.child});

  static const Duration delay = Duration(milliseconds: 400);
  static const Duration grace = Duration(milliseconds: 300);

  final ReactorsModalHandle? Function(ValueChanged<bool> onPointerInside) open;
  final Widget child;

  @override
  State<HoverOpenRegion> createState() => HoverOpenRegionState();
}

class HoverOpenRegionState extends State<HoverOpenRegion> {
  Timer? _openTimer;
  Timer? _closeTimer;
  ReactorsModalHandle? _handle;
  bool _overAnchor = false;
  bool _overModal = false;

  static bool _pointer(PointerEvent e) =>
      e.kind == PointerDeviceKind.mouse || e.kind == PointerDeviceKind.trackpad;

  bool get _hoverOpen => (_handle?.isOpen ?? false) && _handle!.hover;

  bool pinIfOpen() {
    if (!_hoverOpen) return false;
    _handle!.hover = false;
    _closeTimer?.cancel();
    return true;
  }

  void closeHover() {
    _openTimer?.cancel();
    if (_hoverOpen) _handle!.close();
  }

  void _enter(PointerEnterEvent e) {
    if (!_pointer(e)) return;
    _overAnchor = true;
    _closeTimer?.cancel();
    if (_handle?.isOpen ?? false) return;
    _openTimer?.cancel();
    _openTimer = Timer(HoverOpenRegion.delay, _fire);
  }

  void _exit(PointerExitEvent e) {
    if (!_pointer(e)) return;
    _overAnchor = false;
    _openTimer?.cancel();
    _scheduleClose();
  }

  void _fire() {
    if (!mounted || !_overAnchor) return;
    _overModal = false;
    final h = widget.open(_onModal);
    if (h == null) return;
    h.hover = true;
    _handle = h;
  }

  void _onModal(bool inside) {
    _overModal = inside;
    if (inside) {
      _closeTimer?.cancel();
    } else {
      _scheduleClose();
    }
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    if (!_hoverOpen) return;
    _closeTimer = Timer(HoverOpenRegion.grace, () {
      if (_overAnchor || _overModal || !_hoverOpen) return;
      _handle!.close();
      _handle = null;
    });
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (_hoverOpen) _handle!.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      MouseRegion(onEnter: _enter, onExit: _exit, child: widget.child);
}
