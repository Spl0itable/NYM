import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/chat_pane.dart' show NymPageAction, NymPageHeader;
import '../../widgets/common/list_empty_note.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/nym_focusable.dart';
import '../../widgets/common/nym_switch.dart';
import '../../widgets/common/nym_tooltip.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/channel_list_item.dart' show SidebarChannelTile;
import '../../widgets/sidebar/sidebar_chrome.dart';
import '../../widgets/sidebar/sidebar_row_gestures.dart';
import '../i18n/i18n.dart';
import '../identity/modal_chrome.dart';
import 'ghost_mode.dart';
import 'ghost_mode_button.dart';
import 'mesh_bridge.dart' show kMeshNearbyChannel;
import 'mesh_controller.dart';
import 'mesh_diagnostics.dart';
import 'mesh_sheets.dart';

String meshStatusSubtitle(MeshUiState mesh,
    {required bool enabled, required bool ghost}) {
  String base;
  if (!enabled) {
    base = tr('Off');
  } else if (mesh.error != null) {
    base = tr('Mesh error');
  } else if (mesh.availability == MeshTransportAvailability.unsupported) {
    base = tr('Not supported on this device');
  } else if (mesh.availability == MeshTransportAvailability.unauthorized) {
    base = tr('Bluetooth permission needed');
  } else if (mesh.availability == MeshTransportAvailability.poweredOff) {
    base = tr('Bluetooth is off');
  } else if (!mesh.running) {
    base = tr('Starting…');
  } else if (mesh.peers.isEmpty) {
    base = tr('Searching · no peers yet');
  } else {
    final n = mesh.peers.length;
    final l = mesh.linkCount;
    base = [
      n == 1 ? tr('1 peer') : tr('{count} peers', {'count': n}),
      if (l > 0) l == 1 ? tr('1 link') : tr('{count} links', {'count': l}),
    ].join(' · ');
  }
  if (enabled && ghost) return '$base · ${tr('Ghost Mode')}';
  return base;
}

String meshPeerLine(MeshPeer peer, MeshPingState? ping) {
  if (ping != null) {
    if (ping.isWaiting) return tr('Pinging…');
    if (ping.lost) return tr('No reply to ping');
    final ms = ping.roundTripMs ?? 0;
    final hops = ping.hops;
    if (hops == null) return tr('{ms} ms', {'ms': ms});
    if (hops == 1) return tr('1 hop · {ms} ms', {'ms': ms});
    return tr('{hops} hops · {ms} ms', {'hops': hops, 'ms': ms});
  }
  return peer.isVerified ? tr('Verified') : tr('Not verified yet');
}

String _sanitizeGroupName(String raw) {
  final lower = raw.trim().toLowerCase().replaceAll(RegExp(r'^#+'), '');
  final cleaned = lower.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
}

class MeshScreen extends ConsumerStatefulWidget {
  const MeshScreen({super.key, this.onOpenSidebar, this.onBackToList});

  final VoidCallback? onOpenSidebar;
  final VoidCallback? onBackToList;

