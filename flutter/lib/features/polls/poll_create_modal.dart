import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../dm_polls/dm_polls_providers.dart';
import '../i18n/i18n.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/dialog_button.dart';

/// Poll form is valid with a non-empty question and at least 2 non-empty options.
bool pollFormValid(String question, List<String> options) {
  if (question.trim().isEmpty) return false;
  final filled = options.where((o) => o.trim().isNotEmpty).length;
  return filled >= 2;
}

class PollCreateModal extends ConsumerStatefulWidget {
  const PollCreateModal({super.key});

  static Future<void> open(BuildContext context) {
    final isLight = context.nym.isLight;
    return showNymSheet<void>(
      context,
      (_) => const PollCreateModal(),
      barrierColor: isLight
          ? const Color(0x73000000)
          : const Color(0xBF000000),
    );
  }

  @override
  ConsumerState<PollCreateModal> createState() => _PollCreateModalState();
}

class _PollCreateModalState extends ConsumerState<PollCreateModal> {
  static const int _maxOptions = 6;

  final _questionController = TextEditingController();
  final List<TextEditingController> _optionControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _submitting = false;

  bool get _dirty =>
      !_submitting &&
      (_questionController.text.trim().isNotEmpty ||
          _optionControllers.any((o) => o.text.trim().isNotEmpty));


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
    // The first two rows are fixed.
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
    final view = ref.read(currentViewProvider);
    if (view.kind == ViewKind.channel) {
      await ref.read(nostrControllerProvider).publishPoll(question, options);
    } else {
      await ref.read(dmPollsProvider).publish(view, question, options);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    final body = Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              margin: NymSheetScope.of(context)
                  ? const EdgeInsets.fromLTRB(32, 12, 56, 20)
                  : const EdgeInsets.fromLTRB(32, 32, 32, 24),
              padding: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.glassBorder)),
              ),
              child: Text(
                tr('CREATE POLL'),
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
                    _label(c, tr('Question')),
                    const SizedBox(height: 8),
                    _FormInput(
                      controller: _questionController,
                      hint: tr('Ask a question...'),
                      maxLength: 280,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 20),
                    _label(c, tr('Options')),
                    const SizedBox(height: 8),
                    for (var i = 0; i < _optionControllers.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: _FormInput(
                                controller: _optionControllers[i],
                                hint: tr('Option {n}', {'n': i + 1}),
                                maxLength: 100,
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            if (i >= 2) ...[
                              const SizedBox(width: 8),
                              _removeOptionBtn(c, i),
                            ],
                          ],
                        ),
                      ),
                    if (_optionControllers.length < _maxOptions)
                      _addOptionBtn(c),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: DialogActions(
                children: [
                  _cancelBtn(c),
                  _createBtn(c),
                ],
              ),
            ),
          ],
        ),
        Positioned(top: 14, right: 14, child: _closeButton(c)),
      ],
    );
    return NymDiscardGuard(
      isDirty: () => _dirty,
      child: nymSheetOr(
        context,
        body,
        (body) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rxl,
                boxShadow: c.isLight
                    ? const [
                        BoxShadow(
                          color: Color(0x1F000000),
                          blurRadius: 40,
                          offset: Offset(0, 8),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 32,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                        BoxShadow(
                            color: Colors.white.withValues(alpha: 0.05),
                            spreadRadius: 1),
                      ],
              ),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(NymColors c, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      );

  Widget _closeButton(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(),
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
        child: Icon(Icons.close,
            semanticLabel: tr('Close'), size: 16, color: c.textDim),
      ),
    );
  }

  Widget _removeOptionBtn(NymColors c, int index) {
    return InkWell(
      onTap: () => _removeOption(index),
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: c.glassBorder),
        ),
        child: Icon(Icons.close, size: 12, color: c.textDim),
      ),
    );
  }

  Widget _addOptionBtn(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: _addOption,
        borderRadius: NymRadius.rsm,
        child: DottedBorderBox(
          color: c.glassBorder,
          radius: NymRadius.sm,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            alignment: Alignment.center,
            child: Text(
              tr('+ Add option'),
              style: TextStyle(color: c.textDim, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cancelBtn(NymColors c) {
    return DialogButton.secondary(
        label: tr('CANCEL'), onTap: () => Navigator.of(context).pop());
  }

  Widget _createBtn(NymColors c) {
    return DialogButton(
      label: tr('CREATE POLL'),
      onTap: _valid && !_submitting ? _submit : null,
    );
  }
}

bool pollCreationAllowed(WidgetRef ref) {
  final view = ref.read(currentViewProvider);
  return view.kind == ViewKind.channel ||
      ref.read(dmPollsProvider).refusal(view).isEmpty;
}

class _FormInput extends StatefulWidget {
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
  State<_FormInput> createState() => _FormInputState();
}

class _FormInputState extends State<_FormInput> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final focused = _focus.hasFocus;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rsm,
        boxShadow: NymField.ring(c, focused),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        maxLength: widget.maxLength,
        onChanged: widget.onChanged,
        style: TextStyle(color: c.inputText, fontSize: 15),
        decoration: NymField.decoration(c, hint: widget.hint).copyWith(counterText: ''),
      ),
    );
  }
}

/// Rounded box with a dashed border, painted since Flutter has no dashed [Border].
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({
    super.key,
    required this.color,
    required this.radius,
    required this.child,
  });
  final Color color;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 4.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final double end =
            distance + dash < metric.length ? distance + dash : metric.length;
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
