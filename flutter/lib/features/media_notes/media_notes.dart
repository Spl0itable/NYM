import 'dart:math' as math;

class MediaNoteLimits {
  const MediaNoteLimits._();

  static const int voiceMaxSeconds = 300;
  static const int roundMaxSeconds = 60;
  static const int meshMaxFileBytes = 102400;
  static const int meshVoiceMaxSeconds = 20;
  static const int waveformBars = 40;
  static const int voiceBitrate = 32000;
  static const int roundVideoBitrate = 1000000;
  static const int roundAudioBitrate = 64000;
  static const int roundSize = 480;
  static const int photoMaxDimension = 1600;
  static const double photoQuality = 0.82;
  static const int meshPhotoMaxDimension = 640;
  static const double meshPhotoQuality = 0.6;
  static const int uploadMaxBytes = 50 * 1024 * 1024;
  static const double minVoiceSeconds = 0.5;

  static Map<String, num> toJson() => {
        'voiceMaxSeconds': voiceMaxSeconds,
        'roundMaxSeconds': roundMaxSeconds,
        'meshMaxFileBytes': meshMaxFileBytes,
        'meshVoiceMaxSeconds': meshVoiceMaxSeconds,
        'waveformBars': waveformBars,
        'voiceBitrate': voiceBitrate,
        'roundVideoBitrate': roundVideoBitrate,
        'roundAudioBitrate': roundAudioBitrate,
        'roundSize': roundSize,
        'photoMaxDimension': photoMaxDimension,
        'photoQuality': photoQuality,
        'meshPhotoMaxDimension': meshPhotoMaxDimension,
        'meshPhotoQuality': meshPhotoQuality,
        'uploadMaxBytes': uploadMaxBytes,
        'minVoiceSeconds': minVoiceSeconds,
      };
}

class MediaNoteKeys {
  const MediaNoteKeys._();

  static const String speed = 'nym_voice_speed';
  static const String opened = 'nym_once_opened';
  static const String remoteOpened = 'nym_once_remote_opened';
  static const String transcripts = 'nym_voice_transcripts';
  static const String receiptOpened = 'opened';
  static const String meshOnceReceiptPrefix = 'nymonce:';
}

class MediaNoteReasons {
  const MediaNoteReasons._();

  static const String voiceOffline =
      "You're offline. Voice messages need the internet or the Bluetooth mesh.";
  static const String voiceNoMic = "This device can't record audio here.";
  static const String voiceMesh =
      'Over the Bluetooth mesh, voice messages are capped at 20 seconds and arrive slowly.';
  static const String roundOffline =
      "You're offline. Video notes need the internet.";
  static const String roundMesh =
      'Video notes are too large for the Bluetooth mesh. Send a voice message instead.';
  static const String roundNoCamera = 'No camera is available for video notes.';
  static const String onceChannel =
      'View once is only for private messages and groups.';
  static const String onceOffline =
      "You're offline. View-once media needs the internet or the Bluetooth mesh.";
  static const String onceMeshUnsupported =
      "This app can't send direct messages over the Bluetooth mesh, so view once is unavailable here.";
  static const String onceMesh =
      'Sent over the encrypted Bluetooth mesh, up to 100 KB.';
  static const String hdOffline =
      "You're offline. Media needs the internet or the Bluetooth mesh.";
  static const String hdMesh =
      'The Bluetooth mesh is slow and carries at most 100 KB per file, so original quality usually will not fit.';
  static const String meshTooLarge =
      'This file is {size}. The Bluetooth mesh carries at most 100 KB per file.';
  static const String transcribeUnavailable =
      "On-device transcription isn't available on this device.";

