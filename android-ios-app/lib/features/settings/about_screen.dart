import 'dart:convert';

import 'package:bech32/bech32.dart' as b32;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/crypto/keys.dart' show hexToBytes;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart' show kMonoFont;
import '../../models/nostr_event.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../identity/modal_chrome.dart';
import 'settings_widgets.dart';

/// Absolute base for the PWA's relative `static/*.html` legal pages. The PWA
/// serves them from its own origin; on native we point at the same files in the
/// public source repo so the links are real and tappable (gap report F14).
const String _kStaticBase = 'https://github.com/Spl0itable/NYM/blob/main/';

/// App version string shown in the About header (`#aboutVersion`). Matches the
/// current PWA constant `NYMCHAT_VERSION` (app.js:4229). The native build can
/// later override this from its own manifest; until then it tracks the PWA.
const String kAboutVersion = 'v3.72.519';

/// Warrant-canary source + pinned developer pubkey (canary-verify.js:5-6).
const String _kCanaryUrl =
    'https://raw.githubusercontent.com/Spl0itable/NYM/main/canary.json';
const String _kCanaryPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// Relay hints embedded in the canary's `nevent` link (`CANARY_RELAY_HINTS`,
/// app.js:4284).
const List<String> _kCanaryRelayHints = [
  'wss://sendit.nosflare.com',
  'wss://relay.damus.io',
  'wss://nos.lol',
];

/// `var(--success, #3fb950)` — `--success` is never defined in the PWA CSS, so
/// the fallback always applies (`.about-canary-status.ok` etc.).
const Color _kSuccess = Color(0xFF3FB950);

/// Resolved warrant-canary check (`run()`, canary-verify.js:20-44).
class _CanaryResult {
  const _CanaryResult({
    required this.state,
    this.sig = 'unsigned',
    this.statement = '',
    this.updatedAt,
    this.dueBy,
    this.overdue = false,
    this.btcBlockHeight,
    this.btcBlockHash,
    this.id = '',
    this.pubkey = '',
  });

  /// `ok` | `stale` | `gone` | `forged`.
  final String state;

  /// `valid` | `invalid` | `unsigned` | `unverifiable`.
  final String sig;
  final String statement;
  final DateTime? updatedAt;
  final DateTime? dueBy;
  final bool overdue;
  final int? btcBlockHeight;
  final String? btcBlockHash;
  final String id;
  final String pubkey;
}

/// `verifySig` (canary-verify.js:9-18): 'unsigned' when sig/pubkey/id are
/// missing, 'valid' only when the Schnorr signature checks out AND the pubkey
/// is the pinned developer key, 'invalid' otherwise, 'unverifiable' on a crash.
String _verifyCanarySig(Map<String, dynamic> doc) {
  if ((doc['sig'] ?? '') == '' ||
      (doc['pubkey'] ?? '') == '' ||
      (doc['id'] ?? '') == '') {
    return 'unsigned';
  }
  try {
    final event = NostrEvent.fromJson(doc);
    return (schnorr.verifyEvent(event) && event.pubkey == _kCanaryPubkey)
        ? 'valid'
        : 'invalid';
  } catch (_) {
    return 'unverifiable';
  }
}

