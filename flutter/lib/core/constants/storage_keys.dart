/// localStorage key names ported verbatim from the PWA so settings semantics match.
class StorageKeys {
  StorageKeys._();

  // Hybrid post-quantum messaging
  static const pqMode = 'nym_pq_mode';
  static const pqEpoch = 'nym_pq_epoch';
  static const pqDeviceId = 'nym_pq_device_id';
  static const pqUpgradeNotice = 'nym_pq_upgrade_notice';
  static const pqUpgradeSeen = 'nym_pq_upgrade_seen';

  /// Post-quantum root secret: nsec-grade key material, so it lives in secure storage via [SecretKeys.all].
  static const pqRoot = 'nym_pq_root';

  /// Set once a root is generated, so its `nympq1…` code is shown exactly once.
  static const pqRootBackupNotice = 'nym_pq_root_backup_notice';

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
  static const vaultBioProtected = 'nym_vault_bio_protected';
  static const encryptAtRestPref = 'nym_encrypt_at_rest_pref';
  static const encryptAtRestPromptDismissed =
      'nym_encrypt_at_rest_prompt_dismissed';
  static const remotePanic = 'nym_remote_panic';
  static const panicLoginAt = 'nym_panic_login_at';
  static const panicClearPending = 'nym_panic_clear_pending';

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

  /// Reply threads on/off, default on.
  static const threadsEnabled = 'nym_threads_enabled';
  static const columnsLayout = 'nym_columns_layout';
  static const columnsWallpaper = 'nym_columns_wallpaper';
  static const wallpaperType = 'nym_wallpaper_type';
  static const wallpaperCustomUrl = 'nym_wallpaper_custom_url';
  static const lowDataMode = 'nym_low_data_mode';
  static const relayDirectMode = 'nym_relay_direct_mode';
  static const relayDirectAck = 'nym_relay_direct_ack';
  static const relayFallbackNoticeOff = 'nym_relay_fallback_notice_off';

  /// Unix seconds of the last iOS background catch-up; only newer events notify, and absent means none.
  static const backgroundCatchUpTs = 'nym_background_catchup_ts';

  /// Keep relays and the mesh running in the background; off by default for battery.
  static const backgroundConnectivity = 'nym_background_connectivity';
  static const heartbeatToken = 'nym_heartbeat_token';
  static const meshEnabled = 'nym_mesh_enabled';

  /// Ghost Mode on/off; device-local so enabling it is not announced to other devices.
  static const ghostMode = 'nym_ghost_mode';

  /// Peers talked to while ghosted; pinned to the mesh so replies never go out under the real key.
  static const ghostPinnedPms = 'nym_ghost_pinned_pms';
  static const groupchatPmOnlyMode = 'nym_groupchat_pm_only_mode';
  static const nickStyle = 'nym_nick_style';
  static const pinnedLandingChannel = 'nym_pinned_landing_channel';
  static const lastView = 'nym_last_view';
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

  /// Unix seconds of the last local [swipeReactEmoji] pick, so stale synced blobs can't clobber it.
  static const swipeReactEmojiTs = 'nym_swipe_react_emoji_ts';
  static const translateLanguage = 'nym_translate_language';
  static const translateFavorites = 'nym_translate_favorites';

  /// Static UI language (empty means English), distinct from [translateLanguage].
  static const uiLanguage = 'nym_ui_language';

  static const legacyAutoTranslateKeys = <String>[
    'nym_auto_translate',
    'nym_auto_translate_channels',
    'nym_auto_translate_pms',
    'nym_auto_translate_groups',
  ];

  /// Device-local: the first-run language picker was answered, so it shows at most once.
  static const uiLanguageChosen = 'nym_ui_language_chosen';
  static const powDifficulty = 'nym_pow_difficulty';
  static const appVerifiedFilter = 'nym_app_verified_filter';
  static const filterPacks = 'nym_filter_packs';
  static const attestBadge = 'nym_attest_badge';
  static const attestAuthority = 'nym_attest_authority';
  static const hideNonPinned = 'nym_hide_non_pinned';
  static const hidePreviews = 'nym_hide_previews';
  static const sidebarWidth = 'nym_sidebar_width';
  static const columnWidth = 'nym_column_width';
  static const colorfulMessages = 'nym_colorful_messages';
  static const largeTargets = 'nym_large_targets';
  static const highContrast = 'nym_high_contrast';
  static const infoPanelOpen = 'nym_info_panel_open';
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
  static const autoMuted = 'nym_auto_muted';
  static const friends = 'nym_friends';
  static const blockedKeywords = 'nym_blocked_keywords';
  static const blockedRelays = 'nym_blocked_relays';

