/// Group control-event types carried in the `['type', …]` tag of a group rumor
/// (docs/specs/03 §4.2).
class GroupControlType {
  GroupControlType._();
  static const message = 'group-message';
  static const invite = 'group-invite';
  static const addMember = 'group-add-member';
  static const removeMember = 'group-remove-member';
  static const promoteMod = 'group-promote-mod';
  static const revokeMod = 'group-revoke-mod';
  static const transferOwner = 'group-transfer-owner';
  static const metadata = 'group-metadata';
  static const deleteMessage = 'group-delete-message';
  static const joinRequest = 'group-join-request';
  static const leave = 'group-leave';
  static const unban = 'group-unban';
  static const keyResync = 'key-resync';
}

/// A moderation-log entry (docs/specs/03 §4.1).
class ModLogEntry {
  ModLogEntry({
    required this.type,
    required this.actor,
    this.target,
    this.messageId,
    required this.ts,
  });

  /// 'kick'|'ban'|'unban'|'promote'|'revoke'|'transfer'|'delete-message'
  final String type;
  final String actor;
  final String? target;
  final String? messageId;
  final int ts;

  Map<String, dynamic> toJson() => {
        'type': type,
        'actor': actor,
        'target': target,
        'messageId': messageId,
        'ts': ts,
      };

  factory ModLogEntry.fromJson(Map<String, dynamic> j) => ModLogEntry(
        type: j['type'] as String,
        actor: j['actor'] as String,
        target: j['target'] as String?,
        messageId: j['messageId'] as String?,
        ts: (j['ts'] as num).toInt(),
      );
}

/// A multi-member private group chat (docs/specs/03 §4.1).
class Group {
  Group({
    required this.id,
    this.name = '',
    List<String>? members,
    this.lastMessageTime = 0,
    this.createdBy,
    List<String>? mods,
    List<String>? banned,
    this.avatar,
    this.banner,
    this.description,
    this.allowMemberInvites = true,
    this.inviteEnabled = false,
    this.inviteEpoch = 0,
    this.metaUpdatedAt = 0,
    this.lastModTs = 0,
    this.lastModEventId,
    List<ModLogEntry>? modLog,
  })  : members = members ?? <String>[],
        mods = mods ?? <String>[],
        banned = banned ?? <String>[],
        modLog = modLog ?? <ModLogEntry>[];

  /// 64-hex CSPRNG group id.
  final String id;
  String name;
  final List<String> members;
  int lastMessageTime;
  String? createdBy;
  final List<String> mods;
  final List<String> banned;
  String? avatar;
  String? banner;
  String? description;
  bool allowMemberInvites;
  bool inviteEnabled;
  int inviteEpoch;
  int metaUpdatedAt;
  int lastModTs;
  String? lastModEventId;
  final List<ModLogEntry> modLog;

  bool isOwner(String pubkey) => createdBy == pubkey;
  bool isMod(String pubkey) => mods.contains(pubkey);
  bool canModerate(String pubkey) => isOwner(pubkey) || isMod(pubkey);
  bool canAddMembers(String pubkey) =>
      isOwner(pubkey) || (members.contains(pubkey) && allowMemberInvites);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'members': members,
        'lastMessageTime': lastMessageTime,
        'createdBy': createdBy,
        'mods': mods,
        'banned': banned,
        'avatar': avatar,
        'banner': banner,
        'description': description,
        'allowMemberInvites': allowMemberInvites,
        'inviteEnabled': inviteEnabled,
        'inviteEpoch': inviteEpoch,
        'metaUpdatedAt': metaUpdatedAt,
        'lastModTs': lastModTs,
        'lastModEventId': lastModEventId,
        'modLog': modLog.map((e) => e.toJson()).toList(),
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        members:
            ((j['members'] as List?) ?? const []).map((e) => e.toString()).toList(),
        lastMessageTime: (j['lastMessageTime'] as num?)?.toInt() ?? 0,
        createdBy: j['createdBy'] as String?,
        mods: ((j['mods'] as List?) ?? const []).map((e) => e.toString()).toList(),
        banned:
            ((j['banned'] as List?) ?? const []).map((e) => e.toString()).toList(),
        avatar: j['avatar'] as String?,
        banner: j['banner'] as String?,
        description: j['description'] as String?,
        allowMemberInvites: j['allowMemberInvites'] != false,
        inviteEnabled: j['inviteEnabled'] == true,
        inviteEpoch: (j['inviteEpoch'] as num?)?.toInt() ?? 0,
        metaUpdatedAt: (j['metaUpdatedAt'] as num?)?.toInt() ?? 0,
        lastModTs: (j['lastModTs'] as num?)?.toInt() ?? 0,
        lastModEventId: j['lastModEventId'] as String?,
        modLog: ((j['modLog'] as List?) ?? const [])
            .map((e) => ModLogEntry.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// An invite-link token payload (base64url JSON, docs/specs/03 §4.6).
class GroupInviteToken {
  GroupInviteToken({
    this.v = 1,
    required this.groupId,
    required this.approver,
    required this.epoch,
    required this.name,
  });

  final int v;
  final String groupId; // 'g'
  final String approver; // 'a'
  final int epoch; // 'e'
  final String name; // 'n'

  Map<String, dynamic> toJson() =>
      {'v': v, 'g': groupId, 'a': approver, 'e': epoch, 'n': name};

  factory GroupInviteToken.fromJson(Map<String, dynamic> j) => GroupInviteToken(
        v: (j['v'] as num?)?.toInt() ?? 1,
        groupId: j['g'] as String,
        approver: j['a'] as String,
        epoch: (j['e'] as num?)?.toInt() ?? 0,
        name: (j['n'] ?? '') as String,
      );
}
