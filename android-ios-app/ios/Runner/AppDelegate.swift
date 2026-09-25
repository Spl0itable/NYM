import BackgroundTasks
import Flutter
import LocalAuthentication
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Open `beginBackgroundTask` identifier for "Stay Connected in Background".
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  /// Channel the background-refresh window calls into Dart on.
  private var backgroundRefreshChannel: FlutterMethodChannel?
  private var heartbeatChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    excludeMessageStoreFromBackup()
    registerBackgroundConnectivityChannel()
    registerBackgroundRefreshChannel()
    registerHeartbeatChannel()
    registerAttestChannel()
    registerVaultKeyChannel()
    registerPasskeyBackupChannel()
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

  private func registerVaultKeyChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/vault_key",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      VaultKey.handle(call, result: result)
    }
  }

  private func registerPasskeyBackupChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/passkey_backup",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      PasskeyBackup.handle(call, result: result)
    }
  }

  // MARK: - App attestation

  /// Dart side: `lib/services/attest/attest_service.dart`.
  ///
  /// Hands back an App Attest key id and attestation object for the server's
  /// challenge, or nil on a device that cannot attest — which Dart reads as
  /// "no proof" and enrolls nothing.
  private func registerAttestChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/attest",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "attest" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let challenge = args["challenge"] as? String,
        !challenge.isEmpty
      else {
        result(nil)
        return
      }
      AppAttest.attest(challenge: challenge) { payload in
        DispatchQueue.main.async { result(payload) }
      }
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
        self.beginBackgroundTask()
        result(self.backgroundTaskID != .invalid)
      case "stop":
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
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTaskID != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskID)
    backgroundTaskID = .invalid
  }

  // MARK: - Background catch-up (BGAppRefresh)

  /// iOS will not wake a suspended app for network data without APNs, and
  /// Nymchat's only APNs use is a content-free heartbeat sent to every device
  /// alike — a push per message would tell the provider who is messaging whom.
  /// `BGAppRefresh` is the other wake the system offers: a short run at a
  /// time of its choosing, which Dart uses to pull what arrived and raise
  /// notifications for it. Minutes-to-hours late, never
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
      using: DispatchQueue.main
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

    let finish = runDartRefresh { outcome in
      task.setTaskCompleted(success: outcome != .failed)
    }
    // iOS kills the app if a task overruns, so both the OS deadline and a
    // self-imposed cap end the window even if Dart never answers.
    task.expirationHandler = { finish(.failed) }
  }

  @discardableResult
  private func runDartRefresh(
    _ done: @escaping (UIBackgroundFetchResult) -> Void
  ) -> (UIBackgroundFetchResult) -> Void {
    var completed = false
    let finish: (UIBackgroundFetchResult) -> Void = { outcome in
      DispatchQueue.main.async {
        guard !completed else { return }
        completed = true
        done(outcome)
      }
    }
    if backgroundRefreshChannel == nil {
      registerBackgroundRefreshChannel()
    }
    guard let channel = backgroundRefreshChannel else {
      finish(.failed)
      return finish
    }
    channel.invokeMethod("runRefresh", arguments: nil) { result in
      if result is FlutterError || (result as? NSObject) === FlutterMethodNotImplemented {
        finish(.failed)
      } else {
        finish((result as? Bool) == true ? .newData : .noData)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshBudget) {
      finish(.failed)
    }
    return finish
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

  private func registerHeartbeatChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/heartbeat",
      binaryMessenger: controller.binaryMessenger
    )
    heartbeatChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "register":
        UIApplication.shared.registerForRemoteNotifications()
        result(nil)
      case "unregister":
        UIApplication.shared.unregisterForRemoteNotifications()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    heartbeatChannel?.invokeMethod("token", arguments: hex)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    heartbeatChannel?.invokeMethod("registrationFailed", arguments: error.localizedDescription)
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard application.applicationState != .active else {
      completionHandler(.noData)
      return
    }
    runDartRefresh(completionHandler)
  }

  /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
  private static let refreshTaskIdentifier = "app.nymchat.refresh"
  private static let refreshInterval: TimeInterval = 15 * 60
  private static let refreshBudget: TimeInterval = 25
}

enum VaultKey {
  private static let base: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.nymchat.vault",
    kSecAttrAccount as String: "vault_key",
  ]

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    switch call.method {
    case "store":
      guard let secret = args["secret"] as? String, let data = secret.data(using: .utf8) else {
        result(FlutterError(code: "failed", message: nil, details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async { reply(store(data)) }
    case "load":
      let title = args["title"] as? String ?? ""
      let cancel = args["cancel"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async { reply(load(title, cancel)) }
    case "erase":
      DispatchQueue.global(qos: .userInitiated).async {
        SecItemDelete(base as CFDictionary)
        reply(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func store(_ data: Data) -> Any? {
    SecItemDelete(base as CFDictionary)
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
    else {
      return FlutterError(code: "unavailable", message: nil, details: nil)
    }
    var query = base
    query[kSecAttrAccessControl as String] = access
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecSuccess { return nil }
    return failure(status)
  }

  private static func load(_ title: String, _ cancel: String) -> Any? {
    let context = LAContext()
    context.localizedReason = title
    context.localizedCancelTitle = cancel
    context.localizedFallbackTitle = ""
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { return failure(status) }
    guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
      return FlutterError(code: "failed", message: nil, details: nil)
    }
    return secret
  }

  private static func failure(_ status: OSStatus) -> FlutterError {
    let message = SecCopyErrorMessageString(status, nil) as String?
    switch status {
    case errSecUserCanceled:
      return FlutterError(code: "cancelled", message: message, details: nil)
    case errSecNotAvailable, errSecInteractionNotAllowed:
      return FlutterError(code: "unavailable", message: message, details: nil)
    default:
      return FlutterError(code: "failed", message: message, details: nil)
    }
  }
}
