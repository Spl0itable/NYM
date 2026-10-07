import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../calls/call_signaling.dart';
import 'media_notes.dart';

const String kVoiceAppleUnplayable =
    "This voice note was recorded in a format iPhones can't play";

enum VoiceContainer { mp4, webm, ogg, wav, mp3, adts, caf, unknown }

class OpusTrack {
  const OpusTrack({
    required this.channels,
    required this.preSkip,
    required this.packets,
  });

  final int channels;
  final int preSkip;
  final List<Uint8List> packets;
}

class VoiceFile {
  const VoiceFile(this.bytes, this.ext, this.mime);

  final Uint8List bytes;
  final String ext;
  final String? mime;
}

bool _isApple(TargetPlatform p) =>
    p == TargetPlatform.iOS || p == TargetPlatform.macOS;

bool voicePlaysFromLocalFile(TargetPlatform p) => _isApple(p);

bool shouldUseVoicePlaybackSession(TargetPlatform p, CallPhase phase) =>
    p == TargetPlatform.iOS &&
    (phase == CallPhase.idle || phase == CallPhase.ended);

AudioContext voicePlaybackContext() => AudioContext(
    iOS: AudioContextIOS(category: AVAudioSessionCategory.playback, options: const {}));

bool _at(Uint8List b, int o, List<int> sig) {
  if (b.length < o + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[o + i] != sig[i]) return false;
  }
  return true;
}

VoiceContainer sniffVoiceContainer(Uint8List b) {
  if (_at(b, 4, 'ftyp'.codeUnits)) return VoiceContainer.mp4;
  if (_at(b, 0, const [0x1A, 0x45, 0xDF, 0xA3])) return VoiceContainer.webm;
  if (_at(b, 0, 'OggS'.codeUnits)) return VoiceContainer.ogg;
  if (_at(b, 0, 'RIFF'.codeUnits) && _at(b, 8, 'WAVE'.codeUnits)) {
    return VoiceContainer.wav;
  }
  if (_at(b, 0, 'caff'.codeUnits)) return VoiceContainer.caf;
  if (_at(b, 0, 'ID3'.codeUnits)) return VoiceContainer.mp3;
  if (b.length > 1 && b[0] == 0xFF) {
    if ((b[1] & 0xF6) == 0xF0) return VoiceContainer.adts;
    if ((b[1] & 0xE0) == 0xE0 && (b[1] & 0x06) != 0) return VoiceContainer.mp3;
  }
  return VoiceContainer.unknown;
}

class _Box {
  const _Box(this.type, this.start, this.body, this.end);

  final String type;
  final int start;
  final int body;
  final int end;
}

List<_Box> _boxes(Uint8List b, int start, int end) {
  final out = <_Box>[];
  final v = ByteData.sublistView(b);
  var o = start;
  while (o + 8 <= end) {
    var size = v.getUint32(o);
    var header = 8;
    if (size == 1) {
      if (o + 16 > end) break;
      size = v.getUint64(o + 8);
      header = 16;
    } else if (size == 0) {
      size = end - o;
    }
    if (size < header || o + size > end) break;
    out.add(_Box(String.fromCharCodes(b, o + 4, o + 8), o, o + header, o + size));
    o += size;
  }
  return out;
}

_Box? _child(Uint8List b, _Box parent, String type) {
  for (final c in _boxes(b, parent.body, parent.end)) {
    if (c.type == type) return c;
  }
  return null;
}

_Box? _path(Uint8List b, _Box root, List<String> types) {
  _Box? cur = root;
  for (final t in types) {
    cur = cur == null ? null : _child(b, cur, t);
  }
  return cur;
}

class _Mp4Audio {
  const _Mp4Audio(this.trak, this.trackId, this.entry);

  final _Box trak;
  final int trackId;
  final _Box entry;
}

_Mp4Audio? _mp4Audio(Uint8List b) {
  final top = _boxes(b, 0, b.length);
  final moov = top.where((x) => x.type == 'moov').firstOrNull;
  if (moov == null) return null;
  final v = ByteData.sublistView(b);
  for (final trak in _boxes(b, moov.body, moov.end).where((x) => x.type == 'trak')) {
    final hdlr = _path(b, trak, ['mdia', 'hdlr']);
    if (hdlr == null || hdlr.body + 12 > hdlr.end) continue;
    if (String.fromCharCodes(b, hdlr.body + 8, hdlr.body + 12) != 'soun') continue;
    final stsd = _path(b, trak, ['mdia', 'minf', 'stbl', 'stsd']);
    if (stsd == null) continue;
    final entries = _boxes(b, stsd.body + 8, stsd.end);
    if (entries.isEmpty) continue;
    final tkhd = _child(b, trak, 'tkhd');
    var id = 0;
    if (tkhd != null && tkhd.body + 24 <= tkhd.end) {
      id = v.getUint32(tkhd.body + (b[tkhd.body] == 1 ? 20 : 12));
    }
    return _Mp4Audio(trak, id, entries.first);
  }
  return null;
}

