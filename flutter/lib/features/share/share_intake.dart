import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'share_destination_sheet.dart';

/// Bridges the OS share sheet into the destination picker; no-ops when the platform channel is missing.
class ShareIntake {
  ShareIntake({required this.ref, required this.navKey});

  static const channel = MethodChannel('app.nymchat/share');
  static const maxFiles = 10;
  static const maxFileBytes = 16 * 1024 * 1024;

  final WidgetRef ref;
  final GlobalKey<NavigatorState> navKey;

  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'incoming') return null;
      final payload = await decode(call.arguments);
      if (payload != null) _present(payload);
      return null;
    });
    try {
      final held = await channel.invokeMethod<List<Object?>>('initial');
      for (final raw in held ?? const <Object?>[]) {
        final payload = await decode(raw);
        if (payload != null) _present(payload);
      }
    } catch (_) {}
  }

  void _present(SharedPayload payload) {
    if (payload.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = navKey.currentContext;
      if (ctx == null) return;
      showShareDestinationSheet(ctx, ref, payload);
    });
  }

  static String safeName(Object? raw) {
    final text = raw is String ? raw : '';
    final base = text.replaceAll('\\', '/').split('/').last;
    final clean = base
        .replaceAll(RegExp(r'[\x00-\x1f\x7f:*?"<>|]'), '_')
        .trim()
        .replaceFirst(RegExp(r'^\.+'), '');
    if (clean.isEmpty) return 'shared';
    return clean.length > 120 ? clean.substring(clean.length - 120) : clean;
  }

  static Future<SharedPayload?> decode(Object? raw,
      {Future<Directory> Function()? scratch}) async {
    if (raw is! Map) return null;
    final text = raw['text'] is String ? (raw['text'] as String).trim() : null;
    final files = <({String name, Uint8List bytes})>[];
    for (final f in (raw['files'] is List ? raw['files'] as List : const [])) {
      if (files.length >= maxFiles) break;
      if (f is! Map) continue;
      final bytes = f['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty || bytes.length > maxFileBytes) {
        continue;
      }
      files.add((name: safeName(f['name']), bytes: bytes));
    }
    final paths = <String>[];
    if (files.isNotEmpty) {
      try {
        final dir = await (scratch ??
            () => Directory.systemTemp.createTemp('nym_share_'))();
        final used = <String>{};
        for (var i = 0; i < files.length; i++) {
          var name = files[i].name;
          if (!used.add(name)) {
            name = '${i}_$name';
            used.add(name);
          }
          final file = File('${dir.path}${Platform.pathSeparator}$name');
          await file.writeAsBytes(files[i].bytes, flush: true);
          paths.add(file.path);
        }
      } catch (_) {}
    }
    final payload = SharedPayload(
      text: text == null || text.isEmpty ? null : text,
      filePaths: paths,
    );
    return payload.isEmpty ? null : payload;
  }

  void dispose() {
    channel.setMethodCallHandler(null);
  }
}
