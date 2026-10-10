typedef LayoutTr = String Function(String s, [Map<String, Object?>? vars]);

String _same(String s, [Map<String, Object?>? vars]) => s;

const int kRowPreviewMax = 120;

const String kColorfulHint =
    'Tint message text with each sender\'s color. Off keeps text neutral and colors only the nym and avatar.';

const String kHidePreviewsHint =
    'Hide the last-message line under each chat in the sidebar. Previews come only from messages already on this device.';

String _fill(LayoutTr t, String s, [Map<String, Object?>? vars]) {
  final out = t(s, vars);
  if (vars == null) return out;
  return out.replaceAllMapped(RegExp(r'\{(\w+)\}'),
      (m) => vars.containsKey(m[1]) ? '${vars[m[1]]}' : m[0]!);
}

String stripMarkdown(String input) {
  if (input.isEmpty) return '';
  var s = input.replaceAll(RegExp(r'\r\n?'), '\n');
  s = s.replaceAllMapped(
      RegExp(r'```[^\n`]*\n?([\s\S]*?)```'), (m) => m[1] ?? '');
  final lines = s.split('\n');
  final kept = lines.where((l) => !RegExp(r'^\s*>').hasMatch(l)).toList();
  final use = kept.any((l) => l.trim().isNotEmpty)
      ? kept
      : lines.map((l) => l.replaceFirst(RegExp(r'^\s*>+\s?'), '')).toList();
  s = use
      .map((l) => l
          .replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s+'), '')
          .replaceFirst(RegExp(r'^-#\s+'), '')
          .replaceFirst(RegExp(r'^\s*(?:[-*+]|\d{1,3}[.)])\s+'), ''))
      .join('\n');
  s = s.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\([^)\s]*\)'), (m) => m[1] ?? '');
  s = s.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\((?:[^)\s]+)\)'), (m) => m[1] ?? '');
  s = s.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1] ?? '');
  s = s.replaceAllMapped(
      RegExp(r'(\*\*|__|~~)(?=\S)([\s\S]*?\S)\1'), (m) => m[2] ?? '');
  s = s.replaceAllMapped(RegExp(r'(^|[^\w*])\*(?=\S)([^*\n]*?\S)\*(?![\w*])'),
      (m) => '${m[1]}${m[2]}');
  s = s.replaceAllMapped(RegExp(r'(^|[^\w_])_(?=\S)([^_\n]*?\S)_(?![\w_])'),
      (m) => '${m[1]}${m[2]}');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > kRowPreviewMax) {
    s = '${s.substring(0, kRowPreviewMax - 1).trimRight()}…';
  }
  return s;
}

final RegExp _senderTail = RegExp(r'^[0-9a-f]{4}$', caseSensitive: false);

String senderSuffix(String pubkey) {
  final tail = pubkey.length >= 4 ? pubkey.substring(pubkey.length - 4) : '';
  return _senderTail.hasMatch(tail) ? '#$tail' : '';
}

({String name, String sfx})? _previewSender(
    String kind, String author, String pubkey, bool self, LayoutTr t) {
  if (self) return (name: _fill(t, 'You'), sfx: '');
  if (kind == 'pm') return null;
  return author.isEmpty ? null : (name: author, sfx: senderSuffix(pubkey));
}

String rowPreview({
  required String kind,
  String author = '',
  String pubkey = '',
  bool self = false,
  String text = '',
  bool hide = false,
  bool locked = false,
  String redacted = '',
  LayoutTr t = _same,
}) {
  if (hide) return '';
  if (locked) return redacted;
  final body = stripMarkdown(text);
  if (body.isEmpty) return '';
  final who = _previewSender(kind, author, pubkey, self, t);
  return who != null && who.name.isNotEmpty
      ? '${who.name}${who.sfx}: $body'
      : body;
}

final RegExp _mentionSuffix =
    RegExp(r'@[^@#\n]*?(?<!\s)#[0-9a-f]{4}\b', caseSensitive: false);

