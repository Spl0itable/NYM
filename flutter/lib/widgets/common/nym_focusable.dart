import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/shortcuts/shortcuts.dart';
import 'nym_tooltip.dart';

class NymFocusable extends StatefulWidget {
  const NymFocusable({
    super.key,
    required this.onActivate,
    required this.child,
    this.label,
    this.tooltip,
    this.tooltipKeys,
    this.radius = NymRadius.rxs,
    this.onFocusChange,
    this.button = true,
    this.excludeChildSemantics = false,
  });

  final VoidCallback? onActivate;
  final Widget child;
  final String? label;
  final String? tooltip;
  final String? tooltipKeys;
  final BorderRadius radius;
  final ValueChanged<bool>? onFocusChange;
  final bool button;
  final bool excludeChildSemantics;

  static const double ringWidth = 2;

  static bool isActivateKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.space;

  @override
  State<NymFocusable> createState() => _NymFocusableState();
}

class _NymFocusableState extends State<NymFocusable> {
  late final FocusNode _node;
  late final FocusAttachment _attachment;
  bool _focused = false;
  bool _ring = false;

  bool get _enabled => widget.onActivate != null;

  @override
  void initState() {
    super.initState();
    _node = FocusNode(
      debugLabel: 'NymFocusable',
      canRequestFocus: _enabled,
      skipTraversal: !_enabled,
    );
    _attachment = _node.attach(context, onKeyEvent: _onKey);
    _node.addListener(_onNode);
  }

  @override
  void didUpdateWidget(NymFocusable old) {
    super.didUpdateWidget(old);
    _node.canRequestFocus = _enabled;
    _node.skipTraversal = !_enabled;
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onMode);
    _node.removeListener(_onNode);
    _attachment.detach();
    _node.dispose();
    super.dispose();
  }

  bool _ringFor(bool focused, FocusHighlightMode mode) =>
      focused && mode == FocusHighlightMode.traditional;

  void _onNode() {
    final focused = _node.hasPrimaryFocus;
    if (focused == _focused) return;
    _focused = focused;
    if (focused) {
      FocusManager.instance.addHighlightModeListener(_onMode);
    } else {
      FocusManager.instance.removeHighlightModeListener(_onMode);
    }
    if (mounted) {
      setState(() =>
          _ring = _ringFor(focused, FocusManager.instance.highlightMode));
    }
    widget.onFocusChange?.call(focused);
  }

  void _onMode(FocusHighlightMode mode) {
    final ring = _ringFor(_focused, mode);
    if (ring != _ring && mounted) setState(() => _ring = ring);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final act = widget.onActivate;
    if (act == null || !NymFocusable.isActivateKey(e.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) act();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    _attachment.reparent(
        parent: Focus.maybeOf(context, scopeOk: true, createDependency: false));
    final enabled = _enabled;
    Widget out = Semantics(
      button: widget.button,
      enabled: enabled,
      focusable: enabled,
      focused: _focused,
      label: widget.label ?? widget.tooltip,
      excludeSemantics: widget.excludeChildSemantics,
      onTap: widget.onActivate,
      onFocus: enabled ? _node.requestFocus : null,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: _ring
            ? BoxDecoration(
                borderRadius: widget.radius,
                border: Border.all(
                  color: context.nym.secondary,
                  width: NymFocusable.ringWidth,
                ),
              )
            : const BoxDecoration(),
        child: widget.child,
      ),
    );
    final tip = widget.tooltip;
    final keys = widget.tooltipKeys;
    if (tip != null && tip.isNotEmpty) {
      out = keys != null && keys.isNotEmpty
          ? NymTooltip(
              richMessage: keycapTooltip(context, tip, keys),
              excludeFromSemantics: true,
              child: out)
          : NymTooltip(message: tip, excludeFromSemantics: true, child: out);
    }
    return out;
  }
}
