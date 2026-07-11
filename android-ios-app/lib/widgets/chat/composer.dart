import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../common/css_focus_ring.dart';
import '../nym_icons.dart';
import '../../features/autocomplete/autocomplete_dropdown.dart';
import '../../features/autocomplete/autocomplete_queries.dart';
import '../../features/autocomplete/autocomplete_triggers.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/commands/command_handler.dart';
import '../../features/commands/command_palette.dart';
import '../../features/commands/command_registry.dart';
import '../../features/emoji/custom_emoji.dart';
import '../../features/emoji/emoji_data.dart';
import '../../features/emoji/emoji_picker.dart';
import '../../features/emoji/gif_picker.dart';
import '../../features/groups/group_logic.dart';
import '../../features/identity/dev_nsec_modal.dart';
import '../../features/messages/format/message_content.dart'
    show InlineEmojiText, proxiedMedia;
import '../../features/messages/inline_network_image.dart';
import '../../features/nymbot/nymbot_models.dart';
import '../../features/polls/poll_create_modal.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/translate/translate_languages.dart';
import '../../features/translate/translate_service.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/group.dart' show GroupControlType;
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../context_menu/interaction_hooks.dart';
import 'message_row.dart'
    show GroupInfoMember, encodeGroupInfoSystemMessage;

/// Session-wide per-conversation unsent drafts — the PWA's app-level
/// `_inputDrafts` map + `_getInputContextKey` (channels.js:1075-1105). The PWA
/// has ONE persistent `#messageInput` shared by every conversation (including
/// the bot PM), so its draft map survives every switch; natively the store
/// must live OUTSIDE the composer widget state, because opening the Nymbot
/// chat swaps the canonical [Composer] out entirely (chat_pane returns
/// `BotChatScreen`) and its bot composer shares this same store.
class ComposerDrafts {
  ComposerDrafts._();

  static final Map<String, String> _drafts = {};

  /// `_getInputContextKey` (channels.js:1075-1079): `'g:'+group` / `'p:'+pm` /
  /// `'c:'+(geohash||channel)` — the [ChatView] id carries exactly those.
  static String keyFor(ChatView view) {
    switch (view.kind) {
      case ViewKind.group:
        return 'g:${view.id}';
      case ViewKind.pm:
        return 'p:${view.id}';
      case ViewKind.channel:
        return 'c:${view.id}';
    }
  }

  /// `_saveCurrentDraft` semantics (channels.js:1082-1089): stash [value]
  /// under [key]; a blank/whitespace draft DELETES the stored entry.
  static void save(String key, String value) {
    if (value.trim().isNotEmpty) {
      _drafts[key] = value;
    } else {
      _drafts.remove(key);
    }
  }

