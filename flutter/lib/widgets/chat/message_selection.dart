import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../features/layout/pointer_input.dart';

class MessageSelection extends StatefulWidget {
  const MessageSelection({super.key, required this.builder});

  final Widget Function(bool keepAlives) builder;

  static MessageSelectionState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_MessageSelectionScope>()?.state;

  static Widget plain(bool mouse, Widget child) =>
      mouse ? SelectionContainer.disabled(child: child) : child;

  static Widget item(BuildContext context, Widget child, {Key? key}) =>
      PointerInput.mouseOf(context)
          ? MessageSelectionItem(key: key, child: child)
          : child;

  static SelectionRegistrar? itemRegistrarOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ItemRegistrar>()?.registrar;

  @override
  State<MessageSelection> createState() => MessageSelectionState();
}

class MessageSelectionState extends State<MessageSelection> {
  final GlobalKey<SelectionAreaState> _area = GlobalKey<SelectionAreaState>();
  final GlobalKey _list = GlobalKey();
  final FocusNode _focus =
      FocusNode(skipTraversal: true, debugLabel: 'messageSelection');
  final ValueNotifier<String> text = ValueNotifier<String>('');
  final Set<MessageBodySelection> _bodies = <MessageBodySelection>{};
  MessageBodySelection? _lead;
  bool _leadKnown = false;

  SelectableRegionState? get region => _area.currentState?.selectableRegion;

  void clear() => region?.clearSelection();

  void focus() => _focus.requestFocus();

  MessageBodySelection body() => MessageBodySelection._(this);

  void _stale() {
    _leadKnown = false;
    _lead = null;
  }

  bool _leads(MessageBodySelection body) {
    if (!_leadKnown) {
      _leadKnown = true;
      Offset? best;
      for (final b in _bodies) {
        if (b.value.status != SelectionStatus.uncollapsed) continue;
        final at = b._origin();
        if (at == null) continue;
        if (best == null ||
            at.dy < best.dy ||
            (at.dy == best.dy && at.dx < best.dx)) {
          best = at;
          _lead = b;
        }
      }
    }
    return identical(_lead, body);
  }

  @override
  void initState() {
    super.initState();
    PointerInput.instance.addListener(_onPointerMode);
  }

  void _onPointerMode() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PointerInput.instance.removeListener(_onPointerMode);
    _focus.dispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mouse = PointerInput.mouseOf(context);
    final list = KeyedSubtree(key: _list, child: widget.builder(!mouse));
    if (!mouse) {
      if (text.value.isNotEmpty) text.value = '';
      return list;
    }
    return _MessageSelectionScope(
      state: this,
      child: SelectionArea(
        key: _area,
        focusNode: _focus,
        contextMenuBuilder: null,
        onSelectionChanged: (s) => text.value = s?.plainText ?? '',
        child: list,
      ),
    );
  }
}

class MessageSelectionItem extends StatelessWidget {
  const MessageSelectionItem({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) == null ||
        context.getInheritedWidgetOfExactType<_MessageSelectionScope>() ==
            null) {
      return child;
    }
    SelectionRegistrar? registrar;
    context.visitAncestorElements((e) {
      final w = e.widget;
      if (w is SelectionRegistrarScope &&
          w.registrar is SelectionContainerDelegate) {
        registrar = w.registrar;
        return false;
      }
      return w is! _MessageSelectionScope;
    });
    final list = registrar;
    if (list == null) return child;
    return _ItemRegistrar(
      registrar: list,
      child: SelectionContainer.disabled(child: child),
    );
  }
}

class MessageBodySelection extends StaticSelectionContainerDelegate {
  MessageBodySelection._(this._owner) {
    _owner._bodies.add(this);
    _owner._stale();
    addListener(_owner._stale);
  }

  final MessageSelectionState _owner;

  Offset? _origin() {
    for (final s in selectables) {
      final boxes = s.boundingBoxes;
      if (boxes.isEmpty) continue;
      return MatrixUtils.transformPoint(
          s.getTransformTo(null), boxes.first.topLeft);
    }
    return null;
  }

  @override
  SelectedContent? getSelectedContent() {
    final own = super.getSelectedContent();
    if (own == null || own.plainText.isEmpty || _owner._leads(this)) {
      return own;
    }
    return SelectedContent(plainText: '\n${own.plainText}');
  }

  @override
  void dispose() {
    removeListener(_owner._stale);
    _owner._bodies.remove(this);
    _owner._stale();
    super.dispose();
  }
}

class _MessageSelectionScope extends InheritedWidget {
  const _MessageSelectionScope({required this.state, required super.child});

  final MessageSelectionState state;

  @override
  bool updateShouldNotify(_MessageSelectionScope old) => false;
}

class _ItemRegistrar extends InheritedWidget {
  const _ItemRegistrar({required this.registrar, required super.child});

  final SelectionRegistrar registrar;

  @override
  bool updateShouldNotify(_ItemRegistrar old) =>
      !identical(registrar, old.registrar);
}
