import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

const int kPsFirst = 20;
const int kPsStep = 50;
const int kPsMax = 500;
const int kPsPendingMax = 99;
const int kPsClip = 240;
const int kPsMediaMax = 4;
const int kPsWindowSec = 86400;
const String kPsSetting = 'sidebarChannelsMode';
const String kPsDefaultChannel = 'nymchat';
const List<String> kPsModes = ['list', 'stream'];
const List<String> kPsHideFlags = [
  'deleted',
  'pendingDeletion',
  'gated',
  'contentHidden',
  'blocked',
  'expired',
  'threadReply',
  'botThreadForeign',
];

const String kPsLabelText = '{time}, {channel}, {nym}: {text}';
const String kPsLabelBare = '{time}, {channel}, {nym}';

bool psIsMode(Object? v) => v == 'list' || v == 'stream';

String psNormalizeMode(Object? v) => v == 'stream' ? 'stream' : 'list';

List<String> psStreamKeys({
  required List<String> channels,
  Set<String> blocked = const {},
  Set<String> hidden = const {},
  Set<String> pinned = const {},
  Set<String> locked = const {},
  bool hideNonPinned = false,
  bool pmOnly = false,
}) {
  if (pmOnly) return const [];
  final out = <String>[];
  final seen = <String>{};
  final all = channels.contains(kPsDefaultChannel)
      ? channels
      : [kPsDefaultChannel, ...channels];
  for (final key in all) {
    if (key.isEmpty || !seen.add(key)) continue;
    if (blocked.contains(key)) continue;
    if (key != kPsDefaultChannel) {
      if (hidden.contains(key)) continue;
      if (hideNonPinned && !pinned.contains(key)) continue;
    }
    if (locked.contains(key)) continue;
    out.add(key);
  }
  return out;
}

bool psFlagsVisible(Map<String, Object?> flags) {
  for (final k in kPsHideFlags) {
    if (flags[k] == true) return false;
  }
  return true;
}

final RegExp _ws = RegExp(r'\s+');

final RegExp _rxToken = RegExp(
    r'(https?://[^\s<>"]+\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(?:\?[^\s<>"]*)?)|(https?://[^\s<>"]+)|:([a-zA-Z0-9_]+):|(@[^\s]+)',
    caseSensitive: false);

const Set<String> _videoExt = {'mp4', 'webm', 'ogg', 'mov'};

@immutable
class PsPart {
  const PsPart(this.kind, this.value);

  final String kind;
  final String value;

  @override
  bool operator ==(Object other) =>
      other is PsPart && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

@immutable
class PsParts {
  const PsParts(this.parts, this.media, this.clipped);

  final List<PsPart> parts;
  final List<PsPart> media;
  final bool clipped;

  static const empty = PsParts(<PsPart>[], <PsPart>[], false);

  String get text => [
        for (final p in parts) p.kind == 'e' ? ':${p.value}:' : p.value
      ].join();

  @override
  bool operator ==(Object other) =>
      other is PsParts &&
      other.clipped == clipped &&
      listEquals(other.parts, parts) &&
      listEquals(other.media, media);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(parts), Object.hashAll(media), clipped);
}

PsParts psParts(String s,
    {Set<String> emoji = const {}, Map<String, String> builtin = const {}}) {
  final flat = s.replaceAll(_ws, ' ').trim();
  final out = <List<String>>[];
  final media = <PsPart>[];
  var left = kPsClip;
  var clipped = false;
  var gap = false;
  void pushText(String t) {
    gap = false;
    if (t.isEmpty) return;
    if (out.isNotEmpty && out.last[0] == 't') {
      out.last[1] += t;
    } else {
      out.add(['t', t]);
    }
  }

  String lead(String t) {
    final last = out.isEmpty ? null : out.last;
    return gap &&
            t.startsWith(' ') &&
            (last == null || (last[0] == 't' && last[1].endsWith(' ')))
        ? t.substring(1)
        : t;
  }

  final toks = <(String, String)>[];
  var at = 0;
  for (final mt in _rxToken.allMatches(flat)) {
    if (mt.start > at) toks.add(('text', flat.substring(at, mt.start)));
    if (mt[1] != null) {
      toks.add((_videoExt.contains(mt[2]!.toLowerCase()) ? 'v' : 'i', mt[1]!));
    } else if (mt[3] != null) {
      toks.add(('atom', mt[3]!));
    } else if (mt[4] != null) {
      final code = mt[4]!;
      final std = builtin[code.toLowerCase()];
      if (std != null && std.isNotEmpty) {
        toks.add(('std', std));
      } else if (emoji.contains(code)) {
        toks.add(('e', code));
      } else {
        toks.add(('atom', mt[0]!));
      }
    } else {
      toks.add(('atom', mt[5]!));
    }
    at = mt.end;
  }
  if (at < flat.length) toks.add(('text', flat.substring(at)));
  for (final (k, v) in toks) {
    if (k == 'i' || k == 'v') {
      if (media.length < kPsMediaMax) media.add(PsPart(k, v));
      gap = true;
      continue;
    }
    if (clipped) continue;
    if (k == 'text') {
      final t = lead(v);
      final g = t.characters;
      if (g.length <= left) {
        pushText(t);
        left -= g.length;
        continue;
      }
      pushText(g.take(left).toString());
      left = 0;
      clipped = true;
      continue;
    }
    final n = k == 'e' || k == 'std' ? 1 : v.characters.length;
    if (n > left) {
      clipped = true;
      continue;
    }
    left -= n;
    if (k == 'e') {
      out.add(['e', v]);
      gap = false;
    } else {
      pushText(v);
    }
  }
  if (out.isNotEmpty && out.first[0] == 't') {
    out.first[1] = out.first[1].replaceFirst(RegExp(r'^ +'), '');
    if (out.first[1].isEmpty) out.removeAt(0);
  }
  if (!clipped && out.isNotEmpty && out.last[0] == 't') {
    out.last[1] = out.last[1].replaceFirst(RegExp(r' +$'), '');
    if (out.last[1].isEmpty) out.removeLast();
  }
  if (clipped) pushText('…');
  return PsParts(
      List.unmodifiable([for (final p in out) PsPart(p[0], p[1])]),
      List.unmodifiable(media),
      clipped);
}

