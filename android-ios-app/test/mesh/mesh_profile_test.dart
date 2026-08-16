import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_profile.dart';

Uint8List _bytes(int n, [int start = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xFF));

void main() {
  group('MeshProfileRequest', () {
    test('flags round-trip', () {
      final r = MeshProfileRequest(wantAvatar: true, wantBanner: true);
      final d = MeshProfileRequest.decode(r.encode());
      expect(d.wantAvatar, isTrue);
      expect(d.wantBanner, isTrue);
      final avatarOnly = MeshProfileRequest.decode(
          MeshProfileRequest(wantAvatar: true).encode());
      expect(avatarOnly.wantAvatar, isTrue);
      expect(avatarOnly.wantBanner, isFalse);
    });
  });

  group('MeshProfile', () {
    test('round-trips nickname + pubkey + avatar/banner bytes (>255 each)', () {
      final profile = MeshProfile(
        nickname: 'river',
        nostrPubkey: 'a' * 64,
        avatar: _bytes(4000, 3),
        avatarMime: 'image/webp',
        banner: _bytes(9000, 7),
        bannerMime: 'image/jpeg',
      );
      final decoded = MeshProfile.decode(profile.encode())!;
      expect(decoded.nickname, 'river');
      expect(decoded.nostrPubkey, 'a' * 64);
      expect(decoded.avatar, equals(_bytes(4000, 3)));
      expect(decoded.avatarMime, 'image/webp');
      expect(decoded.banner, equals(_bytes(9000, 7)));
      expect(decoded.bannerMime, 'image/jpeg');
    });

    test('nickname-only profile round-trips', () {
      final decoded = MeshProfile.decode(MeshProfile(nickname: 'bob').encode())!;
      expect(decoded.nickname, 'bob');
      expect(decoded.avatar, isNull);
      expect(decoded.nostrPubkey, isNull);
    });

    test('decode tolerates unknown forward-compat fields', () {
      // type 0x7F, len 2, value — an unknown field between known ones.
      final base = MeshProfile(nickname: 'x').encode();
      final withUnknown = Uint8List.fromList(
          [...base, 0x7F, 0x00, 0x02, 0xAB, 0xCD]);
      final decoded = MeshProfile.decode(withUnknown)!;
      expect(decoded.nickname, 'x');
    });

    test('decode returns null on truncated length', () {
      // type 0x10, len 0x00FF but no bytes follow.
      expect(MeshProfile.decode(Uint8List.fromList([0x10, 0x00, 0xFF])), isNull);
    });
  });
}
