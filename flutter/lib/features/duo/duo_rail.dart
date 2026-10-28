import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';

const double kDuoRailMinWidth = 56;
const double kDuoRailItemHeight = 48;
const double kDuoOuterStripBottom = 157;
const double kDuoInnerClusterBottom = 112;
const double kDuoLiveActivityGrowth = 35;
const double kDuoStatusBelowRegion = 87;
const double kDuoRailGap = 8;
const double kDuoAsymmetry = 40;
const int kDuoSheetFallbackPriority = 2;
const int kDuoSheetPriority = 3;

List<Rect> duoRegionsFromInsets(
    Size size, EdgeInsets viewPadding, TargetPlatform platform) {
  if (platform != TargetPlatform.iOS || size.isEmpty) return const [];
  if (viewPadding.right - viewPadding.left < kDuoAsymmetry) return const [];
  final bottom = math.min(size.height,
      _duoBareBottom(size) + kDuoLiveActivityGrowth);
  return [Rect.fromLTRB(size.width - viewPadding.right, 0, size.width, bottom)];
}

double _duoBareBottom(Size size) =>
    size.width < 600 ? kDuoOuterStripBottom : kDuoInnerClusterBottom;

final ValueNotifier<List<Rect>?> duoReportedRegions = ValueNotifier(null);

const MethodChannel _duoRegionsChannel =
    MethodChannel('app.nymchat/duo_regions');

List<Rect>? duoParseRegions(Object? raw) {
  if (raw is! List) return null;
  return [
    for (final e in raw)
      if (e is List &&
          e.length == 4 &&
          e.every((v) => v is num && v.isFinite) &&
          (e[2] as num) > 0 &&
          (e[3] as num) > 0)
        Rect.fromLTWH((e[0] as num).toDouble(), (e[1] as num).toDouble(),
            (e[2] as num).toDouble(), (e[3] as num).toDouble()),
  ];
}

void duoListenToBridge() {
  if (defaultTargetPlatform != TargetPlatform.iOS) return;
  _duoRegionsChannel.setMethodCallHandler((call) async {
    if (call.method == 'regions') {
      duoReportedRegions.value = duoParseRegions(call.arguments);
    }
  });
  _duoRegionsChannel.invokeMethod<Object?>('current').then((raw) {
    final rects = duoParseRegions(raw);
    if (rects != null) duoReportedRegions.value = rects;
  }, onError: (Object _) {});
}

List<Rect> duoMergeReported(
    List<Rect> fallback, List<Rect>? reported, Size size) {
  if (reported == null || reported.isEmpty) return fallback;
  final bare = _duoBareBottom(size);
  return [
    for (final f in fallback)
      _duoReportedOver(f, reported, bare, size.height) ?? f,
  ];
}

Rect? _duoReportedOver(
    Rect fallback, List<Rect> reported, double bare, double height) {
  double? bottom;
  for (final r in reported) {
    if (r.right > fallback.left &&
        r.left < fallback.right &&
        r.top < fallback.bottom) {
      bottom = math.max(bottom ?? 0, r.bottom);
    }
  }
  if (bottom == null) return null;
  final reach = bottom >= bare
      ? bottom
      : math.max(bare, bottom + kDuoStatusBelowRegion);
  return Rect.fromLTRB(
      fallback.left, fallback.top, fallback.right, math.min(height, reach));
}

Rect? duoOuterStrip(List<Rect> rects, Size size) {
  if (size.width >= 600 || size.height <= size.width) return null;
  for (final r in rects) {
    if (r.left > size.width * 0.6 && r.top < 80 && r.height > r.width) {
      return r;
    }
  }
  return null;
}

double duoClearance(Rect box, List<Rect> rects) {
  var need = 0.0;
  for (final o in rects) {
    if (o.top < box.bottom &&
        o.bottom > box.top &&
        o.left < box.right &&
        o.right > box.left) {
      need = math.max(need, box.right - o.left);
    }
  }
  return need;
}

class DuoClear extends StatefulWidget {
  const DuoClear({super.key, required this.child});

  final Widget child;

  @override
  State<DuoClear> createState() => _DuoClearState();
}

class _DuoClearState extends State<DuoClear> {
  double _pad = 0;
  bool _armed = false;

