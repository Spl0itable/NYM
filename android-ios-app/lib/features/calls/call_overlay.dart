// call_overlay.dart - #callOverlay port: full-screen active-call UI.
//
// Layout mirrors index.html #callOverlay:
//   - top: call title (peer / group) + status (status text or m:ss timer)
//   - body: participant video grid (RTCVideoView) + self preview + chat panel
//   - reactions bar + floating reactions
//   - controls row: mute, camera, screenshare, react, chat, switch-cam,
//     end (red)
//
// Renders nothing unless there is an active call.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/common/nym_avatar.dart';
import 'call_providers.dart';
import 'call_service.dart';
import 'call_signaling.dart';
import 'call_state.dart';

/// Reaction emojis offered by the in-call reactions bar (calls.js defaults).
const List<String> _reactionEmojis = ['👍', '❤️', '😂', '😮', '👏', '🎉', '🙌', '🔥'];

class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key});

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  bool _chatOpen = false;
  bool _reactionsOpen = false;
  final _chatController = TextEditingController();

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(currentCallStateProvider);
    if (!call.isActiveCall) return const SizedBox.shrink();

    final c = context.nym;
    final service = ref.read(callServiceProvider);

    return Material(
      color: c.bg,
      child: SafeArea(
        child: Column(
          children: [
            _Top(call: call),
            Expanded(
              child: Stack(
                children: [
                  _Grid(call: call, service: service),
                  if (_chatOpen)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _ChatPanel(
                        call: call,
                        controller: _chatController,
                        onClose: () => setState(() => _chatOpen = false),
                        onSend: (t) {
                          service.sendChat(t);
                          _chatController.clear();
                        },
                      ),
                    ),
                ],
              ),
            ),
            if (_reactionsOpen)
              _ReactionsBar(
                onPick: (e) {
                  service.sendReaction(e);
                  setState(() => _reactionsOpen = false);
                },
              ),
            _Controls(
              call: call,
              chatOpen: _chatOpen,
              onMute: service.toggleMute,
              onCamera: service.toggleCamera,
              onShare: service.toggleScreenShare,
              onSwitchCam: service.switchCamera,
              onReact: () => setState(() => _reactionsOpen = !_reactionsOpen),
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

class _Top extends StatelessWidget {
  const _Top({required this.call});
  final CallState call;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final kindLabel = call.kind == CallKind.video ? 'Video call' : 'Audio call';
    final title = call.isGroup ? 'Group call' : (call.peerNym ?? 'Call');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          Text(
            '$kindLabel · $title',
            style: TextStyle(
                color: c.textBright, fontSize: 16, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(call.statusText, style: TextStyle(color: c.textDim, fontSize: 13)),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.call, required this.service});
  final CallState call;
  final CallService service;

  @override
  Widget build(BuildContext context) {
    // Tiles: self preview + each participant.
    final tiles = <Widget>[
      _Tile(
        label: 'You',
        renderer: service.localRenderer,
        hasVideo: call.kind == CallKind.video && !call.cameraOff || call.sharing,
        seed: 'You',
        mirror: !call.sharing && call.facingMode == 'user',
      ),
      for (final p in call.participants)
        _Tile(
          label: p.nym,
          renderer: service.rendererFor(p.pubkey),
          hasVideo: p.hasVideo,
          seed: p.nym,
          sharing: p.sharing,
        ),
    ];

    final count = tiles.length;
    final columns = count <= 1 ? 1 : (count <= 4 ? 2 : 3);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.count(
        crossAxisCount: columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 3 / 4,
        children: tiles,
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.renderer,
    required this.hasVideo,
    required this.seed,
    this.mirror = false,
    this.sharing = false,
  });

  final String label;
  final RTCVideoRenderer? renderer;
  final bool hasVideo;
  final String seed;
  final bool mirror;
  final bool sharing;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: c.bgTertiary,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasVideo && renderer != null)
              RTCVideoView(
                renderer!,
                mirror: mirror,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              Center(child: NymAvatar(seed: seed, size: 64)),
            if (sharing)
              Positioned(
                top: 6,
                left: 6,
                child: _Badge(text: 'Presenting', color: c.primary),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class _ReactionsBar extends StatelessWidget {
  const _ReactionsBar({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      color: c.bgSecondary,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          for (final e in _reactionEmojis)
            InkWell(
              onTap: () => onPick(e),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(e, style: const TextStyle(fontSize: 24)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatPanel extends StatelessWidget {
  const _ChatPanel({
    required this.call,
    required this.controller,
    required this.onClose,
    required this.onSend,
  });

  final CallState call;
  final TextEditingController controller;
  final VoidCallback onClose;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: 300,
      color: c.bgSecondary.withValues(alpha: 0.97),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.glassBorder)),
            ),
            child: Row(
              children: [
                Text('Chat',
                    style: TextStyle(
                        color: c.textBright, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, color: c.textDim, size: 20),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: call.chatLog.length,
              itemBuilder: (ctx, i) {
                final m = call.chatLog[i];
                return Align(
                  alignment:
                      m.isSelf ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: m.isSelf ? c.primary.withValues(alpha: 0.2) : c.bgTertiary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(m.text, style: TextStyle(color: c.text)),
                  ),
                );
              },
            ),
          ),
          if (call.typingNyms.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                call.typingNyms.length == 1
                    ? '${call.typingNyms.first} is typing'
                    : '${call.typingNyms.length} people are typing',
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    style: TextStyle(color: c.text),
                    decoration: InputDecoration(
                      hintText: 'Message',
                      hintStyle: TextStyle(color: c.textDim),
                      filled: true,
                      fillColor: c.bgTertiary,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (t) {
                      if (t.trim().isNotEmpty) onSend(t);
                    },
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.send, color: c.primary),
                  onPressed: () {
                    final t = controller.text;
                    if (t.trim().isNotEmpty) onSend(t);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.call,
    required this.chatOpen,
    required this.onMute,
    required this.onCamera,
    required this.onShare,
    required this.onSwitchCam,
    required this.onReact,
    required this.onChat,
    required this.onEnd,
  });

  final CallState call;
  final bool chatOpen;
  final VoidCallback onMute;
  final VoidCallback onCamera;
  final VoidCallback onShare;
  final VoidCallback onSwitchCam;
  final VoidCallback onReact;
  final VoidCallback onChat;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isVideo = call.kind == CallKind.video;
    return Container(
      color: c.bgSecondary,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CtrlBtn(
            icon: call.muted ? Icons.mic_off : Icons.mic,
            active: call.muted,
            tooltip: call.muted ? 'Unmute microphone' : 'Mute microphone',
            onTap: onMute,
          ),
          if (isVideo)
            _CtrlBtn(
              icon: call.cameraOff ? Icons.videocam_off : Icons.videocam,
              active: call.cameraOff,
              tooltip: call.cameraOff ? 'Turn on camera' : 'Turn off camera',
              onTap: onCamera,
            ),
          _CtrlBtn(
            icon: Icons.screen_share,
            active: call.sharing,
            tooltip: call.sharing ? 'Stop sharing screen' : 'Share screen',
            onTap: onShare,
          ),
          if (isVideo && !call.sharing)
            _CtrlBtn(
              icon: Icons.cameraswitch,
              tooltip: 'Switch camera',
              onTap: onSwitchCam,
            ),
          _CtrlBtn(
            icon: Icons.emoji_emotions_outlined,
            tooltip: 'React',
            onTap: onReact,
          ),
          _CtrlBtn(
            icon: Icons.chat_bubble_outline,
            active: chatOpen,
            tooltip: 'Chat',
            badge: call.chatUnread,
            onTap: onChat,
          ),
          _CtrlBtn(
            icon: Icons.call_end,
            tooltip: 'End call',
            background: c.danger,
            foreground: Colors.white,
            onTap: onEnd,
          ),
        ],
      ),
    );
  }
}

class _CtrlBtn extends StatelessWidget {
  const _CtrlBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.badge = 0,
    this.background,
    this.foreground,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final int badge;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bg = background ?? (active ? c.primary : c.bgTertiary);
    final fg = foreground ?? (active ? Colors.white : c.text);
    return Tooltip(
      message: tooltip,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            color: bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 50,
                height: 50,
                child: Icon(icon, color: fg, size: 22),
              ),
            ),
          ),
          if (badge > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration:
                    const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                child: Text(
                  badge > 9 ? '9+' : '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
