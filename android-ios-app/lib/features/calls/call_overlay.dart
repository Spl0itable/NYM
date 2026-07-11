// call_overlay.dart - #callOverlay port: full-screen active-call UI.
//
// Layout mirrors index.html #callOverlay:
//   - top: call title (peer / group) + status (status text or m:ss timer)
//   - body: participant video grid (RTCVideoView) + self preview + chat panel
//   - floating reactions overlay + reactions bar + presenter menu
//   - controls row: mute, camera, screenshare, presenter(mod), react, chat,
//     switch-cam, end (red)
//
// Renders nothing unless there is an active call.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../widgets/chat/message_row.dart' show abbreviateNumber;
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/nym_icons.dart';
import '../emoji/emoji_picker.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart';
import '../shop/cosmetics.dart';
import '../reactions/quick_react_popup.dart';
import '../reactions/reactors_modal.dart';
import 'call_nym.dart';
import 'call_providers.dart';
import 'call_service.dart';
import 'call_signaling.dart';
import 'call_state.dart';

/// Opens the shared user context menu (block / friend / PM / report …) from a
/// nickname tapped in the call overlay or call chat — a 1:1 port of the PWA's
/// `showCallUserMenu` (calls.js:41), which calls `showContextMenu(..., /*
/// profileOnly */ true)`. [profileOnly] trims the message-only actions that
/// don't apply during a call (React/Quote/Copy/Translate/Slap/Hug/Edit), leaving
/// PM / Create Group / Gift Credits / Friend / Report / Block. No-op for self /
/// empty pubkey (calls.js:42). `ContextMenuPanel` re-derives the live
/// friend/block flags from app_state, so only pubkey + base nym are needed.
void showCallUserMenu(BuildContext context, String pubkey, {String? nym}) {
  if (pubkey.isEmpty) return;
  // Resolve the display base nym: prefer a caller-supplied nym, else the live
  // `usersProvider` entry (the call chat-from line carries no nym), else fall
  // back to the pubkey (`_nymForPubkey`, calls.js).
  final container = ProviderScope.containerOf(context);
  final resolved = (nym != null && nym.isNotEmpty)
      ? nym
      : (container.read(usersProvider)[pubkey]?.nym ?? pubkey);
  ContextMenuPanel.show(
    context,
    target: CtxTarget(
      pubkey: pubkey,
      nym: stripPubkeySuffix(resolved),
      isSelf: false,
      profileOnly: true,
    ),
  );
}

