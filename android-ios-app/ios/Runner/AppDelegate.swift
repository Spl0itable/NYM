import BackgroundTasks
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Open `beginBackgroundTask` identifier for "Stay Connected in Background".
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  /// Whether Dart still wants the keep-alive. Kept separate from the task id so
  /// an expiring task can be renewed only while the setting is actually on.
  private var keepAliveRequested = false

  /// Channel the background-refresh window calls into Dart on.
  private var backgroundRefreshChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    excludeMessageStoreFromBackup()
    registerBackgroundConnectivityChannel()
    registerBackgroundRefreshChannel()
    // Must happen before launch finishes, or BGTaskScheduler throws.
    registerBackgroundRefreshTask()
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

  // MARK: - Background catch-up (BGAppRefresh)

  /// iOS will not wake a suspended app for network data without APNs, and
  /// Nymchat has no APNs registration on purpose — a push provider would learn
  /// who is messaging whom. `BGAppRefresh` is the alternative the system does
  /// offer: a short run at a time of its choosing, which Dart uses to pull what
  /// arrived and raise notifications for it. Minutes-to-hours late, never
  /// real-time, and entirely at the scheduler's discretion.
  private func registerBackgroundRefreshChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/background_refresh",
      binaryMessenger: controller.binaryMessenger
    )
    backgroundRefreshChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "schedule":
        let args = call.arguments as? [String: Any]
        let earliest = (args?["earliestSeconds"] as? NSNumber)?.doubleValue ?? 15 * 60
        self?.scheduleBackgroundRefresh(earliest: earliest)
        result(nil)
      case "cancel":
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerBackgroundRefreshTask() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.refreshTaskIdentifier,
      using: nil
    ) { [weak self] task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.handleBackgroundRefresh(refreshTask)
    }
  }

  private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
    // Queue the next window first: a task request is consumed by firing, and an
    // early return below would otherwise end the chain permanently.
    scheduleBackgroundRefresh(earliest: Self.refreshInterval)

    var completed = false
    let finish: (Bool) -> Void = { success in
      guard !completed else { return }
      completed = true
      task.setTaskCompleted(success: success)
    }
    // iOS kills the app if a task overruns, so both the OS deadline and a
    // self-imposed cap end the window even if Dart never answers.
    task.expirationHandler = { finish(false) }
    guard let channel = backgroundRefreshChannel else {
      finish(false)
      return
    }
    channel.invokeMethod("runRefresh", arguments: nil) { _ in finish(true) }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshBudget) {
      finish(false)
    }
  }

  private func scheduleBackgroundRefresh(earliest: TimeInterval) {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: max(earliest, 60))
    // Replace rather than stack: only one pending request per identifier is
    // allowed, and submitting over an existing one throws.
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Background App Refresh switched off by the user, or the scheduler is
      // unavailable — nothing to recover, the app simply catches up on resume.
      NSLog("[BackgroundRefresh] submit failed: \(error.localizedDescription)")
    }
  }

  /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
  private static let refreshTaskIdentifier = "app.nymchat.refresh"
  private static let refreshInterval: TimeInterval = 15 * 60
  private static let refreshBudget: TimeInterval = 25
}
