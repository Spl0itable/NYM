import 'dart:convert';
import 'dart:typed_data';

class ChatToolsLimits {
  const ChatToolsLimits._();

  static const int savedMax = 500;
  static const int savedTextMax = 4000;
  static const int removedMax = 1000;
  static const int removedTtlMs = 180 * 24 * 60 * 60 * 1000;
  static const int editVersionsMax = 20;
  static const int editMessagesMax = 1000;
  static const int keepMax = 2000;

  static Map<String, num> toJson() => {
        'savedMax': savedMax,
        'savedTextMax': savedTextMax,
        'removedMax': removedMax,
        'removedTtlMs': removedTtlMs,
        'editVersionsMax': editVersionsMax,
        'editMessagesMax': editMessagesMax,
        'keepMax': keepMax,
      };
}

class ChatToolsKeys {
  const ChatToolsKeys._();

  static const String savedDTag = 'nymchat-saved';
  static const String saved = 'nym_saved_messages';
  static const String savedPending = 'nym_saved_pending';
  static const String edits = 'nym_edit_history';
  static const String keep = 'nym_kept_messages';
  static const String keepOutbox = 'nym_keep_outbox';
  static const String receiptKeep = 'keep';
  static const String receiptUnkeep = 'unkeep';
  static const String meshKeepPrefix = 'nymkeep:';
  static const String meshUnkeepPrefix = 'nymunkeep:';

  static Map<String, String> toJson() => {
        'savedDTag': savedDTag,
        'savedKey': saved,
        'savedPendingKey': savedPending,
        'editsKey': edits,
        'keepKey': keep,
        'receiptKeep': receiptKeep,
        'receiptUnkeep': receiptUnkeep,
        'meshKeepPrefix': meshKeepPrefix,
        'meshUnkeepPrefix': meshUnkeepPrefix,
      };
}

class ChatToolsStrings {
  const ChatToolsStrings._();

  static const String onceNotSaved = "View-once media can't be saved.";
  static const String onceExported = '[view-once media, not exported]';
  static const String localMedia = '[mesh media, not saved]';
  static const String exportTitle = 'Chat export: {title}';
  static const String exportedAt = 'Exported {time}';
  static const String edited = '(edited)';
  static const String voice = 'Voice message';
  static const String round = 'Video note';

  static Map<String, String> toJson() => {
        'onceNotSaved': onceNotSaved,
        'onceExported': onceExported,
        'localMedia': localMedia,
        'exportTitle': exportTitle,
        'exportedAt': exportedAt,
        'edited': edited,
        'voice': voice,
        'round': round,
      };
}

const List<String> _imageExt = [
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'heic', 'bmp', 'svg'
];
const List<String> _videoExt = ['mp4', 'webm', 'mov', 'm4v', 'ogv', 'mkv'];
const List<String> _audioExt = [
  'mp3', 'm4a', 'ogg', 'oga', 'wav', 'flac', 'aac', 'opus', 'weba'
];
const List<String> _fileExt = [
  'pdf', 'zip', 'txt', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv',
  'json', 'md', 'rar', '7z', 'tar', 'gz', 'apk', 'dmg', 'epub', 'rtf', 'odt',
  'ods'
];

final RegExp _rxToken = RegExp(
    r'''(https?:\/\/[^\s<>"'`|]+|nymlocal:[A-Za-z0-9]{1,40}(?:#nym:[A-Za-z0-9=;:.\/_+-]+)?)''');
final RegExp _rxOnceId = RegExp(r'^[0-9a-f]{16}$');
final RegExp _rxKeepId = RegExp(r'^[A-Za-z0-9:_-]{1,128}$');

typedef ChatToolsTr = String Function(String s);

String _fill(String s, Map<String, Object?>? vars) {
  var out = s;
  if (vars != null) {
    vars.forEach((k, v) => out = out.split('{$k}').join('$v'));
  }
  return out;
}

String _tr(ChatToolsTr? t, String s, [Map<String, Object?>? vars]) =>
    _fill(t == null ? s : t(s), vars);

int _count(String s, String ch) {
  var n = 0;
  for (final c in s.split('')) {
    if (c == ch) n++;
  }
  return n;
}

String _trimUrl(String url) {
  var u = url;
  while (u.isNotEmpty) {
    final ch = u[u.length - 1];
    if ('.,;:!?\'"*~'.contains(ch)) {
      u = u.substring(0, u.length - 1);
      continue;
    }
    if (ch == ')' && _count(u, '(') < _count(u, ')')) {
      u = u.substring(0, u.length - 1);
      continue;
    }
    if (ch == ']' && _count(u, '[') < _count(u, ']')) {
      u = u.substring(0, u.length - 1);
      continue;
    }
    break;
  }
  return u;
}

