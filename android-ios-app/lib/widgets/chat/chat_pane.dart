import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/channels/channel_share.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/pms/new_pm_modal.dart';
import '../../features/polls/poll_create_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import 'composer.dart';
import 'messages_list.dart';

/// Signature for the call-start hook the calls feature wires later. [peer] is
/// the PM peer pubkey (or '' for a channel/group), [video] selects video vs
/// audio. The header never implements calls itself — it only invokes this.
typedef OnStartCall = void Function(String peer, {required bool video});

/// Signature for starting a group call (group id + video flag).
typedef OnStartGroupCall = void Function(String groupId, {required bool video});

/// The main chat column: header + messages list + composer
/// (`main.main-content`, docs/specs/02 §1.1, §5.4–5.5).
class ChatPane extends ConsumerWidget {
  const ChatPane({
    super.key,
    this.onOpenSidebar,
    this.compact = false,
    this.onStartCall,
    this.onStartGroupCall,
  });

  /// Mobile/tablet: opens the off-canvas sidebar drawer (hamburger).
  final VoidCallback? onOpenSidebar;

  /// Mobile/tablet chrome (hamburger + stacked composer).
  final bool compact;

  /// Optional call-start hooks (wired by the calls feature; null = no calls).
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          _ChatHeader(
            onOpenSidebar: onOpenSidebar,
            compact: compact,
            onStartCall: onStartCall,
            onStartGroupCall: onStartGroupCall,
          ),
          const Expanded(child: MessagesList()),
          Composer(compact: compact),
        ],
      ),
    );
  }
}

