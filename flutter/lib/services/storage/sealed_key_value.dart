import 'at_rest_cipher.dart';
import 'key_value_store.dart';

enum SealedReadStatus { absent, plain, sealed, locked, unreadable }

class SealedRead {
  const SealedRead(this.status, [this.value]);

  final SealedReadStatus status;
  final String? value;

  bool get locked => status == SealedReadStatus.locked;
}

class SealedKeyValue {
  SealedKeyValue(this.kv, {AtRestCipher? cipher, bool Function()? blocked})
      : _cipher = cipher,
        _blocked = blocked ?? _never;

  static bool _never() => false;

  final KeyValueStore kv;
  final AtRestCipher? _cipher;
  final bool Function() _blocked;
  final Set<String> _locked = <String>{};
  Future<void> _writes = Future<void>.value();

  AtRestCipher get _crypto => _cipher ?? AtRestCipher.instance;

  Future<void> get idle => _writes;

  bool isLocked(String key) => _locked.contains(key);

  void write(String key, String plain) {
    if (_locked.contains(key)) return;
    _enqueue(() async {
      final sealed = await _crypto.encryptString(plain);
      if (_blocked() || _locked.contains(key)) return;
      await kv.setString(key, sealed);
    });
  }

  void remove(String key) {
    _locked.remove(key);
    _enqueue(() => kv.remove(key));
  }

  Future<String?> read(String key) async => (await readDetailed(key)).value;

  Future<SealedRead> readDetailed(String key) async {
    await _writes;
    final stored = kv.getString(key);
    if (stored == null || stored.isEmpty) {
      _locked.remove(key);
      return SealedRead(SealedReadStatus.absent, stored);
    }
    if (AtRestCipher.isEncryptedString(stored)) {
      try {
        final plain = await _crypto.decryptString(stored);
        _locked.remove(key);
        return SealedRead(SealedReadStatus.sealed, plain);
      } on AtRestKeyUnavailable {
        _locked.add(key);
        return const SealedRead(SealedReadStatus.locked);
      } catch (_) {
        _locked.remove(key);
        return const SealedRead(SealedReadStatus.unreadable);
      }
    }
    _locked.remove(key);
    _enqueue(() async {
      final sealed = await _crypto.encryptString(stored);
      if (_blocked() || kv.getString(key) != stored) return;
      await kv.setString(key, sealed);
    });
    return SealedRead(SealedReadStatus.plain, stored);
  }

  void _enqueue(Future<void> Function() job) {
    _writes = _writes.then((_) async {
      if (_blocked()) return;
      try {
        await job();
      } catch (_) {}
    });
  }
}
