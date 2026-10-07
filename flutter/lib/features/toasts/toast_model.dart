enum ToastKind { info, success, error }

class ToastConfig {
  const ToastConfig._();

  static const int maxVisible = 3;
  static const int dedupeMs = 2000;
  static const Map<ToastKind, int> baseMs = {
    ToastKind.info: 3500,
    ToastKind.success: 3500,
    ToastKind.error: 6000,
  };
  static const Map<ToastKind, int> capMs = {
    ToastKind.info: 8000,
    ToastKind.success: 8000,
    ToastKind.error: 10000,
  };
  static const int readableChars = 80;
  static const int msPerExtraChar = 40;
  static const double swipeDismissPx = 60;
  static const int undoMs = 5000;
  static const double offsetPx = 12;
  static const double gutterPx = 16;
  static const double maxWidthPx = 480;
}

const List<String> kToastErrorWords = [
  'failed', 'fail', 'could not', "couldn't", 'cannot', "can't", 'unable',
  'error', 'invalid', 'not found', 'not available', 'unavailable',
  'not supported', 'rejected', 'denied', 'too many', 'slow down',
  'too large', 'too long', 'not connected', 'lost', 'no longer',
  'not allowed', 'disabled for', 'expired', 'only the', 'must be',
  'you must', 'unknown', 'is blocked', 'require', 'requires',
];

const List<String> kToastSuccessWords = [
  'copied', 'saved', 'success', 'successfully', 'added', 'enabled',
  'activated', 'applied', 'sent', 'created', 'updated', 'restored',
  'uploaded', 'joined', 'transferred', 'granted', 'cleared', 'deleted',
  'removed', 'unblocked', 'blocked', 'complete', 'completed', 'downloaded',
  'renamed', 'revoked', 'received',
];

RegExp _wordsRe(List<String> words) => RegExp(
    '(^|[^a-z0-9])(${words.map(RegExp.escape).join('|')})(?![a-z0-9])');

final RegExp _errorRe = _wordsRe(kToastErrorWords);
final RegExp _successRe = _wordsRe(kToastSuccessWords);

