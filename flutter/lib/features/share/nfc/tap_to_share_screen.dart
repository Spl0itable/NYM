import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/nym_colors.dart';
import '../../i18n/i18n.dart';
import '../branded_qr.dart';
import '../share_target.dart';
import 'ndef.dart';
import 'nfc_channel.dart';
import '../../duo/duo_rail.dart';

Future<void> openTapToShare(
        BuildContext context, WidgetRef ref, ShareTarget target) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TapToShareScreen(target: target),
      fullscreenDialog: true,
    ));

enum TapToShareState { starting, armed, nfcOff, unavailable }

class TapToShareScreen extends ConsumerStatefulWidget {
  const TapToShareScreen({super.key, required this.target});

  final ShareTarget target;

  @override
  ConsumerState<TapToShareScreen> createState() => _TapToShareScreenState();
}

class _TapToShareScreenState extends ConsumerState<TapToShareScreen>
    with WidgetsBindingObserver {
  late final NfcPlatform _nfc = ref.read(nfcPlatformProvider);
  TapToShareState _state = TapToShareState.starting;
  Timer? _tick;
  int _left = kTapToShareDuration.inSeconds;
  bool _armed = false;
  bool _closed = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    final caps = await _nfc.caps();
    if (!mounted || _closed || attempt != _attempt) return;
    if (!caps.hce) {
      setState(() => _state = TapToShareState.unavailable);
      return;
    }
    if (!caps.enabled) {
      setState(() => _state = TapToShareState.nfcOff);
      return;
    }
    final file = ndefType4File(ndefUriMessage(widget.target.codeLink));
    if (file == null) {
      setState(() => _state = TapToShareState.unavailable);
      return;
    }
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    _armed = true;
    final ok = await _nfc.arm(ndefType4Cc(), file, kTapToShareDuration);
    if (!mounted || _closed || attempt != _attempt) return;
    if (!ok) {
      _armed = false;
      setState(() => _state = TapToShareState.unavailable);
      return;
    }
    _left = kTapToShareDuration.inSeconds;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= 1) {
        _stop();
        return;
      }
      setState(() => _left--);
    });
    setState(() => _state = TapToShareState.armed);
  }

  void _disarm() {
    _tick?.cancel();
    _tick = null;
    if (!_armed) return;
    _armed = false;
    unawaited(_nfc.disarm());
  }

  void _stop() {
    if (_closed) return;
    _closed = true;
    _disarm();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_closed && _state != TapToShareState.armed) unawaited(_start());
      return;
    }
    if (_armed || _state == TapToShareState.armed) {
      _stop();
    } else {
      _attempt++;
    }
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _disarm();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final t = widget.target;
    final text = TextStyle(color: c.text, fontSize: 15, height: 1.4);
    final dim = TextStyle(color: c.textDim, fontSize: 13, height: 1.4);
    final status = switch (_state) {
      TapToShareState.armed => tr('Hold the back of another phone to this phone'),
      TapToShareState.nfcOff => tr('Turn on NFC'),
      TapToShareState.unavailable => tr('Tap to share is not available on this phone.'),
      TapToShareState.starting => '',
    };
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _closed = true;
          _disarm();
        }
      },
      child: Scaffold(
        backgroundColor: c.bg,
        appBar: AppBar(
          backgroundColor: c.bg,
          foregroundColor: c.text,
          title: DuoRailItems(
            active: DuoScope.railOf(context),
            priority: kDuoSheetPriority,
            items: [duoCloseItem(_stop)],
            child: Text(tr('Tap to share')),
          ),
          automaticallyImplyLeading: !DuoScope.railOf(context),
          leading: DuoScope.railOf(context)
              ? null
              : IconButton(
                  tooltip: tr('Close'),
                  icon: const Icon(Icons.close),
                  onPressed: _stop,
                ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            children: [
              Icon(Icons.nfc, size: 56, color: c.primary),
              const SizedBox(height: 16),
              Text(status,
                  key: const ValueKey('tap-status'),
                  textAlign: TextAlign.center,
                  style: text.copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
              if (_state == TapToShareState.armed) ...[
                const SizedBox(height: 8),
                Text(
                  tr('Tap to share stops in {seconds} s', {'seconds': _left}),
                  key: const ValueKey('tap-countdown'),
                  textAlign: TextAlign.center,
                  style: dim,
                ),
              ],
              if (_state == TapToShareState.nfcOff) ...[
                const SizedBox(height: 12),
                Center(
                  child: FilledButton(
                    key: const ValueKey('tap-nfc-settings'),
                    style: FilledButton.styleFrom(
                        backgroundColor: c.primary, foregroundColor: c.bg),
                    onPressed: () => unawaited(_nfc.openSettings()),
                    child: Text(tr('Turn on NFC')),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Center(
                child: BrandedQr(
                  data: t.codeLink,
                  size: 200,
                  semanticLabel: tr('QR code for {title}', {'title': t.title}),
                ),
              ),
              const SizedBox(height: 12),
              Text(t.title,
                  textAlign: TextAlign.center,
                  style: text.copyWith(fontWeight: FontWeight.w600)),
              if (t.kind == ShareKind.group) ...[
                const SizedBox(height: 8),
                Text(
                  tr('Anyone who sees or scans this code can ask to join and will see the group’s name.'),
                  key: const ValueKey('tap-group-warning'),
                  textAlign: TextAlign.center,
                  style: dim,
                ),
              ],
              const SizedBox(height: 20),
              Center(
                child: OutlinedButton(
                  key: const ValueKey('tap-stop'),
                  style: OutlinedButton.styleFrom(foregroundColor: c.text),
                  onPressed: _stop,
                  child: Text(tr('Stop')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
