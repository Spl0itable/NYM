import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../i18n/i18n.dart';

/// The element each tutorial step points at (the PWA step `selector`s, see
/// `js/app.js` `buildSteps`). The shell + sidebar register a [GlobalKey] for
/// each of these via [TutorialTargets] so the overlay can measure the target's
/// on-screen rect and draw the spotlight ring around it.
///
/// CROSS-FILE NEED: `HomeShell` / the sidebar widgets must attach
/// `TutorialTargets.keyFor(target)` to the matching widget (e.g.
/// `key: TutorialTargets.keyFor(TutorialTarget.nymDisplay)`). When a target is
/// not registered (key has no `RenderBox`) the step degrades gracefully to the
/// centered card (same as the welcome/final steps).
enum TutorialTarget {
  nymDisplay, // `.nym-display`
  statusIndicator, // `.status-indicator`
  mainMenu, // `.header-actions` (>1024) / `.sidebar-actions` (<=1024)
  channelList, // `#channelList`
  discoverIcon, // `.discover-icon` (globe)
  pmList, // `#pmList`
  userList, // `#userList`
  messagesContainer, // `#messagesContainer`
  composer, // `.input-container`
  shareButton, // `#shareChannelBtn`
}

/// A registry of [GlobalKey]s, one per [TutorialTarget], shared between the
/// shell (which keys its widgets) and [TutorialOverlay] (which measures them).
///
/// Kept here (in the onboarding feature this overlay owns) so the cross-file
/// contract is a single import. Keys are created lazily and are stable for the
/// app lifetime.
class TutorialTargets {
  TutorialTargets._();

  static final Map<TutorialTarget, GlobalKey> _keys = {};

  /// The stable key the shell should attach to the widget for [target].
  static GlobalKey keyFor(TutorialTarget target) =>
      _keys.putIfAbsent(target, () => GlobalKey(debugLabel: 'tutorial_$target'));

  /// Drop all registered keys so the next shell mount allocates fresh ones.
  /// Called from `HomeShell.initState` — a single live shell never shares a
  /// [GlobalKey] with a previously-disposed one (which would otherwise reparent
  /// across sequential mounts, e.g. in widget tests, and corrupt teardown).
  static void reset() => _keys.clear();

  /// The global on-screen rect of [target]'s widget, or null when the target
  /// isn't mounted/laid-out (mirrors the PWA's "no element" → center fallback).
  static Rect? rectOf(TutorialTarget target) {
    final ctx = _keys[target]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  /// The live [BuildContext] of [target]'s widget (null when not mounted). Used
  /// to scroll the target into view via [Scrollable.ensureVisible], the native
  /// analogue of the PWA `positionStep`'s `target.scrollIntoView` (app.js:224).
  static BuildContext? contextOf(TutorialTarget target) =>
      _keys[target]?.currentContext;
}

/// Drives the sidebar/drawer open/close per step on narrow layouts
/// (`ensureSidebarOpenOnMobile` / `ensureSidebarClosedOnMobile`, app.js:97-175).
///
/// CROSS-FILE NEED: `HomeShell` supplies an implementation that toggles its
/// drawer and resolves once the slide settles. When absent, sidebar-anchored
/// steps simply rely on whatever is already on screen (desktop has no drawer).
abstract class TutorialSidebarDriver {
  /// Opens the drawer (narrow layouts) and resolves after the transition.
  Future<void> openSidebar();

  /// Closes the drawer (narrow layouts) and resolves after the transition.
  Future<void> closeSidebar();

  /// Restores the drawer to its pre-tour state (`restoreSidebarAfterTutorial`).
  void restore();
}

/// What the overlay does to the sidebar before measuring a step.
enum TutorialSidebarAction { open, close, none }

/// One guided-tutorial step (`buildSteps()` in app.js IIFE).
@immutable
class TutorialStep {
  const TutorialStep({
    required this.title,
    required this.body,
    this.target,
    this.sidebar = TutorialSidebarAction.none,
  });

