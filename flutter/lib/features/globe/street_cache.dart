import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../identity/panic_wipe.dart';
import 'street_plan.dart';

const String kStreetCacheDir = 'nym-map';

typedef StreetMeta = ({int build, int fetchedAt});

class StreetHalt {
  static final Set<void Function()> _live = {};

  static void add(void Function() halt) => _live.add(halt);

  static void remove(void Function() halt) => _live.remove(halt);

  static void haltAll() {
    for (final h in [..._live]) {
      try {
        h();
      } catch (_) {}
    }
  }
}

abstract class StreetStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List bytes);
  Future<int?> negativeUntil(String key);
  Future<void> putNegative(String key, int untilMs);
  Future<StreetMeta?> readMeta();
  Future<void> writeMeta(int build, int fetchedAt);
  Future<void> dropOtherBuilds(int build);
  Future<void> sweep();
  Future<void> wipe();
  void close();
}

int _wallNow() => DateTime.now().millisecondsSinceEpoch;

bool _ofBuild(String key, int build) => key.startsWith('$build/');

class StreetMemoryStore implements StreetStore {
  StreetMemoryStore({this.capBytes = 16777216, int Function()? now})
      : _now = now ?? _wallNow;

  final int capBytes;
  final int Function() _now;
  final Map<String, Uint8List> _data = {};
  final Map<String, int> _neg = {};
  StreetMeta? _meta;
  bool _closed = false;

  @override
  void close() {
    _closed = true;
    _data.clear();
    _neg.clear();
    _meta = null;
  }

  @override
  Future<Uint8List?> read(String key) async {
    final b = _data.remove(key);
    if (b != null) _data[key] = b;
    return b;
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    if (_closed || parseStreetCacheKey(key) == null) return;
    _data.remove(key);
    _data[key] = bytes;
    var total = _data.values.fold<int>(0, (a, b) => a + b.length);
    while (total > capBytes && _data.length > 1) {
      final k = _data.keys.first;
      total -= _data.remove(k)!.length;
    }
  }

  @override
  Future<int?> negativeUntil(String key) async {
    final u = _neg[key];
    if (u == null) return null;
    if (_now() >= u) {
      _neg.remove(key);
      return null;
    }
    return u;
  }

  @override
  Future<void> putNegative(String key, int untilMs) async {
    if (!_closed) _neg[key] = untilMs;
  }

  @override
  Future<StreetMeta?> readMeta() async => _meta;

  @override
  Future<void> writeMeta(int build, int fetchedAt) async {
    if (!_closed) _meta = (build: build, fetchedAt: fetchedAt);
  }

  @override
  Future<void> dropOtherBuilds(int build) async {
    _data.removeWhere((k, _) => !_ofBuild(k, build));
    _neg.removeWhere((k, _) => !_ofBuild(k, build));
  }

  @override
  Future<void> sweep() async {}

  @override
  Future<void> wipe() async {
    _data.clear();
    _neg.clear();
    _meta = null;
  }
}

Future<Directory> _appCache() => getApplicationCacheDirectory();

class StreetFileCache implements StreetStore {
  StreetFileCache(
      {Future<Directory> Function()? base, int? capBytes, int Function()? now})
      : _base = base ?? _appCache,
        capBytes = capBytes ?? kStreet.flutterCacheBytes,
        _now = now ?? _wallNow;

  final Future<Directory> Function() _base;
  final int capBytes;
  final int Function() _now;
  Map<String, int>? _neg;
  bool _closed = false;

  bool get _off => _closed || PanicWipe.inProgress;

  @override
  void close() {
    _closed = true;
    _neg = null;
  }

