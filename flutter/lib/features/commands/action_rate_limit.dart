// Action-command rate limiter — a 1:1 port of
// `_checkActionCommandRateLimit` (commands.js:1090). Shared by `/me`, `/slap`,
// and `/hug`: at most 3 actions per rolling 30s window; on breach a 60s
// cooldown is imposed during which all three are blocked.

/// Outcome of a rate-limit check, carrying the user-facing message the PWA
/// shows via `displaySystemMessage` so the caller can surface it identically.
class RateLimitResult {
  const RateLimitResult.allowed()
      : allowed = true,
        message = null;
  const RateLimitResult.blocked(this.message) : allowed = false;

  final bool allowed;
  final String? message;
}

/// Stateful tracker mirroring `this.actionCommandTracker`. One instance is held
/// by the controller and shared across the three action commands.
class ActionCommandRateLimiter {
  ActionCommandRateLimiter({this.now});

  /// Injectable clock (ms-since-epoch) for tests; defaults to wall clock.
  final int Function()? now;

  static const int _windowMs = 30000; // 30s window
  static const int _maxActions = 3; // up to 3 per window
  static const int _cooldownMs = 60000; // 1 minute cooldown on breach

  final List<int> _timestamps = [];
  int _cooldownUntil = 0;

  int _nowMs() => now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// Returns [RateLimitResult.allowed] and records the action, or a blocked
  /// result carrying the exact PWA message. Pure-port semantics:
  /// - during cooldown: "Slow down! You can use /me, /slap, or /hug again in Ns"
  /// - on the 4th within 30s: "Too many action commands. Try again in 60s"
  RateLimitResult check() {
    final now = _nowMs();
    if (now < _cooldownUntil) {
      final remaining = ((_cooldownUntil - now) / 1000).ceil();
      return RateLimitResult.blocked(
        'Slow down! You can use /me, /slap, or /hug again in ${remaining}s',
      );
    }
    _timestamps.removeWhere((ts) => now - ts >= _windowMs);
    if (_timestamps.length >= _maxActions) {
      _cooldownUntil = now + _cooldownMs;
      return const RateLimitResult.blocked(
        'Too many action commands. Try again in 60s',
      );
    }
    _timestamps.add(now);
    return const RateLimitResult.allowed();
  }
}
