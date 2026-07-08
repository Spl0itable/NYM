#!/usr/bin/env bash
#
# Generate a release signing keystore for the Nymchat Android APK and wire it
# into android/key.properties so `flutter build apk --release` picks it up.
#
# You only run this ONCE. Keep the resulting .jks file and its passwords safe
# and OFFLINE — losing them means you can never ship a signed update that
# existing users can install over the top. Neither the .jks nor key.properties
# is committed (both are covered by .gitignore).
#
# Usage:
#   ./scripts/generate-keystore.sh
#
# Then, to publish from CI, print the base64 you need for the GitHub secret:
#   base64 -w0 android/app/nym-release-key.jks
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYSTORE="$REPO_ROOT/android/app/nym-release-key.jks"
KEY_PROPS="$REPO_ROOT/android/key.properties"
ALIAS="nym-release"

if [[ -f "$KEYSTORE" ]]; then
  echo "Refusing to overwrite existing keystore: $KEYSTORE" >&2
  echo "Delete it by hand first if you REALLY mean to replace it." >&2
  exit 1
fi

if ! command -v keytool >/dev/null 2>&1; then
  echo "keytool not found — install a JDK (e.g. Temurin 17)." >&2
  exit 1
fi

echo "You'll be asked for a keystore password (store password) and can reuse it"
echo "for the key password. You'll also be asked for your name/org (any values)."
echo

# RSA-2048, ~27 year validity (Google requires the key to outlive Oct 2033).
keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000

echo
read -r -s -p "Re-enter the STORE password you just set (for key.properties): " STORE_PW
echo
read -r -s -p "Re-enter the KEY password (press Enter if same as store): " KEY_PW
echo
KEY_PW="${KEY_PW:-$STORE_PW}"

umask 077
cat > "$KEY_PROPS" <<EOF
storePassword=$STORE_PW
keyPassword=$KEY_PW
keyAlias=$ALIAS
storeFile=nym-release-key.jks
EOF

echo
echo "Wrote $KEY_PROPS (gitignored)."
echo "Keystore:      $KEYSTORE (gitignored)"
echo
echo "SHA-256 fingerprint (useful for App Links / assetlinks.json):"
keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" -storepass "$STORE_PW" \
  2>/dev/null | grep -A1 "SHA256:" | head -2 || true
echo
echo "For CI, add these GitHub repo secrets:"
echo "  ANDROID_KEYSTORE_BASE64   = \$(base64 -w0 $KEYSTORE)"
echo "  ANDROID_KEYSTORE_PASSWORD = <your store password>"
echo "  ANDROID_KEY_PASSWORD      = <your key password>"
echo "  ANDROID_KEY_ALIAS         = $ALIAS"
echo "  ZAPSTORE_SIGN_WITH        = <your zapstore nsec1...>"
