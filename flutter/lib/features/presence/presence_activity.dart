class PresenceActivity {
  PresenceActivity._();

  static const int idleMs = 120000;
  static const int throttleMs = 60000;
  static const List<String> activityKinds = [
    'pointer',
    'key',
    'wheel',
    'focus',
    'visible',
    'open-chat',
    'react',
    'type',
    'send',
  ];
  static const List<String> evaluateOnlyKinds = ['connect'];

  static bool countsAsActivity(String kind) => activityKinds.contains(kind);

  static bool evaluates(String kind) =>
      countsAsActivity(kind) || evaluateOnlyKinds.contains(kind);

  static String decide({
    required int now,
    required int lastInputMs,
    required int lastBroadcastMs,
    required bool visible,
    required bool focused,
    required String mode,
    required bool away,
    required bool hasIdentity,
  }) {
    if (!hasIdentity || mode == 'disabled') return 'off';
    if (away) return 'away';
    if (!visible || !focused) return 'background';
    final sinceInput = now - lastInputMs;
    if (lastInputMs <= 0 || sinceInput < 0 || sinceInput >= idleMs) {
      return 'idle';
    }
    final sinceBroadcast = now - lastBroadcastMs;
    if (lastBroadcastMs > 0 &&
        sinceBroadcast >= 0 &&
        sinceBroadcast < throttleMs) {
      return 'throttled';
    }
    return mode == 'friends' ? 'friends' : 'publish';
  }
}

class PresenceActivityGate {
  PresenceActivityGate({
    required this.clock,
    required this.foreground,
    required this.mode,
    required this.away,
    required this.hasIdentity,
    required this.connected,
    required this.publish,
    required this.publishFriends,
  });

  final int Function() clock;
  final bool Function() foreground;
  final String Function() mode;
  final bool Function() away;
  final bool Function() hasIdentity;
  final bool Function() connected;
  final void Function() publish;
  final void Function() publishFriends;

  int lastInputMs = 0;
  int lastBroadcastMs = 0;

  String note(String kind) {
    if (!PresenceActivity.evaluates(kind)) return 'ignored';
    final now = clock();
    if (PresenceActivity.countsAsActivity(kind)) lastInputMs = now;
    if (!connected()) return 'offline';
    final fg = foreground();
    final action = PresenceActivity.decide(
      now: now,
      lastInputMs: lastInputMs,
      lastBroadcastMs: lastBroadcastMs,
      visible: fg,
      focused: fg,
      mode: mode(),
      away: away(),
      hasIdentity: hasIdentity(),
    );
    if (action == 'publish') {
      lastBroadcastMs = now;
      publish();
    } else if (action == 'friends') {
      lastBroadcastMs = now;
      publishFriends();
    }
    return action;
  }

  void reset() {
    lastInputMs = 0;
    lastBroadcastMs = 0;
  }
}