  Future<void> _scrub() async {
    try {
      final d = Directory(await _root());
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  Future<String> _root() async => '${(await _base()).path}/$kStreetCacheDir';

  Future<Directory> _dir() async => Directory('${await _root()}/v2');

  Future<File?> _file(String key) async {
    final k = parseStreetCacheKey(key);
    if (k == null) return null;
    return File('${await _root()}/${streetFlutterFile(k.build, k.z, k.x, k.y).substring(kStreetCacheDir.length + 1)}');
  }

  @override
  Future<Uint8List?> read(String key) async {
    if (_closed) return null;
    final f = await _file(key);
    if (f == null || _closed) return null;
    try {
      if (!await f.exists()) return null;
      final saved = (await f.lastModified()).millisecondsSinceEpoch;
      if (_now() - saved > kStreet.cacheTtlMs) {
        await f.delete();
        return null;
      }
      final b = await f.readAsBytes();
      await f.setLastAccessed(DateTime.fromMillisecondsSinceEpoch(_now()));
      return b;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    if (_off) return;
    final f = await _file(key);
    if (f == null || _off) return;
    try {
      await f.parent.create(recursive: true);
      if (_off) return await _scrub();
      await f.writeAsBytes(bytes, flush: true);
      if (_off) return await _scrub();
      final t = DateTime.fromMillisecondsSinceEpoch(_now());
      await f.setLastModified(t);
      await f.setLastAccessed(t);
      await _evict();
    } catch (_) {}
  }

  Future<List<(File, FileStat)>> _entries() async {
    final d = await _dir();
    if (!await d.exists()) return const [];
    final out = <(File, FileStat)>[];
    await for (final e in d.list(recursive: true)) {
      if (e is File && e.path.endsWith('.mvt.gz')) out.add((e, await e.stat()));
    }
    return out;
  }

  Future<int> sizeBytes() async =>
      (await _entries()).fold<int>(0, (a, e) => a + e.$2.size);

  @override
  Future<void> sweep() async {
    if (_off) return;
    try {
      final v1 = Directory('${await _root()}/v1');
      if (await v1.exists()) await v1.delete(recursive: true);
      await _evict();
    } catch (_) {}
  }

  Future<void> _evict() async {
    final all = <(File, FileStat)>[];
    for (final e in await _entries()) {
      if (_now() - e.$2.modified.millisecondsSinceEpoch > kStreet.cacheTtlMs) {
        try {
          await e.$1.delete();
        } catch (_) {}
      } else {
        all.add(e);
      }
    }
    all.sort((a, b) => a.$2.accessed.compareTo(b.$2.accessed));
    var total = all.fold<int>(0, (a, e) => a + e.$2.size);
    for (final (f, st) in all) {
      if (total <= capBytes) break;
      try {
        await f.delete();
      } catch (_) {}
      total -= st.size;
    }
  }

  Future<Map<String, int>> _loadNeg() async {
    if (_neg != null) return _neg!;
    final out = <String, int>{};
    try {
      final f = File('${(await _dir()).path}/neg.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          for (final e in j.entries) {
            if (e.key is String && e.value is int) out[e.key as String] = e.value as int;
          }
        }
      }
    } catch (_) {}
    return _neg = out;
  }

  Future<void> _saveJson(String name, Object value) async {
    if (_off) return;
    try {
      final d = await _dir();
      if (_off) return;
      await d.create(recursive: true);
      if (_off) return await _scrub();
      await File('${d.path}/$name').writeAsString(jsonEncode(value), flush: true);
      if (_off) return await _scrub();
    } catch (_) {}
  }

  @override
  Future<int?> negativeUntil(String key) async {
    final m = await _loadNeg();
    final u = m[key];
    if (u == null) return null;
    if (_now() >= u) {
      m.remove(key);
      await _saveJson('neg.json', m);
      return null;
    }
    return u;
  }

  @override
  Future<void> putNegative(String key, int untilMs) async {
    if (_off || parseStreetCacheKey(key) == null) return;
    final m = await _loadNeg();
    final now = _now();
    m.removeWhere((_, v) => v <= now);
    m[key] = untilMs;
    await _saveJson('neg.json', m);
  }

  @override
  Future<StreetMeta?> readMeta() async {
    if (_closed) return null;
    try {
      final f = File('${(await _dir()).path}/meta.json');
      if (_closed || !await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['build'] is int && j['fetchedAt'] is int && (j['build'] as int) > 0) {
        return (build: j['build'] as int, fetchedAt: j['fetchedAt'] as int);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> writeMeta(int build, int fetchedAt) =>
      _saveJson('meta.json', {'build': build, 'fetchedAt': fetchedAt});

  @override
  Future<void> dropOtherBuilds(int build) async {
    if (_off) return;
    try {
      final d = await _dir();
      if (await d.exists()) {
        await for (final e in d.list()) {
          if (e is Directory && e.uri.pathSegments.where((s) => s.isNotEmpty).last != '$build') {
            await e.delete(recursive: true);
          }
        }
      }
      final m = await _loadNeg();
      final before = m.length;
      m.removeWhere((k, _) => !_ofBuild(k, build));
      if (m.length != before) await _saveJson('neg.json', m);
    } catch (_) {}
  }

  @override
  Future<void> wipe() async {
    _neg = null;
    try {
      final d = Directory(await _root());
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

class StreetCacheWipe implements PanicFileStore {
  StreetCacheWipe({Future<Directory> Function()? base}) : _base = base ?? _appCache;

  final Future<Directory> Function() _base;

  @override
  Future<void> wipe() {
    StreetHalt.haltAll();
    return StreetFileCache(base: _base).wipe();
  }
}
