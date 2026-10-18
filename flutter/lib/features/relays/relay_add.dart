import 'relay_block.dart';

class RelayAddResult {
  const RelayAddResult({this.url, this.reason, this.host});

  final String? url;
  final String? reason;
  final String? host;

  bool get ok => url != null && reason == null;
}

class RelayAddCheck {
  const RelayAddCheck(this.status, {this.url, this.host});

  final String status;
  final String? url;
  final String? host;

  Map<String, Object> toJson() => {
        'status': status,
        'url': ?url,
        'host': ?host,
      };
}

class RelayAdd {
  RelayAdd._();

  static const int poolMaxUpstreams = 64;
  static const int storedMax = 128;
  static const String storageKey = 'nym_added_relays';
  static const String syncKey = 'addedRelays';
  static const Duration checkTimeout = Duration(seconds: 10);
  static const Duration statusWindow = Duration(seconds: 20);
  static const int _maxUrl = 512;
  static const List<String> excluded = [
    'wss://relay.nosflare.com',
    'wss://relay.nostraddress.com',
    'wss://nostr-server-production.up.railway.app',
  ];
  static const List<String> _localSuffixes = [
    '.local',
    '.internal',
    '.lan',
    '.home.arpa',
    '.localdomain',
  ];

  static const Map<String, String> messages = {
    'empty': 'Enter a relay address.',
    'format': "That isn't a valid relay address.",
    'scheme': 'A relay address starts with wss://.',
    'insecure': 'Only secure relays (wss://) can be added.',
    'port': 'Relays can only be added on the standard port (443).',
    'loopback':
        '{host} points back to this device. Only public relays can be added.',
    'link-local':
        '{host} is a link-local address. Only public relays can be added.',
    'private':
        '{host} is a private network address. Only public relays can be added.',
    'local':
        '{host} is a local network name. Only public relays can be added.',
    'ip':
        "Enter the relay's domain name, like relay.example.com. IP addresses can't be added.",
    'onion': "Tor and I2P relays can't be added.",
    'excluded': "{relay} can't be added: Nymchat never connects to it.",
    'default': '{relay} is already one of the default relays.',
    'added': 'You already added {relay}.',
    'blocked': '{relay} is on your blocked list. Unblock it to use it again.',
    'cap':
        'You can add up to {cap} relays: with the {defaults} default relays that is the most the relay pool connects to. Remove one to add another.',
    'checkingPool': 'Checking {relay} through the relay pool…',
    'checkingDirect': 'Checking {relay}…',
    'reachable': '{relay} answered in {ms} ms.',
    'refused': '{relay} refused the connection: {reason}',
    'timeout': "{relay} didn't answer within {s} seconds.",
    'unreachable': "Couldn't connect to {relay}.",
    'poolDown': "Couldn't reach the relay pool to check {relay}.",
    'done': 'Added {relay}.',
    'unblocked': '{relay} is unblocked and back in use as a default relay.',
    'restored':
        '{relay} is unblocked and back in use as one of your added relays.',
    'restoredCap':
        '{relay} is unblocked and back with your added relays, but not in use yet.',
    'keypair':
        "Relays you add aren't used while Keypair Mode makes a new keypair each session or message: the same relays on every key would link them.",
  };

  static final RegExp _rxScheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/');
  static final RegExp _rxLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  static final RegExp _rxPath =
      RegExp(r"^(?:\/[A-Za-z0-9._~!$&'()*+,;=:@%-]*)*$");
  static final RegExp _rxDigits = RegExp(r'^[0-9]+$');
  static final RegExp _rxV4Part = RegExp(r'^(0|[1-9][0-9]{0,2})$');
  static final RegExp _rxNumericLabel = RegExp(r'^(0x[0-9a-f]*|[0-9]+)$');
  static final RegExp _rxHexGroup = RegExp(r'^[0-9a-f]{1,4}$');
  static final RegExp _rxTrailing = RegExp(r'\/+$');
  static final RegExp _rxTrim = RegExp(
      r'^[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$');
  static final RegExp _rxPrintable = RegExp(r'^[\x21-\x7e]*$');
  static final RegExp _rxDotEscape = RegExp('%2e', caseSensitive: false);
  static final RegExp _rxQueryOrFragment = RegExp(r'[?#]');
  static final RegExp _rxPlaceholder = RegExp(r'\{(\w+)\}');

