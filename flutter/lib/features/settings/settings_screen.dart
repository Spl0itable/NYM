import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/attest/attest_badge.dart';
import 'package:flutter/services.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/pow.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/settings.dart';
import '../identity/panic_overlay.dart';
import '../notifications/notifications_service.dart';
import '../../services/location/geolocation.dart';
import '../../services/platform/background_connectivity.dart';
import '../../services/storage/secure_store.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart' show proxiedAvatarUrl;
import '../../widgets/nym_icons.dart';
import '../../widgets/wallpaper/wallpaper_layer.dart';
import '../emoji/emoji_picker.dart';
import '../i18n/i18n.dart';
import '../i18n/language_select.dart';
import '../messages/format/message_content.dart' show InlineEmojiText;
import '../identity/modal_chrome.dart';
import '../identity/vault_settings_modal.dart';
import '../chat_lock/chat_lock.dart'
    show ChatLockStrings, incognitoSupport, screenSecurityHint;
import '../chat_lock/chat_lock_providers.dart';
import '../chat_lock/chat_lock_ui.dart' show ChatLockSettingsModal;
import '../chat_lock/screen_privacy.dart' show chatLockPlatform;
import '../identity/key_backup/key_backup_actions.dart';
import '../identity/key_backup/key_backup_store.dart';
import '../identity/nick_edit_modal.dart';
import '../../widgets/wallpaper/wallpaper_cache.dart';
import '../../services/filter/filter_packs.dart';
import '../toasts/toast_center.dart';
import 'settings_helpers.dart';
import 'settings_widgets.dart';

/// Post-quantum status line, named so a test can hold the translation catalog to it.
const String kPqStatusFull = 'Active for messages with other Nymchat users.';
const String kPqStatusSendOnly =
    'Active for messages you send to other Nymchat users. Messages you receive, '
    'and your own synced settings and history, stay on standard encryption '
    'until this device has your nympq1\u2026 recovery code.';
/// Capable but on the nsec-derived key because this device has no recovery code; plain "Active" would overstate it.
const String kPqStatusNoRoot =
    'Active, but on the older key: this device has no nympq1… recovery code '
    'yet. It is set up automatically the first time this account reaches the '
    'network — until then, messages use a key derived from your nsec.';
const String kPqStatusUnavailable =
    'Not available. Post-quantum encryption needs the ML-KEM implementation, '
    'which did not load.';

/// Capability and actual use differ: shown when no peer key has been fetched, so messages still go out classical.
const String kPqReachNone =
    'No contact has published a post-quantum key yet, so messages are still '
    'going out on standard encryption. This turns on by itself as soon as one '
    'does.';
const String kPqReachSome = 'Currently in use with {count} contacts.';
const String kPqReachOne = 'Currently in use with 1 contact.';