/// Fetches + verifies the published canary (`run()`, canary-verify.js:20-44).
/// Throws on network/HTTP errors (→ the 'Unavailable offline' state).
Future<_CanaryResult> _fetchCanary() async {
  final res = await http.get(Uri.parse(_kCanaryUrl));
  if (res.statusCode == 404) return const _CanaryResult(state: 'gone');
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception('http ${res.statusCode}');
  }
  // `res.body` would decode charset-less application/json as Latin-1 and
  // mangle any non-ASCII content, breaking the re-hashed event id. The PWA's
  // `response.json()` always decodes UTF-8, so mirror that here.
  final doc = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
      as Map<String, dynamic>;
  final signed = doc['content'] is String && (doc['sig'] ?? '') != '';
  final sig = signed ? _verifyCanarySig(doc) : 'unsigned';
  final c = signed
      ? jsonDecode(doc['content'] as String) as Map<String, dynamic>
      : doc;
  final updatedAt =
      c['updatedAt'] is String ? DateTime.tryParse(c['updatedAt'] as String) : null;
  final dueBy = c['nextUpdateBy'] is String
      ? DateTime.tryParse(c['nextUpdateBy'] as String)
      : null;
  final overdue = dueBy != null && DateTime.now().isAfter(dueBy);
  final sigOk = sig == 'valid';
  final clear = c['allClear'] != false && !overdue && sigOk;
  final btc = c['btcBlock'];
  return _CanaryResult(
    state: sig == 'invalid' ? 'forged' : (clear ? 'ok' : 'stale'),
    sig: sig,
    statement: c['statement'] is String ? c['statement'] as String : '',
    updatedAt: updatedAt,
    dueBy: dueBy,
    overdue: overdue,
    btcBlockHeight:
        btc is Map && btc['height'] is num ? (btc['height'] as num).toInt() : null,
    btcBlockHash: btc is Map && btc['hash'] is String ? btc['hash'] as String : null,
    id: (doc['id'] ?? '') as String,
    pubkey: (doc['pubkey'] ?? '') as String,
  );
}

/// `fmtCanaryDate` (app.js:4279): ISO date (YYYY-MM-DD) or ''.
String _fmtCanaryDate(DateTime? d) =>
    d == null ? '' : d.toUtc().toIso8601String().substring(0, 10);

/// NIP-19 `nevent` TLV encoding (nostr-tools `nip19.neventEncode`, which the
/// PWA uses for the canary's njump link): TLV 0 = 32-byte event id, TLV 1 =
/// each relay hint (utf8), TLV 2 = author pubkey. Callers fall back to the
/// raw hex id on failure, matching the PWA's try/catch.
String _neventEncode(String id, String author, List<String> relays) {
  final data = <int>[];
  void tlv(int type, List<int> value) {
    data
      ..add(type)
      ..add(value.length)
      ..addAll(value);
  }

  tlv(0, hexToBytes(id));
  for (final r in relays) {
    tlv(1, utf8.encode(r));
  }
  if (author.isNotEmpty) tlv(2, hexToBytes(author));
  // 8-bit bytes → zero-padded 5-bit groups, then bech32-encode.
  final five = <int>[];
  var acc = 0;
  var bits = 0;
  for (final b in data) {
    acc = (acc << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      five.add((acc >> bits) & 31);
    }
  }
  if (bits > 0) five.add((acc << (5 - bits)) & 31);
  return b32.bech32.encode(b32.Bech32('nevent', five), 5000);
}