  /// The saved draft for [key], or '' when none (`_restoreDraftForContext`).
  static String restore(String key) => _drafts[key] ?? '';
}

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
  final _controller = EmojiSentinelController();
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

  // LIVE NIP-30 custom emoji (kind-30030 packs + kind-10030 list + inbound
  // `emoji` tags). Synced from [liveCustomEmojiProvider] on every build so the
  // emoji picker AND the `:` autocomplete surface user/relay packs — not just
  // the static `loadCustomEmojiState` cache. (The live notifier itself hydrates
  // from that cache, so this is a strict superset.)
  CustomEmojiState _customEmojis = CustomEmojiState.empty;

  // --- Quote-reply / edit preview chips (F1/F2) ----------------------------
  // The PWA defers the quote/edit until SEND: a colored chip sits above the
  // input while the user's typed text stays clean (messages.js setQuoteReply /
  // startEditMessage). `_pendingQuote` carries the author, the nested-quote-
  // STRIPPED text used by the send prepend (`pendingQuote.text`), and the FULL
  // original content the chip snippet is cleaned from (`setQuoteReply` builds
  // `cleanText` from its `text` ARGUMENT, messages.js:1845-1846, so nested
  // `> …` lines still show in the 120-char preview with the `>` removed);
  // `_pendingEdit` carries the message id + original content.
  ({String author, String text, String fullText})? _pendingQuote;
  PendingEdit? _pendingEdit;

  // --- Per-conversation unsent drafts ---------------------------------------
  // [ComposerDrafts] + `_activeDraftKey` (channels.js:1075-1105): every
  // conversation switch — a sidebar/channel switch OR a columns-deck focus
  // change (`_cvFocusColumn`, columns.js:549-564) — stashes the current input
  // under the OUTGOING conversation's key, clears the quote chip, cancels a
  // pending edit, then restores the INCOMING conversation's saved draft. The
  // map itself is session-level ([ComposerDrafts]) so drafts survive this
  // composer unmounting (the bot chat swap).
  String? _activeDraftKey;

  /// `_saveCurrentDraft` (channels.js:1082-1089): stash the input under the
  /// active key — a blank/whitespace draft DELETES the stored entry. Stored in
  /// EXPANDED form (`:code:` text, via [EmojiSentinelController.expand]) so a
  /// draft never carries sentinel chars whose allocations are dropped when the
  /// input empties (02-F-02-E); [_restoreDraftForContext]'s `_onInputChanged`
  /// re-collapses them on restore.
  void _saveCurrentDraft() {
    final key = _activeDraftKey;
    if (key == null) return;
    ComposerDrafts.save(key, _controller.expand(_controller.text));
  }

  /// `_restoreDraftForContext` (channels.js:1092-1105): point the active key at
  /// [view] and load its saved draft (empty when none). No-ops when the input
  /// already holds that exact text.
  void _restoreDraftForContext(ChatView view) {
    final key = ComposerDrafts.keyFor(view);
    _activeDraftKey = key;
    final draft = ComposerDrafts.restore(key);
    if (_controller.text == draft) return;
    _controller.text = draft;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    // `autoResizeTextarea` + `handleInputChange` — recompute the popout /
    // autocomplete state for the restored text.
    _onInputChanged();
  }

  /// Runs the PWA's conversation-switch composer sequence (columns.js:549-564,
  /// mirrored by switchChannel/openPM/openGroup): save the outgoing draft,
  /// clear any quote chip, cancel a pending edit (which empties the input),
  /// then restore the incoming conversation's draft.
  void _onViewSwitched(ChatView view) {
    if (!mounted) return;
    _saveCurrentDraft();
    _clearQuote();
    if (_pendingEdit != null) _cancelEdit();
    _restoreDraftForContext(view);
  }

  // --- In-composer translate (F7) ------------------------------------------
  // A 26×26 translate button overlaid bottom-right of the input opens a 230px
  // language dropdown; choosing a language translates the typed draft in place
  // (`#translateInputBtn` / `.translate-input-dropdown`, ui-context.js).
  final _translatePortal = OverlayPortalController();
  final _translateAnchor = LayerLink();
  final _translateSearchController = TextEditingController();
  String _translateQuery = '';
  bool _translating = false;

  /// Translate-dropdown favorites (`nym_translate_favorites`), pinned to the top
  /// of the language list. Loaded once prefs resolve (translate.js:93-99).
  List<String> _translateFavorites = const [];

  /// The favorites-pinned language order, snapshotted when the dropdown opens.
  /// The PWA only re-pins on the next open ("the list order updates the next
  /// time the dropdown opens", translate.js:563-571) — toggling a star mid-open
  /// flips its fill in place but does NOT reorder until reopen.
  List<MapEntry<String, String>> _translateLangOrder = const [];

  /// Whether the draft is tall enough to float into the `.composer-popout` box
  /// (PWA expands when content exceeds ~1.5 lines, ui-context.js:1738).
  bool _popout = false;

  /// Drives the `.composer-popout` floating field. When [_popout] is on, the
  /// in-flow slot is a fixed `--composer-row-base` placeholder (so the toolbar
  /// stays put) and the tall field floats UP over the messages via this portal
  /// (`.composer-popout .message-input{position:absolute; bottom:0}`,
  /// styles-chat.css:1737-1748). It follows the same `_acAnchor` leader as the
  /// autocomplete (a single leader supports multiple followers).
  final _popoutPortal = OverlayPortalController();

  /// Keeps the ONE TextField element alive across the `_popout` layout switch.
  /// The field lives in-flow while flat but moves into [_popoutPortal]'s
  /// overlay when the draft grows past the popout threshold — two different
  /// tree locations. Without a GlobalKey the flip REMOUNTS the EditableText
  /// (new element, new TextInputConnection), which force-closes the on-screen
  /// keyboard mid-typing; with it the element is reparented intact, so focus
  /// and the IME connection survive both directions of the switch.
  final GlobalKey _fieldKey = GlobalKey();

  /// Measures the message-input box so the autocomplete dropdown spans the
  /// INPUT width (`.autocomplete-dropdown{left:0;right:0}` = `.input-wrapper`),
  /// not the overlay-theatre / screen width (04-F1). Attached to the input's
  /// [CompositedTransformTarget]; [_anchorWidth] reads this box.
  final GlobalKey _inputKey = GlobalKey();

  /// Measures the visible quote/edit preview chip so the autocomplete dropdown
  /// clears it (`--ac-offset = previewH + 8`, ui-context.js:1759) — see 04-F2.
  final GlobalKey _chipKey = GlobalKey();

  /// Measures the floating popout field so the autocomplete dropdown clears the
  /// popout OVERHANG too (`--ac-offset` includes the overhang, ui-context.js
  /// :1759) — the dropdown floats above the grown field, not under it.
  final GlobalKey _popoutFieldKey = GlobalKey();

  /// Sent-message history for IRC-style ↑/↓ recall on an empty input
  /// (`navigateHistory`, ui-context.js:1021-1027). Newest last; capped.
  final List<String> _sentHistory = [];

  /// Cursor into [_sentHistory] while recalling; `_sentHistory.length` = "at the
  /// live (empty) draft", decremented by ↑, incremented by ↓.
  int _historyIndex = 0;

  /// MIME of the in-flight upload, so the progress label reads
  /// "Uploading video…" vs "…image…" (F6).
  String? _uploadMime;

  // --- Autocomplete / command palette state --------------------------------
  // The active trigger token at the caret + its rendered content. Mirrors the
  // PWA's single-active-dropdown model (only one of @/#/:/\\/`/` is open).
  final _acAnchor = LayerLink();
  final _acPortal = OverlayPortalController();
  TriggerMatch _trigger = const TriggerMatch.none();
  AutocompleteView? _acView;
  List<PaletteRow> _paletteRows = const [];
  // The public `?` Nymbot command palette rows (showBotCommandPalette). Same
  // `#commandPalette` surface as `/`, populated from the real bot catalogue.
  List<BotPaletteCommand> _botRows = const [];
  int _selectedIndex = 0;

  bool get _paletteActive => _trigger.kind == TriggerKind.command;
  bool get _botPaletteActive => _trigger.kind == TriggerKind.botCommand;
  bool get _acActive => _acView != null && !_acView!.isEmpty;
  bool get _overlayActive => _paletteActive
      ? _paletteRows.isNotEmpty
      : (_botPaletteActive ? _botRows.isNotEmpty : _acActive);

  @override
  void dispose() {
    // Stash the active conversation's unsent input before this composer
    // unmounts (opening the Nymbot chat swaps the whole pane for
    // `BotChatScreen`) — the PWA's single persistent input never unmounts, so
    // its `_inputDrafts` survives implicitly; ours must save here.
    _saveCurrentDraft();
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    _translateSearchController.dispose();
    super.dispose();
  }

  /// Applies a mention/quote request from the context menu (ui-context.js
  /// `insertMention` / `setQuoteReply`). Mentions splice at the caret; quotes
  /// set the [_pendingQuote] chip (deferred to send) rather than dumping
  /// `> @author:` markdown into the field.
  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        final insert = '${needsSpace ? ' ' : ''}@$fullNym ';
        _controller.text = existing + insert;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case QuoteAction(:final fullNym, :final content):
        // Set the quote chip; the input text stays clean (messages.js:1816).
        _pendingQuote = (
          author: fullNym,
          text: _strippedQuoteText(content),
          fullText: content,
        );
    }
    _focus.requestFocus();
    setState(() {});
  }

  /// Strips nested `>` quote lines (keep only the top level), collapses blank
  /// runs, and trims — the `setQuoteReply` pre-processing (messages.js:1817).
  static String _strippedQuoteText(String text) {
    final kept = <String>[];
    for (final line in text.split('\n')) {
      var depth = 0;
      var tmp = line;
      while (tmp.startsWith('>')) {
        depth++;
        tmp = tmp.substring(1).trimLeft();
      }
      if (depth < 1) kept.add(line);
    }
    return kept
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// The chip's cleaned preview text: strip HTML/markdown punctuation, cap 120
  /// (`cleanText` in setQuoteReply, messages.js:1845-1846).
  static String _quotePreviewText(String text) {
    final clean = text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_~`>#]'), '');
    return clean.length > 120 ? '${clean.substring(0, 120)}...' : clean;
  }

  void _clearQuote() {
    if (_pendingQuote == null) return;
    setState(() => _pendingQuote = null);
  }

  /// Enters inline-edit mode from a [pendingEditProvider] request: seed the
  /// input with the original content, drop any pending quote, show the amber
  /// edit chip, focus (startEditMessage, messages.js:1861).
  void _applyEdit(PendingEdit edit) {
    setState(() {
      _pendingEdit = edit;
      _pendingQuote = null;
    });
    _controller.text = edit.content;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focus.requestFocus();
    _onInputChanged();
  }

  /// Cancels an in-progress edit and empties the input (cancelEditMessage,
  /// messages.js:1912).
  void _cancelEdit() {
    if (_pendingEdit == null) return;
    setState(() => _pendingEdit = null);
    _controller.clear();
    _onInputChanged();
  }

  @override
  void initState() {
    super.initState();
    // Seed the draft key with the conversation already in view so the FIRST
    // switch away saves its unsent input (the PWA sets `_activeDraftKey` in
    // `_restoreDraftForContext`, which the boot path runs too).
    _activeDraftKey = ComposerDrafts.keyFor(ref.read(currentViewProvider));
    // `.message-input:focus` lifts the fill + paints a 3px focus ring, so
    // rebuild on focus change to swap those in/out.
    _focus.addListener(_onFocusChanged);
    // Register the system-message sink + the modal/effect hooks so slash
    // commands that open a UI surface (poll, zap, PM, group create/admin)
    // actually fire instead of silently no-opping.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(nostrControllerProvider).setCommandHooks(
            onSystemMessage: _onSystemMessage,
            hooks: _buildCommandHooks(),
          );
      // A REMOUNT (e.g. returning from the bot chat, which swaps this composer
      // out) must restore the incoming conversation's stashed draft — the
      // PWA's persistent input still holds it; ours starts empty.
      _restoreDraftForContext(ref.read(currentViewProvider));
    });
  }

  /// Builds the modal/effect hooks for slash commands whose surface lives in
  /// the UI layer. Mirrors the PWA's `cmd*` handlers (commands.js) that open
  /// these surfaces; registered once with the dispatcher via [setCommandHooks].
  CommandHooks _buildCommandHooks() {
    final controller = ref.read(nostrControllerProvider);
    return CommandHooks(
      // `/poll` → the poll editor (`cmdPoll` → #pollModal).
      openPoll: () {
        if (mounted) PollCreateModal.open(context);
      },
      // `/pm @nym` → open/create the thread (target resolved by the dispatcher).
      openPm: (pubkey, nym) => controller.startPM(pubkey, nym: nym),
      // `/zap @nym` → resolve the LN address, then the zap modal (`cmdZap` →
      // showZapModal, zaps.js:1934). The PWA always does a FRESH kind-0 fetch
      // first (`fetchLightningAddressForUser`, zaps.js:1955) after posting a
      // "Checking…" note, so a target whose profile hasn't been ingested yet
      // still gets zapped instead of a spurious "cannot receive zaps" — exactly
      // like the quick-zap path (zap_badge.dart `_quickZap`). Resolve via the
      // controller (nostr_controller.dart `resolveLightningAddressForZap`),
      // NOT the cache alone (F07-Z18).
      openZap: (pubkey, nym) async {
        final baseNym = stripPubkeySuffix(nym);
        _onSystemMessage('Checking if @$baseNym can receive zaps...');
        final lnAddr = await controller.resolveLightningAddressForZap(pubkey);
        if (lnAddr == null || lnAddr.isEmpty) {
          _onSystemMessage(
              '@$baseNym cannot receive zaps (no lightning address set)');
          return;
        }
        if (!mounted) return;
        await ZapModal.show(
          context,
          recipientPubkey: pubkey,
          recipientNym: nym,
          lightningAddress: lnAddr,
        );
      },
      // `/group @a @b [name]` → create the group (`cmdGroup` → createGroup).
      createGroup: (members, name) {
        if (members.isEmpty) {
          _onSystemMessage('Usage: /group @nym1 @nym2 [group name]');
          return;
        }
        unawaited(controller.createGroup(name, members));
      },
      // `/addmember @nym` (and `/invite @nym` in a group) → add to this group.
      addMember: _addMemberToCurrentGroup,
      invite: _addMemberToCurrentGroup,
      // `/groupinfo` → list owner / mods / member count (`cmdGroupInfo`).
      groupInfo: _showGroupInfo,
      // Group moderation (groups.js `cmd*`): the dispatcher resolves the target,
      // we act on the current group.
      kick: (pubkey) =>
          _withCurrentGroup((gid) => controller.kickFromGroup(gid, pubkey)),
      ban: (pubkey) =>
          _withCurrentGroup((gid) => controller.banFromGroup(gid, pubkey)),
      // `/unban @nym` → lift a group ban, owner-only (`cmdUnbanFromGroup` →
      // `unbanFromGroup`, groups.js:1926-1968).
      unban: _unbanFromCurrentGroup,
      addMod: (pubkey) =>
          _withCurrentGroup((gid) => controller.promoteModerator(gid, pubkey)),
      removeMod: (pubkey) =>
          _withCurrentGroup((gid) => controller.revokeModerator(gid, pubkey)),
      transferOwner: (pubkey) =>
          _withCurrentGroup((gid) => controller.transferOwner(gid, pubkey)),
      // `/nick <reserved>` → the developer-nsec challenge (cmdNick's reserved
      // gate, commands.js:614-626).
      openDevNsecChallenge: () => unawaited(_runDevNsecChallenge()),
    );
  }

  /// The `/nick <reserved>` challenge flow (`showDevNsecModal('nick')` →
  /// `applyDeveloperIdentity`, commands.js:614-626): prompt for the developer
  /// nsec, and on a verified match switch the RUNNING session to the developer
  /// account — natively the in-session nsec login ([NostrController.
  /// loginWithNsec], the same primitive the nsec-import modal uses) plays
  /// `applyDeveloperIdentity`'s role — then surface the PWA's confirmation.
  /// Cancel/dismiss aborts with the PWA's cancellation line (commands.js:617).
  Future<void> _runDevNsecChallenge() async {
    if (!mounted) return;
    final result = await DevNsecModal.open(context);
    if (result == null) {
      _onSystemMessage('Nickname change cancelled.');
      return;
    }
    try {
      await ref.read(nostrControllerProvider).loginWithNsec(result.nsec);
    } catch (_) {
      // The modal pre-verified the nsec, so a failure here is a login-flow
      // error; surface the abort line rather than crashing the composer.
      if (mounted) _onSystemMessage('Nickname change cancelled.');
      return;
    }
    if (!mounted) return;
    final nym = ref.read(appStateProvider).selfNym;
    _onSystemMessage('Identity verified. You are now logged in as $nym.');
  }

  /// Runs [action] against the current group id when the active view is a group.
  void _withCurrentGroup(Future<void> Function(String groupId) action) {
    final view = ref.read(currentViewProvider);
    if (view.kind == ViewKind.group) unawaited(action(view.id));
  }

  /// Resolves [arg] and adds them to the current group (`/addmember`/`/invite`).
  void _addMemberToCurrentGroup(String arg) {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) {
      _onSystemMessage('You must be in a group to add members.');
      return;
    }
    final target = resolveTarget(arg, ref.read(usersProvider));
    if (target == null) {
      _onSystemMessage('User ${arg.trim()} not found');
      return;
    }
    unawaited(
        ref.read(nostrControllerProvider).addGroupMembers(view.id, [target.pubkey]));
  }

  /// `/unban @nym` — a port of the PWA's owner-only `unbanFromGroup`
  /// (groups.js:1926-1968): gate on ownership ("Only the group owner can unban
  /// users."), require the target to actually be banned ("That user is not
  /// banned."), then drop the pubkey from `group.banned` and append the
  /// `{type:'unban'}` mod-log entry via the shared control-apply, confirming
  /// with the PWA's system line. The gift-wrapped `group-unban` rumor that
  /// notifies the unbanned user (tags `p`/`g`/`subject`/`type`/`unban`/`x`)
  /// needs an outbound publish path on [NostrController] (`unbanFromGroup`),
  /// which doesn't exist yet — see the handoff note.
  void _unbanFromCurrentGroup(String pubkey) {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) return;
    final appState = ref.read(appStateProvider.notifier);
    final app = ref.read(appStateProvider);
    final group = appState.groupById(view.id);
    if (group == null) return;
    if (!GroupLogic.isOwner(group, app.selfPubkey)) {
      _onSystemMessage('Only the group owner can unban users.');
      return;
    }
    if (!group.banned.contains(pubkey)) {
      _onSystemMessage('That user is not banned.');
      return;
    }
    appState.applyGroupControl(
      groupId: view.id,
      type: GroupControlType.unban,
      tags: [
        ['unban', pubkey],
      ],
      senderPubkey: app.selfPubkey,
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      eventId: GroupLogic.generateGroupId(),
    );
    // Resolve the target's profile if unknown (the PWA's fetchProfileDirect).
    ref.read(nostrControllerProvider).ensureProfiles([pubkey]);
    final nym = ref.read(usersProvider)[pubkey]?.nym ??
        'anon#${pubkey.substring(pubkey.length - 4)}';
    _onSystemMessage('@$nym was unbanned. They can be re-invited.');
  }

  /// `/groupinfo` — the PWA's `cmdGroupInfo` (groups.js:3487-3525): sort the
  /// members owner-first, then mods, then everyone else (each block
  /// alphabetized by nym), label `owner`/`mod`/`you`, and emit the structured
  /// `.group-info` block as a system row — rendered by `MessageRow` with the
  /// 22px avatar member rows — prefetching unknown profiles like the PWA's
  /// `ensureListProfiles`.
  void _showGroupInfo() {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) return;
    final group = ref.read(appStateProvider.notifier).groupById(view.id);
    if (group == null) return;
    final app = ref.read(appStateProvider);
    final users = ref.read(usersProvider);
    final ownerPk = group.createdBy;
    final mods = group.mods;
    String nymOf(String pk) => users[pk]?.nym ?? '';
    int rank(String pk) => pk == ownerPk ? 0 : (mods.contains(pk) ? 1 : 2);
    final sorted = [...group.members]..sort((a, b) {
        final ra = rank(a), rb = rank(b);
        if (ra != rb) return ra - rb;
        return nymOf(a).toLowerCase().compareTo(nymOf(b).toLowerCase());
      });
    final members = <GroupInfoMember>[
      for (final pk in sorted)
        (
          pubkey: pk,
          labels: [
            if (pk == ownerPk)
              'owner'
            else if (mods.contains(pk))
              'mod',
            if (pk == app.selfPubkey) 'you',
          ],
        ),
    ];
    ref.read(nostrControllerProvider).ensureProfiles(sorted);
    // Straight to the in-list system pill — no SnackBar echo of the payload.
    ref.read(appStateProvider.notifier).addSystemMessage(
        encodeGroupInfoSystemMessage((
      name: group.name,
      count: group.members.length,
      members: members,
    )));
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onSystemMessage(String text) {
    if (!mounted) return;
    // Render an in-list system pill (PWA `addSystemMessage`) AND surface a
    // transient SnackBar so command feedback is visible even when scrolled away.
    ref.read(appStateProvider.notifier).addSystemMessage(text);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  /// Resolve prefs once, then hydrate recents + translate favorites. Custom
  /// emoji come from the LIVE [liveCustomEmojiProvider] (synced in `build`).
  Future<SharedPreferences> _ensurePrefs() async {
    if (_prefs != null) return _prefs!;
    final prefs = await ref.read(emojiPrefsProvider.future);
    _prefs = prefs;
    _recents = EmojiRecentsStore(prefs).load();
    _translateFavorites = _loadTranslateFavorites(prefs);
    return prefs;
  }

  /// Read the persisted translate favorites (`nym_translate_favorites`).
  static List<String> _loadTranslateFavorites(SharedPreferences prefs) {
    final raw = prefs.getString(kTranslateFavoritesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// Toggle [code] in the favorites list and persist (translate.js:102-108):
  /// append when absent, remove when present. Persistence routes through
  /// [_ensurePrefs] so the write NEVER silently no-ops — the PWA's
  /// `_toggleTranslateFavorite` always hits localStorage. (In practice prefs
  /// are already resolved here: the dropdown open awaits [_ensurePrefs], and
  /// stars only exist inside the dropdown.)
  void _toggleTranslateFavorite(String code) {
    final next = [..._translateFavorites];
    if (!next.remove(code)) next.add(code);
    setState(() => _translateFavorites = next);
    _ensurePrefs()
        .then((prefs) => prefs.setString(kTranslateFavoritesKey, jsonEncode(next)));
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
    // Recompute the popout/trigger state since the spliced text can cross the
    // popout threshold (e.g. a long GIF url) — `_onInputChanged` also re-syncs
    // the floating-popout portal.
    _onInputChanged();
    _focus.requestFocus();
  }

  /// Hides an emoji/GIF picker WITHOUT a selection (✕ / tap-out / button
  /// toggle) and, on desktop widths, returns focus to the message input —
  /// `closeEnhancedEmojiModal`/`closeGifPicker` → `_focusMessageInput`
  /// (reactions.js:908 / ui-context.js:2194), which bails at ≤768px
  /// (channels.js:1383-1393) so a phone keyboard isn't yanked open.
  void _hidePickerAndRefocus(OverlayPortalController portal) {
    portal.hide();
    if (!mounted) return;
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return;
    }
    _focus.requestFocus();
  }

  void _hideEmojiPicker() => _hidePickerAndRefocus(_emojiPortal);

  void _hideGifPicker() => _hidePickerAndRefocus(_gifPortal);

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _hideEmojiPicker();
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
      _hideGifPicker();
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
    // INLINE-EMOJI-WHILE-TYPING (02-F-02-E): swap any just-completed known
    // `:shortcode:` to a single sentinel char (rendered as the emoji <img> by
    // [EmojiSentinelController.buildTextSpan]) BEFORE trigger/popout math, so the
    // rest of this method already sees the collapsed text + corrected caret.
    _controller.resolveInput();
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : _controller.text.length;
    // The verified-bot PM exposes PM-only `?` commands with multi-step
    // subcommands, so the `?` palette must survive a space there
    // (`showBotCommandPalette` with `inBotPM`, commands.js:436-468).
    final botPM = _inBotPM();
    final trigger =
        detectTrigger(_controller.text, caret: caret, botPM: botPM);
    _trigger = trigger;
    _selectedIndex = 0;

    // `.composer-popout`: float the input into an elevated box once the draft
    // exceeds ~1.5 lines (ui-context.js:1738), MEASURED at the field's real
    // width + font size (see [_draftWantsPopout]). The box lives in an
    // OverlayPortal so it overlays the messages (B4) rather than growing the
    // bottom bar — toggle the portal with the flag.
    _popout = _draftWantsPopout();
    _syncPopoutPortal();

    if (trigger.kind == TriggerKind.command) {
      _paletteRows = buildPaletteRows(trigger.query);
      _botRows = const [];
      _acView = null;
    } else if (trigger.kind == TriggerKind.botCommand) {
      // In the bot PM, surface the PM command set + `?model `/`?git `
      // subcommands (`filterBotPMCommands`, mirrors `showBotCommandPalette`'s
      // `inBotPM` branch, commands.js:441-454); elsewhere the PUBLIC `?` palette
      // filtered by `cmd.startsWith(input)`.
      _botRows = botPM
          ? [
              for (final c in filterBotPMCommands(trigger.query))
                BotPaletteCommand(command: c.name, desc: c.desc),
            ]
          : buildBotPaletteRows(trigger.query);
      _paletteRows = const [];
      _acView = null;
    } else if (trigger.kind != TriggerKind.none) {
      _paletteRows = const [];
      _botRows = const [];
      _acView = _buildAutocompleteView(trigger);
    } else {
      _paletteRows = const [];
      _botRows = const [];
      _acView = null;
    }

    if (_overlayActive) {
      if (!_acPortal.isShowing) _acPortal.show();
    } else {
      if (_acPortal.isShowing) _acPortal.hide();
    }
    setState(() {});
  }

  /// Shows/hides the floating-popout portal to track [_popout]. The portal hosts
  /// the tall `.composer-popout` field so it overlays the conversation while the
  /// in-flow placeholder keeps the toolbar fixed (B4).
  void _syncPopoutPortal() {
    if (_popout) {
      if (!_popoutPortal.isShowing) _popoutPortal.show();
    } else {
      if (_popoutPortal.isShowing) _popoutPortal.hide();
    }
  }

  /// `.message-input` font: `var(--user-text-size)` (the Settings text-size
  /// slider, styles-chat.css:1670), pinned to 16px at the ≤768 phone
  /// breakpoint (`font-size: 16px !important`, styles-themes-responsive.css:
  /// 270-275 — the iOS anti-zoom override).
  double _inputFontSize() {
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return 16;
    }
    return ref.read(settingsProvider).textSize.toDouble();
  }

  /// Whether the draft wraps past ~1.5 visual lines at the input's REAL width
  /// — the PWA's popout rule (`autoResizeTextarea`, ui-context.js:1725-1743:
  /// `expand = (scrollHeight - padV) > lineHeight * 1.5`). Lays the draft out
  /// with a [TextPainter] at the field's content width (the field minus its
  /// 16px paddings / the 38px translate-button inset) and compares the laid-out
  /// height against 1.5 of the SAME painter's line height, so the threshold
  /// tracks any field width and any user text size instead of a hard-coded
  /// chars-per-line guess.
  bool _draftWantsPopout() {
    final text = _controller.text;
    if (text.isEmpty) return false;
    final box = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    // Not laid out yet (first frame): keep the current state.
    if (box == null || !box.hasSize || box.size.width <= 0) return _popout;
    final fontSize = _inputFontSize();
    // `.message-input { padding: 10px 16px }` + 1px borders; with text the
    // right inset is the 38px translate-button reserve (see [_textField]).
    final hasText = text.trim().isNotEmpty;
    final contentWidth =
        box.size.width - 16 - (hasText ? 38 : 16) - 2;
    if (contentWidth <= 0) return _popout;
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: contentWidth);
    final expand = painter.height > painter.preferredLineHeight * 1.5;
    painter.dispose();
    return expand;
  }

  /// Whether the active view is the private chat with the verified Nymbot
  /// (`inPMMode && currentPM && isVerifiedBot(currentPM)`, commands.js:440). The
  /// `?` palette uses the PM command set (with subcommands) only here.
  bool _inBotPM() {
    final view = ref.read(appStateProvider).view;
    if (view.kind != ViewKind.pm) return false;
    return ref.read(nostrControllerProvider).isVerifiedBot(view.id);
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
    _botRows = const [];
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

  void _completeBotCommand(BotPaletteCommand cmd) {
    // selectCommand inserts `"?<name> "` (cmd.command already carries the `?`)
    // then re-runs the palette (commands.js:494-504): a multi-step `?command`
    // immediately shows its next-level options; anything without deeper options
    // just hides. In the bot PM we re-evaluate so `?model`/`?git` cascade into
    // their subcommands; the public set has none, so it stays hidden until a
    // fresh `?`.
    _controller.value = TextEditingValue(
      text: '${cmd.command} ',
      selection: TextSelection.collapsed(offset: cmd.command.length + 1),
    );
    _focus.requestFocus();
    if (_inBotPM()) {
      _onInputChanged();
    } else {
      _hideOverlay();
    }
  }

  int get _navItemCount {
    if (_paletteActive) return paletteCommands(_paletteRows).length;
    if (_botPaletteActive) return _botRows.length;
    return _acView?.itemCount ?? 0;
  }

  void _confirmSelection() {
    if (_paletteActive) {
      final cmds = paletteCommands(_paletteRows);
      if (_selectedIndex >= 0 && _selectedIndex < cmds.length) {
        _completeCommand(cmds[_selectedIndex]);
      }
      return;
    }
    if (_botPaletteActive) {
      if (_selectedIndex >= 0 && _selectedIndex < _botRows.length) {
        _completeBotCommand(_botRows[_selectedIndex]);
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
  /// Esc also cancels a pending edit/quote chip when no dropdown is open
  /// (ui-context.js:1018, 269-270).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_overlayActive) {
      // Hardware Enter SENDS (PWA: `Enter && !shiftKey → preventDefault();
      // sendMessage()`, ui-context.js:1007-1009). Shift+Enter inserts a newline
      // (ui-context.js:1010-1014), as does a bare Enter once the draft has grown
      // into the multi-line `.composer-popout` box — there the field is an
      // explicit long-form editor, so we let Enter fall through to the
      // TextField's `textInputAction.newline`. The field is otherwise
      // `textInputAction.newline` with NO `onSubmitted`, so without this a
      // hardware Enter would only ever insert a newline (never send).
      final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter;
      if (isEnter &&
          !_popout &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _send();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_pendingEdit != null) {
          _cancelEdit();
          return KeyEventResult.handled;
        }
        if (_pendingQuote != null) {
          _clearQuote();
          return KeyEventResult.handled;
        }
      }
      // ↑/↓ on an EMPTY input recall sent-message history, IRC-style
      // (`navigateHistory`, ui-context.js:1021-1027). Only when the field is
      // empty so arrows still move the caret in a real draft, and not during an
      // in-progress edit (the field already holds the original text).
      if (_pendingEdit == null && _controller.text.isEmpty) {
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _navigateHistory(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _navigateHistory(1);
          return KeyEventResult.handled;
        }
      }
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

  /// WIRE-SAFETY (02-F-02-E, non-negotiable): the draft text as it must reach the
  /// relay / services / history — every inline-emoji sentinel char expanded back
  /// to its literal `:shortcode:`. A sentinel PUA code point must NEVER leave the
  /// composer, so EVERY read of the draft headed for the wire routes through here
  /// (`_send`, `_sendAnon`, the translate read). Raw `_controller.text` is fine
  /// only for local UI checks (autocomplete triggers, `hasText`/empty) where a
  /// 1-char sentinel is a harmless token.
  String _draftText() => _controller.expand(_controller.text);

  void _send() {
    final typed = _draftText();
    final controller = ref.read(nostrControllerProvider);

    // Edit mode: route the (next) send to editMessage and exit edit mode
    // (messages.js send path checks `this.pendingEdit`). Empty input cancels.
    final edit = _pendingEdit;
    if (edit != null) {
      final trimmed = typed.trim();
      setState(() => _pendingEdit = null);
      _controller.clear();
      _hideOverlay();
      _focus.requestFocus();
      if (trimmed.isEmpty || trimmed == edit.content.trim()) return;
      controller.editMessage(edit.messageId, trimmed);
      return;
    }

    // Nothing to send unless there's typed text OR a pending quote (the PWA
    // allows sending a bare quote: `if (!content && !this.pendingQuote) return`).
    if (typed.trim().isEmpty && _pendingQuote == null) return;

    final content = _composeOutgoing(typed);

    // Routes through the NostrController: optimistic local echo + relay
    // publish when an identity is live, falling back to local echo otherwise.
    // `?`/@Nymbot interception and `/` commands are handled inside sendCurrent.
    controller.sendCurrent(content);
    // The PWA records the FINAL composed content — quote prepend included —
    // in the ↑/↓ recall history (`commandHistory.push(content)` AFTER the
    // quote prepend, messages.js:2363-2364).
    _pushSentHistory(content);
    _controller.clear();
    _popout = false;
    _syncPopoutPortal();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  /// Records a non-empty sent draft for ↑/↓ recall (`navigateHistory`,
  /// ui-context.js:1021-1027). Skips consecutive duplicates, caps at 50, and
  /// resets the recall cursor to the live (empty) slot.
  void _pushSentHistory(String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty &&
        (_sentHistory.isEmpty || _sentHistory.last != text)) {
      _sentHistory.add(text);
      if (_sentHistory.length > 50) _sentHistory.removeAt(0);
    }
    _historyIndex = _sentHistory.length;
  }

  /// Walks [_sentHistory] by [delta] (−1 = older, +1 = newer) and loads the
  /// recalled draft into the input. At the bottom (`length`) the input is empty
  /// (the live draft), mirroring the PWA's `navigateHistory` (ui-context.js
  /// :1021-1027).
  void _navigateHistory(int delta) {
    if (_sentHistory.isEmpty) return;
    final next = (_historyIndex + delta).clamp(0, _sentHistory.length);
    if (next == _historyIndex) return;
    _historyIndex = next;
    final text = next >= _sentHistory.length ? '' : _sentHistory[next];
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onInputChanged();
  }

  /// Prepends the pending quote to [typed] ONLY at send (messages.js:2354-2361):
  /// first quoted line as `> @author: line`, remaining lines each `> line`, then
  /// a blank line before the user's text. Clears the consumed quote chip.
  String _composeOutgoing(String typed) {
    var content = typed;
    final quote = _pendingQuote;
    if (quote != null) {
      final lines = quote.text.split('\n');
      final quoteRest = lines.length > 1
          ? '\n${lines.skip(1).map((l) => '> $l').join('\n')}'
          : '';
      final quoteLine = '> @${quote.author}: ${lines.first}$quoteRest';
      content = content.isNotEmpty ? '$quoteLine\n\n$content' : quoteLine;
      _pendingQuote = null;
    }
    return content;
  }

  /// SEND long-press → pseudonymous "ANON" send (ui-context.js:1208-1225 →
  /// messages.js `sendMessagePseudonymous`). Publishes the current draft signed
  /// with a FRESH ephemeral keypair instead of the durable identity, so the
  /// message is unlinkable to the user's nym. Only Nostr-login (durable)
  /// identities can do this in the PWA (`if (this.nostrLoginMethod)`); ephemeral
  /// geohash keys are already pseudonymous, so the affordance is gated off for
  /// them (see [_anonEligible]). Quote/edit are handled exactly like a normal
  /// send. Routed through the controller's [NostrController.sendCurrentPseudonymous]
  /// (nostr_controller.dart) — the shared-core ephemeral-key publish.
  void _sendAnon() {
    // Expand inline-emoji sentinels back to `:shortcode:` BEFORE the wire
    // (02-F-02-E wire-safety) — a sentinel PUA char must never reach the relay.
    final typed = _draftText();
    // Edit-in-progress isn't a pseudonymous flow in the PWA (the long-press still
    // calls sendMessagePseudonymous which ignores edit state) — fall back to the
    // normal send so an in-flight edit is never silently dropped.
    if (_pendingEdit != null) {
      _send();
      return;
    }
    if (typed.trim().isEmpty && _pendingQuote == null) return;
    final controller = ref.read(nostrControllerProvider);
    final content = _composeOutgoing(typed);
    // Publish the draft under a FRESH ephemeral keypair (unlinkable to the
    // durable nym), mirroring the normal send's fire-and-forget dispatch.
    controller.sendCurrentPseudonymous(content);
    // Recall history gets the composed content incl. the quote prepend
    // (messages.js:2363-2364) — see [_send].
    _pushSentHistory(content);
    _controller.clear();
    _popout = false;
    _syncPopoutPortal();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  /// Whether the SEND long-press anon affordance applies: a durable Nostr-login
  /// identity (`this.nostrLoginMethod`, ui-context.js:1215). Ephemeral geohash
  /// keys are already anonymous so the PWA doesn't offer it for them.
  ///
  /// The PWA reads `nostrLoginMethod` LIVE on every long-press (ui-context.js
  /// :1215), so the affordance must track login/logout. The controller isn't a
  /// reactive provider, but every login/logout transition rewrites `selfPubkey`
  /// (`goLive`/`reset`) AND updates `_identity` first (init sets `_identity`
  /// before `goLive`; signOut nulls it before `reset`). So we `ref.watch` the
  /// `selfPubkey` signal — forcing a rebuild on the transition — then read the
  /// now-current login method. Called only from `build` (via `_toolbar`).
  bool get _anonEligible {
    ref.watch(appStateProvider.select((s) => s.selfPubkey));
    return ref.read(nostrControllerProvider).identity?.loginMethod != null;
  }

  // --- Attachments: image upload (Blossom) + P2P file share -----------------

  /// `#uploadProgress` state (0..1, null = hidden). Mirrors the PWA's progress
  /// bar shown during `uploadImage` (users.js:971).
  double? _uploadProgress;

  /// Set by the cancel ✕ (`cancelUpload`) so an in-flight upload, once it
  /// resolves, is discarded instead of appended (the underlying
  /// `uploadImage` future isn't cancellable — F11).
  bool _uploadCancelled = false;

  /// 1-based index + total of the current multi-file upload (users.js:1006-1008
  /// labels "Uploading i of N…" when N>1). 0/0 = single-file (no "of N").
  int _uploadIndex = 0;
  int _uploadTotal = 0;

  void _cancelUpload() {
    setState(() {
      _uploadCancelled = true;
      _uploadProgress = null;
      _uploadMime = null;
      _uploadIndex = 0;
      _uploadTotal = 0;
    });
  }

  /// Image/Video button (`selectImage` → fileInput `multiple`, accepts image +
  /// video): pick one OR MANY media, upload each to a Blossom server, then append
  /// ALL resulting URLs (space-joined) to the input — the formatter renders them
  /// as media (users.js:971-1028). For multi-select the progress label reads
  /// "Uploading i of N…".
  Future<void> _pickAndUploadImage() async {
    List<XFile> picked;
    try {
      final picker = ImagePicker();
      // `pickMultipleMedia` returns image OR video files (PWA
      // accept="image/*,video/…" `multiple`).
      picked = await picker.pickMultipleMedia();
    } catch (_) {
      return; // picker unavailable (tests/desktop)
    }
    if (picked.isEmpty) return;
    const maxUpload = 50 * 1024 * 1024; // 50 MB cap (users.js:977)

    if (!mounted) return;
    setState(() {
      _uploadCancelled = false;
      _uploadTotal = picked.length;
    });

    final controller = ref.read(nostrControllerProvider);
    final urls = <String>[];
    for (var i = 0; i < picked.length; i++) {
      if (!mounted || _uploadCancelled) break;
      final file = picked[i];
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        continue;
      }
      if (bytes.length > maxUpload) {
        _onSystemMessage('Files must be under 50MB.');
        continue;
      }
      final contentType = file.mimeType ?? _guessImageMime(file.name);
      if (!mounted) return;
      setState(() {
        _uploadProgress = 0.1;
        _uploadMime = contentType;
        _uploadIndex = i + 1;
      });
      final url = await controller.uploadImage(
        bytes,
        contentType: contentType,
        onProgress: (p) {
          if (mounted && !_uploadCancelled) setState(() => _uploadProgress = p);
        },
      );
      if (!mounted) return;
      if (_uploadCancelled) break;
      if (url == null) {
        _onSystemMessage('Failed to upload media.');
        continue;
      }
      urls.add(url);
    }

    if (!mounted) return;
    final wasCancelled = _uploadCancelled;
    setState(() {
      _uploadProgress = null;
      _uploadMime = null;
      _uploadCancelled = false;
      _uploadIndex = 0;
      _uploadTotal = 0;
    });
    // Drop the results entirely if the user pressed ✕ mid-batch.
    if (wasCancelled || urls.isEmpty) return;
    // Append all URLs space-joined (then a trailing space), like the PWA.
    final existing = _controller.text;
    final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
    _controller.text = '$existing${needsSpace ? ' ' : ''}${urls.join(' ')} ';
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    // Appended media urls can push past the popout threshold — recompute.
    _onInputChanged();
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

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `#sendBtn` is gated on CONNECTION, not input content: the PWA flips
    // `disabled=false` once an identity/relay connects (relays.js:1040/1169/1276)
    // and never re-disables it for an empty field. The empty-input guard lives
    // inside `_send`/`_sendAnon` only (matching `if (!content && !pendingQuote)`).
    final sendEnabled = ref.watch(
          appStateProvider.select((s) => s.connectedRelays > 0),
        ) ||
        ref.read(nostrControllerProvider).isLive;

    // Keep the live NIP-30 custom-emoji snapshot in sync so the open emoji
    // picker / `:` autocomplete refresh when packs arrive over relays.
    _customEmojis = ref.watch(liveCustomEmojiProvider);
    // Feed the same shortcode→url map into the controller so its overridden
    // `buildTextSpan` can resolve a sentinel char to its emoji <img>, and the
    // resolve-on-input pass knows which `:code:` are real (02-F-02-E).
    _controller.codeToUrl = _customEmojis.codeToUrl;

    // Apply mention/quote requests published by the context menu (one-shot).
    ref.listen(pendingComposerActionProvider, (_, action) {
      if (action == null) return;
      _applyComposerAction(action);
      ref.read(pendingComposerActionProvider.notifier).consume();
    });
    // Apply edit requests published by the context menu (one-shot, F2).
    ref.listen(pendingEditProvider, (_, edit) {
      if (edit == null) return;
      _applyEdit(edit);
      ref.read(pendingEditProvider.notifier).consume();
    });
    // Conversation switches — sidebar selections AND columns-deck focus changes
    // (the deck re-points the current view, `_cvFocusColumn`) — run the PWA's
    // composer sequence: save the outgoing conversation's draft, clear any
    // quote-reply chip, cancel a pending edit, restore the incoming draft
    // (columns.js:549-564, channels.js:1216/1267-1268/1373).
    ref.listen(currentViewProvider, (prev, next) {
      if (prev == next) return;
      _onViewSwitched(next);
    });

    // The quote/edit preview chip stacks flush above the input
    // (`.quote-preview` / `.edit-preview`, `bottom:100%` + 8px gap).
    final input = _inputWithChips(context, sendEnabled);
    // `.input-container` is `padding: 12px 16px` (desktop/tablet); the phone
    // breakpoint (≤768) collapses it to a flat `padding: 10px`
    // (styles-themes-responsive.css:221/304). `compact` spans the whole ≤1024
    // off-canvas range, so key the 10px override off the real phone width.
    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final toolbar = _toolbar(context, sendEnabled, phone);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      padding: phone
          ? const EdgeInsets.all(10)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
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

  /// The input column with the quote/edit preview chip stacked directly above
  /// it — the PWA's `.quote-preview` / `.edit-preview` (index.html:720-745):
  /// `position:absolute; bottom:100%` with `margin-bottom:8px` (styles-chat.css
  /// :1412-1427 / 1496-1512), i.e. the chip sits flush above the field with an
  /// 8px gap, sliding in per `quoteSlideIn` (0.2s ease-out, opacity 0→1 /
  /// translateY 8px→0). Structure per the PWA markup: colored bar + content
  /// column (author nym / label over the snippet) + close ✕. The chip slot is
  /// ALWAYS present (an [AnimatedSize] collapsing to 0) so toggling a chip
  /// never re-parents the TextField below it — the keyboard stays up.
  ///
  /// While the tall draft floats (`_popout`), the chip moves INTO the popout
  /// overlay above the grown field: the PWA lifts it by the overhang
  /// (`.input-container.composer-popout .quote-preview/.edit-preview
  /// { bottom: calc(100% + var(--popout-overhang)); z-index: 20 }`,
  /// styles-chat.css:1749-1752) so it stays visible — and its cancel ✕
  /// tappable — over the field that would otherwise paint on top of it.
  Widget _inputWithChips(BuildContext context, bool inputEnabled) {
    final block = _popout ? null : _chipBlock();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomLeft,
          child: block ?? const SizedBox(height: 0, width: double.infinity),
        ),
        _input(context, inputEnabled),
      ],
    );
  }

  /// The quote/edit preview chip with its 8px bottom gap and slide-in, or null
  /// when neither is pending. Rendered in-flow above the field normally, or
  /// inside the popout overlay while the field floats (see [_inputWithChips]).
  Widget? _chipBlock() {
    final chip = _pendingEdit != null
        ? _EditPreviewChip(
            text: _quotePreviewText(_pendingEdit!.content),
            onClose: _cancelEdit,
          )
        : (_pendingQuote != null
            ? _QuotePreviewChip(
                author: _pendingQuote!.author,
                // Snippet from the FULL original content, not the stripped
                // send text (messages.js:1845-1846).
                text: _quotePreviewText(_pendingQuote!.fullText),
                onClose: _clearQuote,
              )
            : null);
    if (chip == null) return null;
    return Padding(
      // `margin-bottom: 8px` between the chip and the field.
      padding: const EdgeInsets.only(bottom: 8),
      // Re-mounts (and so replays the slide-in) when the chip KIND
      // changes — the PWA recreates the element on each
      // setQuoteReply/startEditMessage.
      child: _ChipSlideIn(
        key: ValueKey(_pendingEdit != null ? 'edit' : 'quote'),
        // Keyed so the autocomplete dropdown can clear the chip
        // height (`--ac-offset`, 04-F2). Measures the chip alone
        // (the +8 gap is added in the offset, matching the PWA's
        // `previewH + 8`).
        child: KeyedSubtree(key: _chipKey, child: chip),
      ),
    );
  }

  /// `.upload-progress` — a panel (bg glass-bg, glass border, top corners
  /// radius-sm, 12px padding, 8px bottom gap) floating above the input with a
  /// label + cancel ✕ + a thin gradient progress bar (users.js:988-1008).
  /// Single: "Uploading image..." / "Uploading video..."; multi: "Uploading
  /// i of N...". The bar fills primary→secondary.
  Widget _uploadBar(BuildContext context) {
    final c = context.nym;
    final isVideo = (_uploadMime ?? '').startsWith('video/');
    final kind = isVideo ? 'video' : 'image';
    final label = _uploadTotal > 1
        ? 'Uploading $_uploadIndex of $_uploadTotal...'
        : 'Uploading $kind...';
    final fraction = (_uploadProgress ?? 0.1).clamp(0.0, 1.0);
    // In solid-ui the panel is repainted with --glass-bg (#14141e dark /
    // opaque #ffffff light — styles-themes-responsive.css:1593-1627, sourced
    // AFTER the light white@0.92 rule so it wins in both themes).
    final solidUi = ref.watch(settingsProvider.select((s) => s.solidUi));
    return Container(
      // `.upload-progress`: bg literal rgba(20,20,35,0.9) dark
      // (styles-components.css:1142-1153); `body.light-mode .upload-progress`
      // → white@0.92 (styles-themes-responsive.css:1179). border 1px glass
      // (light: black@0.08 = glassBorder), radius-sm top corners, padding 12,
      // margin-bottom 8.
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: solidUi
            ? c.glassBg
            : (c.isLight
                ? Colors.white.withValues(alpha: 0.92)
                : const Color(0xE6141423)),
        border: Border.all(color: c.glassBorder),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(NymRadius.sm)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(color: c.textDim, fontSize: 12)),
              ),
              // `.upload-progress-close` (22×22 ✕, radius-sm), cancels the
              // in-flight upload.
              Material(
                type: MaterialType.transparency,
                borderRadius: NymRadius.rsm,
                child: InkWell(
                  onTap: _cancelUpload,
                  borderRadius: NymRadius.rsm,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Center(
                      child: NymSvgIcon(NymIcons.close, size: 14, color: c.textDim),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // `.progress-bar`: height 6, bg rgba(255,255,255,0.05), radius 10;
          // `.progress-fill`: linear-gradient(90deg, primary, secondary).
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 6,
              color: Colors.white.withValues(alpha: 0.05),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: LinearGradient(
                        colors: [c.primary, c.secondary],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Collapsed `.input-wrapper` height reserved in-flow while the popout floats
  /// (`--composer-row-base`, ui-context.js:1741 ≈ a single text row + padding).
  /// 15px line × 1.4 + 10+10 vertical padding ≈ 41; mobile 16px → ~42.
  static const double _composerRowBase = 42;

  /// `.message-input` wrapped with the autocomplete/command-palette overlay
  /// anchored above it (`bottom: 100%` like the PWA's inline dropdowns). When the
  /// draft is tall enough (`_popout`), the actual field floats in a separate
  /// portal that grows UP over the messages (`.composer-popout .message-input`
  /// `position:absolute;bottom:0`, styles-chat.css:1737-1748), while the in-flow
  /// slot shrinks to `--composer-row-base` so the toolbar stays put (B4).
  Widget _input(BuildContext context, bool inputEnabled) {
    final focus = Focus(
      onKeyEvent: _onKey,
      child: _textField(context, inputEnabled),
    );
    // Three nested OverlayPortals share the composer leaders. The popout field
    // is the OUTERMOST portal (z-index:12); the translate dropdown and the
    // autocomplete/palette are nested INSIDE it (as `child`, NOT inside its
    // overlay child) so they paint ABOVE the floating field — nested children
    // paint after their ancestors, matching the PWA stack order
    // (styles-chat.css:1746/1749).
    //
    // The translate dropdown portal MUST live here in the main tree rather than
    // inside the field's Stack: when the draft pops out, that Stack is
    // reparented into `_popoutPortal`'s OVERLAY child, and a nested OverlayPortal
    // whose widget sits inside another portal's overlay child never builds its
    // own overlay child (its `overlayChildBuilder` is skipped even though
    // `show()` flips `isShowing` true) — so the translate button went dead in
    // popout. Hosting the portal in the always-mounted main tree and pointing
    // its `_translateDropdown` follower at the `_translateAnchor` leader (the
    // 26×26 button, which keeps its [CompositedTransformTarget] inside the
    // field) lets the dropdown open in BOTH the flat and popout layouts.
    return CompositedTransformTarget(
      key: _inputKey,
      link: _acAnchor,
      child: OverlayPortal(
        controller: _popoutPortal,
        overlayChildBuilder: (ctx) => _popoutOverlay(ctx, focus),
        child: OverlayPortal(
          controller: _translatePortal,
          overlayChildBuilder: _translateDropdown,
          child: OverlayPortal(
            controller: _acPortal,
            overlayChildBuilder: _overlayChild,
            // In-flow we reserve only the base row height while the field
            // floats; flat (non-popout) the field stays in place. The
            // [_fieldKey] GlobalKey on the TextField reparents the SAME element
            // between the in-flow slot and the popout overlay, so the flip never
            // tears down the EditableText (which would force-close the keyboard).
            child: _popout
                ? const SizedBox(
                    height: _composerRowBase, width: double.infinity)
                : focus,
          ),
        ),
      ),
    );
  }

  /// The floating `.composer-popout .message-input` box: anchored to the in-flow
  /// slot's bottom-left, it grows upward and overlays the messages. Same width as
  /// the input (`_anchorWidth`), capped at `min(40vh,360)`. A pending quote/edit
  /// chip rides ABOVE the grown field here — the PWA repositions it by the
  /// popout overhang at z-index 20 over the field's z-index 12
  /// (styles-chat.css:1749-1752) so the chip (and its cancel ✕) is never
  /// occluded by a tall draft.
  Widget _popoutOverlay(BuildContext context, Widget field) {
    if (!_popout) return const SizedBox.shrink();
    final chipBlock = _chipBlock();
    return CompositedTransformFollower(
      link: _acAnchor,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.bottomLeft,
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: _anchorWidth(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (chipBlock != null) chipBlock,
                // [_popoutFieldKey] wraps ONLY the field: `--ac-offset`'s
                // overhang term measures the field's growth past the base row
                // (the chip carries its own `+ chipH + 8` term).
                SizedBox(key: _popoutFieldKey, child: field),
              ],
            ),
          ),
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
        : _botPaletteActive
        ? BotCommandPalette(
            rows: _botRows,
            selectedIndex: _selectedIndex,
            onSelect: _completeBotCommand,
          )
        : AutocompleteDropdown(
            view: _acView!,
            selectedIndex: _selectedIndex,
            custom: _customEmojis,
            badgesFor: _mentionBadges,
            cosmeticsFor: (pk) => resolveCosmetics(ref, pk),
            onSelectMention: (m) => _replaceTriggerToken(m.insertText),
            onSelectChannel: (ch) => _replaceTriggerToken(ch.insertText),
            onSelectEmoji: _onEmojiAutocompletePicked,
            onSelectKaomoji: (k) => _replaceTriggerToken(kaomojiInsertText(k)),
          );
    // The dropdown is anchored to the in-flow slot's TOP, but the PWA pushes it
    // up by `--ac-offset = overhang + (previewH ? previewH+8 : 0)`
    // (ui-context.js:1759): the popout OVERHANG (the floating field's height
    // beyond the in-flow base) AND the quote/edit chip height (+8). Without this
    // the dropdown paints under the floating field / over the chip (04-F2).
    final overhang = _popout
        ? math.max(0.0, _boxHeight(_popoutFieldKey) - _composerRowBase)
        : 0.0;
    final chipH = _boxHeight(_chipKey);
    final acOffset = overhang + (chipH > 0 ? chipH + 8 : 0);
    return CompositedTransformFollower(
      link: _acAnchor,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      // Negative Y lifts the follower above the anchor (matches the translate
      // dropdown's `Offset(0,-4)` convention at :1444).
      offset: Offset(0, -acOffset),
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

  /// Width of the message-input box (the `.input-wrapper`, = `.autocomplete-
  /// dropdown` left:0/right:0 span), measured via the [_inputKey] leader rather
  /// than the overlay-theatre `context` (which is full-screen) — 04-F1.
  double _anchorWidth(BuildContext context) {
    final box = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size.width ?? MediaQuery.sizeOf(context).width;
  }

  /// Laid-out height of the box behind [key], or 0 when not yet measured.
  double _boxHeight(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return (box != null && box.hasSize) ? box.size.height : 0;
  }

  /// Resolves the verified/friend badge flags for a mention row (F3). Verified
  /// = verified developer OR Nymbot (Foundations `isVerifiedDeveloper/Bot`);
  /// friend = in the friend set (`appState.isFriend`). The verified badge's
  /// tooltip distinguishes the two: `verifiedDeveloper.title` ("Nymchat
  /// Developer") vs "Nymchat Bot" (autocomplete.js:430).
  MentionBadges _mentionBadges(String pubkey) {
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = controller.isVerifiedBot(pubkey);
    final friend = ref.read(appStateProvider).isFriend(pubkey);
    return (
      verified: isDev || isBot,
      friend: friend,
      verifiedTitle:
          isDev ? 'Nymchat Developer' : (isBot ? 'Nymchat Bot' : null),
    );
  }

  /// `.message-input` (+ `.message-input-row` with the translate button). When
  /// the draft is tall enough the field takes the `.composer-popout` treatment:
  /// bg-tertiary fill, primary@0.3 border, shadow-lg (F8). The 26×26 translate
  /// button + 230px language dropdown overlay the bottom-right (F7).
  Widget _textField(BuildContext context, bool inputEnabled) {
    final c = context.nym;
    final hasText = _controller.text.trim().isNotEmpty;
    final focused = _focus.hasFocus;
    // `.message-input { font-size: var(--user-text-size) }` — the input font
    // tracks the Settings text-size slider (styles-chat.css:1670); the ≤768
    // phone breakpoint pins it to 16px (`font-size: 16px !important`,
    // styles-themes-responsive.css:270-275). Watch so a slider change
    // re-renders the field live.
    ref.watch(settingsProvider.select((s) => s.textSize));
    final fontSize = _inputFontSize();
    // Flat-field growth cap: `.message-input { max-height: 160px }` with its
    // 10px vertical paddings → ~140px of text, at the PWA's effective
    // `fontSize * 1.4` line height (`autoResizeTextarea`'s fallback). The
    // popout keeps its own `min(40vh, 360)` cap below.
    final flatMaxLines = math.max(1, 140 ~/ (fontSize * 1.4));
    // `.composer-popout .message-input`: elevated rounded box vs the flat field.
    // `.message-input` flat fill is white@0.05 → white@0.07 on focus (dark); in
    // light mode `body.light-mode div.message-input` flips to black@0.04 →
    // black@0.02 on focus (styles-themes-responsive.css:62-67).
    final flatFill = c.isLight
        ? Colors.black.withValues(alpha: focused ? 0.02 : 0.04)
        : Colors.white.withValues(alpha: focused ? 0.07 : 0.05);
    final fill = _popout ? c.bgTertiary : flatFill;
    // `.message-input` rounds ONLY the bottom corners when flat (chips/dropdowns
    // sit `bottom:100%` flush above it — styles-chat.css:1666); the popout box
    // uses full radius-md (styles-chat.css:1737).
    final radius = _popout
        ? NymRadius.rmd
        : const BorderRadius.vertical(bottom: Radius.circular(NymRadius.md));
    final border = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: _popout ? c.primaryA(0.30) : c.glassBorder),
    );
    // INLINE-EMOJI-WHILE-TYPING (02-F-02-E): the PWA's input is a `contenteditable`
    // div, so a just-completed `:shortcode:` is swapped to its custom-emoji <img>
    // live in the field (`_maybeRenderTypedEmoji`, ui-context.js:1034). We do the
    // same here with the SENTINEL technique: [EmojiSentinelController] keeps each
    // rendered emoji as exactly ONE Private-Use-Area char in the controller text
    // (one per distinct shortcode) and overrides `buildTextSpan` to paint that
    // char as the emoji image via a [WidgetSpan]. One char == one caret slot, so
    // selection/backspace stay correct (backspace removes the whole emoji). The
    // resolve-on-input pass ([EmojiSentinelController.resolveInput], run from
    // `_onInputChanged`) replaces a completed known `:code:` with its sentinel;
    // unknown shortcodes stay literal text. WIRE-SAFETY: the sentinel never leaves
    // the composer — every draft read headed for the wire goes through
    // [_draftText] (= `expand`), which maps each sentinel back to its `:code:`.
    final field = TextField(
      // GlobalKey: the ONE field element survives the `_popout` flip (in-flow
      // slot ↔ popout overlay slot, and the DecoratedBox ↔ Container wrapper
      // swap below) by reparenting instead of remounting — remounting would
      // drop the IME connection and force-close the on-screen keyboard the
      // moment the draft crosses the popout threshold.
      key: _fieldKey,
      controller: _controller,
      focusNode: _focus,
      // `#messageInput` starts `disabled` and the PWA flips it to enabled ONLY
      // once relays/identity connect (relays.js:1039/1168/1275 set
      // `messageInput.disabled=false` in the exact same spots as `sendBtn`). Gate
      // on the SAME [inputEnabled] (= the SEND `sendEnabled`) so the field is
      // typable iff SEND is — never inert while SEND is live, nor vice-versa.
      enabled: inputEnabled,
      maxLines: _popout ? 12 : flatMaxLines,
      minLines: 1,
      textInputAction: TextInputAction.newline,
      onChanged: (_) {
        _onInputChanged();
        // Emit a typing indicator on real keystrokes (PWA sends kind-69420
        // 'start' on input). `sendTypingStart` self-throttles to ~1/s, gates on
        // the typing-scope setting, and no-ops in channel views, so calling it
        // every keystroke is safe. (`messages.js` typing emit on input.)
        ref.read(nostrControllerProvider).sendTypingStart();
      },
      style: TextStyle(
        // `.message-input` text is forced pure white (dark) / pure black (light)
        // — `color:#ffffff !important` / `body.light-mode … color:#000000`
        // (styles-themes-responsive.css:578-593), NOT the accent `--text`.
        color: c.isLight ? Colors.black : Colors.white,
        fontSize: fontSize,
      ),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        isDense: true,
        // PWA `data-placeholder` teaches the `/` and `?` affordances (F9).
        hintText: 'Message, / for commands, ? for Nymbot...',
        hintStyle: TextStyle(
            // `div.message-input:empty::before` → white@0.4 (dark) /
            // black@0.4 (`body.light-mode …`, styles-themes-responsive.css:58).
            color: (c.isLight ? Colors.black : Colors.white)
                .withValues(alpha: 0.4),
            fontSize: fontSize),
        filled: true,
        fillColor: fill,
        // The translate button only exists when there's text (A9), so only then
        // does the input reserve right padding for it (`paddingRight 38px`).
        contentPadding: EdgeInsets.fromLTRB(16, 10, hasText ? 38 : 16, 10),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );

    Widget stack = Stack(
      children: [
        field,
        // `#translateInputBtn` starts `.nm-hidden` and `display:flex` ONLY when
        // the field has text (translate.js:588-600). Render it solely then — no
        // faded ghost when empty.
        if (hasText)
          Positioned(
            right: 8,
            bottom: 10,
            child: _translateButton(context),
          ),
      ],
    );
    // `div.message-input.input-disabled { opacity: 0.55; cursor: not-allowed }`
    // (styles-chat.css:1692-1695), toggled by the contenteditable `disabled`
    // setter (ui-context.js:1953) — pre-connect the whole field dims and the
    // pointer reads not-allowed.
    if (!inputEnabled) {
      stack = MouseRegion(
        cursor: SystemMouseCursors.forbidden,
        child: Opacity(opacity: 0.55, child: stack),
      );
    }

    if (!_popout) {
      // `.message-input:focus`: a 3px primary@0.06 focus ring hugging the
      // field's rounded-bottom shape — painted OUTSIDE the field only (CSS
      // box-shadow semantics; a spread BoxShadow also fills behind the
      // translucent field and highlights the whole input, which the PWA never
      // does). ALWAYS rendered (toggling only `show`) — conditionally
      // returning `stack` vs a wrapped `stack` re-parents the TextField
      // subtree the instant it focuses, which REMOUNTS the EditableText and
      // drops the just-requested keyboard. That was the "first tap only
      // highlights, tap again to actually open the keyboard (then the paste
      // toolbar shows)" bug. A stable tree keeps the first tap focusing AND
      // raising the keyboard.
      return CssFocusRing(
        show: focused,
        color: c.primaryA(0.06),
        radius: radius,
        child: stack,
      );
    }
    // The popout box is elevated (shadow-lg) and height-capped (min 40vh,360).
    return Container(
      constraints: BoxConstraints(
        maxHeight: math.min(MediaQuery.sizeOf(context).height * 0.4, 360),
      ),
      decoration: const BoxDecoration(
        borderRadius: NymRadius.rmd,
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
        boxShadow: [
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: stack,
    );
  }

  /// `#translateInputBtn`. Disabled while empty; pulses while translating. Wears
  /// the [_translateAnchor] leader so the 230px language dropdown (hosted by the
  /// main-tree `_translatePortal` in [_input], NOT nested in the field's Stack —
  /// see the note there) anchors above it in both the flat and popout layouts.
  Widget _translateButton(BuildContext context) {
    final hasText = _controller.text.trim().isNotEmpty;
    return CompositedTransformTarget(
      link: _translateAnchor,
      child: _TranslateInputButton(
        enabled: hasText && !_translating,
        translating: _translating,
        onTap: _toggleTranslateDropdown,
      ),
    );
  }

  Future<void> _toggleTranslateDropdown() async {
    if (_translatePortal.isShowing) {
      _translatePortal.hide();
      return;
    }
    if (_controller.text.trim().isEmpty || _translating) return;
    _emojiPortal.hide();
    _gifPortal.hide();
    // The PWA lazily loads `nym_translate_favorites` from localStorage on
    // first dropdown render (`_getTranslateFavorites`, translate.js:93-99) —
    // resolve prefs and RE-read the favorites on every open so a fresh
    // session (no emoji/GIF picker opened yet) shows the saved stars, and
    // favorites toggled elsewhere (bot chat / relay settings sync) aren't
    // stale here.
    final prefs = await _ensurePrefs();
    if (!mounted) return;
    setState(() {
      _translateFavorites = _loadTranslateFavorites(prefs);
      _translateQuery = '';
      // Snapshot the favorites-pinned order at open (re-pins only on reopen).
      _translateLangOrder =
          sortedTranslateLanguagesWithFavorites(_translateFavorites);
    });
    _translateSearchController.clear();
    _translatePortal.show();
  }

  /// `.translate-input-dropdown`: a 230px search + language list anchored above
  /// the translate button. Choosing a language translates the draft in place.
  Widget _translateDropdown(BuildContext context) {
    final c = context.nym;
    final q = _translateQuery.trim().toLowerCase();
    // Star FILL reads the live favorites set; row ORDER uses the open-time
    // snapshot so toggling a star doesn't reshuffle mid-open (PWA parity).
    final favSet = _translateFavorites.toSet();
    final order = _translateLangOrder.isEmpty
        ? sortedTranslateLanguagesWithFavorites(_translateFavorites)
        : _translateLangOrder;
    final langs = order
        .where((e) => q.isEmpty || e.value.toLowerCase().contains(q))
        .toList();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _translatePortal.hide,
          ),
        ),
        CompositedTransformFollower(
          link: _translateAnchor,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -4),
          showWhenUnlinked: false,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                width: 230,
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  // `.translate-input-dropdown` bg `--bg-secondary` / border
                  // `--glass-border` / shadow rgba(0,0,0,0.4); `body.light-mode
                  // .translate-input-dropdown` flips to white@0.98 / black@0.12 /
                  // shadow rgba(0,0,0,0.12) (styles-themes-responsive.css:1278-
                  // 1282) — M4.
                  color:
                      c.isLight ? Colors.white.withValues(alpha: 0.98) : c.bgSecondary,
                  border: Border.all(
                      color: c.isLight
                          ? Colors.black.withValues(alpha: 0.12)
                          : c.glassBorder),
                  borderRadius: NymRadius.rmd,
                  boxShadow: [
                    BoxShadow(
                        color: c.isLight
                            ? Colors.black.withValues(alpha: 0.12)
                            : const Color(0x66000000),
                        blurRadius: 24,
                        offset: const Offset(0, 8)),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // `.translate-dropdown-search`: 8px padding + a bottom
                    // hairline divider under the search region.
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border(
                            bottom: BorderSide(color: c.glassBorder)),
                      ),
                      // NOT autofocused: the PWA never focuses the dropdown
                      // search on open (only the Select-Your-Language MODAL
                      // focuses its search, translate.js:190) — grabbing focus
                      // here would yank the IME away from the message input.
                      child: TextField(
                        controller: _translateSearchController,
                        onChanged: (v) => setState(() => _translateQuery = v),
                        style: TextStyle(color: c.text, fontSize: 13),
                        cursorColor: c.isLight ? Colors.black : Colors.white,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search languages...',
                          hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                          filled: true,
                          // `.translate-dropdown-search input` is white@0.05
                          // (dark); `body.light-mode input` forces black@0.04
                          // !important (styles-themes-responsive.css:561) — M3.
                          fillColor: c.isLight
                              ? Colors.black.withValues(alpha: 0.04)
                              : Colors.white.withValues(alpha: 0.05),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          border: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.glassBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.glassBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.primary),
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      // `.translate-dropdown-list`: padding 4px 0.
                      child: langs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text('No languages found',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13)),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              itemCount: langs.length,
                              itemBuilder: (_, i) {
                                final e = langs[i];
                                return _TranslateLangRow(
                                  name: e.value,
                                  favorited: favSet.contains(e.key),
                                  onTap: () => _translateDraft(e.key),
                                  onToggleFavorite: () =>
                                      _toggleTranslateFavorite(e.key),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Translates the typed draft into [targetLang] and replaces the input text
  /// (the PWA's in-input translate flow). The quote/edit chips are preserved.
  Future<void> _translateDraft(String targetLang) async {
    _translatePortal.hide();
    // Expand inline-emoji sentinels to `:shortcode:` before the (external)
    // translate service ever sees the draft (02-F-02-E wire-safety). The
    // returned text is written back raw; `_onInputChanged` re-resolves any
    // `:code:` it contains into sentinels/images.
    final text = _draftText().trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);
    try {
      final res = await TranslateService().translate(text, targetLang);
      if (!mounted) return;
      final out = res.translatedText;
      // Don't clobber the input if the upstream returned nothing or echoed
      // the original (detected language already matches the target) —
      // `translateInputText` (translate.js:479-483).
      if (out.trim().isEmpty || out.trim() == text) {
        _onSystemMessage(
            'Nothing to translate (text may already be in the target language).');
        return;
      }
      _controller.text = out;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    } catch (e) {
      // `'Translation failed: ' + (err.message || 'Unknown error')`
      // (translate.js:488) — [TranslateException.message] already carries the
      // "Translation failed: …" prefix.
      if (mounted) {
        _onSystemMessage(e is TranslateException
            ? e.message
            : 'Translation failed: Unknown error');
      }
    } finally {
      if (mounted) {
        setState(() => _translating = false);
        _onInputChanged();
      }
    }
  }

  /// `.input-buttons`: image / file / emoji / GIF icon buttons + SEND.
  Widget _toolbar(BuildContext context, bool sendEnabled, bool phone) {
    final buttons = <Widget>[
      _IconBtn(
        svg: NymIcons.composerImage,
        tooltip: 'Upload Image/Video',
        expand: widget.compact,
        // Inert until relays connect (same `sendEnabled` as SEND), then the
        // existing in-upload guard takes over.
        enabled: sendEnabled,
        onTap: _uploadProgress != null ? null : _pickAndUploadImage,
      ),
      _IconBtn(
        svg: NymIcons.composerFile,
        tooltip: 'Share File (P2P)',
        expand: widget.compact,
        enabled: sendEnabled,
        onTap: _pickAndShareFile,
      ),
      _emojiButton(context, sendEnabled),
      _gifButton(context, sendEnabled),
      // The PWA's `.input-buttons` (index.html:758-790) has EXACTLY 5 children:
      // Image, File, Emoji, GIF, SEND — there is NO Nymbot toolbar button (bot
      // access is via `?`/@Nymbot in the input, routed inside `sendCurrent`).
      _SendButton(
        enabled: sendEnabled,
        onTap: _send,
        // Long-press → ANON pseudonymous send, only for durable Nostr-login
        // identities (ephemeral geohash keys are already anonymous).
        onAnon: _anonEligible ? _sendAnon : null,
        expand: widget.compact,
        // Phone (≤768) shrinks SEND to `padding:10px` / `font-size:11px`
        // (styles-themes-responsive.css:341).
        phone: phone,
      ),
    ];

    if (widget.compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            // SEND gets flex:2, others flex:1.
            Expanded(flex: i == buttons.length - 1 ? 2 : 1, child: buttons[i]),
            // Stacked `.input-buttons` is `gap:10px` (≤1024 + ≤768 overrides,
            // styles-themes-responsive.css:325/487), not the desktop 5px.
            if (i != buttons.length - 1) const SizedBox(width: 10),
          ],
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i != buttons.length - 1) const SizedBox(width: 5),
        ],
      ],
    );
  }

  /// Emoji toolbar button + its inline popover anchored above the button.
  Widget _emojiButton(BuildContext context, bool enabled) {
    return CompositedTransformTarget(
      link: _emojiAnchor,
      child: OverlayPortal(
        controller: _emojiPortal,
        // The picker reads `liveCustomEmojiProvider` directly, so it surfaces
        // relay-sourced packs live — no override needed.
        overlayChildBuilder: (context) => _popover(
          link: _emojiAnchor,
          onDismiss: _hideEmojiPicker,
          child: EmojiPicker(
            recents: _recents,
            onSelect: _onEmojiSelected,
            onClose: _hideEmojiPicker,
          ),
        ),
        child: _IconBtn(
          svg: NymIcons.composerEmoji,
          tooltip: 'Emoji',
          expand: widget.compact,
          enabled: enabled,
          onTap: _toggleEmojiPicker,
        ),
      ),
    );
  }

  /// GIF toolbar button + its inline popover anchored above the button.
  Widget _gifButton(BuildContext context, bool enabled) {
    return CompositedTransformTarget(
      link: _gifAnchor,
      child: OverlayPortal(
        controller: _gifPortal,
        overlayChildBuilder: (context) => _popover(
          link: _gifAnchor,
          onDismiss: _hideGifPicker,
          // `.gif-picker` ≤768: `width: 90%; max-width: 350px`
          // (styles-themes-responsive.css:89-97, ui-context.js:2017-2031).
          phoneWidthFactor: 0.9,
          child: GifPicker(
            favoritesStore: FavoriteGifsStore(_prefs!),
            onSelect: _onGifSelected,
            onClose: _hideGifPicker,
          ),
        ),
        child: _IconBtn(
          label: 'GIF',
          tooltip: 'GIF',
          expand: widget.compact,
          enabled: enabled,
          onTap: _toggleGifPicker,
        ),
      ),
    );
  }

  /// Positions a picker above its anchor button (bottom-anchored, like the
  /// PWA's `bottom: 100%` inline popup) with a barrier to dismiss on tap-out.
  ///
  /// [phoneWidthFactor] pins the picker to that fraction of the viewport width
  /// on phones — the GIF picker's ≤768 rule is `width: 90%; max-width: 350px`
  /// (styles-themes-responsive.css:89-97) where the emoji picker only caps
  /// (`max-width: 90%`, :407-419) on top of its base `width: 350px`
  /// (styles-components.css:1214). The no-factor fallback cap below matches
  /// that 350 (the picker itself already self-caps at `min(350, 90vw)`).
  Widget _popover({
    required LayerLink link,
    required VoidCallback onDismiss,
    required Widget child,
    double? phoneWidthFactor,
  }) {
    final media = MediaQuery.of(context);
    // `.emoji-picker`/`.gif-picker` @media (max-width:768): `position: fixed;
    // left: 50%; transform: translateX(-50%); bottom: 60px` — centered above
    // the input bar on phones (vs anchored above the button on desktop, base
    // `bottom: 100%`).
    final isPhone = media.size.width <= NymDimens.mobileBreakpoint;
    final picker = Material(type: MaterialType.transparency, child: child);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        if (isPhone)
          Positioned(
            left: 0,
            right: 0,
            // 60px above the bar, lifted above the keyboard when it's open.
            bottom: 60 + media.viewInsets.bottom,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: phoneWidthFactor != null
                  // `width: 90%` of the viewport; the picker's own max-width
                  // (350 for the GIF picker) still caps it, so this renders
                  // exactly `min(90vw, 350)` like the PWA.
                  ? ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: media.size.width * phoneWidthFactor),
                      child: picker,
                    )
                  : ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: media.size.width - 16 < 350
                              ? media.size.width - 16
                              : 350),
                      child: picker,
                    ),
            ),
          )
        else
          CompositedTransformFollower(
            link: link,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: Align(
              alignment: Alignment.bottomRight,
              child: picker,
            ),
          ),
      ],
    );
  }
}

