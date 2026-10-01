import 'dart:async';
import 'dart:math';

import '../../models/message.dart';

typedef BotRunResponse = ({int status, Map<String, dynamic> data});

typedef BotRunTransport = Future<BotRunResponse> Function(
  String action,
  Map<String, dynamic> body, {
  Duration? timeout,
  bool? asAnon,
});

const int kBotRunDefaultLimit = 3;
const int kBotRunCeiling = 10;
const int kBotRunSteerChars = 2000;
const Duration kBotRunMaxAge = Duration(hours: 1);
const Duration kBotRunPmTimeout = Duration(seconds: 180);
const Duration kBotRunPollEvery = Duration(seconds: 5);
const Duration kBotRunSteerKeep = Duration(hours: 2);
const int _claimFirstMs = 3000;
const int _claimCapMs = 60000;

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
final RegExp _steerId = RegExp(r'^[0-9a-f]{24}$');

int clampBotMaxRuns(int n) =>
    n < 1 ? 0 : (n > kBotRunCeiling ? kBotRunCeiling : n);

int effectiveBotMaxRuns(int n) {
  final clean = clampBotMaxRuns(n);
  return clean == 0 ? kBotRunDefaultLimit : clean;
}

String? botReplyToFromTags(List<dynamic> tags) {
  for (final t in tags) {
    if (t is List && t.length > 1 && t[0] == 'nymreply' && t[1] is String) {
      final v = t[1] as String;
      return _hex64.hasMatch(v) ? v.toLowerCase() : null;
    }
  }
  return null;
}

bool anchorBotReply(List<Message> list, Message reply) {
  final to = reply.replyTo;
  if (to == null || to.isEmpty) return false;
  for (final m in list) {
    if (m.isOwn && m.nymMessageId == to) {
      reply.anchorAt = m.createdAt;
      reply.anchorMs = m.ms > 0 ? m.ms : m.createdAt * 1000;
      return true;
    }
  }
  return false;
}

enum BotRunState { running, claiming, waiting, capped }

enum BotRunNoteKind { stopped, error, capFree, failed, steerLate }

enum BotSteerOutcome { ok, finished, answering, tooLong, retry, empty }

enum BotRunCapOption { start, always, wait }

class BotRunSpec {
  const BotRunSpec({
    required this.id,
    required this.eventId,
    this.thread = '',
    this.content = '',
    this.extra = const <String, dynamic>{},
    this.startedAt,
  });

  final String id;
  final String eventId;
  final String thread;
  final String content;
  final Map<String, dynamic> extra;
  final int? startedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'eventId': eventId,
        'thread': thread,
        'content': content,
        'startedAt': startedAt,
        'extra': extra,
      };

  static BotRunSpec? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final eventId = raw['eventId'];
    if (id is! String || eventId is! String || id.isEmpty) return null;
    final extra = raw['extra'];
    return BotRunSpec(
      id: id,
      eventId: eventId,
      thread: raw['thread'] is String ? raw['thread'] as String : '',
      content: raw['content'] is String ? raw['content'] as String : '',
      extra: extra is Map ? extra.cast<String, dynamic>() : const {},
      startedAt: (raw['startedAt'] as num?)?.toInt(),
    );
  }
}

class BotRunCap {
  const BotRunCap({
    required this.error,
    required this.running,
    required this.limit,
    required this.ceiling,
  });

  final String error;
  final int running;
  final int limit;
  final int ceiling;
}

class BotRun {
  BotRun(this.spec, this.startedAt)
      : id = spec.id.toLowerCase(),
        label = spec.content.length > 80
            ? spec.content.substring(0, 80)
            : spec.content;

  final BotRunSpec spec;
  final String id;
  final String label;
  final int startedAt;
  BotRunState state = BotRunState.running;
  BotRunCap? cap;
  final Map<String, String> steers = <String, String>{};
  bool anon = false;
  String progress = '';
  bool stopped = false;
  int gen = 0;
  Future<void>? done;

  String get eventId => spec.eventId;
  String get thread => spec.thread;
  String get content => spec.content;
}

class BotRunNote {
  const BotRunNote(this.kind,
      {this.text = '', this.steerText, this.spec, this.thread});

  final BotRunNoteKind kind;
  final String text;
  final String? steerText;
  final BotRunSpec? spec;
  final String? thread;
}

