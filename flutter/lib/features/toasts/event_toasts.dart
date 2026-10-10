import 'dart:math' as math;

class EventToastConfig {
  const EventToastConfig._();

  static const int maxVisible = 3;
  static const int durationMs = 5000;
  static const int bodyChars = 120;
  static const int backlogQuietMs = 4000;
  static const int backlogMaxMs = 12000;
  static const double swipeDismissPx = 60;
}

class EventToastPlacement {
  const EventToastPlacement._();

  static const int desktopMinWidth = 1025;
  static const int gutterPx = 16;
  static const int desktopGapPx = 12;
  static const int phoneGapPx = 12;
  static const int composerGapPx = 8;
  static const int desktopMaxWidthPx = 360;
  static const int phoneMaxWidthPx = 480;

  static Map<String, Object?> toJson() => {
        'desktopMinWidth': desktopMinWidth,
        'gutterPx': gutterPx,
        'desktopGapPx': desktopGapPx,
        'phoneGapPx': phoneGapPx,
        'composerGapPx': composerGapPx,
        'desktopMaxWidthPx': desktopMaxWidthPx,
        'phoneMaxWidthPx': phoneMaxWidthPx,
      };
}

class EventToastSpot {
  const EventToastSpot(
      this.top, this.left, this.width, this.maxHeight, this.align);

  final int top;
  final int left;
  final int width;
  final int maxHeight;
  final String align;

  Map<String, Object?> toJson() => {
        'top': top,
        'left': left,
        'width': width,
        'maxHeight': maxHeight,
        'align': align,
      };
}

class EventToastSettings {
  const EventToastSettings({
    this.enabled = true,
    this.foreground = 'both',
    this.types = EventToasts.defaultTypes,
    this.chosen = const [],
  });

  final bool enabled;
  final String foreground;
  final Map<String, bool> types;
  final List<String> chosen;

  bool typeOn(String t) => types[t] ?? (EventToasts.defaultTypes[t] ?? false);

  static EventToastSettings normalize(Object? raw) {
    final r = raw is Map ? raw : const {};
    final t = r['types'] is Map ? r['types'] as Map : const {};
    final fg = r['foreground'];
    final picked = r['chosen'] is List ? r['chosen'] as List : const [];
    final chosen = [
      for (final k in EventToasts.types)
        if (picked.contains(k)) k,
    ];
    bool counts(String k) =>
        t[k] is bool &&
        (!EventToasts.chosenOnly.contains(k) || chosen.contains(k));
    return EventToastSettings(
      enabled: r['enabled'] != false,
      foreground: fg is String && EventToasts.foregroundModes.contains(fg)
          ? fg
          : 'both',
      types: {
        for (final k in EventToasts.types)
          k: counts(k) ? t[k] as bool : EventToasts.defaultTypes[k]!,
      },
      chosen: chosen,
    );
  }

  static EventToastSettings patch(Object? current, Object? patch) {
    final cur = normalize(current);
    final p = patch is Map ? patch : const {};
    final types = p['types'] is Map ? p['types'] as Map : null;
    return normalize({
      'enabled': p['enabled'] is bool ? p['enabled'] : cur.enabled,
      'foreground': p['foreground'] is String ? p['foreground'] : cur.foreground,
      'types': {...cur.types, ...?types},
      'chosen': [...cur.chosen, ...?types?.keys],
    });
  }

  EventToastSettings copyWith(
          {bool? enabled, String? foreground, Map<String, bool>? types}) =>
      patch(toJson(), {
        'enabled': ?enabled,
        'foreground': ?foreground,
        'types': ?types,
      });

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'foreground': foreground,
        'types': {for (final k in EventToasts.types) k: typeOn(k)},
        'chosen': chosen,
      };
}

class EventToastEvent {
  const EventToastEvent({
    this.kind = '',
    this.key = '',
    this.sender = '',
    this.chat = '',
    this.body = '',
    this.mention = false,
    this.everyone = false,
    this.thread = false,
    this.locked = false,
    this.viewOnce = false,
    this.backlog = false,
    this.identity = '',
    this.eventId = '',
    this.seen = false,
    this.system = false,
  });

  final String kind;
  final String key;
  final String sender;
  final String chat;
  final String body;
  final bool mention;
  final bool everyone;
  final bool thread;
  final bool locked;
  final bool viewOnce;
  final bool backlog;
  final String identity;
  final String eventId;
  final bool seen;
  final bool system;