Map<String, String> _params(String frag) {
  final out = <String, String>{};
  for (final part in frag.split(';')) {
    final i = part.indexOf('=');
    if (i > 0) out[part.substring(0, i)] = part.substring(i + 1);
  }
  return out;
}

List<List<int>> spoilerRanges(String text) {
  final out = <List<int>>[];
  for (final m in RegExp(r'\|\|([\s\S]+?)\|\|').allMatches(text)) {
    out.add([m.start, m.end]);
  }
  return out;
}

bool _inRanges(List<List<int>> ranges, int i) {
  for (final r in ranges) {
    if (i >= r[0] && i < r[1]) return true;
  }
  return false;
}

String _extOf(String path) {
  final clean = path.split('?').first.split('#').first;
  final seg = clean.split('/').last;
  final dot = seg.lastIndexOf('.');
  if (dot <= 0 || dot == seg.length - 1) return '';
  return seg.substring(dot + 1).toLowerCase();
}

String _lastSegment(String url) {
  final clean = url.split('?').first.split('#').first;
  final noScheme = clean.replaceFirst(RegExp(r'^https?:\/\/[^/]+'), '');
  final parts = noScheme.split('/').where((p) => p.isNotEmpty).toList();
  var seg = parts.isEmpty ? '' : parts.last;
  try {
    seg = Uri.decodeComponent(seg);
  } catch (_) {}
  return seg;
}

class ContentToken {
  const ContentToken({
    required this.index,
    required this.length,
    required this.token,
    required this.base,
    required this.params,
    required this.local,
  });

  final int index;
  final int length;
  final String token;
  final String base;
  final Map<String, String>? params;
  final bool local;
}

List<ContentToken> contentTokens(String? text) {
  final src = text ?? '';
  final out = <ContentToken>[];
  var pos = 0;
  while (pos <= src.length) {
    final it = _rxToken.allMatches(src, pos).iterator;
    if (!it.moveNext()) break;
    final m = it.current;
    final raw = m.group(0)!;
    final isLocal = raw.startsWith('nymlocal:');
    final token = isLocal ? raw : _trimUrl(raw);
    final step = token.isEmpty ? 1 : token.length;
    if (token.isNotEmpty) {
      final hash = token.indexOf('#nym:');
      out.add(ContentToken(
        index: m.start,
        length: token.length,
        token: token,
        base: hash >= 0 ? token.substring(0, hash) : token,
        params: hash >= 0 ? _params(token.substring(hash + 5)) : null,
        local: isLocal,
      ));
    }
    pos = m.start + step;
  }
  return out;
}

bool _isOnce(Map<String, String>? p) =>
    p != null && p['o'] != null && _rxOnceId.hasMatch(p['o']!);

bool hasOnceMedia(String? content) =>
    contentTokens(content).any((t) => _isOnce(t.params));

class _Kind {
  const _Kind(this.tab, this.kind, [this.note = false]);
  final String tab;
  final String kind;
  final bool note;
}

_Kind _classify(ContentToken tok) {
  final p = tok.params;
  final k = p?['k'];
  if (k != null && k.isNotEmpty) {
    if (k == 'photo') return const _Kind('media', 'image');
    if (k == 'video' || k == 'round') {
      return _Kind('media', 'video', k == 'round');
    }
    if (k == 'voice') return const _Kind('files', 'audio', true);
  }
  if (tok.local) {
    final m = p?['m'] ?? '';
    if (m.startsWith('image/')) return const _Kind('media', 'image');
    if (m.startsWith('video/')) return const _Kind('media', 'video');
    return const _Kind('files', 'file');
  }
  final ext = _extOf(tok.base);
  if (_imageExt.contains(ext)) return const _Kind('media', 'image');
  if (_videoExt.contains(ext)) return const _Kind('media', 'video');
  if (_audioExt.contains(ext)) return const _Kind('files', 'audio');
  if (_fileExt.contains(ext)) return const _Kind('files', 'file');
  return const _Kind('links', 'link');
}

class ChatToolsMessage {
  const ChatToolsMessage({
    required this.id,
    this.nid = '',
    this.pubkey = '',
    this.author = '',
    this.content = '',
    this.at = 0,
    this.edited = false,
    this.system = false,
    this.fileOfferName,
    this.fileOfferSize,
  });

