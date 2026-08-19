import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/wallpaper/wallpaper_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wp_cache_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    WallpaperCache.resetForTest();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
  const urlA = 'https://host.example/wall-a.jpg';
  const urlB = 'https://host.example/wall-b.jpg';

  test('store() makes the wallpaper available synchronously afterwards',
      () async {
    expect(WallpaperCache.cached(urlA), isNull);
    final f = await WallpaperCache.store(urlA, bytes);
    expect(f, isNotNull);
    expect(await f!.readAsBytes(), bytes);
    // The paint path reads this synchronously — no FutureBuilder flash.
    expect(WallpaperCache.cached(urlA), isNotNull);
  });

  test('resolve() fetches once even when many callers race', () async {
    var fetches = 0;
    Future<Uint8List?> fetch(String u) async {
      fetches++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return bytes;
    }

    final results = await Future.wait([
      WallpaperCache.resolve(urlA, fetch: fetch),
      WallpaperCache.resolve(urlA, fetch: fetch),
      WallpaperCache.resolve(urlA, fetch: fetch),
    ]);
    expect(fetches, 1, reason: 'concurrent callers must share one fetch');
    expect(results.every((f) => f != null), isTrue);
  });

  test('an already-written file is adopted without fetching', () async {
    await WallpaperCache.store(urlA, bytes);
    WallpaperCache.resetForTest(); // simulate a fresh launch
    var fetches = 0;
    final f = await WallpaperCache.resolve(urlA, fetch: (u) async {
      fetches++;
      return bytes;
    });
    expect(f, isNotNull);
    expect(fetches, 0, reason: 'cold start must paint from disk, not the host');
  });

  test('a failed fetch is not cached, so a later attempt retries', () async {
    var fetches = 0;
    final first = await WallpaperCache.resolve(urlA, fetch: (u) async {
      fetches++;
      return null;
    });
    expect(first, isNull);
    final second = await WallpaperCache.resolve(urlA, fetch: (u) async {
      fetches++;
      return bytes;
    });
    expect(second, isNotNull);
    expect(fetches, 2);
  });

  test('pruneExcept keeps the current wallpaper and drops the rest', () async {
    await WallpaperCache.store(urlA, bytes);
    await WallpaperCache.store(urlB, bytes);
    await WallpaperCache.pruneExcept(urlB);
    expect(WallpaperCache.cached(urlB), isNotNull);
    expect(WallpaperCache.cached(urlA), isNull);
    final left = Directory('${tmp.path}/wallpaper')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    expect(left, [WallpaperCache.fileNameForTest(urlB)]);
  });

  test('distinct urls map to distinct files', () {
    expect(WallpaperCache.fileNameForTest(urlA),
        isNot(WallpaperCache.fileNameForTest(urlB)));
  });
}