List<List<int>> mentionSuffixRanges(String text, [int from = 0]) => [
      for (final m in _mentionSuffix.allMatches(text))
        [from + m.end - 5, from + m.end],
    ];

({String text, List<List<int>> dim, List<int>? sender, int bodyAt})
    rowPreviewParts({
  required String kind,
  String author = '',
  String pubkey = '',
  bool self = false,
  String text = '',
  bool hide = false,
  bool locked = false,
  String redacted = '',
  LayoutTr t = _same,
}) {
  final out = rowPreview(
    kind: kind,
    author: author,
    pubkey: pubkey,
    self: self,
    text: text,
    hide: hide,
    locked: locked,
    redacted: redacted,
    t: t,
  );
  if (out.isEmpty || hide || locked) {
    return (text: out, dim: const <List<int>>[], sender: null, bodyAt: 0);
  }
  final body = stripMarkdown(text);
  final from = out.length - body.length;
  final who = _previewSender(kind, author, pubkey, self, t);
  final sender = who != null && who.name.isNotEmpty && who.sfx.isNotEmpty
      ? [who.name.length, who.name.length + who.sfx.length]
      : null;
  final whole = from >= 0 && out.substring(from) == body;
  final mentions =
      whole ? mentionSuffixRanges(body, from) : const <List<int>>[];
  return (
    text: out,
    dim: sender == null ? mentions : [[sender[0], sender[1]], ...mentions],
    sender: sender,
    bodyAt: whole ? from : 0,
  );
}

String relativeTime(int nowMs, int tsMs, [LayoutTr t = _same]) {
  if (tsMs == 0) return '';
  final diff = nowMs - tsMs;
  final sec = diff <= 0 ? 0 : diff ~/ 1000;
  if (sec < 60) return _fill(t, 'now');
  final min = sec ~/ 60;
  if (min < 60) return _fill(t, '{n}m', {'n': min});
  final h = min ~/ 60;
  if (h < 24) return _fill(t, '{n}h', {'n': h});
  final d = h ~/ 24;
  if (d < 7) return _fill(t, '{n}d', {'n': d});
  if (d < 365) return _fill(t, '{n}w', {'n': d ~/ 7});
  return _fill(t, '{n}y', {'n': d ~/ 365});
}

const int kPhoneMax = 768;

const int kDockMin = 1280;
const int kSettingsTwoPaneMin = 1025;

const int kCallLabelMin = 1024;
const int kDockWidth = 320;
const int kReadCh = 85;

String infoPanelMode(num width) => width >= kDockMin ? 'docked' : 'overlay';

const double kChatHeaderHeightCompact = 60;
const double kChatHeaderHeightWide = 64;

double chatHeaderHeight(num width) =>
    width <= 1024 ? kChatHeaderHeightCompact : kChatHeaderHeightWide;

String settingsMode(num width) {
  return width >= kSettingsTwoPaneMin ? 'two-pane' : 'page';
}

const double kChEm = 0.55;
const double kPreviewBodyMinEm = 2;

double readWidthPx(num fontSize) => (kReadCh * kChEm * fontSize).roundToDouble();

final RegExp _pubkeyRe = RegExp(r'^[0-9a-fA-F]{64}$');

String notifGroupKey(String type, String route, String sender) {
  if (type == 'group') return route.isNotEmpty ? 'group:$route' : 'other';
  if (type == 'channel' || type == 'geohash') {
    return route.isNotEmpty ? 'channel:${route.toLowerCase()}' : 'other';
  }
  if (type == 'call') {
    if (_pubkeyRe.hasMatch(route)) return 'pm:${route.toLowerCase()}';
    if (route.isNotEmpty) return 'group:$route';
    return sender.isNotEmpty ? 'pm:${sender.toLowerCase()}' : 'other';
  }
  final peer = sender.isNotEmpty ? sender : (_pubkeyRe.hasMatch(route) ? route : '');
  return peer.isNotEmpty ? 'pm:${peer.toLowerCase()}' : 'other';
}

