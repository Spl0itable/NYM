import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/pm_context_menu.dart';
import '../i18n/i18n.dart';
import '../identity/modal_chrome.dart';
import '../identity/deleted_notice.dart' show dimNymSuffixes;
import '../search/unified_search_panel.dart' show nymSuffixStyle;
import 'chat_lock.dart';
import 'chat_lock_providers.dart';
import 'chat_lock_service.dart';
import 'screen_privacy.dart';

class ChatLockIcons {
  const ChatLockIcons._();

  static const String _open =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">';
  static const String lock =
      '$_open<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>';
  static const String unlock =
      '$_open<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.5-2"/></svg>';
}

Future<ChatLockPromptResult?> showChatLockPrompt(
  BuildContext context, {
  required String title,
  required String body,
  required List<String> fields,
  required String ok,
  String? alt,
  String error = '',
}) {
  return showNymSheet<ChatLockPromptResult>(
    context,
    (_) => _ChatLockPrompt(
        title: title, body: body, fields: fields, ok: ok, alt: alt, error: error),
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.7),
  );
}

class _ChatLockPrompt extends StatefulWidget {
  const _ChatLockPrompt({
    required this.title,
    required this.body,
    required this.fields,
    required this.ok,
    this.alt,
    this.error = '',
  });

  final String title;
  final String body;
  final List<String> fields;
  final String ok;
  final String? alt;
  final String error;

  @override
  State<_ChatLockPrompt> createState() => _ChatLockPromptState();
}

class _ChatLockPromptState extends State<_ChatLockPrompt> {
  late final List<TextEditingController> _ctl = [
    for (final _ in widget.fields) TextEditingController(),
  ];

