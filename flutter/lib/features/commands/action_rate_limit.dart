// Action-command rate limiter shared by /me, /slap and /hug: 3 per rolling 30s, then a 60s cooldown.

/// Outcome of a rate-limit check, with the user-facing message to show.
class RateLimitResult {
  const RateLimitResult.allowed()
      : allowed = true,
        message = null;
  const RateLimitResult.blocked(this.message) : allowed = false;

  final bool allowed;
  final String? message;
}

class ActionCommandRateLimiter {
  ActionCommandRateLimiter({this.now});

  /// Injectable clock in ms since epoch, for tests.
  final int Function()? now;

  static const int _windowMs = 30000;
  static const int _maxActions = 3;
  static const int _cooldownMs = 60000;

  final List<int> _timestamps = [];
  int _cooldownUntil = 0;

  int _nowMs() => now?.call() ?? DateTime.now().millisecondsSinceEpoch;

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
