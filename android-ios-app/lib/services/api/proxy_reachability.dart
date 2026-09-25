import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const Set<int> kProxyEdgeFailureStatuses = {
  502,
  503,
  520,
  521,
  522,
  523,
  524,
  525,
  526,
  527,
};

bool proxyUnreachable(Object outcome) {
  if (outcome is http.BaseResponse) return _unreachableResponse(outcome);
  return outcome is SocketException ||
      outcome is TlsException ||
      outcome is HttpException ||
      outcome is http.ClientException;
}

bool _unreachableResponse(http.BaseResponse res) {
  if (_fromWorker(res)) return false;
  if (kProxyEdgeFailureStatuses.contains(res.statusCode)) return true;
  if (res is http.Response && _isWorkerErrorBody(res)) return false;
  return true;
}

bool _fromWorker(http.BaseResponse res) =>
    _header(res.headers, 'access-control-allow-origin') != null;

bool _isWorkerErrorBody(http.Response res) {
  final type = _header(res.headers, 'content-type') ?? '';
  if (!type.toLowerCase().contains('json')) return false;
  try {
    final body = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    return body is Map && body['error'] is String;
  } catch (_) {
    return false;
  }
}

String? _header(Map<String, String> headers, String name) {
  final direct = headers[name];
  if (direct != null) return direct;
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name) return e.value;
  }
  return null;
}

Future<bool> mediaProxyUnreachable(
  String proxiedUrl, {
  http.Client? client,
  Duration connectTimeout = const Duration(seconds: 10),
  Duration responseTimeout = const Duration(seconds: 20),
}) async {
  final c =
      client ?? IOClient(HttpClient()..connectionTimeout = connectTimeout);
  try {
    final req = http.Request('GET', Uri.parse(proxiedUrl))
      ..followRedirects = false
      ..headers['Range'] = 'bytes=0-0';
    final res = await c.send(req).timeout(responseTimeout);
    if (_fromWorker(res) ||
        kProxyEdgeFailureStatuses.contains(res.statusCode)) {
      unawaited(res.stream.listen((_) {}).cancel());
      return proxyUnreachable(res);
    }
    final body = await _readBounded(res.stream, 4096).timeout(responseTimeout);
    return proxyUnreachable(http.Response.bytes(body, res.statusCode,
        headers: res.headers, request: res.request));
  } catch (e) {
    return proxyUnreachable(e);
  } finally {
    if (client == null) c.close();
  }
}

Future<List<int>> _readBounded(Stream<List<int>> stream, int max) async {
  final out = <int>[];
  final done = Completer<List<int>>();
  late StreamSubscription<List<int>> sub;
  sub = stream.listen(
    (chunk) {
      out.addAll(chunk);
      if (out.length >= max && !done.isCompleted) {
        done.complete(out.sublist(0, max));
        unawaited(sub.cancel());
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(out);
    },
    cancelOnError: true,
  );
  return done.future;
}
