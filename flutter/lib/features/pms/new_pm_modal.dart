import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/key_format.dart' show normalizePubkeyInput;
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
import '../groups/group_invite_confirm.dart';
import '../i18n/i18n.dart';

/// A picked recipient: 64-hex pubkey plus display nym.
class PmRecipient {
  const PmRecipient(this.pubkey, this.nym);
  final String pubkey;
  final String nym;
}

/// Resolves hex, `npub1…` or `nym#suffix` (matched against [users]) to a 64-hex pubkey, or null.
String? resolveRecipientPubkey(String input, Map<String, User> users) {
  final raw = input.trim().replaceFirst(RegExp(r'^@'), '');
  if (raw.isEmpty) return null;

  // A public key as hex, npub or nprofile.
  final asPubkey = normalizePubkeyInput(raw);
  if (asPubkey != null) return asPubkey;

  // Case-insensitive nym match, with or without #suffix.
  final query = raw.toLowerCase();
  for (final u in users.values) {
    if (u.nym.toLowerCase() == query) return u.pubkey;
    if (stripPubkeySuffix(u.nym).toLowerCase() == query) return u.pubkey;
  }
  return null;
}

/// New message/group modal: one recipient starts a PM, two or more create a group.
class NewPmModal extends ConsumerStatefulWidget {
  const NewPmModal({super.key});

  static Future<void> open(BuildContext context) {
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: !solidUi
          ? Colors.black.withValues(alpha: 0.7)
          : isLight
              ? const Color(0x73000000)
              : const Color(0xBF000000),
      builder: (_) => const NewPmModal(),
    );
  }

  @override
  ConsumerState<NewPmModal> createState() => _NewPmModalState();
}

class _NewPmModalState extends ConsumerState<NewPmModal> {
  final _recipientController = TextEditingController();
  final _recipientFocus = FocusNode();
  // Non-focusable key sentinel so Backspace on an empty field pops the last chip without stealing focus.
  final _recipientKeyFocus =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  final _groupNameController = TextEditingController();
  final _groupDescController = TextEditingController();
  final _messageController = TextEditingController();
  final List<PmRecipient> _recipients = [];

  /// Hosted URLs uploaded at pick time, so group metadata never carries a `file://` path.
  String? _groupAvatarUrl;
  String? _groupBannerUrl;
  bool _allowInvites = true; // `newGroupAllowInvites` checked by default

  /// Upload progress state: bar visibility, label, and fill fraction.
  bool _uploading = false;
  String _uploadLabel = tr('Uploading…');
  double _uploadProgress = 0;

  /// Last upload error shown under the media section; cleared on the next pick.
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

  /// True while the recipient input has focus, driving the focus glow.
  bool _recipientFocused = false;

  /// Empty query shows the "recently seen" list with a header.
  bool get _isRecentlySeen => _recipientController.text.trim().isEmpty;