class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key});

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  bool _chatOpen = false;
  bool _reactionsOpen = false;
  bool _presenterOpen = false;
  final _chatController = TextEditingController();

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  /// Opens the full emoji picker (reactions-bar "+" / chat-react "more") as a
  /// bottom sheet over the call overlay; [onPick] receives the chosen emoji.
  void _openEmojiPicker(ValueChanged<String> onPick) {
    final recents = ref.read(recentEmojisProvider);
    final c = context.nym;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: Container(
          height: MediaQuery.of(sheetCtx).size.height * 0.55,
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border(top: BorderSide(color: c.glassBorder)),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: EmojiPicker(
            recents: recents,
            onSelect: (emoji) {
              Navigator.of(sheetCtx).maybePop();
              onPick(emoji);
            },
          ),
        ),
      ),
    );
  }

  /// Builds the call-chat panel (`#callChatPanel`). On wide layouts it is a
  /// fixed-320px flex sibling of the grid (so the grid resizes); on narrow
  /// layouts it fills the body.
  Widget _buildChatPanel(CallService service) {
    final call = ref.watch(currentCallStateProvider);
    return _ChatPanel(
      call: call,
      controller: _chatController,
      onClose: () => setState(() => _chatOpen = false),
      onSend: (t) {
        service.sendChat(t);
        _chatController.clear();
      },
      onTyping: service.sendTyping,
      onReact: service.toggleChatReaction,
      onMorePicker: (mid) =>
          _openEmojiPicker((e) => service.toggleChatReaction(mid, e)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(currentCallStateProvider);
    if (!call.isActiveCall) return const SizedBox.shrink();

    final service = ref.read(callServiceProvider);

    return Material(
      // `.call-overlay`: dark rgba(5,5,10,0.96) (#05050a @ 0.96); light mode
      // flips to rgba(245,245,242,0.95) (`body.light-mode .call-overlay`,
      // styles-features.css:4799). The Material is the parent of SafeArea so
      // the fill still reaches the screen edges (under the notch/status bar).
      color: context.nym.isLight
          ? const Color(0xF2F5F5F2)
          : const Color(0xF505050A),
      child: SafeArea(
        child: Column(
          children: [
            _Top(call: call),
            Expanded(
              child: Stack(
                children: [
                  // `.call-body` is `display:flex`: on wide layouts (>640) the
                  // grid and the 320px chat panel are siblings, so opening chat
                  // SHRINKS the grid; on narrow layouts the panel goes
                  // fullscreen over the grid.
                  if (_chatOpen && MediaQuery.of(context).size.width > 640)
                    Row(
                      children: [
                        Expanded(child: _Grid(call: call, service: service)),
                        _buildChatPanel(service),
                      ],
                    )
                  else
                    _Grid(call: call, service: service),
                  // Floating reactions overlay (`#callReactionsFly`).
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _FlyLayer(reactions: call.flyReactions),
                    ),
                  ),
                  // Switch-camera button: top-right, gated on >1 video input,
                  // hidden while the chat panel is open or sharing.
                  if (call.kind == CallKind.video &&
                      !call.sharing &&
                      !_chatOpen &&
                      call.videoInputCount > 1)
                    Positioned(
                      top: 14,
                      right: 14,
                      child: _SwitchCamButton(
                        disabled: call.switchingCamera,
                        facingMode: call.facingMode,
                        onTap: service.switchCamera,
                      ),
                    ),
                  if (_presenterOpen && call.isMod)
                    Positioned(
                      // `.call-presenter-menu`: right 16, bottom 92 (clear of
                      // the controls row).
                      right: 16,
                      bottom: 92,
                      child: _PresenterMenu(
                        call: call,
                        selfPubkey:
                            ref.read(appStateProvider).selfPubkey,
                        onToggleRestrict: () => service
                            .setScreenShareRestricted(!call.shareRestricted),
                        onAssign: service.assignPresenter,
                      ),
                    ),
                  if (_reactionsOpen)
                    Positioned(
                      // `.call-reactions-bar`: bottom 92 (floats above the
                      // 56px controls).
                      left: 0,
                      right: 0,
                      bottom: 92,
                      child: _ReactionsBar(
                        recents: ref.watch(recentEmojisProvider),
                        onPick: (e) {
                          service.sendReaction(e);
                          setState(() => _reactionsOpen = false);
                        },
                        onMore: () {
                          setState(() => _reactionsOpen = false);
                          _openEmojiPicker(service.sendReaction);
                        },
                      ),
                    ),
                  // Narrow (<=640): the panel is `position:absolute; inset:0`
                  // (fullscreen) over the grid.
                  if (_chatOpen && MediaQuery.of(context).size.width <= 640)
                    Positioned.fill(child: _buildChatPanel(service)),
                ],
              ),
            ),
            _Controls(
              call: call,
              chatOpen: _chatOpen,
              reactionsOpen: _reactionsOpen,
              presenterOpen: _presenterOpen,
              onMute: service.toggleMute,
              onCamera: service.toggleCamera,
              onShare: service.toggleScreenShare,
              onReact: () => setState(() {
                _reactionsOpen = !_reactionsOpen;
                _presenterOpen = false;
              }),
              onPresenter: () => setState(() {
                _presenterOpen = !_presenterOpen;
                _reactionsOpen = false;
              }),
              onChat: () {
                setState(() => _chatOpen = !_chatOpen);
                if (_chatOpen) service.markChatRead();
              },
              onEnd: service.end,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Title (#callTitle) — `_callTitleHtml`
// =============================================================================

class _Top extends ConsumerWidget {
  const _Top({required this.call});
  final CallState call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final kindLabel = call.kind == CallKind.video ? tr('Video call') : tr('Audio call');

    Widget id;
    if (call.isGroup) {
      // Resolve groupId → group name (literal "Group call" fallback) and the
      // group roster.
      final app = ref.watch(appStateProvider);
      final selfPk = app.selfPubkey;
      String name = tr('Group call');
      List<String> others = const [];
      for (final g in app.groups) {
        if (g.id == call.groupId) {
          if (g.name.isNotEmpty) name = g.name;
          // `_callTitleHtml` (calls.js:737): the group's OTHER members —
          // `g.members.filter(pk => pk !== this.pubkey)` — NOT the live call
          // participants, and never self.
          others = [
            for (final pk in g.members)
              if (pk != selfPk) pk,
          ];
          break;
        }
      }
      // Up to 4 member avatars (`group-header-avatar`) between the group icon
      // and the name (`others.slice(0, 4)`, calls.js:738).
      final users = ref.watch(usersProvider);
      final members = others.take(4).toList();
      id = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.group-header-svg` (calls.js:740) — the three-figure group glyph.
          NymSvgIcon(NymIcons.groupGlyph, size: 18, color: c.textBright),
          if (members.isNotEmpty) ...[
            const SizedBox(width: 6),
            for (final pk in members)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: NymAvatar(
                  seed: pk,
                  size: 20,
                  imageUrl: users[pk]?.profile?.picture, // Rule 4
                ),
              ),
          ],
          const SizedBox(width: 6),
          Flexible(
            child: Text(name,
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16.8, // `.call-title` 1.05rem
                    fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    } else if (call.peerPubkey != null && call.peerPubkey!.isNotEmpty) {
      final users = ref.watch(usersProvider);
      id = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NymAvatar(
            seed: call.peerPubkey!,
            size: 22,
            imageUrl: users[call.peerPubkey!]?.profile?.picture, // Rule 4
          ),
          const SizedBox(width: 6),
          Flexible(
            child: CallNym(
              pubkey: call.peerPubkey!,
              nym: call.peerNym,
              baseColor: c.textBright,
              // `.call-title` 1.05rem = 16.8px.
              baseStyle:
                  const TextStyle(fontSize: 16.8, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    } else {
      id = Text(call.peerNym ?? tr('Call'),
          style: TextStyle(
              color: c.textBright,
              fontSize: 16.8, // `.call-title` 1.05rem
              fontWeight: FontWeight.w600));
    }

    // `.call-overlay-top { padding: 18px 16px 6px }` (styles-features.css:
    // 4606-4608).
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // `.call-title-kind`: dim, weight 500, at the 1.05rem title size.
              Text('$kindLabel · ',
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: 16.8,
                      fontWeight: FontWeight.w500)),
              Flexible(child: id),
            ],
          ),
          const SizedBox(height: 2),
          // `.call-status` 0.85rem = 13.6px.
          Text(call.statusText,
              style: TextStyle(color: c.textDim, fontSize: 13.6)),
        ],
      ),
    );
  }
}

// =============================================================================
// Video grid (#callGrid) — breakpoints from styles-features.css:4699-4722
// =============================================================================

class _Grid extends StatelessWidget {
  const _Grid({required this.call, required this.service});
  final CallState call;
  final CallService service;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _Tile(
        pubkey: '',
        label: 'You',
        renderer: service.localRenderer,
        hasVideo:
            (call.kind == CallKind.video && !call.cameraOff) || call.sharing,
        seed: 'You',
        self: true,
        mirror: !call.sharing && call.facingMode == 'user',
        sharing: call.sharing,
      ),
      for (final p in call.participants)
        _Tile(
          pubkey: p.pubkey,
          label: p.nym,
          renderer: service.rendererFor(p.pubkey),
          hasVideo: p.hasVideo,
          seed: p.pubkey,
          sharing: p.sharing,
        ),
    ];

    final count = tiles.length;
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 700;

    // PWA mapping: narrow → 1/2:1col, 3/4:2col, 5-9:3col; wide → 2col base
    // (1/2 centred max 1100). Tiles have min-height 160 (no forced aspect).
    // The `[data-count="5"…"9"]` selectors (specificity 0,2,0) BEAT the
    // wide-media `.call-grid` override (0,1,0, styles-features.css:4718), so
    // 5-9 tiles render 3 columns at ANY width. The `[data-count]` selectors
    // only exist for 2-9 (styles-features.css:4708-4716), so 10+ tiles fall
    // back to the `.call-grid` base: 1 column narrow, 2 columns wide.
    final int columns;
    if (count >= 5 && count <= 9) {
      columns = 3;
    } else if (wide) {
      columns = 2;
    } else if (count <= 2) {
      columns = 1;
    } else if (count <= 4) {
      columns = 2;
    } else {
      columns = 1;
    }

    final grid = GridView.count(
      crossAxisCount: columns,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      // min-height 160 with cover video: a ~4:3 cell reads close to the PWA's
      // flexible rows without a forced portrait squish.
      childAspectRatio: 4 / 3,
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      children: tiles,
    );

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: wide && count <= 2 ? 1100 : double.infinity,
            ),
            child: grid,
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.pubkey,
    required this.label,
    required this.renderer,
    required this.hasVideo,
    required this.seed,
    this.self = false,
    this.mirror = false,
    this.sharing = false,
  });

  final String pubkey;
  final String label;
  final RTCVideoRenderer? renderer;
  final bool hasVideo;
  final String seed;
  final bool self;
  final bool mirror;
  final bool sharing;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 160),
      child: Container(
        // Decoration lives on the (clipping) Container itself — not inside a
        // ClipRRect — so the light-mode drop shadow paints outside the tile.
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.bgTertiary,
          // `.call-tile` border = `var(--border)` (primary@0.20), primary
          // when presenting.
          border: Border.all(
              color: sharing ? c.primary : c.border, width: 1),
          borderRadius: BorderRadius.circular(14),
          // `body.light-mode .call-tile { box-shadow: 0 2px 12px
          // rgba(0,0,0,0.12) }` (styles-features.css:4800).
          boxShadow: c.isLight
              ? const [
                  BoxShadow(
                    color: Color(0x1F000000), // black @ 0.12
                    blurRadius: 12,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasVideo && renderer != null)
              RTCVideoView(
                renderer!,
                mirror: mirror,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              // `.call-tile-avatar`: 84px total (border-box) with a 2px
              // `var(--border)` ring, so the avatar itself is 80px.
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.border, width: 2),
                  ),
                  child: NymAvatar(seed: seed, size: 80),
                ),
              ),
            if (sharing)
              Positioned(
                top: 8,
                right: 8,
                child: _Badge(text: tr('Presenting'), color: c.primary, fg: c.bg),
              ),
            // `.call-tile-name`: bottom-left, black@0.55, radius 8, decorated,
            // `max-width: calc(100% - 16px)` (styles-features.css:4756-4769) —
            // pinning left AND right 8 caps it at tile width − 16; the Align
            // shrink-wraps the pill back to its content, left-aligned.
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Align(
                alignment: Alignment.centerLeft,
                heightFactor: 1,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: self || pubkey.isEmpty
                      ? Text(tr('You'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12))
                      // Tile name → shared user context menu (PWA
                      // `callNickMenu` / `showCallUserMenu`, calls.js:1566).
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              showCallUserMenu(context, pubkey, nym: label),
                          child: CallNym(
                            pubkey: pubkey,
                            nym: label,
                            baseColor: Colors.white,
                            baseStyle: const TextStyle(fontSize: 12),
                            badgeSize: 12,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color, this.fg});
  final String text;
  final Color color;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              color: fg ?? Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600)),
    );
  }
}

// =============================================================================
// Floating reactions (#callReactionsFly) — `.call-react-fly-item` callReactFly
// =============================================================================

class _FlyLayer extends StatelessWidget {
  const _FlyLayer({required this.reactions});
  final List<CallFlyReaction> reactions;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            for (final r in reactions)
              Positioned(
                left: (r.leftPercent / 100) * constraints.maxWidth,
                bottom: constraints.maxHeight * 0.04,
                child: _FlyItem(key: ValueKey(r.id), reaction: r),
              ),
          ],
        );
      },
    );
  }
}

