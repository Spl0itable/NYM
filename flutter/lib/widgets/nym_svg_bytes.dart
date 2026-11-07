import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/utils/isolate_gate.dart';

typedef NymSvgCompile = Future<ByteData> Function(SvgStringLoader loader);

Future<ByteData> nymSvgCompileOnce(SvgStringLoader loader) {
  final key = loader.cacheKey(null);
  return loader.loadBytes(null).then((ByteData data) {
    svg.cache.evict(key);
    return data;
  });
}

@immutable
class NymSvgLoader extends BytesLoader {
  const NymSvgLoader(this.source, {this.color});

  final String source;
  final Color? color;

  @override
  Future<ByteData> loadBytes(BuildContext? context) => NymSvgBytes.load(this);

  @override
  bool operator ==(Object other) =>
      other is NymSvgLoader && other.source == source && other.color == color;

  @override
  int get hashCode => Object.hash(source, color);
}

@immutable
class NymSvgTemplate {
  const NymSvgTemplate._(this._bytes, this.slots);

  factory NymSvgTemplate.of(ByteData a, ByteData b) {
    final x = Uint8List.sublistView(a);
    final y = Uint8List.sublistView(b);
    final bytes = Uint8List.fromList(x);
    if (x.length != y.length) return NymSvgTemplate._(bytes, null);
    final pa = NymSvgBytes.probeA.toARGB32();
    final pb = NymSvgBytes.probeB.toARGB32();
    final slots = <int>[];
    var i = 0;
    while (i < x.length) {
      if (x[i] == y[i]) {
        i++;
        continue;
      }
      if (i + 4 > x.length ||
          a.getUint32(i, Endian.little) != pa ||
          b.getUint32(i, Endian.little) != pb) {
        return NymSvgTemplate._(bytes, null);
      }
      slots.add(i);
      i += 4;
    }
    return NymSvgTemplate._(bytes, List<int>.unmodifiable(slots));
  }

  final Uint8List _bytes;
  final List<int>? slots;

  bool get patchable => slots != null;

  ByteData paint(Color color) {
    final out = Uint8List.fromList(_bytes);
    final view = ByteData.sublistView(out);
    final value = color.toARGB32();
    for (final s in slots!) {
      view.setUint32(s, value, Endian.little);
    }
    return view;
  }
}

class _Store<K, V extends Object> {
  _Store(this.capacity);

  final int capacity;
  final LinkedHashMap<K, V> _ready = LinkedHashMap<K, V>();
  final Map<K, Future<V>> _pending = <K, Future<V>>{};

  int get length => _ready.length;

  V? peek(K key) => _ready[key];

  Future<V>? pending(K key) => _pending[key];

  void clear() {
    _ready.clear();
    _pending.clear();
  }

  Future<V> load(K key, Future<V> Function() make) {
    final hit = _ready.remove(key);
    if (hit != null) {
      _ready[key] = hit;
      return SynchronousFuture<V>(hit);
    }
    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;
    var settled = false;
    final result = make().then<V>(
      (V value) {
        settled = true;
        _pending.remove(key);
        _ready[key] = value;
        while (_ready.length > capacity) {
          _ready.remove(_ready.keys.first);
        }
        return value;
      },
      onError: (Object error, StackTrace stack) {
        settled = true;
        _pending.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    if (!settled) _pending[key] = result;
    return result;
  }
}

class NymSvgBytes {
  NymSvgBytes._();

  static const Color probeA = Color(0xFF13579B);
  static const Color probeB = Color(0xFE2468AC);
  static const int templateCapacity = 512;
  static const int directCapacity = 256;

  static final _Store<String, NymSvgTemplate> _templates =
      _Store<String, NymSvgTemplate>(templateCapacity);
  static final _Store<NymSvgLoader, ByteData> _direct =
      _Store<NymSvgLoader, ByteData>(directCapacity);

  static IsolateGate? gate =
      (kDebugMode || kIsWeb) ? null : IsolateGate.shared;
  static NymSvgCompile compile = nymSvgCompileOnce;

  static int get templates => _templates.length;

  static int get direct => _direct.length;

  static NymSvgTemplate? template(String source) => _templates.peek(source);

  static bool isDirect(NymSvgLoader key) => _direct.peek(key) != null;

  static bool isPending(NymSvgLoader key) =>
      _templates.pending(key.source) != null || _direct.pending(key) != null;

  @visibleForTesting
  static void reset() {
    _templates.clear();
    _direct.clear();
    gate = (kDebugMode || kIsWeb) ? null : IsolateGate.shared;
    compile = nymSvgCompileOnce;
  }

  static Future<T> gated<T>(Future<T> Function() body) {
    final g = gate;
    return g == null ? body() : g.hold((_) => body());
  }

  static Future<ByteData> load(NymSvgLoader key) {
    final color = key.color;
    if (color == null) return _compileDirect(key);
    return _templates.load(key.source, () => _probe(key.source)).then(
        (NymSvgTemplate t) =>
            t.patchable ? t.paint(color) : _compileDirect(key));
  }

  static Future<ByteData> _compileDirect(NymSvgLoader key) {
    final c = key.color;
    final run = compile;
    return _direct.load(
        key,
        () => gated(() => run(SvgStringLoader(key.source,
            theme: c == null ? null : SvgTheme(currentColor: c)))));
  }

  static Future<NymSvgTemplate> _probe(String source) {
    final run = compile;
    final a = gated(() =>
        run(SvgStringLoader(source, theme: const SvgTheme(currentColor: probeA))));
    final b = gated(() =>
        run(SvgStringLoader(source, theme: const SvgTheme(currentColor: probeB))));
    return a.then<NymSvgTemplate>(
      (ByteData x) => b.then<NymSvgTemplate>((ByteData y) => NymSvgTemplate.of(x, y)),
      onError: (Object error, StackTrace stack) {
        b.ignore();
        Error.throwWithStackTrace(error, stack);
      },
    );
  }
}