  static RelayAddResult _refuse(String reason, [String? host]) =>
      RelayAddResult(reason: reason, host: host);

  static List<int>? _ipv4Parts(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final out = <int>[];
    for (final p in parts) {
      if (!_rxV4Part.hasMatch(p)) return null;
      final n = int.parse(p);
      if (n > 255) return null;
      out.add(n);
    }
    return out;
  }

  static String _ipv4Class(List<int> b) {
    final a = b[0];
    final c = b[1];
    if (a == 127) return 'loopback';
    if (a == 169 && c == 254) return 'link-local';
    if (a == 0 || a == 10) return 'private';
    if (a == 172 && c >= 16 && c <= 31) return 'private';
    if (a == 192 && c == 168) return 'private';
    if (a == 100 && c >= 64 && c <= 127) return 'private';
    if (a >= 224) return 'private';
    return 'ip';
  }

  static List<int>? _ipv6Groups(String text) {
    var s = text;
    var tail = <int>[];
    final lastColon = s.lastIndexOf(':');
    if (s.contains('.')) {
      final v4 = _ipv4Parts(s.substring(lastColon + 1));
      if (v4 == null) return null;
      tail = [(v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]];
      s = s.substring(0, lastColon + 1);
      if (!s.endsWith('::')) s = s.substring(0, s.length - 1);
    }
    final halves = s.split('::');
    if (halves.length > 2) return null;
    List<int>? parse(String h) {
      if (h.isEmpty) return <int>[];
      final out = <int>[];
      for (final g in h.split(':')) {
        if (!_rxHexGroup.hasMatch(g)) return null;
        out.add(int.parse(g, radix: 16));
      }
      return out;
    }

    final head = parse(halves[0]);
    if (head == null) return null;
    if (halves.length == 1) {
      final all = [...head, ...tail];
      return all.length == 8 ? all : null;
    }
    final back = parse(halves[1]);
    if (back == null) return null;
    final have = head.length + back.length + tail.length;
    if (have > 7) return null;
    return [...head, ...List<int>.filled(8 - have, 0), ...back, ...tail];
  }

  static String _ipv6Class(List<int> g) {
    if (g.every((x) => x == 0)) return 'private';
    if (g.sublist(0, 7).every((x) => x == 0) && g[7] == 1) return 'loopback';
    final mapped = g.sublist(0, 5).every((x) => x == 0) && g[5] == 0xffff;
    final compat = g.sublist(0, 6).every((x) => x == 0);
    final nat64 =
        g[0] == 0x64 && g[1] == 0xff9b && g.sublist(2, 6).every((x) => x == 0);
    if (mapped || compat || nat64) {
      return _ipv4Class([g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255]);
    }
    if ((g[0] & 0xffc0) == 0xfe80) return 'link-local';
    if ((g[0] & 0xfe00) == 0xfc00) return 'private';
    if ((g[0] & 0xff00) == 0xff00) return 'private';
    if (g[0] == 0x2001 && g[1] == 0x0db8) return 'private';
    return 'ip';
  }

