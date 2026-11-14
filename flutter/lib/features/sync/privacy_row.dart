import 'dart:convert';

class PrivacyRow {
  static const int d1Bytes = 65535;
  static const int listBytes = 61440;
  static const List<String> keys = [
    'blockedUsers',
    'friends',
    'blockedKeywords',
    'blockedChannels',
    'hiddenChannels',
  ];
  static const String full =
      'Your block lists are full. Remove some blocked users, friends, keywords or channels to make room.';
  static const String tooLarge =
      'Your block lists are too large to sync to your other devices. Remove some to sync them again.';

  static int listsBytes(Map<String, Iterable<String>> lists) =>
      utf8.encode(jsonEncode({
        for (final k in keys) k: (lists[k] ?? const <String>[]).toList(),
      })).length;

  static bool listsFit(Map<String, Iterable<String>> lists) =>
      listsBytes(lists) <= listBytes;
}
