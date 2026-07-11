import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/nostr/nym_generator.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'dev_nsec_modal.dart';
import 'modal_chrome.dart';
import 'nym_identicon.dart';

/// The profile / nickname editor (`#nickEditModal`, index.html:1149).
///
/// Fields (verbatim order from the PWA): Nickname (≤20, char count) with the
/// `#xxxx` pubkey suffix, Avatar (image/url), Banner, Bio (≤150), Lightning
/// address, then a "Reveal this nym's private key" slideout gated behind a
/// press-and-hold confirm. Save → `NostrController.saveProfile(...)`.
class NickEditModal extends ConsumerStatefulWidget {
  const NickEditModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const NickEditModal(),
    );
  }

  @override
  ConsumerState<NickEditModal> createState() => _NickEditModalState();
}

class _NickEditModalState extends ConsumerState<NickEditModal> {
  late final TextEditingController _nick;
  late final TextEditingController _bio;
  late final TextEditingController _lightning;

  /// The original bio / lightning so `_save` writes only changed fields and
  /// never blanks an existing value (`changeNick`, app.js:2662-2691).
  String _originalBio = '';
  String _originalLightning = '';
  String _originalNick = '';

  /// The current avatar / banner URLs (kind-0 is a full replacement, so these
  /// must be re-published when the user only edits bio/lightning, or the
  /// existing avatar/banner would be dropped). When the user picks a new image
  /// it is uploaded at pick-time (Blossom) and the HOSTED URL replaces the value
  /// here — so `_persist` always publishes a real http(s) URL, never `file://`.
  String? _currentAvatarUrl;
  String? _currentBannerUrl;

  /// The avatar / banner URLs loaded from the profile at open, so "Remove"
  /// reverts a freshly-picked image back to the pre-edit value (never blanking
  /// an existing avatar just because a new pick was abandoned).
  String? _origAvatarUrl;
  String? _origBannerUrl;

  /// Local preview paths shown while/after a pick (the picked file), purely for
  /// the on-screen thumbnail. The published value is always the hosted URL above.
  String? _avatarPath;
  String? _bannerPath;

  /// `.upload-progress` affordance state, mirroring new_pm_modal: `_uploading`
  /// toggles the bar, `_uploadLabel` is the "Uploading avatar…"/"Uploading
  /// banner…" line, `_uploadProgress` drives the fill (15%→55%→100%, users.js
  /// `_uploadFileWithProgress`).
  bool _uploading = false;
  String _uploadLabel = 'Uploading…';
  double _uploadProgress = 0;

  bool _revealOpen = false;
  bool _nsecVisible = false;
  bool _pubkeyOpen = false; // full-hex pubkey slideout
  bool _saving = false;

  /// Per-surface upload caps, mirroring the PWA nick-edit avatar/banner guards
  /// (`handleNickEditAvatarSelect` rejects >5MB, `handleNickEditBannerSelect`
  /// >10MB). Avatar 5MB, banner 10MB.
  static const int _avatarMaxBytes = 5 * 1024 * 1024;
  static const int _bannerMaxBytes = 10 * 1024 * 1024;

  /// Best-effort MIME from the picked file's extension (BUD-02 `Content-Type`),
  /// mirroring `_contentTypeFor` in new_pm_modal.dart.
  static String _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  @override
  void initState() {
    super.initState();
    final id = ref.read(nostrControllerProvider).identity;
    // Prefer the live `selfNym` (which `_ingestProfile` updates from the D1
    // kind-0 profile on login) over the identity's derived/ephemeral nym, so the
    // editor opens pre-filled with your REAL saved nickname, not "anon####".
    final selfNym = ref.read(appStateProvider).selfNym;
    final nym = selfNym.isNotEmpty ? selfNym : (id?.nym ?? '');
    // The nym is `name#suffix`; the input edits only the name part. Split on
    // the TRAILING 4-hex suffix only, so a name containing '#' survives.
    _originalNick = splitNymSuffix(nym).base;
    _nick = TextEditingController(text: _originalNick);

    // Pre-fill bio + lightning from the current profile so opening the editor
    // shows existing values and saving can't silently blank them (app.js:2595).
    final profile = id != null
        ? ref.read(appStateProvider).users[id.pubkey]?.profile
        : null;
    _originalBio = profile?.about ?? '';
    _originalLightning = profile?.lightningAddress ?? '';
    _currentAvatarUrl = profile?.picture;
    _currentBannerUrl = profile?.banner;
    _origAvatarUrl = _currentAvatarUrl;
    _origBannerUrl = _currentBannerUrl;
    _bio = TextEditingController(text: _originalBio);
    _lightning = TextEditingController(text: _originalLightning);
  }

