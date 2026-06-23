import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import 'settings_widgets.dart';

/// App version string shown in the About header (`#aboutVersion`).
///
/// TODO(verify): the PWA derives this from its build manifest at runtime; the
/// native build version source isn't wired into this UI yet.
const String kAboutVersion = 'v1.0.0';

/// The About modal (`#aboutModal`, index.html:2118), presented as a centered
/// `.modal-content`. Layout mirrors the PWA: header (Nymchat + version), build
/// integrity + warrant-canary panels (placeholders), description, links,
/// divider, and the "Contact the developer" form.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const AboutScreen(),
    );
  }

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  final _messageController = TextEditingController();
  String _topic = 'General feedback';
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _messageController.dispose();
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(c),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildPanel(c),
                            const SizedBox(height: 10),
                            _canaryPanel(c),
                            _description(c),
                            _links(c),
                            const SizedBox(height: 20),
                            Container(height: 1, color: c.glassBorder),
                            const SizedBox(height: 20),
                            Text(
                              'Contact the developer',
                              style: TextStyle(
                                color: c.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Send feedback, a question, or a bug report. '
                              'Your message is delivered as an encrypted '
                              'private message to the Nymchat developer.',
                              style: TextStyle(
                                  color: c.textDim, fontSize: 11, height: 1.4),
                            ),
                            const SizedBox(height: 16),
                            FormGroup(
                              label: 'Topic',
                              child: FormSelect<String>(
                                value: _topic,
                                items: const [
                                  (
                                    value: 'General feedback',
                                    label: 'General feedback'
                                  ),
                                  (value: 'Bug report', label: 'Bug report'),
                                  (
                                    value: 'Feature request',
                                    label: 'Feature request'
                                  ),
                                  (value: 'Question', label: 'Question'),
                                  (
                                    value: 'Spam false positive',
                                    label: 'Spam false positive'
                                  ),
                                ],
                                onChanged: (v) => setState(() => _topic = v),
                              ),
                            ),
                            FormGroup(
                              label: 'Message',
                              child: _messageBox(c),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _actions(c),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 8,
              children: [
                Text(
                  'NYMCHAT',
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    kAboutVersion,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.text.withValues(alpha: 0.05),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.close, size: 18, color: c.textDim),
            ),
          ),
        ],
      ),
    );
  }

  /// `.about-build` panel. Network verification (build integrity / provenance)
  /// is a low-priority trust feature, so the live status is a placeholder.
  Widget _buildPanel(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Build integrity',
                  style: TextStyle(color: c.text, fontSize: 13)),
              // Placeholder: not verified on native yet.
              Text('—', style: TextStyle(color: c.textDim, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _link(c, 'source', 'https://github.com/Spl0itable/NYM'),
              _link(c, 'Build provenance',
                  'https://github.com/Spl0itable/NYM/actions'),
              _link(c, 'How to verify',
                  'https://github.com/Spl0itable/NYM#verify-build'),
            ],
          ),
        ],
      ),
    );
  }

  /// `.about-canary` warrant-canary panel (placeholder status).
  Widget _canaryPanel(NymColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Warrant canary',
                  style: TextStyle(color: c.text, fontSize: 13)),
              Text('—', style: TextStyle(color: c.textDim, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          _link(c, 'canary',
              'https://github.com/Spl0itable/NYM/blob/main/canary.json'),
        ],
      ),
    );
  }

  Widget _description(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 16),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
                text: 'A decentralized, pseudonymous chat built on the '),
            _linkSpan(c, 'Nostr', 'https://nostr.com'),
            const TextSpan(
                text: " protocol. Inspired by and bridged with Jack Dorsey's "),
            _linkSpan(c, 'Bitchat', 'https://bitchat.free'),
            const TextSpan(text: '.'),
          ],
        ),
        style: TextStyle(color: c.textDim, fontSize: 13, height: 1.6),
      ),
    );
  }

  Widget _links(NymColors c) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        _link(c, 'GitHub', 'https://github.com/Spl0itable/NYM'),
        _link(c, 'Terms of Service', 'static/tos.html'),
        _link(c, 'Privacy Policy', 'static/pp.html'),
        _link(c, 'DMCA', 'static/dmca.html'),
      ],
    );
  }

  Widget _messageBox(NymColors c) {
    return TextField(
      controller: _messageController,
      maxLines: 4,
      maxLength: 2000,
      style: TextStyle(color: c.text, fontSize: 13),
      cursorColor: c.primary,
      decoration: InputDecoration(
        hintText: 'Write your message...',
        hintStyle: TextStyle(color: c.textDim, fontSize: 13),
        contentPadding: const EdgeInsets.all(12),
        filled: true,
        fillColor: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
        counterStyle: TextStyle(color: c.textDim, fontSize: 10),
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

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NymOutlineButton(
            label: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          // `.send-btn` style.
          InkWell(
            onTap: () {
              // TODO(verify): sendAboutContact delivers an encrypted PM to the
              // developer (networked); wiring deferred to the messaging owner.
            },
            borderRadius: NymRadius.rsm,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
              decoration: BoxDecoration(
                color: c.primaryA(0.10),
                borderRadius: NymRadius.rsm,
                border: Border.all(color: c.primaryA(0.30)),
              ),
              child: Text(
                'SEND MESSAGE',
                style: TextStyle(
                  color: c.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _link(NymColors c, String text, String url) {
    return GestureDetector(
      onTap: () {/* TODO(verify): external link handling */},
      child: Text(
        text,
        style: TextStyle(
          color: c.secondary,
          fontSize: 12,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  TextSpan _linkSpan(NymColors c, String text, String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {/* TODO(verify): external link handling */};
    _recognizers.add(recognizer);
    return TextSpan(
      text: text,
      style: TextStyle(color: c.secondary),
      recognizer: recognizer,
    );
  }
}
