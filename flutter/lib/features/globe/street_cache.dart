import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../identity/panic_wipe.dart';
import 'street_bundle.dart';
import 'street_plan.dart';

const String kStreetCacheDir = 'nym-map';

abstract class StreetStore {
  Future<Uint8List?> read(String cell);
  Future<void> write(String cell, Uint8List bytes);
  Future<int?> negativeUntil(String cell);
  Future<void> putNegative(String cell, int untilMs);
  Future<void> sweep();
  Future<void> wipe();
}

int _wallNow() => DateTime.now().millisecondsSinceEpoch;

class StreetMemoryStore implements StreetStore {
  StreetMemoryStore({this.capBytes = 16777216, int Function()? now})
      : _now = now ?? _wallNow;

  final int capBytes;
  final int Function() _now;
  final Map<String, Uint8List> _data = {};
  final Map<String, int> _neg = {};

  @override
  Future<Uint8List?> read(String cell) async {
    final b = _data.remove(cell);
    if (b != null) _data[cell] = b;
    return b;
  }

  @override
  Future<void> write(String cell, Uint8List bytes) async {
    _data.remove(cell);
    _data[cell] = bytes;
    var total = _data.values.fold<int>(0, (a, b) => a + b.length);
    while (total > capBytes && _data.length > 1) {
      final k = _data.keys.first;
      total -= _data.remove(k)!.length;
    }
  }

  @override
  Future<int?> negativeUntil(String cell) async {
    final u = _neg[cell];
    if (u == null) return null;
    if (_now() >= u) {
      _neg.remove(cell);
      return null;
    }
    return u;
  }

  @override
  Future<void> putNegative(String cell, int untilMs) async => _neg[cell] = untilMs;

  @override
  Future<void> sweep() async {}

  @override
  Future<void> wipe() async {
    _data.clear();
    _neg.clear();
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

  Future<Directory> _dir() async =>
      Directory('${(await _base()).path}/$kStreetCacheDir/v1');

  Future<File?> _file(String cell) async {
    if (!kStreetCellRe.hasMatch(cell)) return null;
    return File('${(await _dir()).path}/$cell.nmt');
  }

  @override
  Future<Uint8List?> read(String cell) async {
    final f = await _file(cell);
    if (f == null) return null;
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
  Future<void> write(String cell, Uint8List bytes) async {
    if (PanicWipe.inProgress) return;
    final f = await _file(cell);
    if (f == null || PanicWipe.inProgress) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      if (PanicWipe.inProgress) {
        await f.delete();
        return;
      }
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
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.nmt')) out.add((e, await e.stat()));
    }
    return out;
  }

  Future<int> sizeBytes() async =>
      (await _entries()).fold<int>(0, (a, e) => a + e.$2.size);

  @override
  Future<void> sweep() async {
    try {
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

  Future<void> _saveNeg(Map<String, int> m) async {
    if (PanicWipe.inProgress) return;
    try {
      final d = await _dir();
      if (PanicWipe.inProgress) return;
      await d.create(recursive: true);
      await File('${d.path}/neg.json').writeAsString(jsonEncode(m), flush: true);
    } catch (_) {}
  }

  @override
  Future<int?> negativeUntil(String cell) async {
    final m = await _loadNeg();
    final u = m[cell];
    if (u == null) return null;
    if (_now() >= u) {
      m.remove(cell);
      await _saveNeg(m);
      return null;
    }
    return u;
  }

  @override
  Future<void> putNegative(String cell, int untilMs) async {
    if (PanicWipe.inProgress) return;
    final m = await _loadNeg();
    final now = _now();
    m.removeWhere((_, v) => v <= now);
    m[cell] = untilMs;
    await _saveNeg(m);
  }

  @override
  Future<void> wipe() async {
    _neg = null;
    try {
      final d = Directory('${(await _base()).path}/$kStreetCacheDir');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

class StreetCacheWipe implements PanicFileStore {
  StreetCacheWipe({Future<Directory> Function()? base}) : _base = base ?? _appCache;

  final Future<Directory> Function() _base;

  @override
  Future<void> wipe() => StreetFileCache(base: _base).wipe();
}
