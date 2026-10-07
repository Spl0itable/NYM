import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/mesh/mesh_controller.dart' show meshScreenOpenProvider;
import 'app_state.dart';

@immutable
class ViewHistoryEntry {
  const ViewHistoryEntry.view(ChatView this.view, {this.threadRoot})
      : mesh = false;

  const ViewHistoryEntry.mesh()
      : view = null,
        threadRoot = null,
        mesh = true;

  final ChatView? view;
  final String? threadRoot;
  final bool mesh;

  @override
  bool operator ==(Object other) =>
      other is ViewHistoryEntry &&
      other.view == view &&
      other.threadRoot == threadRoot &&
      other.mesh == mesh;

  @override
  int get hashCode => Object.hash(view, threadRoot, mesh);
}

class ViewHistory {
  static const int limit = 50;

  final List<ViewHistoryEntry> _entries = [];
  int _index = -1;
  bool navigating = false;

  bool get isEmpty => _index < 0;
  bool get canBack => _index > 0;
  bool get canForward => _index >= 0 && _index < _entries.length - 1;
  ViewHistoryEntry? get current => _index < 0 ? null : _entries[_index];

  void record(ViewHistoryEntry entry) {
    if (navigating || current == entry) return;
    _entries.removeRange(_index + 1, _entries.length);
    _entries.add(entry);
    if (_entries.length > limit) _entries.removeAt(0);
    _index = _entries.length - 1;
  }

  ViewHistoryEntry? step(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= _entries.length) return null;
    _index = next;
    return _entries[next];
  }
}

final viewHistoryProvider = Provider<ViewHistory>((ref) => ViewHistory());

ViewHistoryEntry chatViewEntry(ChatView view, ActiveThread? thread) =>
    ViewHistoryEntry.view(view,
        threadRoot: thread != null && thread.view == view ? thread.rootId : null);

bool stepViewHistory(ProviderContainer c, int delta) {
  final history = c.read(viewHistoryProvider);
  final entry = history.step(delta);
  if (entry == null) return false;
  history.navigating = true;
  final view = entry.view;
  if (entry.mesh || view == null) {
    c.read(meshScreenOpenProvider.notifier).state = true;
  } else {
    c.read(meshScreenOpenProvider.notifier).state = false;
    c.read(appStateProvider.notifier).switchView(view);
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (view != null) {
      final root = entry.threadRoot;
      final target = root == null ? null : ActiveThread(view: view, rootId: root);
      if (c.read(activeThreadProvider) != target) {
        c.read(activeThreadProvider.notifier).state = target;
      }
    }
    history.navigating = false;
  });
  return true;
}
