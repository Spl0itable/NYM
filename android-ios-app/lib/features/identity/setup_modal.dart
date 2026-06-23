import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import 'nostr_login_modal.dart';

/// First-run setup screen mirroring `#setupModal` (index.html 1257–1346).
///
/// The user picks an optional nickname / avatar / banner / bio and taps
/// **Enter** to create an ephemeral identity, or opens the Nostr login. On
/// success [onComplete] fires so the [BootGate] proceeds to the shell.
///
/// Avatar/banner here are URL inputs (the Flutter port has no file picker in
/// this flow yet — TODO(verify): the PWA uploads a file and hosts it; we accept
/// an image URL and persist it the same way to `nym_avatar_url`/`nym_banner_url`).
class SetupModal extends ConsumerStatefulWidget {
  const SetupModal({super.key, required this.onComplete});

  /// Called after the identity is created / login starts so the gate advances.
  final VoidCallback onComplete;

  @override
  ConsumerState<SetupModal> createState() => _SetupModalState();
}

class _SetupModalState extends ConsumerState<SetupModal> {
  final _nymCtl = TextEditingController();
  final _avatarCtl = TextEditingController();
  final _bannerCtl = TextEditingController();
  final _bioCtl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nymCtl.dispose();
    _avatarCtl.dispose();
    _bannerCtl.dispose();
    _bioCtl.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    if (_busy) return;
    setState(() => _busy = true);

    final kv = ref.read(keyValueStoreProvider);
    final controller = ref.read(nostrControllerProvider);
    final nym = _nymCtl.text.trim();

    // Persist auto-ephemeral so future boots skip the modal (initializeNym).
    await kv.setBool(StorageKeys.autoEphemeral, true);
    if (nym.isNotEmpty) {
      await kv.setString(StorageKeys.autoEphemeralNick, nym);
      await kv.setString(StorageKeys.customNick, nym);
    }
    final bio = _bioCtl.text.trim();
    final avatar = _avatarCtl.text.trim();
    final banner = _bannerCtl.text.trim();
    if (bio.isNotEmpty) await kv.setString(StorageKeys.bio, bio);
    if (avatar.isNotEmpty) await kv.setString(StorageKeys.avatarUrl, avatar);
    if (banner.isNotEmpty) await kv.setString(StorageKeys.bannerUrl, banner);

    // The ephemeral keypair was already booted in main(); publish the chosen
    // profile so the nym + avatar/banner/bio land on relays (saveToNostrProfile).
    await controller.saveProfile(
      name: nym.isEmpty ? null : nym,
      about: bio.isEmpty ? null : bio,
      picture: avatar.isEmpty ? null : avatar,
      banner: banner.isEmpty ? null : banner,
    );

    if (!mounted) return;
    widget.onComplete();
  }

  Future<void> _login() async {
    final result = await NostrLoginModal.open(context);
    if (!mounted) return;
    // A non-null result means a login method was chosen + persisted.
    if (result != null) widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final invite = _inviteBannerText();

    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: c.bgSecondary,
                  borderRadius: NymRadius.rxl,
                  border: Border.all(color: c.glassBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ASCII "nymchat" logo doubles as a login affordance.
                    GestureDetector(
                      onTap: _login,
                      child: Text(
                        'nymchat',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.primary,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (invite != null) ...[
                      _InviteBanner(text: invite, c: c),
                      const SizedBox(height: 16),
                    ],
                    GestureDetector(
                      onTap: _login,
                      child: Text(
                        'Login with nsec private key or extension? Click here',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.secondary,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: c.secondary,
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
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Your ephemeral pseudonym nickname for this session',
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    _label(c, 'Choose Your Avatar', optional: true),
                    const SizedBox(height: 6),
                    _field(c,
                        controller: _avatarCtl, hint: 'Image URL (optional)'),
                    const SizedBox(height: 16),
                    _label(c, 'Choose Your Banner', optional: true),
                    const SizedBox(height: 6),
                    _field(c,
                        controller: _bannerCtl, hint: 'Banner URL (optional)'),
                    const SizedBox(height: 16),
                    _label(c, 'Bio', optional: true),
                    const SizedBox(height: 6),
                    _field(
                      c,
                      controller: _bioCtl,
                      hint: 'Tell people a bit about yourself...',
                      maxLength: 150,
                      maxLines: 3,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'NOTE: Nymchat is bridged with Bitchat geohash channels '
                      'and the messages are public and ephemeral; sent across '
                      'the Nostr relay network. Only private messages and group '
                      'chats are end-to-end encrypted.',
                      style: TextStyle(
                          color: c.textDim, fontSize: 11, height: 1.4),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 46,
                      child: FilledButton(
                        key: const Key('setupEnterBtn'),
                        onPressed: _busy ? null : _enter,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.primary,
                          foregroundColor: c.bg,
                          shape: RoundedRectangleBorder(
                              borderRadius: NymRadius.rsm),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Enter',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 15)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'By entering, you agree to our Terms of Service and '
                      'Privacy Policy.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mirrors updateSetupInviteBanner: shows an invite line when a pending
  /// group-invite token is present (`nym_pending_group_invite`).
  String? _inviteBannerText() {
    final kv = ref.read(keyValueStoreProvider);
    final token = kv.getString(StorageKeys.pendingGroupInvite);
    if (token == null || token.isEmpty) return null;
    // TODO(verify): decode the group name from the token (parseGroupInviteInput).
    // We surface the generic copy until the token decoder is ported here.
    return 'You\'ve been invited to join a group. Pick a nym or log in '
        'below to continue.';
  }

  Widget _label(NymColors c, String text, {bool optional = false}) {
    return RichText(
      text: TextSpan(
        text: text,
        style: TextStyle(
            color: c.textBright, fontSize: 13, fontWeight: FontWeight.w600),
        children: [
          if (optional)
            TextSpan(
              text: '  (optional)',
              style: TextStyle(
                  color: c.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.normal),
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
  }) {
    return TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      inputFormatters:
          maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
      style: TextStyle(color: c.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 14),
        counterText: '',
        filled: true,
        fillColor: c.bg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.primary),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.primaryA(0.10),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.primaryA(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.group, size: 18, color: c.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(color: c.textBright, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
