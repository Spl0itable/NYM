final RegExp _suffixRe = RegExp(r'#[0-9a-f]{4}$', caseSensitive: false);
final RegExp _suffixCaptureRe = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);
final RegExp _quoteHeadRe = RegExp(r'^>\s*@([^:\n]+):');
final RegExp _inviteJoinRe = RegExp(r'join\s+#([a-z0-9]+)', caseSensitive: false);

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
    this.nymOf,
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
  final String Function(String pubkey)? nymOf;
}

class CfItem {
  const CfItem({
    this.pubkey = '',
    this.content,
    this.nym = '',
    this.own = false,
    this.system = false,
    this.mesh = false,
    this.people = const <String>[],
    this.quoted = const <String>[],
  });

  final String pubkey;
  final String? content;
  final String nym;
  final bool own;
  final bool system;
  final bool mesh;
  final List<String> people;
  final List<String> quoted;
}

class CfEntry {
  const CfEntry({
    this.sender = '',
    this.nym = '',
    this.body = '',
    this.channel = '',
    this.subject = '',
    this.knownGroup = false,
    this.quoted = const <String>[],
  });

  final String sender;
  final String nym;
  final String body;
  final String channel;
  final String subject;
  final bool knownGroup;
  final List<String> quoted;
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

  static final RegExp _hex64Re = RegExp(r'^[0-9a-f]{64}$');

  static List<String> _carriedKeys(Iterable<String> quoted, String sfx) => [
        for (final raw in quoted)
          if (_hex64Re.hasMatch(raw.toLowerCase()) &&
              raw.toLowerCase().endsWith(sfx))
            raw.toLowerCase(),
      ];

  static bool quoteBlocked(ContentFilterCtx c, String author,
      [Iterable<String> quoted = const <String>[]]) {
    final sfx = nymSuffix(author);
    if (sfx.isEmpty) return false;
    final carried = _carriedKeys(quoted, sfx);
    if (carried.isNotEmpty) {
      final self = c.self.toLowerCase();
      return carried.any((p) =>
          !(self.isNotEmpty && p == self) &&
          (c.blockedUsers.contains(p) || c.muted?.call(p) == true));
    }
    for (final p in c.blockedUsers) {
      if (p.length >= 4 && p.substring(p.length - 4).toLowerCase() == sfx) {
        return true;
      }
    }
    return false;
  }

  static bool _peopleHidden(ContentFilterCtx c, List<String> people) {
    for (final pk in people) {
      if (pk.isEmpty || (c.self.isNotEmpty && pk == c.self)) continue;
      if (personHidden(c, pk, c.nymOf?.call(pk) ?? '')) return true;
    }
    return false;
  }

  static bool metaHidden(
          ContentFilterCtx c, String setter, Iterable<String> admins) =>
      setter.isNotEmpty &&
      setter != c.self &&
      c.blockedUsers.contains(setter) &&
      admins.contains(setter);

  static bool labelHidden(ContentFilterCtx c, String label) {
    final l = label.trim();
    if (l.isEmpty) return false;
    if (quoteBlocked(c, l)) return true;
    return textBlocked(c, '', l, '');
  }

