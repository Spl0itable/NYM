import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/chat/message_row.dart' show abbreviateNumber;
import '../../widgets/context_menu/interaction_hooks.dart';
import '../i18n/i18n.dart';
import 'zap_modal.dart';

/// The lightning bolt fill color (`--lightning`, `#f7931a`).
const Color _kLightning = Color(0xFFF7931A);

/// The inline `⚡ total` zap badge + quick-zap button shown at the FRONT of a
/// message's reactions row (`updateMessageZaps`, `zaps.js:1702-1784`). Reads
/// [zapsProvider] for [message]; renders nothing until the message has zaps.
///
/// - `.zap-badge` (`styles-chat.css:134-151`): orange-gradient pill (135°
///   .15→.08), border orange@.3, padding 3×10, radius 20, 14px lightning bolt,
///   12px/600 `--lightning` abbreviated total. `title` = "N zappers • M sats".
/// - `.add-zap-btn` (`styles-chat.css:332-355`): white@.04 pill, glass border,
///   padding 4×8, radius 20, opacity 0.6, 16px bolt+plus glyph; tap → quick-zap.
class ZapBadge extends ConsumerStatefulWidget {
  const ZapBadge({super.key, required this.message});

  final Message message;

  @override
  ConsumerState<ZapBadge> createState() => _ZapBadgeState();
}

