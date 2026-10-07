import 'dart:convert';
import 'dart:math';

class AccountEntry {
  const AccountEntry({
    required this.id,
    this.ns = '',
    this.pubkey = '',
    this.method = '',
    this.nym = '',
    this.avatar = '',
    this.addedAt = 0,
    this.notifyInactive = false,
    this.unread = 0,
    this.returnTo,
  });

  final String id;
  final String ns;
  final String pubkey;
  final String method;
  final String nym;
  final String avatar;
  final int addedAt;
  final bool notifyInactive;
  final int unread;
  final String? returnTo;

  bool get isPlaceholder => pubkey.isEmpty;

  AccountEntry copyWith({
    String? pubkey,
    String? method,
    String? nym,
    String? avatar,
    bool? notifyInactive,
    int? unread,
    String? returnTo,
    bool clearReturnTo = false,
  }) =>
      AccountEntry(
        id: id,
        ns: ns,
        pubkey: pubkey ?? this.pubkey,
        method: method ?? this.method,
        nym: nym ?? this.nym,
        avatar: avatar ?? this.avatar,
        addedAt: addedAt,
        notifyInactive: notifyInactive ?? this.notifyInactive,
        unread: unread ?? this.unread,
        returnTo: clearReturnTo ? null : (returnTo ?? this.returnTo),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'ns': ns,
        'pubkey': pubkey,
        'method': method,
        'nym': nym,
        'avatar': avatar,
        'addedAt': addedAt,
        'notifyInactive': notifyInactive,
        'unread': unread,
        'returnTo': returnTo,
      };
}

class AccountJournal {
  const AccountJournal(this.effects, this.dbs);

  final List<String> effects;
  final List<String> dbs;

  Map<String, Object?> toJson() => {'effects': effects, 'dbs': dbs};
}

class AccountIndex {
  const AccountIndex({
    this.active,
    this.accounts = const [],
    this.journal,
  });

  final String? active;
  final List<AccountEntry> accounts;
  final AccountJournal? journal;

  AccountEntry? get activeAccount => byId(active);

  AccountEntry? byId(String? id) {
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  AccountIndex withJournal(AccountJournal? journal) =>
      AccountIndex(active: active, accounts: accounts, journal: journal);

  Map<String, Object?> toJson() => {
        'v': 1,
        'active': active,
        'accounts': [for (final a in accounts) a.toJson()],
        'journal': journal?.toJson(),
      };

  String encode() => jsonEncode(toJson());
}

class AccountPlan {
  const AccountPlan({
    required this.ok,
    required this.effects,
    required this.index,
    this.error,
    this.result,
    this.existing,
  });

  final bool ok;
  final String? error;
  final String? result;
  final String? existing;
  final List<String> effects;
  final AccountIndex index;

  bool get needsBoot => effects.contains('reload');

  Map<String, Object?> toJson() => {
        'ok': ok,
        if (error != null) 'error': error,
        if (result != null) 'result': result,
        if (existing != null) 'existing': existing,
        'effects': effects,
        'index': index.toJson(),
      };
}

abstract class AccountOp {
  const AccountOp();
}

class AddAccountOp extends AccountOp {
  const AddAccountOp(this.id, this.now);
  final String id;
  final int now;
}

class RegisterAccountOp extends AccountOp {
  const RegisterAccountOp({
    required this.pubkey,
    required this.method,
    required this.nym,
    this.id = '',
    this.now = 0,
  });
  final String pubkey;
  final String method;
  final String nym;
  final String id;
  final int now;
}

class SwitchAccountOp extends AccountOp {
  const SwitchAccountOp(this.id, {this.unread = 0});
  final String id;
  final int unread;
}

class CancelAddOp extends AccountOp {
  const CancelAddOp();
}

class RemoveAccountOp extends AccountOp {
  const RemoveAccountOp(this.id);
  final String id;
}

class LogoutOp extends AccountOp {
  const LogoutOp();
}

class LogoutAllOp extends AccountOp {
  const LogoutAllOp();
}

class NotifyOp extends AccountOp {
  const NotifyOp(this.id, {required this.on});
  final String id;
  final bool on;
}

class UnknownOp extends AccountOp {
  const UnknownOp();
}

abstract class AccountKeyStore {
  Iterable<String> get keys;
  Object? read(String key);
  void write(String key, Object value);
  void delete(String key);
}

class AccountLogic {
  AccountLogic._();

