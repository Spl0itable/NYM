import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/site_links.dart';
import '../../core/constants/storage_keys.dart';
import '../../core/crypto/key_format.dart' show normalizePrivkeyInput;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/platform/deep_links.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/brand_buttons.dart';
import '../accounts/account_host.dart';
import '../i18n/i18n.dart';
import 'dev_nsec_modal.dart';
import 'key_backup/key_backup_crypto.dart';
import 'key_backup/key_backup_pq_restore.dart';
import 'key_backup/key_backup_store.dart';
import 'key_backup/key_backup_ui.dart';
import 'key_backup/passkey_backup_service.dart';
import 'modal_chrome.dart';
import 'nip46_service.dart';

enum _SetupTab { signup, login }

/// Opens an absolute [url] in the external browser.
TapGestureRecognizer _linkTap(String url) {
  return TapGestureRecognizer()
    ..onTap =
        () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// First-run setup: optional profile then Enter for an ephemeral identity, or Nostr login; images upload at pick time.
class SetupModal extends ConsumerStatefulWidget {
  const SetupModal({super.key, required this.onComplete});

  /// Called after identity creation or login starts so the gate advances.
  final VoidCallback onComplete;

  @override
  ConsumerState<SetupModal> createState() => _SetupModalState();
}

class _SetupModalState extends ConsumerState<SetupModal> {
  final _nymCtl = TextEditingController();
  final _bioCtl = TextEditingController();

  _SetupTab _tab = _SetupTab.signup;

  final _nsecCtl = TextEditingController();

  /// A pasted `bunker://` or `nostrconnect://` signer URI.
  final _bunkerCtl = TextEditingController();
  bool _connectingUri = false;

  String? _loginError;
  bool _remoteSignerOpen = false;
  String? _nostrConnectUri;
  Nip46Service? _nip46;
  String _remoteStatus = tr('Waiting for remote signer...');

  /// Guards the async nsec adopt against a double-tap.
  bool _loggingIn = false;

  /// Set once a signer session is adopted so [dispose] won't cancel the live session.
  bool _loginSucceeded = false;

  /// Local preview paths for thumbnails only; the hosted URLs below are published.
  String? _avatarPath;
  String? _bannerPath;

  /// Hosted URLs from the pick-time upload, published into kind 0 instead of local paths.
  String? _avatarUrl;
  String? _bannerUrl;

  /// Upload progress state: bar visibility, label, and fill fraction.
  bool _uploading = false;
  String _uploadLabel = 'Uploading…';
  double _uploadProgress = 0;

  bool _busy = false;

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

  @override
  void dispose() {
    _nymCtl.dispose();
    _bioCtl.dispose();
    _nsecCtl.dispose();
    _bunkerCtl.dispose();
    // Only abort an incomplete handshake; a live session is the instance the controller signs with.
    if (!_loginSucceeded) _nip46?.cancelConnect();
    super.dispose();
  }

  /// Uploads the picked image so `saveProfile` publishes a hosted URL; on failure the old image is kept.
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
      // Keep the old image; never store a broken or local value.
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
        _avatarUrl = url;
        _avatarPath = path;
      } else {
        _bannerUrl = url;
        _bannerPath = path;
      }
    });
    if (avatar && mounted) {
      await showAppAlert(context, tr('Avatar updated successfully'));
    }
  }

  Future<void> _enter() async {
    if (_busy) return;
    final nym = _nymCtl.text.trim();

    // Reserved nicknames require the developer nsec first.
    if (nym.isNotEmpty && isReservedNick(nym)) {
      final verified = await DevNsecModal.open(context);
      if (!mounted) return;
      if (verified == null) return; // canceled — don't proceed with the name
    }

    setState(() => _busy = true);

    final kv = ref.read(keyValueStoreProvider);
    final controller = ref.read(nostrControllerProvider);

    // Persist auto-ephemeral so future boots skip the modal.
    await kv.setBool(StorageKeys.autoEphemeral, true);
    if (nym.isNotEmpty) {
      await kv.setString(StorageKeys.autoEphemeralNick, nym);
      await kv.setString(StorageKeys.customNick, nym);
    }
    final bio = _bioCtl.text.trim();
    // Publish hosted URLs only; `file://` isn't a valid kind-0 picture or banner.
    final avatar = _avatarUrl;
    final banner = _bannerUrl;
    if (bio.isNotEmpty) await kv.setString(StorageKeys.bio, bio);
    if (avatar != null) await kv.setString(StorageKeys.avatarUrl, avatar);
    if (banner != null) await kv.setString(StorageKeys.bannerUrl, banner);

    // After a panic-wipe remount nothing has booted the controller; runs after the nick persists and before saveProfile.
    await controller.init();

    // Publish the profile; unpicked images are null and not published.
    await controller.saveProfile(
      name: nym.isEmpty ? null : nym,
      about: bio.isEmpty ? null : bio,
      picture: avatar,
      banner: banner,
    );

    if (!mounted) return;
    widget.onComplete();
  }

  /// Inline `nostrconnect://` flow on the shared [nip46ServiceProvider] so its socket is the one the controller signs with.
  void _startRemoteSigner() {
    final service = ref.read(nip46ServiceProvider);
    final uri = service.startNostrConnect();
    setState(() {
      _nip46 = service;
      _remoteSignerOpen = true;
      _nostrConnectUri = uri;
      _remoteStatus = tr('Waiting for remote signer...');
      _loginError = null;
    });
    () async {
      try {
        await service.awaitConnect();
        if (!mounted) return;
        setState(() => _remoteStatus = tr('Connected! Fetching public key...'));
        // Persists the session and keeps the socket live.
        await service.finishNostrConnect();
        if (!mounted) return;
        _loginSucceeded = true;
        // Adopt the remote signer at runtime, then advance the gate.
        await ref.read(nostrControllerProvider).loginWithNip46();
        if (!mounted) return;
        widget.onComplete();
      } catch (e) {
        if (!mounted) return;
        setState(() =>
            _remoteStatus = tr('Connection failed: {error}', {'error': e}));
      }
    }();
  }

  /// Aborts an in-progress remote-signer handshake and collapses its UI.
  void _cancelRemoteSigner() {
    _nip46?.cancelConnect();
    setState(() {
      _remoteSignerOpen = false;
      _nostrConnectUri = null;
      _remoteStatus = tr('Waiting for remote signer...');
    });
  }

  /// `bunker://` sends the `connect` RPC and adopts on ack; `nostrconnect://` waits for the signer.
  Future<void> _connectViaUri() async {
    if (_connectingUri || _loggingIn) return;
    final uri = _bunkerCtl.text.trim();
    if (uri.isEmpty) {
      setState(
          () => _loginError = tr('Paste a bunker:// or nostrconnect:// URI.'));
      return;
    }
    final service = ref.read(nip46ServiceProvider);
    setState(() {
      _nip46 = service;
      _connectingUri = true;
      _loginError = null;
      _remoteSignerOpen = false;
    });
    try {
      await service.connectViaUri(uri);
      if (!mounted) return;
      _loginSucceeded = true;
      await ref.read(nostrControllerProvider).loginWithNip46();
      if (!mounted) return;
      widget.onComplete();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _connectingUri = false;
        _loginError =
            tr('Signer connection failed. Check the URI and try again.');
      });
    }
  }

  /// Validates the nsec and adopts it as the running identity, then advances the gate.
  Future<void> _loginWithNsec() async {
    if (_loggingIn) return;
    final input = _nsecCtl.text.trim();
    if (input.isEmpty) {
      setState(() => _loginError = tr('Please enter your nsec.'));
      return;
    }
    // Accepts `nsec1…` or bare 64-char hex.
    if (normalizePrivkeyInput(input) == null) {
      setState(() => _loginError =
          tr('Invalid private key. Paste an nsec1… or a 64-character hex key.'));
      return;
    }
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    try {
      await ref.read(nostrControllerProvider).loginWithNsec(input);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _loginError = e is AccountAlreadySaved
            ? tr('This key is also saved as {nym}. Switch to it from the '
                'account switcher.', {'nym': e.nym})
            : tr('Invalid nsec key. Please check and try again.');
      });
      return;
    }
    if (!mounted) return;
    widget.onComplete();
  }

  Future<void> _loginWithBackupSecret(BackupSecret restored) async {
    if (_loggingIn) return;
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    final ctrl = ref.read(nostrControllerProvider);
    try {
      await ctrl.loginWithNsec(restored.secretHex,
          pqRootCode: restored.pqCode, newKey: restored.created);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loggingIn = false);
      await showAppAlert(
          context, tr('Invalid nsec key. Please check and try again.'));
      return;
    }
    if (restored.pqCode != null && !restored.created) {
      unawaited(restoreBackupPqCode(ctrl, restored));
    }
    if (!mounted) return;
    widget.onComplete();
  }

  bool get _hasKeyBackup =>
      ref.watch(keyBackupStoresProvider).isNotEmpty ||
      ref.watch(passkeyBackupAvailableProvider).valueOrNull == true;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final invite = _inviteBannerText();

    // Borderless, full-screen, with the inner column capped at 500 or 90% width.
    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (invite != null) ...[
                    _InviteBanner(text: invite, c: c),
                    const SizedBox(height: 16),
                  ],
                  // Login fields swap in inline under the Login tab.
                  _setupTabs(c),
                  if (_tab == _SetupTab.signup)
                    ..._signupPanel(c)
                  else
                    ..._loginPanel(c),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Two equal tabs over a 1px baseline; the active tab gets a 2px primary underline.
  Widget _setupTabs(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(child: _setupTabBtn(c, _SetupTab.signup, tr('Sign up'))),
          const SizedBox(width: 4),
          Expanded(child: _setupTabBtn(c, _SetupTab.login, tr('Login'))),
        ],
      ),
    );
  }

  Widget _setupTabBtn(NymColors c, _SetupTab tab, String label) {
    final active = _tab == tab;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _tab = tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: active ? c.primaryA(0.06) : Colors.transparent,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(NymRadius.xs),
            topRight: Radius.circular(NymRadius.xs),
          ),
          border: Border(
            bottom: BorderSide(
              color: active ? c.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? c.primary : c.textDim,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  List<Widget> _signupPanel(NymColors c) {
    return [
      _label(c, tr('Choose Your Nickname'), optional: true),
      const SizedBox(height: 6),
      _field(
        c,
        controller: _nymCtl,
        hint: tr('Leave empty for random nickname'),
        maxLength: 20,
        showCounter: true,
      ),
      const SizedBox(height: 4),
      Text(
        tr('Your ephemeral pseudonym nickname for this session'),
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 16),
      _label(c, tr('Choose Your Avatar'), optional: true),
      const SizedBox(height: 6),
      _avatarPicker(c),
      const SizedBox(height: 16),
      _label(c, tr('Choose Your Banner'), optional: true),
      const SizedBox(height: 6),
      _bannerPicker(c),
      const SizedBox(height: 16),
      _label(c, tr('Bio'), optional: true),
      const SizedBox(height: 6),
      _field(
        c,
        controller: _bioCtl,
        hint: tr('Tell people a bit about yourself...'),
        maxLength: 150,
        maxLines: 3,
        showCounter: true,
      ),
      const SizedBox(height: 5),
      Text(
        tr('Short bio shown on your profile (max 150 characters)'),
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 20),
      // Content-width and centered, not full-bleed.
      Align(
        key: const Key('setupEnterBtn'),
        alignment: Alignment.center,
        child: ModalChrome.sendButton(
          c,
          tr('Enter'),
          _busy ? null : _enter,
          child: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.primary),
                )
              : null,
        ),
      ),
      if (_hasKeyBackup) ...[
        const SizedBox(height: brandGroupGap - 16),
        ModalChrome.orDivider(c),
        KeyBackupSignInButtons(
          onSecret: _loginWithBackupSecret,
          signUp: true,
        ),
      ],
      const SizedBox(height: 20),
      _tosText(c, tr('By entering, you agree to our ')),
    ];
  }

  /// Remote-signer and paste-nsec login inline; the browser-extension option is hidden on native.
  List<Widget> _loginPanel(NymColors c) {
    return [
      Text(
        tr('Login with your Nostr identity to sync settings across devices.'),
        style: TextStyle(color: c.textDim, fontSize: 13),
      ),
      const SizedBox(height: 18),
      if (_hasKeyBackup) ...[
        KeyBackupSignInButtons(onSecret: _loginWithBackupSecret),
        ModalChrome.orDivider(c),
        const SizedBox(height: brandGroupGap - 16),
      ],
      ModalChrome.sendButton(
        c,
        tr('Login with Remote Signer'),
        _startRemoteSigner,
        fullWidth: true,
      ),
      const SizedBox(height: 5),
      Text(
        tr('Use Amber, or another NIP-46 compatible remote signer'),
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      if (_remoteSignerOpen) ..._remoteSignerConnect(c),
      const SizedBox(height: 14),
      // A signer URI is an alternative to the QR and works with signers on non-default relays.
      _label(c, tr('Or paste a signer URI')),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: _field(
              c,
              controller: _bunkerCtl,
              hint: tr('bunker://…  or  nostrconnect://…'),
            ),
          ),
          const SizedBox(width: 8),
          _smallButton(
            c,
            _connectingUri ? tr('Connecting…') : tr('Connect'),
            _connectingUri ? () {} : _connectViaUri,
          ),
        ],
      ),
      const SizedBox(height: 5),
      Text(
        tr('Paste a bunker:// URI from your signer, or a nostrconnect:// string'),
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      ModalChrome.orDivider(c),
      _label(c, tr('Paste your nsec')),
      const SizedBox(height: 6),
      _field(
        c,
        controller: _nsecCtl,
        hint: 'nsec1... or 64-char hex private key',
        obscureText: true,
      ),
      if (_loginError != null) ...[
        const SizedBox(height: 5),
        Text(_loginError!, style: TextStyle(color: c.danger, fontSize: 12)),
      ],
      const SizedBox(height: 5),
      Text(
        tr('Your private key stays local and is never sent to any server'),
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 40),
      // Content-width and centered, not full-bleed.
      Align(
        alignment: Alignment.center,
        child: ModalChrome.sendButton(
          c,
          tr('Login'),
          _loggingIn ? null : _loginWithNsec,
          child: _loggingIn
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.primary),
                )
              : null,
        ),
      ),
      const SizedBox(height: 20),
      _tosText(c, tr('By logging in, you agree to our ')),
    ];
  }

  /// Remote-signer connect: status, QR, copyable connection string, hint and Cancel.
  List<Widget> _remoteSignerConnect(NymColors c) {
    return [
      const SizedBox(height: 12),
      Center(
        child: Column(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: _nip46?.bareAck ?? ValueNotifier<bool>(false),
              builder: (context, bare, _) => Text(
                  bare && _remoteStatus == tr('Waiting for remote signer...')
                      ? tr('A signer answered without the connection secret, so Nymchat did not trust it. Update your signer app, or paste a bunker:// link instead.')
                      : _remoteStatus,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textDim, fontSize: 13)),
            ),
            const SizedBox(height: 12),
            if (_nostrConnectUri != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: NymRadius.rxs,
                ),
                child: QrImageView(
                  data: _nostrConnectUri!,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _label(c, tr('Connection String')),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: NymRadius.rsm,
                border: Border.all(color: c.glassBorder),
              ),
              child: SelectableText(
                _nostrConnectUri ?? '',
                maxLines: 1,
                style: TextStyle(color: c.textBright, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _smallButton(c, tr('Copy'), () {
            final uri = _nostrConnectUri;
            if (uri != null) Clipboard.setData(ClipboardData(text: uri));
          }),
        ],
      ),
      const SizedBox(height: 5),
      Text(
        tr('Scan the QR code or copy this connection string into your remote '
            'signer app'),
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: _smallButton(c, tr('Cancel'), _cancelRemoteSigner),
      ),
    ];
  }

  /// Centered ToS / Privacy footer shared by both panels.
  Widget _tosText(NymColors c, String lead) {
    return Text.rich(
      TextSpan(
        style: TextStyle(color: c.textDim, fontSize: 16),
        children: [
          TextSpan(text: lead),
          TextSpan(
            text: tr('Terms of Service'),
            style: TextStyle(
              color: c.secondary,
              decoration: TextDecoration.underline,
              decorationColor: c.secondary,
            ),
            recognizer: _linkTap(kTermsUrl),
          ),
          TextSpan(text: tr(' and ')),
          TextSpan(
            text: tr('Privacy Policy'),
            style: TextStyle(
              color: c.secondary,
              decoration: TextDecoration.underline,
              decorationColor: c.secondary,
            ),
            recognizer: _linkTap(kPrivacyUrl),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  /// Invite line for a pending group-invite token, naming the group when the token carries one.
  String? _inviteBannerText() {
    final kv = ref.read(keyValueStoreProvider);
    final token = kv.getString(StorageKeys.pendingGroupInvite);
    if (token == null || token.isEmpty) return null;
    final name = parseGroupInvite(token)?.name.trim() ?? '';
    if (name.isEmpty) {
      return tr('You\'ve been invited to join a group. Pick a nym or log in '
          'below to continue.');
    }
    return tr(
        'You\'ve been invited to join "{name}". Pick a nym or log in '
        'below to continue.',
        {'name': name});
  }

  /// Form label; the trailing "(optional)" is lowercase w400.
  Widget _label(NymColors c, String text, {bool optional = false}) {
    return RichText(
      text: TextSpan(
        text: text.toUpperCase(),
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
        children: [
          if (optional)
            TextSpan(
              text: tr(' (optional)'),
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(
    NymColors c, {
    required TextEditingController controller,
    required String hint,
    int? maxLength,
    int maxLines = 1,
    bool showCounter = false,
    bool obscureText = false,
  }) {
    // Light mode forces a black@0.04 fill and black@0.1 border.
    final baseBorder = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    final field = TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      obscureText: obscureText,
      onChanged: showCounter ? (_) => setState(() {}) : null,
      inputFormatters: maxLength == null
          ? null
          : [LengthLimitingTextInputFormatter(maxLength)],
      style: TextStyle(
        color: c.inputText,
        fontSize: 15,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 15),
        counterText: '',
        filled: true,
        fillColor: c.isLight
            ? const Color(0x0A000000)
            : Colors.white.withValues(alpha: 0.05),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: baseBorder),
        ),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: baseBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.primaryA(0.3), width: 2),
        ),
      ),
    );
    if (!showCounter || maxLength == null) return field;
    // Warn at 80%, limit at 100%.
    final len = controller.text.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '$len/$maxLength',
            style: TextStyle(
              fontSize: 11,
              color: len >= maxLength
                  ? c.danger
                  : (len >= maxLength * 0.8 ? c.warning : c.textDim),
            ),
          ),
        ),
      ],
    );
  }

  /// 80x80 circular avatar preview with Choose/Remove; blank circle before a pick.
  Widget _avatarPicker(NymColors c) {
    return Row(
      children: [
        Container(
          width: 80,
          height: 80,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.04),
            border: Border.all(color: c.glassBorder, width: 2),
          ),
          child: _avatarPath != null
              ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _smallButton(c, tr('Choose photo'), () => _pickImage(true)),
                  if (_avatarPath != null) ...[
                    const SizedBox(width: 8),
                    _smallButton(
                        c,
                        tr('Remove'),
                        () => setState(() {
                              _avatarPath = null;
                              _avatarUrl = null;
                            }),
                        danger: true),
                  ],
                ],
              ),
              if (_uploading && _uploadLabel == 'Uploading avatar…')
                _uploadProgressBar(c),
            ],
          ),
        ),
      ],
    );
  }

  /// Banner preview with Choose/Remove and a "No banner set" placeholder.
  Widget _bannerPicker(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 80,
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
            image: _bannerPath != null
                ? DecorationImage(
                    image: FileImage(File(_bannerPath!)), fit: BoxFit.cover)
                : null,
          ),
          alignment: Alignment.center,
          child: _bannerPath == null
              ? Text(tr('No banner set'), style: TextStyle(color: c.textDim))
              : null,
        ),
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
                        _bannerUrl = null;
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

  /// Upload label over a 6px progress bar with a gradient fill.
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
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({required this.text, required this.c});

  final String text;
  final NymColors c;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('setupInviteBanner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rxs,
        border: Border.all(color: c.secondary),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: c.textBright, fontSize: 13),
      ),
    );
  }
}
