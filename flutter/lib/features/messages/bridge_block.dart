import '../../models/nostr_event.dart';

const String kBridgeBlockedNick = 'radio-bridge';

const String kBridgeBlockedClient = 'meshtastic';

const String kBridgeBlockedProxy = 'meshtastic';

const String _ws =
    '\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff';

final RegExp _edgeSpace = RegExp('^[$_ws]+|[$_ws]+\$');

final RegExp _upper = RegExp('[A-Z]+');

final RegExp _nickSuffix = RegExp(r'#[0-9a-f]{4}$');

final RegExp _authorSuffix = RegExp(r'#[0-9a-fA-F]{4}$');

String _lower(String s) =>
    s.replaceAllMapped(_upper, (m) => m[0]!.toLowerCase());

String _trim(String s) => s.replaceAll(_edgeSpace, '');

bool isBridgeBlockedNick(String nick) =>
    _lower(_trim(nick)).replaceFirst(_nickSuffix, '') == kBridgeBlockedNick;

bool isBridgeBlockedClient(String client) =>
    _lower(client).contains(kBridgeBlockedClient);

bool isBridgeBlockedProxy(String protocol) =>
    _lower(_trim(protocol)) == kBridgeBlockedProxy;

bool isBridgeBlockedTag(Object? tag) {
  if (tag is! List || tag.isEmpty) return false;
  final value = tag.length > 1 ? tag[1] : null;
  switch (tag[0]) {
    case 'n':
      return value is String && isBridgeBlockedNick(value);
    case 'client':
      return value is String && isBridgeBlockedClient(value);
    case 'proxy':
      final protocol = tag.length > 2 ? tag[2] : null;
      return protocol is String && isBridgeBlockedProxy(protocol);
  }
  return false;
}

bool isBridgeBlockedTags(Object? tags) =>
    tags is List && tags.any(isBridgeBlockedTag);

bool isBridgeBlockedEvent(NostrEvent e) => isBridgeBlockedTags(e.tags);

bool isBridgeBlockedAuthor(String author) =>
    isBridgeBlockedNick(author.replaceFirst(_authorSuffix, ''));
