/// localStorage key names ported verbatim from the PWA (docs/specs/01 §5.2).
///
/// On native these back a key/value store (SharedPreferences for non-secret
/// values; the four identity secrets live in flutter_secure_storage — see
/// [SecretKeys]). Names are preserved 1:1 so settings/state semantics match.
class StorageKeys {
  StorageKeys._();

  // Identity / login
  static const nostrLoginMethod = 'nym_nostr_login_method';
  static const nostrLoginPubkey = 'nym_nostr_login_pubkey';
  static const nostrLoginNpub = 'nym_nostr_login_npub';
  static const nostrLoginProfile = 'nym_nostr_login_profile';
  static const nip46RemotePubkey = 'nym_nip46_remote_pubkey';
  static const nip46Relay = 'nym_nip46_relay';
  static const autoEphemeral = 'nym_auto_ephemeral';
  static const autoEphemeralNick = 'nym_auto_ephemeral_nick';
  static const autoEphemeralChannel = 'nym_auto_ephemeral_channel';
  static const randomKeypairPerSession = 'nym_random_keypair_per_session';
  static const keypairMode = 'nym_keypair_mode';

  // Vault
  static const vaultEnabled = 'nym_vault_enabled';
  static const vaultMethod = 'nym_vault_method';
  static const vaultSalt = 'nym_vault_salt';
  static const vaultCred = 'nym_vault_cred';
  static const vaultCheck = 'nym_vault_check';
  static const encryptAtRestPref = 'nym_encrypt_at_rest_pref';
  static const encryptAtRestPromptDismissed =
      'nym_encrypt_at_rest_prompt_dismissed';

  // Settings (one per Settings field)
  static const theme = 'nym_theme';
  static const colorMode = 'nym_color_mode';
  static const sound = 'nym_sound';
  static const autoscroll = 'nym_autoscroll';
  static const timestamps = 'nym_timestamps';
  static const timeFormat = 'nym_time_format';
  static const dateFormat = 'nym_date_format';
  static const sortProximity = 'nym_sort_proximity';
  static const textSize = 'nym_text_size';
  static const transparencyEnabled = 'nym_transparency_enabled';
  static const chatLayout = 'nym_chat_layout';
  static const chatViewMode = 'nym_chat_view_mode';
  static const columnsLayout = 'nym_columns_layout';
  static const columnsWallpaper = 'nym_columns_wallpaper';
  static const wallpaperType = 'nym_wallpaper_type';
  static const wallpaperCustomUrl = 'nym_wallpaper_custom_url';
  static const lowDataMode = 'nym_low_data_mode';
  static const groupchatPmOnlyMode = 'nym_groupchat_pm_only_mode';
  static const nickStyle = 'nym_nick_style';
  static const pinnedLandingChannel = 'nym_pinned_landing_channel';
  static const dmFwdSecEnabled = 'nym_dm_fwdsec_enabled';
  static const dmTtlSeconds = 'nym_dm_ttl_seconds';
  static const readReceiptsScope = 'nym_read_receipts_scope';
  static const readReceiptsEnabled = 'nym_read_receipts_enabled';
  static const typingIndicatorsScope = 'nym_typing_indicators_scope';
  static const typingIndicatorsEnabled = 'nym_typing_indicators_enabled';
  static const acceptPms = 'nym_accept_pms';
  static const acceptCalls = 'nym_accept_calls';
  static const cachePms = 'nym_cache_pms';
  static const syncMlsHistory = 'nym_sync_mls_history';
  static const showStatus = 'nym_show_status';
  static const gesturesEnabled = 'nym_gestures_enabled';
  static const swipeLeftAction = 'nym_swipe_left_action';
  static const swipeRightAction = 'nym_swipe_right_action';
  static const swipeThreshold = 'nym_swipe_threshold';
  static const swipeReactEmoji = 'nym_swipe_react_emoji';
  static const translateLanguage = 'nym_translate_language';
  static const translateFavorites = 'nym_translate_favorites';

  /// The app's static-text UI language (empty ⇒ English). Distinct from
  /// [translateLanguage], which is the on-the-fly message-translation target.
  static const uiLanguage = 'nym_ui_language';

  /// Auto-translate incoming messages (in the active conversation) that aren't
  /// already in [translateLanguage]. Master switch + per-conversation-type
  /// gates (channels / PMs / groups), each default-on once the master is on.
  static const autoTranslate = 'nym_auto_translate';
  static const autoTranslateChannels = 'nym_auto_translate_channels';
  static const autoTranslatePms = 'nym_auto_translate_pms';
  static const autoTranslateGroups = 'nym_auto_translate_groups';

