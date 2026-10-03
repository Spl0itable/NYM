import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import '../../features/autocomplete/autocomplete_dropdown.dart';
import '../../features/mesh/mesh_controller.dart';
import '../../features/autocomplete/autocomplete_queries.dart';
import '../../features/autocomplete/autocomplete_triggers.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/group_tools/group_tools_service.dart' show GtChat;
import '../../features/group_tools/group_tools_ui.dart';
import '../../features/commands/command_handler.dart';
import '../../features/commands/command_i18n.dart';
import '../../features/commands/command_palette.dart';
import '../../features/commands/command_registry.dart';
import '../../features/composer/composer_menus.dart';
import '../../features/composer/composer_model.dart';
import '../../features/dm_polls/dm_polls_providers.dart';
import '../../features/dm_polls/dm_polls_service.dart' show DmPollsService;
import '../../features/emoji/custom_emoji.dart';
import '../../features/emoji/emoji_data.dart';
import '../../features/emoji/emoji_picker.dart';
import '../../features/emoji/gif_picker.dart';
import '../../features/groups/group_logic.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../../features/i18n/i18n.dart';
import '../../features/identity/dev_nsec_modal.dart';
import '../../features/media_notes/media_note_sender.dart';
import '../../features/media_notes/media_notes.dart';
import '../../features/media_notes/media_options_bar.dart';
import '../../features/media_notes/once_crypto.dart';
import '../../features/media_notes/photo_compress.dart';
import '../../features/media_notes/video_note_recorder.dart';
import '../../features/media_notes/voice_record_bar.dart';
import '../../features/media_notes/voice_recorder.dart';
import '../../features/messages/format/message_content.dart'
    show InlineEmojiText, TimestampChip, openFullscreenMedia, proxiedMedia;
import '../../features/messages/format/nym_format.dart' show NymFormat;
import '../../features/messages/inline_network_image.dart';
import '../../features/nymbot/nymbot_models.dart';
import '../../features/polls/poll_create_modal.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/translate/translate_languages.dart';
import '../../features/translate/translate_service.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/user.dart' show UserStatus;
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../context_menu/interaction_hooks.dart';
import 'composer_format.dart';
import 'composer_markdown.dart';
import 'message_row.dart' show GroupInfoMember, encodeGroupInfoSystemMessage;
import '../../features/chat_lock/chat_lock_providers.dart';

/// Session-wide per-conversation drafts, kept outside the widget because the bot chat swaps [Composer] out.
class ComposerDrafts {
  ComposerDrafts._();

  static final Map<String, String> _drafts = {};

  /// `'g:'`/`'p:'`/`'c:'` prefixed keys like the PWA's `_getInputContextKey`.
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

  /// A blank draft deletes the stored entry.
  static void save(String key, String value) {
    if (value.trim().isNotEmpty) {
      _drafts[key] = value;
    } else {
      _drafts.remove(key);
    }
  }

  static String restore(String key) => _drafts[key] ?? '';
}

