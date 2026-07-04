import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/platform/deep_links.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import 'dev_nsec_modal.dart';
import 'modal_chrome.dart';
import 'nostr_login_modal.dart';

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

    // The ephemeral keypair was already booted in main(); publish the chosen
    // profile so the nym + avatar/banner/bio land on relays (saveToNostrProfile).
    // avatar/banner are the hosted URLs returned by `uploadImage`; if no image
    // was picked they're null, so nothing new is published for them.
    await controller.saveProfile(
      name: nym.isEmpty ? null : nym,
      about: bio.isEmpty ? null : bio,
      picture: avatar,
      banner: banner,
    );

    if (!mounted) return;
    widget.onComplete();
  }

  Future<void> _login() async {
    final result = await NostrLoginModal.open(context);
    if (!mounted) return;
    // A non-null result means a login method was chosen, PERSISTED, and adopted:
    //  * nsec — the modal awaited `NostrController.loginWithNsec`, which
    //    persists the key, re-boots under the new pubkey, and bumps the boot
    //    epoch (remounting the gate onto the shell). `onComplete()` here is
    //    idempotent with that remount.
    //  * NIP-46 — `finishNostrConnect` persisted the session; `onComplete()`
    //    advances the gate so the shell shows (restored fully on next boot).
    if (result != null) widget.onComplete();
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
                    // (The "nymchat" wordmark was removed per request; the
                    // "Login with nsec…" link below still carries the login tap.)
                    if (invite != null) ...[
                      _InviteBanner(text: invite, c: c),
                      const SizedBox(height: 16),
                    ],
                    // `.nm-h-50`: text-dim 13px underline (offset 3).
                    GestureDetector(
                      onTap: _login,
                      child: Text(
                        'Login with nsec private key or extension? Click here',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: c.textDim,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
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
                    // (The PWA's `.nm-h-52` "NOTE: Nymchat is bridged with…"
                    // callout is intentionally absent in the native app —
                    // product decision. Bio `.form-group` margin-bottom 20 is
                    // the gap to the actions.)
                    const SizedBox(height: 20),
                    // `.send-btn` (translucent primary pill), h42.
                    Padding(
                      key: const Key('setupEnterBtn'),
                      padding: EdgeInsets.zero,
                      child: ModalChrome.sendButton(
                        c,
                        'Enter',
                        _busy ? null : _enter,
                        fullWidth: true,
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
                    const SizedBox(height: 12),
                    // `.setup-modal-content>span` footer (index.html:1337-1340):
                    // centered `.nm-dim` line at the inherited 16px default;
                    // "Terms of Service"/"Privacy Policy" are `.nm-secondary`
                    // anchors (secondary color, browser-default underline)
                    // opening /static/tos.html / /static/pp.html externally.
                    Text.rich(
                      TextSpan(
                        style: TextStyle(color: c.textDim, fontSize: 16),
                        children: [
                          const TextSpan(text: 'By entering, you agree to our '),
                          TextSpan(
                            text: 'Terms of Service',
                            style: TextStyle(
                              color: c.secondary,
                              decoration: TextDecoration.underline,
                              decorationColor: c.secondary,
                            ),
                            recognizer: _linkTap(
                                'https://web.nymchat.app/static/tos.html'),
                          ),
                          const TextSpan(text: ' and '),
                          TextSpan(
                            text: 'Privacy Policy',
                            style: TextStyle(
                              color: c.secondary,
                              decoration: TextDecoration.underline,
                              decorationColor: c.secondary,
                            ),
                            recognizer: _linkTap(
                                'https://web.nymchat.app/static/pp.html'),
                          ),
                          const TextSpan(text: '.'),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
            ),
          ),
        ),
      ),
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
  }) {
    final field = TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      onChanged: showCounter ? (_) => setState(() {}) : null,
      inputFormatters:
          maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
      style: TextStyle(color: c.textBright, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 15),
        counterText: '',
        filled: true,
        // `.form-input` fill white/0.05.
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.glassBorder),
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

  /// `setupAvatarPreview` (index.html:1285-1302) — 80×80 preview + Choose/Remove.
  Widget _avatarPicker(NymColors c) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 80,
            height: 80,
            color: c.bg,
            child: _avatarPath != null
                ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
                : Icon(Icons.person_outline, color: c.textDim, size: 36),
          ),
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
