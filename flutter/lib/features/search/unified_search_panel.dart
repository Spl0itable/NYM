import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart' show formatFullTimestamp;
import '../../widgets/chat/messages_list.dart' show messageListScrollerProvider;
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/context_menu/context_menu_actions.dart' show CtxTarget;
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/conversation_avatar.dart';
import '../chat_lock/chat_lock_providers.dart';
import '../chat_tools/chat_tools_ui.dart'
    show ChatToolsReader, chatDisplayNym, chatInfoFor, jumpToMessage;
import '../i18n/i18n.dart';
import '../shortcuts/shortcuts.dart';
import 'search_source.dart';
import 'unified_search.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/nym_tooltip.dart';

String _s(String key, [Map<String, Object?>? args]) =>
    tr(kUnifiedSearchStrings[key]!, args);

ChatView searchViewForKey(String key) => key.startsWith('pm-')
    ? ChatView.pm(key.substring(3))
    : key.startsWith('group-')
        ? ChatView.group(key.substring(6))
        : ChatView.channel(key.startsWith('#') ? key.substring(1) : key);

void openSearchHit(ChatToolsReader read, String key, Message m) {
  final app = read(appStateProvider);
  final root = m.threadRoot;
  final list = app.messages[key] ?? const <Message>[];
  final hasRoot = root != null &&
      root.isNotEmpty &&
      list.any((x) => x.threadRoot == null && threadKeyForMessage(x) == root);
  if (!(appThreadsEnabled && hasRoot)) {
    if (read(activeThreadProvider) != null) {
      read(activeThreadProvider.notifier).state = null;
    }
    jumpToMessage(read, m.id);
    return;
  }
  final view = searchViewForKey(key);
  if (view != app.view) read(appStateProvider.notifier).switchView(view);
  read(activeThreadProvider.notifier).state =
      ActiveThread(view: view, rootId: root);
  final scroller = read(messageListScrollerProvider(view.storageKey));
  final flash = read(flashedMessageProvider.notifier);
  var attempts = 8;
  void tryJump(Duration _) {
    if (scroller.scrollToMessage(m.id)) {
      flash.flash(m.id);
      return;
    }
    if (--attempts > 0) {
      SchedulerBinding.instance.addPostFrameCallback(tryJump);
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  SchedulerBinding.instance.addPostFrameCallback(tryJump);
  SchedulerBinding.instance.scheduleFrame();
}

const List<SingleActivator> kUnifiedSearchShortcuts = [
  SingleActivator(LogicalKeyboardKey.keyK, control: true),
  SingleActivator(LogicalKeyboardKey.keyK, meta: true),
];

bool isUnifiedSearchShortcut(KeyEvent e) {
  if (e is! KeyDownEvent) return false;
  for (final a in kUnifiedSearchShortcuts) {
    if (a.accepts(e, HardwareKeyboard.instance)) return true;
  }
  return false;
}

class UnifiedSearchPanel extends ConsumerStatefulWidget {
  const UnifiedSearchPanel({super.key, this.scope, this.initialQuery = ''});

  final String? scope;
  final String initialQuery;

  static _UnifiedSearchPanelState? _live;

  static bool get isOpen => _live != null;

  static final ValueNotifier<bool> openListenable = ValueNotifier<bool>(false);

  static void _syncOpen() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      openListenable.value = _live != null;
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  static Future<void> open(BuildContext context,
      {String? scope, String initialQuery = ''}) async {
    final live = _live;
    if (live != null && live.mounted) {
      live._focus.requestFocus();
      return;
    }
    await showNymSheet<void>(
      context,
      (_) => UnifiedSearchPanel(scope: scope, initialQuery: initialQuery),
      fullHeight: true,
      dragAnywhere: false,
    );
  }

  @override
  ConsumerState<UnifiedSearchPanel> createState() => _UnifiedSearchPanelState();
}

class _Row {
  _Row(this.id, this.label, this.activate);

  final String id;
  final String label;
  final VoidCallback activate;
}

class _UnifiedSearchPanelState extends ConsumerState<UnifiedSearchPanel> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initialQuery);
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;
  late String _query = widget.initialQuery;
  SearchLimits _limits = UnifiedSearchConfig.pages;
  late bool _scoped = widget.scope != null && widget.scope!.isNotEmpty;
  int _active = -1;
  List<_Row> _rows = const [];
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};
  UnifiedSearchResult? _memo;
  List<Object?> _memoKey = const [];

  @override
  void initState() {
    super.initState();
    UnifiedSearchPanel._live = this;
    UnifiedSearchPanel._syncOpen();
    _input.addListener(_onText);
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  UnifiedSearchResult _search(AppState app, int lockRev) {
    final scope = _scoped ? (widget.scope ?? '') : '';
    final key = <Object?>[app, lockRev, _query, _limits, scope];
    final memo = _memo;
    if (memo != null && _sameKey(key, _memoKey)) return memo;
    final lock = ref.read(chatLockProvider);
    final corpus = buildSearchCorpus(app, ref.read(unifiedSearchIndexProvider),
        locked: (k) => lock.isConversationLocked(k));
    final result = unifiedSearch(
      _query,
      channels: corpus.channels,
      nyms: corpus.nyms,
      messages: corpus.messages,
      limits: _limits,
      scope: scope,
      visible: corpus.visible,
    );
    _memo = result;
    _memoKey = key;
    return result;
  }

  static bool _sameKey(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    if (identical(UnifiedSearchPanel._live, this)) UnifiedSearchPanel._live = null;
    UnifiedSearchPanel._syncOpen();
    _debounce?.cancel();
    _input.removeListener(_onText);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(
        const Duration(milliseconds: UnifiedSearchConfig.debounceMs), () {
      if (!mounted) return;
      setState(() {
        _query = v;
        _limits = UnifiedSearchConfig.pages;
        _active = -1;
      });
    });
  }

  void _clear() {
    _debounce?.cancel();
    _input.clear();
    setState(() {
      _query = '';
      _limits = UnifiedSearchConfig.pages;
      _active = -1;
    });
    _focus.requestFocus();
  }

  void _move(int delta) {
    if (_rows.isEmpty) return;
    setState(() {
      _active = _active < 0
          ? (delta > 0 ? 0 : _rows.length - 1)
          : (_active + delta).clamp(0, _rows.length - 1);
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _active < 0 || _active >= _rows.length) return;
      final ctx = _keys[_rows[_active].id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
            duration: Duration.zero);
        Scrollable.ensureVisible(ctx,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
            duration: Duration.zero);
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (_debounce?.isActive ?? false) {
        _debounce!.cancel();
        setState(() => _query = _input.text);
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && _rows.isNotEmpty) _rows.first.activate();
        });
        return KeyEventResult.handled;
      }
      if (_rows.isEmpty) return KeyEventResult.handled;
      _rows[_active < 0 ? 0 : _active].activate();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _close(void Function(ProviderContainer c, BuildContext root) then) {
    final container = ProviderScope.containerOf(context, listen: false);
    final nav = Navigator.of(context);
    final root = Navigator.of(context, rootNavigator: true).context;
    nav.pop();
    then(container, root);
  }

  void _openChannel(SearchChannelItem it) {
    _close((c, _) {
      if (it.kind == 'group') {
        c.read(appStateProvider.notifier).switchView(ChatView.group(it.key));
        return;
      }
      if (!it.joined) {
        c.read(nostrControllerProvider).switchChannel(it.key,
            geohash: it.kind == 'geohash' ? it.key : '');
        return;
      }
      c.read(appStateProvider.notifier).switchView(ChatView.channel(it.key));
    });
  }

  void _join(SearchJoin j) {
    _close((c, _) => c
        .read(nostrControllerProvider)
        .switchChannel(j.key, geohash: j.geohash ? j.key : ''));
  }

  void _openNym(SearchNymItem it) {
    _close((c, root) {
      final self = c.read(appStateProvider).selfPubkey;
      ContextMenuPanel.show(
        root,
        target: CtxTarget(
          pubkey: it.pubkey,
          nym: it.nym,
          isSelf: it.pubkey == self,
          isBot: kVerifiedBotPubkeys.contains(it.pubkey),
          profileOnly: true,
        ),
      );
    });
  }

  void _openMessage(SearchMessageItem it) {
    final m = it.ref;
    if (m is! Message) return;
    _close((c, _) => openSearchHit(c.read, it.key, m));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final app = ref.watch(appStateProvider);
    final lockRev = ref.watch(chatLockRevisionProvider);
    final settings = ref.watch(settingsProvider);
    final result = _search(app, lockRev);
    final q = result.query;
    final rows = <_Row>[];
    final children = <Widget>[];

    Widget header(String title, int total) => Semantics(
          key: ValueKey('searchHeader-$title'),
          header: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(
              '${title.toUpperCase()}  ·  $total',
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );

    Widget more(String group, int shown, int total, SearchLimits next) =>
        SizedBox(
          width: double.infinity,
          child: TextButton(
            key: ValueKey('searchMore-$group'),
            onPressed: () => setState(() => _limits = next),
            child: Text('${_s('showMore')} (${total - shown})',
                textAlign: TextAlign.center),
          ),
        );

    Widget glyph(String key) {
      final Widget inner;
      final String kind;
      if (key.startsWith('pm-')) {
        kind = 'pm';
        inner = NymSvgIcon(NymIcons.ctxPm, size: 18, color: c.primary);
      } else if (key.startsWith('group-')) {
        final id = key.substring(6);
        Group? g;
        for (final x in app.groups) {
          if (x.id == id) g = x;
        }
        final avatar = g?.avatar;
        if (g != null && avatar != null && avatar.isNotEmpty) {
          kind = 'groupAvatar';
          inner = ClipOval(
              child: NymAvatar(seed: g.id, size: 22, imageUrl: avatar));
        } else {
          kind = 'group';
          inner = NymSvgIcon(groupChatGlyphSvg, size: 18, color: c.primary);
        }
      } else {
        final geo = isValidGeohash(key.replaceFirst(RegExp(r'^#+'), ''));
        kind = 'channel';
        inner = NymSvgIcon(channelGlyphSvg(geohash: geo),
            size: 18, color: c.primary);
      }
      return SizedBox(
        key: ValueKey('searchConv-$key'),
        width: 28,
        height: 24,
        child: Center(
            child: KeyedSubtree(key: ValueKey('searchGlyph-$kind'), child: inner)),
      );
    }

    Widget conv(String key) {
      final Widget inner;
      if (key.startsWith('pm-')) {
        final peer = key.substring(3);
        inner = NymAvatar(
            seed: peer, size: 26, imageUrl: app.users[peer]?.profile?.picture);
      } else if (key.startsWith('group-')) {
        final id = key.substring(6);
        Group? g;
        for (final x in app.groups) {
          if (x.id == id) g = x;
        }
        inner = g == null
            ? NymSvgIcon(groupChatGlyphSvg, size: 18, color: c.primary)
            : GroupSidebarAvatar(
                group: g, selfPubkey: app.selfPubkey, users: app.users);
      } else {
        inner = NymSvgIcon(
            channelGlyphSvg(
                geohash:
                    isValidGeohash(key.replaceFirst(RegExp(r'^#+'), ''))),
            size: 18,
            color: c.primary);
      }
      return Align(
          alignment: Alignment.centerLeft,
          child: KeyedSubtree(key: ValueKey('searchConv-$key'), child: inner));
    }

    Widget row(_Row r, Widget child) {
      final i = rows.length;
      rows.add(r);
      final selected = i == _active;
      return Semantics(
        key: _keys.putIfAbsent(r.id, GlobalKey.new),
        button: true,
        selected: selected,
        label: r.label,
        excludeSemantics: true,
        child: Material(
          color: selected ? c.primaryA(0.12) : Colors.transparent,
          borderRadius: NymRadius.rxs,
          child: InkWell(
            key: ValueKey('searchRow-${r.id}'),
            borderRadius: NymRadius.rxs,
            onTap: r.activate,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: child,
              ),
            ),
          ),
        ),
      );
    }

    if (!q.isEmpty) {
      if (result.channels.total > 0 || result.join != null) {
        children.add(header(_s('channels'), result.channels.total));
        for (final it in result.channels.items) {
          final label = it.kind == 'group' ? it.name : '#${it.name}';
          final sub = it.kind == 'group'
              ? _s('group')
              : it.joined
                  ? _s('joined')
                  : _s('notJoined');
          children.add(row(
            _Row('channel-${it.kind}-${it.key}', '$label, $sub',
                () => _openChannel(it)),
            Row(children: [
              SizedBox(
                width: 36,
                child: conv(it.kind == 'group' ? 'group-${it.key}' : '#${it.key}'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Highlighted(
                  text: label,
                  tokens: q.nameTokens,
                  style: TextStyle(color: c.text, fontSize: 14),
                  hit: TextStyle(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                      backgroundColor: c.primaryA(0.18)),
                ),
              ),
              Text(sub, style: TextStyle(color: c.textDim, fontSize: 11)),
            ]),
          ));
        }
        if (result.channels.total > result.channels.items.length) {
          children.add(more(
              'channels',
              result.channels.items.length,
              result.channels.total,
              _limits.copyWith(
                  channels:
                      _limits.channels + UnifiedSearchConfig.steps.channels)));
        }
        final j = result.join;
        if (j != null) {
          final label = j.geohash
              ? _s('joinGeohash', {'name': j.key})
              : _s('joinChannel', {'name': j.key});
          children.add(row(
            _Row('join-${j.key}', label, () => _join(j)),
            Row(children: [
              SizedBox(
                width: 28,
                child: Icon(Icons.add, size: 18, color: c.primary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(color: c.primary, fontSize: 14)),
              ),
            ]),
          ));
        }
      }
      if (result.nyms.total > 0) {
        children.add(header(_s('nyms'), result.nyms.total));
        for (final it in result.nyms.items) {
          final suffix = getPubkeySuffix(it.pubkey);
          final label = '${it.nym}#$suffix';
          children.add(row(
            _Row('nym-${it.pubkey}',
                it.friend ? '$label, ${_s('friend')}' : label,
                () => _openNym(it)),
            Row(children: [
              SizedBox(
                width: 36,
                child: Center(
                    child: NymAvatar(
                        seed: it.pubkey,
                        size: 20,
                        imageUrl: app.users[it.pubkey]?.profile?.picture)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NymName(
                  base: it.nym,
                  pubkey: it.pubkey,
                  tokens: q.nameTokens,
                  style: TextStyle(color: c.text, fontSize: 14),
                  hit: TextStyle(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                      backgroundColor: c.primaryA(0.18)),
                ),
              ),
              if (it.friend)
                Text(_s('friend'),
                    style: TextStyle(color: c.textDim, fontSize: 11)),
            ]),
          ));
        }
        if (result.nyms.total > result.nyms.items.length) {
          children.add(more(
              'nyms',
              result.nyms.items.length,
              result.nyms.total,
              _limits.copyWith(
                  nyms: _limits.nyms + UnifiedSearchConfig.steps.nyms)));
        }
      }
      if (result.messages.total > 0) {
        children.add(header(_s('messages'), result.messages.total));
        for (final it in result.messages.items) {
          final m = it.ref as Message;
          final sender = chatDisplayNym(app, m.pubkey, m.author);
          final senderBase = stripPubkeySuffix(sender);
          final info = chatInfoFor(app, it.key, from: m);
          final chat = info['t'] == 'dm'
              ? _s('dm', {'name': info['n']})
              : '${info['n']}';
          final when = formatFullTimestamp(
              DateTime.fromMillisecondsSinceEpoch(m.timestamp),
              settings.timeFormat,
              settings.dateFormat);
          final snip = searchSnippet(it.text, q.tokens);
          children.add(row(
            _Row('message-${it.key}-${it.id}',
                '$sender, $chat, $when: ${snip.text}', () => _openMessage(it)),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              glyph(it.key),
              const SizedBox(width: 16),
              Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  if (m.pubkey.isNotEmpty) ...[
                    NymAvatar(
                        seed: m.pubkey,
                        size: 16,
                        imageUrl: app.users[m.pubkey]?.profile?.picture),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: _NymName(
                        base: senderBase,
                        pubkey: m.pubkey,
                        tokens: const [],
                        style: TextStyle(
                            color: c.secondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                        hit: const TextStyle()),
                  ),
                  Text('  ·  ',
                      style: TextStyle(color: c.textDim, fontSize: 12)),
                  Flexible(
                    child: Text(chat,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(when,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: 11)),
                  ),
                ]),
                const SizedBox(height: 3),
                _Highlighted(
                  text: snip.text,
                  ranges: snip.ranges,
                  maxLines: 3,
                  style: TextStyle(color: c.text, fontSize: 13, height: 1.3),
                  hit: TextStyle(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                      backgroundColor: c.primaryA(0.18)),
                ),
              ],
            )),
            ]),
          ));
        }
        if (result.messages.total > result.messages.items.length) {
          children.add(more(
              'messages',
              result.messages.items.length,
              result.messages.total,
              _limits.copyWith(
                  messages:
                      _limits.messages + UnifiedSearchConfig.steps.messages)));
        }
      }
    }
    _rows = rows;
    final live = {for (final r in rows) r.id};
    _keys.removeWhere((id, _) => !live.contains(id));
    if (_active >= rows.length) _active = rows.isEmpty ? -1 : rows.length - 1;

    final total =
        result.channels.total + result.nyms.total + result.messages.total;
    Widget body;
    if (q.isEmpty) {
      body = _State(
        key: const ValueKey('searchEmptyState'),
        icon: NymIcons.search,
        title: _s('empty'),
        hint: _s('emptyHint'),
      );
    } else if (result.isEmpty) {
      body = _State(
        key: const ValueKey('searchNoResults'),
        icon: NymIcons.search,
        title: _s('noResults', {'q': _query.trim()}),
        hint: q.text.length < UnifiedSearchConfig.minMessageChars
            ? _s('shortMessages')
            : null,
      );
    } else {
      body = ListView(
        key: const ValueKey('searchResults'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        children: children,
      );
    }

    final scopeKey = widget.scope ?? '';
    final scopeName = scopeKey.isEmpty ? '' : '${chatInfoFor(app, scopeKey)['n']}';
    final panel = Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 6),
          child: Row(children: [
            Expanded(
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  key: const ValueKey('unifiedSearchInput'),
                  controller: _input,
                  focusNode: _focus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  style: TextStyle(color: c.text, fontSize: 15),
                  decoration: NymField.decoration(c,
                    hint: _input.text.isEmpty ? _s('placeholder') : null,
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(12),
                      child: NymSvgIcon(NymIcons.search,
                          size: 16, color: NymField.icon(c)),
                    ),
                    suffixIcon: _input.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: tr('Clear'),
                            onPressed: _clear,
                            icon: Icon(Icons.close,
                                size: 16, color: NymField.icon(c)),
                          )),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('unifiedSearchClose'),
              tooltip: _s('close'),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.close, size: 20, color: c.textDim),
            ),
          ]),
        ),
        if (scopeKey.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Wrap(spacing: 8, children: [
              ChoiceChip(
                key: const ValueKey('searchScopeAll'),
                label: Text(_s('scopeAll')),
                selected: !_scoped,
                onSelected: (_) => setState(() {
                  _scoped = false;
                  _active = -1;
                }),
              ),
              ChoiceChip(
                key: const ValueKey('searchScopeChat'),
                label: Text(_s('scopeChat', {'chat': scopeName})),
                selected: _scoped,
                onSelected: (_) => setState(() {
                  _scoped = true;
                  _active = -1;
                }),
              ),
            ]),
          ),
        if (!q.isEmpty && !result.isEmpty)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_s('resultCount', {'n': total}),
                  key: const ValueKey('searchCount'),
                  style: TextStyle(color: c.textDim, fontSize: 11)),
            ),
          ),
        Expanded(child: body),
      ],
    );

    return nymSheetOr(
      context,
      panel,
      (body) {
        final size = MediaQuery.sizeOf(context);
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: size.width * 0.92,
              height: size.height * 0.8,
              constraints: const BoxConstraints(maxWidth: 640),
              padding: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: body,
            ),
          ),
        );
      },
    );
  }
}

