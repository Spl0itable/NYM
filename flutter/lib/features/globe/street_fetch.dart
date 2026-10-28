import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/api/api_config.dart';
import 'street_bundle.dart';

const int kStreetMaxBody = 3145728;

Uri streetCellUri(String cell) {
  if (!kStreetCellRe.hasMatch(cell)) throw ArgumentError.value(cell, 'cell');
  return Uri(scheme: 'https', host: ApiConfig.apiHost, path: '/api/map/v1/$cell');
}

class StreetFetchResult {
  const StreetFetchResult(this.status, this.bytes, {this.aborted = false});
  final int status;
  final Uint8List? bytes;
  final bool aborted;
}

abstract class StreetFetcher {
  Future<StreetFetchResult> fetch(String cell);
  void abort();
}

class HttpStreetFetcher implements StreetFetcher {
  HttpStreetFetcher({http.Client Function()? client})
      : _make = client ?? http.Client.new;

  final http.Client Function() _make;
  http.Client? _client;
  int _gen = 0;

  @override
  Future<StreetFetchResult> fetch(String cell) async {
    final gen = _gen;
    final c = _client ??= _make();
    try {
      final req = http.Request('GET', streetCellUri(cell))
        ..followRedirects = false
        ..headers.addAll(ApiConfig.defaultHeaders);
      final res = await c.send(req).timeout(const Duration(seconds: 30));
      final out = BytesBuilder(copy: false);
      var over = false;
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        out.add(chunk);
        if (out.length > kStreetMaxBody) {
          over = true;
          break;
        }
      }
      if (gen != _gen) return const StreetFetchResult(0, null, aborted: true);
      if (over) return const StreetFetchResult(0, null);
      return StreetFetchResult(
          res.statusCode, res.statusCode == 200 ? out.takeBytes() : null);
    } catch (_) {
      if (gen != _gen) return const StreetFetchResult(0, null, aborted: true);
      return const StreetFetchResult(0, null);
    }
  }

  @override
  void abort() {
    _gen++;
    final c = _client;
    _client = null;
    c?.close();
  }
}
