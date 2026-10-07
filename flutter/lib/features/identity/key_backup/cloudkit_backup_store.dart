import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'key_backup_config.dart';
import 'key_backup_crypto.dart';

const String kCloudKitContainer = kAppleCloudKitContainer;
const String kCloudKitRecordType = 'KeyBackup';
const List<String> kCloudKitFields = <String>['payload', 'format', 'updatedAt'];

final RegExp kCloudKitRecordNamePattern = RegExp(
    r'^nymbk-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

String newCloudKitRecordName([String Function()? newId]) =>
    'nymbk-${(newId ?? () => const Uuid().v4())().toLowerCase()}';

class KeyBackupICloudUnavailable implements Exception {
  const KeyBackupICloudUnavailable(this.status);

  final String status;

  @override
  String toString() => 'KeyBackupICloudUnavailable($status)';
}

class KeyBackupICloudFull implements Exception {
  const KeyBackupICloudFull();
}

class CloudKitRecord {
  const CloudKitRecord({
    required this.recordName,
    required this.payload,
    required this.updatedAt,
  });

  final String recordName;
  final String payload;
  final int updatedAt;
}

class CloudKitBackupChannel {
  const CloudKitBackupChannel({this.container = kCloudKitContainer});

  static const MethodChannel channel =
      MethodChannel('app.nymchat/cloudkit_backup');

  static const Set<String> _unavailable = {
    'no_account',
    'restricted',
    'unavailable',
    'not_authenticated',
  };

  final String container;

  Future<T?> _call<T>(String method, [Map<String, Object?>? extra]) async {
    try {
      return await channel.invokeMethod<T>(
          method, <String, Object?>{'container': container, ...?extra});
    } on PlatformException catch (e) {
      if (_unavailable.contains(e.code)) {
        throw KeyBackupICloudUnavailable(e.code);
      }
      if (e.code == 'quota') throw const KeyBackupICloudFull();
      rethrow;
    }
  }

  Future<String> userRecordName() async {
    final name = await _call<String>('accountId');
    if (name == null || name.isEmpty) {
      throw const KeyBackupICloudUnavailable('no_user');
    }
    return name;
  }

  Future<List<CloudKitRecord>> query() async {
    final raw = await _call<List<Object?>>(
            'list', <String, Object?>{'recordType': kCloudKitRecordType}) ??
        const <Object?>[];
    final out = <CloudKitRecord>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['recordName'];
      final payload = item['payload'];
      final at = item['updatedAt'];
      if (name is! String || !kCloudKitRecordNamePattern.hasMatch(name)) {
        continue;
      }
      if (payload is! String || payload.isEmpty) continue;
      out.add(CloudKitRecord(
          recordName: name, payload: payload, updatedAt: at is int ? at : 0));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<void> save(String recordName, String payload) =>
      _call<void>('save', <String, Object?>{
        'recordType': kCloudKitRecordType,
        'recordName': recordName,
        'payload': payload,
        'format': kKeyBackupFormat,
      });

  Future<void> delete(String recordName) =>
      _call<void>('delete', <String, Object?>{'recordName': recordName});
}

const String kCloudKitSavedKey = 'nym_cloudkit_saved_records';

class CloudKitSavedRecords {
  static List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final v = jsonDecode(raw);
      if (v is List) {
        return [
          for (final x in v)
            if (x is String && x.startsWith('nymbk-')) x,
        ];
      }
    } catch (_) {}
    return const <String>[];
  }

  static Future<List<String>> all(SharedPreferences prefs) async {
    final keys = prefs
        .getKeys()
        .where((k) =>
            k.startsWith('nymacct:') && k.endsWith(':$kCloudKitSavedKey'))
        .toList()
      ..sort();
    final out = <String>[];
    for (final k in [kCloudKitSavedKey, ...keys]) {
      for (final name in _decode(prefs.getString(k))) {
        if (!out.contains(name)) out.add(name);
      }
    }
    return out;
  }

  static Future<void> add(SharedPreferences prefs, String name) async {
    final list = [..._decode(prefs.getString(kCloudKitSavedKey))];
    if (list.contains(name)) return;
    list.add(name);
    await prefs.setString(kCloudKitSavedKey, jsonEncode(list));
  }

  static Future<void> remove(SharedPreferences prefs, String name) async {
    final list = [..._decode(prefs.getString(kCloudKitSavedKey))]
      ..remove(name);
    if (list.isEmpty) {
      await prefs.remove(kCloudKitSavedKey);
    } else {
      await prefs.setString(kCloudKitSavedKey, jsonEncode(list));
    }
  }
}

Future<int> deleteSavedICloudBackups(
    SharedPreferences prefs, CloudKitBackupChannel channel) async {
  var n = 0;
  for (final name in await CloudKitSavedRecords.all(prefs)) {
    try {
      await channel.delete(name);
      n++;
    } catch (_) {}
  }
  return n;
}