  factory ChatToolsMessage.fromJson(Map<String, dynamic> j) {
    final fo = j['fileOffer'];
    return ChatToolsMessage(
      id: '${j['id'] ?? ''}',
      nid: j['nid'] == null ? '' : '${j['nid']}',
      pubkey: '${j['pubkey'] ?? ''}',
      author: '${j['author'] ?? ''}',
      content: '${j['content'] ?? ''}',
      at: (j['at'] is num) ? (j['at'] as num).toInt() : 0,
      edited: j['edited'] == true,
      system: j['system'] == true,
      fileOfferName: fo is Map && fo['name'] != null ? '${fo['name']}' : null,
      fileOfferSize: fo is Map && fo['size'] is num
          ? (fo['size'] as num).toInt()
          : null,
    );
  }

  final String id;
  final String nid;
  final String pubkey;
  final String author;
  final String content;
  final int at;
  final bool edited;
  final bool system;
  final String? fileOfferName;
  final int? fileOfferSize;
}

class GalleryItem {
  const GalleryItem({
    required this.mid,
    required this.nid,
    required this.url,
    required this.kind,
    required this.name,
    required this.at,
    required this.author,
    required this.pubkey,
    required this.spoiler,
    required this.local,
  });

  final String mid;
  final String nid;
  final String url;
  final String kind;
  final String name;
  final int at;
  final String author;
  final String pubkey;
  final bool spoiler;
  final bool local;

  Map<String, dynamic> toJson() => {
        'mid': mid,
        'nid': nid,
        'url': url,
        'kind': kind,
        'name': name,
        'at': at,
        'author': author,
        'pubkey': pubkey,
        'spoiler': spoiler,
        'local': local,
      };
}

class _Ranked {
  _Ranked(this.item, this.order, this.pos);
  final GalleryItem item;
  final int order;
  final int pos;
}

class ChatGallery {
  const ChatGallery(this.media, this.files, this.links);
  final List<GalleryItem> media;
  final List<GalleryItem> files;
  final List<GalleryItem> links;

  List<GalleryItem> tab(String name) =>
      name == 'files' ? files : (name == 'links' ? links : media);

  Map<String, dynamic> toJson() => {
        'media': [for (final i in media) i.toJson()],
        'files': [for (final i in files) i.toJson()],
        'links': [for (final i in links) i.toJson()],
      };
}

List<List<Object>> _quoteMask(String text) {
  final mask = <List<Object>>[];
  var offset = 0;
  for (final line in text.split('\n')) {
    mask.add([offset, offset + line.length, line.startsWith('>')]);
    offset += line.length + 1;
  }
  return mask;
}

bool _inQuote(List<List<Object>> mask, int i) {
  for (final m in mask) {
    if (i >= (m[0] as int) && i <= (m[1] as int)) return m[2] as bool;
  }
  return false;
}

ChatGallery galleryItems(List<ChatToolsMessage> messages) {
  final media = <_Ranked>[];
  final files = <_Ranked>[];
  final links = <_Ranked>[];
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (m.system) continue;
    final spoilers = spoilerRanges(m.content);
    final quote = _quoteMask(m.content);
    final seen = <String>{};
    var pos = 0;
    for (final tok in contentTokens(m.content)) {
      if (_inQuote(quote, tok.index)) continue;
      if (_isOnce(tok.params)) continue;
      if (!seen.add(tok.base)) continue;
      final c = _classify(tok);
      final item = GalleryItem(
        mid: m.id,
        nid: m.nid,
        url: tok.base,
        kind: c.kind,
        name: c.note
            ? (c.kind == 'audio' ? 'voice' : 'round')
            : _lastSegment(tok.base),
        at: m.at,
        author: m.author,
        pubkey: m.pubkey,
        spoiler: _inRanges(spoilers, tok.index),
        local: tok.local,
      );
      final r = _Ranked(item, i, pos++);
      if (c.tab == 'media') {
        media.add(r);
      } else if (c.tab == 'files') {
        files.add(r);
      } else {
        links.add(r);
      }
    }
    final offer = m.fileOfferName;
    if (offer != null && offer.isNotEmpty) {
      files.add(_Ranked(
        GalleryItem(
          mid: m.id,
          nid: m.nid,
          url: '',
          kind: 'offer',
          name: offer,
          at: m.at,
          author: m.author,
          pubkey: m.pubkey,
          spoiler: false,
          local: false,
        ),
        i,
        pos++,
      ));
    }
  }
  int cmp(_Ranked a, _Ranked b) {
    if (b.item.at != a.item.at) return b.item.at - a.item.at;
    if (b.order != a.order) return b.order - a.order;
    return a.pos - b.pos;
  }

  List<GalleryItem> done(List<_Ranked> l) =>
      [for (final r in (l..sort(cmp))) r.item];
  return ChatGallery(done(media), done(files), done(links));
}