class _FarSteer {
  _FarSteer(this.runId, this.text, this.thread, this.anon, this.at);

  final String runId;
  final String text;
  final String thread;
  final bool anon;
  final int at;
  int tries = 0;
}

class BotRunRow {
  const BotRunRow({
    required this.id,
    required this.label,
    required this.progress,
    required this.state,
    required this.startedAt,
    required this.thread,
    required this.remote,
  });

  final String id;
  final String label;
  final String progress;
  final BotRunState state;
  final int startedAt;
  final String thread;
  final bool remote;
}

class BotRunsEngine {
  BotRunsEngine({
    required this.transport,
    required this.onDelivered,
    this.onNoCredits,
    this.onPriceUnavailable,
    this.onOpenBuy,
    this.onChanged,
    this.onTyping,
    this.onResponse,
    this.onPersist,
    this.anonNow,
    int Function()? maxRuns,
    void Function(int n)? setMaxRuns,
    Future<void> Function(Duration d)? sleep,
    int Function()? now,
    int Function(int ms)? jitter,
  })  : _maxRuns = maxRuns ?? (() => 0),
        _setMaxRuns = setMaxRuns ?? ((_) {}),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _jitter = jitter ?? _defaultJitter;

  final BotRunTransport transport;
  final Future<void> Function(BotRun run, Map<String, dynamic> data)
      onDelivered;
  final void Function(Map<String, dynamic> data)? onNoCredits;
  final void Function(BotRun run)? onPriceUnavailable;
  final void Function(bool pro)? onOpenBuy;
  final void Function()? onChanged;
  final void Function(bool live)? onTyping;
  final void Function()? onResponse;
  final void Function(List<Map<String, dynamic>> inflight)? onPersist;
  final bool Function()? anonNow;
  final int Function() _maxRuns;
  final void Function(int n) _setMaxRuns;
  final Future<void> Function(Duration d) _sleep;
  final int Function() _now;
  final int Function(int ms) _jitter;

  static final Random _rng = Random();
  static int _defaultJitter(int ms) =>
      (ms * (0.8 + _rng.nextDouble() * 0.4)).round();

  final Map<String, BotRun> runs = <String, BotRun>{};
  final Map<String, BotRunNote> notes = <String, BotRunNote>{};
  List<Map<String, dynamic>> remote = const <Map<String, dynamic>>[];
  final Set<String> _guard = <String>{};
  final Map<String, _FarSteer> _far = <String, _FarSteer>{};
  bool _farChecking = false;
  bool _typingOn = false;
  bool disposed = false;

  bool guardTake(String key) => _guard.add(key);

  void guardRelease(String key) => _guard.remove(key);

  int get liveCount => runs.values
      .where((r) =>
          r.state == BotRunState.running || r.state == BotRunState.claiming)
      .length;

  BotRun? start(BotRunSpec spec) {
    final id = spec.id.toLowerCase();
    if (id.isEmpty || spec.eventId.isEmpty) return null;
    final existing = runs[id];
    if (existing != null) return existing;
    final run = BotRun(spec, spec.startedAt ?? _now())
      ..anon = anonNow?.call() ?? false;
    runs[id] = run;
    notes.remove(id);
    _persist();
    _changed();
    run.done = _send(run);
    return run;
  }

  bool _gone(BotRun run, [int? gen]) =>
      disposed ||
      run.stopped ||
      !identical(runs[run.id], run) ||
      (gen != null && run.gen != gen);

  Map<String, dynamic> _body(BotRun run, [int? maxRuns]) {
    final body = <String, dynamic>{...run.spec.extra, 'eventId': run.eventId};
    final limit = maxRuns ?? clampBotMaxRuns(_maxRuns());
    if (limit > 0) {
      body['maxRuns'] = limit > kBotRunCeiling ? kBotRunCeiling : limit;
    } else {
      body.remove('maxRuns');
    }
    return body;
  }

  Future<void> _send(BotRun run, [int? maxRuns]) async {
    run.state = BotRunState.running;
    run.cap = null;
    final gen = ++run.gen;
    _changed();
    BotRunResponse res;
    try {
      res =
          await transport('pm', _body(run, maxRuns), timeout: kBotRunPmTimeout);
    } catch (_) {
      if (_gone(run, gen)) return;
      return _claim(run);
    }
    if (_gone(run, gen)) return;
    return _handle(run, res.status, res.data);
  }