  static String _s(Object? v) => v is String ? v : '';

  factory EventToastEvent.fromJson(Map<String, dynamic> j) => EventToastEvent(
        kind: _s(j['kind']),
        key: _s(j['key']),
        sender: _s(j['sender']),
        chat: _s(j['chat']),
        body: _s(j['body']),
        mention: j['mention'] == true,
        everyone: j['everyone'] == true,
        thread: j['thread'] == true,
        locked: j['locked'] == true,
        viewOnce: j['viewOnce'] == true,
        backlog: j['backlog'] == true,
        identity: _s(j['identity']),
        eventId: _s(j['eventId']),
        seen: j['seen'] == true,
        system: j['system'] == true,
      );

  EventToastEvent slim() => EventToastEvent(
        kind: kind,
        key: key,
        sender: sender,
        chat: chat,
        body: body,
        mention: mention,
        everyone: everyone,
        thread: thread,
        locked: locked,
        viewOnce: viewOnce,
        eventId: eventId,
      );

  EventToastEvent asLive({bool? seen}) => EventToastEvent(
        kind: kind,
        key: key,
        sender: sender,
        chat: chat,
        body: body,
        mention: mention,
        everyone: everyone,
        thread: thread,
        locked: locked,
        viewOnce: viewOnce,
        identity: identity,
        eventId: eventId,
        seen: seen ?? this.seen,
      );

  EventToastEvent copyWith({
    String? body,
    bool? locked,
    bool? backlog,
    String? identity,
    String? eventId,
    bool? seen,
  }) =>
      EventToastEvent(
        kind: kind,
        key: key,
        sender: sender,
        chat: chat,
        body: body ?? this.body,
        mention: mention,
        everyone: everyone,
        thread: thread,
        locked: locked ?? this.locked,
        viewOnce: viewOnce,
        backlog: backlog ?? this.backlog,
        identity: identity ?? this.identity,
        eventId: eventId ?? this.eventId,
        seen: seen ?? this.seen,
      );

  Map<String, Object?> toJson() => {
        if (kind.isNotEmpty) 'kind': kind,
        if (key.isNotEmpty) 'key': key,
        if (sender.isNotEmpty) 'sender': sender,
        if (chat.isNotEmpty) 'chat': chat,
        if (body.isNotEmpty) 'body': body,
        if (mention) 'mention': true,
        if (everyone) 'everyone': true,
        if (thread) 'thread': true,
        if (locked) 'locked': true,
        if (viewOnce) 'viewOnce': true,
        if (eventId.isNotEmpty) 'eventId': eventId,
      };
}

class EventToastView {
  const EventToastView({
    this.foreground = false,
    this.call = false,
    this.sheet = false,
    this.identity = '',
  });

  final bool foreground;
  final bool call;
  final bool sheet;
  final String identity;

  factory EventToastView.fromJson(Map<String, dynamic> j) => EventToastView(
        foreground: j['foreground'] == true,
        call: j['call'] == true,
        sheet: j['sheet'] == true,
        identity: j['identity'] is String ? j['identity'] as String : '',
      );
}

class EventToastDecision {
  const EventToastDecision(this.toast, this.system, this.reason, this.category);

  final String toast;
  final bool system;
  final String reason;
  final String category;

  Map<String, Object?> toJson() => {
        'toast': toast,
        'system': system,
        'reason': reason,
        'category': category,
      };
}

class EventToastPrefs {
  const EventToastPrefs({this.hidePreviews = false});
  final bool hidePreviews;
}

class EventToastText {
  const EventToastText(this.title, this.meta, this.body, this.target);

  final String title;
  final String meta;
  final String body;
  final String target;

  Map<String, Object?> toJson() =>
      {'title': title, 'meta': meta, 'body': body, 'target': target};
}

class EventToast {
  const EventToast({
    required this.id,
    required this.kind,
    this.key = '',
    this.count = 0,
    this.events = const [],
    this.keys = const [],
    this.cats = const [],
    this.locked = false,
    this.last,
    required this.expiresAt,
    this.paused = false,
    this.remaining = 0,
  });

  final int id;
  final String kind;
  final String key;
  final int count;
  final List<String> events;
  final List<String> keys;
  final List<String> cats;
  final bool locked;
  final EventToastEvent? last;
  final int expiresAt;
  final bool paused;
  final int remaining;

