import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/api/storage_sync.dart';

void main() {
  group('NIP-44 size model', () {
    test('calc_padded_len matches the NIP-44 spec vectors', () {
      const vectors = <int, int>{
        16: 32, 32: 32, 33: 64, 37: 64, 45: 64, 49: 64, 64: 64, 65: 96,
        100: 128, 111: 128, 200: 224, 250: 256, 320: 320, 383: 384, 384: 384,
        400: 448, 500: 512, 512: 512, 515: 640, 700: 768, 800: 896, 900: 1024,
        1020: 1024, 65536: 65536,
      };
      vectors.forEach((input, want) {
        expect(StorageSync.nip44PaddedLen(input), want,
            reason: 'calc_padded_len($input)');
      });
    });

    test('the wrap cliff sits at 28672 bytes', () {
      final max = StorageSync.maxRumorBytesForWrap();
      expect(max, 28672);
      expect(StorageSync.wrappedSizeForRumor(max), lessThanOrEqualTo(65000));
      expect(StorageSync.wrappedSizeForRumor(max + 1), greaterThan(65000));
    });

    test('reproduces the size that was being rejected', () {
      // The old bound was floor(60000 / 1.95) = 30769, and history shards were
      // budgeted at 30000 bytes of message JSON. Both wrap to 65,958.
      expect(StorageSync.wrappedSizeForRumor(30769), 65958);
      expect(StorageSync.wrappedSizeForRumor(30000), 65958);
      expect(StorageSync.wrappedSizeForRumor(30000), greaterThan(65000));
    });

    test('wrapped size never decreases as the rumor grows', () {
      var prev = 0;
      for (var r = 32; r < 40000; r += 97) {
        final v = StorageSync.wrappedSizeForRumor(r);
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
    });

    test('a tighter limit yields a smaller bound', () {
      expect(StorageSync.maxRumorBytesForWrap(30000),
          lessThan(StorageSync.maxRumorBytesForWrap()));
    });
  });

  // The bug this models: budgeting with the classical size and then publishing
  // post-quantum. The layer adds ~1.5 KB of KEM ciphertext and inflates what
  // it wraps by a third, on BOTH layers.
  group('the post-quantum layer moves the ceiling', () {
    test('the pq2 frame is exact: prefix + b64(1088) + dot + b64(inner+16)',
        () {
      int b64(int n) => (n * 4 + 2) ~/ 3;
      for (final inner in [1456, 6916, 13744, 27396]) {
        expect(StorageSync.pq2PayloadLen(inner),
            4 + b64(1088) + 1 + b64(inner + 16));
      }
    });

    test('a rumor at the classical ceiling overflows if published pq2', () {
      final clsMax = StorageSync.maxRumorBytesForWrap();
      expect(StorageSync.wrappedSizeForRumor(clsMax), lessThanOrEqualTo(65000));
      expect(StorageSync.wrappedSizeForRumor(clsMax, pq2: true),
          greaterThan(65000),
          reason: 'this is exactly what was falling back to NIP-44');
    });

    test('the pq2 ceiling is lower, and tight', () {
      final pqMax = StorageSync.maxRumorBytesForWrap(65000, true);
      expect(pqMax, lessThan(StorageSync.maxRumorBytesForWrap()));
      expect(StorageSync.wrappedSizeForRumor(pqMax, pq2: true),
          lessThanOrEqualTo(65000));
      expect(StorageSync.wrappedSizeForRumor(pqMax + 1, pq2: true),
          greaterThan(65000));
    });

    test('and it agrees with the PWA, which shares the format', () {
      // Both apps must shard identically or a device re-publishes the other's
      // history under different boundaries on every save.
      expect(StorageSync.maxRumorBytesForWrap(), 28672);
      expect(StorageSync.maxRumorBytesForWrap(65000, true), 16384);
    });
  });
}