  @override
  void dispose() {
    for (final c in _ctl) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() => Navigator.of(context)
      .pop(ChatLockPromptResult(values: [for (final c in _ctl) c.text]));

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return NymDiscardGuard(
      isDirty: () => _ctl.any((t) => t.text.isNotEmpty),
      child: ModalChrome.shell(
        context,
        maxWidth: 420,
        scroll: true,
        child: ModalChrome.box(
          c,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title.toUpperCase(),
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                Text(widget.body,
                    style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5)),
                for (var i = 0; i < widget.fields.length; i++) ...[
                  const SizedBox(height: 12),
                  ModalChrome.focusRing(
                    c,
                    child: TextField(
                      key: ValueKey('chat-lock-field-$i'),
                      controller: _ctl[i],
                      autofocus: i == 0,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      keyboardType: TextInputType.visiblePassword,
                      onSubmitted: (_) => _submit(),
                      decoration:
                          ModalChrome.inputDecoration(c, widget.fields[i]),
                      style: TextStyle(color: c.inputText, fontSize: 15),
                    ),
                  ),
                ],
                if (widget.error.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(widget.error,
                      key: const ValueKey('chat-lock-error'),
                      style: TextStyle(color: c.danger, fontSize: 12)),
                ],
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ModalChrome.iconButton(c, tr('Cancel'),
                        () => Navigator.of(context).pop(), height: 42),
                    if (widget.alt != null)
                      ModalChrome.iconButton(
                          c,
                          widget.alt!,
                          () => Navigator.of(context)
                              .pop(const ChatLockPromptResult(alt: true)),
                          height: 42),
                    ModalChrome.sendButton(c, widget.ok, _submit),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void installChatLockPrompter(
    ChatLockService service, BuildContext? Function() context) {
  service.prompter = ({
    required String title,
    required String body,
    required List<String> fields,
    required String ok,
    String? alt,
    String error = '',
  }) async {
    final ctx = context();
    if (ctx == null || !ctx.mounted) return null;
    return showChatLockPrompt(ctx,
        title: title, body: body, fields: fields, ok: ok, alt: alt, error: error);
  };
}

List<SidebarQuickMenuItem> chatLockSidebarItems(
    WidgetRef ref, String storageKey) {
  final service = ref.read(chatLockProvider);
  final k = lockKeyForChat(storageKey, ref.read(appStateProvider).selfPubkey);
  if (k.isEmpty || k == 'c:nymchat') return const [];
  final locked = service.isChatLocked(k);
  return [
    SidebarQuickMenuItem(
      label: tr(locked ? ChatLockStrings.unlockChat : ChatLockStrings.lockChat),
      svg: locked ? ChatLockIcons.unlock : ChatLockIcons.lock,
      onSelected: () => unawaited(service.toggleLock(k)),
    ),
  ];
}

String chatLockLabel(WidgetRef ref, String lockKey) {
  final p = lockParse(lockKey);
  if (p == null) return lockKey;
  final app = ref.read(appStateProvider);
  if (p.kind == 'dm') {
    String? stored;
    for (final pm in ref.read(pmListProvider)) {
      if (pm.pubkey.toLowerCase() == p.id) stored = pm.nym;
    }
    return '${pickDisplayNym(app.users[p.id]?.nym, stored)}#${getPubkeySuffix(p.id)}';
  }
  if (p.kind == 'group') {
    for (final g in ref.read(groupsProvider)) {
      if (g.id.toLowerCase() == p.id) return g.name.isEmpty ? tr('Group') : g.name;
    }
    return tr('Group');
  }
  return '#${p.id}';
}

ChatView? chatLockViewFor(String lockKey) {
  final p = lockParse(lockKey);
  if (p == null) return null;
  if (p.kind == 'dm') return ChatView.pm(p.id);
  if (p.kind == 'group') return ChatView.group(p.id);
  return ChatView.channel(p.id);
}

int chatLockUnread(WidgetRef ref, String lockKey) {
  final unread = ref.read(unreadCountsProvider);
  final self = ref.read(appStateProvider).selfPubkey;
  var n = 0;
  for (final e in chatLockUnreadEntries(unread)) {
    if (lockKeyForChat(e.key, self) == lockKey) {
      final v = e.n is int ? e.n as int : 0;
      if (v > n) n = v;
    }
  }
  return n;
}

Future<bool> openLockedChats(BuildContext context, WidgetRef ref) async {
  final service = ref.read(chatLockProvider);
  if (!service.unlocked) {
    if (!await service.authenticate()) return false;
    service.sessionEvent('unlock');
  }
  service.revealed = true;
  if (!context.mounted) return false;
  final opened = await showNymSheet<ChatView>(
    context,
    (_) => const LockedChatsPanel(),
    barrierColor: context.nym.isLight
        ? const Color(0x73000000)
        : const Color(0xBF000000),
  );
  service.revealed = false;
  if (opened != null) {
    ref.read(appStateProvider.notifier).switchView(opened);
    return true;
  }
  final cur = ref.read(appStateProvider).view.storageKey;
  if (!service.isConversationLocked(cur)) service.sessionEvent('leave');
  return true;
}

class LockedChatsPanel extends ConsumerWidget {
  const LockedChatsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatLockRevisionProvider);
    ref.watch(unreadCountsProvider);
    final c = context.nym;
    final service = ref.read(chatLockProvider);
    final keys = service.lockedKeys;
    final size = MediaQuery.of(context).size;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr(ChatLockStrings.lockedChats).toUpperCase(),
                style: TextStyle(
                  color: c.primary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            IconButton(
              tooltip: tr('Close'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.close, size: 18, color: c.textDim),
            ),
          ],
        ),
        Divider(color: c.glassBorder, height: 16),
        Flexible(
          child: keys.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(tr(ChatLockStrings.lockedEmpty),
                      style: TextStyle(color: c.textDim, fontSize: 13)),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final k in keys) _LockedRow(lockKey: k),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PanelButton(
              label: tr(ChatLockStrings.settingsButton),
              onTap: () => ChatLockSettingsModal.open(context),
            ),
            _PanelButton(
              key: const ValueKey('chat-lock-now'),
              label: tr(ChatLockStrings.lockNow),
              onTap: () {
                Navigator.of(context).maybePop();
                service.lockNow();
              },
            ),
          ],
        ),
      ],
    );
    return nymSheetOr(
      context,
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: body),
      (body) => ScreenPrivacyHold(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: size.width * 0.92,
              constraints:
                  BoxConstraints(maxWidth: 520, maxHeight: size.height * 0.88),
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
              ),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _LockedRow extends ConsumerWidget {
  const _LockedRow({required this.lockKey});

  final String lockKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final n = chatLockUnread(ref, lockKey);
    final service = ref.read(chatLockProvider);
    return Container(
      key: ValueKey('locked-row-$lockKey'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                final v = chatLockViewFor(lockKey);
                if (v != null) Navigator.of(context).pop(v);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    NymSvgIcon(ChatLockIcons.lock, size: 16, color: c.textDim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        lockParse(lockKey)?.kind == 'dm'
                            ? dimNymSuffixes(
                                chatLockLabel(ref, lockKey),
                                nymSuffixStyle(
                                    TextStyle(color: c.text, fontSize: 14)))
                            : TextSpan(text: chatLockLabel(ref, lockKey)),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontSize: 14),
                      ),
                    ),
                    if (n > 0)
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                            color: c.primary,
                            borderRadius: BorderRadius.circular(20)),
                        child: Text(n > 99 ? '99+' : '$n',
                            style: TextStyle(
                                color: c.bg,
                                fontSize: 10,
                                fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _PanelButton(
            label: tr(ChatLockStrings.unlockChat),
            svg: ChatLockIcons.unlock,
            onTap: () => unawaited(service.toggleLock(lockKey)),
          ),
        ],
      ),
    );
  }
}