  bool get isSummary => kind == 'summary';

  EventToast copyWith({
    int? count,
    List<String>? events,
    List<String>? keys,
    List<String>? cats,
    bool? locked,
    EventToastEvent? last,
    int? expiresAt,
    bool? paused,
    int? remaining,
  }) =>
      EventToast(
        id: id,
        kind: kind,
        key: key,
        count: count ?? this.count,
        events: events ?? this.events,
        keys: keys ?? this.keys,
        cats: cats ?? this.cats,
        locked: locked ?? this.locked,
        last: last ?? this.last,
        expiresAt: expiresAt ?? this.expiresAt,
        paused: paused ?? this.paused,
        remaining: remaining ?? this.remaining,
      );

  EventToast rearm(int now) => paused
      ? copyWith(remaining: EventToastConfig.durationMs)
      : copyWith(expiresAt: now + EventToastConfig.durationMs);

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'key': key,
        'count': count,
        'events': events,
        'keys': keys,
        'cats': cats,
        'locked': locked,
        'last': last?.toJson(),
        'expiresAt': expiresAt,
        'paused': paused,
        'remaining': remaining,
      };
}

class EventToastState {
  const EventToastState({this.toasts = const [], this.seq = 0});
  final List<EventToast> toasts;
  final int seq;
}

class EventToastResult {
  const EventToastResult(this.state,
      {this.id, this.updated = const [], this.removed = const []});
  final EventToastState state;
  final int? id;
  final List<int> updated;
  final List<int> removed;
}

typedef EventToastTr = String Function(String s, [Map<String, Object?>? p]);

class EventToasts {
  const EventToasts._();

  static const List<String> types = [
    'pm', 'mention', 'everyone', 'group', 'reaction', 'zap', 'invite', 'thread',
  ];

  static const List<String> foregroundModes = ['both', 'toast', 'system'];

  static const List<String> chosenOnly = ['reaction'];

  static const Map<String, bool> defaultTypes = {
    'pm': true,
    'mention': true,
    'everyone': true,
    'group': true,
    'reaction': true,
    'zap': true,
    'invite': true,
    'thread': true,
  };

  static const EventToastSettings defaults = EventToastSettings();

  static const List<String> messageTypes = [
    'pm', 'mention', 'everyone', 'group', 'thread',
  ];

  static const Map<String, String> labels = {
    'pm': 'PM',
    'mention': 'Mention',
    'everyone': '@everyone',
    'group': 'Group message',
    'reaction': 'Reaction',
    'zap': 'Zap',
    'invite': 'Invite',
    'thread': 'Thread reply',
  };

  static const Map<String, String> settingLabels = {
    'pm': 'PMs',
    'mention': 'Mentions',
    'everyone': '@here and @everyone',
    'group': 'Group messages',
    'reaction': 'Reactions to your messages',
    'zap': 'Zaps',
    'invite': 'Group invites and join requests',
    'thread': 'Replies in your threads',
  };

  static const Map<String, String> foregroundLabels = {
    'both': 'Banner and system notification',
    'toast': 'Banner only',
    'system': 'System notification only',
  };

  static const Map<String, String> strings = {
    'newMessage': 'New message',
    'countMessages': '{count} new messages',
    'countMessagesIn': '{count} new messages in {chat}',
    'countMessagesFrom': '{count} new messages from {name}',
    'countNotificationsIn': '{count} new notifications in {chat}',
    'countNotificationsFrom': '{count} new notifications from {name}',
    'countNotifications': '{count} new notifications',
    'viewOnce': 'View-once media',
    'master': 'Show in-app banners',
    'whileOpen': 'While Nymchat is open',
    'typesHeading': 'Show banners for',
  };

  static const Map<String, Map<String, String>> topics = {
    'reminder': {
      'prefix': 'event-reminder-',
      'title': 'Event reminder',
      'template': 'Reminder: {title}',
    },
    'callLink': {
      'prefix': 'call-link-',
      'title': 'Call link',
      'template': 'Call link: {name}',
    },
  };

  static const String legacyIdPrefix = 'gt-';

  static const Map<String, String> callStrings = {
    'call': 'Call',
    'missed': 'Missed {kind} call',
    'inGroup': ' in {group}',
    'audio': 'audio',
    'video': 'video',
  };

