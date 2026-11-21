import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:visibility_detector/visibility_detector.dart';

class ChatCover {
  ChatCover._();

  static final Set<Object> _holders = <Object>{};
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  static bool get covered => _holders.isNotEmpty;

  static Listenable get changes => _changes;

  static void hold(Object holder) {
    if (_holders.add(holder)) _changes.value++;
  }

  static void release(Object holder) {
    if (_holders.remove(holder)) _changes.value++;
  }
}

class ChatCoverScope extends InheritedWidget {
  const ChatCoverScope(
      {super.key, required this.covered, required super.child});

  final bool covered;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatCoverScope>()?.covered ??
      false;

  @override
  bool updateShouldNotify(ChatCoverScope oldWidget) =>
      oldWidget.covered != covered;
}

class ChatCoverGate extends StatefulWidget {
  const ChatCoverGate({
    super.key,
    required this.listCovers,
    required this.listOpaque,
    required this.settle,
    required this.child,
  });

  final bool listCovers;
  final bool listOpaque;
  final Duration settle;
  final Widget child;

  @override
  State<ChatCoverGate> createState() => _ChatCoverGateState();
}

class _ChatCoverGateState extends State<ChatCoverGate> {
  late bool _rest = widget.listCovers;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    ChatCover.changes.addListener(_onCover);
  }

  @override
  void didUpdateWidget(ChatCoverGate old) {
    super.didUpdateWidget(old);
    if (widget.listCovers == old.listCovers) return;
    _settle?.cancel();
    _settle = null;
    if (_rest) {
      _rest = false;
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => VisibilityDetectorController.instance.notifyNow());
    }
    if (!widget.listCovers) return;
    if (widget.settle == Duration.zero) {
      _rest = true;
      return;
    }
    _settle = Timer(widget.settle, () {
      _settle = null;
      if (mounted && widget.listCovers) setState(() => _rest = true);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    ChatCover.changes.removeListener(_onCover);
    super.dispose();
  }

  void _onCover() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final covered = _rest || ChatCover.covered;
    return ChatCoverScope(
      covered: covered && TickerMode.valuesOf(context).enabled,
      child: TickerMode(
        enabled: !covered,
        child: _PaintGate(
            paints: !_rest || !widget.listOpaque, child: widget.child),
      ),
    );
  }
}

class _PaintGate extends SingleChildRenderObjectWidget {
  const _PaintGate({required this.paints, super.child});

  final bool paints;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintGate(paints);

  @override
  void updateRenderObject(BuildContext context, _RenderPaintGate renderObject) {
    renderObject.paints = paints;
  }
}

class _RenderPaintGate extends RenderProxyBox {
  _RenderPaintGate(this._paints);

  bool _paints;

  set paints(bool value) {
    if (value == _paints) return;
    _paints = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_paints) super.paint(context, offset);
  }
}
