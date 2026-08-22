# iOS + Android Platform-Readiness Audit

Project: `nym_bar` (Nymchat native Flutter clone)
Date: 2026-06-23
Scope: Confirm the app will BUILD and RUN on iOS and Android with every native
permission/capability its features require; fix gaps in `android/**`, `ios/**`,
`pubspec.yaml`, and the owned platform services.

---

## 1. Verdict

| Platform | Will build? | Will run with all capabilities? |
| --- | --- | --- |
| **Android** | **Yes** (config valid; build could not be executed here — no Android SDK in env, see §6) | **Yes**, after permissions/package fixes below |
| **iOS** | **Yes** (by inspection; no macOS to compile) | **Yes**, after plist/entitlement/deployment-target fixes below, plus the manual signing/APNs steps in §7 |

Both platforms had **real blockers** that are now fixed:
- Android: app package was the template `com.mycompany.CounterApp` / `com.example.counter` (namespace ≠ applicationId ≠ MainActivity package) and was missing ~12 runtime permissions.
- iOS: the `Runner.entitlements` file existed but was **never wired into the Xcode project** (associated domains / keychain groups would silently not apply); deployment target was `12.0` (too low for `flutter_webrtc`); Face ID, photo-add, background-audio/voip/push and `https` query scheme were all missing.

---

## 2. Capability → permission matrix

Status legend: present = already correct; **ADDED** = added in this audit; FIXED = corrected.

| Capability (plugin) | Android entry | iOS entry | Status |
| --- | --- | --- | --- |
| Internet / sockets | `INTERNET`, `ACCESS_NETWORK_STATE` **ADDED** | (none needed) | present / ADDED |
| Camera — video calls, photos, QR (`flutter_webrtc`, `image_picker`, `mobile_scanner`) | `CAMERA` | `NSCameraUsageDescription` (FIXED wording) | present |
| Microphone — calls/audio (`flutter_webrtc`) | `RECORD_AUDIO` | `NSMicrophoneUsageDescription` | present |
| Audio routing (`flutter_webrtc`) | `MODIFY_AUDIO_SETTINGS` **ADDED** | n/a | ADDED |
| Bluetooth audio for calls | `BLUETOOTH` (maxSdk 30) + `BLUETOOTH_CONNECT` **ADDED** | `NSBluetooth*UsageDescription` (re-worded) | ADDED / present |
| Screen-share in calls (`getDisplayMedia`) | `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION` **ADDED** | covered by `UIBackgroundModes: audio` | ADDED |
| Keep call alive in background | `WAKE_LOCK` **ADDED**, `FOREGROUND_SERVICE_MICROPHONE/CAMERA` **ADDED** | `UIBackgroundModes: audio`, `voip` **ADDED** | ADDED |
| Local notifications (`flutter_local_notifications`) | `POST_NOTIFICATIONS` **ADDED**, `VIBRATE` **ADDED**, `RECEIVE_BOOT_COMPLETED` **ADDED** + desugaring (present) | Darwin init in `notification_service.dart` (present) | ADDED |
| Push / FCM (guarded no-op today) | `POST_NOTIFICATIONS` (shared) | `UIBackgroundModes: remote-notification` **ADDED**; `aps-environment` = MANUAL (§7) | ADDED / manual |
| Biometric / Face ID unlock (`local_auth`) | `USE_BIOMETRIC` + `USE_FINGERPRINT` **ADDED** | `NSFaceIDUsageDescription` **ADDED** | ADDED |
| Secure storage (`flutter_secure_storage`, Keychain/Keystore) | Keystore — no manifest entry needed | `keychain-access-groups` entitlement **ADDED** | ADDED |
| Pick photos/files (`image_picker`, `file_picker`, `file_selector`) | `READ_MEDIA_IMAGES/VIDEO/AUDIO` **ADDED**, `READ_EXTERNAL_STORAGE` (maxSdk 32) **ADDED** | `NSPhotoLibraryUsageDescription` | ADDED |
| Save media to gallery (`gal`) | `WRITE_EXTERNAL_STORAGE` (maxSdk 29) + `ACCESS_MEDIA_LOCATION` **ADDED** | `NSPhotoLibraryAddUsageDescription` **ADDED** | ADDED |
| Audio playback (`audioplayers`) | no extra permission | no extra permission | present |
| Deep links — custom scheme (`app_links`) | `nymchat://` intent-filter | `CFBundleURLTypes` scheme `nymchat` | present |
| Deep links — universal links | autoVerify intent-filters for `app.nymchat.app`, `app.nym.bar`, `web.nymchat.app`, `nymchat.app` **FIXED** | `associated-domains` for same hosts **FIXED** | FIXED |
| Open Lightning wallet / external URLs (`url_launcher`) | `<queries>` `lightning` + `https` + SEND **ADDED https** | `LSApplicationQueriesSchemes` `lightning` + `https`/`http`/`mailto`/`tel` **ADDED** | ADDED |
| Share (`share_plus`) | SEND query **ADDED** | system | ADDED |
| Cleartext policy | `usesCleartextTraffic="false"` **ADDED** (app uses only wss/https) | ATS default (secure) | ADDED |
| Encryption export compliance | n/a | `ITSAppUsesNonExemptEncryption=false` **ADDED** | ADDED |

