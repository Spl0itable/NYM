import 'dart:convert';

import 'package:bech32/bech32.dart' as b32;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/site_links.dart';
import '../../core/crypto/keys.dart' show hexToBytes;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart' show kMonoFont;
import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../identity/modal_chrome.dart';
import 'build_integrity.dart';
import 'settings_widgets.dart';
import '../../widgets/common/nym_sheet.dart';

/// Bundled fallback version, shown until the live version resolves; keep in sync with `NYMCHAT_VERSION` at release.
const String kAboutVersion = 'v3.75.545';

const String kAboutCopyright = '© 21 Million LLC';

/// Live version JSON (`{"version":"vX.Y.Z"}`) published by the main build; cached for the session.
const String _kVersionUrl = 'https://web.nymchat.app/version.json';

/// Session cache; null until the first success.
String? _liveVersionCache;

/// Live version, or null on failure so the caller keeps [kAboutVersion].
Future<String?> _fetchLiveVersion() async {
  if (_liveVersionCache != null) return _liveVersionCache;
  try {
    final res = await http
        .get(Uri.parse(_kVersionUrl))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final doc = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (doc is! Map) return null;
    final v = doc['version'];
    // Validate the shape so a stray HTML or error body can't land in the header.
    if (v is String && RegExp(r'^v?[0-9][0-9A-Za-z.\-]{1,31}$').hasMatch(v)) {
      _liveVersionCache = v;
      return v;
    }
  } catch (_) {
    // Offline, timeout or bad body: keep the bundled constant.
  }
  return null;
}

/// Pinned Zapstore publisher key; unpinned, anyone could publish a matching kind-3063 event.
const String kZapstorePublisherPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// Warrant canary source and pinned developer pubkey.
const String _kCanaryUrl =
    'https://raw.githubusercontent.com/Spl0itable/NYM/main/canary.json';
const String _kCanaryPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// Relay hints embedded in the canary's `nevent` link.
const List<String> _kCanaryRelayHints = [
  'wss://sendit.nosflare.com',
  'wss://relay.damus.io',
  'wss://nos.lol',
];

/// `--success` is never defined in the PWA CSS, so this fallback always applies.
const Color _kSuccess = Color(0xFF3FB950);

/// Resolved warrant-canary check.
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

/// 'valid' only when the Schnorr signature checks and the pubkey is pinned; 'unsigned' when fields are missing.
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

Future<http.Response> fetchCanaryDocument({ApiClient? api}) =>
    (api ?? _canaryApi).proxiedJsonFetch(_kCanaryUrl);

final _canaryApi = ApiClient();

/// Fetches and verifies the canary; throws on network or HTTP errors.
Future<_CanaryResult> _fetchCanary() async {
  final res = await fetchCanaryDocument();
  if (res.statusCode == 404) return const _CanaryResult(state: 'gone');
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception('http ${res.statusCode}');
  }
  // Decode as UTF-8; `res.body` would read charset-less JSON as Latin-1 and break the re-hashed event id.
  final doc = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))
      as Map<String, dynamic>;
  final signed = doc['content'] is String && (doc['sig'] ?? '') != '';
  final sig = signed ? _verifyCanarySig(doc) : 'unsigned';
  final c = signed
      ? jsonDecode(doc['content'] as String) as Map<String, dynamic>
      : doc;
  final updatedAt = c['updatedAt'] is String
      ? DateTime.tryParse(c['updatedAt'] as String)
      : null;
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
    btcBlockHeight: btc is Map && btc['height'] is num
        ? (btc['height'] as num).toInt()
        : null,
    btcBlockHash:
        btc is Map && btc['hash'] is String ? btc['hash'] as String : null,
    id: (doc['id'] ?? '') as String,
    pubkey: (doc['pubkey'] ?? '') as String,
  );
}

/// ISO date (YYYY-MM-DD) or ''.
String _fmtCanaryDate(DateTime? d) =>
    d == null ? '' : d.toUtc().toIso8601String().substring(0, 10);