  Future<void> _handle(
      BotRun run, int status, Map<String, dynamic> data) async {
    if (_gone(run)) return;
    onResponse?.call();
    if (data['runCap'] == true) {
      if (data['free'] == true) {
        _note(
            run,
            BotRunNote(BotRunNoteKind.capFree,
                text: (data['error'] ?? '').toString()));
        _end(run);
        onOpenBuy?.call(false);
        return;
      }
      run.state = BotRunState.capped;
      run.cap = BotRunCap(
        error: (data['error'] ?? '').toString(),
        running: _int(data['running'], 0),
        limit: _int(data['limit'], kBotRunDefaultLimit),
        ceiling: _int(data['ceiling'], kBotRunCeiling),
      );
      _changed();
      return;
    }
    if (status == 202 || data['pending'] == true) return _claim(run);
    if (data['noCredits'] == true) {
      _end(run);
      onNoCredits?.call(data);
      return;
    }
    if (data['priceUnavailable'] == true) {
      _end(run);
      onPriceUnavailable?.call(run);
      return;
    }
    final err = data['error'];
    if (status >= 400 || (err is String && err.isNotEmpty)) {
      _note(
          run,
          BotRunNote(BotRunNoteKind.error,
              text:
                  'Nymbot: ${err is String && err.isNotEmpty ? err : 'request failed'}'));
      _end(run);
      return;
    }
    final missedIds = data['steerMissed'];
    final missed = [
      for (final id in missedIds is List ? missedIds : const [])
        if (id is String && run.steers.containsKey(id)) run.steers[id]!,
    ];
    _end(run);
    if (missed.isNotEmpty && data['stopped'] != true) {
      _note(run,
          BotRunNote(BotRunNoteKind.steerLate, steerText: missed.join('\n\n')));
    }
    await onDelivered(run, data);
  }

  static int _int(Object? v, int fallback) {
    final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return n == null || n < 0 ? fallback : n;
  }

  Future<void> _claim(BotRun run) async {
    if (_gone(run)) return;
    final gen = run.gen;
    run.state = BotRunState.claiming;
    _changed();
    var step = 0;
    while (true) {
      if (_gone(run, gen)) return;
      if (_now() - run.startedAt > kBotRunMaxAge.inMilliseconds) {
        return _fail(run);
      }
      final wait = min(_claimCapMs, _claimFirstMs * pow(2, step).toInt());
      await _sleep(Duration(milliseconds: _jitter(wait)));
      step++;
      if (_gone(run, gen)) return;
      BotRunResponse res;
      try {
        res = await transport('pm-claim', {'eventId': run.eventId});
      } catch (_) {
        continue;
      }
      if (_gone(run, gen)) return;
      var status = res.status;
      var data = res.data;
      if (status == 200) return _handle(run, status, data);
      if (status == 202 || data['pending'] == true) continue;
      if (status == 404 && data['unknown'] == true) return _fail(run);
      if (status == 429) continue;
      try {
        res = await transport('pm', _body(run), timeout: kBotRunPmTimeout);
      } catch (_) {
        continue;
      }
      if (_gone(run, gen)) return;
      status = res.status;
      data = res.data;
      if (status == 202 || data['pending'] == true) continue;
      return _handle(run, status, data);
    }
  }

  void _fail(BotRun run) {
    _note(run, BotRunNote(BotRunNoteKind.failed, spec: run.spec));
    _end(run);
  }

  void _note(BotRun run, BotRunNote note) {
    notes[run.id] = note;
    _changed();
  }

  void _end(BotRun run) {
    if (identical(runs[run.id], run)) runs.remove(run.id);
    run.gen++;
    _persist();
    _changed();
    for (final r in runs.values) {
      if (r.state == BotRunState.waiting) {
        r.done = _send(r);
        return;
      }
    }
  }

  void _changed() {
    if (disposed) return;
    final live = liveCount > 0;
    if (live != _typingOn) {
      _typingOn = live;
      onTyping?.call(live);
    }
    onChanged?.call();
  }

  void _persist() {
    onPersist?.call([
      for (final r in runs.values)
        BotRunSpec(
          id: r.id,
          eventId: r.eventId,
          thread: r.thread,
          content: r.label,
          startedAt: r.startedAt,
          extra: {
            for (final e in r.spec.extra.entries)
              if (e.key != 'pqAnnouncement') e.key: e.value,
          },
        ).toJson(),
    ]);
  }