  static const List<String> onceLabels = [
    'View-once photo',
    'View-once video',
    'View-once voice message',
  ];

  static Map<String, Object?> configJson() => {
        'maxVisible': EventToastConfig.maxVisible,
        'durationMs': EventToastConfig.durationMs,
        'bodyChars': EventToastConfig.bodyChars,
        'backlogQuietMs': EventToastConfig.backlogQuietMs,
        'backlogMaxMs': EventToastConfig.backlogMaxMs,
        'swipeDismissPx': EventToastConfig.swipeDismissPx.toInt(),
      };

  static String fill(String s, [Map<String, Object?>? params]) {
    var out = s;
    params?.forEach((k, v) => out = out.split('{$k}').join('$v'));
    return out;
  }

  static String plainTr(String s, [Map<String, Object?>? p]) => fill(s, p);

  static String category(EventToastEvent e) {
    if (e.kind == 'reaction' || e.kind == 'zap' || e.kind == 'invite') {
      return e.kind;
    }
    if (e.everyone) return 'everyone';
    if (e.mention) return 'mention';
    if (e.thread) return 'thread';
    if (e.kind == 'pm') return 'pm';
    if (e.kind == 'group') return 'group';
    return 'mention';
  }

  static EventToastDecision decide(
      EventToastEvent e, EventToastView v, EventToastSettings s) {
    final cat = category(e);
    EventToastDecision out(String toast, bool system, String reason) =>
        EventToastDecision(toast, system, reason, cat);
    final live = !e.backlog;
    if (v.identity.isNotEmpty &&
        e.identity.isNotEmpty &&
        v.identity != e.identity) {
      return out('none', false, 'identity');
    }
    if (!v.foreground) return out('none', live, 'background');
    if (!s.enabled || !s.typeOn(cat)) return out('none', live, 'disabled');
    if (s.foreground == 'system') return out('none', live, 'system-only');
    final system = live && s.foreground != 'toast';
    if (e.seen) return out('none', system, 'in-view');
    if (e.backlog) return out('hold', false, 'backlog');
    if (v.call) return out('hold', system, 'call');
    if (v.sheet) return out('hold', system, 'sheet');
    return out('show', system, 'show');
  }

  static bool systemWhileOpen(EventToastSettings s, String category) =>
      !(s.enabled && s.typeOn(category) && s.foreground == 'toast');

  static final RegExp _ws = RegExp(r'\s+');
  static final RegExp _trailingWs = RegExp(r'\s+$');

  static String clip(String? text) {
    final s = (text ?? '').replaceAll(_ws, ' ').trim();
    if (s.length <= EventToastConfig.bodyChars) return s;
    return '${s.substring(0, EventToastConfig.bodyChars).replaceAll(_trailingWs, '')}…';
  }

  static String preview(EventToastEvent e, EventToastPrefs p) {
    if (e.locked) return '';
    if (e.viewOnce) return strings['viewOnce']!;
    if (p.hidePreviews) return '';
    return e.body;
  }

  static String _bodyOf(EventToastEvent e, EventToastPrefs p) =>
      clip(preview(e, p));

  static String _metaLine(EventToastEvent e, EventToastTr tr) {
    final label = tr(labels[category(e)]!);
    return e.chat.isNotEmpty ? '$label · ${e.chat}' : label;
  }

  static String systemBody(EventToastEvent e, EventToastPrefs p,
      [EventToastTr tr = plainTr]) {
    if (e.locked) return tr(strings['newMessage']!);
    final shown = preview(e, p);
    if (shown == strings['viewOnce']) return tr(shown);
    if (shown.isNotEmpty || !p.hidePreviews) return shown;
    return _metaLine(e, tr);
  }

  static String topicOf(String? eventId) {
    final id = eventId ?? '';
    for (final t in topics.entries) {
      if (id.startsWith(t.value['prefix']!)) return t.key;
    }
    return '';
  }

  static String systemTitle(String title, EventToastPrefs p,
      {String topic = '', bool locked = false, EventToastTr tr = plainTr}) {
    final t = topics[topic];
    if (t == null || locked || !p.hidePreviews) return title;
    return tr(t['title']!);
  }

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static String _onceLabelOf(String body, EventToastTr tr) {
    final s = body.trim();
    var best = '';
    for (final l in onceLabels) {
      for (final f in [l, tr(l)]) {
        if (f.isEmpty || f.length <= best.length || !s.startsWith(f)) continue;
        if (s.length > f.length && _wordChar.hasMatch(s[f.length])) continue;
        best = f;
      }
    }
    return best;
  }