/// NIP-19 `nevent` TLV: 0 = event id, 1 = each relay hint, 2 = author; callers fall back to the hex id.
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
  // 8-bit bytes to zero-padded 5-bit groups, then bech32.
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

/// Build-integrity panel copy; only Android can measure itself (see build_integrity.dart).
const String kBuildIntegrityLabel = 'Build integrity';

/// Android: the APK hash is in the signed release manifest.
const String kBuildStatusVerified = 'Verified official build';
const String kBuildNoteVerified =
    'The APK installed on this device hashes to the value in the publisher\'s '
    'signed Zapstore release event. Anyone can repeat the check: download the '
    'published APK, hash it, and verify that event against the publisher key.';

/// Android: the APK isn't what was published.
const String kBuildStatusMismatch = 'Unrecognized build';
const String kBuildNoteMismatch =
    'The APK installed on this device does not match any hash the publisher\'s '
    'signed release events carry for this version. It was modified after '
    'publication, or built by someone else.';

/// Android via Google Play: nothing to compare, and that isn't a failure.
const String kBuildStatusStore = 'Installed from Google Play';
const String kBuildNoteStore =
    'Google Play re-signs the upload with its own key and builds a separate '
    'APK for each device, so what is installed here is not the file the '
    'developer published and its hash matches nothing. To check a build '
    'yourself, install the APK published directly and open this panel again.';

/// Android: events unfetchable or unverified, deliberately one state.
const String kBuildStatusUnreachable = 'Provenance unreachable';
const String kBuildNoteUnreachable =
    'The signed release events could not be fetched, or none of them checked '
    'out against the publisher key. Nothing is wrong with the app as far as '
    'this panel can tell — it simply has nothing trustworthy to compare '
    'against right now.';

/// Android: published, but not this version.
const String kBuildStatusNotPublished = 'No published hash yet';
const String kBuildNoteNotPublished =
    'The publisher has released other versions but none matching this one, so '
    'there is nothing to compare the installed APK against. This is what a '
    'build newer than the published listing looks like.';

/// Everywhere else, principally iOS.
const String kBuildStatusUnsupported = 'Not verifiable on this platform';
const String kBuildNoteUnsupported =
    'This app cannot check itself here: what runs is compiled code, not the '
    'source, and iOS re-signs and encrypts each download so a hash computed '
    'on the device matches nothing published. Verify the release you '
    'installed against the published build instead, or use the web app, '
    'which re-hashes every file it is running against this repository\'s '
    'signed attestations.';

const String kBuildIntegrityChecking = 'Checking…';

/// Every literal the build-integrity panel can show.
const List<String> kBuildIntegrityStrings = [
  kBuildIntegrityLabel,
  kBuildIntegrityChecking,
  kBuildStatusVerified,
  kBuildNoteVerified,
  kBuildStatusMismatch,
  kBuildNoteMismatch,
  kBuildStatusStore,
  kBuildNoteStore,
  kBuildStatusUnreachable,
  kBuildNoteUnreachable,
  kBuildStatusNotPublished,
  kBuildNoteNotPublished,
  kBuildStatusUnsupported,
  kBuildNoteUnsupported,
];

/// Status line and explanation for a verdict.
(String, String) buildIntegrityCopy(BuildIntegrityState state) {
  switch (state) {
    case BuildIntegrityState.verified:
      return (kBuildStatusVerified, kBuildNoteVerified);
    case BuildIntegrityState.mismatch:
      return (kBuildStatusMismatch, kBuildNoteMismatch);
    case BuildIntegrityState.storeRepackaged:
      return (kBuildStatusStore, kBuildNoteStore);
    case BuildIntegrityState.provenanceUnreachable:
      return (kBuildStatusUnreachable, kBuildNoteUnreachable);
    case BuildIntegrityState.notPublished:
      return (kBuildStatusNotPublished, kBuildNoteNotPublished);
    case BuildIntegrityState.unsupported:
      return (kBuildStatusUnsupported, kBuildNoteUnsupported);
  }
}

