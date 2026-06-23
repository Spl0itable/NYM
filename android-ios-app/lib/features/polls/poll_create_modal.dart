import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';

/// Validation for the poll-create form (commands.js `submitPoll`): a non-empty
/// question and at least 2 non-empty options. Returns true when the form may be
/// submitted.
bool pollFormValid(String question, List<String> options) {
  if (question.trim().isEmpty) return false;
  final filled = options.where((o) => o.trim().isNotEmpty).length;
  return filled >= 2;
}

/// `#pollModal` — "Create Poll": a question field + dynamic option rows (start
/// with 2, add up to 6, the first two have no remove button) → `publishPoll`.
/// Channel-only; the entry affordance is disabled in PM/group views
/// (commands.js `cmdPoll`).
class PollCreateModal extends ConsumerStatefulWidget {
  const PollCreateModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const PollCreateModal(),
    );
  }

  @override
  ConsumerState<PollCreateModal> createState() => _PollCreateModalState();
}

class _PollCreateModalState extends ConsumerState<PollCreateModal> {
  static const int _maxOptions = 6;

  final _questionController = TextEditingController();
  // Start with two option rows (commands.js `cmdPoll`).
  final List<TextEditingController> _optionControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _submitting = false;

  @override
  void dispose() {
    _questionController.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid => pollFormValid(
        _questionController.text,
        _optionControllers.map((c) => c.text).toList(),
      );

  void _addOption() {
    if (_optionControllers.length >= _maxOptions) return;
    setState(() => _optionControllers.add(TextEditingController()));
  }

  void _removeOption(int index) {
    // The first two rows are fixed (no remove button), matching the PWA.
    if (index < 2 || index >= _optionControllers.length) return;
    setState(() {
      _optionControllers.removeAt(index).dispose();
    });
  }

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    final question = _questionController.text.trim();
    final options = _optionControllers
        .map((c) => c.text.trim())
        .where((o) => o.isNotEmpty)
        .toList();
    setState(() => _submitting = true);
    await ref.read(nostrControllerProvider).publishPoll(question, options);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

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
                        'Create Poll',
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
                      _label(c, 'Question'),
                      const SizedBox(height: 8),
                      _FormInput(
                        controller: _questionController,
                        hint: 'Ask a question...',
                        maxLength: 280,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      _label(c, 'Options'),
                      const SizedBox(height: 8),
                      for (var i = 0; i < _optionControllers.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: _FormInput(
                                  controller: _optionControllers[i],
                                  hint: 'Option ${i + 1}',
                                  maxLength: 100,
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                              if (i >= 2) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: Icon(Icons.close,
                                      size: 16, color: c.textDim),
                                  onPressed: () => _removeOption(i),
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (_optionControllers.length < _maxOptions)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _addOption,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add option'),
                            style: TextButton.styleFrom(
                              foregroundColor: c.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // `.modal-actions`: Cancel + Create Poll.
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
                      onPressed: _valid && !_submitting ? _submit : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: c.bg,
                        disabledBackgroundColor: c.primaryA(0.3),
                      ),
                      child: const Text('Create Poll'),
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
}

/// Whether the poll-create affordance should be enabled — channel-only.
bool pollCreationAllowed(WidgetRef ref) =>
    ref.read(currentViewProvider).kind == ViewKind.channel;

/// `.form-input` — a bordered text field matching the PWA's modal inputs.
class _FormInput extends StatelessWidget {
  const _FormInput({
    required this.controller,
    required this.hint,
    required this.maxLength,
    this.onChanged,
  });
  final TextEditingController controller;
  final String hint;
  final int maxLength;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TextField(
      controller: controller,
      maxLength: maxLength,
      onChanged: onChanged,
      style: TextStyle(color: c.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 14),
        counterText: '',
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
      ),
    );
  }
}