  static bool isViewOnce(String body, [EventToastTr tr = plainTr]) =>
      _onceLabelOf(body, tr).isNotEmpty;

  static String listBody(EventToastEvent e, EventToastPrefs p,
      [EventToastTr tr = plainTr]) {
    if (e.locked) return '';
    if (!p.hidePreviews || e.system) return e.body;
    if (e.viewOnce) {
      final label = _onceLabelOf(e.body, tr);
      return label.isNotEmpty ? label : tr(strings['viewOnce']!);
    }
    return '';
  }

  static bool _fitsTemplate(String text, String template) {
    final m = RegExp(r'\{[A-Za-z]+\}').firstMatch(template);
    if (m == null) return false;
    final pre = template.substring(0, m.start);
    final post = template.substring(m.end);
    if (pre.trim().isEmpty && post.trim().isEmpty) return false;
    return text.length >= pre.length + post.length &&
        text.startsWith(pre) &&
        text.endsWith(post);
  }

  static String entryTopic(String? eventId, String title,
      [EventToastTr tr = plainTr]) {
    final byId = topicOf(eventId);
    if (byId.isNotEmpty) return byId;
    if (!(eventId ?? '').startsWith(legacyIdPrefix)) return '';
    for (final t in topics.entries) {
      final tpl = t.value['template']!;
      if (_fitsTemplate(title, tpl) || _fitsTemplate(title, tr(tpl))) {
        return t.key;
      }
    }
    return '';
  }

  static String callLabel(
      {String topic = '',
      bool missed = false,
      bool video = false,
      String chat = '',
      EventToastTr tr = plainTr}) {
    if (topic == 'callLink') return tr(topics['callLink']!['title']!);
    if (!missed) return tr(callStrings['call']!);
    final base = tr(callStrings['missed']!,
        {'kind': tr(callStrings[video ? 'video' : 'audio']!)});
    return chat.isNotEmpty
        ? base + tr(callStrings['inGroup']!, {'group': chat})
        : base;
  }

  static bool callIsVideo(String body, [EventToastTr tr = plainTr]) {
    final s = body.trim();
    if (s.isEmpty) return false;
    final forms = [
      fill(callStrings['missed']!, {'kind': callStrings['video']}),
      tr(callStrings['missed']!, {'kind': tr(callStrings['video']!)}),
    ];
    return forms.any((f) => f.isNotEmpty && s.startsWith(f));
  }

  static EventToastText present(EventToast t, EventToastPrefs prefs,
      [EventToastTr tr = plainTr]) {
    if (t.isSummary) {
      return EventToastText(
          tr(strings['countNotifications']!, {'count': t.count}), '', '', 'panel');
    }
    final e = t.last ?? const EventToastEvent();
    final viewOnce = strings['viewOnce']!;
    if (t.count <= 1) {
      if (t.locked) {
        return EventToastText(tr(strings['newMessage']!), '', '', 'conversation');
      }
      final label = tr(labels[category(e)]!);
      final chat = e.chat;
      final title = e.sender.isNotEmpty ? e.sender : (chat.isNotEmpty ? chat : label);
      final meta = chat.isNotEmpty && chat != title ? _metaLine(e, tr) : label;
      final body = _bodyOf(e, prefs);
      return EventToastText(
          title, meta, body == viewOnce ? tr(body) : body, 'conversation');
    }
    if (t.locked) {
      return EventToastText(tr(strings['countMessages']!, {'count': t.count}),
          '', '', 'conversation');
    }
    final allMessages = t.cats.every(messageTypes.contains);
    final pm = t.key.startsWith('pm:');
    final name = e.sender;
    final chat = e.chat.isNotEmpty ? e.chat : name;
    final title = pm
        ? tr(
            strings[allMessages ? 'countMessagesFrom' : 'countNotificationsFrom']!,
            {'count': t.count, 'name': name.isNotEmpty ? name : chat})
        : tr(strings[allMessages ? 'countMessagesIn' : 'countNotificationsIn']!,
            {'count': t.count, 'chat': chat});
    final raw = _bodyOf(e, prefs);
    final shown = raw == viewOnce ? tr(raw) : raw;
    final body = shown.isEmpty
        ? ''
        : (name.isNotEmpty && !pm ? '$name: $shown' : shown);
    return EventToastText(title, '', body, 'conversation');
  }

