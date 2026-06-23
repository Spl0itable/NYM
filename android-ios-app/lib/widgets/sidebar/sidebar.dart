import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/identity/panic_overlay.dart';
import '../../features/identity/panic_wipe.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import 'channel_list_item.dart';
import 'pm_list_item.dart';
import 'user_list_item.dart';

/// The left sidebar: identity header + three collapsible nav sections
/// (PUBLIC CHANNELS, PRIVATE MESSAGES, ONLINE NYMS). Width 290 desktop / 300 in
/// the mobile drawer (caller sizes it). bg `--bg-secondary`, right hairline
/// border. (docs/specs/02 §1.1, §5.3)
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key, this.onItemSelected});

  /// Called after a channel/PM is tapped (so the mobile drawer can close).
  final VoidCallback? onItemSelected;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  bool _channelsOpen = true;
  bool _pmsOpen = true;
  bool _nymsOpen = true;

  bool _channelSearch = false;
  bool _pmSearch = false;
  bool _nymSearch = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final textSize = settings.textSize.toDouble();

    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    final channels = ref.watch(channelsProvider);
    final pms = ref.watch(pmListProvider);
    final users = ref.watch(usersProvider);
    final unread = ref.watch(unreadCountsProvider);

    final notifier = ref.read(appStateProvider.notifier);

    void select(ChatView v) {
      notifier.switchView(v);
      widget.onItemSelected?.call();
    }

    // Online nyms exclude self and offline-hidden.
    final onlineUsers = users.values
        .where((u) => u.pubkey != app.selfPubkey)
        .toList()
      ..sort((a, b) {
        int rank(User u) {
          switch (u.effectiveStatus()) {
            case UserStatus.online:
              return 0;
            case UserStatus.away:
              return 1;
            default:
              return 2;
          }
        }

        final r = rank(a) - rank(b);
        return r != 0 ? r : a.nym.compareTo(b.nym);
      });

    return Container(
      decoration: BoxDecoration(
        color: c.bgSecondary,
        border: Border(right: BorderSide(color: c.glassBorder)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, app.selfNym),
            _SidebarActions(onItemSelected: widget.onItemSelected),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _NavSection(
                    title: 'Public Channels',
                    open: _channelsOpen,
                    searching: _channelSearch,
                    onToggleOpen: () =>
                        setState(() => _channelsOpen = !_channelsOpen),
                    onToggleSearch: () =>
                        setState(() => _channelSearch = !_channelSearch),
                    searchHint: 'Search channels…',
                    children: [
                      for (final ch in channels)
                        ChannelListItem(
                          entry: ch,
                          active: view.kind == ViewKind.channel &&
                              view.id == ch.key,
                          unread: unread[ch.key] ?? 0,
                          textSize: textSize,
                          onTap: () => select(ChatView.channel(ch.key)),
                        ),
                    ],
                  ),
                  _NavSection(
                    title: 'Private Messages',
                    open: _pmsOpen,
                    searching: _pmSearch,
                    onToggleOpen: () => setState(() => _pmsOpen = !_pmsOpen),
                    onToggleSearch: () =>
                        setState(() => _pmSearch = !_pmSearch),
                    searchHint: 'Search messages…',
                    children: [
                      for (final pm in pms)
                        PMListItem(
                          nym: pm.nym,
                          pubkey: pm.pubkey,
                          active: view.kind == ViewKind.pm &&
                              view.id == pm.pubkey,
                          status: users[pm.pubkey]?.effectiveStatus() ??
                              UserStatus.offline,
                          unread: unread[pm.pubkey] ?? 0,
                          textSize: textSize,
                          onTap: () => select(ChatView.pm(pm.pubkey)),
                        ),
                    ],
                  ),
                  _NavSection(
                    title: 'Online Nyms',
                    open: _nymsOpen,
                    searching: _nymSearch,
                    onToggleOpen: () => setState(() => _nymsOpen = !_nymsOpen),
                    onToggleSearch: () =>
                        setState(() => _nymSearch = !_nymSearch),
                    searchHint: 'Search nyms…',
                    children: [
                      for (final u in onlineUsers)
                        UserListItem(
                          user: u,
                          textSize: textSize,
                          onTap: () => select(ChatView.pm(u.pubkey)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.sidebar-header` with `.nym-display` (avatar 20 + nym + status/connection).
  ///
  /// Panic gesture (`bindNymPanicGesture`, docs/specs/04 §10.1): a normal tap
  /// opens the nick editor; a 2000 ms press-and-hold triggers the emergency
  /// wipe. The post-hold tap is swallowed so the editor doesn't open over the
  /// scramble overlay.
  Widget _header(BuildContext context, String nym) {
    final c = context.nym;
    // `.sidebar-header`: padding 20/16, bottom hairline, bg black@0.15.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: _PanicHoldDetector(
        onTap: () => NickEditModal.open(context),
        onHold: () => _triggerPanic(context),
        // `.nym-display`: padding 10/14, bg white@0.04, glass border, radius-sm.
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rsm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // `.nym-label`: 10px uppercase ls 1.5 textDim weight 500.
              Text(
                'NYM',
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              // `.nym-identity`: avatar 20 + nym value, gap 10.
              Row(
                children: [
                  NymAvatar(seed: nym, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      nym,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.secondary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // `.status-indicator`: 11px textDim, gap 5, 8px dot.
              Row(
                children: [
                  const StatusDot(status: UserStatus.online, size: 8),
                  const SizedBox(width: 5),
                  Text(
                    'connected',
                    style: TextStyle(color: c.textDim, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _triggerPanic(BuildContext context) {
    PanicOverlay.show(
      context,
      wipe: PanicWipe.production(),
      onComplete: () {
        // Pop the overlay; a real app restart-to-first-run would re-bootstrap
        // the identity here.
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
      },
    );
  }
}

/// Wraps the identity header to implement the panic gesture: a tap fires
/// [onTap], while a press held for [holdMs] fires [onHold] (and suppresses the
/// following tap). Bound for pointer down/up/cancel, matching the PWA's
/// mouse/touch handlers (`bindNymPanicGesture`).
class _PanicHoldDetector extends StatefulWidget {
  const _PanicHoldDetector({
    required this.child,
    required this.onTap,
    required this.onHold,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onHold;

  /// Press-and-hold threshold (`_PANIC_HOLD_MS`).
  static const int holdMs = 2000;

  @override
  State<_PanicHoldDetector> createState() => _PanicHoldDetectorState();
}

class _PanicHoldDetectorState extends State<_PanicHoldDetector> {
  Timer? _timer;
  bool _fired = false;

  void _start(PointerDownEvent _) {
    _fired = false;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: _PanicHoldDetector.holdMs),
      () {
        _fired = true;
        widget.onHold();
      },
    );
  }

  void _cancel([PointerEvent? _]) {
    _timer?.cancel();
    _timer = null;
  }

  void _up(PointerUpEvent _) {
    _cancel();
    if (!_fired) widget.onTap();
    _fired = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _start,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: widget.child,
    );
  }
}

/// `.sidebar-actions`: the Flair / Settings / About / Logout button row that
/// sits under the identity header (index.html:440). Each is an `.icon-btn` with
/// an icon over a small label.
class _SidebarActions extends StatelessWidget {
  const _SidebarActions({this.onItemSelected});

  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.sidebar-actions`: padding 16/12, gap 6, top hairline border.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ActionButton(
            icon: Icons.star_border,
            label: 'Flair',
            onTap: () {
              onItemSelected?.call();
              ShopModal.open(context);
            },
          ),
          _ActionButton(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () {
              onItemSelected?.call();
              SettingsScreen.open(context);
            },
          ),
          _ActionButton(
            icon: Icons.info_outline,
            label: 'About',
            onTap: () {
              onItemSelected?.call();
              AboutScreen.open(context);
            },
          ),
          _ActionButton(
            icon: Icons.logout,
            label: 'Logout',
            onTap: () {
              // TODO(verify): sign-out flow (signOut) is owned by the identity
              // subsystem.
            },
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        // `.sidebar-actions .icon-btn`: padding 6/4, gap 3, 9px label.
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            children: [
              Icon(icon, size: 16, color: c.text),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: c.text,
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A collapsible nav section: 10px uppercase title (letter-spacing 1.5,
/// textDim), a search-toggle + collapse chevron, an optional search field, then
/// the list body. (docs/specs/02 §1.1, §4 nav-title)
class _NavSection extends StatelessWidget {
  const _NavSection({
    required this.title,
    required this.open,
    required this.searching,
    required this.onToggleOpen,
    required this.onToggleSearch,
    required this.searchHint,
    required this.children,
  });

  final String title;
  final bool open;
  final bool searching;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleSearch;
  final String searchHint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggleOpen,
          // `.nav-section` padding 16/12/12 + `.nav-title` padding-left 8,
          // margin-bottom 10.
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 10,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _MiniIcon(
                  icon: Icons.search,
                  active: searching,
                  onTap: onToggleSearch,
                ),
                const SizedBox(width: 2),
                _MiniIcon(
                  icon: open
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  onTap: onToggleOpen,
                ),
              ],
            ),
          ),
        ),
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: _SearchField(hint: searchHint),
          ),
        if (open) ...children,
      ],
    );
  }
}

class _MiniIcon extends StatelessWidget {
  const _MiniIcon({required this.icon, this.active = false, required this.onTap});
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          icon,
          size: 16,
          color: active ? c.primary : c.textDim,
        ),
      ),
    );
  }
}

/// `.search-input`: radius rxs, padding 8/12, 12px, bg white@5.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TextField(
      style: TextStyle(color: c.text, fontSize: 12),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 12),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        prefixIcon: Icon(Icons.search, size: 16, color: c.textDim),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 34, minHeight: 0),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );
  }
}
