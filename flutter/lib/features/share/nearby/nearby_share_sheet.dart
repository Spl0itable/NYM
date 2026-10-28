import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../../services/mesh/mesh_peer.dart';
import '../../../widgets/common/dialog_button.dart';
import '../../../widgets/common/nym_sheet.dart';
import '../../../widgets/nym_icons.dart';
import '../../i18n/i18n.dart';
import '../../identity/modal_chrome.dart';
import '../../mesh/mesh_controller.dart' show meshScreenOpenProvider;
import '../share_sheet.dart';
import '../share_target.dart';
import 'nearby_interaction.dart';
import 'nearby_link.dart';

const int kNearbySendIntervalMs = 3000;

List<MeshPeer> nearbyCandidates(
    List<MeshPeer> peers, bool Function(String pubkey) isBlocked) {
  final list = [
    for (final p in peers)
      if ((p.nostrPubkey ?? '').isNotEmpty &&
          p.nostrLinkVerified &&
          !isBlocked(p.nostrPubkey!.toLowerCase()))
        p,
  ];
  list.sort((a, b) {
    if (a.isDirectLink != b.isDirectLink) return a.isDirectLink ? -1 : 1;
    final byRssi = b.rssi.compareTo(a.rssi);
    return byRssi != 0 ? byRssi : a.peerID.compareTo(b.peerID);
  });
  return list;
}

class NearbySendGuard {
  final Map<String, int> _last = {};

  bool allow(String peerID, int now) {
    final last = _last[peerID];
    if (last != null && now - last < kNearbySendIntervalMs) return false;
    _last[peerID] = now;
    return true;
  }
}

String _nickOf(MeshPeer p) => nearbyPeerLabel(p.nickname, p.peerID);

class NearbyShareSheet extends ConsumerStatefulWidget {
  const NearbyShareSheet({super.key, required this.target});

  final ShareTarget target;

  static Future<void> open(BuildContext context, ShareTarget target) =>
      ShareSheet.show(context, NearbyShareSheet(target: target));

  @override
  ConsumerState<NearbyShareSheet> createState() => _NearbyShareSheetState();
}