  static const spamFilterEnabled = 'nym_spam_filter_enabled';
  static const spamFilterAggressive = 'nym_spam_filter_aggressive';

  static const pubkeyFormat = 'nym_pubkey_format';
  static const voiceSpeed = 'nym_voice_speed';
  static const keepCallHistory = 'nym_keep_call_history';
  static const botAnonEnabled = 'nym_botanon_enabled';

  // PMs / groups
  static const closedPms = 'nym_closed_pms';
  static const closedPmTimes = 'nym_closed_pm_times';
  static const leftGroups = 'nym_left_groups';
  static const leftGroupTimes = 'nym_left_group_times';
  static String lastPmSyncFor(String pubkey) => 'nym_last_pm_sync_$pubkey';
  static String pmSupportTokensFor(String pubkey) =>
      'nym_pm_support_tokens_$pubkey';
  static const pendingGroupInvite = 'nym_pending_group_invite';
  static const groupStorePrefix = 'nym_groups_';
  static String groupStoreFor(String pubkey) => '$groupStorePrefix$pubkey';

  /// Mesh sender outbox, replayed to Nostr when relays return.
  static const meshOutbox = 'nym_mesh_outbox';

  static const switchOutbox = 'nym_switch_outbox';

  /// Gossip-sync public history, persisted so it can still be served after a restart.
  static const meshGossipArchive = 'nym_mesh_gossip_archive';

  /// One-time mesh prekey private halves, persisted so mail sealed before a restart still opens.
  static const meshPrekeys = 'nym_mesh_prekeys';

  static const sealedPrefs = [
    leftGroups,
    leftGroupTimes,
    meshGossipArchive,
    meshPrekeys,
    switchOutbox,
  ];

  // Notifications / sync
  static const notificationsEnabled = 'nym_notifications_enabled';
  static const groupNotifyMentionsOnly = 'nym_group_notify_mentions_only';
  static const threadNotifyMentionsOnly = 'nym_thread_notify_mentions_only';
  static const notifyFriendsOnly = 'nym_notify_friends_only';
  static const eventToasts = 'nym_event_toasts';
  static const notificationLastRead = 'nym_notification_last_read';
  static const lastSettingsSyncTs = 'nym_last_settings_sync_ts';
  static const settingsDirtyKeys = 'nym_settings_dirty_keys';

  // Emoji / gifs
  static const emojiPackFavorites = 'nym_emoji_pack_favorites';
  static const emojiCategoryFavorites = 'nym_emoji_category_favorites';
  static const recentEmojis = 'nym_recent_emojis';
  static const favoriteGifs = 'nym_favorite_gifs';

  // Bot / shop
  static const botpmWelcomed = 'nym_botpm_welcomed';
  static const botpmClearedAt = 'nym_botpm_cleared_at';
  static const botpmMaxRuns = 'nym_botpm_max_runs';
  static const botpmProModel = 'nym_botpm_pro_model';
  static const purchasesCache = 'nym_purchases_cache';
  static const activeStyle = 'nym_active_style';
  static const activeFlair = 'nym_active_flair';

  // Sidebar layout
  static const sidebarSectionCollapsed = 'nym_sidebar_section_collapsed';
  static const sidebarSectionOrder = 'nym_sidebar_section_order';

  // Misc
  static const tutorialSeen = 'nym_tutorial_seen';
  static const dismissedTransfers = 'nym_dismissed_transfers';
  static const relayStats = 'nym_relay_stats';
}

/// Identity secrets, kept in flutter_secure_storage (Keychain/Keystore).
class SecretKeys {
  SecretKeys._();
  static const sessionNsec = 'nym_session_nsec';
  static const devNsec = 'nym_dev_nsec';
  static const nostrLoginNsec = 'nym_nostr_login_nsec';
  static const nip46ClientSecret = 'nym_nip46_client_secret';

  /// In the protected set so the root is encrypted at rest and cleared with the identity.
  static const pqRoot = StorageKeys.pqRoot;

  static const List<String> all = [
    sessionNsec,
    devNsec,
    nostrLoginNsec,
    nip46ClientSecret,
    pqRoot,
  ];
}
