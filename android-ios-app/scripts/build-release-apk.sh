#!/usr/bin/env bash
#
# Build the signed, universal release APK for sideloading / Zapstore.
# Requires android/key.properties + the keystore it points at (see
# ./scripts/generate-keystore.sh). Output:
#   build/app/outputs/flutter-apk/app-release.apk
#
# Usage:
#   ./scripts/build-release-apk.sh            # universal APK (all ABIs)
#   ./scripts/build-release-apk.sh --split    # one APK per ABI (smaller each)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH." >&2
  exit 1
fi

if [[ ! -f android/key.properties ]]; then
  echo "android/key.properties missing — run ./scripts/generate-keystore.sh first." >&2
  exit 1
fi

flutter pub get

if [[ "${1:-}" == "--split" ]]; then
  flutter build apk --release --split-per-abi
  echo
  echo "Per-ABI APKs in build/app/outputs/flutter-apk/:"
  ls -1 build/app/outputs/flutter-apk/*-release.apk
else
  # Universal APK: single file, installs on every supported ABI. This is the
  # one Zapstore's release_source points at.
  flutter build apk --release
  echo
  echo "Universal APK: build/app/outputs/flutter-apk/app-release.apk"
fi

echo
echo "Verify it is signed with YOUR key (not a debug key):"
echo "  keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk"