  static int _jsRound(num v) => (v + 0.5).floor();

  static EventToastSpot place({
    double? vw,
    double? vh,
    double? safeTop,
    double? safeLeft,
    double? safeRight,
    double? headerBottom,
    double? chatLeft,
    double? chatRight,
    double? composerTop,
  }) {
    double fin(double? v, double d) =>
        v != null && v.isFinite ? v : d;
    final w = math.max(0.0, fin(vw, 0));
    final h = math.max(0.0, fin(vh, 0));
    final desktop = w >= EventToastPlacement.desktopMinWidth;
    final top = _jsRound(
        math.max(math.max(0.0, fin(headerBottom, 0)), math.max(0.0, fin(safeTop, 0))) +
            (desktop ? EventToastPlacement.desktopGapPx : EventToastPlacement.phoneGapPx));
    final floor = math.min(
        h - EventToastPlacement.gutterPx, fin(composerTop, h) - EventToastPlacement.composerGapPx);
    final maxHeight = math.max(0, _jsRound(floor - top));
    final minLeft = math.max(
        EventToastPlacement.gutterPx.toDouble(), fin(safeLeft, 0));
    final maxRight =
        w - math.max(EventToastPlacement.gutterPx.toDouble(), fin(safeRight, 0));
    if (desktop) {
      final left0 = math.max(0.0, fin(chatLeft, 0));
      final right0 = math.min(w, fin(chatRight, w));
      final right =
          math.min(right0 - EventToastPlacement.gutterPx, maxRight);
      final width = math.max(
          0.0,
          math.min(EventToastPlacement.desktopMaxWidthPx.toDouble(),
              right - math.max(left0 + EventToastPlacement.gutterPx, minLeft)));
      return EventToastSpot(top, _jsRound(right - width), _jsRound(width),
          maxHeight, 'end');
    }
    final room = math.max(0.0, maxRight - minLeft);
    final width =
        math.min(EventToastPlacement.phoneMaxWidthPx.toDouble(), room);
    return EventToastSpot(top, _jsRound(minLeft + (room - width) / 2),
        _jsRound(width), maxHeight, 'center');
  }

  static EventToast _summary(int id, int now) => EventToast(
      id: id, kind: 'summary', expiresAt: now + EventToastConfig.durationMs);

  static ({List<EventToast> toasts, int seq, List<int> removed}) _fold(
      List<EventToast> input, int seq, int now) {
    var list = [...input];
    var nextSeq = seq;
    final removed = <int>[];
    while (list.length > EventToastConfig.maxVisible) {
      var si = list.indexWhere((t) => t.isSummary);
      final gi = list.indexWhere((t) => !t.isSummary);
      if (gi < 0) break;
      final g = list[gi];
      if (si < 0) {
        nextSeq += 1;
        list.insert(0, _summary(nextSeq, now));
        si = 0;
      }
      final s = list[si];
      list = [
        for (final t in list)
          if (!identical(t, g)) t,
      ];
      removed.add(g.id);
      final merged = s
          .copyWith(
            count: s.count + g.count,
            events: [...s.events, ...g.events],
            keys: s.keys.contains(g.key) ? s.keys : [...s.keys, g.key],
          )
          .rearm(now);
      list = [for (final t in list) identical(t, s) ? merged : t];
    }
    return (toasts: list, seq: nextSeq, removed: removed);
  }

