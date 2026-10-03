import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_notes.dart';

enum TranscribeStatus { available, downloadable, downloading, unavailable }

class TranscribeAvailability {
  const TranscribeAvailability(this.status, [this.reason = '']);

  final TranscribeStatus status;
  final String reason;

  bool get usable => status != TranscribeStatus.unavailable;
}

const String kNoSpeechEngine =
    'This device has no on-device speech recognizer, so transcription is unavailable.';
const String kNoSpeechModel =
    'No on-device speech model is available for {lang}.';
const String kSpeechOsTooOld =
    'On-device transcription needs Android 13 or newer.';
const String kSpeechDenied =
    'Speech recognition permission was denied, so transcription is unavailable.';
const String kSpeechNoBuild =
    "This version of the app can't transcribe on this device.";

const String kModelStarting = 'Starting the speech model download…';
const String kModelDownloading = 'Downloading the speech model…';
const String kModelPreparing = 'Preparing the speech model…';
const String kModelDownloadLabel = 'Speech model download';
const String kModelFailed = "The speech model couldn't be downloaded.";
const String kModelStalled =
    "The speech model download didn't start. This device may not offer on-device speech models.";
const String kModelTimeout = 'The speech model download is taking too long.';
const String kModelCanceled =
    'Canceled. The system may still finish the download in the background.';

const List<String> kTranscriptionStrings = <String>[
  kNoSpeechEngine,
  kNoSpeechModel,
  kSpeechOsTooOld,
  kSpeechDenied,
  kSpeechNoBuild,
  kModelStarting,
  kModelDownloading,
  kModelPreparing,
  kModelDownloadLabel,
  kModelFailed,
  kModelStalled,
  kModelTimeout,
  kModelCanceled,
];

String transcribeStatusName(TranscribeStatus s) => switch (s) {
      TranscribeStatus.available => 'available',
      TranscribeStatus.downloadable => 'downloadable',
      TranscribeStatus.downloading => 'downloading',
      TranscribeStatus.unavailable => 'unavailable',
    };

String transcribeReasonText(String code) {
  switch (code) {
    case 'no_engine':
      return kNoSpeechEngine;
    case 'no_model':
      return kNoSpeechModel;
    case 'os_too_old':
      return kSpeechOsTooOld;
    case 'denied':
      return kSpeechDenied;
  }
  return kSpeechNoBuild;
}

class TranscriptionService {
  TranscriptionService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'app.nymchat/transcribe';

  final MethodChannel _channel;

  Future<TranscribeAvailability> availability(String lang) async {
    if (kIsWeb) {
      return const TranscribeAvailability(
          TranscribeStatus.unavailable, kSpeechNoBuild);
    }
    try {
      final res = await _channel
          .invokeMapMethod<String, Object?>('availability', {'lang': lang});
      final status = res?['status'] as String? ?? 'unavailable';
      final reason = res?['reason'] as String? ?? '';
      switch (status) {
        case 'available':
          return const TranscribeAvailability(TranscribeStatus.available);
        case 'downloadable':
          return const TranscribeAvailability(TranscribeStatus.downloadable);
        case 'downloading':
          return const TranscribeAvailability(TranscribeStatus.downloading);
      }
      return TranscribeAvailability(
          TranscribeStatus.unavailable, transcribeReasonText(reason));
    } on MissingPluginException {
      return const TranscribeAvailability(
          TranscribeStatus.unavailable, kSpeechNoBuild);
    } on PlatformException catch (e) {
      return TranscribeAvailability(
          TranscribeStatus.unavailable, transcribeReasonText(e.code));
    }
  }

  Future<bool> install(String lang) async {
    try {
      return await _channel.invokeMethod<bool>('install', {'lang': lang}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<String> transcribe(String path, String lang) async {
    final text = await _channel
        .invokeMethod<String>('transcribe', {'path': path, 'lang': lang});
    return (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

final transcriptionServiceProvider =
    Provider<TranscriptionService>((ref) => TranscriptionService());

final modelDownloadLimitsProvider =
    Provider<ModelDownloadLimits>((ref) => kModelDownload);