  static const int maxAccounts = 10;
  static const String indexKey = 'nymacct:index';
  static const String nsPrefix = 'nymacct:';
  static const List<String> methods = [
    'nsec',
    'extension',
    'nip46',
    'ephemeral',
    'anonymous',
  ];
  static const String cacheDb = 'nym-cache';

  static const Set<String> deviceKeys = {
    'nym_theme',
    'nym_color_mode',
    'nym_text_size',
    'nym_transparency_enabled',
    'nym_chat_layout',
    'nym_chat_view_mode',
    'nym_nick_style',
    'nym_timestamps',
    'nym_time_format',
    'nym_date_format',
    'nym_ui_language',
    'nym_ui_language_chosen',
    'nym_translate_language',
    'nym_connection_mode',
    'nym_relay_url',
    'nym_relay_direct_mode',
    'nym_relay_direct_ack',
    'nym_relay_fallback_notice_off',
    'nym_low_data_mode',
    'nym_mesh_ghost_mode',
    'nym_tutorial_seen',
    'nym_attest_authority',
    'nym_voice_speed',
    'nym_sidebar_section_order',
    'nym_sidebar_section_collapsed',
    'nym_settings_sections_collapsed',
  };

  static const List<String> devicePrefixes = ['nym_ui_i18n_', 'nym_cmd_i18n_'];

  static const Set<String> volatileKeys = {
    'nym_unfurl_cache',
    'nym_nostr_ref_cache',
    'nym_msg_verify_status',
    'nym_relay_stats',
  };

  static const Set<String> nativeDeviceKeys = {
    'nym_installed',
    'nym_mesh_enabled',
    'nym_ghost_mode',
    'nym_background_connectivity',
    'nym_heartbeat_token',
    'nym_geo_relays',
    'nym_geohash_places',
    'nym_botpm_model_catalog',
    'nym_pubkey_format',
    'nym_screen_security',
    'nym_incognito_keyboard',
  };

  static const List<String> nativeDevicePrefixes = ['nym_bk_'];

  static const Map<String, List<String>> settingsScope = {
    'device': [
      'theme',
      'colorMode',
      'textSize',
      'transparency',
      'chatLayout',
      'chatViewMode',
      'nickStyle',
      'timestamps',
      'timeFormat',
      'dateFormat',
      'sidebarLayout',
      'uiLanguage',
      'translateLanguage',
      'connectionMode',
      'relayTransport',
      'lowDataMode',
      'meshEnabled',
      'meshGhostMode',
      'notificationPermission',
      'tutorialSeen',
      'voiceSpeed',
    ],
    'account': [
      'keys',
      'loginMethod',
      'vault',
      'pqRoot',
      'pqDeviceId',
      'profile',
      'lightningAddress',
      'settingsSync',
      'pmCache',
      'groupCache',
      'channelCache',
      'unread',
      'lastRead',
      'chatLocks',
      'savedMessages',
      'keptMessages',
      'drafts',
      'mutes',
      'blocks',
      'friends',
      'pinnedChannels',
      'hiddenChannels',
      'columnsLayout',
      'notificationPrefs',
      'notificationHistory',
      'readReceipts',
      'typingIndicators',
      'wallpaper',
      'emojiFavorites',
      'd1Session',
      'pushRegistration',
      'attestation',
      'nymbotCredits',
      'nymbotSession',
      'purchases',
      'outbox',
      'depositQueue',
      'scheduledMessages',
      'meshIdentity',
      'meshOutbox',
      'anonNymbotKeys',
      'notifyInactive',
    ],
  };

  static final RegExp _idPattern = RegExp(r'^[0-9a-z]{1,32}$');

  static String nsKey(String id, String key) => '$nsPrefix$id:$key';

  static String dbName(String base, String? ns) =>
      ns != null && ns.isNotEmpty ? '$base~$ns' : base;