  static EventToastResult add(EventToastState st, EventToastEvent ev, int now) {
    final e = ev.slim();
    final cat = category(e);
    final idx = st.toasts.indexWhere((t) => !t.isSummary && t.key == e.key);
    if (idx >= 0) {
      final g = st.toasts[idx];
      final next = g
          .copyWith(
            count: g.count + 1,
            events: [...g.events, e.eventId],
            cats: g.cats.contains(cat) ? g.cats : [...g.cats, cat],
            locked: g.locked || e.locked,
            last: e,
          )
          .rearm(now);
      final toasts = [
        for (var i = 0; i < st.toasts.length; i++)
          i == idx ? next : st.toasts[i],
      ];
      return EventToastResult(EventToastState(toasts: toasts, seq: st.seq),
          id: g.id, updated: [g.id]);
    }
    final seq = st.seq + 1;
    final toast = EventToast(
      id: seq,
      kind: 'group',
      key: e.key,
      count: 1,
      events: [e.eventId],
      keys: [e.key],
      cats: [cat],
      locked: e.locked,
      last: e,
      expiresAt: now + EventToastConfig.durationMs,
    );
    final f = _fold([...st.toasts, toast], seq, now);
    EventToast? summary;
    for (final t in f.toasts) {
      if (t.isSummary) {
        summary = t;
        break;
      }
    }
    final updated =
        f.removed.isNotEmpty && summary != null ? [summary.id] : <int>[];
    return EventToastResult(EventToastState(toasts: f.toasts, seq: f.seq),
        id: f.removed.contains(seq) ? summary?.id : seq,
        updated: updated,
        removed: f.removed);
  }

  static EventToastResult addMany(
      EventToastState st, List<EventToastEvent> events, int now) {
    final list = [for (final e in events) e.slim()];
    if (list.isEmpty) return EventToastResult(st);
    final keys = <String>[];
    for (final e in list) {
      if (!keys.contains(e.key)) keys.add(e.key);
    }
    if (keys.length == 1) {
      var r = EventToastResult(st);
      final updated = <int>[];
      final removed = <int>[];
      for (final e in list) {
        r = add(r.state, e, now);
        for (final u in r.updated) {
          if (!updated.contains(u)) updated.add(u);
        }
        for (final x in r.removed) {
          if (!removed.contains(x)) removed.add(x);
        }
      }
      return EventToastResult(r.state,
          id: r.id,
          updated: [
            for (final u in updated)
              if (!removed.contains(u)) u,
          ],
          removed: removed);
    }
    var toasts = [...st.toasts];
    var seq = st.seq;
    var si = toasts.indexWhere((t) => t.isSummary);
    var created = false;
    if (si < 0) {
      seq += 1;
      toasts.insert(0, _summary(seq, now));
      si = 0;
      created = true;
    }
    final s = toasts[si];
    final allKeys = [...s.keys];
    for (final k in keys) {
      if (!allKeys.contains(k)) allKeys.add(k);
    }
    final merged = s
        .copyWith(
          count: s.count + list.length,
          events: [...s.events, for (final e in list) e.eventId],
          keys: allKeys,
        )
        .rearm(now);
    toasts = [for (final t in toasts) identical(t, s) ? merged : t];
    final f = _fold(toasts, seq, now);
    return EventToastResult(EventToastState(toasts: f.toasts, seq: f.seq),
        id: merged.id,
        updated: created ? const [] : [merged.id],
        removed: f.removed);
  }

  static EventToastState dismiss(EventToastState st, int id) => EventToastState(
      toasts: [
        for (final t in st.toasts)
          if (t.id != id) t,
      ],
      seq: st.seq);

  static EventToastState pause(EventToastState st, int id, int now) =>
      EventToastState(toasts: [
        for (final t in st.toasts)
          t.id == id && !t.paused
              ? t.copyWith(
                  paused: true,
                  remaining: t.expiresAt - now > 0 ? t.expiresAt - now : 0)
              : t,
      ], seq: st.seq);

  static EventToastState resume(EventToastState st, int id, int now) =>
      EventToastState(toasts: [
        for (final t in st.toasts)
          t.id == id && t.paused
              ? t.copyWith(
                  paused: false, expiresAt: now + t.remaining, remaining: 0)
              : t,
      ], seq: st.seq);

  static EventToastResult expire(EventToastState st, int now) {
    final gone = [
      for (final t in st.toasts)
        if (!t.paused && t.expiresAt <= now) t.id,
    ];
    if (gone.isEmpty) return EventToastResult(st);
    return EventToastResult(
        EventToastState(toasts: [
          for (final t in st.toasts)
            if (!gone.contains(t.id)) t,
        ], seq: st.seq),
        removed: gone);
  }

  static int? nextExpiry(EventToastState st) {
    int? next;
    for (final t in st.toasts) {
      if (t.paused) continue;
      if (next == null || t.expiresAt < next) next = t.expiresAt;
    }
    return next;
  }
}
