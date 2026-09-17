import 'dart:convert';

import '../../models/nostr_event.dart';

/// A Nostr subscription filter (NIP-01) plus the tag filters Nymchat uses.
///
/// `toJson` emits standard fields plus `#x` tag keys (e.g. `#e`, `#p`, `#g`,
/// `#d`, `#k`, `#t`), omitting any null / empty values.
class NostrFilter {
  NostrFilter({
    this.ids,
    this.authors,
    this.kinds,
    this.since,
    this.until,
    this.limit,
    Map<String, List<String>>? tags,
  }) : tags = tags ?? const {};

  final List<String>? ids;
  final List<String>? authors;
  final List<int>? kinds;
  final int? since;
  final int? until;
  final int? limit;

  /// Tag filters keyed by a single tag letter, e.g. `e`, `p`, `g`, `d`, `k`,
  /// `t`. Keys may be supplied with or without the leading `#`; `toJson`
  /// always emits the `#`-prefixed form.
  final Map<String, List<String>> tags;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{};
    if (ids != null && ids!.isNotEmpty) out['ids'] = ids;
    if (authors != null && authors!.isNotEmpty) out['authors'] = authors;
    if (kinds != null && kinds!.isNotEmpty) out['kinds'] = kinds;
    if (since != null) out['since'] = since;
    if (until != null) out['until'] = until;
    if (limit != null) out['limit'] = limit;
    tags.forEach((key, values) {
      if (values.isEmpty) return;
      final k = key.startsWith('#') ? key : '#$key';
      out[k] = values;
    });
    return out;
  }

  factory NostrFilter.fromJson(Map<String, dynamic> j) {
    final tags = <String, List<String>>{};
    for (final entry in j.entries) {
      if (entry.key.startsWith('#')) {
        tags[entry.key.substring(1)] =
            (entry.value as List).map((e) => e.toString()).toList();
      }
    }
    List<String>? strList(dynamic v) =>
        v == null ? null : (v as List).map((e) => e.toString()).toList();
    List<int>? intList(dynamic v) =>
        v == null ? null : (v as List).map((e) => (e as num).toInt()).toList();
    return NostrFilter(
      ids: strList(j['ids']),
      authors: strList(j['authors']),
      kinds: intList(j['kinds']),
      since: (j['since'] as num?)?.toInt(),
      until: (j['until'] as num?)?.toInt(),
      limit: (j['limit'] as num?)?.toInt(),
      tags: tags,
    );
  }

  NostrFilter copyWith({
    List<String>? ids,
    List<String>? authors,
    List<int>? kinds,
    int? since,
    int? until,
    int? limit,
    Map<String, List<String>>? tags,
  }) {
    return NostrFilter(
      ids: ids ?? this.ids,
      authors: authors ?? this.authors,
      kinds: kinds ?? this.kinds,
      since: since ?? this.since,
      until: until ?? this.until,
      limit: limit ?? this.limit,
      tags: tags ?? this.tags,
    );
  }
}

/// Builds the raw outbound Nostr frames (NIP-01) sent over a relay socket.
class RelayFrame {
  RelayFrame._();

  /// `["REQ", subId, ...filters]`
  static String req(String subId, List<NostrFilter> filters) {
    return jsonEncode(
      <dynamic>['REQ', subId, ...filters.map((f) => f.toJson())],
    );
  }

  /// `["EVENT", event]`
  static String event(NostrEvent event) {
    return jsonEncode(<dynamic>['EVENT', event.toJson()]);
  }

  /// `["CLOSE", subId]`
  static String close(String subId) {
    return jsonEncode(<dynamic>['CLOSE', subId]);
  }
}

/// Sealed hierarchy of inbound relay messages parsed from raw NIP-01 frames.
sealed class RelayMessage {
  const RelayMessage();

