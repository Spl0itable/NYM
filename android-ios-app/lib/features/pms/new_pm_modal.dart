import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../../services/platform/deep_links.dart' show parseGroupInvite;
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';

/// A picked recipient: pubkey (64-hex) + a display nym.
class PmRecipient {
  const PmRecipient(this.pubkey, this.nym);
  final String pubkey;
  final String nym;
}

/// Resolves a recipient token to a 64-hex pubkey: accepts a bare 64-hex pubkey,
/// an `npub1…`, or a `nym#suffix` matched against [users]. Returns null if it
/// can't be resolved. Mirrors the PWA's `onNewPMRecipientInput` /
/// `resolvePubkeyFromNym` paste handling (pms.js).
String? resolveRecipientPubkey(String input, Map<String, User> users) {
  final raw = input.trim().replaceFirst(RegExp(r'^@'), '');
  if (raw.isEmpty) return null;

  // Direct hex pubkey.
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw)) return raw.toLowerCase();

  // npub.
  if (RegExp(r'^npub1', caseSensitive: false).hasMatch(raw)) {
    try {
      return decodeNpub(raw.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  // Nym match (case-insensitive, with or without #suffix).
  final query = raw.toLowerCase();
  for (final u in users.values) {
    if (u.nym.toLowerCase() == query) return u.pubkey;
    if (stripPubkeySuffix(u.nym).toLowerCase() == query) return u.pubkey;
  }
  return null;
}

/// `#newPMModal` — "New Message" / "New Group". A recipient picker (nym /
/// pubkey / npub) yields chips; one recipient → `startPM`, two or more →
/// `createGroup` (with an optional group name). Mirrors pms.js
/// `openNewPMModal` / `startNewPMFromModal`.
class NewPmModal extends ConsumerStatefulWidget {
  const NewPmModal({super.key});

  static Future<void> open(BuildContext context) {
    // `.modal` barrier: glass `rgba(0,0,0,0.7)` (styles-chat.css:1974);
    // `body.solid-ui .modal { rgba(0,0,0,0.75) }` and
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1636).
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: !solidUi
          ? Colors.black.withValues(alpha: 0.7)
          : isLight
              ? const Color(0x73000000) // black @ 0.45
              : const Color(0xBF000000), // black @ 0.75
      builder: (_) => const NewPmModal(),
    );
  }

  @override
  ConsumerState<NewPmModal> createState() => _NewPmModalState();
}

class _NewPmModalState extends ConsumerState<NewPmModal> {
  final _recipientController = TextEditingController();
  final _recipientFocus = FocusNode();
  // A non-focusable key sentinel around the recipient input so Backspace on an
  // empty field can pop the last chip without stealing the field's own focus.
  final _recipientKeyFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  final _groupNameController = TextEditingController();
  final _groupDescController = TextEditingController();
  final _messageController = TextEditingController();
  final List<PmRecipient> _recipients = [];

  /// Group-creation extras (revealed for ≥2 recipients, index.html:319-347).
  /// The PWA uploads the picked file at pick-time and keeps the HOSTED URL in
  /// `_newGroupAvatar`/`_newGroupBanner` (pms.js `_pickNewGroupMedia`), passing
  /// those URLs into `createGroup`. We mirror that: these hold hosted URLs (NOT
  /// local file paths), so kind-0/group metadata never carries a `file://` path.
  String? _groupAvatarUrl;
  String? _groupBannerUrl;
  bool _allowInvites = true; // `newGroupAllowInvites` checked by default

  /// `.new-group-progress` upload affordance state (index.html:329-334):
  /// `_uploading` toggles the bar, `_uploadLabel` is the "Uploading group
  /// avatar…"/"Uploading group banner…" line, `_uploadProgress` drives the
  /// `.progress-fill` width (15%→55%→100%, users.js `_uploadFileWithProgress`).
  bool _uploading = false;
  String _uploadLabel = tr('Uploading…');
  double _uploadProgress = 0;
  /// Last upload error surfaced under the media section (PWA `displaySystemMessage`
  /// "Failed to upload image: …"); cleared on the next pick.
  String? _uploadError;