class _ZapBadgeState extends ConsumerState<ZapBadge>
    with SingleTickerProviderStateMixin {
  final GlobalKey _badgeKey = GlobalKey();

  /// `.zap-badge-shock` (`@keyframes zapBadgeShock`, styles-features.css:464):
  /// a 0.55s scale-up-and-settle pulse with a gold/cyan box-shadow flash,
  /// applied to the badge each time the total ticks up (zaps.js:1697).
  late final AnimationController _shock;

  /// Last observed total (sats). -1 = not yet observed; the first observation
  /// (existing zaps on load) is recorded WITHOUT a burst so only live increases
  /// pop. A zap-less message records 0 here, so its first zap still bursts.
  int _lastTotal = -1;

  Message get message => widget.message;

  @override
  void initState() {
    super.initState();
    _shock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
  }

  @override
  void dispose() {
    _shock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zaps = ref.watch(zapsProvider)[message.id];
    if (zaps == null || zaps.totalSats <= 0) {
      if (_lastTotal < 0) _lastTotal = 0;
      return const SizedBox.shrink();
    }

    final total = zaps.totalSats;
    // Lightning burst when the total ticks up while mounted (zaps.js
    // `_playZapBurst`, fired from `_recordMessageZap`): the SVG bolt flash +
    // radiating mini-bolts over the badge, plus the `.zap-badge-shock` pulse on
    // the badge pill itself. Anchored to the badge.
    if (_lastTotal >= 0 && total > _lastTotal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _shock.forward(from: 0); // `.zap-badge-shock` (deferred off-build)
        final box = _badgeKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        ZapBurst.play(context, box.localToGlobal(box.size.center(Offset.zero)));
      });
    }
    _lastTotal = total;

    final zappers = zaps.zapperCount;
    // Tooltip mirrors zaps.js:1748-1751: "N zappers • M sats total", with a
    // trailing " (U unverified)" when any zap on this message is unverified (a
    // gift-wrapped, zapper-signed announcement not validated against the
    // recipient's LNURL provider pubkey).
    final unverifiedSats = zaps.unverifiedSats;
    final zapperLabel = zappers == 1
        ? tr('{n} zapper', {'n': abbreviateNumber(zappers)})
        : tr('{n} zappers', {'n': abbreviateNumber(zappers)});
    final tooltip = unverifiedSats > 0
        ? tr('{zappers} • {total} sats total ({u} unverified)', {
            'zappers': zapperLabel,
            'total': abbreviateNumber(total),
            'u': abbreviateNumber(unverifiedSats),
          })
        : tr('{zappers} • {total} sats total', {
            'zappers': zapperLabel,
            'total': abbreviateNumber(total),
          });

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          // `.zap-badge-shock` — scale-pulse + glow flash while _shock runs.
          // The scale/translate/glow all re-evaluate each tick inside the
          // builder; the constant inner pill is passed as the cached `child`.
          child: AnimatedBuilder(
            animation: _shock,
            builder: (context, child) {
              final shock = _ZapBadgeShock.at(_shock.value, _shock.isAnimating);
              return Transform.translate(
                offset: Offset(shock.dx, 0),
                child: Transform.scale(
                  scale: shock.scale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius:
                          const BorderRadius.all(Radius.circular(20)),
                      boxShadow: _shockGlow(),
                    ),
                    child: child,
                  ),
                ),
              );
            },
            child: Container(
              key: _badgeKey,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x26F7931A), Color(0x14F7931A)], // .15 / .08
                ),
                border: Border.all(color: const Color(0x4DF7931A)), // .3
                borderRadius: const BorderRadius.all(Radius.circular(20)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CustomPaint(painter: _BoltPainter(_kLightning)),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    abbreviateNumber(total),
                    style: const TextStyle(
                      color: _kLightning,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Quick-zap button: only when the author pubkey is known.
        if (message.pubkey.isNotEmpty) ...[
          const SizedBox(width: 5),
          _QuickZapBtn(
            onTap: () => _quickZap(context),
          ),
        ],
      ],
    );
  }

  /// The `.zap-badge-shock` box-shadow flash (`@keyframes zapBadgeShock`,
  /// styles-features.css:467-473). box-shadow is keyed at 0/20/60/100% (the
  /// 40% keyframe omits it), each segment eased with the animation's
  /// `ease-out`:
  ///   0%   0 0 10px orange(247,147,26)@.5
  ///   20%  0 0 18px gold(255,216,107)@.95 + 0 0 26px cyan(159,232,255)@.7
  ///   60%  0 0 16px orange@.9
  ///   100% 0 0 10px orange@.5
  /// CSS pads the shorter lists with transparent zero shadows, so the cyan
  /// companion fades in to the 20% flare and back out by 60%. Driven by the
  /// same `_shock` controller as the scale.
  List<BoxShadow> _shockGlow() {
    if (!_shock.isAnimating) return const [];
    final t = _shock.value;
    const orange = Color(0xFFF7931A);
    const gold = Color(0xFFFFD86B);
    const cyan = Color(0xFF9FE8FF);
    final Color main;
    final double mainBlur;
    final double cyanAlpha;
    final double cyanBlur;
    if (t < 0.20) {
      final f = Curves.easeOut.transform(t / 0.20);
      main = _shadowLerp(
          orange.withValues(alpha: 0.5), gold.withValues(alpha: 0.95), f);
      mainBlur = 10 + 8 * f;
      cyanAlpha = 0.7 * f;
      cyanBlur = 26 * f;
    } else if (t < 0.60) {
      final f = Curves.easeOut.transform((t - 0.20) / 0.40);
      main = _shadowLerp(
          gold.withValues(alpha: 0.95), orange.withValues(alpha: 0.9), f);
      mainBlur = 18 - 2 * f;
      cyanAlpha = 0.7 * (1 - f);
      cyanBlur = 26 * (1 - f);
    } else {
      final f = Curves.easeOut.transform((t - 0.60) / 0.40);
      main = _shadowLerp(
          orange.withValues(alpha: 0.9), orange.withValues(alpha: 0.5), f);
      mainBlur = 16 - 6 * f;
      cyanAlpha = 0;
      cyanBlur = 0;
    }
    return [
      BoxShadow(color: main, blurRadius: mainBlur),
      if (cyanAlpha > 0)
        BoxShadow(
          color: cyan.withValues(alpha: cyanAlpha),
          blurRadius: cyanBlur,
        ),
    ];
  }

  /// CSS interpolates shadow colors with premultiplied alpha; [Color.lerp] is
  /// straight-alpha, so lerp the premultiplied components and divide back out.
  static Color _shadowLerp(Color a, Color b, double t) {
    final alpha = a.a + (b.a - a.a) * t;
    if (alpha <= 0) return const Color(0x00000000);
    double ch(double ca, double cb) =>
        (ca * a.a + (cb * b.a - ca * a.a) * t) / alpha;
    return Color.from(
      alpha: alpha,
      red: ch(a.r, b.r),
      green: ch(a.g, b.g),
      blue: ch(a.b, b.b),
    );
  }

  /// Resolves the author's lightning address and opens the zap modal, mirroring
  /// `handleQuickZap` (`zaps.js:1786`). The PWA always does a FRESH fetch first
  /// (`fetchLightningAddressForUser`) rather than trusting the cache, so an
  /// author whose kind-0 hasn't arrived yet still gets zapped instead of a
  /// spurious "cannot receive zaps". Posts the PWA's "Checking…" system note,
  /// awaits the resolve, then either opens the modal or reports no address.
  Future<void> _quickZap(BuildContext context) async {
    final baseNym = stripPubkeySuffix(message.author);
    final notifier = ref.read(appStateProvider.notifier);
    notifier.addSystemMessage(
        tr('Checking if @{nym} can receive zaps...', {'nym': baseNym}));
    final controller = ref.read(nostrControllerProvider);
    final lnAddr = await controller.resolveLightningAddressForZap(message.pubkey);
    if (lnAddr == null || lnAddr.isEmpty) {
      notifier.addSystemMessage(tr(
          '@{nym} cannot receive zaps (no lightning address set)',
          {'nym': baseNym}));
      return;
    }
    if (!context.mounted) return;
    await ZapModal.show(
      context,
      recipientPubkey: message.pubkey,
      recipientNym: baseNym,
      lightningAddress: lnAddr,
      messageId: message.id,
      originalKind:
          inferOriginalKind(message, view: ref.read(currentViewProvider)),
    );
  }
}

