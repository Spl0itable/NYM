import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/secret_screen.dart';
import '../i18n/i18n.dart';
import '../toasts/toast_center.dart';

/// Tutorial step targets; unregistered targets fall back to a centered card.
enum TutorialTarget {
  nymDisplay,
  statusIndicator,
  mainMenu,
  channelList,
  discoverIcon,
  pmList,
  userList,
  messagesContainer,
  composer,
  shareButton,
}

/// Lazily created, app-lifetime [GlobalKey]s shared between the shell and the overlay.
class TutorialTargets {
  TutorialTargets._();

  static final Map<TutorialTarget, GlobalKey> _keys = {};

  /// The stable key the shell attaches to the widget for [target].
  static GlobalKey keyFor(TutorialTarget target) => _keys.putIfAbsent(
      target, () => GlobalKey(debugLabel: 'tutorial_$target'));

  /// Called from `HomeShell.initState` so a new shell never shares a [GlobalKey] with a disposed one.
  static void reset() => _keys.clear();

  /// Global rect of [target]'s widget, or null when not laid out.
  static Rect? rectOf(TutorialTarget target) {
    final ctx = _keys[target]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  /// Live context of [target]'s widget, for [Scrollable.ensureVisible]; null when not mounted.
  static BuildContext? contextOf(TutorialTarget target) =>
      _keys[target]?.currentContext;
}

/// Opens and closes the drawer per step on narrow layouts; absent on desktop.
abstract class TutorialSidebarDriver {
  /// Opens the drawer and resolves after the transition.
  Future<void> openSidebar();

  /// Closes the drawer and resolves after the transition.
  Future<void> closeSidebar();

  /// Restores the drawer to its pre-tour state.
  void restore();
}

/// What the overlay does to the sidebar before measuring a step.
enum TutorialSidebarAction { open, close, none }

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

  /// Spotlighted element, or null for a centered card.
  final TutorialTarget? target;

  /// On narrow layouts, whether to open or close the sidebar before measuring.
  final TutorialSidebarAction sidebar;
}

