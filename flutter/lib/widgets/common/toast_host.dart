import 'dart:math' as math;


import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/i18n/i18n.dart';
import '../../features/identity/deleted_notice.dart';
import '../../features/search/unified_search_panel.dart' show nymSuffixStyle;
import '../../features/toasts/event_toast_area.dart';
import '../../features/toasts/event_toast_center.dart';
import '../../features/toasts/event_toasts.dart';
import '../../features/toasts/toast_center.dart';
import '../../features/toasts/toast_model.dart';
import 'event_toast_card.dart';

class ToastHost extends StatefulWidget {
  const ToastHost(
      {super.key, required this.child, this.center, this.eventCenter});

  final Widget child;
  final ToastCenter? center;
  final EventToastCenter? eventCenter;

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  late ToastCenter _center;
  late EventToastCenter _events;
  final Set<int> _announced = {};
  final Map<int, String> _eventSpoken = {};

  @override
  void initState() {
    super.initState();
    _center = widget.center ?? ToastCenter.instance;
    _center.addListener(_changed);
    _center.attach();
    _events = widget.eventCenter ?? EventToastCenter.instance;
    _events.addListener(_changed);
    _events.attach();
  }

  @override
  void didUpdateWidget(ToastHost old) {
    super.didUpdateWidget(old);
    final next = widget.center ?? ToastCenter.instance;
    if (!identical(next, _center)) {
      _center.removeListener(_changed);
      _center.detach();
      _center = next;
      _center.addListener(_changed);
      _center.attach();
    }
    final nextEvents = widget.eventCenter ?? EventToastCenter.instance;
    if (!identical(nextEvents, _events)) {
      _events.removeListener(_changed);
      _events.detach();
      _events = nextEvents;
      _events.addListener(_changed);
      _events.attach();
    }
  }

  @override
  void dispose() {
    _center.removeListener(_changed);
    _center.detach();
    _events.removeListener(_changed);
    _events.detach();
    super.dispose();
  }

  void _announceEvent(EventToast t) {
    final p = _events.textFor(t);
    final spoken = [p.title, p.meta, p.body].where((s) => s.isNotEmpty).join('. ');
    if (_eventSpoken[t.id] == spoken) return;
    _eventSpoken[t.id] = spoken;
    if (_eventSpoken.length > 32) _eventSpoken.remove(_eventSpoken.keys.first);
    final view = View.maybeOf(context);
    if (view == null) return;
    SemanticsService.sendAnnouncement(
      view,
      spoken,
      Directionality.maybeOf(context) ?? TextDirection.ltr,
      assertiveness: Assertiveness.polite,
    );
  }

  void _changed() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _announce(ToastItem t) {
    if (!_announced.add(t.id)) return;
    if (_announced.length > 32) _announced.remove(_announced.first);
    final view = View.maybeOf(context);
    if (view == null) return;
    SemanticsService.sendAnnouncement(
      view,
      t.text,
      Directionality.maybeOf(context) ?? TextDirection.ltr,
      assertiveness: t.kind == ToastKind.error
          ? Assertiveness.assertive
          : Assertiveness.polite,
    );
  }