String _pad(int n, [int w = 2]) => n.toString().padLeft(w, '0');

String formatStamp(int sec, int offsetMin) {
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000 + offsetMin * 60000,
      isUtc: true);
  return '${d.year}-${_pad(d.month)}-${_pad(d.day)} ${_pad(d.hour)}:${_pad(d.minute)}';
}

List<ChatToolsMessage> _ordered(List<ChatToolsMessage> messages) {
  final indexed = <MapEntry<int, ChatToolsMessage>>[
    for (var i = 0; i < messages.length; i++)
      if (!messages[i].system) MapEntry(i, messages[i]),
  ];
  indexed.sort((a, b) {
    if (a.value.at != b.value.at) return a.value.at - b.value.at;
    return a.key - b.key;
  });
  return [for (final e in indexed) e.value];
}

String _exportLineText(ChatToolsMessage m, ChatToolsTr? t,
    Map<String, String> names) {
  var text = m.content;
  final toks = contentTokens(text);
  for (var i = toks.length - 1; i >= 0; i--) {
    final tok = toks[i];
    String rep;
    final named = names[tok.base];
    if (_isOnce(tok.params)) {
      rep = _tr(t, ChatToolsStrings.onceExported);
    } else if (tok.local) {
      rep = named != null ? 'media/$named' : _tr(t, ChatToolsStrings.localMedia);
    } else if (tok.params != null) {
      rep = named != null ? '${tok.base} (media/$named)' : tok.base;
    } else {
      rep = named != null ? '${tok.base} (media/$named)' : tok.token;
    }
    text = text.substring(0, tok.index) +
        rep +
        text.substring(tok.index + tok.length);
  }
  final offer = m.fileOfferName;
  if (offer != null && offer.isNotEmpty && text.trim().isEmpty) text = offer;
  if (m.edited) text = '$text ${_tr(t, ChatToolsStrings.edited)}';
  return text;
}

String exportTranscript({
  required String title,
  required List<ChatToolsMessage> messages,
  required int exportedAtMs,
  required int offsetMin,
  ChatToolsTr? t,
  Map<String, String>? mediaNames,
}) {
  final lines = <String>[
    _tr(t, ChatToolsStrings.exportTitle, {'title': title}),
    _tr(t, ChatToolsStrings.exportedAt,
        {'time': formatStamp(exportedAtMs ~/ 1000, offsetMin)}),
    '',
  ];
  for (final m in _ordered(messages)) {
    final body = _exportLineText(m, t, mediaNames ?? const {}).split('\n');
    lines.add('[${formatStamp(m.at, offsetMin)}] ${m.author}: ${body.first}');
    for (final rest in body.skip(1)) {
      lines.add('    $rest');
    }
  }
  return '${lines.join('\n')}\n';
}

String _safeName(String s) {
  var cleaned = s
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceFirst(RegExp(r'^[._]+'), '');
  if (cleaned.length > 60) cleaned = cleaned.substring(0, 60);
  return cleaned.isEmpty ? 'file' : cleaned;
}

String extForMime(String? mime) {
  final m = (mime ?? '').toLowerCase().split(';').first;
  const map = {
    'audio/mp4': 'm4a',
    'audio/webm': 'weba',
    'audio/ogg': 'ogg',
    'audio/mpeg': 'mp3',
    'video/mp4': 'mp4',
    'video/webm': 'webm',
    'video/quicktime': 'mov',
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
  };
  return map[m] ?? '';
}

class ExportMediaEntry {
  const ExportMediaEntry({
    required this.mid,
    required this.url,
    required this.name,
    required this.local,
  });
  final String mid;
  final String url;
  final String name;
  final bool local;

  Map<String, dynamic> toJson() =>
      {'mid': mid, 'url': url, 'name': name, 'local': local};
}