/// A single flying reaction: rises 0→-260px, scales 0.6→1, fades in then out
/// over 3.1s (`@keyframes callReactFly`).
class _FlyItem extends StatefulWidget {
  const _FlyItem({super.key, required this.reaction});
  final CallFlyReaction reaction;

  @override
  State<_FlyItem> createState() => _FlyItemState();
}

class _FlyItemState extends State<_FlyItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3100),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        // @keyframes callReactFly: translateY 0→-26px(12%)→-260px(100%) [linear
        // between keyframes], scale .6→1 by 12%, opacity 0→1 by 12%, hold to
        // 80%, then 1→0 by 100%.
        final double dy;
        final double scale;
        if (t < 0.12) {
          final k = t / 0.12;
          dy = -26 * k; // 12%: -10% of a phone tile height
          scale = 0.6 + 0.4 * k;
        } else {
          final k = (t - 0.12) / 0.88;
          dy = -26 - (260 - 26) * k;
          scale = 1;
        }
        final double opacity;
        if (t < 0.12) {
          opacity = t / 0.12;
        } else if (t < 0.80) {
          opacity = 1;
        } else {
          opacity = 1 - (t - 0.80) / 0.20;
        }
        return Opacity(
          opacity: opacity.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.call-react-emoji` 2.5rem = 40px. A custom `:shortcode:`
          // fly-reaction renders as its image (PWA `renderReactionEmoji`,
          // calls.js:1177 — whole-string only) at `.call-react-emoji
          // .custom-emoji { width/height: 2.5rem; vertical-align: middle }`
          // (styles-features.css:5185, margin 0 via `.custom-emoji-reaction`);
          // unicode falls through to a plain Text.
          InlineEmojiText(
              text: widget.reaction.emoji,
              style: const TextStyle(fontSize: 40),
              emojiSize: 40,
              wholeStringOnly: true,
              emojiMargin: EdgeInsets.zero,
              emojiAlignment: PlaceholderAlignment.middle),
          const SizedBox(height: 2),
          // `.call-react-who`: white on black@0.5, radius 8.
          Container(
            constraints: const BoxConstraints(maxWidth: 160),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: widget.reaction.pubkey != null &&
                    widget.reaction.pubkey!.isNotEmpty
                ? CallNym(
                    pubkey: widget.reaction.pubkey!,
                    baseColor: Colors.white,
                    baseStyle: const TextStyle(fontSize: 11),
                    badgeSize: 11,
                  )
                : Text(widget.reaction.who ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Reactions bar (#callReactionsBar) — recents-first + "+" more
// =============================================================================

class _ReactionsBar extends StatelessWidget {
  const _ReactionsBar({
    required this.recents,
    required this.onPick,
    required this.onMore,
  });
  final List<String> recents;
  final ValueChanged<String> onPick;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // recents-first padded with the 8 defaults. Keep a custom `:shortcode:`
    // recent when its pack is still known (PWA `_callReactionBarEmojis`,
    // calls.js:1106-1118 → `known()`); without the predicate every custom code
    // is treated as unknown and dropped.
    final codeToUrl =
        ProviderScope.containerOf(context).read(liveCustomEmojiProvider).codeToUrl;
    final emojis = callReactionBarEmojis(recents,
        isKnownCustom: (code) => codeToUrl.containsKey(code));
    return Center(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: math.min(MediaQuery.of(context).size.width * 0.92, 420),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          // `.call-reactions-bar` border = `var(--border)` (primary@0.20).
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 8)),
          ],
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final e in emojis)
              _ReactBarBtn(
                onTap: () => onPick(e),
                // Known custom `:shortcode:` recents render as their image
                // (PWA `renderReactionEmoji`, calls.js:1130 — whole-string
                // only) at `.call-react-btn .custom-emoji { width/height:
                // 1.9rem; vertical-align: middle }` = 30.4px
                // (styles-features.css:5183, margin 0); unicode falls
                // through `InlineEmojiText`'s fast path to a plain Text at
                // the 1.75rem = 28px button font.
                child: InlineEmojiText(
                    text: e,
                    style: const TextStyle(fontSize: 28),
                    emojiSize: 30.4,
                    wholeStringOnly: true,
                    emojiMargin: EdgeInsets.zero,
                    emojiAlignment: PlaceholderAlignment.middle),
              ),
            // `.call-react-more`: dim "+" (also a `.call-react-btn`,
            // calls.js:1134) opens the full picker.
            _ReactBarBtn(
              onTap: onMore,
              child: Text('＋',
                  style: TextStyle(fontSize: 24, color: c.textDim)),
            ),
          ],
        ),
      ),
    );
  }
}

