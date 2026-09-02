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
///   a store exceeds its limit, oldest `lastTouched` first. That LRU has no time
///   component; the 24-hour window below is separate and applies to public
///   channel history only.
/// - Per-record message caps: channels keep the last [channelMessageLimit],
///   pms the last [pmStorageLimit]. These mirror what app.js actually SETS
///   (`this.channelMessageLimit = 1000`, `this.pmStorageLimit = 1000`) — they
///   used to mirror the `|| 100` / `|| 500` fallbacks in the persistence.js
///   expressions, which the PWA never reaches, so a phone kept a tenth of the
///   history the web client did.
/// - Public channel history is additionally bounded to a rolling
///   [channelHistoryMaxAge] (the PWA's `channelHistoryMaxAgeMs`): the D1 archive
///   floors `channel-get` at the same 24 hours and the relay filters ask for
///   `since: now - 86400`, so anything older cannot be re-fetched by this device
///   or any other.
/// - PMs are **only** persisted when caching is enabled
///   (`settings.cachePMs`); when disabled, `savePmMessages` is a no-op (and the
///   `pms` table can be cleared via [clearPms]).
/// - The database is encrypted at rest with SQLCipher under a random key held
///   in the platform keystore (Keychain / Android Keystore) — the local mirror
///   of end-to-end-encrypted conversations must not be plaintext on disk. A
///   pre-encryption plaintext database is migrated in place losslessly via
///   `sqlcipher_export` on first open.
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

  /// Per-record message caps used when persisting, matching the values app.js
  /// assigns (`this.channelMessageLimit` / `this.pmStorageLimit`).
  static const int channelMessageLimit = 1000;
  static const int pmStorageLimit = 1000;

  /// Rolling window for PUBLIC channel history — see
  /// `core/constants/history_window.dart`.
  static const Duration channelHistoryMaxAge = kChannelHistoryMaxAge;

  /// `meta` store key constants (persistence.js).
  static const String metaProcessedPmEventIds = 'processedPMEventIds';
  static const String metaDeletedEventIds = 'deletedEventIds';
  static const String metaNymchatPubkeys = 'nymchatPubkeys';
  static const String metaNymchatVouches = 'nymchatVouches';
  static const String metaTrustedPubkeys = 'trustedPubkeys';
  static const String metaPoolShardLastSeen = 'poolShardLastSeen';
  static const String metaEventTimeCeilings = 'eventTimeCeilings';
  static const String metaPqKeys = 'pqKeys';

  /// Event ids whose BIP340 signatures verified in past sessions (bounded,
  /// newest-biased — see `IsolateVerifier.snapshotVerifiedIds`). Restored at
  /// boot so the relay/D1 replay of already-seen reactions, profiles, presence
  /// and out-of-cache history skips the ~12 ms/event signature math that made
  /// heavy accounts crawl on open/resume. Ids are public, content-bound
  /// hashes; caching them weakens nothing (tampered content re-hashes to a
  /// different id and misses the cache).
  static const String metaVerifiedEventIds = 'verifiedEventIds';

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

  /// SecureStore key holding the SQLCipher passphrase for [_dbName].
  static const String _dbKeyName = 'nym_cache_db_key';

  /// Returns the SQLCipher passphrase from the platform keystore, minting a
  /// random 64-hex one on first use. The passphrase never leaves the device:
  /// it is not synced and is destroyed with the keystore on panic wipe, which
  /// renders any surviving database file undecryptable ciphertext.
  Future<String> _databasePassword(SecureStore secure) async {
    final existing = await secure.get(_dbKeyName);
    if (existing != null && existing.isNotEmpty) return existing;
    final minted = keys.bytesToHex(keys.randomBytes(32));
    await secure.set(_dbKeyName, minted);
    return minted;
  }

  /// True when the file at [path] is a plaintext SQLite database (SQLCipher
  /// databases have a random header instead of the magic string).
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

  /// Losslessly migrates a pre-encryption plaintext database to SQLCipher:
  /// open plain, `sqlcipher_export` into an encrypted sibling, then swap the
  /// files. On any failure the plaintext original is left untouched so the
  /// open below falls back to it (encryption retries next launch) instead of
  /// destroying the user's local history.
  Future<void> _migratePlaintextIfNeeded(String path, String password) async {
    if (!await _isPlaintextDb(path)) return;
    final tmp = '$path.enc';
    try {
      final tmpFile = File(tmp);
      if (await tmpFile.exists()) await tmpFile.delete();
      final plain = await openDatabase(path);
      try {
        // The passphrase is 64 lowercase hex chars (see [_databasePassword]),
        // so inlining it in the SQL literal cannot break out of the quotes.
        await plain.rawQuery("ATTACH DATABASE '$tmp' AS enc KEY '$password'");
        await plain.rawQuery("SELECT sqlcipher_export('enc')");
        // sqlcipher_export copies schema + data but NOT user_version. Carry it
        // over so the encrypted copy doesn't read as a brand-new (version-0)
        // database — today onCreate is all IF-NOT-EXISTS so that would be
        // harmless, but a future onUpgrade must see the real version.
        final ver = await plain.rawQuery('PRAGMA main.user_version');
        final v = (ver.isNotEmpty ? ver.first.values.first : 0) as int? ?? 0;
        await plain.rawQuery('PRAGMA enc.user_version = $v');
        await plain.rawQuery('DETACH DATABASE enc');
      } finally {
        await plain.close();
      }
      // Swap: remove the plaintext original (and its WAL/SHM sidecars, which
      // also hold plaintext pages) and move the encrypted copy into place.
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

  /// Open (and create/migrate) the cache database. If a [Database] was injected
  /// via the constructor (e.g. an in-memory DB in tests) it is used directly,
  /// otherwise the on-device app-documents path is used, encrypted with
  /// SQLCipher under a keystore-held key.
  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _path = path;
    final password = await _databasePassword(SecureStore());
    await _migratePlaintextIfNeeded(path, password);
    if (await _isPlaintextDb(path)) {
      // Migration failed and left the plaintext original — open it as-is so
      // the app keeps working; encryption is retried on the next launch.
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

  /// Drop channel messages that have aged out of [channelHistoryMaxAge], then
  /// pin back any thread ROOT the survivors still reply to — an in-window reply
  /// whose root aged out would otherwise reflow inline as a top-level message
  /// with a dead-end thread affordance. Mirrors `_pruneChannelWindow`.
  static List<Message> _withinChannelWindow(List<Message> messages) {
    if (messages.isEmpty) return messages;
    final floor = channelWindowFloorSec();
    if (!messages.any((m) => m.createdAt < floor)) return messages;
    final kept = messages.where((m) => m.createdAt >= floor).toList();
    return _withPinnedThreadRoots(messages, kept, (m) => m.id);
  }

  /// Keep thread ROOTS in the persisted window (PWA
  /// `persistence.js#_withPinnedThreadRoots`). The window is a plain last-N
  /// slice, so a root older than the window drops off while its replies stay —
  /// and after a reload those replies can never re-thread: they render inline,
  /// as though they were top-level messages, and their thread affordance
  /// dead-ends. Any message the kept window references as a thread root is
  /// pinned in front of the slice.
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
    // Age first, then the count cap — a channel quiet for a day must not write
    // back a full window of messages that have all aged out.
    final inWindow = _withinChannelWindow(msgs);
    if (inWindow.isEmpty) {
      await db.delete('channels', where: 'key = ?', whereArgs: [key]);
      return;
    }
    var trimmed = inWindow.length > channelMessageLimit
        ? inWindow.sublist(inWindow.length - channelMessageLimit)
        : inWindow;
    // Channel thread keys are event ids (`threadKeyForMessage`).
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

  /// Delete the cached reactions targeting [messageIds] — reactions are keyed by
  /// the id of the message they react to, so pruning the rows for a set of
  /// dropped channel messages is exactly "kind 7 events whose `k` tag is
  /// 20000/23333". A reaction on a PM or group message is keyed by an id that
  /// never appears in a channel history.
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

  /// Load EVERY cached channel history, keyed by storage key — the boot
  /// hydration read (persistence.js `hydrateFromCache` getAll over the
  /// `channels` store, :427-433). Empty/corrupt records are skipped.
  Future<Map<String, List<Message>>> loadAllChannelMessages() async {
    final all = await _loadAllMessages('channels');
    // A cache written before the window rule, or simply left unopened for a
    // day, must not put aged-out history back into memory. Rows that empty out
    // are deleted rather than reloaded every launch.
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

  /// Load EVERY cached PM/group conversation, keyed by storage key — the boot
  /// hydration read (persistence.js `hydrateFromCache` getAll over the `pms`
  /// store, :455-461). The caller gates this on `settings.cachePMs` the way
  /// the PWA does (`cachePMsAllowed`); disabled → it calls [clearPms] instead.
  Future<Map<String, List<Message>>> loadAllPmMessages() =>
      _loadAllMessages('pms');

  Future<Map<String, List<Message>>> _loadAllMessages(String table) async {
    final rows = await _database.query(table, columns: ['key', 'json']);
    // Decode OFF the main isolate: a heavy account's boot hydration decodes
    // tens of thousands of message maps, and doing that jsonDecode +
    // Message.fromJson loop on the UI thread both janked the first seconds of
    // the app AND made hydration lose the boot race against the relay
    // connect gate — the empty stores then re-downloaded and re-rendered the
    // whole history from the network. One compute hop per table keeps the
    // main isolate free while the worker chews through the JSON.
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
        out.add(
            Message.fromJson(e.cast<String, dynamic>())..isHistorical = true);
      }
    }
    return out;
  }

  /// `compute` entry point for [_loadAllMessages]: decodes every conversation's
  /// JSON blob into [Message] lists in a worker isolate. Top-level (as
  /// `compute` requires); per-record try/catch so one corrupt row can't abort
  /// the whole hydration. Same historical-marking as [_decodeMessages].
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
    final kind0Ts =
        (row['kind0Ts'] as int?) ?? (map['kind0Ts'] as num?)?.toInt() ?? 0;
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

  // ---------------------------------------------------------------------------
  // Pre-encoded flush path
  // ---------------------------------------------------------------------------
  //
  // The periodic cache flush used to call the save* methods above directly,
  // which jsonEncode whole conversations (up to 1000 messages each), every
  // in-memory profile and every reaction tally ON THE MAIN ISOLATE — during a
  // busy backfill that was hundreds of ms of solid UI-thread block every few
  // seconds (the recurring scroll/sidebar freezes that "settle down" once the
  // backfill stops dirtying keys). The flush now builds all of that JSON in a
  // worker isolate via [encodeCacheFlush] and writes the finished strings
  // through these thin row-insert variants.

  /// Writes a channel row whose JSON was pre-encoded off-isolate. An empty
  /// array deletes the row (same contract as [saveChannelMessages]).
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

  /// [saveChannelMessagesJson]'s `pms` counterpart. The caller gates on
  /// `settings.cachePMs` exactly like [savePmMessages].
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

  /// [saveProfile] with the JSON (which already embeds kind0Ts) pre-encoded.
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

  /// [saveReactions] with the entries pre-encoded. `[]` deletes the row.
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

/// A cached avatar/banner blob record (bytes + source URL + kind0Ts).
class CachedBlob {
  const CachedBlob({required this.bytes, this.sourceUrl, this.kind0Ts});

  final Uint8List bytes;
  final String? sourceUrl;
  final int? kind0Ts;
}

/// The full input of one periodic cache flush, shipped to a worker isolate so
/// every byte of jsonEncode happens off the main thread. Plain model objects
/// only (Message / UserProfile / reaction entry lists) — all isolate-sendable.
class CacheFlushPayload {
  const CacheFlushPayload({
    this.channels = const {},
    this.pms = const {},
    this.profiles = const {},
    this.reactions = const {},
  });

  /// storageKey → already-filtered, already-capped messages to persist.
  final Map<String, List<Message>> channels;
  final Map<String, List<Message>> pms;

  /// pubkey → profile (only the ones that CHANGED since the last flush).
  final Map<String, UserProfile> profiles;

  /// messageId → reaction entries snapshot.
  final Map<String, List<dynamic>> reactions;
}

/// [encodeCacheFlush]'s result: finished JSON strings per row, ready for the
/// thin `save*Json` writers inside one transaction.
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

/// `compute` entry point: serializes a whole flush in a worker isolate.
/// Mirrors exactly what the save* methods encode inline — including embedding
/// `kind0Ts` inside the profile JSON (see [CacheStore.saveProfile]).
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