  @override
  Widget build(BuildContext context) {
    final toasts = _center.visible;
    for (final t in toasts) {
      _announce(t);
    }
    final events = _events.visible;
    for (final t in events) {
      _announceEvent(t);
    }
    final pad = MediaQuery.paddingOf(context);
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (toasts.isNotEmpty || events.isNotEmpty)
          ValueListenableBuilder<Rect?>(
            valueListenable: eventToastRegion,
            builder: (context, region, _) => ValueListenableBuilder<Rect?>(
              valueListenable: eventToastComposer,
              builder: (context, composer, _) {
                final size = MediaQuery.sizeOf(context);
                final spot = EventToasts.place(
                  vw: size.width,
                  vh: size.height,
                  safeTop: pad.top,
                  safeLeft: pad.left,
                  safeRight: pad.right,
                  headerBottom: region?.top ?? 0,
                  chatLeft: region?.left ?? 0,
                  chatRight: region?.right ?? size.width,
                  composerTop: composer?.top ?? region?.bottom ?? size.height,
                );
                var top = spot.top.toDouble();
                var maxHeight = spot.maxHeight.toDouble();
                final dialog =
                    _events.observer.anyOpen ? _events.dialogRect() : null;
                if (_events.observer.anyOpen && dialog == null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _events.observer.anyOpen) setState(() {});
                  });
                }
                if (dialog != null) {
                  final above = dialog.top - pad.top - 16;
                  final below = size.height - dialog.bottom - 16;
                  if (above >= below) {
                    top = pad.top + 8;
                    maxHeight = math.max(0, dialog.top - 8 - top);
                  } else {
                    top = dialog.bottom + 8;
                    maxHeight = math.max(0, size.height - 8 - top);
                  }
                }
                return Positioned(
                  key: const ValueKey('toastHost'),
                  top: top,
                  left: spot.left.toDouble(),
                  width: spot.width.toDouble(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: ClipRect(
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final t in toasts)
                              Padding(
                                key: ValueKey('toast-${t.id}'),
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _ToastCard(item: t, center: _center),
                              ),
                            for (final t in events)
                              Padding(
                                key: ValueKey('eventToastSlot-${t.id}'),
                                padding: const EdgeInsets.only(bottom: 8),
                                child: EventToastCard(toast: t, center: _events),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({required this.item, required this.center});

  final ToastItem item;
  final ToastCenter center;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> {
  double _dx = 0;
  bool _hovered = false;
  bool _focused = false;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  void _hold(bool hovered, bool focused) {
    final wasHeld = _hovered || _focused;
    _hovered = hovered;
    _focused = focused;
    final held = _hovered || _focused;
    if (held == wasHeld) return;
    if (held) {
      widget.center.pause(widget.item.id);
    } else {
      widget.center.resume(widget.item.id);
    }
  }

  void _dismiss() => widget.center.dismiss(widget.item.id);

  @override
  Widget build(BuildContext context) {
    final t = widget.item;
    final c = Theme.of(context).extension<NymColors>();
    final scheme = Theme.of(context).colorScheme;
    final accent = switch (t.kind) {
      ToastKind.error => c?.danger ?? scheme.error,
      ToastKind.success => c?.primary ?? scheme.primary,
      ToastKind.info => c?.secondary ?? scheme.secondary,
    };
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

    final card = Container(
      key: ValueKey('toastCard-${t.kind.name}'),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
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
                  child: hasNymSuffix(t.text)
                      ? Text.rich(
                          dimNymSuffixes(
                            t.text,
                            nymSuffixStyle(TextStyle(
                                color: fg, fontSize: 13, height: 1.4)),
                          ),
                          style:
                              TextStyle(color: fg, fontSize: 13, height: 1.4),
                        )
                      : Text(
                          t.text,
                          style:
                              TextStyle(color: fg, fontSize: 13, height: 1.4),
                        ),
                ),
              ),
              if (t.action != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 2),
                  child: Center(
                    child: Semantics(
                      button: true,
                      label: t.action,
                      excludeSemantics: true,
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          key: ValueKey('toastAction-${t.id}'),
                          onTap: () => widget.center.runAction(t.id),
                          onFocusChange: (f) => _hold(_hovered, f),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: c?.primary ?? accent),
                            ),
                            child: Text(
                              t.action!,
                              style: TextStyle(
                                color: c?.primary ?? accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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
                      key: ValueKey('toastClose-${t.id}'),
                      onTap: _dismiss,
                      onFocusChange: (f) => _hold(_hovered, f),
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

    return Semantics(
      container: true,
      liveRegion: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _hold(true, _focused),
        onExit: (_) => _hold(false, _focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
          onHorizontalDragCancel: () => setState(() => _dx = 0),
          onHorizontalDragEnd: (_) {
            if (_dx.abs() >= ToastConfig.swipeDismissPx) {
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
    );
  }
}