  static Map<String, String> toJson() => {
        'voiceOffline': voiceOffline,
        'voiceNoMic': voiceNoMic,
        'voiceMesh': voiceMesh,
        'roundOffline': roundOffline,
        'roundMesh': roundMesh,
        'roundNoCamera': roundNoCamera,
        'onceChannel': onceChannel,
        'onceOffline': onceOffline,
        'onceMeshUnsupported': onceMeshUnsupported,
        'onceMesh': onceMesh,
        'hdOffline': hdOffline,
        'hdMesh': hdMesh,
        'meshTooLarge': meshTooLarge,
        'transcribeUnavailable': transcribeUnavailable,
      };
}

const List<String> kMediaNoteStrings = <String>[
  MediaNoteReasons.voiceOffline,
  MediaNoteReasons.voiceNoMic,
  MediaNoteReasons.voiceMesh,
  MediaNoteReasons.roundOffline,
  MediaNoteReasons.roundMesh,
  MediaNoteReasons.roundNoCamera,
  MediaNoteReasons.onceChannel,
  MediaNoteReasons.onceOffline,
  MediaNoteReasons.onceMeshUnsupported,
  MediaNoteReasons.onceMesh,
  MediaNoteReasons.hdOffline,
  MediaNoteReasons.hdMesh,
  MediaNoteReasons.meshTooLarge,
  MediaNoteReasons.transcribeUnavailable,
  'View-once photo',
  'View-once video',
  'View-once voice message',
  'Voice message',
  'Video note',
  'Photo',
  'Video',
];

const List<double> kVoiceSpeeds = <double>[1, 1.5, 2];

const List<String> _kinds = <String>['voice', 'round', 'photo', 'video'];
const String _b64 =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
final RegExp _rxMime = RegExp(r'^(audio|video|image)\/[a-z0-9.+-]{1,40}$');
final RegExp _rxDuration = RegExp(r'^\d{1,4}(\.\d)?$');
final RegExp _rxSize = RegExp(r'^\d{1,10}$');
final RegExp _rxWave = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final RegExp _rxOnceId = RegExp(r'^[0-9a-f]{16}$');
final RegExp _rxKey = RegExp(r'^[0-9a-f]{64}$');
final RegExp _rxNonce = RegExp(r'^[0-9a-f]{24}$');
final RegExp _rxRemoteBase = RegExp(r'^https?:\/\/[^\s#<>"]+$');
final RegExp _rxLocalBase = RegExp(r'^nymlocal:[A-Za-z0-9]{1,40}$');
final RegExp _rxInText =
    RegExp(r'(https?:\/\/[^\s#<>"]+)#(nym:[A-Za-z0-9=;:.\/_+-]+)');
final RegExp _rxLocalInText =
    RegExp(r'nymlocal:([A-Za-z0-9]{1,40})#(nym:[A-Za-z0-9=;:.\/_+-]+)');
const Map<String, String> _kindPrefix = {
  'voice': 'audio/',
  'round': 'video/',
  'photo': 'image/',
  'video': 'video/',
};

class MediaNote {
  MediaNote({
    required this.kind,
    required this.mime,
    this.duration,
    this.size,
    List<int>? waveform,
    this.once = false,
    this.onceId = '',
    this.key = '',
    this.nonce = '',
    this.url = '',
    this.fullUrl = '',
    this.local = false,
    this.index = 0,
    this.length = 0,
  }) : waveform = waveform ?? const <int>[];

  final String kind;
  final String mime;
  final double? duration;
  final int? size;
  final List<int> waveform;
  final bool once;
  final String onceId;
  final String key;
  final String nonce;
  String url;
  String fullUrl;
  bool local;
  int index;
  int length;

  String get localId => local ? url.substring('nymlocal:'.length) : '';

  MediaNote copyWith({
    String? url,
    String? fullUrl,
    bool? local,
    bool? once,
    String? onceId,
    String? key,
    String? nonce,
  }) =>
      MediaNote(
        kind: kind,
        mime: mime,
        duration: duration,
        size: size,
        waveform: waveform,
        once: once ?? this.once,
        onceId: onceId ?? this.onceId,
        key: key ?? this.key,
        nonce: nonce ?? this.nonce,
        url: url ?? this.url,
        fullUrl: fullUrl ?? this.fullUrl,
        local: local ?? this.local,
        index: index,
        length: length,
      );
}

