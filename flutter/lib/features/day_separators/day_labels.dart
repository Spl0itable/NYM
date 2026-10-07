import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../chat_nav/chat_nav.dart' show effectiveAt;

class DayLabels {
  const DayLabels._();

  static const int weekdayDays = 7;
  static const int floatIdleMs = 1500;
  static const int floatTopPx = 8;
  static const int floatPx = 26;
  static const String today = 'Today';
  static const String yesterday = 'Yesterday';
}

const int _daySec = 86400;

class DayZone {
  const DayZone._(this._offsetAt);

  factory DayZone.fixed(int minutes) => DayZone._((_) => minutes);

  factory DayZone.table(List<List<num>> pairs) => DayZone._((sec) {
    var out = 0;
    for (final p in pairs) {
      if (p.length < 2) continue;
      if (p[0] <= sec) {
        out = p[1].round();
      } else {
        break;
      }
    }
    return out;
  });

  static final DayZone local = DayZone._(
    (sec) =>
        DateTime.fromMillisecondsSinceEpoch(sec * 1000)
            .timeZoneOffset
            .inMinutes,
  );

  final int Function(int sec) _offsetAt;

  int offsetAt(int sec) => _offsetAt(sec);
}

class LocalDay {
  const LocalDay(this.ordinal, this.y, this.m, this.d, this.wd);

  final int ordinal;
  final int y;
  final int m;
  final int d;
  final int wd;

  String get key =>
      '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}

LocalDay localDay(int sec, DayZone tz) {
  final shifted = sec + tz.offsetAt(sec) * 60;
  final ordinal = (shifted / _daySec).floor();
  final d = DateTime.fromMillisecondsSinceEpoch(
    ordinal * _daySec * 1000,
    isUtc: true,
  );
  return LocalDay(ordinal, d.year, d.month, d.day, d.weekday % 7);
}

String dayKeyOf(int createdAt, int now, DayZone tz) =>
    localDay(effectiveAt(createdAt, now), tz).key;

enum DayKind { today, yesterday, weekday, date }

class DayInfo {
  const DayInfo({
    required this.key,
    required this.kind,
    required this.y,
    required this.m,
    required this.d,
    required this.showYear,
  });

  final String key;
  final DayKind kind;
  final int y;
  final int m;
  final int d;
  final bool showYear;
}

DayInfo dayInfo(int createdAt, int now, DayZone tz) {
  final at = localDay(effectiveAt(createdAt, now), tz);
  final today = localDay(now, tz);
  final diff = today.ordinal - at.ordinal;
  final DayKind kind;
  if (diff <= 0) {
    kind = DayKind.today;
  } else if (diff == 1) {
    kind = DayKind.yesterday;
  } else if (diff < DayLabels.weekdayDays) {
    kind = DayKind.weekday;
  } else {
    kind = DayKind.date;
  }
  return DayInfo(
    key: at.key,
    kind: kind,
    y: at.y,
    m: at.m,
    d: at.d,
    showYear: kind == DayKind.date && at.y != today.y,
  );
}

bool _symbolsReady = false;

String _intlLocale(String? locale) {
  if (!_symbolsReady) {
    initializeDateFormatting();
    _symbolsReady = true;
  }
  if (locale == null || locale.isEmpty) return 'en';
  final tag = locale.replaceAll('-', '_');
  if (DateFormat.localeExists(tag)) return tag;
  final short = tag.split('_').first;
  if (DateFormat.localeExists(short)) return short;
  return 'en';
}

String formatDayLabel(
  DayInfo info,
  String? locale,
  String Function(String) translate,
) {
  switch (info.kind) {
    case DayKind.today:
      return translate(DayLabels.today);
    case DayKind.yesterday:
      return translate(DayLabels.yesterday);
    case DayKind.weekday:
    case DayKind.date:
      break;
  }
  final loc = _intlLocale(locale);
  final date = DateTime.utc(info.y, info.m, info.d, 12);
  final f = info.kind == DayKind.weekday
      ? DateFormat.EEEE(loc)
      : (info.showYear ? DateFormat.yMMMMd(loc) : DateFormat.MMMMd(loc));
  return f.format(date).replaceAll(RegExp('[  ]'), ' ');
}

List<bool> dayBoundaries(List<int> stamps, int now, DayZone tz) {
  final out = <bool>[];
  String? prev;
  for (final s in stamps) {
    final k = dayKeyOf(s, now, tz);
    out.add(k != prev);
    prev = k;
  }
  return out;
}

bool sameDayAt(int a, int b, int now, DayZone tz) =>
    dayKeyOf(a, now, tz) == dayKeyOf(b, now, tz);

int nextMidnightMs(int nowMs, DayZone tz) {
  final sec = (nowMs / 1000).floor();
  final today = localDay(sec, tz);
  var guess = (today.ordinal + 1) * _daySec - tz.offsetAt(sec) * 60;
  for (var i = 0; i < 3 && localDay(guess, tz).ordinal == today.ordinal; i++) {
    guess += 3600;
  }
  return guess * 1000;
}

bool dayFloatVisible({
  required String? key,
  String? inlineKey,
  num? inlineTop,
  num viewTop = 0,
  bool atBottom = false,
  bool scrolling = false,
  num idleMs = 0,
  num? coverTop,
  num? coverBottom,
}) {
  if (key == null || key.isEmpty) return false;
  if (inlineKey == key && inlineTop != null && inlineTop >= viewTop - 1) {
    return false;
  }
  if (coverTop != null &&
      coverBottom != null &&
      coverBottom > viewTop + DayLabels.floatTopPx &&
      coverTop < viewTop + DayLabels.floatTopPx + DayLabels.floatPx) {
    return false;
  }
  if (atBottom && !scrolling) return false;
  return scrolling || idleMs < DayLabels.floatIdleMs;
}