### Removed (unused — were rejection/clutter risks)
- Android `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` and iOS `NSLocation*UsageDescription`: **removed**. No geolocation plugin is used; the globe/geohash feature reads a bundled static dataset (`assets/data/countries-110m.json`) and takes manual geohash input. Declaring unused location strings risks App Store rejection.

---

## 3. Android package identity (FIXED — was a hard blocker)

| Field | Before | After |
| --- | --- | --- |
| `applicationId` (build.gradle) | `com.nym.bar` | `com.nym.bar` (unchanged — already correct, matches AASA/assetlinks) |
| `namespace` (build.gradle) | `com.mycompany.CounterApp` | **`com.nym.bar`** |
| MainActivity package + path | `com.mycompany.CounterApp` at `kotlin/com/example/counter/MainActivity.kt` | **`com.nym.bar`** at `kotlin/com/nym/bar/MainActivity.kt` |

`com.nym.bar` was chosen (not `app.nymchat`) because it is already the
`applicationId`, the iOS `PRODUCT_BUNDLE_IDENTIFIER`, the `package_name` in
`web/.well-known/assetlinks.json`, and the `appID` suffix in
`web/.well-known/apple-app-site-association`. Changing those would break the
already-published association files; aligning the namespace/MainActivity to
`com.nym.bar` is the consistent, non-breaking fix.

---

## 4. Gradle / build config (verified, no change needed beyond namespace)

- `minSdk = 23` — satisfies the highest floor among plugins (`flutter_webrtc` ≥23, `mobile_scanner` ≥21, `local_auth` ≥18, `flutter_secure_storage` ≥18). OK.
- `compileSdk = 36`, `targetSdk = 36` — current. OK.
- `coreLibraryDesugaringEnabled = true` + `desugar_jdk_libs:2.1.4` — required by `flutter_local_notifications`. Present.
- MultiDex — automatic at minSdk ≥21. OK.
- NDK r27 + `useLegacyPackaging=false` — 16 KB page-size ready. OK.
- AGP 8.7.3 / Gradle 8.12 / Kotlin 2.2.0 / JDK 17. OK.

---

## 5. iOS config (FIXED)

- **`CODE_SIGN_ENTITLEMENTS` was missing from `project.pbxproj`** — added `Runner/Runner.entitlements` to all three Runner build configs (Debug/Profile/Release). Without it, associated domains and keychain groups never reach the signed app.
- **`IPHONEOS_DEPLOYMENT_TARGET` 12.0 → 15.0** in all three configs — `flutter_webrtc 0.12.x` needs ≥13 and the Podfile/`AppFrameworkInfo.plist` already pin 15.0; the project file was inconsistent. Now uniform at 15.0.
- Info.plist: added `NSPhotoLibraryAddUsageDescription`, `NSFaceIDUsageDescription`, `ITSAppUsesNonExemptEncryption`; `UIBackgroundModes` now includes `audio`/`voip`/`remote-notification`; `LSApplicationQueriesSchemes` now includes `https`/`http`/`mailto`/`tel`.
- Entitlements: associated-domains now list all four deep-link hosts (was only `web.nymchat.app`/`nymchat.app`, but the code parses `app.nymchat.app`/`app.nym.bar`); added `keychain-access-groups` for `flutter_secure_storage`.
- Podfile already forces the 15.0 floor and enables `permission_handler` macros (camera/photos/microphone/location). Left intact.