String mp4AudioCodec(Uint8List b) {
  try {
    return _mp4Audio(b)?.entry.type ?? '';
  } catch (_) {
    return '';
  }
}

OpusTrack? opusFromMp4(Uint8List b) {
  try {
    return _opusFromMp4(b);
  } catch (_) {
    return null;
  }
}

OpusTrack? _opusFromMp4(Uint8List b) {
  final a = _mp4Audio(b);
  if (a == null || a.entry.type != 'Opus') return null;
  final v = ByteData.sublistView(b);
  final dops = _boxes(b, a.entry.body + 28, a.entry.end)
      .where((x) => x.type == 'dOps')
      .firstOrNull;
  if (dops == null || dops.body + 11 > dops.end) return null;
  final channels = b[dops.body + 1];
  final preSkip = v.getUint16(dops.body + 2);
  if (b[dops.body + 10] != 0 || channels < 1 || channels > 2) return null;
  final packets = <Uint8List>[];
  final stbl = _path(b, a.trak, ['mdia', 'minf', 'stbl'])!;
  final stsz = _child(b, stbl, 'stsz');
  final stsc = _child(b, stbl, 'stsc');
  final stco = _child(b, stbl, 'stco') ?? _child(b, stbl, 'co64');
  if (stsz != null && stsc != null && stco != null) {
    final fixed = v.getUint32(stsz.body + 4);
    final count = v.getUint32(stsz.body + 8);
    final sizes = List<int>.generate(
        count, (i) => fixed != 0 ? fixed : v.getUint32(stsz.body + 12 + i * 4));
    final wide = stco.type == 'co64';
    final chunks = v.getUint32(stco.body + 4);
    final offsets = List<int>.generate(
        chunks,
        (i) => wide
            ? v.getUint64(stco.body + 8 + i * 8)
            : v.getUint32(stco.body + 8 + i * 4));
    final runs = v.getUint32(stsc.body + 4);
    var sample = 0;
    for (var r = 0; r < runs && sample < count; r++) {
      final first = v.getUint32(stsc.body + 8 + r * 12) - 1;
      final per = v.getUint32(stsc.body + 12 + r * 12);
      final last = r + 1 < runs
          ? v.getUint32(stsc.body + 8 + (r + 1) * 12) - 1
          : chunks;
      for (var c = first; c < last && c < chunks && sample < count; c++) {
        var o = offsets[c];
        for (var k = 0; k < per && sample < count; k++) {
          packets.add(Uint8List.sublistView(b, o, o + sizes[sample]));
          o += sizes[sample];
          sample++;
        }
      }
    }
  }
  final top = _boxes(b, 0, b.length);
  final moov = top.firstWhere((x) => x.type == 'moov');
  var trexSize = 0;
  final mvex = _child(b, moov, 'mvex');
  if (mvex != null) {
    for (final t in _boxes(b, mvex.body, mvex.end).where((x) => x.type == 'trex')) {
      if (v.getUint32(t.body + 4) == a.trackId) trexSize = v.getUint32(t.body + 16);
    }
  }
  for (final moof in top.where((x) => x.type == 'moof')) {
    for (final traf in _boxes(b, moof.body, moof.end).where((x) => x.type == 'traf')) {
      final tfhd = _child(b, traf, 'tfhd');
      if (tfhd == null || v.getUint32(tfhd.body + 4) != a.trackId) continue;
      final tf = v.getUint32(tfhd.body) & 0xFFFFFF;
      var o = tfhd.body + 8;
      var base = moof.start;
      if (tf & 0x1 != 0) {
        base = v.getUint64(o);
        o += 8;
      }
      if (tf & 0x2 != 0) o += 4;
      if (tf & 0x8 != 0) o += 4;
      var defSize = trexSize;
      if (tf & 0x10 != 0) defSize = v.getUint32(o);
      var cursor = base;
      for (final trun in _boxes(b, traf.body, traf.end).where((x) => x.type == 'trun')) {
        final rf = v.getUint32(trun.body) & 0xFFFFFF;
        final count = v.getUint32(trun.body + 4);
        var p = trun.body + 8;
        if (rf & 0x1 != 0) {
          cursor = base + v.getInt32(p);
          p += 4;
        }
        if (rf & 0x4 != 0) p += 4;
        for (var i = 0; i < count; i++) {
          if (rf & 0x100 != 0) p += 4;
          var size = defSize;
          if (rf & 0x200 != 0) {
            size = v.getUint32(p);
            p += 4;
          }
          if (rf & 0x400 != 0) p += 4;
          if (rf & 0x800 != 0) p += 4;
          if (size <= 0 || cursor + size > b.length) return null;
          packets.add(Uint8List.sublistView(b, cursor, cursor + size));
          cursor += size;
        }
      }
    }
  }
  if (packets.isEmpty) return null;
  return OpusTrack(channels: channels, preSkip: preSkip, packets: packets);
}

