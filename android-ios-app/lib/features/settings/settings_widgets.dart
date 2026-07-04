import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/nym_icons.dart';

/// Shared form/control widgets that mirror the PWA's `.form-*` and
/// `.settings-section` styling (docs/specs/02 §5.10, §5.6). All controls take
/// their colors from `context.nym`.

/// A collapsible `.settings-section`. The header bar is full-bleed: a
/// `rgba(255,255,255,.04)` tinted bar, primary 12px/700 uppercase label with
/// letter-spacing 1.2, a primary chevron that rotates -90° when collapsed, and a
/// bottom glass-border divider. The section spans the full modal-body width (the
/// PWA's `.settings-section{margin:0 -32px}` cancels the modal padding); [bleed]
/// is the horizontal inset (32) applied to the header/body content so it lines up
/// with the rest of the modal.
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
      // `.settings-section { border-bottom: 1px glass-border }`.
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              // `.settings-section-header { background: rgba(255,255,255,.04);
              //   padding: 14px 32px }`.
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
                    // chevron points down when open, -90° (right) when collapsed.
                    turns: open ? 0 : -0.25,
                    // `.settings-section-chevron` (index.html:1363) — the down
                    // chevron; the PWA rotates it -90° when collapsed.
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
              // `.settings-section-body { padding: 18px 32px 4px }`.
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

