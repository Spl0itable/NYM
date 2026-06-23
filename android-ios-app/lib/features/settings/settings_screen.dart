import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
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
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
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
  String _search = '';

  // Section open/collapsed state (all expanded by default, matching the PWA's
  // aria-expanded="true").
  final Map<String, bool> _open = {
    'appearance': true,
    'privacy': true,
    'messaging': true,
    'channels': true,
    'mobile': true,
    'data': true,
  };

  // Live text-size preview value (commits to the controller on change end).
  double? _textSizePreview;

  @override
  void dispose() {
    _searchController.dispose();
    _keywordController.dispose();
    _transferPubkeyController.dispose();
    super.dispose();
  }

  bool _matches(String haystack) {
    if (_search.isEmpty) return true;
    return haystack.toLowerCase().contains(_search.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);

    final sections = <_SectionSpec>[
      _SectionSpec(
        key: 'appearance',
        title: 'Appearance',
        keywords: 'appearance theme color mode chat view wallpaper '
            'message layout transparency text size',
        builder: () => _appearance(settings, ctrl),
      ),
      _SectionSpec(
        key: 'privacy',
        title: 'Privacy & Security',
        keywords: 'privacy security identity encryption keypair proof of work '
            'accept private messages calls disappearing pm forward secrecy '
            'read receipts typing indicators status cache blur images blocked '
            'keywords friends blocked users',
        builder: () => _privacy(settings, ctrl),
      ),
      _SectionSpec(
        key: 'messaging',
        title: 'Messaging & Display',
        keywords: 'messaging display translation language notification sound '
            'auto-scroll show timestamps time format date format random '
            'nickname style ephemeral',
        builder: () => _messaging(settings, ctrl),
      ),
      _SectionSpec(
        key: 'channels',
        title: 'Channels',
        keywords: 'channels group chats pms only proximity landing channel '
            'hide non-favorited hidden blocked',
        builder: () => _channels(settings, ctrl),
      ),
      _SectionSpec(
        key: 'mobile',
        title: 'Mobile Gestures',
        keywords: 'mobile gestures swipe left right action react emoji '
            'sensitivity threshold',
        builder: () => _mobile(settings, ctrl),
      ),
      _SectionSpec(
        key: 'data',
        title: 'Data & Backup',
        keywords: 'data backup low data mode transfer settings pending '
            'transfers cache clear reset defaults',
        builder: () => _data(settings, ctrl),
      ),
    ];

    final visibleSections = sections
        .where((s) => _matches(s.title) || _matches(s.keywords))
        .toList();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(c),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _searchBar(c),
                            if (visibleSections.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 24),
                                child: Text(
                                  'No settings match your search.',
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13),
                                ),
                              ),
                            for (final s in visibleSections)
                              SettingsSection(
                                title: s.title,
                                open: _open[s.key] ?? true,
                                onToggle: () => setState(
                                    () => _open[s.key] = !(_open[s.key] ?? true)),
                                children: [s.builder()],
                              ),
                          ],
                        ),
                      ),
                    ),
                    _actions(c),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 14, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'SETTINGS',
              style: TextStyle(
                color: c.primary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.text.withValues(alpha: 0.05),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.close, size: 18, color: c.textDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FormInput(
        controller: _searchController,
        hint: 'Search settings...',
        onChanged: (v) => setState(() => _search = v),
      ),
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NymOutlineButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          // `.send-btn`: primary-tinted (bg primary@0.1, border primary@0.3),
          // primary uppercase text with wide letter-spacing.
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: NymRadius.rsm,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
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

  // --- Appearance -----------------------------------------------------------

  Widget _appearance(Settings s, SettingsController ctrl) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Color mode segment.
        FormGroup(
          hint: 'Auto matches your system preference',
          child: SegmentGroup<ColorMode>(
            value: s.colorMode,
            segments: const [
              (value: ColorMode.light, label: 'Light'),
              (value: ColorMode.auto, label: 'Auto'),
              (value: ColorMode.dark, label: 'Dark'),
            ],
            onChanged: ctrl.setColorMode,
          ),
        ),
        // Theme picker (each swatch shows its real accent).
        FormGroup(
          label: 'Theme',
          child: _ThemePicker(
            value: s.theme,
            onChanged: ctrl.setTheme,
          ),
        ),
        // Chat View (single / columns).
        FormGroup(
          label: 'Chat View',
          hint: 'Single shows one conversation at a time. Column view shows '
              'channels, PMs, and group chats side by side in scrollable '
              'columns you can add, remove, and drag to reorder.',
          child: FormSelect<String>(
            value: s.chatViewMode,
            items: const [
              (value: 'single', label: 'Single Chat (Default)'),
              (value: 'columns', label: 'Column View'),
            ],
            onChanged: ctrl.setChatViewMode,
          ),
        ),
        // Reset columns to defaults (PWA index.html:1406, `resetColumnView`).
        if (s.useColumns)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: NymOutlineButton(
              label: 'Reset columns to defaults',
              onPressed: ctrl.resetColumns,
            ),
          ),
        // Column Message Wallpaper (cv-only).
        if (s.useColumns)
          FormGroup(
            label: 'Column Message Wallpaper',
            hint: 'In column view, let your chat wallpaper show through the '
                'message area of each column instead of a solid background.',
            child: FormSelect<bool>(
              value: s.columnsWallpaper,
              items: const [
                (value: false, label: 'Solid background'),
                (value: true, label: 'Show wallpaper through messages'),
              ],
              onChanged: ctrl.setColumnsWallpaper,
            ),
          ),
        // Chat Wallpaper grid.
        FormGroup(
          label: 'Chat Wallpaper',
          hint: 'Choose a background pattern or upload your own image '
              '(min 1920x1080)',
          child: _WallpaperPicker(
            value: s.wallpaperType,
            onChanged: ctrl.setWallpaperType,
          ),
        ),
        // Message Layout (bubbles / irc).
        FormGroup(
          label: 'Message Layout',
          hint: 'Choose between classic IRC-style or modern chat bubbles',
          child: _LayoutPicker(
            value: s.chatLayout,
            onChanged: ctrl.setChatLayout,
          ),
        ),
        // Visual Transparency.
        FormGroup(
          label: 'Visual Transparency',
          hint: 'Choose between Solid or Glass, where messages, modals, '
              'sidebars, and other surfaces are rendered with either solid '
              'backgrounds or a translucent "Glass" look.',
          child: FormSelect<bool>(
            value: s.transparencyEnabled,
            items: const [
              (value: false, label: 'Solid'),
              (value: true, label: 'Glass'),
            ],
            onChanged: ctrl.setTransparencyEnabled,
          ),
        ),
        // Text Size slider with live preview + reset.
        FormGroup(
          label: 'Text Size',
          hint: 'Adjust the size of all text across the app',
          child: _TextSizeRow(
            value: (_textSizePreview ?? s.textSize.toDouble()),
            previewColor: c.primary,
            onChanged: (v) => setState(() => _textSizePreview = v),
            onChangeEnd: (v) {
              ctrl.setTextSize(v.round());
              setState(() => _textSizePreview = null);
            },
            onReset: () {
              ctrl.setTextSize(NymTextSize.defaultSize.round());
              setState(() => _textSizePreview = null);
            },
          ),
        ),
      ],
    );
  }

  // --- Privacy & Security ---------------------------------------------------

  Widget _privacy(Settings s, SettingsController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Identity Encryption',
          hint: "Optionally protect your saved identity's (nsec) private key "
              'with a password, PIN, passkey, or biometric (Face/Touch ID) so '
              "it can't be read from this device without unlocking. Passkeys "
              '(synced or hardware security keys) and biometrics use WebAuthn '
              'where supported, with password/PIN as the universal fallback.',
          child: NymOutlineButton(
            label: 'Encrypt identity (nsec) key on this device…',
            onPressed: () {
              // TODO(verify): vault settings flow (openVaultSettings) is a
              // separate identity feature; out of scope for this settings UI.
            },
          ),
        ),
        FormGroup(
          label: 'Generate Random Keypair Per Session',
          hint: 'Generate a new random keypair on every session restart for '
              'improved pseudonymity. When disabled, your generated keypair '
              'persists across reloads.',
          warning: ctrl.keypairMode == 'hardcore'
              ? '⚠ Hardcore mode changes your identity after every sent '
                  'message. PMs and group chats will not work reliably since '
                  'recipients cannot reply to a constantly changing pubkey. '
                  'Settings will not sync across devices.'
              : null,
          child: FormSelect<String>(
            value: ctrl.keypairMode,
            items: const [
              (value: 'persistent', label: 'Disabled (reuse same keypair)'),
              (value: 'random', label: 'Enabled (new identity each session)'),
              (value: 'hardcore', label: 'Hardcore (new keypair every message)'),
            ],
            onChanged: (v) => setState(() => ctrl.setKeypairMode(v)),
          ),
        ),
        FormGroup(
          label: 'Proof of Work Difficulty',
          hint: 'Enable for anti-spam to require messages have a minimum PoW',
          child: FormSelect<int>(
            value: ctrl.powDifficulty,
            items: const [
              (value: 0, label: 'Disabled'),
              (value: 8, label: 'Very Low (8 bits)'),
              (value: 12, label: 'Low (12 bits)'),
              (value: 16, label: 'Medium (16 bits)'),
              (value: 20, label: 'High (20 bits)'),
              (value: 24, label: 'Very High (24 bits)'),
            ],
            onChanged: (v) => setState(() => ctrl.setPowDifficulty(v)),
          ),
        ),
        FormGroup(
          label: 'Accept Private Messages & Group Chat Requests',
          hint: 'Control who can send you PMs and group chat invites. '
              '"Friends only" filters messages from non-friends.',
          child: FormSelect<String>(
            value: s.acceptPMs,
            items: const [
              (value: 'enabled', label: 'Enabled'),
              (value: 'friends', label: 'Friends only'),
              (value: 'disabled', label: 'Disabled'),
            ],
            onChanged: ctrl.setAcceptPMs,
          ),
        ),
        FormGroup(
          label: 'Accept Audio & Video Calls',
          hint: 'Control who can ring you with an audio or video call. '
              '"Friends only" silently ignores calls from non-friends.',
          warning: '⚠ Audio/video calls and P2P file sharing connect peers '
              'directly over WebRTC, which can reveal your true IP address to '
              'the other party. Use a VPN or Tor to help conceal it.',
          child: FormSelect<String>(
            value: s.acceptCalls,
            items: const [
              (value: 'enabled', label: 'Enabled'),
              (value: 'friends', label: 'Friends only'),
              (value: 'disabled', label: 'Disabled'),
            ],
            onChanged: ctrl.setAcceptCalls,
          ),
        ),
        FormGroup(
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
            onChanged: ctrl.setDmForwardSecrecy,
          ),
        ),
        // Disappear After (TTL) — shown when forward secrecy is enabled.
        if (s.dmForwardSecrecyEnabled)
          FormGroup(
            label: 'Disappear After',
            hint: 'This sets the "expiration" timestamp on each outgoing '
                'gift‑wrapped PM.',
            child: FormSelect<int>(
              value: s.dmTtlSeconds,
              items: const [
                (value: 3600, label: '1 hour'),
                (value: 21600, label: '6 hours'),
                (value: 86400, label: '1 day'),
                (value: 259200, label: '3 days'),
                (value: 604800, label: '7 days'),
              ],
              onChanged: ctrl.setDmTtlSeconds,
            ),
          ),
        FormGroup(
          label: 'Read Receipts',
          hint: "Choose where senders can see when you've read their messages "
              '(✓✓). "Enabled everywhere" includes PMs, group chats, and '
              'public channels.',
          child: FormSelect<String>(
            value: s.readReceiptsScope,
            items: const [
              (value: 'everywhere', label: 'Enabled everywhere'),
              (value: 'pms-groups', label: 'Both PMs and group chats'),
              (value: 'pms', label: 'Only PMs'),
              (value: 'groups', label: 'Only group chats'),
              (value: 'disabled', label: 'Disabled completely'),
            ],
            onChanged: ctrl.setReadReceiptsScope,
          ),
        ),
        FormGroup(
          label: 'Typing Indicators',
          hint: "Choose where others can see when you're typing. "
              '"Enabled everywhere" includes PMs, group chats, and public '
              'channels.',
          child: FormSelect<String>(
            value: s.typingIndicatorsScope,
            items: const [
              (value: 'everywhere', label: 'Enabled everywhere'),
              (value: 'pms-groups', label: 'Both PMs and group chats'),
              (value: 'pms', label: 'Only PMs'),
              (value: 'groups', label: 'Only group chats'),
              (value: 'disabled', label: 'Disabled completely'),
            ],
            onChanged: ctrl.setTypingIndicatorsScope,
          ),
        ),
        FormGroup(
          label: 'Show Status Indicators',
          hint: 'When enabled, online/away/offline status dots are shown on '
              'avatars and in user profiles. "Friends only" broadcasts a '
              'hidden status publicly while privately sharing your real status '
              "with people you've marked as friends, so only they can see it. "
              'When disabled, your status is hidden from everyone, but you can '
              "still see other people's status indicators.",
          child: FormSelect<String>(
            value: s.showStatus,
            items: const [
              (value: 'true', label: 'Enabled'),
              (value: 'friends', label: 'Friends only'),
              (value: 'false', label: 'Disabled'),
            ],
            onChanged: ctrl.setShowStatus,
          ),
        ),
        FormGroup(
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
            onChanged: ctrl.setCachePMs,
          ),
        ),
        FormGroup(
          label: 'Blur Images from Others',
          hint: 'Blur images shared by others until clicked. Your own images '
              'are never blurred. "Friends only" shows images from friends '
              'unblurred.',
          child: FormSelect<String>(
            value: ctrl.blurImages,
            items: const [
              (value: 'true', label: 'Enabled (blur by default)'),
              (value: 'friends', label: 'Disabled (for friends only)'),
              (value: 'false', label: 'Disabled (show all images)'),
            ],
            onChanged: (v) => setState(() => ctrl.setBlurImages(
                  v,
                  pubkey: ref.read(appStateProvider).selfPubkey,
                )),
          ),
        ),
        FormGroup(
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
                  onPressed: () {
                    // TODO(verify): blocked-keyword list persistence
                    // (nym_blocked_keywords) is a moderation list owned by the
                    // messaging subsystem; this UI only exposes the editor.
                    _keywordController.clear();
                  },
                ),
              ),
              const SizedBox(height: 8),
              _emptyListBox('No blocked keywords'),
            ],
          ),
        ),
        FormGroup(
          label: 'Friends',
          hint: 'Friends can have special privileges like bypassing image '
              'blur and message filters. Add friends from the context menu on '
              'any user.',
          child: _emptyListBox('No friends added'),
        ),
        FormGroup(
          label: 'Blocked Users',
          child: _emptyListBox('No blocked users'),
        ),
      ],
    );
  }

  // --- Messaging & Display --------------------------------------------------

  Widget _messaging(Settings s, SettingsController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Translation Language',
          hint: 'Choose your preferred language for translating messages via '
              'the context menu.',
          child: FormSelect<String>(
            value: s.translateLanguage,
            items: _translationLanguages,
            onChanged: ctrl.setTranslateLanguage,
          ),
        ),
        FormGroup(
          label: 'Notification Sound',
          child: FormSelect<String>(
            value: s.sound,
            items: _soundOptions,
            onChanged: ctrl.setSound,
          ),
        ),
        FormGroup(
          label: 'Auto-scroll Messages',
          child: FormSelect<bool>(
            value: s.autoscroll,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: ctrl.setAutoscroll,
          ),
        ),
        FormGroup(
          label: 'Show Timestamps',
          child: FormSelect<bool>(
            value: s.showTimestamps,
            items: const [
              (value: true, label: 'Show'),
              (value: false, label: 'Hide'),
            ],
            onChanged: ctrl.setShowTimestamps,
          ),
        ),
        FormGroup(
          label: 'Time Format',
          child: FormSelect<String>(
            value: s.timeFormat,
            items: const [
              (value: '24hr', label: '24-hour (14:30)'),
              (value: '12hr', label: '12-hour (2:30 PM)'),
            ],
            onChanged: ctrl.setTimeFormat,
          ),
        ),
        FormGroup(
          label: 'Date Format',
          hint: 'Used in the full timestamp shown when tapping a message time',
          child: FormSelect<String>(
            value: s.dateFormat,
            items: const [
              (value: 'default', label: 'Default (May 28, 2026)'),
              (value: 'mdy', label: 'MM/DD/YYYY (05/28/2026)'),
              (value: 'dmy', label: 'DD/MM/YYYY (28/05/2026)'),
              (value: 'ymd', label: 'YYYY-MM-DD (2026-05-28)'),
            ],
            onChanged: ctrl.setDateFormat,
          ),
        ),
        FormGroup(
          label: 'Random Nickname Style',
          hint: 'Style used when generating random nicknames',
          child: FormSelect<String>(
            value: s.nickStyle,
            items: const [
              (value: 'fancy', label: 'Fancy (adjective_noun)'),
              (value: 'simple', label: 'Simple (nym1234)'),
            ],
            onChanged: ctrl.setNickStyle,
          ),
        ),
        // NOTE: #autoEphemeralSettingGroup is hidden by default in the PWA
        // (nm-hidden) and only shown in ephemeral-login context, so it is
        // omitted here to match the default rendering.
      ],
    );
  }

  // --- Channels -------------------------------------------------------------

  Widget _channels(Settings s, SettingsController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Group Chats & PMs Only Mode',
          hint: 'Hides all geohash channels and focuses the app on group '
              'chats and private messages only. Reduces bandwidth by skipping '
              'channel subscriptions.',
          child: FormSelect<bool>(
            value: s.groupChatPMOnlyMode,
            items: const [
              (value: false, label: 'Disabled (show geohash channels)'),
              (value: true, label: 'Enabled (group chats & PMs only)'),
            ],
            onChanged: ctrl.setGroupChatPMOnlyMode,
          ),
        ),
        FormGroup(
          label: 'Sort Geohash Channels by Proximity',
          hint: 'Sort geohash channels by distance from your location',
          child: FormSelect<bool>(
            value: s.sortByProximity,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled (requires location access)'),
            ],
            onChanged: ctrl.setSortByProximity,
          ),
        ),
        FormGroup(
          label: 'Default Landing Channel',
          hint: 'Channel to load when you first open or reload the app',
          child: FormInput(
            hint: 'Type to search or select a channel...',
          ),
        ),
        FormGroup(
          label: 'Hide All Non-Favorited Channels',
          hint: 'When enabled, only your favorited channels will appear in '
              'the sidebar',
          child: FormSelect<bool>(
            value: ctrl.hideNonPinned,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled (only show favorited channels)'),
            ],
            onChanged: (v) => setState(() => ctrl.setHideNonPinned(v)),
          ),
        ),
        FormGroup(
          label: 'Hidden Channels',
          child: _emptyListBox('No hidden channels'),
        ),
        FormGroup(
          label: 'Blocked Channels',
          child: _emptyListBox('No blocked channels'),
        ),
      ],
    );
  }

  // --- Mobile Gestures ------------------------------------------------------

  Widget _mobile(Settings s, SettingsController ctrl) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Swipe Gestures (Mobile)',
          hint: 'Swipe a message horizontally to trigger an action. Disable '
              'to turn off all swipe gestures on messages.',
          child: FormSelect<bool>(
            value: s.gesturesEnabled,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: ctrl.setGesturesEnabled,
          ),
        ),
        FormGroup(
          label: 'Swipe Left Action',
          hint: 'Action triggered when swiping a message to the left.',
          child: FormSelect<String>(
            value: s.swipeLeftAction,
            items: swipeActions,
            onChanged: ctrl.setSwipeLeftAction,
          ),
        ),
        FormGroup(
          label: 'Swipe Right Action',
          hint: 'Action triggered when swiping a message to the right.',
          child: FormSelect<String>(
            value: s.swipeRightAction,
            items: swipeRightActions,
            onChanged: ctrl.setSwipeRightAction,
          ),
        ),
        FormGroup(
          label: 'Quick React Emoji',
          hint: 'Emoji always used when a swipe gesture is set to "Quick '
              'React". Tap to choose from the full emoji picker.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: '${s.swipeReactEmoji}   Change',
              uppercase: false,
              onPressed: () {
                // TODO(verify): swipe react emoji picker hooks into the emoji
                // subsystem (out of scope for the settings UI).
              },
            ),
          ),
        ),
        FormGroup(
          label: 'Swipe Sensitivity',
          hint: 'How far you need to swipe before the action fires. Higher '
              'sensitivity means a shorter swipe.',
          child: FormSelect<int>(
            value: s.swipeThreshold,
            items: const [
              (value: 40, label: 'High (40px)'),
              (value: 60, label: 'Medium (60px)'),
              (value: 80, label: 'Low (80px)'),
              (value: 100, label: 'Very Low (100px)'),
            ],
            onChanged: ctrl.setSwipeThreshold,
          ),
        ),
      ],
    );
  }

  // --- Data & Backup --------------------------------------------------------

  Widget _data(Settings s, SettingsController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Low Data Mode',
          hint: 'Reduces bandwidth by connecting to only 5 default relays and '
              'loading geo relays on-demand when entering channels',
          child: FormSelect<bool>(
            value: s.lowDataMode,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled'),
            ],
            onChanged: ctrl.setLowDataMode,
          ),
        ),
        FormGroup(
          label: 'Transfer Settings to Another User',
          hint: 'Transfers your nickname, avatar, and all preferences to the '
              'specified pubkey',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FormInput(
                  controller: _transferPubkeyController,
                  hint: 'Recipient hex pubkey (64 chars)',
                ),
              ),
              const SizedBox(width: 8),
              NymOutlineButton(
                label: 'Send',
                onPressed: () {
                  // TODO(verify): settings transfer is a networked sync feature
                  // (executeSettingsTransfer) outside this UI's ownership.
                },
              ),
            ],
          ),
        ),
        FormGroup(
          label: 'Pending Settings Transfers',
          child: _emptyListBox('No pending transfers'),
        ),
        FormGroup(
          hint: 'Clears the on-device app cache (channel history, PMs, group '
              'chats, profiles, reactions). Preserves your login, settings, '
              'group memberships, and flair purchases.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Calculating…',
                style: TextStyle(color: context.nym.textDim, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: 'Clear Local Storage Cache',
                  onPressed: () {
                    // TODO(verify): cache clearing spans multiple subsystems;
                    // wiring deferred to the data/storage owner.
                  },
                ),
              ),
            ],
          ),
        ),
        FormGroup(
          hint: 'Resets preferences (theme, layout, wallpaper, sound, '
              'favorited/hidden/blocked channels, blocked users, blocked '
              'keywords) to defaults. Preserves your login, group '
              'memberships, PM history, and flair purchases.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: 'Reset Settings to Defaults',
              onPressed: () {
                // TODO(verify): full reset clears moderation lists owned by
                // other subsystems; deferred.
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyListBox(String text) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.bg.withValues(alpha: c.isLight ? 1 : 0.3),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Text(
        text,
        style: TextStyle(color: c.textDim, fontSize: 12),
      ),
    );
  }
}

