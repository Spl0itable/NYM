class CampaignVerdict {
  const CampaignVerdict({required this.flood, required this.mute});

  final bool flood;

  final bool mute;

  static const CampaignVerdict none =
      CampaignVerdict(flood: false, mute: false);
}

class CrossContentFlood {
  CrossContentFlood({
    this.window = const Duration(minutes: 15),
    this.allowance = 3,
    this.senderRepeat = 3,
    this.stampedRepeat = 4,
    this.minStamped = 8,
    this.minLength = 24,
    this.minShingles = 8,
    this.similarity = 0.6,
    this.maxClusters = 2000,
    this.maxHits = 64,
  });

  final Duration window;

  final int allowance;

  final int senderRepeat;

  final int stampedRepeat;

  final int minStamped;

  final int minLength;

  final int minShingles;

  final double similarity;

  final int maxClusters;
  final int maxHits;

  final Set<_Cluster> _clusters = <_Cluster>{};
  final Map<int, _Cluster> _byKey = <int, _Cluster>{};
  final Map<int, Set<_Cluster>> _byShingle = <int, Set<_Cluster>>{};
  final Map<String, List<_StampHit>> _bySender = <String, List<_StampHit>>{};
  static const int _maxSenders = 4096;
  static const int _maxSenderHits = 32;

  int get length => _clusters.length;

  void clear() {
    _clusters.clear();
    _byKey.clear();
    _byShingle.clear();
    _bySender.clear();
  }

  CampaignVerdict check(String? content, String pubkey,
      {int createdAtMs = 0, DateTime? now}) {
    final tokens = campaignTokens(content);
    final text = tokens.join(' ');
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final created = createdAtMs > 0 ? createdAtMs : t;
    final stamped = _stampedRepeat(content, pubkey, t, created);
    if (text.length < minLength) {
      return stamped
          ? const CampaignVerdict(flood: true, mute: true)
          : CampaignVerdict.none;
    }
    final key = fnv1a32(text);
    final shingles = _shingles(tokens);

    var cluster = _match(key, shingles);
    if (cluster == null) {
      if (_clusters.length >= maxClusters) _evict(t);
      cluster = _Cluster(shingles: shingles, last: t);
      _clusters.add(cluster);
      for (final s in shingles) {
        _byShingle.putIfAbsent(s, () => <_Cluster>{}).add(cluster);
      }
    }
    if (cluster.keys.add(key)) _byKey[key] = cluster;
    cluster.last = t;

    final w = window.inMilliseconds;
    final hits = cluster.hits.where((h) => t - h.at <= w).toList();
    hits.add(_Hit(pubkey: pubkey, at: t, created: created));
    if (hits.length > maxHits) hits.removeRange(0, hits.length - maxHits);
    cluster.hits = hits;

    var copies = 0, mine = 0;
    for (final h in hits) {
      if ((h.at - t).abs() > w && (h.created - created).abs() > w) continue;
      copies++;
      if (pubkey.isNotEmpty && h.pubkey == pubkey) mine++;
    }
    final flood = copies > allowance || stamped;
    final mute = stamped ||
        pubkey.isNotEmpty && (mine >= senderRepeat || (flood && mine >= 2));
    return CampaignVerdict(flood: flood, mute: mute);
  }

  bool _stampedRepeat(String? content, String pubkey, int t, int created) {
    if (pubkey.isEmpty || content == null) return false;
    final raw = content.toLowerCase().trim().replaceAll(_space, ' ');
    if (raw.isEmpty) return false;
    final template = raw.replaceAll(_digit, '').replaceAll(_space, ' ').trim();
    if (template == raw ||
        template.length < minStamped ||
        !template.contains(' ')) {
      return false;
    }
    final w = window.inMilliseconds;
    final hit = _StampHit(
        template: fnv1a32(template), raw: fnv1a32(raw), at: t, created: created);
    var hits = _bySender[pubkey];
    if (hits == null) {
      if (_bySender.length >= _maxSenders) _evictSenders(t);
      hits = _bySender[pubkey] = <_StampHit>[];
    }
    hits.removeWhere((h) => t - h.at > w);
    hits.add(hit);
    if (hits.length > _maxSenderHits) {
      hits.removeRange(0, hits.length - _maxSenderHits);
    }
    final raws = <int>{};
    for (final h in hits) {
      if (h.template != hit.template) continue;
      if ((h.at - t).abs() > w && (h.created - created).abs() > w) continue;
      raws.add(h.raw);
    }
    return raws.length >= stampedRepeat;
  }

