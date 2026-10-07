import 'dart:math' as math;

typedef ActivityTyper = ({String? activity, bool bot});

class UploadActivitySignal {
  const UploadActivitySignal(
      {required this.status, required this.activity, required this.ttl});

  final String status;
  final String? activity;
  final int ttl;
}

class UploadActivity {
  UploadActivity._();

  static const List<String> kinds = [
    'photo',
    'video',
    'file',
    'voice',
    'recording-voice',
    'recording-video',
  ];
  static const int refreshMs = 12000;
  static const int ttlSec = 15;
  static const int _defaultExpirySec = 15;
  static const int _maxExpirySec = 30;

  static const Map<String, String> _one = {
    'photo': '{nym} is sending a photo',
    'video': '{nym} is sending a video',
    'file': '{nym} is sending a file',
    'voice': '{nym} is sending a voice message',
    'recording-voice': '{nym} is recording a voice message',
    'recording-video': '{nym} is recording a video message',
  };
  static const Map<String, String> _two = {
    'photo': '{nym} and {other} are sending photos',
    'video': '{nym} and {other} are sending videos',
    'file': '{nym} and {other} are sending files',
    'voice': '{nym} and {other} are sending voice messages',
    'recording-voice': '{nym} and {other} are recording voice messages',
    'recording-video': '{nym} and {other} are recording video messages',
  };
  static const Map<String, String> _many = {
    'photo': '{n} people are sending photos',
    'video': '{n} people are sending videos',
    'file': '{n} people are sending files',
    'voice': '{n} people are sending voice messages',
    'recording-voice': '{n} people are recording voice messages',
    'recording-video': '{n} people are recording video messages',
  };

  static bool isKind(String? k) => k != null && kinds.contains(k);

  static List<List<String>> encode(String status, String? activity, int ttl) {
    final tags = <List<String>>[
      ['typing', status],
    ];
    if (status != 'start') return tags;
    if (isKind(activity)) tags.add(['activity', activity!]);
    if (ttl > 0) tags.add(['ttl', '$ttl']);
    return tags;
  }

  static List<List<String>> channelTags(String status, String? activity,
          String wireTag, String channel, String nym) =>
      [
        ['typing', status],
        if (status == 'start' && isKind(activity)) ['activity', activity!],
        [wireTag, channel],
        ['n', nym],
      ];

  static UploadActivitySignal? decode(Object? tags) {
    if (tags is! List) return null;
    String? status;
    Object? activity;
    var ttl = 0;
    for (final t in tags) {
      if (t is! List || t.length < 2) continue;
      if (t[0] == 'typing' && t[1] is String) {
        status = t[1] as String;
      } else if (t[0] == 'activity') {
        activity = t[1];
      } else if (t[0] == 'ttl') {
        final n = _parseIntPrefix('${t[1]}');
        ttl = n > 0 ? n : 0;
      }
    }
    if (status == null) return null;
    final a = activity is String ? activity : null;
    return UploadActivitySignal(
      status: status,
      activity: status == 'start' && isKind(a) ? a : null,
      ttl: ttl,
    );
  }

  static int _parseIntPrefix(String s) {
    final m = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }

  static String kindForMime(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('image/')) return 'photo';
    if (m.startsWith('video/')) return 'video';
    return 'file';
  }

  static String kindForNote(String kind) {
    if (kind == 'voice') return 'voice';
    if (kind == 'round') return 'video';
    return 'file';
  }

  static int expiryMs(int ttl) =>
      (ttl > 0 ? math.min(ttl, _maxExpirySec) : _defaultExpirySec) * 1000;

  static bool isStale(num ageSec, int ttl) => ageSec * 1000 > expiryMs(ttl);

  static String label(List<ActivityTyper> typers) {
    if (typers.isEmpty) return '';
    final acts = [for (final t in typers) isKind(t.activity) ? t.activity : null];
    final shared =
        acts.first != null && acts.every((a) => a == acts.first) ? acts.first : null;
    if (typers.length == 1) {
      if (shared != null) return _one[shared]!;
      return typers.first.bot ? '{nym} is thinking' : '{nym} is typing';
    }
    if (typers.length == 2) {
      return shared != null ? _two[shared]! : '{nym} and {other} are typing';
    }
    return shared != null ? _many[shared]! : '{n} people are typing';
  }
}