/// `.icon-btn.input-btn`: height 42, 18×18 icon stroke text→primary, radius sm.
class _IconBtn extends StatefulWidget {
  const _IconBtn({
    this.svg,
    this.label,
    required this.tooltip,
    this.expand = false,
    this.enabled = true,
    this.onTap,
  }) : assert(svg != null || label != null, 'provide an svg or a label');
  /// The exact-PWA glyph markup (image/file/emoji), or null for a [label] button.
  final String? svg;

  /// A text glyph instead of an SVG — the PWA's GIF button is the literal "GIF"
  /// text (`<text>GIF</text>`), which flutter_svg can't render, so it's drawn as
  /// styled text here.
  final String? label;
  final String tooltip;
  final bool expand;

  /// When false the button is inert: dimmed (opacity 0.35, like the disabled
  /// SEND/input) and unresponsive. The composer gates the Image/File/Emoji/GIF
  /// buttons on the relay-connection flag so the toolbar starts inert until
  /// connect, matching the PWA disabling the input row pre-connect (relays.js).
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.enabled;
    // Hover highlight only while enabled (a disabled button never lifts to
    // primary). `.icon-btn:disabled` is opacity 0.35 (mirrors the SEND/input).
    final hovered = enabled && _hover;
    // `.icon-btn.input-btn` inherits the base `.icon-btn` chrome
    // (styles-shell.css:912-935 + light `styles-themes-responsive.css:595-605`),
    // overriding only height/padding/radius (styles-chat.css:1946-1953) — so it
    // carries the SAME fill/border/hover the header pills do (B1/B2). Mirrors
    // `_iconBtnStyle` (chat_pane.dart:1172):
    //  - Dark base : fill white@0.05, border `--glass-border`.
    //  - Dark hover: fill primary@0.12, border primary@0.3.
    //  - Light base: fill black@0.03, border black@0.1.
    //  - Light hover: fill black@0.06, border `--primary`.
    // Glyph colors split by markup:
    //  - SVG strokes: the explicit `.icon-btn.input-btn svg { stroke:
    //    var(--text) }` resolves directly, so the light-mode `color:
    //    var(--primary)` on `.icon-btn` does NOT recolor them — `--text` at
    //    rest in BOTH themes, `--primary` only on hover
    //    (styles-chat.css:1955-1961).
    //  - The GIF `<text fill="currentColor">` follows `color:` — `--text`/
    //    hover-primary in dark, always `--primary` in light
    //    (styles-themes-responsive.css:595-605).
    final Color fill;
    final Color borderColor;
    final Color labelColor;
    if (c.isLight) {
      fill = hovered
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.03);
      borderColor = hovered ? c.primary : Colors.black.withValues(alpha: 0.1);
      labelColor = c.primary;
    } else {
      fill = hovered ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05);
      borderColor = hovered ? c.primaryA(0.30) : c.glassBorder;
      labelColor = hovered ? c.primary : c.text;
    }
    final glyphColor = hovered ? c.primary : c.text;
    // `.icon-btn.input-btn`: 42 tall, 0 12 padding, radius sm. Hover adds the
    // `0 0 15px primary@0.1` glow (`.icon-btn:hover box-shadow`).
    final btn = Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => setState(() => _hover = true) : null,
        onExit: enabled ? (_) => setState(() => _hover = false) : null,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: borderColor),
            boxShadow: hovered
                ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: NymRadius.rsm,
            child: InkWell(
              onTap: enabled ? (widget.onTap ?? () {}) : null,
              borderRadius: NymRadius.rsm,
              child: Container(
                height: 42,
                constraints: const BoxConstraints(minWidth: 42),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                child: widget.label != null
                    ? Text(
                        widget.label!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: labelColor,
                        ),
                      )
                    : NymSvgIcon(
                        widget.svg!,
                        size: 18,
                        color: glyphColor,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    return enabled ? btn : Opacity(opacity: 0.35, child: btn);
  }
}

