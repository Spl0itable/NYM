import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/nym_colors.dart';
import '../core/theme/nym_metrics.dart';
import '../models/settings.dart';
import '../state/settings_provider.dart';

/// Temporary design-system validation screen: switch between the six themes /
/// color modes and preview the core component styling. Will be replaced by the
/// real chat shell as that subsystem is ported.
class ThemeGalleryScreen extends ConsumerWidget {
  const ThemeGalleryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'NYMCHAT',
                style: TextStyle(
                  color: c.primary,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                'Design system preview',
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
              const SizedBox(height: 20),

              // Theme selector
              _label(c, 'THEME'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in NymThemeKey.values)
                    _chip(
                      c,
                      label: t.label,
                      selected: settings.theme == t,
                      onTap: () => ctrl.setTheme(t),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _label(c, 'MODE'),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in ColorMode.values)
                    _chip(
                      c,
                      label: m.name,
                      selected: settings.colorMode == m,
                      onTap: () => ctrl.setColorMode(m),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Switch(
                    value: settings.transparencyEnabled,
                    thumbColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) return c.primary;
                      return null;
                    }),
                    onChanged: ctrl.setTransparencyEnabled,
                  ),
                  Text('Transparency (glass UI)',
                      style: TextStyle(color: c.text, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 20),

              // Color token swatches
              _label(c, 'TOKENS'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _swatch('primary', c.primary),
                  _swatch('secondary', c.secondary),
                  _swatch('text', c.text),
                  _swatch('textDim', c.textDim),
                  _swatch('textBright', c.textBright),
                  _swatch('warning', c.warning),
                  _swatch('danger', c.danger),
                  _swatch('purple', c.purple),
                  _swatch('blue', c.blue),
                  _swatch('lightning', c.lightning),
                  _swatch('bgSecondary', c.bgSecondary),
                  _swatch('bgTertiary', c.bgTertiary),
                ],
              ),
              const SizedBox(height: 24),

              // Components preview
              _label(c, 'COMPONENTS'),
              _surface(
                c,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sidebarItem(c, '#nymchat', active: true, unread: 3),
                    _sidebarItem(c, '#9q5', active: false, unread: 0),
                    _sidebarItem(c, '#bitcoin', active: false, unread: 12),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // IRC message
              _surface(
                c,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ircMessage(c, 'satoshi', '21:00',
                        'gm everyone, building on nostr today'),
                    _ircMessage(c, 'you', '21:01', 'lets ship it', self: true),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Bubble messages
              _bubble(c, 'gm! welcome to nymchat', self: false),
              const SizedBox(height: 4),
              _bubble(c, 'thanks, loving the native app', self: true),
              const SizedBox(height: 16),

              // Buttons + badges
              Row(
                children: [
                  _sendBtn(c),
                  const SizedBox(width: 8),
                  _iconBtn(c, 'EMOJI'),
                  const SizedBox(width: 8),
                  _iconBtn(c, 'GIF'),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  _pill(c, '3', c.primary, c.bg),
                  _pill(c, 'GEOHASH', c.warning, c.warning.withValues(alpha: 0.1)),
                  _pill(c, 'STD', c.blue, c.blue.withValues(alpha: 0.1)),
                  _pill(c, '⚡ 21', c.lightning,
                      c.lightning.withValues(alpha: 0.12)),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(NymColors c, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            color: c.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
      );

  Widget _chip(NymColors c,
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.primaryA(0.15) : Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(
            color: selected ? c.primaryA(0.3) : c.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c.primary : c.text,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _swatch(String name, Color color) => SizedBox(
        width: 80,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 32,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 2),
            Text(name,
                style: const TextStyle(fontSize: 9, color: Colors.white70)),
          ],
        ),
      );

  Widget _surface(NymColors c, {required Widget child}) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          borderRadius: NymRadius.rmd,
          border: Border.all(color: c.glassBorder),
        ),
        child: child,
      );

  Widget _sidebarItem(NymColors c, String name,
      {required bool active, required int unread}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: active ? c.primaryA(0.10) : Colors.transparent,
        borderRadius: NymRadius.rxs,
        border: Border.all(
            color: active ? c.primaryA(0.20) : Colors.transparent),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(name,
                style: TextStyle(
                    color: active ? c.text : c.textDim, fontSize: 15)),
          ),
          if (unread > 0) _pill(c, '$unread', c.primary, c.bg),
        ],
      ),
    );
  }

  Widget _ircMessage(NymColors c, String author, String time, String content,
      {bool self = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(author,
                style: TextStyle(
                    color: self ? c.primary : c.secondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
          ),
          const SizedBox(width: 8),
          Text(time, style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(content,
                style: TextStyle(color: c.text, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  Widget _bubble(NymColors c, String text, {required bool self}) {
    return Align(
      alignment: self ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: self ? c.primaryA(0.25) : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(self ? 16 : 4),
            bottomRight: Radius.circular(self ? 4 : 16),
          ),
        ),
        child: Text(text, style: TextStyle(color: c.text, fontSize: 15)),
      ),
    );
  }

  Widget _sendBtn(NymColors c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        decoration: BoxDecoration(
          color: c.primaryA(0.10),
          borderRadius: NymRadius.rsm,
          border: Border.all(color: c.primaryA(0.30)),
        ),
        child: Text('SEND',
            style: TextStyle(
                color: c.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5)),
      );

  Widget _iconBtn(NymColors c, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(label,
            style: TextStyle(
                color: c.text, fontSize: 12, letterSpacing: 0.8)),
      );

  Widget _pill(NymColors c, String text, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                color: fg, fontSize: 10, fontWeight: FontWeight.w600)),
      );
}
