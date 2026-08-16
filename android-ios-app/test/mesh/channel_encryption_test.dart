import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/noise/channel_encryption.dart';

void main() {
  group('MeshChannelEncryption', () {
    test('same password + channel yields the same key (deterministic)', () async {
      final a = await MeshChannelEncryption.deriveKey('hunter2', '#festival');
      final b = await MeshChannelEncryption.deriveKey('hunter2', '#festival');
      expect(await a.extractBytes(), equals(await b.extractBytes()));
    });

    test('channel name is the salt — different channel, different key', () async {
      final a = await MeshChannelEncryption.deriveKey('hunter2', '#festival');
      final b = await MeshChannelEncryption.deriveKey('hunter2', '#afterparty');
      expect(await a.extractBytes(), isNot(equals(await b.extractBytes())));
    });

    test('encrypt/decrypt round-trips with IV(12)+ct+tag(16) layout', () async {
      final enc = MeshChannelEncryption();
      await enc.setChannelPassword('#festival', 'hunter2');
      final wire = await enc.encrypt('#festival', 'meet at the north stage');
      // 12-byte IV + ciphertext(23) + 16-byte tag.
      expect(wire.length, 12 + 'meet at the north stage'.length + 16);
      expect(await enc.decrypt('#festival', wire), 'meet at the north stage');
    });

    test('a member with the wrong password cannot decrypt', () async {
      final alice = MeshChannelEncryption();
      final mallory = MeshChannelEncryption();
      await alice.setChannelPassword('#festival', 'correct horse');
      await mallory.setChannelPassword('#festival', 'wrong');
      final wire = await alice.encrypt('#festival', 'secret plan');
      expect(() => mallory.decrypt('#festival', wire), throwsA(anything));
    });

    test('a member with the right password decrypts a peer message', () async {
      final alice = MeshChannelEncryption();
      final bob = MeshChannelEncryption();
      await alice.setChannelPassword('#crew', 'sharedpass');
      await bob.setChannelPassword('#crew', 'sharedpass');
      final wire = await alice.encrypt('#crew', 'gm crew');
      expect(await bob.decrypt('#crew', wire), 'gm crew');
    });

    test('tampered ciphertext fails authentication', () async {
      final enc = MeshChannelEncryption();
      await enc.setChannelPassword('#crew', 'sharedpass');
      final wire = await enc.encrypt('#crew', 'gm crew');
      wire[wire.length - 1] ^= 0xFF;
      expect(() => enc.decrypt('#crew', Uint8List.fromList(wire)),
          throwsA(anything));
    });
  });
}
