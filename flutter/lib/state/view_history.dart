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
    final cur = current;
    if (cur != null &&
        cur.threadRoot != null &&
        entry.threadRoot == null &&
        entry.view == cur.view &&
        _index > 0 &&
        _entries[_index - 1] == entry) {
      _index--;
      return;
    }
    _entries.removeRange(_index + 1, _entries.length);
    _entries.add(entry);
    if (_entries.length > limit) _entries.removeAt(0);
    _index = _entries.length - 1;
  }

  ViewHistoryEntry? step(int delta) => jump(_index + delta);

  ViewHistoryEntry? jump(int index) {
    if (_index < 0 || index < 0 || index >= _entries.length) return null;
    _index = index;
    return _entries[index];
  }

  ViewHistoryEntry? at(int index) =>
      index < 0 || index >= _entries.length ? null : _entries[index];

  List<int> recent({int max = 10}) {
    final out = <int>[];
    final seen = <ViewHistoryEntry>{};
    final cur = current;
    for (var i = _index - 1; i >= 0 && out.length < max; i--) {
      final e = _entries[i];
      if (e.mesh || e == cur || !seen.add(e)) continue;
      out.add(i);
    }
    return out;
  }
}

final viewHistoryProvider = Provider<ViewHistory>((ref) => ViewHistory());

ViewHistoryEntry chatViewEntry(ChatView view, ActiveThread? thread) =>
    ViewHistoryEntry.view(view,
        threadRoot: thread != null && thread.view == view ? thread.rootId : null);

bool stepViewHistory(ProviderContainer c, int delta) {
  final history = c.read(viewHistoryProvider);
  return _goToEntry(c, history, history.step(delta));
}

bool jumpViewHistory(ProviderContainer c, int index) {
  final history = c.read(viewHistoryProvider);
  return _goToEntry(c, history, history.jump(index));
}

bool _goToEntry(ProviderContainer c, ViewHistory history, ViewHistoryEntry? entry) {
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
