import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../services/storage/mesh_file_store.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import 'media_notes.dart';

class MediaNoteFiles {
  MediaNoteFiles._();

  static final Random _rng = Random();

  static Future<String> writeTemp(Uint8List bytes, String mime) =>
      writeTempExt(bytes, extForMime(mime));

  static Future<String> writeTempExt(Uint8List bytes, String ext) async {
    final dir = await getTemporaryDirectory();
    final name =
        'nymnote_${DateTime.now().microsecondsSinceEpoch}_${_rng.nextInt(1 << 30)}.$ext';
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  static Future<void> deleteQuietly(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  static Future<Uint8List> readLocal(String storePath) =>
      MeshFileStore.instance.read(storePath);

  static Future<Uint8List> fetch(String url, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final proxied = proxiedMedia(url);
      try {
        final res = await c.get(Uri.parse(proxied));
        if (res.statusCode == 200) return res.bodyBytes;
        if (proxied == url) throw HttpException('HTTP ${res.statusCode}');
      } catch (_) {
        if (proxied == url) rethrow;
      }
      final res = await c.get(Uri.parse(url));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      return res.bodyBytes;
    } finally {
      if (client == null) c.close();
    }
  }
}