class _PanelButton extends StatelessWidget {
  const _PanelButton({super.key, required this.label, required this.onTap, this.svg});

  final String label;
  final VoidCallback onTap;
  final String? svg;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: c.primary.withValues(alpha: 0.08),
          borderRadius: NymRadius.rsm,
          border: Border.all(color: c.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (svg != null) ...[
              NymSvgIcon(svg!, size: 14, color: c.text),
              const SizedBox(width: 4),
            ],
            Text(label, style: TextStyle(color: c.text, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class ChatLockSettingsModal extends ConsumerStatefulWidget {
  const ChatLockSettingsModal({super.key});

  static Future<void> open(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(chatLockProvider);
    if (service.lockedKeys.isNotEmpty && !service.unlocked) {
      if (!await service.authenticate()) return;
      service.sessionEvent('unlock');
    }
    if (!context.mounted) return;
    await showNymSheet<void>(
      context,
      (_) => const ChatLockSettingsModal(),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
  }

  @override
  ConsumerState<ChatLockSettingsModal> createState() =>
      _ChatLockSettingsModalState();
}

class _ChatLockSettingsModalState extends ConsumerState<ChatLockSettingsModal> {
  late final TextEditingController _code;
  late bool _hide;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final s = ref.read(chatLockProvider).state();
    final hide = s['hide'] as Map;
    _code = TextEditingController(text: '${hide['code'] ?? ''}');
    _hide = hide['on'] == true;
    _savedCode = _code.text;
  }

  late String _savedCode;

  void _save(ChatLockService service) {
    setState(() {
      _error = service.setHide(_hide, _code.text);
      if (_error.isEmpty) _savedCode = _code.text;
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(chatLockRevisionProvider);
    final c = context.nym;
    final service = ref.read(chatLockProvider);
    final relock = service.relockMinutes;
    return NymDiscardGuard(
      isDirty: () => _code.text != _savedCode,
      child: ModalChrome.shell(
        context,
        maxWidth: 440,
        child: ModalChrome.box(
          c,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(ChatLockStrings.settingsTitle).toUpperCase(),
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(tr(ChatLockStrings.settingsHint),
                    style: TextStyle(color: c.textDim, fontSize: 12, height: 1.5)),
                const SizedBox(height: 18),
                ModalChrome.formLabel(c, tr(ChatLockStrings.relockAfter)),
                const SizedBox(height: 6),
                DropdownButton<int>(
                  key: const ValueKey('chat-lock-relock'),
                  value: relock,
                  isExpanded: true,
                  dropdownColor: c.bgTertiary,
                  style: TextStyle(color: c.text, fontSize: 14),
                  items: [
                    for (final o in relockOptions((s) => tr(s)))
                      DropdownMenuItem<int>(value: o.value, child: Text(o.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) service.relockMinutes = v;
                  },
                ),
                const SizedBox(height: 16),
                Material(
                  type: MaterialType.transparency,
                  child: CheckboxListTile(
                    key: const ValueKey('chat-lock-hide'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _hide,
                    onChanged: (v) => setState(() => _hide = v == true),
                    title: Text(tr(ChatLockStrings.hideEntry),
                        style: TextStyle(color: c.text, fontSize: 14)),
                    subtitle: Text(tr(ChatLockStrings.hideEntryHint),
                        style: TextStyle(color: c.textDim, fontSize: 11)),
                  ),
                ),
                ModalChrome.focusRing(
                  c,
                  child: TextField(
                    key: const ValueKey('chat-lock-code'),
                    controller: _code,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: ModalChrome.inputDecoration(
                        c, tr(ChatLockStrings.secretCode)),
                    style: TextStyle(color: c.inputText, fontSize: 15),
                  ),
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(_error, style: TextStyle(color: c.danger, fontSize: 12)),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PanelButton(
                      key: const ValueKey('chat-lock-save-hide'),
                      label: tr('Save'),
                      onTap: () => _save(service),
                    ),
                    if (service.hasPasscode)
                      _PanelButton(
                        label: tr(ChatLockStrings.resetPasscode),
                        onTap: () => unawaited(service.changePasscode()),
                      ),
                    _PanelButton(
                      label: tr(ChatLockStrings.lockNow),
                      onTap: () {
                        Navigator.of(context).pop();
                        service.lockNow();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.center,
                  child: ModalChrome.iconButton(
                      c, tr('Close'), () => Navigator.of(context).pop()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PrivacyShield extends ConsumerStatefulWidget {
  const PrivacyShield({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends ConsumerState<PrivacyShield>
    with WidgetsBindingObserver {
  AppLifecycleState _life = AppLifecycleState.resumed;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScreenPrivacy.bindNative();
    ScreenPrivacy.wanted.addListener(_rebuild);
    ScreenPrivacy.captured.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ScreenPrivacy.wanted.removeListener(_rebuild);
    ScreenPrivacy.captured.removeListener(_rebuild);
    if (_holding) unawaited(ScreenPrivacy.release());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _life == AppLifecycleState.resumed;
    setState(() => _life = state);
    try {
      final service = ref.read(chatLockProvider);
      if (state == AppLifecycleState.resumed) {
        service.sessionEvent('foreground');
      } else if (wasForeground &&
          (state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden)) {
        service.sessionEvent('background');
      }
    } catch (_) {}
  }

  void _syncHold(bool want) {
    if (want == _holding) return;
    _holding = want;
    unawaited(want ? ScreenPrivacy.hold() : ScreenPrivacy.release());
  }

  @override
  Widget build(BuildContext context) {
    var lockedOpen = false;
    try {
      lockedOpen = ref.watch(lockedConversationOpenProvider);
      ref.listen<bool>(lockedConversationOpenProvider, (_, next) => _syncHold(next));
    } catch (_) {}
    if (lockedOpen != _holding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncHold(lockedOpen);
      });
    }
    final wanted = ScreenPrivacy.wanted.value || lockedOpen;
    final away = _life != AppLifecycleState.resumed;
    final captured = ScreenPrivacy.captured.value;
    final shield = wanted && (away || captured);
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (shield)
          Positioned.fill(
            child: _ShieldCover(captured: captured && !away),
          ),
      ],
    );
  }
}

class _ShieldCover extends StatelessWidget {
  const _ShieldCover({required this.captured});

  final bool captured;

  @override
  Widget build(BuildContext context) {
    NymColors? c;
    try {
      c = context.nym;
    } catch (_) {
      c = null;
    }
    final bg = c?.bg ?? const Color(0xFF000000);
    final fg = c?.textDim ?? const Color(0xFF9E9E9E);
    return ColoredBox(
      key: const ValueKey('privacy-shield'),
      color: bg,
      child: Center(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NymSvgIcon(ChatLockIcons.lock, size: 28, color: fg),
              const SizedBox(height: 10),
              Text(
                tr(captured ? ChatLockStrings.captured : ChatLockStrings.hidden),
                textAlign: TextAlign.center,
                style: TextStyle(color: fg, fontSize: 14, decoration: TextDecoration.none),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
