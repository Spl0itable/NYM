import 'dart:convert';
import 'dart:typed_data';

import 'mesh_message_type.dart';
import 'noise_payload.dart';

const int kNymShareVersion = 1;
const int kNymShareMaxBytes = 1024;
const int kNiTokenMaxBytes = 1024;

class NiTokenPayload {
  const NiTokenPayload({required this.token, required this.replyRequested});

  final Uint8List token;
  final bool replyRequested;

  bool get isStop => token.isEmpty;
}

class MeshNymShare {
  const MeshNymShare({required this.senderPeerID, required this.link});

  final String senderPeerID;
  final String link;
}

class MeshNiToken {
  const MeshNiToken({
    required this.senderPeerID,
    required this.token,
    required this.replyRequested,
  });

  final String senderPeerID;
  final Uint8List token;
  final bool replyRequested;

  bool get isStop => token.isEmpty;
}

Uint8List? encodeNymShare(String link) {
  final bytes = utf8.encode(link);
  if (bytes.isEmpty || bytes.length > kNymShareMaxBytes) return null;
  return Uint8List.fromList(
      [kNymShareVersion, bytes.length >> 8, bytes.length & 0xFF, ...bytes]);
}

String? decodeNymShare(Uint8List data) {
  if (data.length < 4 || data[0] != kNymShareVersion) return null;
  final len = (data[1] << 8) | data[2];
  if (len < 1 || len > kNymShareMaxBytes || data.length != 3 + len) {
    return null;
  }
  try {
    return const Utf8Decoder(allowMalformed: false)
        .convert(data.sublist(3, 3 + len));
  } on FormatException {
    return null;
  }
}

Uint8List? nymSharePlaintext(String link) {
  final data = encodeNymShare(link);
  if (data == null) return null;
  return NoisePayload(NoisePayloadType.nymShare, data).encode();
}

Uint8List? encodeNiToken(Uint8List token, {bool replyRequested = false}) {
  if (token.length > kNiTokenMaxBytes) return null;
  return Uint8List.fromList([
    kNymShareVersion,
    replyRequested ? 1 : 0,
    token.length >> 8,
    token.length & 0xFF,
    ...token,
  ]);
}

NiTokenPayload? decodeNiToken(Uint8List data) {
  if (data.length < 4 || data[0] != kNymShareVersion) return null;
  final len = (data[2] << 8) | data[3];
  if (len > kNiTokenMaxBytes || data.length != 4 + len) return null;
  return NiTokenPayload(
    token: Uint8List.fromList(data.sublist(4)),
    replyRequested: data[1] & 1 == 1,
  );
}

Uint8List? niTokenPlaintext(Uint8List token, {bool replyRequested = false}) {
  final data = encodeNiToken(token, replyRequested: replyRequested);
  if (data == null) return null;
  return NoisePayload(NoisePayloadType.nymNiToken, data).encode();
}
