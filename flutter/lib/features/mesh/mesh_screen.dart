import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/common/nym_switch.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'mesh_bridge.dart' show kMeshNearbyChannel;
import 'ghost_mode_button.dart';
import 'mesh_controller.dart';
import 'mesh_diagnostics.dart';

/// Mesh status and peer discovery, rendered as an overlay inside the home shell (not a route) so the drawer opens over it.
class MeshScreen extends ConsumerStatefulWidget {
  const MeshScreen({super.key, this.onOpenSidebar});

  /// Opens the shell drawer on compact layouts; null on wide layouts.
  final VoidCallback? onOpenSidebar;

  @override
  ConsumerState<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends ConsumerState<MeshScreen> {
  void _close() {
    ref.read(meshScreenOpenProvider.notifier).state = false;
  }

  /// Lowercase letters and digits only, so a name resolves to the same room on every device; '' if nothing remains.
  String _sanitizeGroupName(String raw) {
    final lower = raw.trim().toLowerCase().replaceAll(RegExp(r'^#+'), '');
    final cleaned =
        lower.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  /// Prompts for a group name and optional password, joins via the mesh controller, then opens it.
  Future<void> _promptJoinMeshGroup() async {
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final c = context.nym;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.bgSecondary,
        title: Text(tr('Mesh group'), style: TextStyle(color: c.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: TextStyle(color: c.inputText),
              decoration: InputDecoration(
                prefixText: '#',
                prefixStyle: TextStyle(color: c.textDim),
                hintText: tr('group name'),
                hintStyle: TextStyle(color: c.textDim),
              ),
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: true,
              style: TextStyle(color: c.inputText),
              decoration: InputDecoration(
                hintText: tr('password (optional — encrypts the group)'),
                hintStyle: TextStyle(color: c.textDim),
              ),
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('Cancel'), style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Join'), style: TextStyle(color: c.primary)),
          ),
        ],
      ),
    );
    if (result != true || !mounted) return;
    final name = _sanitizeGroupName(nameCtrl.text);
    if (name.isEmpty) return;
    await ref
        .read(meshControllerProvider.notifier)
        .joinChannel(name, password: passCtrl.text);
    if (!mounted) return;
    ref.read(appStateProvider.notifier).switchChannel(name);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Don't watch meshControllerProvider here; it ticks constantly while scanning.
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: c.glassBorder)),
        titleSpacing: 8,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            _MeshNavBtn(
              svg: NymIcons.chevronLeft,
              tooltip: tr('Go back'),
              onTap: _close,
            ),
            _MeshNavBtn(
              svg: NymIcons.chevronRight,
              tooltip: tr('Go forward'),
              // Nothing ahead of the overlay, so forward rests disabled.
              onTap: null,
            ),
            const SizedBox(width: 4),
            NymSvgIcon(NymIcons.bluetooth, size: 18, color: c.primary),
            const SizedBox(width: 8),
            Text(tr('Bluetooth Mesh'),
                style: TextStyle(
                    color: c.text, fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          _MeshHeaderToggle(
            svg: NymIcons.bell,
            tooltip: tr('Notifications'),
            badge: ref.watch(
                    settingsProvider.select((s) => s.notificationsEnabled))
                ? ref.watch(notificationHistoryProvider.select((s) => s.unread))
                : 0,
            onTap: () => showNotificationsPanel(context),
          ),
          if (widget.onOpenSidebar != null) ...[
            const SizedBox(width: 8),
            _MeshHeaderToggle(
              svg: NymIcons.menu,
              tooltip: tr('Menu'),
              // Instance fields don't promote; the surrounding null check guarantees this.
              onTap: widget.onOpenSidebar!,
            ),
          ],
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Consumer(builder: (context, ref, _) {
            return _StatusBar(
                mesh: ref.watch(meshControllerProvider), colors: c);
          }),
          // Public #mesh channel, mixing Nostr kind-20000 and Bluetooth-mesh messages.
          ListTile(
            leading: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Text('#',
                  style: TextStyle(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 18)),
            ),
            title: Text('#mesh', style: TextStyle(color: c.text)),
            subtitle: Text(tr('Public channel · everyone in range'),
                style: TextStyle(color: c.textDim, fontSize: 12)),
            trailing:
                NymSvgIcon(NymIcons.bluetooth, size: 16, color: c.primary),
            onTap: () {
              ref
                  .read(appStateProvider.notifier)
                  .switchChannel(kMeshNearbyChannel);
              // Explicit close: the shell's view listener won't fire if #mesh was already active.
              _close();
            },
          ),
          // Named mesh group: membership is by shared name, and a password makes it end-to-end encrypted over the air.
          ListTile(
            leading: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: NymSvgIcon(NymIcons.groupAddMembers,
                  size: 18, color: c.primary),
            ),
            title: Text(tr('Join or create a mesh group'),
                style: TextStyle(color: c.text)),
            subtitle: Text(tr('A named room · optional password for privacy'),
                style: TextStyle(color: c.textDim, fontSize: 12)),
            trailing: Icon(Icons.add, size: 18, color: c.primary),
            onTap: _promptJoinMeshGroup,
          ),
          Divider(height: 1, color: c.border),
          Expanded(
            child: Consumer(builder: (context, ref, _) {
              return _PeersList(
                  mesh: ref.watch(meshControllerProvider), colors: c);
            }),
          ),
          Divider(height: 1, color: c.border),
          _MeshDiagnostics(colors: c),
        ],
      ),
    );
  }
}

