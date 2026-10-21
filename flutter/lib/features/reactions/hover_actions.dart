const List<String> kHoverActionIds = [
  'react',
  'reply',
  'replyPrivately',
  'thread',
  'copy',
  'translate',
  'save',
  'keep',
  'zap',
  'edit',
  'delete',
  'editHistory',
  'eventDetails',
  'report',
];

const List<String> kHoverActionDefaults = ['react', 'reply', 'thread'];

const int kHoverActionSlots = 3;

const Map<String, List<String>> kHoverActionVariants = {
  'save': ['save', 'unsave'],
  'keep': ['keep', 'unkeep'],
};

List<String> hoverActionVariants(String id) =>
    kHoverActionVariants[id] ?? [id];

List<String> normalizeHoverActions(Object? v) {
  if (v is! List || v.length != kHoverActionSlots) {
    return [...kHoverActionDefaults];
  }
  final out = <String>[];
  for (final id in v) {
    if (id is! String || !kHoverActionIds.contains(id) || out.contains(id)) {
      return [...kHoverActionDefaults];
    }
    out.add(id);
  }
  return out;
}

List<String> pickHoverAction(Object? slots, int index, String id) {
  final cur = normalizeHoverActions(slots);
  if (index < 0 || index >= kHoverActionSlots || !kHoverActionIds.contains(id)) {
    return cur;
  }
  final j = cur.indexOf(id);
  if (j >= 0) cur[j] = cur[index];
  cur[index] = id;
  return cur;
}

List<String> resolveHoverActions(Object? slots, List<String> available) {
  String? offered(String id) {
    for (final c in hoverActionVariants(id)) {
      if (available.contains(c)) return c;
    }
    return null;
  }

  final chosen = normalizeHoverActions(slots);
  final spare = <String>{
    for (final id in [...kHoverActionDefaults, ...kHoverActionIds])
      if (!chosen.contains(id) && offered(id) != null) id,
  }.toList();
  final out = <String>[];
  for (final id in chosen) {
    final c =
        offered(id) ?? (spare.isEmpty ? null : offered(spare.removeAt(0)));
    if (c != null) out.add(c);
  }
  return out;
}
