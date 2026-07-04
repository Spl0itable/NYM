import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';

/// The `.typing-indicator` row pinned at the bottom of the active conversation
/// (`_renderTypingInto`, `styles-features.css:4227`): hidden (height 0 / opacity
/// 0) until a peer is typing, then animates to a 24px row showing up to three
/// overlapping 18px avatars + "X is typing" / "X and Y are typing" / "N people
/// are typing".
///
/// Reads `AppState.typing` (`<storageKey>|<pubkey>` → expiry ms) directly with a
/// live clock so the indicator self-expires even when no other state changes,
/// matching the PWA's per-peer typing timeout.
///
/// By default it keys off the active view's storage key (`app.view.storageKey`).
/// When [storageKey] is provided it keys off that instead, so the same canonical
/// row can be hosted per-column inside the deck (`.cv-typing`, columns.js:410-412
/// builds the identical `.typing-indicator` markup fed by `_renderTypingInto`),
/// instead of a degraded re-implementation.
class TypingIndicatorRow extends ConsumerStatefulWidget {
  const TypingIndicatorRow({super.key, this.storageKey});

  /// The conversation storage key to watch (`<storageKey>|<pubkey>` in
  /// `AppState.typing`). When null, the active view's key is used.
  final String? storageKey;

  @override
  ConsumerState<TypingIndicatorRow> createState() => _TypingIndicatorRowState();
}

class _TypingIndicatorRowState extends ConsumerState<TypingIndicatorRow> {
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Pubkeys typing in the watched conversation (non-expired), computed against
  /// `now` so the row hides the instant an indicator lapses. Keys off
  /// [TypingIndicatorRow.storageKey] when provided (per-column reuse), else the
  /// active view's storage key.
  List<String> _activeTypers(AppState app) {
    final prefix = '${widget.storageKey ?? app.view.storageKey}|';
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <String>[];
    app.typing.forEach((k, expiry) {
      if (k.startsWith(prefix) && expiry > now) out.add(k.substring(prefix.length));
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final app = ref.watch(appStateProvider);
    final pubkeys = _activeTypers(app);
    final active = pubkeys.isNotEmpty;

    // While anyone is typing, re-evaluate every second so the row animates out
    // when the last indicator expires (no incoming event would otherwise tick).
    if (active) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }

    String nymOf(String pk) {
      final nym = app.users[pk]?.nym;
      return (nym != null && nym.isNotEmpty) ? nym : 'Someone';
    }

    // `fmtTyper` (nostr-core.js:1432-1437): the trailing `#xxxx` renders in a
    // dimmed `.nym-suffix` span (opacity .7, 0.9em, weight 100); a nym with no
    // trailing 4-hex suffix (or a '#' inside the name) renders whole.
    List<InlineSpan> typerSpans(String pk) {
      final split = splitNymSuffix(nymOf(pk));
      return [
        TextSpan(text: split.base),
        if (split.suffix.isNotEmpty)
          TextSpan(
            text: split.suffix,
            style: TextStyle(
              color: c.textDim.withValues(alpha: 0.7),
              fontSize: 12 * 0.9,
              fontWeight: FontWeight.w100,
            ),
          ),
      ];
    }

    Widget content = const SizedBox.shrink();
    if (active) {
      final visible = pubkeys.take(3).toList();
      final List<InlineSpan> spans;
      if (pubkeys.length == 1) {
        // A bot "is thinking" rather than "is typing" (PWA `_renderTypingInto`
        // `isVerifiedBot` → verb 'thinking').
        final isBot =
            ref.read(nostrControllerProvider).isVerifiedBot(pubkeys[0]);
        spans = [
          ...typerSpans(pubkeys[0]),
          TextSpan(text: ' is ${isBot ? 'thinking' : 'typing'}'),
        ];
      } else if (pubkeys.length == 2) {
        spans = [
          ...typerSpans(pubkeys[0]),
          const TextSpan(text: ' and '),
          ...typerSpans(pubkeys[1]),
          const TextSpan(text: ' are typing'),
        ];
      } else {
        spans = [TextSpan(text: '${pubkeys.length} people are typing')];
      }
      content = Padding(
        // `.typing-indicator`: padding 4px 20px, gap 8.
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            // `.typing-indicator-avatars`: 18px round, overlapping by 6px, each
            // ringed by a 1.5px `--bg` border.
            for (var i = 0; i < visible.length; i++)
              Transform.translate(
                offset: Offset(-6.0 * i, 0),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 1.5),
                  ),
                  child: NymAvatar(
                    seed: visible[i],
                    size: 18,
                    imageUrl: app.users[visible[i]]?.profile?.picture,
                  ),
                ),
              ),
            // 8px gap after the avatar stack (less the cumulative overlap so the
            // dots don't drift right).
            if (visible.isNotEmpty)
              SizedBox(
                width: (8 - 6.0 * (visible.length - 1)).clamp(0, 8).toDouble()),
            // `.typing-indicator-dots`: three 5px dots bouncing in sequence.
            _TypingDots(color: c.textDim),
            const SizedBox(width: 8),
            // `.typing-indicator-text`: nowrap + ellipsis, 12px text-dim.
            Expanded(
              child: Text.rich(
                TextSpan(children: spans),
                style: TextStyle(color: c.textDim, fontSize: 12, height: 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // Animate the 0↔24 height + opacity, matching the CSS transition.
    // `.typing-indicator` bg: rgba(0,0,0,0.15) dark; light-mode → rgba(0,0,0,
    // 0.04).
    final bg = c.isLight
        ? const Color(0x0A000000) // black @ 0.04
        : const Color(0x26000000); // black @ 0.15
    return ClipRect(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
        height: active ? 24 : 0,
        width: double.infinity,
        color: bg,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: active ? 1 : 0,
          child: content,
        ),
      ),
    );
  }
}

/// `.typing-indicator-dots`: three 5px round dots that bounce in sequence
/// (`@keyframes typingBounce`, 1.2s loop, delays 0 / 0.15s / 0.3s):
/// opacity 0.3 → 1 and translateY 0 → −3 at the 30% mark, back by 60%.
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});
  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// One dot's bounce factor (0..1) at phase [t] (0..1), peaking at the 30% mark
  /// and resting (0) from 60% to 100% — the CSS keyframes (0%,60%,100% → rest;
  /// 30% → peak) with the declared `ease-in-out` timing applied WITHIN each
  /// keyframe segment (`animation: typingBounce 1.2s ease-in-out`,
  /// styles-features.css:4278): slow-fast-slow up, slow-fast-slow down.
  /// [Curves.easeInOut] is cubic-bezier(0.42,0,0.58,1) = CSS `ease-in-out`.
  double _bounce(double t) {
    if (t < 0.3) return Curves.easeInOut.transform(t / 0.3);
    if (t < 0.6) return 1 - Curves.easeInOut.transform((t - 0.3) / 0.3);
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 3), // `.typing-indicator-dots{gap:3}`
              Builder(builder: (_) {
                // Stagger each dot by 0.15s / 1.2s ≈ 0.125 of the loop.
                final phase = (_ctrl.value - i * 0.125) % 1.0;
                final b = _bounce(phase < 0 ? phase + 1 : phase);
                return Transform.translate(
                  offset: Offset(0, -3 * b),
                  child: Opacity(
                    opacity: 0.3 + 0.7 * b,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: widget.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }
}