  @override
  void dispose() {
    _nick.dispose();
    _bio.dispose();
    _lightning.dispose();
    super.dispose();
  }

  String get _pubkey => ref.read(nostrControllerProvider).identity?.pubkey ?? '';

  String get _suffix {
    final pk = _pubkey;
    return pk.length >= 4 ? '#${pk.substring(pk.length - 4)}' : '';
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
            child: Stack(
              children: [
                ModalChrome.box(
                  c,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.9,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _modalHeader(c),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _nicknameGroup(c),
                                const SizedBox(height: 18),
                                _avatarGroup(c),
                                const SizedBox(height: 18),
                                _bannerGroup(c),
                                const SizedBox(height: 18),
                                _bioGroup(c),
                                const SizedBox(height: 18),
                                _lightningGroup(c),
                                const SizedBox(height: 18),
                                _revealPrivkeyGroup(c),
                              ],
                            ),
                          ),
                        ),
                        _actions(c),
                      ],
                    ),
                  ),
                ),
                ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // `.modal-header`: 22px primary UPPERCASE ls1.5 w700 + bottom rule. A block
  // element in the PWA — full width, LEFT-aligned (never centered).
  Widget _modalHeader(NymColors c) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Text(
          tr("Change Nym's Details").toUpperCase(),
          style: TextStyle(
            color: c.primary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      );

  Widget _label(NymColors c, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            color: c.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _hint(NymColors c, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: TextStyle(color: c.textDim, fontSize: 11)),
      );

  InputBorder _inputBorder(NymColors c, [Color? color]) => OutlineInputBorder(
        borderRadius: NymRadius.rxs,
        borderSide: BorderSide(color: color ?? c.glassBorder),
      );

  Widget _nicknameGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, tr('Nickname')),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nick,
                maxLength: 20,
                buildCounter: (_,
                        {required currentLength,
                        required isFocused,
                        maxLength}) =>
                    null,
                onChanged: (_) => setState(() {}),
                style: TextStyle(color: c.text, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Enter new nym'),
                  hintStyle: TextStyle(color: c.textDim),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 11),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: _inputBorder(c),
                  enabledBorder: _inputBorder(c),
                  focusedBorder: _inputBorder(c, c.primaryA(0.3)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // `.nym-suffix-clickable` (index.html:1159) — tap to view the full
            // hex pubkey.
            Tooltip(
              message: tr('Click to view full pubkey'),
              child: InkWell(
                onTap: () => setState(() => _pubkeyOpen = !_pubkeyOpen),
                borderRadius: NymRadius.rxs,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    _suffix,
                    style: TextStyle(
                      color: c.primary,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${_nick.text.length}/20',
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ),
        if (_pubkeyOpen) _pubkeySlideout(c),
        _hint(
          c,
          tr('Your ephemeral pseudonym nickname for this session. The # and four '
              'characters identify this Nym\'s pubkey.'),
        ),
      ],
    );
  }

  /// The full-hex pubkey panel (`#pubkeySlideout`, index.html:1159-1169): a
  /// title, an explanatory paragraph, the full pubkey, and a Copy button.
  Widget _pubkeySlideout(NymColors c) {
    final pk = _pubkey;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Full Hex Pubkey'),
              style: TextStyle(
                  color: c.text, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            tr('This is your public key — a unique identifier derived from your '
                'keypair. Share it so others can find and verify this Nym. It is '
                'safe to share (unlike your private key).'),
            style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  pk,
                  style: TextStyle(
                    color: c.text,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _smallButton(
                c,
                tr('Copy'),
                () => _copyToClipboard(pk, tr('Pubkey copied')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _avatarGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, tr('Avatar')),
        Row(
          children: [
            // `.avatar-preview` (styles-features.css:2891): a CIRCLE
            // (border-radius 50%) with a 2px glass border, not a rounded square.
            Container(
              width: 64,
              height: 64,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.glassBorder, width: 2),
              ),
              child: SizedBox(
                width: 64,
                height: 64,
                child: _avatarPath != null
                    ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
                    : (_currentAvatarUrl != null && _currentAvatarUrl!.isNotEmpty
                        ? NymAvatar(
                            seed: _pubkey,
                            size: 64,
                            imageUrl: _currentAvatarUrl,
                          )
                        : NymIdenticon(seed: _pubkey, size: 64)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _smallButton(
                          c, tr('Change photo'), () => _pickImage(true)),
                      if (_avatarPath != null) ...[
                        const SizedBox(width: 8),
                        _smallButton(
                          c,
                          tr('Remove'),
                          () => setState(() {
                            _avatarPath = null;
                            _currentAvatarUrl = _origAvatarUrl;
                          }),
                          danger: true,
                        ),
                      ],
                    ],
                  ),
                  if (_uploading && _uploadLabel == 'Uploading avatar…')
                    _uploadProgressBar(c),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bannerGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, tr('Banner')),
        Builder(builder: (_) {
          final remoteBanner = _bannerPath == null
              ? proxiedAvatarUrl(_currentBannerUrl)
              : null;
          return Container(
            height: 80,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
              image: _bannerPath != null
                  ? DecorationImage(
                      image: FileImage(File(_bannerPath!)), fit: BoxFit.cover)
                  : (remoteBanner != null
                      ? DecorationImage(
                          image: NetworkImage(remoteBanner), fit: BoxFit.cover)
                      : null),
            ),
            alignment: Alignment.center,
            child: (_bannerPath == null && remoteBanner == null)
                ? Text(tr('No banner set'), style: TextStyle(color: c.textDim))
                : null,
          );
        }),
        const SizedBox(height: 8),
        Row(
          children: [
            _smallButton(c, tr('Choose banner'), () => _pickImage(false)),
            if (_bannerPath != null) ...[
              const SizedBox(width: 8),
              _smallButton(
                  c,
                  tr('Remove'),
                  () => setState(() {
                        _bannerPath = null;
                        _currentBannerUrl = _origBannerUrl;
                      }),
                  danger: true),
            ],
          ],
        ),
        if (_uploading && _uploadLabel == 'Uploading banner…')
          _uploadProgressBar(c),
      ],
    );
  }

  /// `.upload-progress` body: an "Uploading …" label over the `.progress-bar`
  /// (height 6, bg white/0.05, radius 10) with the `.progress-fill` (90°
  /// primary→secondary gradient) at the live progress width (mirrors
  /// new_pm_modal's `_uploadProgressBar`).
  Widget _uploadProgressBar(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_uploadLabel, style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            child: Container(
              height: 6,
              color: Colors.white.withValues(alpha: 0.05),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: _uploadProgress.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.all(Radius.circular(10)),
                      gradient:
                          LinearGradient(colors: [c.primary, c.secondary]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bioGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, tr('Bio')),
        TextField(
          controller: _bio,
          maxLength: 150,
          maxLines: 3,
          onChanged: (_) => setState(() {}),
          buildCounter: (_,
                  {required currentLength, required isFocused, maxLength}) =>
              null,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: tr('Tell people a bit about yourself...'),
            hintStyle: TextStyle(color: c.textDim),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: _inputBorder(c),
            enabledBorder: _inputBorder(c),
            focusedBorder: _inputBorder(c, c.primaryA(0.3)),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text('${_bio.text.length}/150',
              style: TextStyle(color: c.textDim, fontSize: 11)),
        ),
        _hint(c, tr('Short bio shown on your profile (max 150 characters)')),
      ],
    );
  }

  Widget _lightningGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, tr('Bitcoin Lightning Address')),
        TextField(
          controller: _lightning,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'your@lightning-address.com',
            hintStyle: TextStyle(color: c.textDim),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: _inputBorder(c),
            enabledBorder: _inputBorder(c),
            focusedBorder: _inputBorder(c, c.primaryA(0.3)),
          ),
        ),
        _hint(c, tr('Your Bitcoin Lightning address for receiving zaps')),
      ],
    );
  }

  Widget _revealPrivkeyGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _revealOpen = !_revealOpen),
          child: Row(
            children: [
              // `#revealPrivkeyArrow` (app.js:2959) — a filled triangle that
              // swaps down/right with the slideout (the PWA rewrites the SVG,
              // no CSS rotation).
              NymSvgIcon(
                _revealOpen
                    ? NymIcons.revealArrowDown
                    : NymIcons.revealArrowRight,
                size: 18,
                color: c.textDim,
              ),
              Text(
                tr("Reveal this nym's private key"),
                style: TextStyle(color: c.textDim, fontSize: 13),
              ),
            ],
          ),
        ),
        if (_revealOpen) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.warning.withValues(alpha: 0.08),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.warning.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The nsec-warning triangle (index.html:1237).
                    NymSvgIcon(NymIcons.warningTriangle,
                        size: 16, color: c.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('Your private key (nsec) is like a password for your '
                            'Nym identity. Anyone with access to it can post as you '
                            'and read your encrypted messages. Never share it.'),
                        style: TextStyle(color: c.text, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // The PWA reveals the nsec on a plain click toggle — no hold
                // gate (toggleRevealPrivkey, app.js:2959). Populate immediately.
                _nsecRow(c),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _nsecRow(NymColors c) {
    final id = ref.read(nostrControllerProvider).identity;
    String nsec = '';
    if (id?.privkey != null) {
      try {
        nsec = encodeNsecBytes(id!.privkey!);
      } catch (_) {}
    }
    final display = nsec.isEmpty
        ? tr('No local private key (delegated signer)')
        : (_nsecVisible
            ? nsec
            : '•' * (nsec.length.clamp(8, 24)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('nsec (Nostr Private Key)'),
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: c.glassBorder),
                ),
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.text,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            IconButton(
              // `toggleNsecVisibility` (index.html:1242) shows the SAME eye for
              // both states — the PWA only flips the input type, never the glyph.
              icon: NymSvgIcon(NymIcons.nsecEye, size: 18, color: c.textDim),
              onPressed: () => setState(() => _nsecVisible = !_nsecVisible),
            ),
            // `copyRevealedNsec` (index.html:1243) — one-tap copy of the nsec
            // (the two-sheet glyph, identical to the context-menu copy).
            if (nsec.isNotEmpty)
              IconButton(
                tooltip: tr('Copy'),
                icon: NymSvgIcon(NymIcons.ctxCopy, size: 16, color: c.textDim),
                onPressed: () => _copyToClipboard(nsec, tr('Private key copied')),
              ),
          ],
        ),
      ],
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      // `.modal-actions`: center, gap 10 (Randomize / Cancel are `.icon-btn`,
      // Change is `.send-btn`). No casino icon in the PWA.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ModalChrome.iconButton(
              c, tr('Randomize'), _saving ? null : _randomize),
          const SizedBox(width: 10),
          ModalChrome.iconButton(
              c, tr('Cancel'), () => Navigator.of(context).pop()),
          const SizedBox(width: 10),
          ModalChrome.sendButton(
            c,
            tr('Change'),
            _saving ? null : _save,
            child: _saving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.primary),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _smallButton(NymColors c, String label, VoidCallback onTap,
      {bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(
            color: danger ? c.danger.withValues(alpha: 0.4) : c.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: danger ? c.danger : c.text,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// Pick an avatar/banner, then UPLOAD it (Blossom) before saving — the kind-0
  /// `picture`/`banner` must carry a hosted URL, never a `file://` path. Mirrors
  /// the PWA `handleNickEdit{Avatar,Banner}Select` → `uploadImage` flow: enforce
  /// the per-surface cap (avatar 5MB / banner 10MB), show the progress
  /// affordance, then store the returned URL. On failure the old image is kept
  /// (nothing published) and the PWA failure alert is shown.
  Future<void> _pickImage(bool avatar) async {
    if (_uploading) return; // one upload at a time
    final Uint8List bytes;
    final String contentType;
    final String path;
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      bytes = await file.readAsBytes();
      contentType = _contentTypeFor(file.path);
      path = file.path;
    } catch (_) {
      // Picker unavailable (e.g. tests / desktop) — silently ignore.
      return;
    }
    if (!mounted) return; // readAsBytes awaited above

    // Enforce the per-surface size cap before uploading (PWA rejects oversize
    // files with a system message and aborts the upload).
    final cap = avatar ? _avatarMaxBytes : _bannerMaxBytes;
    if (bytes.length > cap) {
      final capMb = avatar ? 5 : 10;
      final actualMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      await showAppAlert(
        context,
        tr('{label} must be under {cap}MB (this image is {actual}MB).', {
          'label': avatar ? tr('Avatar') : tr('Banner'),
          'cap': capMb,
          'actual': actualMb,
        }),
      );
      return;
    }

    setState(() {
      _uploading = true;
      _uploadProgress = 0.15; // PWA seeds the fill at 15%.
      _uploadLabel = avatar ? 'Uploading avatar…' : 'Uploading banner…';
    });

    String? url;
    try {
      url = await ref.read(nostrControllerProvider).uploadImage(
            bytes,
            contentType: contentType,
            onProgress: (p) {
              if (mounted) setState(() => _uploadProgress = p);
            },
          );
    } catch (_) {
      url = null;
    }
    if (!mounted) return;

    if (url == null || url.isEmpty) {
      // Keep the old image — never publish a broken/local value (PWA shows
      // "Upload failed — try again").
      setState(() {
        _uploading = false;
        _uploadProgress = 0;
      });
      await showAppAlert(context, tr('Upload failed — try again.'));
      return;
    }

    setState(() {
      _uploading = false;
      _uploadProgress = 1;
      if (avatar) {
        _currentAvatarUrl = url;
        _avatarPath = path; // local preview thumbnail
      } else {
        _currentBannerUrl = url;
        _bannerPath = path;
      }
    });
    // PWA confirms the avatar swap with "Avatar updated successfully".
    if (avatar && mounted) {
      await showAppAlert(context, tr('Avatar updated successfully'));
    }
  }

  Future<void> _save() async {
    final newNick = _nick.text.trim();
    final nickChanged = newNick.isNotEmpty && newNick != _originalNick;

    // Reserved nicknames ("Luxas") require proving the developer nsec before
    // the rename is allowed (changeNick → isReservedNick gate, app.js:2693).
    if (nickChanged && isReservedNick(newNick)) {
      final verified = await DevNsecModal.open(context);
      if (!mounted) return;
      if (verified == null) {
        // Cancelled the reserved-nick check: persist bio/lightning edits but
        // keep the current nick (app.js:2705-2709).
        await _persist(includeName: false);
        return;
      }
    }

    await _persist(includeName: nickChanged);
  }

  /// Publishes the kind-0 profile. Because a kind-0 is a full replacement, ALL
  /// fields are sent from the prefilled controllers / current URLs — an
  /// untouched bio/lightning/avatar is re-published as-is (never blanked); a
  /// cleared field is intentionally blanked. [includeName] gates the rename so
  /// a non-change (or a cancelled reserved-nick check) leaves the nick alone.
  Future<void> _persist({required bool includeName}) async {
    setState(() => _saving = true);
    final bio = _bio.text.trim();
    final lightning = _lightning.text.trim();
    bool ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).saveProfile(
            name: includeName ? _nick.text.trim() : null,
            about: bio,
            // `_currentAvatarUrl`/`_currentBannerUrl` are always hosted http(s)
            // URLs: either the value loaded from the existing profile or the URL
            // returned by `uploadImage` at pick-time. A locally-picked file is
            // NEVER published — only its uploaded URL is. Re-publishing the
            // existing URLs also keeps them on the replaced kind-0 when only the
            // bio/lightning changed.
            picture: _currentAvatarUrl,
            banner: _currentBannerUrl,
            lud16: lightning,
          );
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text(ok ? tr('Profile updated') : tr('Could not save profile'))),
    );
  }

  /// Fills the nick field with a freshly generated random nym (Randomize,
  /// app.js:2721 `randomizeNick`).
  void _randomize() {
    final pk = _pubkey;
    final generated = NymGenerator().generate(pk);
    setState(() => _nick.text = splitNymSuffix(generated).base);
  }

  void _copyToClipboard(String value, String confirm) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(confirm)));
  }
}