/// The `.add-zap-btn` pill (bolt+plus glyph, dim until hover/press).
class _QuickZapBtn extends StatelessWidget {
  const _QuickZapBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: tr('Quick zap'),
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: 0.6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: c.glassBorder),
              borderRadius: const BorderRadius.all(Radius.circular(20)),
            ),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CustomPaint(painter: _BoltPlusPainter(c.text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The PWA lightning bolt (`M13 2L3 14h8l-1 8 10-12h-8l1-8z`, 24×24 viewBox).
class _BoltPainter extends CustomPainter {
  const _BoltPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(13 * s, 2 * s)
      ..lineTo(3 * s, 14 * s)
      ..lineTo(11 * s, 14 * s)
      ..lineTo(10 * s, 22 * s)
      ..lineTo(20 * s, 10 * s)
      ..lineTo(12 * s, 10 * s)
      ..lineTo(13 * s, 2 * s)
      ..close();
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _BoltPainter old) => old.color != color;
}

/// The quick-zap glyph: a bolt offset left (`M11 2L1 14h8l-1 8 10-12h-8l1-8z`)
/// plus a small "+" at the top-right (the PWA `add-zap-btn` SVG).
class _BoltPlusPainter extends CustomPainter {
  const _BoltPlusPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final bolt = Path()
      ..moveTo(11 * s, 2 * s)
      ..lineTo(1 * s, 14 * s)
      ..lineTo(9 * s, 14 * s)
      ..lineTo(8 * s, 22 * s)
      ..lineTo(18 * s, 10 * s)
      ..lineTo(10 * s, 10 * s)
      ..lineTo(11 * s, 2 * s)
      ..close();
    canvas.drawPath(bolt, fill);
    // The "+" (vertical bar x=19 y=2..6, horizontal bar x=17..21 y=4).
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawLine(Offset(19 * s, 2 * s), Offset(19 * s, 6 * s), stroke);
    canvas.drawLine(Offset(17 * s, 4 * s), Offset(21 * s, 4 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _BoltPlusPainter old) => old.color != color;
}

/// The instantaneous transform of the `.zap-badge-shock` pulse
/// (`@keyframes zapBadgeShock`, styles-features.css:467): scale + a small
/// horizontal wobble, keyed at 0/20/40/60/100% of the 0.55s window.
class _ZapBadgeShock {
  const _ZapBadgeShock(this.scale, this.dx);
  final double scale;
  final double dx;

  static _ZapBadgeShock at(double t, bool animating) {
    if (!animating) return const _ZapBadgeShock(1, 0);
    // Keyframes: 0%(1,0) 20%(1.25,-1) 40%(1.12,2) 60%(1.18,-1) 100%(1,0).
    // `animation: zapBadgeShock 0.55s ease-out` — the timing function applies
    // per keyframe segment.
    if (t < 0.20) {
      final f = Curves.easeOut.transform(t / 0.20);
      return _ZapBadgeShock(_l(1, 1.25, f), _l(0, -1, f));
    } else if (t < 0.40) {
      final f = Curves.easeOut.transform((t - 0.20) / 0.20);
      return _ZapBadgeShock(_l(1.25, 1.12, f), _l(-1, 2, f));
    } else if (t < 0.60) {
      final f = Curves.easeOut.transform((t - 0.40) / 0.20);
      return _ZapBadgeShock(_l(1.12, 1.18, f), _l(2, -1, f));
    } else {
      final f = Curves.easeOut.transform((t - 0.60) / 0.40);
      return _ZapBadgeShock(_l(1.18, 1, f), _l(-1, 0, f));
    }
  }

  static double _l(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);
}

/// A one-shot zap "burst" overlay (`_playZapBurst`, zaps.js:1655): the PWA's
/// `.zap-burst` SVG lightning-bolt flash (`@keyframes zapBurst`, 0.6s) plus 9
/// `.zap-bolt` radiating mini-bolts (`@keyframes zapBolt`, 0.5s), drawn over the
/// zap badge. Mirrors the `ReactionBurst` structure but with the electric bolt
/// + radiating bolts instead of an emoji + dot sparks.
///
/// Inserted into the root [Overlay]; removes itself after ~800ms (the PWA's
/// `setTimeout(…, 800)`).
class ZapBurst {
  ZapBurst._();

  static const _durationMs = 800;
  static const _boltCount = 9; // zaps.js:1675 `boltCount = 9`.

  /// Spawns a zap burst centred at [globalCenter].
  static void play(BuildContext context, Offset globalCenter) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _ZapBurstWidget(center: globalCenter));
    overlay.insert(entry);
    Future<void>.delayed(const Duration(milliseconds: _durationMs), () {
      if (entry.mounted) entry.remove();
    });
  }
}

