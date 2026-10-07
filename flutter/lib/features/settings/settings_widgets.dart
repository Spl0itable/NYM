import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/nym_tooltip.dart';

/// Shared form controls matching the PWA's settings styling, colored from `context.nym`.

/// Collapsible full-bleed settings section; [bleed] insets content to line up with the modal padding.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.children,
    this.bleed = 32,
  });

  final String title;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;
  final double bleed;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              color: const Color(0x0AFFFFFF),
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: bleed),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    duration: NymMotion.transition,
                    curve: NymMotion.curve,
                    // Down when open, -90° when collapsed.
                    turns: open ? 0 : -0.25,
                    child: NymSvgIcon(
                      NymIcons.chevronDown,
                      size: 18,
                      color: c.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: EdgeInsets.fromLTRB(bleed, 18, bleed, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
        ],
      ),
    );
  }
}

/// Label, control, and optional hint or warning.
class FormGroup extends StatelessWidget {
  const FormGroup({
    super.key,
    this.label,
    required this.child,
    this.hint,
    this.amberHint,
    this.warning,
    this.footer,
  });

  final String? label;
  final Widget child;
  final String? hint;

  /// Plain amber hint line, un-boxed.
  final String? amberHint;
  final String? warning;

  /// Optional widget after the hints, inside the group.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) ...[
            Text(
              label!.toUpperCase(),
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
          ],
          child,
          if (hint != null) ...[
            const SizedBox(height: 5),
            Text(
              hint!,
              style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
            ),
          ],
          if (amberHint != null) ...[
            const SizedBox(height: 4),
            // The warning-color variable is undefined in the PWA, so the #f0a030 fallback always applies.
            Text(
              amberHint!,
              style: const TextStyle(
                  color: Color(0xFFF0A030), fontSize: 11, height: 1.4),
            ),
          ],
          if (warning != null) ...[
            const SizedBox(height: 6),
            // Danger-tinted box, not the amber warning color.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.danger.withValues(alpha: 0.4)),
              ),
              child: Text(
                warning!,
                style: TextStyle(color: c.danger, fontSize: 11, height: 1.4),
              ),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: 12),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// Styled dropdown; [disabled] dims it and makes it inert, with an optional [tooltip].
class FormSelect<T> extends StatelessWidget {
  const FormSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.disabled = false,
    this.tooltip,
  });

  final T value;
  final List<({T value, String label})> items;
  final ValueChanged<T> onChanged;
  final bool disabled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final field = Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: _field(c),
    );
    if (disabled && tooltip != null) {
      return NymTooltip(message: tooltip!, child: field);
    }
    return field;
  }

  Widget _field(NymColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.isLight
            ? const Color(0x0A000000)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: NymRadius.rsm,
        border: Border.all(
          color: c.isLight ? const Color(0x1A000000) : c.glassBorder,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: c.bgTertiary,
          iconEnabledColor: c.textDim,
          // Inputs force pure white/black text at 15px.
          style: TextStyle(
            color: c.isLight ? Colors.black : Colors.white,
            fontSize: 15,
          ),
          borderRadius: NymRadius.rsm,
          padding: const EdgeInsets.symmetric(vertical: 11),
          items: [
            for (final it in items)
              DropdownMenuItem<T>(
                value: it.value,
                child: Text(it.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          // Null handler renders it greyed and inert.
          onChanged: disabled
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
          disabledHint: () {
            for (final it in items) {
              if (it.value == value) {
                return Text(it.label, overflow: TextOverflow.ellipsis);
              }
            }
            return null;
          }(),
        ),
      ),
    );
  }
}