class _State extends StatelessWidget {
  const _State({super.key, required this.icon, required this.title, this.hint});

  final String icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NymSvgIcon(icon, size: 36, color: c.textDim),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.text, fontSize: 15)),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.style,
    required this.hit,
    this.tokens,
    this.ranges,
    this.maxLines = 1,
  });

  final String text;
  final List<String>? tokens;
  final List<List<int>>? ranges;
  final TextStyle style;
  final TextStyle hit;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final rs = ranges ?? searchHighlight(text, tokens ?? const []);
    final spans = <TextSpan>[];
    var at = 0;
    for (final r in rs) {
      if (r[0] > at) spans.add(TextSpan(text: text.substring(at, r[0])));
      spans.add(TextSpan(text: text.substring(r[0], r[1]), style: hit));
      at = r[1];
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class UnifiedSearchButton extends StatefulWidget {
  const UnifiedSearchButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<UnifiedSearchButton> createState() => _UnifiedSearchButtonState();
}

class _UnifiedSearchButtonState extends State<UnifiedSearchButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = _s('placeholder');
    return ValueListenableBuilder<bool>(
      valueListenable: UnifiedSearchPanel.openListenable,
      builder: (context, open, child) =>
          open ? const SizedBox(height: 58) : child!,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: NymTooltip(
       richMessage: keycapTooltip(context, label, shortcutKeyLabel('search')),
       excludeFromSemantics: true,
       child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: const ValueKey('unifiedSearchOpen'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: NymField.fill(c),
                borderRadius: NymRadius.rsm,
                border: Border.all(
                    color: _hover ? c.primaryA(0.4) : NymField.border(c)),
              ),
              child: Row(children: [
                NymSvgIcon(NymIcons.search, size: 15, color: NymField.icon(c)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: NymField.placeholder(c), fontSize: 13)),
                ),
              ]),
            ),
          ),
        ),
      ),
      ),
    ),
    );
  }
}

