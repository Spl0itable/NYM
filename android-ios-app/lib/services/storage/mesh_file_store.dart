import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'at_rest_cipher.dart';

class MeshFileStore {
  MeshFileStore({
    AtRestCipher? cipher,
    Future<Directory> Function()? baseDirectory,
  })  : _cipher = cipher,
        _baseDirectory = baseDirectory ?? getApplicationDocumentsDirectory;

  static MeshFileStore instance = MeshFileStore();

  static const String folderName = 'mesh_files';

  final AtRestCipher? _cipher;
  final Future<Directory> Function() _baseDirectory;

  AtRestCipher get _crypto => _cipher ?? AtRestCipher.instance;

  Future<Directory> directory() async =>
      Directory('${(await _baseDirectory()).path}/$folderName');

  Future<String?> save(String fileName, Uint8List bytes) async {
    try {
      final dir = await directory();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${dir.path}/${stamp}_$safe';
      await File(path)
          .writeAsBytes(await _crypto.encryptBytes(bytes), flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> read(String path) async {
    final file = File(path);
    final stored = await file.readAsBytes();
    if (AtRestCipher.isEncryptedBytes(stored)) {
      return _crypto.decryptBytes(stored);
    }
    await _migrate(file, stored);
    return stored;
  }

  Future<void> _migrate(File file, Uint8List plain) async {
    final staging = File('${file.path}.sealing');
    try {
      await staging.writeAsBytes(await _crypto.encryptBytes(plain),
          flush: true);
      await staging.rename(file.path);
    } catch (_) {
      try {
        if (staging.existsSync()) await staging.delete();
      } catch (_) {}
    }
  }

  Future<void> wipe() async {
    final dir = await directory();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
