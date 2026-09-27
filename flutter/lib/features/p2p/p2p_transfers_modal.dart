import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../i18n/i18n.dart';
import 'p2p_models.dart';
import 'p2p_service.dart';

/// `#p2pTransfersModal` — lists seeding files + active/queued transfers with
/// progress (`openP2PTransfersModal`, p2p.js:732). Driven live by [P2PService]
/// (a [ChangeNotifier]); rebuilds as transfers progress.
///
/// Rendered as a centered `.modal` (showDialog), matching the PWA. Shared modal
/// chrome applies: 22px UPPERCASE primary header + bottom rule, 32px circular
/// glass close chip, translucent `.icon-btn` Close action.
class P2PTransfersModal extends ConsumerWidget {
  const P2PTransfersModal({super.key, required this.service});

  final P2PService service;

  /// The geohash of the channel the user is *currently viewing*, or null when
  /// the active view is a named channel / PM / group. The PWA's `stopSeeding`
  /// reads `this.currentGeohash` at stop-time and, when set, appends the channel
  /// wire tag so other channel viewers learn the file is gone (p2p.js:828). We
  /// resolve it the same way the share / typing paths do: a channel is a geohash
  /// when its key matches a `channels` entry flagged `isGeohash`
  /// (nostr_controller.dart:5552-5554).
  static String? _currentGeohash(WidgetRef ref) {
    final state = ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) return null;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return isGeo ? view.id : null;
  }

  /// The NAMED (non-geohash) channel key of the current view, or null when the
  /// active view is a geohash channel / PM / group. Companion to
  /// [_currentGeohash]: the PWA's `stopSeeding` emits the channel wire tag for
  /// whatever channel is open, which for a named channel is a `d` tag
  /// (`channelWire`, channels.js:454; `currentGeohash` holds the channel name).
  /// `stopSeeding` lets [_currentGeohash] win, so this only fires for a genuinely
  /// named channel. F06-B3.
  static String? _currentNamedChannel(WidgetRef ref) {
    final state = ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) return null;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return isGeo ? null : view.id;
  }

  /// Opens the transfers modal as a centered dialog (PWA `.modal`).
  static Future<void> open(BuildContext context, P2PService service) {
    // `.modal` barrier: solid-ui (default) dark `rgba(0,0,0,0.75)` →
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1635).
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: isLight
          ? const Color(0x73000000) // black @ 0.45
          : const Color(0xBF000000), // black @ 0.75
      builder: (_) => P2PTransfersModal(service: service),
    );
  }

  /// Back-compat alias for [open] (older call sites).
  static Future<void> show(BuildContext context, P2PService service) =>
      open(context, service);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: service,
          builder: (context, _) {
            final seeding = service.seeding;
            final transfers = service.transfers;
            final empty = seeding.isEmpty && transfers.isEmpty;
            return Container(
              // .modal-content + .p2p-modal-content (max-width 500, width 90%,
              // max-height 90vh, radius 24, glass border, shadow-lg + glow +
              // 1px white ring) (styles-components.css:17-27).
              width: MediaQuery.of(context).size.width * 0.9,
              constraints: BoxConstraints(
                maxWidth: 500,
                maxHeight: MediaQuery.of(context).size.height * 0.9,
              ),
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                // `body.light-mode .modal-content { box-shadow: 0 8px 40px
                // rgba(0,0,0,0.12) }` — one soft shadow, no glow, no white ring
                // in light (styles-themes-responsive.css:1050-1052).
                boxShadow: c.isLight
                    ? const [
                        BoxShadow(
                          color: Color(0x1F000000), // black @ 0.12
                          blurRadius: 40,
                          offset: Offset(0, 8),
                        ),
                      ]
                    : [
                        const BoxShadow(
                          color: Color(0x80000000),
                          blurRadius: 32,
                          offset: Offset(0, 8),
                        ),
                        BoxShadow(
                            color: c.primary.withValues(alpha: 0.1),
                            blurRadius: 20),
                        BoxShadow(
                            color: Colors.white.withValues(alpha: 0.05),
                            spreadRadius: 1),
                      ],
              ),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // .modal-header.
                        Container(
                          margin: const EdgeInsets.only(bottom: 24),
                          padding: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            border: Border(
                                bottom: BorderSide(color: c.glassBorder)),
                          ),
                          child: Text(
                            tr('P2P FILE TRANSFERS'),
                            style: TextStyle(
                              color: c.primary,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        // .modal-body > .p2p-transfers-list { max-height:
                        // 400px; overflow-y: auto } (styles-features.css:
                        // 1925-1928) — the scrolling list itself caps at 400,
                        // independent of the modal's own 90vh limit.
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 400),
                            child: empty
                                ? Padding(
                                    // .p2p-empty-state: centered italic
                                    // textDim, padding 30.
                                    padding: const EdgeInsets.all(30),
                                    child: Text(
                                      tr('No active transfers'),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: c.textDim,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  )
                                : SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (final entry in seeding.entries)
                                          _SeedingRow(
                                            offer: entry.value,
                                            onStop: () => service.stopSeeding(
                                              entry.key,
                                              geohash: _currentGeohash(ref),
                                              channelName:
                                                  _currentNamedChannel(ref),
                                            ),
                                          ),
                                        for (final t in transfers)
                                          _TransferRow(
                                            // PWA keys each row's DOM node by
                                            // `transfer-${id}` (p2p.js), so
                                            // the fill's width transition
                                            // stays with its transfer as rows
                                            // come and go.
                                            key: ValueKey(t.transferId),
                                            transfer: t,
                                            onCancel: () => service
                                                .cancelTransfer(t.transferId),
                                          ),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // .modal-actions: centered Close .icon-btn.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _IconBtn(
                              label: tr('Close'),
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // .modal-close chip.
                  Positioned(
                    top: 14,
                    right: 14,
                    child: _CloseChip(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// `.p2p-transfer-item` shell (white/0.03 fill, glass border, radius 12,
/// padding 14, margin-bottom 10).
class _TransferItem extends StatelessWidget {
  const _TransferItem({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// `.p2p-transfer-header`: filename (primary, bold, left) + size (textDim,
/// right), space-between, margin-bottom 8.
class _TransferHeader extends StatelessWidget {
  const _TransferHeader({required this.name, required this.size});
  final String name;
  final int size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatFileSize(size),
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SeedingRow extends StatelessWidget {
  const _SeedingRow({required this.offer, required this.onStop});
  final FileOffer offer;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return _TransferItem(
      children: [
        _TransferHeader(name: offer.name, size: offer.size),
        // .p2p-transfer-status: status text (complete=primary) + Stop button.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                offer.isTorrent ? tr('Seeding (Torrent)') : tr('Seeding (P2P)'),
                style: TextStyle(color: c.primary, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            _CancelBtn(label: tr('Stop'), onTap: onStop),
          ],
        ),
      ],
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow(
      {super.key, required this.transfer, required this.onCancel});
  final P2PTransfer transfer;
  final VoidCallback onCancel;

  /// Status-text color (`.p2p-transfer-status-text.<state>`): connecting →
  /// warning, transferring → secondary, complete → primary, error → danger.
  Color _statusColor(NymColors c) => switch (transfer.status) {
        P2PStatus.connecting => c.warning,
        P2PStatus.transferring => c.secondary,
        P2PStatus.complete => c.primary,
        P2PStatus.error => c.danger,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final pct = (transfer.progress / 100).clamp(0.0, 1.0);
    return _TransferItem(
      children: [
        _TransferHeader(name: transfer.offer.name, size: transfer.offer.size),
        // .p2p-transfer-progress: 6px track white/0.05 radius 10; fill gradient
        // primary→secondary radius 10, `transition: width 0.3s ease`
        // (styles-features.css:1981-1987). margin-bottom 8.
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: [
                  Container(color: Colors.white.withValues(alpha: 0.05)),
                  AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 300),
                    // CSS `ease` = cubic-bezier(0.25, 0.1, 0.25, 1).
                    curve: Curves.ease,
                    widthFactor: pct,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: LinearGradient(
                          colors: [c.primary, c.secondary],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // .p2p-transfer-status: raw status word (colored per state) + Cancel.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                p2pStatusWire(transfer.status),
                style: TextStyle(color: _statusColor(c), fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            _CancelBtn(label: tr('Cancel'), onTap: onCancel),
          ],
        ),
      ],
    );
  }
}

/// `.p2p-transfer-btn.cancel`: danger border + danger text, radius 8, padding
/// 5/10, font 11; hover fills danger / bg text.
class _CancelBtn extends StatelessWidget {
  const _CancelBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.danger),
        ),
        child: Text(
          label,
          style: TextStyle(color: c.danger, fontSize: 11),
        ),
      ),
    );
  }
}

/// `.icon-btn` (shared modal chrome): white/0.05 fill, glass border, radius 8,
/// `--text` color, padding 7/14, UPPERCASE 12px ls0.8 w500.
class _IconBtn extends StatefulWidget {
  const _IconBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            // `body.light-mode .icon-btn { background: rgba(0,0,0,0.03);
            // color: var(--primary) }`; hover `rgba(0,0,0,0.06)`
            // (styles-themes-responsive.css:595-605). `subtleFill` is exactly
            // black@.03 light / white@.05 dark (nym_colors.dart:112).
            color: _hover
                ? (c.isLight
                    ? const Color(0x0F000000) // black @ 0.06
                    : c.primary.withValues(alpha: 0.12))
                : c.subtleFill,
            borderRadius: NymRadius.rxs,
            border: Border.all(
              color: _hover ? c.primary.withValues(alpha: 0.3) : c.glassBorder,
            ),
          ),
          child: Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: _hover || c.isLight ? c.primary : c.text,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
    );
  }
}

/// 32×32 circular glass close chip with a danger hover (`.modal-close`).
class _CloseChip extends StatefulWidget {
  const _CloseChip({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseChip> createState() => _CloseChipState();
}

class _CloseChipState extends State<_CloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? c.danger.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover ? c.danger.withValues(alpha: 0.3) : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