  void _arm() {
    if (_armed) return;
    _armed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _armed = false;
      _measure();
    });
  }

  void _measure() {
    if (!mounted) return;
    final rects =
        context.getInheritedWidgetOfExactType<DuoScope>()?.rects ?? const [];
    if (rects.isEmpty) {
      if (_pad != 0) setState(() => _pad = 0);
      return;
    }
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      final need =
          duoClearance(box.localToGlobal(Offset.zero) & box.size, rects);
      if ((need - _pad).abs() > 0.5) setState(() => _pad = need);
    }
    _arm();
  }

  @override
  Widget build(BuildContext context) {
    final rects = DuoScope.maybeOf(context)?.rects ?? const <Rect>[];
    MediaQuery.sizeOf(context);
    if (rects.isEmpty) {
      _pad = 0;
    } else {
      _arm();
    }
    return Padding(
      padding: EdgeInsets.only(right: _pad),
      child: widget.child,
    );
  }
}

@immutable
class DuoRailItem {
  const DuoRailItem({
    required this.id,
    required this.label,
    this.svg,
    this.icon,
    this.onTap,
    this.badge = 0,
    this.toggled,
    this.semanticsLabel,
  });

  final String id;
  final String label;
  final String? svg;
  final IconData? icon;
  final VoidCallback? onTap;
  final int badge;
  final bool? toggled;
  final String? semanticsLabel;
}

class _DuoEntry {
  _DuoEntry(this.items, this.active, this.priority, this.order, this.seq);

  final List<DuoRailItem> items;
  final bool active;
  final int priority;
  final int order;
  final int seq;
}

class DuoRailController extends ChangeNotifier {
  final Map<Object, _DuoEntry> _entries = {};
  int _seq = 0;
  bool _pending = false;
  bool _disposed = false;

  void put(Object owner, List<DuoRailItem> items,
      {bool active = true, int priority = 0, int order = 0}) {
    final prev = _entries[owner];
    _entries[owner] =
        _DuoEntry(items, active, priority, order, prev?.seq ?? _seq++);
    _schedule();
  }

  void remove(Object owner) {
    if (_entries.remove(owner) != null) _schedule();
  }

  List<DuoRailItem> get items {
    final live = [
      for (final e in _entries.entries)
        if (e.value.active) e
    ];
    if (live.isEmpty) return const [];
    final top = live.map((e) => e.value.priority).reduce(math.max);
    final pick = [
      for (final e in live)
        if (e.value.priority == top) e
    ]..sort((a, b) => a.value.order != b.value.order
        ? a.value.order - b.value.order
        : a.value.seq - b.value.seq);
    return [
      for (final e in pick)
        for (final item in e.value.items) _live(e.key, item)
    ];
  }

  DuoRailItem _live(Object owner, DuoRailItem item) {
    final tap = item.onTap;
    return DuoRailItem(
      id: item.id,
      label: item.label,
      svg: item.svg,
      icon: item.icon,
      badge: item.badge,
      toggled: item.toggled,
      semanticsLabel: item.semanticsLabel,
      onTap: tap == null
          ? null
          : () {
              if (_entries.containsKey(owner)) tap();
            },
    );
  }

