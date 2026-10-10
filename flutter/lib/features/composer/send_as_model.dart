class SendAsStrings {
  const SendAsStrings._();

  static const String header = 'Send as…';
  static const String rowLabel = 'Send as {nym}';
  static const String sending = 'Sending as {nym}…';
  static const String sentAs = 'Sent as {nym}';
  static const String failed =
      "Couldn't send as {nym}. Your message is back in the composer.";
  static const String failedShort = "Couldn't send as {nym}.";
  static const String putBack = 'Back to composer';
  static const String locked = 'Locked. Switch to this identity to unlock it.';
  static const String extension =
      'Signs with a browser extension. Switch to it to send.';
  static const String bunker =
      'Signs with a remote signer. Switch to it to send.';
  static const String offline = "You're offline.";
  static const String nymbot = "Nymbot isn't turned on for this identity.";
  static const String removed = 'That identity is no longer on this device.';
  static const String quote = 'Wait until the quoted message is sent.';

  static Map<String, String> toJson() => {
        'header': header,
        'rowLabel': rowLabel,
        'sending': sending,
        'sentAs': sentAs,
        'failed': failed,
        'failedShort': failedShort,
        'putBack': putBack,
        'locked': locked,
        'extension': extension,
        'bunker': bunker,
        'offline': offline,
        'nymbot': nymbot,
        'removed': removed,
        'quote': quote,
      };
}

const List<String> kSendAsMethods = ['nsec', 'ephemeral', 'extension', 'nip46'];

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

class SendAsAccount {
  const SendAsAccount({
    required this.id,
    this.pubkey = '',
    this.method = '',
    this.nym = '',
    this.keypairMode = '',
    this.signer = 'none',
    this.aiConsent = '',
  });

  factory SendAsAccount.fromJson(Map<String, dynamic> j) => SendAsAccount(
        id: '${j['id'] ?? ''}',
        pubkey: '${j['pubkey'] ?? ''}',
        method: '${j['method'] ?? ''}',
        nym: '${j['nym'] ?? ''}',
        keypairMode: '${j['keypairMode'] ?? ''}',
        signer: '${j['signer'] ?? 'none'}',
        aiConsent: '${j['aiConsent'] ?? ''}',
      );

  final String id;
  final String pubkey;
  final String method;
  final String nym;
  final String keypairMode;
  final String signer;
  final String aiConsent;
}

class SendAsRow {
  const SendAsRow({
    required this.account,
    required this.nym,
    required this.suffix,
    required this.state,
    required this.reason,
  });

  final String account;
  final String nym;
  final String suffix;
  final String state;
  final String reason;

  String get id => 'as:$account';

  bool get enabled => state == 'ready';

  String get label => '$nym#$suffix';

  Map<String, Object> toJson() => {
        'id': id,
        'account': account,
        'nym': nym,
        'suffix': suffix,
        'state': state,
        'enabled': enabled,
        'reason': reason,
      };
}

bool canSendAs({
  bool loggedIn = false,
  bool anonymousActive = false,
  String surface = 'channel',
  bool editing = false,
  bool mesh = false,
  bool command = false,
}) =>
    loggedIn &&
    !anonymousActive &&
    surface == 'channel' &&
    !editing &&
    !mesh &&
    !command;

String sendAsSignerState({
  required String method,
  String? secret,
  bool vaultOn = false,
}) {
  if (method == 'extension') return 'extension';
  if (method == 'nip46') return 'bunker';
  final s = secret ?? '';
  if (s.isEmpty) return 'none';
  if (vaultOn || s.startsWith('enc:v1:')) return 'locked';
  if (s.startsWith('nsec1')) return 'key';
  return 'none';
}

String sendAsSecretKey(String method) =>
    method == 'ephemeral' ? 'nym_session_nsec' : 'nym_nostr_login_nsec';

bool isThrowawayKeypairMode(String mode) =>
    mode == 'random' || mode == 'hardcore';

List<SendAsRow> sendAsRows({
  required String? activeId,
  required List<SendAsAccount> accounts,
  bool online = true,
  bool needsNymbot = false,
  bool quotePending = false,
}) {
  var activePubkey = '';
  for (final a in accounts) {
    if (a.id == activeId) activePubkey = a.pubkey;
  }
  final out = <SendAsRow>[];
  for (final a in accounts) {
    final pk = a.pubkey;
    if (a.id == activeId || !_hex64.hasMatch(pk) || pk == activePubkey) {
      continue;
    }
    if (!kSendAsMethods.contains(a.method)) continue;
    if (a.method == 'ephemeral' && isThrowawayKeypairMode(a.keypairMode)) {
      continue;
    }
    if (a.signer == 'none') continue;
    final String state;
    final String reason;
    if (a.signer == 'locked') {
      state = 'locked';
      reason = SendAsStrings.locked;
    } else if (a.signer == 'extension') {
      state = 'signer';
      reason = SendAsStrings.extension;
    } else if (a.signer == 'bunker') {
      state = 'signer';
      reason = SendAsStrings.bunker;
    } else if (quotePending) {
      state = 'quote';
      reason = SendAsStrings.quote;
    } else if (!online) {
      state = 'offline';
      reason = SendAsStrings.offline;
    } else if (needsNymbot && a.aiConsent != 'allowed') {
      state = 'nymbot';
      reason = SendAsStrings.nymbot;
    } else {
      state = 'ready';
      reason = '';
    }
    out.add(SendAsRow(
      account: a.id,
      nym: a.nym.isEmpty ? 'nym' : a.nym,
      suffix: pk.substring(pk.length - 4),
      state: state,
      reason: reason,
    ));
  }
  return out;
}

List<SendAsRow> sendAsSection({
  required bool allowed,
  required List<SendAsRow> rows,
}) =>
    allowed ? rows : const [];
