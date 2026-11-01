const int kCatchUpFirst = 4;

const int kCatchUpBatch = 4;

const Duration kCatchUpYield = Duration(milliseconds: 120);

class CatchUpPlan {
  const CatchUpPlan(this.first, this.batches, this.skipped);

  final List<String> first;
  final List<List<String>> batches;
  final List<String> skipped;

  int get restored =>
      first.length + batches.fold<int>(0, (n, b) => n + b.length);
}

CatchUpPlan planChannelCatchUp(
  Iterable<String> keys, {
  String? open,
  Map<String, int> lastActivityMs = const {},
  Map<String, int> restoredAtMs = const {},
  int coveredSinceMs = 0,
  int first = kCatchUpFirst,
  int batch = kCatchUpBatch,
}) {
  final openKey = open?.toLowerCase();
  final seen = <String>{};
  final todo = <(String, int)>[];
  final skipped = <String>[];
  for (final k in keys) {
    final name = k.toLowerCase();
    if (name.isEmpty || !seen.add(name)) continue;
    final at = restoredAtMs[name] ?? 0;
    if (name != openKey && coveredSinceMs > 0 && at >= coveredSinceMs) {
      skipped.add(k);
      continue;
    }
    todo.add((k, todo.length));
  }
  int last(String k) => lastActivityMs['#${k.toLowerCase()}'] ?? 0;
  todo.sort((a, b) {
    final ao = a.$1.toLowerCase() == openKey;
    final bo = b.$1.toLowerCase() == openKey;
    if (ao != bo) return ao ? -1 : 1;
    final c = last(b.$1).compareTo(last(a.$1));
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  final ordered = [for (final e in todo) e.$1];
  final head = ordered.take(first).toList();
  final rest = ordered.skip(first).toList();
  final step = batch < 1 ? 1 : batch;
  return CatchUpPlan(head, [
    for (var i = 0; i < rest.length; i += step)
      rest.sublist(i, i + step < rest.length ? i + step : rest.length),
  ], skipped);
}

Future<void> runChannelCatchUp(
  CatchUpPlan plan,
  Future<void> Function(List<String> batch) restore, {
  bool Function()? stopped,
  Duration pause = kCatchUpYield,
}) async {
  await restore(plan.first);
  for (final batch in plan.batches) {
    if (stopped?.call() ?? false) return;
    await Future<void>.delayed(pause);
    await restore(batch);
  }
}
