final RegExp _suffixRe = RegExp(r'#[0-9a-f]{4}$', caseSensitive: false);
final RegExp _suffixCaptureRe = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);
final RegExp _quoteHeadRe = RegExp(r'^>\s*@([^:\n]+):');

class ContentFilterCtx {
  const ContentFilterCtx({
    this.self = '',
    this.blockedUsers = const <String>{},
    this.keywords = const <String>[],
    this.blockedChannels = const <String>[],
    this.hiddenChannels = const <String>[],
    this.friendsOnly = false,
    this.packs = false,
    this.friend,
    this.bot,
    this.pack,
    this.muted,
    this.deleted,
    this.quiet,
    this.spam,
    this.gated,
  });

  final String self;
  final Set<String> blockedUsers;
  final Iterable<String> keywords;
  final Iterable<String> blockedChannels;
  final Iterable<String> hiddenChannels;
  final bool friendsOnly;
  final bool packs;
  final bool Function(String pubkey)? friend;
  final bool Function(String pubkey)? bot;
  final bool Function(String text, String nym)? pack;
  final bool Function(String pubkey)? muted;
  final bool Function(Object? ref)? deleted;
  final bool Function(Object? ref)? quiet;
  final bool Function(Object? ref)? spam;
  final bool Function(Object? ref)? gated;
}

class CfItem {
  const CfItem({
    this.pubkey = '',
    this.content,
    this.nym = '',
    this.own = false,
    this.system = false,
    this.mesh = false,
  });

  final String pubkey;
  final String? content;
  final String nym;
  final bool own;
  final bool system;
  final bool mesh;
}

class CfEntry {
  const CfEntry({
    this.sender = '',
    this.nym = '',
    this.body = '',
    this.channel = '',
    this.subject = '',
  });

  final String sender;
  final String nym;
  final String body;
  final String channel;
  final String subject;
}

abstract final class ContentFilter {
  static String baseNym(String nym) =>
      nym.trim().replaceFirst(_suffixRe, '').trim();

  static String nymSuffix(String nym) {
    final m = _suffixCaptureRe.firstMatch(nym.trim());
    return m == null ? '' : m.group(1)!.toLowerCase();
  }

  static bool keywordHit(Iterable<String> keywords, String text, String nym) {
    final t = text.toLowerCase();
    final n = baseNym(nym).toLowerCase();
    for (final raw in keywords) {
      final k = raw.trim().toLowerCase();
      if (k.isEmpty) continue;
      if (t.contains(k) || (n.isNotEmpty && n.contains(k))) return true;
    }
    return false;
  }

  static bool _exempt(ContentFilterCtx c, String pubkey) {
    if (pubkey.isEmpty) return false;
    if (c.self.isNotEmpty && pubkey == c.self) return true;
    if (c.friend?.call(pubkey) == true) return true;
    if (c.bot?.call(pubkey) == true) return true;
    return false;
  }

  static bool textBlocked(
      ContentFilterCtx c, String text, String nym, String pubkey) {
    if (keywordHit(c.keywords, text, nym)) return true;
    final pack = c.pack;
    if (pack == null || _exempt(c, pubkey)) return false;
    return pack(text, nym);
  }

  static List<String> quoteAuthors(String text) {
    final out = <String>[];
    for (final line in text.split('\n')) {
      final m = _quoteHeadRe.firstMatch(line);
      if (m != null) out.add(m.group(1)!.trim());
    }
    return out;
  }

  static bool userBlocked(ContentFilterCtx c, String pubkey) =>
      pubkey.isNotEmpty && c.blockedUsers.contains(pubkey);

  static bool personHidden(ContentFilterCtx c, String pubkey, String nym) {
    if (pubkey.isNotEmpty && c.self.isNotEmpty && pubkey == c.self) {
      return false;
    }
    if (pubkey.isNotEmpty && c.blockedUsers.contains(pubkey)) return true;
    if (pubkey.isNotEmpty && c.muted?.call(pubkey) == true) return true;
    return textBlocked(c, '', nym, pubkey);
  }