/// The message composer: input, toolbar buttons and send.
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key, required this.compact});

  /// Mobile/tablet stacks the toolbar below the input.
  final bool compact;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = EmojiSentinelController();
  final _focus = FocusNode();

  // Only one picker popover is open at a time.
  final _emojiPortal = OverlayPortalController();
  final _emojiAnchor = LayerLink();
  String _pickerTab = 'emoji';
  final GlobalKey _attachKey = GlobalKey();
  final GlobalKey _sendSplitKey = GlobalKey();

  SharedPreferences? _prefs;
  List<String> _recents = const [];

  // Live NIP-30 custom emoji, a superset of the cached state, synced each build.
  CustomEmojiState _customEmojis = CustomEmojiState.empty;

  // Quote/edit are deferred to send: a chip sits above the input while the typed text stays clean.
  ({String author, String text, String fullText})? _pendingQuote;
  PendingEdit? _pendingEdit;

  // Each conversation switch stashes the outgoing draft, clears quote/edit, and restores the incoming draft.
  String? _activeDraftKey;

  /// Stored expanded (`:code:` text) so drafts never carry sentinel chars whose allocations can be dropped.
  void _saveCurrentDraft() {
    final key = _activeDraftKey;
    if (key == null) return;
    ComposerDrafts.save(key, _controller.expand(_controller.text));
  }

  /// No-ops when the input already holds that exact text.
  void _restoreDraftForContext(ChatView view) {
    final key = ComposerDrafts.keyFor(view);
    _activeDraftKey = key;
    final draft = ComposerDrafts.restore(key);
    if (_controller.text == draft) return;
    _controller.text = draft;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    // Recompute popout and autocomplete state for the restored text.
    _onInputChanged();
  }

  /// Save the outgoing draft, clear the quote chip, cancel an edit, then restore the incoming draft.
  void _onViewSwitched(ChatView view) {
    if (!mounted) return;
    _saveCurrentDraft();
    _clearQuote();
    if (_pendingEdit != null) _cancelEdit();
    _restoreDraftForContext(view);
  }

  final _translatePortal = OverlayPortalController();
  final _translateAnchor = LayerLink();
  final _translateSearchController = TextEditingController();
  String _translateQuery = '';
  bool _translating = false;

  bool _formatToolbarOpen = false;

  /// Uploaded bytes by hosted URL, so thumbnails need no re-download.
  final Map<String, Uint8List> _localMediaPreviews = {};

  /// Uploaded URLs (to is-video), matched by identity since Blossom URLs may lack an extension.
  final Map<String, bool> _uploadedMedia = {};

  /// This, not the draft text, decides which media the message carries; URLs are appended on send.
  final List<ComposerAttachment> _attachments = [];
  int _attachmentSeq = 0;

  /// Only finished uploads contribute, so a half-finished batch never sends a broken link.
  List<String> get attachmentUrls => [
        for (final a in _attachments)
          if (a.isDone && _attachmentContent(a).isNotEmpty) _attachmentContent(a)
      ];

  bool get hasPendingUploads => _attachments.any((a) =>
      a.status == ComposerAttachmentStatus.uploading || _attachmentStale(a));

  bool _composerHd = false;
  bool _composerOnce = false;
  VoiceRecordingController? _voice;
  ChatView? _voiceTarget;
  String _voiceRoute = 'online';

  String _currentMediaRoute(ChatView view) {
    final online = ref.read(appStateProvider).connectedRelays > 0 ||
        ref.read(nostrControllerProvider).isLive;
    return mediaRouteFor(
        ref.read(meshControllerProvider.notifier).bridge, online, view);
  }

  MediaFeatureState _mediaFeature(String feature) {
    final view = ref.read(appStateProvider).view;
    return mediaFeatureWith(feature, view, _currentMediaRoute(view));
  }

  bool get _wantOnce =>
      _composerOnce && _mediaFeature('once').level != MediaFeatureLevel.off;

  String _attachmentContent(ComposerAttachment a) {
    final v = a.uploadedAs;
    if (v == null || !v.once) return a.url;
    final kind = a.isVideo ? 'video' : 'photo';
    final full = attachDescriptor(
        a.url,
        MediaNote(
          kind: kind,
          mime: v.mime,
          size: v.size,
          once: true,
          onceId: v.onceId,
          key: v.key,
          nonce: v.nonce,
        ));
    return full.isEmpty ? '' : onceContent(kind, full);
  }

  bool _attachmentStale(ComposerAttachment a) {
    final v = a.uploadedAs;
    if (a.status != ComposerAttachmentStatus.done || v == null) return false;
    final hdMatters = !a.isVideo && a.compressed != null;
    return v.once != _wantOnce || (hdMatters && v.hd != _composerHd);
  }

  void _reuploadStale() {
    for (final a in List.of(_attachments)) {
      if (_attachmentStale(a)) _retryAttachment(a);
    }
  }

  void _toggleComposerHd() {
    setState(() => _composerHd = !_composerHd);
    _reuploadStale();
  }

  void _toggleComposerOnce() {
    final st = _mediaFeature('once');
    if (st.level == MediaFeatureLevel.off) {
      _onSystemMessage(tr(st.reason));
      return;
    }
    setState(() => _composerOnce = !_composerOnce);
    _reuploadStale();
  }

  Future<bool> _startVoice() async {
    if (_voice != null) return true;
    final st = _mediaFeature('voice');
    if (st.level == MediaFeatureLevel.off) {
      _onSystemMessage(tr(st.reason));
      return false;
    }
    final view = ref.read(appStateProvider).view;
    final rec = VoiceRecordingController(
      backend: ref.read(voiceRecorderBackendProvider)(),
      tempPath: ref.read(voiceTempPathProvider),
      maxSeconds: st.maxSeconds ?? MediaNoteLimits.voiceMaxSeconds,
      warnReason: st.level == MediaFeatureLevel.warn ? st.reason : '',
    );
    setState(() {
      _voice = rec;
      _voiceTarget = view;
      _voiceRoute = _currentMediaRoute(view);
    });
    final r = await rec.start();
    if (r != VoiceStartResult.started) {
      if (mounted && _voice == rec) setState(() => _voice = null);
      rec.dispose();
      _onSystemMessage(r == VoiceStartResult.denied
          ? tr("Microphone access was denied, so voice messages can't be recorded.")
          : tr(MediaNoteReasons.voiceNoMic));
      return false;
    }
    return true;
  }

  void _lockVoice() => _voice?.lock();

  Future<void> _stopVoice(bool send) async {
    final rec = _voice;
    if (rec == null) return;
    final target = _voiceTarget ?? ref.read(appStateProvider).view;
    final route = _voiceRoute;
    final recorded = await rec.stop(send: send);
    if (mounted && _voice == rec) setState(() => _voice = null);
    rec.dispose();
    if (!send) return;
    if (recorded == null) {
      _onSystemMessage(
          tr('Hold to record, release to send. Tap to record hands-free.'));
      return;
    }
    final bytes = await File(recorded.path).readAsBytes();
    try {
      File(recorded.path).deleteSync();
    } catch (_) {}
    final desc = MediaNote(
      kind: 'voice',
      mime: recorded.mime,
      duration: recorded.duration,
      size: bytes.length,
      waveform: computeWaveform(recorded.samples),
    );
    await ref
        .read(mediaNoteSenderProvider)
        .send(desc, bytes, target, route: route, once: recorded.once);
  }

  Future<void> _openVideoNote() async {
    final st = _mediaFeature('round');
    if (st.level == MediaFeatureLevel.off) {
      _onSystemMessage(tr(st.reason));
      return;
    }
    final view = ref.read(appStateProvider).view;
    final route = _currentMediaRoute(view);
    final onceAllowed = _mediaFeature('once').level != MediaFeatureLevel.off;
    final note = await showVideoNoteRecorder(context,
        onceAllowed: onceAllowed,
        maxSeconds: st.maxSeconds ?? MediaNoteLimits.roundMaxSeconds);
    if (note == null || !mounted) return;
    final bytes = await File(note.path).readAsBytes();
    try {
      File(note.path).deleteSync();
    } catch (_) {}
    final desc = MediaNote(
      kind: 'round',
      mime: note.mime,
      duration: note.duration,
      size: bytes.length,
    );
    await ref
        .read(mediaNoteSenderProvider)
        .send(desc, bytes, view, route: route, once: note.once);
  }

  List<String> _translateFavorites = const [];

  /// Snapshotted on open; toggling a star mid-open doesn't reorder until reopen, as in the PWA.
  List<MapEntry<String, String>> _translateLangOrder = const [];

  /// Whether the draft exceeds ~1.5 lines and floats into the `.composer-popout` box.
  bool _popout = false;

  /// Held so the popout can show a [Scrollbar] for drafts taller than the box.
  final ScrollController _fieldScroll = ScrollController();

  /// For ~1/s throttling.
  int _lastMeshTypingMs = 0;

  /// Hosts the floating popout field while the in-flow slot keeps a fixed placeholder so the toolbar stays put.
  final _popoutPortal = OverlayPortalController();

  /// Keeps the one TextField element alive across the popout switch, so focus and the IME connection survive.
  final GlobalKey _fieldKey = GlobalKey();

  /// Lets the autocomplete dropdown span the input width, not the screen.
  final GlobalKey _inputKey = GlobalKey();

  /// Lets the autocomplete dropdown clear the quote/edit chip.
  final GlobalKey _chipKey = GlobalKey();

  /// Lets the dropdown clear the attachment strip and format toolbar; the column already includes its 8px gap.
  final GlobalKey _panelsKey = GlobalKey();

  /// Last offset used, so a panel appearing beneath the dropdown can trigger the needed rebuilds.
  double _acOffsetUsed = 0;

  /// Lets the dropdown clear the popout overhang too.
  final GlobalKey _popoutFieldKey = GlobalKey();

  /// Sent history for ↑/↓ recall on an empty input; newest last, capped.
  final List<String> _sentHistory = [];

  /// `_sentHistory.length` means the live (empty) draft.
  int _historyIndex = 0;

  // Autocomplete/command palette: one active trigger token at a time.
  final _acAnchor = LayerLink();
  final _acPortal = OverlayPortalController();

  /// Ties the field and dropdown so taps elsewhere dismiss it; per-instance so column composers don't cross-dismiss.
  final Object _acGroupId = Object();
  TriggerMatch _trigger = const TriggerMatch.none();
  AutocompleteView? _acView;
  List<PaletteRow> _paletteRows = const [];
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
    // Stash the unsent input before unmounting; the PWA's single input never unmounts.
    _saveCurrentDraft();
    final voice = _voice;
    _voice = null;
    if (voice != null) {
      unawaited(voice.stop(send: false).whenComplete(voice.dispose));
    }
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    _fieldScroll.dispose();
    _translateSearchController.dispose();
    super.dispose();
  }

  /// Mentions splice at the caret; quotes set the deferred chip rather than inserting markdown.
  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        final lead = needsSpace ? ' ' : '';
        // Resolve to a pubkey so the mention carries the avatar/flair chip; unresolved stays literal.
        final target = resolveTarget(fullNym, ref.read(usersProvider));
        final ch = target == null
            ? null
            : _controller.mentionSentinel(
                fullNym: fullNym, pubkey: target.pubkey);
        final insert = ch != null ? '$lead$ch ' : '$lead@$fullNym ';
        _controller.text = existing + insert;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case QuoteAction(:final fullNym, :final content):
        _pendingQuote = (
          author: fullNym,
          text: _strippedQuoteText(content),
          fullText: content.contains('#nym:') ? previewText(content) : content,
        );
      case InsertTextAction(:final text):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ')
            ? (existing.endsWith('\n') ? '' : '\n')
            : '';
        _controller.text = existing + needsSpace + text;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case ShareFilesAction(:final paths):
        final files = [for (final p in paths) XFile(p)];
        if (files.isNotEmpty) {
          // Fire-and-forget; the upload path manages its own progress state.
          unawaited(_pickAndUploadImage(preselected: files));
        }
    }
    _focus.requestFocus();
    setState(() {});
  }

  /// Keeps only top-level quote lines, collapses blank runs and trims.
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
    final joined =
        kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return joined.contains('#nym:') ? previewText(joined) : joined;
  }

  /// Elides the game-state token first so a quote chip never shows a raw `[gc:…]` blob; capped at 120.
  static String _quotePreviewText(String text) {
    final clean = NymFormat.stripForPreview(NymFormat.stripGameTokens(text))
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_~`>#]'), '');
    return clean.length > 120 ? '${clean.substring(0, 120)}...' : clean;
  }

  void _clearQuote() {
    if (_pendingQuote == null) return;
    setState(() => _pendingQuote = null);
  }

  /// Seeds the input with the original content, drops a pending quote, and shows the edit chip.
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

  void _cancelEdit() {
    if (_pendingEdit == null) return;
    setState(() => _pendingEdit = null);
    _controller.clear();
    _onInputChanged();
  }

  @override
  void initState() {
    super.initState();
    // Seed the draft key so the first switch away saves the unsent input.
    _activeDraftKey = ComposerDrafts.keyFor(ref.read(currentViewProvider));
    // Rebuild on focus change for the focus fill and ring.
    _focus.addListener(_onFocusChanged);
    // Register hooks so slash commands that open UI surfaces actually fire.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(nostrControllerProvider).setCommandHooks(
            onSystemMessage: _onSystemMessage,
            hooks: _buildCommandHooks(),
          );
      // A remount (e.g. returning from the bot chat) must restore the stashed draft.
      _restoreDraftForContext(ref.read(currentViewProvider));
    });
  }

  /// UI-layer hooks for slash commands that open surfaces, registered once via [setCommandHooks].
  CommandHooks _buildCommandHooks() {
    final controller = ref.read(nostrControllerProvider);
    return CommandHooks(
      openPoll: _openPoll,
      openPm: (pubkey, nym) => controller.startPM(pubkey, nym: nym),
      // Fresh LN-address resolve via the controller so an un-ingested profile can still be zapped.
      openZap: (pubkey, nym) async {
        final baseNym = stripPubkeySuffix(nym);
        _onSystemMessage(
            tr('Checking if @{nym} can receive zaps...', {'nym': baseNym}));
        final lnAddr = await controller.resolveLightningAddressForZap(pubkey);
        if (lnAddr == null || lnAddr.isEmpty) {
          _onSystemMessage(tr(
              '@{nym} cannot receive zaps (no lightning address set)',
              {'nym': baseNym}));
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
      createGroup: (members, name) {
        if (members.isEmpty) {
          _onSystemMessage(tr('Usage: /group @nym1 @nym2 [group name]'));
          return;
        }
        unawaited(controller.createGroup(name, members));
      },
      addMember: _addMemberToCurrentGroup,
      invite: _addMemberToCurrentGroup,
      groupInfo: _showGroupInfo,
      kick: (pubkey) =>
          _withCurrentGroup((gid) => controller.kickFromGroup(gid, pubkey)),
      ban: (pubkey) =>
          _withCurrentGroup((gid) => controller.banFromGroup(gid, pubkey)),
      unban: _unbanFromCurrentGroup,
      addMod: (pubkey) =>
          _withCurrentGroup((gid) => controller.promoteModerator(gid, pubkey)),
      removeMod: (pubkey) =>
          _withCurrentGroup((gid) => controller.revokeModerator(gid, pubkey)),
      addAdmin: (pubkey) =>
          _withCurrentGroup((gid) => controller.promoteAdmin(gid, pubkey)),
      removeAdmin: (pubkey) =>
          _withCurrentGroup((gid) => controller.revokeAdmin(gid, pubkey)),
      transferOwner: (pubkey) =>
          _withCurrentGroup((gid) => controller.transferOwner(gid, pubkey)),
      openDevNsecChallenge: () => unawaited(_runDevNsecChallenge()),
      openTimestampPicker: () => unawaited(_pickTimestamp()),
    );
  }

  /// Prompts for the developer nsec and on a verified match logs the running session into that account.
  Future<void> _runDevNsecChallenge() async {
    if (!mounted) return;
    final result = await DevNsecModal.open(context);
    if (result == null) {
      _onSystemMessage(tr('Nickname change canceled.'));
      return;
    }
    try {
      await ref.read(nostrControllerProvider).loginWithNsec(result.nsec);
    } catch (_) {
      // The modal pre-verified the nsec, so a failure here is a login error; show the abort line.
      if (mounted) _onSystemMessage(tr('Nickname change canceled.'));
      return;
    }
    if (!mounted) return;
    final nym = ref.read(appStateProvider).selfNym;
    _onSystemMessage(
        tr('Identity verified. You are now logged in as {nym}.', {'nym': nym}));
  }

  void _withCurrentGroup(Future<void> Function(String groupId) action) {
    final view = ref.read(currentViewProvider);
    if (view.kind == ViewKind.group) unawaited(action(view.id));
  }

  void _addMemberToCurrentGroup(String arg) {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) {
      _onSystemMessage(tr('You must be in a group to add members.'));
      return;
    }
    final target = resolveTarget(arg, ref.read(usersProvider));
    if (target == null) {
      _onSystemMessage(tr('User {user} not found', {'user': arg.trim()}));
      return;
    }
    unawaited(ref
        .read(nostrControllerProvider)
        .addGroupMembers(view.id, [target.pubkey]));
  }

  /// Owner/mod only; the target must be banned; publishes `group-unban` to every member.
  void _unbanFromCurrentGroup(String pubkey) {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) return;
    final appState = ref.read(appStateProvider.notifier);
    final app = ref.read(appStateProvider);
    final group = appState.groupById(view.id);
    if (group == null) return;
    if (!GroupLogic.canModerate(group, app.selfPubkey)) {
      _onSystemMessage(
          tr('Only the group owner or a moderator can unban users.'));
      return;
    }
    if (!group.banned.contains(pubkey)) {
      _onSystemMessage(tr('That user is not banned.'));
      return;
    }
    unawaited(
        ref.read(nostrControllerProvider).unbanFromGroup(view.id, pubkey));
    ref.read(nostrControllerProvider).ensureProfiles([pubkey]);
    final nym = ref.read(usersProvider)[pubkey]?.nym ??
        'anon#${pubkey.substring(pubkey.length - 4)}';
    _onSystemMessage(
        tr('@{nym} was unbanned. They can be re-invited.', {'nym': nym}));
  }

  /// Emits the `.group-info` block: owner, mods, then members, each alphabetized; prefetches unknown profiles.
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
    int rank(String pk) => GroupLogic.roleRank(group, pk);
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
            else if (group.admins.contains(pk))
              'admin'
            else if (mods.contains(pk))
              'mod',
            if (pk == app.selfPubkey) 'you',
          ],
        ),
    ];
    ref.read(nostrControllerProvider).ensureProfiles(sorted);
    ref
        .read(appStateProvider.notifier)
        .addSystemMessage(encodeGroupInfoSystemMessage((
          name: group.name,
          count: group.members.length,
          members: members,
        )));
  }

  void _onFocusChanged() {
    // Markers follow the caret, and an unfocused field has no caret.
    _controller.composerFocused = _focus.hasFocus;
    if (mounted) setState(() {});
  }

  void _onSystemMessage(String text) {
    if (!mounted) return;
    // Also shows a SnackBar so feedback is visible when scrolled away.
    ref.read(appStateProvider.notifier).addSystemMessage(text);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  Future<SharedPreferences> _ensurePrefs() async {
    if (_prefs != null) return _prefs!;
    final prefs = await ref.read(emojiPrefsProvider.future);
    _prefs = prefs;
    _recents = EmojiRecentsStore(prefs).load();
    _translateFavorites = _loadTranslateFavorites(prefs);
    // Same key the PWA uses.
    final toolbar = prefs.getBool(kFormatToolbarKey) ?? false;
    if (mounted && toolbar != _formatToolbarOpen) {
      setState(() => _formatToolbarOpen = toolbar);
    }
    return prefs;
  }

  static List<String> _loadTranslateFavorites(SharedPreferences prefs) {
    final raw = prefs.getString(kTranslateFavoritesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// Persists via [_ensurePrefs] so the write never silently no-ops.
  void _toggleTranslateFavorite(String code) {
    final next = [..._translateFavorites];
    if (!next.remove(code)) next.add(code);
    setState(() => _translateFavorites = next);
    _ensurePrefs().then(
        (prefs) => prefs.setString(kTranslateFavoritesKey, jsonEncode(next)));
  }

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
    // The spliced text can cross the popout threshold; this also re-syncs the popout portal.
    _onInputChanged();
    _focus.requestFocus();
  }

  /// Closes a picker without selection and refocuses the input, except at <=768px so no phone keyboard pops up.
  void _hidePickerAndRefocus(OverlayPortalController portal) {
    portal.hide();
    if (!mounted) return;
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return;
    }
    _focus.requestFocus();
  }

  void _hideEmojiPicker() {
    _hidePickerAndRefocus(_emojiPortal);
    if (mounted) setState(() {});
  }

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _hideEmojiPicker();
      return;
    }
    await _ensurePrefs();
    if (!mounted) return;
    setState(() => _pickerTab = 'emoji');
    _emojiPortal.show();
  }

  void _switchPickerTab(String tab) {
    if (tab == _pickerTab) return;
    setState(() => _pickerTab = tab);
  }

  Future<void> _onEmojiSelected(String emoji) async {
    _insertAtCaret(emoji);
    _emojiPortal.hide();
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  void _onGifSelected(String url) {
    _insertAtCaret(url);
    _emojiPortal.hide();
  }

  /// Recomputes the trigger and dropdown contents on every input change.
  void _onInputChanged() {
    // Collapse completed `:shortcode:`s to sentinel chars before trigger/popout math.
    _controller.resolveInput();
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : _controller.text.length;
    // In the bot PM the `?` palette must survive a space for multi-step subcommands.
    final botPM = _inBotPM();
    final trigger = detectTrigger(_controller.text, caret: caret, botPM: botPM);
    _trigger = trigger;
    _selectedIndex = 0;

    // Popout when the draft exceeds ~1.5 lines, measured at the real field width.
    _popout = _draftWantsPopout();
    _syncPopoutPortal();

    if (trigger.kind == TriggerKind.command) {
      _paletteRows = buildPaletteRows(trigger.query);
      _botRows = const [];
      _acView = null;
    } else if (trigger.kind == TriggerKind.botCommand) {
      _botRows = botPM
          ? [
              for (final c
                  in filterBotPMCommands(canonicalizeCommandInput(trigger.query)))
                BotPaletteCommand(
                  command: localizeCommandTokensIn(c.name),
                  desc: c.desc,
                ),
            ]
          : buildLocalizedBotPaletteRows(trigger.query);
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

  void _syncPopoutPortal() {
    if (_popout) {
      if (!_popoutPortal.isShowing) _popoutPortal.show();
    } else {
      if (_popoutPortal.isShowing) _popoutPortal.hide();
    }
  }

  /// Pinned to 16px at <=768px, the iOS anti-zoom override.
  double _inputFontSize() {
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return 16;
    }
    return ref.read(settingsProvider).textSize.toDouble();
  }

  /// Lays the draft out at the field's real content width and compares to 1.5 line heights.
  bool _draftWantsPopout() {
    final text = _controller.text;
    if (text.isEmpty) return false;
    final box = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    // Not laid out yet: keep the current state.
    if (box == null || !box.hasSize || box.size.width <= 0) return _popout;
    final fontSize = _inputFontSize();
    // With text, the right inset is the translate-button reserve.
    final hasText = text.trim().isNotEmpty;
    final contentWidth = box.size.width - 16 - (hasText ? 38 : 16) - 2;
    if (contentWidth <= 0) return _popout;
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: contentWidth);
    final expand = painter.height > painter.preferredLineHeight * 1.5;
    painter.dispose();
    return expand;
  }

  /// The `?` palette uses the PM command set only in the verified Nymbot PM.
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
        final broadcast = [
          for (final w in gtBroadcastSuggestions(ref, trigger.query))
            MentionResult(
              pubkey: '',
              nym: w,
              baseNym: w,
              suffix: '',
              status: UserStatus.offline,
              broadcastHint: w == 'here'
                  ? tr('Notify everyone in this group')
                  : tr('Notify all members'),
            ),
        ];
        return AutocompleteView.mentions([...broadcast, ...results]);
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

  /// Replaces the trigger token up to the caret and moves the caret after the insert.
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
    // The inserted trailing space closes the token.
    _onInputChanged();
  }

  /// Inserts a mention as one sentinel chip that expands to `@base#suffix` on the wire.
  void _selectMention(MentionResult m) {
    if (m.isBroadcast) {
      _replaceTriggerToken(m.insertText);
      return;
    }
    final fullNym = '${m.baseNym}#${m.suffix}';
    final ch = _controller.mentionSentinel(fullNym: fullNym, pubkey: m.pubkey);
    _replaceTriggerToken(ch != null ? '$ch ' : m.insertText);
  }

  void _completeCommand(CommandSpec spec) {
    // Inserted in the user's language; the dispatcher resolves it back.
    final name = localizedCommandToken(spec.name);
    _controller.value = TextEditingValue(
      text: '$name ',
      selection: TextSelection.collapsed(offset: name.length + 1),
    );
    _hideOverlay();
    _focus.requestFocus();
  }

  void _completeBotCommand(BotPaletteCommand cmd) {
    // Re-evaluate so a multi-step `?command` cascades into its subcommands.
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
          _selectMention(v.mentions[_selectedIndex]);
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
    unawaitedRecents(e.emoji);
  }

  void unawaitedRecents(String emoji) async {
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  /// Esc also cancels a pending edit/quote chip when no dropdown is open.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_handleFormatShortcut(event)) return KeyEventResult.handled;
    if (!_overlayActive) {
      // Enter sends; Shift+Enter, or Enter in the popout editor, inserts a newline.
      final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter;
      if (isEnter && !_popout && !HardwareKeyboard.instance.isShiftPressed) {
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
      // Only on an empty input (and not mid-edit), so arrows still move the caret in a draft.
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

  /// Wire-safety: every draft read headed for the wire must expand sentinel chars back to `:shortcode:`.
  String _draftText() => _controller.expand(_controller.text);

  void _send() {
    final typed = _draftText();
    final controller = ref.read(nostrControllerProvider);

    // Edit mode routes the send to editMessage; an empty input cancels.
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

    // Sending mid-upload would silently drop that attachment.
    if (hasPendingUploads) {
      _onSystemMessage(
          tr('Still uploading — send again once the attachments finish.'));
      return;
    }

    // Attachment URLs are appended here; failed tiles contribute nothing.
    final urls = attachmentUrls;

    // The PWA allows sending a bare quote.
    if (typed.trim().isEmpty && urls.isEmpty && _pendingQuote == null) return;
    final blocked = controller.groupSendBlockReason(typed);
    if (blocked != null) {
      _onSystemMessage(blocked);
      return;
    }

    var composed = typed;
    if (urls.isNotEmpty) {
      final needsSpace = composed.isNotEmpty && !composed.endsWith(' ');
      composed = '$composed${needsSpace ? ' ' : ''}${urls.join(' ')}';
    }
    final content = _composeOutgoing(composed);

    // `?`/@Nymbot interception and `/` commands are handled inside sendCurrent.
    controller.sendCurrent(content);
    // Recall history records the final content, quote prepend included.
    _pushSentHistory(content);
    _controller.clear();
    _attachments.clear();
    _popout = false;
    _syncPopoutPortal();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  /// Skips consecutive duplicates, caps at 50, and resets the recall cursor.
  void _pushSentHistory(String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty &&
        (_sentHistory.isEmpty || _sentHistory.last != text)) {
      _sentHistory.add(text);
      if (_sentHistory.length > 50) _sentHistory.removeAt(0);
    }
    _historyIndex = _sentHistory.length;
  }

  /// -1 is older, +1 newer; at `length` the input is the empty live draft.
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

  /// Prepends the pending quote only at send: `> @author: line`, then `> line`s and a blank line.
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

  /// Long-press send: publishes under a fresh ephemeral keypair so the message is unlinkable to the nym.
  void _sendAnon() {
    // Expand sentinels before the wire.
    final typed = _draftText();
    // An in-progress edit falls back to a normal send so it is never silently dropped.
    if (_pendingEdit != null) {
      _send();
      return;
    }
    // An anon send also clears the tiles, so it must carry their URLs.
    if (hasPendingUploads) {
      _onSystemMessage(
          tr('Still uploading — send again once the attachments finish.'));
      return;
    }
    final urls = attachmentUrls;
    if (typed.trim().isEmpty && urls.isEmpty && _pendingQuote == null) return;
    final controller = ref.read(nostrControllerProvider);
    var composed = typed;
    if (urls.isNotEmpty) {
      final needsSpace = composed.isNotEmpty && !composed.endsWith(' ');
      composed = '$composed${needsSpace ? ' ' : ''}${urls.join(' ')}';
    }
    final content = _composeOutgoing(composed);
    controller.sendCurrentPseudonymous(content);
    _pushSentHistory(content);
    _controller.clear();
    _attachments.clear();
    _popout = false;
    _syncPopoutPortal();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  void _openSendLater() {
    if (_pendingEdit != null) return;
    if (hasPendingUploads) {
      _onSystemMessage(
          tr('Still uploading — send again once the attachments finish.'));
      return;
    }
    final urls = attachmentUrls;
    var composed = _draftText();
    if (urls.isNotEmpty) {
      final needsSpace = composed.isNotEmpty && !composed.endsWith(' ');
      composed = '$composed${needsSpace ? ' ' : ''}${urls.join(' ')}';
    }
    final quote = _pendingQuote;
    final content = _composeOutgoing(composed);
    _pendingQuote = quote;
    final view = _chatView();
    final thread = ref.read(activeThreadProvider);
    final threadRoot =
        thread != null && thread.view == view ? thread.rootId : null;
    unawaited(SendLaterSheet.open(
      context,
      storageKey: view.storageKey,
      draft: content,
      threadRoot: threadRoot,
      onScheduled: () {
        if (!mounted) return;
        _pushSentHistory(content);
        _controller.clear();
        _attachments.clear();
        _pendingQuote = null;
        _popout = false;
        _syncPopoutPortal();
        _hideOverlay();
        setState(() {});
      },
    ));
  }

  /// Durable Nostr-login identities only; watches `selfPubkey` to track login/logout transitions.
  bool get _anonEligible {
    ref.watch(appStateProvider.select((s) => s.selfPubkey));
    return ref.read(nostrControllerProvider).identity?.loginMethod != null;
  }

  /// The underlying upload isn't cancellable, so a cancelled result is discarded when it resolves.
  bool _uploadCancelled = false;

  void _removeAttachment2(ComposerAttachment a) {
    setState(() => _attachments.remove(a));
  }

  void clearAttachments() {
    if (_attachments.isEmpty) return;
    setState(() => _attachments.clear());
  }

  Future<({Uint8List bytes, String type, ComposerUploadVariant variant})>
      _prepareUpload(ComposerAttachment a, Uint8List original) async {
    a.originalSize = original.length;
    if (!a.isVideo && !a.compressionTried) {
      a.compressionTried = true;
      a.compressed = await compressPhoto(original, a.contentType);
    }
    a.compressedSize = a.compressed?.length ?? original.length;
    final hd = _composerHd;
    final useCompressed = !a.isVideo && !hd && a.compressed != null;
    final body = useCompressed ? a.compressed! : original;
    final mime = useCompressed ? 'image/jpeg' : baseMime(a.contentType);
    if (!_wantOnce) {
      return (
        bytes: body,
        type: useCompressed ? 'image/jpeg' : a.contentType,
        variant: ComposerUploadVariant(hd: hd, once: false),
      );
    }
    final secret = newOnceSecret();
    final ct = await encryptOnce(body, secret.key, secret.nonce);
    return (
      bytes: ct,
      type: 'application/octet-stream',
      variant: ComposerUploadVariant(
        hd: hd,
        once: true,
        onceId: secret.onceId,
        key: secret.key,
        nonce: secret.nonce,
        mime: mime,
        size: body.length,
      ),
    );
  }

  /// Never throws: a failure marks only that tile retryable.
  Future<void> _uploadAttachment(ComposerAttachment a) async {
    final bytes = a.bytes;
    if (bytes == null || bytes.isEmpty) return;
    if (mounted) {
      setState(() {
        a.status = ComposerAttachmentStatus.uploading;
        a.error = '';
      });
    }
    String? url;
    ComposerUploadVariant? variant;
    try {
      final prepared = await _prepareUpload(a, bytes);
      variant = prepared.variant;
      if (mounted) setState(() {});
      url = await ref
          .read(nostrControllerProvider)
          .uploadImage(prepared.bytes, contentType: prepared.type);
    } catch (e) {
      url = null;
      a.error = e.toString();
    }
    if (!mounted) return;
    if (_uploadCancelled) return;
    setState(() {
      if (url == null || url.isEmpty) {
        a.status = ComposerAttachmentStatus.failed;
        if (a.error.isEmpty) a.error = tr('Failed to upload media.');
        if (a.error.length > 120) a.error = a.error.substring(0, 120);
      } else {
        a.status = ComposerAttachmentStatus.done;
        a.url = url;
        a.error = '';
        a.uploadedAs = variant;
        // Reuse the uploaded bytes so the thumbnail doesn't flicker or re-fetch.
        if (!a.isVideo) _localMediaPreviews[url] = bytes;
        _uploadedMedia[url] = a.isVideo;
      }
    });
    if (_attachmentStale(a)) _retryAttachment(a);
  }

  Future<void> _retryAttachment(ComposerAttachment a) async {
    if (a.status == ComposerAttachmentStatus.uploading) return;
    _uploadCancelled = false;
    await _uploadAttachment(a);
  }

  /// Picks one or more media and uploads each to Blossom.
  Future<void> _pickAndUploadImage({List<XFile>? preselected}) async {
    List<XFile> picked;
    if (preselected != null) {
      picked = preselected;
    } else {
      try {
        final picker = ImagePicker();
        picked = await picker.pickMultipleMedia();
      } catch (_) {
        return; // Picker unavailable (tests/desktop).
      }
    }
    if (picked.isEmpty) return;

    // Mesh view has no Blossom server, so send the media over the mesh as a file.
    final meshBridge = ref.read(meshControllerProvider.notifier).bridge;
    final view = ref.read(appStateProvider).view;
    if (meshBridge != null && meshBridge.shouldSendOverMesh(view)) {
      for (final f in picked) {
        Uint8List bytes;
        try {
          bytes = await f.readAsBytes();
        } catch (_) {
          continue;
        }
        if (bytes.isEmpty) continue;
        final mime = f.mimeType ?? _guessImageMime(f.name);
        if (!_composerHd && compressibleImageMime(mime)) {
          final small = await compressPhoto(bytes, mime,
              maxDimension: MediaNoteLimits.meshPhotoMaxDimension,
              quality: MediaNoteLimits.meshPhotoQuality);
          if (small != null) bytes = small;
        }
        final sendMime =
            compressibleImageMime(mime) && !_composerHd ? 'image/jpeg' : mime;
        final ok = meshSizeCheck(bytes.length).ok &&
            await meshBridge.sendFileFromComposer(view, f.name, sendMime, bytes);
        if (!ok) {
          _onSystemMessage(tr(MediaNoteReasons.meshTooLarge,
              {'size': formatBytes(bytes.length)}));
        }
      }
      return;
    }
    const maxUpload = 50 * 1024 * 1024;

    if (!mounted) return;
    _uploadCancelled = false;

    // Each picked file becomes its own tile with its own progress wheel.
    final fresh = <ComposerAttachment>[];
    for (final f in picked) {
      Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        continue;
      }
      if (bytes.length > maxUpload) {
        _onSystemMessage(tr('Files must be under 50MB.'));
        continue;
      }
      final contentType = f.mimeType ?? _guessImageMime(f.name);
      final isVideo = contentType.startsWith('video/');
      fresh.add(ComposerAttachment(
        id: ++_attachmentSeq,
        isVideo: isVideo,
        contentType: contentType,
        // Kept for retry even though the tile can't draw a video frame.
        bytes: bytes,
      ));
    }
    if (fresh.isEmpty || !mounted) return;
    setState(() => _attachments.addAll(fresh));

    for (final a in fresh) {
      if (!mounted || _uploadCancelled) break;
      await _uploadAttachment(a);
    }
    if (mounted) _focus.requestFocus();
  }


  Future<void> _pickAndShareFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(withData: true);
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _onSystemMessage(tr('Could not read the selected file.'));
      return;
    }
    // Mesh view sends the file directly over the mesh.
    final meshBridge = ref.read(meshControllerProvider.notifier).bridge;
    final view = ref.read(appStateProvider).view;
    if (meshBridge != null && meshBridge.shouldSendOverMesh(view)) {
      final ok = meshSizeCheck(bytes.length).ok &&
          await meshBridge.sendFileFromComposer(
              view, file.name, _guessImageMime(file.name), bytes);
      if (!ok) {
        _onSystemMessage(tr(MediaNoteReasons.meshTooLarge,
            {'size': formatBytes(bytes.length)}));
      }
      return;
    }
    await ref.read(nostrControllerProvider).shareP2PFile(
          bytes: bytes,
          name: file.name,
          type: _guessImageMime(file.name),
        );
    if (mounted) _onSystemMessage(tr('File offered for P2P download.'));
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
    // Send is gated on connection, not input content; empty-input guards live in the send paths.
    final sendEnabled = ref.watch(
          appStateProvider.select((s) => s.connectedRelays > 0),
        ) ||
        ref.read(nostrControllerProvider).isLive;

    _customEmojis = ref.watch(liveCustomEmojiProvider);
    // Lets the controller resolve sentinel chars to emoji images and recognize real `:code:`s.
    _controller.codeToUrl = _customEmojis.codeToUrl;

    ref.listen(pendingComposerActionProvider, (_, action) {
      if (action == null) return;
      _applyComposerAction(action);
      ref.read(pendingComposerActionProvider.notifier).consume();
    });
    ref.listen(pendingEditProvider, (_, edit) {
      if (edit == null) return;
      if (!DmPollsService.blocksEdit(_chatView(), edit.content)) {
        _applyEdit(edit);
      }
      ref.read(pendingEditProvider.notifier).consume();
    });
    ref.listen(currentViewProvider, (prev, next) {
      if (prev == next) return;
      _onViewSwitched(next);
    });

    final input = _inputWithChips(context, sendEnabled);
    // `compact` spans <=1024, so the phone padding keys off the real 768px width.
    final width = MediaQuery.of(context).size.width;
    final phone = width <= NymDimens.mobileBreakpoint;
    final gap = phone ? 6.0 : (width <= NymDimens.tabletBreakpoint ? 8.0 : 10.0);

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
            ScheduledBar(
                storageKey: ref.watch(
                    currentViewProvider.select((v) => v.storageKey))),
            OverlayPortal(
              controller: _emojiPortal,
              overlayChildBuilder: _pickerOverlay,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _attachButton(),
                  SizedBox(width: gap),
                  Expanded(child: input),
                  SizedBox(width: gap),
                  _primaryButton(sendEnabled, phone),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The chip slot is always present (collapsing to 0) so toggling never re-parents the TextField.
  Widget _inputWithChips(BuildContext context, bool inputEnabled) {
    final block = _popout ? null : _chipBlock();
    // Panels ride into the overlay with the chip while the field floats, or the toolbar hides behind it.
    final panels = _popout ? null : _formatPanels(context);
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
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomLeft,
          child: panels ?? const SizedBox(height: 0, width: double.infinity),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: ref.read(mediaNoteSenderProvider).sending,
          builder: (context, label, _) => label == null
              ? const SizedBox.shrink()
              : Padding(
                  key: const ValueKey('noteSending'),
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Text(label,
                          style: TextStyle(
                              color: context.nym.textDim, fontSize: 12)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          color: context.nym.primary,
                          backgroundColor: context.nym.glassBorder,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const GtSlowmodeBar(),
        Stack(
          clipBehavior: Clip.none,
          children: [
            _input(context, inputEnabled),
            if (_voice != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VoiceRecordBar(
                  controller: _voice!,
                  onCancel: () => _stopVoice(false),
                  onSend: () => _stopVoice(true),
                  onToggleOnce: () {
                    final st = _mediaFeature('once');
                    if (st.level == MediaFeatureLevel.off) {
                      _onSystemMessage(tr(st.reason));
                      return;
                    }
                    _voice?.toggleOnce();
                  },
                  onceAllowed:
                      _mediaFeature('once').level != MediaFeatureLevel.off,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget? _chipBlock() {
    // Top corners square off when a popup is stacked above.
    final chip = _pendingEdit != null
        ? _EditPreviewChip(
            text: _quotePreviewText(_pendingEdit!.content),
            onClose: _cancelEdit,
            squareTop: _overlayActive,
          )
        : (_pendingQuote != null
            ? _QuotePreviewChip(
                author: _pendingQuote!.author,
                // Snippet from the full original content, not the stripped send text.
                text: _quotePreviewText(_pendingQuote!.fullText),
                onClose: _clearQuote,
                squareTop: _overlayActive,
              )
            : null);
    if (chip == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // Keyed on chip kind so a kind change replays the slide-in.
      child: _ChipSlideIn(
        key: ValueKey(_pendingEdit != null ? 'edit' : 'quote'),
        // Measures the chip alone; the 8px gap is added in the offset.
        child: KeyedSubtree(key: _chipKey, child: chip),
      ),
    );
  }


  /// In-flow height reserved while the popout floats (single text row plus padding).
  static const double _composerRowBase = 42;

  /// When popped out, the field floats in a portal over the messages while the slot keeps the base row height.
  Widget _input(BuildContext context, bool inputEnabled) {
    final focus = Focus(
      onKeyEvent: _onKey,
      child: _textField(context, inputEnabled),
    );
    // Nested portals paint above the popout; translate must live in the main tree or it never builds in popout.
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
            // The [_fieldKey] GlobalKey reparents the same element, so the flip never closes the keyboard.
            child: _popout
                ? const SizedBox(
                    height: _composerRowBase, width: double.infinity)
                : focus,
          ),
        ),
      ),
    );
  }

  /// Floating popout field capped at `min(40vh,360)`; a pending chip rides above it.
  Widget _popoutOverlay(BuildContext context, Widget field) {
    if (!_popout) return const SizedBox.shrink();
    final chipBlock = _chipBlock();
    final panels = _formatPanels(context);
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
                ?chipBlock,
                ?panels,
                // Wraps only the field so the offset measures its growth past the base row.
                SizedBox(key: _popoutFieldKey, child: field),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The anchored command palette or autocomplete dropdown above the input.
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
                onSelectMention: _selectMention,
                onSelectChannel: (ch) => _replaceTriggerToken(ch.insertText),
                onSelectEmoji: _onEmojiAutocompletePicked,
                onSelectKaomoji: (k) =>
                    _replaceTriggerToken(kaomojiInsertText(k)),
              );
    // Lift the dropdown by the popout overhang and chip height, or it paints under the field or over the chip.
    final overhang = _popout
        ? math.max(0.0, _boxHeight(_popoutFieldKey) - _composerRowBase)
        : 0.0;
    final chipH = _boxHeight(_chipKey);
    // The panel stack sits outside the `_acAnchor` target, so its height must be added too.
    final panelsH = _boxHeight(_panelsKey);
    final acOffset = overhang + panelsH + (chipH > 0 ? chipH + 8 : 0);
    _acOffsetUsed = acOffset;
    _settleOverlayOffset();
    return CompositedTransformFollower(
      link: _acAnchor,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      // Negative Y lifts the follower above the anchor.
      offset: Offset(0, -acOffset),
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Material(
          type: MaterialType.transparency,
          // Same group as the field, so tapping a row isn't an outside tap that dismisses first.
          child: TapRegion(
            groupId: _acGroupId,
            child: SizedBox(
              width: _anchorWidth(context),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  /// Measured via [_inputKey], since the overlay context is full-screen.
  double _anchorWidth(BuildContext context) {
    final box = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size.width ?? MediaQuery.sizeOf(context).width;
  }

  double _boxHeight(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return (box != null && box.hasSize) ? box.size.height : 0;
  }

  /// The offset is measured during build, so re-measure after the frame until the panel height settles.
  void _settleOverlayOffset() {
    if (_offsetSettleQueued) return;
    _offsetSettleQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _offsetSettleQueued = false;
      if (!mounted || !_acPortal.isShowing) return;
      final overhang = _popout
          ? math.max(0.0, _boxHeight(_popoutFieldKey) - _composerRowBase)
          : 0.0;
      final chipH = _boxHeight(_chipKey);
      final settled =
          overhang + _boxHeight(_panelsKey) + (chipH > 0 ? chipH + 8 : 0);
      if ((settled - _acOffsetUsed).abs() > 0.5) setState(() {});
    });
  }

  bool _offsetSettleQueued = false;

  /// The badge tooltip distinguishes developer from bot.
  MentionBadges _mentionBadges(String pubkey) {
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = controller.isVerifiedBot(pubkey);
    final friend = ref.read(appStateProvider).isFriend(pubkey);
    return (
      verified: isDev || isBot,
      friend: friend,
      verifiedTitle:
          isDev ? tr('Nymchat Developer') : (isBot ? tr('Nymchat Bot') : null),
    );
  }

  /// The message input with its inline translate/format buttons; tall drafts get the popout treatment.
  Widget _textField(BuildContext context, bool inputEnabled) {
    final c = context.nym;
    final hasText = _controller.text.trim().isNotEmpty;
    final focused = _focus.hasFocus;
    // Watch so a text-size change re-renders the field live.
    ref.watch(settingsProvider.select((s) => s.textSize));
    final fontSize = _inputFontSize();
    // Flat field caps at 160px (about 140px of text at 1.4 line height).
    final flatMaxLines = math.max(1, 140 ~/ (fontSize * 1.4));
    // Bound the popout by the space actually available above the composer, not 40% of the full screen.
    final mq = MediaQuery.of(context);
    final available = mq.size.height -
        mq.padding.top -
        mq.viewInsets.bottom -
        _composerRowBase -
        8;
    final popoutMaxHeight = math.max(
      _composerRowBase,
      math.min(math.min(mq.size.height * 0.4, 360.0), available),
    );
    // Grow to fill that box and no further.
    final popoutLineHeight = mq.textScaler.scale(fontSize) * 1.5;
    final popoutMaxLines = math.max(
      3,
      ((popoutMaxHeight - 20) / popoutLineHeight).floor(),
    );
    final flatFill = c.isLight
        ? Colors.black.withValues(alpha: focused ? 0.02 : 0.04)
        : Colors.white.withValues(alpha: focused ? 0.07 : 0.05);
    final fill = _popout ? c.bgTertiary : flatFill;
    // Bottom corners only: the field grows out of the one-line input.
    const radius = BorderRadius.vertical(bottom: Radius.circular(NymRadius.md));
    final border = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: _popout ? c.primaryA(0.30) : c.glassBorder),
    );
    // Custom emoji render inline via single PUA sentinel chars painted as images; see [EmojiSentinelController].
    final incog = ref.watch(incognitoFieldFlagsProvider);
    final field = TextField(
      // Reparent rather than remount across the popout flip, or the keyboard closes.
      key: _fieldKey,
      controller: _controller,
      focusNode: _focus,
      enableIMEPersonalizedLearning: incog.imeLearning,
      autocorrect: incog.autocorrect,
      enableSuggestions: incog.suggestions,
      // Taps outside both the field and its dropdown close the dropdown.
      groupId: _acGroupId,
      onTapOutside: (_) {
        if (_overlayActive) _hideOverlay();
      },
      // Typable iff SEND is enabled (after connect).
      enabled: inputEnabled,
      maxLines: _popout ? popoutMaxLines : flatMaxLines,
      minLines: 1,
      scrollController: _fieldScroll,
      textInputAction: TextInputAction.newline,
      // Deletes a hidden markdown marker as a whole rather than one invisible char at a time.
      inputFormatters: const [RichMarkerDeleteFormatter()],
      onChanged: (_) {
        _onInputChanged();
        // `sendTypingStart` self-throttles and gates itself, so calling it per keystroke is safe.
        final meshBridge = ref.read(meshControllerProvider.notifier).bridge;
        final view = ref.read(appStateProvider).view;
        if (meshBridge != null && meshBridge.shouldSendOverMesh(view)) {
          // Throttle mesh typing to ~1/s so we don't flood the radio.
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastMeshTypingMs >= 1000) {
            _lastMeshTypingMs = now;
            meshBridge.sendTyping(view, true);
          }
        } else {
          ref.read(nostrControllerProvider).sendTypingStart();
        }
      },
      style: TextStyle(
        // Input text is forced pure white (dark) or black (light), not `--text`.
        color: c.isLight ? Colors.black : Colors.white,
        fontSize: fontSize,
      ),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        isDense: true,
        // Inside an open thread the composer replies into it, so the placeholder says so.
        hintText: ref.watch(activeThreadProvider) != null
            ? tr('Reply in thread...')
            : tr('Message, / for commands, ? for Nymbot...'),
        // One line with ellipsis, or longer translated hints wrap and push the buttons down.
        hintMaxLines: 1,
        hintStyle: TextStyle(
            color: (c.isLight ? Colors.black : Colors.white)
                .withValues(alpha: 0.4),
            fontSize: fontSize),
        filled: true,
        fillColor: fill,
        contentPadding: EdgeInsets.fromLTRB(16, 10, hasText ? 94 : 66, 10),
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
        // The translate button joins the row only when the field has text.
        Positioned(
          right: 8,
          bottom: 10,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CompositedTransformTarget(
                link: _emojiAnchor,
                child: EmojiInputButton(
                  key: const ValueKey('emojiInputBtn'),
                  enabled: inputEnabled,
                  open: _emojiPortal.isShowing,
                  onTap: _toggleEmojiPicker,
                ),
              ),
              const SizedBox(width: 2),
              FormatInputButton(
                active: _formatToolbarOpen,
                enabled: inputEnabled,
                onTap: _toggleFormatToolbar,
              ),
              if (hasText) const SizedBox(width: 2),
              if (hasText) _translateButton(context),
            ],
          ),
        ),
      ],
    );
    if (!inputEnabled) {
      stack = MouseRegion(
        cursor: SystemMouseCursors.forbidden,
        child: Opacity(opacity: 0.55, child: stack),
      );
    }

    if (!_popout) {
      // Always rendered, toggling only `show`, so focusing never re-parents the TextField and drops the keyboard.
      return CssFocusRing(
        show: focused,
        color: c.primaryA(0.06),
        radius: radius,
        child: stack,
      );
    }
    return Container(
      constraints: BoxConstraints(maxHeight: popoutMaxHeight),
      decoration: const BoxDecoration(
        borderRadius: NymRadius.rmd,
        boxShadow: [
          BoxShadow(
              color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: Scrollbar(
        controller: _fieldScroll,
        thumbVisibility: true,
        child: stack,
      ),
    );
  }

  /// Hosts the [_translateAnchor] leader for the dropdown portal in [_input].
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

  /// Remembered so the toolbar stays on between sessions.
  Future<void> _toggleFormatToolbar() async {
    // Resolve prefs before flipping, or first-tap hydration snaps the toolbar shut again.
    final prefs = await _ensurePrefs();
    if (!mounted) return;
    setState(() => _formatToolbarOpen = !_formatToolbarOpen);
    await prefs.setBool(kFormatToolbarKey, _formatToolbarOpen);
  }

  /// Operates on the raw text: each emoji is one sentinel char, so selection offsets line up.
  Future<void> _pickTimestamp() async {
    final sel = _controller.selection;
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(1970),
      lastDate: DateTime(now.year + 100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !mounted) return;
    final picked =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final text = _controller.text;
    final out = insertTimestampTag(
        FormatEdit(text, sel.start, sel.end),
        (picked.millisecondsSinceEpoch / 1000).floor());
    _controller.value = TextEditingValue(
      text: out.text,
      selection: TextSelection.collapsed(offset: out.start),
    );
    _onInputChanged();
    _focus.requestFocus();
  }

  bool _handleFormatShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!(keyboard.isControlPressed || keyboard.isMetaPressed) ||
        keyboard.isAltPressed) {
      return false;
    }
    final label = event.logicalKey.keyLabel;
    if (label.length != 1) return false;
    final tool =
        formatToolForShortcut(label, shift: keyboard.isShiftPressed);
    if (tool == null) return false;
    _applyFormatTool(tool);
    return true;
  }

  void _applyFormatTool(FormatTool tool) {
    if (tool.kind == FormatToolKind.picker) {
      unawaited(_pickTimestamp());
      return;
    }
    final sel = _controller.selection;
    final text = _controller.text;
    // A never-focused field reports -1; treat it as the end of the draft.
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final out = applyFormatTool(FormatEdit(text, start, end), tool);
    _controller.value = TextEditingValue(
      text: out.text,
      selection: TextSelection(baseOffset: out.start, extentOffset: out.end),
    );
    _onInputChanged();
    _focus.requestFocus();
  }

  void _removeAttachment(int index) {
    final out = removeComposerMedia(_controller.text, index,
        knownMedia: _uploadedMedia);
    _controller.value = TextEditingValue(
      text: out.text,
      selection: TextSelection.collapsed(offset: out.start),
    );
    _onInputChanged();
    _focus.requestFocus();
  }

  /// Attachments, upload bar and toolbar between the chip and field; null when empty.
  Widget? _formatPanels(BuildContext context) {
    final matches =
        composerMediaMatches(_controller.text, knownMedia: _uploadedMedia);
    final panels = <Widget>[];

    // Each layer squares its top corners when any layer is stacked above it.
    final chipShowing = _pendingEdit != null || _pendingQuote != null;
    final stripShowing = matches.isNotEmpty || _attachments.isNotEmpty;

    if (_attachments.isEmpty) {
      _composerHd = false;
      _composerOnce = false;
    } else {
      panels.add(MediaOptionsBar(
        attachments: _attachments,
        hd: _composerHd,
        once: _composerOnce,
        hdState: _mediaFeature('hd'),
        onceState: _mediaFeature('once'),
        onToggleHd: _toggleComposerHd,
        onToggleOnce: _toggleComposerOnce,
      ));
    }

    // The strip goes first so each preview sits above its own progress.
    if (stripShowing) {
      panels.add(ComposerMediaStrip(
        squareTop: _overlayActive || chipShowing,
        matches: matches,
        attachments: _attachments,
        onRemoveAttachment: _removeAttachment2,
        onRetry: _retryAttachment,
        localPreviews: _localMediaPreviews,
        onRemove: _removeAttachment,
        onOpen: (m) {
          // Only stills open fullscreen; the video viewer needs an inline player's controller.
          if (m.isVideo) return;
          final images = matches.where((e) => !e.isVideo).toList();
          final idx = images.indexWhere((e) => e.start == m.start);
          openFullscreenMedia(
            context,
            images.map((e) => proxiedMedia(e.url)).toList(),
            idx < 0 ? 0 : idx,
          );
        },
      ));
    }

    if (_formatToolbarOpen) {
      panels.add(FormatToolbar(
        onTool: _applyFormatTool,
        squareTop: _overlayActive || chipShowing || stripShowing,
      ));
    }

    if (panels.isEmpty) return null;
    // Only one instance is mounted at a time, in flow or in the popout.
    return KeyedSubtree(
      key: _panelsKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < panels.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == panels.length - 1 ? 8 : 4),
              child: panels[i],
            ),
        ],
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
    // Re-read favorites on every open so changes from elsewhere aren't stale.
    final prefs = await _ensurePrefs();
    if (!mounted) return;
    setState(() {
      _translateFavorites = _loadTranslateFavorites(prefs);
      _translateQuery = '';
      _translateLangOrder =
          sortedTranslateLanguagesWithFavorites(_translateFavorites);
    });
    _translateSearchController.clear();
    _translatePortal.show();
  }

  Widget _translateDropdown(BuildContext context) {
    final c = context.nym;
    final q = _translateQuery.trim().toLowerCase();
    // Star fill is live; row order uses the open-time snapshot.
    final favSet = _translateFavorites.toSet();
    final order = _translateLangOrder.isEmpty
        ? sortedTranslateLanguagesWithFavorites(_translateFavorites)
        : _translateLangOrder;
    final langs = order
        .where((e) => q.isEmpty || languageSearchKey(e.key, e.value).contains(q))
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
                  color: c.isLight
                      ? Colors.white.withValues(alpha: 0.98)
                      : c.bgSecondary,
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
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border:
                            Border(bottom: BorderSide(color: c.glassBorder)),
                      ),
                      // Not autofocused: grabbing focus would pull the IME away from the message input.
                      child: TextField(
                        controller: _translateSearchController,
                        onChanged: (v) => setState(() => _translateQuery = v),
                        style: TextStyle(color: c.inputText, fontSize: 13),
                        cursorColor: c.isLight ? Colors.black : Colors.white,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: tr('Search languages...'),
                          hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                          filled: true,
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
                      child: langs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text(tr('No languages found'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13)),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: langs.length,
                              itemBuilder: (_, i) {
                                final e = langs[i];
                                return _TranslateLangRow(
                                  name: languageNative(e.key),
                                  subtitle: languageSubtitle(e.key),
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

  /// Replaces the input with the translation; quote/edit chips are preserved.
  Future<void> _translateDraft(String targetLang) async {
    _translatePortal.hide();
    // Expand sentinels before the external service sees the draft.
    final text = _draftText().trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);
    try {
      final res = await TranslateService().translate(text, targetLang);
      if (!mounted) return;
      final out = res.translatedText;
      // Keep the input when the result is empty or echoes the original.
      if (out.trim().isEmpty || out.trim() == text) {
        _onSystemMessage(tr(
            'Nothing to translate (text may already be in the target language).'));
        return;
      }
      _controller.text = out;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    } catch (e) {
      // [TranslateException.message] already carries the "Translation failed:" prefix.
      if (mounted) {
        _onSystemMessage(e is TranslateException
            ? e.message
            : tr('Translation failed: Unknown error'));
      }
    } finally {
      if (mounted) {
        setState(() => _translating = false);
        _onInputChanged();
      }
    }
  }

  Widget _attachButton() {
    return _IconBtn(
      key: _attachKey,
      svg: ComposerIcons.plus,
      tooltip: tr('Attach'),
      onTap: () => unawaited(_openAttachMenu()),
    );
  }

  List<AttachItem> _attachModel() {
    final view = _chatView();
    final round = _mediaFeature('round');
    return attachItems(
      surface: mediaSurface(view),
      route: _currentMediaRoute(view),
      round: RoundState(round.state, round.reason),
      bot: _isBotDm(view),
    );
  }

  Future<void> _openAttachMenu() async {
    if (_emojiPortal.isShowing) _hideEmojiPicker();
    final items = _attachModel();
    final id = await showComposerMenu(
      context,
      kind: 'attach',
      label: tr('Attach'),
      entries: [for (final it in items) ComposerMenuEntry.attach(it)],
      anchor: globalRectOf(_attachKey),
    );
    if (id == null || !mounted) return;
    final fresh = _attachModel();
    final item = fresh.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    if (!item.enabled) {
      if (item.detail.isNotEmpty) _onSystemMessage(tr(item.detail));
      return;
    }
    _runAttach(id);
  }

  bool _isBotDm(ChatView view) =>
      view.kind == ViewKind.pm &&
      ref.read(nostrControllerProvider).isVerifiedBot(view.id);

  void _openPoll() {
    if (!mounted) return;
    final view = _chatView();
    final refused = ref.read(dmPollsProvider).refusal(view);
    if (refused.isNotEmpty) {
      _onSystemMessage(refused);
      return;
    }
    if (pollAllowedOn(mediaSurface(view), bot: _isBotDm(view))) {
      PollCreateModal.open(context);
    }
  }

  bool get _canUpload =>
      ref.read(appStateProvider).connectedRelays > 0 ||
      ref.read(nostrControllerProvider).isLive;

  void _runAttach(String id) {
    final view = _chatView();
    final route = _currentMediaRoute(view);
    switch (id) {
      case 'photo':
        if (hasPendingUploads) return;
        if (!_canUpload && route != 'mesh') {
          _onSystemMessage(tr(MediaNoteReasons.hdOffline));
          return;
        }
        unawaited(_pickAndUploadImage());
      case 'file':
        if (!_canUpload && route != 'mesh') {
          _onSystemMessage(tr(MediaNoteReasons.hdOffline));
          return;
        }
        unawaited(_pickAndShareFile());
      case 'location':
        if (view.kind == ViewKind.channel) return;
        showGtShareLocation(context,
            view.kind == ViewKind.group ? GtChat.group(view.id) : GtChat.dm(view.id));
      case 'videoNote':
        unawaited(_openVideoNote());
      case 'poll':
        _openPoll();
      case 'event':
        if (view.kind == ViewKind.group) {
          unawaited(showGtCreateEvent(context, view.id));
        }
    }
  }

  Future<void> _openSendMenu() async {
    final id = await showComposerMenu(
      context,
      kind: 'send',
      label: tr('Send options'),
      entries: [
        for (final it in sendMenuItems(canAnon: _anonEligible))
          ComposerMenuEntry.send(it),
      ],
      anchor: globalRectOf(_sendSplitKey),
    );
    if (id == null || !mounted) return;
    if (id == 'later') _openSendLater();
    if (id == 'anon' && _anonEligible) _sendAnon();
  }

  Widget _primaryButton(bool sendEnabled, bool phone) {
    final action = primaryAction(
      text: _controller.text,
      attachments: _attachments.length,
      editing: _pendingEdit != null,
      recording: _voice != null,
    );
    if (action == 'mic') return _micButton();
    return _SendButton(
      key: _sendSplitKey,
      enabled: sendEnabled,
      onTap: _send,
      onMenu: () => unawaited(_openSendMenu()),
      phone: phone,
    );
  }

  ChatView _chatView() => ref.read(appStateProvider).view;

  String _mediaTooltip(String label, MediaFeatureState st) =>
      st.reason.isEmpty ? tr(label) : '${tr(label)} — ${tr(st.reason)}';

  Widget _micButton() {
    final st = _mediaFeature('voice');
    return VoiceMicGesture(
      key: const ValueKey('voiceRecordBtn'),
      recording: () => _voice != null,
      onStart: _startVoice,
      onLock: _lockVoice,
      onCancel: () => _stopVoice(false),
      onRelease: () => _stopVoice(true),
      onDrag: (dx) => _voice?.drag(dx),
      child: _IconBtn(
        svg: NymIcons.composerMic,
        tooltip: _mediaTooltip('Voice message', st),
        enabled: st.level != MediaFeatureLevel.off,
        active: _voice != null,
        warn: st.level == MediaFeatureLevel.warn,
        onTap: () {},
      ),
    );
  }

  Widget _pickerOverlay(BuildContext context) {
    final tabs = PickerTabs(active: _pickerTab, onSelect: _switchPickerTab);
    final gif = _pickerTab == 'gif' && _prefs != null;
    return _popover(
      link: _emojiAnchor,
      onDismiss: _hideEmojiPicker,
      phoneWidthFactor: gif ? 0.9 : null,
      child: gif
          ? GifPicker(
              key: const ValueKey('gifPicker'),
              favoritesStore: FavoriteGifsStore(_prefs!),
              onSelect: _onGifSelected,
              onClose: _hideEmojiPicker,
              tabs: tabs,
            )
          : EmojiPicker(
              key: const ValueKey('emojiPicker'),
              recents: _recents,
              onSelect: _onEmojiSelected,
              onClose: _hideEmojiPicker,
              tabs: tabs,
            ),
    );
  }

  /// Picker above its anchor with a tap-out barrier; [phoneWidthFactor] sets a viewport fraction on phones.
  Widget _popover({
    required LayerLink link,
    required VoidCallback onDismiss,
    required Widget child,
    double? phoneWidthFactor,
  }) {
    final media = MediaQuery.of(context);
    // Phones center the picker above the input bar instead of anchoring to the button.
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
            // Lifted above the keyboard when open.
            bottom: 60 + media.viewInsets.bottom,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: phoneWidthFactor != null
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

class _IconBtn extends StatefulWidget {
  const _IconBtn({
    super.key,
    required this.svg,
    required this.tooltip,
    this.enabled = true,
    this.onTap,
    this.active = false,
    this.warn = false,
  });

  final bool active;
  final bool warn;

  final String svg;
  final String tooltip;

  /// False dims and disables the button; the composer gates it on relay connection.
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
    final hovered = enabled && _hover;
    // Same `.icon-btn` chrome as the header pills; SVG strokes stay `--text` at rest even in light mode.
    final Color fill;
    final Color borderColor;
    if (c.isLight) {
      fill = hovered
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.03);
      borderColor = hovered ? c.primary : Colors.black.withValues(alpha: 0.1);
    } else {
      fill = hovered ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05);
      borderColor = hovered ? c.primaryA(0.30) : c.glassBorder;
    }
    final glyphColor = widget.active
        ? c.danger
        : (widget.warn ? c.warning : (hovered ? c.primary : c.text));
    final btn = Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => setState(() => _hover = true) : null,
        onExit: enabled ? (_) => setState(() => _hover = false) : null,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: widget.active ? c.danger : borderColor),
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
                child: NymSvgIcon(
                  widget.svg,
                  size: 18,
                  color: glyphColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (enabled) return btn;
    return Opacity(opacity: 0.35, child: btn);
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({
    super.key,
    required this.enabled,
    required this.onTap,
    required this.onMenu,
    this.phone = false,
  });
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  final bool phone;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hover = false;
  bool _chevronHover = false;

  Timer? _holdTimer;
  bool _menuFired = false;
  DateTime _suppressClickUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _openMenu() {
    _menuFired = true;
    _suppressClickUntil = DateTime.now().add(const Duration(milliseconds: 800));
    HapticFeedback.mediumImpact();
    widget.onMenu();
  }

  void _startHold(PointerDownEvent e) {
    if (!widget.enabled || _holdTimer != null) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _menuFired = false;
    _holdTimer = Timer(const Duration(milliseconds: 500), () {
      _holdTimer = null;
      if (!mounted) return;
      _openMenu();
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _maybeCancelOnExit(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse || _holdTimer == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if (!(Offset.zero & box.size).contains(box.globalToLocal(e.position))) {
      _cancelHold();
    }
  }

  void _handleTap() {
    if (_menuFired || DateTime.now().isBefore(_suppressClickUntil)) {
      _menuFired = false;
      return;
    }
    if (widget.enabled) widget.onTap();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || !widget.enabled) return KeyEventResult.ignored;
    final key = e.logicalKey == LogicalKeyboardKey.contextMenu
        ? 'ContextMenu'
        : (e.logicalKey == LogicalKeyboardKey.f10 ? 'F10' : '');
    if (!isMenuKey(key, shift: HardwareKeyboard.instance.isShiftPressed)) {
      return KeyEventResult.ignored;
    }
    widget.onMenu();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hovering = _hover && widget.enabled;
    final List<BoxShadow>? glow = hovering
        ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
        : null;
    const left = BorderRadius.horizontal(left: Radius.circular(NymRadius.sm));
    const right = BorderRadius.horizontal(right: Radius.circular(NymRadius.sm));
    final send = MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapUp: widget.enabled
            ? (_) {
                _cancelHold();
                _openMenu();
              }
            : null,
        child: Listener(
          onPointerDown: _startHold,
          onPointerMove: _maybeCancelOnExit,
          onPointerUp: (_) => _cancelHold(),
          onPointerCancel: (_) => _cancelHold(),
          child: AnimatedContainer(
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            decoration: BoxDecoration(
              color: c.primaryA(hovering ? 0.18 : 0.10),
              borderRadius: left,
              border: Border.all(color: c.primaryA(0.30)),
              boxShadow: glow,
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: left,
              child: Focus(
                onKeyEvent: _onKey,
                skipTraversal: true,
                child: InkWell(
                  key: const ValueKey('composer-send'),
                  onTap: widget.enabled ? _handleTap : null,
                  borderRadius: left,
                  child: Container(
                    height: 42,
                    padding: EdgeInsets.symmetric(
                        horizontal: widget.phone ? 14 : 22),
                    alignment: Alignment.center,
                    child: Text(
                      tr('SEND'),
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
      ),
    );
    final chevron = Tooltip(
      message: tr('More send options'),
      child: MouseRegion(
        onEnter: (_) => setState(() => _chevronHover = true),
        onExit: (_) => setState(() => _chevronHover = false),
        child: Container(
          decoration: BoxDecoration(
            color: c.primaryA(_chevronHover && widget.enabled ? 0.18 : 0.10),
            borderRadius: right,
            border: Border(
              top: BorderSide(color: c.primaryA(0.30)),
              right: BorderSide(color: c.primaryA(0.30)),
              bottom: BorderSide(color: c.primaryA(0.30)),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: right,
            child: InkWell(
              key: const ValueKey('sendMenuBtn'),
              onTap: widget.enabled ? widget.onMenu : null,
              borderRadius: right,
              child: SizedBox(
                width: 24,
                height: 42,
                child: Center(
                  child: NymSvgIcon(ComposerIcons.chevronUp,
                      size: 14, color: c.primary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Opacity(
      opacity: widget.enabled ? 1 : 0.35,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [send, chevron],
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({
    required this.barColor,
    required this.content,
    required this.onClose,
    required this.closeTooltip,
    this.squareTop = false,
  });

  final Color barColor;
  final Widget content;
  final VoidCallback onClose;
  final String closeTooltip;

  final bool squareTop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: squareTop ? 0 : NymRadius.md),
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      builder: (context, topRadius, child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          // Solid-ui light plate differs from the light bg-tertiary token, so it is set explicitly.
          color:
              c.solidUi && c.isLight ? const Color(0xFFECECEA) : c.bgTertiary,
          border: Border.all(color: c.glassBorder),
          borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
          boxShadow: [
            BoxShadow(
              color:
                  c.isLight ? const Color(0x1F000000) : const Color(0x80000000),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
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
          _ChipCloseButton(tooltip: closeTooltip, onTap: onClose),
        ],
      ),
    );
  }
}

/// Slide-in replayed on each (re)mount.
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

/// Quote chip: author with avatar and flair over the truncated quoted text.
class _QuotePreviewChip extends ConsumerWidget {
  const _QuotePreviewChip({
    required this.author,
    required this.text,
    required this.onClose,
    this.squareTop = false,
  });

  final String author;
  final String text;
  final VoidCallback onClose;
  final bool squareTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final split = splitNymSuffix(author);
    final base = split.base;
    final suffix = split.suffix;
    // Unresolved authors render plain.
    final users = ref.watch(usersProvider);
    final t = resolveTarget(author, users);
    return _PreviewChip(
      barColor: c.primary,
      onClose: onClose,
      closeTooltip: tr('Cancel reply'),
      squareTop: squareTop,
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
                if (t != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: NymAvatar(
                        seed: t.pubkey,
                        size: 12,
                        imageUrl: users[t.pubkey]?.profile?.picture,
                      ),
                    ),
                  ),
                TextSpan(text: base),
                if (suffix.isNotEmpty)
                  TextSpan(
                    text: suffix,
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w100,
                      fontSize: 12 * 0.9,
                    ),
                  ),
                if (t != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: CosmeticNymBadges(
                      cosmetics: ref.watch(userCosmeticsProvider(t.pubkey)),
                      flairSize: 12,
                      supporterHeight: 12,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // Renders custom emoji as images, like the PWA quote preview.
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

class _EditPreviewChip extends StatelessWidget {
  const _EditPreviewChip({
    required this.text,
    required this.onClose,
    this.squareTop = false,
  });

  static const Color amber = Color(0xFFF0AD4E);

  final String text;
  final VoidCallback onClose;
  final bool squareTop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return _PreviewChip(
      barColor: amber,
      onClose: onClose,
      closeTooltip: tr('Cancel edit'),
      squareTop: squareTop,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('Editing message'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
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
              color: _hover ? (c.isLight ? c.text : Colors.white) : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Pulses while [translating]; disabled when the draft is empty.
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
    // Created eagerly so dispose always has a controller; a lazy field would tick a deactivated State.
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
    // The rest dim is folded into the glyph color, since an [Opacity] wrapper costs a saveLayer per frame.
    final restAlpha =
        widget.translating ? 1.0 : (widget.enabled ? (_hover ? 1.0 : 0.6) : 0.4);
    final base = _hover && widget.enabled ? c.primary : c.textDim;
    final color = base.withValues(alpha: base.a * restAlpha);
    Widget glyph = NymSvgIcon(NymIcons.translate, size: 16, color: color);
    if (widget.translating) {
      glyph = FadeTransition(
        opacity: Tween(begin: 0.4, end: 0.8).animate(_pulse),
        child: glyph,
      );
    }
    // The pulse replaces the base opacity, so don't also apply the disabled dim.
    return Tooltip(
        message: tr('Translate text'),
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.enabled ? widget.onTap : null,
            // Opaque is load-bearing: nothing else here hit-tests, so taps fell through.
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
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
    );
  }
}

/// Language row with a trailing favorite star.
class _TranslateLangRow extends StatefulWidget {
  const _TranslateLangRow({
    required this.name,
    required this.subtitle,
    required this.favorited,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final String name;

  /// The English name under the endonym, when it adds something.
  final String subtitle;
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
          color: _hover
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : Colors.white.withValues(alpha: 0.08))
              : null,
          padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _hover ? c.textBright : c.text,
                        fontSize: 13,
                      ),
                    ),
                    if (widget.subtitle.isNotEmpty)
                      Text(
                        widget.subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: 10),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
                      // No explicit light override in the CSS; matches the row hover.
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

/// Sentinels are allocated upward from U+E000 within the BMP Private Use Area.
const int _kSentinelBase = 0xE000;
const int _kSentinelEnd = 0xF8FF;

final RegExp _rxSentinel = RegExp('[\u{E000}-\u{F8FF}]', unicode: true);

/// A completed `:code:` token (NIP-30 codes are `[a-zA-Z0-9_+-]+`).
final RegExp _rxShortcodeToken = RegExp(r':([a-zA-Z0-9_+\-]+):');

/// Renders each custom emoji or mention as one PUA char painted via WidgetSpan; [expand] restores the wire form.
class EmojiSentinelController extends TextEditingController {
  EmojiSentinelController({super.text});

  /// Shortcode to image URL; decides which `:code:`s resolve and what a sentinel paints.
  Map<String, String> _codeToUrl = const {};
  set codeToUrl(Map<String, String> value) {
    if (identical(_codeToUrl, value)) return;
    _codeToUrl = value;
    // Repaint so a sentinel whose URL just arrived gets its image; no text mutation.
    notifyListeners();
  }

  /// One sentinel per distinct shortcode, reused across occurrences.
  final Map<String, String> _sentinelToCode = {};
  final Map<String, String> _codeToSentinel = {};

  /// Mentions use the same technique: one sentinel per distinct mention, expanded to `@base#suffix`.
  final Map<String, _MentionSentinel> _sentinelToMention = {};
  final Map<String, String> _mentionToSentinel = {};
  int _nextSentinel = _kSentinelBase;

  /// Null only when the PUA space is exhausted; the caller then leaves the literal text.
  String? _sentinelFor(String code) {
    final existing = _codeToSentinel[code];
    if (existing != null) return existing;
    if (_nextSentinel > _kSentinelEnd) return null;
    final ch = String.fromCharCode(_nextSentinel++);
    _codeToSentinel[code] = ch;
    _sentinelToCode[ch] = code;
    return ch;
  }

  /// Null when the PUA space is exhausted, so the caller inserts the literal `@fullNym`.
  String? mentionSentinel({required String fullNym, required String pubkey}) {
    final existing = _mentionToSentinel[fullNym];
    if (existing != null) return existing;
    if (_nextSentinel > _kSentinelEnd) return null;
    final ch = String.fromCharCode(_nextSentinel++);
    _mentionToSentinel[fullNym] = ch;
    _sentinelToMention[ch] = _MentionSentinel(fullNym: fullNym, pubkey: pubkey);
    return ch;
  }

  /// Wire-safety primitive: maps every sentinel back to `:shortcode:` or `@base#suffix`.
  String expand(String input) {
    if (input.isEmpty ||
        (_sentinelToCode.isEmpty && _sentinelToMention.isEmpty)) {
      return input;
    }
    return input.replaceAllMapped(_rxSentinel, (m) {
      final ch = m[0]!;
      final code = _sentinelToCode[ch];
      if (code != null) return ':$code:';
      final mention = _sentinelToMention[ch];
      if (mention != null) return '@${mention.fullNym}';
      return ch;
    });
  }

  /// Replaces completed known `:code:`s with sentinels, shifting the selection; null when unchanged.
  TextEditingValue? resolveValue(TextEditingValue value) {
    final src = value.text;
    if (src.isEmpty || !src.contains(':')) return null;
    final sb = StringBuffer();
    var last = 0;
    var changed = false;
    // A `:code:` of length N collapses to 1, so later offsets shift by -(N-1).
    var base = value.selection.baseOffset;
    var extent = value.selection.extentOffset;
    for (final m in _rxShortcodeToken.allMatches(src)) {
      final code = m.group(1)!;
      if (!_codeToUrl.containsKey(code)) continue; // Unknown codes stay literal.
      final ch = _sentinelFor(code);
      if (ch == null) continue; // PUA exhausted: leave literal.
      sb.write(src.substring(last, m.start));
      sb.write(ch);
      last = m.end;
      changed = true;
      final delta = (m.end - m.start) - 1;
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

  /// After the run shift left by delta; inside clamp to just past the sentinel; before unchanged.
  static int _shiftOffset(int offset, int start, int end, int delta) {
    if (offset < 0) return offset;
    if (offset >= end) return offset - delta;
    if (offset > start) return start + 1;
    return offset;
  }

  /// Applies [resolveValue] in place after every edit.
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
    // Drop sentinel allocations when the draft empties so stale mappings can't leak.
    if (newValue.text.isEmpty &&
        (_sentinelToCode.isNotEmpty || _sentinelToMention.isNotEmpty)) {
      _resetSentinels();
    }
    super.value = newValue;
  }

  void _resetSentinels() {
    _sentinelToCode.clear();
    _codeToSentinel.clear();
    _sentinelToMention.clear();
    _mentionToSentinel.clear();
    _nextSentinel = _kSentinelBase;
  }

  /// Markers follow the caret, and an unfocused field has no caret, so they stay hidden.
  bool get composerFocused => _composerFocused;
  bool _composerFocused = false;
  set composerFocused(bool value) {
    if (_composerFocused == value) return;
    _composerFocused = value;
    notifyListeners();
  }

  /// Markdown and sentinels are painted while the spans cover the draft char for char, keeping offsets valid.
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final src = text;
    final hasSentinel = (_sentinelToCode.isNotEmpty ||
            _sentinelToMention.isNotEmpty) &&
        _rxSentinel.hasMatch(src);
    // Never restyle mid-composition; the IME's composing underline must stay intact.
    final composing =
        withComposing && value.composing.isValid && !value.composing.isCollapsed;
    final runs = composing ? const <RichRun>[] : parseRichFormat(src);
    final formatted = hasRichFormat(runs);
    if (!hasSentinel && !formatted) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final baseStyle = style ?? const TextStyle();
    final children = <InlineSpan>[];
    if (formatted) {
      final sel = value.selection;
      final caret = _composerFocused && sel.isValid ? sel : null;
      _emitRuns(
        runs: runs,
        src: src,
        style: baseStyle,
        fieldStyle: baseStyle,
        colors: context.nym,
        caretStart: caret?.start ?? -1,
        caretEnd: caret?.end ?? -1,
        out: children,
      );
    } else {
      _emitPlain(src, 0, src.length, baseStyle, children);
    }
    return TextSpan(style: baseStyle, children: children);
  }

  void _emitRuns({
    required List<RichRun> runs,
    required String src,
    required TextStyle style,
    required TextStyle fieldStyle,
    required NymColors colors,
    required int caretStart,
    required int caretEnd,
    required List<InlineSpan> out,
  }) {
    for (final run in runs) {
      if (run.isText) {
        _emitPlain(src, run.start, run.end, style, out);
        continue;
      }
      final revealed = run.revealedAt(caretStart, caretEnd);
      final inner = richRunStyle(style, run.type, colors);
      final mark = richMarkStyle(inner, fieldStyle, revealed, colors,
          keepSpace: run.emptyBody);
      if (run.type == 'timestamp') {
        final seconds = int.tryParse(
            RegExp(r'^<t:(-?\d+)').firstMatch(run.open)?.group(1) ?? '');
        final styleLetter =
            RegExp(r':([tTdDfFR])>$').firstMatch(run.open)?.group(1) ?? 'f';
        if (seconds != null) {
          out.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: TimestampChip(
                seconds: seconds, style: styleLetter, textStyle: style),
          ));
          out.add(TextSpan(text: run.open.substring(1), style: mark));
          continue;
        }
      }
      if (run.type == 'ulist' || run.type == 'ulist2') {
        final markerAt = run.open.indexOf(RegExp(r'[-*]'));
        out.add(TextSpan(text: run.open.substring(0, markerAt), style: style));
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Text(run.type == 'ulist2' ? '\u25E6' : '\u2022',
              style: style.copyWith(color: colors.textDim)),
        ));
        out.add(TextSpan(text: run.open.substring(markerAt + 1), style: style));
      } else if (run.open.isNotEmpty) {
        out.add(TextSpan(text: run.open, style: mark));
      }
      _emitRuns(
        runs: run.children,
        src: src,
        style: inner,
        fieldStyle: fieldStyle,
        colors: colors,
        caretStart: caretStart,
        caretEnd: caretEnd,
        out: out,
      );
      if (run.close.isNotEmpty) {
        out.add(TextSpan(text: run.close, style: mark));
      }
    }
  }

  void _emitPlain(String src, int from, int to, TextStyle baseStyle,
      List<InlineSpan> children) {
    if (to <= from) return;
    final side = (baseStyle.fontSize ?? 14) * 1.4;
    final buf = StringBuffer();

    void flushText() {
      if (buf.isEmpty) return;
      children.add(TextSpan(text: buf.toString(), style: baseStyle));
      buf.clear();
    }

    for (final rune in src.substring(from, to).runes) {
      final isSentinel = rune >= _kSentinelBase && rune <= _kSentinelEnd;
      final chStr = isSentinel ? String.fromCharCode(rune) : null;
      final code = chStr == null ? null : _sentinelToCode[chStr];
      final url = code == null ? null : _codeToUrl[code];
      final mention = chStr == null ? null : _sentinelToMention[chStr];
      if ((code == null || url == null) && mention == null) {
        // An emoji sentinel without a URL renders its literal `:code:`, never a bare PUA glyph.
        buf.write(code != null ? ':$code:' : String.fromCharCode(rune));
        continue;
      }
      flushText();
      if (mention != null) {
        children.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InputMentionChip(
            pubkey: mention.pubkey,
            fullNym: mention.fullNym,
            baseStyle: baseStyle,
          ),
        ));
        continue;
      }
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: EmojiBaselineDrop(
            drop: (baseStyle.fontSize ?? 14) * 0.3,
            child: InlineNetworkImage(
              url: proxiedMedia(url!, emoji: true),
              width: side,
              height: side,
              fit: BoxFit.contain,
              retryOnError: true,
              errorChild: Text(':$code:', style: baseStyle),
            ),
          ),
        ),
      ));
    }
    flushText();
  }
}

class _MentionSentinel {
  const _MentionSentinel({required this.fullNym, required this.pubkey});
  final String fullNym;
  final String pubkey;
}

/// Inline mention chip for a mention sentinel; watches the user so late profiles fill in place.
class _InputMentionChip extends ConsumerWidget {
  const _InputMentionChip({
    required this.pubkey,
    required this.fullNym,
    required this.baseStyle,
  });

  final String pubkey;

  final String fullNym;
  final TextStyle baseStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final split = splitNymSuffix(fullNym);
    final base = split.base;
    final suffix = split.suffix; // Includes the leading '#'.
    final size = baseStyle.fontSize ?? 14;
    final picture =
        ref.watch(usersProvider.select((m) => m[pubkey]?.profile?.picture));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NymAvatar(seed: pubkey, size: size, imageUrl: picture),
        const SizedBox(width: 3),
        Text.rich(
          TextSpan(
            style: baseStyle,
            children: [
              TextSpan(text: '@$base'),
              if (suffix.isNotEmpty)
                TextSpan(
                  text: suffix,
                  style: baseStyle.copyWith(
                    color: (baseStyle.color ?? c.text).withValues(alpha: 0.7),
                    fontWeight: FontWeight.w100,
                    fontSize: size * 0.9,
                  ),
                ),
            ],
          ),
        ),
        CosmeticNymBadges(
          cosmetics: ref.watch(userCosmeticsProvider(pubkey)),
          flairSize: size,
          supporterHeight: size,
        ),
      ],
    );
  }
}