/// The About modal (`#aboutModal`, index.html:2118), presented as a centered
/// `.modal-content`. Layout mirrors the PWA: header (Nymchat + version), build
/// integrity panel (honest static native state — the web bundle hash check has
/// no native analogue), the LIVE warrant-canary panel (fetch + Schnorr verify,
/// `runCanaryCheck`), description, external links, divider, and the "Contact
/// the developer" form.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key, this.initialTopic, this.initialMessage});

  /// Pre-selected contact-form topic (must be one of the [FormSelect] options,
  /// e.g. `'Spam false positive'`). Null keeps the default 'General feedback'.
  final String? initialTopic;

  /// Pre-filled contact-form message body. Null leaves it empty.
  final String? initialMessage;

  static Future<void> open(
    BuildContext context, {
    String? initialTopic,
    String? initialMessage,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => AboutScreen(
        initialTopic: initialTopic,
        initialMessage: initialMessage,
      ),
    );
  }

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  final _messageController = TextEditingController();
  String _topic = 'General feedback';
  final List<TapGestureRecognizer> _recognizers = [];

  /// Contact-form status line (`#aboutContactStatus`). [_statusOk] picks the
  /// secondary (success) vs danger (error) color.
  String? _status;
  bool _statusOk = false;
  bool _sending = false;

  /// Warrant-canary check state (`runCanaryCheck`, app.js:4286): null while
  /// 'Checking…'; [_canaryFailed] = fetch error → 'Unavailable offline'.
  _CanaryResult? _canary;
  bool _canaryFailed = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill from `reportSpamFalsePositive(content)` (app.js:4399): topic
    // 'Spam false positive' + the flagged message in a code block.
    final topic = widget.initialTopic;
    if (topic != null && topic.isNotEmpty) _topic = topic;
    final msg = widget.initialMessage;
    if (msg != null && msg.isNotEmpty) _messageController.text = msg;
    // The PWA kicks off `runCanaryCheck()` every time the About modal opens.
    _runCanaryCheck();
  }

  Future<void> _runCanaryCheck() async {
    _CanaryResult? result;
    var failed = false;
    try {
      result = await _fetchCanary();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _canary = result;
      _canaryFailed = failed;
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Stack(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _header(c),
                        Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildPanel(c),
                            const SizedBox(height: 10),
                            _canaryPanel(c),
                            _description(c),
                            _links(c),
                            const SizedBox(height: 20),
                            Container(height: 1, color: c.glassBorder),
                            const SizedBox(height: 20),
                            Text(
                              'Contact the developer',
                              style: TextStyle(
                                color: c.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Send feedback, a question, or a bug report. '
                              'Your message is delivered as an encrypted '
                              'private message to the Nymchat developer.',
                              style: TextStyle(
                                  color: c.textDim, fontSize: 11, height: 1.4),
                            ),
                            const SizedBox(height: 16),
                            FormGroup(
                              label: 'Topic',
                              child: FormSelect<String>(
                                value: _topic,
                                items: const [
                                  (
                                    value: 'General feedback',
                                    label: 'General feedback'
                                  ),
                                  (value: 'Bug report', label: 'Bug report'),
                                  (
                                    value: 'Feature request',
                                    label: 'Feature request'
                                  ),
                                  (value: 'Question', label: 'Question'),
                                  (
                                    value: 'Spam false positive',
                                    label: 'Spam false positive'
                                  ),
                                ],
                                onChanged: (v) => setState(() => _topic = v),
                              ),
                            ),
                            FormGroup(
                              label: 'Message',
                              child: _messageBox(),
                            ),
                            // Contact status line (`#aboutContactStatus`, F12).
                            if (_status != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _status!,
                                  style: TextStyle(
                                    color: _statusOk ? c.secondary : c.danger,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                        _actions(c),
                      ],
                    ),
                    // `.modal-close`: 32×32 glass ✕ chip, absolute top-right
                    // (14,14) over the card — not inline in the title row.
                    ModalChrome.closeChip(
                        c, () => Navigator.of(context).maybePop()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    // `.modal-header "Nymchat <ver>"`: a full-width title (name + version) with
    // a 1px glass bottom rule. The close ✕ is the separate absolute chip
    // (build); right padding (56) keeps the title clear of the floating chip.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 24, 56, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          Text(
            'NYMCHAT',
            style: TextStyle(
              color: c.primary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              kAboutVersion,
              style: TextStyle(
                color: c.textDim,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `.about-build` panel (styles-components.css:363-415): white@.04 fill (no
  /// light override), 12px title/status row, 11px meta + links rows. The web
  /// bundle-attestation check (`build-verify.js`) has no native analogue (the
  /// app ships as a signed store binary, not a hashed web bundle), so the
  /// status is an honest static state — styled like the PWA's w600
  /// `.about-build-status` — with the same source/provenance links.
  Widget _buildPanel(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF), // rgba(255,255,255,.04), both modes
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Build integrity',
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              // Native ships as a signed store binary; verify via the repo.
              // Unclassed `.about-build-status` inherits `var(--text)`, w600.
              Text('Signed native build',
                  style: TextStyle(
                    color: c.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          // `.about-build-meta { margin-top: 4px; font-size: 11px }`.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _link(c, 'source', 'https://github.com/Spl0itable/NYM',
                    size: 11),
              ],
            ),
          ),
          // `.about-build-links { margin-top: 6px; font-size: 11px }`.
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _link(c, 'Build provenance',
                    'https://github.com/Spl0itable/NYM/actions',
                    size: 11),
                _link(c, 'How to verify',
                    'https://github.com/Spl0itable/NYM#verify-build',
                    size: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `.about-canary` warrant-canary panel, live like the PWA's
  /// `runCanaryCheck()` (app.js:4286-4356): fetch + Schnorr-verify the
  /// published canary, then render the state-colored status chip, the note,
  /// and the meta row (canary link, monospace sig chip, njump event link, BTC
  /// anchor link, monospace updated/due dates).
  Widget _canaryPanel(NymColors c) {
    final r = _canary;

    // `.about-canary-status` text + state class color.
    String statusText;
    Color statusColor;
    if (_canaryFailed) {
      statusText = 'Unavailable offline';
      statusColor = c.textDim; // .checking
    } else if (r == null) {
      statusText = 'Checking…';
      statusColor = c.textDim; // .checking
    } else if (r.state == 'gone') {
      statusText = '⚠ Canary removed';
      statusColor = c.danger; // .gone → var(--danger, #f85149)
    } else if (r.state == 'forged') {
      statusText = '✗ Signature invalid';
      statusColor = c.danger; // .forged
    } else if (r.state == 'ok') {
      statusText = '✓ All clear';
      statusColor = _kSuccess; // .ok
    } else {
      statusText = r.overdue ? '✗ Update overdue' : '✗ Not all clear';
      statusColor = c.warning; // .stale → var(--warning, #d29922)
    }

    // `#aboutCanaryNote`.
    var note = '';
    if (r != null && !_canaryFailed) {
      if (r.state == 'gone') {
        note = 'The signed canary is no longer published. '
            'Treat this as a serious warning.';
      } else if (r.state == 'forged') {
        // 'develper' [sic] — the PWA string, preserved verbatim (app.js:4340).
        note = 'The canary signature does not match the Nymchat develper key. '
            'Do not trust this canary.';
      } else if (r.state == 'ok') {
        note = r.statement.isNotEmpty
            ? r.statement
            : 'No secret government requests have been received.';
      } else {
        note = 'The canary has not been refreshed on schedule — a silenced '
            'request (NSL/FISA order) cannot be ruled out.';
      }
    }

    // Sig/date/event/anchor are filled for every resolved state except 'gone'
    // (the PWA returns before setting them; on 'checking' they start empty).
    var sigText = '';
    var sigColor = c.textDim; // `.about-canary-sig` default
    var dateText = '';
    String? eventUrl;
    String? anchorLabel;
    String? anchorUrl;
    if (r != null && !_canaryFailed && r.state != 'gone') {
      if (r.sig == 'valid') {
        sigText = 'signature ✓';
        sigColor = _kSuccess; // .about-canary-sig.ok
      } else if (r.sig == 'invalid') {
        sigText = 'signature ✗';
        sigColor = c.danger; // .about-canary-sig.bad
      } else {
        sigText = 'unsigned';
      }
      final upd = _fmtCanaryDate(r.updatedAt);
      final due = _fmtCanaryDate(r.dueBy);
      dateText = (upd.isNotEmpty ? 'updated $upd' : '') +
          (due.isNotEmpty ? ' · due $due' : '');
      if (r.id.isNotEmpty) {
        var ref = r.id;
        try {
          ref = _neventEncode(r.id, r.pubkey, _kCanaryRelayHints);
        } catch (_) {
          // Fall back to the raw hex id, like the PWA.
        }
        eventUrl = 'https://njump.me/$ref';
      }
      if (r.btcBlockHeight != null) {
        anchorLabel = 'btc block ${r.btcBlockHeight}';
        anchorUrl = 'https://mempool.space/block/${r.btcBlockHash ?? ''}';
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF), // rgba(255,255,255,.04), both modes
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Warrant canary',
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              Text(
                statusText,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          // `.about-canary-note { margin-top: 5px; font-size: 11px }`.
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                note,
                style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
              ),
            ),
          // `.about-canary-meta { margin-top: 6px; gap: 4px 12px; 11px }`.
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _link(c, 'canary',
                    'https://github.com/Spl0itable/NYM/blob/main/canary.json',
                    size: 11),
                if (sigText.isNotEmpty)
                  Text(
                    sigText,
                    style: TextStyle(
                      color: sigColor,
                      fontSize: 11,
                      fontFamily: kMonoFont,
                    ),
                  ),
                if (eventUrl != null)
                  _link(c, 'nostr event', eventUrl, size: 11),
                if (anchorUrl != null)
                  _link(c, anchorLabel!, anchorUrl, size: 11),
                if (dateText.isNotEmpty)
                  Text(
                    dateText,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 11,
                      fontFamily: kMonoFont,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _description(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 16),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
                text: 'A decentralized, pseudonymous chat built on the '),
            _linkSpan(c, 'Nostr', 'https://nostr.com'),
            const TextSpan(
                text: " protocol. Inspired by and bridged with Jack Dorsey's "),
            _linkSpan(c, 'Bitchat', 'https://bitchat.free'),
            const TextSpan(text: '.'),
          ],
        ),
        style: TextStyle(color: c.textDim, fontSize: 13, height: 1.6),
      ),
    );
  }

  Widget _links(NymColors c) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        _link(c, 'GitHub', 'https://github.com/Spl0itable/NYM'),
        _link(c, 'Terms of Service', 'static/tos.html'),
        _link(c, 'Privacy Policy', 'static/pp.html'),
        _link(c, 'DMCA', 'static/dmca.html'),
      ],
    );
  }

  /// `#aboutContactMessage`: a `.form-textarea` (maxlength=2000, no counter)
  /// sharing the `.form-input` styling — [FormInput] carries the exact fills,
  /// borders, focus ring, and forced white/black 15px text.
  Widget _messageBox() {
    return FormInput(
      controller: _messageController,
      hint: 'Write your message...',
      maxLines: 4,
      maxLength: 2000,
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NymOutlineButton(
            label: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          // `.send-btn` style; disabled while sending → opacity .35 (PWA
          // `.send-btn:disabled`), height 42.
          Opacity(
            opacity: _sending ? 0.35 : 1.0,
            child: InkWell(
              onTap: _sending ? null : _sendContact,
              borderRadius: NymRadius.rsm,
              child: Container(
                height: 42,
                alignment: Alignment.center,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: c.primaryA(0.10),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(color: c.primaryA(0.30)),
                ),
                child: Text(
                  _sending ? 'SENDING...' : 'SEND MESSAGE',
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _link(NymColors c, String text, String url, {double size = 12}) {
    return GestureDetector(
      onTap: () => _openLink(url),
      child: Text(
        text,
        style: TextStyle(
          color: c.secondary,
          fontSize: size,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  TextSpan _linkSpan(NymColors c, String text, String url) {
    final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url);
    _recognizers.add(recognizer);
    return TextSpan(
      text: text,
      style: TextStyle(color: c.secondary),
      recognizer: recognizer,
    );
  }

  /// Opens [url] externally (F14). Relative `static/*` legal pages are resolved
  /// against the source-repo base.
  Future<void> _openLink(String url) async {
    final abs = url.startsWith('http') ? url : '$_kStaticBase$url';
    final uri = Uri.tryParse(abs);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort; a missing browser/handler just no-ops.
    }
  }

  /// About → Send Message (F12; app.js:4406 `sendAboutContact`): validate a
  /// non-empty message + relay connection, then build the
  /// `[Nymchat contact — <topic>]` body and deliver it as an encrypted PM to the
  /// verified developer via the controller. Drives the button label
  /// ("Sending…") and the `#aboutContactStatus` line through sent/error states,
  /// clearing the field only on success.
  Future<void> _sendContact() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _status = 'Please enter a message.';
        _statusOk = false;
      });
      return;
    }
    // Relay connectivity (PWA `nym.connected`).
    final connected = ref.read(appStateProvider).connectedRelays > 0;
    if (!connected) {
      setState(() {
        _status = 'Not connected to relay. Try again once connected.';
        _statusOk = false;
      });
      return;
    }

    setState(() {
      _sending = true;
      _status = null;
    });

    // The body the PWA gift-wraps to the developer (`sendAboutContact`):
    //   `[Nymchat contact — <topic>]\n\n<message>`
    // sent as an encrypted PM to `NostrController.verifiedDeveloperPubkey`.
    final body = '[Nymchat contact — $_topic]\n\n$text';
    var ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).sendContactMessage(body);
    } catch (_) {
      ok = false;
    }

    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _status = 'Message sent. Thanks for reaching out!';
        _statusOk = true;
        _messageController.clear();
      } else {
        _status = 'Failed to send. Please try again.';
        _statusOk = false;
      }
    });
  }
}
