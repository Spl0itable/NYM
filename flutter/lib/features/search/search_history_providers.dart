import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import '../../services/storage/sealed_key_value.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../identity/panic_wipe.dart';
import 'search_history.dart';

class SearchHistoryController extends StateNotifier<List<SearchHistoryEntry>> {
  SearchHistoryController(
    this._kv,
    this._sealed, {
    required this.currentOwner,
    required this.memoryOnly,
    required this.knownMemoryOnly,
    this.now,
  }) : super(const []);

  final KeyValueStore _kv;
  final SealedKeyValue _sealed;
  final String Function() currentOwner;
  final bool Function() memoryOnly;
  final bool? Function() knownMemoryOnly;
  final int Function()? now;
  String _for = '';
  bool _held = false;
  bool _locked = false;
  Future<void>? _loading;
  String _loadingFor = '';

  String get owner => currentOwner();

  bool get loaded =>
      _for.isNotEmpty && _for == owner && _seenHeld(_held) == _held;

  bool get locked => _locked;

  bool get remember =>
      _kv.getString(StorageKeys.rememberSearches) != SearchHistoryKeys.off;

  int get _nowMs => now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  bool _seenHeld(bool fallback) => knownMemoryOnly() ?? fallback;

  void _forget() {
    _for = '';
    _locked = false;
    state = const <SearchHistoryEntry>[];
  }

  Future<void> get idle async {
    await (_loading ?? Future<void>.value());
    await _sealed.idle;
  }

  void followOwner() {
    if (_for.isEmpty) return;
    final pk = owner;
    final held = _seenHeld(_held);
    if (pk == _for && held == _held) return;
    if (pk.isNotEmpty && held && _held) {
      _for = pk;
      return;
    }
    _forget();
  }

  Future<void> load() {
    followOwner();
    final pk = owner;
    if (pk.isEmpty || loaded) return Future<void>.value();
    final held = _seenHeld(false);
    final tag = held ? 'memory:$pk' : pk;
    final running = _loading;
    if (running != null && _loadingFor == tag) return running;
    _loadingFor = tag;
    late final Future<void> f;
    f = _load(pk, held).whenComplete(() {
      if (identical(_loading, f)) _loading = null;
    });
    _loading = f;
    return f;
  }

  Future<void> _load(String pk, bool held) async {
    var read = const SealedRead(SealedReadStatus.absent);
    if (!held) {
      try {
        read = await _sealed.readDetailed(StorageKeys.searchHistoryFor(pk));
      } catch (_) {
        read = const SealedRead(SealedReadStatus.unreadable);
      }
    }
    if (!mounted || owner != pk || _seenHeld(held) != held || loaded) return;
    if (read.status == SealedReadStatus.locked) {
      _locked = true;
      return;
    }
    _locked = false;
    _for = pk;
    _held = held;
    final raw = read.value;
    final items = raw == null ||
            raw.isEmpty ||
            read.status == SealedReadStatus.unreadable ||
            !remember
        ? const <SearchHistoryEntry>[]
        : decodeSearchHistory(raw);
    state = List<SearchHistoryEntry>.unmodifiable(items);
  }

  Future<bool> _ready() async {
    if (owner.isEmpty) return false;
    final held = memoryOnly();
    if (_for.isNotEmpty && held != _held) _forget();
    if (!loaded) await load();
    return mounted && loaded;
  }

  void _persist() {
    final pk = owner;
    if (pk.isEmpty || _held || memoryOnly()) return;
    final key = StorageKeys.searchHistoryFor(pk);
    if (state.isEmpty) {
      _sealed.remove(key);
    } else {
      _sealed.write(key, encodeSearchHistory(state));
    }
  }

  Future<void> record(Object? raw) async {
    if (!remember) return;
    if (!await _ready()) return;
    if (!remember) return;
    final next = addSearch(state, raw, _nowMs);
    if (identical(next, state)) return;
    state = next;
    _persist();
  }

  Future<void> remove(Object? raw) async {
    if (!await _ready()) return;
    final next = removeSearch(state, raw);
    if (identical(next, state)) return;
    state = next;
    _persist();
  }

  Future<void> clear() async {
    if (!await _ready()) return;
    state = List<SearchHistoryEntry>.unmodifiable(clearSearches());
    _persist();
  }

  Future<void> setRemember(bool on) async {
    if (on) {
      await _kv.remove(StorageKeys.rememberSearches);
    } else {
      await _kv.setString(StorageKeys.rememberSearches, SearchHistoryKeys.off);
    }
    if (owner.isNotEmpty && !loaded) await load();
    if (!mounted) return;
    final pk = owner;
    if (!on && pk.isNotEmpty) {
      _for = pk;
      _held = memoryOnly();
      _locked = false;
      _sealed.remove(StorageKeys.searchHistoryFor(pk));
    }
    state = List<SearchHistoryEntry>.unmodifiable(const <SearchHistoryEntry>[]);
  }
}

final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryController, List<SearchHistoryEntry>>(
        (ref) {
  ref.watch(bootEpochProvider);
  final kv = ref.watch(keyValueStoreProvider);
  final c = SearchHistoryController(
    kv,
    SealedKeyValue(kv, blocked: () => PanicWipe.inProgress),
    currentOwner: () => ref.read(appStateProvider).selfPubkey,
    memoryOnly: () => !ref.read(nostrControllerProvider).savedSyncAllowed,
    knownMemoryOnly: () => ref.exists(nostrControllerProvider)
        ? !ref.read(nostrControllerProvider).savedSyncAllowed
        : null,
  );
  ref.listen<String>(appStateProvider.select((s) => s.selfPubkey), (_, _) {
    c.followOwner();
    unawaited(c.load());
  });
  unawaited(c.load());
  return c;
});
