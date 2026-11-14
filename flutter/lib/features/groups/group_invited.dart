import 'dart:convert';

class GroupInvitedView {
  GroupInvitedView({
    required this.accepted,
    required this.invited,
    required this.expired,
    required this.keep,
    required this.shown,
  });

  final List<String> accepted;
  final List<String> invited;
  final List<String> expired;
  final Map<String, int> keep;
  final List<String> shown;

  int get count => accepted.length;
  int get waiting => invited.length + expired.length;

  String statusOf(String pk) {
    if (invited.contains(pk)) return GroupInvited.invitedStatus;
    if (expired.contains(pk)) return GroupInvited.expiredStatus;
    return GroupInvited.memberStatus;
  }

  int rankOf(String pk) => GroupInvited.statuses.indexOf(statusOf(pk));

  Map<String, Object> toJson() => {
        'accepted': accepted,
        'invited': invited,
        'expired': expired,
        'keep': keep,
        'count': count,
        'waiting': waiting,
        'shown': shown,
      };
}

abstract final class GroupInvited {
  static const int _day = 86400;
  static const int expiry = 30 * _day;
  static const int skew = 600;
  static const int max = 100;
  static const bool showExpired = true;

  static const Map<String, Object> limits = {
    'expiry': expiry,
    'skew': skew,
    'max': max,
    'showExpired': showExpired,
  };

  static const String field = 'invited';
  static const Map<String, String> keys = {'field': field};

  static const String sInvited = 'Invited';
  static const String sInvitedLabel = '{nym}, invited, has not joined yet';
  static const String sExpired = 'Invite expired';
  static const String sExpiredLabel = '{nym}, invite expired, never joined';
  static const String sCount = '{n} invited';

  static const Map<String, String> strings = {
    'invited': sInvited,
    'invitedLabel': sInvitedLabel,
    'expired': sExpired,
    'expiredLabel': sExpiredLabel,
    'count': sCount,
  };

  static const String memberStatus = 'member';
  static const String invitedStatus = 'invited';
  static const String expiredStatus = 'expired';
  static const List<String> statuses = [memberStatus, invitedStatus, expiredStatus];

  static final RegExp _pk = RegExp(r'^[0-9a-f]{64}$');

  static int _int(Object? x) {
    double? d;
    if (x is num) {
      d = x.toDouble();
    } else if (x is bool) {
      d = x ? 1 : 0;
    } else if (x is String) {
      final t = x.trim();
      d = t.isEmpty ? 0 : double.tryParse(t);
    }
    if (d == null || !d.isFinite) return 0;
    final n = d.floor();
    return n > 0 ? n : 0;
  }

  static Map<String, int> _cap(Map<String, int> map) {
    if (map.length <= max) return map;
    final keys = map.keys.toList()
      ..sort((a, b) {
        final d = map[b]!.compareTo(map[a]!);
        return d != 0 ? d : a.compareTo(b);
      });
    final kept = keys.take(max).toList()..sort();
    return {for (final k in kept) k: map[k]!};
  }

  static Map<String, int> normalize(Object? inv, [Object? members, Object? self]) {
    final src = inv is Map ? inv : const {};
    final keep = members is List ? {for (final m in members) '$m'} : null;
    final me = self is String ? self : '';
    final out = <String, int>{};
    final ids = [for (final k in src.keys) '$k']..sort();
    for (final pk in ids) {
      final it = _int(src[pk]);
      if (it == 0 || !_pk.hasMatch(pk) || pk == me) continue;
      if (keep != null && !keep.contains(pk)) continue;
      out[pk] = it;
    }
    return _cap(out);
  }

  static Map<String, int> mark(Object? inv, Object? pks, Object? it, [Object? self]) {
    final out = Map<String, int>.of(normalize(inv, null, self));
    final t = _int(it);
    if (t > 0 && pks is Iterable) {
      for (final pk in pks) {
        if (pk is! String || !_pk.hasMatch(pk)) continue;
        if ((out[pk] ?? 0) < t) out[pk] = t;
      }
    }
    return normalize(out, null, self);
  }

  static Map<String, int> merge(Object? a, Object? b) {
    final out = Map<String, int>.of(normalize(a));
    normalize(b).forEach((pk, t) {
      if ((out[pk] ?? 0) < t) out[pk] = t;
    });
    return normalize(out);
  }

  static bool same(Object? a, Object? b) =>
      jsonEncode(normalize(a)) == jsonEncode(normalize(b));

  static String statusOf({Object? it, Object? keyTs, Object? removedAt, Object? now}) {
    final i = _int(it);
    if (i == 0) return memberStatus;
    final kt = _int(keyTs);
    if (kt > 0 && kt > _int(removedAt) && kt + skew >= i) return memberStatus;
    return _int(now) - i > expiry ? expiredStatus : invitedStatus;
  }

  static String status(Map input) => statusOf(
      it: input['it'], keyTs: input['keyTs'], removedAt: input['removedAt'], now: input['now']);

  static GroupInvitedView view({
    Object? self,
    Object? members,
    Object? invited,
    Object? keyTs,
    Object? removedAt,
    Object? now,
  }) {
    final me = self is String ? self : '';
    final roster = <String>[];
    if (members is Iterable) {
      for (final pk in members) {
        if (pk is String && pk.isNotEmpty && !roster.contains(pk)) roster.add(pk);
      }
    }
    final inv = normalize(invited, roster, me);
    final kt = keyTs is Map ? keyTs : const {};
    final rm = removedAt is Map ? removedAt : const {};
    final accepted = <String>[], waiting = <String>[], gone = <String>[];
    final keep = <String, int>{};
    for (final pk in roster) {
      final st = pk == me
          ? memberStatus
          : statusOf(it: inv[pk], keyTs: kt[pk], removedAt: rm[pk], now: now);
      if (st == memberStatus) {
        accepted.add(pk);
        continue;
      }
      (st == invitedStatus ? waiting : gone).add(pk);
      keep[pk] = inv[pk]!;
    }
    return GroupInvitedView(
      accepted: accepted,
      invited: waiting,
      expired: gone,
      keep: keep,
      shown: [...accepted, ...waiting, if (showExpired) ...gone],
    );
  }

  static Map<String, int> trimKeyTs(Object? keyTs, Object? invited) {
    final src = <String, int>{};
    if (keyTs is Map) {
      keyTs.forEach((k, v) {
        final t = _int(v);
        if (t != 0) src['$k'] = t;
      });
    }
    final marks = normalize(invited);
    final dead = [
      for (final e in src.entries)
        if ((marks[e.key] ?? 0) != 0 && e.value + skew < marks[e.key]!) e.key,
    ];
    final order = src.keys.toList()
      ..sort((a, b) {
        final d = src[a]!.compareTo(src[b]!);
        return d != 0 ? d : a.compareTo(b);
      });
    final n = (order.length * 0.25).ceil();
    final drop =
        dead.isNotEmpty ? dead.toSet() : order.take(n < 1 ? 1 : n).toSet();
    final keys = src.keys.where((k) => !drop.contains(k)).toList()..sort();
    return {for (final k in keys) k: src[k]!};
  }
}
