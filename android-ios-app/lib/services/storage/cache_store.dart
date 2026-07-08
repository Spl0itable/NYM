import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/message.dart';
import '../../models/user.dart';

/// sqflite-backed mirror of the PWA's IndexedDB `nym-cache` (v2) store
/// (`js/modules/persistence.js`, docs/specs/01 §5.1).
///
/// This is a thin, well-documented data layer: it persists and reloads cached
/// channel/PM messages, profiles, reactions and dedup/meta sets, enforcing the
/// same LRU limits as the PWA. It holds **no app state** — integration into the
/// controller is done elsewhere.
///
/// Fidelity notes (mirrored from persistence.js):
/// - Same logical stores: meta / profiles / channels / pms / reactions /
///   avatars / banners. (Here as SQLite tables of the same names.)
/// - `STORE_LIMITS` — profiles 2000, channels 50, pms 100, reactions 5000,
///   avatars 500, banners 200. Eviction trims to ~90% (`floor(limit*0.9)`) once
///   a store exceeds its limit, oldest `lastTouched` first. **No time expiry.**
/// - Per-record message caps: channels keep the last `channelMessageLimit||100`
///   messages, pms keep the last `pmStorageLimit||500`.
/// - PMs are **only** persisted when caching is enabled
///   (`settings.cachePMs`); when disabled, `savePmMessages` is a no-op (and the
///   `pms` table can be cleared via [clearPms]).
/// - Message cache is **not** encrypted at rest (matches the PWA; the only
///   privacy control is the cachePMs opt-out).
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

  /// Per-record message cap fallbacks used when persisting (persistence.js
  /// `this.channelMessageLimit || 100` / `this.pmStorageLimit || 500`).
  static const int channelMessageLimit = 100;
  static const int pmStorageLimit = 500;

  /// `meta` store key constants (persistence.js).
  static const String metaProcessedPmEventIds = 'processedPMEventIds';
  static const String metaDeletedEventIds = 'deletedEventIds';
  static const String metaNymchatPubkeys = 'nymchatPubkeys';
  static const String metaNymchatVouches = 'nymchatVouches';
  static const String metaTrustedPubkeys = 'trustedPubkeys';
  static const String metaPoolShardLastSeen = 'poolShardLastSeen';

  static const String _dbName = 'nym_cache.db';
  static const int _dbVersion = 2;

  /// Every logical store, mirroring persistence.js `STORES` + the unbounded
  /// `meta` store.
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

  /// On-disk path recorded by [open] so [panicWipe] can delete the database
  /// FILE itself. Null for injected (test/in-memory) databases.
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

  /// Open (and create/migrate) the cache database. If a [Database] was injected
  /// via the constructor (e.g. an in-memory DB in tests) it is used directly,
  /// otherwise the on-device app-documents path is used.
  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _path = path;
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) => _createSchema(db),
    );
  }

  /// Initialise the schema on an already-open [Database]. Useful for tests that
  /// open an in-memory database through sqflite_common_ffi and pass it in.
  Future<void> initSchema() async {
    await _createSchema(_database);
  }

  Future<void> _createSchema(Database db) async {
    // meta(key PK, json) — sets like processedPMEventIds/deletedEventIds and the
    // poolShardLastSeen map.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS meta ('
      'key TEXT PRIMARY KEY, '
      'json TEXT NOT NULL)',
    );
    // profiles(pubkey PK, json, kind0Ts, lastTouched).
    await db.execute(
      'CREATE TABLE IF NOT EXISTS profiles ('
      'pubkey TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'kind0Ts INTEGER, '
      'lastTouched INTEGER NOT NULL)',
    );
    // channels(key PK, json /*messages array*/, lastTouched).
    await db.execute(
      'CREATE TABLE IF NOT EXISTS channels ('
      'key TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'lastTouched INTEGER NOT NULL)',
    );
    // pms(key PK, json, lastTouched) — only written when caching enabled.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS pms ('
      'key TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'lastTouched INTEGER NOT NULL)',
    );
    // reactions(messageId PK, json, lastTouched).
    await db.execute(
      'CREATE TABLE IF NOT EXISTS reactions ('
      'messageId TEXT PRIMARY KEY, '
      'json TEXT NOT NULL, '
      'lastTouched INTEGER NOT NULL)',
    );
    // avatars(pubkey PK, bytes, sourceUrl, kind0Ts, lastTouched).
    await db.execute(
      'CREATE TABLE IF NOT EXISTS avatars ('
      'pubkey TEXT PRIMARY KEY, '
      'bytes BLOB, '
      'sourceUrl TEXT, '
      'kind0Ts INTEGER, '
      'lastTouched INTEGER NOT NULL)',
    );
    // banners(pubkey PK, bytes, sourceUrl, kind0Ts, lastTouched).
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

  // ---------------------------------------------------------------------------
  // Channel messages
  // ---------------------------------------------------------------------------

  /// Persist a channel's messages, keeping only the last [channelMessageLimit]
  /// (mirrors `persistChannelMessages`: `messages.slice(-limit)`). Stamps
  /// `lastTouched`. An empty list deletes the record, as in the PWA.
  Future<void> saveChannelMessages(String key, List<Message> msgs,
      [DatabaseExecutor? executor]) async {
    if (key.isEmpty) return;
    final db = executor ?? _database;
    if (msgs.isEmpty) {
      await db.delete('channels', where: 'key = ?', whereArgs: [key]);
      return;
    }
    final trimmed = msgs.length > channelMessageLimit
        ? msgs.sublist(msgs.length - channelMessageLimit)
        : msgs;
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
    return _decodeMessages(rows.first['json'] as String?);
  }

  /// Load EVERY cached channel history, keyed by storage key — the boot
  /// hydration read (persistence.js `hydrateFromCache` getAll over the
  /// `channels` store, :427-433). Empty/corrupt records are skipped.
  Future<Map<String, List<Message>>> loadAllChannelMessages() =>
      _loadAllMessages('channels');

  // ---------------------------------------------------------------------------
  // PM / group messages (only persisted when caching enabled)
  // ---------------------------------------------------------------------------

  /// Persist a PM/group conversation's messages — **only when [enabled]**
  /// (`settings.cachePMs`). When disabled this is a no-op, mirroring
  /// `persistPMMessages`'s `if (settings.cachePMs === false) return;`.
  /// Keeps the last [pmStorageLimit] messages; empty list deletes the record.
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
    final trimmed = msgs.length > pmStorageLimit
        ? msgs.sublist(msgs.length - pmStorageLimit)
        : msgs;
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

  /// Load EVERY cached PM/group conversation, keyed by storage key — the boot
  /// hydration read (persistence.js `hydrateFromCache` getAll over the `pms`
  /// store, :455-461). The caller gates this on `settings.cachePMs` the way
  /// the PWA does (`cachePMsAllowed`); disabled → it calls [clearPms] instead.
  Future<Map<String, List<Message>>> loadAllPmMessages() =>
      _loadAllMessages('pms');

  Future<Map<String, List<Message>>> _loadAllMessages(String table) async {
    final rows = await _database.query(table, columns: ['key', 'json']);
    final out = <String, List<Message>>{};
    for (final r in rows) {
      final key = r['key'] as String?;
      if (key == null || key.isEmpty) continue;
      final List<Message> msgs;
      try {
        msgs = _decodeMessages(r['json'] as String?);
      } catch (_) {
        continue; // One corrupt record must not abort the whole hydration.
      }
      if (msgs.isNotEmpty) out[key] = msgs;
    }
    return out;
  }

  /// Wipe the `pms` table (`clearPMCache`). Used when the user disables PM
  /// caching.
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
        // Anything restored from the on-disk cache is BACKLOG by provenance, no
        // matter what timestamp it carries — mark it historical so it is never
        // flood-dimmed or snap-in animated on rehydrate (matches the PWA restore
        // path; a live message that was cached and reloaded is no longer "live").
        out.add(Message.fromJson(e.cast<String, dynamic>())..isHistorical = true);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Profiles
  // ---------------------------------------------------------------------------

  /// Persist a kind-0 [UserProfile] keyed by pubkey, recording its `kind0Ts`
  /// alongside (mirrors `persistProfile`'s enriched snapshot). Stamps
  /// `lastTouched`.
  Future<void> saveProfile(String pubkey, UserProfile profile,
      [DatabaseExecutor? executor]) async {
    if (pubkey.isEmpty) return;
    final map = profile.toJson();
    // Persist kind0Ts inside the JSON too so it survives the round-trip even if
    // toJson() (which omits it today) ever changes.
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

  /// Load every cached profile, keyed by pubkey.
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
    final kind0Ts = (row['kind0Ts'] as int?) ??
        (map['kind0Ts'] as num?)?.toInt() ??
        0;
    return UserProfile.fromJson(map, kind0Ts: kind0Ts);
  }

  // ---------------------------------------------------------------------------
  // Avatars / banners (raw bytes keyed by pubkey)
  // ---------------------------------------------------------------------------

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

  /// A cached avatar/banner blob record.
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

  // ---------------------------------------------------------------------------
  // Reactions
  // ---------------------------------------------------------------------------

  /// Persist a reaction record keyed by [messageId]. [entries] mirrors the
  /// PWA's `entries` shape: `[[emoji, [[reactor, value], ...]], ...]`. An empty
  /// list deletes the record (`persistReactions`).
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

  /// Runs [body] inside a single SQLite transaction, passing the transaction
  /// executor to thread into the `save*` methods. The whole flush thus commits
  /// as ONE transaction instead of hundreds of individually-locked inserts —
  /// which is what was tripping sqflite's "database locked for 10s" warning when
  /// a busy channel re-persisted every profile/reaction on each 6s flush.
  Future<void> runInTransaction(
    Future<void> Function(DatabaseExecutor txn) body,
  ) async {
    await _database.transaction((txn) async => body(txn));
  }

  /// Load all reaction records, keyed by messageId. Each value is the decoded
  /// `entries` list (`[[emoji, [[reactor, value], ...]], ...]`).
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

  // ---------------------------------------------------------------------------
  // Meta sets / maps
  // ---------------------------------------------------------------------------

  /// Persist a dedup set under [key] as `{ids: [...]}` (mirrors the meta store's
  /// `{key, ids}` record). An empty set deletes the record.
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

  /// Persist a meta map under [key] as `{map: {...}}` (the `poolShardLastSeen`
  /// shape). An empty map deletes the record.
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

  // ---------------------------------------------------------------------------
  // LRU enforcement
  // ---------------------------------------------------------------------------

  /// Evict oldest-by-`lastTouched` records from each store that exceeds its
  /// [storeLimits] cap, trimming down to `floor(limit * 0.9)` (mirrors
  /// `_trimStore`/`_trimAllStores`). The `meta` store is unbounded, as in the
  /// PWA. **No time expiry.**
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

    // Oldest first (matches the PWA's ascending lastTouched sort + slice).
    // rowid breaks ties so eviction stays deterministic when several records
    // share a lastTouched millisecond.
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

  /// Wipe every cache table (`resetCache` — logout / nuke).
  Future<void> resetCache() async {
    for (final table in _allTables) {
      await _database.delete(table);
    }
  }

  /// EMERGENCY destruction for the panic wipe (panic.js `_panicWipeDb`,
  /// :237-277): overwrite a few junk records into every store, clear the
  /// stores, then close the connection and delete the database FILE itself —
  /// the sqflite analogue of the PWA's junk `put`s + `indexedDB.deleteDatabase`.
  /// Every step is best-effort and isolated so a locked table can't block the
  /// wipe. Injected (test/in-memory) databases have no file; for those the
  /// junk-overwrite + clear + close is the whole wipe.
  Future<void> panicWipe() async {
    final db = _db;
    if (db != null) {
      final rng = Random.secure();
      for (final table in _allTables) {
        try {
          final keyColumn = _keyColumnFor(table);
          // 3 junk records per store, like the PWA's `__panic_<i>` puts.
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

  /// Clears all cached **content** — channels / PMs / profiles / reactions
  /// (plus their avatar/banner blobs) — leaving only the `meta` dedup/trust sets
  /// intact, then reclaims the freed pages. This is the "Clear cache" data
  /// control (settings.js `clearMessageCache`): a user wiping cached
  /// conversations + profiles, NOT a full identity logout (which uses
  /// [resetCache]). `meta` is preserved so processed-event dedup and the trust
  /// roster survive the wipe (mirrors the PWA, which keeps the meta store when
  /// clearing the message cache).
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
    // Reclaim the pages the deleted rows held so the reported on-disk size drops
    // (SQLite keeps freed pages by default). VACUUM can't run inside a txn; the
    // deletes above are auto-committed, so this is safe.
    try {
      await _database.execute('VACUUM');
    } catch (_) {
      // VACUUM is best-effort (e.g. an in-memory DB or an open cursor); the rows
      // are already gone regardless.
    }
  }

  /// The real on-disk size of the cache database in bytes (settings.js
  /// `estimateCacheSize` / the "Cache: N MB" data-control readout).
  ///
  /// Uses SQLite's own page accounting (`page_count * page_size`) rather than a
  /// row-by-row estimate so it reflects the actual file footprint — including
  /// index + free pages — and works for the injected in-memory test DB (where
  /// there is no file to `stat`). Returns 0 if the pragmas are unavailable.
  Future<int> totalBytes() async {
    try {
      final pageCountRows =
          await _database.rawQuery('PRAGMA page_count');
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

/// A cached avatar/banner blob record (bytes + source URL + kind0Ts).
class CachedBlob {
  const CachedBlob({required this.bytes, this.sourceUrl, this.kind0Ts});

  final Uint8List bytes;
  final String? sourceUrl;
  final int? kind0Ts;
}
