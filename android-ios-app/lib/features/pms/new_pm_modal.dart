import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';

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
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const NewPmModal(),
    );
  }

  @override
  ConsumerState<NewPmModal> createState() => _NewPmModalState();
}

class _NewPmModalState extends ConsumerState<NewPmModal> {
  final _recipientController = TextEditingController();
  final _groupNameController = TextEditingController();
  final List<PmRecipient> _recipients = [];

  bool get _groupMode => _recipients.length >= 2;

  @override
  void dispose() {
    _recipientController.dispose();
    _groupNameController.dispose();
    super.dispose();
  }

  void _addFromInput() {
    final users = ref.read(usersProvider);
    final pk = resolveRecipientPubkey(_recipientController.text, users);
    if (pk == null) return;
    if (pk == ref.read(appStateProvider).selfPubkey) return;
    if (_recipients.any((r) => r.pubkey == pk)) {
      _recipientController.clear();
      return;
    }
    final nym = users[pk]?.nym ?? getNymFromPubkey('anon', pk);
    setState(() {
      _recipients.add(PmRecipient(pk, nym));
      _recipientController.clear();
    });
  }

  void _remove(String pubkey) {
    setState(() => _recipients.removeWhere((r) => r.pubkey == pubkey));
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
      await controller.createGroup(
        name,
        _recipients.map((r) => r.pubkey).toList(),
      );
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final title = _groupMode ? 'New Group' : 'New Message';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rmd,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: c.textBright,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: Icon(Icons.close, size: 18, color: c.textDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _label(c, 'To'),
                      const SizedBox(height: 8),
                      // Recipient chips.
                      if (_recipients.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final r in _recipients)
                                _Chip(
                                  nym: r.nym,
                                  onRemove: () => _remove(r.pubkey),
                                ),
                            ],
                          ),
                        ),
                      TextField(
                        controller: _recipientController,
                        onSubmitted: (_) => _addFromInput(),
                        style: TextStyle(color: c.text, fontSize: 14),
                        decoration: _inputDecoration(
                          c,
                          'Search nym or paste pubkey...',
                          suffix: IconButton(
                            tooltip: 'Add',
                            icon: Icon(Icons.add, size: 18, color: c.primary),
                            onPressed: _addFromInput,
                          ),
                        ),
                      ),
                      if (_groupMode) ...[
                        const SizedBox(height: 16),
                        _label(c, 'Group Name (optional)'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupNameController,
                          maxLength: 40,
                          style: TextStyle(color: c.text, fontSize: 14),
                          decoration: _inputDecoration(
                            c,
                            'Enter a group name...',
                          ).copyWith(counterText: ''),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      style: TextButton.styleFrom(foregroundColor: c.textDim),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _recipients.isNotEmpty ? _start : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: c.bg,
                        disabledBackgroundColor: c.primaryA(0.3),
                      ),
                      child: Text(_groupMode ? 'Create' : 'Start'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(NymColors c, String text) => Text(
        text,
        style: TextStyle(
          color: c.textDim,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      );

  InputDecoration _inputDecoration(NymColors c, String hint, {Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 14),
      suffixIcon: suffix,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      filled: true,
      fillColor: c.glassBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: NymRadius.rxs,
        borderSide: BorderSide(color: c.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: NymRadius.rxs,
        borderSide: BorderSide(color: c.primaryA(0.5)),
      ),
    );
  }
}

/// `.pm-recipient-chip` — nym pill with a remove button.
class _Chip extends StatelessWidget {
  const _Chip({required this.nym, required this.onRemove});
  final String nym;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: c.primaryA(0.10),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(color: c.primaryA(0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            nym,
            style: TextStyle(color: c.primary, fontSize: 12),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            child: Icon(Icons.close, size: 14, color: c.primary),
          ),
        ],
      ),
    );
  }
}