String _jsFixed1(double v) {
  final scaled = _jsRound(v * 10);
  final whole = scaled ~/ 10;
  final frac = scaled % 10;
  return '$whole.$frac';
}

String formatDurationValue(num seconds) {
  final d = seconds.toDouble().clamp(0, 3600).toDouble();
  return _jsFixed1(d);
}

String encodeWaveform(List<int> levels) {
  final b = StringBuffer();
  for (final v in levels) {
    final n = v.clamp(0, 63);
    b.write(_b64[n]);
  }
  return b.toString();
}

List<int> decodeWaveform(String s) {
  final out = <int>[];
  for (final ch in s.split('')) {
    final i = _b64.indexOf(ch);
    if (i < 0) return <int>[];
    out.add(i);
  }
  return out;
}

int _jsRound(double v) => (v + 0.5).floor();

List<int> computeWaveform(List<double> samples, [int? bars]) {
  final n = bars ?? MediaNoteLimits.waveformBars;
  final len = samples.length;
  final values = List<double>.filled(n, 0);
  if (len == 0) return List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final start = math.min(len - 1, (i * len / n).floor());
    final end = math.min(len, math.max(start + 1, ((i + 1) * len / n).floor()));
    var peak = 0.0;
    for (var j = start; j < end; j++) {
      final v = samples[j].abs();
      if (v > peak) peak = v;
    }
    values[i] = peak;
  }
  var max = 0.0;
  for (final v in values) {
    if (v > max) max = v;
  }
  if (max <= 0) return List<int>.filled(n, 0);
  return values.map((v) => _jsRound(v / max * 63)).toList();
}

double dbfsToLevel(num db) {
  final d = db.toDouble();
  if (d.isNaN || d.isInfinite) return 0;
  if (d >= 0) return 1;
  if (d <= -60) return 0;
  return math.pow(10, d / 20).toDouble();
}

List<int> waveformToImeta(List<int> levels) =>
    levels.map((v) => _jsRound(v.clamp(0, 63) * 100 / 63)).toList();

String encodeDescriptor(MediaNote d) {
  if (!_kinds.contains(d.kind) || !_rxMime.hasMatch(d.mime)) return '';
  if (!d.mime.startsWith(_kindPrefix[d.kind]!)) return '';
  final parts = <String>['v=1', 'k=${d.kind}', 'm=${d.mime}'];
  final dur = d.duration;
  if (dur != null && dur.isFinite) parts.add('d=${formatDurationValue(dur)}');
  final size = d.size;
  if (size != null && size >= 0) parts.add('s=$size');
  if (d.waveform.isNotEmpty) parts.add('w=${encodeWaveform(d.waveform)}');
  if (d.once) {
    if (!_rxOnceId.hasMatch(d.onceId)) return '';
    final hasKey = d.key.isNotEmpty || d.nonce.isNotEmpty;
    if (hasKey && (!_rxKey.hasMatch(d.key) || !_rxNonce.hasMatch(d.nonce))) {
      return '';
    }
    parts.addAll(['o=1', 'i=${d.onceId}']);
    if (hasKey) parts.addAll(['x=${d.key}', 'n=${d.nonce}']);
  }
  return 'nym:${parts.join(';')}';
}

String attachDescriptor(String url, MediaNote d) {
  final enc = encodeDescriptor(d);
  if (enc.isEmpty || url.isEmpty) return '';
  return '${url.split('#').first}#$enc';
}