class _NearbyShareSheetState extends ConsumerState<NearbyShareSheet>
    with WidgetsBindingObserver {
  final NearbySendGuard _guard = NearbySendGuard();
  late final NearbyNiHub _hub;
  NearbyNiSession? _session;
  List<MeshPeer> _candidates = const [];
  String? _selected;
  String? _sentTo;
  bool _background = false;

  @override
  void initState() {
    super.initState();
    _hub = ref.read(nearbyNiHubProvider);
    WidgetsBinding.instance.addObserver(this);
    _candidates = nearbyCandidates(
        ref.read(nearbyRawPeersProvider), ref.read(nearbyBlockedProvider));
    _startNi();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopNi());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _background = false;
        _startNi();
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _background = true;
        unawaited(_stopNi());
    }
  }

  bool _eligible(String peerID) =>
      _candidates.any((p) => p.peerID == peerID && p.isDirectLink);

  void _startNi() {
    if (_session != null || _background) return;
    final platform = ref.read(niPlatformProvider);
    final link = ref.read(nearbyLinkProvider);
    if (platform == null || link == null) return;
    final session = NearbyNiSession(
      platform: platform,
      link: link,
      isEligible: _eligible,
      now: ref.read(nearbyClockProvider),
    );
    _session = session;
    _hub.session = session;
    session.addListener(_onNi);
    unawaited(session.start(_candidates));
  }

  Future<void> _stopNi() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    if (identical(_hub.session, session)) _hub.session = null;
    session.removeListener(_onNi);
    await session.stop();
    session.dispose();
  }

  void _onNi() {
    if (mounted) setState(() {});
  }

  Future<void> _send(MeshPeer peer) async {
    final link = ref.read(nearbyLinkProvider);
    if (link == null) return;
    if (!_guard.allow(peer.peerID, ref.read(nearbyClockProvider)())) return;
    final ok = await link.sendShare(peer.peerID, widget.target.codeLink);
    if (!mounted) return;
    setState(() => _sentTo = ok ? _nickOf(peer) : null);
  }

  void _openMesh() {
    ref.read(meshScreenOpenProvider.notifier).state = true;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final running = ref.watch(nearbyMeshRunningProvider);
    final link = ref.watch(nearbyLinkProvider);
    _candidates = nearbyCandidates(
        ref.watch(nearbyRawPeersProvider), ref.watch(nearbyBlockedProvider));
    final on = running && link != null;
    if (!on && _session != null) unawaited(_stopNi());
    final byId = {for (final p in _candidates) p.peerID: p};
    final selected = byId[_selected];
    final session = _session;
    final niOn = on && session != null && session.active;
    final pointed = niOn ? byId[session.highlighted] : null;
    void close() => Navigator.of(context).maybePop();

    final content = <Widget>[];
    if (!on) {
      content.addAll([
        Text(
          tr('Nearby sharing needs the Bluetooth mesh to be on.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.text, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 16),
        Center(
          child: DialogButton(
            key: const ValueKey('nearby-open-mesh'),
            label: tr('Bluetooth Mesh'),
            onTap: _openMesh,
          ),
        ),
      ]);
    } else if (_candidates.isEmpty) {
      content.add(Text(
        tr('No Nymchat users nearby'),
        textAlign: TextAlign.center,
        style: TextStyle(color: c.textDim, fontSize: 14, height: 1.4),
      ));
    } else {
      if (niOn) {
        content.addAll([
          Text(
            session.supportsDirection
                ? tr('Point at the iPhone you want to share with')
                : tr('Hold phones close together'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 10),
        ]);
      }
      if (pointed != null) {
        content.addAll([
          _PointedCard(
            nick: _nickOf(pointed),
            onSend: () => unawaited(_send(pointed)),
          ),
          const SizedBox(height: 12),
        ]);
      }
      for (final p in _candidates) {
        content.add(KeyedSubtree(
          key: ValueKey('nearby-peer-${p.peerID}'),
          child: _PeerRow(
            nick: _nickOf(p),
            selected: p.peerID == _selected,
            onTap: () => setState(() {
              _selected = p.peerID;
              _sentTo = null;
            }),
          ),
        ));
      }
      content.addAll([
        const SizedBox(height: 14),
        KeyedSubtree(
          key: const ValueKey('nearby-send'),
          child: DialogButton(
            label: tr('Send'),
            fullWidth: true,
            onTap: selected == null ? null : () => unawaited(_send(selected)),
          ),
        ),
      ]);
      final sentTo = _sentTo;
      if (sentTo != null) {
        content.addAll([
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: Text(
              tr('Sent to {nick}. They need to accept it.', {'nick': sentTo}),
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontSize: 12, height: 1.35),
            ),
          ),
        ]);
      }
    }

    final body = Stack(
      children: [
        ModalChrome.box(
          c,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ModalChrome.header(c, tr('Share nearby')),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: content,
                ),
              ),
            ],
          ),
        ),
        ModalChrome.closeChip(c, close),
      ],
    );
    return nymSheetOr(
      context,
      SingleChildScrollView(child: body),
      (body) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 820),
          child: SingleChildScrollView(child: body),
        ),
      ),
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({
    required this.nick,
    required this.selected,
    required this.onTap,
  });

  final String nick;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rsm,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                NymSvgIcon(NymIcons.bluetooth,
                    size: 18, color: selected ? c.primary : c.textDim),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    nick,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? c.primary : c.text,
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, size: 18, color: c.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PointedCard extends StatelessWidget {
  const _PointedCard({required this.nick, required this.onSend});

  final String nick;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      key: const ValueKey('nearby-pointed'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: c.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.primary.withValues(alpha: 0.6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            nick,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: c.text, fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          DialogButton(
            key: const ValueKey('nearby-pointed-send'),
            label: tr('Send'),
            fullWidth: true,
            onTap: onSend,
          ),
        ],
      ),
    );
  }
}