  Future<void> stop(String id) async {
    final key = id.toLowerCase();
    final run = runs[key];
    var wasSent = run == null;
    if (run != null) {
      wasSent =
          run.state == BotRunState.running || run.state == BotRunState.claiming;
      run.stopped = true;
      _note(run, const BotRunNote(BotRunNoteKind.stopped));
      _end(run);
    }
    if (!wasSent) return;
    try {
      await transport('pm-cancel', {'replyTo': key});
    } catch (_) {}
    if (run == null) {
      remote = [
        for (final r in remote)
          if ('${r['replyTo']}'.toLowerCase() != key) r,
      ];
      _changed();
    }
  }

  Future<void> stopAll() => Future.wait([for (final r in rows()) stop(r.id)]);

  Future<BotSteerOutcome> steer(String id, String text) async {
    final t = text.trim();
    if (t.isEmpty) return BotSteerOutcome.empty;
    if (t.length > kBotRunSteerChars) return BotSteerOutcome.tooLong;
    final key = id.toLowerCase();
    final run = runs[key];
    BotRunResponse res;
    try {
      res = await transport('pm-steer', {'replyTo': key, 'text': t},
          asAnon: run?.anon);
    } catch (_) {
      return BotSteerOutcome.retry;
    }
    if (res.status == 200 && res.data['ok'] == true) {
      final sid = res.data['id'];
      if (run != null && sid is String && sid.isNotEmpty) {
        run.steers[sid] = t;
      } else if (run == null && sid is String && _steerId.hasMatch(sid)) {
        _far[sid] = _FarSteer(
            key, t, threadFor(key), anonNow?.call() ?? false, _now());
        if (_far.length > 50) _far.remove(_far.keys.first);
      }
      return BotSteerOutcome.ok;
    }
    if (res.status == 413) return BotSteerOutcome.tooLong;
    if (res.status == 429 || res.status == 0 || res.status >= 500) {
      return BotSteerOutcome.retry;
    }
    if (res.status == 409 && res.data['final'] == true) {
      return BotSteerOutcome.answering;
    }
    return BotSteerOutcome.finished;
  }

  bool get watchingSteers {
    final now = _now();
    _far.removeWhere((_, s) => now - s.at > kBotRunSteerKeep.inMilliseconds);
    return _far.isNotEmpty;
  }

  Future<void> _checkSteers() async {
    if (_farChecking || !watchingSteers) return;
    _farChecking = true;
    try {
      final live = <String>{
        ...runs.keys,
        for (final r in remote) '${r['replyTo']}'.toLowerCase(),
      };
      final groups = <bool, List<String>>{};
      _far.forEach((id, s) {
        if (live.contains(s.runId)) return;
        if (s.anon != (anonNow?.call() ?? false)) return;
        groups.putIfAbsent(s.anon, () => <String>[]).add(id);
      });
      for (final entry in groups.entries) {
        final ids = entry.value.take(20).toList();
        BotRunResponse res;
        try {
          res = await transport('pm-steer-status', {'ids': ids},
              asAnon: entry.key);
        } catch (_) {
          continue;
        }
        final states = res.data['states'];
        if (disposed || res.status != 200 || states is! Map) continue;
        final missed = <String, List<String>>{};
        final threads = <String, String>{};
        for (final id in ids) {
          final s = _far[id];
          if (s == null) continue;
          final state = states[id];
          if (state == 'pending' || state == null) {
            s.tries++;
            if (s.tries >= 6) _far.remove(id);
            continue;
          }
          _far.remove(id);
          if (state != 'missed') continue;
          missed.putIfAbsent(s.runId, () => <String>[]).add(s.text);
          threads[s.runId] = s.thread;
        }
        missed.forEach((runId, texts) {
          notes[runId] = BotRunNote(BotRunNoteKind.steerLate,
              steerText: texts.join('\n\n'), thread: threads[runId]);
        });
        if (missed.isNotEmpty) _changed();
      }
    } finally {
      _farChecking = false;
    }
  }

  List<BotRunCapOption> capOptions(String id) {
    final run = runs[id.toLowerCase()];
    final cap = run?.cap;
    if (run == null || run.state != BotRunState.capped || cap == null) {
      return const <BotRunCapOption>[];
    }
    return cap.limit >= cap.ceiling
        ? const [BotRunCapOption.wait]
        : const [
            BotRunCapOption.start,
            BotRunCapOption.always,
            BotRunCapOption.wait,
          ];
  }