  bool get _groupMode => _recipients.length >= 2;

  @override
  void initState() {
    super.initState();
    _recipientController.addListener(_onRecipientInput);
    _recipientFocus.addListener(
        () => setState(() => _recipientFocused = _recipientFocus.hasFocus));
  }

  @override
  void dispose() {
    _recipientController.dispose();
    _recipientFocus.dispose();
    _recipientKeyFocus.dispose();
    _groupNameController.dispose();
    _groupDescController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _onRecipientInput() => setState(() {}); // refresh suggestions live

  /// True while the recipient input has focus (drives the `.pm-recipient-box`
  /// `:focus-within` glow).
  bool _recipientFocused = false;

  /// Whether the current suggestion list is the empty-query "recently seen"
  /// list (which gets a header) vs. a live filter (pms.js `_showRecentlySeen`).
  bool get _isRecentlySeen => _recipientController.text.trim().isEmpty;

  /// Live recipient suggestions (`onNewPMRecipientInput` / pms.js
  /// `_showRecentlySeenSuggestions`): known users (minus self + already-picked)
  /// filtered by the typed nym, sorted by `lastSeen` desc, capped at 10. On
  /// empty input this becomes the "recently seen users" list.
  List<User> get _suggestions {
    final raw = _recipientController.text.trim().replaceFirst(RegExp(r'^@'), '');
    final query = raw.toLowerCase();
    final self = ref.read(appStateProvider).selfPubkey;
    final picked = _recipients.map((r) => r.pubkey).toSet();
    final controller = ref.read(nostrControllerProvider);
    final out = <User>[];
    for (final u in ref.read(usersProvider).values) {
      if (u.pubkey == self || picked.contains(u.pubkey)) continue;
      // Nymbot is never suggested (pms.js:3477 `if (this.isVerifiedBot(pubkey))
      // return;`) — the bot is reachable via its sidebar row / direct paste,
      // not via the recently-seen list.
      if (controller.isVerifiedBot(u.pubkey)) continue;
      if (query.isEmpty ||
          u.nym.toLowerCase().contains(query) ||
          stripPubkeySuffix(u.nym).toLowerCase().contains(query)) {
        out.add(u);
      }
    }
    out.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return out.take(10).toList();
  }

  /// Inline guard line under the recipient box, standing in for the PWA's
  /// `displaySystemMessage` (which lands in the chat behind the modal).
  /// Cleared on the next successful add/remove.
  String? _recipientError;

  void _addRecipient(String pubkey, String nym) {
    if (pubkey == ref.read(appStateProvider).selfPubkey) return;
    if (_recipients.any((r) => r.pubkey == pubkey)) {
      _recipientController.clear();
      return;
    }
    // Nymbot can be messaged 1:1 but never added to a group chat — blocked in
    // both directions (bot-after-others and others-after-bot), pms.js
    // `addNewPMRecipient` (:3628-3636). The PWA keeps the input as-is on a
    // guard trip, so don't clear the field here.
    final controller = ref.read(nostrControllerProvider);
    final isBot = controller.isVerifiedBot(pubkey);
    if ((isBot && _recipients.isNotEmpty) ||
        (!isBot &&
            _recipients.any((r) => controller.isVerifiedBot(r.pubkey)))) {
      setState(() => _recipientError =
          tr('Nymbot can only be messaged 1:1, not added to a group chat.'));
      return;
    }
    setState(() {
      _recipientError = null;
      _recipients.add(PmRecipient(pubkey, nym));
      _recipientController.clear();
    });
  }

  void _addFromInput() {
    final users = ref.read(usersProvider);
    final pk = resolveRecipientPubkey(_recipientController.text, users);
    if (pk == null) return;
    // Unknown-pubkey fallback is `nym#xxxx` (users.js:1085), never 'anon'.
    final nym = users[pk]?.nym ?? getNymFromPubkey('nym', pk);
    _addRecipient(pk, nym);
  }

  void _remove(String pubkey) {
    setState(() {
      _recipientError = null;
      _recipients.removeWhere((r) => r.pubkey == pubkey);
    });
  }

  /// Backspace on an empty input removes the last chip (pms.js
  /// `onNewPMRecipientKeydown`).
  void _removeLast() {
    if (_recipientController.text.isNotEmpty || _recipients.isEmpty) return;
    setState(() {
      _recipientError = null;
      _recipients.removeLast();
    });
  }

  /// Per-surface upload caps, mirroring the PWA nick-edit avatar/banner guards
  /// (`handleNickEditAvatarSelect` rejects >5MB, `handleNickEditBannerSelect`
  /// >10MB). Avatar 5MB, banner 10MB.
  static const int _avatarMaxBytes = 5 * 1024 * 1024;
  static const int _bannerMaxBytes = 10 * 1024 * 1024;

  /// Best-effort MIME from the picked file's extension (BUD-02 `Content-Type`),
  /// mirroring `_contentTypeFor` in group_context_menu_panel.dart.
  static String _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Pick a group avatar/banner, then UPLOAD it (Blossom) before publishing —
  /// `createGroup` must receive a hosted URL, never a `file://` path. Mirrors the
  /// PWA `_pickNewGroupMedia` → `_uploadFileWithProgress` → store URL flow, with
  /// the `.new-group-progress` affordance shown during the upload and an error
  /// surfaced (no bad image stored) on failure. Caps: avatar 5MB / banner 10MB.
  Future<void> _pickGroupImage(bool avatar) async {
    final Uint8List bytes;
    final String contentType;
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      bytes = await file.readAsBytes();
      contentType = _contentTypeFor(file.path);
    } catch (_) {
      // Picker unavailable (tests / desktop) — nothing to do.
      return;
    }

    // Enforce the per-surface size cap before uploading (PWA rejects oversize
    // files with a system message and aborts the upload).
    final cap = avatar ? _avatarMaxBytes : _bannerMaxBytes;
    if (bytes.length > cap) {
      final capMb = avatar ? 5 : 10;
      final actualMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      setState(() => _uploadError = tr(
          '{label} must be under {cap}MB (this is {actual}MB).', {
        'label': avatar ? tr('Avatar') : tr('Banner'),
        'cap': capMb,
        'actual': actualMb,
      }));
      return;
    }

    setState(() {
      _uploadError = null;
      _uploading = true;
      _uploadProgress = 0.15; // PWA seeds the fill at 15%.
      _uploadLabel =
          avatar ? tr('Uploading group avatar…') : tr('Uploading group banner…');
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
      // Surface an error and DON'T publish a bad image (PWA shows a system
      // message "Failed to upload image: …" and keeps the prior media).
      setState(() {
        _uploading = false;
        _uploadProgress = 0;
        _uploadError = tr('Failed to upload image. Try again.');
      });
      return;
    }

    setState(() {
      _uploading = false;
      _uploadProgress = 1;
      if (avatar) {
        _groupAvatarUrl = url;
      } else {
        _groupBannerUrl = url;
      }
    });
  }

  Future<void> _start() async {
    if (_recipients.isEmpty) return;
    final controller = ref.read(nostrControllerProvider);
    if (_recipients.length == 1) {
      final r = _recipients.first;
      controller.startPM(r.pubkey, nym: r.nym);
    } else {
      final name = _groupNameController.text.trim().isNotEmpty
          ? _groupNameController.text.trim()
          : _recipients.map((r) => stripPubkeySuffix(r.nym)).take(3).join(', ');
      final description = _groupDescController.text.trim();
      // Thread the group-creation extras the modal collected into createGroup
      // (groups.js `createGroup(name, members, { avatar, banner, description,
      // allowMemberInvites })`). avatar/banner are HOSTED URLs (uploaded at
      // pick-time via `_pickGroupImage`), never local paths — matching the PWA,
      // which passes `_newGroupAvatar`/`_newGroupBanner` (upload URLs).
      await controller.createGroup(
        name,
        _recipients.map((r) => r.pubkey).toList(),
        avatar: _groupAvatarUrl,
        banner: _groupBannerUrl,
        description: description.isNotEmpty ? description : null,
        allowMemberInvites: _allowInvites,
      );
    }
    // Send the optional initial message into the just-opened conversation
    // (`pmInitialMessage` → first DM/group send, index.html:348-351). After
    // startPM/createGroup the active view IS the new conversation.
    final initial = _messageController.text.trim();
    if (initial.isNotEmpty) {
      await controller.sendCurrent(initial);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final title = _groupMode ? tr('New Group') : tr('New Message');

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        // `.modal-content` — max-width 440 (`.pm-modal-content` is not set; the
        // PWA modal-content defaults apply, narrowed to 440 by the brief).
        constraints: const BoxConstraints(maxWidth: 440),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            // radius 24 + shadow-lg/glow/ring stack.
            borderRadius: NymRadius.rxl,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
              BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
              BoxShadow(color: Colors.white.withValues(alpha: 0.05), spreadRadius: 1),
            ],
          ),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // `.modal-header` — 22px primary UPPERCASE ls1.5 w700, bottom
                  // rule, padding-bottom 14, margin-bottom 24. (32px padding.)
                  Container(
                    margin: const EdgeInsets.fromLTRB(32, 32, 32, 24),
                    padding: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.glassBorder)),
                    ),
                    child: Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _label(c, tr('To')),
                          const SizedBox(height: 8),
                          // `.pm-recipient-box` — chips + inline input in one box.
                          _recipientBox(c),
                          // "Nymbot can only be messaged 1:1…" guard line (the
                          // PWA's displaySystemMessage lands in the chat behind
                          // the modal; here it sits inline under the box).
                          if (_recipientError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _recipientError!,
                                style: TextStyle(color: c.danger, fontSize: 11),
                              ),
                            ),
                          _suggestionsList(c),
                      if (_groupMode) ...[
                        const SizedBox(height: 16),
                        _label(c, tr('Group Name'), optional: true),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupNameController,
                          maxLength: 40,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: c.textBright, fontSize: 15),
                          decoration: _inputDecoration(
                            c,
                            tr('Enter a group name...'),
                          ).copyWith(counterText: ''),
                        ),
                        // `pmGroupNameCharCount 0/40` (index.html:317).
                        _charCount(c, _groupNameController.text.length, 40),
                        const SizedBox(height: 16),
                        _groupMediaSection(c),
                        const SizedBox(height: 16),
                        _label(c, tr('Description'), optional: true),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupDescController,
                          maxLength: 150,
                          maxLines: 3,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: c.textBright, fontSize: 15),
                          decoration: _inputDecoration(
                            c,
                            tr("What's this group about?"),
                          ).copyWith(counterText: ''),
                        ),
                        // `newGroupDescCharCount 0/150` (index.html:339).
                        _charCount(c, _groupDescController.text.length, 150),
                        const SizedBox(height: 12),
                        _allowInvitesRow(c),
                      ],
                      // `pmInitialMessage` — "Message (optional)" (index.html:348).
                      const SizedBox(height: 16),
                      _label(c, tr('Message'), optional: true),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _messageController,
                        maxLines: 3,
                        style: TextStyle(color: c.textBright, fontSize: 15),
                        decoration:
                            _inputDecoration(c, tr('Start the conversation...')),
                      ),
                        ],
                      ),
                    ),
                  ),
                  // `.modal-actions` — center, gap 10.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _cancelBtn(c),
                        const SizedBox(width: 10),
                        _startBtn(c),
                      ],
                    ),
                  ),
                ],
              ),
              // `.modal-close` — 32px circular glass chip at top:14/right:14.
              Positioned(top: 14, right: 14, child: _closeButton(c)),
            ],
          ),
        ),
      ),
    );
  }

  /// `.modal-close` — 32×32 circular glass chip with a 16px ✕ (text-dim).
  Widget _closeButton(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.glassBorder),
        ),
        // `.modal-close` is a literal "✕" char in the PWA — styled text.
        child: Text('✕',
            style: TextStyle(color: c.textDim, fontSize: 16, height: 1)),
      ),
    );
  }

  /// `.icon-btn` Cancel — bg white/0.05, glass border, radius 8, color --text,
  /// UPPERCASE 12px w500 ls0.8, padding 7/14.
  Widget _cancelBtn(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxs,
        ),
        child: Text(
          tr('Cancel').toUpperCase(),
          style: TextStyle(
            color: c.text,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  /// `.send-btn` Start/Create — translucent primary outline pill (bg
  /// primary/0.1, border primary/0.3, text primary, radius 12, h42, padding
  /// 22/10, UPPERCASE 12px w600 ls1.5; disabled opacity 0.35).
  Widget _startBtn(NymColors c) {
    final enabled = _recipients.isNotEmpty;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? _start : null,
        borderRadius: NymRadius.rsm,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.primaryA(0.1),
            border: Border.all(color: c.primaryA(0.3)),
            borderRadius: NymRadius.rsm,
          ),
          child: Text(
            (_groupMode ? tr('Create') : tr('Start')).toUpperCase(),
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  /// `.form-label` — 11px UPPERCASE ls1.2 w600 text-dim, with an optional
  /// trailing `.nm-h-2` "(optional)" span (lowercase, w400, ls0). Pass the
  /// label text WITHOUT "(optional)"; set [optional] to append the span.
  Widget _label(NymColors c, String text, {bool optional = false}) => Text.rich(
        TextSpan(
          text: text.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
          children: optional
              ? [
                  TextSpan(
                    text: tr(' (optional)'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                    ),
                  ),
                ]
              : null,
        ),
      );

  /// The unified `.pm-recipient-box`: chips wrap inline with a borderless input
  /// inside one bordered box, with the `:focus-within` glow.
  Widget _recipientBox(NymColors c) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rsm,
        boxShadow: _recipientFocused
            ? [BoxShadow(color: c.primaryA(0.06), spreadRadius: 3)]
            : null,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 42),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _recipientFocused ? 0.07 : 0.05),
          border: Border.all(
            color: _recipientFocused ? c.primaryA(0.3) : c.glassBorder,
          ),
          borderRadius: NymRadius.rsm,
        ),
        child: Wrap(
          spacing: 5,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final r in _recipients)
              _Chip(
                base: stripPubkeySuffix(r.nym),
                suffix: getPubkeySuffix(r.pubkey),
                onRemove: () => _remove(r.pubkey),
              ),
            // Borderless inline input (`.pm-recipient-input`): 13px, --text.
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
              child: IntrinsicWidth(
                child: Focus(
                  focusNode: _recipientKeyFocus,
                  onKeyEvent: (_, e) {
                    if (e is KeyDownEvent &&
                        e.logicalKey == LogicalKeyboardKey.backspace) {
                      _removeLast();
                    }
                    // Never consume — let the TextField handle the key itself.
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _recipientController,
                    focusNode: _recipientFocus,
                    autofocus: true, // PWA focuses pmRecipientInput on open
                    onSubmitted: (_) => _addFromInput(),
                    style: TextStyle(color: c.text, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: _recipients.isEmpty
                          ? tr('Search nym or paste pubkey...')
                          : null,
                      hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(vertical: 2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.input-char-count` — base text-dim @0.6 opacity, warning #f59e0b at 80%,
  /// limit (--danger) at 100% (updateFieldCharCount).
  Widget _charCount(NymColors c, int len, int max) {
    final Color color;
    if (len >= max) {
      color = c.danger;
    } else if (len >= max * 0.8) {
      color = const Color(0xFFF59E0B);
    } else {
      color = c.textDim.withValues(alpha: 0.6);
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('$len/$max', style: TextStyle(fontSize: 11, color: color)),
      ),
    );
  }

  /// The trimmed recipient input with a leading `@` stripped (the PWA parses the
  /// raw value for invites but lower-cases for the pubkey/nym checks).
  String get _rawInput => _recipientController.text.trim().replaceFirst(RegExp(r'^@'), '');

  /// A group-invite token if the current input is a `#gjoin=…` link/token,
  /// decoded via the EXISTING `parseGroupInvite` (deep_links.dart). The PWA's
  /// `onNewPMRecipientInput` tries `parseGroupInviteInput(value.trim())` first
  /// (case-sensitive — the base64url token must never be lower-cased).
  GroupInviteToken? get _inviteToken {
    if (_rawInput.isEmpty) return null;
    return parseGroupInvite(_recipientController.text.trim());
  }

  /// If the input is a bare 64-hex pubkey or an `npub1…`, the resolved pubkey
  /// for the single direct-pubkey suggestion row — unless it's self or already
  /// picked (the PWA hides the row in those cases). Returns null otherwise.
  /// Mirrors `onNewPMRecipientInput`'s `/^[0-9a-f]{64}$/i` branch, extended to
  /// `npub1…` per the brief (submit already resolves both via
  /// `resolveRecipientPubkey`).
  String? get _directPubkey {
    final raw = _rawInput;
    if (raw.isEmpty) return null;
    final isHex = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw);
    final isNpub = RegExp(r'^npub1', caseSensitive: false).hasMatch(raw);
    if (!isHex && !isNpub) return null;
    final pk = resolveRecipientPubkey(raw, ref.read(usersProvider));
    if (pk == null) return null;
    if (pk == ref.read(appStateProvider).selfPubkey) return null;
    if (_recipients.any((r) => r.pubkey == pk)) return null;
    return pk;
  }

  /// `.pm-suggestions` — bg-secondary box, radius 12, mt4, `0 6px 20px
  /// rgba(0,0,0,0.4)` shadow, max-height 200. Priority mirrors the PWA
  /// `onNewPMRecipientInput`: a `#gjoin=…` invite → a single "Join group" row;
  /// else a bare 64-hex/npub → a single direct-pubkey row; else the nym
  /// substring list (the "recently seen users" set under a header on empty).
  Widget _suggestionsList(NymColors c) {
    // 1) Group-invite link/token paste → a single "Join group" row.
    final invite = _inviteToken;
    if (invite != null) {
      return _suggestionsBox(c, [_inviteSuggestionItem(c, invite)]);
    }

    // 2) Direct 64-hex / npub paste → a single direct-pubkey row.
    final directPk = _directPubkey;
    if (directPk != null) {
      final user = ref.read(usersProvider)[directPk];
      // Unknown-pubkey fallback is `nym#xxxx` (users.js:1085), never 'anon'.
      final nym = user?.nym ?? getNymFromPubkey('nym', directPk);
      return _suggestionsBox(c, [
        _suggestionItem(
          c,
          pubkey: directPk,
          nym: nym,
          imageUrl: user?.profile?.picture,
        ),
      ]);
    }

    // 3) Known-user substring list (recently-seen on empty input).
    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return _suggestionsBox(c, [
      // `.pm-suggestion-header` — only for the empty-query recently-seen
      // list (11px UPPERCASE ls0.5 text-dim + bottom hairline).
      if (_isRecentlySeen)
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
          ),
          child: Text(
            tr('Recently seen users').toUpperCase(),
            style: TextStyle(
              color: c.textDim,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
        ),
      for (final u in suggestions)
        _suggestionItem(
          c,
          pubkey: u.pubkey,
          nym: u.nym,
          imageUrl: u.profile?.picture,
        ),
    ]);
  }

  /// The shared `.pm-suggestions` chrome wrapping a set of rows.
  Widget _suggestionsBox(NymColors c, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: c.bgSecondary,
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: children,
      ),
    );
  }

  /// `_buildGroupInviteSuggestionItem` (pms.js) — a `.pm-suggestion-item` with
  /// the group glyph, the invite's (sanitized) name (or "Group"), and a
  /// "Join group" suffix. On tap: close the modal, then join via the EXISTING
  /// `joinGroupViaInvite(token)` (no fakes).
  Widget _inviteSuggestionItem(NymColors c, GroupInviteToken token) {
    final name = _sanitizeGroupName(token.name);
    return InkWell(
      onTap: () {
        Navigator.of(context).maybePop();
        ref.read(nostrControllerProvider).joinGroupViaInvite(token);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // `.group-suggestion-ico` — 26px circle holding the people glyph
            // (primary), standing in for the avatar slot.
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
                border: Border.all(color: c.glassBorder),
              ),
              // `.group-suggestion-ico` (pms.js:3545) — the 3-figure group glyph.
              child: NymSvgIcon(NymIcons.groupGlyph, color: c.primary, size: 16),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name.isEmpty ? tr('Group') : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            // `.pm-suggestion-suffix` — "Join group" (11px text-dim).
            Text(
              tr('Join group'),
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  /// `sanitizeGroupName` (groups.js) — collapse control chars/whitespace, trim,
  /// cap at 40. Matches the PWA's invite-name sanitiser.
  static String _sanitizeGroupName(String name) {
    final s = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.length > 40 ? s.substring(0, 40) : s;
  }

  /// `.pm-suggestion-item` — avatar 26 + base nym (13px --text) + `#suffix`
  /// (11px text-dim), padding 8/12, gap 6. Used for both the known-user list and
  /// the single direct-pubkey row (`_buildPMSuggestionItem`).
  Widget _suggestionItem(
    NymColors c, {
    required String pubkey,
    required String nym,
    String? imageUrl,
  }) {
    final base = stripPubkeySuffix(nym);
    final suffix = getPubkeySuffix(pubkey);
    return InkWell(
      onTap: () => _addRecipient(pubkey, nym),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            NymAvatar(
              seed: pubkey,
              size: 26,
              imageUrl: imageUrl,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                base,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '#$suffix',
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  /// `newGroupMediaGroup` (index.html:319-335) — `.new-group-media`: a 96px
  /// gradient banner with the 56px circular avatar overhanging its bottom-left
  /// (`left:12; bottom:-22`), so the section reserves a 30px bottom margin.
  Widget _groupMediaSection(NymColors c) {
    final hasBanner = _groupBannerUrl != null;
    final hasAvatar = _groupAvatarUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(c, tr('Group Avatar & Banner'), optional: true),
        const SizedBox(height: 4), // `.new-group-media` margin-top
        Padding(
          padding: const EdgeInsets.only(bottom: 30), // clear the -22 overhang
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // `.new-group-banner` — 96px, radius 12, 135° primary→secondary
              // gradient (hidden when an image is set), glass border. Tap is
              // ignored while an upload is in flight (the PWA disables re-pick).
              GestureDetector(
                onTap: _uploading ? null : () => _pickGroupImage(false),
                child: Container(
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: NymRadius.rsm,
                    border: Border.all(color: c.glassBorder),
                    gradient: hasBanner
                        ? null
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [c.primaryA(0.4), c.secondaryA(0.4)],
                          ),
                    image: hasBanner
                        ? DecorationImage(
                            // Route the uploaded banner through the media proxy
                            // (hides the user's IP from the image host, mirrors
                            // the PWA's getProxiedMediaUrl).
                            image: NetworkImage(proxiedAvatarUrl(_groupBannerUrl)!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: hasBanner
                      ? null
                      // `.new-group-media-hint` — dark pill (12px white).
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.4),
                            borderRadius: NymRadius.rsm,
                          ),
                          child: Text(tr('Add banner'),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ),
                ),
              ),
              // `.new-group-avatar` — 56px circle, left:12, bottom:-22, bg
              // bg-secondary, 3px bg-primary border, people icon (primary).
              Positioned(
                left: 12,
                bottom: -22,
                child: GestureDetector(
                  onTap: _uploading ? null : () => _pickGroupImage(true),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.bgSecondary,
                      border: Border.all(color: c.bg, width: 3),
                      image: hasAvatar
                          ? DecorationImage(
                              // Proxy the uploaded avatar (IP-hiding parity with
                              // the PWA's getProxiedMediaUrl).
                              image: NetworkImage(proxiedAvatarUrl(_groupAvatarUrl)!),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: hasAvatar
                        ? null
                        // `#newGroupAvatarPreview` placeholder (index.html:326) —
                        // the 3-figure group glyph.
                        : NymSvgIcon(NymIcons.groupGlyph,
                            color: c.primary, size: 26),
                  ),
                ),
              ),
            ],
          ),
        ),
        // `.new-group-progress` (index.html:329-334) — the upload affordance:
        // a label + `.progress-bar`/`.progress-fill`, shown only during upload
        // (`position:static; margin:6px 0 0`).
        if (_uploading) _uploadProgressBar(c),
        // Upload failure line (PWA `displaySystemMessage` "Failed to upload
        // image: …"). Cleared on the next pick.
        if (_uploadError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _uploadError!,
              style: TextStyle(color: c.danger, fontSize: 11),
            ),
          ),
      ],
    );
  }

  /// `.new-group-progress` / `.upload-progress` body: an "Uploading …" label
  /// over the `.progress-bar` (height 6, bg white/0.05, radius 10) with the
  /// `.progress-fill` (90° primary→secondary gradient, radius 10) at the live
  /// progress width.
  Widget _uploadProgressBar(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 6), // `.new-group-progress` margin
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _uploadLabel,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
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
                      borderRadius:
                          const BorderRadius.all(Radius.circular(10)),
                      gradient: LinearGradient(
                        colors: [c.primary, c.secondary],
                      ),
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

  /// `newGroupAllowInvites` (index.html:341-347) — checked by default; off ⇒
  /// only the owner can add members.
  Widget _allowInvitesRow(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _allowInvites = !_allowInvites),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: _allowInvites,
                  onChanged: (v) => setState(() => _allowInvites = v ?? true),
                  activeColor: c.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Text(tr('Allow members to add others'),
                  style: TextStyle(color: c.text, fontSize: 13)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 30, top: 2),
          child: Text(
            tr('When off, only you (the group owner) can add new members.'),
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ),
      ],
    );
  }

  /// `.form-input` — radius 12, bg white/0.05, padding 11/14, font 15 hint.
  InputDecoration _inputDecoration(NymColors c, String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 15),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      border: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.primaryA(0.3)),
      ),
    );
  }
}

/// `.pm-recipient-chip` — base nym (--text) + `#suffix` (text-dim) pill with a
/// remove ✕. bg primary/0.15, border primary/0.3, radius 999, padding
/// 2px 8px 2px 10px, gap 4.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.base,
    required this.suffix,
    required this.onRemove,
  });
  final String base;
  final String suffix;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 8, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: c.primaryA(0.15),
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        border: Border.all(color: c.primaryA(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(base, style: TextStyle(color: c.text, fontSize: 12)),
          // `.pm-chip-suffix` — text-dim 11px.
          Text('#$suffix', style: TextStyle(color: c.textDim, fontSize: 11)),
          const SizedBox(width: 4),
          // `.pm-chip-remove` — text-dim "×" (U+00D7, NOT the modal-close ✕;
          // pms.js:3672 uses `×`), danger on hover.
          InkWell(
            onTap: onRemove,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            child: Text('×',
                style: TextStyle(color: c.textDim, fontSize: 14, height: 1)),
          ),
        ],
      ),
    );
  }
}