  final String title;
  final String body;

  /// The element this step spotlights, or null for a centered card
  /// (welcome + "All set!" steps).
  final TutorialTarget? target;

  /// On narrow layouts, whether to open/close the sidebar before measuring.
  final TutorialSidebarAction sidebar;
}

/// The 12 tutorial steps, text matching the PWA verbatim, each mapped to the
/// [TutorialTarget] its PWA `selector` points at and the per-step sidebar
/// action (`onBefore`).
const List<TutorialStep> kTutorialSteps = [
  TutorialStep(
    title: 'Nymchat Tutorial',
    body:
        'Take a quick tour so you know where important functionality is across '
        'the app. You can skip anytime. And use our helpful chat bot @Nymbot or '
        'the /help command in any channel to learn more.',
  ),
  TutorialStep(
    title: 'Your Nym',
    body:
        'Tap here to edit the nickname, avatar, banner, bio, and Bitcoin '
        'lightning address for your Nym in this session. View the private key '
        '(nsec) of the Nym and save it if you would like to reuse this same Nym '
        'identity to login with it across devices. Long-pressing this area for '
        '2 seconds will engage Panic Mode, which will encrypt all data with '
        'multiple throwaway Nyms, overwrite all data with junk, and logout '
        'immediately to make it difficult for anyone to access the data if you '
        'need to quickly hide and protect yourself.',
    target: TutorialTarget.nymDisplay,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Connection',
    body:
        'The current relay connection status. Tap here to view network stats '
        'such as the average latency, number of received events, and bandwidth '
        'usage.',
    target: TutorialTarget.statusIndicator,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Main Menu',
    body:
        'Get flair addon packs to change the styling of your messages and '
        'nickname. Edit settings such as changing the app\'s theme, manage '
        'blocked users and keywords, sorting geohash channels by proximity, and '
        'much more. Logout to terminate the current session and start fresh '
        'with a new identity.',
    target: TutorialTarget.mainMenu,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Channels',
    body:
        'Browse and switch geohash or non-geohash channels. Use the search '
        'feature to find and join geohash or non-geohash channels. Geohash is '
        'for location-based chat using geohash codes (e.g., #w1, #dr5r). These '
        'are bridged with Bitchat and can be sorted by proximity to your '
        'location. Long-press a channel to favorite it to the top of the list '
        'for easy access, or to hide/block it from the list if you don\'t want '
        'to see it.',
    target: TutorialTarget.channelList,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Explore Geohash',
    body:
        'Tap the globe to explore geohash-only channels on a world map. Find '
        'interesting channels to join based on location, see where other users '
        'are active, and view heatmap, day/night, and geohash grid layers '
        'showing where the most popular geohash channels are located around the '
        'world.',
    target: TutorialTarget.discoverIcon,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Private Messages',
    body:
        'Your end-to-end encrypted one-on-one and group chat messages live '
        'here. Tap the + symbol to start a new PM or group chat. Long-press an '
        'existing PM or group chat to view options such as blocking the user, '
        'or to close the conversation if you want to hide it from the list.',
    target: TutorialTarget.pmList,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Active Nyms',
    body:
        'See who is currently active. Tap a nym to PM them and more. This list '
        'is based on recent activity and relay presence, not just who you '
        'follow. It\'s a great way to discover and connect with active people '
        'on the app!',
    target: TutorialTarget.userList,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Messages',
    body:
        'Channel messages appear here. Long-press a message or click on a '
        'nym\'s nickname for quick actions such as to react with emoji, '
        'edit/delete your own message, zap a Bitcoin tip, start a PM, mention, '
        'block and much more from the context menu.',
    target: TutorialTarget.messagesContainer,
    sidebar: TutorialSidebarAction.close,
  ),
  TutorialStep(
    title: 'Compose',
    body:
        'Type your message, translate it in a different language, add emoji or '
        'GIFs, or upload images/videos, share files via P2P, and more. Markdown '
        'is supported. You can also type commands for other actions, such as '
        'creating an away message and many more. Check out all of the available '
        'commands by typing ?help to have our chat bot @Nymbot assist you or '
        'the /help command in any channel.',
    target: TutorialTarget.composer,
  ),
  TutorialStep(
    title: 'Share',
    body: 'Invite others to a channel with a shareable link.',
    target: TutorialTarget.shareButton,
  ),
  TutorialStep(
    title: 'All set!',
    body:
        'That\'s it. Enjoy Nymchat! Check out all of the available commands by '
        'typing ?help to have our chat bot @Nymbot assist you or the /help '
        'command in any channel.',
  ),
];

/// Every user-facing string the guided tutorial renders — each step's title and
/// body plus the fixed chrome labels — so onboarding can pre-translate the WHOLE
/// tutorial the moment a language is chosen (before its first step mounts),
/// rather than letting each step flash English and swap in translation. Kept in
/// lockstep with the literals `_card` passes to `tr(...)`.
List<String> tutorialStringsForPretranslate() => <String>[
      for (final step in kTutorialSteps) ...[step.title, step.body],
      'Skip',
      'Back',
      'Next',
      'Done',
      'Step {n} of {total}',
    ];

/// The guided tutorial overlay (`#tutorialOverlay`).
///
/// For each step with a [TutorialStep.target] it measures the target widget's
/// global rect (via [TutorialTargets]), inflates it 8px, paints a dim
/// `rgba(0,0,0,0.5)` cut-out around it with a 2px `--secondary` (#00ffff
/// default) highlight ring + 30px glow, and anchors the step card below (or
/// above) the
/// target — mirroring `positionStep` (app.js:206-283). Welcome + "All set!"
/// steps (no target) show the card centered.
///
/// Keyboard (desktop): Esc ends the tour, →/Enter = Next, ← = Back
/// (`keyHandler`, app.js:401-410). Steps whose target can't be measured are
/// auto-skipped (`skipIfTargetMissingForward/Backward`, app.js:332-356).
///
/// Any dismissal path (Skip, Done, Escape) marks the tutorial seen via
/// [onDismiss].
class TutorialOverlay extends StatefulWidget {
  const TutorialOverlay({super.key, required this.onDismiss, this.sidebar});

