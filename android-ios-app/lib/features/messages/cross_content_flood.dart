/// A token bucket keyed on the CONTENT of a message rather than its sender.
///
/// The per-pubkey tracker in flood_tracker.dart taxes one key sending the same
/// thing repeatedly, which a spammer defeats with a fresh key per message —
/// and that is the pattern these channels actually see. This keys on a hash of
/// the normalized payload, so the same text from fifty keys draws on one
/// allowance.
///
/// Mirrors `isDuplicateContentFlooding` in the PWA's js/modules/messages.js,
/// including the constants: three copies, then one more every two seconds.
class CrossContentFlood {
  CrossContentFlood({
    this.capacity = 3,
    this.refillPerSecond = 0.5,
    this.minLength = 24,
    this.maxBuckets = 2000,
    this.idle = const Duration(minutes: 10),
  });

  final int capacity;
  final double refillPerSecond;

  /// Below this, a payload is exempt. "gm", an emoji and a short greeting are
  /// supposed to arrive from everyone at once.
  final int minLength;

  final int maxBuckets;
  final Duration idle;

  final Map<int, _Bucket> _buckets = <int, _Bucket>{};

  int get length => _buckets.length;
  void clear() => _buckets.clear();

  /// True when this exact payload has used up its allowance, whoever sent the
  /// earlier copies.
  bool isFlooding(String? content, {DateTime? now}) {
    final key = _key(content);
    if (key == null) return false;
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;

    var bucket = _buckets[key];
    if (bucket == null) {
      if (_buckets.length >= maxBuckets) _evict(t);
      bucket = _Bucket(tokens: capacity.toDouble(), last: t);
      _buckets[key] = bucket;
    }

    final elapsed = ((t - bucket.last).clamp(0, 1 << 30)) / 1000.0;
    bucket.tokens = (bucket.tokens + elapsed * refillPerSecond)
        .clamp(0.0, capacity.toDouble());
    bucket.last = t;
    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return false;
    }
    return true;
  }

  void _evict(int now) {
    _buckets.removeWhere((_, b) => now - b.last >= idle.inMilliseconds);
    if (_buckets.length < maxBuckets) return;
    int? oldestKey;
    var oldest = 1 << 62;
    _buckets.forEach((k, b) {
      if (b.last < oldest) {
        oldest = b.last;
        oldestKey = k;
      }
    });
    if (oldestKey != null) _buckets.remove(oldestKey);
  }

  static final RegExp _url = RegExp(r'(https?:\/\/[^\s?#]+)(?:[?#]\S*)?');
  static final RegExp _space = RegExp(r'\s+');

  /// Query strings and fragments are stripped from URLs, so one campaign with
  /// a per-victim tracking parameter is still one payload.
  int? _key(String? content) {
    if (content == null) return null;
    final s = content
        .toLowerCase()
        .replaceAllMapped(_url, (m) => m[1]!)
        .replaceAll(_space, ' ')
        .trim();
    if (s.length < minLength) return null;
    return _fnv1a(s.length > 160 ? s.substring(0, 160) : s);
  }

  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }
}

class _Bucket {
  _Bucket({required this.tokens, required this.last});
  double tokens;
  int last;
}

/// Process-wide, like the PWA's single bucket map on the app object: the point
/// is that it spans senders, so it cannot be per-conversation.
CrossContentFlood crossContentFlood = CrossContentFlood();