  static RelayAddResult normalize(Object? input) {
    if (input is! String) return _refuse('format');
    final s = input.replaceAll(_rxTrim, '');
    if (s.isEmpty) return _refuse('empty');
    if (s.length > _maxUrl) return _refuse('format');
    if (!_rxPrintable.hasMatch(s)) return _refuse('format');
    var rest = s;
    final m = _rxScheme.firstMatch(s);
    if (m != null) {
      final scheme = m.group(1)!.toLowerCase();
      if (scheme == 'ws') return _refuse('insecure');
      if (scheme != 'wss') return _refuse('scheme');
      rest = s.substring(m.group(0)!.length);
    } else if (s.contains('://')) {
      return _refuse('format');
    }
    if (_rxQueryOrFragment.hasMatch(rest)) return _refuse('format');
    final slash = rest.indexOf('/');
    final authority = slash >= 0 ? rest.substring(0, slash) : rest;
    final path = slash >= 0 ? rest.substring(slash) : '';
    if (authority.isEmpty || authority.contains('@')) return _refuse('format');
    var host = authority;
    var port = '';
    var v6 = false;
    if (authority.startsWith('[')) {
      final close = authority.indexOf(']');
      if (close < 0) return _refuse('format');
      host = authority.substring(1, close);
      final after = authority.substring(close + 1);
      if (after.isNotEmpty) {
        if (!after.startsWith(':')) return _refuse('format');
        port = after.substring(1);
      }
      v6 = true;
    } else {
      final colon = authority.lastIndexOf(':');
      if (colon >= 0) {
        host = authority.substring(0, colon);
        port = authority.substring(colon + 1);
      }
      if (host.contains(':')) return _refuse('format');
    }
    if (port.isNotEmpty) {
      if (!_rxDigits.hasMatch(port)) return _refuse('format');
      if (int.tryParse(port) != 443) return _refuse('port');
    }
    host = host.toLowerCase();
    if (v6) {
      final groups = _ipv6Groups(host);
      if (groups == null) return _refuse('format');
      return _refuse(_ipv6Class(groups), '[$host]');
    }
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host.isEmpty || host.length > 253) return _refuse('format');
    final labels = host.split('.');
    if (!labels.every(_rxLabel.hasMatch)) return _refuse('format');
    if (_rxNumericLabel.hasMatch(labels.last)) {
      final v4 = _ipv4Parts(host);
      if (v4 == null) return _refuse('format');
      return _refuse(_ipv4Class(v4), host);
    }
    if (host == 'localhost' || host.endsWith('.localhost')) {
      return _refuse('loopback', host);
    }
    if (labels.length == 1 || _localSuffixes.any(host.endsWith)) {
      return _refuse('local', host);
    }
    if (host.endsWith('.onion') || host.endsWith('.i2p')) {
      return _refuse('onion');
    }
    if (!_rxPath.hasMatch(path)) return _refuse('format');
    if (path.split('/').any((seg) {
      final d = seg.replaceAll(_rxDotEscape, '.');
      return d == '.' || d == '..';
    })) {
      return _refuse('format');
    }
    final url = 'wss://$host${path.replaceAll(_rxTrailing, '')}';
    if (url.length > _maxUrl) return _refuse('format');
    return RelayAddResult(url: url);
  }

  static Set<String> _canonSet(Iterable<Object?>? list) => {
        for (final u in list ?? const <Object?>[])
          if (u is String && u.isNotEmpty) RelayBlock.canon(u),
      };

  static int cap(Iterable<String> defaults) {
    final n = poolMaxUpstreams - _canonSet(defaults).length;
    return n < 0 ? 0 : n;
  }

  static RelayAddCheck check(
    String input, {
    required Iterable<String> defaults,
    Iterable<String> added = const [],
    Iterable<String> blocked = const [],
    bool keypair = false,
  }) {
    if (keypair) return const RelayAddCheck('keypair');
    final n = normalize(input);
    if (!n.ok) return RelayAddCheck(n.reason!, host: n.host);
    final url = n.url!;
    if (excluded.contains(url)) return RelayAddCheck('excluded', url: url);
    if (_canonSet(blocked).contains(url)) {
      return RelayAddCheck('blocked', url: url);
    }
    if (_canonSet(defaults).contains(url)) {
      return RelayAddCheck('default', url: url);
    }
    final shown =
        listed(added.toList(), defaults: defaults, blocked: blocked);
    if (shown.contains(url)) return RelayAddCheck('added', url: url);
    if (shown.length >= cap(defaults)) return RelayAddCheck('cap', url: url);
    return RelayAddCheck('ok', url: url);
  }

  static List<String> norm(Object? raw, {required Iterable<String> defaults}) {
    if (raw is! List) return <String>[];
    final defaultSet = _canonSet(defaults);
    final out = <String>[];
    for (final item in raw) {
      if (out.length >= storedMax) break;
      if (item is! String) continue;
      final n = normalize(item);
      if (!n.ok) continue;
      final url = n.url!;
      if (excluded.contains(url) ||
          defaultSet.contains(url) ||
          out.contains(url)) {
        continue;
      }
      out.add(url);
    }
    return out;
  }

  static List<String> listed(
    Object? raw, {
    required Iterable<String> defaults,
    Iterable<String> blocked = const [],
  }) {
    final blockedSet = _canonSet(blocked);
    return [
      for (final u in norm(raw, defaults: defaults))
        if (!blockedSet.contains(u)) u
    ];
  }

  static List<String> inUse(
    Object? raw, {
    required Iterable<String> defaults,
    Iterable<String> blocked = const [],
  }) =>
      listed(raw, defaults: defaults, blocked: blocked)
          .take(cap(defaults))
          .toList();

  static List<String> add(
    List<String> list,
    String url, {
    required Iterable<String> defaults,
    Iterable<String> blocked = const [],
  }) {
    final current = norm(list, defaults: defaults);
    final r = check(url, defaults: defaults, added: current, blocked: blocked);
    if (r.status != 'ok') return current;
    final blockedSet = _canonSet(blocked);
    final next = [...current];
    while (next.length >= storedMax) {
      final i = next.indexWhere(blockedSet.contains);
      if (i < 0) return current;
      next.removeAt(i);
    }
    return [...next, r.url!];
  }

  static List<String> restore(
    List<String> list,
    Iterable<String> urls, {
    required Iterable<String> defaults,
    Iterable<String> blocked = const [],
  }) {
    final stored = norm(list, defaults: defaults);
    final blockedSet = _canonSet(blocked);
    final back = <String>{
      for (final u in urls)
        if (u.isNotEmpty) normalize(u).url ?? RelayBlock.canon(u),
    };
    final moved = [
      for (final u in stored)
        if (back.contains(u) && !blockedSet.contains(u)) u
    ];
    if (moved.isEmpty) return stored;
    final rest = [
      for (final u in stored)
        if (!moved.contains(u)) u
    ];
    final others = rest.where((u) => !blockedSet.contains(u)).length;
    if (others + moved.length <= cap(defaults)) return stored;
    return [...rest, ...moved];
  }

  static List<String> remove(List<String> list, String url) {
    final n = normalize(url);
    final target = n.ok ? n.url! : RelayBlock.canon(url);
    return [
      for (final u in list)
        if (u != target && RelayBlock.canon(u) != target) u
    ];
  }

  static List<dynamic>? stripKeys(List<dynamic> frame, Set<String> keys) {
    if (keys.isEmpty || frame.isEmpty || frame[0] != 'REQ') return frame;
    var changed = false;
    final filters = <dynamic>[];
    for (final f in frame.skip(2)) {
      if (f is! Map) {
        filters.add(f);
        continue;
      }
      final out = Map<String, dynamic>.from(f);
      var empty = false;
      for (final key in const ['#p', 'authors']) {
        final list = out[key];
        if (list is! List) continue;
        final kept = [
          for (final pk in list)
            if (!keys.contains(pk)) pk
        ];
        if (kept.length == list.length) continue;
        changed = true;
        if (kept.isEmpty) empty = true;
        out[key] = kept;
      }
      if (!empty) filters.add(out);
    }
    if (!changed) return frame;
    if (filters.isEmpty) return null;
    return [frame[0], frame[1], ...filters];
  }

  static bool anonEvent(
      Object? ev, Iterable<String> keys, Iterable<String> lane) {
    if (ev is! Map) return false;
    final id = ev['id'];
    if (id is String && lane.contains(id)) return true;
    final hidden = keys is Set<String> ? keys : keys.toSet();
    if (hidden.isEmpty) return false;
    final pk = ev['pubkey'];
    if (pk is String && hidden.contains(pk)) return true;
    final tags = ev['tags'];
    if (tags is! List) return false;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == 'p') {
        final v = t[1];
        if (v is String && hidden.contains(v)) return true;
      }
    }
    return false;
  }

  static String status({
    required bool paused,
    bool overCap = false,
    required bool connected,
    int? addedAgoMs,
    required bool proxy,
    ({bool open, int? openedAgoMs})? shard,
    required bool connecting,
  }) {
    bool recent(int? ms) => ms != null && ms < statusWindow.inMilliseconds;
    if (paused) return 'offline';
    if (overCap) return 'unused';
    if (connected) return 'connected';
    if (recent(addedAgoMs)) return 'connecting';
    if (proxy) {
      if (shard == null || !shard.open) return 'connecting';
      return recent(shard.openedAgoMs) ? 'connecting' : 'offline';
    }
    return connecting ? 'connecting' : 'offline';
  }

  static String fill(String template, [Map<String, Object?> vars = const {}]) =>
      template.replaceAllMapped(_rxPlaceholder, (m) {
        final k = m.group(1)!;
        return vars.containsKey(k) ? '${vars[k]}' : m.group(0)!;
      });

  static String message(String code, [Map<String, Object?> vars = const {}]) {
    final t = messages[code];
    return t == null ? '' : fill(t, vars);
  }
}