/// About modal: version header, build integrity, live warrant canary, links and the contact form.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key, this.initialTopic, this.initialMessage});

  /// Pre-selected contact topic, one of the [FormSelect] options; null keeps 'General feedback'.
  final String? initialTopic;

  /// Pre-filled contact message; null leaves it empty.
  final String? initialMessage;

  static Future<void> open(
    BuildContext context, {
    String? initialTopic,
    String? initialMessage,
  }) {
    return showNymSheet<void>(
      context,
      (_) => AboutScreen(
        initialTopic: initialTopic,
        initialMessage: initialMessage,
      ),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
  }

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  final _messageController = TextEditingController();
  String _topic = 'General feedback';
  final List<TapGestureRecognizer> _recognizers = [];

  /// Contact status line; [_statusOk] picks success vs error color.
  String? _status;
  bool _statusOk = false;
  bool _sending = false;

  /// Null while checking; [_canaryFailed] means the fetch errored.
  _CanaryResult? _canary;
  bool _canaryFailed = false;

  /// Live version once fetched, else [kAboutVersion].
  String _version = _liveVersionCache ?? kAboutVersion;

  /// Null while the build check runs, then the verdict.
  BuildIntegrityResult? _build;

  @override
  void initState() {
    super.initState();
    // Pre-fill for a spam false-positive report.
    final topic = widget.initialTopic;
    if (topic != null && topic.isNotEmpty) _topic = topic;
    final msg = widget.initialMessage;
    if (msg != null && msg.isNotEmpty) _messageController.text = msg;
    _runCanaryCheck();
    // Keeps the bundled fallback on error.
    _loadLiveVersion();
    // No-ops off Android.
    _runBuildCheck();
  }

  Future<void> _runBuildCheck() async {
    if (!BuildIntegrityService.isSupported) return;
    final result = await BuildIntegrityService(
      publisherPubkey: kZapstorePublisherPubkey,
    ).run();
    if (!mounted) return;
    setState(() => _build = result);
  }

  Future<void> _loadLiveVersion() async {
    final v = await _fetchLiveVersion();
    if (!mounted || v == null || v == _version) return;
    setState(() => _version = v);
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
    // Shift up by the keyboard inset and cap the height so the contact field isn't hidden.
    final viewInsets = MediaQuery.of(context).viewInsets;
    final visibleHeight =
        MediaQuery.of(context).size.height - viewInsets.bottom;
    final body = Stack(
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
                    _license(c),
                    const SizedBox(height: 20),
                    Container(height: 1, color: c.glassBorder),
                    const SizedBox(height: 20),
                    Text(
                      tr('Contact the developer'),
                      style: TextStyle(
                        color: c.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('Send feedback, a question, or a bug report. '
                          'Your message is delivered as an encrypted '
                          'private message to the Nymchat developer.'),
                      style: TextStyle(
                          color: c.textDim,
                          fontSize: 11,
                          height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    FormGroup(
                      label: tr('Topic'),
                      child: FormSelect<String>(
                        value: _topic,
                        items: [
                          (
                            value: 'General feedback',
                            label: tr('General feedback')
                          ),
                          (
                            value: 'Bug report',
                            label: tr('Bug report')
                          ),
                          (
                            value: 'Feature request',
                            label: tr('Feature request')
                          ),
                          (
                            value: 'Question',
                            label: tr('Question')
                          ),
                          (
                            value: 'Spam false positive',
                            label: tr('Spam false positive')
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _topic = v),
                      ),
                    ),
                    FormGroup(
                      label: tr('Message'),
                      child: _messageBox(),
                    ),
                    if (_status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _status!,
                          style: TextStyle(
                            color: _statusOk
                                ? c.secondary
                                : c.danger,
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
        ModalChrome.closeChip(
            c, () => Navigator.of(context).pop()),
      ],
    );
    return NymDiscardGuard(
      isDirty: () => _messageController.text.trim().isNotEmpty,
      child: nymSheetOr(
        context,
        body,
        (body) => AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: Center(
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
                        maxHeight:
                            (visibleHeight - 40).clamp(200.0, visibleHeight) * 0.98,
                      ),
                      child: body,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    // Right padding keeps the title clear of the floating close chip.
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
              _version,
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

  /// Build-integrity panel with source and provenance links for checking off-device.
  Widget _buildPanel(NymColors c) {
    final result = _build;
    // While a supported check runs, say so instead of a verdict about to change.
    final pending = result == null && BuildIntegrityService.isSupported;
    final state = result?.state ?? BuildIntegrityState.unsupported;
    final copy = buildIntegrityCopy(state);
    final status = pending ? kBuildIntegrityChecking : copy.$1;
    final note = pending ? '' : copy.$2;
    final measured = result?.info;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr(kBuildIntegrityLabel),
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              // Only a real check earns a color; states that compared nothing stay neutral.
              Flexible(
                child: Text(
                  tr(status),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: switch (state) {
                      BuildIntegrityState.verified => _kSuccess,
                      BuildIntegrityState.mismatch => c.danger,
                      _ => c.text,
                    },
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(tr(note),
                  style:
                      TextStyle(color: c.textDim, fontSize: 11, height: 1.45)),
            ),
          // Values needed to repeat the check off-device.
          if (measured != null) ...[
            if (measured.apkSha256 != null)
              _hashRow(c, tr('Installed APK'), measured.apkSha256!),
            if (measured.signerSha256 != null)
              _hashRow(c, tr('Signing certificate'), measured.signerSha256!),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _link(c, tr('source'), kGithubUrl, size: 11),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _link(c, tr('Build provenance'),
                    'https://github.com/Spl0itable/NYM/actions',
                    size: 11),
                _link(c, tr('How to verify'),
                    'https://github.com/Spl0itable/NYM#verify-build',
                    size: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Monospace, selectable hash for comparing against a published value.
  Widget _hashRow(NymColors c, String label, String hex) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: c.textDim, fontSize: 11)),
          SelectableText(
            hex,
            style: TextStyle(
              color: c.textDim,
              fontSize: 10,
              fontFamily: kMonoFont,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Live warrant-canary panel: fetch and Schnorr-verify, then status, note and meta row.
  Widget _canaryPanel(NymColors c) {
    final r = _canary;

    String statusText;
    Color statusColor;
    if (_canaryFailed) {
      statusText = tr('Unavailable offline');
      statusColor = c.textDim;
    } else if (r == null) {
      statusText = tr('Checking…');
      statusColor = c.textDim;
    } else if (r.state == 'gone') {
      statusText = tr('⚠ Canary removed');
      statusColor = c.danger;
    } else if (r.state == 'forged') {
      statusText = tr('✗ Signature invalid');
      statusColor = c.danger;
    } else if (r.state == 'ok') {
      statusText = tr('✓ All clear');
      statusColor = _kSuccess;
    } else {
      statusText = r.overdue ? tr('✗ Update overdue') : tr('✗ Not all clear');
      statusColor = c.warning;
    }

    var note = '';
    if (r != null && !_canaryFailed) {
      if (r.state == 'gone') {
        note = tr('The signed canary is no longer published. '
            'Treat this as a serious warning.');
      } else if (r.state == 'forged') {
        // 'develper' [sic] matches the PWA string verbatim.
        note = tr('The canary signature does not match the Nymchat develper '
            'key. Do not trust this canary.');
      } else if (r.state == 'ok') {
        note = r.statement.isNotEmpty
            ? r.statement
            : tr('No secret government requests have been received.');
      } else {
        note = tr('The canary has not been refreshed on schedule — a silenced '
            'request (NSL/FISA order) cannot be ruled out.');
      }
    }

    // Filled for every resolved state except 'gone'.
    var sigText = '';
    var sigColor = c.textDim;
    var dateText = '';
    String? eventUrl;
    String? anchorLabel;
    String? anchorUrl;
    if (r != null && !_canaryFailed && r.state != 'gone') {
      if (r.sig == 'valid') {
        sigText = tr('signature ✓');
        sigColor = _kSuccess;
      } else if (r.sig == 'invalid') {
        sigText = tr('signature ✗');
        sigColor = c.danger;
      } else {
        sigText = tr('unsigned');
      }
      final upd = _fmtCanaryDate(r.updatedAt);
      final due = _fmtCanaryDate(r.dueBy);
      dateText = (upd.isNotEmpty ? tr('updated {date}', {'date': upd}) : '') +
          (due.isNotEmpty ? ' · ${tr('due {date}', {'date': due})}' : '');
      if (r.id.isNotEmpty) {
        var ref = r.id;
        try {
          ref = _neventEncode(r.id, r.pubkey, _kCanaryRelayHints);
        } catch (_) {
          // Fall back to the raw hex id.
        }
        eventUrl = 'https://njump.me/$ref';
      }
      if (r.btcBlockHeight != null) {
        anchorLabel = tr('btc block {height}', {'height': r.btcBlockHeight});
        anchorUrl = 'https://mempool.space/block/${r.btcBlockHash ?? ''}';
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('Warrant canary'),
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
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                note,
                style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _link(c, tr('canary'),
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
                  _link(c, tr('nostr event'), eventUrl, size: 11),
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
            TextSpan(
                text: tr('A decentralized, pseudonymous chat built on the ')),
            _linkSpan(c, 'Nostr', 'https://nostr.com'),
            TextSpan(
                text: tr(
                    " protocol. Inspired by and bridged with Jack Dorsey's ")),
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
        _link(c, tr('Docs'), kDocsUrl),
        _link(c, 'GitHub', kGithubUrl),
        _link(c, tr('Terms of Service'), kTermsUrl),
        _link(c, tr('Privacy Policy'), kPrivacyUrl),
        _link(c, 'DMCA', kDmcaUrl),
      ],
    );
  }

  Widget _license(NymColors c) {
    return Padding(
      key: const ValueKey('about-license'),
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _creditLink(c, kAboutCopyright, kCopyrightUrl),
          Text(' · ', style: TextStyle(color: c.textDim, fontSize: 12)),
          _creditLink(c, tr('Licensed under AGPL-3.0'), kLicenseUrl),
        ],
      ),
    );
  }

  Widget _creditLink(NymColors c, String text, String url) {
    return Semantics(
      link: true,
      linkUrl: Uri.parse(url),
      child: InkWell(
        onTap: () => _openLink(url),
        child: Text(
          text,
          style: TextStyle(color: c.secondary, fontSize: 12),
        ),
      ),
    );
  }

  /// Contact textarea, max 2000 chars with no counter.
  Widget _messageBox() {
    return FormInput(
      controller: _messageController,
      hint: tr('Write your message...'),
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
            label: tr('Close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),
          Opacity(
            opacity: _sending ? 0.35 : 1.0,
            child: InkWell(
              onTap: _sending ? null : _sendContact,
              borderRadius: NymRadius.rsm,
              child: Container(
                height: 42,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: c.primaryA(0.10),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(color: c.primaryA(0.30)),
                ),
                child: Text(
                  _sending ? tr('SENDING...') : tr('SEND MESSAGE'),
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

  /// Opens [url] externally; every link is absolute.
  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort; a missing handler no-ops.
    }
  }

  /// Sends the contact message as an encrypted PM to the verified developer, clearing the field only on success.
  Future<void> _sendContact() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _status = tr('Please enter a message.');
        _statusOk = false;
      });
      return;
    }
    final connected = ref.read(appStateProvider).connectedRelays > 0;
    if (!connected) {
      setState(() {
        _status = tr('Not connected to relay. Try again once connected.');
        _statusOk = false;
      });
      return;
    }

    setState(() {
      _sending = true;
      _status = null;
    });

    // Gift-wrapped to the developer as `[Nymchat contact — <topic>]\n\n<message>`.
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
        _status = tr('Message sent. Thanks for reaching out!');
        _statusOk = true;
        _messageController.clear();
      } else {
        _status = tr('Failed to send. Please try again.');
        _statusOk = false;
      }
    });
  }
}
