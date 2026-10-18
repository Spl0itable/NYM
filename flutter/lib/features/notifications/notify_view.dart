class NotifyThread {
  const NotifyThread({required this.key, required this.root});

  final String key;
  final String root;

  static NotifyThread? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final root = raw['root'];
    if (key is! String || root is! String || key.isEmpty || root.isEmpty) {
      return null;
    }
    return NotifyThread(key: key, root: root);
  }
}

class NotifyViewState {
  const NotifyViewState({
    this.focused = false,
    this.keys = const [],
    this.thread,
  });

  final bool focused;
  final List<String> keys;
  final NotifyThread? thread;

  static NotifyViewState fromJson(Object? raw) {
    if (raw is! Map) return const NotifyViewState();
    final keys = raw['keys'];
    return NotifyViewState(
      focused: raw['focused'] == true,
      keys: [
        if (keys is List)
          for (final k in keys)
            if (k is String && k.isNotEmpty) k,
      ],
      thread: NotifyThread.fromJson(raw['thread']),
    );
  }
}

class NotifyEvent {
  const NotifyEvent({required this.key, this.root = '', this.notify = false});

  final String key;
  final String root;
  final bool notify;

  static NotifyEvent fromJson(Object? raw) {
    if (raw is! Map) return const NotifyEvent(key: '');
    return NotifyEvent(
      key: raw['key'] is String ? raw['key'] as String : '',
      root: raw['root'] is String ? raw['root'] as String : '',
      notify: raw['notify'] == true,
    );
  }
}

class NotifyOutcome {
  const NotifyOutcome({
    required this.badge,
    required this.sound,
    required this.read,
    required this.toast,
  });

  final bool badge;
  final bool sound;
  final bool read;
  final bool toast;
}

class NotifyAlertKey {
  const NotifyAlertKey({
    this.eventId = '',
    this.title = '',
    this.body = '',
    this.sender = '',
    this.ts = 0,
    this.exact = false,
    this.stable = false,
    this.scope = '',
    this.typed = false,
  });

  final String eventId;
  final String title;
  final String body;
  final String sender;
  final int ts;
  final bool exact;
  final bool stable;
  final String scope;
  final bool typed;

  static NotifyAlertKey fromJson(Map<String, dynamic> raw) => NotifyAlertKey(
        eventId: raw['eventId'] is String ? raw['eventId'] as String : '',
        title: raw['title'] is String ? raw['title'] as String : '',
        body: raw['body'] is String ? raw['body'] as String : '',
        sender: raw['sender'] is String ? raw['sender'] as String : '',
        ts: raw['ts'] is num ? (raw['ts'] as num).toInt() : 0,
        exact: raw['exact'] == true,
        stable: raw['stable'] == true,
        scope: raw['scope'] is String ? raw['scope'] as String : '',
      );
}

class NotifyPmKey {
  const NotifyPmKey({
    this.pubkey = '',
    this.content = '',
    this.createdAt = 0,
    this.nymId = '',
    this.replyTo = '',
  });

  final String pubkey;
  final String content;
  final int createdAt;
  final String nymId;
  final String replyTo;

  static NotifyPmKey fromJson(Map<String, dynamic> raw) => NotifyPmKey(
        pubkey: raw['pubkey'] is String ? raw['pubkey'] as String : '',
        content: raw['content'] is String ? raw['content'] as String : '',
        createdAt:
            raw['createdAt'] is num ? (raw['createdAt'] as num).toInt() : 0,
        nymId: raw['nymId'] is String ? raw['nymId'] as String : '',
        replyTo: raw['replyTo'] is String ? raw['replyTo'] as String : '',
      );
}

abstract final class NotifyView {
  static int readTs(int ts, int receivedAt, bool live) =>
      live && receivedAt > ts ? receivedAt : ts;

  static final RegExp _pubkeyRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
  static final RegExp _ws = RegExp(r'\s+');
  static final RegExp _quoteLine = RegExp(r'^\s*>');
  static const int _nearMs = 1000;

  static ({String eventId, bool stable}) alertId(
      {String? x, String? id, bool stable = false}) {
    final shared = x ?? '';
    if (shared.isNotEmpty) return (eventId: shared, stable: true);
    final own = id ?? '';
    return (eventId: own, stable: own.isNotEmpty && stable);
  }

  static ({String eventId, bool stable}) reactionId(
      String? wrapId, String? messageId) {
    final w = wrapId ?? '';
    final m = messageId ?? '';
    if (w.isEmpty) return (eventId: '', stable: false);
    return m.isNotEmpty
        ? (eventId: '$w:$m', stable: true)
        : (eventId: w, stable: false);
  }

  static int _sec(num v) {
    final n = v.floor();
    return n > 0 ? n : 0;
  }

  static String knockId(String linkId, String sender, num createdAt) =>
      'call-link-$linkId-$sender-${_sec(createdAt)}';

  static String joinRequestId(String groupId, String joiner, num ts) =>
      'join-req-$groupId-$joiner-${_sec(ts)}';

  static String joinDeclinedId(String groupId, num createdAt) =>
      'join-declined-$groupId-${_sec(createdAt)}';

  static String _collapse(String s) => s.replaceAll(_ws, ' ').trim();

  static String bodyKey(String body) {
    final kept = _collapse(
        body.split('\n').where((l) => !_quoteLine.hasMatch(l)).join(' '));
    final key = kept.isNotEmpty ? kept : _collapse(body);
    return key.length > 40 ? key.substring(0, 40) : key;
  }