  /// Called when the tutorial is dismissed (always marks `nym_tutorial_seen`).
  final VoidCallback onDismiss;

  /// Optional sidebar driver (narrow layouts open/close the drawer per step).
  final TutorialSidebarDriver? sidebar;

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _index = 0;
  final FocusNode _focus = FocusNode();

  /// Measured target rect for the current step (null → centered card).
  Rect? _targetRect;

  /// Pass to re-measure the step once a frame has settled (sidebar slide, etc).
  bool _measureScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _enterStep(_index);
    });
  }

  @override
  void dispose() {
    widget.sidebar?.restore();
    _focus.dispose();
    super.dispose();
  }

  bool get _isFinal => _index >= kTutorialSteps.length - 1;

  bool _narrow(BuildContext context) =>
      MediaQuery.of(context).size.width < NymDimens.tabletBreakpoint;

  /// Runs the step's `onBefore` (sidebar open/close on narrow), scrolls the
  /// target into view if it's off-screen, then measures.
  Future<void> _enterStep(int index) async {
    final step = kTutorialSteps[index];
    final sidebar = widget.sidebar;
    if (sidebar != null && _narrow(context)) {
      if (step.sidebar == TutorialSidebarAction.open) {
        await sidebar.openSidebar();
      } else if (step.sidebar == TutorialSidebarAction.close) {
        await sidebar.closeSidebar();
      }
    }
    if (!mounted) return;
    await _ensureTargetVisible(step);
    if (!mounted) return;
    _remeasure();
  }

  /// Scrolls the step's target into view — the native analogue of the PWA
  /// `positionStep`'s `scrollIntoView` (app.js:216-227). Without this, a
  /// sidebar-anchored step lower down the scroll list (Private Messages, Active
  /// Nyms) never scrolls into view and its spotlight lands off-screen.
  ///
  /// Fires whenever the target isn't ALREADY fully on-screen (top above the
  /// viewport, bottom below it, or entirely off) — not only when fully
  /// off-screen — so a section body whose first row sits just below the fold is
  /// pulled fully into view. It aligns toward the target's TOP rather than
  /// centering: a section body (e.g. `#pmList`) is the whole stack of rows with
  /// the newest/highlighted conversation FIRST, so the Nymbot welcome PM lives
  /// at the top — centering a multi-row list would push that top row away from
  /// where the spotlight lands.
  Future<void> _ensureTargetVisible(TutorialStep step) async {
    final target = step.target;
    if (target == null) return;
    final ctx = TutorialTargets.contextOf(target);
    if (ctx == null) return;
    final screen = MediaQuery.of(context).size;
    final rect = TutorialTargets.rectOf(target);
    final fullyOnScreen = rect != null &&
        rect.top >= 0 &&
        rect.bottom <= screen.height &&
        rect.left >= 0 &&
        rect.right <= screen.width;
    if (fullyOnScreen) return;
    try {
      await Scrollable.ensureVisible(
        ctx,
        // Sit the target's top ~12% down the viewport so the FIRST row (the
        // Nymbot welcome PM for `#pmList`) is prominently shown with headroom,
        // even when the section is taller than the viewport.
        alignment: 0.12,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } catch (_) {
      // Header-anchored targets have no scrollable ancestor — nothing to do.
    }
  }

  /// Measures the active step's target rect and repaints **only when it
  /// changed** (so the per-frame re-measure in `build` can't loop). Mirrors
  /// `positionStep`'s resize/scroll re-positioning.
  void _remeasure() {
    if (!mounted) return;
    final step = kTutorialSteps[_index];
    final rect = step.target == null ? null : TutorialTargets.rectOf(step.target!);
    if (rect != _targetRect) setState(() => _targetRect = rect);
  }

  /// Defers a single re-measure to the next frame (used after `setState` that
  /// changes the index, so the freshly-shown layout is captured).
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _remeasure();
    });
  }

  /// Whether [index]'s target is reachable (no selector → always reachable).
  bool _reachable(int index) {
    final step = kTutorialSteps[index];
    return step.target == null || TutorialTargets.rectOf(step.target!) != null;
  }

  void _next() {
    if (_isFinal) {
      widget.onDismiss();
      return;
    }
    var i = _index + 1;
    // skipIfTargetMissingForward: advance to the next reachable step.
    var guard = 0;
    while (guard++ < kTutorialSteps.length &&
        i < kTutorialSteps.length - 1 &&
        !_reachable(i)) {
      i++;
    }
    setState(() => _index = i);
    _enterStep(i);
  }

  void _back() {
    if (_index <= 0) return;
    var i = _index - 1;
    // skipIfTargetMissingBackward: retreat to the prior reachable step.
    var guard = 0;
    while (guard++ < kTutorialSteps.length && i > 0 && !_reachable(i)) {
      i--;
    }
    setState(() => _index = i);
    _enterStep(i);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.enter) {
      _next();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final screen = MediaQuery.of(context).size;

    // Re-measure when the layout (size) changes, like the PWA's resize/scroll
    // re-position handlers.
    _scheduleMeasure();

    // Inflate the measured rect by 8px and clamp into the viewport (pad=8 →
    // hlLeft/hlTop/hlWidth/hlHeight in positionStep).
    Rect? ring;
    final raw = _targetRect;
    if (raw != null) {
      final left = (raw.left - 8).clamp(8.0, screen.width);
      final top = (raw.top - 8).clamp(8.0, screen.height);
      final right = (raw.right + 8).clamp(left, screen.width - 8);
      final bottom = (raw.bottom + 8).clamp(top, screen.height - 8);
      if (right > left && bottom > top) {
        ring = Rect.fromLTRB(left, top, right, bottom);
      }
    }

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Dim backdrop. With a target → a black cut-out around the ring;
          // otherwise a flat scrim (matches the welcome/final steps).
          // `.tutorial-highlight` box-shadow spread: dark `rgba(0,0,0,0.5)` →
          // `body.light-mode .tutorial-highlight { … rgba(0,0,0,0.3) }`
          // (styles-themes-responsive.css:693-695).
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _SpotlightPainter(
                  hole: ring,
                  radius: NymRadius.md,
                  dim: Colors.black.withValues(alpha: c.isLight ? 0.3 : 0.5),
                ),
              ),
            ),
          ),
          // The highlight ring (2px secondary + 30px glow), drawn over the dim.
          if (ring != null)
            Positioned.fromRect(
              rect: ring,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: NymRadius.rmd,
                    border: Border.all(color: c.secondary, width: 2),
                    // `.tutorial-highlight` glow: dark `0 0 30px rgb(secondary
                    // /0.3)` → `body.light-mode … 0 0 30px rgba(0,0,0,0.15)`
                    // (styles-themes-responsive.css:693-695) — a neutral black
                    // glow, not the saturated cyan, in light mode.
                    boxShadow: [
                      BoxShadow(
                        color: c.isLight
                            ? Colors.black.withValues(alpha: 0.15)
                            : c.secondary.withValues(alpha: 0.3),
                        blurRadius: 30,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // The step card: anchored to the target, or centered.
          _positionedCard(c, ring, screen),
        ],
      ),
    );
  }

  /// Places the card per the PWA's `positionStep` measure-then-place pass
  /// (app.js:242-269): below the ring only when the MEASURED card fits
  /// (`spaceBelow > cardH + 16`), else above when that fits, else clamped
  /// fully on-screen near the bottom (overlapping the target if necessary —
  /// this is what keeps the "Messages" step's card from running off the
  /// bottom edge when its target spans the whole viewport). Implemented with
  /// a [CustomSingleChildLayout] so the real card size is known at placement
  /// time, exactly like the PWA's hidden-render measurement frame.
  Widget _positionedCard(NymColors c, Rect? ring, Size screen) {
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _TutorialCardLayoutDelegate(
          ring: ring,
          phone: screen.width <= NymDimens.mobileBreakpoint,
        ),
        child: _card(c),
      ),
    );
  }

  Widget _card(NymColors c) {
    final step = kTutorialSteps[_index];
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const Key('tutorialCard'),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.bgTertiary, // PWA `.tutorial-card` background
          borderRadius: NymRadius.rlg, // --radius-lg (20)
          border: Border.all(color: c.glassBorder),
          // `--shadow-lg` = 0 8px 32px black@0.5 (styles-core.css:93);
          // `body.light-mode .tutorial-card { box-shadow: 0 8px 32px
          // rgba(0,0,0,0.12) }` (styles-themes-responsive.css:697-699).
          boxShadow: [
            BoxShadow(
              color: c.isLight
                  ? const Color(0x1F000000) // black @ 0.12
                  : Colors.black.withValues(alpha: 0.5),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    tr(step.title).toUpperCase(), // uppercase, --primary, ls1
                    style: TextStyle(
                      color: c.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _skipBtn(c),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              tr(step.body),
              style: TextStyle(color: c.text, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 10),
            Text(
              tr('Step {n} of {total}',
                  {'n': _index + 1, 'total': kTutorialSteps.length}),
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
            const SizedBox(height: 12),
            // Back + Next: two identical ghost pills, right-aligned (gap 8).
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _ghostPill(
                  c,
                  tr('Back'),
                  key: const Key('tutorialPrevBtn'),
                  enabled: _index != 0,
                  onTap: _back,
                ),
                const SizedBox(width: 8),
                _ghostPill(
                  c,
                  _isFinal ? tr('Done') : tr('Next'),
                  key: const Key('tutorialNextBtn'),
                  enabled: true,
                  onTap: _next,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// `.tutorial-skip` — an uppercase outlined pill (11px, padding 6/12).
  Widget _skipBtn(NymColors c) {
    return InkWell(
      key: const Key('tutorialSkipBtn'),
      onTap: widget.onDismiss,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          // `.tutorial-skip { background: rgba(255,255,255,0.05) }`
          // (styles-components.css:2030-2043) — no light-mode override.
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(
          tr('Skip').toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  /// `.tutorial-btn` — `white@0.05` fill, glass border, radius 8, uppercase
  /// 12px w500 ls1, `--text` color. Used for both Back and Next.
  Widget _ghostPill(
    NymColors c,
    String label, {
    required Key key,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: enabled ? onTap : null,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: enabled ? c.text : c.textDim,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

/// The PWA `positionStep` card placement, given the laid-out card size:
///
///  * sized to `max-width: min(420px, 92vw)` (phones: 94vw,
///    styles-themes-responsive.css:104-107) and never taller than the
///    viewport minus margins;
///  * no ring → centered (min 12px margins);
///  * below the ring when the card fits (`spaceBelow > cardH + 16`), else
///    above when that fits, else `min(viewportH - cardH - 12,
///    max(12, ringBottom + 12))` — clamped fully on-screen;
///  * horizontally centered on the ring, clamped 12px from the edges.
class _TutorialCardLayoutDelegate extends SingleChildLayoutDelegate {
  const _TutorialCardLayoutDelegate({required this.ring, required this.phone});

  final Rect? ring;
  final bool phone;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final w = constraints.maxWidth;
    final capped = phone ? w * 0.94 : w * 0.92;
    final maxW = capped < 420.0 || phone ? capped : 420.0;
    final maxH = (constraints.maxHeight - 24).clamp(0.0, double.infinity);
    return BoxConstraints(maxWidth: maxW, maxHeight: maxH);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final r = ring;
    if (r == null) {
      // Centered (welcome / "All set!"), min 12px margins.
      final left = (size.width - childSize.width) / 2;
      final top = (size.height - childSize.height) / 2;
      return Offset(left < 12 ? 12 : left, top < 12 ? 12 : top);
    }
    final spaceBelow = size.height - r.bottom;
    final spaceAbove = r.top;
    final double top;
    if (spaceBelow > childSize.height + 16) {
      top = r.bottom + 12;
    } else if (spaceAbove > childSize.height + 16) {
      top = r.top - childSize.height - 12;
    } else {
      // Fallback: keep the card fully on-screen in the bottom area (the card
      // is height-capped above, so this is always >= 12).
      final onScreen = size.height - childSize.height - 12;
      final below = r.bottom + 12 < 12 ? 12.0 : r.bottom + 12;
      top = onScreen < below ? onScreen : below;
    }
    var left = r.left + (r.width - childSize.width) / 2;
    final maxLeft = size.width - childSize.width - 12;
    if (left > maxLeft) left = maxLeft;
    if (left < 12) left = 12;
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_TutorialCardLayoutDelegate old) =>
      old.ring != ring || old.phone != phone;
}

/// Fills the screen with [dim], punching a rounded-rect [hole] clear so the
/// highlighted element shows through — the Flutter analogue of the PWA's
/// `box-shadow: 0 0 0 9999px rgba(0,0,0,0.5)` spread on `.tutorial-highlight`.
class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({
    required this.hole,
    required this.radius,
    required this.dim,
  });

  final Rect? hole;
  final double radius;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = dim;
    final full = Offset.zero & size;
    if (hole == null) {
      canvas.drawRect(full, paint);
      return;
    }
    final outer = Path()..addRect(full);
    final inner = Path()
      ..addRRect(RRect.fromRectAndRadius(hole!, Radius.circular(radius)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.radius != radius || old.dim != dim;
}