TextStyle nymSuffixStyle(TextStyle base) => base.copyWith(
      color: (base.color ?? const Color(0xFFFFFFFF)).withValues(
          alpha: (base.color ?? const Color(0xFFFFFFFF)).a * 0.7),
      fontSize: (base.fontSize ?? 14) * 0.9,
      fontWeight: FontWeight.w100,
    );

class _NymName extends StatelessWidget {
  const _NymName({
    required this.base,
    required this.pubkey,
    required this.tokens,
    required this.style,
    required this.hit,
  });

  final String base;
  final String pubkey;
  final List<String> tokens;
  final TextStyle style;
  final TextStyle hit;

  @override
  Widget build(BuildContext context) {
    final suffix = '#${getPubkeySuffix(pubkey)}';
    final label = '$base$suffix';
    final rs = searchHighlight(label, tokens);
    final suffixStyle = nymSuffixStyle(style);
    List<InlineSpan> part(int from, int to) {
      final out = <InlineSpan>[];
      var at = from;
      for (final r in rs) {
        final a = r[0] < from ? from : r[0];
        final b = r[1] > to ? to : r[1];
        if (b <= a) continue;
        if (a > at) out.add(TextSpan(text: label.substring(at, a)));
        out.add(TextSpan(text: label.substring(a, b), style: hit));
        at = b;
      }
      if (at < to) out.add(TextSpan(text: label.substring(at, to)));
      return out;
    }

    final tail = part(base.length, label.length);
    return Text.rich(
      TextSpan(style: style, children: [
        ...part(0, base.length),
        tail.length == 1 && tail.single is TextSpan && (tail.single as TextSpan).style == null
            ? TextSpan(text: suffix, style: suffixStyle)
            : TextSpan(style: suffixStyle, children: tail),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
