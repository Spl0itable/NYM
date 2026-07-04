import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/settings.dart';
import '../notifications/notifications_service.dart';
import '../../services/location/geolocation.dart';
import '../../services/storage/secure_store.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart' show proxiedAvatarUrl;
import '../../widgets/nym_icons.dart';
import '../../widgets/wallpaper/wallpaper_layer.dart';
import '../emoji/emoji_picker.dart';
import '../messages/format/message_content.dart' show InlineEmojiText;
import '../identity/modal_chrome.dart';
import '../identity/vault_settings_modal.dart';
import 'settings_helpers.dart';
import 'settings_widgets.dart';

/// The Settings modal (`#settingsModal`, docs/specs/02 §5.10, §04-features §9).
///
/// Presented as a centered `.modal-content` dialog (bg `--bg-secondary`,
/// radius xl, 1px glass border, max-width 500, padding 32). Sections mirror the
/// PWA collapsible `.settings-section`s in order: Appearance, Privacy &
/// Security, Messaging & Display, Channels, Mobile Gestures, Data & Backup.
///
/// Each control's label text, option order and option labels are copied
/// verbatim from `index.html`'s `#settingsModal` markup.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  /// Opens the settings dialog as a modal route.
  static Future<void> open(BuildContext context) {
    // `.modal` overlay: glass default `rgba(0,0,0,0.7)` (styles-chat.css:1974);
    // `body.solid-ui .modal { rgba(0,0,0,0.75) }` and
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1635).
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: !solidUi
          ? Colors.black.withValues(alpha: 0.7)
          : isLight
              ? const Color(0x73000000) // black @ 0.45
              : const Color(0xBF000000), // black @ 0.75
      builder: (_) => const SettingsScreen(),
    );
  }

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _searchController = TextEditingController();
  final _keywordController = TextEditingController();
  final _transferPubkeyController = TextEditingController();
  final _landingController = TextEditingController();
  final _landingFocus = FocusNode();
  String _search = '';

  /// Inline error under the transfer field (F9 / shop.js settingsTransferError).
  String? _transferError;

  /// Whether an outbound settings transfer is in flight (F9). Disables the Send
  /// button + relabels it "Sending…" while the gift wrap publishes.
  bool _transferSending = false;

  /// The current landing-channel selection (F8). Seeded from the store.
  LandingChannel _landing = LandingChannel.defaultChannel;

  /// Whether the landing-channel suggestions overlay is open.
  bool _landingOpen = false;

  /// The on-device cache readout shown in Data & Backup (F7). Null while the
  /// first `cacheSizeBytes()` read is in flight (renders the PWA's
  /// "Calculating…" placeholder); otherwise a formatted human string.
  String? _cacheReadout;

  // Section open/collapsed state (all expanded by default, matching the PWA's
  // aria-expanded="true"). Restored from `nym_settings_sections_collapsed` on
  // open and persisted on every toggle (inline-bindings.js:28-46
  // persist/restoreSettingsSectionState).
  final Map<String, bool> _open = {
    'appearance': true,
    'privacy': true,
    'messaging': true,
    'channels': true,
    'mobile': true,
    'data': true,
  };

  /// Whether the blocked-users profile fetch is in flight (users.js:1767
  /// `updateBlockedList` renders "Loading..." while `loadBlockedUsersAsync`
  /// resolves unknown blocked users' metadata).
  bool _blockedProfilesLoading = false;

  /// Whether a custom-wallpaper pick is being processed (the PWA's
  /// "Uploading..." state in the Upload tile, app.js:4184).
  bool _wallpaperUploading = false;

  // Live text-size preview value (commits to the controller on change end).
  double? _textSizePreview;

  /// Draft copy of every Save-gated setting (09-M1). The PWA settings modal is
  /// Save-gated: changing a dropdown mutates the in-DOM value only and is
  /// committed to `nym.settings` + persisted + synced ONLY when Save is pressed
  /// (`saveSettings`, app.js:3719-3998); pressing Cancel/closing discards it.
  /// We mirror that by editing `_draft` on change and fanning it out to the
  /// real setters in `_onSave`. The handful of controls the PWA applies live —
  /// theme, color mode, transparency, columns-wallpaper, text size, keypair
  /// mode — call their real setter immediately AND mirror into `_draft` so the
  /// Save fan-out doesn't revert them (see `_appearance`).
  late Settings _draft;

  /// `cachePMs` at the moment the modal opened. The PWA only wipes the existing
  /// PM/group cache on Save when the value flipped on→off (app.js:3853-3858),
  /// not on every change, so we compare against this baseline in `_onSave`.
  late bool _cachePMsAtOpen;

  // Save-gated drafts for the three controls backed by KV-only controller
  // getters (not `Settings` fields). The PWA reads each on Save too
  // (keypair app.js:3873-3877, PoW app.js:3616/save, blur app.js:3729-3754).
  late String _draftKeypair; // 'persistent' | 'random' | 'hardcore'
  late int _draftPow;
  late String _draftBlur; // 'true' | 'friends' | 'false'

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    // Snapshot the live settings as the editable draft (09-M1).
    _draft = ref.read(settingsProvider);
    // Coerce legacy/corrupt indicator-scope values before they reach the two
    // scope `FormSelect`s (settings.js:27-32 `_normalizeIndicatorScope` +
    // 1105-1112: 'true' → 'everywhere', 'false' → 'disabled', anything
    // unknown → the fallback derived from the legacy
    // `nym_read_receipts_enabled` / `nym_typing_indicators_enabled` booleans).
    _draft = _draft.copyWith(
      readReceiptsScope: normalizeIndicatorScope(
        _draft.readReceiptsScope,
        fallback: kv.getString(StorageKeys.readReceiptsEnabled) == 'false'
            ? 'disabled'
            : 'everywhere',
      ),
      typingIndicatorsScope: normalizeIndicatorScope(
        _draft.typingIndicatorsScope,
        fallback: kv.getString(StorageKeys.typingIndicatorsEnabled) == 'false'
            ? 'disabled'
            : 'everywhere',
      ),
    );
    _cachePMsAtOpen = _draft.cachePMs;
    final ctrl0 = ref.read(settingsProvider.notifier);
    _draftKeypair = ctrl0.keypairMode;
    _draftPow = ctrl0.powDifficulty;
    // Blur seeds from the per-pubkey key first, then the global key, default
    // blur — `loadImageBlurSettings` precedence (settings.js:1139-1156; the
    // PWA's modal shows the resolved value, and the Save-time `setBlurImages`
    // writes both keys, converging them). Anything that isn't
    // 'friends'/'true' coerces to 'false' exactly like the PWA's
    // `saved === 'true'` boolean read.
    final selfPk = ref.read(appStateProvider).selfPubkey;
    final rawBlur = (selfPk.isNotEmpty
            ? kv.getString(StorageKeys.imageBlurFor(selfPk))
            : null) ??
        kv.getString(StorageKeys.imageBlur);
    _draftBlur = rawBlur == null
        ? 'true' // default to blur
        : rawBlur == 'friends'
            ? 'friends'
            : (rawBlur == 'true' ? 'true' : 'false');
    // Seed the landing-channel field from the persisted value (F8).
    _landing = readLandingChannel(kv);
    _landingController.text = _landing.label;
    // Restore the persisted section collapse layout (the PWA calls
    // `restoreSettingsSectionState` on every settings open, app.js:3197;
    // collapsed sections are stored as `{key: 1}` in
    // `nym_settings_sections_collapsed`, inline-bindings.js:36-46).
    try {
      final raw = kv.getString(_kSettingsSectionsCollapsedKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw);
        if (map is Map) {
          for (final key in _open.keys.toList()) {
            final v = map[key];
            if (v != null && v != 0 && v != false) _open[key] = false;
          }
        }
      }
    } catch (_) {}
    _landingFocus.addListener(() {
      if (!_landingFocus.hasFocus && _landingOpen) {
        setState(() => _landingOpen = false);
      }
    });
    // Kick off the real on-device cache-size read (F7; refreshAppCacheSize is
    // run on settings open in the PWA, app.js:3625).
    _loadCacheSize();
    // Pull any inbound pending settings transfers (F17).
    ref.read(nostrControllerProvider).refreshPendingSettingsTransfers();
    // Resolve unknown blocked users' profiles so the Blocked Users list can
    // show real nyms (users.js `loadBlockedUsersAsync` → metadata fetch).
    _fetchBlockedProfiles();
  }

  /// Fetches kind-0 profiles for blocked users we don't know yet, showing the
  /// PWA's "Loading..." placeholder in the Blocked Users list meanwhile
  /// (users.js:1774-1815 `updateBlockedList`/`loadBlockedUsersAsync`).
  Future<void> _fetchBlockedProfiles() async {
    final app = ref.read(appStateProvider);
    final unknown = app.blockedUsers.where((pk) {
      final user = app.users[pk];
      return user == null || user.nym.isEmpty;
    }).toList();
    if (unknown.isEmpty) return;
    setState(() => _blockedProfilesLoading = true);
    try {
      await ref.read(nostrControllerProvider).resolveProfiles(unknown);
    } catch (_) {
      // Best-effort; unresolved entries fall back to `anon#xxxx`.
    }
    if (!mounted) return;
    setState(() => _blockedProfilesLoading = false);
  }

  /// Reads the real on-device cache size from the controller and formats the
  /// PWA readout into [_cacheReadout] (F7). Mirrors `refreshAppCacheSize`
  /// (app.js:3681-3716): show "Calculating…" until the async read resolves,
  /// then `"[size] cached on device — N channels, N PM/group threads,
  /// N profiles, N reaction records"` (size auto-scaled B/KB/MB/GB), the
  /// honest empty-state string when nothing is cached, or the
  /// cache-unavailable string when the store errors.
  Future<void> _loadCacheSize() async {
    final controller = ref.read(nostrControllerProvider);
    try {
      final bytes = await controller.cacheSizeBytes();
      if (!mounted) return;
      setState(() {
        _cacheReadout =
            cacheReadoutFor(ref.read(appStateProvider), realBytes: bytes);
      });
    } catch (e) {
      if (!mounted) return;
      // The PWA's failed-probe branch: `IndexedDB unavailable (<reason>) —
      // cache disabled in this app` (app.js:3702-3705); the native store's
      // equivalent honest failure state.
      setState(() => _cacheReadout =
          'Cache unavailable ($e) — cache disabled in this app');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _keywordController.dispose();
    _transferPubkeyController.dispose();
    _landingController.dispose();
    _landingFocus.dispose();
    super.dispose();
  }

  /// Toggles a section's collapsed state and persists the layout to
  /// `nym_settings_sections_collapsed` (inline-bindings.js:28
  /// `persistSettingsSectionState`: collapsed keys map to `1`, expanded keys
  /// are removed).
  void _toggleSection(String key) {
    setState(() => _open[key] = !(_open[key] ?? true));
    final collapsed = <String, int>{
      for (final e in _open.entries)
        if (!e.value) e.key: 1,
    };
    ref
        .read(keyValueStoreProvider)
        .setString(_kSettingsSectionsCollapsedKey, jsonEncode(collapsed));
  }

  /// The option-label text of a select's items, for the per-group search text
  /// (the PWA's `filterSettings` matches each `.form-group`'s full rendered
  /// `textContent`, which includes every `<option>` label,
  /// inline-bindings.js:66-74).
  static String _optText<T>(List<({T value, String label})> items) =>
      items.map((it) => it.label).join(' ');

  /// Mutates the Save-gated [_draft] in place (09-M1). Save-gated dropdowns call
  /// this from their `onChanged` instead of the live `ctrl.setX` setter, so the
  /// change is held locally until Save.
  void _mutate(Settings Function(Settings draft) fn) {
    setState(() => _draft = fn(_draft));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Watch the live settings so live-applied controls (theme / color mode /
    // transparency) rebuild `context.nym` immediately. The section builders,
    // however, render from the Save-gated `_draft` (09-M1) so a pending dropdown
    // edit shows but is not yet committed.
    ref.watch(settingsProvider);
    final settings = _draft;
    final ctrl = ref.read(settingsProvider.notifier);
    // Watch the moderation Sets so the Friends/Blocked/Keywords/Hidden/Blocked
    // lists (F1) re-render on add/remove.
    ref.watch(appStateProvider);
    // Watch inbound USER-TO-USER settings transfers so the Pending Settings
    // Transfers list (F17) re-renders as offers arrive or are
    // accepted/rejected.
    ref.watch(pendingUserSettingsTransfersProvider);

    // `.settings-section.mobile-only` is `display:none` by default and revealed
    // only `@media (max-width:768px)` (styles-components.css:215 +
    // styles-themes-responsive.css:70). Gate the Mobile Gestures section the
    // same way so wide windows/tablets don't over-render it.
    final isMobileWidth = MediaQuery.of(context).size.width <= 768;

    final sections = <_SectionSpec>[
      _SectionSpec(
        key: 'appearance',
        title: 'Appearance',
        groups: _appearance(settings, ctrl),
      ),
      _SectionSpec(
        key: 'privacy',
        title: 'Privacy & Security',
        groups: _privacy(settings, ctrl),
      ),
      _SectionSpec(
        key: 'messaging',
        title: 'Messaging & Display',
        groups: _messaging(settings, ctrl),
      ),
      _SectionSpec(
        key: 'channels',
        title: 'Channels',
        groups: _channels(settings, ctrl),
      ),
      // Mobile Gestures — only on a mobile-width viewport (PWA mobile-only).
      if (isMobileWidth)
        _SectionSpec(
          key: 'mobile',
          title: 'Mobile Gestures',
          groups: _mobile(settings, ctrl),
        ),
      _SectionSpec(
        key: 'data',
        title: 'Data & Backup',
        groups: _data(settings, ctrl),
      ),
    ];

    // `filterSettings` (inline-bindings.js:53-91): a section-title match shows
    // the whole section; otherwise each `.form-group` is matched individually
    // against its full text (label + hint + option labels + placeholders +
    // rendered content) and hidden on a miss. Matching sections are
    // force-expanded while a query is active; an empty query restores the
    // saved collapse layout.
    final q = _search.trim().toLowerCase();
    final visibleSections = <({_SectionSpec spec, List<_GroupSpec> groups})>[];
    for (final s in sections) {
      final sectionMatches = q.isNotEmpty && s.title.toLowerCase().contains(q);
      final groups = q.isEmpty
          ? s.groups
          : [
              for (final g in s.groups)
                if (sectionMatches || g.text.toLowerCase().contains(q)) g,
            ];
      if (q.isNotEmpty && groups.isEmpty) continue;
      visibleSections.add((spec: s, groups: groups));
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            // `.modal-content` card chrome, shared with every other standard
            // modal: shadow-lg + shadow-glow (primary@.1/20px) + white@.05
            // ring in dark; a single `0 8px 40px black@0.12` in light
            // (styles-themes-responsive.css:1050-1052).
            child: ModalChrome.box(
              c,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                // `.modal-content { max-height: 90vh; overflow-y: auto }`
                // (styles-components.css:17-27): the WHOLE card scrolls — the
                // SETTINGS header (and its absolute ✕ chip) scrolls off-screen
                // and the Cancel/Save `.modal-actions` row sits at the END of
                // the content — only `.settings-search` sticks
                // (`position: sticky; top: 0`, styles-components.css:136-140).
                child: CustomScrollView(
                  shrinkWrap: true,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Stack(
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _header(c),
                              // `.modal-header { margin-bottom: 24px }` — the
                              // gap between the header rule and the search row
                              // shows the modal background.
                              const SizedBox(height: 24),
                            ],
                          ),
                          // `.modal-close`: 32×32 glass ✕ chip, absolute
                          // top-right (14,14) INSIDE the scroll content — like
                          // the PWA's `position: absolute` chip it scrolls away
                          // with the header.
                          ModalChrome.closeChip(
                              c, () => Navigator.of(context).maybePop()),
                        ],
                      ),
                    ),
                    PinnedHeaderSliver(child: _searchBar(c)),
                    SliverToBoxAdapter(
                      // Sections are full-bleed; the no-results text carries
                      // the `.modal-content { padding: 32px }` horizontal
                      // inset itself.
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (visibleSections.isEmpty)
                            // `.settings-no-results { padding: 18px 0 6px;
                            //   color: text-dim; font-size: 13px;
                            //   text-align: center }`.
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(32, 18, 32, 6),
                              child: Text(
                                'No settings match your search.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: c.textDim, fontSize: 13),
                              ),
                            ),
                          for (final s in visibleSections)
                            SettingsSection(
                              title: s.spec.title,
                              // A live query force-expands matching sections
                              // (filterSettings removes `collapsed` without
                              // persisting); empty query renders the saved
                              // layout.
                              open: q.isNotEmpty
                                  ? true
                                  : (_open[s.spec.key] ?? true),
                              onToggle: () => _toggleSection(s.spec.key),
                              children: [
                                for (final g in s.groups) g.child,
                              ],
                            ),
                          // `.modal-actions` is the last block of the scrolled
                          // content (you scroll to the bottom to reach Save);
                          // the 20px body→actions gap (`.modal-body
                          // { margin-bottom }`) lives on its padding.
                          _actions(c),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Chrome ---------------------------------------------------------------

  Widget _header(NymColors c) {
    // `.modal-header`: a full-width title with a 1px glass bottom rule
    // (`padding-bottom: 14px`), inset by `.modal-content { padding: 32px }`.
    // The close ✕ is the separate absolute chip (build), not a Row child.
    // Right padding (56) keeps the title clear of the floating chip.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(32, 32, 56, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        'SETTINGS',
        style: TextStyle(
          color: c.primary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _searchBar(NymColors c) {
    // `.settings-search { padding: 4px 32px 14px; background: var(--glass-bg) }`
    // with the 16px magnifier SVG inset at the input's left
    // (styles-components.css:136-157 + index.html:1351-1353).
    return Container(
      color: c.glassBg,
      padding: const EdgeInsets.fromLTRB(32, 4, 32, 14),
      child: FormInput(
        controller: _searchController,
        hint: 'Search settings...',
        prefix: NymSvgIcon(NymIcons.search, size: 16, color: c.textDim),
        onChanged: (v) => setState(() => _search = v),
      ),
    );
  }

  Widget _actions(NymColors c) {
    // `.modal-actions`: a centered 10px-gap button row with NO border or
    // background of its own — separated from the body by `.modal-body
    // { margin-bottom: 20px }` and inset by `.modal-content { padding: 32px }`.
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // `.icon-btn` Cancel: `.modal-actions` sets no `align-items`, so
          // flex's default stretch sizes it to the 42px `.send-btn` Save.
          NymOutlineButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).maybePop(),
            height: 42,
          ),
          const SizedBox(width: 10),
          // `.send-btn`: primary-tinted (bg primary@0.1, border primary@0.3),
          // primary uppercase text with wide letter-spacing, height 42.
          InkWell(
            onTap: _onSave,
            borderRadius: NymRadius.rsm,
            child: Container(
              height: 42,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                color: c.primaryA(0.10),
                borderRadius: NymRadius.rsm,
                border: Border.all(color: c.primaryA(0.30)),
              ),
              child: Text(
                'SAVE',
                style: TextStyle(
                  color: c.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Actions / wiring -----------------------------------------------------

  /// Emits a transient in-conversation system pill (the PWA's
  /// `displaySystemMessage`), then optionally closes the modal. Scheduled
  /// post-frame so it runs after the dialog pops.
  void _systemMessage(String text) {
    final notifier = ref.read(appStateProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifier.addSystemMessage(text);
    });
  }

  /// SAVE (F3 / 09-M1): fan the Save-gated [_draft] out to the real setters
  /// (mirroring the PWA's `saveSettings`, app.js:3719-3998, which reads every
  /// control's current value and only THEN persists + syncs), run the
  /// proximity-grant geolocation flow, wipe the PM/group cache iff Cache-PMs
  /// flipped on→off, commit the landing channel, confirm, and close.
  ///
  /// The live-applied controls (theme / color mode / transparency / chat view /
  /// wallpaper / message layout / text size / keypair mode) already persisted
  /// on-change; re-sending their (unchanged) draft value here is idempotent and
  /// keeps the persisted state == draft.
  Future<void> _onSave() async {
    final ctrl = ref.read(settingsProvider.notifier);
    final d = _draft;

    // Resolve the proximity geolocation grant BEFORE persisting so a denial
    // flips the staged value back to Disabled (PWA app.js:3917-3950).
    final proximity = await _resolveProximityOnSave(d.sortByProximity);
    if (!mounted) return;

    // Snapshot the pre-save status visibility so a changed value can trigger
    // the PWA's immediate re-broadcast (app.js:3837-3847).
    final prevShowStatus = ref.read(settingsProvider).showStatus;

    // Fan out every Save-gated dropdown value through its setter (each writes
    // KV + state + queues the cross-device sync). Appearance live-applied
    // controls are included for idempotence.
    ctrl.setTheme(d.theme);
    ctrl.setColorMode(d.colorMode);
    ctrl.setChatViewMode(d.chatViewMode);
    ctrl.setColumnsWallpaper(d.columnsWallpaper);
    ctrl.setWallpaperType(d.wallpaperType);
    ctrl.setChatLayout(d.chatLayout);
    ctrl.setTransparencyEnabled(d.transparencyEnabled);
    ctrl.setTextSize(d.textSize);
    ctrl.setAcceptPMs(d.acceptPMs);
    ctrl.setAcceptCalls(d.acceptCalls);
    ctrl.setDmForwardSecrecy(d.dmForwardSecrecyEnabled);
    ctrl.setDmTtlSeconds(d.dmTtlSeconds);
    ctrl.setReadReceiptsScope(d.readReceiptsScope);
    ctrl.setTypingIndicatorsScope(d.typingIndicatorsScope);
    ctrl.setShowStatus(d.showStatus);
    // Show-Status changed: immediately re-assert presence under the NEW
    // visibility mode so peers hide/show our status dot right away instead of
    // waiting for the next organic (≤1/60s throttled) broadcast — the PWA's
    // `publishStatusVisibility()` on Save (app.js:3842-3847 →
    // nostr-core.js:2841-2846: `publishPresence(away ? 'away' : 'online',
    // awayMsg)`). The PM-header/user-list refreshes the PWA pairs with it are
    // reactive on native. Runs after `setShowStatus` so `publishPresence`
    // reads the new `_statusMode`.
    if (prevShowStatus != d.showStatus) {
      final appState = ref.read(appStateProvider);
      final awayMsg =
          appState.users[appState.selfPubkey]?.awayMessage ?? '';
      unawaited(ref.read(nostrControllerProvider).publishPresence(
            awayMsg.isNotEmpty ? 'away' : 'online',
            awayMessage: awayMsg,
          ));
    }
    ctrl.setCachePMs(d.cachePMs);
    ctrl.setTranslateLanguage(d.translateLanguage);
    ctrl.setSound(d.sound);
    ctrl.setAutoscroll(d.autoscroll);
    ctrl.setShowTimestamps(d.showTimestamps);
    ctrl.setTimeFormat(d.timeFormat);
    ctrl.setDateFormat(d.dateFormat);
    ctrl.setNickStyle(d.nickStyle);
    ctrl.setGroupChatPMOnlyMode(d.groupChatPMOnlyMode);
    ctrl.setSortByProximity(proximity);
    ctrl.setHideNonPinned(d.hideNonPinned);
    ctrl.setGesturesEnabled(d.gesturesEnabled);
    ctrl.setSwipeLeftAction(d.swipeLeftAction);
    ctrl.setSwipeRightAction(d.swipeRightAction);
    ctrl.setSwipeThreshold(d.swipeThreshold);
    ctrl.setSwipeReactEmoji(d.swipeReactEmoji);
    ctrl.setLowDataMode(d.lowDataMode);

    // KV-only Save-gated controls (not Settings fields). Skip keypair when
    // locked to 'persistent' by a logged-in Nostr identity (the select is
    // disabled, app.js:3237-3241, so its value never changes).
    final nostrLoggedIn =
        ref.read(nostrControllerProvider).identity?.loginMethod != null;
    if (!nostrLoggedIn) {
      ctrl.setKeypairMode(_draftKeypair);
      // `saveSettings`' keypair side effects (app.js:3878-3890): switching to
      // random/hardcore removes the saved session nsec so the next launch
      // generates a fresh identity; switching to persistent saves the CURRENT
      // keypair's nsec (only when none is stored) so the identity in use
      // survives the next launch instead of being regenerated.
      final secure = SecureStore();
      if (_draftKeypair == 'random' || _draftKeypair == 'hardcore') {
        unawaited(secure.remove(SecretKeys.sessionNsec));
      } else {
        final privkey = ref.read(nostrControllerProvider).identity?.privkey;
        if (privkey != null) {
          unawaited(() async {
            try {
              final existing = await secure.get(SecretKeys.sessionNsec);
              if (existing == null || existing.isEmpty) {
                await secure.set(
                    SecretKeys.sessionNsec, bech32.encodeNsecBytes(privkey));
              }
            } catch (_) {
              // Best-effort, like the PWA's swallowed nsecEncode try/catch.
            }
          }());
        }
      }
    }
    ctrl.setPowDifficulty(_draftPow);
    ctrl.setBlurImages(_draftBlur, pubkey: ref.read(appStateProvider).selfPubkey);

    // Cache-PMs side-effect: wipe existing decrypted PM/group cache only when
    // the value flipped on→off (PWA app.js:3853-3858), not on every save.
    if (_cachePMsAtOpen && !d.cachePMs) {
      ref.read(nostrControllerProvider).clearPmGroupCache();
    }

    // Commit the landing channel (F8 — not write-on-change). Routed through the
    // synced setter (settings_provider.dart:274) rather than a bare KV write so
    // a Save fires the cross-device `settings-set` publish like every other
    // Save-gated control — the PWA syncs `pinnedLandingChannel` on Save
    // (settings.js:21,116; `nostrSettingsSave()`, app.js:3995). The serialized
    // value is byte-identical to the old `writeLandingChannel` write.
    ctrl.setPinnedLandingChannel(_landing.toJsonString());

    // Hidden #autoEphemeralSelect compatibility handling (app.js:3862-3870):
    // the PWA seeds the (permanently hidden) select from `nym_auto_ephemeral`
    // on open and reads it back on Save — anything but 'true' removes the
    // auto-ephemeral keys.
    final kvStore = ref.read(keyValueStoreProvider);
    if (kvStore.getString(StorageKeys.autoEphemeral) == 'true') {
      kvStore.setString(StorageKeys.autoEphemeral, 'true');
    } else {
      kvStore.remove(StorageKeys.autoEphemeral);
      kvStore.remove(StorageKeys.autoEphemeralNick);
      kvStore.remove(StorageKeys.autoEphemeralChannel);
    }

    if (!mounted) return;
    _systemMessage('Settings saved');
    Navigator.of(context).maybePop();
  }

  /// Chat-Wallpaper "Upload" tile: pick an image from the gallery, validate
  /// the PWA's 1920x1080 minimum (users.js:830-850 `uploadWallpaper`), upload
  /// it to the Blossom hosts and store the returned public URL in
  /// `nym_wallpaper_custom_url` (so it can roam cross-device as
  /// `wallpaperCustomUrl`, settings.js:12), then select custom mode. Mirrors
  /// the PWA `triggerWallpaperUpload`/`handleWallpaperUpload`
  /// (app.js:4177-4209) — including the Upload tile's "Uploading..." state and
  /// thumbnail, and leaving the selection unchanged on a failed upload.
  /// No-op on cancel.
  Future<void> _uploadCustomWallpaper(SettingsController ctrl) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return; // user cancelled the picker
    if (mounted) setState(() => _wallpaperUploading = true);
    try {
      // Validate the minimum image size (users.js:831-850: reject anything
      // under 1920x1080 with the exact PWA system message; a decode failure
      // counts as invalid, like the PWA's `img.onerror`).
      const minWidth = 1920, minHeight = 1080;
      final bytes = await File(picked.path).readAsBytes();
      var validSize = false;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        validSize =
            frame.image.width >= minWidth && frame.image.height >= minHeight;
        frame.image.dispose();
        codec.dispose();
      } catch (_) {
        validSize = false;
      }
      if (!validSize) {
        _systemMessage(
            'Wallpaper image must be at least ${minWidth}x$minHeight pixels.');
        return;
      }
      // Upload through the proxy to the Blossom hosts (users.js:852-857
      // `_uploadWithFallback` — the SHA-256 `x`-tag auth + 3-server fallback
      // live in `NostrController.uploadImage`, the same path chat images use).
      String? url;
      try {
        url = await ref
            .read(nostrControllerProvider)
            .uploadImage(bytes, contentType: _imageContentType(picked.path));
      } catch (e) {
        // `uploadWallpaper`'s catch branch (users.js:864-866) surfaces
        // `error.message` — strip Dart's `Exception: ` toString prefix so the
        // system message reads like the PWA's.
        final msg = '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '');
        _systemMessage('Failed to upload wallpaper: $msg');
        return;
      }
      if (url == null || url.isEmpty) {
        // Every server failed (`uploadImage` swallows per-server errors and
        // returns null; `_uploadWithFallback`'s no-lastErr throw is
        // `'All Blossom servers failed'`, users.js:562 → uploadWallpaper's
        // catch, users.js:864-866): the tile reverts and the selection stays
        // unchanged, like `handleWallpaperUpload`'s null branch
        // (app.js:4203-4205).
        _systemMessage('Failed to upload wallpaper: All Blossom servers failed');
        return;
      }
      await ref.read(keyValueStoreProvider).setString(
            StorageKeys.wallpaperCustomUrl,
            url,
          );
      // Live-applied like the PWA's custom upload; mirror into the draft so the
      // Save fan-out (which sends `_draft.wallpaperType`) keeps 'custom'
      // selected.
      ctrl.setWallpaperType('custom');
      if (!mounted) return;
      _mutate((d) => d.copyWith(wallpaperType: 'custom'));
      _systemMessage('Wallpaper uploaded and applied.');
    } finally {
      if (mounted) setState(() => _wallpaperUploading = false);
    }
  }

  /// The picked file's MIME type from its extension (the PWA sends the File's
  /// own `type` to the Blossom PUT).
  static String _imageContentType(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.heic':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }

  /// Add Keyword (F4): persist + render the new row + confirm + queue the
  /// cross-device sync (users.js:121-148 `addBlockedKeyword` ends with
  /// `nostrSettingsSave()`). A duplicate is a no-op on the Set, but the PWA
  /// still clears the input, shows the confirmation, and syncs — only an
  /// empty input skips everything.
  void _addKeyword(SettingsController ctrl) {
    final kw = _keywordController.text.trim().toLowerCase();
    if (kw.isEmpty) return;
    ref.read(appStateProvider.notifier).addBlockedKeyword(kw);
    _persistBlockedKeywords();
    _keywordController.clear();
    _systemMessage('Blocked keyword: "$kw"');
    ref.read(nostrControllerProvider).syncSettings();
    setState(() {});
  }

  /// Persists a live moderation Set to KV as the JSON string array the PWA
  /// uses (`saveFriends`/`saveBlockedUsers`/`saveHiddenChannels`/
  /// `saveBlockedChannels`/`saveBlockedKeywords`). The store has no typed
  /// set-setter, so we serialize through `setString`.
  void _persistStringSet(String key, Set<String> values) {
    ref
        .read(keyValueStoreProvider)
        .setString(key, jsonEncode(values.toList()));
  }

  /// Persists the live blocked-keyword Set to `nym_blocked_keywords`.
  void _persistBlockedKeywords() {
    _persistStringSet(
        StorageKeys.blockedKeywords, ref.read(appStateProvider).blockedKeywords);
  }

  /// Quick React emoji "Change" (F5): open the emoji picker; a pick commits
  /// IMMEDIATELY (app.js:3294-3303 — the picker callback sets
  /// `nym.settings.swipeReactEmoji` + localStorage `nym_swipe_react_emoji` at
  /// once, so the choice survives Cancel). No `nostrSettingsSave` fires at
  /// pick time, so the write goes through `ctrl.update` (raw KV + live state,
  /// no synced publish); Save later re-sends the same value through the
  /// synced setter, like the PWA's `saveSettings`. The draft is kept in step
  /// so Save persists what was picked.
  void _openSwipeReactPicker(SettingsController ctrl) {
    final c = context.nym;
    final recents = ref.read(recentEmojisProvider);
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (dialogCtx) => Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
          width: MediaQuery.of(context).size.width * 0.9,
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rmd,
          ),
          clipBehavior: Clip.antiAlias,
          child: EmojiPicker(
            recents: recents,
            onSelect: (emoji) {
              Navigator.of(dialogCtx).maybePop();
              // Immediate commit (app.js:3298-3300): persisted key + live
              // state, no sync publish at pick time.
              ref
                  .read(keyValueStoreProvider)
                  .setString(StorageKeys.swipeReactEmoji, emoji);
              ctrl.update((s) => s.copyWith(swipeReactEmoji: emoji));
              _mutate((d) => d.copyWith(swipeReactEmoji: emoji));
              ref.read(recentEmojisProvider.notifier).record(emoji);
            },
          ),
        ),
      ),
    );
  }

  /// Swipe-action `<select>` change (09-F-LOW-5): stage the new action into the
  /// draft, then — mirroring the PWA's `handleSwipeActionChange`
  /// (app.js:3316-3324) — auto-open the emoji picker the moment a swipe action
  /// is switched TO "react" when (a) the previous action wasn't already "react"
  /// and (b) no swipe-react emoji has ever been persisted. The PWA gates on the
  /// raw `localStorage.getItem('nym_swipe_react_emoji')` being absent, so we
  /// check the raw KV key (NOT the draft's `'❤️'` default, which is always
  /// present) — a user who deliberately picked an emoji is never re-prompted.
  void _onSwipeActionChanged(
    SettingsController ctrl, {
    required String prev,
    required String next,
    required Settings Function(Settings draft) apply,
  }) {
    _mutate(apply);
    final hasPersistedEmoji =
        (ref.read(keyValueStoreProvider).getString(StorageKeys.swipeReactEmoji) ??
                '')
            .isNotEmpty;
    if (next == 'react' && prev != 'react' && !hasPersistedEmoji) {
      _openSwipeReactPicker(ctrl);
    }
  }

  /// Notification-sound change: stage the choice into the draft (Save-gated,
  /// 09-M1 — the PWA only commits the sound on Save), then play it as an audible
  /// preview (the PWA's `soundSelect.onchange` → `nym.playSound(value)`,
  /// app.js:3480-3484, which previews but does NOT persist). `'none'`/unknown is
  /// silent. The PWA zeroes its 2s replay-dedupe before the preview
  /// (app.js:3481-3483) so back-to-back previews always sound — without it a
  /// second change within 2s is swallowed by the guard.
  void _onSoundChanged(SettingsController ctrl, String value) {
    _mutate((d) => d.copyWith(sound: value));
    final svc = ref.read(notificationsServiceProvider);
    svc.resetSoundDedupe();
    svc.playSound(value);
  }

  /// Clear Local Storage Cache (F10): danger confirm with the PWA copy, wipe
  /// the real on-device cache via the controller (which also mirrors the wipe
  /// in the in-memory session, app.js:4013-4030), then toast and close the
  /// settings modal (app.js:4033 `closeModal('settingsModal')`). The wipe is
  /// best-effort — the PWA swallows `resetCache` errors (app.js:4007-4011) and
  /// still confirms + closes.
  Future<void> _clearCache() async {
    final ok = await showAppConfirm(
      context,
      'Clear cached channel history, PMs, group chats, profiles, and '
      'reactions? This will not log you out or change your settings.',
      okLabel: 'Clear',
      danger: true,
    );
    if (!ok || !mounted) return;
    final controller = ref.read(nostrControllerProvider);
    // Reflect the in-flight wipe in the readout immediately.
    setState(() => _cacheReadout = null);
    try {
      await controller.clearCache();
    } catch (_) {
      // Best-effort, like the PWA's swallowed resetCache try/catch.
    }
    if (!mounted) return;
    setState(() => _cacheReadout = 'No cached data on device yet');
    _systemMessage(
        'Local storage cache cleared. Settings, group memberships, and login '
        'preserved.');
    Navigator.of(context).maybePop();
  }

  /// Reset Settings to Defaults (F11): danger confirm, wipe the exact settings
  /// keys (+ image-blur prefixes), reset moderation Sets, reload Settings from
  /// the now-cleared store so theme/layout/wallpaper revert live, then toast +
  /// close.
  Future<void> _resetSettings() async {
    final ok = await showAppConfirm(
      context,
      'Reset all settings and preferences to defaults? This will reset theme, '
      'layout, wallpaper, sound, favorited/hidden/blocked channels, blocked '
      'users, and blocked keywords. Your login, group memberships, and PMs '
      'will be preserved.',
      okLabel: 'Reset',
      danger: true,
    );
    if (!ok) return;
    final kv = ref.read(keyValueStoreProvider);
    for (final key in kSettingsResetKeys) {
      kv.remove(key);
    }
    // Per-pubkey image-blur keys (`nym_image_blur_<pubkey>`): the store can't
    // enumerate keys, so clear the self entry explicitly (the only one this
    // device writes via setBlurImages).
    final self = ref.read(appStateProvider).selfPubkey;
    if (self.isNotEmpty) kv.remove(StorageKeys.imageBlurFor(self));

    // Reset the in-memory moderation Sets (pinned/hidden/blocked/keywords).
    final notifier = ref.read(appStateProvider.notifier);
    // `nym.pinnedChannels = new Set()` + `updateChannelPins()` (app.js:4090,
    // 4101): un-pin every favorited channel so the stars (and the
    // hide-non-pinned filter) clear immediately, not on the next relaunch.
    // `togglePin` notifies per removal; #nymchat is never in the set (it can
    // neither be pinned nor unpinned).
    for (final key in ref.read(appStateProvider).pinnedChannels.toList()) {
      notifier.togglePin(key);
    }
    for (final pk in ref.read(appStateProvider).blockedUsers.toList()) {
      notifier.removeBlockedUser(pk);
    }
    for (final kw in ref.read(appStateProvider).blockedKeywords.toList()) {
      notifier.removeBlockedKeyword(kw);
    }
    for (final key in ref.read(appStateProvider).hiddenChannels.toList()) {
      notifier.removeHiddenChannel(key);
    }
    for (final key in ref.read(appStateProvider).blockedChannels.toList()) {
      notifier.removeBlockedChannel(key);
    }

    // F11 follow-up: rebuild Settings from the now-cleared store so every
    // synced/visual default (theme, color-mode, message layout, wallpaper,
    // text size, transparency, …) reverts immediately without a relaunch.
    // This mirrors the PWA's post-reset re-apply of color-mode/wallpaper('none')
    // /layout('bubbles') (app.js:4095-4100): rebuilding `Settings.fromStore`
    // drives all of those reactively here.
    ref.read(settingsProvider.notifier).reloadFromStore();

    if (!mounted) return;
    _systemMessage(
        'Settings reset to defaults. Cache, group memberships, and login '
        'preserved.');
    Navigator.of(context).maybePop();
  }

  /// Transfer → Send (F9): client-side validate the recipient pubkey and show
  /// the matching inline error (shop.js:1767 `executeSettingsTransfer`). On a
  /// valid recipient, publish the gift-wrapped kind-30078 settings transfer via
  /// the controller, then mirror the PWA's success/error states: clear the input
  /// + "Settings transfer sent to <8>...!" system message on success, or the
  /// "Failed to send settings transfer." inline error otherwise.
  Future<void> _sendTransfer() async {
    if (_transferSending) return;
    final raw = _transferPubkeyController.text.trim().toLowerCase();
    final err = validateTransferPubkey(
      raw,
      selfPubkey: ref.read(appStateProvider).selfPubkey,
    );
    if (err != null) {
      setState(() => _transferError = err);
      return;
    }
    // `_canSendGiftWraps()` precondition (shop.js:1788-1791): gift wraps need a
    // signer-capable identity; without one show the PWA's exact error.
    if (ref.read(nostrControllerProvider).identity == null) {
      setState(() =>
          _transferError = 'Settings transfer requires a logged-in account.');
      return;
    }
    setState(() {
      _transferError = null;
      _transferSending = true;
    });
    bool ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).sendSettingsTransfer(raw);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _transferSending = false);
    if (ok) {
      // PWA success path: clear the input + confirm with the truncated pubkey.
      _transferPubkeyController.clear();
      _systemMessage('Settings transfer sent to ${raw.substring(0, 8)}...!');
    } else {
      setState(() => _transferError =
          'Failed to send settings transfer. Please try again.');
    }
  }

  /// Resolves the proximity-sorting grant at Save time (F13 / 09-M1). Mirrors
  /// the PWA's `saveSettings` geolocation branch (app.js:3917-3950): when the
  /// staged value is enabled AND no location is cached yet, request location
  /// permission — on grant keep it on, on deny flip back to Disabled and clear
  /// the cached location. Returns the resolved enabled state for `_onSave` to
  /// persist.
  Future<bool> _resolveProximityOnSave(bool desired) async {
    if (!desired) {
      ref.read(userLocationProvider.notifier).state = null;
      return false;
    }
    // Already have a location: the PWA's `else` branch (app.js:3941-3946)
    // keeps proximity on SILENTLY — no permission re-request, no fresh GPS
    // fix, and no repeated "Location access granted…" system message.
    if (ref.read(userLocationProvider) != null) return true;
    try {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        status = await Permission.locationWhenInUse.request();
      }
      if (status.isGranted) {
        // Permission granted — now fetch the actual GPS fix (the PWA's
        // getCurrentPosition success callback, app.js:3920-3930) and store it so
        // the Haversine proximity sort can engage. A failed/timed-out fix
        // disables proximity, mirroring the PWA's error branch.
        final loc = await fetchCurrentUserLocation();
        if (loc != null) {
          ref.read(userLocationProvider.notifier).state = loc;
          _systemMessage(
              'Location access granted. Geohash channels sorted by proximity.');
          return true;
        }
        ref.read(userLocationProvider.notifier).state = null;
        _systemMessage('Location unavailable. Proximity sorting disabled.');
        return false;
      }
      ref.read(userLocationProvider.notifier).state = null;
      _systemMessage('Location access denied. Proximity sorting disabled.');
      return false;
    } catch (_) {
      ref.read(userLocationProvider.notifier).state = null;
      _systemMessage('Location access denied. Proximity sorting disabled.');
      return false;
    }
  }

  // --- Appearance -----------------------------------------------------------

  List<_GroupSpec> _appearance(Settings s, SettingsController ctrl) {
    const columnsWallpaperItems = <({bool value, String label})>[
      (value: false, label: 'Solid background'),
      (value: true, label: 'Show wallpaper through messages'),
    ];
    const transparencyItems = <({bool value, String label})>[
      (value: false, label: 'Solid'),
      (value: true, label: 'Glass'),
    ];
    // The custom-wallpaper thumbnail shown on the Upload tile when custom mode
    // is active (`initWallpaperUI`, app.js:4211-4227).
    final customWallpaperPath = s.wallpaperType == 'custom'
        ? ref.read(keyValueStoreProvider).getString(StorageKeys.wallpaperCustomUrl)
        : null;
    return [
      // Color mode segment. Live-applied (PWA auto-saves + applies on click,
      // app.js:3205-3211): commit immediately AND mirror into the draft.
      _GroupSpec(
        text: 'Light Auto Dark Auto matches your system preference',
        child: FormGroup(
          hint: 'Auto matches your system preference',
          child: SegmentGroup<ColorMode>(
            value: s.colorMode,
            segments: const [
              (value: ColorMode.light, label: 'Light'),
              (value: ColorMode.auto, label: 'Auto'),
              (value: ColorMode.dark, label: 'Dark'),
            ],
            onChanged: (v) {
              ctrl.setColorMode(v);
              _mutate((d) => d.copyWith(colorMode: v));
            },
          ),
        ),
      ),
      // Theme `<select>` (index.html:1370-1380 `#themeSelect .form-select`).
      // Live-applied (PWA `themeSelect.onchange`, app.js:3471-3476).
      _GroupSpec(
        text: 'Theme ${_optText(_themeOptions)}',
        child: FormGroup(
          label: 'Theme',
          child: FormSelect<NymThemeKey>(
            value: s.theme,
            items: _themeOptions,
            onChanged: (v) {
              ctrl.setTheme(v);
              _mutate((d) => d.copyWith(theme: v));
            },
          ),
        ),
      ),
      // Chat View (single / columns) — two preview cards (.view-option) with
      // the unconditional "Reset columns to defaults" button after the hint
      // (index.html:1401; the button has no cv-only-setting class, so it shows
      // in single-chat mode too).
      _GroupSpec(
        text: 'Chat View Single Chat (Default) Column View Single shows one '
            'conversation at a time. Column view shows channels, PMs, and '
            'group chats side by side in scrollable columns you can add, '
            'remove, and drag to reorder. Reset columns to defaults',
        child: FormGroup(
          label: 'Chat View',
          hint: 'Single shows one conversation at a time. Column view shows '
              'channels, PMs, and group chats side by side in scrollable '
              'columns you can add, remove, and drag to reorder.',
          // `.nm-h-58` (btn-small): NOT uppercase (`resetColumnView`).
          footer: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: 'Reset columns to defaults',
              uppercase: false,
              onPressed: ctrl.resetColumns,
            ),
          ),
          // Live-applied (PWA `selectChatView`, app.js:4115).
          child: _ViewPicker(
            value: s.useColumns ? 'columns' : 'single',
            onChanged: (v) {
              ctrl.setChatViewMode(v);
              _mutate((d) => d.copyWith(chatViewMode: v));
            },
          ),
        ),
      ),
      // Column Message Wallpaper (cv-only: shown under body.columns-mode,
      // styles-columns.css:64-70).
      if (s.useColumns)
        _GroupSpec(
          text: 'Column Message Wallpaper ${_optText(columnsWallpaperItems)} '
              'In column view, let your chat wallpaper show through the '
              'message area of each column instead of a solid background.',
          child: FormGroup(
            label: 'Column Message Wallpaper',
            hint: 'In column view, let your chat wallpaper show through the '
                'message area of each column instead of a solid background.',
            // Live-applied (PWA `onColumnsWallpaperChange`, app.js:2218).
            child: FormSelect<bool>(
              value: s.columnsWallpaper,
              items: columnsWallpaperItems,
              onChanged: (v) {
                ctrl.setColumnsWallpaper(v);
                _mutate((d) => d.copyWith(columnsWallpaper: v));
              },
            ),
          ),
        ),
      // Chat Wallpaper grid.
      _GroupSpec(
        text: 'Chat Wallpaper None Geometric Circuit Dots Waves Topography '
            'Hexagons Diamonds Upload Choose a background pattern or upload '
            'your own image (min 1920x1080)',
        child: FormGroup(
          label: 'Chat Wallpaper',
          hint: 'Choose a background pattern or upload your own image '
              '(min 1920x1080)',
          // Live-applied (PWA `selectWallpaper`, app.js:4159-4161).
          child: _WallpaperPicker(
            value: s.wallpaperType,
            customThumbPath: customWallpaperPath,
            uploading: _wallpaperUploading,
            onChanged: (v) {
              ctrl.setWallpaperType(v);
              _mutate((d) => d.copyWith(wallpaperType: v));
            },
            onUploadCustom: () => _uploadCustomWallpaper(ctrl),
          ),
        ),
      ),
      // Message Layout (bubbles / irc). Live-applied (PWA
      // `selectMessageLayout`, app.js:4127). The search text includes the mock
      // preview lines (they're part of the group's rendered textContent).
      _GroupSpec(
        text: 'Message Layout Bubbles (Default) IRC Style Choose between '
            "classic IRC-style or modern chat bubbles alice#e45f hey there! "
            "you#6si9 hello! bob#2t5g what's up?",
        child: FormGroup(
          label: 'Message Layout',
          hint: 'Choose between classic IRC-style or modern chat bubbles',
          child: _LayoutPicker(
            value: s.chatLayout,
            onChanged: (v) {
              ctrl.setChatLayout(v);
              _mutate((d) => d.copyWith(chatLayout: v));
            },
          ),
        ),
      ),
      // Visual Transparency.
      _GroupSpec(
        text: 'Visual Transparency ${_optText(transparencyItems)} Choose '
            'between Solid or Glass, where messages, modals, sidebars, and '
            'other surfaces are rendered with either solid backgrounds or a '
            'translucent "Glass" look.',
        child: FormGroup(
          label: 'Visual Transparency',
          hint: 'Choose between Solid or Glass, where messages, modals, '
              'sidebars, and other surfaces are rendered with either solid '
              'backgrounds or a translucent "Glass" look.',
          // Live-applied (PWA `onTransparencyChange`, app.js:2223).
          child: FormSelect<bool>(
            value: s.transparencyEnabled,
            items: transparencyItems,
            onChanged: (v) {
              ctrl.setTransparencyEnabled(v);
              _mutate((d) => d.copyWith(transparencyEnabled: v));
            },
          ),
        ),
      ),
      // Text Size slider with live preview + reset. Live-applied/committed
      // (PWA `commitTextSize`, app.js:2182).
      _GroupSpec(
        text: 'Text Size Adjust the size of all text across the app '
            '${(_textSizePreview ?? s.textSize.toDouble()).round()}px Reset',
        child: FormGroup(
          label: 'Text Size',
          hint: 'Adjust the size of all text across the app',
          child: _TextSizeRow(
            value: (_textSizePreview ?? s.textSize.toDouble()),
            onChanged: (v) => setState(() => _textSizePreview = v),
            onChangeEnd: (v) {
              ctrl.setTextSize(v.round());
              _mutate((d) => d.copyWith(textSize: v.round()));
              setState(() => _textSizePreview = null);
            },
            onReset: () {
              ctrl.setTextSize(NymTextSize.defaultSize.round());
              _mutate((d) => d.copyWith(textSize: NymTextSize.defaultSize.round()));
              setState(() => _textSizePreview = null);
            },
          ),
        ),
      ),
    ];
  }

  // --- Privacy & Security ---------------------------------------------------

  List<_GroupSpec> _privacy(Settings s, SettingsController ctrl) {
    // The moderation sets (friends / blocked users / blocked keywords) live on
    // AppState, not Settings.
    final app = ref.watch(appStateProvider);
    // `isNostrLoggedIn()` (app.js:4960): a durable Nostr identity is logged in
    // (loginMethod != null; null = ephemeral). Locks the keypair-rotation
    // control to 'persistent'.
    final nostrLoggedIn =
        ref.read(nostrControllerProvider).identity?.loginMethod != null;
    // Save-gated draft value (09-M1); locked to 'persistent' while logged in.
    final keypairValue = nostrLoggedIn ? 'persistent' : _draftKeypair;
    const keypairItems = <({String value, String label})>[
      (value: 'persistent', label: 'Disabled (reuse same keypair)'),
      (value: 'random', label: 'Enabled (new identity each session)'),
      (value: 'hardcore', label: 'Hardcore (new keypair every message)'),
    ];
    const hardcoreWarning =
        '⚠ Hardcore mode changes your identity after every sent message. PMs '
        'and group chats will not work reliably since recipients cannot reply '
        'to a constantly changing pubkey. Settings will not sync across '
        'devices.';
    const powItems = <({int value, String label})>[
      (value: 0, label: 'Disabled'),
      (value: 8, label: 'Very Low (8 bits)'),
      (value: 12, label: 'Low (12 bits)'),
      (value: 16, label: 'Medium (16 bits)'),
      (value: 20, label: 'High (20 bits)'),
      (value: 24, label: 'Very High (24 bits)'),
    ];
    const acceptItems = <({String value, String label})>[
      (value: 'enabled', label: 'Enabled'),
      (value: 'friends', label: 'Friends only'),
      (value: 'disabled', label: 'Disabled'),
    ];
    const callsWarning =
        '⚠ Audio/video calls and P2P file sharing connect peers directly over '
        'WebRTC, which can reveal your true IP address to the other party. '
        'Use a VPN or Tor to help conceal it.';
    const dmTtlItems = <({int value, String label})>[
      (value: 3600, label: '1 hour'),
      (value: 21600, label: '6 hours'),
      (value: 86400, label: '1 day'),
      (value: 259200, label: '3 days'),
      (value: 604800, label: '7 days'),
    ];
    const scopeItems = <({String value, String label})>[
      (value: 'everywhere', label: 'Enabled everywhere'),
      (value: 'pms-groups', label: 'Both PMs and group chats'),
      (value: 'pms', label: 'Only PMs'),
      (value: 'groups', label: 'Only group chats'),
      (value: 'disabled', label: 'Disabled completely'),
    ];
    const showStatusItems = <({String value, String label})>[
      (value: 'true', label: 'Enabled'),
      (value: 'friends', label: 'Friends only'),
      (value: 'false', label: 'Disabled'),
    ];
    const blurItems = <({String value, String label})>[
      (value: 'true', label: 'Enabled (blur by default)'),
      (value: 'friends', label: 'Disabled (for friends only)'),
      (value: 'false', label: 'Disabled (show all images)'),
    ];
    return [
      _GroupSpec(
        text: 'Identity Encryption Encrypt identity (nsec) key on this '
            "device… Optionally protect your saved identity's (nsec) private "
            'key with a password, PIN, passkey, or biometric (Face/Touch ID) '
            "so it can't be read from this device without unlocking. Passkeys "
            '(synced or hardware security keys) and biometrics use WebAuthn '
            'where supported, with password/PIN as the universal fallback.',
        child: FormGroup(
          label: 'Identity Encryption',
          hint: "Optionally protect your saved identity's (nsec) private key "
              'with a password, PIN, passkey, or biometric (Face/Touch ID) so '
              "it can't be read from this device without unlocking. Passkeys "
              '(synced or hardware security keys) and biometrics use WebAuthn '
              'where supported, with password/PIN as the universal fallback.',
          child: NymOutlineButton(
            label: 'Encrypt identity (nsec) key on this device…',
            // F18: open the existing vault-settings modal (identity slice).
            onPressed: () => VaultSettingsModal.open(context),
          ),
        ),
      ),
      // The hidden hardcore warning is part of the group's textContent even
      // when collapsed away in the PWA, so it's always searchable.
      _GroupSpec(
        text: 'Generate Random Keypair Per Session ${_optText(keypairItems)} '
            'Generate a new random keypair on every session restart for '
            'improved pseudonymity. When disabled, your generated keypair '
            'persists across reloads. $hardcoreWarning',
        child: FormGroup(
          label: 'Generate Random Keypair Per Session',
          hint: 'Generate a new random keypair on every session restart for '
              'improved pseudonymity. When disabled, your generated keypair '
              'persists across reloads.',
          // `#hardcoreKeypairWarning` (index.html:1541): a plain amber
          // `.form-hint.nm-h-59` line, NOT the danger `.form-warning` box.
          amberHint: keypairValue == 'hardcore' ? hardcoreWarning : null,
          child: FormSelect<String>(
            value: keypairValue,
            // Locked at 'persistent' while logged in with a Nostr identity —
            // rotation would conflict with it (app.js:3237-3241).
            disabled: nostrLoggedIn,
            tooltip: 'Not available while logged in with a Nostr identity',
            items: keypairItems,
            // Save-gated (PWA commits keypair mode in saveSettings,
            // app.js:3873-3877).
            onChanged: (v) => setState(() => _draftKeypair = v),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Proof of Work Difficulty ${_optText(powItems)} Enable for '
            'anti-spam to require messages have a minimum PoW',
        child: FormGroup(
          label: 'Proof of Work Difficulty',
          hint: 'Enable for anti-spam to require messages have a minimum PoW',
          child: FormSelect<int>(
            value: _draftPow,
            items: powItems,
            // Save-gated (PWA reads #powDifficultySelect in saveSettings).
            onChanged: (v) => setState(() => _draftPow = v),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Accept Private Messages & Group Chat Requests '
            '${_optText(acceptItems)} Control who can send you PMs and group '
            'chat invites. "Friends only" filters messages from non-friends.',
        child: FormGroup(
          label: 'Accept Private Messages & Group Chat Requests',
          hint: 'Control who can send you PMs and group chat invites. '
              '"Friends only" filters messages from non-friends.',
          child: FormSelect<String>(
            value: s.acceptPMs,
            items: acceptItems,
            onChanged: (v) => _mutate((d) => d.copyWith(acceptPMs: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Accept Audio & Video Calls ${_optText(acceptItems)} Control '
            'who can ring you with an audio or video call. "Friends only" '
            'silently ignores calls from non-friends. $callsWarning',
        child: FormGroup(
          label: 'Accept Audio & Video Calls',
          hint: 'Control who can ring you with an audio or video call. '
              '"Friends only" silently ignores calls from non-friends.',
          warning: callsWarning,
          child: FormSelect<String>(
            value: s.acceptCalls,
            items: acceptItems,
            onChanged: (v) => _mutate((d) => d.copyWith(acceptCalls: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Disappearing PM (forward secrecy) Disabled Enabled When '
            'enabled, your private messages include an "expiration" tag '
            '(NIP‑40) so relays/clients can delete them after the period '
            'chosen when enabled.',
        child: FormGroup(
          label: 'Disappearing PM (forward secrecy)',
          hint: 'When enabled, your private messages include an "expiration" '
              'tag (NIP‑40) so relays/clients can delete them after the period '
              'chosen when enabled.',
          child: FormSelect<bool>(
            value: s.dmForwardSecrecyEnabled,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled'),
            ],
            onChanged: (v) =>
                _mutate((d) => d.copyWith(dmForwardSecrecyEnabled: v)),
          ),
        ),
      ),
      // Disappear After (TTL) — shown when forward secrecy is enabled.
      if (s.dmForwardSecrecyEnabled)
        _GroupSpec(
          text: 'Disappear After ${_optText(dmTtlItems)} This sets the '
              '"expiration" timestamp on each outgoing gift‑wrapped PM.',
          child: FormGroup(
            label: 'Disappear After',
            hint: 'This sets the "expiration" timestamp on each outgoing '
                'gift‑wrapped PM.',
            child: FormSelect<int>(
              value: s.dmTtlSeconds,
              items: dmTtlItems,
              onChanged: (v) => _mutate((d) => d.copyWith(dmTtlSeconds: v)),
            ),
          ),
        ),
      _GroupSpec(
        text: 'Read Receipts ${_optText(scopeItems)} Choose where senders can '
            "see when you've read their messages (✓✓). \"Enabled everywhere\" "
            'includes PMs, group chats, and public channels.',
        child: FormGroup(
          label: 'Read Receipts',
          hint: "Choose where senders can see when you've read their messages "
              '(✓✓). "Enabled everywhere" includes PMs, group chats, and '
              'public channels.',
          child: FormSelect<String>(
            value: s.readReceiptsScope,
            items: scopeItems,
            onChanged: (v) => _mutate((d) => d.copyWith(readReceiptsScope: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Typing Indicators ${_optText(scopeItems)} Choose where others '
            'can see when you\'re typing. "Enabled everywhere" includes PMs, '
            'group chats, and public channels.',
        child: FormGroup(
          label: 'Typing Indicators',
          hint: "Choose where others can see when you're typing. "
              '"Enabled everywhere" includes PMs, group chats, and public '
              'channels.',
          child: FormSelect<String>(
            value: s.typingIndicatorsScope,
            items: scopeItems,
            onChanged: (v) =>
                _mutate((d) => d.copyWith(typingIndicatorsScope: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Show Status Indicators ${_optText(showStatusItems)} When '
            'enabled, online/away/offline status dots are shown on avatars '
            'and in user profiles. "Friends only" broadcasts a hidden status '
            'publicly while privately sharing your real status with people '
            "you've marked as friends, so only they can see it. When "
            'disabled, your status is hidden from everyone, but you can still '
            "see other people's status indicators.",
        child: FormGroup(
          label: 'Show Status Indicators',
          hint: 'When enabled, online/away/offline status dots are shown on '
              'avatars and in user profiles. "Friends only" broadcasts a '
              'hidden status publicly while privately sharing your real status '
              "with people you've marked as friends, so only they can see it. "
              'When disabled, your status is hidden from everyone, but you can '
              "still see other people's status indicators.",
          child: FormSelect<String>(
            value: s.showStatus,
            items: showStatusItems,
            onChanged: (v) => _mutate((d) => d.copyWith(showStatus: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Cache PMs & Group Chats On Device Enabled Disabled When '
            'enabled, decrypted private messages and group chats are stored '
            'on this device so they appear instantly on app launch. Disable '
            "if you'd rather not have decrypted message content kept at rest "
            'in app storage. Toggling off clears the existing cached PM/group '
            'data.',
        child: FormGroup(
          label: 'Cache PMs & Group Chats On Device',
          hint: 'When enabled, decrypted private messages and group chats are '
              'stored on this device so they appear instantly on app launch. '
              "Disable if you'd rather not have decrypted message content kept "
              'at rest in app storage. Toggling off clears the existing cached '
              'PM/group data.',
          child: FormSelect<bool>(
            value: s.cachePMs,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            // Save-gated. The existing PM/group cache is wiped on Save (only when
            // the value flipped on→off, PWA app.js:3853-3858) — handled in
            // `_onSave`, not on-change.
            onChanged: (v) => _mutate((d) => d.copyWith(cachePMs: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Blur Images from Others ${_optText(blurItems)} Blur images '
            'shared by others until clicked. Your own images are never '
            'blurred. "Friends only" shows images from friends unblurred.',
        child: FormGroup(
          label: 'Blur Images from Others',
          hint: 'Blur images shared by others until clicked. Your own images '
              'are never blurred. "Friends only" shows images from friends '
              'unblurred.',
          child: FormSelect<String>(
            value: _draftBlur,
            items: blurItems,
            // Save-gated (PWA commits blur in saveSettings, app.js:3729-3754).
            onChanged: (v) => setState(() => _draftBlur = v),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Blocked Keywords/Phrases Add keyword or phrase to block '
            'Add Keyword Remove '
            '${app.blockedKeywords.isEmpty ? 'No blocked keywords' : app.blockedKeywords.join(' ')}',
        child: FormGroup(
          label: 'Blocked Keywords/Phrases',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormInput(
                controller: _keywordController,
                hint: 'Add keyword or phrase to block',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: 'Add Keyword',
                  onPressed: () => _addKeyword(ctrl),
                ),
              ),
              const SizedBox(height: 8),
              _removableList(
                entries: app.blockedKeywords,
                emptyText: 'No blocked keywords',
                buttonLabel: 'Remove',
                labelFor: (kw) => kw,
                onRemove: (kw) {
                  ref.read(appStateProvider.notifier).removeBlockedKeyword(kw);
                  _persistBlockedKeywords();
                  // users.js:150-178 `removeBlockedKeyword`: confirm with the
                  // system pill, then `nostrSettingsSave()`.
                  _systemMessage('Unblocked keyword: "$kw"');
                  ref.read(nostrControllerProvider).syncSettings();
                },
              ),
            ],
          ),
        ),
      ),
      _GroupSpec(
        text: 'Friends Remove Friends can have special privileges like '
            'bypassing image blur and message filters. Add friends from the '
            'context menu on any user. '
            '${app.friends.isEmpty ? 'No friends added' : app.friends.map(_nymLabelFor).join(' ')}',
        child: FormGroup(
          label: 'Friends',
          hint: 'Friends can have special privileges like bypassing image '
              'blur and message filters. Add friends from the context menu on '
              'any user.',
          child: _removableList(
            entries: app.friends,
            emptyText: 'No friends added',
            buttonLabel: 'Remove',
            labelFor: _nymLabelFor,
            labelSpanFor: _nymSpanFor,
            // `removeFriendByPubkey` (users.js:1953-1961): delete + saveFriends
            // + system message + nostrSettingsSave. The controller wrapper
            // persists `nym_friends` and emits "Removed … from friends".
            onRemove: (pk) {
              final controller = ref.read(nostrControllerProvider);
              controller.toggleFriend(pk);
              controller.syncSettings();
            },
          ),
        ),
      ),
      _GroupSpec(
        text: 'Blocked Users Unblock '
            '${app.blockedUsers.isEmpty ? 'No blocked users' : app.blockedUsers.map(_nymLabelFor).join(' ')}',
        child: FormGroup(
          label: 'Blocked Users',
          child: _blockedProfilesLoading
              // `updateBlockedList` renders "Loading..." while unknown blocked
              // users' profiles are fetched (users.js:1774-1781).
              ? _emptyListBox('Loading...')
              : _removableList(
                  entries: app.blockedUsers,
                  emptyText: 'No blocked users',
                  buttonLabel: 'Unblock',
                  labelFor: _nymLabelFor,
                  labelSpanFor: _nymSpanFor,
                  // `unblockByPubkey` (users.js): delete + saveBlockedUsers +
                  // "Unblocked …" system message + nostrSettingsSave. The
                  // controller wrapper persists `nym_blocked` + emits the
                  // message.
                  onRemove: (pk) {
                    final controller = ref.read(nostrControllerProvider);
                    controller.unblockUser(pk);
                    controller.syncSettings();
                  },
                ),
        ),
      ),
    ];
  }

  /// The rich `name` + dim `#suffix` span for a moderation-list row
  /// (users.js `getNymHtmlFromPubkey` → `dimNymSuffix`: the trailing 4-hex
  /// suffix renders in `.nym-suffix` — opacity .7, 0.9em, weight 100).
  TextSpan _nymSpanFor(String pubkey) {
    final c = context.nym;
    final nym = _nymLabelFor(pubkey);
    final m = RegExp(r'^([\s\S]*?)#([0-9a-f]{4})$', caseSensitive: false)
        .firstMatch(nym);
    if (m == null) {
      return TextSpan(
          text: nym, style: TextStyle(color: c.text, fontSize: 13));
    }
    return TextSpan(
      children: [
        TextSpan(
            text: m.group(1), style: TextStyle(color: c.text, fontSize: 13)),
        TextSpan(
          text: '#${m.group(2)}',
          style: TextStyle(
            color: c.text.withValues(alpha: 0.7),
            fontSize: 13 * 0.9,
            fontWeight: FontWeight.w100,
          ),
        ),
      ],
    );
  }

  // --- Messaging & Display --------------------------------------------------

  List<_GroupSpec> _messaging(Settings s, SettingsController ctrl) {
    const timeFormatItems = <({String value, String label})>[
      (value: '24hr', label: '24-hour (14:30)'),
      (value: '12hr', label: '12-hour (2:30 PM)'),
    ];
    const dateFormatItems = <({String value, String label})>[
      (value: 'default', label: 'Default (May 28, 2026)'),
      (value: 'mdy', label: 'MM/DD/YYYY (05/28/2026)'),
      (value: 'dmy', label: 'DD/MM/YYYY (28/05/2026)'),
      (value: 'ymd', label: 'YYYY-MM-DD (2026-05-28)'),
    ];
    const nickStyleItems = <({String value, String label})>[
      (value: 'fancy', label: 'Fancy (adjective_noun)'),
      (value: 'simple', label: 'Simple (nym1234)'),
    ];
    return [
      _GroupSpec(
        text: 'Translation Language ${_optText(_translationLanguages)} Choose '
            'your preferred language for translating messages via the context '
            'menu.',
        child: FormGroup(
          label: 'Translation Language',
          hint: 'Choose your preferred language for translating messages via '
              'the context menu.',
          child: FormSelect<String>(
            value: s.translateLanguage,
            items: _translationLanguages,
            onChanged: (v) => _mutate((d) => d.copyWith(translateLanguage: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Notification Sound ${_optText(_soundOptions)}',
        child: FormGroup(
          label: 'Notification Sound',
          child: FormSelect<String>(
            value: s.sound,
            items: _soundOptions,
            // Persist + play an audible preview of the chosen tone.
            onChanged: (v) => _onSoundChanged(ctrl, v),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Auto-scroll Messages Enabled Disabled',
        child: FormGroup(
          label: 'Auto-scroll Messages',
          child: FormSelect<bool>(
            value: s.autoscroll,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(autoscroll: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Show Timestamps Show Hide',
        child: FormGroup(
          label: 'Show Timestamps',
          child: FormSelect<bool>(
            value: s.showTimestamps,
            items: const [
              (value: true, label: 'Show'),
              (value: false, label: 'Hide'),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(showTimestamps: v)),
          ),
        ),
      ),
      // Time/Date Format are hidden when Show Timestamps = Hide (09-M2),
      // mirroring the PWA's `#timeFormatGroup`/`#dateFormatGroup` display
      // toggle (app.js:3492-3499 + the #timestampSelect change listener
      // app.js:6843-6852). `s` is the draft, so toggling re-renders this.
      if (s.showTimestamps) ...[
        _GroupSpec(
          text: 'Time Format ${_optText(timeFormatItems)}',
          child: FormGroup(
            label: 'Time Format',
            child: FormSelect<String>(
              value: s.timeFormat,
              items: timeFormatItems,
              onChanged: (v) => _mutate((d) => d.copyWith(timeFormat: v)),
            ),
          ),
        ),
        _GroupSpec(
          text: 'Date Format ${_optText(dateFormatItems)} Used in the full '
              'timestamp shown when tapping a message time',
          child: FormGroup(
            label: 'Date Format',
            hint:
                'Used in the full timestamp shown when tapping a message time',
            child: FormSelect<String>(
              value: s.dateFormat,
              items: dateFormatItems,
              onChanged: (v) => _mutate((d) => d.copyWith(dateFormat: v)),
            ),
          ),
        ),
      ],
      _GroupSpec(
        text: 'Random Nickname Style ${_optText(nickStyleItems)} Style used '
            'when generating random nicknames',
        child: FormGroup(
          label: 'Random Nickname Style',
          hint: 'Style used when generating random nicknames',
          child: FormSelect<String>(
            value: s.nickStyle,
            items: nickStyleItems,
            onChanged: (v) => _mutate((d) => d.copyWith(nickStyle: v)),
          ),
        ),
      ),
      // NOTE: #autoEphemeralSettingGroup is permanently hidden in the PWA
      // (nm-hidden), so no control renders here — but its save-time key
      // cleanup is mirrored in `_onSave` (app.js:3862-3870).
    ];
  }

  // --- Channels -------------------------------------------------------------

  List<_GroupSpec> _channels(Settings s, SettingsController ctrl) {
    final state = ref.watch(appStateProvider);
    const gcPmOnlyItems = <({bool value, String label})>[
      (value: false, label: 'Disabled (show geohash channels)'),
      (value: true, label: 'Enabled (group chats & PMs only)'),
    ];
    const proximityItems = <({bool value, String label})>[
      (value: false, label: 'Disabled'),
      (value: true, label: 'Enabled (requires location access)'),
    ];
    const hideNonPinnedItems = <({bool value, String label})>[
      (value: false, label: 'Disabled'),
      (value: true, label: 'Enabled (only show favorited channels)'),
    ];
    return [
      _GroupSpec(
        text: 'Group Chats & PMs Only Mode ${_optText(gcPmOnlyItems)} Hides '
            'all geohash channels and focuses the app on group chats and '
            'private messages only. Reduces bandwidth by skipping channel '
            'subscriptions.',
        child: FormGroup(
          label: 'Group Chats & PMs Only Mode',
          hint: 'Hides all geohash channels and focuses the app on group '
              'chats and private messages only. Reduces bandwidth by skipping '
              'channel subscriptions.',
          child: FormSelect<bool>(
            value: s.groupChatPMOnlyMode,
            items: gcPmOnlyItems,
            onChanged: (v) =>
                _mutate((d) => d.copyWith(groupChatPMOnlyMode: v)),
          ),
        ),
      ),
      // Geohash-specific settings (data-geohash-setting) are hidden in
      // group-chat/PM-only mode (F6; app.js:3598-3607).
      if (!s.groupChatPMOnlyMode) ...[
        _GroupSpec(
          text: 'Sort Geohash Channels by Proximity ${_optText(proximityItems)} '
              'Sort geohash channels by distance from your location',
          child: FormGroup(
            label: 'Sort Geohash Channels by Proximity',
            hint: 'Sort geohash channels by distance from your location',
            // Save-gated: the PWA reads `#proximitySelect` and runs the
            // geolocation permission flow inside `saveSettings`
            // (app.js:3728/3917-3950), not on-change. The grant/deny resolution
            // is handled in `_onSave`.
            child: FormSelect<bool>(
              value: s.sortByProximity,
              items: proximityItems,
              onChanged: (v) => _mutate((d) => d.copyWith(sortByProximity: v)),
            ),
          ),
        ),
        _GroupSpec(
          text: 'Default Landing Channel Type to search or select a '
              'channel... Channel to load when you first open or reload the '
              'app',
          child: FormGroup(
            label: 'Default Landing Channel',
            hint: 'Channel to load when you first open or reload the app',
            child: _landingChannelField(state.channels),
          ),
        ),
        _GroupSpec(
          text: 'Hide All Non-Favorited Channels '
              '${_optText(hideNonPinnedItems)} When enabled, only your '
              'favorited channels will appear in the sidebar',
          child: FormGroup(
            label: 'Hide All Non-Favorited Channels',
            hint: 'When enabled, only your favorited channels will appear in '
                'the sidebar',
            child: FormSelect<bool>(
              value: s.hideNonPinned,
              items: hideNonPinnedItems,
              onChanged: (v) => _mutate((d) => d.copyWith(hideNonPinned: v)),
            ),
          ),
        ),
        _GroupSpec(
          text: 'Hidden Channels Unhide '
              '${state.hiddenChannels.isEmpty ? 'No hidden channels' : state.hiddenChannels.map(_hiddenChannelLabel).join(' ')}',
          child: FormGroup(
            label: 'Hidden Channels',
            child: _removableList(
              entries: state.hiddenChannels,
              emptyText: 'No hidden channels',
              buttonLabel: 'Unhide',
              // `updateHiddenChannelsList` (channels.js:942-945): `#key` plus
              // the decoded geohash location, e.g. `#9q (37.77°N, 122.41°W)`.
              labelFor: _hiddenChannelLabel,
              // `unhideChannelFromSettings` (channels.js:955-961): delete +
              // saveHiddenChannels + nostrSettingsSave + applyHiddenChannels.
              onRemove: (key) {
                ref.read(appStateProvider.notifier).removeHiddenChannel(key);
                _persistStringSet(StorageKeys.hiddenChannels,
                    ref.read(appStateProvider).hiddenChannels);
                ref.read(nostrControllerProvider).syncSettings();
              },
            ),
          ),
        ),
        _GroupSpec(
          text: 'Blocked Channels Unblock '
              '${state.blockedChannels.isEmpty ? 'No blocked channels' : state.blockedChannels.map(_blockedChannelLabel).join(' ')}',
          child: FormGroup(
            label: 'Blocked Channels',
            child: _removableList(
              entries: state.blockedChannels,
              emptyText: 'No blocked channels',
              buttonLabel: 'Unblock',
              // `updateBlockedChannelsList` (channels.js:915): geohash keys
              // render `#key [GEO]`, ephemeral keys `#key [EPH]`.
              labelFor: _blockedChannelLabel,
              // `unblockChannelFromSettings` (channels.js:926-932) →
              // `unblockChannel(key, geohash)`: delete + saveBlockedChannels +
              // nostrSettingsSave + re-add the channel to the sidebar.
              onRemove: (key) {
                final controller = ref.read(nostrControllerProvider);
                final isGeo = isValidGeohash(key);
                ref
                    .read(appStateProvider.notifier)
                    .unblockChannel(key, geohash: isGeo ? key : '');
                _persistStringSet(StorageKeys.blockedChannels,
                    ref.read(appStateProvider).blockedChannels);
                // Re-adding through the controller is idempotent and persists
                // the rejoined channel list (the PWA's `addChannel` path).
                controller.addChannel(key, geohash: isGeo ? key : '');
                controller.syncSettings();
              },
            ),
          ),
        ),
      ],
    ];
  }

  /// `#key (37.77°N, 122.41°W)` for a hidden geohash channel, bare `#key`
  /// otherwise (channels.js:942-945).
  String _hiddenChannelLabel(String key) {
    final loc = geohashLocationLabel(key);
    return loc.isEmpty ? '#$key' : '#$key ($loc)';
  }

  /// `#key [GEO]` for a geohash channel, `#key [EPH]` for an ephemeral one
  /// (channels.js:915).
  String _blockedChannelLabel(String key) =>
      isValidGeohash(key) ? '#$key [GEO]' : '#$key [EPH]';

  /// Default-landing-channel searchable field (F8): a text input that, when
  /// focused/typed, shows a grouped suggestions overlay (Common / Joined
  /// geohash channels). Picking an option seeds the field + `_landing`; SAVE
  /// persists it.
  Widget _landingChannelField(List<ChannelEntry> channels) {
    final c = context.nym;
    final options = buildLandingChannelOptions(channels);
    final query = _landingController.text;
    final filterLower = query.toLowerCase().replaceFirst(RegExp(r'^#'), '');
    final filtered = (query.isEmpty || query == _landing.label)
        ? options
        : options.where((o) => o.searchText.contains(filterLower)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormInput(
          controller: _landingController,
          focusNode: _landingFocus,
          hint: 'Type to search or select a channel...',
          onChanged: (_) => setState(() => _landingOpen = true),
          onTap: () => setState(() => _landingOpen = true),
        ),
        if (_landingOpen)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: c.bgTertiary,
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('No channels found',
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: _buildLandingRows(filtered, c),
                  ),
          ),
      ],
    );
  }

  List<Widget> _buildLandingRows(
      List<LandingChannelOption> options, NymColors c) {
    final rows = <Widget>[];
    String? lastGroup;
    for (final o in options) {
      if (o.group != lastGroup) {
        lastGroup = o.group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text(
            o.group,
            style: TextStyle(
              color: c.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ));
      }
      // `.channel-dropdown-option.nm-app-3 { padding: 8px 12px; color:
      // var(--text) }` (no-inline.css:103) — plain rows with no selected
      // highlight (the PWA's hover handler sets `var(--background)`, an
      // undefined variable, so even hover renders no visible tint;
      // app.js:3428-3441).
      rows.add(InkWell(
        onTap: () {
          setState(() {
            _landing = o.value;
            _landingController.text = o.label;
            _landingOpen = false;
          });
          _landingFocus.unfocus();
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            o.label,
            style: TextStyle(color: c.text, fontSize: 13),
          ),
        ),
      ));
    }
    return rows;
  }

  // --- Mobile Gestures ------------------------------------------------------

  List<_GroupSpec> _mobile(Settings s, SettingsController ctrl) {
    const swipeActions = <({String value, String label})>[
      (value: 'quote', label: 'Quote Reply'),
      (value: 'translate', label: 'Translate'),
      (value: 'copy', label: 'Copy Message'),
      (value: 'react', label: 'Quick React'),
      (value: 'zap', label: 'Zap Bitcoin'),
      (value: 'slap', label: 'Slap with Trout'),
      (value: 'hug', label: 'Give Warm Hug'),
      (value: 'none', label: 'None'),
    ];
    // Swipe-right's options list leads with Translate in the PWA markup.
    const swipeRightActions = <({String value, String label})>[
      (value: 'translate', label: 'Translate'),
      (value: 'quote', label: 'Quote Reply'),
      (value: 'copy', label: 'Copy Message'),
      (value: 'react', label: 'Quick React'),
      (value: 'zap', label: 'Zap Bitcoin'),
      (value: 'slap', label: 'Slap with Trout'),
      (value: 'hug', label: 'Give Warm Hug'),
      (value: 'none', label: 'None'),
    ];
    const thresholdItems = <({int value, String label})>[
      (value: 40, label: 'High (40px)'),
      (value: 60, label: 'Medium (60px)'),
      (value: 80, label: 'Low (80px)'),
      (value: 100, label: 'Very Low (100px)'),
    ];
    return [
      _GroupSpec(
        text: 'Swipe Gestures (Mobile) Enabled Disabled Swipe a message '
            'horizontally to trigger an action. Disable to turn off all swipe '
            'gestures on messages.',
        child: FormGroup(
          label: 'Swipe Gestures (Mobile)',
          hint: 'Swipe a message horizontally to trigger an action. Disable '
              'to turn off all swipe gestures on messages.',
          child: FormSelect<bool>(
            value: s.gesturesEnabled,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(gesturesEnabled: v)),
          ),
        ),
      ),
      // Swipe sub-settings hide when gestures are disabled (F16;
      // app.js:3305 updateSwipeSubsettings).
      if (s.gesturesEnabled) ...[
        _GroupSpec(
          text: 'Swipe Left Action ${_optText(swipeActions)} Action triggered '
              'when swiping a message to the left.',
          child: FormGroup(
            label: 'Swipe Left Action',
            hint: 'Action triggered when swiping a message to the left.',
            child: FormSelect<String>(
              value: s.swipeLeftAction,
              items: swipeActions,
              onChanged: (v) => _onSwipeActionChanged(
                ctrl,
                prev: s.swipeLeftAction,
                next: v,
                apply: (d) => d.copyWith(swipeLeftAction: v),
              ),
            ),
          ),
        ),
        _GroupSpec(
          text: 'Swipe Right Action ${_optText(swipeRightActions)} Action '
              'triggered when swiping a message to the right.',
          child: FormGroup(
            label: 'Swipe Right Action',
            hint: 'Action triggered when swiping a message to the right.',
            child: FormSelect<String>(
              value: s.swipeRightAction,
              items: swipeRightActions,
              onChanged: (v) => _onSwipeActionChanged(
                ctrl,
                prev: s.swipeRightAction,
                next: v,
                apply: (d) => d.copyWith(swipeRightAction: v),
              ),
            ),
          ),
        ),
        // The Quick-React-emoji group only shows when a swipe action is set
        // to "Quick React" (the PWA's `needsEmoji`).
        if (s.swipeLeftAction == 'react' || s.swipeRightAction == 'react')
          _GroupSpec(
            text: 'Quick React Emoji ${s.swipeReactEmoji} Change Emoji always '
                'used when a swipe gesture is set to "Quick React". Tap to '
                'choose from the full emoji picker.',
            child: FormGroup(
              label: 'Quick React Emoji',
              hint: 'Emoji always used when a swipe gesture is set to "Quick '
                  'React". Tap to choose from the full emoji picker.',
              // The preview renders a custom `:code:` emoji as its image
              // (02-G; PWA `renderEmojiPreview`, app.js:3284-3292 — an
              // anchored `^:code:$` match, so [wholeStringOnly]). A unicode
              // emoji inherits the button's 22px font (`.nm-h-60`,
              // no-inline.css:78); a custom-emoji image is 33x33 with
              // `vertical-align: middle` (`#swipeReactEmojiPreview
              // img.custom-emoji`, styles-chat.css:1650-1656).
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InlineEmojiText(
                      text: s.swipeReactEmoji,
                      style: const TextStyle(fontSize: 22, height: 1),
                      emojiSize: 33,
                      wholeStringOnly: true,
                      emojiAlignment: PlaceholderAlignment.middle,
                    ),
                    const SizedBox(width: 12),
                    NymOutlineButton(
                      label: 'Change',
                      uppercase: false,
                      onPressed: () => _openSwipeReactPicker(ctrl),
                    ),
                  ],
                ),
              ),
            ),
          ),
        _GroupSpec(
          text: 'Swipe Sensitivity ${_optText(thresholdItems)} How far you '
              'need to swipe before the action fires. Higher sensitivity '
              'means a shorter swipe.',
          child: FormGroup(
            label: 'Swipe Sensitivity',
            hint: 'How far you need to swipe before the action fires. Higher '
                'sensitivity means a shorter swipe.',
            child: FormSelect<int>(
              value: s.swipeThreshold,
              items: thresholdItems,
              onChanged: (v) => _mutate((d) => d.copyWith(swipeThreshold: v)),
            ),
          ),
        ),
      ],
    ];
  }

  // --- Data & Backup --------------------------------------------------------

  List<_GroupSpec> _data(Settings s, SettingsController ctrl) {
    final transfers = ref.watch(pendingUserSettingsTransfersProvider);
    return [
      _GroupSpec(
        text: 'Low Data Mode Disabled Enabled Reduces bandwidth by connecting '
            'to only 5 default relays and loading geo relays on-demand when '
            'entering channels',
        child: FormGroup(
          label: 'Low Data Mode',
          hint: 'Reduces bandwidth by connecting to only 5 default relays and '
              'loading geo relays on-demand when entering channels',
          // Inside the settings modal the PWA renders Low Data Mode as a
          // Disabled/Enabled `<select>` (index.html:1963-1970, `#lowDataModeSelect`),
          // consistent with its sibling `.form-select`s — NOT a switch (09-M3).
          // Save-gated like the other dropdowns (09-M1).
          child: FormSelect<bool>(
            value: s.lowDataMode,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled'),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(lowDataMode: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: 'Transfer Settings to Another User Recipient hex pubkey '
            '(64 chars) Send Transfers your nickname, avatar, and all '
            'preferences to the specified pubkey',
        child: FormGroup(
          label: 'Transfer Settings to Another User',
          hint: 'Transfers your nickname, avatar, and all preferences to the '
              'specified pubkey',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FormInput(
                      controller: _transferPubkeyController,
                      hint: 'Recipient hex pubkey (64 chars)',
                      onChanged: (_) {
                        if (_transferError != null) {
                          setState(() => _transferError = null);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  NymOutlineButton(
                    label: _transferSending ? 'Sending…' : 'Send',
                    onPressed: _transferSending ? () {} : _sendTransfer,
                  ),
                ],
              ),
              // Inline validation error (F9; #settingsTransferError).
              if (_transferError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _transferError!,
                  style: TextStyle(
                      color: context.nym.danger, fontSize: 11, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ),
      _GroupSpec(
        text: 'Pending Settings Transfers Accept Reject '
            '${transfers.isEmpty ? 'No pending transfers' : transfers.map((t) => t.fromNym).join(' ')}',
        child: FormGroup(
          label: 'Pending Settings Transfers',
          child: _pendingTransfers(),
        ),
      ),
      _GroupSpec(
        text: 'Clear Local Storage Cache ${_cacheReadout ?? 'Calculating…'} '
            'Clears the on-device app cache (channel history, PMs, group '
            'chats, profiles, reactions). Preserves your login, settings, '
            'group memberships, and flair purchases.',
        child: FormGroup(
          hint: 'Clears the on-device app cache (channel history, PMs, group '
              'chats, profiles, reactions). Preserves your login, settings, '
              'group memberships, and flair purchases.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Real on-device cache readout (F7; refreshAppCacheSize,
              // app.js:3681-3716). Shows the PWA's "Calculating…" placeholder
              // until the async read resolves, then the auto-scaled size +
              // item breakdown.
              Text(
                _cacheReadout ?? 'Calculating…',
                style: TextStyle(color: context.nym.textDim, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: 'Clear Local Storage Cache',
                  onPressed: _clearCache,
                ),
              ),
            ],
          ),
        ),
      ),
      _GroupSpec(
        text: 'Reset Settings to Defaults Resets preferences (theme, layout, '
            'wallpaper, sound, favorited/hidden/blocked channels, blocked '
            'users, blocked keywords) to defaults. Preserves your login, '
            'group memberships, PM history, and flair purchases.',
        child: FormGroup(
          hint: 'Resets preferences (theme, layout, wallpaper, sound, '
              'favorited/hidden/blocked channels, blocked users, blocked '
              'keywords) to defaults. Preserves your login, group '
              'memberships, PM history, and flair purchases.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: 'Reset Settings to Defaults',
              onPressed: _resetSettings,
            ),
          ),
        ),
      ),
    ];
  }

  /// The list container chrome shared by the moderation lists and the
  /// pending-transfers list (`.blocked-list,.keyword-list`): `padding:10px;
  /// border:1px glass-border; border-radius:var(--radius-sm); background:
  /// rgba(255,255,255,.03); max-height:200px; overflow-y:auto`.
  Widget _listBox({required Widget child}) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: c.isLight
            ? c.bg
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: child,
      ),
    );
  }

  Widget _emptyListBox(String text) {
    final c = context.nym;
    // Empty state: the dim `.nm-dim12` text inside the same padded list box.
    return _listBox(
      child: Text(
        text,
        style: TextStyle(color: c.textDim, fontSize: 12),
      ),
    );
  }

  /// A populated moderation list (`.keyword-list` / `.blocked-list`): one row
  /// per entry with a trailing Remove/Unblock button, falling back to the dim
  /// empty placeholder when [entries] is empty (F1). Each row resolves a
  /// display label via [labelFor] — or, when [labelSpanFor] is provided, a
  /// rich span (the PWA's `getNymHtmlFromPubkey` rows: base nym + dim
  /// `.nym-suffix`). Rows are borderless (PWA `.blocked-item`/`.keyword-item`
  /// have no dividers), `padding:5px; margin:2px 0`.
  Widget _removableList({
    required Iterable<String> entries,
    required String emptyText,
    required String buttonLabel,
    required String Function(String entry) labelFor,
    TextSpan Function(String entry)? labelSpanFor,
    required void Function(String entry) onRemove,
  }) {
    final items = entries.toList();
    if (items.isEmpty) return _emptyListBox(emptyText);
    final c = context.nym;
    return _listBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              // `.blocked-item/.keyword-item { padding: 5px; margin: 2px 0 }`.
              padding: EdgeInsets.only(
                top: i == 0 ? 0 : 4,
                bottom: 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: labelSpanFor != null
                        ? Text.rich(
                            labelSpanFor(items[i]),
                            overflow: TextOverflow.ellipsis,
                          )
                        : Text(
                            labelFor(items[i]),
                            style: TextStyle(color: c.text, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  const SizedBox(width: 8),
                  // `.unblock-btn`/`.remove-keyword-btn`: small red pill,
                  // label as written ('Remove'/'Unblock'/'Unhide').
                  DangerPillButton(
                    label: buttonLabel,
                    onPressed: () => onRemove(items[i]),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Pending Settings Transfers list (F17; shop.js:1996
  /// `renderPendingSettingsTransfers`): one card per inbound USER-TO-USER
  /// transfer (from another account's `executeSettingsTransfer`) showing the
  /// sender nym, `Verified sender key: <first16>…<last8>`, the transfer date,
  /// and an "Includes:" summary, with Accept/Reject buttons wired to
  /// [NostrController.acceptUserSettingsTransfer] /
  /// [NostrController.rejectUserSettingsTransfer]. Falls back to the dim
  /// placeholder when there are no offers. (The controller's own-device D1
  /// sections auto-apply and never appear here, matching the PWA.)
  Widget _pendingTransfers() {
    final transfers = ref.watch(pendingUserSettingsTransfersProvider);
    if (transfers.isEmpty) return _emptyListBox('No pending transfers');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in transfers) _transferRow(t),
      ],
    );
  }

  /// One `.nm-shop-27` transfer card (shop.js:2005-2018): info column (flex 1)
  /// + Accept/Reject `.icon-btn`s in a trailing `.nm-shop-32` row (gap 6px,
  /// margin-left 8px). Card chrome: `padding:8px; margin-bottom:6px;
  /// background:rgba(255,255,255,.03); border:1px glass-border;
  /// border-radius:8px`, contents vertically centered.
  Widget _transferRow(UserSettingsTransfer t) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    // `Includes: ${t.nickname ? 'nickname' : ''}${t.avatarUrl ? ', avatar' :
    // ''}${t.settings ? ', preferences' : ''}` (shop.js:2013) — including the
    // PWA's leading-comma quirk when the nickname is absent. `settings` is
    // always present (the ingest guard requires it), so ', preferences'
    // always renders.
    final includes = StringBuffer('Includes: ');
    if ((t.nickname ?? '').isNotEmpty) includes.write('nickname');
    if ((t.avatarUrl ?? '').isNotEmpty) includes.write(', avatar');
    includes.write(', preferences');
    final dimStyle = TextStyle(color: c.textDim, fontSize: 11);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.isLight ? c.bg : Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // `.nm-shop-29`: sender nym, 13px/500.
                Text(
                  t.fromNym,
                  style: TextStyle(
                      color: c.text, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // `.nm-shop-30` with `title="<full pubkey>"` → Tooltip.
                Tooltip(
                  message: t.fromPubkey,
                  child: Text(
                    'Verified sender key: '
                    '${abbreviateTransferKey(t.fromPubkey)}',
                    style: dimStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                // `new Date(t.transferredAt * 1000).toLocaleString()`.
                Text(formatTransferTimestamp(t.transferredAt), style: dimStyle),
                // `.nm-shop-31`.
                Text(includes.toString(), style: dimStyle),
              ],
            ),
          ),
          const SizedBox(width: 8),
          NymOutlineButton(
            label: 'Accept',
            onPressed: () =>
                unawaited(controller.acceptUserSettingsTransfer(t.eventId)),
          ),
          const SizedBox(width: 6),
          NymOutlineButton(
            label: 'Reject',
            danger: true,
            onPressed: () => controller.rejectUserSettingsTransfer(t.eventId),
          ),
        ],
      ),
    );
  }

  /// Resolves a `base#suffix` display nym for a pubkey, preferring a known user
  /// entry and falling back to the abbreviated pubkey (users.js
  /// `getNymFromPubkey`).
  String _nymLabelFor(String pubkey) {
    final user = ref.read(appStateProvider).users[pubkey];
    if (user != null && user.nym.isNotEmpty) return user.nym;
    return getNymFromPubkey('nym', pubkey);
  }
}

/// Section descriptor: a titled collection of searchable form groups.
class _SectionSpec {
  _SectionSpec({
    required this.key,
    required this.title,
    required this.groups,
  });
  final String key;
  final String title;
  final List<_GroupSpec> groups;
}

/// One searchable `.form-group` (inline-bindings.js `filterSettings` hides
/// non-matching groups individually): [text] is the group's full rendered
/// text — label + hints + option labels + placeholders + list contents.
class _GroupSpec {
  const _GroupSpec({required this.text, required this.child});
  final String text;
  final Widget child;
}

/// The KV key for the persisted section collapse layout
/// (inline-bindings.js:28-46 `persist`/`restoreSettingsSectionState`).
const String _kSettingsSectionsCollapsedKey = 'nym_settings_sections_collapsed';

// === Pickers ================================================================

/// Theme options, verbatim and in order from `#themeSelect`
/// (index.html:1370-1380) — a standard `.form-select` dropdown.
const List<({NymThemeKey value, String label})> _themeOptions = [
  (value: NymThemeKey.bitchat, label: 'Bitchat (Multicolor)'),
  (value: NymThemeKey.matrix, label: 'Matrix Green'),
  (value: NymThemeKey.amber, label: 'Amber Terminal'),
  (value: NymThemeKey.cyber, label: 'Cyberpunk'),
  (value: NymThemeKey.hacker, label: 'Hacker Blue'),
  (value: NymThemeKey.ghost, label: 'Ghost (B&W)'),
];

/// Wallpaper picker: 3-column grid of the 8 built-in patterns + Upload, with
/// the selected option ringed in the accent color.
class _WallpaperPicker extends StatelessWidget {
  const _WallpaperPicker({
    required this.value,
    required this.onChanged,
    required this.onUploadCustom,
    this.customThumbPath,
    this.uploading = false,
  });
  final String value;
  final ValueChanged<String> onChanged;

  /// Tapping the "Upload" tile runs this instead of `onChanged('custom')`: it
  /// picks an image, persists it and selects custom mode (the picker stays
  /// stateless — the async work lives in the parent state). PWA ref:
  /// `triggerWallpaperUpload`/`handleWallpaperUpload` (app.js:4173-4209).
  final Future<void> Function() onUploadCustom;

  /// The active custom wallpaper's on-device path, painted as the Upload
  /// tile's background thumbnail when custom mode is selected
  /// (`initWallpaperUI`, app.js:4211-4227 + `handleWallpaperUpload`'s
  /// post-upload thumbnail, app.js:4190-4192). Null → generic upload glyph.
  final String? customThumbPath;

  /// The in-flight "Uploading..." state on the Upload tile (app.js:4184).
  final bool uploading;

  static const _options = <({String id, String label})>[
    (id: 'none', label: 'None'),
    (id: 'geometric', label: 'Geometric'),
    (id: 'circuit', label: 'Circuit'),
    (id: 'dots', label: 'Dots'),
    (id: 'waves', label: 'Waves'),
    (id: 'topography', label: 'Topography'),
    (id: 'hexagons', label: 'Hexagons'),
    (id: 'diamonds', label: 'Diamonds'),
    (id: 'custom', label: 'Upload'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.wallpaper-grid { grid-template-columns: repeat(3, 1fr); gap: 10px }`
    // (styles-features.css:3133-3138). Row heights follow each tile's own
    // 16:10 preview + label, so plain Rows beat GridView's fixed-aspect cells.
    return Column(
      children: [
        for (var row = 0; row < _options.length; row += 3) ...[
          if (row > 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = row; i < row + 3 && i < _options.length; i++) ...[
                if (i > row) const SizedBox(width: 10),
                Expanded(child: _option(c, _options[i])),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// One `.wallpaper-option` tile (styles-features.css:3140-3182): padding 6,
  /// an ALWAYS-2px border (transparent at rest, so selecting never shifts
  /// content), radius 12; `.selected` rings the WHOLE option — preview + label
  /// — in `--primary` and tints its background primary@0.1.
  Widget _option(NymColors c, ({String id, String label}) o) {
    final selected = o.id == value;
    return GestureDetector(
      onTap: o.id == 'custom' ? onUploadCustom : () => onChanged(o.id),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: selected ? c.primaryA(0.1) : null,
          borderRadius: NymRadius.rsm,
          border: Border.all(
            color: selected ? c.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // `.wallpaper-preview`: 16:10, radius 8, and a CONSTANT 1px border
            // (glass dark / black@0.12 light) regardless of selection.
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Container(
                decoration: BoxDecoration(
                  // `.wallpaper-preview` background: rgba(0,0,0,0.3) dark /
                  // #ffffff light (styles-features.css:3170 +
                  // styles-themes-responsive.css:1354-1357), so the light
                  // thumbnails read light-primary-on-white like the PWA.
                  color: c.isLight
                      ? Colors.white
                      : Colors.black.withValues(alpha: 0.3),
                  borderRadius: NymRadius.rxs,
                  border: Border.all(
                    color: c.isLight ? const Color(0x1F000000) : c.glassBorder,
                  ),
                ),
                alignment: Alignment.center,
                // `.wallpaper-option` icons (index.html:1420-1471): "None" is
                // the two-line ✕ SVG, "Upload" is the feather upload glyph —
                // both 20px. Each pattern tile renders the SAME tiled CSS
                // pattern as the live wallpaper at thumbnail scale
                // (`.wallpaper-preview.wallpaper-<name>`,
                // styles-features.css:3184-3243) via the shared painter's
                // preview variant.
                child: o.id == 'none'
                    ? NymSvgIcon(NymIcons.close, size: 20, color: c.textDim)
                    : o.id == 'custom'
                        ? _customTile(c)
                        : ClipRRect(
                            borderRadius: NymRadius.rxs,
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: WallpaperPatternPainter(
                                type: o.id,
                                primary: c.primary,
                                isLight: c.isLight,
                                preview: true,
                              ),
                            ),
                          ),
              ),
            ),
            // `.wallpaper-option { gap: 6px }` + `.wallpaper-label`: 11px
            // text-dim, primary when selected.
            const SizedBox(height: 6),
            Text(
              o.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? c.primary : c.textDim,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The Upload tile's content: "Uploading..." while an upload is in flight
  /// (app.js:4184), the active custom wallpaper as a cover-fit thumbnail when
  /// one is set (app.js:4190-4192, 4220-4226), else the upload glyph.
  Widget _customTile(NymColors c) {
    if (uploading) {
      return Text(
        'Uploading...',
        style: TextStyle(color: c.textDim, fontSize: 10),
      );
    }
    final path = customThumbPath;
    if (path != null && path.isNotEmpty) {
      // The PWA stores the uploaded blob's public URL; older native installs
      // may still hold an on-device file path — render either.
      final isRemote =
          path.startsWith('http://') || path.startsWith('https://');
      if (isRemote || File(path).existsSync()) {
        return ClipRRect(
          borderRadius: NymRadius.rxs,
          child: SizedBox.expand(
            child: isRemote
                // Proxied like every other remote image (hide IP / bypass
                // hotlink 403s), matching wallpaper_layer.dart's render path.
                ? Image.network(
                    proxiedAvatarUrl(path) ?? path,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => NymSvgIcon(NymIcons.upload,
                        size: 20, color: c.textDim),
                  )
                : Image.file(File(path), fit: BoxFit.cover),
          ),
        );
      }
    }
    return NymSvgIcon(NymIcons.upload, size: 20, color: c.textDim);
  }
}

/// A selectable preview card shared by the Chat-View (`.view-option`) and
/// Message-Layout (`.layout-option`) pickers: a 2px-bordered card (radius sm)
/// whose preview area sits above a label; selecting it switches the border to
/// solid `--primary`, adds a `0 0 12px primary@.25` glow, and tints the label
/// primary.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.selected,
    required this.label,
    required this.preview,
    required this.onTap,
  });

  final bool selected;
  final String label;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          // `.view-option/.layout-option { border: 2px solid glass-border;
          //   border-radius: var(--radius-sm); padding: 8px }`.
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: NymRadius.rsm,
            border: Border.all(
              color: selected ? c.primary : c.glassBorder,
              width: 2,
            ),
            // `.selected { box-shadow: 0 0 12px primary@.25 }`.
            boxShadow: selected
                ? [BoxShadow(color: c.primaryA(0.25), blurRadius: 12)]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              preview,
              // `.view-label/.layout-label { padding-top: 6px; font-size: 11px;
              //   color: text-dim }`; selected → primary.
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? c.primary : c.textDim,
                    fontSize: 11,
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

/// One faux column in the Chat-View preview (`.vp-col`): a `bg-tertiary` box of
/// dim bars; `bars` is the list of bar widths where `true` = full, `false` =
/// 60% (`.vp-bar.short`). The caller controls width (Expanded for columns,
/// FractionallySizedBox for the centered single column).
class _VpCol extends StatelessWidget {
  const _VpCol({required this.bars});
  final List<bool> bars;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      // `.vp-col { padding: 5px; gap: 4px; background: bg-tertiary;
      //   border: 1px glass-border; border-radius: 4px }`.
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < bars.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              // `.vp-bar.short { width: 60% }` else 100%.
              widthFactor: bars[i] ? 1.0 : 0.6,
              child: Container(
                // `.vp-bar { height: 5px; border-radius: 3px; background:
                //   text-dim; opacity: .5 }`.
                height: 5,
                decoration: BoxDecoration(
                  color: c.textDim.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Chat-View picker: two `.view-option` cards with miniature column-layout
/// previews (single = one 60%-width column; columns = three columns), mirroring
/// index.html:1389-1404.
class _ViewPicker extends StatelessWidget {
  const _ViewPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    // `.view-preview { min-height: 90px; padding: 8px; gap: 4px; background:
    //   rgba(0,0,0,.3); border-radius: var(--radius-xs) }`; selected →
    //   primary@.08 dark / primary@.12 light (styles-columns.css:480-486
    //   `body.light-mode .view-option.selected .view-preview`).
    Widget previewBox(bool selected, MainAxisAlignment align,
        List<Widget> cols) {
      return Container(
        constraints: const BoxConstraints(minHeight: 90),
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected
              ? c.primaryA(c.isLight ? 0.12 : 0.08)
              : Colors.black.withValues(alpha: c.isLight ? 0.06 : 0.3),
          borderRadius: NymRadius.rxs,
        ),
        child: Row(
          mainAxisAlignment: align,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: cols,
        ),
      );
    }

    final singleSel = value == 'single';
    final columnsSel = value == 'columns';
    // `.view-grid { display: flex; gap: 12px }` with equal-height cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewCard(
            selected: singleSel,
            label: 'Single Chat (Default)',
            onTap: () => onChanged('single'),
            // Single: one centered column at 60% width (`.vp-col{flex:0 0 60%}`)
            // — flex 1:3:1 spacers give the 3/5 = 60% centered column.
            preview: previewBox(singleSel, MainAxisAlignment.center, const [
              Spacer(),
              Expanded(flex: 3, child: _VpCol(bars: [true, false, true, false])),
              Spacer(),
            ]),
          ),
          const SizedBox(width: 12),
          _PreviewCard(
            selected: columnsSel,
            label: 'Column View',
            onTap: () => onChanged('columns'),
            // Columns: three equal-flex columns (`.vp-col{flex:1}`).
            preview: previewBox(columnsSel, MainAxisAlignment.start, const [
              Expanded(child: _VpCol(bars: [true, false])),
              SizedBox(width: 4),
              Expanded(child: _VpCol(bars: [false, true])),
              SizedBox(width: 4),
              Expanded(child: _VpCol(bars: [true])),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Message-layout picker (Bubbles / IRC) as two `.layout-option` cards, each
/// previewing a realistic 3-line mini chat (bubbles or IRC), mirroring
/// index.html:1481-1496.
class _LayoutPicker extends StatelessWidget {
  const _LayoutPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  // The mock messages the PWA hardcodes into the preview.
  static const _rows = <({String nick, String suffix, String msg, bool self})>[
    (nick: 'alice', suffix: '#e45f', msg: 'hey there!', self: false),
    (nick: 'you', suffix: '#6si9', msg: 'hello!', self: true),
    (nick: 'bob', suffix: '#2t5g', msg: "what's up?", self: false),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bubblesSel = value == 'bubbles';
    final ircSel = value == 'irc';
    // `.layout-grid { display: flex; gap: 12px }` with equal-height cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewCard(
            selected: bubblesSel,
            label: 'Bubbles (Default)',
            onTap: () => onChanged('bubbles'),
            preview: _layoutPreviewBox(c, bubbles: true),
          ),
          const SizedBox(width: 12),
          _PreviewCard(
            selected: ircSel,
            label: 'IRC Style',
            onTap: () => onChanged('irc'),
            preview: _layoutPreviewBox(c, bubbles: false),
          ),
        ],
      ),
    );
  }

  /// `.layout-preview { min-height: 72px; padding: 8px; background:
  /// rgba(0,0,0,.3); border-radius: var(--radius-xs); gap: 3px }` (bubbles
  /// variant: padding 6/4, gap 4).
  Widget _layoutPreviewBox(NymColors c, {required bool bubbles}) {
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      width: double.infinity,
      padding: bubbles
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 6)
          : const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: c.isLight ? 0.06 : 0.3),
        borderRadius: NymRadius.rxs,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _rows.length; i++) ...[
            if (i > 0) SizedBox(height: bubbles ? 4 : 3),
            bubbles ? _bubble(c, _rows[i]) : _ircLine(c, _rows[i]),
          ],
        ],
      ),
    );
  }

  /// A mini chat bubble (`.lp-bubble`): other = left `white@.14`, self = right
  /// `primary@.2`; nick block in `--secondary`, text in `--text`.
  Widget _bubble(
      NymColors c, ({String nick, String suffix, String msg, bool self}) r) {
    final bubble = Container(
      // `.lp-bubble { padding: 3px 7px; border-radius: 8px; max-width: 80% }`.
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        // Light-mode flips both bubbles (09-L). other:
        // `light-mode .lp-bubble-other { background: rgba(0,0,0,0.07) }`
        // (responsive:1384-1386); self:
        // `light-mode .lp-bubble-self { background: primary/0.15 }`
        // (responsive:1388-1390) vs dark primary/0.2 (features:3398-3401).
        color: r.self
            ? c.primaryA(c.isLight ? 0.15 : 0.2)
            : (c.isLight
                ? const Color(0x12000000) // black@.07
                : Colors.white.withValues(alpha: 0.14)),
        // radius 8, with the inner top corner squared to 2px.
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(r.self ? 8 : 2),
          topRight: Radius.circular(r.self ? 2 : 8),
          bottomLeft: const Radius.circular(8),
          bottomRight: const Radius.circular(8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.lp-bubble-nick { color: secondary; font-size: 7px; weight: 600 }`
          // + the dim `.nym-suffix`.
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: r.nick),
                TextSpan(
                  text: r.suffix,
                  style: TextStyle(
                    color: c.secondary.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w100,
                  ),
                ),
              ],
            ),
            style: TextStyle(
              color: c.secondary,
              fontSize: 7,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 1),
          // `.lp-bubble-text { color: text; font-size: 8px }`.
          Text(
            r.msg,
            style: TextStyle(color: c.text, fontSize: 8, height: 1.3),
          ),
        ],
      ),
    );
    // `max-width: 80%` of the preview, aligned left (other) / right (self).
    return FractionallySizedBox(
      widthFactor: 0.8,
      alignment: r.self ? Alignment.centerRight : Alignment.centerLeft,
      child: Align(
        alignment: r.self ? Alignment.centerRight : Alignment.centerLeft,
        child: bubble,
      ),
    );
  }

  /// An IRC preview line (`.layout-line`): `<nick#suffix> msg`, mono 9px, nick
  /// in `--secondary` (self → `--primary`), msg in `--text`.
  Widget _ircLine(
      NymColors c, ({String nick, String suffix, String msg, bool self}) r) {
    final nickColor = r.self ? c.primary : c.secondary;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '<${r.nick}',
            style: TextStyle(color: nickColor, fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: r.suffix,
            style: TextStyle(
              color: nickColor.withValues(alpha: 0.7),
              fontWeight: FontWeight.w100,
            ),
          ),
          TextSpan(
            text: '> ',
            style: TextStyle(color: nickColor, fontWeight: FontWeight.w600),
          ),
          TextSpan(text: r.msg, style: TextStyle(color: c.text)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.clip,
      softWrap: false,
      style: TextStyle(
        fontFamily: kMonoFont,
        fontSize: 9,
        height: 1.4,
      ),
    );
  }
}

/// Text-size slider row: small "A", slider, large "A", value badge, Reset.
class _TextSizeRow extends StatelessWidget {
  const _TextSizeRow({
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onReset,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Row(
      children: [
        Text('A', style: TextStyle(color: c.textDim, fontSize: 12)),
        Expanded(
          child: SliderTheme(
            // `.form-range`: track height 4px, uniform `glass-border` (no
            // active/inactive split); thumb 16px (radius 8) `--primary`.
            data: SliderThemeData(
              activeTrackColor: c.glassBorder,
              inactiveTrackColor: c.glassBorder,
              thumbColor: c.primary,
              overlayColor: c.primaryA(0.2),
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.clamp(
                  NymTextSize.min, NymTextSize.max),
              min: NymTextSize.min,
              max: NymTextSize.max,
              divisions: (NymTextSize.max - NymTextSize.min).round(),
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        Text('A', style: TextStyle(color: c.textDim, fontSize: 20)),
        const SizedBox(width: 8),
        // `#textSizeValue` (`.nm-h-57`): 12px `--text-dim`, min-width 32,
        // centered (no-inline.css:75).
        Container(
          constraints: const BoxConstraints(minWidth: 32),
          alignment: Alignment.center,
          child: Text(
            '${value.round()}px',
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        NymOutlineButton(
            label: 'Reset', onPressed: onReset, uppercase: false),
      ],
    );
  }
}

// === Static option lists ====================================================

/// Notification-sound options, verbatim and in order from `#soundSelect`.
const List<({String value, String label})> _soundOptions = [
  (value: 'beep', label: 'Classic Beep'),
  (value: 'low', label: 'Low Tone'),
  (value: 'high', label: 'High Ping'),
  (value: 'uhoh', label: 'ICQ Uh-Oh'),
  (value: 'msnding', label: 'MSN Alert'),
  (value: 'nudge', label: 'MSN Nudge'),
  (value: 'nokia', label: 'Nokia SMS'),
  (value: 'nokiatune', label: 'Nokia Tune'),
  (value: 'dialup', label: 'Dial-Up Modem'),
  (value: 'coin', label: 'Mario Coin'),
  (value: 'oneup', label: 'Mario 1-Up'),
  (value: 'powerup', label: 'Mario Power-Up'),
  (value: 'secret', label: 'Zelda Secret'),
  (value: 'gameboy', label: 'Game Boy Boot'),
  (value: 'tetris', label: 'Tetris'),
  (value: 'pokeheal', label: 'Pokémon Heal'),
  (value: 'chirp', label: 'Communicator Chirp'),
  (value: 'f1', label: 'F1 Radio'),
  (value: 'none', label: 'Silent'),
];

/// Translation-language options, verbatim and in order from
/// `#translateLanguageSelect` (empty value = Disabled).
const List<({String value, String label})> _translationLanguages = [
  (value: '', label: 'Disabled'),
  (value: 'en', label: 'English'),
  (value: 'es', label: 'Spanish'),
  (value: 'fr', label: 'French'),
  (value: 'de', label: 'German'),
  (value: 'it', label: 'Italian'),
  (value: 'pt', label: 'Portuguese'),
  (value: 'ru', label: 'Russian'),
  (value: 'zh', label: 'Chinese'),
  (value: 'ja', label: 'Japanese'),
  (value: 'ko', label: 'Korean'),
  (value: 'ar', label: 'Arabic'),
  (value: 'hi', label: 'Hindi'),
  (value: 'tr', label: 'Turkish'),
  (value: 'nl', label: 'Dutch'),
  (value: 'pl', label: 'Polish'),
  (value: 'uk', label: 'Ukrainian'),
  (value: 'vi', label: 'Vietnamese'),
  (value: 'th', label: 'Thai'),
  (value: 'id', label: 'Indonesian'),
  (value: 'sv', label: 'Swedish'),
  (value: 'af', label: 'Afrikaans'),
  (value: 'bg', label: 'Bulgarian'),
  (value: 'bn', label: 'Bengali'),
  (value: 'ca', label: 'Catalan'),
  (value: 'cs', label: 'Czech'),
  (value: 'da', label: 'Danish'),
  (value: 'el', label: 'Greek'),
  (value: 'et', label: 'Estonian'),
  (value: 'fa', label: 'Persian'),
  (value: 'fi', label: 'Finnish'),
  (value: 'fil', label: 'Filipino'),
  (value: 'he', label: 'Hebrew'),
  (value: 'hr', label: 'Croatian'),
  (value: 'hu', label: 'Hungarian'),
  (value: 'lt', label: 'Lithuanian'),
  (value: 'lv', label: 'Latvian'),
  (value: 'ms', label: 'Malay'),
  (value: 'no', label: 'Norwegian'),
  (value: 'ro', label: 'Romanian'),
  (value: 'sk', label: 'Slovak'),
  (value: 'sl', label: 'Slovenian'),
  (value: 'sr', label: 'Serbian'),
  (value: 'sw', label: 'Swahili'),
  (value: 'ta', label: 'Tamil'),
  (value: 'te', label: 'Telugu'),
  (value: 'ur', label: 'Urdu'),
];
