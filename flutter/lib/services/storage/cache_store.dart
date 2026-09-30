import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/constants/history_window.dart';
import '../../core/crypto/keys.dart' as keys;
import '../../models/message.dart';
import '../../models/user.dart';
import 'secure_store.dart';

/// SQLCipher-encrypted mirror of the PWA's IndexedDB `nym-cache`, with the same LRU limits and no app state.
class CacheStore {
  CacheStore({Database? db}) : _db = db;

  /// LRU caps per store (`STORE_LIMITS` in persistence.js).
  static const Map<String, int> storeLimits = {
    'profiles': 2000,
    'channels': 50,
    'pms': 100,
    'reactions': 5000,
    'avatars': 500,
    'banners': 200,
  };

  /// Per-record message caps matching what app.js actually assigns.
  static const int channelMessageLimit = 1000;
  static const int pmStorageLimit = 1000;

  /// Rolling window for public channel history.
  static const Duration channelHistoryMaxAge = kChannelHistoryMaxAge;

  /// `meta` store keys (persistence.js).
  static const String metaProcessedPmEventIds = 'processedPMEventIds';
  static const String metaDeletedEventIds = 'deletedEventIds';
  static const String metaNymchatPubkeys = 'nymchatPubkeys';
  static const String metaNymchatVouches = 'nymchatVouches';
  static const String metaTrustedPubkeys = 'trustedPubkeys';
  static const String metaPoolShardLastSeen = 'poolShardLastSeen';
  static const String metaEventTimeCeilings = 'eventTimeCeilings';
  static const String metaPqKeys = 'pqKeys';

  /// Past-verified event ids, restored at boot to skip signature checks; ids are content-bound, so this is safe.
  static const String metaVerifiedEventIds = 'verifiedEventIds';

  static const String _dbName = 'nym_cache.db';
  static const int _dbVersion = 2;

  /// Every logical store, plus the unbounded `meta` store.
  static const List<String> _allTables = [
    'meta',
    'profiles',
    'channels',
    'pms',
    'reactions',
    'avatars',
    'banners',
  ];

  Database? _db;