  int capAlwaysN(BotRunCap cap) => min(cap.running + 1, cap.ceiling);

  void capStart(String id) {
    final run = runs[id.toLowerCase()];
    final cap = run?.cap;
    if (run == null || run.state != BotRunState.capped || cap == null) return;
    run.done = _send(run, cap.running + 1);
  }

  void capAlways(String id) {
    final run = runs[id.toLowerCase()];
    final cap = run?.cap;
    if (run == null || run.state != BotRunState.capped || cap == null) return;
    _setMaxRuns(capAlwaysN(cap));
    run.done = _send(run);
  }

  void capWait(String id) {
    final run = runs[id.toLowerCase()];
    if (run == null || run.state != BotRunState.capped) return;
    run.state = BotRunState.waiting;
    _changed();
  }

  void retry(String id) {
    final key = id.toLowerCase();
    final note = notes[key];
    final spec = note?.spec;
    if (note == null || note.kind != BotRunNoteKind.failed || spec == null) {
      return;
    }
    notes.remove(key);
    start(BotRunSpec(
      id: spec.id,
      eventId: spec.eventId,
      thread: spec.thread,
      content: spec.content,
      extra: spec.extra,
      startedAt: _now(),
    ));
  }

  void dismissNote(String id) {
    if (notes.remove(id.toLowerCase()) != null) _changed();
  }

  void resume(List<Object?> inflight) {
    final now = _now();
    for (final raw in inflight) {
      final spec = BotRunSpec.fromJson(raw);
      if (spec == null || spec.eventId.isEmpty) continue;
      final id = spec.id.toLowerCase();
      if (runs.containsKey(id)) continue;
      if (now - (spec.startedAt ?? 0) > kBotRunMaxAge.inMilliseconds) {
        continue;
      }
      final run = BotRun(spec, spec.startedAt ?? now);
      runs[id] = run;
      run.done = _claim(run);
    }
    _persist();
  }

  Future<void> poll() async {
    BotRunResponse res;
    try {
      res = await transport('pm-runs', <String, dynamic>{});
    } catch (_) {
      return;
    }
    final list = res.data['runs'];
    if (res.status != 200 || list is! List) {
      remote = const <Map<String, dynamic>>[];
      _changed();
      return;
    }
    remote = [
      for (final r in list)
        if (r is Map && r['replyTo'] is String && r['app'] != 'nymbot')
          r.cast<String, dynamic>(),
    ];
    for (final r in remote) {
      final run = runs['${r['replyTo']}'.toLowerCase()];
      if (run == null) continue;
      run.progress = r['progress'] is String ? r['progress'] as String : '';
    }
    if (watchingSteers) unawaited(_checkSteers());
    for (final r in runs.values) {
      final cap = r.cap;
      if (r.state == BotRunState.waiting &&
          cap != null &&
          remote.length < cap.limit) {
        r.done = _send(r);
        break;
      }
    }
    _changed();
  }

  List<BotRunRow> rows() {
    final seen = <String>{};
    final out = <BotRunRow>[];
    for (final r in runs.values) {
      seen.add(r.id);
      out.add(BotRunRow(
        id: r.id,
        label: r.label,
        progress: r.progress,
        state: r.state,
        startedAt: r.startedAt,
        thread: r.thread,
        remote: false,
      ));
    }
    for (final r in remote) {
      final id = '${r['replyTo']}'.toLowerCase();
      if (!seen.add(id)) continue;
      out.add(BotRunRow(
        id: id,
        label: r['label'] is String ? r['label'] as String : '',
        progress: r['progress'] is String ? r['progress'] as String : '',
        state: BotRunState.running,
        startedAt: (r['startedAt'] as num?)?.toInt() ?? 0,
        thread: r['thread'] is String ? r['thread'] as String : '',
        remote: true,
      ));
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }

  String threadFor(String id) {
    final key = id.toLowerCase();
    final run = runs[key];
    if (run != null) return run.thread;
    for (final r in remote) {
      if ('${r['replyTo']}'.toLowerCase() == key) {
        return r['thread'] is String ? r['thread'] as String : '';
      }
    }
    return '';
  }

  void dispose() {
    disposed = true;
  }
}