OpusTrack? _opusHead(Uint8List? head, List<Uint8List> packets) {
  if (head == null || !_at(head, 0, 'OpusHead'.codeUnits) || head.length < 19) {
    return null;
  }
  final channels = head[9];
  if (head[18] != 0 || channels < 1 || channels > 2 || packets.isEmpty) {
    return null;
  }
  final preSkip = head[10] | (head[11] << 8);
  return OpusTrack(channels: channels, preSkip: preSkip, packets: packets);
}

const Set<int> _ebmlMasters = {
  0x18538067,
  0x1F43B675,
  0x1654AE6B,
  0xAE,
  0xA0,
};

OpusTrack? opusFromWebm(Uint8List b) {
  try {
    return _opusFromWebm(b);
  } catch (_) {
    return null;
  }
}

OpusTrack? _opusFromWebm(Uint8List b) {
  if (!_at(b, 0, const [0x1A, 0x45, 0xDF, 0xA3])) return null;
  int vlen(int first) {
    for (var i = 0; i < 8; i++) {
      if (first & (0x80 >> i) != 0) return i + 1;
    }
    return 0;
  }

  final tracks = <Map<String, Object?>>[];
  final blocks = <(int, Uint8List)>[];
  var o = 0;
  while (o < b.length) {
    final il = vlen(b[o]);
    if (il == 0 || il > 4 || o + il >= b.length) break;
    var id = 0;
    for (var i = 0; i < il; i++) {
      id = (id << 8) | b[o + i];
    }
    o += il;
    final sl = vlen(b[o]);
    if (sl == 0 || o + sl > b.length) break;
    var size = b[o] & (0xFF >> sl);
    var allOnes = size == (0xFF >> sl);
    for (var i = 1; i < sl; i++) {
      size = size * 256 + b[o + i];
      if (b[o + i] != 0xFF) allOnes = false;
    }
    o += sl;
    if (_ebmlMasters.contains(id)) {
      if (id == 0xAE) tracks.add(<String, Object?>{});
      continue;
    }
    if (allOnes) return null;
    final end = o + size;
    if (end > b.length) break;
    if (id == 0x1A45DFA3) {
      o = end;
      continue;
    }
    if (tracks.isNotEmpty) {
      if (id == 0xD7) {
        var n = 0;
        for (var i = o; i < end; i++) {
          n = (n << 8) | b[i];
        }
        tracks.last['num'] = n;
      } else if (id == 0x86) {
        tracks.last['codec'] = String.fromCharCodes(b, o, end);
      } else if (id == 0x63A2) {
        tracks.last['head'] = Uint8List.sublistView(b, o, end);
      }
    }
    if ((id == 0xA3 || id == 0xA1) && size > 4) {
      final tl = vlen(b[o]);
      if (tl == 0 || o + tl + 3 > end) return null;
      final track = b[o] & (0xFF >> tl);
      final flags = b[o + tl + 2];
      if ((flags >> 1) & 3 != 0) return null;
      blocks.add((track, Uint8List.sublistView(b, o + tl + 3, end)));
    }
    o = end;
  }
  final opus = tracks.where((t) => t['codec'] == 'A_OPUS').firstOrNull;
  if (opus == null) return null;
  final num = opus['num'] as int? ?? 1;
  return _opusHead(opus['head'] as Uint8List?,
      [for (final (t, p) in blocks) if (t == num) p]);
}

OpusTrack? opusFromOgg(Uint8List b) {
  try {
    return _opusFromOgg(b);
  } catch (_) {
    return null;
  }
}

OpusTrack? _opusFromOgg(Uint8List b) {
  final v = ByteData.sublistView(b);
  final streams = <int, List<Uint8List>>{};
  final partial = <int, BytesBuilder>{};
  var o = 0;
  while (o + 27 <= b.length && _at(b, o, 'OggS'.codeUnits)) {
    final serial = v.getUint32(o + 14, Endian.little);
    final segs = b[o + 26];
    var data = o + 27 + segs;
    if (data > b.length) return null;
    final list = streams.putIfAbsent(serial, () => <Uint8List>[]);
    for (var i = 0; i < segs; i++) {
      final len = b[o + 27 + i];
      if (data + len > b.length) return null;
      final buf = partial.putIfAbsent(serial, () => BytesBuilder(copy: false));
      buf.add(Uint8List.sublistView(b, data, data + len));
      data += len;
      if (len < 255) {
        list.add(buf.takeBytes());
      }
    }
    o = data;
  }
  for (final packets in streams.values) {
    if (packets.length < 3) continue;
    final t = _opusHead(packets.first, packets.sublist(2));
    if (t != null) return t;
  }
  return null;
}