  static String stripBlockedQuotes(ContentFilterCtx c, String text,
      [Iterable<String> quoted = const <String>[]]) {
    if (!text.contains('>')) return text;
    final out = <String>[];
    var skipping = false;
    var removed = false;
    for (final line in text.split('\n')) {
      final m = _quoteHeadRe.firstMatch(line);
      if (m != null) {
        skipping = quoteBlocked(c, m.group(1)!.trim(), quoted);
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

  static bool onlyBlockedQuotes(ContentFilterCtx c, String text,
      [Iterable<String> quoted = const <String>[]]) {
    if (!text.contains('>')) return false;
    final out = stripBlockedQuotes(c, text, quoted);
    return out != text && out.trim().isEmpty;
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
    if (!own && _peopleHidden(c, m.people)) return true;
    if (textBlocked(c, m.content ?? '', own ? '' : m.nym, m.pubkey)) return true;
    if (onlyBlockedQuotes(c, m.content ?? '', m.quoted)) return true;
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
    if (textBlocked(c, e.body, self ? '' : e.nym, sender)) return true;
    if (onlyBlockedQuotes(c, e.body, e.quoted)) return true;
    if (e.subject.isNotEmpty && textBlocked(c, e.subject, '', sender)) {
      return true;
    }
    return false;
  }

  static String inviteChannel(String text) {
    if (!text.contains('Channel Invitation:')) return '';
    final m = _inviteJoinRe.firstMatch(text);
    return m == null ? '' : m.group(1)!.toLowerCase();
  }

  static bool inboxHidden(ContentFilterCtx c, CfEntry e, String accept,
      [Object? ref]) {
    final sender = e.sender;
    final other = sender.isNotEmpty && sender != c.self;
    if (other && !e.knownGroup) {
      if (accept == 'disabled') return true;
      if (accept == 'friends' && c.friend?.call(sender) != true) return true;
    }
    if (other && c.spam?.call(ref ?? e) == true) return true;
    return entryHidden(c, e);
  }

  static String zapper(String claimed, String publisher, bool verified) {
    final want = claimed.toLowerCase();
    if (want.isEmpty) return publisher;
    if (verified || want == publisher.toLowerCase()) return want;
    return publisher;
  }

  static const Set<String> _blockedGroupControl = {
    'group-join-request',
    'group-add-member',
    'group-remove-member',
    'group-promote-mod',
    'group-revoke-mod',
    'group-promote-admin',
    'group-revoke-admin',
    'group-roster-req',
    'group-roster',
    'group-transfer-owner',
    'group-metadata',
    'group-delete-message',
    'group-leave',
    'group-unban',
    'key-resync',
    'group-join-pending',
    'group-join-waiting',
    'group-join-declined',
    'group-join-resolved',
  };

  static bool keepsBlockedGroupControl(String type) =>
      type.isNotEmpty && _blockedGroupControl.contains(type);

  static bool keepsBlockedChat(int kind, String type) =>
      kind == 14 && type.trim().isEmpty;

  static const int blockedKeep = 200;

  static const int blockedTotal = 400;

  static String personMask(ContentFilterCtx c, String pubkey, String nym) {
    if (pubkey.isNotEmpty && c.self.isNotEmpty && pubkey == c.self) return '';
    if (pubkey.isNotEmpty && c.blockedUsers.contains(pubkey)) return 'blocked';
    return personHidden(c, pubkey, nym) ? 'hidden' : '';
  }

  static List<int> blockedOverflow(
      ContentFilterCtx c, List<CfItem> items, int cap,
      [int total = blockedTotal]) {
    final keep = cap < 0 ? 0 : cap;
    final all = total < 0 ? 0 : total;
    final seen = <String, int>{};
    var kept = 0;
    final drop = <int>[];
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      final pk = it.pubkey;
      if (pk.isEmpty ||
          it.own ||
          (c.self.isNotEmpty && pk == c.self) ||
          !c.blockedUsers.contains(pk)) {
        continue;
      }
      final n = (seen[pk] ?? 0) + 1;
      seen[pk] = n;
      if (n > keep || kept >= all) {
        drop.add(i);
      } else {
        kept++;
      }
    }
    return drop.reversed.toList();
  }

  static List<int> storeOverflow(
      ContentFilterCtx c, List<CfItem> items, int limit, int cap,
      [int total = blockedTotal]) {
    final max = limit < 0 ? 0 : limit;
    final keep = cap < 0 ? 0 : cap;
    final all = total < 0 ? 0 : total;
    final seen = <String, int>{};
    var kept = 0;
    var shown = 0;
    final drop = <int>[];
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      final pk = it.pubkey;
      final blocked = pk.isNotEmpty &&
          !it.own &&
          !(c.self.isNotEmpty && pk == c.self) &&
          c.blockedUsers.contains(pk);
      if (blocked) {
        final n = (seen[pk] ?? 0) + 1;
        seen[pk] = n;
        if (n > keep || kept >= all) {
          drop.add(i);
        } else {
          kept++;
        }
        continue;
      }
      shown++;
      if (shown > max) drop.add(i);
    }
    return drop.reversed.toList();
  }

  static bool activeFilters(ContentFilterCtx c) {
    if (c.blockedUsers.isNotEmpty) return true;
    if (c.keywords.any((k) => k.trim().isNotEmpty)) return true;
    return c.packs;
  }
}
