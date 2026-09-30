import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../i18n/i18n.dart';
import 'p2p_models.dart';
import 'p2p_service.dart';

/// Lists seeding files and active transfers, rebuilding live from [P2PService].
class P2PTransfersModal extends ConsumerWidget {
  const P2PTransfersModal({super.key, required this.service});

  final P2PService service;

  /// Geohash of the channel being viewed, or null; stopSeeding tags it so other viewers learn the file is gone.
  static String? _currentGeohash(WidgetRef ref) {
    final state = ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) return null;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return isGeo ? view.id : null;
  }

  /// Named channel key of the current view, or null; [_currentGeohash] wins in stopSeeding.
  static String? _currentNamedChannel(WidgetRef ref) {
    final state = ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) return null;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return isGeo ? null : view.id;
  }

  static Future<void> open(BuildContext context, P2PService service) {
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: isLight
          ? const Color(0x73000000)
          : const Color(0xBF000000),
      builder: (_) => P2PTransfersModal(service: service),
    );
  }

  /// Alias for [open].
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
              width: MediaQuery.of(context).size.width * 0.9,
              constraints: BoxConstraints(
                maxWidth: 500,
                maxHeight: MediaQuery.of(context).size.height * 0.9,
              ),
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: c.isLight
                    ? const [
                        BoxShadow(
                          color: Color(0x1F000000),
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
                        // The list itself caps at 400, independent of the modal's 90% limit.
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 400),
                            child: empty
                                ? Padding(
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
                                            // Keyed by transfer id so the fill's width animation stays with its transfer.
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

  /// Connecting is warning, transferring secondary, complete primary, error danger.
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
            color: _hover
                ? (c.isLight
                    ? const Color(0x0F000000)
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