  static String classify(String key) {
    if (key.startsWith(nsPrefix)) return 'meta';
    if (deviceKeys.contains(key) || devicePrefixes.any(key.startsWith)) {
      return 'device';
    }
    if (volatileKeys.contains(key)) return 'volatile';
    if (key.startsWith('nym_')) return 'account';
    return 'device';
  }

  static String classifyNative(String key) {
    if (nativeDeviceKeys.contains(key) ||
        nativeDevicePrefixes.any(key.startsWith)) {
      return 'device';
    }
    return classify(key);
  }

  static String methodFromStorage(String? Function(String) get) {
    final m = get('nym_nostr_login_method');
    if (m == 'nsec' || m == 'extension' || m == 'nip46') return m!;
    if (get('nym_auto_ephemeral') == 'true') {
      return get('nym_random_keypair_per_session') == 'true'
          ? 'anonymous'
          : 'ephemeral';
    }
    return '';
  }

  static bool _durable(String method) =>
      method == 'nsec' || method == 'extension' || method == 'nip46';

  static String nymFromStorage(String? Function(String) get, String method) {
    if (_durable(method)) {
      try {
        final p = jsonDecode(get('nym_nostr_login_profile') ?? '{}');
        if (p is Map && p['name'] is String) return p['name'] as String;
      } catch (_) {}
      return '';
    }
    return get('nym_auto_ephemeral_nick') ?? '';
  }

  static AccountIndex emptyIndex() => const AccountIndex();

  static AccountIndex? parseIndex(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    Object? j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (j is! Map || j['accounts'] is! List) return null;
    String str(Object? v) => v is String ? v : '';
    int number(Object? v) {
      if (v is num) return v.isFinite ? v.toInt() : 0;
      if (v is String) return num.tryParse(v)?.toInt() ?? 0;
      return 0;
    }

    final accounts = <AccountEntry>[];
    for (final a in j['accounts'] as List) {
      if (a is! Map) continue;
      final id = a['id'];
      if (id is! String || !_idPattern.hasMatch(id)) continue;
      final unread = number(a['unread']);
      accounts.add(AccountEntry(
        id: id,
        ns: a['ns'] is String ? a['ns'] as String : id,
        pubkey: str(a['pubkey']),
        method: str(a['method']),
        nym: str(a['nym']),
        avatar: str(a['avatar']),
        addedAt: number(a['addedAt']),
        notifyInactive: a['notifyInactive'] == true,
        unread: unread < 0 ? 0 : unread,
        returnTo: a['returnTo'] is String ? a['returnTo'] as String : null,
      ));
    }
    final rawActive = j['active'];
    final active = accounts.any((a) => a.id == rawActive)
        ? rawActive as String
        : null;
    final rawJournal = j['journal'];
    AccountJournal? journal;
    if (rawJournal is Map && rawJournal['effects'] is List) {
      journal = AccountJournal(
        [for (final e in rawJournal['effects'] as List) '$e'],
        rawJournal['dbs'] is List
            ? [for (final d in rawJournal['dbs'] as List) '$d']
            : const [],
      );
    }
    return AccountIndex(active: active, accounts: accounts, journal: journal);
  }

  static AccountIndex loadOrMigrate(
      String? Function(String) get, String id, int now) {
    final parsed = parseIndex(get(indexKey));
    if (parsed != null) return parsed;
    final method = methodFromStorage(get);
    if (method.isEmpty) return emptyIndex();
    final pubkey =
        _durable(method) ? (get('nym_nostr_login_pubkey') ?? '') : '';
    return AccountIndex(active: id, accounts: [
      AccountEntry(
        id: id,
        pubkey: pubkey,
        method: method,
        nym: nymFromStorage(get, method),
        addedAt: now,
      ),
    ]);
  }

  static AccountPlan _refuse(AccountIndex index, String error) =>
      AccountPlan(ok: false, error: error, effects: const [], index: index);

  static String _freeNs(AccountIndex index, String id) =>
      index.accounts.any((a) => a.ns.isEmpty) ? id : '';