/// One `.call-react-btn`: padding 4, radius 8, transparent until hover.
/// `:hover { transform: scale(1.25); background: var(--bg-hover,
/// rgba(255,255,255,0.08)) }` with `transition: transform 0.12s, background
/// 0.12s` (styles-features.css:5173-5182). `--bg-hover` is never defined in
/// the PWA CSS, so the white@0.08 fallback applies in both themes.
class _ReactBarBtn extends StatefulWidget {
  const _ReactBarBtn({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ReactBarBtn> createState() => _ReactBarBtnState();
}

class _ReactBarBtnState extends State<_ReactBarBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.25 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hover ? const Color(0x14FFFFFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Chat panel (#callChatPanel)
// =============================================================================

class _ChatPanel extends ConsumerWidget {
  const _ChatPanel({
    required this.call,
    required this.controller,
    required this.onClose,
    required this.onSend,
    required this.onTyping,
    required this.onReact,
    required this.onMorePicker,
  });

  final CallState call;
  final TextEditingController controller;
  final VoidCallback onClose;
  final ValueChanged<String> onSend;
  final VoidCallback onTyping;
  final void Function(String mid, String emoji) onReact;
  final ValueChanged<String> onMorePicker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final width = MediaQuery.of(context).size.width;
    final fullscreen = width <= 640;
    return Container(
      width: fullscreen ? width : 320,
      constraints: BoxConstraints(maxWidth: width * 0.84),
      decoration: BoxDecoration(
        color: c.bgSecondary,
        border: Border(left: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.glassBorder)),
            ),
            child: Row(
              children: [
                Text(tr('Chat'),
                    style: TextStyle(
                        color: c.textBright, fontWeight: FontWeight.w600)),
                const Spacer(),
                // `.call-chat-close` is a literal "✕" char in the PWA — render as
                // styled text, not an SVG glyph.
                IconButton(
                  icon: Text('✕',
                      style: TextStyle(
                          color: c.textDim, fontSize: 20, height: 1)),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              // The 14px horizontal gutter lives on each row (not here) so a
              // supporter/aura-gold row can pull its gold left border 8px into
              // the gutter (`margin-left: -8px`, styles-features.css:4949).
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: call.chatLog.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) => _ChatRow(
                msg: call.chatLog[i],
                isGroup: call.isGroup,
                onReact: onReact,
                onMorePicker: onMorePicker,
              ),
            ),
          ),
          if (call.typingPubkeys.isNotEmpty) _TypingLine(pubkeys: call.typingPubkeys),
          _InputRow(
            call: call,
            controller: controller,
            onSend: onSend,
            onTyping: onTyping,
          ),
        ],
      ),
    );
  }
}

/// One chat row: decorated from-line (non-self) + mention-highlighted text +
/// reaction badges, with long-press → quick-react, plus a self read receipt.
class _ChatRow extends ConsumerWidget {
  const _ChatRow({
    required this.msg,
    required this.isGroup,
    required this.onReact,
    required this.onMorePicker,
  });

  final CallChatMessage msg;
  final bool isGroup;
  final void Function(String mid, String emoji) onReact;
  final ValueChanged<String> onMorePicker;

  void _openQuickReact(BuildContext context, Rect anchor) {
    final recents = ProviderScope.containerOf(context)
        .read(recentEmojisProvider);
    // A non-self chat row's quick-react popup exposes a "User options" affordance
    // (PWA `_showCallChatQuickReact` 3-dot `data-qr="menu"`, calls.js:1526,1566)
    // that opens the shared user context menu. Rendered as the inline
    // quick-context-menu card below the pill (the native popup has no in-pill
    // ⋮ slot; `showQuickReactPopup.contextItems` is the supported channel).
    final contextItems = (!msg.isSelf && msg.pubkey.isNotEmpty)
        ? [
            QuickContextItem(
              label: tr('User options'),
              svg: NymIcons.info,
              onTap: () => showCallUserMenu(context, msg.pubkey),
            ),
          ]
        : const <QuickContextItem>[];
    showQuickReactPopup(
      context,
      anchorRect: anchor,
      emojis: quickReactEmojis(recents),
      onReact: (e) => onReact(msg.mid, e),
      onMore: () => onMorePicker(msg.mid),
      contextItems: contextItems,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // `.call-chat-msg { font-size: 0.85rem }` = 13.6px (styles-features.css:
    // 4866-4870); `.call-chat-text` inherits it.
    var base = TextStyle(color: c.textBright, fontSize: 13.6, height: 1.3);

    // Carry the sender's purchased message flair (style / supporter / aura)
    // onto the call-chat row, mirroring `_appendCallChat` (calls.js:1407-1414)
    // which adds `shop.style` / `supporter-style` / `cosmetic-aura-gold`
    // classes. The `.call-chat-text` rules (styles-features.css:4901-4946)
    // tint the text; supporter wins over a base message style, matching the
    // CSS cascade order.
    var supporter = false;
    var auraGold = false;
    if (msg.pubkey.isNotEmpty) {
      final cosmetics = ref.watch(userCosmeticsProvider(msg.pubkey));
      supporter = cosmetics.supporter;
      auraGold = cosmetics.cosmetics.contains('cosmetic-aura-gold');
      final deco = supporter
          ? supporterStyleDecoration
          : messageStyleDecoration(cosmetics.styleId);
      if (deco != null) {
        base = base.copyWith(
          color: deco.textColor,
          shadows: deco.textShadows,
        );
      }
    }

    Widget row = Stack(
      children: [
        _buildRow(context, c, base),
        // `.call-chat-react-btn`: always-present 24×24 ＋ affordance, top-right.
        Positioned(
          top: 0,
          right: 0,
          child: _ChatReactBtn(
            onTap: () {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              final offset = box.localToGlobal(Offset.zero);
              _openQuickReact(context, offset & box.size);
            },
          ),
        ),
      ],
    );

    // `.call-chat-msg.supporter-style, .call-chat-msg.cosmetic-aura-gold`
    // (styles-features.css:4947-4951): a 2px solid #ffd700 left border with
    // padding-left 6 / margin-left -8 (border + padding cancel the negative
    // margin, so the text stays put and the gold rule sits 8px into the 14px
    // list gutter). `.cosmetic-aura-gold` (4952-4956) additionally wraps the
    // row in an inset 1px gold ring + soft gold glow, radius 8, padding 4/6.
    const gold = Color(0xFFFFD700);
    if (auraGold) {
      row = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            // `0 0 14px rgba(255,215,0,0.15)`.
            BoxShadow(color: Color(0x26FFD700), blurRadius: 14),
          ],
        ),
        // `inset 0 0 0 1px rgba(255,215,0,0.3)` — the 1px gold ring, painted
        // over the content like a CSS inset shadow.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x4DFFD700)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // border-left: 2px solid #ffd700 (clipped to the radius-8 box).
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: gold),
            ),
            // padding: 4px 6px, after the 2px left border.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
              child: row,
            ),
          ],
        ),
      );
    } else if (supporter) {
      row = Container(
        padding: const EdgeInsets.only(left: 6),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: gold, width: 2)),
        ),
        child: row,
      );
    }

    // The list's 14px horizontal gutter; a gold-edged row starts 8px earlier
    // (`margin-left: -8px`).
    return Padding(
      padding: EdgeInsets.only(
          left: (supporter || auraGold) ? 6 : 14, right: 14),
      child: row,
    );
  }

  Widget _buildRow(BuildContext context, NymColors c, TextStyle base) {
    // `_setupCallChatInteractions` (calls.js:1598-1621): a 500ms hold
    // (cancelled once the touch drifts more than 10px on either axis) buzzes
    // (`nymHapticTap` = a 30ms vibrate) and opens the quick-react popup
    // centred on the PRESS POINT — `_showCallChatQuickReact` places it
    // `left = cx - w/2, top = cy - h - 10` from the recorded touch x/y
    // (calls.js:1533-1537) — NOT on the row rect. A zero-size anchor at the
    // touch point reproduces that. The tight 10px pre-fire cancel slop needs
    // the custom recognizer: a stock long-press would ride the framework's
    // ~18px kTouchSlop and still fire after a small scroll drift.
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        _CallChatLongPressRecognizer: GestureRecognizerFactoryWithHandlers<
            _CallChatLongPressRecognizer>(
          () => _CallChatLongPressRecognizer(debugOwner: this),
          (r) => r
            ..onLongPressStart = (d) {
              HapticFeedback.mediumImpact();
              _openQuickReact(
                  context,
                  Rect.fromCenter(
                      center: d.globalPosition, width: 0, height: 0));
            },
        ),
      },
      // `.call-chat-msg` is a left-aligned IRC-style log row (no align-self /
      // text-align:right for self in the CSS); self ONLY dims the from-line.
      // The receipt (`.call-chat-readers`) is the sole right-aligned element.
      // Right padding clears the absolute react ＋ button.
      child: Padding(
        padding: const EdgeInsets.only(right: 28),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `.call-chat-from`: decorated nym (non-self primary, self dim
          // "You"), `font-size: 0.75rem` = 12px (styles-features.css:4874-4877).
          if (msg.isSelf)
            Text(tr('You'),
                style: TextStyle(
                    color: c.textDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600))
          else
            // Chat-from nym → shared user context menu (PWA `callNickMenu` →
            // `showCallUserMenu`, inline-bindings.js:289).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showCallUserMenu(context, msg.pubkey),
              child: CallNym(
                pubkey: msg.pubkey,
                baseColor: c.primary,
                baseStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                badgeSize: 11,
              ),
            ),
          const SizedBox(height: 2),
          // Bubble with @mention highlighting (`_formatCallChatText`).
          Text.rich(
            callChatTextSpans(msg.text, base, c.primary),
            textAlign: TextAlign.left,
          ),
          // Reaction count badges.
          if (msg.reactions.isNotEmpty) ...[
            const SizedBox(height: 3),
            _ReactionBadges(msg: msg, onReact: onReact),
          ],
          // Read receipt (self only): right-aligned ✓/✓✓ in 1:1, reader
          // avatars in group (`.call-chat-readers { justify-content:flex-end }`).
          if (msg.isSelf) _Receipt(msg: msg, isGroup: isGroup),
        ],
        ),
      ),
    );
  }
}

