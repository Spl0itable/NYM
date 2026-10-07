import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../common/nym_avatar.dart';

class GroupSidebarAvatar extends StatelessWidget {
  const GroupSidebarAvatar({
    super.key,
    required this.group,
    required this.selfPubkey,
    required this.users,
    this.size = 26,
  });

  final Group group;
  final String selfPubkey;
  final Map<String, User> users;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final avatarUrl = proxiedAvatarUrl(group.avatar);
    final otherMembers =
        group.members.where((pk) => pk != selfPubkey).toList(growable: false);
    if (size != 26) {
      final Widget inner;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        inner = ClipOval(
          child: NymAvatar(seed: group.id, size: size, imageUrl: group.avatar),
        );
      } else if (otherMembers.isNotEmpty) {
        inner = _GroupAvatarStack(
          members: otherMembers.take(3).toList(),
          users: users,
          size: size,
        );
      } else {
        inner = _GroupIconWrap(c: c, size: size);
      }
      return SizedBox(width: size, height: size, child: inner);
    }
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ClipOval(
          child: NymAvatar(
            seed: group.id,
            size: 26,
            imageUrl: group.avatar,
          ),
        ),
      );
    }
    if (otherMembers.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: _GroupAvatarStack(
          members: otherMembers.take(3).toList(),
          users: users,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: _GroupIconWrap(c: c),
    );
  }
}

const String _groupGlyphSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
    'stroke="{C}" stroke-width="1.75" stroke-linecap="round" '
    'stroke-linejoin="round">'
    '<circle cx="12" cy="7" r="2.75"/>'
    '<path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/>'
    '<circle cx="4.5" cy="9.5" r="2"/>'
    '<path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/>'
    '<circle cx="19.5" cy="9.5" r="2"/>'
    '<path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>';

String get groupChatGlyphSvg => _groupGlyphSvg.replaceAll('{C}', 'currentColor');

String _hex(Color c) {
  int ch(double v) => (v * 255).round() & 0xff;
  return '#${ch(c.r).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.b).toRadixString(16).padLeft(2, '0')}';
}

class _GroupAvatarStack extends StatelessWidget {
  const _GroupAvatarStack(
      {required this.members, required this.users, this.size});

  final List<String> members;
  final Map<String, User> users;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final s = size;
    if (s != null) {
      final img = s * 0.7;
      final step = s * 0.15;
      return SizedBox(
        width: s,
        height: s,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = members.length.clamp(0, 3) - 1; i >= 0; i--)
              Positioned(
                left: i * step,
                top: step,
                child: Container(
                  key: const ValueKey('groupStackAvatar'),
                  width: img,
                  height: img,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 1),
                  ),
                  child: ClipOval(
                    child: NymAvatar(
                      seed: members[i],
                      size: img - 2,
                      imageUrl: users[members[i]]?.profile?.picture,
                    ),
                  ),
                ),
              ),
            Positioned(
              right: -3,
              bottom: -2,
              child: Container(
                key: const ValueKey('groupStackBadge'),
                width: s * 0.5,
                height: s * 0.5,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.bgSecondary,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.primaryA(0.3), width: 1),
                ),
                child: SvgPicture.string(
                  _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
                  width: s * 0.3,
                  height: s * 0.3,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      width: 34,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < members.length && i < 3; i++)
            Positioned(
              left: i * 9.0,
              top: 0,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.bg, width: 1),
                ),
                child: ClipOval(
                  child: NymAvatar(
                    seed: members[i],
                    size: 18,
                    imageUrl: users[members[i]]?.profile?.picture,
                  ),
                ),
              ),
            ),
          Positioned(
            right: -4,
            bottom: -3,
            child: Container(
              width: 13,
              height: 13,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.bgSecondary,
                shape: BoxShape.circle,
                border: Border.all(color: c.primaryA(0.3), width: 1),
              ),
              child: SvgPicture.string(
                _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
                width: 8,
                height: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupIconWrap extends StatelessWidget {
  const _GroupIconWrap({required this.c, this.size = 26});
  final NymColors c;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.primaryA(0.10),
        border: Border.all(color: c.primaryA(0.25), width: 1),
      ),
      child: SvgPicture.string(
        _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
        width: size * 14 / 26,
        height: size * 14 / 26,
      ),
    );
  }
}
