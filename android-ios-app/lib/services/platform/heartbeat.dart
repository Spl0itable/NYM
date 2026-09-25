import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/storage_keys.dart';
import '../api/api_config.dart';
import '../storage/key_value_store.dart';
import 'background_refresh.dart';

class HeartbeatService {
  HeartbeatService({
    required KeyValueStore kv,
    MethodChannel? channel,
    http.Client? client,
    bool? supported,
    String? env,
    Uri? endpoint,
    Future<void> Function(Duration)? sleep,
    this.retryBase = const Duration(seconds: 30),
    this.maxRetryDelay = const Duration(minutes: 30),
    this.maxAttempts = 6,
    this.relaunchBase = const Duration(minutes: 1),
    this.maxRelaunchDelay = const Duration(hours: 1),
  })  : _kv = kv,
        _channel = channel ?? const MethodChannel(channelName),
        _client = client ?? http.Client(),
        _supported = supported ?? isSupported,
        _env = env ?? defaultEnv,
        _endpoint = endpoint ?? Uri.https(ApiConfig.apiHost, '/push/'),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  static const String channelName = 'app.nymchat/heartbeat';

  static bool get isSupported => BackgroundRefreshService.isSupported;

  static String get defaultEnv => kDebugMode ? 'sandbox' : 'production';

  final KeyValueStore _kv;
  final MethodChannel _channel;
  final http.Client _client;
  final bool _supported;
  final String _env;
  final Uri _endpoint;
  final Future<void> Function(Duration) _sleep;
  final Duration retryBase;
  final Duration maxRetryDelay;
  final int maxAttempts;
  final Duration relaunchBase;
  final Duration maxRelaunchDelay;

  bool _listening = false;
  Timer? _retry;
  int _failures = 0;
  bool _enabled = false;
  int _generation = 0;
  String? _sentToken;
  Future<void>? _pending;

  bool get enabled => _enabled;

  bool get registered => _sentToken != null;

  bool get retryPending => _retry?.isActive ?? false;

  Future<void> get idle => _pending ?? Future<void>.value();

  Future<void> setEnabled(bool on) async {
    if (!_supported) return;
    _listen();
    final gen = ++_generation;
    _enabled = on;
    _sentToken = null;
    _cancelRetry();
    _failures = 0;
    if (on) {
      await _invoke('register');
      return;
    }
    final token = _kv.getString(StorageKeys.heartbeatToken);
    if (token != null && token.isNotEmpty) {
      final done = _post('unregister', {'token': token}, gen);
      _pending = done;
      await done;
      if (gen != _generation) return;
      await _kv.remove(StorageKeys.heartbeatToken);
    }
    await _invoke('unregister');
  }

  Future<void> resume() async {
    if (!_supported || !_enabled || registered) return;
    _cancelRetry();
    _listen();
    await _invoke('register');
  }

  void dispose() {
    _generation++;
    _cancelRetry();
    if (_listening) _channel.setMethodCallHandler(null);
    _listening = false;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'token':
          final token = call.arguments;
          if (token is String && token.isNotEmpty) {
            _pending = _onToken(token.toLowerCase());
          }
        case 'registrationFailed':
          debugPrint('[Heartbeat] push registration failed');
          _scheduleRetry();
      }
      return null;
    });
  }

  Future<void> _onToken(String token) async {
    if (!_enabled || token == _sentToken) return;
    final gen = _generation;
    final previous = _kv.getString(StorageKeys.heartbeatToken);
    await _kv.setString(StorageKeys.heartbeatToken, token);
    if (previous != null && previous.isNotEmpty && previous != token) {
      await _post('unregister', {'token': previous}, gen);
    }
    if (await _post('register', {'token': token, 'env': _env}, gen) &&
        gen == _generation) {
      _sentToken = token;
      _failures = 0;
      _cancelRetry();
    } else if (gen == _generation) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_enabled || _retry?.isActive == true) return;
    final gen = _generation;
    final exp = math.min(_failures, 16);
    _failures++;
    final delay = Duration(
      milliseconds: math.min(
        relaunchBase.inMilliseconds * (1 << exp),
        maxRelaunchDelay.inMilliseconds,
      ),
    );
    _retry = Timer(delay, () {
      _retry = null;
      if (!_enabled || gen != _generation || registered) return;
      unawaited(_invoke('register'));
    });
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      return;
    } catch (e) {
      debugPrint('[Heartbeat] $method failed: ${e.runtimeType}');
    }
  }

  Future<bool> _post(String path, Map<String, String> body, int gen) async {
    var delay = retryBase;
    for (var attempt = 1;; attempt++) {
      if (gen != _generation) return false;
      Duration wait = delay;
      try {
        final res = await _client
            .post(
              _endpoint.resolve(path),
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': ApiConfig.dartUserAgent,
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 20));
        final status = res.statusCode;
        if (status >= 200 && status < 300) return true;
        if (status == 429) {
          wait = retryAfter(res.headers['retry-after']) ?? delay;
        } else if (status < 500) {
          debugPrint('[Heartbeat] $path refused: $status');
          return false;
        }
      } catch (_) {}
      if (attempt >= maxAttempts || gen != _generation) return false;
      await _sleep(wait);
      delay = Duration(
        milliseconds: math.min(
          delay.inMilliseconds * 2,
          maxRetryDelay.inMilliseconds,
        ),
      );
    }
  }

  static Duration? retryAfter(String? header, {DateTime? now}) {
    if (header == null) return null;
    final value = header.trim();
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: math.max(seconds, 0));
    try {
      final at = HttpDate.parse(value);
      final left = at.difference(now ?? DateTime.now());
      return left.isNegative ? Duration.zero : left;
    } catch (_) {
      return null;
    }
  }
}
