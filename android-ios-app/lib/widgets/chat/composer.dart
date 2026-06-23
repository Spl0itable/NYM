import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/autocomplete/autocomplete_dropdown.dart';
import '../../features/autocomplete/autocomplete_queries.dart';
import '../../features/autocomplete/autocomplete_triggers.dart';
import '../../features/commands/command_palette.dart';
import '../../features/commands/command_registry.dart';
import '../../features/emoji/custom_emoji.dart';
import '../../features/emoji/emoji_data.dart';
import '../../features/emoji/emoji_picker.dart';
import '../../features/emoji/gif_picker.dart';
import '../../features/nymbot/bot_chat_screen.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../context_menu/interaction_hooks.dart';

/// The message composer (`.input-container` + `.message-input` + `.input-buttons`,
/// docs/specs/02 §5.5). A multi-line input with a toolbar of image/file/emoji/GIF
/// icon buttons and a SEND button wired to a local echo. On mobile the toolbar
/// stacks full-width below the input. (docs/specs/02 §1.2)
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key, required this.compact});

  /// Mobile/tablet: stack toolbar below the input (column layout).
  final bool compact;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  // Inline composer popovers (`#emojiPicker` / `#gifPicker`). Only one open at
  // a time, anchored above the toolbar button like the PWA's inline popups.
  final _emojiPortal = OverlayPortalController();
  final _gifPortal = OverlayPortalController();
  final _emojiAnchor = LayerLink();
  final _gifAnchor = LayerLink();

  // Lazily-loaded prefs + stores (only touched once a picker is opened).
  SharedPreferences? _prefs;
  List<String> _recents = const [];
  CustomEmojiState _customEmojis = CustomEmojiState.empty;

  // --- Autocomplete / command palette state --------------------------------
  // The active trigger token at the caret + its rendered content. Mirrors the
  // PWA's single-active-dropdown model (only one of @/#/:/\\/`/` is open).
  final _acAnchor = LayerLink();
  final _acPortal = OverlayPortalController();
  TriggerMatch _trigger = const TriggerMatch.none();
  AutocompleteView? _acView;
  List<PaletteRow> _paletteRows = const [];
  int _selectedIndex = 0;

  bool get _paletteActive => _trigger.kind == TriggerKind.command;
  bool get _acActive => _acView != null && !_acView!.isEmpty;
  bool get _overlayActive => _paletteActive
      ? _paletteRows.isNotEmpty
      : _acActive;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Applies a mention/quote request from the context menu into the input
  /// (ui-context.js `insertMention` / `setQuoteReply`).
  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        final insert = '${needsSpace ? ' ' : ''}@$fullNym ';
        _controller.text = existing + insert;
      case QuoteAction(:final fullNym, :final content):
        // Render as a `> @author: msg` blockquote the formatter recognizes.
        final prefix = _controller.text.isEmpty ? '' : '\n';
        _controller.text =
            '$prefix> @$fullNym: $content\n${_controller.text}';
    }
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focus.requestFocus();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // Register the system-message sink so command feedback surfaces somewhere.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(nostrControllerProvider).setCommandHooks(
            onSystemMessage: _onSystemMessage,
          );
    });
  }

  void _onSystemMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  /// Resolve prefs once, then hydrate recents + the cached NIP-30 custom emoji.
  Future<SharedPreferences> _ensurePrefs() async {
    if (_prefs != null) return _prefs!;
    final prefs = await ref.read(emojiPrefsProvider.future);
    _prefs = prefs;
    _recents = EmojiRecentsStore(prefs).load();
    _customEmojis = loadCustomEmojiState(prefs);
    return prefs;
  }

  /// Insert text at the current selection (mirrors PWA `insertEmoji`/`insertGif`
  /// which splice at the caret), keeping focus in the input.
  void _insertAtCaret(String insert) {
    final sel = _controller.selection;
    final text = _controller.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, insert);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {});
    _focus.requestFocus();
  }

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _emojiPortal.hide();
      return;
    }
    _gifPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    setState(() {});
    _emojiPortal.show();
  }

  Future<void> _toggleGifPicker() async {
    if (_gifPortal.isShowing) {
      _gifPortal.hide();
      return;
    }
    _emojiPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    setState(() {});
    _gifPortal.show();
  }

  /// Emoji chosen: insert (unicode char or `:shortcode:`) and bump recents.
  Future<void> _onEmojiSelected(String emoji) async {
    _insertAtCaret(emoji);
    _emojiPortal.hide();
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  void _onGifSelected(String url) {
    // PWA appends the GIF URL; the formatter renders it as media.
    _insertAtCaret(url);
    _gifPortal.hide();
  }

  // --- Autocomplete driving ------------------------------------------------

  /// Recomputes the active trigger + dropdown contents on every input change
  /// (mirrors handleInputChange + refresh*IfOpen). Re-queries as the user types.
  void _onInputChanged() {
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : _controller.text.length;
    final trigger = detectTrigger(_controller.text, caret: caret);
    _trigger = trigger;
    _selectedIndex = 0;

    if (trigger.kind == TriggerKind.command) {
      _paletteRows = buildPaletteRows(trigger.query);
      _acView = null;
    } else if (trigger.kind != TriggerKind.none) {
      _paletteRows = const [];
      _acView = _buildAutocompleteView(trigger);
    } else {
      _paletteRows = const [];
      _acView = null;
    }

    if (_overlayActive) {
      if (!_acPortal.isShowing) _acPortal.show();
    } else {
      if (_acPortal.isShowing) _acPortal.hide();
    }
    setState(() {});
  }

  AutocompleteView? _buildAutocompleteView(TriggerMatch trigger) {
    final state = ref.read(appStateProvider);
    final view = state.view;
    final currentKey =
        view.kind == ViewKind.channel ? view.id.toLowerCase() : '';

    switch (trigger.kind) {
      case TriggerKind.mention:
        // Priority pubkeys: the current PM peer / group members.
        Set<String>? priority;
        if (view.kind == ViewKind.pm) {
          priority = {view.id};
        } else if (view.kind == ViewKind.group) {
          final g = state.groups.where((g) => g.id == view.id);
          if (g.isNotEmpty) {
            priority =
                g.first.members.where((p) => p != state.selfPubkey).toSet();
          }
        }
        final results = queryMentions(
          users: state.users,
          search: trigger.query,
          currentChannelKey: currentKey,
          priority: priority,
        );
        return AutocompleteView.mentions(results);
      case TriggerKind.channel:
        final counts = <String, int>{};
        state.messages.forEach((key, msgs) {
          if (key.startsWith('#')) counts[key.substring(1)] = msgs.length;
        });
        final results = queryChannels(
          search: trigger.query,
          channels: state.channels,
          messageChannelCounts: counts,
          currentKey: currentKey,
        );
        return AutocompleteView.channels(results);
      case TriggerKind.emoji:
        final results = queryEmoji(
          search: trigger.query,
          recents: _recents,
          custom: _customEmojis,
        );
        return AutocompleteView.emoji(results);
      case TriggerKind.kaomoji:
        final sections = queryKaomoji(search: trigger.query);
        return AutocompleteView.kaomoji(sections);
      default:
        return null;
    }
  }

  void _hideOverlay() {
    _trigger = const TriggerMatch.none();
    _acView = null;
    _paletteRows = const [];
    if (_acPortal.isShowing) _acPortal.hide();
    setState(() {});
  }

  /// Replaces the trigger token (from [triggerIndex] to the caret) with [insert]
  /// and moves the caret to the end of the inserted text. Mirrors the splice in
  /// selectAutocomplete / insertChannelReference / selectSpecificEmojiAutocomplete.
  void _replaceTriggerToken(String insert) {
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : _controller.text.length;
    final start = _trigger.triggerIndex;
    if (start < 0) return;
    final text = _controller.text;
    final next = text.replaceRange(start, caret, insert);
    final offset = start + insert.length;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: offset),
    );
    _hideOverlay();
    _focus.requestFocus();
    // Re-evaluate (the inserted trailing space closes the token).
    _onInputChanged();
  }

  void _completeCommand(CommandSpec spec) {
    // selectCommand inserts `"<command> "` then hides the palette.
    _controller.value = TextEditingValue(
      text: '${spec.name} ',
      selection: TextSelection.collapsed(offset: spec.name.length + 1),
    );
    _hideOverlay();
    _focus.requestFocus();
  }

  int get _navItemCount =>
      _paletteActive ? paletteCommands(_paletteRows).length : (_acView?.itemCount ?? 0);

  void _confirmSelection() {
    if (_paletteActive) {
      final cmds = paletteCommands(_paletteRows);
      if (_selectedIndex >= 0 && _selectedIndex < cmds.length) {
        _completeCommand(cmds[_selectedIndex]);
      }
      return;
    }
    final v = _acView;
    if (v == null) return;
    switch (v.kind) {
      case AutocompleteKind.mention:
        if (_selectedIndex < v.mentions.length) {
          _replaceTriggerToken(v.mentions[_selectedIndex].insertText);
        }
      case AutocompleteKind.channel:
        if (_selectedIndex < v.channels.length) {
          _replaceTriggerToken(v.channels[_selectedIndex].insertText);
        }
      case AutocompleteKind.emoji:
        if (_selectedIndex < v.emoji.length) {
          _onEmojiAutocompletePicked(v.emoji[_selectedIndex]);
        }
      case AutocompleteKind.kaomoji:
        final items = v.kaomojiItems;
        if (_selectedIndex < items.length) {
          _replaceTriggerToken(kaomojiInsertText(items[_selectedIndex]));
        }
    }
  }

  void _onEmojiAutocompletePicked(EmojiResult e) {
    _replaceTriggerToken(e.insertText);
    // Bump recents like selectSpecificEmojiAutocomplete (addToRecentEmojis).
    unawaitedRecents(e.emoji);
  }

  void unawaitedRecents(String emoji) async {
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  /// Intercepts arrow/Enter/Tab/Esc while a dropdown is open (navigate*/select*).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_overlayActive) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final count = _navItemCount;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedIndex = wrapIndex(_selectedIndex, 1, count));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedIndex = wrapIndex(_selectedIndex, -1, count));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
      _confirmSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _hideOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    // Routes through the NostrController: optimistic local echo + relay
    // publish when an identity is live, falling back to local echo otherwise.
    // `?`/@Nymbot interception and `/` commands are handled inside sendCurrent.
    ref.read(nostrControllerProvider).sendCurrent(text);
    _controller.clear();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  // --- Attachments: image upload (Blossom) + P2P file share -----------------

  /// `#uploadProgress` state (0..1, null = hidden). Mirrors the PWA's progress
  /// bar shown during `uploadImage` (users.js:971).
  double? _uploadProgress;

  /// Image button (`selectImage` → fileInput): pick an image, upload it to a
  /// Blossom server through the ApiClient, then append the resulting URL to the
  /// input (the formatter renders it as media — users.js:1022).
  Future<void> _pickAndUploadImage() async {
    Uint8List bytes;
    String contentType;
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      bytes = await picked.readAsBytes();
      contentType = picked.mimeType ?? _guessImageMime(picked.name);
    } catch (_) {
      return; // picker unavailable (tests/desktop)
    }
    const maxUpload = 50 * 1024 * 1024; // 50 MB cap (users.js:977)
    if (bytes.length > maxUpload) {
      _onSystemMessage('Image files must be under 50MB.');
      return;
    }
    if (!mounted) return;
    setState(() => _uploadProgress = 0.1);
    final url = await ref.read(nostrControllerProvider).uploadImage(
          bytes,
          contentType: contentType,
          onProgress: (p) {
            if (mounted) setState(() => _uploadProgress = p);
          },
        );
    if (!mounted) return;
    setState(() => _uploadProgress = null);
    if (url == null) {
      _onSystemMessage('Failed to upload media.');
      return;
    }
    // Append the URL to the input (then a trailing space), like the PWA.
    final existing = _controller.text;
    final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
    _controller.text = '$existing${needsSpace ? ' ' : ''}$url ';
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    setState(() {});
    _focus.requestFocus();
  }

  /// File button (`selectP2PFile` → p2pFileInput): pick any file and offer it as
  /// a P2P transfer (`shareP2PFile`, p2p.js:86).
  Future<void> _pickAndShareFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(withData: true);
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _onSystemMessage('Could not read the selected file.');
      return;
    }
    await ref.read(nostrControllerProvider).shareP2PFile(
          bytes: bytes,
          name: file.name,
          type: _guessImageMime(file.name),
        );
    if (mounted) _onSystemMessage('File offered for P2P download.');
  }

  static String _guessImageMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  /// Bot-PM entry: binds the private Nymbot chat to the identity and opens
  /// [BotChatScreen] (the paid 1:1 surface). Exposed as a composer affordance
  /// since the PM-list entry is owned elsewhere.
  void _openBotChat() {
    ref.read(nostrControllerProvider).bindBotChat();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BotChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hasText = _controller.text.trim().isNotEmpty;

    // Apply mention/quote requests published by the context menu (one-shot).
    ref.listen(pendingComposerActionProvider, (_, action) {
      if (action == null) return;
      _applyComposerAction(action);
      ref.read(pendingComposerActionProvider.notifier).consume();
    });

    final input = _input(context);
    final toolbar = _toolbar(context, hasText);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_uploadProgress != null) _uploadBar(context),
            widget.compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      input,
                      const SizedBox(height: 10),
                      toolbar,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: input),
                      const SizedBox(width: 10),
                      toolbar,
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  /// `#uploadProgress` — a thin progress bar + "Uploading image…" label shown
  /// while a Blossom upload is in flight (users.js:988).
  Widget _uploadBar(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Uploading image…',
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(c.primary),
            ),
          ),
        ],
      ),
    );
  }

  /// `.message-input` wrapped with the autocomplete/command-palette overlay
  /// anchored above it (`bottom: 100%` like the PWA's inline dropdowns).
  Widget _input(BuildContext context) {
    return CompositedTransformTarget(
      link: _acAnchor,
      child: OverlayPortal(
        controller: _acPortal,
        overlayChildBuilder: _overlayChild,
        child: Focus(
          onKeyEvent: _onKey,
          child: _textField(context),
        ),
      ),
    );
  }

  /// The anchored dropdown — either the command palette or one of the four
  /// autocompletes — positioned above the input, full-width.
  Widget _overlayChild(BuildContext context) {
    if (!_overlayActive) return const SizedBox.shrink();
    final body = _paletteActive
        ? CommandPalette(
            rows: _paletteRows,
            selectedIndex: _selectedIndex,
            onSelect: _completeCommand,
          )
        : AutocompleteDropdown(
            view: _acView!,
            selectedIndex: _selectedIndex,
            custom: _customEmojis,
            onSelectMention: (m) => _replaceTriggerToken(m.insertText),
            onSelectChannel: (ch) => _replaceTriggerToken(ch.insertText),
            onSelectEmoji: _onEmojiAutocompletePicked,
            onSelectKaomoji: (k) => _replaceTriggerToken(kaomojiInsertText(k)),
          );
    return CompositedTransformFollower(
      link: _acAnchor,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: _anchorWidth(context),
            child: body,
          ),
        ),
      ),
    );
  }

  double _anchorWidth(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.size.width ?? MediaQuery.sizeOf(context).width;
  }

  /// `.message-input`: white@5 bg, glass border, bottom-rounded radius md.
  Widget _textField(BuildContext context) {
    final c = context.nym;
    return TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: 5,
      minLines: 1,
      textInputAction: TextInputAction.newline,
      onChanged: (_) => _onInputChanged(),
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.compact ? 16 : 15,
      ),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Type a message…',
        hintStyle: TextStyle(color: c.textDim, fontSize: widget.compact ? 16 : 15),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(NymRadius.md),
            top: Radius.circular(NymRadius.md),
          ),
          borderSide: BorderSide(color: c.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(NymRadius.md),
            top: Radius.circular(NymRadius.md),
          ),
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(NymRadius.md),
            top: Radius.circular(NymRadius.md),
          ),
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );
  }

  /// `.input-buttons`: image / file / emoji / GIF icon buttons + SEND.
  Widget _toolbar(BuildContext context, bool hasText) {
    final buttons = <Widget>[
      _IconBtn(
        icon: Icons.image_outlined,
        tooltip: 'Image',
        expand: widget.compact,
        onTap: _uploadProgress != null ? null : _pickAndUploadImage,
      ),
      _IconBtn(
        icon: Icons.attach_file,
        tooltip: 'File',
        expand: widget.compact,
        onTap: _pickAndShareFile,
      ),
      _emojiButton(context),
      _gifButton(context),
      _IconBtn(
        icon: Icons.smart_toy_outlined,
        tooltip: 'Nymbot',
        expand: widget.compact,
        onTap: _openBotChat,
      ),
      _SendButton(enabled: hasText, onTap: _send, expand: widget.compact),
    ];

    if (widget.compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            // SEND gets flex:2, others flex:1.
            Expanded(flex: i == buttons.length - 1 ? 2 : 1, child: buttons[i]),
            if (i != buttons.length - 1) const SizedBox(width: 6),
          ],
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i != buttons.length - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }

  /// Emoji toolbar button + its inline popover anchored above the button.
  Widget _emojiButton(BuildContext context) {
    return CompositedTransformTarget(
      link: _emojiAnchor,
      child: OverlayPortal(
        controller: _emojiPortal,
        overlayChildBuilder: (context) => _popover(
          link: _emojiAnchor,
          onDismiss: _emojiPortal.hide,
          child: ProviderScope(
            overrides: [
              customEmojiStateProvider.overrideWithValue(_customEmojis),
            ],
            child: EmojiPicker(
              recents: _recents,
              onSelect: _onEmojiSelected,
            ),
          ),
        ),
        child: _IconBtn(
          icon: Icons.emoji_emotions_outlined,
          tooltip: 'Emoji',
          expand: widget.compact,
          onTap: _toggleEmojiPicker,
        ),
      ),
    );
  }

  /// GIF toolbar button + its inline popover anchored above the button.
  Widget _gifButton(BuildContext context) {
    return CompositedTransformTarget(
      link: _gifAnchor,
      child: OverlayPortal(
        controller: _gifPortal,
        overlayChildBuilder: (context) => _popover(
          link: _gifAnchor,
          onDismiss: _gifPortal.hide,
          child: GifPicker(
            favoritesStore: FavoriteGifsStore(_prefs!),
            onSelect: _onGifSelected,
          ),
        ),
        child: _IconBtn(
          icon: Icons.gif_box_outlined,
          tooltip: 'GIF',
          expand: widget.compact,
          onTap: _toggleGifPicker,
        ),
      ),
    );
  }

  /// Positions a picker above its anchor button (bottom-anchored, like the
  /// PWA's `bottom: 100%` inline popup) with a barrier to dismiss on tap-out.
  Widget _popover({
    required LayerLink link,
    required VoidCallback onDismiss,
    required Widget child,
  }) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -8),
          showWhenUnlinked: false,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Material(
              type: MaterialType.transparency,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

/// `.icon-btn.input-btn`: height 42, 18×18 icon stroke text→primary, radius sm.
class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    this.expand = false,
    this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final bool expand;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final btn = Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: NymRadius.rsm,
        child: InkWell(
          onTap: onTap ?? () {},
          borderRadius: NymRadius.rsm,
          child: Container(
            height: 42,
            constraints: const BoxConstraints(minWidth: 42),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
            ),
            child: Icon(icon, size: 18, color: c.text),
          ),
        ),
      ),
    );
    return btn;
  }
}

/// `.send-btn`: primary@10 bg, primary@30 border, radius sm, "SEND" 12px
/// uppercase letter-spacing 1.5 weight 600. Disabled opacity 0.35.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.onTap,
    this.expand = false,
  });
  final bool enabled;
  final VoidCallback onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: c.primaryA(0.10),
        borderRadius: NymRadius.rsm,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: NymRadius.rsm,
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.primaryA(0.30)),
            ),
            child: Text(
              'SEND',
              style: TextStyle(
                color: c.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
