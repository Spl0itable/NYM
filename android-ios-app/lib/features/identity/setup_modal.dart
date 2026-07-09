import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/platform/deep_links.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import 'dev_nsec_modal.dart';
import 'modal_chrome.dart';
import 'nip46_service.dart';

/// Which auth tab the setup modal shows (`.setup-tab`, index.html:1204-1206).
enum _SetupTab { signup, login }

/// Opens an absolute [url] in the external browser (ToS/PP footer links).
TapGestureRecognizer _linkTap(String url) {
  return TapGestureRecognizer()
    ..onTap = () =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// First-run setup screen mirroring `#setupModal` (index.html 1257–1346).
///
/// The user picks an optional nickname / avatar / banner / bio and taps
/// **Enter** to create an ephemeral identity, or opens the Nostr login. On
/// success [onComplete] fires so the [BootGate] proceeds to the shell.
///
/// Avatar/banner are file pickers (`setupAvatarPreview` / `setupBannerPreview`,
/// index.html:1285-1323): a preview, "Choose photo"/"Remove" buttons. The picked
/// file is uploaded (Blossom) at pick-time and the returned HOSTED URL is what
/// `saveProfile` publishes into the kind-0 — a `file://` path is never sent.
class SetupModal extends ConsumerStatefulWidget {
  const SetupModal({super.key, required this.onComplete});

  /// Called after the identity is created / login starts so the gate advances.
  final VoidCallback onComplete;

  @override
  ConsumerState<SetupModal> createState() => _SetupModalState();
}

class _SetupModalState extends ConsumerState<SetupModal> {
  final _nymCtl = TextEditingController();
  final _bioCtl = TextEditingController();

  /// Active auth tab — Sign up (default) or Login (`switchSetupTab`).
  _SetupTab _tab = _SetupTab.signup;

  // ---- Login tab state (inlined from the former Nostr-login popup) ----
  final _nsecCtl = TextEditingController();

  /// A pasted `bunker://` (or `nostrconnect://`) signer connection URI.
  final _bunkerCtl = TextEditingController();
  bool _connectingUri = false;

  String? _loginError;
  bool _remoteSignerOpen = false;
  String? _nostrConnectUri;
  Nip46Service? _nip46;
  String _remoteStatus = 'Waiting for remote signer...';

  /// Guards the async nsec adopt so a double-tap can't re-enter login.
  bool _loggingIn = false;

  /// Set once a remote-signer session is established + adopted, so [dispose]
  /// won't cancel the (now live) session when the modal tears down.
  bool _loginSucceeded = false;

  /// Local preview paths for the on-screen thumbnails only — the published
  /// value is always the HOSTED URL below (set after a pick-time upload).
  String? _avatarPath;
  String? _bannerPath;

  /// The hosted (Blossom) URLs returned by `uploadImage` after a pick. These —
  /// not the local `file://` paths — are what `saveProfile` publishes into the
  /// kind-0 `picture`/`banner`.
  String? _avatarUrl;
  String? _bannerUrl;

  /// `.upload-progress` affordance state (mirrors new_pm_modal): `_uploading`
  /// toggles the bar, `_uploadLabel` is the "Uploading avatar…"/"Uploading
  /// banner…" line, `_uploadProgress` drives the fill (users.js
  /// `_uploadFileWithProgress`).
  bool _uploading = false;
  String _uploadLabel = 'Uploading…';
  double _uploadProgress = 0;

  bool _busy = false;

  /// Per-surface upload caps, mirroring the PWA avatar/banner guards. Avatar
  /// 5MB, banner 10MB.
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
  void dispose() {
    _nymCtl.dispose();
    _bioCtl.dispose();
    _nsecCtl.dispose();
    _bunkerCtl.dispose();
    // Only abort an INCOMPLETE handshake — a successful session is the shared
    // [nip46ServiceProvider] instance the controller now signs with.
    if (!_loginSucceeded) _nip46?.cancelConnect();
    super.dispose();
  }

  /// Pick an avatar/banner, then UPLOAD it (Blossom) so `saveProfile` publishes
  /// a hosted URL, never a `file://` path. Mirrors the PWA setup avatar/banner
  /// select → `uploadImage` flow: enforce the cap (avatar 5MB / banner 10MB),
  /// show the progress affordance, store the returned URL. On failure the old
  /// image is kept (nothing stored) and the PWA failure alert is shown.
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

    // Enforce the per-surface size cap before uploading.
    final cap = avatar ? _avatarMaxBytes : _bannerMaxBytes;
    if (bytes.length > cap) {
      final capMb = avatar ? 5 : 10;
      final actualMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      await showAppAlert(
        context,
        '${avatar ? 'Avatar' : 'Banner'} must be under ${capMb}MB '
        '(this image is ${actualMb}MB).',
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
      // Keep the old image — never store a broken/local value (PWA shows
      // "Upload failed — try again").
      setState(() {
        _uploading = false;
        _uploadProgress = 0;
      });
      await showAppAlert(context, 'Upload failed — try again.');
      return;
    }

    setState(() {
      _uploading = false;
      _uploadProgress = 1;
      if (avatar) {
        _avatarUrl = url;
        _avatarPath = path; // local preview thumbnail
      } else {
        _bannerUrl = url;
        _bannerPath = path;
      }
    });
    if (avatar && mounted) {
      await showAppAlert(context, 'Avatar updated successfully');
    }
  }

  Future<void> _enter() async {
    if (_busy) return;
    final nym = _nymCtl.text.trim();

    // Reserved nicknames ("Luxas") require the developer nsec before the name
    // is allowed (index.html setup submit → isReservedNick, app.js:4766).
    if (nym.isNotEmpty && isReservedNick(nym)) {
      final verified = await DevNsecModal.open(context);
      if (!mounted) return;
      if (verified == null) return; // cancelled — don't proceed with the name
    }

    setState(() => _busy = true);

    final kv = ref.read(keyValueStoreProvider);
    final controller = ref.read(nostrControllerProvider);

    // Persist auto-ephemeral so future boots skip the modal (initializeNym).
    await kv.setBool(StorageKeys.autoEphemeral, true);
    if (nym.isNotEmpty) {
      await kv.setString(StorageKeys.autoEphemeralNick, nym);
      await kv.setString(StorageKeys.customNick, nym);
    }
    final bio = _bioCtl.text.trim();
    // Persist/publish the HOSTED URLs (uploaded at pick-time), never the local
    // `file://` paths — a `file://` is not a valid kind-0 `picture`/`banner`.
    final avatar = _avatarUrl;
    final banner = _bannerUrl;
    if (bio.isNotEmpty) await kv.setString(StorageKeys.bio, bio);
    if (avatar != null) await kv.setString(StorageKeys.avatarUrl, avatar);
    if (banner != null) await kv.setString(StorageKeys.bannerUrl, banner);

    // Ensure the controller is booted. At COLD boot main() already booted the
    // ephemeral identity behind this modal (init() is then a no-op via its
    // _started guard), but after a panic-wipe remount NOTHING has re-booted
    // it — the PWA reloads the page, which re-runs its whole boot chain.
    // Without this the shell mounts with no identity (empty pubkey → '????'
    // suffix) and no relay service, so nothing ever loads. Runs AFTER the
    // autoEphemeral/nick persists (the boot adopts the chosen nick) and
    // BEFORE saveProfile (the publish needs a live identity + signer).
    await controller.init();

    // Publish the chosen profile so the nym + avatar/banner/bio land on
    // relays (saveToNostrProfile). avatar/banner are the hosted URLs returned
    // by `uploadImage`; if no image was picked they're null, so nothing new
    // is published for them.
    await controller.saveProfile(
      name: nym.isEmpty ? null : nym,
      about: bio.isEmpty ? null : bio,
      picture: avatar,
      banner: banner,
    );

    if (!mounted) return;
    widget.onComplete();
  }

  /// Starts the inline `nostrconnect://` remote-signer flow (Login tab). Drives
  /// the SHARED [nip46ServiceProvider] so the live socket this handshake opens
  /// is the exact instance the controller signs with after
  /// [NostrController.loginWithNip46] adopts it — remote signing works
  /// immediately, not only after an app restart.
  void _startRemoteSigner() {
    final service = ref.read(nip46ServiceProvider);
    final uri = service.startNostrConnect();
    setState(() {
      _nip46 = service;
      _remoteSignerOpen = true;
      _nostrConnectUri = uri;
      _remoteStatus = 'Waiting for remote signer...';
      _loginError = null;
    });
    () async {
      try {
        await service.awaitConnect();
        if (!mounted) return;
        setState(() => _remoteStatus = 'Connected! Fetching public key...');
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
        setState(() => _remoteStatus = 'Connection failed: $e');
      }
    }();
  }

  /// Aborts an in-progress remote-signer handshake and collapses its UI.
  void _cancelRemoteSigner() {
    _nip46?.cancelConnect();
    setState(() {
      _remoteSignerOpen = false;
      _nostrConnectUri = null;
      _remoteStatus = 'Waiting for remote signer...';
    });
  }

  /// Connects to a signer from a pasted `bunker://` (or `nostrconnect://`) URI
  /// via [Nip46Service.connectViaUri] — for a `bunker://` we send the explicit
  /// `connect` RPC and adopt on the signer's ack; for a pasted `nostrconnect://`
  /// we wait for the signer to initiate. Then adopts at runtime like the QR flow.
  Future<void> _connectViaUri() async {
    if (_connectingUri || _loggingIn) return;
    final uri = _bunkerCtl.text.trim();
    if (uri.isEmpty) {
      setState(() => _loginError = 'Paste a bunker:// or nostrconnect:// URI.');
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
        _loginError = 'Signer connection failed. Check the URI and try again.';
      });
    }
  }

  /// Validates the pasted nsec, then ADOPTS it as the running identity via
  /// [NostrController.loginWithNsec] (persist + re-boot under the new pubkey +
  /// bump the boot epoch, which remounts the gate onto the shell). Then advances
  /// the gate via [onComplete] (idempotent with the boot-epoch remount).
  Future<void> _loginWithNsec() async {
    if (_loggingIn) return;
    final input = _nsecCtl.text.trim();
    if (input.isEmpty) {
      setState(() => _loginError = 'Please enter your nsec.');
      return;
    }
    try {
      final bytes = decodeNsec(input);
      if (bytes.length != 32) {
        setState(() =>
            _loginError = 'Invalid nsec key. Please check and try again.');
        return;
      }
    } catch (_) {
      setState(
          () => _loginError = 'Invalid nsec key. Please check and try again.');
      return;
    }
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    try {
      await ref.read(nostrControllerProvider).loginWithNsec(input);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _loginError = 'Invalid nsec key. Please check and try again.';
      });
      return;
    }
    if (!mounted) return;
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final invite = _inviteBannerText();

    // `.setup-modal-content`: borderless, radius 0, fills the screen, with the
    // inner column capped at 500 / 90% width (index.html:1258, CSS :30-46/75-89).
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
                    // `.setup-tabs` (index.html:1204-1206): Sign up / Login —
                    // replaces the old "Login with nsec…" link; the Login tab
                    // swaps in the login fields inline (no popup).
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

  /// `.setup-tabs` (styles-components.css:87-127): a flex row of two equal
  /// `.setup-tab` buttons over a 1px glass-border baseline; the active tab is
  /// primary-tinted with a 2px primary underline.
  Widget _setupTabs(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(child: _setupTabBtn(c, _SetupTab.signup, 'Sign up')),
          const SizedBox(width: 4), // `.setup-tabs { gap: 4px }`
          Expanded(child: _setupTabBtn(c, _SetupTab.login, 'Login')),
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
        // `.setup-tab { padding: 12px 10px }`.
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: active ? c.primaryA(0.06) : Colors.transparent,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(NymRadius.xs),
            topRight: Radius.circular(NymRadius.xs),
          ),
          // `.setup-tab.active::after`: a 2px primary underline.
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

  /// `#setupSignupPanel` (index.html:1208-1267) + the shared Enter action / ToS
  /// footer that live under the signup tab.
  List<Widget> _signupPanel(NymColors c) {
    return [
      _label(c, 'Choose Your Nickname', optional: true),
      const SizedBox(height: 6),
      _field(
        c,
        controller: _nymCtl,
        hint: 'Leave empty for random nickname',
        maxLength: 20,
        showCounter: true,
      ),
      const SizedBox(height: 4),
      Text(
        'Your ephemeral pseudonym nickname for this session',
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 16),
      _label(c, 'Choose Your Avatar', optional: true),
      const SizedBox(height: 6),
      _avatarPicker(c),
      const SizedBox(height: 16),
      _label(c, 'Choose Your Banner', optional: true),
      const SizedBox(height: 6),
      _bannerPicker(c),
      const SizedBox(height: 16),
      _label(c, 'Bio', optional: true),
      const SizedBox(height: 6),
      _field(
        c,
        controller: _bioCtl,
        hint: 'Tell people a bit about yourself...',
        maxLength: 150,
        maxLines: 3,
        showCounter: true,
      ),
      const SizedBox(height: 5),
      // `.form-hint` under the bio char count (index.html:1332).
      Text(
        'Short bio shown on your profile (max 150 characters)',
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 20),
      // `.send-btn` (translucent primary pill), h42. `.modal-actions` is a
      // centered flex and the button is `flex: 0 1 auto`, so it's content-width
      // and centered — NOT full-bleed (index.html:1338, styles-chat.css:1920).
      Align(
        key: const Key('setupEnterBtn'),
        alignment: Alignment.center,
        child: ModalChrome.sendButton(
          c,
          'Enter',
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
      const SizedBox(height: 20),
      // `#setupSignupTos` (index.html:1341): centered ToS/Privacy footer.
      _tosText(c, 'By entering, you agree to our '),
    ];
  }

  /// `#setupLoginPanel` (index.html:1268-1345): remote-signer + paste-nsec login
  /// inline (the browser-extension option is native-hidden, as in the PWA).
  List<Widget> _loginPanel(NymColors c) {
    return [
      // `.nm-h-21`: 13px text-dim.
      Text(
        'Login with your Nostr identity to sync settings across devices.',
        style: TextStyle(color: c.textDim, fontSize: 13),
      ),
      const SizedBox(height: 18),
      // `.send-btn` "Login with Remote Signer" + hint.
      ModalChrome.sendButton(
        c,
        'Login with Remote Signer',
        _startRemoteSigner,
        fullWidth: true,
      ),
      const SizedBox(height: 5),
      Text(
        'Use Amber, or another NIP-46 compatible remote signer',
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      if (_remoteSignerOpen) ..._remoteSignerConnect(c),
      const SizedBox(height: 14),
      // Paste a signer connection URI (bunker:// or a nostrconnect:// string) —
      // an alternative to scanning the QR, and the way to use a signer whose
      // relay isn't the default (the URI carries its own relay).
      _label(c, 'Or paste a signer URI'),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: _field(
              c,
              controller: _bunkerCtl,
              hint: 'bunker://…  or  nostrconnect://…',
            ),
          ),
          const SizedBox(width: 8),
          _smallButton(
            c,
            _connectingUri ? 'Connecting…' : 'Connect',
            _connectingUri ? () {} : _connectViaUri,
          ),
        ],
      ),
      const SizedBox(height: 5),
      Text(
        'Paste a bunker:// URI from your signer, or a nostrconnect:// string',
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      ModalChrome.orDivider(c),
      // Paste-nsec option.
      _label(c, 'Paste your nsec'),
      const SizedBox(height: 6),
      _field(
        c,
        controller: _nsecCtl,
        hint: 'nsec1...',
        obscureText: true,
      ),
      if (_loginError != null) ...[
        const SizedBox(height: 5),
        Text(_loginError!, style: TextStyle(color: c.danger, fontSize: 12)),
      ],
      const SizedBox(height: 5),
      Text(
        'Your private key stays local and is never sent to any server',
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      // `.modal-actions.nm-h-81 { margin: 40px auto 20px }`.
      const SizedBox(height: 40),
      // `.send-btn.nm-h-82 { flex: 0 1 auto }` in a centered `.modal-actions`:
      // content-width, centered — not full-bleed.
      Align(
        alignment: Alignment.center,
        child: ModalChrome.sendButton(
          c,
          'Login',
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
      _tosText(c, 'By logging in, you agree to our '),
    ];
  }

  /// The remote-signer connection affordance (`#nostrLoginRemoteSignerConnect`,
  /// index.html:1292-1311): status line, QR, readonly connection string + Copy,
  /// hint, and a Cancel action.
  List<Widget> _remoteSignerConnect(NymColors c) {
    return [
      const SizedBox(height: 12),
      Center(
        child: Column(
          children: [
            Text(_remoteStatus,
                style: TextStyle(color: c.textDim, fontSize: 13)),
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
      _label(c, 'Connection String'),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
          _smallButton(c, 'Copy', () {
            final uri = _nostrConnectUri;
            if (uri != null) Clipboard.setData(ClipboardData(text: uri));
          }),
        ],
      ),
      const SizedBox(height: 5),
      Text(
        'Scan the QR code or copy this connection string into your remote '
        'signer app',
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: _smallButton(c, 'Cancel', _cancelRemoteSigner),
      ),
    ];
  }

  /// The centered `.nm-secondary` ToS / Privacy footer shared by both panels
  /// (`#setupSignupTos` / `#setupLoginPanel .nm-h-35`), with the given lead-in.
  Widget _tosText(NymColors c, String lead) {
    return Text.rich(
      TextSpan(
        style: TextStyle(color: c.textDim, fontSize: 16),
        children: [
          TextSpan(text: lead),
          TextSpan(
            text: 'Terms of Service',
            style: TextStyle(
              color: c.secondary,
              decoration: TextDecoration.underline,
              decorationColor: c.secondary,
            ),
            recognizer: _linkTap('https://web.nymchat.app/static/tos.html'),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: TextStyle(
              color: c.secondary,
              decoration: TextDecoration.underline,
              decorationColor: c.secondary,
            ),
            recognizer: _linkTap('https://web.nymchat.app/static/pp.html'),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  /// Mirrors updateSetupInviteBanner: shows an invite line when a pending
  /// group-invite token is present (`nym_pending_group_invite`), decoding the
  /// group name so the banner reads `You've been invited to join "<name>".`
  /// (app.js:7161) — falling back to the generic copy when the token carries
  /// no name.
  String? _inviteBannerText() {
    final kv = ref.read(keyValueStoreProvider);
    final token = kv.getString(StorageKeys.pendingGroupInvite);
    if (token == null || token.isEmpty) return null;
    final name = parseGroupInvite(token)?.name.trim() ?? '';
    if (name.isEmpty) {
      return 'You\'ve been invited to join a group. Pick a nym or log in '
          'below to continue.';
    }
    return 'You\'ve been invited to join "$name". Pick a nym or log in '
        'below to continue.';
  }

  /// `.form-label`: 11px textDim UPPERCASE ls1.2 w600; the trailing
  /// "(optional)" span is `.nm-h-2` (w400, none-case, ls0).
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
              text: ' (optional)',
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
    // Light mode forces `input/.form-input { background: rgba(0,0,0,0.04);
    // border-color: rgba(0,0,0,0.1); color: #000 } !important`
    // (styles-themes-responsive.css:561-592); dark keeps the `.form-input`
    // white/0.05 fill + glass border.
    final baseBorder = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    final field = TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      obscureText: obscureText,
      onChanged: showCounter ? (_) => setState(() {}) : null,
      inputFormatters:
          maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
      style: TextStyle(
        color: c.isLight ? const Color(0xFF000000) : c.textBright,
        fontSize: 15,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 15),
        counterText: '',
        filled: true,
        // `.form-input` fill white/0.05 (light: black/0.04).
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
    // `.input-char-count` — warn at 80%, limit at 100% (updateFieldCharCount).
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

  /// `setupAvatarPreview` (index.html:1220-1233) — 80×80 preview + Choose/Remove.
  /// `.avatar-preview` (styles-features.css:2891) is a CIRCLE (border-radius 50%)
  /// with a 2px glass border over a `white@0.04` fill; before a pick the PWA
  /// shows a BLANK circle (a plain `#222` SVG), not a person glyph.
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
                  _smallButton(c, 'Choose photo', () => _pickImage(true)),
                  if (_avatarPath != null) ...[
                    const SizedBox(width: 8),
                    _smallButton(
                        c,
                        'Remove',
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

  /// `setupBannerPreview` (index.html:1304-1323) — preview wrap + Choose/Remove
  /// with a "No banner set" placeholder.
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
              ? Text('No banner set', style: TextStyle(color: c.textDim))
              : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _smallButton(c, 'Choose banner', () => _pickImage(false)),
            if (_bannerPath != null) ...[
              const SizedBox(width: 8),
              _smallButton(
                  c,
                  'Remove',
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
    // `.setup-invite-banner`: 1px secondary border, bg white/0.04, radius 8,
    // padding 10/12, 13px, centered, NO icon (styles-components.css:59-68).
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
