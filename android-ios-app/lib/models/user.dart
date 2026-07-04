/// Presence status of a user (docs/specs/03 §2.5).
enum UserStatus { online, away, offline, hidden }

UserStatus userStatusFromString(String? s) {
  switch (s) {
    case 'online':
      return UserStatus.online;
    case 'away':
      return UserStatus.away;
    case 'hidden':
      return UserStatus.hidden;
    default:
      return UserStatus.offline;
  }
}

/// Active-presence threshold (ms).
const int kActiveThresholdMs = 300000;

/// A seen user (`this.users` entry) merged with kind-0 profile data.
class User {
  User({
    required this.pubkey,
    this.nym = '',
    this.lastSeen = 0,
    this.status = UserStatus.offline,
    Set<String>? channels,
    this.profile,
    this.awayMessage,
    this.shopStyle,
    this.shopFlair,
    this.isSupporter = false,
    List<String>? shopCosmetics,
    this.shopEdition,
  })  : channels = channels ?? <String>{},
        shopCosmetics = shopCosmetics ?? const <String>[];

  final String pubkey;
  String nym;

  /// Last activity, ms since epoch.
  int lastSeen;
  UserStatus status;

  /// Channels the user was seen in.
  final Set<String> channels;

  UserProfile? profile;
  String? awayMessage;

  /// Active flair-shop cosmetics broadcast by this user (via the presence
  /// `shop-update` tag / shop backend). Self cosmetics come from the shop
  /// controller; others' come from presence ingestion.
  String? shopStyle; // active message-style item id
  String? shopFlair; // active nickname-flair item id
  bool isSupporter; // owns the supporter badge

  /// Active special-cosmetic item ids broadcast by this user (the
  /// `active.cosmetics` array — `cosmetic-aura-gold`, `cosmetic-frost`, …).
  /// Populated by presence / shop-status ingestion for OTHER users; the self
  /// pubkey reads these live from the shop controller instead. (`shop.js:459`.)
  List<String> shopCosmetics;

  /// Active numbered-flair edition (`active.editions['flair-genesis']`), stamped
  /// on the rendered flair badge for OTHER users. Null when unknown / unnumbered.
  int? shopEdition;

  /// Effective status given the active threshold (docs/specs/03 §2.5).
  ///
  /// [isVerifiedBot] mirrors the PWA's verified-bot always-online override
  /// (`getEffectiveUserStatus`, users.js:1112: `verifiedBotPubkeys.has(pubkey)
  /// -> 'online'`). It sits AFTER the `hidden` short-circuit and BEFORE the
  /// away/recency checks, exactly as in the PWA (statusHidden at :1111 wins over
  /// the bot override at :1112). Callers pass
  /// `kVerifiedBotPubkeys.contains(pubkey)` so every call site inherits the
  /// override without its own special-case.
  UserStatus effectiveStatus({int? nowMs, bool isVerifiedBot = false}) {
    if (status == UserStatus.hidden) return UserStatus.hidden;
    if (isVerifiedBot) return UserStatus.online;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (awayMessage != null && awayMessage!.isNotEmpty) return UserStatus.away;
    if (status == UserStatus.away) return UserStatus.away;
    if (now - lastSeen < kActiveThresholdMs) return UserStatus.online;
    return UserStatus.offline;
  }
}

/// Kind-0 profile metadata (NIP-01).
class UserProfile {
  UserProfile({
    this.name,
    this.displayName,
    this.about,
    this.picture,
    this.banner,
    this.nip05,
    this.lud16,
    this.lud06,
    this.kind0Ts = 0,
  });

  String? name;
  String? displayName;
  String? about;
  String? picture;
  String? banner;
  String? nip05;
  String? lud16;
  String? lud06;

  /// Timestamp of the kind-0 event this profile was parsed from (sec).
  int kind0Ts;

  String? get lightningAddress => lud16 ?? lud06;

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        if (displayName != null) 'display_name': displayName,
        if (about != null) 'about': about,
        if (picture != null) 'picture': picture,
        if (banner != null) 'banner': banner,
        if (nip05 != null) 'nip05': nip05,
        if (lud16 != null) 'lud16': lud16,
        if (lud06 != null) 'lud06': lud06,
      };

  factory UserProfile.fromJson(Map<String, dynamic> j, {int kind0Ts = 0}) {
    return UserProfile(
      name: j['name'] as String?,
      displayName: j['display_name'] as String?,
      about: j['about'] as String?,
      picture: j['picture'] as String?,
      banner: j['banner'] as String?,
      nip05: j['nip05'] as String?,
      lud16: j['lud16'] as String?,
      lud06: j['lud06'] as String?,
      kind0Ts: kind0Ts,
    );
  }
}