/// Every literal the post-quantum status line can show.
const List<String> kPqStatusStrings = [
  kPqStatusFull,
  kPqStatusNoRoot,
  kPqStatusSendOnly,
  kPqStatusUnavailable,
  kPqReachNone,
  kPqReachSome,
  kPqReachOne,
];

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    super.key,
    this.initialSearch,
    this.focusLanding = false,
  });

  /// Pre-fills the search so the dialog opens narrowed to one setting.
  final String? initialSearch;

  /// Focuses the Default Landing Channel field once shown.
  final bool focusLanding;

  /// Opens the settings dialog as a modal route.
  static Future<void> open(
    BuildContext context, {
    String? initialSearch,
    bool focusLanding = false,
  }) {
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: !solidUi
          ? Colors.black.withValues(alpha: 0.7)
          : isLight
              ? const Color(0x73000000)
              : const Color(0xBF000000),
      builder: (_) => SettingsScreen(
        initialSearch: initialSearch,
        focusLanding: focusLanding,
      ),
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

  /// Inline error under the transfer field.
  String? _transferError;

  /// Outbound transfer in flight; disables Send and shows "Sending…".
  bool _transferSending = false;

  /// Current landing-channel selection, seeded from the store.
  LandingChannel _landing = LandingChannel.defaultChannel;

  /// Whether the landing-channel suggestions overlay is open.
  bool _landingOpen = false;

  /// Cache readout; null while the first read is in flight ("Calculating…").
  String? _cacheReadout;

  // Section expanded state, all open by default; restored and persisted per toggle.
  final Map<String, bool> _open = {
    'appearance': true,
    'privacy': true,
    'messaging': true,
    'channels': true,
    'mobile': true,
    'data': true,
  };

  /// Blocked users' profile fetch in flight; the list shows "Loading..." meanwhile.
  bool _blockedProfilesLoading = false;

  /// A custom wallpaper upload is in progress.
  bool _wallpaperUploading = false;

  // Live text-size preview; commits on change end.
  double? _textSizePreview;

  /// Save-gated draft of settings; live-applied controls also mirror into it so Save doesn't revert them.
  late Settings _draft;

  /// `cachePMs` at open; the cache is wiped on Save only when it flipped on to off.
  late bool _cachePMsAtOpen;

  // Save-gated drafts for the KV-only keypair, PoW and blur controls.
  late String _draftKeypair; // 'persistent' | 'random' | 'hardcore'
  late int _draftPow;
  late String _draftVerified;
  late Set<String> _draftFilterPacks;
  late String _draftBlur; // 'true' | 'friends' | 'false'

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    _draft = ref.read(settingsProvider);
    // Coerce legacy indicator-scope values: 'true' -> everywhere, 'false' -> disabled, unknown -> legacy-derived fallback.
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
    // Map retired 8/12 values onto the offered set so the dropdown isn't empty.
    _draftPow = normalizePowDifficulty(ctrl0.powDifficulty);
    _draftVerified = ctrl0.appVerifiedFilter;
    _draftFilterPacks = ctrl0.filterPacks.toSet();
    // Blur seeds from the per-pubkey key, then the global key; anything but 'friends'/'true' reads as 'false'.
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
    _landing = readLandingChannel(kv);
    _landingController.text = _landing.label;
    // Restore the persisted section collapse layout (`{key: 1}` per collapsed section).
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
    final seed = widget.initialSearch;
    if (seed != null && seed.isNotEmpty) {
      _search = seed;
      _searchController.text = seed;
    }
    if (widget.focusLanding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _landingFocus.requestFocus();
      });
    }
    _landingFocus.addListener(() {
      if (!_landingFocus.hasFocus && _landingOpen) {
        setState(() => _landingOpen = false);
      }
    });
    _loadCacheSize();
    ref.read(nostrControllerProvider).refreshPendingSettingsTransfers();
    // Resolve unknown blocked users' profiles so the list shows real nyms.
    _fetchBlockedProfiles();
  }

  /// Fetches unknown blocked users' profiles, showing "Loading..." meanwhile.
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

  /// Formats the on-device cache size, an empty state, or an unavailable state.
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
      // Honest failure state when the store errors.
      setState(() => _cacheReadout = tr(
          'Cache unavailable ({error}) — cache disabled in this app',
          {'error': e}));
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

  /// Toggles a section and persists the layout (collapsed keys map to 1).
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

  /// Option labels, included in each group's search text.
  static String _optText<T>(List<({T value, String label})> items) =>
      items.map((it) => it.label).join(' ');

  /// Mutates the Save-gated [_draft] instead of committing.
  void _mutate(Settings Function(Settings draft) fn) {
    setState(() => _draft = fn(_draft));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Watch live settings so live-applied controls restyle at once; sections render from [_draft].
    ref.watch(settingsProvider);
    final settings = _draft;
    final ctrl = ref.read(settingsProvider.notifier);
    // Re-render moderation lists on add/remove.
    ref.watch(appStateProvider);
    // Re-render the pending user-to-user transfers list.
    ref.watch(pendingUserSettingsTransfersProvider);

    // Mobile Gestures only at ≤768px width.
    final isMobileWidth = MediaQuery.of(context).size.width <= 768;

    final sections = <_SectionSpec>[
      _SectionSpec(
        key: 'appearance',
        title: tr('Appearance'),
        groups: _appearance(settings, ctrl),
      ),
      _SectionSpec(
        key: 'privacy',
        title: tr('Privacy & Security'),
        groups: _privacy(settings, ctrl),
      ),
      _SectionSpec(
        key: 'messaging',
        title: tr('Messaging & Display'),
        groups: _messaging(settings, ctrl),
      ),
      _SectionSpec(
        key: 'channels',
        title: tr('Channels'),
        groups: _channels(settings, ctrl),
      ),
      if (isMobileWidth)
        _SectionSpec(
          key: 'mobile',
          title: tr('Mobile Gestures'),
          groups: _mobile(settings, ctrl),
        ),
      _SectionSpec(
        key: 'data',
        title: tr('Data & Backup'),
        groups: _data(settings, ctrl),
      ),
    ];

    // Section-title matches show the whole section; otherwise groups match individually, and matching sections force-expand.
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

    return KeyboardInsetDialog(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            child: ModalChrome.box(
              c,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                // The whole card scrolls; only the search row is sticky, and Save sits at the end.
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
                              const SizedBox(height: 24),
                            ],
                          ),
                          // The close chip scrolls away with the header.
                          ModalChrome.closeChip(
                              c, () => Navigator.of(context).maybePop()),
                        ],
                      ),
                    ),
                    PinnedHeaderSliver(child: _searchBar(c)),
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (visibleSections.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(32, 18, 32, 6),
                              child: Text(
                                tr('No settings match your search.'),
                                textAlign: TextAlign.center,
                                style:
                                    TextStyle(color: c.textDim, fontSize: 13),
                              ),
                            ),
                          for (final s in visibleSections)
                            SettingsSection(
                              title: s.spec.title,
                              // A live query force-expands matching sections without persisting.
                              open: q.isNotEmpty
                                  ? true
                                  : (_open[s.spec.key] ?? true),
                              onToggle: () => _toggleSection(s.spec.key),
                              children: [
                                for (final g in s.groups) g.child,
                              ],
                            ),
                          // Actions are the last block of the scrolled content.
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

  String _attestReadout() {
    final attest = ref.read(nostrControllerProvider).attest;
    final tier = attest?.tier;
    final lines = <String>[
      switch (tier) {
        AttestTier.attested => tr('Badge: attested (hardware proof)'),
        AttestTier.challenged => tr('Badge: challenged (proof of work)'),
        AttestTier.origin => tr('Badge: origin'),
        null => tr('Badge: none'),
      },
    ];
    final refused = attest?.lastPlatformRefusal;
    if (refused != null) {
      lines.add(tr('Platform proof refused: {reason}', {'reason': refused}));
    }
    final err = attest?.lastError;
    if (err != null) {
      lines.add(tr('Last enrollment failed: {reason}', {'reason': err}));
    } else if (attest?.lastAttemptAt == null && tier == null) {
      lines.add(tr('Enrollment has not run yet'));
    }
    return lines.join('\n');
  }

  Widget _header(NymColors c) {
    // Right padding keeps the title clear of the floating close chip.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(32, 32, 56, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        tr('SETTINGS'),
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
    return Container(
      color: c.glassBg,
      padding: const EdgeInsets.fromLTRB(32, 4, 32, 14),
      child: FormInput(
        controller: _searchController,
        hint: tr('Search settings...'),
        prefix: NymSvgIcon(NymIcons.search, size: 16, color: c.textDim),
        onChanged: (v) => setState(() => _search = v),
      ),
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Stretched to match the 42px Save button.
          NymOutlineButton(
            label: tr('Cancel'),
            onPressed: () => Navigator.of(context).maybePop(),
            height: 42,
          ),
          const SizedBox(width: 10),
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
                tr('SAVE'),
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

  void _systemMessage(String text) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showToast(text);
    });
  }

  /// Fans the Save-gated draft out to the real setters, resolves proximity, conditionally wipes the PM cache, and closes.
  Future<void> _onSave() async {
    final ctrl = ref.read(settingsProvider.notifier);
    final d = _draft;

    // Resolve the proximity grant first so a denial flips it back to Disabled.
    final proximity = await _resolveProximityOnSave(d.sortByProximity);
    if (!mounted) return;

    // Snapshot status visibility to re-broadcast immediately if it changes.
    final prevShowStatus = ref.read(settingsProvider).showStatus;

    // Fan out every draft value through its synced setter; live-applied ones are idempotent.
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
    // Re-assert presence under the new visibility now rather than at the next throttled broadcast.
    if (prevShowStatus != d.showStatus) {
      final appState = ref.read(appStateProvider);
      final awayMsg = appState.users[appState.selfPubkey]?.awayMessage ?? '';
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
    ctrl.setBackgroundConnectivity(d.backgroundConnectivity);

    // Keypair is locked to 'persistent' while logged in with a Nostr identity.
    final nostrLoggedIn =
        ref.read(nostrControllerProvider).identity?.loginMethod != null;
    if (!nostrLoggedIn) {
      ctrl.setKeypairMode(_draftKeypair);
      // Random/hardcore removes the saved nsec; persistent saves the current one if none is stored.
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
              // Best-effort.
            }
          }());
        }
      }
    }
    ctrl.setPowDifficulty(_draftPow);
    ctrl.setAppVerifiedFilter(_draftVerified);
    ctrl.setFilterPacks(_draftFilterPacks.toList());
    unawaited(FilterPacks.setActive(_draftFilterPacks));
    ctrl.setBlurImages(_draftBlur,
        pubkey: ref.read(appStateProvider).selfPubkey);

    // Wipe the PM/group cache only when caching flipped on to off.
    if (_cachePMsAtOpen && !d.cachePMs) {
      ref.read(nostrControllerProvider).clearPmGroupCache();
    }

    // Commit via the synced setter so Save publishes it like other settings.
    ctrl.setPinnedLandingChannel(_landing.toJsonString());

    // The hidden auto-ephemeral select: anything but 'true' removes the auto-ephemeral keys.
    final kvStore = ref.read(keyValueStoreProvider);
    if (kvStore.getString(StorageKeys.autoEphemeral) == 'true') {
      kvStore.setString(StorageKeys.autoEphemeral, 'true');
    } else {
      kvStore.remove(StorageKeys.autoEphemeral);
      kvStore.remove(StorageKeys.autoEphemeralNick);
      kvStore.remove(StorageKeys.autoEphemeralChannel);
    }

    if (!mounted) return;
    _systemMessage(tr('Settings saved'));
    Navigator.of(context).maybePop();
  }

  /// Picks an image, uploads it to Blossom and selects it; failures leave the selection unchanged.
  Future<void> _uploadCustomWallpaper(SettingsController ctrl) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    if (mounted) setState(() => _wallpaperUploading = true);
    try {
      // Reject anything under 1920x1080; a decode failure counts as invalid.
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
        _systemMessage(tr(
            'Wallpaper image must be at least {width}x{height} pixels.',
            {'width': minWidth, 'height': minHeight}));
        return;
      }
      // Same Blossom upload path as chat images.
      String? url;
      try {
        url = await ref
            .read(nostrControllerProvider)
            .uploadImage(bytes, contentType: _imageContentType(picked.path));
      } catch (e) {
        // Strip Dart's `Exception: ` prefix.
        final msg = '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '');
        _systemMessage(
            tr('Failed to upload wallpaper: {error}', {'error': msg}));
        return;
      }
      if (url == null || url.isEmpty) {
        // Every server failed: the tile reverts and the selection stays.
        _systemMessage(
            tr('Failed to upload wallpaper: All Blossom servers failed'));
        return;
      }
      // Cache our own bytes under the new URL so this device never re-fetches them.
      await WallpaperCache.store(url, bytes);
      unawaited(WallpaperCache.pruneExcept(url));
      await ref.read(keyValueStoreProvider).setString(
            StorageKeys.wallpaperCustomUrl,
            url,
          );
      // Live-applied; mirror into the draft so Save keeps 'custom'.
      ctrl.setWallpaperType('custom');
      if (!mounted) return;
      _mutate((d) => d.copyWith(wallpaperType: 'custom'));
      _systemMessage(tr('Wallpaper uploaded and applied.'));
    } finally {
      if (mounted) setState(() => _wallpaperUploading = false);
    }
  }

  /// MIME type from the file extension.
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

  /// Adds a keyword, confirms and syncs; duplicates still confirm, only empty input is skipped.
  void _addKeyword(SettingsController ctrl) {
    final kw = _keywordController.text.trim().toLowerCase();
    if (kw.isEmpty) return;
    ref.read(appStateProvider.notifier).addBlockedKeyword(kw);
    _persistBlockedKeywords();
    _keywordController.clear();
    _systemMessage(tr('Blocked keyword: "{keyword}"', {'keyword': kw}));
    ref.read(nostrControllerProvider).syncSettings();
    setState(() {});
  }

  /// Persists a moderation set as a JSON string array.
  void _persistStringSet(String key, Set<String> values) {
    ref.read(keyValueStoreProvider).setString(key, jsonEncode(values.toList()));
  }

  void _persistBlockedKeywords() {
    _persistStringSet(StorageKeys.blockedKeywords,
        ref.read(appStateProvider).blockedKeywords);
  }

  /// The pick commits immediately via the synced setter, outside the Save-gated draft, so a later boot can't revert it.
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
              // Immediate synced commit; keep the draft in step.
              ctrl.setSwipeReactEmoji(emoji);
              // Publish now rather than on the 5s debounce, or leaving the app loses the pick.
              ref.read(nostrControllerProvider).flushSettingsSyncNow();
              _mutate((d) => d.copyWith(swipeReactEmoji: emoji));
              ref.read(recentEmojisProvider.notifier).record(emoji);
            },
          ),
        ),
      ),
    );
  }

  /// Switching to "react" opens the emoji picker if no swipe emoji was ever persisted (raw KV key, not the draft default).
  void _onSwipeActionChanged(
    SettingsController ctrl, {
    required String prev,
    required String next,
    required Settings Function(Settings draft) apply,
  }) {
    _mutate(apply);
    final hasPersistedEmoji = (ref
                .read(keyValueStoreProvider)
                .getString(StorageKeys.swipeReactEmoji) ??
            '')
        .isNotEmpty;
    if (next == 'react' && prev != 'react' && !hasPersistedEmoji) {
      _openSwipeReactPicker(ctrl);
    }
  }

  /// Stages the sound and plays a preview, resetting the 2s replay guard so back-to-back previews sound.
  void _onSoundChanged(SettingsController ctrl, String value) {
    _mutate((d) => d.copyWith(sound: value));
    final svc = ref.read(notificationsServiceProvider);
    svc.resetSoundDedupe();
    svc.playSound(value);
  }

  /// Confirms, wipes the on-device cache (best-effort), then toasts and closes.
  Future<void> _clearCache() async {
    final ok = await showAppConfirm(
      context,
      tr('Clear cached channel history, PMs, group chats, profiles, and '
          'reactions? This will not log you out or change your settings.'),
      okLabel: tr('Clear'),
      danger: true,
    );
    if (!ok || !mounted) return;
    final controller = ref.read(nostrControllerProvider);
    // Reflect the in-flight wipe in the readout.
    setState(() => _cacheReadout = null);
    try {
      await controller.clearCache();
    } catch (_) {
      // Best-effort.
    }
    if (!mounted) return;
    setState(() => _cacheReadout = tr('No cached data on device yet'));
    _systemMessage(tr(
        'Local storage cache cleared. Settings, group memberships, and login '
        'preserved.'));
    Navigator.of(context).maybePop();
  }

  /// Confirms, wipes settings keys, resets moderation sets and reloads Settings so everything reverts live.
  Future<void> _resetSettings() async {
    final ok = await showAppConfirm(
      context,
      tr('Reset all settings and preferences to defaults? This will reset '
          'theme, layout, wallpaper, sound, favorited/hidden/blocked channels, '
          'blocked users, and blocked keywords. Your login, group memberships, '
          'and PMs will be preserved.'),
      okLabel: tr('Reset'),
      danger: true,
    );
    if (!ok) return;
    final kv = ref.read(keyValueStoreProvider);
    for (final key in kSettingsResetKeys) {
      kv.remove(key);
    }
    // The store can't enumerate keys, so clear this pubkey's blur key explicitly.
    final self = ref.read(appStateProvider).selfPubkey;
    if (self.isNotEmpty) kv.remove(StorageKeys.imageBlurFor(self));

    // Reset the in-memory moderation sets.
    final notifier = ref.read(appStateProvider.notifier);
    // Unpin every channel now; #nymchat is never in the set.
    for (final key in ref.read(appStateProvider).pinnedChannels.toList()) {
      ref.read(nostrControllerProvider).togglePin(key);
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

    // Rebuild Settings from the cleared store so visual defaults revert without a relaunch.
    ref.read(settingsProvider.notifier).reloadFromStore();

    if (!mounted) return;
    _systemMessage(
        tr('Settings reset to defaults. Cache, group memberships, and login '
            'preserved.'));
    Navigator.of(context).maybePop();
  }

  /// Validates the recipient, publishes the gift-wrapped settings transfer, and shows success or error.
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
    // Gift wraps need a signer-capable identity.
    if (ref.read(nostrControllerProvider).identity == null) {
      setState(() => _transferError =
          tr('Settings transfer requires a logged-in account.'));
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
      _transferPubkeyController.clear();
      _systemMessage(tr('Settings transfer sent to {pubkey}...!',
          {'pubkey': raw.substring(0, 8)}));
    } else {
      setState(() => _transferError =
          tr('Failed to send settings transfer. Please try again.'));
    }
  }

  /// Enabling proximity without a cached location asks permission; a denial flips it off and clears the location.
  Future<bool> _resolveProximityOnSave(bool desired) async {
    if (!desired) {
      ref.read(userLocationProvider.notifier).state = null;
      return false;
    }
    // Already located: keep proximity on silently.
    if (ref.read(userLocationProvider) != null) return true;
    try {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        status = await Permission.locationWhenInUse.request();
      }
      if (status.isGranted) {
        // Granted: fetch a fix; failure disables proximity.
        final loc = await fetchCurrentUserLocation();
        if (loc != null) {
          ref.read(userLocationProvider.notifier).state = loc;
          _systemMessage(tr(
              'Location access granted. Geohash channels sorted by proximity.'));
          return true;
        }
        ref.read(userLocationProvider.notifier).state = null;
        _systemMessage(tr('Location unavailable. Proximity sorting disabled.'));
        return false;
      }
      ref.read(userLocationProvider.notifier).state = null;
      _systemMessage(tr('Location access denied. Proximity sorting disabled.'));
      return false;
    } catch (_) {
      ref.read(userLocationProvider.notifier).state = null;
      _systemMessage(tr('Location access denied. Proximity sorting disabled.'));
      return false;
    }
  }

  List<_GroupSpec> _appearance(Settings s, SettingsController ctrl) {
    final columnsWallpaperItems = <({bool value, String label})>[
      (value: false, label: tr('Solid background')),
      (value: true, label: tr('Show wallpaper through messages')),
    ];
    final transparencyItems = <({bool value, String label})>[
      (value: false, label: tr('Solid')),
      (value: true, label: tr('Glass')),
    ];
    final threadsItems = <({bool value, String label})>[
      (value: true, label: tr('Enabled')),
      (value: false, label: tr('Disabled (classic flat view)')),
    ];
    final customWallpaperPath = s.wallpaperType == 'custom'
        ? ref
            .read(keyValueStoreProvider)
            .getString(StorageKeys.wallpaperCustomUrl)
        : null;
    return [
      // App UI language; the choice persists and syncs, separate from the translation target.
      _GroupSpec(
        text: tr('Language app language localization {lang}',
            {'lang': uiLanguageName(s.uiLanguage)}),
        child: FormGroup(
          label: tr('Language'),
          hint: tr('Show the app interface in your chosen language.'),
          child: _LanguageSelectRow(
            currentName: uiLanguageName(s.uiLanguage),
            onTap: () async {
              await showLanguagePickerDialog(context, ref);
              if (!mounted) return;
              // Choosing the app language also sets the translation language; mirror both into the draft.
              final live = ref.read(settingsProvider);
              _mutate((d) => d.copyWith(
                    uiLanguage: live.uiLanguage,
                    translateLanguage: live.translateLanguage,
                  ));
            },
          ),
        ),
      ),
      // Live-applied: commit now and mirror into the draft.
      _GroupSpec(
        text: tr('Light Auto Dark Auto matches your system preference'),
        child: FormGroup(
          hint: tr('Auto matches your system preference'),
          child: SegmentGroup<ColorMode>(
            value: s.colorMode,
            segments: [
              (value: ColorMode.light, label: tr('Light')),
              (value: ColorMode.auto, label: tr('Auto')),
              (value: ColorMode.dark, label: tr('Dark')),
            ],
            onChanged: (v) {
              ctrl.setColorMode(v);
              _mutate((d) => d.copyWith(colorMode: v));
            },
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Theme {options}', {'options': _optText(_themeOptions())}),
        child: FormGroup(
          label: tr('Theme'),
          child: FormSelect<NymThemeKey>(
            value: s.theme,
            items: _themeOptions(),
            onChanged: (v) {
              ctrl.setTheme(v);
              _mutate((d) => d.copyWith(theme: v));
            },
          ),
        ),
      ),
      // The reset-columns button shows in single view too.
      _GroupSpec(
        text: tr('Chat View Single Chat (Default) Column View Single shows one '
            'conversation at a time. Column view shows channels, PMs, and '
            'group chats side by side in scrollable columns you can add, '
            'remove, and drag to reorder. Reset columns to defaults'),
        child: FormGroup(
          label: tr('Chat View'),
          hint: tr('Single shows one conversation at a time. Column view shows '
              'channels, PMs, and group chats side by side in scrollable '
              'columns you can add, remove, and drag to reorder.'),
          // Not uppercase.
          footer: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: tr('Reset columns to defaults'),
              uppercase: false,
              onPressed: ctrl.resetColumns,
            ),
          ),
          child: _ViewPicker(
            value: s.useColumns ? 'columns' : 'single',
            onChanged: (v) {
              ctrl.setChatViewMode(v);
              _mutate((d) => d.copyWith(chatViewMode: v));
            },
          ),
        ),
      ),
      // Default on; off restores the flat view.
      _GroupSpec(
        text: tr('Message Threads {options} Group replies under their '
            'original message. Replies open in a thread view and the '
            'original shows a reply count. Disabling shows every message '
            'inline like before.', {'options': _optText(threadsItems)}),
        child: FormGroup(
          label: tr('Message Threads'),
          hint: tr('Group replies under their original message. Replies '
              'open in a thread view and the original shows a reply count. '
              'Disabling shows every message inline like before.'),
          child: FormSelect<bool>(
            value: s.threadsEnabled,
            items: threadsItems,
            onChanged: (v) {
              ctrl.setThreadsEnabled(v);
              _mutate((d) => d.copyWith(threadsEnabled: v));
            },
          ),
        ),
      ),
      // Columns mode only.
      if (s.useColumns)
        _GroupSpec(
          text: tr(
              'Column Message Wallpaper {options} In column view, let your '
              'chat wallpaper show through the message area of each column '
              'instead of a solid background.',
              {'options': _optText(columnsWallpaperItems)}),
          child: FormGroup(
            label: tr('Column Message Wallpaper'),
            hint: tr('In column view, let your chat wallpaper show through the '
                'message area of each column instead of a solid background.'),
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
      _GroupSpec(
        text: tr('Chat Wallpaper None Geometric Circuit Dots Waves Topography '
            'Hexagons Diamonds Upload Choose a background pattern or upload '
            'your own image (min 1920x1080)'),
        child: FormGroup(
          label: tr('Chat Wallpaper'),
          hint: tr('Choose a background pattern or upload your own image '
              '(min 1920x1080)'),
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
      // Search text includes the mock preview lines.
      _GroupSpec(
        text: tr('Message Layout Bubbles (Default) IRC Style Choose between '
            "classic IRC-style or modern chat bubbles alice#e45f hey there! "
            "you#6si9 hello! bob#2t5g what's up?"),
        child: FormGroup(
          label: tr('Message Layout'),
          hint: tr('Choose between classic IRC-style or modern chat bubbles'),
          child: _LayoutPicker(
            value: s.chatLayout,
            onChanged: (v) {
              ctrl.setChatLayout(v);
              _mutate((d) => d.copyWith(chatLayout: v));
            },
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Visual Transparency {options} Choose between Solid or Glass, '
            'where messages, modals, sidebars, and other surfaces are '
            'rendered with either solid backgrounds or a translucent "Glass" '
            'look.',
            {'options': _optText(transparencyItems)}),
        child: FormGroup(
          label: tr('Visual Transparency'),
          hint: tr('Choose between Solid or Glass, where messages, modals, '
              'sidebars, and other surfaces are rendered with either solid '
              'backgrounds or a translucent "Glass" look.'),
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
      _GroupSpec(
        text: tr(
            'Text Size Adjust the size of all text across the app '
            '{size}px Reset',
            {'size': (_textSizePreview ?? s.textSize.toDouble()).round()}),
        child: FormGroup(
          label: tr('Text Size'),
          hint: tr('Adjust the size of all text across the app'),
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
              _mutate(
                  (d) => d.copyWith(textSize: NymTextSize.defaultSize.round()));
              setState(() => _textSizePreview = null);
            },
          ),
        ),
      ),
    ];
  }

  List<_GroupSpec> _privacy(Settings s, SettingsController ctrl) {
    // Moderation sets live on AppState.
    final app = ref.watch(appStateProvider);
    // A durable Nostr login locks keypair rotation to 'persistent'.
    final nostrLoggedIn =
        ref.read(nostrControllerProvider).identity?.loginMethod != null;
    final keypairValue = nostrLoggedIn ? 'persistent' : _draftKeypair;
    final keypairItems = <({String value, String label})>[
      (value: 'persistent', label: tr('Disabled (reuse same keypair)')),
      (value: 'random', label: tr('Enabled (new identity each session)')),
      (value: 'hardcore', label: tr('Hardcore (new keypair every message)')),
    ];
    final hardcoreWarning = tr(
        '⚠ Hardcore mode changes your identity after every sent message. PMs '
        'and group chats will not work reliably since recipients cannot reply '
        'to a constantly changing pubkey. Settings will not sync across '
        'devices.');
    // This filters inbound messages only; sends are floored at 16 bits, so above 16 hides other Nymchat users.
    final powItems = <({int value, String label})>[
      (value: 0, label: tr('Disabled')),
      (value: 16, label: tr('16 bits (Nymchat minimum)')),
      (value: 20, label: tr('20 bits — also hides Nymchat messages')),
      (value: 24, label: tr('24 bits — also hides Nymchat messages')),
    ];
    final verifiedItems = <({String value, String label})>[
      (value: 'off', label: tr('Disabled')),
      (value: 'on', label: tr('Enabled')),
    ];
    final acceptItems = <({String value, String label})>[
      (value: 'enabled', label: tr('Enabled')),
      (value: 'friends', label: tr('Friends only')),
      (value: 'disabled', label: tr('Disabled')),
    ];
    final callsWarning = tr(
        '⚠ Audio/video calls and P2P file sharing connect peers directly over '
        'WebRTC, which can reveal your true IP address to the other party. '
        'Use a VPN or Tor to help conceal it.');
    // Sending post-quantum needs only the peer's key; receiving needs this device's root.
    final nostrCtrl = ref.read(nostrControllerProvider);
    final pqCapable = nostrCtrl.pqCapable;
    final pqSendOnly = !pqCapable && nostrCtrl.pqEnabled;
    final pqPeers = nostrCtrl.pqKnownPeerCount;
    final pqReach = pqPeers == 0
        ? tr(kPqReachNone)
        : pqPeers == 1
            ? tr(kPqReachOne)
            : tr(kPqReachSome, {'count': '$pqPeers'});
    // Only root-seeded gets the unqualified "Active".
    final pqRootHeld = nostrCtrl.pqRootHeld;
    final pqStatus = pqCapable && pqRootHeld
        ? '${tr(kPqStatusFull)} $pqReach'
        : pqCapable
            ? '${tr(kPqStatusNoRoot)} $pqReach'
            : pqSendOnly
                ? '${tr(kPqStatusSendOnly)} $pqReach'
                : tr(kPqStatusUnavailable);
    final dmTtlItems = <({int value, String label})>[
      (value: 3600, label: tr('1 hour')),
      (value: 21600, label: tr('6 hours')),
      (value: 86400, label: tr('1 day')),
      (value: 259200, label: tr('3 days')),
      (value: 604800, label: tr('7 days')),
    ];
    final scopeItems = <({String value, String label})>[
      (value: 'everywhere', label: tr('Enabled everywhere')),
      (value: 'pms-groups', label: tr('Both PMs and group chats')),
      (value: 'pms', label: tr('Only PMs')),
      (value: 'groups', label: tr('Only group chats')),
      (value: 'disabled', label: tr('Disabled completely')),
    ];
    final showStatusItems = <({String value, String label})>[
      (value: 'true', label: tr('Enabled')),
      (value: 'friends', label: tr('Friends only')),
      (value: 'false', label: tr('Disabled')),
    ];
    final blurItems = <({String value, String label})>[
      (value: 'true', label: tr('Enabled (blur by default)')),
      (value: 'friends', label: tr('Disabled (for friends only)')),
      (value: 'false', label: tr('Disabled (show all images)')),
    ];
    final canBackUpKey = canShowKeyBackup(ref);
    final backupHint = '${keyBackupHint(passkeyOnly: ref.watch(keyBackupStoresProvider).isEmpty)} '
        '${tr('The backup options are in View or Edit Nym\u2019s Details, '
            'beside your private key and recovery code.')}';
    return [
      _GroupSpec(
        text: tr('Identity Encryption Encrypt identity (nsec) key on this '
            "device… Optionally protect your saved identity's (nsec) private "
            'key with a password, PIN, passkey, or biometric (Face/Touch ID) '
            "so it can't be read from this device without unlocking. Passkeys "
            '(synced or hardware security keys) and biometrics use WebAuthn '
            'where supported, with password/PIN as the universal fallback.'),
        child: FormGroup(
          label: tr('Identity Encryption'),
          hint: tr("Optionally protect your saved identity's (nsec) private "
              'key with a password, PIN, passkey, or biometric (Face/Touch '
              "ID) so it can't be read from this device without unlocking. "
              'Passkeys (synced or hardware security keys) and biometrics use '
              'WebAuthn where supported, with password/PIN as the universal '
              'fallback.'),
          child: NymOutlineButton(
            label: tr('Encrypt identity (nsec) key on this device…'),
            onPressed: () => VaultSettingsModal.open(context),
          ),
        ),
      ),
      ..._chatLockGroups(),
      if (canBackUpKey)
        _GroupSpec(
          text: '${tr('Cloud Key Backup')} $backupHint',
          child: FormGroup(
            label: tr('Cloud Key Backup'),
            hint: backupHint,
            child: Align(
              alignment: Alignment.centerLeft,
              child: NymOutlineButton(
                key: const Key('keyBackupOpenDetails'),
                label: tr("View or Edit Nym's Details"),
                onPressed: () => NickEditModal.open(context),
              ),
            ),
          ),
        ),
      // The hardcore warning is always searchable.
      _GroupSpec(
        text: tr(
            'Generate Random Keypair Per Session {options} Generate a new '
            'random keypair on every session restart for improved '
            'pseudonymity. When disabled, your generated keypair persists '
            'across reloads. {warning}',
            {'options': _optText(keypairItems), 'warning': hardcoreWarning}),
        child: FormGroup(
          label: tr('Generate Random Keypair Per Session'),
          hint: tr('Generate a new random keypair on every session restart '
              'for improved pseudonymity. When disabled, your generated '
              'keypair persists across reloads.'),
          // A plain amber hint, not the danger box.
          amberHint: keypairValue == 'hardcore' ? hardcoreWarning : null,
          child: FormSelect<String>(
            value: keypairValue,
            // Locked while logged in with a Nostr identity.
            disabled: nostrLoggedIn,
            tooltip: tr('Not available while logged in with a Nostr identity'),
            items: keypairItems,
            onChanged: (v) => setState(() => _draftKeypair = v),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Proof of Work Difficulty {options} Filters incoming messages by '
            'proof of work — it does not change what you send. Every message '
            'Nymchat sends is already mined to at least 16 bits, so 16 keeps '
            'Nymchat traffic and drops clients that do no work. Above 16 also '
            'hides messages from other Nymchat users.',
            {'options': _optText(powItems)}),
        child: FormGroup(
          label: tr('Proof of Work Difficulty'),
          hint: tr('Filters incoming messages by proof of work — it does not '
              'change what you send. Every message Nymchat sends is already '
              'mined to at least 16 bits, so 16 keeps Nymchat traffic and '
              'drops clients that do no work. Above 16 also hides messages '
              'from other Nymchat users.'),
          child: FormSelect<int>(
            value: _draftPow,
            items: powItems,
            onChanged: (v) => setState(() => _draftPow = v),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Verified Nymchat Users Only {options} Filters incoming channel '
            'messages to senders who proved they are running Nymchat, on the '
            'web app or the phone apps. Scripted senders cannot prove it and '
            'are dropped. Your own messages, friends and Nymbot are always '
            'shown.',
            {'options': _optText(verifiedItems)}),
        child: FormGroup(
          label: tr('Verified Nymchat Users Only'),
          hint: tr(
              'Filters incoming channel messages to senders who proved they '
              'are running Nymchat, on the web app or the phone apps. '
              'Scripted senders cannot prove it and are dropped. Your own '
              'messages, friends and Nymbot are always shown.'),
          child: FormSelect<String>(
            value: _draftVerified,
            items: verifiedItems,
            onChanged: (v) => setState(() => _draftVerified = v),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('This Device {status} What this install proved to the '
            'attestation service. Other people running the filter above see '
            'your messages only when a badge is here.',
            {'status': _attestReadout()}),
        child: FormGroup(
          label: tr('This Device'),
          hint: tr('What this install proved to the attestation service. '
              'Other people running the filter above see your messages only '
              'when a badge is here.'),
          child: Text(
            _attestReadout(),
            style: TextStyle(color: context.nym.textDim, fontSize: 12),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Accept Private Messages & Group Chat Requests {options} Control '
            'who can send you PMs and group chat invites. "Friends only" '
            'filters messages from non-friends.',
            {'options': _optText(acceptItems)}),
        child: FormGroup(
          label: tr('Accept Private Messages & Group Chat Requests'),
          hint: tr('Control who can send you PMs and group chat invites. '
              '"Friends only" filters messages from non-friends.'),
          child: FormSelect<String>(
            value: s.acceptPMs,
            items: acceptItems,
            onChanged: (v) => _mutate((d) => d.copyWith(acceptPMs: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Accept Audio & Video Calls {options} Control who can ring you '
            'with an audio or video call. "Friends only" silently ignores '
            'calls from non-friends. {warning}',
            {'options': _optText(acceptItems), 'warning': callsWarning}),
        child: FormGroup(
          label: tr('Accept Audio & Video Calls'),
          hint: tr('Control who can ring you with an audio or video call. '
              '"Friends only" silently ignores calls from non-friends.'),
          warning: callsWarning,
          child: FormSelect<String>(
            value: s.acceptCalls,
            items: acceptItems,
            onChanged: (v) => _mutate((d) => d.copyWith(acceptCalls: v)),
          ),
        ),
      ),
      // Read-only status so the security posture and any classical reason are visible.
      _GroupSpec(
        text: tr(
            'Quantum-resistant encryption {status} Private messages and group '
            'chats with other Nymchat users add ML-KEM-768 (a post-quantum key '
            'exchange) alongside the standard NIP‑44 secp256k1 ECDH.',
            {'status': pqStatus}),
        child: FormGroup(
          label: tr('Quantum-resistant encryption'),
          hint: tr('Private messages and group chats with other Nymchat users '
              'add ML-KEM-768 (a post-quantum key exchange) alongside the '
              'standard NIP‑44 secp256k1 ECDH, so both would have to be broken '
              'to read a message and traffic recorded today can\'t be decrypted '
              'by a future quantum computer. This is automatic and has no '
              'setting. Bitchat users and other Nostr clients keep receiving '
              'standard NIP‑17 exactly as before.'),
          // Green only when genuinely on end to end.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pqStatus,
                style: TextStyle(
                  color: pqCapable && pqRootHeld
                      ? context.nym.primary
                      : context.nym.text.withValues(alpha: 0.85),
                  fontSize: 13,
                ),
              ),
              // On-demand diagnostics of the terms behind each conversation's shield.
              const _PqDiagnostics(),
            ],
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Disappearing PM (forward secrecy) Disabled Enabled When '
            'enabled, your private messages include an "expiration" tag '
            '(NIP‑40) so relays/clients can delete them after the period '
            'chosen when enabled.'),
        child: FormGroup(
          label: tr('Disappearing PM (forward secrecy)'),
          hint: tr('When enabled, your private messages include an '
              '"expiration" tag (NIP‑40) so relays/clients can delete them '
              'after the period chosen when enabled.'),
          child: FormSelect<bool>(
            value: s.dmForwardSecrecyEnabled,
            items: [
              (value: false, label: tr('Disabled')),
              (value: true, label: tr('Enabled')),
            ],
            onChanged: (v) =>
                _mutate((d) => d.copyWith(dmForwardSecrecyEnabled: v)),
          ),
        ),
      ),
      if (s.dmForwardSecrecyEnabled)
        _GroupSpec(
          text: tr(
              'Disappear After {options} This sets the "expiration" timestamp '
              'on each outgoing gift‑wrapped PM.',
              {'options': _optText(dmTtlItems)}),
          child: FormGroup(
            label: tr('Disappear After'),
            hint: tr('This sets the "expiration" timestamp on each outgoing '
                'gift‑wrapped PM.'),
            child: FormSelect<int>(
              value: s.dmTtlSeconds,
              items: dmTtlItems,
              onChanged: (v) => _mutate((d) => d.copyWith(dmTtlSeconds: v)),
            ),
          ),
        ),
      _GroupSpec(
        text: tr(
            'Read Receipts {options} Choose where senders can see when '
            "you've read their messages (✓✓). \"Enabled everywhere\" "
            'includes PMs, group chats, and public channels.',
            {'options': _optText(scopeItems)}),
        child: FormGroup(
          label: tr('Read Receipts'),
          hint: tr("Choose where senders can see when you've read their "
              'messages (✓✓). "Enabled everywhere" includes PMs, group '
              'chats, and public channels.'),
          child: FormSelect<String>(
            value: s.readReceiptsScope,
            items: scopeItems,
            onChanged: (v) => _mutate((d) => d.copyWith(readReceiptsScope: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Typing Indicators {options} Choose where others can see when '
            'you\'re typing. "Enabled everywhere" includes PMs, group chats, '
            'and public channels.',
            {'options': _optText(scopeItems)}),
        child: FormGroup(
          label: tr('Typing Indicators'),
          hint: tr("Choose where others can see when you're typing. "
              '"Enabled everywhere" includes PMs, group chats, and public '
              'channels.'),
          child: FormSelect<String>(
            value: s.typingIndicatorsScope,
            items: scopeItems,
            onChanged: (v) =>
                _mutate((d) => d.copyWith(typingIndicatorsScope: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Show Status Indicators {options} When enabled, '
            'online/away/offline status dots are shown on avatars and in user '
            'profiles. "Friends only" broadcasts a hidden status publicly '
            "while privately sharing your real status with people you've "
            'marked as friends, so only they can see it. When disabled, your '
            "status is hidden from everyone, but you can still see other "
            "people's status indicators.",
            {'options': _optText(showStatusItems)}),
        child: FormGroup(
          label: tr('Show Status Indicators'),
          hint: tr('When enabled, online/away/offline status dots are shown '
              'on avatars and in user profiles. "Friends only" broadcasts a '
              'hidden status publicly while privately sharing your real '
              "status with people you've marked as friends, so only they can "
              'see it. When disabled, your status is hidden from everyone, '
              "but you can still see other people's status indicators."),
          child: FormSelect<String>(
            value: s.showStatus,
            items: showStatusItems,
            onChanged: (v) => _mutate((d) => d.copyWith(showStatus: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Cache PMs & Group Chats On Device Enabled Disabled When '
            'enabled, decrypted private messages and group chats are stored '
            'on this device so they appear instantly on app launch. Disable '
            "if you'd rather not have decrypted message content kept at rest "
            'in app storage. Toggling off clears the existing cached PM/group '
            'data.'),
        child: FormGroup(
          label: tr('Cache PMs & Group Chats On Device'),
          hint: tr('When enabled, decrypted private messages and group chats '
              'are stored on this device so they appear instantly on app '
              "launch. Disable if you'd rather not have decrypted message "
              'content kept at rest in app storage. Toggling off clears the '
              'existing cached PM/group data.'),
          child: FormSelect<bool>(
            value: s.cachePMs,
            items: [
              (value: true, label: tr('Enabled')),
              (value: false, label: tr('Disabled')),
            ],
            // The cache wipe happens in `_onSave`, only on an on-to-off flip.
            onChanged: (v) => _mutate((d) => d.copyWith(cachePMs: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Blur Images from Others {options} Blur images shared by others '
            'until clicked. Your own images are never blurred. "Friends only" '
            'shows images from friends unblurred.',
            {'options': _optText(blurItems)}),
        child: FormGroup(
          label: tr('Blur Images from Others'),
          hint: tr('Blur images shared by others until clicked. Your own '
              'images are never blurred. "Friends only" shows images from '
              'friends unblurred.'),
          child: FormSelect<String>(
            value: _draftBlur,
            items: blurItems,
            onChanged: (v) => setState(() => _draftBlur = v),
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Blocked Keywords/Phrases Add keyword or phrase to block '
            'Add Keyword Remove {list}',
            {
              'list': app.blockedKeywords.isEmpty
                  ? tr('No blocked keywords')
                  : app.blockedKeywords.join(' ')
            }),
        child: FormGroup(
          label: tr('Blocked Keywords/Phrases'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormInput(
                controller: _keywordController,
                hint: tr('Add keyword or phrase to block'),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: tr('Add Keyword'),
                  onPressed: () => _addKeyword(ctrl),
                ),
              ),
              const SizedBox(height: 8),
              _removableList(
                entries: app.blockedKeywords,
                emptyText: tr('No blocked keywords'),
                buttonLabel: tr('Remove'),
                labelFor: (kw) => kw,
                onRemove: (kw) {
                  ref.read(appStateProvider.notifier).removeBlockedKeyword(kw);
                  _persistBlockedKeywords();
                  _systemMessage(
                      tr('Unblocked keyword: "{keyword}"', {'keyword': kw}));
                  ref.read(nostrControllerProvider).syncSettings();
                },
              ),
            ],
          ),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Friends Remove Friends can have special privileges like '
            'bypassing image blur and message filters. Add friends from the '
            'context menu on any user. {list}',
            {
              'list': app.friends.isEmpty
                  ? tr('No friends added')
                  : app.friends.map(_nymLabelFor).join(' ')
            }),
        child: FormGroup(
          label: tr('Friends'),
          hint: tr('Friends can have special privileges like bypassing image '
              'blur and message filters. Add friends from the context menu on '
              'any user.'),
          child: _removableList(
            entries: app.friends,
            emptyText: tr('No friends added'),
            buttonLabel: tr('Remove'),
            labelFor: _nymLabelFor,
            labelSpanFor: _nymSpanFor,
            onRemove: (pk) {
              final controller = ref.read(nostrControllerProvider);
              controller.toggleFriend(pk);
              controller.syncSettings();
            },
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Blocked Users Unblock {list}', {
          'list': app.blockedUsers.isEmpty
              ? tr('No blocked users')
              : app.blockedUsers.map(_nymLabelFor).join(' ')
        }),
        child: FormGroup(
          label: tr('Blocked Users'),
          child: _blockedProfilesLoading
              ? _emptyListBox(tr('Loading...'))
              : _removableList(
                  entries: app.blockedUsers,
                  emptyText: tr('No blocked users'),
                  buttonLabel: tr('Unblock'),
                  labelFor: _nymLabelFor,
                  labelSpanFor: _nymSpanFor,
                  onRemove: (pk) {
                    final controller = ref.read(nostrControllerProvider);
                    controller.unblockUser(pk);
                    controller.syncSettings();
                  },
                ),
        ),
      ),
      _GroupSpec(
        text: tr('Filter Packs {packs} Ready-made keyword lists, applied like '
            'your own blocked keywords: a matching message is hidden, and so is '
            'one from a matching nym. Your friends and your own messages are '
            'never filtered.', {
          'packs': _filterPackSpecs.map((p) => '${p.label} ${p.desc}').join(' ')
        }),
        child: FormGroup(
          label: tr('Filter Packs'),
          hint: tr('Ready-made keyword lists, applied like your own blocked '
              'keywords: a matching message is hidden, and so is one from a '
              'matching nym. Your friends and your own messages are never '
              'filtered.'),
          child: _filterPackList(),
        ),
      ),
    ];
  }

  /// Each pack's description is shown, since what it does and doesn't catch is the basis for choosing it.
  static const List<({String id, String label, String desc})> _filterPackSpecs = [
    (
      id: 'profanity',
      label: 'Profanity',
      desc: 'Swearing and slurs, in 28 languages. Matched as whole words, so '
          'Scunthorpe, classic, cocktail and analysis are not caught.'
    ),
    (
      id: 'scams',
      label: 'Scams & spam',
      desc: 'Seed-phrase requests, non-Bitcoin chain addresses, doubling '
          'offers, Telegram handoffs, lookalike links. Recognizes shapes, so '
          'it works in every language.'
    ),
    (
      id: 'crypto',
      label: 'Crypto shilling',
      desc: 'Price hype, launch promotion and altcoin tickers — not crypto '
          'talk. Bitcoin, sats, zaps, nodes and wallets are explicitly allowed.'
    ),
    (
      id: 'politics',
      label: 'Politics',
      desc: 'Party labels, political figures and charged coinages. Ordinary '
          'words like state, party, vote, left and right are allowed.'
    ),
  ];

  Widget _filterPackList() {
    final c = context.nym;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.isLight ? c.bg : Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _filterPackSpecs.length; i++)
            _filterPackRow(_filterPackSpecs[i], first: i == 0),
        ],
      ),
    );
  }

  Widget _filterPackRow(({String id, String label, String desc}) pack,
      {required bool first}) {
    final c = context.nym;
    final on = _draftFilterPacks.contains(pack.id);
    return InkWell(
      borderRadius: NymRadius.rxs,
      onTap: () => setState(() {
        if (on) {
          _draftFilterPacks.remove(pack.id);
        } else {
          _draftFilterPacks.add(pack.id);
        }
      }),
      child: Container(
        decoration: first
            ? null
            : BoxDecoration(
                border: Border(top: BorderSide(color: c.glassBorder))),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: on,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _draftFilterPacks.add(pack.id);
                  } else {
                    _draftFilterPacks.remove(pack.id);
                  }
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr(pack.label), style: TextStyle(fontSize: 13, color: c.text)),
                  const SizedBox(height: 2),
                  Text(tr(pack.desc),
                      style: TextStyle(fontSize: 11, height: 1.4, color: c.textDim)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Moderation row nym with a dim `#suffix`.
  TextSpan _nymSpanFor(String pubkey) {
    final c = context.nym;
    final nym = _nymLabelFor(pubkey);
    final m = RegExp(r'^([\s\S]*?)#([0-9a-f]{4})$', caseSensitive: false)
        .firstMatch(nym);
    if (m == null) {
      return TextSpan(text: nym, style: TextStyle(color: c.text, fontSize: 13));
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

  List<_GroupSpec> _messaging(Settings s, SettingsController ctrl) {
    final timeFormatItems = <({String value, String label})>[
      (value: '24hr', label: tr('24-hour (14:30)')),
      (value: '12hr', label: tr('12-hour (2:30 PM)')),
    ];
    final dateFormatItems = <({String value, String label})>[
      (value: 'default', label: tr('Default (May 28, 2026)')),
      (value: 'mdy', label: tr('MM/DD/YYYY (05/28/2026)')),
      (value: 'dmy', label: tr('DD/MM/YYYY (28/05/2026)')),
      (value: 'ymd', label: tr('YYYY-MM-DD (2026-05-28)')),
    ];
    final nickStyleItems = <({String value, String label})>[
      (value: 'fancy', label: tr('Fancy (adjective_noun)')),
      (value: 'simple', label: tr('Simple (nym1234)')),
    ];
    return [
      _GroupSpec(
        text: tr(
            'Translation Language {name} Choose your preferred language '
            'for translating messages via the context menu.',
            {'name': uiLanguageName(s.translateLanguage)}),
        child: FormGroup(
          label: tr('Translation Language'),
          hint: tr('Choose your preferred language for translating messages '
              'via the context menu.'),
          // Same language chooser as the app language.
          child: _LanguageSelectRow(
            currentName: uiLanguageName(s.translateLanguage),
            onTap: () => showLanguageListDialog(
              context,
              selectedCode: s.translateLanguage,
              title: tr('Translation Language'),
              onSelected: (code) =>
                  _mutate((d) => d.copyWith(translateLanguage: code)),
            ),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Notification Sound {options}',
            {'options': _optText(_soundOptions())}),
        child: FormGroup(
          label: tr('Notification Sound'),
          child: FormSelect<String>(
            value: s.sound,
            items: _soundOptions(),
            // Stage and preview the chosen tone.
            onChanged: (v) => _onSoundChanged(ctrl, v),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Auto-scroll Messages Enabled Disabled'),
        child: FormGroup(
          label: tr('Auto-scroll Messages'),
          child: FormSelect<bool>(
            value: s.autoscroll,
            items: [
              (value: true, label: tr('Enabled')),
              (value: false, label: tr('Disabled')),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(autoscroll: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Show Timestamps Show Hide'),
        child: FormGroup(
          label: tr('Show Timestamps'),
          child: FormSelect<bool>(
            value: s.showTimestamps,
            items: [
              (value: true, label: tr('Show')),
              (value: false, label: tr('Hide')),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(showTimestamps: v)),
          ),
        ),
      ),
      // Time/date format hide when timestamps are hidden.
      if (s.showTimestamps) ...[
        _GroupSpec(
          text: tr(
              'Time Format {options}', {'options': _optText(timeFormatItems)}),
          child: FormGroup(
            label: tr('Time Format'),
            child: FormSelect<String>(
              value: s.timeFormat,
              items: timeFormatItems,
              onChanged: (v) => _mutate((d) => d.copyWith(timeFormat: v)),
            ),
          ),
        ),
        _GroupSpec(
          text: tr(
              'Date Format {options} Used in the full timestamp shown when '
              'tapping a message time',
              {'options': _optText(dateFormatItems)}),
          child: FormGroup(
            label: tr('Date Format'),
            hint: tr('Used in the full timestamp shown when tapping a message '
                'time'),
            child: FormSelect<String>(
              value: s.dateFormat,
              items: dateFormatItems,
              onChanged: (v) => _mutate((d) => d.copyWith(dateFormat: v)),
            ),
          ),
        ),
      ],
      _GroupSpec(
        text: tr(
            'Random Nickname Style {options} Style used when generating '
            'random nicknames',
            {'options': _optText(nickStyleItems)}),
        child: FormGroup(
          label: tr('Random Nickname Style'),
          hint: tr('Style used when generating random nicknames'),
          child: FormSelect<String>(
            value: s.nickStyle,
            items: nickStyleItems,
            onChanged: (v) => _mutate((d) => d.copyWith(nickStyle: v)),
          ),
        ),
      ),
      // Auto-ephemeral has no visible control; its Save cleanup is in `_onSave`.
    ];
  }

  List<_GroupSpec> _channels(Settings s, SettingsController ctrl) {
    final state = ref.watch(appStateProvider);
    final gcPmOnlyItems = <({bool value, String label})>[
      (value: false, label: tr('Disabled (show geohash channels)')),
      (value: true, label: tr('Enabled (group chats & PMs only)')),
    ];
    final proximityItems = <({bool value, String label})>[
      (value: false, label: tr('Disabled')),
      (value: true, label: tr('Enabled (requires location access)')),
    ];
    final hideNonPinnedItems = <({bool value, String label})>[
      (value: false, label: tr('Disabled')),
      (value: true, label: tr('Enabled (only show favorited channels)')),
    ];
    return [
      _GroupSpec(
        text: tr(
            'Group Chats & PMs Only Mode {options} Hides all geohash channels '
            'and focuses the app on group chats and private messages only. '
            'Reduces bandwidth by skipping channel subscriptions.',
            {'options': _optText(gcPmOnlyItems)}),
        child: FormGroup(
          label: tr('Group Chats & PMs Only Mode'),
          hint: tr('Hides all geohash channels and focuses the app on group '
              'chats and private messages only. Reduces bandwidth by skipping '
              'channel subscriptions.'),
          child: FormSelect<bool>(
            value: s.groupChatPMOnlyMode,
            items: gcPmOnlyItems,
            onChanged: (v) =>
                _mutate((d) => d.copyWith(groupChatPMOnlyMode: v)),
          ),
        ),
      ),
      // Geohash settings are hidden in group-chat/PM-only mode.
      if (!s.groupChatPMOnlyMode) ...[
        _GroupSpec(
          text: tr(
              'Sort Geohash Channels by Proximity {options} Sort geohash '
              'channels by distance from your location',
              {'options': _optText(proximityItems)}),
          child: FormGroup(
            label: tr('Sort Geohash Channels by Proximity'),
            hint: tr('Sort geohash channels by distance from your location'),
            // Save-gated; the permission flow runs in `_onSave`.
            child: FormSelect<bool>(
              value: s.sortByProximity,
              items: proximityItems,
              onChanged: (v) => _mutate((d) => d.copyWith(sortByProximity: v)),
            ),
          ),
        ),
        _GroupSpec(
          text: tr('Default Landing Channel Type to search or select a '
              'channel... Channel to load when you first open or reload the '
              'app'),
          child: FormGroup(
            label: tr('Default Landing Channel'),
            hint: tr('Channel to load when you first open or reload the app'),
            child: _landingChannelField(state.channels),
          ),
        ),
        _GroupSpec(
          text: tr(
              'Hide All Non-Favorited Channels {options} When enabled, only '
              'your favorited channels will appear in the sidebar',
              {'options': _optText(hideNonPinnedItems)}),
          child: FormGroup(
            label: tr('Hide All Non-Favorited Channels'),
            hint: tr('When enabled, only your favorited channels will appear '
                'in the sidebar'),
            child: FormSelect<bool>(
              value: s.hideNonPinned,
              items: hideNonPinnedItems,
              onChanged: (v) => _mutate((d) => d.copyWith(hideNonPinned: v)),
            ),
          ),
        ),
        _GroupSpec(
          text: tr('Hidden Channels Unhide {list}', {
            'list': state.hiddenChannels.isEmpty
                ? tr('No hidden channels')
                : state.hiddenChannels.map(_hiddenChannelLabel).join(' ')
          }),
          child: FormGroup(
            label: tr('Hidden Channels'),
            child: _removableList(
              entries: state.hiddenChannels,
              emptyText: tr('No hidden channels'),
              buttonLabel: tr('Unhide'),
              // `#key` plus the decoded geohash location.
              labelFor: _hiddenChannelLabel,
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
          text: tr('Blocked Channels Unblock {list}', {
            'list': state.blockedChannels.isEmpty
                ? tr('No blocked channels')
                : state.blockedChannels.map(_blockedChannelLabel).join(' ')
          }),
          child: FormGroup(
            label: tr('Blocked Channels'),
            child: _removableList(
              entries: state.blockedChannels,
              emptyText: tr('No blocked channels'),
              buttonLabel: tr('Unblock'),
              // Geohash keys show `[GEO]`, ephemeral keys `[EPH]`.
              labelFor: _blockedChannelLabel,
              onRemove: (key) {
                final controller = ref.read(nostrControllerProvider);
                final isGeo = isValidGeohash(key);
                ref
                    .read(appStateProvider.notifier)
                    .unblockChannel(key, geohash: isGeo ? key : '');
                _persistStringSet(StorageKeys.blockedChannels,
                    ref.read(appStateProvider).blockedChannels);
                // Re-adding is idempotent and persists the channel list.
                controller.addChannel(key, geohash: isGeo ? key : '');
                controller.syncSettings();
              },
            ),
          ),
        ),
      ],
    ];
  }

  /// `#key (37.77°N, 122.41°W)` for a hidden geohash channel, else `#key`.
  String _hiddenChannelLabel(String key) {
    final loc = geohashLocationLabel(key);
    return loc.isEmpty ? '#$key' : '#$key ($loc)';
  }

  /// `#key [GEO]` for a geohash channel, `#key [EPH]` otherwise.
  String _blockedChannelLabel(String key) =>
      isValidGeohash(key) ? '#$key [GEO]' : '#$key [EPH]';

  /// Searchable landing-channel field with grouped suggestions; Save persists it.
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
          hint: tr('Type to search or select a channel...'),
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
                    child: Text(tr('No channels found'),
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
      // Plain rows without a selected or hover tint.
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

  List<_GroupSpec> _mobile(Settings s, SettingsController ctrl) {
    final swipeActions = <({String value, String label})>[
      (value: 'quote', label: tr('Quote Reply')),
      (value: 'translate', label: tr('Translate')),
      (value: 'copy', label: tr('Copy Message')),
      (value: 'react', label: tr('Quick React')),
      (value: 'zap', label: tr('Zap Bitcoin')),
      (value: 'slap', label: tr('Slap with Trout')),
      (value: 'hug', label: tr('Give Warm Hug')),
      (value: 'none', label: tr('None')),
    ];
    // Swipe-right options lead with Translate.
    final swipeRightActions = <({String value, String label})>[
      (value: 'translate', label: tr('Translate')),
      (value: 'quote', label: tr('Quote Reply')),
      (value: 'copy', label: tr('Copy Message')),
      (value: 'react', label: tr('Quick React')),
      (value: 'zap', label: tr('Zap Bitcoin')),
      (value: 'slap', label: tr('Slap with Trout')),
      (value: 'hug', label: tr('Give Warm Hug')),
      (value: 'none', label: tr('None')),
    ];
    final thresholdItems = <({int value, String label})>[
      (value: 40, label: tr('High (40px)')),
      (value: 60, label: tr('Medium (60px)')),
      (value: 80, label: tr('Low (80px)')),
      (value: 100, label: tr('Very Low (100px)')),
    ];
    return [
      _GroupSpec(
        text: tr('Swipe Gestures (Mobile) Enabled Disabled Swipe a message '
            'horizontally to trigger an action. Disable to turn off all swipe '
            'gestures on messages.'),
        child: FormGroup(
          label: tr('Swipe Gestures (Mobile)'),
          hint: tr('Swipe a message horizontally to trigger an action. '
              'Disable to turn off all swipe gestures on messages.'),
          child: FormSelect<bool>(
            value: s.gesturesEnabled,
            items: [
              (value: true, label: tr('Enabled')),
              (value: false, label: tr('Disabled')),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(gesturesEnabled: v)),
          ),
        ),
      ),
      // Swipe sub-settings hide when gestures are disabled.
      if (s.gesturesEnabled) ...[
        _GroupSpec(
          text: tr(
              'Swipe Left Action {options} Action triggered when swiping a '
              'message to the left.',
              {'options': _optText(swipeActions)}),
          child: FormGroup(
            label: tr('Swipe Left Action'),
            hint: tr('Action triggered when swiping a message to the left.'),
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
          text: tr(
              'Swipe Right Action {options} Action triggered when swiping a '
              'message to the right.',
              {'options': _optText(swipeRightActions)}),
          child: FormGroup(
            label: tr('Swipe Right Action'),
            hint: tr('Action triggered when swiping a message to the right.'),
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
        // Only when a swipe action is Quick React.
        if (s.swipeLeftAction == 'react' || s.swipeRightAction == 'react')
          _GroupSpec(
            text: tr(
                'Quick React Emoji {emoji} Change Emoji always used when a '
                'swipe gesture is set to "Quick React". Tap to choose from '
                'the full emoji picker.',
                {'emoji': s.swipeReactEmoji}),
            child: FormGroup(
              label: tr('Quick React Emoji'),
              hint: tr('Emoji always used when a swipe gesture is set to '
                  '"Quick React". Tap to choose from the full emoji picker.'),
              // A custom `:code:` preview renders as a 33x33 image; unicode uses the button's 22px font.
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
                      label: tr('Change'),
                      uppercase: false,
                      onPressed: () => _openSwipeReactPicker(ctrl),
                    ),
                  ],
                ),
              ),
            ),
          ),
        _GroupSpec(
          text: tr(
              'Swipe Sensitivity {options} How far you need to swipe before '
              'the action fires. Higher sensitivity means a shorter swipe.',
              {'options': _optText(thresholdItems)}),
          child: FormGroup(
            label: tr('Swipe Sensitivity'),
            hint: tr('How far you need to swipe before the action fires. '
                'Higher sensitivity means a shorter swipe.'),
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

  List<_GroupSpec> _data(Settings s, SettingsController ctrl) {
    final transfers = ref.watch(pendingUserSettingsTransfersProvider);
    return [
      // Keep-alive first, offered only where the platform can honor it.
      if (BackgroundConnectivityService.isSupported)
        _GroupSpec(
          text: tr('Stay Connected in Background Disabled Enabled Keeps relay '
              'connections and the Bluetooth mesh running while the app is in '
              'the background, so messages arrive without reopening it. Uses more '
              'battery and data. Android shows a permanent notification while it '
              'is on; iOS limits how long connections can be held, wakes the app '
              'about every 20 minutes with an empty push every device gets '
              'alike, and, with identity encryption on, catches up only while the device has '
              'been unlocked at least once since it was powered on.'),
          child: FormGroup(
            label: tr('Stay Connected in Background'),
            hint: tr('Keeps relay connections and the Bluetooth mesh running '
                'while the app is in the background, so messages arrive '
                'without reopening it. Uses more battery and data. Android shows a '
                'permanent notification while it is on; iOS limits how long '
                'connections can be held, wakes the app about every 20 '
                'minutes with an empty push every device gets alike, and, '
                'with identity encryption on, '
                'catches up only while the device has been unlocked at least '
                'once since it was powered on.'),
            // Save-gated; the shell starts the keep-alive when the committed value flips.
            child: FormSelect<bool>(
              value: s.backgroundConnectivity,
              items: [
                (value: false, label: tr('Disabled')),
                (value: true, label: tr('Enabled')),
              ],
              onChanged: (v) =>
                  _mutate((d) => d.copyWith(backgroundConnectivity: v)),
            ),
          ),
        ),
      _GroupSpec(
        text: tr('Low Data Mode Disabled Enabled Reduces bandwidth by '
            'connecting to only 5 default relays and loading geo relays '
            'on-demand when entering channels'),
        child: FormGroup(
          label: tr('Low Data Mode'),
          hint: tr('Reduces bandwidth by connecting to only 5 default relays '
              'and loading geo relays on-demand when entering channels'),
          // A select, not a switch, and Save-gated.
          child: FormSelect<bool>(
            value: s.lowDataMode,
            items: [
              (value: false, label: tr('Disabled')),
              (value: true, label: tr('Enabled')),
            ],
            onChanged: (v) => _mutate((d) => d.copyWith(lowDataMode: v)),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Transfer Settings to Another User Recipient npub or hex '
            'pubkey Send Transfers your nickname, avatar, and all '
            'preferences to the specified pubkey'),
        child: FormGroup(
          label: tr('Transfer Settings to Another User'),
          hint: tr('Transfers your nickname, avatar, and all preferences to '
              'the specified pubkey'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FormInput(
                      controller: _transferPubkeyController,
                      hint: tr('Recipient npub or hex pubkey'),
                      onChanged: (_) {
                        if (_transferError != null) {
                          setState(() => _transferError = null);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  NymOutlineButton(
                    label: _transferSending ? tr('Sending…') : tr('Send'),
                    onPressed: _transferSending ? () {} : _sendTransfer,
                  ),
                ],
              ),
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
        text: tr('Pending Settings Transfers Accept Reject {list}', {
          'list': transfers.isEmpty
              ? tr('No pending transfers')
              : transfers.map((t) => t.fromNym).join(' ')
        }),
        child: FormGroup(
          label: tr('Pending Settings Transfers'),
          child: _pendingTransfers(),
        ),
      ),
      _GroupSpec(
        text: tr(
            'Clear Local Storage Cache {readout} Clears the on-device app '
            'cache (channel history, PMs, group chats, profiles, reactions). '
            'Preserves your login, settings, group memberships, and flair '
            'purchases.',
            {'readout': _cacheReadout ?? tr('Calculating…')}),
        child: FormGroup(
          hint: tr('Clears the on-device app cache (channel history, PMs, '
              'group chats, profiles, reactions). Preserves your login, '
              'settings, group memberships, and flair purchases.'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // "Calculating…" until the async read resolves.
              Text(
                _cacheReadout ?? tr('Calculating…'),
                style: TextStyle(color: context.nym.textDim, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: tr('Clear Local Storage Cache'),
                  onPressed: _clearCache,
                ),
              ),
            ],
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Reset Settings to Defaults Resets preferences (theme, '
            'layout, wallpaper, sound, favorited/hidden/blocked channels, '
            'blocked users, blocked keywords) to defaults. Preserves your '
            'login, group memberships, PM history, and flair purchases.'),
        child: FormGroup(
          hint: tr('Resets preferences (theme, layout, wallpaper, sound, '
              'favorited/hidden/blocked channels, blocked users, blocked '
              'keywords) to defaults. Preserves your login, group '
              'memberships, PM history, and flair purchases.'),
          child: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: tr('Reset Settings to Defaults'),
              onPressed: _resetSettings,
            ),
          ),
        ),
      ),
      _GroupSpec(
        text: tr('Wipe This Device Everything, permanently: your key, your '
            'settings, your message history and your post-quantum recovery '
            'code, on this device and on our servers.'),
        child: FormGroup(
          hint: tr('Everything, permanently: your key, your settings, your '
              'message history and your post-quantum recovery code, on this '
              'device and on our servers. The same emergency wipe as holding '
              'your Nym for two seconds. Credits on your key are not touched. '
              'This cannot be undone.'),
          child: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: tr('Wipe This Device'),
              danger: true,
              onPressed: _wipeThisDevice,
            ),
          ),
        ),
      ),
    ];
  }

  /// Same wipe as the press-and-hold panic gesture, reached deliberately.
  Future<void> _wipeThisDevice() async {
    final ok = await showAppConfirm(
      context,
      tr('Wipe this device? Your key, your settings, your message history and '
          'your post-quantum recovery code go — here and on our servers. '
          'Credits on your key are not touched. This cannot be undone.'),
      okLabel: tr('Wipe'),
      danger: true,
    );
    if (!ok || !mounted) return;
    startPanicWipe(context, ref);
  }

  /// Shared list container: padded, bordered, max 200px tall, scrolling.
  Widget _listBox({required Widget child}) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: c.isLight ? c.bg : Colors.white.withValues(alpha: 0.03),
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
    return _listBox(
      child: Text(
        text,
        style: TextStyle(color: c.textDim, fontSize: 12),
      ),
    );
  }

  /// Moderation list with a trailing remove button per row, or the empty placeholder.
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

  /// Inbound user-to-user transfers with sender, verified key, date and contents, plus Accept/Reject.
  Widget _pendingTransfers() {
    final transfers = ref.watch(pendingUserSettingsTransfersProvider);
    if (transfers.isEmpty) return _emptyListBox(tr('No pending transfers'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in transfers) _transferRow(t),
      ],
    );
  }

  Widget _transferRow(UserSettingsTransfer t) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    // Keeps the PWA's leading-comma quirk when nickname is absent; preferences always render.
    final includes = StringBuffer(tr('Includes: '));
    if ((t.nickname ?? '').isNotEmpty) includes.write(tr('nickname'));
    if ((t.avatarUrl ?? '').isNotEmpty) includes.write(', ${tr('avatar')}');
    includes.write(', ${tr('preferences')}');
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
                Text(
                  t.fromNym,
                  style: TextStyle(
                      color: c.text, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Tooltip(
                  message: t.fromPubkey,
                  child: Text(
                    tr('Verified sender key: {key}',
                        {'key': abbreviateTransferKey(t.fromPubkey)}),
                    style: dimStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(formatTransferTimestamp(t.transferredAt), style: dimStyle),
                Text(includes.toString(), style: dimStyle),
              ],
            ),
          ),
          const SizedBox(width: 8),
          NymOutlineButton(
            label: tr('Accept'),
            onPressed: () =>
                unawaited(controller.acceptUserSettingsTransfer(t.eventId)),
          ),
          const SizedBox(width: 6),
          NymOutlineButton(
            label: tr('Reject'),
            danger: true,
            onPressed: () => controller.rejectUserSettingsTransfer(t.eventId),
          ),
        ],
      ),
    );
  }

  /// `base#suffix` for a pubkey, falling back to the abbreviated pubkey.
  String _nymLabelFor(String pubkey) {
    final user = ref.read(appStateProvider).users[pubkey];
    if (user != null && user.nym.isNotEmpty) return user.nym;
    return getNymFromPubkey('nym', pubkey);
  }
}

/// Section descriptor: a titled set of searchable form groups.
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

/// One searchable form group; [text] is its full rendered text.
extension _ChatLockSettings on _SettingsScreenState {
  List<_GroupSpec> _chatLockGroups() {
    ref.watch(chatLockRevisionProvider);
    final lock = ref.read(chatLockProvider);
    final platform = chatLockPlatform();
    final onOff = <({String value, String label})>[
      (value: 'off', label: tr(ChatLockStrings.disabled)),
      (value: 'on', label: tr(ChatLockStrings.enabled)),
    ];
    final screenHint = tr(screenSecurityHint(platform));
    final incog = incognitoSupport(platform);
    final incogHint = tr(incog.hint);
    return [
      _GroupSpec(
        text: '${tr(ChatLockStrings.settingsTitle)} '
            '${tr(ChatLockStrings.settingsButton)} '
            '${tr(ChatLockStrings.settingsHint)}',
        child: FormGroup(
          label: tr(ChatLockStrings.settingsTitle),
          hint: tr(ChatLockStrings.settingsHint),
          child: NymOutlineButton(
            key: const Key('chatLockSettingsButton'),
            label: tr(ChatLockStrings.settingsButton),
            onPressed: () => ChatLockSettingsModal.open(context),
          ),
        ),
      ),
      _GroupSpec(
        text: '${tr(ChatLockStrings.screenSecurity)} ${_SettingsScreenState._optText(onOff)} $screenHint',
        child: FormGroup(
          label: tr(ChatLockStrings.screenSecurity),
          hint: screenHint,
          child: FormSelect<String>(
            key: const Key('screenSecuritySelect'),
            value: lock.screenSecurity ? 'on' : 'off',
            items: onOff,
            onChanged: (v) => lock.screenSecurity = v == 'on',
          ),
        ),
      ),
      _GroupSpec(
        text: '${tr(ChatLockStrings.incognitoKeyboard)} ${_SettingsScreenState._optText(onOff)} $incogHint',
        child: FormGroup(
          label: tr(ChatLockStrings.incognitoKeyboard),
          hint: incogHint,
          child: FormSelect<String>(
            key: const Key('incognitoKeyboardSelect'),
            value: incog.available && lock.incognitoKeyboard ? 'on' : 'off',
            items: onOff,
            disabled: !incog.available,
            tooltip: incogHint,
            onChanged: (v) => lock.incognitoKeyboard = v == 'on',
          ),
        ),
      ),
    ];
  }
}

class _GroupSpec {
  const _GroupSpec({required this.text, required this.child});
  final String text;
  final Widget child;
}

/// Persisted section collapse layout key.
const String _kSettingsSectionsCollapsedKey = 'nym_settings_sections_collapsed';

/// Theme options in order.
List<({NymThemeKey value, String label})> _themeOptions() => [
      (value: NymThemeKey.bitchat, label: tr('Bitchat (Multicolor)')),
      (value: NymThemeKey.matrix, label: tr('Matrix Green')),
      (value: NymThemeKey.amber, label: tr('Amber Terminal')),
      (value: NymThemeKey.cyber, label: tr('Cyberpunk')),
      (value: NymThemeKey.hacker, label: tr('Hacker Blue')),
      (value: NymThemeKey.ghost, label: tr('Ghost (B&W)')),
    ];

/// 3-column grid of the built-in patterns plus Upload, selection ringed.
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

  /// The Upload tile runs this instead of `onChanged('custom')`.
  final Future<void> Function() onUploadCustom;

  /// Custom wallpaper thumbnail on the Upload tile, or null for the glyph.
  final String? customThumbPath;

  /// Upload in progress.
  final bool uploading;

  List<({String id, String label})> get _options => [
        (id: 'none', label: tr('None')),
        (id: 'geometric', label: tr('Geometric')),
        (id: 'circuit', label: tr('Circuit')),
        (id: 'dots', label: tr('Dots')),
        (id: 'waves', label: tr('Waves')),
        (id: 'topography', label: tr('Topography')),
        (id: 'hexagons', label: tr('Hexagons')),
        (id: 'diamonds', label: tr('Diamonds')),
        (id: 'custom', label: tr('Upload')),
      ];

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Plain rows rather than GridView, since tile heights vary.
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

  /// Wallpaper tile with an always-2px border so selecting never shifts content.
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
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Container(
                decoration: BoxDecoration(
                  // Light previews use a white background.
                  color: c.isLight
                      ? Colors.white
                      : Colors.black.withValues(alpha: 0.3),
                  borderRadius: NymRadius.rxs,
                  border: Border.all(
                    color: c.isLight ? const Color(0x1F000000) : c.glassBorder,
                  ),
                ),
                alignment: Alignment.center,
                // Pattern tiles use the live wallpaper painter at thumbnail scale.
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

  /// Upload tile: "Uploading...", the current custom thumbnail, or the glyph.
  Widget _customTile(NymColors c) {
    if (uploading) {
      return Text(
        tr('Uploading...'),
        style: TextStyle(color: c.textDim, fontSize: 10),
      );
    }
    final path = customThumbPath;
    if (path != null && path.isNotEmpty) {
      // Older installs may hold a local file path instead of a URL.
      final isRemote =
          path.startsWith('http://') || path.startsWith('https://');
      if (isRemote || File(path).existsSync()) {
        return ClipRRect(
          borderRadius: NymRadius.rxs,
          child: SizedBox.expand(
            child: isRemote
                // Proxied like every other remote image.
                ? Image.network(
                    proxiedAvatarUrl(path) ?? path,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        NymSvgIcon(NymIcons.upload, size: 20, color: c.textDim),
                  )
                : Image.file(File(path), fit: BoxFit.cover),
          ),
        );
      }
    }
    return NymSvgIcon(NymIcons.upload, size: 20, color: c.textDim);
  }
}

/// Selectable preview card for the view and layout pickers.
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
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: NymRadius.rsm,
            border: Border.all(
              color: selected ? c.primary : c.glassBorder,
              width: 2,
            ),
            boxShadow: selected
                ? [BoxShadow(color: c.primaryA(0.25), blurRadius: 12)]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              preview,
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

/// Faux column in the view preview; `bars` are full (true) or 60% width.
class _VpCol extends StatelessWidget {
  const _VpCol({required this.bars});
  final List<bool> bars;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
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
              widthFactor: bars[i] ? 1.0 : 0.6,
              child: Container(
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

/// Single vs columns picker with miniature previews.
class _ViewPicker extends StatelessWidget {
  const _ViewPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    Widget previewBox(
        bool selected, MainAxisAlignment align, List<Widget> cols) {
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
    // Equal-height cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewCard(
            selected: singleSel,
            label: tr('Single Chat (Default)'),
            onTap: () => onChanged('single'),
            // Flex 1:3:1 spacers make a centered 60% column.
            preview: previewBox(singleSel, MainAxisAlignment.center, const [
              Spacer(),
              Expanded(
                  flex: 3, child: _VpCol(bars: [true, false, true, false])),
              Spacer(),
            ]),
          ),
          const SizedBox(width: 12),
          _PreviewCard(
            selected: columnsSel,
            label: tr('Column View'),
            onTap: () => onChanged('columns'),
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

/// Bubbles vs IRC picker with 3-line mock chats.
class _LayoutPicker extends StatelessWidget {
  const _LayoutPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  // The mock preview messages.
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
    // Equal-height cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewCard(
            selected: bubblesSel,
            label: tr('Bubbles (Default)'),
            onTap: () => onChanged('bubbles'),
            preview: _layoutPreviewBox(c, bubbles: true),
          ),
          const SizedBox(width: 12),
          _PreviewCard(
            selected: ircSel,
            label: tr('IRC Style'),
            onTap: () => onChanged('irc'),
            preview: _layoutPreviewBox(c, bubbles: false),
          ),
        ],
      ),
    );
  }

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

  /// Mini chat bubble: others left, self right.
  Widget _bubble(
      NymColors c, ({String nick, String suffix, String msg, bool self}) r) {
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        // Light mode flips both bubble fills.
        color: r.self
            ? c.primaryA(c.isLight ? 0.15 : 0.2)
            : (c.isLight
                ? const Color(0x12000000)
                : Colors.white.withValues(alpha: 0.14)),
        // Radius 8 with the inner top corner squared.
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
          Text(
            r.msg,
            style: TextStyle(color: c.text, fontSize: 8, height: 1.3),
          ),
        ],
      ),
    );
    // Max 80% width, left for others, right for self.
    return FractionallySizedBox(
      widthFactor: 0.8,
      alignment: r.self ? Alignment.centerRight : Alignment.centerLeft,
      child: Align(
        alignment: r.self ? Alignment.centerRight : Alignment.centerLeft,
        child: bubble,
      ),
    );
  }

  /// IRC preview line `<nick#suffix> msg`.
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

/// Text-size slider row with value badge and Reset.
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
            // Uniform 4px track, 16px primary thumb.
            data: SliderThemeData(
              activeTrackColor: c.glassBorder,
              inactiveTrackColor: c.glassBorder,
              thumbColor: c.primary,
              overlayColor: c.primaryA(0.2),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.clamp(NymTextSize.min, NymTextSize.max),
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
            label: tr('Reset'), onPressed: onReset, uppercase: false),
      ],
    );
  }
}

/// Notification-sound options in order.
List<({String value, String label})> _soundOptions() => [
      (value: 'beep', label: tr('Classic Beep')),
      (value: 'low', label: tr('Low Tone')),
      (value: 'high', label: tr('High Ping')),
      (value: 'uhoh', label: tr('ICQ Uh-Oh')),
      (value: 'msnding', label: tr('MSN Alert')),
      (value: 'nudge', label: tr('MSN Nudge')),
      (value: 'nokia', label: tr('Nokia SMS')),
      (value: 'nokiatune', label: tr('Nokia Tune')),
      (value: 'dialup', label: tr('Dial-Up Modem')),
      (value: 'coin', label: tr('Mario Coin')),
      (value: 'oneup', label: tr('Mario 1-Up')),
      (value: 'powerup', label: tr('Mario Power-Up')),
      (value: 'secret', label: tr('Zelda Secret')),
      (value: 'gameboy', label: tr('Game Boy Boot')),
      (value: 'tetris', label: tr('Tetris')),
      (value: 'pokeheal', label: tr('Pokémon Heal')),
      (value: 'chirp', label: tr('Communicator Chirp')),
      (value: 'f1', label: tr('F1 Radio')),
      (value: 'none', label: tr('Silent')),
    ];

/// Opens the full language chooser, since the list is too long for a dropdown.
class _LanguageSelectRow extends StatelessWidget {
  const _LanguageSelectRow({required this.currentName, required this.onTap});

  final String currentName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          borderRadius: NymRadius.rsm,
          border: Border.all(color: c.glassBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                currentName,
                style: TextStyle(color: c.text, fontSize: 14),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, size: 20, color: c.textDim),
          ],
        ),
      ),
    );
  }
}

/// Expandable, copyable dump of the live post-quantum terms.
class _PqDiagnostics extends ConsumerStatefulWidget {
  const _PqDiagnostics();

  @override
  ConsumerState<_PqDiagnostics> createState() => _PqDiagnosticsState();
}

class _PqDiagnosticsState extends ConsumerState<_PqDiagnostics> {
  String? _text;

  void _refresh() => setState(
      () => _text = ref.read(nostrControllerProvider).pqDiagnosticsText());

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final text = _text;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(tr('Post-quantum diagnostics'),
            style: TextStyle(color: c.textDim, fontSize: 12)),
        onExpansionChanged: (open) {
          if (open) _refresh();
        },
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text ?? '',
                style: TextStyle(
                    color: c.textDim, fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: text == null || text.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: text)),
              child: Text(tr('Copy')),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