/// A [LongPressGestureRecognizer] with the PWA's tighter pre-fire cancel slop
/// for the call-chat quick-react hold (`_setupCallChatInteractions`,
/// calls.js:1595,1611-1616): the pending 500ms timer is cancelled once the
/// touch drifts more than `MOVE = 10` px on EITHER axis — tighter than the
/// framework's default ~18px kTouchSlop drift, which would still pop the popup
/// on a slow call-chat scroll. Movement AFTER the 500ms deadline no longer
/// matters (the popup is already up), so the check applies only before the
/// deadline elapses.
class _CallChatLongPressRecognizer extends LongPressGestureRecognizer {
  _CallChatLongPressRecognizer({super.debugOwner});

  /// `MOVE` (calls.js:1595).
  static const double _moveThreshold = 10;

  Offset _downPosition = Offset.zero;
  Duration _downTime = Duration.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (event.pointer == primaryPointer) {
      _downPosition = event.position;
      _downTime = event.timeStamp;
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent &&
        event.pointer == primaryPointer &&
        state == GestureRecognizerState.possible &&
        event.timeStamp - _downTime < (deadline ?? kLongPressTimeout) &&
        ((event.position.dx - _downPosition.dx).abs() > _moveThreshold ||
            (event.position.dy - _downPosition.dy).abs() > _moveThreshold)) {
      // Same rejection path the built-in pre-accept slop check takes.
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    super.handleEvent(event);
  }
}

/// `.call-chat-react-btn`: a 24×24 ＋ button, top-right of each chat row,
/// bordered (`var(--border)`) over `--bg-tertiary`, radius 8; opacity 0.65 → 1 +
/// primary glyph on hover. Opens the same quick-react popup as long-press.
class _ChatReactBtn extends StatefulWidget {
  const _ChatReactBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ChatReactBtn> createState() => _ChatReactBtnState();
}

