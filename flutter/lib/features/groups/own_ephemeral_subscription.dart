import '../../services/relay/relay_pool.dart';

class OwnEphemeralSubscription {
  OwnEphemeralSubscription({required this.subscribe, required this.pubkeys});

  final Subscription Function(List<String> pubkeys) subscribe;
  final List<String> Function() pubkeys;

  Subscription? _current;
  Set<String> _covered = const {};

  Subscription? get current => _current;

  bool get coversAll {
    final pks = pubkeys();
    return pks.length == _covered.length && pks.every(_covered.contains);
  }

  void refresh() {
    final previous = _current;
    _current = null;
    final pks = pubkeys();
    if (pks.isEmpty) {
      _covered = const {};
      previous?.close();
      return;
    }
    final sub = subscribe(pks);
    _current = sub;
    _covered = pks.toSet();
    if (previous != null && !previous.isClosed) {
      retireAfterAnswer(previous, sub);
    }
  }

  bool ensure() {
    final pks = pubkeys();
    if (pks.isEmpty || pks.every(_covered.contains)) return false;
    refresh();
    return true;
  }

  void close() {
    _current?.close();
    _current = null;
    _covered = const {};
  }
}
