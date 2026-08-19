# iOS Share Extension — one-time Xcode setup

The share-sheet feature (share text / links / images from other apps INTO
Nymchat) is fully wired in Dart and on Android. iOS additionally needs a
**Share Extension** target, which must be added in Xcode because it creates a
new bundle target with its own build phases and entitlements — this can't be
committed as plain source edits.

Everything below is a standard `receive_sharing_intent` iOS setup; the Dart
side (`lib/features/share/`) already consumes what the extension delivers.

## Steps (in `ios/Runner.xcworkspace`, ~10 min)

1. **File ▸ New ▸ Target… ▸ Share Extension.** Name it `Share Extension`.
   Bundle id must be a child of the app id, e.g.
   `app.nymchat.mobile.ShareExtension`. Do NOT activate the scheme when asked.

2. **App Group** — add the SAME group to BOTH targets (Runner and the new
   Share Extension) under *Signing & Capabilities ▸ App Groups*:
   `group.app.nymchat.mobile`. The plugin passes the shared payload through
   this group.

3. Replace the generated `ShareViewController.swift` with the plugin's
   subclass (from the `receive_sharing_intent` README — it forwards the shared
   items to the app group and opens the host app). Set the extension's
   `Info.plist` `NSExtensionActivationRule` to accept text, URLs, and images
   (the README provides the exact `SUBQUERY` snippet; allow
   `NSExtensionActivationSupportsText`,
   `NSExtensionActivationSupportsWebURLWithMaxCount`, and
   `NSExtensionActivationSupportsImageWithMaxCount`).

4. In the **Runner** target's `Info.plist`, confirm the custom URL scheme is
   present (it already is: `nymchat`). The plugin uses it to reopen the app
   from the extension.

5. Add the app group id to `ios/Runner/Runner.entitlements` (create it if the
   project has none) and reference it from the target's *Signing &
   Capabilities*.

## Verify

Build to a device, share a link from Safari ▸ Nymchat. The app opens with the
"Share to…" destination picker. Sharing while the app is already running takes
the warm-stream path; sharing while it's closed takes the cold-start path —
both are handled in `lib/features/share/share_intake.dart`.

## Android

No manual step — the SEND / SEND_MULTIPLE intent filters on `MainActivity`
(`AndroidManifest.xml`) are all that's required, and they're committed.
