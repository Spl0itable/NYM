import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/nostr_controller.dart';
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

  String? _avatarPath;
  String? _bannerPath;
  bool _revealOpen = false;
  bool _revealed = false; // gate passed (held)
  bool _nsecVisible = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final id = ref.read(nostrControllerProvider).identity;
    final nym = id?.nym ?? '';
    // The nym is `name#suffix`; the input edits only the name part.
    final hash = nym.indexOf('#');
    _nick = TextEditingController(
      text: hash >= 0 ? nym.substring(0, hash) : nym,
    );
    _bio = TextEditingController();
    _lightning = TextEditingController();
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
          ),
        ),
      ),
    );
  }

  Widget _modalHeader(NymColors c) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Change Nym's Details",
                style: TextStyle(
                  color: c.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: c.textDim),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
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
        _label(c, 'Nickname'),
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
                  hintText: 'Enter new nym',
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
            Text(
              _suffix,
              style: TextStyle(
                color: c.textDim,
                fontFamily: 'monospace',
                fontSize: 13,
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
        _hint(
          c,
          'Your ephemeral pseudonym nickname for this session. The # and four '
          'characters identify this Nym\'s pubkey.',
        ),
      ],
    );
  }

  Widget _avatarGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Avatar'),
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64,
                height: 64,
                child: _avatarPath != null
                    ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
                    : NymIdenticon(seed: _pubkey, size: 64),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _smallButton(c, 'Change photo', () => _pickImage(true)),
                      if (_avatarPath != null) ...[
                        const SizedBox(width: 8),
                        _smallButton(
                          c,
                          'Remove',
                          () => setState(() => _avatarPath = null),
                          danger: true,
                        ),
                      ],
                    ],
                  ),
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
        _label(c, 'Banner'),
        Container(
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
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
              _smallButton(c, 'Remove', () => setState(() => _bannerPath = null),
                  danger: true),
            ],
          ],
        ),
      ],
    );
  }

  Widget _bioGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Bio'),
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
            hintText: 'Tell people a bit about yourself...',
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
        _hint(c, 'Short bio shown on your profile (max 150 characters)'),
      ],
    );
  }

  Widget _lightningGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Bitcoin Lightning Address'),
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
        _hint(c, 'Your Bitcoin Lightning address for receiving zaps'),
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
              Icon(
                _revealOpen
                    ? Icons.arrow_drop_down
                    : Icons.arrow_right,
                size: 18,
                color: c.textDim,
              ),
              Text(
                "Reveal this nym's private key",
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
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: c.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Your private key (nsec) is like a password for your '
                        'Nym identity. Anyone with access to it can post as you '
                        'and read your encrypted messages. Never share it.',
                        style: TextStyle(color: c.text, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!_revealed)
                  _HoldToReveal(
                    color: c.danger,
                    onRevealed: () => setState(() => _revealed = true),
                  )
                else
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
        ? 'No local private key (delegated signer)'
        : (_nsecVisible
            ? nsec
            : '•' * (nsec.length.clamp(8, 24)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('nsec (Nostr Private Key)',
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
              icon: Icon(_nsecVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18, color: c.textDim),
              onPressed: () => setState(() => _nsecVisible = !_nsecVisible),
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
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.primary),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Change'),
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

  Future<void> _pickImage(bool avatar) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      setState(() {
        if (avatar) {
          _avatarPath = file.path;
        } else {
          _bannerPath = file.path;
        }
      });
    } catch (_) {
      // Picker unavailable (e.g. tests / desktop) — silently ignore.
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    bool ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).saveProfile(
            name: _nick.text.trim().isEmpty ? null : _nick.text.trim(),
            about: _bio.text.trim(),
            // TODO(verify): upload the picked image to a host → URL. For now
            // pass the local path through; the engine treats empty as "no
            // change". A real implementation uploads to nostr.build / blossom.
            picture: _avatarPath,
            banner: _bannerPath,
            lud16:
                _lightning.text.trim().isEmpty ? null : _lightning.text.trim(),
          );
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(ok ? 'Profile updated' : 'Could not save profile')),
    );
  }
}

/// A press-and-hold confirmation that reveals the private key after a 1.2s hold
/// (mirrors the PWA's hold/confirm gate before showing the nsec).
class _HoldToReveal extends StatefulWidget {
  const _HoldToReveal({required this.color, required this.onRevealed});
  final Color color;
  final VoidCallback onRevealed;

  @override
  State<_HoldToReveal> createState() => _HoldToRevealState();
}

class _HoldToRevealState extends State<_HoldToReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onRevealed();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) => _ctrl.reverse(),
      onTapCancel: () => _ctrl.reverse(),
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.12),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: widget.color.withValues(alpha: 0.4)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => FractionallySizedBox(
                widthFactor: _ctrl.value,
                alignment: Alignment.centerLeft,
                child: Container(color: widget.color.withValues(alpha: 0.18)),
              ),
            ),
            Text(
              'Hold to reveal private key',
              style: TextStyle(color: widget.color, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