List<({String key, List<int> items})> groupNotifications(List<String> keys) {
  final order = <({String key, List<int> items})>[];
  final at = <String, int>{};
  for (var i = 0; i < keys.length; i++) {
    final k = keys[i];
    final idx = at.putIfAbsent(k, () {
      order.add((key: k, items: <int>[]));
      return order.length - 1;
    });
    order[idx].items.add(i);
  }
  return order;
}

bool formatToolbarVisible(
        {required bool draft, required bool focused, bool overlay = false}) =>
    draft && (focused || overlay);

const List<String> kRoleSections = ['owner', 'admins', 'mods', 'members'];

List<({String key, List<int> items})> memberSections(List<String> roles) {
  final out = [for (final k in kRoleSections) (key: k, items: <int>[])];
  for (var i = 0; i < roles.length; i++) {
    final r = roles[i];
    final k = r == 'owner'
        ? 0
        : r == 'admin'
            ? 1
            : r == 'mod'
                ? 2
                : 3;
    out[k].items.add(i);
  }
  return out.where((s) => s.items.isNotEmpty).toList();
}

String presenceClass(String status) {
  if (status == 'online' || status == 'away') return status;
  return status == 'hidden' ? '' : 'offline';
}

const int kSidebarMin = 240;
const int kSidebarMax = 400;
const int kSidebarDefault = 290;

int clampSidebarWidth(Object? w) {
  double? n;
  if (w is num) {
    n = w.toDouble();
  } else if (w is String && w.trim().isNotEmpty) {
    n = double.tryParse(w.trim());
  }
  if (n == null || n.isNaN || n.isInfinite) return kSidebarDefault;
  return n.clamp(kSidebarMin.toDouble(), kSidebarMax.toDouble()).round();
}

const int kColumnMin = 280;
const int kColumnMax = 560;
const int kColumnDefault = 360;
const int kAddRail = 56;

int clampColumnWidth(Object? w) {
  double? n;
  if (w is num) {
    n = w.toDouble();
  } else if (w is String && w.trim().isNotEmpty) {
    n = double.tryParse(w.trim());
  }
  if (n == null || n.isNaN || n.isInfinite) return kColumnDefault;
  return n.clamp(kColumnMin.toDouble(), kColumnMax.toDouble()).round();
}

const double kHeaderMinTitle = 96;

const List<String> kHeaderEssential = ['bell', 'more', 'rejoin'];

const Map<String, List<String>> kHeaderPriority = {
  'channel': ['share', 'favorite'],
  'pm': ['video', 'audio'],
  'group': ['video', 'audio'],
  'mesh': ['addDevice', 'ghost'],
};

const Map<String, String> kHeaderKinds = {
  'channel': 'channel',
  'geohash': 'channel',
  'thread': 'channel',
  'pm': 'pm',
  'bot': 'pm',
  'group': 'group',
  'groupcall': 'group',
  'mesh': 'mesh',
};

({double box, double gap, double pitch}) headerActionMetrics(
    {required bool phone, required bool targets}) {
  final double box = phone && !targets ? 34 : 40;
  final double gap = targets ? 4 : 2;
  return (box: box, gap: gap, pitch: box + gap);
}

({List<String> moved, double room, bool more}) headerOverflow({
  required String kind,
  required List<String> actions,
  required double base,
  required double step,
  required bool more,
  double min = kHeaderMinTitle,
}) {
  var room = base;
  var shown = more;
  final moved = <String>[];
  if (room < min) {
    for (final id in kHeaderPriority[kind] ?? const <String>[]) {
      if (!actions.contains(id) || kHeaderEssential.contains(id)) continue;
      moved.add(id);
      if (shown) {
        room += step;
      } else {
        shown = true;
      }
      if (room >= min) break;
    }
  }
  if (room <= base) return (moved: const <String>[], room: base, more: more);
  return (moved: moved, room: room, more: shown);
}
