import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<void> releasePeerConnection(RTCPeerConnection pc) async {
  try {
    await pc.close();
  } catch (_) {}
  try {
    await pc.dispose();
  } catch (_) {}
}