/// `.send-btn`: primary@10 bg, primary@30 border, radius sm, "SEND" 12px
/// uppercase letter-spacing 1.5 weight 600. Disabled opacity 0.35. On hover
/// the bg lifts to primary@18 with a primary@10 glow (F10).
///
/// When [onAnon] is non-null a 2s press-and-hold fires the pseudonymous "ANON"
/// send (ui-context.js:1202-1264): a 700ms pre-glow (primary@0.2) telegraphs the
/// press, then at 2s the label swaps to "ANON" with a primary@0.4 glow + haptic,
/// [onAnon] runs, and after 1s it reverts to "SEND". The trailing click is
/// suppressed so the hold doesn't also fire a normal send.
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.enabled,
    required this.onTap,
    this.onAnon,
    this.expand = false,
    this.phone = false,
  });
  final bool enabled;
  final VoidCallback onTap;

  /// Long-press (2s) pseudonymous send. Null = no anon affordance (the hold then
  /// does nothing special; a tap still sends normally).
  final VoidCallback? onAnon;
  final bool expand;

  /// Phone (≤768) shrinks the button to `padding:10px` / `font-size:11px`.
  final bool phone;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hover = false;

  // Long-press state (ui-context.js sendLongPressTimer/Fired/SuppressClickUntil).
  Timer? _holdTimer;
  Timer? _preGlowTimer;
  Timer? _revertTimer;
  bool _anonFired = false;
  bool _preGlow = false;
  DateTime _suppressClickUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _holdTimer?.cancel();
    _preGlowTimer?.cancel();
    _revertTimer?.cancel();
    super.dispose();
  }

  void _startHold() {
    if (widget.onAnon == null || !widget.enabled) return;
    if (_holdTimer != null) return;
    _anonFired = false;
    // 700ms pre-glow telegraph (primary@0.2).
    _preGlowTimer = Timer(const Duration(milliseconds: 700), () {
      if (_holdTimer != null && mounted) setState(() => _preGlow = true);
    });
    // 2s → fire ANON.
    _holdTimer = Timer(const Duration(seconds: 2), () {
      _holdTimer = null;
      _preGlowTimer?.cancel();
      if (!mounted) return;
      _anonFired = true;
      _suppressClickUntil =
          DateTime.now().add(const Duration(milliseconds: 800));
      // `nymHapticTap` = the same 30ms vibrate every long-press site uses
      // (ui-context.js:1217, inline-bindings.js:106-115) — a solid motor
      // pulse, so mediumImpact rather than the faint lightImpact.
      HapticFeedback.mediumImpact();
      setState(() => _preGlow = true);
      widget.onAnon!.call();
      // Revert label + glow after 1s.
      _revertTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() {
          _anonFired = false;
          _preGlow = false;
        });
      });
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _preGlowTimer?.cancel();
    if (!_anonFired && mounted && _preGlow) setState(() => _preGlow = false);
  }

  /// `mouseleave` → cancel (ui-context.js:1261): dragging a pressed MOUSE
  /// pointer off the button abandons the 2s hold. Mouse only — the PWA binds
  /// no `touchmove` cancel, so a touch that wanders keeps the timer running.
  /// Tracked from the captured pointer stream (a MouseRegion exit is not
  /// guaranteed mid-drag), against the button's own bounds.
  void _maybeCancelOnExit(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse || _holdTimer == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if (!(Offset.zero & box.size).contains(box.globalToLocal(e.position))) {
      _cancelHold();
    }
  }

  void _handleTap() {
    // Suppress the click that follows a fired long-press (ui-context.js:1250).
    if (_anonFired || DateTime.now().isBefore(_suppressClickUntil)) return;
    if (widget.enabled) widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hovering = _hover && widget.enabled;
    // Glow: 700ms pre-glow → primary@0.2; fired → primary@0.4; hover → @0.1.
    final List<BoxShadow>? glow = _preGlow
        ? [
            BoxShadow(
                color: c.primaryA(_anonFired ? 0.4 : 0.2),
                blurRadius: _anonFired ? 15 : 10),
          ]
        : (hovering
            ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
            : null);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.35,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          onPointerDown: (_) => _startHold(),
          onPointerMove: _maybeCancelOnExit,
          onPointerUp: (_) => _cancelHold(),
          onPointerCancel: (_) => _cancelHold(),
          child: AnimatedContainer(
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            decoration: BoxDecoration(
              color: c.primaryA(hovering ? 0.18 : 0.10),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.primaryA(0.30)),
              boxShadow: glow,
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: NymRadius.rsm,
              child: InkWell(
                onTap: widget.enabled ? _handleTap : null,
                borderRadius: NymRadius.rsm,
                child: Container(
                  height: 42,
                  // Desktop `.send-btn`: `padding:10px 22px` / `font-size:12px`.
                  // Phone (≤768): `padding:10px` / `font-size:11px`
                  // (styles-themes-responsive.css:341).
                  padding: EdgeInsets.symmetric(
                      horizontal: widget.phone ? 10 : 22),
                  alignment: Alignment.center,
                  child: Text(
                    _anonFired ? 'ANON' : 'SEND',
                    style: TextStyle(
                      color: c.primary,
                      fontSize: widget.phone ? 11 : 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
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

/// Shared chrome for the quote/edit preview chips (`.quote-preview` /
/// `.edit-preview`, styles-chat.css:1412): bg-tertiary, glass border, top
/// corners rounded radius-md, shadow-lg, 8×12 padding, a colored left bar, a
/// 2-line content column, and a close ✕ (hover #fff on white@10).
class _PreviewChip extends StatelessWidget {
  const _PreviewChip({
    required this.barColor,
    required this.content,
    required this.onClose,
    required this.closeTooltip,
  });

  final Color barColor;
  final Widget content;
  final VoidCallback onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        // solid-ui repaints the chip opaque: `body.solid-ui .quote-preview,
        // .edit-preview { background: #1c1c2c }` — which IS the solid dark
        // bg-tertiary — but light `#ececea` (styles-themes-responsive.css:
        // 1836-1843), NOT the solid light bg-tertiary `#f0f0ed`, so the token
        // alone can't carry the light plate.
        color: c.solidUi && c.isLight ? const Color(0xFFECECEA) : c.bgTertiary,
        // `border: 1px solid var(--glass-border)`; `body.light-mode
        // .quote-preview/.edit-preview` re-states rgba(0,0,0,0.08) — the light
        // glassBorder — so both themes resolve to glassBorder.
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(NymRadius.md)),
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5); `body.light-mode` softens
        // it to 0 8px 32px rgba(0,0,0,0.12) (styles-themes-responsive.css:
        // 1070-1083).
        boxShadow: [
          BoxShadow(
            color: c.isLight ? const Color(0x1F000000) : const Color(0x80000000),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // `.quote-preview-bar`: 3px wide, ≥28 tall, radius 2.
          Container(
            width: 3,
            constraints: const BoxConstraints(minHeight: 28),
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: content),
          const SizedBox(width: 8),
          // `.quote-preview-close`: 16×16 ✕, dim → #fff on hover.
          _ChipCloseButton(tooltip: closeTooltip, onTap: onClose),
        ],
      ),
    );
  }
}

/// `@keyframes quoteSlideIn` (styles-chat.css:1428-1439): opacity 0→1 +
/// translateY 8px→0 over 0.2s ease-out, replayed whenever the chip (re)mounts
/// — the PWA recreates the preview element on every setQuoteReply /
/// startEditMessage, so each new chip animates in.
class _ChipSlideIn extends StatefulWidget {
  const _ChipSlideIn({super.key, required this.child});
  final Widget child;

  @override
  State<_ChipSlideIn> createState() => _ChipSlideInState();
}

class _ChipSlideInState extends State<_ChipSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();
  late final CurvedAnimation _t =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

  @override
  void dispose() {
    _t.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 8 * (1 - _t.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// `.quote-preview`: author (primary 12/w600 with a muted `#suffix`) over the
/// truncated quoted text (dim 12, ellipsis).
class _QuotePreviewChip extends StatelessWidget {
  const _QuotePreviewChip({
    required this.author,
    required this.text,
    required this.onClose,
  });

  final String author;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final split = splitNymSuffix(author);
    final base = split.base;
    final suffix = split.suffix;
    return _PreviewChip(
      barColor: c.primary,
      onClose: onClose,
      closeTooltip: 'Cancel reply',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: TextStyle(
                  color: c.primary, fontSize: 12, fontWeight: FontWeight.w600),
              children: [
                TextSpan(text: base),
                if (suffix.isNotEmpty)
                  TextSpan(
                    text: suffix,
                    // `.nym-suffix`: opacity 0.7, font-size 0.9em (≈10.8 of 12),
                    // weight 100 (styles-chat.css:706-710).
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w100,
                      fontSize: 12 * 0.9,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // The quoted line renders custom emoji as images, matching the PWA's
          // `renderCustomEmojiInEscapedText` in setQuoteReply (messages.js:1847,
          // "keep shortcodes so they render as images"). `InlineEmojiText` falls
          // back to a plain Text for unicode-only text (F-02-B). Image size is
          // the base `.custom-emoji` 1.75em of the 12px `.quote-preview-text`
          // (= 21px) — the InlineEmojiText default.
          InlineEmojiText(
            text: text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// `.edit-preview`: an amber (`#F0AD4E`) bar + a fixed "Editing message" label
/// (amber 12/w600) over the truncated original text (dim 12).
class _EditPreviewChip extends StatelessWidget {
  const _EditPreviewChip({required this.text, required this.onClose});

  static const Color amber = Color(0xFFF0AD4E);

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return _PreviewChip(
      barColor: amber,
      onClose: onClose,
      closeTooltip: 'Cancel edit',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Editing message',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: amber, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// `.quote-preview-close` / `#editPreviewClose`: 16×16 ✕, dim by default,
/// `#fff` on `white@10` on hover.
class _ChipCloseButton extends StatefulWidget {
  const _ChipCloseButton({required this.tooltip, required this.onTap});
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_ChipCloseButton> createState() => _ChipCloseButtonState();
}

class _ChipCloseButtonState extends State<_ChipCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              // `.quote-preview-close:hover` is white@0.1 fill + #fff icon
              // (dark); `body.light-mode` flips to black@0.08 fill + `--text`
              // icon (styles-themes-responsive.css:1074). Use mode-aware values.
              color: _hover
                  ? (c.isLight
                      ? Colors.black.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.1))
                  : null,
              borderRadius: NymRadius.rxs,
            ),
            child: NymSvgIcon(
              NymIcons.close,
              size: 16,
              color: _hover
                  ? (c.isLight ? c.text : Colors.white)
                  : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.translate-input-btn`: a 26×26 translate glyph, dim @0.6, hover → primary on
/// `white@8`. Pulses (opacity) while [translating]; disabled (faded) when the
/// draft is empty.
class _TranslateInputButton extends StatefulWidget {
  const _TranslateInputButton({
    required this.enabled,
    required this.translating,
    required this.onTap,
  });

  final bool enabled;
  final bool translating;
  final VoidCallback onTap;

  @override
  State<_TranslateInputButton> createState() => _TranslateInputButtonState();
}

class _TranslateInputButtonState extends State<_TranslateInputButton>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // Created eagerly (not lazily) so a never-translated button still has a
    // controller to dispose — a lazy `late` field would otherwise initialise a
    // ticker against a deactivated State during dispose().
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void didUpdateWidget(covariant _TranslateInputButton old) {
    super.didUpdateWidget(old);
    if (widget.translating && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.translating && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = _hover && widget.enabled ? c.primary : c.textDim;
    Widget glyph = NymSvgIcon(NymIcons.translate, size: 16, color: color);
    if (widget.translating) {
      // `.translating` pulse: opacity 0.4 ↔ 0.8.
      glyph = FadeTransition(
        opacity: Tween(begin: 0.4, end: 0.8).animate(_pulse),
        child: glyph,
      );
    }
    // `.translating`'s keyframes animate the SAME opacity property, so the
    // 0.4↔0.8 pulse REPLACES the base opacity (styles-chat.css:1784-1800) —
    // don't also apply the disabled 0.4 or the pulse dims to 0.16–0.32.
    return Opacity(
      opacity: widget.translating
          ? 1.0
          : (widget.enabled ? (_hover ? 1.0 : 0.6) : 0.4),
      child: Tooltip(
        message: 'Translate text',
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.enabled ? widget.onTap : null,
            // OPAQUE is load-bearing: the default deferToChild never hits —
            // the Container's decoration color is null at rest and the SVG
            // glyph's render object doesn't hit-test itself, so taps fell
            // straight through (the PWA's 26×26 `<button>` is clickable over
            // its whole box).
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // `.translate-input-btn:hover` is white@0.08 (dark);
                // `body.light-mode` flips it to black@0.06
                // (styles-themes-responsive.css:1274) — M1.
                color: _hover && widget.enabled
                    ? (c.isLight
                        ? Colors.black.withValues(alpha: 0.06)
                        : Colors.white.withValues(alpha: 0.08))
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }
}

/// One `.translate-dropdown-item` row: the language name + a trailing favorite
/// star. The row hovers to `white@0.08` + `--text-bright`; the star is
/// `--text-dim` (hover `white@0.1` + text-bright), and `#f5c518` when favorited
/// (styles-chat.css:1850-1897).
class _TranslateLangRow extends StatefulWidget {
  const _TranslateLangRow({
    required this.name,
    required this.favorited,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final String name;
  final bool favorited;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  State<_TranslateLangRow> createState() => _TranslateLangRowState();
}

class _TranslateLangRowState extends State<_TranslateLangRow> {
  bool _hover = false;
  bool _starHover = false;

  static const Color _favColor = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // `.translate-dropdown-item:hover` white@0.08 (dark);
          // `body.light-mode` → black@0.05 (styles-themes-responsive.css:1284) — M2.
          color: _hover
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : Colors.white.withValues(alpha: 0.08))
              : null,
          // `.translate-dropdown-item`: padding 7px 8px 7px 14px; gap 8.
          padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hover ? c.textBright : c.text,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // `.translate-dropdown-star`: 24×24, radius-sm.
              MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _starHover = true),
                onExit: (_) => setState(() => _starHover = false),
                child: GestureDetector(
                  onTap: widget.onToggleFavorite,
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      // `.translate-dropdown-star:hover` white@0.1 (dark); no
                      // explicit light override, so use black@0.06 on the light
                      // surface (parity with the row hover) — M2.
                      color: _starHover
                          ? (c.isLight
                              ? Colors.black.withValues(alpha: 0.06)
                              : Colors.white.withValues(alpha: 0.1))
                          : null,
                      borderRadius: NymRadius.rsm,
                    ),
                    child: NymSvgIcon(
                      widget.favorited
                          ? NymIcons.starFilled
                          : NymIcons.starOutline,
                      size: 14,
                      color: widget.favorited
                          ? _favColor
                          : (_starHover ? c.textBright : c.textDim),
                    ),
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

/// Lowest Unicode Private-Use-Area code point (U+E000). Sentinels are allocated
/// upward from here (the BMP PUA runs U+E000…U+F8FF = 6400 slots — far more than
/// the handful of distinct custom emoji a single draft can hold).
const int _kSentinelBase = 0xE000;
const int _kSentinelEnd = 0xF8FF;

/// Matches one PUA sentinel code point (for `expand` / `buildTextSpan` walks and
/// the wire-safety test invariant). The BMP Private-Use-Area block.
final RegExp _rxSentinel = RegExp('[\u{E000}-\u{F8FF}]', unicode: true);

/// A COMPLETED custom-emoji shortcode token `:code:` (NIP-30 codes are
/// `[a-zA-Z0-9_+-]+`). Resolve-on-input swaps a token whose `code` is a known
/// custom emoji to a single sentinel char (the picker's literal insert + typed
/// input both flow through here).
final RegExp _rxShortcodeToken = RegExp(r':([a-zA-Z0-9_+\-]+):');

/// A [TextEditingController] that renders custom (image) emoji INLINE in the
/// composer while the user types (02-F-02-E), replicating the PWA's
/// `_maybeRenderTypedEmoji` (ui-context.js:1034) on a Flutter [TextField].
///
/// THE TECHNIQUE (sentinel char + WidgetSpan): a `WidgetSpan` occupies exactly
/// ONE character slot in caret/selection math, but a typed `:smile:` is 7 chars.
/// So each rendered emoji is kept as exactly ONE Private-Use-Area code point in
/// [text] (allocated per DISTINCT shortcode via [_codeToSentinel]); [buildTextSpan]
/// paints that char as the emoji image. Because emoji == 1 char, caret / selection
/// / backspace all stay correct automatically (backspace deletes the whole emoji).
///
/// WIRE-SAFETY (non-negotiable): a sentinel must NEVER reach the relay or any
/// service. [expand] maps every sentinel back to its `:shortcode:`; the composer
/// routes every wire-bound draft read through it (see `_draftText`).
class EmojiSentinelController extends TextEditingController {
  EmojiSentinelController({super.text});

  /// shortcode → image url (the live NIP-30 `codeToUrl`). Set from the composer's
  /// `build`; drives both which `:code:` resolve and what image a sentinel paints.
  Map<String, String> _codeToUrl = const {};
  set codeToUrl(Map<String, String> value) {
    if (identical(_codeToUrl, value)) return;
    _codeToUrl = value;
    // The picker/autocomplete already re-resolve on insert; repaint so a sentinel
    // whose url only just arrived over relays gets its image (and so a code that
    // became known can resolve on the next input pass). Cheap: no text mutation.
    notifyListeners();
  }

  /// sentinel char → shortcode and the inverse. One sentinel per DISTINCT
  /// shortcode present in the draft, reused across occurrences.
  final Map<String, String> _sentinelToCode = {};
  final Map<String, String> _codeToSentinel = {};
  int _nextSentinel = _kSentinelBase;

  /// Allocates (or reuses) the sentinel char for [code]. Returns null only if the
  /// PUA space is exhausted (≈6400 distinct codes — never in practice), in which
  /// case the caller leaves the literal `:code:` text alone.
  String? _sentinelFor(String code) {
    final existing = _codeToSentinel[code];
    if (existing != null) return existing;
    if (_nextSentinel > _kSentinelEnd) return null;
    final ch = String.fromCharCode(_nextSentinel++);
    _codeToSentinel[code] = ch;
    _sentinelToCode[ch] = code;
    return ch;
  }

  /// Maps every sentinel char in [input] back to its literal `:shortcode:`. The
  /// wire-safety primitive: the composer expands the draft through this before it
  /// reaches the relay / translate / history. Non-sentinel text passes verbatim.
  String expand(String input) {
    if (input.isEmpty || _sentinelToCode.isEmpty) return input;
    return input.replaceAllMapped(_rxSentinel, (m) {
      final code = _sentinelToCode[m[0]];
      return code != null ? ':$code:' : m[0]!;
    });
  }

  /// The pure resolve transform (extracted so it is unit-testable without a
  /// widget pump): given a [value], replace each COMPLETED `:code:` whose `code`
  /// is in [_codeToUrl] with its single sentinel char and return the rewritten
  /// value with the selection shifted by the cumulative length delta (so the
  /// caret stays put relative to the surrounding text). Returns null when nothing
  /// changed (no known token present).
  TextEditingValue? resolveValue(TextEditingValue value) {
    final src = value.text;
    if (src.isEmpty || !src.contains(':')) return null;
    final sb = StringBuffer();
    var last = 0;
    var changed = false;
    // Track the selection endpoints as we rewrite, decrementing each by the chars
    // removed BEFORE it (a `:code:` of length N collapses to 1 → −(N−1)).
    var base = value.selection.baseOffset;
    var extent = value.selection.extentOffset;
    for (final m in _rxShortcodeToken.allMatches(src)) {
      final code = m.group(1)!;
      if (!_codeToUrl.containsKey(code)) continue; // unknown → stays literal
      final ch = _sentinelFor(code);
      if (ch == null) continue; // PUA exhausted → leave literal
      sb.write(src.substring(last, m.start));
      sb.write(ch);
      last = m.end;
      changed = true;
      final delta = (m.end - m.start) - 1; // chars removed for this token
      base = _shiftOffset(base, m.start, m.end, delta);
      extent = _shiftOffset(extent, m.start, m.end, delta);
    }
    if (!changed) return null;
    sb.write(src.substring(last));
    final out = sb.toString();
    final maxOffset = out.length;
    return TextEditingValue(
      text: out,
      selection: TextSelection(
        baseOffset: base.clamp(-1, maxOffset),
        extentOffset: extent.clamp(-1, maxOffset),
      ),
      composing: TextRange.empty,
    );
  }

  /// Shifts a single caret [offset] for a `[start,end)` run that collapsed by
  /// [delta] chars. After the run → move left by delta; inside → clamp to the run
  /// start + 1 (just past the inserted sentinel); before → unchanged. A negative
  /// offset (no selection) is passed through.
  static int _shiftOffset(int offset, int start, int end, int delta) {
    if (offset < 0) return offset;
    if (offset >= end) return offset - delta;
    if (offset > start) return start + 1;
    return offset;
  }

  /// Runs [resolveValue] against the live [value] and applies it in place. Called
  /// from the composer's `_onInputChanged` after every edit so a just-completed
  /// known `:code:` becomes its sentinel/image immediately (mirrors the PWA's
  /// `_maybeRenderTypedEmoji` firing when the closing `:` completes a token).
  void resolveInput() {
    final next = resolveValue(value);
    if (next != null) value = next;
  }

  @override
  void clear() {
    _resetSentinels();
    super.clear();
  }

  @override
  set value(TextEditingValue newValue) {
    // When the draft empties (cleared / sent / recalled to the live slot), drop
    // the sentinel allocations so a fresh draft starts from U+E000 and stale
    // mappings can't leak. (`clear()` also resets, but text can empty via a
    // direct value/`text=` assignment too.)
    if (newValue.text.isEmpty && _sentinelToCode.isNotEmpty) {
      _resetSentinels();
    }
    super.value = newValue;
  }

  void _resetSentinels() {
    _sentinelToCode.clear();
    _codeToSentinel.clear();
    _nextSentinel = _kSentinelBase;
  }

  /// Paints the editing text: each sentinel char becomes the custom-emoji image
  /// (the SAME construction [InlineEmojiText] / the message `CustomEmojiNode` use
  /// — `InlineNetworkImage(url: proxiedMedia(url, emoji:true), …)` so the composer
  /// emoji is pixel-identical to the rendered-message one), every other run is a
  /// normal [TextSpan] using the passed [style].
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final src = text;
    // Fast path: no sentinel → defer to the framework's default (also keeps
    // composing-region underlines intact while typing plain text).
    if (_sentinelToCode.isEmpty || !_rxSentinel.hasMatch(src)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final baseStyle = style ?? const TextStyle();
    // 1.4× the font size, square — `div.message-input .custom-emoji
    // { width/height: 1.4em }` (styles-chat.css:1703-1708).
    final side = (baseStyle.fontSize ?? 14) * 1.4;
    final children = <InlineSpan>[];
    final buf = StringBuffer();

    void flushText() {
      if (buf.isEmpty) return;
      children.add(TextSpan(text: buf.toString(), style: baseStyle));
      buf.clear();
    }

    for (final rune in src.runes) {
      final isSentinel = rune >= _kSentinelBase && rune <= _kSentinelEnd;
      final code =
          isSentinel ? _sentinelToCode[String.fromCharCode(rune)] : null;
      final url = code == null ? null : _codeToUrl[code];
      if (code == null || url == null) {
        // Plain char — OR a sentinel whose mapping/url is somehow gone: render the
        // literal `:code:` (never a bare PUA glyph) so nothing visually leaks.
        buf.write(code != null ? ':$code:' : String.fromCharCode(rune));
        continue;
      }
      flushText();
      // `div.message-input .custom-emoji { vertical-align: -0.3em }`
      // (styles-chat.css:1703-1708): baseline-aligned with the image bottom
      // 0.3em below the alphabetic baseline.
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: EmojiBaselineDrop(
            drop: (baseStyle.fontSize ?? 14) * 0.3,
            child: InlineNetworkImage(
              url: proxiedMedia(url, emoji: true),
              width: side,
              height: side,
              fit: BoxFit.contain,
              // Same disk-cache + SVG handling + retry + literal-fallback as the
              // rendered message emoji (message_content.dart `CustomEmojiNode`).
              retryOnError: true,
              errorChild: Text(':$code:', style: baseStyle),
            ),
          ),
        ),
      ));
    }
    flushText();
    return TextSpan(style: baseStyle, children: children);
  }
}