  void _schedule() {
    if (_pending || _disposed) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class DuoScope extends InheritedWidget {
  const DuoScope({
    super.key,
    required this.rects,
    required this.strip,
    required this.controller,
    required super.child,
  });

  final List<Rect> rects;
  final Rect? strip;
  final DuoRailController controller;

  static DuoScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DuoScope>();

  static bool railOf(BuildContext context) => maybeOf(context)?.strip != null;

  @override
  bool updateShouldNotify(DuoScope oldWidget) =>
      oldWidget.strip != strip ||
      oldWidget.controller != controller ||
      !listEquals(oldWidget.rects, rects);
}

class DuoRailFrame extends StatefulWidget {
  const DuoRailFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DuoRailFrame> createState() => _DuoRailFrameState();
}

double duoRailWidth(Size size, Rect strip) =>
    math.max(kDuoRailMinWidth, size.width - strip.left);

class _DuoRailFrameState extends State<DuoRailFrame> {
  final DuoRailController _controller = DuoRailController();
  final FocusNode _railHost = FocusNode(
      debugLabel: 'duo-rail', skipTraversal: true, canRequestFocus: false);
  late final OverlayEntry _entry =
      OverlayEntry(builder: (context) => _DuoRailColumn(host: _railHost));
  late final Map<Type, Action<Intent>> _tabActions = {
    NextFocusIntent: _DuoNextFocus(this),
    PreviousFocusIntent: _DuoPreviousFocus(this),
  };
  FocusScopeNode? _content;

  @override
  void initState() {
    super.initState();
    duoReportedRegions.addListener(_reported);
    duoListenToBridge();
  }

  void _reported() {
    if (mounted) setState(() {});
  }

  bool? _tab(bool forward) {
    final node = primaryFocus;
    if (node == null || node.context == null) return null;
    final rail = [
      for (final n in _railHost.traversalDescendants)
        if (n is! FocusScopeNode && n.context != null) n
    ]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    if (rail.isEmpty) return null;
    if (node.ancestors.contains(_railHost)) {
      final next = rail.indexOf(node) + (forward ? 1 : -1);
      if (next >= 0 && next < rail.length) {
        FocusTraversalPolicy.defaultTraversalRequestFocusCallback(rail[next]);
        return true;
      }
      final scope = _content;
      if (scope == null || scope.context == null || !scope.canRequestFocus) {
        return null;
      }
      final policy = FocusTraversalGroup.maybeOfNode(scope);
      final target = forward
          ? policy?.findFirstFocus(scope, ignoreCurrentFocus: true)
          : policy?.findLastFocus(scope, ignoreCurrentFocus: true);
      if (target == null || target == scope) return null;
      FocusTraversalPolicy.defaultTraversalRequestFocusCallback(target);
      return true;
    }
    final policy = FocusTraversalGroup.maybeOfNode(node);
    final edge = forward
        ? policy?.findLastFocus(node, ignoreCurrentFocus: true)
        : policy?.findFirstFocus(node, ignoreCurrentFocus: true);
    if (edge != node || node.nearestScope == null) return null;
    _content = node.nearestScope;
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
        forward ? rail.first : rail.last);
    return true;
  }

  @override
  void dispose() {
    duoReportedRegions.removeListener(_reported);
    _controller.dispose();
    _railHost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final rects = duoMergeReported(
        duoRegionsFromInsets(
            media.size, media.viewPadding, defaultTargetPlatform),
        duoReportedRegions.value,
        media.size);
    final strip = duoOuterStrip(rects, media.size);
    final column = strip == null ? 0.0 : duoRailWidth(media.size, strip);
    final inner = strip == null
        ? media
        : media
            .copyWith(size: Size(media.size.width - column, media.size.height))
            .removePadding(removeRight: true)
            .removeViewPadding(removeRight: true);
    return DuoScope(
      rects: rects,
      strip: strip,
      controller: _controller,
      child: Actions(
        actions: strip == null ? const {} : _tabActions,
        child: Stack(
          textDirection: TextDirection.ltr,
          children: [
            Row(
              textDirection: TextDirection.ltr,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: MediaQuery(data: inner, child: widget.child)),
                SizedBox(key: const ValueKey('duo-rail-column'), width: column),
              ],
            ),
            Positioned.fill(child: Overlay(initialEntries: [_entry])),
          ],
        ),
      ),
    );
  }
}

class _DuoNextFocus extends NextFocusAction {
  _DuoNextFocus(this.frame);

  final _DuoRailFrameState frame;

  @override
  bool invoke(NextFocusIntent intent) =>
      frame._tab(true) ?? super.invoke(intent);
}

class _DuoPreviousFocus extends PreviousFocusAction {
  _DuoPreviousFocus(this.frame);

  final _DuoRailFrameState frame;

  @override
  bool invoke(PreviousFocusIntent intent) =>
      frame._tab(false) ?? super.invoke(intent);
}

class _DuoRailColumn extends StatelessWidget {
  const _DuoRailColumn({required this.host});

  final FocusNode host;