---

## 6. Build result

`flutter analyze` → **No issues found.**
`flutter test test/platform_smoke_test.dart` → **31/31 passed** (the new test asserts every permission/key/host/package above against the real files; it needs no SDK so it guards the config in CI).

`flutter build apk --debug` → **could not run in this environment**: the only
blocker is `No Android SDK found`. The sandbox has no Android SDK and it cannot
be installed — `dl.google.com` (the SDK repo) is not in the network egress
allowlist, so `commandlinetools` download is refused. This is purely an
environment limitation; the Gradle project itself is valid:
- the namespace/applicationId/MainActivity now resolve consistently,
- `GeneratedPluginRegistrant.java` registers every native plugin
  (FlutterWebRTC, FlutterLocalNotifications, FlutterSecureStorage, LocalAuth,
  MobileScanner, Gal, ImagePicker, FilePicker, PermissionHandler, SharePlus,
  UrlLauncher, AppLinks, Audioplayers),
- Dart compiles cleanly (analyze is green).

To complete Android build verification on a machine with the SDK:
`export ANDROID_HOME=<sdk>` then `flutter build apk --debug` — expected to
configure and compile with the current config.

---

## 7. Remaining MANUAL steps (cannot be done in-repo)

1. **Android signing**: provide `android/key.properties` + a release keystore (build.gradle already reads them). Debug build needs none.
2. **iOS signing / team**: `DEVELOPMENT_TEAM` is unset in `project.pbxproj`. Set it in Xcode (Apple Developer account `KJ6U2Y9B2M`, per the AASA `appID`) and enable the Associated Domains + Keychain Sharing capabilities so the entitlements provision.
3. **Universal-link hosting**: serve `web/.well-known/assetlinks.json` (Android) and `web/.well-known/apple-app-site-association` (iOS) over HTTPS at the real hosts. The repo copies pin `com.nym.bar` + team `KJ6U2Y9B2M` but currently only enumerate `nymchat.app`/`web.nymchat.app`; if `app.nymchat.app`/`app.nym.bar` are live hosts, host the files there too (the manifest/entitlements now accept all four). Update the `sha256_cert_fingerprints` in `assetlinks.json` to the real signing-cert SHA-256.
4. **Push (FCM)**: currently a guarded no-op (`firebase_messaging`/`firebase_core` are intentionally not in `pubspec.yaml` to stay de-Google-able — see `lib/services/firebase_messaging_service.dart`). To enable real push: add those plugins, drop in `google-services.json` (Android) + `GoogleService-Info.plist` (iOS), apply the `com.google.gms.google-services` Gradle plugin, and add the `aps-environment` key to `Runner.entitlements` with an APNs-enabled provisioning profile. The `remote-notification` background mode and `POST_NOTIFICATIONS` permission are already in place for that switch-on.

---

## 8. Files changed

- `android/app/src/main/AndroidManifest.xml` — full permission/queries/deep-link rewrite.
- `android/app/build.gradle` — `namespace` → `com.nym.bar`.
- `android/app/src/main/kotlin/com/nym/bar/MainActivity.kt` — new (replaces `com/example/counter`).
- `ios/Runner/Info.plist` — usage strings, background modes, query schemes, ITSApp key; removed unused location keys.
- `ios/Runner/Runner.entitlements` — associated domains + keychain group.
- `ios/Runner.xcodeproj/project.pbxproj` — wired entitlements; deployment target 12→15.
- `test/platform_smoke_test.dart` — new SDK-free config guard (31 assertions).

---

## 9. Note on `lib/features/groups/group_logic.dart`

This file is outside audit ownership (`lib/features/**`). During the audit a
transient `_appendModLog` undefined-method error surfaced from in-progress work
there; it resolved on its own and the final `flutter analyze` is clean. No edit
was made to it.
