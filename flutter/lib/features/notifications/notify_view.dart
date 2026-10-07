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
  });

  final String eventId;
  final String title;
  final String body;
  final String sender;
  final int ts;
  final bool exact;

  static NotifyAlertKey fromJson(Map<String, dynamic> raw) => NotifyAlertKey(
        eventId: raw['eventId'] is String ? raw['eventId'] as String : '',
        title: raw['title'] is String ? raw['title'] as String : '',
        body: raw['body'] is String ? raw['body'] as String : '',
        sender: raw['sender'] is String ? raw['sender'] as String : '',
        ts: raw['ts'] is num ? (raw['ts'] as num).toInt() : 0,
        exact: raw['exact'] == true,
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

  static bool sameAlert(NotifyAlertKey a, NotifyAlertKey b) {
    if (a.eventId.isNotEmpty && b.eventId.isNotEmpty) {
      return a.eventId == b.eventId;
    }
    if ((a.exact && a.eventId.isNotEmpty) || (b.exact && b.eventId.isNotEmpty)) {
      return false;
    }
    return a.title == b.title &&
        a.body == b.body &&
        a.sender == b.sender &&
        (a.ts - b.ts).abs() < 60000;
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