/// Section descriptor for search filtering.
class _SectionSpec {
  _SectionSpec({
    required this.key,
    required this.title,
    required this.keywords,
    required this.builder,
  });
  final String key;
  final String title;
  final String keywords;
  final Widget Function() builder;
}

// === Pickers ================================================================

/// Theme picker showing each of the six themes with its real accent dot.
class _ThemePicker extends ConsumerWidget {
  const _ThemePicker({required this.value, required this.onChanged});
  final NymThemeKey value;
  final ValueChanged<NymThemeKey> onChanged;

  static const _labels = {
    NymThemeKey.bitchat: 'Bitchat (Multicolor)',
    NymThemeKey.matrix: 'Matrix Green',
    NymThemeKey.amber: 'Amber Terminal',
    NymThemeKey.cyber: 'Cyberpunk',
    NymThemeKey.hacker: 'Hacker Blue',
    NymThemeKey.ghost: 'Ghost (B&W)',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final brightness = c.brightness;
    return Column(
      children: [
        for (final t in NymThemeKey.values)
          () {
            final accent = resolveNymColors(
              theme: t,
              brightness: brightness,
              solidUi: true,
            ).primary;
            final selected = t == value;
            return InkWell(
              onTap: () => onChanged(t),
              borderRadius: NymRadius.rsm,
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? c.primaryA(0.10)
                      : c.bg.withValues(alpha: c.isLight ? 1 : 0.3),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(
                    color: selected ? c.primaryA(0.5) : c.glassBorder,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.glassBorder),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _labels[t]!,
                        style: TextStyle(
                          color: selected ? c.primary : c.text,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check, size: 16, color: c.primary),
                  ],
                ),
              ),
            );
          }(),
      ],
    );
  }
}