  @override
  Widget build(BuildContext context) {
    final scope = DuoScope.maybeOf(context);
    final strip = scope?.strip;
    if (scope == null || strip == null) return const SizedBox.shrink();
    final c = context.nym;
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: duoRailWidth(MediaQuery.sizeOf(context), strip),
        height: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border(left: BorderSide(color: c.glassBorder)),
          ),
          child: Padding(
            padding: EdgeInsets.only(top: strip.bottom + kDuoRailGap),
            child: Focus(
              focusNode: host,
              includeSemantics: false,
              child: ListenableBuilder(
                listenable: scope.controller,
                builder: (context, _) =>
                    DuoRail(items: scope.controller.items),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DuoRail extends StatelessWidget {
  const DuoRail({super.key, required this.items});

  final List<DuoRailItem> items;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Material(
      type: MaterialType.transparency,
      child: FocusTraversalGroup(
        child: ListView(
          key: const ValueKey('duo-rail'),
          padding: EdgeInsets.only(
              bottom:
                  8 + math.max(media.viewInsets.bottom, media.padding.bottom)),
          children: [
            for (final item in items)
              Center(child: DuoRailButton(key: ValueKey('duo-rail-${item.id}'), item: item)),
          ],
        ),
      ),
    );
  }
}

class DuoRailButton extends StatelessWidget {
  const DuoRailButton({super.key, required this.item});

  final DuoRailItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final on = item.toggled ?? false;
    final enabled = item.onTap != null;
    final fg = !enabled
        ? c.textDim.withValues(alpha: 0.4)
        : (on ? c.primary : c.textDim);
    final glyph = item.svg != null
        ? NymSvgIcon(item.svg!, size: 18, color: fg)
        : Icon(item.icon, size: 20, color: fg);
    final count = item.badge > 99 ? '99+' : '${item.badge}';
    return Tooltip(
      message: item.label,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        toggled: item.toggled,
        label: item.semanticsLabel ?? item.label,
        value: item.badge > 0 ? count : null,
        excludeSemantics: true,
        onTap: item.onTap,
        child: InkWell(
          onTap: item.onTap,
          borderRadius: NymRadius.rsm,
          child: Container(
            width: kDuoRailItemHeight,
            height: kDuoRailItemHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? c.primary.withValues(alpha: 0.12) : null,
              borderRadius: NymRadius.rsm,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                glyph,
                if (item.badge > 0)
                  Positioned(
                    right: -10,
                    top: -7,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      height: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.danger,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(count,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DuoRailItems extends StatefulWidget {
  const DuoRailItems({
    super.key,
    required this.items,
    required this.child,
    this.active = true,
    this.priority = 0,
    this.order = 0,
  });

  final List<DuoRailItem> items;
  final bool active;
  final int priority;
  final int order;
  final Widget child;

  @override
  State<DuoRailItems> createState() => _DuoRailItemsState();
}

class _DuoRailItemsState extends State<DuoRailItems> {
  DuoRailController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = DuoScope.maybeOf(context)?.controller;
    if (next != _controller) {
      _controller?.remove(this);
      _controller = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    _controller?.put(this, widget.items,
        active: widget.active && current,
        priority: widget.priority,
        order: widget.order);
    return widget.child;
  }

  @override
  void dispose() {
    _controller?.remove(this);
    super.dispose();
  }
}

DuoRailItem duoCloseItem(VoidCallback? onTap) => DuoRailItem(
    id: 'sheet-close', label: tr('Close'), icon: Icons.close, onTap: onTap);

DuoRailItem duoBackItem(VoidCallback? onTap) => DuoRailItem(
    id: 'sheet-back', label: tr('Back'), icon: Icons.arrow_back, onTap: onTap);

class DuoRailSwap extends StatelessWidget {
  const DuoRailSwap({
    super.key,
    required this.items,
    required this.child,
    this.order = 0,
  });

  DuoRailSwap.close({
    super.key,
    required VoidCallback? onTap,
    required this.child,
    this.order = 0,
  }) : items = [duoCloseItem(onTap)];

  final List<DuoRailItem> items;
  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DuoScope.railOf(context)) return child;
    return DuoRailItems(
      priority: kDuoSheetPriority,
      order: order,
      items: items,
      child: const SizedBox.shrink(),
    );
  }
}
