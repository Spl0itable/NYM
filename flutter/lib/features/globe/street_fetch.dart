import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/api/api_config.dart';
import 'street_plan.dart';

Uri streetTileUri(int build, int z, int x, int y) {
  if (parseStreetCacheKey(streetCacheKey(build, z, x, y)) == null) {
    throw ArgumentError.value('$build/$z/$x/$y', 'tile');
  }
  return Uri(scheme: 'https', host: ApiConfig.apiHost, path: streetTilePath(build, z, x, y));
}

Uri streetMetaUri() => Uri(scheme: 'https', host: ApiConfig.apiHost, path: '/api/map/v2/meta');

class StreetFetchResult {
  const StreetFetchResult(this.status, this.bytes, {this.aborted = false});
  final int status;
  final Uint8List? bytes;
  final bool aborted;
}

abstract class StreetFetcher {
  Future<StreetFetchResult> fetchMeta();
  Future<StreetFetchResult> fetchTile(int build, StreetTileId t);
  void cancel(String key);
  void abort();
}

class HttpStreetFetcher implements StreetFetcher {
  HttpStreetFetcher({http.Client Function()? client})
      : _make = client ?? http.Client.new;

  final http.Client Function() _make;
  http.Client? _client;
  int _gen = 0;
  final Map<String, Completer<void>> _open = {};

  @override
  Future<StreetFetchResult> fetchMeta() => _get(streetMetaUri(), null);

  @override
  Future<StreetFetchResult> fetchTile(int build, StreetTileId t) =>
      _get(streetTileUri(build, t.z, t.x, t.y), streetCacheKey(build, t.z, t.x, t.y));

  Future<StreetFetchResult> _get(Uri uri, String? key) async {
    final gen = _gen;
    final c = _client ??= _make();
    final stop = Completer<void>();
    if (key != null) {
      cancel(key);
      _open[key] = stop;
    }
    bool dead() => gen != _gen || stop.isCompleted;
    try {
      final req = http.AbortableRequest('GET', uri, abortTrigger: stop.future)
        ..followRedirects = false
        ..headers.addAll(ApiConfig.defaultHeaders);
      final res = await c.send(req).timeout(const Duration(seconds: 30));
      final out = BytesBuilder(copy: false);
      var over = false;
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        if (dead()) break;
        out.add(chunk);
        if (out.length > kStreet.maxBodyBytes) {
          over = true;
          break;
        }
      }
      if (dead()) return const StreetFetchResult(0, null, aborted: true);
      if (over) return const StreetFetchResult(422, null);
      return StreetFetchResult(res.statusCode, out.takeBytes());
    } catch (_) {
      if (dead()) return const StreetFetchResult(0, null, aborted: true);
      return const StreetFetchResult(0, null);
    } finally {
      if (key != null && identical(_open[key], stop)) _open.remove(key);
    }
  }

  @override
  void cancel(String key) {
    final s = _open.remove(key);
    if (s != null && !s.isCompleted) s.complete();
  }

  @override
  void abort() {
    _gen++;
    for (final s in _open.values) {
      if (!s.isCompleted) s.complete();
    }
    _open.clear();
    final c = _client;
    _client = null;
    c?.close();
  }
}