/// One radiating `.zap-bolt`: a direction (dx,dy), its rotation, and a 0..1
/// start delay (the PWA's `animationDelay` up to 60ms).
class _ZapBolt {
  _ZapBolt(this.dx, this.dy, this.rot, this.delay);
  final double dx;
  final double dy;
  final double rot; // radians
  final double delay;
}

class _ZapBurstWidget extends StatefulWidget {
  const _ZapBurstWidget({required this.center});
  final Offset center;

  @override
  State<_ZapBurstWidget> createState() => _ZapBurstWidgetState();
}

class _ZapBurstWidgetState extends State<_ZapBurstWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_ZapBolt> _bolts;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    // zaps.js:1676-1684: angle = i/N*2π + random±0.25; dist = 20+random*20;
    // rotation = angle + 90°; animationDelay up to 60ms.
    _bolts = List.generate(ZapBurst._boltCount, (i) {
      final angle = (i / ZapBurst._boltCount) * math.pi * 2 +
          (rng.nextDouble() - 0.5) * 0.5;
      final dist = 20 + rng.nextDouble() * 20;
      return _ZapBolt(
        math.cos(angle) * dist,
        math.sin(angle) * dist,
        angle + math.pi / 2,
        (rng.nextDouble() * 60) / ZapBurst._durationMs,
      );
    });
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: ZapBurst._durationMs),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The burst is inserted into the root Overlay, which is NOT under a
    // Material (app.dart). Painting is all CustomPaint/DecoratedBox (no Text),
    // so there is no yellow-underline risk, but IgnorePointer keeps it
    // non-interactive like `pointer-events: none`.
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Stack(
            children: [
              ..._buildBolts(),
              _buildFlash(),
            ],
          );
        },
      ),
    );
  }

  /// `animation: zapBurst 0.6s cubic-bezier(0.2, 1.4, 0.5, 1)` — in CSS the
  /// timing function applies PER keyframe segment, and the 1.4 y control point
  /// overshoots each segment's target before settling.
  static const Cubic _kBurstCurve = Cubic(0.2, 1.4, 0.5, 1);

  /// The `.zap-burst` 40×40 SVG bolt (`@keyframes zapBurst`, 0.6s of the 0.8s
  /// window): scale 0→1.6→1.05→1.35→0.5, rotate -12°→6°→-7°→5°→0°, opacity
  /// 0→1→…→0, each segment eased with the overshooting [_kBurstCurve]. The
  /// upward jump (translate -50%→-90% of the 40px box) is only keyed on the
  /// final 45%→100% segment.
  ///
  /// `filter` is keyed only at 15% (`brightness(2.2)`) and 45%
  /// (`brightness(1.8)`); the implicit 0%/100% keys hold the element's
  /// drop-shadow filter. drop-shadow↔brightness is a mismatched filter list,
  /// which CSS interpolates DISCRETELY (flip at eased progress 0.5), while
  /// 15%→45% interpolates brightness 2.2→1.8 smoothly — so the glow is
  /// replaced by a brightness flash for the middle of the burst.
  Widget _buildFlash() {
    final t = (_c.value * 800 / 600).clamp(0.0, 1.0);
    double scale;
    double rotDeg;
    double opacity;
    double yShift = 0;
    if (t < 0.15) {
      final f = _kBurstCurve.transform(t / 0.15);
      scale = _u(0, 1.6, f);
      rotDeg = _u(-12, 6, f);
      opacity = _u(0, 1, f);
    } else if (t < 0.30) {
      final f = _kBurstCurve.transform((t - 0.15) / 0.15);
      scale = _u(1.6, 1.05, f);
      rotDeg = _u(6, -7, f);
      opacity = 1;
    } else if (t < 0.45) {
      final f = _kBurstCurve.transform((t - 0.30) / 0.15);
      scale = _u(1.05, 1.35, f);
      rotDeg = _u(-7, 5, f);
      opacity = 1;
    } else {
      final f = _kBurstCurve.transform((t - 0.45) / 0.55);
      scale = _u(1.35, 0.5, f);
      rotDeg = _u(5, 0, f);
      opacity = _u(1, 0, f);
      // translate(-50%,-50%) → translate(-50%,-90%): -40% of 40px = -16px.
      yShift = _u(0, -16, f);
    }

    // filter keys: drop-shadows(0%) → brightness(2.2)@15% →
    // brightness(1.8)@45% → drop-shadows(100%).
    double brightness = 1;
    var dropShadow = true;
    if (t < 0.15) {
      if (_kBurstCurve.transform(t / 0.15) >= 0.5) {
        brightness = 2.2;
        dropShadow = false;
      }
    } else if (t < 0.45) {
      brightness = _u(2.2, 1.8, _kBurstCurve.transform((t - 0.15) / 0.30));
      dropShadow = false;
    } else {
      if (_kBurstCurve.transform((t - 0.45) / 0.55) < 0.5) {
        brightness = 1.8;
        dropShadow = false;
      }
    }

    const box = 40.0;
    // `.zap-burst svg { fill: #ffd86b }` (24×24 bolt path, reused).
    Widget bolt = const SizedBox(
      width: box,
      height: box,
      child: CustomPaint(painter: _BoltPainter(Color(0xFFFFD86B))),
    );
    if (dropShadow) {
      // drop-shadow(0 0 10px rgba(247,147,26,.9)) +
      // drop-shadow(0 0 18px rgba(159,232,255,.55)) — the bolt glow.
      bolt = DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(color: Color(0xE6F7931A), blurRadius: 10),
            BoxShadow(color: Color(0x8C9FE8FF), blurRadius: 18),
          ],
        ),
        child: bolt,
      );
    } else {
      // brightness(k): multiply RGB by k, alpha untouched. It REPLACES the
      // drop-shadow filter while active (mismatched lists don't combine).
      bolt = ColorFiltered(
        colorFilter: ColorFilter.matrix(<double>[
          brightness, 0, 0, 0, 0, //
          0, brightness, 0, 0, 0, //
          0, 0, brightness, 0, 0, //
          0, 0, 0, 1, 0, //
        ]),
        child: bolt,
      );
    }
    return Positioned(
      left: widget.center.dx - box / 2,
      top: widget.center.dy - box / 2 + yShift,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: rotDeg * math.pi / 180,
          child: Transform.scale(
            scale: scale,
            child: bolt,
          ),
        ),
      ),
    );
  }

  /// The 9 `.zap-bolt` mini-bolts (`@keyframes zapBolt`, 0.5s of the window):
  /// scaleY 0→1→0.2, translating from the centre out to (dx,dy), each a 2×14px
  /// rounded gradient bar (white→gold→orange) with a gold/cyan glow.
  List<Widget> _buildBolts() {
    return _bolts.map((b) {
      final raw = ((_c.value - b.delay) * 800 / 500).clamp(0.0, 1.0);
      // 0%→40%: travel half-way + grow to full height; 40%→100%: rest of the
      // travel while shrinking to 0.2 and fading out.
      final double prog; // 0..1 fraction of the (dx,dy) travel
      final double scaleY;
      final double opacity;
      // `animation: zapBolt 0.5s ease-out` — eased per keyframe segment.
      if (raw < 0.40) {
        final f = Curves.easeOut.transform(raw / 0.40);
        prog = _l(0, 0.5, f);
        scaleY = _l(0, 1, f);
        opacity = 1;
      } else {
        final f = Curves.easeOut.transform((raw - 0.40) / 0.60);
        prog = _l(0.5, 1, f);
        scaleY = _l(1, 0.2, f);
        opacity = _l(1, 0, f);
      }
      final x = widget.center.dx + b.dx * prog;
      final y = widget.center.dy + b.dy * prog;
      return Positioned(
        left: x - 1, // 2px wide → centre by 1px
        top: y - 7, // 14px tall, transform-origin top-centre
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: b.rot,
            alignment: Alignment.topCenter,
            child: Transform.scale(
              scaleY: scaleY,
              alignment: Alignment.topCenter,
              child: Container(
                width: 2,
                height: 14,
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(1)),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFFFFFFF), Color(0xFFFFD86B), Color(0xFFF7931A)],
                    stops: [0.0, 0.45, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(color: Color(0xE6F7931A), blurRadius: 6),
                    BoxShadow(color: Color(0x999FE8FF), blurRadius: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  static double _l(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);

  /// Unclamped lerp — the overshooting [_kBurstCurve] drives values past
  /// their keyframe targets (CSS bezier overshoot).
  static double _u(double a, double b, double t) => a + (b - a) * t;
}
