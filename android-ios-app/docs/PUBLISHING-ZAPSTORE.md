# Publishing Nymchat to Zapstore (self-signed APK)

This guide covers shipping Nymchat as a standalone, sideloadable `.apk` through
[Zapstore](https://zapstore.dev/docs/publish) — independent of Google Play and
of Dreamflow's Play pipeline.

## TL;DR of the situation

- **The app is already "de-Googled."** There is no Firebase, no Google Play
  Services (`com.google.android.gms`), no Play Billing, no analytics, and no
  Play Integrity / SafetyNet gate anywhere in the code. The only Google package
  is `google_fonts`, and it is imported but never called — the UI uses the
  bundled Roboto / Noto Sans fonts, so nothing fetches from Google at runtime.
  There is nothing to strip out to make a "non-Googled" build.
- **What differs from the Play build is only two things:**
  1. **Format** — Play wants an `.aab`; sideloading / Zapstore wants a signed
     `.apk`. → `flutter build apk --release`.
  2. **Signing key** — you sign the APK with **your own** keystore instead of
     Google Play App Signing. This is what this guide sets up.
- **"Google Play verification at install"** is **Play Protect**, a device-level
  OS scan — not something baked into the APK. On a fresh sideload some devices
  show a "scan / install anyway" prompt; it is not a hard block and it fades as
  the install count grows. Because the app has no attestation gate, it runs
  fine sideloaded.

## One-time: signature-continuity caveat (read this)

You chose to generate a **new keystore**. That means the Zapstore APK is signed
with a different key than the copy on Google Play. Android treats an app's
identity as *package name + signing key*, so:

- A Zapstore install of `com.nym.bar` is a **separate install** from the Play
  Store one. A user cannot update from the Play version to the Zapstore version
  (or vice-versa) in place — they'd uninstall one first.
- This is the normal, expected trade-off for leaving a managed Play pipeline.
  New users installing from Zapstore are unaffected.

If you ever *do* obtain Dreamflow's actual app-signing `.jks` + passwords, you
can drop it in instead (same `key.properties` shape) and the two channels
become interchangeable. That is usually not possible when Google Play App
Signing holds the key.

## Files added to the repo

| File | Purpose |
| --- | --- |
| `zapstore.yaml` | Zapstore listing manifest (metadata, icon, APK path). |
| `scripts/generate-keystore.sh` | One-time: create your keystore + `android/key.properties`. |
| `scripts/build-release-apk.sh` | Build the signed release APK locally. |
| `.github/workflows/release-apk.yml` | CI: build + publish to Zapstore on tag push. |

The existing `android/app/build.gradle` already reads `android/key.properties`
for its release `signingConfig`, so no Gradle changes were needed. Both the
keystore (`*.jks`) and `key.properties` are already covered by `.gitignore` and
must never be committed.

---

## Path A — build & publish locally

Prereqs: Flutter SDK, Android SDK, and a JDK 17 on your machine.

```bash
# 1. Create your signing key (ONCE). Keep the .jks + passwords safe/offline.
./scripts/generate-keystore.sh

# 2. Build the signed universal APK.
./scripts/build-release-apk.sh
#    -> build/app/outputs/flutter-apk/app-release.apk
#    (use `--split` for smaller per-ABI APKs instead)

# 3. Confirm it is signed with YOUR key, not a debug key.
keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk

# 4. Install the Zapstore publishing CLI (Go required).
go install github.com/zapstore/zsp@latest

# 5. Publish. Your Zapstore identity is a Nostr key (nsec).
SIGN_WITH=nsec1your_key_here zsp publish
```

`zsp` reads `zapstore.yaml`, uploads the APK + icon to the Zapstore CDN, and
signs the Nostr release event with your key. It pulls the version /
`versionCode` straight from the APK, so bump the app version in
`pubspec.yaml` (`version: 1.0.1+147`) before each release.

> No Nostr key yet? Any Nostr client (e.g. Alby, Amethyst, nostr keychain)
> generates an `nsec`/`npub` pair. The `npub` becomes your publisher identity
> on Zapstore. Guard the `nsec` like a signing key.

## Path B — build & publish from GitHub Actions

The workflow `.github/workflows/release-apk.yml` does the same thing in CI.

1. Generate the keystore locally once (`./scripts/generate-keystore.sh`), then
   print its base64:
   ```bash
   base64 -w0 android/app/nym-release-key.jks
   ```
2. In the GitHub repo: **Settings → Secrets and variables → Actions** → add:
   | Secret | Value |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | output of the base64 command above |
   | `ANDROID_KEYSTORE_PASSWORD` | your store password |
   | `ANDROID_KEY_PASSWORD` | your key password (often the same) |
   | `ANDROID_KEY_ALIAS` | `nym-release` |
   | `ZAPSTORE_SIGN_WITH` | your Zapstore `nsec1...` |
3. Trigger it:
   - **Release:** push a version tag →
     `git tag v1.0.1 && git push origin v1.0.1` → builds **and** publishes.
   - **Dry run:** Actions tab → *Build & publish APK to Zapstore* → *Run
     workflow* → leave "Publish" unticked to just build. The APK is always
     uploaded as a workflow **artifact** you can download.

The workflow deletes the keystore and `key.properties` from the runner at the
end of every run.

---

## Before your first publish — finish the listing

`zapstore.yaml` is filled in but a few things make the listing look right:

- **Screenshots** — add 2–5 phone PNGs (e.g. under
  `assets/store/screenshots/`) and uncomment the `images:` list.
- **License** — add a `LICENSE` file to the repo, then set `license:` in
  `zapstore.yaml` to its SPDX id (e.g. `MIT`, `Apache-2.0`, `GPL-3.0-only`).
- **Release notes** — add a `CHANGELOG.md` (Keep a Changelog format) and
  uncomment `release_notes:` so each release shows its notes.
- **Website / repository / tags** — already set to `nymchat.app` and this repo;
  adjust if you'd rather point elsewhere.

### Optional cleanup

`google_fonts` in `pubspec.yaml` is unused. Removing it drops the last Google
package from the dependency tree (purely cosmetic — it already never runs).
