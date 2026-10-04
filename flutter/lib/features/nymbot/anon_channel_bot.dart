class AnonNymbotStrings {
  const AnonNymbotStrings._();

  static const String mesh =
      "Nymbot wasn't asked: it needs the internet, and this channel is on the mesh only.";
  static const String unavailable =
      "Nymbot wasn't asked: it isn't available on this host.";
  static const String rateLimited =
      "Nymbot wasn't asked: too many requests right now. Try again in a minute.";
  static const String failed =
      "Nymbot couldn't be reached, so it didn't answer.";

  static Map<String, String> toJson() => {
        'mesh': mesh,
        'unavailable': unavailable,
        'rateLimited': rateLimited,
        'failed': failed,
      };
}

final RegExp _command = RegExp(r'^\?\S');
final RegExp _mention = RegExp(
    r'(^|[^A-Za-z0-9_])@nymbot(?:#[0-9a-f]{4})?(?![A-Za-z0-9_])',
    caseSensitive: false);
final RegExp _botAuthor =
    RegExp(r'^nymbot(?:#[0-9a-f]{4})?$', caseSensitive: false);
final RegExp _suffix = RegExp(r'#[0-9a-f]{4}$', caseSensitive: false);

bool anonNymbotTriggers({
  required String body,
  String quoteAuthor = '',
  bool threadBot = false,
}) {
  final b = body.trim();
  if (_command.hasMatch(b) || _mention.hasMatch(b)) return true;
  if (b.isEmpty) return false;
  if (_botAuthor.hasMatch(quoteAuthor.trim())) return true;
  return threadBot;
}

String? anonNymbotBlocker({
  required bool apiHost,
  required bool mesh,
  bool validChannel = true,
}) {
  if (mesh) return 'mesh';
  if (!apiHost || !validChannel) return 'unavailable';
  return null;
}

String? anonNymbotOutcome(int status, bool hasEvent) {
  if (status == 429) return 'rateLimited';
  if (status == 403) return 'unavailable';
  if (status >= 200 && status < 300) return hasEvent ? null : 'failed';
  if (status >= 400 && status < 500) return null;
  return 'failed';
}

String anonNymbotNotice(String? reason) =>
    AnonNymbotStrings.toJson()[reason] ?? '';

String anonNymbotSenderNym(String nym, String pubkey) {
  var base = nym.replaceFirst(_suffix, '').trim();
  if (base.isEmpty) base = 'nym';
  final tail =
      pubkey.length > 4 ? pubkey.substring(pubkey.length - 4) : pubkey;
  return '$base#$tail';
}

({List<Map<String, dynamic>> messages, List<Map<String, dynamic>> users})
    anonNymbotScrubContext({
  required List<Map<String, dynamic>> messages,
  required List<Map<String, dynamic>> users,
  required Iterable<String> self,
}) {
  final mine = {
    for (final p in self)
      if (p.isNotEmpty) p.toLowerCase(),
  };
  final outMessages = <Map<String, dynamic>>[];
  for (final m in messages) {
    if (m['pending'] == true) continue;
    final copy = Map<String, dynamic>.of(m)
      ..['pubkey'] = ''
      ..remove('pending');
    outMessages.add(copy);
  }
  final outUsers = <Map<String, dynamic>>[];
  for (final u in users) {
    final pk = (u['pubkey'] ?? '').toString().toLowerCase();
    if (mine.contains(pk)) continue;
    outUsers.add(Map<String, dynamic>.of(u)..['pubkey'] = '');
  }
  return (messages: outMessages, users: outUsers);
}