  /// Device-local flag: the first-run language picker has been answered (even
  /// if the user kept English), so onboarding shows it at most once per device.
  static const uiLanguageChosen = 'nym_ui_language_chosen';
  static const powDifficulty = 'nym_pow_difficulty';
  static const hideNonPinned = 'nym_hide_non_pinned';
  static const imageBlur = 'nym_image_blur';
  static String imageBlurFor(String pubkey) => 'nym_image_blur_$pubkey';

  // Profile / wallet
  static const bio = 'nym_bio';
  static const avatarUrl = 'nym_avatar_url';
  static const bannerUrl = 'nym_banner_url';
  static const lightningAddressGlobal = 'nym_lightning_address_global';
  static const lightningAddress = 'nym_lightning_address';
  static String lightningAddressFor(String pubkey) =>
      'nym_lightning_address_$pubkey';
  static const customNick = 'nym_custom_nick';

  // Channels / lists
  static const pinnedChannels = 'nym_pinned_channels';
  static const hiddenChannels = 'nym_hidden_channels';
  static const blockedChannels = 'nym_blocked_channels';
  static const userJoinedChannels = 'nym_user_joined_channels';
  static const userChannels = 'nym_user_channels';
  static const unreadCounts = 'nym_unread_counts';
  static const channelActivity = 'nym_channel_activity';
  static const channelLastRead = 'nym_channel_last_read';

  // Social / blocks
  static const blocked = 'nym_blocked';
  static const friends = 'nym_friends';
  static const blockedKeywords = 'nym_blocked_keywords';

  // Spam filter (heuristic content filter — PWA `spamFilterEnabled` /
  // `spamFilterAggressive`, both default true; device-local, no UI in the PWA's
  // settings modal). Distinct from the web-of-trust spam GATE.
  static const spamFilterEnabled = 'nym_spam_filter_enabled';
  static const spamFilterAggressive = 'nym_spam_filter_aggressive';

  // PMs / groups
  static const closedPms = 'nym_closed_pms';
  static const closedPmTimes = 'nym_closed_pm_times';
  static const leftGroupTimes = 'nym_left_group_times';
  static String lastPmSyncFor(String pubkey) => 'nym_last_pm_sync_$pubkey';
  static const pendingGroupInvite = 'nym_pending_group_invite';

  // Notifications / sync
  static const notificationsEnabled = 'nym_notifications_enabled';
  static const groupNotifyMentionsOnly = 'nym_group_notify_mentions_only';
  static const notifyFriendsOnly = 'nym_notify_friends_only';
  static const notificationLastRead = 'nym_notification_last_read';
  static const lastSettingsSyncTs = 'nym_last_settings_sync_ts';

  // Emoji / gifs
  static const emojiPackFavorites = 'nym_emoji_pack_favorites';
  static const emojiCategoryFavorites = 'nym_emoji_category_favorites';
  static const recentEmojis = 'nym_recent_emojis';
  static const favoriteGifs = 'nym_favorite_gifs';

  // Bot / shop
  static const botpmWelcomed = 'nym_botpm_welcomed';
  static const botpmClearedAt = 'nym_botpm_cleared_at';
  static const botpmProModel = 'nym_botpm_pro_model';
  static const botpmGit = 'nym_botpm_git';
  static const purchasesCache = 'nym_purchases_cache';
  static const activeStyle = 'nym_active_style';
  static const activeFlair = 'nym_active_flair';

  // Sidebar layout (section collapse + order persistence)
  static const sidebarSectionCollapsed = 'nym_sidebar_section_collapsed';
  static const sidebarSectionOrder = 'nym_sidebar_section_order';

  // Misc
  static const tutorialSeen = 'nym_tutorial_seen';
  static const dismissedTransfers = 'nym_dismissed_transfers';
  static const relayStats = 'nym_relay_stats';
}

/// The four identity secrets that are encrypted at rest in the PWA vault.
/// On native these are stored via flutter_secure_storage (Keychain/Keystore).
class SecretKeys {
  SecretKeys._();
  static const sessionNsec = 'nym_session_nsec';
  static const devNsec = 'nym_dev_nsec';
  static const nostrLoginNsec = 'nym_nostr_login_nsec';
  static const nip46ClientSecret = 'nym_nip46_client_secret';

  static const List<String> all = [
    sessionNsec,
    devNsec,
    nostrLoginNsec,
    nip46ClientSecret,
  ];
}
