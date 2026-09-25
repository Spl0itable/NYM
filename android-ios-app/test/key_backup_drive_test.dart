import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/identity/key_backup/apple_keychain_backup_store.dart';
import 'package:nym_bar/features/identity/key_backup/drive_backup_client.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_store.dart';

const _uuid = '0f8fad5b-d9cb-469f-a165-70867728950e';

void main() {
  group('DriveBackupClient', () {
    late List<http.Request> requests;
    late List<bool> tokenCalls;

    DriveBackupClient client(
      Future<http.Response> Function(http.Request) handler, {
      List<String> tokens = const ['t1', 't2', 't3'],
    }) {
      requests = [];
      tokenCalls = [];
      var i = 0;
      return DriveBackupClient(
        client: MockClient((req) {
          requests.add(req);
          return handler(req);
        }),
        accessToken: ({bool forceRefresh = false}) async {
          tokenCalls.add(forceRefresh);
          if (forceRefresh) i++;
          return tokens[i];
        },
        newId: () => _uuid,
      );
    }

    test('list queries appDataFolder and keeps only backup names', () async {
      final c = client((_) async => http.Response(
          jsonEncode({
            'files': [
              {
                'id': 'a',
                'name': 'nym_bk_$_uuid.bin',
                'modifiedTime': '2026-01-02T03:04:05.000Z',
              },
              {'id': 'b', 'name': 'nym_bk_npub1abc.bin'},
              {'id': 'c', 'name': 'other.bin'},
              {'id': 'd', 'name': 'nym_bk_$_uuid.bin.bak'},
              {'id': 'e', 'name': 'nym_bk_${_uuid.toUpperCase()}.bin'},
            ],
          }),
          200));
      final files = await c.list();
      expect(files.map((f) => f.id), ['a']);
      expect(files.single.modifiedTime, DateTime.utc(2026, 1, 2, 3, 4, 5));
      final req = requests.single;
      expect(req.method, 'GET');
      expect(req.url.host, 'www.googleapis.com');
      expect(req.url.path, '/drive/v3/files');
      expect(req.url.queryParameters, {
        'spaces': 'appDataFolder',
        'q': "name contains 'nym_bk_'",
        'fields': 'files(id,name,modifiedTime)',
        'pageSize': '100',
      });
      expect(req.headers['Authorization'], 'Bearer t1');
    });

    test('list tolerates an empty or odd body', () async {
      final c = client((_) async => http.Response('{}', 200));
      expect(await c.list(), isEmpty);
    });

    test('download fetches the media of a file', () async {
      final c = client((_) async => http.Response('AgAA\n', 200));
      expect(await c.download('file 1'), 'AgAA');
      expect(requests.single.url.path, '/drive/v3/files/file%201');
      expect(requests.single.url.queryParameters, {'alt': 'media'});
    });

    test('upload posts a multipart body into appDataFolder', () async {
      final c = client((_) async =>
          http.Response(jsonEncode({'id': 'new', 'name': 'x'}), 200));
      final file = await c.upload('PAYLOAD');
      expect(file.id, 'new');
      expect(file.name, 'nym_bk_$_uuid.bin');
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/upload/drive/v3/files');
      expect(req.url.queryParameters, {'uploadType': 'multipart'});
      final type = req.headers['Content-Type']!;
      expect(type, startsWith('multipart/related; boundary='));
      final boundary = type.split('boundary=').last;
      final body = req.body;
      final parts = body.split('--$boundary');
      expect(parts.length, 4);
      expect(parts.last.trim(), '--');
      final meta = parts[1].split('\r\n\r\n');
      expect(meta.first, contains('application/json'));
      expect(jsonDecode(meta.last.trim()), {
        'name': 'nym_bk_$_uuid.bin',
        'parents': ['appDataFolder'],
      });
      final media = parts[2].split('\r\n\r\n');
      expect(media.first, contains('application/octet-stream'));
      expect(media.last, 'PAYLOAD\r\n');
      expect(body, isNot(contains('npub')));
    });

    test('delete sends DELETE and accepts 204 and 404', () async {
      final c = client((req) async =>
          http.Response('', req.url.path.endsWith('gone') ? 404 : 204));
      await c.delete('abc');
      await c.delete('gone');
      expect(requests.map((r) => r.method), ['DELETE', 'DELETE']);
      expect(requests.first.url.path, '/drive/v3/files/abc');
    });

    test('a 401 refreshes the token once and retries', () async {
      final c = client((req) async => req.headers['Authorization'] == 'Bearer t1'
          ? http.Response('', 401)
          : http.Response(jsonEncode({'files': []}), 200));
      expect(await c.list(), isEmpty);
      expect(tokenCalls, [false, true]);
      expect(requests.map((r) => r.headers['Authorization']),
          ['Bearer t1', 'Bearer t2']);
    });

    test('a second 401 gives up with DriveAuthException', () async {
      final c = client((_) async => http.Response('', 401));
      await expectLater(c.list(), throwsA(isA<DriveAuthException>()));
      expect(requests.length, 2);
    });

    test('other failures throw DriveRequestException', () async {
      final c = client((_) async => http.Response('', 500));
      await expectLater(
          c.download('x'),
          throwsA(isA<DriveRequestException>()
              .having((e) => e.statusCode, 'status', 500)));
      expect(requests.length, 1);
    });
  });

  group('AppleKeychainBackupStore', () {
    test('uses the shared synchronizable keychain options', () {
      final store = AppleKeychainBackupStore(accessGroup: 'TEAM.com.nym.shared');
      expect(store.options.toMap(), {
        'accessibility': 'first_unlock',
        'accountName': 'com.nym.apple-backup',
        'groupId': 'TEAM.com.nym.shared',
        'synchronizable': 'true',
      });
    });

    test('writes, lists only backup items and deletes', () async {
      FlutterSecureStorage.setMockInitialValues({'unrelated': 'x'});
      final store = AppleKeychainBackupStore(newId: () => _uuid);
      final account = await store.write('PAYLOAD');
      expect(account, 'nym_bk_$_uuid');
      expect(await store.readAll(), {'nym_bk_$_uuid': 'PAYLOAD'});
      await store.delete(account);
      expect(await store.readAll(), isEmpty);
    });
  });

  group('subFromIdToken', () {
    String jwt(Map<String, Object> claims) =>
        'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

    test('reads the sub claim', () {
      expect(subFromIdToken(jwt({'sub': '109876543210987654321'})),
          '109876543210987654321');
    });

    test('returns null for missing or malformed tokens', () {
      expect(subFromIdToken(null), isNull);
      expect(subFromIdToken('nope'), isNull);
      expect(subFromIdToken(jwt({'aud': 'x'})), isNull);
    });
  });
}
