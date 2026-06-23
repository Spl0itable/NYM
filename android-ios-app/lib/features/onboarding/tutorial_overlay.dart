import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// One guided-tutorial step (`buildSteps()` in app.js IIFE).
@immutable
class TutorialStep {
  const TutorialStep({required this.title, required this.body});
  final String title;
  final String body;
}

/// The 12 tutorial steps, text matching the PWA verbatim. The `selector`
/// targets (which element each step highlights) are documented in the body but
/// not yet positionally highlighted here — TODO(verify): port the highlight
/// box that points at each target element. The card is shown centered for now.
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
  ),
  TutorialStep(
    title: 'Connection',
    body:
        'The current relay connection status. Tap here to view network stats '
        'such as the average latency, number of received events, and bandwidth '
        'usage.',
  ),
  TutorialStep(
    title: 'Main Menu',
    body:
        'Get flair addon packs to change the styling of your messages and '
        'nickname. Edit settings such as changing the app\'s theme, manage '
        'blocked users and keywords, sorting geohash channels by proximity, and '
        'much more. Logout to terminate the current session and start fresh '
        'with a new identity.',
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
  ),
  TutorialStep(
    title: 'Explore Geohash',
    body:
        'Tap the globe to explore geohash-only channels on a world map. Find '
        'interesting channels to join based on location, see where other users '
        'are active, and view heatmap, day/night, and geohash grid layers '
        'showing where the most popular geohash channels are located around the '
        'world.',
  ),
  TutorialStep(
    title: 'Private Messages',
    body:
        'Your end-to-end encrypted one-on-one and group chat messages live '
        'here. Tap the + symbol to start a new PM or group chat. Long-press an '
        'existing PM or group chat to view options such as blocking the user, '
        'or to close the conversation if you want to hide it from the list.',
  ),
  TutorialStep(
    title: 'Active Nyms',
    body:
        'See who is currently active. Tap a nym to PM them and more. This list '
        'is based on recent activity and relay presence, not just who you '
        'follow. It\'s a great way to discover and connect with active people '
        'on the app!',
  ),
  TutorialStep(
    title: 'Messages',
    body:
        'Channel messages appear here. Long-press a message or click on a '
        'nym\'s nickname for quick actions such as to react with emoji, '
        'edit/delete your own message, zap a Bitcoin tip, start a PM, mention, '
        'block and much more from the context menu.',
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
  ),
  TutorialStep(
    title: 'Share',
    body: 'Invite others to a channel with a shareable link.',
  ),
  TutorialStep(
    title: 'All set!',
    body:
        'That\'s it. Enjoy Nymchat! Check out all of the available commands by '
        'typing ?help to have our chat bot @Nymbot assist you or the /help '
        'command in any channel.',
  ),
];

/// The guided tutorial overlay (`#tutorialOverlay`): a dim full-screen backdrop
/// with a card carrying a title, body, "Step X of Y" progress, and Back / Next
/// (→ Done on the last step) controls plus a header Skip button. Any dismissal
/// path (Skip, Done, Escape) marks the tutorial seen via [onDismiss].
class TutorialOverlay extends StatefulWidget {
  const TutorialOverlay({super.key, required this.onDismiss});

  /// Called when the tutorial is dismissed (always marks `nym_tutorial_seen`).
  final VoidCallback onDismiss;

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _index = 0;

  bool get _isFinal => _index >= kTutorialSteps.length - 1;

  void _next() {
    if (_isFinal) {
      widget.onDismiss();
    } else {
      setState(() => _index++);
    }
  }

  void _back() {
    if (_index > 0) setState(() => _index--);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final step = kTutorialSteps[_index];

    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              key: const Key('tutorialCard'),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rlg,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 30,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          step.title,
                          style: TextStyle(
                            color: c.textBright,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('tutorialSkipBtn'),
                        onPressed: widget.onDismiss,
                        child: Text('Skip',
                            style: TextStyle(color: c.textDim, fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    step.body,
                    style: TextStyle(
                        color: c.text, fontSize: 13.5, height: 1.45),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Step ${_index + 1} of ${kTutorialSteps.length}',
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        key: const Key('tutorialPrevBtn'),
                        onPressed: _index == 0 ? null : _back,
                        child: Text(
                          'Back',
                          style: TextStyle(
                            color: _index == 0 ? c.textDim : c.text,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      FilledButton(
                        key: const Key('tutorialNextBtn'),
                        onPressed: _next,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.primary,
                          foregroundColor: c.bg,
                          shape: RoundedRectangleBorder(
                              borderRadius: NymRadius.rsm),
                        ),
                        child: Text(_isFinal ? 'Done' : 'Next'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