/// Text field ([maxLines] > 1 for a textarea); light mode forces its fill and border with no focus lift.
class FormInput extends StatefulWidget {
  const FormInput({
    super.key,
    this.controller,
    this.hint,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.onTap,
    this.prefix,
    this.maxLines = 1,
    this.maxLength,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final VoidCallback? onTap;

  /// Optional 16px leading icon; text starts at 36px.
  final Widget? prefix;

  /// More than 1 renders the textarea variant.
  final int maxLines;

  /// Hard length cap with no visible counter.
  final int? maxLength;

  @override
  State<FormInput> createState() => _FormInputState();
}

class _FormInputState extends State<FormInput> {
  FocusNode? _internalNode;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_internalNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant FormInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalNode)?.removeListener(_onFocusChange);
      _node.addListener(_onFocusChange);
      _onFocusChange();
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocusChange);
    _internalNode?.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final focused = _node.hasFocus;
    if (focused != _focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rsm,
        boxShadow: NymField.ring(c, _focused),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _node,
        onTap: widget.onTap,
        onSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        buildCounter: widget.maxLength == null
            ? null
            : (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        // Inputs force pure white/black text at 15px.
        style: TextStyle(
          color: c.isLight ? Colors.black : Colors.white,
          fontSize: 15,
        ),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        decoration: NymField.decoration(c,
          hint: widget.hint,
          prefixIcon: widget.prefix == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: widget.prefix,
                ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 16)),
      ),
    );
  }
}

/// Segmented control; the active segment is primary at 15%.
class SegmentGroup<T> extends StatelessWidget {
  const SegmentGroup({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final T value;
  final List<({T value, String label})> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.all(3),
      // Neutral white/black tint, not the theme text color.
      decoration: BoxDecoration(
        color: c.insetFill,
        borderRadius: NymRadius.rsm,
      ),
      child: Row(
        children: [
          for (final s in segments)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(s.value),
                child: AnimatedContainer(
                  duration: NymMotion.transition,
                  curve: NymMotion.curve,
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: s.value == value
                        ? c.primaryA(0.15)
                        : Colors.transparent,
                    borderRadius: NymRadius.rxs,
                    border: Border.all(
                      color: s.value == value
                          ? c.primaryA(0.2)
                          : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    s.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: s.value == value ? c.primary : c.textDim,
                      fontSize: 12,
                      fontWeight:
                          s.value == value ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small fixed-red danger pill for moderation rows; labels aren't uppercased.
class DangerPillButton extends StatelessWidget {
  const DangerPillButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final radius = BorderRadius.circular(20);
    return InkWell(
      onTap: onPressed,
      borderRadius: radius,
      // Hover and active reach 0.2 via the 0.1 fill plus this overlay.
      highlightColor: const Color(0x1AFF4444),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0x1AFF4444),
          borderRadius: radius,
          border: Border.all(color: const Color(0x4DFF4444)),
        ),
        child: Text(
          label,
          style: TextStyle(color: c.danger, fontSize: 10),
        ),
      ),
    );
  }
}

/// `.icon-btn`-style inline action button.
class NymOutlineButton extends StatelessWidget {
  const NymOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.uppercase = true,
    this.height,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;

  /// `.icon-btn` text is uppercase; `.btn-small` (Reset) isn't.
  final bool uppercase;

  /// Fixed height to match a 42px send button beside it; null keeps the natural height.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Light mode uses a primary label; the danger variant has no light override.
    final accent = danger ? c.danger : (c.isLight ? c.primary : c.text);
    final text = Text(
      uppercase ? label.toUpperCase() : label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: accent,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: uppercase ? 0.8 : 0,
      ),
    );
    return InkWell(
      onTap: onPressed,
      borderRadius: NymRadius.rxs,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: danger ? c.danger.withValues(alpha: 0.08) : c.subtleFill,
          borderRadius: NymRadius.rxs,
          border: Border.all(
            color: danger
                ? c.danger.withValues(alpha: 0.3)
                : (c.isLight ? const Color(0x1A000000) : c.glassBorder),
          ),
        ),
        // Center with widthFactor keeps the pill shrink-wrapped while centering the label.
        child: height == null ? text : Center(widthFactor: 1, child: text),
      ),
    );
  }
}