  static String alertScope(String type, String route, String sender) {
    switch (type) {
      case 'pm':
        final peer = route.isNotEmpty ? route : sender;
        return peer.isNotEmpty ? 'pm:${peer.toLowerCase()}' : '';
      case 'group':
        return route.isNotEmpty ? 'group:$route' : '';
      case 'channel':
      case 'geohash':
        return route.isNotEmpty ? 'channel:${route.toLowerCase()}' : '';
      case 'mention':
        return route.isNotEmpty && !_pubkeyRe.hasMatch(route)
            ? 'channel:${route.toLowerCase()}'
            : '';
    }
    return '';
  }

  static bool sameAlert(NotifyAlertKey a, NotifyAlertKey b) {
    final ai = a.eventId;
    final bi = b.eventId;
    if (ai.isNotEmpty && bi.isNotEmpty && ai == bi) return true;
    if ((a.exact && ai.isNotEmpty) || (b.exact && bi.isNotEmpty)) {
      return false;
    }
    if (a.scope.isNotEmpty && b.scope.isNotEmpty && a.scope != b.scope) {
      return false;
    }
    final dt = (a.ts - b.ts).abs();
    bool near() {
      if (a.sender.isEmpty || a.sender != b.sender || dt >= _nearMs) {
        return false;
      }
      final k = bodyKey(a.body);
      return k.isNotEmpty && k == bodyKey(b.body);
    }

    if (ai.isNotEmpty && bi.isNotEmpty) return !(a.stable && b.stable) && near();
    return near() ||
        (a.title == b.title &&
            a.body == b.body &&
            a.sender == b.sender &&
            dt < 60000);
  }

  static const int pieceMaxBytes = 255;
  static const int pieceOpenBytes = 252;
  static const int pieceHoldMs = 3000;

  static int _runeBytes(int cp) =>
      cp < 0x80 ? 1 : (cp < 0x800 ? 2 : (cp < 0x10000 ? 3 : 4));

  static int utf8Length(String text) {
    var n = 0;
    for (final r in text.runes) {
      n += _runeBytes(r);
    }
    return n;
  }

  static List<String> pmChunks(String content) {
    final out = <String>[];
    final cur = StringBuffer();
    var bytes = 0;
    for (final r in content.runes) {
      final b = _runeBytes(r);
      if (cur.isNotEmpty && bytes + b > pieceMaxBytes) {
        out.add(cur.toString());
        cur.clear();
        bytes = 0;
      }
      cur.writeCharCode(r);
      bytes += b;
    }
    if (cur.isNotEmpty || out.isEmpty) out.add(cur.toString());
    return out;
  }

  static bool pmOpenPiece(String content) {
    final n = utf8Length(content);
    return n >= pieceOpenBytes && n <= pieceMaxBytes;
  }

  static bool pmPiece(NotifyPmKey a, NotifyPmKey b) {
    if (a.pubkey.isEmpty || a.pubkey != b.pubkey) return false;
    if (a.nymId.isNotEmpty || b.nymId.isEmpty) return false;
    if (a.content.isEmpty || a.content.length >= b.content.length) {
      return false;
    }
    if ((a.createdAt - b.createdAt).abs() >= 5) return false;
    if (a.replyTo.isNotEmpty && a.replyTo != b.replyTo) return false;
    return pmChunks(b.content).contains(a.content);
  }

  static bool samePm(NotifyPmKey a, NotifyPmKey b) {
    if (a.pubkey != b.pubkey) return false;
    if (a.nymId.isNotEmpty && b.nymId.isNotEmpty) return a.nymId == b.nymId;
    if (a.content != b.content) return false;
    if ((a.createdAt - b.createdAt).abs() >= 5) return false;
    return a.replyTo.isEmpty || a.replyTo == b.replyTo;
  }

  static bool threadOpen(NotifyViewState view, NotifyEvent ev) {
    final t = view.thread;
    if (ev.key.isEmpty || ev.root.isEmpty || t == null) return false;
    return t.key == ev.key && t.root == ev.root;
  }

  static bool onScreen(NotifyViewState view, NotifyEvent ev) {
    if (ev.key.isEmpty) return false;
    if (ev.root.isNotEmpty) return threadOpen(view, ev);
    return view.keys.contains(ev.key);
  }

  static bool sees(NotifyViewState view, NotifyEvent ev) =>
      view.focused && onScreen(view, ev);

  static NotifyOutcome outcome(NotifyViewState view, NotifyEvent ev) {
    final seen = sees(view, ev);
    final alert = ev.notify && !seen;
    return NotifyOutcome(
      badge: alert,
      sound: alert,
      read: seen,
      toast: alert && view.focused,
    );
  }

  static bool addressed({
    required String kind,
    bool thread = false,
    bool mention = false,
    bool ownRoot = false,
    bool ownReply = false,
    bool threadMentionsOnly = false,
    bool groupMentionsOnly = false,
  }) {
    final k = (kind == 'pm' || kind == 'group') ? kind : 'channel';
    if (thread) {
      if (threadMentionsOnly) return mention;
      if (mention || ownRoot || ownReply) return true;
      return k == 'pm';
    }
    if (k == 'channel') return mention;
    if (k == 'group') return mention || !groupMentionsOnly;
    return true;
  }

  static String storageKeyFor(String type, String route) {
    if (route.isEmpty) return '';
    if (route.startsWith('#') ||
        route.startsWith('pm-') ||
        route.startsWith('group-')) {
      return route;
    }
    return switch (type) {
      'pm' => 'pm-$route',
      'group' => 'group-$route',
      'channel' || 'mention' => '#$route',
      _ => '',
    };
  }
}
