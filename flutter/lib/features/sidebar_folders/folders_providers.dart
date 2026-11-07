import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/storage/sealed_key_value.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../identity/panic_wipe.dart';
import '../sidebar/sidebar_layout.dart';
import 'folders.dart';
import 'folders_service.dart';

final sidebarFoldersRevisionProvider = StateProvider<int>((ref) => 0);

final sidebarFolderCollapseRevisionProvider = StateProvider<int>((ref) => 0);

final sidebarFoldersProvider = Provider<SidebarFoldersService>((ref) {
  ref.watch(bootEpochProvider);
  final kv = ref.watch(keyValueStoreProvider);
  var bump = false;
  var bumpCollapse = false;
  var disposed = false;
  void later(void Function() run) => Future.microtask(() {
        if (!disposed) run();
      });
  final service = SidebarFoldersService(
    kv,
    SealedKeyValue(kv, blocked: () => PanicWipe.inProgress),
    SidebarFoldersHooks(
      selfPubkey: () => ref.read(appStateProvider).selfPubkey,
      syncAllowed: () => ref.read(nostrControllerProvider).savedSyncAllowed,
      online: () => ref.read(appStateProvider).connectedRelays > 0,
      hydrated: () => ref.read(nostrControllerProvider).savesHydrated,
      publish: (s, ping) =>
          ref.read(nostrControllerProvider).publishSidebarFolders(s, ping: ping),
      onChanged: () {
        if (bump) return;
        bump = true;
        later(() {
          bump = false;
          ref.read(sidebarFoldersRevisionProvider.notifier).state++;
        });
      },
      onCollapse: () {
        if (bumpCollapse) return;
        bumpCollapse = true;
        later(() {
          bumpCollapse = false;
          ref.read(sidebarFolderCollapseRevisionProvider.notifier).state++;
        });
      },
    ),
  );
  ref.onDispose(() {
    disposed = true;
    service.dispose();
  });
  Future.microtask(() {
    if (!disposed) service.load();
  });
  return service;
});

@immutable
class SidebarFolderLayout {
  const SidebarFolderLayout(this.tokens, this.ready);

  final List<String> tokens;
  final bool ready;

  List<String> get builtins =>
      [for (final t in tokens) if (kFolderBuiltins.contains(t)) t];

  @override
  bool operator ==(Object other) =>
      other is SidebarFolderLayout &&
      other.ready == ready &&
      listEquals(other.tokens, tokens);

  @override
  int get hashCode => Object.hash(ready, Object.hashAll(tokens));
}

final sidebarFolderLayoutProvider = Provider<SidebarFolderLayout>((ref) {
  ref.watch(sidebarFoldersRevisionProvider);
  ref.watch(appStateProvider.select((s) => s.selfPubkey));
  final order = ref.watch(sidebarSectionOrderProvider);
  final service = ref.watch(sidebarFoldersProvider);
  if (!service.ready) return SidebarFolderLayout(List.unmodifiable(order), false);
  return SidebarFolderLayout(
      List.unmodifiable(effectiveLayout(service.state, order)), true);
});

@immutable
class SidebarFolderCollapsed {
  const SidebarFolderCollapsed(this.ids);

  final Set<String> ids;

  bool contains(String fid) => ids.contains(fid);

  @override
  bool operator ==(Object other) =>
      other is SidebarFolderCollapsed && setEquals(other.ids, ids);

  @override
  int get hashCode => Object.hashAllUnordered(ids);
}

final sidebarFolderCollapsedProvider = Provider<SidebarFolderCollapsed>((ref) {
  ref.watch(sidebarFolderCollapseRevisionProvider);
  ref.watch(sidebarFoldersRevisionProvider);
  ref.watch(appStateProvider.select((s) => s.selfPubkey));
  return SidebarFolderCollapsed(ref.watch(sidebarFoldersProvider).collapsed);
});

@immutable
class SidebarFolderPicker {
  const SidebarFolderPicker(this.fid, this.selected, this.query);

  final String fid;
  final Set<String> selected;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is SidebarFolderPicker &&
      other.fid == fid &&
      other.query == query &&
      setEquals(other.selected, selected);

  @override
  int get hashCode => Object.hash(fid, query, Object.hashAllUnordered(selected));
}

class SidebarFolderPickerNotifier extends StateNotifier<SidebarFolderPicker?> {
  SidebarFolderPickerNotifier() : super(null);

  SidebarFolderPicker? get current => state;

  void open(String fid, Set<String> selected) =>
      state = SidebarFolderPicker(fid, Set.unmodifiable(selected), '');

  void toggle(String ref, {required bool canAdd}) {
    final s = state;
    if (s == null) return;
    final next = Set.of(s.selected);
    if (!next.remove(ref)) {
      if (!canAdd) return;
      next.add(ref);
    }
    state = SidebarFolderPicker(s.fid, Set.unmodifiable(next), s.query);
  }

  void search(String q) {
    final s = state;
    if (s == null || s.query == q) return;
    state = SidebarFolderPicker(s.fid, s.selected, q);
  }

  void close() => state = null;
}

final sidebarFolderPickerProvider =
    StateNotifierProvider<SidebarFolderPickerNotifier, SidebarFolderPicker?>(
        (ref) => SidebarFolderPickerNotifier());