  /// Parse a raw inbound frame string into a [RelayMessage], or null if the
  /// frame is malformed / of an unknown type.
  static RelayMessage? parse(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! List || decoded.isEmpty) return null;
    return fromList(decoded);
  }

  /// Parse an already-decoded JSON array into a [RelayMessage].
  static RelayMessage? fromList(List<dynamic> arr) {
    if (arr.isEmpty || arr[0] is! String) return null;
    final type = arr[0] as String;
    switch (type) {
      case 'EVENT':
        // ["EVENT", subId, event]
        if (arr.length < 3) return null;
        final subId = arr[1]?.toString() ?? '';
        final ev = arr[2];
        if (ev is! Map) return null;
        return EventMessage(
          subId,
          NostrEvent.fromJson(Map<String, dynamic>.from(ev)),
        );
      case 'OK':
        // ["OK", id, bool, msg]
        if (arr.length < 3) return null;
        return OkMessage(
          arr[1]?.toString() ?? '',
          arr[2] == true,
          arr.length > 3 ? (arr[3]?.toString() ?? '') : '',
        );
      case 'EOSE':
        // ["EOSE", subId]
        if (arr.length < 2) return null;
        return EoseMessage(arr[1]?.toString() ?? '');
      case 'NOTICE':
        // ["NOTICE", msg]
        return NoticeMessage(arr.length > 1 ? (arr[1]?.toString() ?? '') : '');
      case 'CLOSED':
        // ["CLOSED", subId, reason]
        if (arr.length < 2) return null;
        return ClosedMessage(
          arr[1]?.toString() ?? '',
          arr.length > 2 ? (arr[2]?.toString() ?? '') : '',
        );
      default:
        return null;
    }
  }
}

/// `["EVENT", subId, event]` — an event delivered for a subscription.
class EventMessage extends RelayMessage {
  const EventMessage(this.subId, this.event);
  final String subId;
  final NostrEvent event;
}

/// `["OK", id, accepted, message]` — publish acknowledgment.
class OkMessage extends RelayMessage {
  const OkMessage(this.id, this.accepted, this.message);
  final String id;
  final bool accepted;
  final String message;
}

/// `["EOSE", subId]` — end of stored events for a subscription.
class EoseMessage extends RelayMessage {
  const EoseMessage(this.subId);
  final String subId;
}

/// `["NOTICE", message]` — human-readable relay notice.
class NoticeMessage extends RelayMessage {
  const NoticeMessage(this.message);
  final String message;
}

/// `["CLOSED", subId, reason]` — relay closed a subscription.
class ClosedMessage extends RelayMessage {
  const ClosedMessage(this.subId, this.reason);
  final String subId;
  final String reason;
}

bool isUnsupportedKindRejection(String reason) =>
    RegExp(r'kinds?\s*not\s*supported', caseSensitive: false)
        .hasMatch(reason) ||
    RegExp(r'\bNIP[\s\-_:]*\d+\b', caseSensitive: false).hasMatch(reason) ||
    RegExp(r'\bkinds?[\s\-_:]*\d+\b', caseSensitive: false).hasMatch(reason);

final List<RegExp> _relayWideRejectionPatterns = [
  r'auth[\s\-_:]*required',
  r'\bauthentic',
  r'nip-?42',
  r'\bblocked\b',
  r'\brestricted\b',
  r'\bbanned\b',
  r'\bforbidden\b',
  r'\bunauthorized\b',
  r'payment[\s\-_:]*required',
  r'\bpaid\b',
  r'''must have ['"]?h['"]?,?\s*['"]?e['"]?\s*or\s*['"]?a['"]?\s*tag''',
  r'\binvalid query\b',
  r'\bnot\s+whitelisted\b',
  r'\bauthor[\s\-_]+banned\b',
  r'\bnot\s+allowed\b',
  r'(does\s+not\s+have\s+permission|no\s+permission|permission\s+to\s+write)',
  r'\bonly\s+members\b',
  r'out\s+of\s+time\b',
  r'\btop[\s\-]?up\b',
  r'\baccepted\s+(repository|event)\b',
  r'\bmust\s+reference\b',
  r'\bweb\s+of\s+trust\b',
  r'\bpolicy\s+violated\b',
  r'\bonly\s+(serves|accepts|supports)\b',
  r'\blow\s+trust\b',
].map((p) => RegExp(p, caseSensitive: false)).toList(growable: false);

bool isRelayWideRejection(String reason) {
  if (reason.isEmpty) return false;
  for (final p in _relayWideRejectionPatterns) {
    if (p.hasMatch(reason)) return true;
  }
  return false;
}
