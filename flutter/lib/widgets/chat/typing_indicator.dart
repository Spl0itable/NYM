import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/i18n/i18n.dart';
import '../../features/pms/upload_activity.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';

/// Typing-indicator row for a conversation; reads `AppState.typing` against a live clock so it self-expires.
class TypingIndicatorRow extends ConsumerStatefulWidget {
  const TypingIndicatorRow({super.key, this.storageKey});

  /// Conversation to watch; null uses the active view's key.
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

  List<String> _activeTypers(AppState app) {
    final prefix = '${widget.storageKey ?? app.view.storageKey}|';
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <String>[];
    app.typing.forEach((k, expiry) {
      if (k.startsWith(prefix) && expiry > now) {
        out.add(k.substring(prefix.length));
      }
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final app = ref.watch(appStateProvider);
    final pubkeys = _activeTypers(app);
    final active = pubkeys.isNotEmpty;

    // Tick every second while anyone types so the row hides when the last indicator expires.
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

    final controller = ref.read(nostrControllerProvider);

    List<InlineSpan> typerSpans(String pk) {
      final split = splitNymSuffix(nymOf(pk));
      final isVerified =
          controller.isVerifiedDeveloper(pk) || controller.isVerifiedBot(pk);
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
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: CosmeticNymBadges(
            cosmetics: ref.watch(userCosmeticsProvider(pk)),
            flairSize: 14,
            supporterHeight: 14,
          ),
        ),
        if (isVerified)
          const WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: EdgeInsets.only(left: 4),
              child: VerifiedBadge(size: 14),
            ),
          ),
      ];
    }

    Widget content = const SizedBox.shrink();
    if (active) {
      final visible = pubkeys.take(3).toList();
      final prefix = '${widget.storageKey ?? app.view.storageKey}|';
      final tpl = UploadActivity.label([
        for (final pk in pubkeys)
          (
            activity: app.typingActivity['$prefix$pk'],
            bot: pubkeys.length == 1 && controller.isVerifiedBot(pk),
          ),
      ]);
      final spans = <InlineSpan>[
        for (final part in _splitTemplate(tr(tpl)))
          if (part == '{nym}')
            ...typerSpans(pubkeys[0])
          else if (part == '{other}')
            ...(pubkeys.length > 1 ? typerSpans(pubkeys[1]) : const <InlineSpan>[])
          else if (part == '{n}')
            TextSpan(text: '${pubkeys.length}')
          else if (part.isNotEmpty)
            TextSpan(text: part),
      ];
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            // Fixed-width Stack so overlapping avatars collapse like the CSS negative margin; a Row would reserve full widths.
            if (visible.isNotEmpty) ...[
              SizedBox(
                width: 18 + (visible.length - 1) * 12.0,
                height: 18,
                child: Stack(
                  children: [
                    for (var i = 0; i < visible.length; i++)
                      Positioned(
                        left: i * 12.0,
                        child: Container(
                          width: 18,
                          height: 18,
                          foregroundDecoration: BoxDecoration(
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
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
            _TypingDots(color: c.textDim),
            const SizedBox(width: 8),
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

    final bg = c.isLight
        ? const Color(0x0A000000)
        : const Color(0x26000000);
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

List<String> _splitTemplate(String tpl) {
  final out = <String>[];
  var last = 0;
  for (final m in RegExp(r'\{nym\}|\{other\}|\{n\}').allMatches(tpl)) {
    out.add(tpl.substring(last, m.start));
    out.add(m.group(0)!);
    last = m.end;
  }
  out.add(tpl.substring(last));
  return out;
}

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

  /// Bounce factor per phase [t]: peak at 30%, rest from 60%, with ease-in-out inside each keyframe segment.
  double _bounce(double t) {
    if (t < 0.3) return Curves.easeInOut.transform(t / 0.3);
    if (t < 0.6) return 1 - Curves.easeInOut.transform((t - 0.3) / 0.3);
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      if (_ctrl.isAnimating) _ctrl.stop();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Opacity(
              opacity: 0.6,
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ],
      );
    }
    if (!_ctrl.isAnimating) _ctrl.repeat();
    return RepaintBoundary(
        child: AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0)
                const SizedBox(width: 3),
              Builder(builder: (_) {
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
    ));
  }
}
