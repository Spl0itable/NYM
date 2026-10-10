import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/at_rest_cipher.dart';
import '../../services/storage/secure_store.dart';
import 'account_logic.dart';

class SwitchOutboxStash {
  SwitchOutboxStash(this.prefs, this.accountId, [this._secure]);

  static const int eventCap = 2000;
  static const int rumorCap = 500;

  final SharedPreferences prefs;
  final String accountId;
  final SecureStore? _secure;

  String get key => AccountLogic.nsKey(accountId, StorageKeys.switchOutbox);

  AtRestCipher _cipher() => AtRestCipher(SecureAtRestKeyStore(_secure,
      AccountLogic.nsKey(accountId, SecureAtRestKeyStore.keyName)));

  Future<bool> add(String pubkey, Map<dynamic, dynamic> entry) async {
    if (accountId.isEmpty || pubkey.isEmpty) return false;
    final cipher = _cipher();
    final stored = prefs.getString(key);
    Map<String, dynamic> all;
    try {
      if (stored == null || stored.isEmpty) {
        all = <String, dynamic>{};
      } else {
        final plain = AtRestCipher.isEncryptedString(stored)
            ? await cipher.decryptString(stored)
            : stored;
        final j = jsonDecode(plain);
        if (j is! Map) return false;
        all = Map<String, dynamic>.from(j);
      }
    } catch (_) {
      return false;
    }
    final mine = all[pubkey];
    all[pubkey] = {
      'e': _merge(mine is Map ? mine['e'] : null, entry['e'], eventCap,
          (x) => x['ev'] is Map ? (x['ev'] as Map)['id'] : null),
      'r': _merge(mine is Map ? mine['r'] : null, entry['r'], rumorCap,
          (x) => x['id']),
    };
    try {
      final sealed = await cipher.encryptString(jsonEncode(all));
      if (prefs.getString(key) != stored) return false;
      return await prefs.setString(key, sealed);
    } catch (_) {
      return false;
    }
  }

  static List<Object> _merge(
      Object? have, Object? add, int cap, Object? Function(Map) id) {
    final out = <Object>[];
    final seen = <String>{};
    for (final list in [have, add]) {
      if (list is! List) continue;
      for (final x in list) {
        if (x is! Map) continue;
        final k = id(x);
        if (k is! String || k.isEmpty || !seen.add(k)) continue;
        out.add(x);
      }
    }
    return out.length > cap ? out.sublist(out.length - cap) : out;
  }
}