  void _evictSenders(int now) {
    final w = window.inMilliseconds;
    _bySender.removeWhere((_, hits) => hits.isEmpty || now - hits.last.at > w);
    if (_bySender.length < _maxSenders) return;
    String? oldest;
    var oldestAt = now;
    _bySender.forEach((pk, hits) {
      if (hits.last.at <= oldestAt) {
        oldestAt = hits.last.at;
        oldest = pk;
      }
    });
    if (oldest != null) _bySender.remove(oldest);
  }

  bool isFlooding(String? content, {String pubkey = '', DateTime? now}) =>
      check(content, pubkey, now: now).flood;

  _Cluster? _match(int key, Set<int> shingles) {
    final exact = _byKey[key];
    if (exact != null) return exact;
    if (shingles.length < minShingles) return null;
    final votes = <_Cluster, int>{};
    for (final s in shingles) {
      final owners = _byShingle[s];
      if (owners == null) continue;
      for (final c in owners) {
        votes[c] = (votes[c] ?? 0) + 1;
      }
    }
    _Cluster? best;
    var bestScore = 0.0;
    votes.forEach((c, v) {
      if (c.shingles.length < minShingles) return;
      final score = v / (shingles.length + c.shingles.length - v);
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    });
    return bestScore >= similarity ? best : null;
  }

  void _drop(_Cluster cluster) {
    _clusters.remove(cluster);
    for (final k in cluster.keys) {
      if (identical(_byKey[k], cluster)) _byKey.remove(k);
    }
    for (final s in cluster.shingles) {
      final owners = _byShingle[s];
      if (owners == null) continue;
      owners.remove(cluster);
      if (owners.isEmpty) _byShingle.remove(s);
    }
  }

  void _evict(int now) {
    final idle = window.inMilliseconds * 2;
    for (final c in _clusters.toList()) {
      if (now - c.last >= idle) _drop(c);
    }
    if (_clusters.length < maxClusters) return;
    _Cluster? oldest;
    for (final c in _clusters) {
      if (oldest == null || c.last < oldest.last) oldest = c;
    }
    if (oldest != null) _drop(oldest);
  }

  Set<int> _shingles(List<String> tokens) {
    final set = <int>{};
    if (tokens.length == 1) {
      set.add(fnv1a32(tokens[0]));
      return set;
    }
    for (var i = 0; i + 1 < tokens.length; i++) {
      set.add(fnv1a32('${tokens[i]} ${tokens[i + 1]}'));
    }
    return set;
  }

  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _urlStart = RegExp(r'^(https?://|www\.)');
  static final RegExp _urlQuery = RegExp(r'[?#].*$');
  static final RegExp _urlTail = RegExp(r'[^\p{L}\p{N}/]+$', unicode: true);
  static final RegExp _lead = RegExp(r'^[^\p{L}\p{N}@#]+', unicode: true);
  static final RegExp _trail = RegExp(r'[^\p{L}\p{N}]+$', unicode: true);
  static final RegExp _digit = RegExp(r'\p{N}', unicode: true);

  static List<String> campaignTokens(String? content) {
    if (content == null) return const [];
    final out = <String>[];
    for (var w in content.toLowerCase().split(_space)) {
      if (w.isEmpty) continue;
      if (_urlStart.hasMatch(w)) {
        w = w.replaceFirst(_urlQuery, '').replaceFirst(_urlTail, '');
        if (w.isNotEmpty) out.add(w);
        continue;
      }
      w = w.replaceFirst(_lead, '').replaceFirst(_trail, '');
      if (w.isEmpty || w.startsWith('@') || _digit.hasMatch(w)) continue;
      out.add(w);
    }
    return out;
  }

  static int fnv1a32(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = ((h & 0xffff) * 0x01000193 + (((h >> 16) * 0x01000193) << 16)) &
          0xffffffff;
    }
    return h;
  }
}

class _Cluster {
  _Cluster({required this.shingles, required this.last});
  final Set<int> keys = <int>{};
  final Set<int> shingles;
  List<_Hit> hits = <_Hit>[];
  int last;
}

class _Hit {
  const _Hit({required this.pubkey, required this.at, required this.created});
  final String pubkey;
  final int at;
  final int created;
}

class _StampHit {
  const _StampHit({
    required this.template,
    required this.raw,
    required this.at,
    required this.created,
  });
  final int template;
  final int raw;
  final int at;
  final int created;
}

CrossContentFlood crossContentFlood = CrossContentFlood();
