# Google, Apple and passkey key backup

"Continue with Google" / "Continue with Apple" back up the user's locally generated Nostr key, encrypted with a PIN, to their own cloud account, and restore it on another device. The format is `nym-key-backup-v1`, shared byte for byte with Nymbot (web and Flutter) and the Nymchat web app. The canonical test vector is `test/key-backup-vector.json`.

Code: `lib/features/identity/key_backup/`.

Every button stays hidden until its provider is configured, so a build without the settings below behaves exactly as before.

The encrypted plaintext (and the passkey largeBlob) is the bundle `{"v":1,"sk":"<64 lowercase hex>","pq":"<nympq1… code>"}`, with `pq` left out when the account has no post-quantum recovery code. Restore also accepts the older bare 64-hex plaintext. A brand-new key (Continue with Google/Apple with no backups, Create a new key with a passkey, or the plain ephemeral key) gets its recovery code at the same moment, so the first backup holds both and the first sign-in records and announces that code instead of minting another. Restoring a bundle into an account that has no recovery-code record yet adopts the backed-up code the same way. Otherwise a restored code goes through the same link path as a pasted one, after sign-in; a code that can't be parsed or doesn't match the account is skipped with a note and never blocks the sign-in. The "Back up to Google / Apple / with a passkey" and "Remove backups" buttons live in View or Edit Nym's Details, beside the nsec and the recovery code, for local keys only; Settings links there.

## Build settings (`--dart-define`)

| Define | Value | Needed for |
| --- | --- | --- |
| `GOOGLE_IOS_CLIENT_ID` | the iOS OAuth client id (`<id>.apps.googleusercontent.com`) | Google on iOS |
| `GOOGLE_SERVER_CLIENT_ID` | the Web OAuth client id, shared with the web apps | Google on Android (required there as `serverClientId`), optional on iOS |
| `APPLE_BACKUP` | `true` | Apple on iOS (default off) |
| `APPLE_KEYCHAIN_GROUP` | `<TEAMID>.com.nym.shared` (the full access group, team prefix included) | Apple on iOS, so Nymbot and Nymchat share backups |
| `PASSKEY_BACKUP` | `true` | Continue with a passkey on iOS 17+ and Android 9+ (default off) |
| `PASSKEY_RP_ID` | defaults to `web.nymchat.app` | the WebAuthn RP ID, the same one the Nymchat web app uses (`location.hostname`) |

Example:

```sh
flutter build ipa \
  --dart-define=GOOGLE_IOS_CLIENT_ID=1234-abc.apps.googleusercontent.com \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=1234-web.apps.googleusercontent.com \
  --dart-define=APPLE_BACKUP=true \
  --dart-define=APPLE_KEYCHAIN_GROUP=ABCDE12345.com.nym.shared
```

## Google Cloud (shared project with Nymbot)

- OAuth consent screen: add the scopes `openid` and `https://www.googleapis.com/auth/drive.appdata`. Nothing broader.
- Enable the Google Drive API.
- Create an **Android** OAuth client for package `com.nym.bar` with the SHA-1 of every signing key in use (the upload key and, for Play, the app signing key). No client id goes into the Android code; Credential Manager matches the package and certificate.
- Create an **iOS** OAuth client for bundle id `com.nym.bar`. Its id is `GOOGLE_IOS_CLIENT_ID`.
- The existing **Web** client (used by the web apps) is `GOOGLE_SERVER_CLIENT_ID`.

## iOS

- `ios/Runner/Info.plist` has a placeholder URL scheme `com.googleusercontent.apps.REPLACE-WITH-GOOGLE-IOS-CLIENT-ID` under `CFBundleURLTypes` (`google-sign-in`). Replace it with the reversed iOS client id (`com.googleusercontent.apps.<id>`) before shipping Google sign-in on iOS.
- Apple backup, only when turning on `APPLE_BACKUP`:
  - Enable **Sign in with Apple** on the App ID `com.nym.bar` (and Nymbot's) in the same team, regenerate the provisioning profile, then add to `ios/Runner/Runner.entitlements` and `RunnerDebug.entitlements`:
    ```xml
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
    ```
  - Add the shared keychain group to `keychain-access-groups` in both entitlements files, next to the existing `$(AppIdentifierPrefix)com.nym.bar` (keep that one first so flutter_secure_storage's existing items stay where they are), and add the same group to Nymbot:
    ```xml
    <string>$(AppIdentifierPrefix)com.nym.shared</string>
    ```
  - Backups are iCloud Keychain generic-password items: service `com.nym.apple-backup`, account `nym_bk_<uuid>`, `kSecAttrSynchronizable = true`, `kSecAttrAccessibleAfterFirstUnlock`, in that access group.
- None of these entitlements are in the repo yet, on purpose: adding them before the App ID and profile have the capability makes signing fail.

## Android

Nothing beyond the Google Cloud setup above and `GOOGLE_SERVER_CLIENT_ID`. The Apple option never shows on Android.

## Passkey (`nym-passkey-backup-v1`)

"Continue with a passkey" restores a key from a passkey; if no passkey is chosen or none has a backup, it offers "Create a new key and back it up with a passkey", which the sign-up tab also shows directly. View or Edit Nym's Details has "Back up with a passkey" for local keys. The canonical vector is `test/passkey-backup-vector.json`.

- PRF (iOS 18+, Android through Credential Manager): the key is NIP-44 encrypted with a key derived from the passkey's PRF output and published as a kind 30078 event (`d` = `nym-key-backup`), signed by a locator key that is also derived from the PRF output, to the app's default relays plus relay.damus.io, nos.lol, relay.primal.net, relay.nostr.band and nostr.mom.
- largeBlob fallback (iOS 17+, and Android providers that support it): the key is written into the passkey itself.
- Native code: `ios/Runner/PasskeyBackup.swift` (AuthenticationServices) and `android/app/src/main/kotlin/com/nym/bar/PasskeyBackup.kt` (androidx.credentials 1.6.0), on the `app.nymchat/passkey_backup` method channel.

Keep `PASSKEY_BACKUP` off until all of this is in place, or the passkey sheet fails with a domain error:

- `https://web.nymchat.app/.well-known/apple-app-site-association` must list the app under `webcredentials`:
  ```json
  "webcredentials": { "apps": ["KJ6U2Y9B2M.com.nym.bar"] }
  ```
- iOS: enable **Associated Domains** on the App ID `com.nym.bar`, regenerate the provisioning profile, then add to `Runner.entitlements` and `RunnerDebug.entitlements`:
  ```xml
  <key>com.apple.developer.associated-domains</key>
  <array>
      <string>webcredentials:web.nymchat.app</string>
  </array>
  ```
  The entitlement is not in the repo: the capability was removed because the automatic provisioning profile does not include it, and adding it back before the profile has it breaks signing.
- `https://web.nymchat.app/.well-known/assetlinks.json` must grant the Android app the login-credentials relation, with the SHA-256 of every signing certificate in use (the release key below, plus the Play app signing key if the app ships through Play):
  ```json
  {
    "relation": ["delegate_permission/common.get_login_creds"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.nym.bar",
      "sha256_cert_fingerprints": [
        "29:F3:59:CC:6A:BA:A6:70:93:5A:2A:96:92:43:AD:A6:6B:56:BD:39:07:AB:D0:C0:24:53:35:FD:E8:2C:F4:D9"
      ]
    }
  }
  ```