  /// Database file path for [panicWipe]; null for injected databases.
  String? _path;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('CacheStore.open() must be called before use');
    }
    return db;
  }

  bool get isOpen => _db != null;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// SecureStore key holding the SQLCipher passphrase for [_dbName].
  static const String _dbKeyName = 'nym_cache_db_key';

  /// SQLCipher passphrase from the keystore, minted as random 64-hex on first use; never leaves the device.
  Future<String> _databasePassword(SecureStore secure, String path) async {
    final existing = await secure.get(_dbKeyName);
    if (existing != null && existing.isNotEmpty) return existing;
    await dropUnreadable(path);
    final minted = keys.bytesToHex(keys.randomBytes(32));
    await secure.set(_dbKeyName, minted);
    return minted;
  }

  Future<void> dropUnreadable(String path) async {
    if (!await File(path).exists() || await _isPlaintextDb(path)) return;
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      try {
        final f = File('$path$suffix');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// True when [path] is plaintext SQLite (SQLCipher files have a random header).
  Future<bool> _isPlaintextDb(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final raf = await f.open();
      try {
        final header = await raf.read(16);
        return String.fromCharCodes(header).startsWith('SQLite format 3');
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Migrates a plaintext database to SQLCipher via `sqlcipher_export`; on failure the original is left intact.
  Future<void> _migratePlaintextIfNeeded(String path, String password) async {
    if (!await _isPlaintextDb(path)) return;
    final tmp = '$path.enc';
    try {
      final tmpFile = File(tmp);
      if (await tmpFile.exists()) await tmpFile.delete();
      final plain = await openDatabase(path);
      try {
        // The passphrase is 64 lowercase hex chars, so inlining it in the SQL literal is safe.
        await plain.rawQuery("ATTACH DATABASE '$tmp' AS enc KEY '$password'");
        await plain.rawQuery("SELECT sqlcipher_export('enc')");
        // sqlcipher_export skips user_version; carry it over so future upgrades see the real version.
        final ver = await plain.rawQuery('PRAGMA main.user_version');
        final v = (ver.isNotEmpty ? ver.first.values.first : 0) as int? ?? 0;
        await plain.rawQuery('PRAGMA enc.user_version = $v');
        await plain.rawQuery('DETACH DATABASE enc');
      } finally {
        await plain.close();
      }
      // Remove the plaintext original and its sidecars, which also hold plaintext pages.
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final side = File('$path$suffix');
        if (await side.exists()) await side.delete();
      }
      await File(tmp).rename(path);
    } catch (_) {
      try {
        final tmpFile = File(tmp);
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
    }
  }

  /// Opens the database: an injected one directly, else the app-documents file encrypted with SQLCipher.
  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _path = path;
    final password = await _databasePassword(SecureStore(), path);
    await _migratePlaintextIfNeeded(path, password);
    if (await _isPlaintextDb(path)) {
      // Migration failed: open the plaintext original; encryption retries next launch.
      _db = await openDatabase(
        path,
        version: _dbVersion,
        onCreate: (db, version) => _createSchema(db),
      );
      return;
    }
    _db = await openDatabase(
      path,
      password: password,
      version: _dbVersion,
      onCreate: (db, version) => _createSchema(db),
    );
  }

  /// Creates the schema on an open [Database], e.g. an in-memory test DB.
  Future<void> initSchema() async {
    await _createSchema(_database);
  }

  Future<void> _createSchema(Database db) async {
    // meta(key PK, json)
    await db.execute(
      'CREATE TABLE IF NOT EXISTS meta ('
      'key TEXT PRIMARY KEY, '
      'json TEXT NOT NULL)',
    );
    // profiles(pubkey PK, json, kind0Ts, lastTouched)
    await db.execute(
      'CREATE TABLE IF NOT EXISTS profiles ('
      'pubkey TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'kind0Ts INTEGER, '
      'lastTouched INTEGER NOT NULL)',
    );
    // channels(key PK, json messages array, lastTouched)
    await db.execute(
      'CREATE TABLE IF NOT EXISTS channels ('
      'key TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'lastTouched INTEGER NOT NULL)',
    );
    // pms(key PK, json, lastTouched), only written when caching is enabled
    await db.execute(
      'CREATE TABLE IF NOT EXISTS pms ('
      'key TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'lastTouched INTEGER NOT NULL)',
    );
    // reactions(messageId PK, json, lastTouched)
    await db.execute(
      'CREATE TABLE IF NOT EXISTS reactions ('
      'messageId TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'lastTouched INTEGER NOT NULL)',
    );
    // avatars(pubkey PK, bytes, sourceUrl, kind0Ts, lastTouched)
    await db.execute(
      'CREATE TABLE IF NOT EXISTS avatars ('
      'pubkey TEXT PRIMARY KEY, '
      'bytes BLOB, '
      'sourceUrl TEXT, '
      'kind0Ts INTEGER, '
      'lastTouched INTEGER NOT NULL)',
    );
    // banners(pubkey PK, bytes, sourceUrl, kind0Ts, lastTouched)
    await db.execute(
      'CREATE TABLE IF NOT EXISTS banners ('
      'pubkey TEXT PRIMARY KEY, '
      'bytes BLOB, '
      'sourceUrl TEXT, '
      'kind0Ts INTEGER, '
      'lastTouched INTEGER NOT NULL)',
    );
  }

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }

  // Channel messages

  /// Drops aged-out channel messages, then pins back thread roots the survivors reply to.
  static List<Message> _withinChannelWindow(List<Message> messages) {
    if (messages.isEmpty) return messages;
    final floor = channelWindowFloorSec();
    if (!messages.any((m) => m.createdAt < floor)) return messages;
    final kept = messages.where((m) => m.createdAt >= floor).toList();
    return _withPinnedThreadRoots(messages, kept, (m) => m.id);
  }

  /// Pins referenced thread roots in front of the last-N slice so replies can still re-thread after reload.
  static List<Message> _withPinnedThreadRoots(
    List<Message> messages,
    List<Message> trimmed,
    String Function(Message) keyOf,
  ) {
    if (identical(trimmed, messages)) return trimmed;
    final kept = <String>{for (final m in trimmed) keyOf(m)};
    final wanted = <String>{};
    for (final m in trimmed) {
      final root = m.threadRoot;
      if (root != null && root.isNotEmpty && !kept.contains(root)) {
        wanted.add(root);
      }
    }
    if (wanted.isEmpty) return trimmed;
    final pinned = <Message>[];
    for (final m in messages) {
      if (wanted.remove(keyOf(m))) pinned.add(m);
    }
    return pinned.isEmpty ? trimmed : [...pinned, ...trimmed];
  }

  /// Persists the last [channelMessageLimit] messages; an empty list deletes the record.
  Future<void> saveChannelMessages(String key, List<Message> msgs,
      [DatabaseExecutor? executor]) async {
    if (key.isEmpty) return;
    final db = executor ?? _database;
    if (msgs.isEmpty) {
      await db.delete('channels', where: 'key = ?', whereArgs: [key]);
      return;
    }
    // Age first, then the count cap.
    final inWindow = _withinChannelWindow(msgs);
    if (inWindow.isEmpty) {
      await db.delete('channels', where: 'key = ?', whereArgs: [key]);
      return;
    }
    var trimmed = inWindow.length > channelMessageLimit
        ? inWindow.sublist(inWindow.length - channelMessageLimit)
        : inWindow;
    // Channel thread keys are event ids.
    trimmed = _withPinnedThreadRoots(inWindow, trimmed, (m) => m.id);
    final json = jsonEncode(trimmed.map((m) => m.toJson()).toList());
    await db.insert(
      'channels',
      {'key': key, 'json': json, 'lastTouched': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Message>> loadChannelMessages(String key) async {
    final rows = await _database.query(
      'channels',
      columns: ['json'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return [];
    return _withinChannelWindow(_decodeMessages(rows.first['json'] as String?));
  }

  /// Deletes cached reactions targeting [messageIds], which only channel messages use.
  Future<void> deleteReactionsFor(Iterable<String> messageIds) async {
    final ids = messageIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return;
    for (var i = 0; i < ids.length; i += 200) {
      final end = i + 200 < ids.length ? i + 200 : ids.length;
      final chunk = ids.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _database.delete('reactions',
          where: 'messageId IN ($placeholders)', whereArgs: chunk);
    }
  }

  /// Loads every cached channel history by storage key; empty or corrupt records are skipped.
  Future<Map<String, List<Message>>> loadAllChannelMessages() async {
    final all = await _loadAllMessages('channels');
    // Drop aged-out history on load; rows that empty out are deleted.
    final drop = <String>[];
    all.updateAll((key, msgs) {
      final kept = _withinChannelWindow(msgs);
      if (kept.isEmpty) drop.add(key);
      return kept;
    });
    for (final key in drop) {
      all.remove(key);
      await _database.delete('channels', where: 'key = ?', whereArgs: [key]);
    }
    return all;
  }

  // PM / group messages

  /// Persists the last [pmStorageLimit] messages only when [enabled]; an empty list deletes the record.
  Future<void> savePmMessages(
    String key,
    List<Message> msgs, {
    required bool enabled,
    DatabaseExecutor? executor,
  }) async {
    if (!enabled) return;
    if (key.isEmpty) return;
    final db = executor ?? _database;
    if (msgs.isEmpty) {
      await db.delete('pms', where: 'key = ?', whereArgs: [key]);
      return;
    }
    var trimmed = msgs.length > pmStorageLimit
        ? msgs.sublist(msgs.length - pmStorageLimit)
        : msgs;
    // PM/group thread keys are the shared nymMessageId when present.
    trimmed = _withPinnedThreadRoots(msgs, trimmed, (m) => m.nymMessageId ?? m.id);
    final json = jsonEncode(trimmed.map((m) => m.toJson()).toList());
    await db.insert(
      'pms',
      {'key': key, 'json': json, 'lastTouched': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Message>> loadPmMessages(String key) async {
    final rows = await _database.query(
      'pms',
      columns: ['json'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return [];
    return _decodeMessages(rows.first['json'] as String?);
  }

  /// Loads every cached PM/group conversation; callers gate this on `settings.cachePMs`.
  Future<Map<String, List<Message>>> loadAllPmMessages() =>
      _loadAllMessages('pms');

  Future<Map<String, List<Message>>> _loadAllMessages(String table) async {
    final rows = await _database.query(table, columns: ['key', 'json']);
    // Decode off the main isolate so heavy hydration neither janks the UI nor loses the boot race.
    final raw = <String, String>{};
    for (final r in rows) {
      final key = r['key'] as String?;
      final json = r['json'] as String?;
      if (key == null || key.isEmpty || json == null || json.isEmpty) continue;
      raw[key] = json;
    }
    if (raw.isEmpty) return {};
    return compute(decodeMessageStores, raw);
  }

  /// Wipes the `pms` table when PM caching is disabled.
  Future<void> clearPms() async {
    await _database.delete('pms');
  }

  List<Message> _decodeMessages(String? json) {
    if (json == null || json.isEmpty) return [];
    final decoded = jsonDecode(json);
    if (decoded is! List) return [];
    final out = <Message>[];
    for (final e in decoded) {
      if (e is Map) {
        // Anything restored from cache is backlog, so mark it historical.
        out.add(
            Message.fromJson(e.cast<String, dynamic>())..isHistorical = true);
      }
    }
    return out;
  }

  /// `compute` entry that decodes every conversation's JSON; a corrupt row is skipped, not fatal.
  static Map<String, List<Message>> decodeMessageStores(
      Map<String, String> raw) {
    final out = <String, List<Message>>{};
    raw.forEach((key, json) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is! List) return;
        final msgs = <Message>[
          for (final e in decoded)
            if (e is Map)
              Message.fromJson(e.cast<String, dynamic>())..isHistorical = true,
        ];
        if (msgs.isNotEmpty) out[key] = msgs;
      } catch (_) {
        // Skip the corrupt record.
      }
    });
    return out;
  }

  // Profiles

  /// Persists a kind-0 profile with its `kind0Ts`; stamps `lastTouched`.
  Future<void> saveProfile(String pubkey, UserProfile profile,
      [DatabaseExecutor? executor]) async {
    if (pubkey.isEmpty) return;
    final map = profile.toJson();
    // Keep kind0Ts inside the JSON too, independent of toJson().
    map['kind0Ts'] = profile.kind0Ts;
    await (executor ?? _database).insert(
      'profiles',
      {
        'pubkey': pubkey,
        'json': jsonEncode(map),
        'kind0Ts': profile.kind0Ts,
        'lastTouched': _now(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<UserProfile?> loadProfile(String pubkey) async {
    final rows = await _database.query(
      'profiles',
      columns: ['json', 'kind0Ts'],
      where: 'pubkey = ?',
      whereArgs: [pubkey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeProfile(rows.first);
  }

  Future<Map<String, UserProfile>> loadAllProfiles() async {
    final rows = await _database.query(
      'profiles',
      columns: ['pubkey', 'json', 'kind0Ts'],
    );
    final out = <String, UserProfile>{};
    for (final r in rows) {
      final pubkey = r['pubkey'] as String?;
      if (pubkey == null) continue;
      final profile = _decodeProfile(r);
      if (profile != null) out[pubkey] = profile;
    }
    return out;
  }

  UserProfile? _decodeProfile(Map<String, Object?> row) {
    final json = row['json'] as String?;
    if (json == null || json.isEmpty) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();
    final kind0Ts =
        (row['kind0Ts'] as int?) ?? (map['kind0Ts'] as num?)?.toInt() ?? 0;
    return UserProfile.fromJson(map, kind0Ts: kind0Ts);
  }

  // Avatars / banners

  Future<void> saveAvatar(
    String pubkey,
    Uint8List bytes, {
    String? sourceUrl,
    int? kind0Ts,
  }) =>
      _saveBlob('avatars', pubkey, bytes, sourceUrl, kind0Ts);

  Future<void> saveBanner(
    String pubkey,
    Uint8List bytes, {
    String? sourceUrl,
    int? kind0Ts,
  }) =>
      _saveBlob('banners', pubkey, bytes, sourceUrl, kind0Ts);

  Future<void> _saveBlob(
    String table,
    String pubkey,
    Uint8List bytes,
    String? sourceUrl,
    int? kind0Ts,
  ) async {
    if (pubkey.isEmpty) return;
    await _database.insert(
      table,
      {
        'pubkey': pubkey,
        'bytes': bytes,
        'sourceUrl': sourceUrl,
        'kind0Ts': kind0Ts,
        'lastTouched': _now(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<CachedBlob?> loadAvatar(String pubkey) => _loadBlob('avatars', pubkey);

  Future<CachedBlob?> loadBanner(String pubkey) => _loadBlob('banners', pubkey);

  Future<CachedBlob?> _loadBlob(String table, String pubkey) async {
    final rows = await _database.query(
      table,
      columns: ['bytes', 'sourceUrl', 'kind0Ts'],
      where: 'pubkey = ?',
      whereArgs: [pubkey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final bytes = r['bytes'];
    if (bytes is! Uint8List) return null;
    return CachedBlob(
      bytes: bytes,
      sourceUrl: r['sourceUrl'] as String?,
      kind0Ts: r['kind0Ts'] as int?,
    );
  }

  Future<void> deleteAvatar(String pubkey) async {
    await _database.delete('avatars', where: 'pubkey = ?', whereArgs: [pubkey]);
  }

  Future<void> deleteBanner(String pubkey) async {
    await _database.delete('banners', where: 'pubkey = ?', whereArgs: [pubkey]);
  }

  // Reactions

  /// Persists `[[emoji, [[reactor, value], ...]], ...]` for [messageId]; an empty list deletes it.
  Future<void> saveReactions(String messageId, List<dynamic> entries,
      [DatabaseExecutor? executor]) async {
    if (messageId.isEmpty) return;
    final db = executor ?? _database;
    if (entries.isEmpty) {
      await db
          .delete('reactions', where: 'messageId = ?', whereArgs: [messageId]);
      return;
    }
    await db.insert(
      'reactions',
      {
        'messageId': messageId,
        'json': jsonEncode(entries),
        'lastTouched': _now(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Pre-encoded flush path: JSON is built off-isolate by [encodeCacheFlush], then written here.

  /// Writes a pre-encoded channel row; an empty array deletes it.
  Future<void> saveChannelMessagesJson(String key, String json,
      [DatabaseExecutor? executor]) async {
    if (key.isEmpty) return;
    final db = executor ?? _database;
    if (json.isEmpty || json == '[]') {
      await db.delete('channels', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert(
      'channels',
      {'key': key, 'json': json, 'lastTouched': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The `pms` counterpart; callers gate on `settings.cachePMs`.
  Future<void> savePmMessagesJson(String key, String json,
      [DatabaseExecutor? executor]) async {
    if (key.isEmpty) return;
    final db = executor ?? _database;
    if (json.isEmpty || json == '[]') {
      await db.delete('pms', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert(
      'pms',
      {'key': key, 'json': json, 'lastTouched': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// [saveProfile] with pre-encoded JSON that already embeds kind0Ts.
  Future<void> saveProfileJson(String pubkey, String json, int kind0Ts,
      [DatabaseExecutor? executor]) async {
    if (pubkey.isEmpty) return;
    await (executor ?? _database).insert(
      'profiles',
      {
        'pubkey': pubkey,
        'json': json,
        'kind0Ts': kind0Ts,
        'lastTouched': _now(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// [saveReactions] with pre-encoded entries; `[]` deletes the row.
  Future<void> saveReactionsJson(String messageId, String json,
      [DatabaseExecutor? executor]) async {
    if (messageId.isEmpty) return;
    final db = executor ?? _database;
    if (json.isEmpty || json == '[]') {
      await db
          .delete('reactions', where: 'messageId = ?', whereArgs: [messageId]);
      return;
    }
    await db.insert(
      'reactions',
      {'messageId': messageId, 'json': json, 'lastTouched': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Runs [body] in one SQLite transaction so a flush doesn't hold the lock for many inserts.
  Future<void> runInTransaction(
    Future<void> Function(DatabaseExecutor txn) body,
  ) async {
    await _database.transaction((txn) async => body(txn));
  }

  /// All reaction records by messageId, as decoded `entries` lists.
  Future<Map<String, List<dynamic>>> loadAllReactions() async {
    final rows = await _database.query(
      'reactions',
      columns: ['messageId', 'json'],
    );
    final out = <String, List<dynamic>>{};
    for (final r in rows) {
      final id = r['messageId'] as String?;
      final json = r['json'] as String?;
      if (id == null || json == null) continue;
      final decoded = jsonDecode(json);
      if (decoded is List) out[id] = decoded;
    }
    return out;
  }

  // Meta sets / maps

  /// Persists a dedup set as `{ids: [...]}`; an empty set deletes it.
  Future<void> saveMetaSet(String key, Set<String> ids) async {
    if (key.isEmpty) return;
    if (ids.isEmpty) {
      await _database.delete('meta', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _database.insert(
      'meta',
      {
        'key': key,
        'json': jsonEncode({'ids': ids.toList()}),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Set<String>> loadMetaSet(String key) async {
    final rows = await _database.query(
      'meta',
      columns: ['json'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return <String>{};
    final json = rows.first['json'] as String?;
    if (json == null || json.isEmpty) return <String>{};
    final decoded = jsonDecode(json);
    if (decoded is! Map) return <String>{};
    final ids = decoded['ids'];
    if (ids is! List) return <String>{};
    return ids.whereType<String>().toSet();
  }

  /// Persists a meta map as `{map: {...}}`; an empty map deletes it.
  Future<void> saveMetaMap(String key, Map<String, dynamic> map) async {
    if (key.isEmpty) return;
    if (map.isEmpty) {
      await _database.delete('meta', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _database.insert(
      'meta',
      {
        'key': key,
        'json': jsonEncode({'map': map}),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>> loadMetaMap(String key) async {
    final rows = await _database.query(
      'meta',
      columns: ['json'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return {};
    final json = rows.first['json'] as String?;
    if (json == null || json.isEmpty) return {};
    final decoded = jsonDecode(json);
    if (decoded is! Map) return {};
    final map = decoded['map'];
    if (map is! Map) return {};
    return map.cast<String, dynamic>();
  }

  // LRU enforcement

  /// Evicts oldest-`lastTouched` rows down to `floor(limit * 0.9)` per store; `meta` is unbounded, no time expiry.
  Future<void> enforceLruLimits() async {
    for (final entry in storeLimits.entries) {
      await _trimStore(entry.key, entry.value);
    }
  }

  Future<void> _trimStore(String table, int limit) async {
    final keyColumn = _keyColumnFor(table);
    final countRows =
        await _database.rawQuery('SELECT COUNT(*) AS c FROM $table');
    final count = (countRows.first['c'] as int?) ?? 0;
    if (count <= limit) return;

    final target = (limit * 0.9).floor();
    final evictCount = count - target;

    // Oldest first; rowid breaks ties deterministically.
    final victims = await _database.query(
      table,
      columns: [keyColumn],
      orderBy: 'lastTouched ASC, rowid ASC',
      limit: evictCount,
    );
    if (victims.isEmpty) return;
    final keys = victims.map((r) => r[keyColumn]).toList();
    final placeholders = List.filled(keys.length, '?').join(',');
    await _database.delete(
      table,
      where: '$keyColumn IN ($placeholders)',
      whereArgs: keys,
    );
  }

  String _keyColumnFor(String table) {
    switch (table) {
      case 'profiles':
      case 'avatars':
      case 'banners':
        return 'pubkey';
      case 'reactions':
        return 'messageId';
      default:
        return 'key'; // channels, pms, meta
    }
  }

  /// Wipes every cache table (logout).
  Future<void> resetCache() async {
    for (final table in _allTables) {
      await _database.delete(table);
    }
  }

  /// Panic wipe: junk-overwrite and clear every store, then delete the file; each step best-effort.
  Future<void> panicWipe() async {
    final db = _db;
    if (db != null) {
      final rng = Random.secure();
      for (final table in _allTables) {
        try {
          final keyColumn = _keyColumnFor(table);
          // 3 junk records per store, as the PWA does.
          for (var i = 0; i < 3; i++) {
            final record = <String, Object?>{keyColumn: '__panic_$i'};
            if (table == 'avatars' || table == 'banners') {
              record['bytes'] = Uint8List.fromList(
                List<int>.generate(2048, (_) => rng.nextInt(256)),
              );
            } else {
              record['json'] = base64Encode(
                List<int>.generate(2048, (_) => rng.nextInt(256)),
              );
            }
            if (table != 'meta') record['lastTouched'] = _now();
            await db.insert(
              table,
              record,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await db.delete(table);
        } catch (_) {}
      }
    }
    try {
      await close();
    } catch (_) {}
    final path = _path;
    if (path != null) {
      try {
        await deleteDatabase(path);
      } catch (_) {}
    }
  }

  /// "Clear cache": deletes cached content but keeps `meta` dedup/trust sets, then vacuums.
  Future<void> wipe() async {
    for (final table in const [
      'channels',
      'pms',
      'profiles',
      'reactions',
      'avatars',
      'banners',
    ]) {
      await _database.delete(table);
    }
    // Reclaim freed pages; VACUUM can't run in a transaction, and the deletes auto-committed.
    try {
      await _database.execute('VACUUM');
    } catch (_) {
      // VACUUM is best-effort; the rows are already gone.
    }
  }

  /// On-disk size via `page_count * page_size`; works for in-memory DBs; 0 if unavailable.
  Future<int> totalBytes() async {
    try {
      final pageCountRows = await _database.rawQuery('PRAGMA page_count');
      final pageSizeRows = await _database.rawQuery('PRAGMA page_size');
      final pageCount = _firstInt(pageCountRows);
      final pageSize = _firstInt(pageSizeRows);
      return pageCount * pageSize;
    } catch (_) {
      return 0;
    }
  }

  static int _firstInt(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return 0;
    final v = rows.first.values.first;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}

class CachedBlob {
  const CachedBlob({required this.bytes, this.sourceUrl, this.kind0Ts});

  final Uint8List bytes;
  final String? sourceUrl;
  final int? kind0Ts;
}

/// One cache flush's input, sent to a worker isolate for encoding.
class CacheFlushPayload {
  const CacheFlushPayload({
    this.channels = const {},
    this.pms = const {},
    this.profiles = const {},
    this.reactions = const {},
  });

  /// Storage key to filtered, capped messages.
  final Map<String, List<Message>> channels;
  final Map<String, List<Message>> pms;

  /// Pubkey to profile, only those changed since the last flush.
  final Map<String, UserProfile> profiles;

  /// Message id to reaction entries snapshot.
  final Map<String, List<dynamic>> reactions;
}

/// Finished JSON strings per row for the `save*Json` writers.
class EncodedCacheFlush {
  const EncodedCacheFlush({
    required this.channels,
    required this.pms,
    required this.profiles,
    required this.profileKind0Ts,
    required this.reactions,
  });

  final Map<String, String> channels;
  final Map<String, String> pms;
  final Map<String, String> profiles;
  final Map<String, int> profileKind0Ts;
  final Map<String, String> reactions;
}

/// `compute` entry that encodes a flush exactly as the inline save* methods would.
EncodedCacheFlush encodeCacheFlush(CacheFlushPayload p) {
  final channels = <String, String>{};
  p.channels.forEach((key, msgs) {
    channels[key] = jsonEncode([for (final m in msgs) m.toJson()]);
  });
  final pms = <String, String>{};
  p.pms.forEach((key, msgs) {
    pms[key] = jsonEncode([for (final m in msgs) m.toJson()]);
  });
  final profiles = <String, String>{};
  final kind0Ts = <String, int>{};
  p.profiles.forEach((pubkey, profile) {
    final map = profile.toJson();
    map['kind0Ts'] = profile.kind0Ts;
    profiles[pubkey] = jsonEncode(map);
    kind0Ts[pubkey] = profile.kind0Ts;
  });
  final reactions = <String, String>{};
  p.reactions.forEach((id, entries) {
    reactions[id] = jsonEncode(entries);
  });
  return EncodedCacheFlush(
    channels: channels,
    pms: pms,
    profiles: profiles,
    profileKind0Ts: kind0Ts,
    reactions: reactions,
  );
}