  static AccountPlan _removePlan(AccountIndex index, String id) {
    final pos = index.accounts.indexWhere((a) => a.id == id);
    if (pos < 0) return _refuse(index, 'unknown');
    final gone = index.accounts[pos];
    final rest = [
      for (final a in index.accounts)
        if (a.id != id) a.returnTo == id ? a.copyWith(clearReturnTo: true) : a,
    ];
    if (id != index.active) {
      return AccountPlan(
        ok: true,
        effects: ['wipe:$id'],
        index: AccountIndex(active: index.active, accounts: rest),
      );
    }
    String? next;
    if (gone.isPlaceholder &&
        gone.returnTo != null &&
        rest.any((a) => a.id == gone.returnTo)) {
      next = gone.returnTo;
    } else if (pos < rest.length) {
      next = rest[pos].id;
    } else if (pos - 1 >= 0 && pos - 1 < rest.length) {
      next = rest[pos - 1].id;
    }
    final effects = ['clear', 'wipe:$id', if (next != null) 'restore:$next', 'reload'];
    return AccountPlan(
      ok: true,
      effects: effects,
      index: AccountIndex(active: next, accounts: [
        for (final a in rest) a.id == next ? a.copyWith(unread: 0) : a,
      ]),
    );
  }

  static AccountPlan plan(AccountIndex indexIn, AccountOp op) {
    final index = indexIn.withJournal(null);
    final cur = index.activeAccount;
    switch (op) {
      case AddAccountOp(:final id, :final now):
        if (index.accounts.length >= maxAccounts) return _refuse(index, 'cap');
        if (cur != null && cur.isPlaceholder) return _refuse(index, 'pending');
        final acct = AccountEntry(
          id: id,
          ns: _freeNs(index, id),
          addedAt: now,
          returnTo: cur?.id,
        );
        return AccountPlan(
          ok: true,
          effects: cur != null ? ['stash:${cur.id}', 'reload'] : ['reload'],
          index: AccountIndex(active: id, accounts: [...index.accounts, acct]),
        );
      case RegisterAccountOp(
          :final pubkey,
          :final method,
          :final nym,
          :final id,
          :final now
        ):
        if (cur == null) {
          if (index.accounts.length >= maxAccounts) {
            return _refuse(index, 'cap');
          }
          final acct = AccountEntry(
            id: id,
            ns: _freeNs(index, id),
            addedAt: now,
            pubkey: pubkey,
            method: method,
            nym: nym,
          );
          return AccountPlan(
            ok: true,
            result: 'created',
            effects: const [],
            index: AccountIndex(active: id, accounts: [...index.accounts, acct]),
          );
        }
        AccountEntry? dup;
        if (pubkey.isNotEmpty) {
          for (final a in index.accounts) {
            if (a.id != cur.id && a.pubkey == pubkey) {
              dup = a;
              break;
            }
          }
        }
        if (dup != null) {
          if (!cur.isPlaceholder) {
            return AccountPlan(
              ok: false,
              result: 'duplicate',
              existing: dup.id,
              effects: const [],
              index: index,
            );
          }
          return AccountPlan(
            ok: true,
            result: 'duplicate',
            existing: dup.id,
            effects: [
              'clear',
              'wipe:${cur.id}',
              'restore:${dup.id}',
              'reload'
            ],
            index: AccountIndex(active: dup.id, accounts: [
              for (final a in index.accounts)
                if (a.id != cur.id) a.id == dup.id ? a.copyWith(unread: 0) : a,
            ]),
          );
        }
        return AccountPlan(
          ok: true,
          result: 'updated',
          effects: const [],
          index: AccountIndex(active: cur.id, accounts: [
            for (final a in index.accounts)
              a.id == cur.id
                  ? a.copyWith(
                      pubkey: pubkey,
                      method: method,
                      nym: nym,
                      clearReturnTo: true)
                  : a,
          ]),
        );
      case SwitchAccountOp(:final id, :final unread):
        final target = index.byId(id);
        if (target == null) return _refuse(index, 'unknown');
        if (cur != null && target.id == cur.id) return _refuse(index, 'active');
        if (cur != null && cur.isPlaceholder) {
          return AccountPlan(
            ok: true,
            effects: [
              'clear',
              'wipe:${cur.id}',
              'restore:${target.id}',
              'reload'
            ],
            index: AccountIndex(active: target.id, accounts: [
              for (final a in index.accounts)
                if (a.id != cur.id)
                  a.id == target.id ? a.copyWith(unread: 0) : a,
            ]),
          );
        }
        final kept = unread < 0 ? 0 : unread;
        return AccountPlan(
          ok: true,
          effects: [
            cur != null ? 'stash:${cur.id}' : 'clear',
            'restore:${target.id}',
            'reload',
          ],
          index: AccountIndex(active: target.id, accounts: [
            for (final a in index.accounts)
              if (cur != null && a.id == cur.id)
                a.copyWith(unread: kept)
              else if (a.id == target.id)
                a.copyWith(unread: 0)
              else
                a,
          ]),
        );
      case CancelAddOp():
        if (cur == null || !cur.isPlaceholder) return _refuse(index, 'none');
        return _removePlan(index, cur.id);
      case RemoveAccountOp(:final id):
        return _removePlan(index, id);
      case LogoutOp():
        if (cur == null) return _refuse(index, 'none');
        return _removePlan(index, cur.id);
      case LogoutAllOp():
        return AccountPlan(
          ok: true,
          effects: [
            'clear',
            for (final a in index.accounts) 'wipe:${a.id}',
            'reload',
          ],
          index: emptyIndex(),
        );
      case NotifyOp(:final id, :final on):
        final target = index.byId(id);
        if (target == null) return _refuse(index, 'unknown');
        if (on && (target.method == 'anonymous' || target.pubkey.isEmpty)) {
          return _refuse(index, 'unsupported');
        }
        return AccountPlan(
          ok: true,
          effects: const [],
          index: AccountIndex(active: index.active, accounts: [
            for (final a in index.accounts)
              a.id == id ? a.copyWith(notifyInactive: on) : a,
          ]),
        );
    }
    return _refuse(index, 'op');
  }

