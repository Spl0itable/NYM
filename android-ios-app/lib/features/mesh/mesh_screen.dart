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
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/sidebar.dart';
import '../i18n/i18n.dart';
import 'mesh_bridge.dart' show kMeshNearbyChannel;
import 'mesh_controller.dart';
import 'mesh_diagnostics.dart';

/// Bluetooth-mesh status + discovery surface. Conversations themselves live in
/// the normal Channels / Private Messages lists and open in the canonical
/// ChatPane — this screen only shows radio status and the peers in range, and
/// lets you start (or jump into) a mesh DM with a nearby peer or the public
/// `#mesh` channel.
class MeshScreen extends ConsumerStatefulWidget {
  const MeshScreen({super.key});

  /// Pushes the mesh screen with a route that does NOT install iOS's left-edge
  /// back-swipe gesture. That system pop-gesture otherwise wins the gesture
  /// arena over the Scaffold's `drawerEdgeDragWidth`, so a left-to-right swipe
  /// pops this route ("go back to last place") instead of opening the sidebar.
  /// With no route pop-gesture, the drawer's own edge-drag handles the swipe and
  /// the sidebar slides in, matching the rest of the app.
  static Route<void> route() => _MeshPageRoute();

  @override
  ConsumerState<MeshScreen> createState() => _MeshScreenState();
}

/// A [MaterialPageRoute] whose transition never installs the Cupertino
/// interactive back-swipe. We force the (non-Cupertino) fade-upwards builder so
/// that on iOS no `_CupertinoBackGestureDetector` is wrapped around the page —
/// leaving the left-edge swipe to the mesh screen's own drawer edge-drag. The
/// small cost is a fade-up push instead of the iOS horizontal slide.
class _MeshPageRoute extends MaterialPageRoute<void> {
  _MeshPageRoute() : super(builder: (_) => const MeshScreen());

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return const FadeUpwardsPageTransitionsBuilder().buildTransitions<void>(
        this, context, animation, secondaryAnimation, child);
  }
}

class _MeshScreenState extends ConsumerState<MeshScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final mesh = ref.watch(meshControllerProvider);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bg,
      // The same off-canvas sidebar the rest of the app uses. Selecting a
      // conversation from it pops the mesh screen so the chosen chat (which
      // lives in the shell beneath this route) is revealed. Scaffold handles
      // the left-edge swipe-to-open natively via [drawerEdgeDragWidth].
      drawerEdgeDragWidth: 60,
      // Opaque backing behind the sidebar. The Sidebar surface is the app-wide
      // translucent `bgSecondary` (0.85), which everywhere else composites over
      // the shell's WallpaperLayer/ambient glow. This pushed route has no such
      // backdrop, so without a solid layer the drawer reads as see-through — the
      // mesh screen (its Bluetooth glyph and all) bleeds through and the sidebar
      // looks blank. A solid `c.bg` under it restores the normal opaque surface.
      drawer: Container(
        width: NymDimens.sidebarDrawerWidth,
        color: c.bg,
        child: Sidebar(
          compact: true,
          onItemSelected: () => Navigator.of(context).maybePop(),
        ),
      ),
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: c.glassBorder)),
        titleSpacing: 8,
        // No back arrow — the hamburger in the actions opens the sidebar,
        // matching the rest of the app's headers. Back/forward chevrons sit to
        // the left of the title (like the channel header's nav buttons).
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            _MeshNavBtn(
              svg: NymIcons.chevronLeft,
              tooltip: tr('Go back'),
              onTap: Navigator.of(context).canPop()
                  ? () => Navigator.of(context).maybePop()
                  : null,
            ),
            _MeshNavBtn(
              svg: NymIcons.chevronRight,
              tooltip: tr('Go forward'),
              // A pushed leaf route has nothing ahead of it — the forward
              // chevron rests disabled, exactly as the chat header's does until
              // you've navigated back.
              onTap: null,
            ),
            const SizedBox(width: 4),
            NymSvgIcon(NymIcons.bluetooth, size: 18, color: c.primary),
            const SizedBox(width: 8),
            Text(tr('Bluetooth Mesh'),
                style: TextStyle(
                    color: c.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          _MeshHeaderToggle(
            svg: NymIcons.bell,
            tooltip: tr('Notifications'),
            badge: ref.watch(settingsProvider
                    .select((s) => s.notificationsEnabled))
                ? ref.watch(
                    notificationHistoryProvider.select((s) => s.unread))
                : 0,
            onTap: () => showNotificationsPanel(context),
          ),
          const SizedBox(width: 8),
          _MeshHeaderToggle(
            svg: NymIcons.menu,
            tooltip: tr('Menu'),
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(mesh: mesh, colors: c),
          // The public #mesh channel — opens in the normal chat view, where it
          // weaves together Nostr (kind-20000) and Bluetooth-mesh messages.
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
              Navigator.of(context).maybePop();
            },
          ),
          Divider(height: 1, color: c.border),
          Expanded(child: _PeersList(mesh: mesh, colors: c)),
          Divider(height: 1, color: c.border),
          _MeshDiagnostics(colors: c),
        ],
      ),
    );
  }
}