  @override
  ConsumerState<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends ConsumerState<MeshScreen> {
  void _close() {
    ref.read(meshScreenOpenProvider.notifier).state = false;
  }

  Future<void> _promptJoinMeshGroup() async {
    final result = await showMeshSheet<(String, String)>(
        context, (_) => const _JoinSheet());
    if (result == null || !mounted) return;
    final name = _sanitizeGroupName(result.$1);
    if (name.isEmpty) return;
    await ref
        .read(meshControllerProvider.notifier)
        .joinChannel(name, password: result.$2);
    if (!mounted) return;
    ref.read(appStateProvider.notifier).switchChannel(name);
    _close();
  }

  void _openPeer(MeshPeer peer) {
    final linked = peer.nostrLinkVerified &&
        peer.nostrPubkey != null &&
        peer.nostrPubkey!.length == 64;
    final pubkey =
        ref.read(meshControllerProvider.notifier).bridge?.openPeerDm(peer) ??
            (linked ? peer.nostrPubkey!.toLowerCase() : null);
    if (pubkey == null) return;
    if (linked) {
      ref
          .read(appStateProvider.notifier)
          .ensurePMConversation(pubkey, nym: peer.displayName);
    }
    ref.read(appStateProvider.notifier).switchView(ChatView.pm(pubkey));
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = ref.watch(settingsProvider.select((s) => s.meshEnabled));
    final ghost = ref.watch(ghostModeProvider.select((s) => s.enabled));
    final subtitle = ref.watch(meshControllerProvider.select(
        (m) => meshStatusSubtitle(m, enabled: enabled, ghost: ghost)));
    return Material(
      color: c.bg,
      child: Column(
        children: [
          NymPageHeader(
            tile: NymSvgIcon(NymIcons.bluetooth, size: 18, color: c.primary),
            title: tr('Bluetooth mesh'),
            subtitle: subtitle,
            onBack: _close,
            onBackToList: widget.onBackToList,
            onOpenSidebar: widget.onOpenSidebar,
            actions: [
              NymPageAction(
                key: const ValueKey('meshGhost'),
                svg: NymIcons.ghost,
                tooltip: ghost ? tr('Ghost Mode on') : tr('Ghost Mode off'),
                active: ghost,
                disabled: !enabled,
                onTap: () => toggleGhostMode(context, ref),
              ),
            ],
          ),
          Expanded(
            child: Consumer(builder: (context, ref, _) {
              final mesh = ref.watch(meshControllerProvider);
              return _MeshBody(
                mesh: mesh,
                enabled: enabled,
                onOpenMeshChannel: () {
                  ref
                      .read(appStateProvider.notifier)
                      .switchChannel(kMeshNearbyChannel);
                  _close();
                },
                onJoin: _promptJoinMeshGroup,
                onOpenPeer: _openPeer,
              );
            }),
          ),
          Consumer(builder: (context, ref, _) {
            return _MeshDiagnostics(mesh: ref.watch(meshControllerProvider));
          }),
        ],
      ),
    );
  }
}

class _MeshBody extends ConsumerWidget {
  const _MeshBody({
    required this.mesh,
    required this.enabled,
    required this.onOpenMeshChannel,
    required this.onJoin,
    required this.onOpenPeer,
  });

  final MeshUiState mesh;
  final bool enabled;
  final VoidCallback onOpenMeshChannel;
  final VoidCallback onJoin;
  final ValueChanged<MeshPeer> onOpenPeer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final textSize =
        ref.watch(settingsProvider.select((s) => s.textSize)).toDouble();
    final needsPermission =
        enabled && mesh.availability == MeshTransportAvailability.unauthorized;
    final poweredOff =
        enabled && mesh.availability == MeshTransportAvailability.poweredOff;
    final short = mesh.myPeerID == null
        ? ''
        : (mesh.myPeerID!.length > 8
            ? mesh.myPeerID!.substring(0, 8)
            : mesh.myPeerID!);
    final String powerSub;
    if (!enabled) {
      powerSub = tr('Chat with people nearby, no internet needed');
    } else if (needsPermission) {
      powerSub = tr('Waiting for permission');
    } else if (poweredOff) {
      powerSub = tr('Turn on Bluetooth');
    } else if (short.isEmpty) {
      powerSub = tr('Starting…');
    } else {
      powerSub = tr('On · your mesh ID {id}', {'id': short});
    }
    final peers = [...mesh.peers]
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final peersTitle = enabled && mesh.running && peers.isNotEmpty
        ? tr('Peers nearby ({count})', {'count': peers.length})
        : tr('Peers nearby');
    final String? empty;
    if (!enabled) {
      empty = tr('Turn the mesh on to find people nearby.');
    } else if (needsPermission) {
      empty = tr('Allow Bluetooth to find people nearby.');
    } else if (poweredOff) {
      empty = tr('Turn on Bluetooth to find people nearby.');
    } else if (peers.isEmpty) {
      empty = tr(
          'No one in range yet. Peers show up when another Nymchat device is nearby.');
    } else {
      empty = null;
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(4, 4, 4, 16),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: NymField.fill(c),
                borderRadius: NymRadius.rsm,
                border: Border.all(color: NymField.border(c)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Mesh'),
                            style: TextStyle(
                                color: c.text,
                                fontSize: NymType.md,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(powerSub,
                            key: const ValueKey('meshPowerSub'),
                            style: TextStyle(
                                color: c.textDim, fontSize: NymType.sm)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Semantics(
                    label: tr('Bluetooth mesh'),
                    toggled: enabled,
                    child: NymSwitch(
                      key: const ValueKey('meshPowerSwitch'),
                      value: enabled,
                      onChanged: (v) =>
                          ref.read(settingsProvider.notifier).setMeshEnabled(v),
                    ),
                  ),
                ],
              ),
            ),
            if (needsPermission || poweredOff)
              Container(
                key: const ValueKey('meshBanner'),
                margin: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                decoration: BoxDecoration(
                  color: c.warning.withValues(alpha: 0.08),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(color: c.warning.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        needsPermission
                            ? tr('Nymchat needs Bluetooth permission to find people nearby.')
                            : tr('Turn on Bluetooth to find people nearby.'),
                        style: TextStyle(
                            color: c.text, fontSize: NymType.sm, height: 1.4),
                      ),
                    ),
                    if (needsPermission) ...[
                      const SizedBox(width: 10),
                      ModalChrome.sendButton(
                        c,
                        tr('Allow'),
                        () => ref
                            .read(meshControllerProvider.notifier)
                            .openSystemSettings(),
                      ),
                    ],
                  ],
                ),
              ),
            _SectionTitle(tr('Channels')),
            _MeshRow(
              key: const ValueKey('meshChannelRow'),
              textSize: textSize,
              leading: const SidebarChannelTile(geohash: true),
              title: Text('#mesh',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _nameStyle(c, textSize)),
              sub: tr('Public · everyone in range'),
              onTap: onOpenMeshChannel,
            ),
            _MeshRow(
              key: const ValueKey('meshJoinRow'),
              textSize: textSize,
              leading: SidebarChannelTile(geohash: false, svg: NymIcons.plus),
              title: Text(tr('Join or create a mesh group'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _nameStyle(c, textSize)),
              sub: tr('Named room · optional password'),
              onTap: onJoin,
            ),
            _SectionTitle(peersTitle),
            if (empty != null)
              KeyedSubtree(
                key: const ValueKey('meshPeersEmpty'),
                child: ListEmptyNote(text: empty),
              )
            else
              for (final peer in peers)
                _PeerRow(
                  key: ValueKey('meshPeer-${peer.peerID}'),
                  peer: peer,
                  ping: mesh.pings[peer.peerID],
                  textSize: textSize,
                  onTap: () => onOpenPeer(peer),
                ),
          ],
        ),
      ),
    );
  }
}