MediaNote? parseDescriptor(String frag) {
  if (!frag.startsWith('nym:')) return null;
  final map = <String, String>{};
  for (final part in frag.substring(4).split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final k = part.substring(0, eq);
    map.putIfAbsent(k, () => part.substring(eq + 1));
  }
  if (map['v'] != '1') return null;
  final kind = map['k'];
  if (kind == null || !_kinds.contains(kind)) return null;
  final mime = map['m'] ?? '';
  if (!_rxMime.hasMatch(mime) || !mime.startsWith(_kindPrefix[kind]!)) {
    return null;
  }
  double? duration;
  int? size;
  var waveform = <int>[];
  var once = false;
  var onceId = '';
  var key = '';
  var nonce = '';
  final d = map['d'];
  if (d != null) {
    if (!_rxDuration.hasMatch(d)) return null;
    final v = double.parse(d);
    if (!(v >= 0 && v <= 3600)) return null;
    duration = v;
  }
  final s = map['s'];
  if (s != null) {
    if (!_rxSize.hasMatch(s)) return null;
    size = int.parse(s);
  }
  final w = map['w'];
  if (w != null) {
    if (!_rxWave.hasMatch(w)) return null;
    waveform = decodeWaveform(w);
  }
  final o = map['o'];
  if (o != null) {
    if (o != '1' || !_rxOnceId.hasMatch(map['i'] ?? '')) return null;
    final hasKey = map.containsKey('x') || map.containsKey('n');
    if (hasKey &&
        (!_rxKey.hasMatch(map['x'] ?? '') || !_rxNonce.hasMatch(map['n'] ?? ''))) {
      return null;
    }
    once = true;
    onceId = map['i']!;
    key = hasKey ? map['x']! : '';
    nonce = hasKey ? map['n']! : '';
  }
  return MediaNote(
    kind: kind,
    mime: mime,
    duration: duration,
    size: size,
    waveform: waveform,
    once: once,
    onceId: onceId,
    key: key,
    nonce: nonce,
  );
}

MediaNote? parseMediaUrl(String full) {
  final hash = full.indexOf('#');
  if (hash < 0) return null;
  final base = full.substring(0, hash);
  final remote = _rxRemoteBase.hasMatch(base);
  if (!remote && !_rxLocalBase.hasMatch(base)) return null;
  final d = parseDescriptor(full.substring(hash + 1));
  if (d == null) return null;
  if (remote && d.once && d.key.isEmpty) return null;
  if (remote && (d.kind == 'photo' || d.kind == 'video') && !d.once) {
    return null;
  }
  d.url = base;
  d.fullUrl = full;
  d.local = !remote;
  return d;
}

List<MediaNote> findMediaNotes(String content) {
  final out = <MediaNote>[];
  if (!content.contains('#nym:')) return out;
  void scan(RegExp rx) {
    for (final m in rx.allMatches(content)) {
      final d = parseMediaUrl(m[0]!);
      if (d != null) {
        d.index = m.start;
        d.length = m[0]!.length;
        out.add(d);
      }
    }
  }

  scan(_rxInText);
  scan(_rxLocalInText);
  out.sort((a, b) => a.index.compareTo(b.index));
  return out;
}

List<List<String>> imetaTagsForContent(String content,
    [List<String> Function(String url)? fallbacksFor]) {
  final tags = <List<String>>[];
  final seen = <String>{};
  for (final d in findMediaNotes(content)) {
    if (d.once || !seen.add(d.fullUrl) || d.url.startsWith('nymlocal:')) {
      continue;
    }
    final tag = <String>['imeta', 'url ${d.fullUrl}', 'm ${d.mime}'];
    if (d.size != null) tag.add('size ${d.size}');
    if (d.duration != null) {
      tag.add('duration ${formatDurationValue(d.duration!)}');
    }
    if (d.kind == 'voice' && d.waveform.isNotEmpty) {
      tag.add('waveform ${waveformToImeta(d.waveform).join(' ')}');
    }
    final mirrors = fallbacksFor == null ? const <String>[] : fallbacksFor(d.url);
    for (final mu in mirrors) {
      tag.add('fallback $mu');
    }
    tags.add(tag);
  }
  return tags;
}