  static void runEffects(
    AccountKeyStore store,
    List<String> effects, {
    String Function(String key) classifier = classify,
  }) {
    for (final e in effects) {
      final at = e.indexOf(':');
      final verb = at < 0 ? e : e.substring(0, at);
      final id = at < 0 ? '' : e.substring(at + 1);
      if (verb == 'stash' && id.isNotEmpty) {
        for (final k in store.keys.toList()) {
          final c = classifier(k);
          if (c == 'account') {
            final v = store.read(k);
            if (v != null) store.write(nsKey(id, k), v);
            store.delete(k);
          } else if (c == 'volatile') {
            store.delete(k);
          }
        }
      } else if (verb == 'restore' && id.isNotEmpty) {
        final pre = nsKey(id, '');
        for (final k in store.keys.toList()) {
          if (!k.startsWith(pre)) continue;
          final v = store.read(k);
          final plain = k.substring(pre.length);
          if (v != null && classifier(plain) == 'account') {
            store.write(plain, v);
          }
          store.delete(k);
        }
      } else if (verb == 'clear') {
        for (final k in store.keys.toList()) {
          final c = classifier(k);
          if (c == 'account' || c == 'volatile') store.delete(k);
        }
      } else if (verb == 'wipe' && id.isNotEmpty) {
        final pre = nsKey(id, '');
        for (final k in store.keys.toList()) {
          if (k.startsWith(pre)) store.delete(k);
        }
      }
    }
  }

  static List<String> journalDbs(AccountIndex before, List<String> effects) {
    final out = <String>[];
    for (final e in effects) {
      if (!e.startsWith('wipe:')) continue;
      final a = before.byId(e.substring(5));
      if (a != null) out.add(dbName(cacheDb, a.ns));
    }
    return out;
  }

  static List<String> journalNamespaces(
      AccountIndex before, List<String> effects) {
    final out = <String>[];
    for (final e in effects) {
      if (!e.startsWith('wipe:')) continue;
      final a = before.byId(e.substring(5));
      if (a != null) out.add(a.ns);
    }
    return out;
  }

  static String randomId([Random? rng]) {
    final r = rng ?? Random.secure();
    final b = StringBuffer();
    for (var i = 0; i < 6; i++) {
      b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }
}