class _ChatReactBtnState extends State<_ChatReactBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Opacity(
        opacity: _hover ? 1 : 0.65,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.bgTertiary,
              border: Border.all(color: c.border),
              borderRadius: NymRadius.rxs,
            ),
            child: Text(
              '＋',
              style: TextStyle(
                color: _hover ? c.primary : c.textDim,
                fontSize: 14,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionBadges extends StatelessWidget {
  const _ReactionBadges({required this.msg, required this.onReact});
  final CallChatMessage msg;
  final void Function(String mid, String emoji) onReact;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final selfPk =
        ProviderScope.containerOf(context).read(appStateProvider).selfPubkey;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final entry in msg.reactions.entries)
          if (entry.value.isNotEmpty)
            GestureDetector(
              onTap: () => onReact(msg.mid, entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  // `.call-chat-reaction.self`: primary 22% bg + primary border.
                  color: entry.value.contains(selfPk)
                      ? c.primary.withValues(alpha: 0.22)
                      : c.bgTertiary,
                  border: Border.all(
                      // `.call-chat-reaction` border = `var(--border)`
                      // (primary@0.20); self adds the solid primary border.
                      color: entry.value.contains(selfPk)
                          ? c.primary
                          : c.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Custom `:shortcode:` reaction renders as its image (PWA
                    // `renderReactionEmoji`, calls.js:1689 — whole-string
                    // only) at `.call-chat-reaction .custom-emoji { width/
                    // height: 1.4em; vertical-align: -0.2em }` = 17.5px of the
                    // 0.78rem = 12.5px badge font (styles-features.css:
                    // 4989-5003); unicode falls through to a plain Text.
                    InlineEmojiText(
                        text: entry.key,
                        style: const TextStyle(fontSize: 12.5),
                        emojiSize: 17.5,
                        wholeStringOnly: true,
                        emojiMargin: EdgeInsets.zero,
                        emojiBaselineDropEm: 0.2),
                    const SizedBox(width: 3),
                    // `.call-chat-reaction-count` 0.72rem = 11.5px.
                    Text('${entry.value.length}',
                        style: TextStyle(color: c.textDim, fontSize: 11.5)),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _Receipt extends ConsumerWidget {
  const _Receipt({required this.msg, required this.isGroup});
  final CallChatMessage msg;
  final bool isGroup;

  /// `_bindCallReaderLongPress` (calls.js:1370-1395): a 500ms hold on the
  /// reader strip (contextmenu suppressed, cancelled on release/move) buzzes
  /// (`nymHapticTap`) and opens the "Seen by" readers modal
  /// (`_showReadersModalFromMap`, groups.js:2829-2880) lifted above the call
  /// overlay (`z-index: 10060` — the root overlay here).
  void _showSeenBy(BuildContext context, WidgetRef ref) {
    if (msg.readers.isEmpty) return;
    final users = ref.read(usersProvider);
    final selfPk = ref.read(appStateProvider).selfPubkey;
    final box = context.findRenderObject() as RenderBox?;
    final anchor = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    showReactorsModal(
      context,
      anchorRect: anchor,
      emoji: '',
      // `.reactors-modal-header`: "Seen by <count>".
      title: tr('Seen by {count}', {'count': abbreviateNumber(msg.readers.length)}),
      reactors: [
        for (final e in msg.readers.entries)
          ReactorEntry(
            pubkey: e.key,
            nym: stripPubkeySuffix(e.value),
            suffix: getPubkeySuffix(e.key),
            isYou: e.key == selfPk,
            imageUrl: users[e.key]?.profile?.picture,
          ),
      ],
      // "Click user row to open their context menu" (groups.js:2861-2869):
      // the modal closes itself, then `showContextMenu(e,
      // `${baseNym}#${suffix}`, pubkey, null, null, false)` — NOT
      // profile-only.
      onTapReactor: (r) => ContextMenuPanel.show(
        context,
        target: CtxTarget(pubkey: r.pubkey, nym: r.nym, isSelf: r.isYou),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    if (isGroup) {
      // Reader avatars (`.call-chat-readers`, justify-end); empty until read.
      // `_syncReaderAvatars` (groups.js:2644-2695) shows up to 3 overlapping
      // 14px avatars (`.group-reader-avatar`: 1.5px bg ring, opacity 0.85,
      // -5px stacking) + a `+N` overflow badge (9px dim,
      // `.group-reader-overflow`).
      if (msg.readers.isEmpty) return const SizedBox.shrink();
      const maxVisible = 3;
      final entries = msg.readers.entries.toList();
      final visible = entries.take(maxVisible).toList();
      final overflow = entries.length - visible.length;
      final users = ref.watch(usersProvider);
      return Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onLongPress: () {
            // The PWA buzzes (nymHapticTap = 30ms vibrate) as the 500ms
            // reader long-press fires (calls.js:1373-1377).
            HapticFeedback.mediumImpact();
            _showSeenBy(context, ref);
          },
          child: Padding(
            padding: const EdgeInsets.only(top: 3, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < visible.length; i++)
                  Transform.translate(
                    offset: Offset(i == 0 ? 0 : -5.0 * i, 0),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: c.bg, width: 1.5),
                      ),
                      child: Opacity(
                        opacity: 0.85,
                        child: NymAvatar(
                          seed: visible[i].key,
                          size: 14,
                          imageUrl: users[visible[i].key]?.profile?.picture,
                        ),
                      ),
                    ),
                  ),
                if (overflow > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Text(
                      '+${abbreviateNumber(overflow)}',
                      style: TextStyle(
                          color: c.textDim, fontSize: 9, height: 14 / 9),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    // 1:1 ✓ (sent) / ✓✓ (read) — right-aligned receipt.
    final read = msg.delivery == CallChatDelivery.read || msg.readers.isNotEmpty;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          read ? '✓✓' : '✓',
          style: TextStyle(
              color: read ? c.primary : c.textDim, fontSize: 11),
        ),
      ),
    );
  }
}

class _TypingLine extends StatelessWidget {
  const _TypingLine({required this.pubkeys});
  final List<String> pubkeys;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.call-chat-typing { font-size: 0.72rem }` = 11.5px
    // (styles-features.css:5006-5009).
    final style = TextStyle(
        color: c.textDim, fontSize: 11.5, fontStyle: FontStyle.italic);
    // Bound each decorated nym so its internal Flexible has finite width inside
    // the unbounded Wrap.
    Widget nym(String pk) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: CallNym(
            pubkey: pk,
            baseColor: c.textDim,
            baseStyle: style,
            badgeSize: 11,
          ),
        );

    final List<Widget> parts;
    if (pubkeys.length == 1) {
      parts = [nym(pubkeys[0]), Text(tr(' is typing'), style: style)];
    } else if (pubkeys.length == 2) {
      parts = [
        nym(pubkeys[0]),
        Text(tr(' and '), style: style),
        nym(pubkeys[1]),
        Text(tr(' are typing'), style: style),
      ];
    } else {
      parts = [
        Text(tr('{n} people are typing', {'n': pubkeys.length}), style: style)
      ];
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 3,
        children: parts,
      ),
    );
  }
}

class _InputRow extends ConsumerStatefulWidget {
  const _InputRow({
    required this.call,
    required this.controller,
    required this.onSend,
    required this.onTyping,
  });
  final CallState call;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final VoidCallback onTyping;

  @override
  ConsumerState<_InputRow> createState() => _InputRowState();
}

class _InputRowState extends ConsumerState<_InputRow> {
  /// Active mention matches (pubkeys) for the autocomplete overlay.
  List<String> _mentionMatches = const [];

  /// Keyboard-selected match (`_callMentionIndex`, calls.js:1906/1912): first
  /// item on open, ArrowUp/Down moves it with wrap-around.
  int _mentionIndex = 0;

  /// PWA `callChatKeydown` (calls.js:1207-1213): while the autocomplete is
  /// open, ArrowDown/Up move the `.selected` highlight, Escape closes it and
  /// Enter/Tab complete the selected mention.
  KeyEventResult _onMentionKey(FocusNode node, KeyEvent event) {
    if (_mentionMatches.isEmpty || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _navigateMention(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _navigateMention(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _mentionMatches = const []);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      _insertMention(
          _mentionMatches[_mentionIndex.clamp(0, _mentionMatches.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// `_navigateCallMention` (calls.js:1915-1926): step with wrap-around.
  void _navigateMention(int direction) {
    if (_mentionMatches.isEmpty) return;
    var idx = _mentionIndex + direction;
    if (idx < 0) idx = _mentionMatches.length - 1;
    if (idx >= _mentionMatches.length) idx = 0;
    setState(() => _mentionIndex = idx);
  }

  void _onChanged(String value) {
    final sel = widget.controller.selection.baseOffset;
    final cursor = sel < 0 ? value.length : sel;
    final before = value.substring(0, cursor.clamp(0, value.length));
    final m = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(before);
    if (m != null) {
      _updateMentions(m.group(1) ?? '');
    } else if (_mentionMatches.isNotEmpty) {
      setState(() => _mentionMatches = const []);
    }
    if (value.trim().isNotEmpty) widget.onTyping();
  }

  void _updateMentions(String search) {
    final s = search.toLowerCase();
    final blocked = ref.read(appStateProvider).blockedUsers;
    final selfPk = ref.read(appStateProvider).selfPubkey;
    final users = ref.read(usersProvider);
    // `_showCallMentionAutocomplete` (calls.js:1880-1886) filters AND sorts on
    // the lowercased `base#suffix` searchable string — not the raw pubkey —
    // then slices the first 8, so both the row order and (with >8 candidates)
    // which 8 appear are driven by the display nyms.
    final searchable = <String, String>{};
    final matches = widget.call.participants
        .map((p) => p.pubkey)
        .where((pk) => pk != selfPk && !blocked.contains(pk))
        .where((pk) {
      final base = stripPubkeySuffix(users[pk]?.nym ?? pk);
      final sfx = getPubkeySuffix(pk);
      final key = '$base#$sfx'.toLowerCase();
      searchable[pk] = key;
      return key.contains(s);
    }).toList()
      ..sort((a, b) => searchable[a]!.compareTo(searchable[b]!));
    setState(() {
      _mentionMatches = matches.take(8).toList();
      // `_showCallMentionAutocomplete` re-selects the first item on every
      // refresh (calls.js:1891,1906).
      _mentionIndex = 0;
    });
  }

  void _insertMention(String pubkey) {
    final users = ref.read(usersProvider);
    final base = stripPubkeySuffix(users[pubkey]?.nym ?? pubkey);
    final sfx = getPubkeySuffix(pubkey);
    final value = widget.controller.text;
    final sel = widget.controller.selection.baseOffset;
    final cursor = sel < 0 ? value.length : sel;
    final before = value.substring(0, cursor.clamp(0, value.length));
    final after = value.substring(cursor.clamp(0, value.length));
    final atIdx = before.lastIndexOf('@');
    if (atIdx < 0) {
      setState(() => _mentionMatches = const []);
      return;
    }
    final insert = '@$base#$sfx ';
    final next = before.substring(0, atIdx) + insert + after;
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: atIdx + insert.length),
    );
    setState(() => _mentionMatches = const []);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          // `.call-chat-input-row { border-top: 1px solid var(--border) }`
          // (styles-features.css:5035-5042) — the separator above the input.
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: _onMentionKey,
                  child: TextField(
                    controller: widget.controller,
                    style: TextStyle(color: c.textBright, fontSize: 14),
                    minLines: 1,
                    maxLines: 4,
                    onChanged: _onChanged,
                    decoration: InputDecoration(
                      hintText: tr('Message'),
                      hintStyle: TextStyle(color: c.textDim),
                      filled: true,
                      fillColor: c.bgTertiary,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      // `.call-chat-input` border = `var(--border)`
                      // (primary@0.20).
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: c.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: c.border),
                      ),
                    ),
                    onSubmitted: (t) {
                      // A mention pick should complete the mention, not send
                      // (`_selectCallMention` picks the `.selected` item).
                      if (_mentionMatches.isNotEmpty) {
                        _insertMention(_mentionMatches[_mentionIndex.clamp(
                            0, _mentionMatches.length - 1)]);
                        return;
                      }
                      if (t.trim().isNotEmpty) widget.onSend(t);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: c.primary,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    final t = widget.controller.text;
                    if (t.trim().isNotEmpty) widget.onSend(t);
                  },
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: NymSvgIcon(NymIcons.send, color: c.bg, size: 18),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // `.call-mention-autocomplete`: anchored above the input.
        if (_mentionMatches.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            bottom: 60,
            child: _MentionAutocomplete(
              pubkeys: _mentionMatches,
              selected: _mentionIndex,
              onPick: _insertMention,
            ),
          ),
      ],
    );
  }
}