TextStyle _nameStyle(NymColors c, double textSize) => TextStyle(
      color: c.text,
      fontSize: textSize,
      fontWeight: FontWeight.w400,
      height: 1.3,
    );

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Semantics(
        header: true,
        child: Text(
          title.toUpperCase(),
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: c.textDim,
            fontSize: 10,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MeshRow extends StatelessWidget {
  const _MeshRow({
    super.key,
    required this.leading,
    required this.title,
    required this.sub,
    required this.onTap,
    required this.textSize,
    this.trailing,
    this.tooltip,
  });

  final Widget leading;
  final Widget title;
  final String sub;
  final VoidCallback onTap;
  final double textSize;
  final Widget? trailing;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hoverFill = c.isLight
        ? Colors.black.withValues(alpha: 0.04)
        : Colors.white.withValues(alpha: 0.06);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
                color: c.textDim,
                fontSize: NymType.sm,
                height: kSidebarSubLine / NymType.sm),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: NymFocusable(
        onActivate: onTap,
        radius: NymRadius.rxs,
        child: SidebarRowGestures(
          onTap: onTap,
          onShowMenu: (_) => false,
          builder: (context, hovered) => Container(
            constraints: const BoxConstraints(minHeight: kSidebarRowMinH),
            padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 6, 6, 6),
            decoration: BoxDecoration(
              color: hovered ? hoverFill : Colors.transparent,
              borderRadius: NymRadius.rxs,
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: kSidebarGap),
                Expanded(
                  child: tooltip == null
                      ? text
                      : NymTooltip(message: tooltip, child: text),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PeerRow extends ConsumerWidget {
  const _PeerRow({
    super.key,
    required this.peer,
    required this.ping,
    required this.textSize,
    required this.onTap,
  });

  final MeshPeer peer;
  final MeshPingState? ping;
  final double textSize;
  final VoidCallback onTap;

  static final RegExp _hex64Re = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final pk = peer.nostrPubkey;
    final display = (pk != null && _hex64Re.hasMatch(pk))
        ? getNymFromPubkey(peer.displayName, pk)
        : (peer.nickname == null || peer.nickname!.isEmpty
            ? peer.peerID.substring(0, peer.peerID.length > 8 ? 8 : peer.peerID.length)
            : peer.displayName);
    final parts = splitNymSuffix(display);
    final waiting = ping?.isWaiting ?? false;
    return _MeshRow(
      textSize: textSize,
      tooltip: '${peer.displayName} · ${peer.peerID}',
      leading: NymAvatar(
        seed: pk ?? peer.peerID,
        size: kSidebarIcon,
        imageUrl: peer.avatarUrl,
        label: peer.displayName,
      ),
      title: Text.rich(
        TextSpan(
          text: parts.base,
          children: parts.suffix.isEmpty
              ? null
              : [
                  TextSpan(
                    text: parts.suffix,
                    style: TextStyle(color: c.textDim.withValues(alpha: 0.7)),
                  ),
                ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _nameStyle(c, textSize),
      ),
      sub: meshPeerLine(peer, ping),
      onTap: onTap,
      trailing: IconButton(
        key: ValueKey('meshPing-${peer.peerID}'),
        icon: NymSvgIcon(NymIcons.radar,
            size: 16,
            color: waiting ? c.textDim.withValues(alpha: 0.4) : c.textDim),
        tooltip: tr('Ping'),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: waiting
            ? null
            : () => ref.read(meshControllerProvider.notifier).ping(peer.peerID),
      ),
    );
  }
}

class _MeshDiagnostics extends StatefulWidget {
  const _MeshDiagnostics({required this.mesh});
  final MeshUiState mesh;

  @override
  State<_MeshDiagnostics> createState() => _MeshDiagnosticsState();
}

class _MeshDiagnosticsState extends State<_MeshDiagnostics> {
  bool _expanded = false;

  List<String> _ids() => [
        if (widget.mesh.myPeerID != null)
          '${tr('Your mesh ID')}  ${widget.mesh.myPeerID}',
        for (final p in widget.mesh.peers) '${p.displayName}  ${p.peerID}',
      ];

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final ids = _ids();
    final mono = TextStyle(
        color: c.textDim, fontSize: 11, fontFamily: 'monospace', height: 1.35);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const ValueKey('meshDiagnostics'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    NymSvgIcon(
                      _expanded ? NymIcons.chevronDown : NymIcons.chevronRight,
                      size: 14,
                      color: c.textDim,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(tr('Mesh diagnostics'),
                          style: TextStyle(
                              color: c.textDim,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
                    if (_expanded) ...[
                      TextButton(
                        onPressed: () {
                          final text = [
                            ...ids,
                            ...MeshDiagnostics.instance.entries.value,
                          ].join('\n');
                          Clipboard.setData(ClipboardData(text: text));
                        },
                        child: Text(tr('Copy'),
                            style: TextStyle(color: c.primary, fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: MeshDiagnostics.instance.clear,
                        child: Text(tr('Clear'),
                            style: TextStyle(color: c.textDim, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_expanded)
              SizedBox(
                height: 190,
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: MeshDiagnostics.instance.entries,
                  builder: (context, entries, _) {
                    if (entries.isEmpty && ids.isEmpty) {
                      return Center(
                        child: Text(tr('No mesh activity yet'),
                            style: TextStyle(color: c.textDim, fontSize: 12)),
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final line in ids)
                          SelectableText(line,
                              key: ValueKey('meshDiagId-$line'), style: mono),
                        if (ids.isNotEmpty && entries.isNotEmpty)
                          const SizedBox(height: 6),
                        for (final e in entries)
                          Text(
                            e,
                            style: mono.copyWith(
                              color: e.contains('DROPPED')
                                  ? const Color(0xFFE0736B)
                                  : (e.contains('LANDED')
                                      ? const Color(0xFF6BCB77)
                                      : c.textDim),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _JoinSheet extends StatefulWidget {
  const _JoinSheet();

  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  final _name = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((_name.text, _pass.text));

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MeshSheetFrame(
      title: tr('Mesh group'),
      actions: [
        ModalChrome.iconButton(c, tr('Cancel'), () => Navigator.of(context).pop()),
        KeyedSubtree(
          key: const ValueKey('meshJoinSubmit'),
          child: ModalChrome.sendButton(c, tr('Join'), _submit),
        ),
      ],
      children: [
        TextField(
          key: const ValueKey('meshJoinName'),
          controller: _name,
          autofocus: true,
          style: TextStyle(color: c.inputText),
          decoration: NymField.decoration(c, hint: tr('Group name')).copyWith(
            prefixText: '#',
            prefixStyle: TextStyle(color: NymField.icon(c)),
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('meshJoinPassword'),
          controller: _pass,
          obscureText: true,
          style: TextStyle(color: c.inputText),
          decoration: NymField.decoration(c,
              hint: tr('Password (optional, encrypts the group)')),
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }
}