  /// Known users minus self and picked, filtered by nym, newest first, capped at 10.
  List<User> get _suggestions {
    final raw =
        _recipientController.text.trim().replaceFirst(RegExp(r'^@'), '');
    final query = raw.toLowerCase();
    final self = ref.read(appStateProvider).selfPubkey;
    final picked = _recipients.map((r) => r.pubkey).toSet();
    final controller = ref.read(nostrControllerProvider);
    final out = <User>[];
    for (final u in ref.read(usersProvider).values) {
      if (u.pubkey == self || picked.contains(u.pubkey)) continue;
      // Nymbot is never suggested; it's reachable via its sidebar row or a direct paste.
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

  /// Inline guard line under the recipient box; cleared on the next add or remove.
  String? _recipientError;

  void _addRecipient(String pubkey, String nym) {
    if (pubkey == ref.read(appStateProvider).selfPubkey) return;
    if (_recipients.any((r) => r.pubkey == pubkey)) {
      _recipientController.clear();
      return;
    }
    // Nymbot can be messaged 1:1 but never grouped, in either order; keep the input on a guard trip.
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
    // Unknown pubkeys fall back to `nym#xxxx`, never 'anon'.
    final nym = users[pk]?.nym ?? getNymFromPubkey('nym', pk);
    _addRecipient(pk, nym);
  }

  void _remove(String pubkey) {
    setState(() {
      _recipientError = null;
      _recipients.removeWhere((r) => r.pubkey == pubkey);
    });
  }

  /// Backspace on an empty input removes the last chip.
  void _removeLast() {
    if (_recipientController.text.isNotEmpty || _recipients.isEmpty) return;
    setState(() {
      _recipientError = null;
      _recipients.removeLast();
    });
  }

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

  /// Uploads the picked group image before creating so `createGroup` gets a hosted URL; errors store nothing.
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
      // Picker unavailable (tests, desktop).
      return;
    }

    // Enforce the size cap before uploading.
    final cap = avatar ? _avatarMaxBytes : _bannerMaxBytes;
    if (bytes.length > cap) {
      final capMb = avatar ? 5 : 10;
      final actualMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      setState(() => _uploadError =
              tr('{label} must be under {cap}MB (this is {actual}MB).', {
            'label': avatar ? tr('Avatar') : tr('Banner'),
            'cap': capMb,
            'actual': actualMb,
          }));
      return;
    }

    setState(() {
      _uploadError = null;
      _uploading = true;
      _uploadProgress = 0.15;
      _uploadLabel = avatar
          ? tr('Uploading group avatar…')
          : tr('Uploading group banner…');
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
      // Surface the error and keep the prior media.
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
      // Avatar and banner are hosted URLs, never local paths.
      await controller.createGroup(
        name,
        _recipients.map((r) => r.pubkey).toList(),
        avatar: _groupAvatarUrl,
        banner: _groupBannerUrl,
        description: description.isNotEmpty ? description : null,
        allowMemberInvites: _allowInvites,
      );
    }
    // Send the optional initial message into the newly active conversation.
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
        constraints: const BoxConstraints(maxWidth: 440),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rxl,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
              BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
              BoxShadow(
                  color: Colors.white.withValues(alpha: 0.05), spreadRadius: 1),
            ],
          ),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                          _recipientBox(c),
                          // Inline under the box rather than in the chat behind the modal.
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
                              style:
                                  TextStyle(color: c.textBright, fontSize: 15),
                              decoration: _inputDecoration(
                                c,
                                tr('Enter a group name...'),
                              ).copyWith(counterText: ''),
                            ),
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
                              style:
                                  TextStyle(color: c.textBright, fontSize: 15),
                              decoration: _inputDecoration(
                                c,
                                tr("What's this group about?"),
                              ).copyWith(counterText: ''),
                            ),
                            _charCount(
                                c, _groupDescController.text.length, 150),
                            const SizedBox(height: 12),
                            _allowInvitesRow(c),
                          ],
                          const SizedBox(height: 16),
                          _label(c, tr('Message'), optional: true),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _messageController,
                            maxLines: 3,
                            style: TextStyle(color: c.inputText, fontSize: 15),
                            decoration: _inputDecoration(
                                c, tr('Start the conversation...')),
                          ),
                        ],
                      ),
                    ),
                  ),
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
              Positioned(top: 14, right: 14, child: _closeButton(c)),
            ],
          ),
        ),
      ),
    );
  }

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
        child: Text('✕',
            style: TextStyle(color: c.textDim, fontSize: 16, height: 1)),
      ),
    );
  }

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

  /// Pass the label without "(optional)"; [optional] appends a lowercase span.
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

  /// Chips and a borderless input inside one bordered box.
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
          color:
              Colors.white.withValues(alpha: _recipientFocused ? 0.07 : 0.05),
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
                    // Never consume; let the TextField handle the key.
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _recipientController,
                    focusNode: _recipientFocus,
                    autofocus: true, // PWA focuses pmRecipientInput on open
                    onSubmitted: (_) => _addFromInput(),
                    style: TextStyle(color: c.inputText, fontSize: 13),
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

  /// Dim at rest, warning at 80%, danger at 100%.
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

  /// Trimmed input without a leading `@`.
  String get _rawInput =>
      _recipientController.text.trim().replaceFirst(RegExp(r'^@'), '');

  /// Invite token for a `#gjoin=…` input; parsed case-sensitively since base64url must not be lowercased.
  GroupInviteToken? get _inviteToken {
    if (_rawInput.isEmpty) return null;
    return parseGroupInvite(_recipientController.text.trim());
  }

  /// Resolved pubkey for bare hex or `npub1…` input, unless it's self or already picked.
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

  /// Suggestion priority: invite link, then direct pubkey, then the nym list.
  Widget _suggestionsList(NymColors c) {
    final invite = _inviteToken;
    if (invite != null) {
      return _suggestionsBox(c, [_inviteSuggestionItem(c, invite)]);
    }

    final directPk = _directPubkey;
    if (directPk != null) {
      final user = ref.read(usersProvider)[directPk];
      // Unknown pubkeys fall back to `nym#xxxx`, never 'anon'.
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

    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return _suggestionsBox(c, [
      // Header only for the empty-query recently-seen list.
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

  /// "Join group" row; tapping confirms, closes the modal, then joins.
  Widget _inviteSuggestionItem(NymColors c, GroupInviteToken token) {
    final name = _sanitizeGroupName(token.name);
    return InkWell(
      onTap: () async {
        final controller = ref.read(nostrControllerProvider);
        final ok = await confirmGroupInviteJoin(context, token);
        if (!ok || !mounted) return;
        Navigator.of(context).maybePop();
        await controller.joinGroupViaInvite(token);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
                border: Border.all(color: c.glassBorder),
              ),
              child:
                  NymSvgIcon(NymIcons.groupGlyph, color: c.primary, size: 16),
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
            Text(
              tr('Join group'),
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  /// Collapse control chars and whitespace, trim, cap at 40.
  static String _sanitizeGroupName(String name) {
    final s = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.length > 40 ? s.substring(0, 40) : s;
  }

  /// Suggestion row used for both known users and the direct-pubkey row.
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

  /// 96px gradient banner with a 56px avatar overhanging its bottom-left, reserving 30px below.
  Widget _groupMediaSection(NymColors c) {
    final hasBanner = _groupBannerUrl != null;
    final hasAvatar = _groupAvatarUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(c, tr('Group Avatar & Banner'), optional: true),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 30), // clear the -22 overhang
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Taps are ignored while an upload is in flight.
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
                            // Proxied to hide the user's IP from the image host.
                            image: NetworkImage(
                                proxiedAvatarUrl(_groupBannerUrl)!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: hasBanner
                      ? null
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
                              // Proxied to hide the user's IP from the image host.
                              image: NetworkImage(
                                  proxiedAvatarUrl(_groupAvatarUrl)!),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: hasAvatar
                        ? null
                        : NymSvgIcon(NymIcons.groupGlyph,
                            color: c.primary, size: 26),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_uploading) _uploadProgressBar(c),
        // Cleared on the next pick.
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

  Widget _uploadProgressBar(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
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
                      borderRadius: const BorderRadius.all(Radius.circular(10)),
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

  /// Checked by default; off means only the owner can add members.
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

/// Recipient chip: base nym plus dim `#suffix`, with a remove button.
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
          Text('#$suffix', style: TextStyle(color: c.textDim, fontSize: 11)),
          const SizedBox(width: 4),
          // Uses `×` (U+00D7), not the modal-close ✕.
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