/// A `.form-group`: label + control + optional hint/warning.
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

  /// A plain amber `.form-hint.nm-h-59` line (`color: var(--warning-color,
  /// #f0a030); margin-top: 4px`, no-inline.css:77) — un-boxed hint text, used
  /// by e.g. the hardcore-keypair warning (index.html hardcoreKeypairWarning).
  final String? amberHint;
  final String? warning;

  /// Optional trailing widget rendered after the hint(s), inside the group —
  /// e.g. the "Reset columns to defaults" button that follows the Chat View
  /// hint in the PWA markup (index.html `.nm-h-58`).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      // `.form-group { margin-bottom: 20px }`.
      padding: const EdgeInsets.only(bottom: 20),
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
            // `.form-hint { margin-top: 5px }`.
            const SizedBox(height: 5),
            Text(
              hint!,
              style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
            ),
          ],
          if (amberHint != null) ...[
            const SizedBox(height: 4),
            // `.nm-h-59`: plain form-hint text in the amber warning color
            // (`var(--warning-color, #f0a030)` — the variable is undefined in
            // the PWA CSS, so the #f0a030 fallback always applies). No box.
            Text(
              amberHint!,
              style: const TextStyle(
                  color: Color(0xFFF0A030), fontSize: 11, height: 1.4),
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
          if (footer != null) ...[
            const SizedBox(height: 12),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// A `.form-select`: a styled dropdown over [items] (value, label). When
/// [disabled] is true the control is locked (the PWA's `select.disabled`): dimmed
/// and non-interactive, with an optional [tooltip] (the PWA's `title=`).
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
      // Disabled native selects render at reduced opacity.
      opacity: disabled ? 0.5 : 1.0,
      child: _field(c),
    );
    if (disabled && tooltip != null) {
      return Tooltip(message: tooltip!, child: field);
    }
    return field;
  }

  Widget _field(NymColors c) {
    return Container(
      // `.form-select { background: rgba(255,255,255,.05); padding: 11px 14px }`;
      // light mode forces `background: rgba(0,0,0,.04) !important; border-color:
      // rgba(0,0,0,.1) !important` (styles-themes-responsive.css:560-568).
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
          // Inputs/selects force neutral text: `color: #ffffff !important`
          // dark / `#000000 !important` light, 15px
          // (styles-themes-responsive.css:570-592, styles-components.css:236).
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
          // `disabled` → null handler (Material renders it greyed + inert).
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

/// A `.form-input` text field (or `.form-textarea` when [maxLines] > 1).
///
/// Mirrors styles-components.css:229-255 + the theme input overrides
/// (styles-themes-responsive.css:560-592): bg white@.05 dark (focus → .07) /
/// black@.04 light (`!important`, so no focus lift), text forced pure
/// white/black at 15px, glass border (focus → primary@.3 in dark; light keeps
/// the `!important` rgba(0,0,0,.1) border), and a `0 0 0 3px` primary@.06
/// focus ring.
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

  /// Optional leading in-field icon (the PWA's `.settings-search-icon`: a 16px
  /// glyph inset at the left with the input's text starting at 36px).
  final Widget? prefix;

  /// > 1 renders the `.form-textarea` variant (e.g. the About contact box).
  final int maxLines;

  /// HTML `maxlength=` equivalent — hard cap with no visible counter (the PWA
  /// attribute renders none).
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
    final borderColor = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    return DecoratedBox(
      // `.form-input:focus { box-shadow: 0 0 0 3px primary@.06 }` — a
      // hard-edged ring (no blur); light mode's `:focus` override lifts it to
      // primary@.1 `!important` (styles-themes-responsive.css:1087-1093).
      decoration: BoxDecoration(
        borderRadius: NymRadius.rsm,
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: c.primaryA(c.isLight ? 0.1 : 0.06),
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _node,
        onTap: widget.onTap,
        onSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        // No counter — the PWA's `maxlength=` attribute renders none.
        buildCounter: widget.maxLength == null
            ? null
            : (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        // Inputs force neutral text: `color: #ffffff !important` dark /
        // `#000000 !important` light, 15px (styles-themes-responsive.css:
        // 570-592, styles-components.css:236).
        style: TextStyle(
          color: c.isLight ? Colors.black : Colors.white,
          fontSize: 15,
        ),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        decoration: InputDecoration(
          isDense: true,
          // `.settings-search .form-input { padding-left: 36px }` with the 16px
          // icon inset at the left (styles-components.css:148-157).
          prefixIcon: widget.prefix == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: widget.prefix,
                ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 16),
          hintText: widget.hint,
          hintStyle: TextStyle(color: c.textDim, fontSize: 15),
          // `.form-input { padding: 11px 14px }`.
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          filled: true,
          // Dark: white@.05, focus lifts to .07; light: black@.04 `!important`
          // (no focus lift).
          fillColor: c.isLight
              ? const Color(0x0A000000)
              : Colors.white.withValues(alpha: _focused ? 0.07 : 0.05),
          border: OutlineInputBorder(
            borderRadius: NymRadius.rsm,
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: NymRadius.rsm,
            borderSide: BorderSide(color: borderColor),
          ),
          // `:focus` border is primary@.3 in both modes — light mode's own
          // `:focus` rule re-asserts it `!important` and, being more specific,
          // beats the base light `border-color: rgba(0,0,0,.1) !important`
          // (styles-themes-responsive.css:1087-1093 over :564-569).
          focusedBorder: OutlineInputBorder(
            borderRadius: NymRadius.rsm,
            borderSide: BorderSide(color: c.primaryA(0.3)),
          ),
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
      // `.color-mode-group { background: rgba(255,255,255,.04) }`; light mode
      // → `rgba(0,0,0,.04)` (styles-themes-responsive.css:1292-1294). Neutral
      // white/black — NOT the theme text color.
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
                  // `.color-mode-btn { padding: 8px 4px; border: 1px solid
                  //   transparent }`; `.active { border-color: primary@.2 }`.
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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

/// `.unblock-btn` / `.remove-keyword-btn` (styles-components.css:532-549): the
/// small danger pill on moderation-list rows. Fixed red tint in both modes
/// (`rgba(255,68,68,.1)` fill, `.3` border), 20px pill radius, `3px 10px`
/// padding, 10px `--danger` label. No uppercase transform — the PWA labels are
/// 'Remove' / 'Unblock' / 'Unhide' as written.
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
      // :hover/:active → bg rgba(255,68,68,.2): the .1 fill + this overlay.
      highlightColor: const Color(0x1AFF4444),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0x1AFF4444), // rgba(255,68,68,.1)
          borderRadius: radius,
          border: Border.all(color: const Color(0x4DFF4444)), // @.3
        ),
        child: Text(
          label,
          style: TextStyle(color: c.danger, fontSize: 10),
        ),
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
    this.height,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;

  /// `.icon-btn` text is uppercase with letter-spacing; `.btn-small` (Reset)
  /// is not.
  final bool uppercase;

  /// Fixed pill height. `.modal-actions` sets no `align-items`, so flex's
  /// default stretch sizes an `.icon-btn` to the 42px `.send-btn` beside it
  /// (label centered — `.icon-btn` is `inline-flex; align-items: center`).
  /// Null keeps the natural padded height.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.icon-btn` rest palette: white/0.05 fill + glass border + `--text`
    // label in dark; black/0.03 fill + black/0.1 border + `--primary` label
    // in light (`body.light-mode .icon-btn`, styles-themes-responsive.css:
    // 595-599) — same as _IconButtonState in modal_chrome.dart. The danger
    // variant is a separate class (danger/0.08 fill, danger/0.3 border,
    // danger label) with no light override.
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
        // Center + widthFactor keeps the pill shrink-wrapped while centering
        // the label within the pinned height.
        child: height == null ? text : Center(widthFactor: 1, child: text),
      ),
    );
  }
}