/// Wallpaper picker: 3-column grid of the 8 built-in patterns + Upload, with
/// the selected option ringed in the accent color.
class _WallpaperPicker extends StatelessWidget {
  const _WallpaperPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

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
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.4,
      children: [
        for (final o in _options)
          GestureDetector(
            onTap: () => onChanged(o.id),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
                      borderRadius: NymRadius.rxs,
                      border: Border.all(
                        color: o.id == value ? c.primary : c.glassBorder,
                        width: o.id == value ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      o.id == 'none'
                          ? Icons.close
                          : o.id == 'custom'
                              ? Icons.file_upload_outlined
                              : Icons.texture,
                      size: 18,
                      color: c.textDim,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  o.label,
                  style: TextStyle(
                    color: o.id == value ? c.primary : c.textDim,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Message-layout picker (Bubbles / IRC) as two selectable preview cards.
class _LayoutPicker extends StatelessWidget {
  const _LayoutPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    Widget card(String id, String label) {
      final selected = value == id;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(id),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected
                  ? c.primaryA(0.10)
                  : c.bg.withValues(alpha: c.isLight ? 1 : 0.3),
              borderRadius: NymRadius.rsm,
              border: Border.all(
                color: selected ? c.primaryA(0.5) : c.glassBorder,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  id == 'bubbles'
                      ? Icons.chat_bubble_outline
                      : Icons.format_align_left,
                  color: selected ? c.primary : c.textDim,
                  size: 28,
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? c.primary : c.text,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card('bubbles', 'Bubbles (Default)'),
          const SizedBox(width: 8),
          card('irc', 'IRC Style'),
        ],
      ),
    );
  }
}

/// Text-size slider row: small "A", slider, large "A", value badge, Reset.
class _TextSizeRow extends StatelessWidget {
  const _TextSizeRow({
    required this.value,
    required this.previewColor,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onReset,
  });

  final double value;
  final Color previewColor;
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
            data: SliderThemeData(
              activeTrackColor: c.primary,
              inactiveTrackColor: c.glassBorder,
              thumbColor: c.primary,
              overlayColor: c.primaryA(0.2),
              trackHeight: 3,
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
        Text(
          '${value.round()}px',
          style: TextStyle(color: previewColor, fontSize: 12),
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
