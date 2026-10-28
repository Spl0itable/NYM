import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/nym_colors.dart';
import '../duo/duo_rail.dart';
import '../i18n/i18n.dart';
import 'qr_decoder_channel.dart';
import 'share_actions.dart';
import 'share_inbound.dart';
import 'share_links.dart';

const Duration kScanFrameGap = Duration(milliseconds: 200);

abstract class ScanCamera {
  Future<bool> start(void Function(Map<String, Object?> frame) onFrame);
  Future<void> stop();
  Widget preview();
}

class PluginScanCamera implements ScanCamera {
  CameraController? _controller;

  @override
  Future<bool> start(void Function(Map<String, Object?> frame) onFrame) async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return false;
      final back = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );
      _controller = controller;
      await controller.initialize();
      await controller.startImageStream((image) {
        if (image.planes.isEmpty) return;
        final p = image.planes.first;
        onFrame(Platform.isAndroid
            ? androidFrameArgs(
                width: image.width,
                height: image.height,
                rowStride: p.bytesPerRow,
                y: p.bytes)
            : iosFrameArgs(
                width: image.width,
                height: image.height,
                bytesPerRow: p.bytesPerRow,
                bgra: p.bytes));
      });
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  @override
  Future<void> stop() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  @override
  Widget preview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.expand();
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c.value.previewSize?.height ?? 1,
        height: c.value.previewSize?.width ?? 1,
        child: CameraPreview(c),
      ),
    );
  }
}

Future<String?> _pickPhoto() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery);
  return file?.path;
}

final scanCameraFactoryProvider =
    Provider<ScanCamera Function()>((ref) => PluginScanCamera.new);

final scanPhotoPickerProvider =
    Provider<Future<String?> Function()>((ref) => _pickPhoto);

Future<void> openShareScanner(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const ShareScannerScreen(),
      fullscreenDialog: true,
    ));

enum _ScanState { starting, scanning, cameraOff, notNymchat, noCodeInPhoto }

class ShareScannerScreen extends ConsumerStatefulWidget {
  const ShareScannerScreen({super.key});

  @override
  ConsumerState<ShareScannerScreen> createState() => _ShareScannerScreenState();
}

class _ShareScannerScreenState extends ConsumerState<ShareScannerScreen>
    with WidgetsBindingObserver {
  late final ScanCamera _camera = ref.read(scanCameraFactoryProvider)();
  _ScanState _state = _ScanState.starting;
  bool _busy = false;
  bool _done = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _done = true;
    unawaited(_camera.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      unawaited(_camera.stop());
    } else if (state == AppLifecycleState.resumed &&
        !_done &&
        _state == _ScanState.scanning) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    final ok = await _camera.start(_onFrame);
    if (!mounted) {
      await _camera.stop();
      return;
    }
    setState(() => _state = ok ? _ScanState.scanning : _ScanState.cameraOff);
  }

  void _onFrame(Map<String, Object?> frame) {
    if (_busy || _done) return;
    final now = DateTime.now();
    if (now.difference(_last) < kScanFrameGap) return;
    _last = now;
    _busy = true;
    unawaited(ref.read(qrDecoderProvider).decodeFrame(frame).then((text) {
      _busy = false;
      if (text != null && !_done) unawaited(_found(text, InboundSource.scan));
    }, onError: (_) => _busy = false));
  }

  Future<void> _found(String raw, InboundSource source) async {
    _done = true;
    await _camera.stop();
    if (!mounted) return;
    if (!parseShareInput(raw).isValid) {
      setState(() => _state = _ScanState.notNymchat);
      return;
    }
    final nav = Navigator.of(context);
    final handler = ref.read(inboundShareProvider);
    nav.pop();
    await handler.handle(nav.context, raw, source: source);
  }

  Future<void> _fromPhoto() async {
    final path = await ref.read(scanPhotoPickerProvider)();
    if (path == null || !mounted) return;
    final text = await ref.read(qrDecoderProvider).decodeFile(path);
    if (!mounted) return;
    if (text == null) {
      setState(() => _state = _ScanState.noCodeInPhoto);
      return;
    }
    await _found(text, InboundSource.photo);
  }

  void _again() {
    _done = false;
    setState(() => _state = _ScanState.starting);
    unawaited(_start());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final nfc = ref.watch(nfcReadLauncherProvider);
    final message = switch (_state) {
      _ScanState.cameraOff =>
        tr('Camera access is off. Scan from a photo instead.'),
      _ScanState.notNymchat => tr('Not a Nymchat code'),
      _ScanState.noCodeInPhoto => tr('No code found in this photo.'),
      _ => null,
    };
    final showCamera =
        _state == _ScanState.scanning || _state == _ScanState.starting;
    final rail = DuoScope.railOf(context);
    return DuoRailItems(
      active: rail,
      priority: kDuoSheetPriority,
      items: [duoCloseItem(() => Navigator.of(context).maybePop())],
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(tr('Scan a code')),
        automaticallyImplyLeading: !rail,
        leading: rail
            ? null
            : IconButton(
                tooltip: tr('Close'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: showCamera
                  ? ClipRect(child: _camera.preview())
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          message ?? '',
                          key: const ValueKey('scan-message'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (_state == _ScanState.notNymchat ||
                      _state == _ScanState.noCodeInPhoto)
                    OutlinedButton(
                      key: const ValueKey('scan-again'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white),
                      onPressed: _again,
                      child: Text(tr('Scan a code')),
                    ),
                  FilledButton(
                    key: const ValueKey('scan-photo'),
                    style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: Colors.black),
                    onPressed: _fromPhoto,
                    child: Text(tr('Scan from photo')),
                  ),
                  if (nfc != null)
                    OutlinedButton(
                      key: const ValueKey('scan-nfc'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white),
                      onPressed: () => nfc(context),
                      child: Text(tr('Read NFC')),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