String stripMediaNotes(String content) {
  var out = content;
  final found = findMediaNotes(content);
  for (var i = found.length - 1; i >= 0; i--) {
    out = out.substring(0, found[i].index) +
        out.substring(found[i].index + found[i].length);
  }
  return out;
}

const Map<String, String> _onceLabels = {
  'photo': 'View-once photo',
  'video': 'View-once video',
  'voice': 'View-once voice message',
  'round': 'View-once video',
};

String onceLabel(String kind) => _onceLabels[kind] ?? _onceLabels['photo']!;

String plainLabel(MediaNote d, [String Function(String)? tr]) {
  String t(String s) => tr == null ? s : tr(s);
  if (d.once) return t(onceLabel(d.kind));
  final dur = d.duration != null ? ' (${formatClock(d.duration!)})' : '';
  switch (d.kind) {
    case 'voice':
      return '${t('Voice message')}$dur';
    case 'round':
      return '${t('Video note')}$dur';
    case 'photo':
      return t('Photo');
    case 'video':
      return t('Video');
  }
  return '';
}

String previewText(String content, [String Function(String)? tr]) {
  final found = findMediaNotes(content);
  if (found.isEmpty) return content;
  var out = content;
  for (var i = found.length - 1; i >= 0; i--) {
    final d = found[i];
    final label = plainLabel(d, tr);
    var start = d.index;
    final prefix = '${onceLabel(d.kind)}: ';
    if (d.once &&
        start >= prefix.length &&
        out.substring(start - prefix.length, start) == prefix) {
      start -= prefix.length;
    }
    out = out.substring(0, start) + label + out.substring(d.index + d.length);
  }
  return out
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .trim();
}

String onceContent(String kind, String fullUrl) =>
    '${onceLabel(kind)}: $fullUrl';

String formatClock(num seconds) {
  final s = seconds.isFinite ? math.max(0, seconds.floor()) : 0;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r < 10 ? '0' : ''}$r';
}

String formatBytes(num n) {
  final b = math.max(0, n.toInt());
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${_jsFixed1(_jsRound(b / 102.4) / 10)} KB';
  return '${_jsFixed1(_jsRound(b / (1024 * 102.4)) / 10)} MB';
}

double nextSpeed(double current) {
  final i = kVoiceSpeeds.indexOf(current);
  return kVoiceSpeeds[(i + 1) % kVoiceSpeeds.length];
}

double parseSpeed(String? raw) {
  final v = double.tryParse(raw ?? '');
  return v != null && kVoiceSpeeds.contains(v) ? v : 1;
}

String speedLabel(double v) => '${v == 1.5 ? '1.5' : v.round().toString()}×';

({int width, int height}) scaledDimensions(num w, num h, int max) {
  final width = math.max(0, w.floor());
  final height = math.max(0, h.floor());
  if (width == 0 || height == 0) return (width: width, height: height);
  final longest = math.max(width, height);
  if (longest <= max) return (width: width, height: height);
  final scale = max / longest;
  return (
    width: math.max(1, _jsRound(width * scale)),
    height: math.max(1, _jsRound(height * scale)),
  );
}

String baseMime(String? mime) =>
    (mime ?? '').split(';').first.trim().toLowerCase();

String extForMime(String? mime) {
  const map = {
    'audio/mp4': 'm4a',
    'audio/aac': 'aac',
    'audio/webm': 'webm',
    'audio/ogg': 'ogg',
    'audio/mpeg': 'mp3',
    'audio/wav': 'wav',
    'video/mp4': 'mp4',
    'video/webm': 'webm',
    'video/quicktime': 'mov',
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
    'image/gif': 'gif',
  };
  return map[baseMime(mime)] ?? 'bin';
}