/// Collapsible live mesh log for devices without adb or Console access.
class _MeshDiagnostics extends StatefulWidget {
  const _MeshDiagnostics({required this.colors});
  final NymColors colors;

  @override
  State<_MeshDiagnostics> createState() => _MeshDiagnosticsState();
}

class _MeshDiagnosticsState extends State<_MeshDiagnostics> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
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
                      final text =
                          MeshDiagnostics.instance.entries.value.join('\n');
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
                if (entries.isEmpty) {
                  return Center(
                    child: Text(tr('No mesh activity yet'),
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => Text(
                    entries[i],
                    style: TextStyle(
                      color: entries[i].contains('DROPPED')
                          ? const Color(0xFFE0736B)
                          : (entries[i].contains('LANDED')
                              ? const Color(0xFF6BCB77)
                              : c.textDim),
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.35,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Small boxed back/forward chevron; disabled rests faint and ignores taps.
class _MeshNavBtn extends StatelessWidget {
  const _MeshNavBtn({required this.svg, this.onTap, this.tooltip});
  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final disabled = onTap == null;
    final btn = InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        child: NymSvgIcon(
          svg,
          size: 18,
          color: disabled ? c.textDim.withValues(alpha: 0.3) : c.textDim,
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}

/// Boxed header icon button with an optional unread badge.
class _MeshHeaderToggle extends StatelessWidget {
  const _MeshHeaderToggle({
    required this.svg,
    required this.onTap,
    this.tooltip,
    this.badge = 0,
  });
  final String svg;
  final VoidCallback onTap;
  final String? tooltip;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final box = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.isLight ? const Color(0xD9FFFFFF) : const Color(0xCC141423),
        borderRadius: NymRadius.rsm,
        border: Border.all(
          color:
              c.isLight ? Colors.black.withValues(alpha: 0.08) : c.glassBorder,
        ),
      ),
      child: NymSvgIcon(svg, size: 20, color: c.primary),
    );
    final child = InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: badge > 0
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                box,
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.danger,
                      borderRadius: const BorderRadius.all(Radius.circular(8)),
                    ),
                    child: Text(
                      badge > 99 ? '99+' : '$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : box,
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: child) : child;
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.mesh, required this.colors});
  final MeshUiState mesh;
  final NymColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(settingsProvider.select((s) => s.meshEnabled));
    final needsPermission =
        enabled && mesh.availability == MeshTransportAvailability.unauthorized;
    return Container(
      color: colors.bgSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_statusLabel(enabled),
                    style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                if (mesh.myPeerID != null)
                  Text('You: ${mesh.myPeerID}  •  ${mesh.linkCount} link(s)',
                      style: TextStyle(
                          color: colors.textDim,
                          fontSize: 11,
                          fontFamily: 'monospace')),
              ],
            ),
          ),
          if (needsPermission)
            TextButton(
              onPressed: () => ref
                  .read(meshControllerProvider.notifier)
                  .openSystemSettings(),
              child:
                  Text(tr('Enable'), style: TextStyle(color: colors.primary)),
            ),
          GhostModeButton(colors: colors),
          NymSwitch(
            value: enabled,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setMeshEnabled(v),
          ),
        ],
      ),
    );
  }

  String _statusLabel(bool enabled) {
    if (!enabled) return tr('Mesh off');
    if (mesh.error != null) return tr('Mesh error');
    switch (mesh.availability) {
      case MeshTransportAvailability.ready:
        return mesh.running ? tr('Mesh active') : tr('Starting…');
      case MeshTransportAvailability.poweredOff:
        return tr('Turn on Bluetooth');
      case MeshTransportAvailability.unauthorized:
        return tr('Bluetooth permission needed');
      case MeshTransportAvailability.unsupported:
        return tr('Mesh not supported on this device');
      case MeshTransportAvailability.unknown:
        return tr('Starting…');
    }
  }
}

