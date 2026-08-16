import 'dart:convert';
import 'dart:typed_data';

/// What a [MeshMessageType.nymProfileRequest] is asking for.
class MeshProfileRequest {
  const MeshProfileRequest({this.wantAvatar = true, this.wantBanner = false});

  final bool wantAvatar;
  final bool wantBanner;

  static const int _flagAvatar = 0x01;
  static const int _flagBanner = 0x02;

  Uint8List encode() {
    var flags = 0;
    if (wantAvatar) flags |= _flagAvatar;
    if (wantBanner) flags |= _flagBanner;
    return Uint8List.fromList([flags]);
  }

  static MeshProfileRequest decode(Uint8List data) {
    final flags = data.isEmpty ? _flagAvatar : data[0];
    return MeshProfileRequest(
      wantAvatar: (flags & _flagAvatar) != 0,
      wantBanner: (flags & _flagBanner) != 0,
    );
  }
}

/// A rich profile transferred directly over the mesh
/// ([MeshMessageType.nymProfileResponse]) so a peer's real avatar/banner can be
/// shown offline even when we've never seen them on Nostr. This is a
/// Nymchat-only extension; bitchat ignores the carrying packet.
///
/// TLV stream with 2-byte big-endian lengths (images exceed the 255-byte
/// single-byte field): `type:1 · length:2 · value`.
class MeshProfile {
  MeshProfile({
    required this.nickname,
    this.nostrPubkey,
    this.avatar,
    this.avatarMime,
    this.banner,
    this.bannerMime,
  });

  final String nickname;
  final String? nostrPubkey; // 64-hex
  final Uint8List? avatar;
  final String? avatarMime;
  final Uint8List? banner;
  final String? bannerMime;

  static const int _tNickname = 0x01;
  static const int _tNostrPubkey = 0x02;
  static const int _tAvatar = 0x10;
  static const int _tAvatarMime = 0x11;
  static const int _tBanner = 0x20;
  static const int _tBannerMime = 0x21;

  Uint8List encode() {
    final out = BytesBuilder();
    void field(int type, List<int> value) {
      if (value.length > 0xFFFF) return;
      out.addByte(type);
      out.addByte((value.length >> 8) & 0xFF);
      out.addByte(value.length & 0xFF);
      out.add(value);
    }

    field(_tNickname, utf8.encode(nickname));
    if (nostrPubkey != null) field(_tNostrPubkey, utf8.encode(nostrPubkey!));
    if (avatar != null) field(_tAvatar, avatar!);
    if (avatarMime != null) field(_tAvatarMime, utf8.encode(avatarMime!));
    if (banner != null) field(_tBanner, banner!);
    if (bannerMime != null) field(_tBannerMime, utf8.encode(bannerMime!));
    return out.toBytes();
  }

  static MeshProfile? decode(Uint8List data) {
    var offset = 0;
    String? nickname;
    String? nostrPubkey;
    Uint8List? avatar;
    String? avatarMime;
    Uint8List? banner;
    String? bannerMime;

    while (offset + 3 <= data.length) {
      final type = data[offset];
      final len = (data[offset + 1] << 8) | data[offset + 2];
      offset += 3;
      if (offset + len > data.length) return null;
      final value = Uint8List.sublistView(data, offset, offset + len);
      offset += len;
      switch (type) {
        case _tNickname:
          nickname = utf8.decode(value, allowMalformed: true);
          break;
        case _tNostrPubkey:
          nostrPubkey = utf8.decode(value, allowMalformed: true);
          break;
        case _tAvatar:
          avatar = Uint8List.fromList(value);
          break;
        case _tAvatarMime:
          avatarMime = utf8.decode(value, allowMalformed: true);
          break;
        case _tBanner:
          banner = Uint8List.fromList(value);
          break;
        case _tBannerMime:
          bannerMime = utf8.decode(value, allowMalformed: true);
          break;
        default:
          break; // forward-compatible: ignore unknown fields
      }
    }
    if (nickname == null) return null;
    return MeshProfile(
      nickname: nickname,
      nostrPubkey: nostrPubkey,
      avatar: avatar,
      avatarMime: avatarMime,
      banner: banner,
      bannerMime: bannerMime,
    );
  }
}
