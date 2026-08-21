import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Open `beginBackgroundTask` identifier for "Stay Connected in Background".
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  /// Whether Dart still wants the keep-alive. Kept separate from the task id so
  /// an expiring task can be renewed only while the setting is actually on.
  private var keepAliveRequested = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    excludeMessageStoreFromBackup()
    registerBackgroundConnectivityChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The sqflite message store (nym_cache.db + WAL/SHM sidecars) mirrors
  /// end-to-end encrypted conversations locally; it must not ride iCloud or
  /// Finder/iTunes backups. Identity secrets live in the Keychain (protected
  /// separately); this covers the Documents-directory database files. Applied
  /// on every launch so files recreated after a wipe are re-excluded.
  private func excludeMessageStoreFromBackup() {
    guard let docs = FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask).first else { return }
    for name in ["nym_cache.db", "nym_cache.db-wal", "nym_cache.db-shm", "nym_cache.db-journal"] {
      var url = docs.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
  }

  // MARK: - Stay Connected in Background

  /// Dart side: `lib/services/platform/background_connectivity.dart`.
  ///
  /// iOS gives no way to simply keep running, so this does the two things it
  /// does allow. The Bluetooth mesh continues on its own under the
  /// `bluetooth-central` / `bluetooth-peripheral` background modes declared in
  /// Info.plist — CoreBluetooth wakes the app for its events. The rest of the
  /// app, relay sockets included, is held out of suspension by an open
  /// background task for as long as the system is willing to grant, instead of
  /// being suspended the instant the app leaves the screen.
  private func registerBackgroundConnectivityChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/background_connectivity",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "start":
        self.keepAliveRequested = true
        self.beginBackgroundTask()
        result(self.backgroundTaskID != .invalid)
      case "stop":
        self.keepAliveRequested = false
        self.endBackgroundTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginBackgroundTask() {
    // Replace any task already open so we never leak identifiers across
    // successive background transitions.
    endBackgroundTask()
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(
      withName: "app.nymchat.background-connectivity"
    ) { [weak self] in
      guard let self = self else { return }
      // The OS is reclaiming this window. Ending the task is mandatory (the app
      // is killed otherwise); re-requesting one keeps the connections alive for
      // another window while the system still grants them.
      let stillWanted = self.keepAliveRequested
      self.endBackgroundTask()
      if stillWanted {
        self.beginBackgroundTask()
      }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTaskID != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskID)
    backgroundTaskID = .invalid
  }
}
