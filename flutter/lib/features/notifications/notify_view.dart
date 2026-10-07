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

abstract final class NotifyView {
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
