import 'package:flutter/widgets.dart';

final ValueNotifier<Rect?> eventToastRegion = ValueNotifier<Rect?>(null);
final ValueNotifier<Rect?> eventToastComposer = ValueNotifier<Rect?>(null);

class EventToastAreaReporter extends StatefulWidget {
  const EventToastAreaReporter(
      {super.key, required this.target, required this.child});

  final ValueNotifier<Rect?> target;
  final Widget child;

  @override
  State<EventToastAreaReporter> createState() => _EventToastAreaReporterState();
}

class _EventToastAreaReporterState extends State<EventToastAreaReporter> {
  Rect? _last;
  bool _scheduled = false;

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      _last = rect;
      if (widget.target.value != rect) widget.target.value = rect;
    });
  }

  @override
  void dispose() {
    final target = widget.target;
    final mine = _last;
    if (mine != null && target.value == mine) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (target.value == mine) target.value = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _schedule();
      return widget.child;
    });
  }
}
