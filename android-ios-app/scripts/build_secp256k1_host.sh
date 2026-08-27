#!/usr/bin/env bash
# Builds libsecp256k1 for the HOST machine into build/libsecp256k1.so so that
# `flutter test` exercises the native BIP340 verification path
# (test/native_schnorr_test.dart). Devices don't need this — coinlib_flutter
# bundles the library per platform; without it the tests skip and the app
# falls back to pure-Dart verification.
#
# Uses the same source fork + commit coinlib 5.0.0 pins in its own build
# scripts (bin/build_linux.dart).
set -euo pipefail

REPO=https://github.com/peercoin/secp256k1-coinlib
COMMIT=69018e5b939d8d540ca6b237945100f4ecb5681e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q "$REPO" "$WORK/secp256k1"
git -C "$WORK/secp256k1" checkout -q "$COMMIT"
cmake -S "$WORK/secp256k1" -B "$WORK/build" \
  -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
  -DSECP256K1_BUILD_TESTS=OFF \
  -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
  -DSECP256K1_BUILD_BENCHMARK=OFF \
  -DSECP256K1_BUILD_EXAMPLES=OFF \
  -DSECP256K1_BUILD_CTIME_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$WORK/build" -j >/dev/null

mkdir -p "$ROOT/build"
cp "$(find "$WORK/build" -name 'libsecp256k1.so*' -type f | sort | head -1)" \
  "$ROOT/build/libsecp256k1.so"
echo "Installed $ROOT/build/libsecp256k1.so"