/// The 12 steps with the PWA's text, targets and sidebar actions.
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
    body: 'Tap here to edit the nickname, avatar, banner, bio, and Bitcoin '
        'lightning address for your Nym in this session. View the private key '
        '(nsec) of the Nym and save it if you would like to reuse this same Nym '
        'identity to login with it across devices. Beside it you will find your '
        'post-quantum recovery code, the nympq1… code that makes your private '
        'messages quantum-resistant. Save that one too and keep it with your '
        'nsec: another device needs it to read those messages, and if every '
        'device holding it is lost they cannot be recovered. '
        'Long-pressing this area for '
        '2 seconds will engage Panic Mode, which will encrypt all data with '
        'multiple throwaway Nyms, overwrite all data with junk, and logout '
        'immediately to make it difficult for anyone to access the data if you '
        'need to quickly hide and protect yourself.',
    target: TutorialTarget.nymDisplay,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Connection',
    body: 'The current relay connection status. Tap here to view network stats '
        'such as the average latency, number of received events, and bandwidth '
        'usage.',
    target: TutorialTarget.statusIndicator,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Main Menu',
    body: 'Get flair addon packs to change the styling of your messages and '
        'nickname. Edit settings such as changing the app\'s theme, manage '
        'blocked users and keywords, sorting geohash channels by proximity, and '
        'much more. Logout to terminate the current session and start fresh '
        'with a new identity.',
    target: TutorialTarget.mainMenu,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Channels',
    body: 'Browse and switch geohash or non-geohash channels. Use the search '
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
    body: 'Tap the globe to explore geohash-only channels on a world map. Find '
        'interesting channels to join based on location, see where other users '
        'are active, and view heatmap, day/night, and geohash grid layers '
        'showing where the most popular geohash channels are located around the '
        'world.',
    target: TutorialTarget.discoverIcon,
    sidebar: TutorialSidebarAction.open,
  ),
  TutorialStep(
    title: 'Private Messages',
    body: 'Your end-to-end encrypted one-on-one and group chat messages live '
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
    body: 'Channel messages appear here. Long-press a message or click on a '
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

/// Every tutorial string, for pre-translation when a language is chosen; keep in step with `_card`'s `tr(...)` literals.
List<String> tutorialStringsForPretranslate() => <String>[
      for (final step in kTutorialSteps) ...[step.title, step.body],
      'Skip',
      'Back',
      'Next',
      'Done',
      'Step {n} of {total}',
      'Private key (nsec)',
      'Recovery code (nympq1…)',
      'Show',
      'Hide',
      'Copy',
      'Save both now and keep them together. The nsec is your identity; '
          'the nympq1… code is what lets another device read your '
          'quantum-resistant messages. Nobody can send them back to you.',
      'Your signer holds the private key, so there is no nsec to '
          'show here. Save this nympq1… recovery code — it is what lets '
          'another device read your quantum-resistant messages, and '
          'nobody can send it back to you.',
      'Save this now. It is your identity, and nobody can send it '
          'back to you.',
    ];

/// Guided tour: spotlights each step's target with a dim cut-out and ring; any dismissal marks it seen via [onDismiss].
class TutorialOverlay extends StatefulWidget {
  const TutorialOverlay({
    super.key,
    required this.onDismiss,
    this.sidebar,
    this.nsec,
    this.recoveryCode,
  });

  /// Called on dismissal; always marks the tutorial seen.
  final VoidCallback onDismiss;

  /// Optional drawer driver for narrow layouts.
  final TutorialSidebarDriver? sidebar;

  /// This session's `nsec1…`, or null when a signer holds the key.
  final String? Function()? nsec;

  /// The `nympq1…` recovery code, or null before the account has one.
  final String? Function()? recoveryCode;

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _index = 0;
  final FocusNode _focus = FocusNode();

  bool _nsecShown = false;
  bool _codeShown = false;

  /// A fresh account mints its root while the tour is up, so the first step keeps checking briefly.
  Timer? _codeWait;
  int _codeTries = 0;

  /// Measured target rect; null means a centered card.
  Rect? _targetRect;

  /// Re-measure once a frame settles (sidebar slide, etc.).
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
    _codeWait?.cancel();
    widget.sidebar?.restore();
    _focus.dispose();
    super.dispose();
  }

  String? get _nsec => widget.nsec?.call();
  String? get _code => widget.recoveryCode?.call();

  void _waitForCode() {
    if (_codeWait != null || _codeTries >= 20) return;
    _codeTries++;
    _codeWait = Timer(const Duration(seconds: 1), () {
      _codeWait = null;
      if (mounted) setState(() {});
    });
  }

  bool get _isFinal => _index >= kTutorialSteps.length - 1;

  bool _narrow(BuildContext context) =>
      MediaQuery.of(context).size.width < NymDimens.tabletBreakpoint;

  /// Runs the sidebar action, scrolls the target into view, then measures.
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

  /// Scrolls the target fully into view, aligned toward its top so a list's first row stays under the spotlight.
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
        // Target top ~12% down the viewport so the first row shows with headroom.
        alignment: 0.12,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } catch (_) {
      // Header targets have no scrollable ancestor.
    }
  }

  /// Re-measures and repaints only on change, so the per-frame re-measure can't loop.
  void _remeasure() {
    if (!mounted) return;
    final step = kTutorialSteps[_index];
    final rect =
        step.target == null ? null : TutorialTargets.rectOf(step.target!);
    if (rect != _targetRect) setState(() => _targetRect = rect);
  }

  /// Defers one re-measure to the next frame so the new layout is captured.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _remeasure();
    });
  }

  /// Steps without a target are always reachable.
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
    // Advance to the next reachable step.
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
    // Retreat to the previous reachable step.
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

    _scheduleMeasure();

    // Inflate the rect by 8px and clamp into the viewport.
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
          // Cut-out around the ring when there is a target, else a flat scrim.
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
          if (ring != null)
            Positioned.fromRect(
              rect: ring,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: NymRadius.rmd,
                    border: Border.all(color: c.secondary, width: 2),
                    // Light mode uses a neutral black glow instead of cyan.
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
          _positionedCard(c, ring, screen),
        ],
      ),
    );
  }

  /// Places the measured card below the ring if it fits, else above, else clamped on-screen near the bottom.
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
          color: c.bgTertiary,
          borderRadius: NymRadius.rlg,
          border: Border.all(color: c.glassBorder),
          boxShadow: [
            BoxShadow(
              color: c.isLight
                  ? const Color(0x1F000000)
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
                    tr(step.title).toUpperCase(),
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
            if (_index == 0) ..._keysPanel(c),
            const SizedBox(height: 10),
            Text(
              tr('Step {n} of {total}',
                  {'n': _index + 1, 'total': kTutorialSteps.length}),
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
            const SizedBox(height: 12),
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

  /// The nsec and recovery code on the first step, so they're saved first; signer logins get only the code.
  List<Widget> _keysPanel(NymColors c) {
    final nsec = _nsec;
    final code = _code;
    if (code == null || code.isEmpty) _waitForCode();
    final rows = <Widget>[
      if (nsec != null && nsec.isNotEmpty)
        _keyRow(c, tr('Private key (nsec)'), nsec, 'tutorialNsec',
            shown: _nsecShown,
            onToggle: () => setState(() => _nsecShown = !_nsecShown),
            copied: tr('Private key copied')),
      if (code != null && code.isNotEmpty)
        _keyRow(c, tr('Recovery code (nympq1…)'), code, 'tutorialPq',
            shown: _codeShown,
            onToggle: () => setState(() => _codeShown = !_codeShown),
            copied: tr('Post-quantum recovery code copied')),
    ];
    if (rows.isEmpty) return const [];

    final hasNsec = nsec != null && nsec.isNotEmpty;
    final hasCode = code != null && code.isNotEmpty;
    final note = hasNsec && hasCode
        ? tr('Save both now and keep them together. The nsec is your identity; '
            'the nympq1… code is what lets another device read your '
            'quantum-resistant messages. Nobody can send them back to you.')
        : (hasCode
            ? tr('Your signer holds the private key, so there is no nsec to '
                'show here. Save this nympq1… recovery code — it is what lets '
                'another device read your quantum-resistant messages, and '
                'nobody can send it back to you.')
            : tr('Save this now. It is your identity, and nobody can send it '
                'back to you.'));

    return [
      const SizedBox(height: 12),
      Column(
        key: const Key('tutorialKeys'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i != 0) const SizedBox(height: 10),
            rows[i],
          ],
          const SizedBox(height: 10),
          Text(note, style: TextStyle(color: c.textDim, fontSize: 12, height: 1.4)),
        ],
      ),
    ];
  }

  Widget _keyRow(NymColors c, String label, String value, String keyPrefix,
      {required bool shown,
      required VoidCallback onToggle,
      required String copied}) {
    return Column(
      key: Key('${keyPrefix}Row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shown) const SecretGuard(),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: c.glassBorder),
                ),
                child: Text(
                  shown ? value : '•' * 24,
                  key: Key('${keyPrefix}Value'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _keyBtn(c, shown ? tr('Hide') : tr('Show'),
                key: Key('${keyPrefix}Eye'), onTap: onToggle),
            const SizedBox(width: 6),
            _keyBtn(c, tr('Copy'), key: Key('${keyPrefix}Copy'), onTap: () async {
              await SecretScreen.copy(value);
              if (!mounted) return;
              showToast(copied);
            }),
          ],
        ),
      ],
    );
  }

  Widget _keyBtn(NymColors c, String label,
      {required Key key, required VoidCallback onTap}) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(
          label.toUpperCase(),
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

  Widget _skipBtn(NymColors c) {
    return InkWell(
      key: const Key('tutorialSkipBtn'),
      onTap: widget.onDismiss,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          // No light-mode override.
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

  /// Ghost pill used for both Back and Next.
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

/// Card placement: max width min(420, 92vw), centered without a ring, else below/above/clamped and centered on the ring.
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
      // The card is height-capped, so this is always at least 12.
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

/// Dims the screen with a rounded-rect [hole] punched clear.
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
