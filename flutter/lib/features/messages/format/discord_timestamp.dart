import 'dart:ui' show PlatformDispatcher;

import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../i18n/i18n.dart';
import '../../i18n/localization_service.dart';

bool _dateSymbolsReady = false;

String resolveTimestampLocale([String? locale]) {
  if (!_dateSymbolsReady) {
    initializeDateFormatting();
    _dateSymbolsReady = true;
  }
  String? platform;
  try {
    platform = PlatformDispatcher.instance.locale.toLanguageTag();
  } catch (_) {
    platform = null;
  }
  for (final candidate in [
    locale,
    LocalizationService.instance.language,
    platform,
  ]) {
    if (candidate == null || candidate.isEmpty) continue;
    final normalized = candidate.replaceAll('-', '_');
    if (DateFormat.localeExists(normalized)) return normalized;
    final short = normalized.split('_').first;
    if (DateFormat.localeExists(short)) return short;
  }
  return 'en_US';
}

String _clean(String s) => s.replaceAll(RegExp('[  ]'), ' ');

int _roundHalfUp(double v) => (v + 0.5).floor();

String _relativeText(String unit, int value, String locale) {
  final n = value.abs();
  final shown = NumberFormat.decimalPattern(locale).format(n);
  final args = {'n': shown};
  final future = value >= 0;
  final one = n == 1;
  switch (unit) {
    case 'second':
      if (future) {
        return one ? tr('in {n} second', args) : tr('in {n} seconds', args);
      }
      return one ? tr('{n} second ago', args) : tr('{n} seconds ago', args);
    case 'minute':
      if (future) {
        return one ? tr('in {n} minute', args) : tr('in {n} minutes', args);
      }
      return one ? tr('{n} minute ago', args) : tr('{n} minutes ago', args);
    case 'hour':
      if (future) {
        return one ? tr('in {n} hour', args) : tr('in {n} hours', args);
      }
      return one ? tr('{n} hour ago', args) : tr('{n} hours ago', args);
    case 'day':
      if (future) {
        return one ? tr('in {n} day', args) : tr('in {n} days', args);
      }
      return one ? tr('{n} day ago', args) : tr('{n} days ago', args);
    case 'month':
      if (future) {
        return one ? tr('in {n} month', args) : tr('in {n} months', args);
      }
      return one ? tr('{n} month ago', args) : tr('{n} months ago', args);
    default:
      if (future) {
        return one ? tr('in {n} year', args) : tr('in {n} years', args);
      }
      return one ? tr('{n} year ago', args) : tr('{n} years ago', args);
  }
}

const List<(String, int, num)> _relativeUnits = [
  ('second', 1, 60),
  ('minute', 60, 60),
  ('hour', 3600, 24),
  ('day', 86400, 30),
  ('month', 2592000, 12),
  ('year', 31536000, double.infinity),
];

String relativeTimestamp(int seconds, {String? locale, DateTime? now}) {
  final loc = resolveTimestampLocale(locale);
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final diff = _roundHalfUp((seconds * 1000 - nowMs) / 1000);
  var unit = 'second';
  var value = diff;
  for (final (name, size, limit) in _relativeUnits) {
    final v = _roundHalfUp(diff / size);
    unit = name;
    value = v;
    if (v.abs() < limit) break;
  }
  return _clean(_relativeText(unit, value, loc));
}

String formatDiscordTimestamp(
  int seconds,
  String style, {
  String? locale,
  DateTime? now,
}) {
  final loc = resolveTimestampLocale(locale);
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String time(bool withSeconds) => _clean(
    (withSeconds ? DateFormat.jms(loc) : DateFormat.jm(loc)).format(date),
  );
  String longDate(bool weekday) => _clean(
    (weekday ? DateFormat.yMMMMEEEEd(loc) : DateFormat.yMMMMd(loc)).format(
      date,
    ),
  );
  switch (style) {
    case 't':
      return time(false);
    case 'T':
      return time(true);
    case 'd':
      return _clean(DateFormat.yMd(loc).format(date));
    case 'D':
      return longDate(false);
    case 'F':
      return '${longDate(true)} ${time(false)}';
    case 'R':
      return relativeTimestamp(seconds, locale: locale, now: now);
    default:
      return '${longDate(false)} ${time(false)}';
  }
}