String meshFileName(MediaNote d) {
  if (!_kinds.contains(d.kind)) return '';
  if ((d.kind == 'photo' || d.kind == 'video') && !d.once) return '';
  final parts = <String>['nym', 'k=${d.kind}'];
  final dur = d.duration;
  if (dur != null && dur.isFinite) {
    parts.add('d=${_jsRound(dur.clamp(0, 3600) * 10)}');
  }
  if (d.waveform.isNotEmpty) parts.add('w=${encodeWaveform(d.waveform)}');
  if (d.once) {
    if (!_rxOnceId.hasMatch(d.onceId)) return '';
    parts.add('o=${d.onceId}');
  }
  return '${parts.join('.')}.${extForMime(d.mime)}';
}

MediaNote? parseMeshFileName(String name, String? mime) {
  final segs = name.split('.');
  if (segs.length < 3 || segs.first != 'nym') return null;
  segs.removeLast();
  final map = <String, String>{};
  for (final s in segs.skip(1)) {
    final eq = s.indexOf('=');
    if (eq <= 0) continue;
    map[s.substring(0, eq)] = s.substring(eq + 1);
  }
  final kind = map['k'];
  if (kind == null || !_kinds.contains(kind)) return null;
  final m = baseMime(mime);
  if (!_rxMime.hasMatch(m) || !m.startsWith(_kindPrefix[kind]!)) return null;
  double? duration;
  var waveform = <int>[];
  var once = false;
  var onceId = '';
  final d = map['d'];
  if (d != null) {
    if (!RegExp(r'^\d{1,5}$').hasMatch(d)) return null;
    duration = math.min(3600, int.parse(d) / 10);
  }
  final w = map['w'];
  if (w != null) {
    if (!_rxWave.hasMatch(w)) return null;
    waveform = decodeWaveform(w);
  }
  final o = map['o'];
  if (o != null) {
    if (!_rxOnceId.hasMatch(o)) return null;
    once = true;
    onceId = o;
  }
  if ((kind == 'photo' || kind == 'video') && !once) return null;
  return MediaNote(
    kind: kind,
    mime: m,
    duration: duration,
    waveform: waveform,
    once: once,
    onceId: onceId,
  );
}

String meshOnceReceiptId(String onceId) =>
    '${MediaNoteKeys.meshOnceReceiptPrefix}$onceId';

String parseMeshOnceReceiptId(String id) {
  if (!id.startsWith(MediaNoteKeys.meshOnceReceiptPrefix)) return '';
  final v = id.substring(MediaNoteKeys.meshOnceReceiptPrefix.length);
  return _rxOnceId.hasMatch(v) ? v : '';
}

enum MediaFeatureLevel { ok, warn, off }

class MediaFeatureState {
  const MediaFeatureState(this.level, this.reason,
      {this.maxSeconds, this.maxBytes});

  final MediaFeatureLevel level;
  final String reason;
  final int? maxSeconds;
  final int? maxBytes;

  String get state => level.name;

  Map<String, Object> toJson() => {
        'state': state,
        'reason': reason,
        'maxSeconds': ?maxSeconds,
        'maxBytes': ?maxBytes,
      };
}

class MediaFeatureContext {
  const MediaFeatureContext({
    this.surface = 'channel',
    this.route = 'online',
    this.meshDm = false,
    this.canRecordAudio,
    this.canRecordVideo,
    this.canTranscribe,
    this.transcribeReason,
  });

  final String surface;
  final String route;
  final bool meshDm;
  final bool? canRecordAudio;
  final bool? canRecordVideo;
  final bool? canTranscribe;
  final String? transcribeReason;
}