  static bool quoteBlocked(ContentFilterCtx c, String author) {
    final sfx = nymSuffix(author);
    if (sfx.isEmpty) return false;
    for (final p in c.blockedUsers) {
      if (p.length >= 4 && p.substring(p.length - 4).toLowerCase() == sfx) {
        return true;
      }
    }
    return false;
  }

  static String stripBlockedQuotes(ContentFilterCtx c, String text) {
    if (!text.contains('>')) return text;
    final out = <String>[];
    var skipping = false;
    var removed = false;
    for (final line in text.split('\n')) {
      final m = _quoteHeadRe.firstMatch(line);
      if (m != null) {
        skipping = quoteBlocked(c, m.group(1)!.trim());
        if (skipping) {
          removed = true;
          continue;
        }
        out.add(line);
        continue;
      }
      if (skipping && line.startsWith('>')) continue;
      skipping = false;
      out.add(line);
    }
    if (!removed) return text;
    while (out.isNotEmpty && out.first.trim().isEmpty) {
      out.removeAt(0);
    }
    return out.join('\n');
  }

  static String channelKey(String key) {
    final k = key.trim();
    return (k.startsWith('#') ? k.substring(1) : k).toLowerCase();
  }

  static bool _inChannels(Iterable<String> set, String key) {
    final k = channelKey(key);
    if (k.isEmpty) return false;
    for (final v in set) {
      if (channelKey(v) == k) return true;
    }
    return false;
  }

  static bool channelBlocked(ContentFilterCtx c, String key) =>
      _inChannels(c.blockedChannels, key);

  static bool channelHidden(ContentFilterCtx c, String key) =>
      channelBlocked(c, key) || _inChannels(c.hiddenChannels, key);

  static bool _isOwn(ContentFilterCtx c, CfItem m) =>
      m.own || (c.self.isNotEmpty && m.pubkey == c.self);

  static bool hidden(ContentFilterCtx c, CfItem m, [Object? ref]) {
    final r = ref ?? m;
    if (m.system) return false;
    if (c.deleted?.call(r) == true) return true;
    final own = _isOwn(c, m);
    if (!own && m.pubkey.isNotEmpty && c.blockedUsers.contains(m.pubkey)) {
      return true;
    }
    if (!own && c.muted?.call(m.pubkey) == true) return true;
    if (textBlocked(c, m.content ?? '', m.nym, m.pubkey)) return true;
    if (own || m.mesh) return false;
    if (c.quiet?.call(r) == true) return true;
    if (c.spam?.call(r) == true) return true;
    if (c.gated?.call(r) == true) return true;
    return false;
  }

  static bool countsUnread(ContentFilterCtx c, CfItem m, [Object? ref]) {
    if (m.system || _isOwn(c, m)) return false;
    return !hidden(c, m, ref);
  }

  static int lastVisible<T>(
      ContentFilterCtx c, List<T> items, CfItem? Function(T raw) view) {
    for (var i = items.length - 1; i >= 0; i--) {
      final raw = items[i];
      final m = view(raw);
      if (m == null || m.content == null || m.system) continue;
      if (hidden(c, m, raw)) continue;
      return i;
    }
    return -1;
  }

  static bool entryHidden(ContentFilterCtx c, CfEntry e) {
    final sender = e.sender;
    final self = sender.isNotEmpty && sender == c.self;
    if (sender.isNotEmpty && !self && c.blockedUsers.contains(sender)) {
      return true;
    }
    if (sender.isNotEmpty && !self && c.muted?.call(sender) == true) {
      return true;
    }
    if (sender.isNotEmpty &&
        !self &&
        c.friendsOnly &&
        c.friend?.call(sender) != true &&
        c.bot?.call(sender) != true) {
      return true;
    }
    if (e.channel.isNotEmpty && channelHidden(c, e.channel)) return true;
    if (textBlocked(c, e.body, e.nym, sender)) return true;
    if (e.subject.isNotEmpty && textBlocked(c, e.subject, '', sender)) {
      return true;
    }
    return false;
  }

  static bool activeFilters(ContentFilterCtx c) {
    if (c.blockedUsers.isNotEmpty) return true;
    if (c.keywords.any((k) => k.trim().isNotEmpty)) return true;
    return c.packs;
  }
}
