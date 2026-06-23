import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// Shared form/control widgets that mirror the PWA's `.form-*` and
/// `.settings-section` styling (docs/specs/02 §5.10, §5.6). All controls take
/// their colors from `context.nym`.

/// A collapsible `.settings-section`: header (12px uppercase, letter-spacing,
/// 14px/32px padding) with a chevron that rotates -90° when collapsed.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.children,
  });

  final String title;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              // `.settings-section-header` padding 14px 0 (32px is the modal's
              // own horizontal padding in the PWA; here the modal body supplies
              // its own inset so we use 0 horizontally).
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: c.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    duration: NymMotion.transition,
                    curve: NymMotion.curve,
                    // chevron points down when open, -90° (right) when collapsed.
                    turns: open ? 0 : -0.25,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: c.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
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

/// A `.form-group`: label + control + optional hint/warning.
class FormGroup extends StatelessWidget {
  const FormGroup({
    super.key,
    this.label,
    required this.child,
    this.hint,
    this.warning,
  });

  final String? label;
  final Widget child;
  final String? hint;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) ...[
            // `.form-label`: 11px uppercase, letter-spacing 1.2, weight 600.
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
            const SizedBox(height: 6),
            Text(
              hint!,
              style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
            ),
          ],
          if (warning != null) ...[
            const SizedBox(height: 6),
            // `.form-warning`: danger-tinted box (not the amber warning color).
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
        ],
      ),
    );
  }
}

/// A `.form-select`: a styled dropdown over [items] (value, label).
class FormSelect<T> extends StatelessWidget {
  const FormSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<({T value, String label})> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: c.bgTertiary,
          iconEnabledColor: c.textDim,
          style: TextStyle(color: c.text, fontSize: 13),
          borderRadius: NymRadius.rsm,
          padding: const EdgeInsets.symmetric(vertical: 12),
          items: [
            for (final it in items)
              DropdownMenuItem<T>(
                value: it.value,
                child: Text(it.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// A `.form-input` single-line text field.
class FormInput extends StatelessWidget {
  const FormInput({
    super.key,
    this.controller,
    this.hint,
    this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TextField(
      controller: controller,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: TextStyle(color: c.text, fontSize: 13),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 13),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: true,
        fillColor: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
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
          borderSide: BorderSide(color: c.primaryA(0.4)),
        ),
      ),
    );
  }
}

/// `.color-mode-group`: a segmented control. Container bg @0.04, radius sm,
/// padding 3px; buttons flex:1, radius xs; active = primary @15%.
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
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
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
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: s.value == value
                        ? c.primaryA(0.15)
                        : Colors.transparent,
                    borderRadius: NymRadius.rxs,
                  ),
                  child: Text(
                    s.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: s.value == value ? c.primary : c.textDim,
                      fontSize: 13,
                      fontWeight:
                          s.value == value ? FontWeight.w600 : FontWeight.w400,
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

/// A `.icon-btn`-style button used for inline actions (Add, Send, Reset…).
class NymOutlineButton extends StatelessWidget {
  const NymOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.uppercase = true,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;

  /// `.icon-btn` text is uppercase with letter-spacing; `.btn-small` (Reset)
  /// is not.
  final bool uppercase;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final accent = danger ? c.danger : c.text;
    return InkWell(
      onTap: onPressed,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          // `.icon-btn`: bg white@5%, 1px glass border, radius xs.
          color: danger
              ? accent.withValues(alpha: 0.08)
              : c.text.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(
            color: danger ? accent.withValues(alpha: 0.3) : c.glassBorder,
          ),
        ),
        child: Text(
          uppercase ? label.toUpperCase() : label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: accent,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: uppercase ? 0.8 : 0,
          ),
        ),
      ),
    );
  }
}