/// `.chat-header`: title (primary, textSize+3, weight700) + meta line + nav and
/// action icon buttons. Mobile shows the hamburger + a notification toggle.
class _ChatHeader extends ConsumerStatefulWidget {
  const _ChatHeader({
    this.onOpenSidebar,
    required this.compact,
    this.onStartCall,
    this.onStartGroupCall,
  });
  final VoidCallback? onOpenSidebar;
  final bool compact;
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  @override
  ConsumerState<_ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends ConsumerState<_ChatHeader> {
  // A simple back/forward navigation history (channels.js `navigationHistory` /
  // `navigationIndex`). Each entry is a [ChatView]. Forward is disabled when at
  // the tip; back is disabled at the start (like the PWA).
  final List<ChatView> _history = [];
  int _index = -1;
  bool _navigating = false;

  bool get _canBack => _index > 0;
  bool get _canForward => _index >= 0 && _index < _history.length - 1;

  void _recordView(ChatView view) {
    if (_navigating) return;
    if (_index >= 0 && _history[_index] == view) return;
    // Truncate any forward entries, then push.
    if (_index < _history.length - 1) {
      _history.removeRange(_index + 1, _history.length);
    }
    _history.add(view);
    if (_history.length > 50) _history.removeAt(0);
    _index = _history.length - 1;
  }

  void _back() {
    if (!_canBack) return;
    _index--;
    _go(_history[_index]);
  }

  void _forward() {
    if (!_canForward) return;
    _index++;
    _go(_history[_index]);
  }

  void _go(ChatView view) {
    _navigating = true;
    ref.read(appStateProvider.notifier).switchView(view);
    // Reset the flag after the frame so didChangeDependencies doesn't re-record.
    WidgetsBinding.instance.addPostFrameCallback((_) => _navigating = false);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final compact = widget.compact;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    _recordView(view);

    final title = _titleFor(app, view);
    final meta = _metaFor(app, view);
    final titleSize = settings.textSize + 3.0;

    final isChannel = view.kind == ViewKind.channel;
    final channelKey = isChannel ? view.id.toLowerCase() : '';
    final isPinned = isChannel && app.pinnedChannels.contains(channelKey);
    final isDefault = channelKey == kDefaultChannel;

    // `.chat-header`: padding 16/24 (mobile 15/10, top 12); bg --glass-bg,
    // bottom hairline.
    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 12, 10, 15)
          : const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            children: [
              if (compact) ...[
                _NavBtn(
                  icon: Icons.menu,
                  onTap: widget.onOpenSidebar,
                  tooltip: 'Menu',
                ),
                const SizedBox(width: 4),
              ] else ...[
                _NavBtn(
                  icon: Icons.chevron_left,
                  tooltip: 'Go back',
                  onTap: _canBack ? _back : null,
                  disabled: !_canBack,
                ),
                _NavBtn(
                  icon: Icons.chevron_right,
                  tooltip: 'Go forward',
                  onTap: _canForward ? _forward : null,
                  disabled: !_canForward,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.primary,
                        fontSize: titleSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: 11),
                      ),
                  ],
                ),
              ),
              if (compact)
                _NavBtn(
                  icon: settings.notificationsEnabled
                      ? Icons.notifications_none
                      : Icons.notifications_off_outlined,
                  tooltip: 'Notifications',
                )
              else
                ..._desktopActions(
                  view: view,
                  app: app,
                  isChannel: isChannel,
                  channelKey: channelKey,
                  isPinned: isPinned,
                  isDefault: isDefault,
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _desktopActions({
    required ChatView view,
    required AppState app,
    required bool isChannel,
    required String channelKey,
    required bool isPinned,
    required bool isDefault,
  }) {
    final controller = ref.read(nostrControllerProvider);
    return [
      // Discover / globe entry (`#geohashExplorerModal`).
      _NavBtn(
        icon: Icons.public,
        tooltip: 'Discover channels',
        onTap: _openDiscover,
      ),
      // New message / group.
      _NavBtn(
        icon: Icons.edit_outlined,
        tooltip: 'New message',
        onTap: () => NewPmModal.open(context),
      ),
      if (isChannel) ...[
        // Favorite (togglePin) — filled star when pinned, disabled for #nymchat.
        _NavBtn(
          icon: isPinned ? Icons.star : Icons.star_border,
          tooltip: isDefault
              ? '#nymchat is always favorited'
              : (isPinned ? 'Unfavorite channel' : 'Favorite channel'),
          active: isPinned,
          disabled: isDefault,
          onTap: isDefault ? null : () => controller.togglePin(channelKey),
        ),
        // Share channel URL.
        _NavBtn(
          icon: Icons.ios_share,
          tooltip: 'Share channel URL',
          onTap: () => ShareChannelModal.open(context, channelKey),
        ),
        // Create poll (channel-only).
        _NavBtn(
          icon: Icons.poll_outlined,
          tooltip: 'Create poll',
          onTap: () => PollCreateModal.open(context),
        ),
      ],
      // Audio / video call (delegated to the calls hook; no-op if unwired).
      _NavBtn(
        icon: Icons.call_outlined,
        tooltip: 'Start audio call',
        onTap: () => _startCall(view, video: false),
      ),
      _NavBtn(
        icon: Icons.videocam_outlined,
        tooltip: 'Start video call',
        onTap: () => _startCall(view, video: true),
      ),
      _NavBtn(
        icon: Icons.settings_outlined,
        tooltip: 'Settings',
        onTap: () => SettingsScreen.open(context),
      ),
      _NavBtn(
        icon: Icons.info_outline,
        tooltip: 'About',
        onTap: () => AboutScreen.open(context),
      ),
    ];
  }

  Future<void> _openDiscover() async {
    final gh = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const GeohashExplorer()),
    );
    if (gh == null || gh.isEmpty || !mounted) return;
    ref.read(nostrControllerProvider).switchChannel(gh, geohash: gh);
  }

  void _startCall(ChatView view, {required bool video}) {
    switch (view.kind) {
      case ViewKind.pm:
        widget.onStartCall?.call(view.id, video: video);
      case ViewKind.group:
        widget.onStartGroupCall?.call(view.id, video: video);
      case ViewKind.channel:
        // Channel calls aren't a thing in the PWA; ignore.
        break;
    }
  }

  String _titleFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        return '#${ch.isGeohash ? ch.geohash : ch.channel}';
      case ViewKind.pm:
        return app.users[view.id]?.nym ?? 'PM';
      case ViewKind.group:
        final g = app.groups.firstWhere(
          (g) => g.id == view.id,
          orElse: () => app.groups.first,
        );
        return g.name;
    }
  }

  String _metaFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        if (ch.isGeohash) {
          final loc = decodeGeohash(ch.geohash);
          final ns = loc.lat >= 0 ? 'N' : 'S';
          final ew = loc.lng >= 0 ? 'E' : 'W';
          return '${loc.lat.abs().toStringAsFixed(2)}°$ns, '
              '${loc.lng.abs().toStringAsFixed(2)}°$ew · geohash';
        }
        return 'public channel';
      case ViewKind.pm:
        return 'private message · end-to-end encrypted';
      case ViewKind.group:
        final g = app.groups.firstWhere(
          (g) => g.id == view.id,
          orElse: () => app.groups.first,
        );
        return '${g.members.length} members';
    }
  }
}

/// `.channel-nav-btn`: 28×28, radius 4, textDim → primary on hover/tap.
/// Disabled buttons render at 0.3 opacity (PWA `.channel-nav-btn:disabled`).
class _NavBtn extends StatelessWidget {
  const _NavBtn({
    required this.icon,
    this.onTap,
    this.tooltip,
    this.active = false,
    this.disabled = false,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool active;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (active ? c.primary : c.textDim);
    final btn = InkWell(
      onTap: disabled ? null : (onTap ?? () {}),
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(icon, size: 20, color: color),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}
