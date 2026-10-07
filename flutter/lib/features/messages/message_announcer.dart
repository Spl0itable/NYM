import 'dart:async';

import '../../models/message.dart';
import '../i18n/i18n.dart';

class MessageAnnouncer {
  MessageAnnouncer({
    required this.speak,
    DateTime Function()? clock,
    this.gap = const Duration(seconds: 2),
    this.quiet = const Duration(milliseconds: 1500),
    this.freshSeconds = 120,
  }) : _clock = clock ?? DateTime.now;

  final void Function(String text) speak;
  final DateTime Function() _clock;
  final Duration gap;
  final Duration quiet;
  final int freshSeconds;

  String? _conversation;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastAt;
  Timer? _timer;
  final List<({String nym, String body})> _queue = [];
  final Set<String> _done = <String>{};

  static String textFor(List<({String nym, String body})> items) {
    if (items.length == 1) {
      final one = items.first;
      return one.nym.isEmpty ? one.body : '${one.nym}: ${one.body}';
    }
    return tr('{n} new messages', {'n': items.length});
  }

  void update(
    String conversation,
    List<Message> previous,
    List<Message> next, {
    required String Function(Message m) nymOf,
  }) {
    final now = _clock();
    if (conversation != _conversation) {
      _conversation = conversation;
      _quietUntil = now.add(quiet);
      _queue.clear();
      return;
    }
    if (now.isBefore(_quietUntil)) return;
    final before = <String>{for (final m in previous) m.id};
    var after = -1;
    for (var i = 0; i < next.length; i++) {
      if (before.contains(next[i].id)) after = i;
    }
    final nowS = now.millisecondsSinceEpoch ~/ 1000;
    for (var i = after + 1; i < next.length; i++) {
      final m = next[i];
      if (m.id.isEmpty || m.isOwn || m.isHistorical || m.isSystemRow) continue;
      final body = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (body.isEmpty) continue;
      if (nowS - m.createdAt > freshSeconds) continue;
      if (!_done.add(m.id)) continue;
      if (_done.length > 500) _done.remove(_done.first);
      _queue.add((
        nym: nymOf(m),
        body: body.length > 160 ? body.substring(0, 160) : body,
      ));
    }
    _schedule();
  }

  void _schedule() {
    if (_queue.isEmpty || _timer != null) return;
    final last = _lastAt;
    final wait = last == null ? Duration.zero : last.add(gap).difference(_clock());
    if (wait <= Duration.zero) {
      _flush();
      return;
    }
    _timer = Timer(wait, () {
      _timer = null;
      _flush();
    });
  }

  void _flush() {
    if (_queue.isEmpty) return;
    final text = textFor(List.of(_queue));
    _queue.clear();
    _lastAt = _clock();
    speak(text);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