String psClip(String s) => psParts(s).text;

@immutable
class PsStamp {
  const PsStamp(
      {required this.t, required this.ms, required this.key, required this.id});

  final int t;
  final int ms;
  final String key;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is PsStamp &&
      other.t == t &&
      other.ms == ms &&
      other.key == key &&
      other.id == id;

  @override
  int get hashCode => Object.hash(t, ms, key, id);
}

int psCompareNewest(PsStamp a, PsStamp b) {
  if (a.t != b.t) return b.t - a.t;
  if (a.ms > a.t * 1000 && b.ms > b.t * 1000 && a.ms != b.ms) {
    return b.ms - a.ms;
  }
  if (a.key != b.key) return a.key.compareTo(b.key) < 0 ? -1 : 1;
  return 0;
}

class PsList<M> {
  const PsList(this.key, this.msgs);

  final String key;
  final List<M> msgs;
}

@immutable
class PsHold {
  const PsHold({this.anchor, this.tail, this.frozen = const []});

  final PsStamp? anchor;
  final PsStamp? tail;
  final List<String> frozen;
}

@immutable
class PsState {
  const PsState({this.shown = kPsFirst, this.hold});

  final int shown;
  final PsHold? hold;
}

@immutable
class PsButton {
  const PsButton(this.kind, this.n, this.next);

  final String kind;
  final int n;
  final int next;

  @override
  bool operator ==(Object other) =>
      other is PsButton &&
      other.kind == kind &&
      other.n == n &&
      other.next == next;

  @override
  int get hashCode => Object.hash(kind, n, next);
}

@immutable
class PsRow<M> {
  const PsRow(this.stamp, this.m);

  final PsStamp stamp;
  final M m;

  String get key => stamp.key;
  String get id => stamp.id;
}

class PsPage<M> {
  const PsPage({
    required this.rows,
    required this.pendingIds,
    required this.remaining,
    required this.shown,
    required this.held,
    required this.buttons,
    this.pendingMore = false,
  });

  final List<PsRow<M>> rows;
  final List<String> pendingIds;
  final bool pendingMore;
  final int remaining;
  final int shown;
  final bool held;
  final List<PsButton> buttons;

  int get pending => pendingIds.length + (pendingMore ? 1 : 0);
}

class _Cursor<M> {
  _Cursor(this.key, this.msgs) : i = msgs.length - 1;

  final String key;
  final List<M> msgs;
  int i;
  PsStamp? s;
  M? m;
}

void psWalk<M>(
  List<PsList<M>> lists, {
  required int Function(M) at,
  required int Function(M) ms,
  required String Function(M) id,
  required bool Function(M, String key) visible,
  required bool Function(PsStamp s, M m) visit,
  int? floorSec,
  int? Function()? seek,
}) {
  final cur = <_Cursor<M>>[
    for (final l in lists)
      if (l.msgs.isNotEmpty) _Cursor<M>(l.key, l.msgs),
  ];
  void advance(_Cursor<M> c) {
    while (c.i >= 0) {
      final m = c.msgs[c.i];
      final s = PsStamp(t: at(m), ms: ms(m), key: c.key, id: id(m));
      if (floorSec != null && s.t < floorSec) {
        c.i = -1;
        break;
      }
      c.i--;
      if (visible(m, c.key)) {
        c.s = s;
        c.m = m;
        return;
      }
    }
    c.s = null;
    c.m = null;
  }

  int below(_Cursor<M> c, int sec) {
    var lo = 0;
    var hi = c.i;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (at(c.msgs[mid]) <= sec) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return hi;
  }

  cur.forEach(advance);
  var live = cur.where((c) => c.s != null).toList();
  while (live.isNotEmpty) {
    var best = live.first;
    for (var j = 1; j < live.length; j++) {
      if (psCompareNewest(live[j].s!, best.s!) < 0) best = live[j];
    }
    final t = best.s!.t;
    if (!visit(best.s!, best.m as M)) return;
    final sec = seek?.call();
    if (sec != null && t > sec) {
      for (final c in live) {
        final s = c.s;
        if (s == null || s.t <= sec) continue;
        final b = below(c, sec);
        if (b < c.i) c.i = b;
        advance(c);
      }
      live = live.where((c) => c.s != null).toList();
      continue;
    }
    advance(best);
    if (best.s == null) live = live.where((c) => c.s != null).toList();
  }
}

