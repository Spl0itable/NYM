import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import 'media_notes.dart';

abstract class MediaNotePrefs {
  String? read(String key);
  void write(String key, String value);
}

class KeyValueMediaPrefs implements MediaNotePrefs {
  KeyValueMediaPrefs(this._kv);

  final KeyValueStore _kv;

  @override
  String? read(String key) => _kv.getString(key);

  @override
  void write(String key, String value) {
    _kv.setString(key, value).ignore();
  }
}

class MemoryMediaPrefs implements MediaNotePrefs {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;
}

Map<String, dynamic> _readMap(MediaNotePrefs prefs, String key) {
  try {
    final raw = prefs.read(key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

int _stamp(dynamic v) =>
    v is Map && v['t'] is num ? (v['t'] as num).toInt() : 0;

void _writeMap(MediaNotePrefs prefs, String key, Map<String, dynamic> map,
    int cap) {
  try {
    if (map.length > cap) {
      final keys = map.keys.toList()
        ..sort((a, b) => _stamp(map[a]).compareTo(_stamp(map[b])));
      for (final k in keys.take(map.length - cap)) {
        map.remove(k);
      }
    }
    prefs.write(key, jsonEncode(map));
  } catch (_) {}
}

class OnceStore {
  OnceStore(this._prefs);

  final MediaNotePrefs _prefs;

  bool isOpened(String onceId) =>
      _readMap(_prefs, MediaNoteKeys.opened)[onceId] != null;

  bool markOpened(String onceId, [int? nowMs]) {
    final m = _readMap(_prefs, MediaNoteKeys.opened);
    if (m[onceId] != null) return false;
    m[onceId] = {'t': nowMs ?? DateTime.now().millisecondsSinceEpoch};
    _writeMap(_prefs, MediaNoteKeys.opened, m, 2000);
    return true;
  }

  List<String> remoteOpenedBy(String onceId) {
    final v = _readMap(_prefs, MediaNoteKeys.remoteOpened)[onceId];
    if (v is Map && v['by'] is List) {
      return (v['by'] as List).map((e) => e.toString()).toList();
    }
    return const <String>[];
  }

  bool markRemoteOpened(String onceId, String byPubkey, [int? nowMs]) {
    final m = _readMap(_prefs, MediaNoteKeys.remoteOpened);
    final cur = m[onceId];
    final by = cur is Map && cur['by'] is List
        ? (cur['by'] as List).map((e) => e.toString()).toList()
        : <String>[];
    if (by.contains(byPubkey)) return false;
    by.add(byPubkey);
    m[onceId] = {'by': by, 't': nowMs ?? DateTime.now().millisecondsSinceEpoch};
    _writeMap(_prefs, MediaNoteKeys.remoteOpened, m, 2000);
    return true;
  }
}

class TranscriptStore {
  TranscriptStore(this._prefs);

  final MediaNotePrefs _prefs;

  String? get(String key) {
    final v = _readMap(_prefs, MediaNoteKeys.transcripts)[key];
    return v is Map && v['text'] is String ? v['text'] as String : null;
  }

  void set(String key, String text, [int? nowMs]) {
    final m = _readMap(_prefs, MediaNoteKeys.transcripts);
    final clipped = text.length > 20000 ? text.substring(0, 20000) : text;
    m[key] = {'text': clipped, 't': nowMs ?? DateTime.now().millisecondsSinceEpoch};
    _writeMap(_prefs, MediaNoteKeys.transcripts, m, 200);
  }
}

final mediaNotePrefsProvider = Provider<MediaNotePrefs>(
    (ref) => KeyValueMediaPrefs(ref.watch(keyValueStoreProvider)));

final onceStoreProvider =
    Provider<OnceStore>((ref) => OnceStore(ref.watch(mediaNotePrefsProvider)));

final transcriptStoreProvider = Provider<TranscriptStore>(
    (ref) => TranscriptStore(ref.watch(mediaNotePrefsProvider)));

final onceRevisionProvider = StateProvider<int>((ref) => 0);

class VoiceSpeedController extends StateNotifier<double> {
  VoiceSpeedController(this._prefs)
      : super(parseSpeed(_prefs.read(MediaNoteKeys.speed)));

  final MediaNotePrefs _prefs;

  double cycle() {
    final next = nextSpeed(state);
    _prefs.write(MediaNoteKeys.speed, _speedString(next));
    state = next;
    return next;
  }

  static String _speedString(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
}

final voiceSpeedProvider = StateNotifierProvider<VoiceSpeedController, double>(
    (ref) => VoiceSpeedController(ref.watch(mediaNotePrefsProvider)));