String normalizeToastText(String? text) => (text ?? '')
    .replaceAll(RegExp('[‘’]'), "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

ToastKind classifyToast(String? text) {
  final s = normalizeToastText(text);
  if (s.startsWith('❌')) return ToastKind.error;
  if (s.startsWith('✅')) return ToastKind.success;
  final low = s.toLowerCase();
  if (_errorRe.hasMatch(low)) return ToastKind.error;
  if (_successRe.hasMatch(low)) return ToastKind.success;
  return ToastKind.info;
}

ToastKind? toastKindFromName(String? name) {
  for (final k in ToastKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

int toastDurationMs(String? text, ToastKind kind) {
  final len = normalizeToastText(text).length;
  final extra = len > ToastConfig.readableChars
      ? (len - ToastConfig.readableChars) * ToastConfig.msPerExtraChar
      : 0;
  final total = ToastConfig.baseMs[kind]! + extra;
  final cap = ToastConfig.capMs[kind]!;
  return total < cap ? total : cap;
}

class ToastItem {
  const ToastItem({
    required this.id,
    required this.key,
    required this.text,
    required this.kind,
    required this.expiresAt,
    this.paused = false,
    this.remaining = 0,
    this.action,
  });

  final int id;
  final String key;
  final String text;
  final ToastKind kind;
  final int expiresAt;
  final bool paused;
  final int remaining;
  final String? action;

  ToastItem copyWith({int? expiresAt, bool? paused, int? remaining}) =>
      ToastItem(
        id: id,
        key: key,
        text: text,
        kind: kind,
        expiresAt: expiresAt ?? this.expiresAt,
        paused: paused ?? this.paused,
        remaining: remaining ?? this.remaining,
        action: action,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'kind': kind.name,
        'expiresAt': expiresAt,
        'paused': paused,
        'remaining': remaining,
        if (action != null) 'action': action,
      };
}

class ToastQueue {
  const ToastQueue({
    this.toasts = const [],
    this.recent = const {},
    this.seq = 0,
  });

  final List<ToastItem> toasts;
  final Map<String, int> recent;
  final int seq;

  int? get nextExpiry {
    int? next;
    for (final t in toasts) {
      if (t.paused) continue;
      if (next == null || t.expiresAt < next) next = t.expiresAt;
    }
    return next;
  }
}

class ToastPush {
  const ToastPush(this.queue, this.id, this.deduped, this.evicted);
  final ToastQueue queue;
  final int? id;
  final bool deduped;
  final List<int> evicted;
}

String _keyOf(String text, ToastKind kind) =>
    '${kind.name}\u0000${normalizeToastText(text)}';

Map<String, int> _prune(Map<String, int> recent, int now) => {
      for (final e in recent.entries)
        if (now - e.value < ToastConfig.dedupeMs) e.key: e.value,
    };

ToastPush pushToast(ToastQueue q, String text, ToastKind? kind, int now,
    {String? action}) {
  final k = kind ?? classifyToast(text);
  final label = action?.trim();
  final hasAction = label != null && label.isNotEmpty;
  final key = hasAction ? '${k.name}\u0001${q.seq + 1}' : _keyOf(text, k);
  final recent = _prune(q.recent, now);
  final liveIdx = q.toasts.indexWhere((t) => t.key == key);
  if (liveIdx >= 0) {
    final live = q.toasts[liveIdx];
    final duration = toastDurationMs(text, k);
    final toasts = [...q.toasts];
    toasts[liveIdx] = live.paused
        ? live.copyWith(remaining: duration)
        : live.copyWith(expiresAt: now + duration);
    recent[key] = now;
    return ToastPush(ToastQueue(toasts: toasts, recent: recent, seq: q.seq),
        live.id, true, const []);
  }
  if (recent.containsKey(key)) {
    return ToastPush(
        ToastQueue(toasts: q.toasts, recent: recent, seq: q.seq),
        null,
        true,
        const []);
  }
  final seq = q.seq + 1;
  var toasts = [
    ...q.toasts,
    ToastItem(
      id: seq,
      key: key,
      text: normalizeToastText(text),
      kind: k,
      expiresAt: now + (hasAction ? ToastConfig.undoMs : toastDurationMs(text, k)),
      action: hasAction ? label : null,
    ),
  ];
  final evicted = <int>[];
  while (toasts.length > ToastConfig.maxVisible) {
    evicted.add(toasts.first.id);
    toasts = toasts.sublist(1);
  }
  recent[key] = now;
  return ToastPush(
      ToastQueue(toasts: toasts, recent: recent, seq: seq), seq, false, evicted);
}

ToastQueue dismissToastIn(ToastQueue q, int id) => ToastQueue(
    toasts: q.toasts.where((t) => t.id != id).toList(),
    recent: q.recent,
    seq: q.seq);

ToastQueue pauseToastIn(ToastQueue q, int id, int now) => ToastQueue(
      toasts: [
        for (final t in q.toasts)
          t.id == id && !t.paused
              ? t.copyWith(
                  paused: true,
                  remaining: t.expiresAt - now > 0 ? t.expiresAt - now : 0)
              : t,
      ],
      recent: q.recent,
      seq: q.seq,
    );

ToastQueue resumeToastIn(ToastQueue q, int id, int now) => ToastQueue(
      toasts: [
        for (final t in q.toasts)
          t.id == id && t.paused
              ? t.copyWith(
                  paused: false, expiresAt: now + t.remaining, remaining: 0)
              : t,
      ],
      recent: q.recent,
      seq: q.seq,
    );

({ToastQueue queue, List<int> expired}) expireToasts(ToastQueue q, int now) {
  final gone = [
    for (final t in q.toasts)
      if (!t.paused && t.expiresAt <= now) t.id,
  ];
  if (gone.isEmpty) return (queue: q, expired: const <int>[]);
  return (
    queue: ToastQueue(
        toasts: q.toasts.where((t) => !gone.contains(t.id)).toList(),
        recent: q.recent,
        seq: q.seq),
    expired: gone,
  );
}
