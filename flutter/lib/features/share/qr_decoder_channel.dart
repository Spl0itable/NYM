import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String kQrDecoderChannel = 'app.nymchat/qr';
const int kQrMaxText = 8192;

abstract class QrDecoder {
  Future<String?> decodeFrame(Map<String, Object?> frame);
  Future<String?> decodeFile(String path);
}

class MethodChannelQrDecoder implements QrDecoder {
  MethodChannelQrDecoder([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(kQrDecoderChannel);
  final MethodChannel _channel;

  Future<String?> _call(String method, Object? args) async {
    try {
      final text = await _channel.invokeMethod<String>(method, args);
      if (text == null || text.length > kQrMaxText) return null;
      return text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<String?> decodeFrame(Map<String, Object?> frame) =>
      _call('decodeFrame', frame);

  @override
  Future<String?> decodeFile(String path) =>
      _call('decodeFile', {'path': path});
}

Map<String, Object?> androidFrameArgs(
        {required int width,
        required int height,
        required int rowStride,
        required Uint8List y}) =>
    {'width': width, 'height': height, 'rowStride': rowStride, 'y': y};

Map<String, Object?> iosFrameArgs(
        {required int width,
        required int height,
        required int bytesPerRow,
        required Uint8List bgra}) =>
    {'width': width, 'height': height, 'bytesPerRow': bytesPerRow, 'bgra': bgra};

bool get qrScannerPlatformSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

final qrDecoderProvider = Provider<QrDecoder>((ref) => MethodChannelQrDecoder());

final qrScannerAvailableProvider =
    Provider<bool>((ref) => qrScannerPlatformSupported);