PsPage<M> psPage<M>(
  List<PsList<M>> lists,
  PsState state, {
  required int nowSec,
  required int Function(M) at,
  required int Function(M) ms,
  required String Function(M) id,
  required bool Function(M, String key) visible,
  int max = kPsMax,
}) {
  final shown = state.shown.clamp(1, max);
  final cap = shown + kPsStep < max ? shown + kPsStep : max;
  final hold = state.hold;
  final anchor = hold?.anchor;
  final tail = hold?.tail;
  final frozen = hold == null ? const <String>{} : hold.frozen.toSet();
  final held = anchor != null;
  final rows = <PsRow<M>>[];
  final pendingIds = <String>[];
  var pendingMore = false;
  var eligible = 0;
  var pastTail = false;
  psWalk<M>(lists,
      floorSec: nowSec - kPsWindowSec,
      at: at,
      ms: ms,
      id: id,
      seek: () => pendingMore ? anchor!.t : null,
      visible: visible, visit: (s, m) {
    if (held && !frozen.contains(s.id)) {
      final older =
          pastTail || (tail != null ? psCompareNewest(s, tail) > 0 : false);
      if (!older) {
        if (pendingIds.length < kPsPendingMax) {
          pendingIds.add(s.id);
        } else {
          pendingMore = true;
        }
        return true;
      }
    }
    if (tail != null && s.id == tail.id) pastTail = true;
    if (eligible >= cap) return false;
    eligible++;
    if (rows.length < shown) rows.add(PsRow<M>(s, m));
    return true;
  });
  final remaining = (eligible < cap ? eligible : cap) - rows.length;
  final left = remaining < 0 ? 0 : remaining;
  return PsPage<M>(
    rows: rows,
    pendingIds: pendingIds,
    pendingMore: pendingMore,
    remaining: left,
    shown: shown,
    held: held,
    buttons: psMoreButton(shown, left, max),
  );
}

List<PsButton> psMoreButton(int shown, int remaining, [int max = kPsMax]) {
  final out = <PsButton>[];
  if (remaining > 0 && shown <= kPsFirst) {
    out.add(PsButton('view', remaining,
        kPsFirst + kPsStep < max ? kPsFirst + kPsStep : max));
  } else if (remaining > 0) {
    out.add(PsButton('show', remaining < kPsStep ? remaining : kPsStep,
        shown + kPsStep < max ? shown + kPsStep : max));
  }
  if (shown > kPsFirst) out.add(const PsButton('less', 0, kPsFirst));
  return out;
}

PsHold psHold(List<PsStamp> rows, PsHold? cur) {
  if (rows.isEmpty) return const PsHold();
  return PsHold(
    anchor: cur?.anchor ?? rows.first,
    tail: rows.last,
    frozen: [for (final r in rows) r.id],
  );
}

bool psIsHeld({double? headTop, double? viewTop, bool pointerDown = false}) {
  if (pointerDown) return true;
  if (headTop == null || viewTop == null) return false;
  return headTop < viewTop - 1;
}

typedef PsLabel = ({String template, Map<String, Object> vars});

PsLabel psRowLabel({
  required String time,
  required String channel,
  required String nym,
  required String text,
  bool hide = false,
}) {
  final bare = hide || text.isEmpty;
  final template = bare ? kPsLabelBare : kPsLabelText;
  return (
    template: template,
    vars: <String, Object>{
      'time': time,
      'channel': channel,
      'nym': nym,
      if (!bare) 'text': text,
    },
  );
}

PsLabel? psPillLabel(int n) {
  if (n <= 0) return null;
  if (n > kPsPendingMax) {
    return (template: '99+ new messages', vars: const <String, Object>{});
  }
  return n == 1
      ? (template: '1 new message', vars: const <String, Object>{})
      : (template: '{n} new messages', vars: <String, Object>{'n': n});
}

String psTagLabel(String key) => key.startsWith('#') ? key : '#$key';