MediaFeatureState featureState(String feature, MediaFeatureContext c) {
  MediaFeatureState ok({int? maxSeconds, int? maxBytes}) => MediaFeatureState(
      MediaFeatureLevel.ok, '',
      maxSeconds: maxSeconds, maxBytes: maxBytes);
  MediaFeatureState warn(String reason, {int? maxSeconds, int? maxBytes}) =>
      MediaFeatureState(MediaFeatureLevel.warn, reason,
          maxSeconds: maxSeconds, maxBytes: maxBytes);
  MediaFeatureState off(String reason) =>
      MediaFeatureState(MediaFeatureLevel.off, reason);
  switch (feature) {
    case 'voice':
      if (c.canRecordAudio == false) return off(MediaNoteReasons.voiceNoMic);
      if (c.route == 'offline') return off(MediaNoteReasons.voiceOffline);
      if (c.route == 'mesh') {
        return warn(MediaNoteReasons.voiceMesh,
            maxSeconds: MediaNoteLimits.meshVoiceMaxSeconds,
            maxBytes: MediaNoteLimits.meshMaxFileBytes);
      }
      return ok(
          maxSeconds: MediaNoteLimits.voiceMaxSeconds,
          maxBytes: MediaNoteLimits.uploadMaxBytes);
    case 'round':
      if (c.canRecordVideo == false) return off(MediaNoteReasons.roundNoCamera);
      if (c.route == 'offline') return off(MediaNoteReasons.roundOffline);
      if (c.route == 'mesh') return off(MediaNoteReasons.roundMesh);
      return ok(
          maxSeconds: MediaNoteLimits.roundMaxSeconds,
          maxBytes: MediaNoteLimits.uploadMaxBytes);
    case 'once':
      if (c.surface == 'channel') return off(MediaNoteReasons.onceChannel);
      if (c.route == 'offline') return off(MediaNoteReasons.onceOffline);
      if (c.route == 'mesh') {
        if (c.surface != 'dm' || !c.meshDm) {
          return off(MediaNoteReasons.onceMeshUnsupported);
        }
        return warn(MediaNoteReasons.onceMesh,
            maxBytes: MediaNoteLimits.meshMaxFileBytes);
      }
      return ok(maxBytes: MediaNoteLimits.uploadMaxBytes);
    case 'hd':
      if (c.route == 'offline') return off(MediaNoteReasons.hdOffline);
      if (c.route == 'mesh') {
        return warn(MediaNoteReasons.hdMesh,
            maxBytes: MediaNoteLimits.meshMaxFileBytes);
      }
      return ok(maxBytes: MediaNoteLimits.uploadMaxBytes);
    case 'transcribe':
      if (c.canTranscribe == false) {
        return off(c.transcribeReason ?? MediaNoteReasons.transcribeUnavailable);
      }
      return ok();
  }
  return off('');
}

({bool ok, String reason}) meshSizeCheck(int bytes) {
  final n = math.max(0, bytes);
  if (n <= MediaNoteLimits.meshMaxFileBytes) return (ok: true, reason: '');
  return (
    ok: false,
    reason: MediaNoteReasons.meshTooLarge.replaceAll('{size}', formatBytes(n)),
  );
}

class ModelDownloadLimits {
  const ModelDownloadLimits(
      {this.pollMs = 1000, this.stallMs = 20000, this.maxMs = 600000});

  final int pollMs;
  final int stallMs;
  final int maxMs;
}

const ModelDownloadLimits kModelDownload = ModelDownloadLimits();

String modelDownloadStage({
  String? status,
  bool? installResult,
  int elapsedMs = 0,
  bool sawDownloading = false,
  bool canceled = false,
  ModelDownloadLimits limits = kModelDownload,
}) {
  if (canceled) return 'canceled';
  if (installResult == false) return 'failed';
  if (status == 'available' || installResult == true) return 'done';
  if (status == 'unavailable') return 'failed';
  if (elapsedMs >= limits.maxMs) return 'timeout';
  if (status == 'downloading' || sawDownloading) return 'downloading';
  if (elapsedMs >= limits.stallMs) return 'stalled';
  return 'starting';
}