List<ExportMediaEntry> exportMediaPlan(List<ChatToolsMessage> messages) {
  final out = <ExportMediaEntry>[];
  final taken = <String>{};
  final seen = <String>{};
  for (final m in _ordered(messages)) {
    for (final tok in contentTokens(m.content)) {
      if (_isOnce(tok.params)) continue;
      if (seen.contains(tok.base)) continue;
      final c = _classify(tok);
      if (c.tab == 'links') continue;
      seen.add(tok.base);
      final stem = tok.local
          ? tok.base.substring('nymlocal:'.length)
          : _lastSegment(tok.base);
      var ext = _extOf(stem);
      if (ext.isEmpty && tok.params?['m'] != null) {
        ext = extForMime(tok.params!['m']);
      }
      final name = _safeName(ext.isNotEmpty && _extOf(stem).isNotEmpty
          ? stem
          : '$stem${ext.isNotEmpty ? '.$ext' : ''}');
      var n = out.length + 1;
      var candidate = '${_pad(n, 3)}-$name';
      while (taken.contains(candidate)) {
        n++;
        candidate = '${_pad(n, 3)}-$name';
      }
      taken.add(candidate);
      out.add(ExportMediaEntry(
          mid: m.id, url: tok.base, name: candidate, local: tok.local));
    }
  }
  return out;
}

String exportFileName(String title, int nowMs, int offsetMin, String ext) {
  var slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 40) slug = slug.substring(0, 40);
  if (slug.isEmpty) slug = 'chat';
  final stamp =
      formatStamp(nowMs ~/ 1000, offsetMin).replaceAll(RegExp(r'[-: ]'), '');
  return 'nymchat-$slug-${stamp.substring(0, 8)}-${stamp.substring(8)}.${ext.isEmpty ? 'txt' : ext}';
}

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c & 0xFFFFFFFF;
  }
  return t;
}();

