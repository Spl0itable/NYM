import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../dm_polls/dm_polls_providers.dart';
import '../i18n/i18n.dart';

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
    return showDialog<void>(
      context: context,
      barrierColor: isLight
          ? const Color(0x73000000)
          : const Color(0xBF000000),
      builder: (_) => const PollCreateModal(),
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _cancelBtn(c),
                        const SizedBox(width: 10),
                        _createBtn(c),
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
        child: Text('✕',
            style: TextStyle(color: c.textDim, fontSize: 12, height: 1)),
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
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxs,
        ),
        child: Text(
          tr('CANCEL'),
          style: TextStyle(
            color: c.isLight ? c.primary : c.text,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _createBtn(NymColors c) {
    final enabled = _valid && !_submitting;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? _submit : null,
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
            tr('CREATE POLL'),
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
        boxShadow: focused
            ? [BoxShadow(color: c.primaryA(0.06), spreadRadius: 3)]
            : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        maxLength: widget.maxLength,
        onChanged: widget.onChanged,
        style: TextStyle(color: c.inputText, fontSize: 15),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: TextStyle(color: c.textDim, fontSize: 15),
          counterText: '',
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          filled: true,
          fillColor: Colors.white.withValues(alpha: focused ? 0.07 : 0.05),
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
        ),
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
