import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../toasts/toast_center.dart';
import 'pq_root.dart';
import '../../core/crypto/pq.dart' as pq;
import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/key_format.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/secret_screen.dart';
import '../../services/nostr/nym_generator.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../accounts/account_host.dart';
import 'dev_nsec_modal.dart';
import 'key_backup/key_backup_actions.dart';
import 'modal_chrome.dart';
import 'nym_identicon.dart';

/// Profile and nickname editor, with a reveal slideout for the private key and recovery code.
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

  /// Originals so `_save` writes only changed fields and never blanks an existing value.
  String _originalBio = '';
  String _originalLightning = '';
  String _originalNick = '';

  /// Hosted avatar/banner URLs, re-published on every save since kind 0 is a full replacement; never `file://`.
  String? _currentAvatarUrl;
  String? _currentBannerUrl;

  /// Values at open, so "Remove" reverts a fresh pick instead of blanking the avatar.
  String? _origAvatarUrl;
  String? _origBannerUrl;

  /// Local preview paths for the on-screen thumbnail only.
  String? _avatarPath;
  String? _bannerPath;

  /// Upload progress state: bar visibility, label, and fill fraction.
  bool _uploading = false;
  String _uploadLabel = 'Uploading…';
  double _uploadProgress = 0;

  bool _revealOpen = false;
  bool _nsecVisible = false;
  bool _pqRootVisible = false;
  final TextEditingController _pqRootLink = TextEditingController();
  String? _pqRootLinkStatus;
  bool _pqRootLinking = false;
  final TextEditingController _pqRootReplace = TextEditingController();
  String? _pqRootReplaceStatus;
  bool _pqRootReplacing = false;
  bool _pqRootReplaceOpen = false;
  bool _saving = false;

  /// Upload caps: avatar 5MB, banner 10MB.
  static const int _avatarMaxBytes = 5 * 1024 * 1024;
  static const int _bannerMaxBytes = 10 * 1024 * 1024;

  /// Best-effort MIME type from the file extension (BUD-02 `Content-Type`).
  static String _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Full-pubkey display form, shared app-wide with the context menu.
  PubkeyFormat _pubkeyFormat = PubkeyFormat.npub;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final stored = readPubkeyFormat(prefs);
      if (stored != _pubkeyFormat) setState(() => _pubkeyFormat = stored);
    });
    final id = ref.read(nostrControllerProvider).identity;
    // Prefer the live `selfNym` (updated from the saved profile) over the derived ephemeral nym.
    final selfNym = ref.read(appStateProvider).selfNym;
    final nym = selfNym.isNotEmpty ? selfNym : (id?.nym ?? '');
    // Split only the trailing 4-hex suffix, so a name containing '#' survives.
    _originalNick = splitNymSuffix(nym).base;
    _nick = TextEditingController(text: _originalNick);

    // Pre-fill bio and lightning so saving can't silently blank them.
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
    _pqRootLink.dispose();
    _pqRootReplace.dispose();
    super.dispose();
  }

  String get _pubkey =>
      ref.read(nostrControllerProvider).identity?.pubkey ?? '';

  String get _suffix {
    final pk = _pubkey;
    return pk.length >= 4 ? '#${pk.substring(pk.length - 4)}' : '';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final media = MediaQuery.of(context);
    // Pad by the keyboard height and cap the modal height so lower fields stay visible.
    final keyboardInset = media.viewInsets.bottom;
    return Center(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: 20 + keyboardInset,
        ),
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
                      maxHeight: (media.size.height - keyboardInset) * 0.9,
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
                                _pubkeySlideout(c),
                                const SizedBox(height: 18),
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
                        _logoutRow(c),
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

  // Full width and left-aligned, never centered.
  Widget _modalHeader(NymColors c) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Text(
          tr("View or Edit Nym's Details").toUpperCase(),
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
                style: TextStyle(color: c.inputText, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Enter new nym'),
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
            ),
            const SizedBox(width: 8),
            // The key tail is shown in full above, so this doesn't look tappable.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                _suffix,
                style: TextStyle(
                  color: c.primary,
                  fontFamily: 'monospace',
                  fontSize: 13,
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
      ],
    );
  }

  /// Full pubkey panel above the nickname field, explaining where the `#suffix` comes from.
  Widget _pubkeySlideout(NymColors c) {
    // Same app-wide npub/hex preference as the context menu.
    final isNpub = _pubkeyFormat == PubkeyFormat.npub;
    final pk = formatPubkeyForDisplay(_pubkey, _pubkeyFormat);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              isNpub
                  ? tr('Full Public Key (npub)')
                  : tr('Full Public Key (hex)'),
              style: TextStyle(
                  color: c.text, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            tr('A "pubkey" aka "public key" is one half of a keypair: your '
                'public key identifies you to everyone, like a username, while '
                'your private key proves you are really you, like a password. '
                'Others use this pubkey to find you on Nymchat, and you use '
                'theirs to find them. The same key has two formats — npub '
                'and hex — and they are interchangeable. The four characters '
                'after the # in a nickname are the last four of the hex '
                'format.'),
            style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 8),
          // The key gets the full width, with the controls below it.
          SelectableText(
            pk,
            style: TextStyle(
              color: c.text,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _smallButton(
                c,
                isNpub ? tr('Copy npub') : tr('Copy hex pubkey'),
                () => _copyToClipboard(
                    pk, isNpub ? tr('npub copied') : tr('Pubkey copied')),
              ),
              const SizedBox(width: 6),
              _smallButton(
                c,
                isNpub ? tr('Show hex') : tr('Show npub'),
                _togglePubkeyFormat,
                icon: NymIcons.ctxSwapFormat,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Flip npub/hex and persist so the context menu agrees.
  Future<void> _togglePubkeyFormat() async {
    final next = _pubkeyFormat == PubkeyFormat.npub
        ? PubkeyFormat.hex
        : PubkeyFormat.npub;
    setState(() => _pubkeyFormat = next);
    final prefs = await SharedPreferences.getInstance();
    await writePubkeyFormat(prefs, next);
  }

  Widget _avatarGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, tr('Avatar')),
        Row(
          children: [
            // A circle with a 2px glass border.
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
                    : (_currentAvatarUrl != null &&
                            _currentAvatarUrl!.isNotEmpty
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
          final remoteBanner =
              _bannerPath == null ? proxiedAvatarUrl(_currentBannerUrl) : null;
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
          style: TextStyle(color: c.inputText, fontSize: 14),
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
          style: TextStyle(color: c.inputText, fontSize: 14),
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
              // Secondary, not dim: this row leads to key material.
              NymSvgIcon(
                _revealOpen
                    ? NymIcons.revealArrowDown
                    : NymIcons.revealArrowRight,
                size: 18,
                color: c.secondary,
              ),
              Flexible(
                child: Text(
                  tr("Reveal this nym's private key and recovery code"),
                  style: TextStyle(
                      color: c.secondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
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
                // The nsec reveals on a plain toggle with no hold gate.
                _nsecRow(c),
                const SizedBox(height: 16),
                _pqRootRow(c),
                if (canShowKeyBackup(ref)) ...[
                  const SizedBox(height: 16),
                  const KeyBackupActions(),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Recovery code row; without it another device can't read quantum-resistant messages.
  Widget _pqRootRow(NymColors c) {
    final ctrl = ref.read(nostrControllerProvider);
    final code = ctrl.pqRootCode;
    return code == null ? _pqRootLinkRow(c) : _pqRootCodeRow(c, code);
  }

  Widget _pqRootCodeRow(NymColors c, String code) {
    final display = _pqRootVisible ? code : '•' * code.length.clamp(8, 24);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pqRootVisible) const SecretGuard(),
        Text(tr('Post-quantum recovery code'),
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          tr('This code, not your nsec, is what makes your messages '
              'quantum-resistant. Copy it to any other device you use this '
              'account on. Store it with your nsec and never share it.'),
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
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
                      color: c.inputText, fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            IconButton(
              icon: NymSvgIcon(NymIcons.nsecEye, size: 18, color: c.textDim),
              onPressed: () =>
                  setState(() => _pqRootVisible = !_pqRootVisible),
            ),
            IconButton(
              tooltip: tr('Copy'),
              icon: NymSvgIcon(NymIcons.ctxCopy, size: 16, color: c.textDim),
              onPressed: () => _copyToClipboard(
                  code, tr('Post-quantum recovery code copied'),
                  secret: true),
            ),
          ],
        ),
        // The fingerprint lets devices be compared without revealing the code and confirms a paste took.
        if (_pqRootFingerprint != null) ...[
          const SizedBox(height: 6),
          Text(
            tr('Fingerprint: {fp}', {'fp': _pqRootFingerprint!}),
            style: TextStyle(
                color: c.textDim, fontFamily: 'monospace', fontSize: 11),
          ),
        ],
        const SizedBox(height: 6),
        _pqRootReplaceRow(c),
      ],
    );
  }

  Widget _pqRootReplaceRow(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () =>
              setState(() => _pqRootReplaceOpen = !_pqRootReplaceOpen),
          child: Text(
            tr('Replace with a different code'),
            style: TextStyle(color: c.primary, fontSize: 11),
          ),
        ),
        if (_pqRootReplaceOpen) ...[
          const SizedBox(height: 4),
          Text(
            tr('If this device created a new code by mistake and you still '
                'have your previous nympq1… code, paste it here to make it '
                'this account\u2019s recovery code again, on this device and '
                'in your synced account record.'),
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pqRootReplace,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: TextStyle(
                      color: c.inputText,
                      fontFamily: 'monospace',
                      fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'nympq1…',
                    hintStyle: TextStyle(color: c.textDim, fontSize: 12),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    enabledBorder: _inputBorder(c, c.glassBorder),
                    focusedBorder: _inputBorder(c, c.primaryA(0.3)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _pqRootReplacing ? null : _replacePqRoot,
                child: Text(tr('Replace'),
                    style: TextStyle(color: c.primary, fontSize: 12)),
              ),
            ],
          ),
          if (_pqRootReplaceStatus != null) ...[
            const SizedBox(height: 4),
            Text(_pqRootReplaceStatus!,
                style: TextStyle(color: c.textDim, fontSize: 11)),
          ],
        ],
      ],
    );
  }

  Future<void> _replacePqRoot() async {
    final code = _pqRootReplace.text.trim();
    if (code.isEmpty) return;
    final ctrl = ref.read(nostrControllerProvider);
    final verdict = ctrl.pqRootLinkVerdict(code);
    if (verdict == 'invalid') {
      setState(() => _pqRootReplaceStatus =
          tr('That is not a valid nympq1… code. Check it and try again.'));
      return;
    }
    if (ctrl.pqRootCode == code) {
      setState(() => _pqRootReplaceStatus =
          tr('This device already uses that code.'));
      return;
    }
    final confirmed = await _confirmPqRootReplace();
    if (!confirmed || !mounted) return;
    setState(() {
      _pqRootReplacing = true;
      _pqRootReplaceStatus = tr('Replacing…');
    });
    final ok = await ctrl.replacePqRootWithCode(code);
    if (!mounted) return;
    setState(() {
      _pqRootReplacing = false;
      _pqRootReplaceStatus = ok
          ? tr('Replaced. This account now uses the code you pasted.')
          : tr('The code could not be saved to your account right now. '
              'Check your connection and try again.');
      if (ok) {
        _pqRootReplace.clear();
        _pqRootReplaceOpen = false;
      }
    });
  }

  Future<bool> _confirmPqRootReplace() => showAppConfirm(
        context,
        tr('This replaces the recovery code this account uses with the one '
            'you pasted, on this device and in your synced account record.'
            '\n\nEvery other device on this account will then need the '
            'pasted code. Messages sealed to the current code stay readable '
            'only on devices that still hold it.\n\nReplace the recovery '
            'code?'),
        title: tr('Replace the recovery code?'),
        okLabel: tr('Replace'),
        danger: true,
      );

  /// Short public fingerprint of the held root, or null.
  String? get _pqRootFingerprint {
    final code = ref.read(nostrControllerProvider).pqRootCode;
    if (code == null) return null;
    final bytes = pqRootFromCode(code);
    return bytes == null ? null : pq.pqRootFingerprint(bytes);
  }

  Widget _pqRootLinkRow(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _pqRootLink,
          builder: (_, value, _) => value.text.trim().isEmpty
              ? const SizedBox.shrink()
              : const SecretGuard(),
        ),
        Text(tr('Post-quantum recovery code'),
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          ref.read(nostrControllerProvider).pqRootRowUnreadable
              ? tr('This account\u2019s recovery-code record could not be '
                  'read on this device. Paste your nympq1… code to restore '
                  'it for this account.')
              : tr('This device has no recovery code yet. Paste the one from a '
                  'device that already has it — you will find it in this same '
                  'panel there — so both can read the same quantum-resistant '
                  'messages.'),
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pqRootLink,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(
                    color: c.inputText, fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'nympq1…',
                  hintStyle: TextStyle(color: c.textDim, fontSize: 12),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  enabledBorder: _inputBorder(c, c.glassBorder),
                  focusedBorder: _inputBorder(c, c.primaryA(0.3)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _pqRootLinking ? null : _linkPqRoot,
              child: Text(tr('Link'),
                  style: TextStyle(color: c.primary, fontSize: 12)),
            ),
          ],
        ),
        if (_pqRootLinkStatus != null) ...[
          const SizedBox(height: 4),
          Text(_pqRootLinkStatus!,
              style: TextStyle(color: c.textDim, fontSize: 11)),
        ],
      ],
    );
  }

  Future<void> _linkPqRoot() async {
    final code = _pqRootLink.text.trim();
    if (code.isEmpty) return;
    final ctrl = ref.read(nostrControllerProvider);
    if (ctrl.pqRootLinkVerdict(code) == 'mismatch') {
      setState(() => _pqRootLinkStatus = tr(
          'That code does not match this account\u2019s current recovery code.'));
      final replace = await showAppConfirm(
        context,
        tr('This code does not match the recovery code the account currently '
            'uses.\n\nIf the current code was created by mistake, you can '
            'replace it with this one. Every device on this account will then '
            'need this code, and messages sealed to the current code will only '
            'stay readable on devices that still hold it.\n\nReplace the '
            'account\u2019s recovery code with the one you pasted?'),
        title: tr('Replace the recovery code?'),
        okLabel: tr('Replace'),
        danger: true,
      );
      if (!replace || !mounted) return;
      setState(() => _pqRootLinking = true);
      final replaced = await ctrl.replacePqRootWithCode(code);
      if (!mounted) return;
      setState(() {
        _pqRootLinking = false;
        _pqRootLinkStatus = replaced
            ? tr('Replaced. This account now uses the code you pasted.')
            : tr('The code could not be saved to your account right now. '
                'Check your connection and try again.');
        if (replaced) _pqRootLink.clear();
      });
      return;
    }
    setState(() => _pqRootLinking = true);
    final ok = await ctrl.linkPqRootFromCode(code);
    if (!mounted) return;
    setState(() {
      _pqRootLinking = false;
      _pqRootLinkStatus = ok
          ? tr('Linked. This device can now read your quantum-resistant '
              'messages.')
          : tr('That code does not match this account. Check it and try '
              'again.');
      if (ok) _pqRootLink.clear();
    });
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
        : (_nsecVisible ? nsec : '•' * (nsec.length.clamp(8, 24)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_nsecVisible && nsec.isNotEmpty) const SecretGuard(),
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
                    color: c.inputText,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            IconButton(
              // Same eye glyph for both states; only the visibility flips.
              icon: NymSvgIcon(NymIcons.nsecEye, size: 18, color: c.textDim),
              onPressed: () => setState(() => _nsecVisible = !_nsecVisible),
            ),
            if (nsec.isNotEmpty)
              IconButton(
                tooltip: tr('Copy'),
                icon: NymSvgIcon(NymIcons.ctxCopy, size: 16, color: c.textDim),
                onPressed: () =>
                    _copyToClipboard(nsec, tr('Private key copied'),
                        secret: true),
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

  Future<void> _logout() async {
    final controller = ref.read(nostrControllerProvider);
    final accounts = ref.read(accountsProvider);
    final ok = await showAppConfirm(
      context,
      accounts == null
          ? tr('Sign out and disconnect from Nymchat?')
          : tr('Log out of this account? Keys stored only on this device will '
              'be deleted. Back up your nsec first. Your other accounts stay '
              'on this device.'),
      okLabel: tr('Sign out'),
      danger: true,
    );
    if (!ok) return;
    if (mounted) Navigator.of(context).pop();
    if (accounts != null) {
      await accounts.logout();
      return;
    }
    await controller.signOut();
  }

  Widget _logoutRow(NymColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('nickLogoutBtn'),
          onTap: _logout,
          borderRadius: NymRadius.rxs,
          hoverColor: c.danger.withValues(alpha: 0.12),
          focusColor: c.danger.withValues(alpha: 0.12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NymSvgIcon(NymIcons.logout, size: 16, color: c.danger),
                const SizedBox(width: 8),
                Text(
                  tr('Log out'),
                  style: TextStyle(
                    color: c.danger,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _smallButton(NymColors c, String label, VoidCallback onTap,
      {bool danger = false, String? icon}) {
    final fg = danger ? c.danger : c.text;
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              NymSvgIcon(icon, size: 12, color: fg),
              const SizedBox(width: 5),
            ],
            Text(label, style: TextStyle(color: fg, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// Uploads the picked image before saving so kind 0 carries a hosted URL; on failure the old image is kept.
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
      // Picker unavailable (tests, desktop): ignore.
      return;
    }
    if (!mounted) return;

    // Enforce the size cap before uploading.
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
      _uploadProgress = 0.15;
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
      // Keep the old image; never publish a broken or local value.
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
        _avatarPath = path;
      } else {
        _currentBannerUrl = url;
        _bannerPath = path;
      }
    });
    if (avatar && mounted) {
      await showAppAlert(context, tr('Avatar updated successfully'));
    }
  }

  Future<void> _save() async {
    final newNick = _nick.text.trim();
    final nickChanged = newNick.isNotEmpty && newNick != _originalNick;

    // Reserved nicknames require proving the developer nsec first.
    if (nickChanged && isReservedNick(newNick)) {
      final verified = await DevNsecModal.open(context);
      if (!mounted) return;
      if (verified == null) {
        // Check canceled: persist bio and lightning but keep the current nick.
        await _persist(includeName: false);
        return;
      }
    }

    await _persist(includeName: nickChanged);
  }

  /// Publishes the full kind-0 from current fields; [includeName] gates the rename.
  Future<void> _persist({required bool includeName}) async {
    setState(() => _saving = true);
    final bio = _bio.text.trim();
    final lightning = _lightning.text.trim();
    bool ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).saveProfile(
            name: includeName ? _nick.text.trim() : null,
            about: bio,
            // Always hosted URLs, never a local file.
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
    showToast(ok ? tr('Profile updated') : tr('Could not save profile'));
  }

  /// Fills the nick field with a random nym.
  void _randomize() {
    final pk = _pubkey;
    final generated = NymGenerator().generate(pk);
    setState(() => _nick.text = splitNymSuffix(generated).base);
  }

  void _copyToClipboard(String value, String confirm, {bool secret = false}) {
    if (secret) {
      SecretScreen.copy(value);
    } else {
      Clipboard.setData(ClipboardData(text: value));
    }
    showToast(confirm);
  }
}