int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class ZipEntry {
  const ZipEntry(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

Uint8List zipStore(List<ZipEntry> entries, int atMs, int offsetMin) {
  final d = DateTime.fromMillisecondsSinceEpoch(atMs + offsetMin * 60000,
      isUtc: true);
  final year = d.year < 1980 ? 1980 : d.year;
  final time = (d.hour << 11) | (d.minute << 5) | (d.second ~/ 2);
  final date = ((year - 1980) << 9) | (d.month << 5) | d.day;
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;
  for (final e in entries) {
    final name = utf8.encode(e.name);
    final data = e.bytes;
    final crc = crc32(data);
    final local = ByteData(30);
    local.setUint32(0, 0x04034b50, Endian.little);
    local.setUint16(4, 20, Endian.little);
    local.setUint16(6, 0x0800, Endian.little);
    local.setUint16(8, 0, Endian.little);
    local.setUint16(10, time, Endian.little);
    local.setUint16(12, date, Endian.little);
    local.setUint32(14, crc, Endian.little);
    local.setUint32(18, data.length, Endian.little);
    local.setUint32(22, data.length, Endian.little);
    local.setUint16(26, name.length, Endian.little);
    local.setUint16(28, 0, Endian.little);
    out.add(local.buffer.asUint8List());
    out.add(name);
    out.add(data);
    final cen = ByteData(46);
    cen.setUint32(0, 0x02014b50, Endian.little);
    cen.setUint16(4, 20, Endian.little);
    cen.setUint16(6, 20, Endian.little);
    cen.setUint16(8, 0x0800, Endian.little);
    cen.setUint16(10, 0, Endian.little);
    cen.setUint16(12, time, Endian.little);
    cen.setUint16(14, date, Endian.little);
    cen.setUint32(16, crc, Endian.little);
    cen.setUint32(20, data.length, Endian.little);
    cen.setUint32(24, data.length, Endian.little);
    cen.setUint16(28, name.length, Endian.little);
    cen.setUint32(42, offset, Endian.little);
    central.add(cen.buffer.asUint8List());
    central.add(name);
    offset += 30 + name.length + data.length;
  }
  final cenBytes = central.takeBytes();
  final end = ByteData(22);
  end.setUint32(0, 0x06054b50, Endian.little);
  end.setUint16(8, entries.length, Endian.little);
  end.setUint16(10, entries.length, Endian.little);
  end.setUint32(12, cenBytes.length, Endian.little);
  end.setUint32(16, offset, Endian.little);
  out.add(cenBytes);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

class SavedEntryResult {
  const SavedEntryResult({this.entry, this.error});
  final Map<String, dynamic>? entry;
  final String? error;

  Map<String, dynamic> toJson() =>
      error != null ? {'error': error} : {'entry': entry};
}

SavedEntryResult savedEntry(
    ChatToolsMessage m, Map<String, String> chat, int nowMs) {
  if (hasOnceMedia(m.content)) return const SavedEntryResult(error: 'once');
  final id = m.nid.isNotEmpty ? m.nid : m.id;
  if (id.isEmpty) return const SavedEntryResult(error: 'missing');
  var text = m.content;
  if (text.length > ChatToolsLimits.savedTextMax) {
    text = text.substring(0, ChatToolsLimits.savedTextMax);
  }
  final t = chat['t'];
  return SavedEntryResult(entry: {
    'id': id,
    'mid': m.id,
    'nid': m.nid,
    'chat': {
      't': (t == 'dm' || t == 'group') ? t : 'channel',
      'k': chat['k'] ?? '',
      'n': chat['n'] ?? '',
    },
    'a': {'pk': m.pubkey, 'n': m.author},
    'text': text,
    'at': m.at,
    'sv': nowMs,
  });
}

bool _validEntry(dynamic e) {
  if (e is! Map) return false;
  final id = e['id'];
  final chat = e['chat'];
  return id is String &&
      id.isNotEmpty &&
      chat is Map &&
      chat['k'] is String &&
      e['a'] is Map &&
      e['text'] is String &&
      e['sv'] is num &&
      (e['sv'] as num).isFinite;
}

num? _num(dynamic v) {
  if (v is num) return v.isFinite ? v : null;
  if (v is String) {
    final n = num.tryParse(v.trim());
    return (n != null && n.isFinite) ? n : null;
  }
  return null;
}

Map<String, dynamic> emptySaved() =>
    {'v': 1, 'items': <Map<String, dynamic>>[], 'removed': <String, num>{}};

Map<String, dynamic> normalizeSaved(dynamic raw) {
  final out = emptySaved();
  if (raw is! Map) return out;
  final items = raw['items'] is List ? raw['items'] as List : const [];
  final byId = <String, Map<String, dynamic>>{};
  for (final e in items) {
    if (!_validEntry(e)) continue;
    final entry = Map<String, dynamic>.from(e as Map);
    if (hasOnceMedia(entry['text'] as String)) continue;
    final prev = byId[entry['id']];
    if (prev == null || (entry['sv'] as num) > (prev['sv'] as num)) {
      byId[entry['id'] as String] = entry;
    }
  }
  final removed = <String, num>{};
  final r = raw['removed'];
  if (r is Map) {
    r.forEach((k, v) {
      final n = _num(v);
      if ('$k'.isNotEmpty && n != null && n > 0) removed['$k'] = n;
    });
  }
  out['items'] = byId.values.toList();
  out['removed'] = removed;
  return out;
}

Map<String, dynamic> _finishSaved(Map<String, dynamic> s, int nowMs) {
  final removed = <String, num>{};
  final cutoff = nowMs - ChatToolsLimits.removedTtlMs;
  (s['removed'] as Map<String, num>).forEach((k, v) {
    if (v >= cutoff) removed[k] = v;
  });
  var items = (s['items'] as List<Map<String, dynamic>>)
      .where((e) => !((removed[e['id']] ?? -1) >= (e['sv'] as num)))
      .toList();
  items.sort((a, b) {
    final d = (b['sv'] as num).compareTo(a['sv'] as num);
    if (d != 0) return d;
    return (a['id'] as String).compareTo(b['id'] as String);
  });
  if (items.length > ChatToolsLimits.savedMax) {
    items = items.sublist(0, ChatToolsLimits.savedMax);
  }
  if (removed.length > ChatToolsLimits.removedMax) {
    final keys = removed.keys.toList()
      ..sort((a, b) {
        final d = removed[b]!.compareTo(removed[a]!);
        return d != 0 ? d : a.compareTo(b);
      });
    final keep = <String, num>{
      for (final k in keys.take(ChatToolsLimits.removedMax)) k: removed[k]!,
    };
    return {'v': 1, 'items': items, 'removed': keep};
  }
  return {'v': 1, 'items': items, 'removed': removed};
}

Map<String, dynamic> mergeSaved(dynamic a, dynamic b, int nowMs) {
  final x = normalizeSaved(a);
  final y = normalizeSaved(b);
  final byId = <String, Map<String, dynamic>>{};
  for (final e in [
    ...(x['items'] as List<Map<String, dynamic>>),
    ...(y['items'] as List<Map<String, dynamic>>),
  ]) {
    final prev = byId[e['id']];
    if (prev == null || (e['sv'] as num) > (prev['sv'] as num)) {
      byId[e['id'] as String] = e;
    }
  }
  final removed = Map<String, num>.from(x['removed'] as Map<String, num>);
  (y['removed'] as Map<String, num>).forEach((k, v) {
    final cur = removed[k];
    if (cur == null || cur < v) removed[k] = v;
  });
  return _finishSaved(
      {'v': 1, 'items': byId.values.toList(), 'removed': removed}, nowMs);
}

Map<String, dynamic> addSaved(
    dynamic state, Map<String, dynamic> entry, int nowMs) {
  final s = normalizeSaved(state);
  if (!_validEntry(entry) || hasOnceMedia(entry['text'] as String)) {
    return _finishSaved(s, nowMs);
  }
  final items = (s['items'] as List<Map<String, dynamic>>)
      .where((e) => e['id'] != entry['id'])
      .toList()
    ..add(Map<String, dynamic>.from(entry));
  s['items'] = items;
  final removed = s['removed'] as Map<String, num>;
  final r = removed[entry['id']];
  if (r != null && r < (entry['sv'] as num)) removed.remove(entry['id']);
  return _finishSaved(s, nowMs);
}

Map<String, dynamic> removeSaved(dynamic state, String id, int nowMs) {
  final s = normalizeSaved(state);
  s['items'] = (s['items'] as List<Map<String, dynamic>>)
      .where((e) => e['id'] != id)
      .toList();
  final removed = s['removed'] as Map<String, num>;
  final cur = removed[id] ?? 0;
  removed[id] = nowMs > cur ? nowMs : cur;
  return _finishSaved(s, nowMs);
}

bool isSaved(dynamic state, String id) =>
    (normalizeSaved(state)['items'] as List<Map<String, dynamic>>)
        .any((e) => e['id'] == id);

bool trimSavedPayload(Map<String, dynamic> p) {
  final s = p['savedMessages'];
  if (s is! Map || s['items'] is! List) return false;
  final removed = s['removed'];
  if (removed is Map && removed.length > 50) {
    final keys = removed.keys.toList()
      ..sort((a, b) => (_num(removed[a]) ?? 0).compareTo(_num(removed[b]) ?? 0));
    final drop = (keys.length / 4).ceil();
    for (final k in keys.take(drop)) {
      removed.remove(k);
    }
    return true;
  }
  final items = s['items'] as List;
  if (items.length <= 1) return false;
  var drop = (items.length * 0.1).ceil();
  if (drop < 1) drop = 1;
  s['items'] = items.sublist(0, items.length - drop);
  return true;
}

class EditRecord {
  const EditRecord(this.versions, this.editedAt);

  factory EditRecord.fromJson(dynamic j) {
    if (j is! Map || j['versions'] is! List) return const EditRecord([], 0);
    return EditRecord([
      for (final v in j['versions'] as List)
        if (v is Map)
          EditVersion('${v['text'] ?? ''}',
              v['at'] is num ? (v['at'] as num).toInt() : 0),
    ], j['editedAt'] is num ? (j['editedAt'] as num).toInt() : 0);
  }

  final List<EditVersion> versions;
  final int editedAt;

  Map<String, dynamic> toJson() => {
        'versions': [for (final v in versions) v.toJson()],
        'editedAt': editedAt,
      };
}

class EditVersion {
  const EditVersion(this.text, this.at, [this.current = false]);
  final String text;
  final int at;
  final bool current;

  Map<String, dynamic> toJson() => {'text': text, 'at': at};
}

EditRecord recordEdit(EditRecord? rec, String? prevText, String? newText,
    int createdAt, int editAt) {
  final prev = prevText ?? '';
  final next = newText ?? '';
  final base = rec ?? const EditRecord([], 0);
  if (prev == next) return base;
  final versions = [...base.versions];
  final prevAt = base.editedAt != 0 ? base.editedAt : createdAt;
  if (versions.isEmpty || versions.last.text != prev) {
    versions.add(EditVersion(prev, prevAt));
  }
  while (versions.length > ChatToolsLimits.editVersionsMax) {
    versions.removeAt(0);
  }
  return EditRecord(versions, editAt > prevAt ? editAt : prevAt);
}

List<EditVersion> editTimeline(EditRecord? rec, String currentText) {
  final r = rec ?? const EditRecord([], 0);
  return [
    EditVersion(currentText, r.editedAt, true),
    for (final v in r.versions.reversed) EditVersion(v.text, v.at),
  ];
}

Map<String, dynamic> pruneEditStore(Map<String, dynamic> store) {
  if (store.length <= ChatToolsLimits.editMessagesMax) return store;
  int at(String k) {
    final v = store[k];
    return v is Map && v['editedAt'] is num ? (v['editedAt'] as num).toInt() : 0;
  }

  final keys = store.keys.toList()..sort((a, b) => at(a) - at(b));
  return {
    for (final k in keys.skip(keys.length - ChatToolsLimits.editMessagesMax))
      k: store[k],
  };
}

List<List<String>> keepTags(
    List<String> ids, bool kept, String? recipient, String? groupId) {
  return [
    if (recipient != null && recipient.isNotEmpty) ['p', recipient],
    for (final id in ids)
      if (_rxKeepId.hasMatch(id)) ['target', id],
    ['receipt', kept ? ChatToolsKeys.receiptKeep : ChatToolsKeys.receiptUnkeep],
    if (groupId != null && groupId.isNotEmpty) ['g', groupId],
  ];
}

class KeepControl {
  const KeepControl(this.ids, this.kept, this.groupId);
  final List<String> ids;
  final bool kept;
  final String? groupId;

  Map<String, dynamic> toJson() =>
      {'ids': ids, 'kept': kept, 'groupId': groupId};
}

KeepControl? parseKeep(List<dynamic>? tags) {
  String? type;
  String? groupId;
  final ids = <String>[];
  for (final t in tags ?? const []) {
    if (t is! List || t.length < 2 || t[1] is! String) continue;
    final v = t[1] as String;
    if (t[0] == 'receipt') {
      type = v;
    } else if (t[0] == 'target' && _rxKeepId.hasMatch(v)) {
      ids.add(v);
    } else if (t[0] == 'g') {
      groupId = v;
    }
  }
  if (type != ChatToolsKeys.receiptKeep && type != ChatToolsKeys.receiptUnkeep) {
    return null;
  }
  if (ids.isEmpty) return null;
  return KeepControl(ids, type == ChatToolsKeys.receiptKeep, groupId);
}

bool applyKeep(
    Map<String, dynamic> state, String id, bool kept, int at, String by) {
  final cur = state[id];
  if (cur is Map) {
    final curAt = cur['at'] is num ? (cur['at'] as num).toInt() : 0;
    final curKept = cur['k'] == true;
    if (at < curAt) return false;
    if (at == curAt) {
      if (curKept == kept) return false;
      if (!kept) return false;
    }
  }
  state[id] = {'k': kept, 'at': at, 'by': by};
  return true;
}

bool isKept(Map<String, dynamic> state, String? id) {
  if (id == null || id.isEmpty) return false;
  final v = state[id];
  return v is Map && v['k'] == true;
}

Map<String, dynamic> pruneKeep(Map<String, dynamic> state) {
  if (state.length <= ChatToolsLimits.keepMax) return state;
  int at(String k) {
    final v = state[k];
    return v is Map && v['at'] is num ? (v['at'] as num).toInt() : 0;
  }

  final keys = state.keys.toList()..sort((a, b) => at(a) - at(b));
  return {
    for (final k in keys.skip(keys.length - ChatToolsLimits.keepMax))
      k: state[k],
  };
}

bool isExpired(int? expiresAt, bool kept, int nowSec) {
  final e = expiresAt ?? 0;
  if (e == 0 || kept) return false;
  return e <= nowSec;
}

bool keepAvailable({
  required String? nid,
  required String surface,
  int? expiresAt,
  bool kept = false,
}) {
  if (nid == null || !_rxKeepId.hasMatch(nid)) return false;
  if (surface != 'dm' && surface != 'group') return false;
  return (expiresAt ?? 0) > 0 || kept;
}

String meshKeepId(String id, bool kept) =>
    '${kept ? ChatToolsKeys.meshKeepPrefix : ChatToolsKeys.meshUnkeepPrefix}$id';

({String id, bool kept})? parseMeshKeepId(String? s) {
  if (s == null) return null;
  bool kept;
  String rest;
  if (s.startsWith(ChatToolsKeys.meshKeepPrefix)) {
    kept = true;
    rest = s.substring(ChatToolsKeys.meshKeepPrefix.length);
  } else if (s.startsWith(ChatToolsKeys.meshUnkeepPrefix)) {
    kept = false;
    rest = s.substring(ChatToolsKeys.meshUnkeepPrefix.length);
  } else {
    return null;
  }
  return _rxKeepId.hasMatch(rest) ? (id: rest, kept: kept) : null;
}

bool replyPrivatelyAllowed({
  required String surface,
  required String pubkey,
  required String self,
  bool system = false,
}) {
  if (surface != 'group' && surface != 'channel') return false;
  if (pubkey.isEmpty || system) return false;
  if (self.isNotEmpty && pubkey == self) return false;
  return true;
}

int wrapExpiration(List<dynamic>? tags) {
  for (final t in tags ?? const []) {
    if (t is List &&
        t.length > 1 &&
        t[0] == 'expiration' &&
        RegExp(r'^\d{1,12}$').hasMatch('${t[1]}')) {
      return int.parse('${t[1]}');
    }
  }
  return 0;
}