int opusPacketSamples(Uint8List p) {
  if (p.isEmpty) return 0;
  final toc = p[0];
  final config = toc >> 3;
  final int frame;
  if (config < 12) {
    frame = const [480, 960, 1920, 2880][config & 3];
  } else if (config < 16) {
    frame = const [480, 960][config & 1];
  } else {
    frame = const [120, 240, 480, 960][config & 3];
  }
  final code = toc & 3;
  final frames = code == 0
      ? 1
      : code < 3
          ? 2
          : (p.length > 1 ? p[1] & 0x3F : 0);
  return frame * frames;
}

void _varint(BytesBuilder out, int n) {
  final groups = <int>[n & 0x7F];
  n >>= 7;
  while (n > 0) {
    groups.add(n & 0x7F);
    n >>= 7;
  }
  for (var i = groups.length - 1; i >= 0; i--) {
    out.addByte(i > 0 ? groups[i] | 0x80 : groups[i]);
  }
}

Uint8List _chunk(String type, Uint8List body) {
  final h = ByteData(12);
  for (var i = 0; i < 4; i++) {
    h.setUint8(i, type.codeUnitAt(i));
  }
  h.setInt64(4, body.length);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...body]);
}

Uint8List opusToCaf(OpusTrack t) {
  final frames = [for (final p in t.packets) opusPacketSamples(p)];
  final total = frames.fold<int>(0, (s, f) => s + f);
  final constant = frames.every((f) => f == frames.first) ? frames.first : 0;
  final desc = ByteData(32)
    ..setFloat64(0, 48000)
    ..setUint32(8, 0x6F707573)
    ..setUint32(12, 0)
    ..setUint32(16, 0)
    ..setUint32(20, constant)
    ..setUint32(24, t.channels)
    ..setUint32(28, 0);
  final chan = ByteData(12)
    ..setUint32(0, t.channels == 1 ? 0x00640001 : 0x00650002);
  final table = BytesBuilder();
  for (var i = 0; i < t.packets.length; i++) {
    _varint(table, t.packets[i].length);
    if (constant == 0) _varint(table, frames[i]);
  }
  final pakt = ByteData(24)
    ..setInt64(0, t.packets.length)
    ..setInt64(8, total)
    ..setInt32(16, 0)
    ..setInt32(20, 0);
  final data = BytesBuilder(copy: false)..add(Uint8List(4));
  for (final p in t.packets) {
    data.add(p);
  }
  final out = BytesBuilder(copy: false)
    ..add(const [0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0])
    ..add(_chunk('desc', desc.buffer.asUint8List()))
    ..add(_chunk('chan', chan.buffer.asUint8List()))
    ..add(_chunk('pakt',
        Uint8List.fromList([...pakt.buffer.asUint8List(), ...table.takeBytes()])))
    ..add(_chunk('data', data.takeBytes()));
  return out.takeBytes();
}

VoiceFile? _caf(OpusTrack? t) =>
    t == null ? null : VoiceFile(opusToCaf(t), 'caf', null);

VoiceFile? voiceFileFor(Uint8List bytes, String mime, TargetPlatform platform) {
  if (!_isApple(platform)) {
    return VoiceFile(bytes, extForMime(mime), baseMime(mime));
  }
  switch (sniffVoiceContainer(bytes)) {
    case VoiceContainer.mp4:
      return mp4AudioCodec(bytes) == 'Opus'
          ? _caf(opusFromMp4(bytes))
          : VoiceFile(bytes, 'm4a', null);
    case VoiceContainer.webm:
      return _caf(opusFromWebm(bytes));
    case VoiceContainer.ogg:
      return _caf(opusFromOgg(bytes));
    case VoiceContainer.wav:
      return VoiceFile(bytes, 'wav', null);
    case VoiceContainer.mp3:
      return VoiceFile(bytes, 'mp3', null);
    case VoiceContainer.adts:
      return VoiceFile(bytes, 'aac', null);
    case VoiceContainer.caf:
      return VoiceFile(bytes, 'caf', null);
    case VoiceContainer.unknown:
      final ext = extForMime(mime);
      if (ext == 'webm' || ext == 'ogg' || ext == 'bin') return null;
      return VoiceFile(bytes, ext == 'mp4' ? 'm4a' : ext, null);
  }
}