/// Live mesh log — the radio lifecycle (power state, scanning, advertising,
/// links) plus, per inbound packet/message, whether the bridge ran, the
/// resolved conversation key, the open view, and whether it LANDED in the store
/// the chat reads. A collapsible bar: collapsed by default so it stays out of
/// the way, tapped open to read and copy the logs on a device with no adb /
/// Console access.
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
        // Collapsible header bar: chevron + title, with Copy/Clear revealed
        // only while expanded.
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

/// A small boxed back/forward chevron matching the channel header's
/// `.channel-nav-btn` (28×28, radius 4, dimmed; disabled rests faint and
/// ignores taps).
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

/// A boxed header icon button matching the main chat header's mobile toggles
/// (`.icon-btn`, 40×40, glass fill) with an optional unread-count badge. Used
/// for the notification bell and the sidebar hamburger in the mesh header.
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
        color: c.isLight
            ? const Color(0xD9FFFFFF)
            : const Color(0xCC141423),
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
                      borderRadius:
                          const BorderRadius.all(Radius.circular(8)),
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
              onPressed: () =>
                  ref.read(meshControllerProvider.notifier).openSystemSettings(),
              child: Text(tr('Enable'), style: TextStyle(color: colors.primary)),
            ),
          Switch(
            value: enabled,
            activeColor: colors.primary,
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

  /// The peer's display name with its trailing `#xxxx` suffix dimmed, matching
  /// how nyms render everywhere else in the app. When the peer has a verified
  /// Nostr pubkey we derive the canonical suffix from it; otherwise we split any
  /// suffix already present on the announced nickname.
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

  void _openPeer(BuildContext context, WidgetRef ref, MeshPeer peer) {
    final pubkey =
        ref.read(meshControllerProvider.notifier).bridge?.openPeerDm(peer);
    if (pubkey == null) return;
    ref.read(appStateProvider.notifier).switchView(ChatView.pm(pubkey));
    Navigator.of(context).maybePop();
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
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.border),
      itemBuilder: (_, i) {
        final peer = peers[i];
        final seed = peer.nostrPubkey ?? peer.peerID;
        return ListTile(
          leading: NymAvatar(
            seed: seed,
            size: 38,
            imageUrl: peer.avatarUrl,
            label: peer.displayName,
          ),
          title: _peerName(peer, colors),
          subtitle: Text(
            peer.peerID + (peer.nostrLinkVerified ? '  • linked' : ''),
            style: TextStyle(
                color: colors.textDim, fontSize: 11, fontFamily: 'monospace'),
          ),
          trailing: NymSvgIcon(NymIcons.lock, size: 16, color: colors.purple),
          onTap: () => _openPeer(context, ref, peer),
        );
      },
    );
  }
}
