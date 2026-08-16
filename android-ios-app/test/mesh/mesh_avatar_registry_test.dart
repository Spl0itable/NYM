import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/mesh_avatar_registry.dart';

void main() {
  setUp(() => MeshAvatarRegistry.instance.clear());

  test('registers bytes under every provided seed', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    MeshAvatarRegistry.instance.register(['peer123', 'pubkeyABC'], bytes);
    expect(MeshAvatarRegistry.instance.bytesFor('peer123'), equals(bytes));
    expect(MeshAvatarRegistry.instance.bytesFor('pubkeyABC'), equals(bytes));
    expect(MeshAvatarRegistry.instance.bytesFor('unknown'), isNull);
  });

  test('bumps revision only on real change', () {
    final rev0 = MeshAvatarRegistry.instance.revision.value;
    final bytes = Uint8List.fromList([9, 9]);
    MeshAvatarRegistry.instance.register(['x'], bytes);
    final rev1 = MeshAvatarRegistry.instance.revision.value;
    expect(rev1, greaterThan(rev0));
    // Same bytes again → no bump.
    MeshAvatarRegistry.instance.register(['x'], Uint8List.fromList([9, 9]));
    expect(MeshAvatarRegistry.instance.revision.value, rev1);
  });

  test('empty seeds are ignored', () {
    MeshAvatarRegistry.instance.register(['', 'ok'], Uint8List.fromList([5]));
    expect(MeshAvatarRegistry.instance.bytesFor(''), isNull);
    expect(MeshAvatarRegistry.instance.bytesFor('ok'), isNotNull);
  });
}