class _PeersList extends ConsumerWidget {
  const _PeersList({required this.mesh, required this.colors});
  final MeshUiState mesh;
  final NymColors colors;

  static final RegExp _hex64Re =
      RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  /// Peer name with its `#xxxx` suffix dimmed, derived from the verified pubkey when there is one.
  Widget _peerName(MeshPeer peer, NymColors c) {
    final pk = peer.nostrPubkey;
    final display = (pk != null && _hex64Re.hasMatch(pk))
        ? getNymFromPubkey(peer.displayName, pk)
        : peer.displayName;
    final parts = splitNymSuffix(display);
    return Text.rich(
      TextSpan(
        text: parts.base,
        children: parts.suffix.isEmpty
            ? null
            : [
                TextSpan(
                  text: parts.suffix,
                  style: TextStyle(
                    color: c.textDim.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: c.text),
    );
  }

  String _pingLabel(MeshPingState? ping) {
    if (ping == null) return '';
    if (ping.isWaiting) return '  • pinging…';
    if (ping.lost) return '  • no reply';
    final hops = ping.hops;
    final hopLabel = hops == null ? '' : ', $hops hop${hops == 1 ? '' : 's'}';
    return '  • ${ping.roundTripMs}ms$hopLabel';
  }

  void _openPeer(BuildContext context, WidgetRef ref, MeshPeer peer) {
    final pubkey =
        ref.read(meshControllerProvider.notifier).bridge?.openPeerDm(peer);
    if (pubkey == null) return;
    ref.read(appStateProvider.notifier).switchView(ChatView.pm(pubkey));
    // Explicit close in case this DM was already active.
    ref.read(meshScreenOpenProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (mesh.peers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            tr('No peers discovered yet.\nMake sure Bluetooth is on.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textDim, height: 1.5),
          ),
        ),
      );
    }
    final peers = [...mesh.peers]
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: colors.border),
      itemBuilder: (_, i) {
        final peer = peers[i];
        final seed = peer.nostrPubkey ?? peer.peerID;
        final ping = mesh.pings[peer.peerID];
        return ListTile(
          leading: NymAvatar(
            seed: seed,
            size: 38,
            imageUrl: peer.avatarUrl,
            label: peer.displayName,
          ),
          title: _peerName(peer, colors),
          subtitle: Text(
            peer.peerID +
                (peer.nostrLinkVerified ? '  • linked' : '') +
                _pingLabel(ping),
            style: TextStyle(
                color: colors.textDim, fontSize: 11, fontFamily: 'monospace'),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The echo shows whether a peer is actually in range, which the list can't.
              IconButton(
                icon: NymSvgIcon(NymIcons.radar,
                    size: 16, color: colors.textDim),
                tooltip: tr('Ping'),
                // The default 48px tap target is too wide beside the lock.
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 34, minHeight: 34),
                onPressed: ping?.isWaiting ?? false
                    ? null
                    : () => ref
                        .read(meshControllerProvider.notifier)
                        .ping(peer.peerID),
              ),
              NymSvgIcon(NymIcons.lock, size: 16, color: colors.purple),
            ],
          ),
          onTap: () => _openPeer(context, ref, peer),
        );
      },
    );
  }
}
