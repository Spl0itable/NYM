import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/nym_utils.dart';
import '../../services/nostr/nostr_service.dart' show PresenceStatusMode, presenceStatusModeFrom;
import '../../services/storage/key_value_store.dart';
import '../accounts/account_logic.dart';
import '../away/away_sync.dart';
import '../composer/send_as_model.dart';
import '../emoji/custom_emoji.dart';
import '../relays/relay_block.dart';

class StashKeyValueStore extends KeyValueStore {
  StashKeyValueStore(this._inner, this.accountId) : super(_inner);

  final SharedPreferences _inner;
  final String accountId;

  String _k(String key) => AccountLogic.nsKey(accountId, key);

  @override
  String? getString(String key) {
    try {
      return _inner.getString(_k(key));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setString(String key, String value) =>
      _inner.setString(_k(key), value);

  @override
  Future<void> remove(String key) => _inner.remove(_k(key));

  @override
  Future<void> clear() async {}

  @override
  bool contains(String key) => _inner.containsKey(_k(key));

  @override
  Set<String> get keys {
    final pre = _k('');
    return {
      for (final k in _inner.getKeys())
        if (k.startsWith(pre)) k.substring(pre.length),
    };
  }

  @override
  bool getBool(String key, {bool defaultValue = false}) {
    final v = getString(key);
    if (v == null) return defaultValue;
    return v == 'true' || v == '1';
  }

  @override
  Future<void> setBool(String key, bool value) =>
      setString(key, value ? 'true' : 'false');

  @override
  int getInt(String key, {required int defaultValue}) =>
      int.tryParse(getString(key) ?? '') ?? defaultValue;

  @override
  Future<void> setInt(String key, int value) => setString(key, '$value');

  @override
  Set<String> getStringSet(String key) {
    final v = getString(key);
    if (v == null || v.isEmpty) return <String>{};
    final t = v.trim();
    if (t.startsWith('[')) {
      try {
        final d = jsonDecode(t);
        if (d is List) return {for (final e in d) '$e'}..remove('');
      } catch (_) {}
    }
    return v.split(',').where((s) => s.isNotEmpty).toSet();
  }
}

class SendAsStash {
  SendAsStash(this.entry, this.get);

  final AccountEntry entry;
  final String? Function(String key) get;

  String? _read(String key) {
    try {
      return get(key);
    } catch (_) {
      return null;
    }
  }

  String get keypairMode {
    final m = _read('nym_keypair_mode') ?? '';
    if (m.isNotEmpty) return m;
    return _read('nym_random_keypair_per_session') == 'true' ? 'random' : '';
  }

  bool get vaultOn {
    final v = _read('nym_vault_enabled');
    return v == 'true' || v == '1';
  }

  String get aiConsent => _read('nym_ai_consent') ?? '';

  int get powDifficulty =>
      int.tryParse(_read('nym_pow_difficulty') ?? '') ?? 0;

  bool get durable =>
      entry.method == 'nsec' ||
      entry.method == 'extension' ||
      entry.method == 'nip46';

  Map<String, dynamic> get _profile {
    try {
      final p = jsonDecode(_read('nym_nostr_login_profile') ?? '{}');
      return p is Map ? Map<String, dynamic>.from(p) : const {};
    } catch (_) {
      return const {};
    }
  }

  String get nym {
    final pk = entry.pubkey;
    if (durable) {
      var name = _profile['name'];
      var base = name is String ? name : '';
      if (base.isEmpty) base = stripPubkeySuffix(entry.nym);
      if (base.isEmpty) base = 'nym';
      if (base.length > 20) base = base.substring(0, 20);
      return getNymFromPubkey(base, pk);
    }
    final nick = _read('nym_auto_ephemeral_nick') ?? '';
    if (nick.isNotEmpty) return nick;
    return entry.nym.isNotEmpty ? entry.nym : 'nym';
  }

  String? get avatar {
    final a = durable ? _profile['avatar'] : _read('nym_avatar_url');
    return a is String && a.isNotEmpty ? a : null;
  }

  Map<String, String> get emojiMap =>
      loadCustomEmojiStateWith(_read).codeToUrl;

  List<List<String>> emojiTagsFor(String content) {
    final map = emojiMap;
    if (content.isEmpty || map.isEmpty) return const [];
    final out = <List<String>>[];
    final added = <String>{};
    for (final m in RegExp(r':([a-zA-Z0-9_]+):').allMatches(content)) {
      final code = m.group(1)!;
      if (added.contains(code)) continue;
      final url = map[code];
      if (url != null) {
        added.add(code);
        out.add(['emoji', code, url]);
      }
    }
    return out;
  }

  List<String> get blockedRelays {
    try {
      final raw = _read('nym_blocked_relays');
      if (raw == null || raw.isEmpty) return const [];
      return RelayBlock.list(
          RelayBlock.norm(jsonDecode(raw), DateTime.now().millisecondsSinceEpoch));
    } catch (_) {
      return const [];
    }
  }

  PresenceStatusMode get statusMode =>
      presenceStatusModeFrom(_read('nym_show_status') ?? 'true');

  bool get away =>
      AwaySync.decode(_read(AwaySync.storageKey(entry.pubkey)))?.enabled ==
      true;

  bool get remotePanicOn => _read('nym_remote_panic') == 'true';

  int? get panicLoginAt {
    final v = int.tryParse(_read('nym_panic_login_at') ?? '') ?? 0;
    return v > 0 ? v : null;
  }

  SendAsAccount account(String? secret) => SendAsAccount(
        id: entry.id,
        pubkey: entry.pubkey,
        method: entry.method,
        nym: stripPubkeySuffix(nym),
        keypairMode: keypairMode,
        signer: sendAsSignerState(
          method: entry.method,
          secret: secret,
          vaultOn: vaultOn,
        ),
        aiConsent: aiConsent,
      );
}