class _MentionAutocomplete extends StatefulWidget {
  const _MentionAutocomplete({
    required this.pubkeys,
    required this.selected,
    required this.onPick,
  });
  final List<String> pubkeys;

  /// Keyboard-selected row (`.call-mention-item.selected`).
  final int selected;
  final ValueChanged<String> onPick;

  @override
  State<_MentionAutocomplete> createState() => _MentionAutocompleteState();
}

class _MentionAutocompleteState extends State<_MentionAutocomplete> {
  /// Fixed row extent (7px vertical padding + 22px avatar) so the keyboard
  /// selection can be scrolled into view (`scrollIntoView({block:'nearest'})`,
  /// calls.js:1925) with plain offset math.
  static const double _itemExtent = 36;

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_MentionAutocomplete old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible());
    }
  }

  void _ensureVisible() {
    if (!mounted || !_scroll.hasClients) return;
    final top = widget.selected * _itemExtent;
    final bottom = top + _itemExtent - _scroll.position.viewportDimension;
    if (_scroll.offset > top) {
      _scroll.jumpTo(top);
    } else if (_scroll.offset < bottom) {
      _scroll.jumpTo(bottom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 200),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          // `.call-mention-autocomplete` border = `var(--border)` (primary@0.20).
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, -4)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          controller: _scroll,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemExtent: _itemExtent,
          children: [
            for (var i = 0; i < widget.pubkeys.length; i++)
              InkWell(
                onTap: () => widget.onPick(widget.pubkeys[i]),
                // `.call-mention-item.selected, .call-mention-item:hover
                // { background: var(--bg-tertiary) }`
                // (styles-features.css:5077-5078).
                hoverColor: c.bgTertiary,
                child: Container(
                  color: i == widget.selected ? c.bgTertiary : null,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      NymAvatar(seed: widget.pubkeys[i], size: 22),
                      const SizedBox(width: 8),
                      Flexible(
                        child: DefaultTextStyle(
                          style: TextStyle(
                              color: c.textBright,
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('@', style: TextStyle(color: c.textBright)),
                              Flexible(
                                child: CallNym(
                                  pubkey: widget.pubkeys[i],
                                  baseColor: c.textBright,
                                  baseStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                  badgeSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Presenter menu (#callPresenterMenu) — `_renderPresenterMenu`
// =============================================================================

class _PresenterMenu extends ConsumerWidget {
  const _PresenterMenu({
    required this.call,
    required this.selfPubkey,
    required this.onToggleRestrict,
    required this.onAssign,
  });

  final CallState call;
  final String selfPubkey;
  final VoidCallback onToggleRestrict;

  /// Assign a presenter, or pass null to clear.
  final ValueChanged<String?> onAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final users = ref.watch(usersProvider);
    // Participants = self + remote members (call.participants excludes self).
    final members = <String>[
      selfPubkey,
      ...call.participants.map((p) => p.pubkey),
    ];
    final requests =
        call.presentRequests.where(members.contains).toList();

    String nameOf(String pk) =>
        pk == selfPubkey ? tr('You') : stripPubkeySuffix(users[pk]?.nym ?? pk);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 280,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - 32,
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          // `.call-presenter-menu` border = `var(--border)` (primary@0.20).
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 8)),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // "Only the presenter can share" checkbox row.
              InkWell(
                onTap: onToggleRestrict,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: call.shareRestricted,
                          onChanged: (_) => onToggleRestrict(),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(tr('Only the presenter can share'),
                            style: TextStyle(
                                color: c.textBright, fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
              if (requests.isNotEmpty) ...[
                _Head(text: tr('Requests')),
                for (final pk in requests)
                  _PresenterRow(
                    name: nameOf(pk),
                    isPresenter: call.presenter == pk,
                    actionLabel: tr('Approve'),
                    onAction: () => onAssign(pk),
                    onClear: () => onAssign(null),
                  ),
              ],
              _Head(text: tr('Participants')),
              for (final pk in members)
                _PresenterRow(
                  name: nameOf(pk) +
                      (call.presenter == pk ? tr(' · presenter') : ''),
                  isPresenter: call.presenter == pk,
                  actionLabel: tr('Make presenter'),
                  onAction: () => onAssign(pk),
                  onClear: () => onAssign(null),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PresenterRow extends StatelessWidget {
  const _PresenterRow({
    required this.name,
    required this.isPresenter,
    required this.actionLabel,
    required this.onAction,
    required this.onClear,
  });

  final String name;
  final bool isPresenter;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(name,
                style: TextStyle(color: c.textBright, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          if (isPresenter)
            _PresenterAction(
                label: tr('Clear'), color: c.danger, onTap: onClear)
          else
            _PresenterAction(
                label: actionLabel, color: c.primary, onTap: onAction),
        ],
      ),
    );
  }
}

class _PresenterAction extends StatelessWidget {
  const _PresenterAction(
      {required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 12)),
      ),
    );
  }
}

// =============================================================================
// Switch-camera button (#callSwitchCamBtn)
// =============================================================================

class _SwitchCamButton extends StatefulWidget {
  const _SwitchCamButton({
    required this.disabled,
    required this.facingMode,
    required this.onTap,
  });
  final bool disabled;
  final String facingMode;
  final VoidCallback onTap;

  @override
  State<_SwitchCamButton> createState() => _SwitchCamButtonState();
}

class _SwitchCamButtonState extends State<_SwitchCamButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: widget.facingMode == 'environment'
          ? tr('Switch to front camera')
          : tr('Switch to rear camera'),
      // `.call-switch-cam-btn:hover { transform: scale(1.08) }` with
      // `transition: transform 0.15s` (styles-features.css:4626-4629);
      // `:disabled { transform: none }` (4630) suppresses the scale.
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover && !widget.disabled ? 1.08 : 1,
          duration: const Duration(milliseconds: 150),
          child: Opacity(
            opacity: widget.disabled ? 0.5 : 1,
            child: Material(
              // `.call-switch-cam-btn { background: rgba(15,15,22,0.6) }`
              // (styles-features.css:4620) — #0F0F16 @ 0.6, not pure black.
              color: const Color(0x990F0F16),
              // `.call-switch-cam-btn` border = `var(--border)` (primary@0.20).
              shape: CircleBorder(side: BorderSide(color: c.border)),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.disabled ? null : widget.onTap,
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: Center(
                    child: NymSvgIcon(NymIcons.callSwitchCam,
                        color: c.textBright, size: 20),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Controls (#callControls)
// =============================================================================

class _Controls extends StatelessWidget {
  const _Controls({
    required this.call,
    required this.chatOpen,
    required this.reactionsOpen,
    required this.presenterOpen,
    required this.onMute,
    required this.onCamera,
    required this.onShare,
    required this.onReact,
    required this.onPresenter,
    required this.onChat,
    required this.onEnd,
  });

  final CallState call;
  final bool chatOpen;
  final bool reactionsOpen;
  final bool presenterOpen;
  final VoidCallback onMute;
  final VoidCallback onCamera;
  final VoidCallback onShare;
  final VoidCallback onReact;
  final VoidCallback onPresenter;
  final VoidCallback onChat;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isVideo = call.kind == CallKind.video;
    // `.call-controls`: no background (transparent over the overlay backdrop),
    // gap 20, `padding: 16px; padding-bottom: calc(16px +
    // env(safe-area-inset-bottom))` (styles-features.css:4771-4777) — the
    // overlay's SafeArea already consumes the bottom inset.
    return Container(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 20,
        runSpacing: 10,
        children: [
          _CtrlBtn(
            // PWA toggles `.active` (red) on the SAME mic glyph when muted.
            svg: NymIcons.callMic,
            active: call.muted,
            tooltip: call.muted ? tr('Unmute microphone') : tr('Mute microphone'),
            onTap: onMute,
          ),
          if (isVideo)
            _CtrlBtn(
              // PWA `#callVideoBtn` keeps the same video glyph and goes `.active`
              // (red) when the camera is off.
              svg: NymIcons.video,
              active: call.cameraOff,
              tooltip: call.cameraOff ? tr('Turn on camera') : tr('Turn off camera'),
              onTap: onCamera,
            ),
          _CtrlBtn(
            svg: NymIcons.callScreenShare,
            active: call.sharing,
            // request-mode: primary outline when we can't share (calls.js).
            requestMode: !call.sharing && !call.canShareScreen,
            tooltip: call.sharing
                ? tr('Stop sharing screen')
                : (call.canShareScreen ? tr('Share screen') : tr('Request to present')),
            onTap: onShare,
          ),
          // Presenter button — mods only, badge = pending requests.
          if (call.isMod)
            _CtrlBtn(
              svg: NymIcons.callPresenter,
              active: presenterOpen,
              tooltip: tr('Presenter controls'),
              badge: call.presentRequests.length,
              onTap: onPresenter,
            ),
          _CtrlBtn(
            svg: NymIcons.callReact,
            active: reactionsOpen,
            tooltip: tr('React'),
            onTap: onReact,
          ),
          _CtrlBtn(
            svg: NymIcons.callChat,
            active: chatOpen,
            tooltip: tr('Chat'),
            badge: call.chatUnread,
            onTap: onChat,
          ),
          _CtrlBtn(
            // `#callHangupBtn` — the feather phone ROTATED 135° (the hang-up
            // glyph), danger bg, white icon.
            svg: NymIcons.phone,
            rotation: 0.375,
            tooltip: tr('End call'),
            background: c.danger,
            foreground: Colors.white,
            onTap: onEnd,
          ),
        ],
      ),
    );
  }
}

class _CtrlBtn extends StatefulWidget {
  const _CtrlBtn({
    required this.svg,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.requestMode = false,
    this.badge = 0,
    this.background,
    this.foreground,
    this.rotation = 0,
  });

  final String svg;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool requestMode;
  final int badge;
  final Color? background;
  final Color? foreground;

  /// Glyph rotation in turns. The hangup button is the feather phone rotated
  /// 135° (`.call-control-btn.hangup svg { transform: rotate(135deg) }`):
  /// 135/360 = 0.375.
  final double rotation;

  @override
  State<_CtrlBtn> createState() => _CtrlBtnState();
}

class _CtrlBtnState extends State<_CtrlBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bg = widget.background ?? (widget.active ? c.danger : c.bgTertiary);
    final fg =
        widget.foreground ?? (widget.active ? Colors.white : c.textBright);
    // `.call-control-btn` border = `var(--border)` (primary@0.20); request-mode
    // gets the solid primary outline.
    final borderColor = widget.requestMode ? c.primary : c.border;
    final iconColor = widget.requestMode ? c.primary : fg;
    return Tooltip(
      message: widget.tooltip,
      // `.call-control-btn:hover { transform: scale(1.08) }` with `transition:
      // transform 0.15s` (styles-features.css:4779-4794). The badge is a child
      // of the button in the PWA, so the whole stack scales.
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover ? 1.08 : 1,
          duration: const Duration(milliseconds: 150),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: bg,
                shape: CircleBorder(side: BorderSide(color: borderColor)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onTap,
                  child: SizedBox(
                    width: 54,
                    height: 54,
                    child: Center(
                      child: widget.rotation == 0
                          ? NymSvgIcon(widget.svg, color: iconColor, size: 22)
                          : Transform.rotate(
                              angle: widget.rotation * 2 * math.pi,
                              child: NymSvgIcon(widget.svg,
                                  color: iconColor, size: 22),
                            ),
                    ),
                  ),
                ),
              ),
              if (widget.badge > 0)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration:
                        BoxDecoration(color: c.danger, shape: BoxShape.circle),
                    constraints:
                        const BoxConstraints(minWidth: 18, minHeight: 18),
                    child: Text(
                      widget.badge > 9 ? '9+' : '${widget.badge}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
