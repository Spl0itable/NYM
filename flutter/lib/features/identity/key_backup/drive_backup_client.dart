import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

typedef DriveAccessToken = Future<String> Function({bool forceRefresh});

final RegExp kDriveBackupNamePattern = RegExp(r'^nym_bk_[0-9a-f-]{36}\.bin$');

class DriveBackupFile {
  const DriveBackupFile({required this.id, required this.name, this.modifiedTime});

  final String id;
  final String name;
  final DateTime? modifiedTime;
}

class DriveAuthException implements Exception {
  const DriveAuthException();

  @override
  String toString() => 'DriveAuthException: Google authorization was refused';
}

class DriveRequestException implements Exception {
  const DriveRequestException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'DriveRequestException: HTTP $statusCode';
}

class DriveBackupClient {
  DriveBackupClient({
    required DriveAccessToken accessToken,
    http.Client? client,
    String Function()? newId,
  })  : _accessToken = accessToken,
        _client = client ?? http.Client(),
        _newId = newId ?? (() => const Uuid().v4());

  static const String _host = 'www.googleapis.com';

  final DriveAccessToken _accessToken;
  final http.Client _client;
  final String Function() _newId;

  Future<List<DriveBackupFile>> list() async {
    final uri = Uri.https(_host, '/drive/v3/files', {
      'spaces': 'appDataFolder',
      'q': "name contains 'nym_bk_'",
      'fields': 'files(id,name,modifiedTime)',
      'pageSize': '100',
    });
    final res = await _send((token) => _client.get(uri, headers: _auth(token)));
    final body = jsonDecode(res.body);
    final files = body is Map ? body['files'] : null;
    if (files is! List) return const [];
    final out = <DriveBackupFile>[];
    for (final f in files) {
      if (f is! Map) continue;
      final id = f['id'];
      final name = f['name'];
      if (id is! String || name is! String) continue;
      if (!kDriveBackupNamePattern.hasMatch(name)) continue;
      final modified = f['modifiedTime'];
      out.add(DriveBackupFile(
        id: id,
        name: name,
        modifiedTime: modified is String ? DateTime.tryParse(modified) : null,
      ));
    }
    return out;
  }

  Future<String> download(String id) async {
    final uri = _fileUri(id, {'alt': 'media'});
    final res = await _send((token) => _client.get(uri, headers: _auth(token)));
    return utf8.decode(res.bodyBytes).trim();
  }

  Future<DriveBackupFile> upload(String payload) async {
    final name = 'nym_bk_${_newId().toLowerCase()}.bin';
    final boundary = 'nym_bk_boundary_${_newId().replaceAll('-', '')}';
    final metadata = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
    });
    final body = '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/octet-stream\r\n\r\n'
        '$payload\r\n'
        '--$boundary--\r\n';
    final uri = Uri.https(
        _host, '/upload/drive/v3/files', {'uploadType': 'multipart'});
    final res = await _send((token) => _client.post(
          uri,
          headers: {
            ..._auth(token),
            'Content-Type': 'multipart/related; boundary=$boundary',
          },
          body: utf8.encode(body),
        ));
    var id = '';
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['id'] is String) id = decoded['id'];
    } catch (_) {}
    return DriveBackupFile(id: id, name: name);
  }

  Future<void> delete(String id) async {
    final uri = _fileUri(id);
    await _send((token) => _client.delete(uri, headers: _auth(token)),
        allowNotFound: true);
  }

  Uri _fileUri(String id, [Map<String, String>? query]) => Uri(
        scheme: 'https',
        host: _host,
        pathSegments: ['drive', 'v3', 'files', id],
        queryParameters: query,
      );

  Map<String, String> _auth(String token) => {'Authorization': 'Bearer $token'};

  Future<http.Response> _send(
    Future<http.Response> Function(String token) request, {
    bool allowNotFound = false,
  }) async {
    var res = await request(await _accessToken());
    if (res.statusCode == 401) {
      res = await request(await _accessToken(forceRefresh: true));
      if (res.statusCode == 401) throw const DriveAuthException();
    }
    if (allowNotFound && res.statusCode == 404) return res;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DriveRequestException(res.statusCode);
    }
    return res;
  }
}
