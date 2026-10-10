import AVFoundation
import BackgroundTasks
import CallKit
import Flutter
import PushKit
import LocalAuthentication
import Security
import Speech
import UIKit
import UniformTypeIdentifiers
import UserNotifications
#if canImport(WebRTC) && canImport(flutter_webrtc)
import WebRTC
import flutter_webrtc
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Open `beginBackgroundTask` identifier for "Stay Connected in Background".
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  /// Channel the background-refresh window calls into Dart on.
  private var backgroundRefreshChannel: FlutterMethodChannel?
  private var heartbeatChannel: FlutterMethodChannel?
  private var shareChannel: FlutterMethodChannel?
  private var pendingShares: [[String: Any]] = []
  private var shareListening = false
  private let shareQueue = DispatchQueue(label: "app.nymchat.share-inbox")
  private var privacyChannel: FlutterMethodChannel?
  private var privacyEnabled = false
  private var privacyCover: UIView?
  private var channelMessenger: FlutterBinaryMessenger?
  private var headlessEngine: FlutterEngine?
  private var headlessChannel: FlutterMethodChannel?
  private var headlessWaiters: [(UIBackgroundFetchResult) -> Void] = []
  private var headlessRun = 0
  private var callChannel: FlutterMethodChannel?
  private var ringEngine: FlutterEngine?
  private var ringChannel: FlutterMethodChannel?
  private var ringPendingChecks: [UUID] = []
  private var voipRegistry: PKPushRegistry?
  private var pushCallUUID: UUID?
  private var callUUIDs: [String: UUID] = [:]
  private var answeredCalls: Set<UUID> = []
  private var callOnRingEngine: Set<UUID> = []
  private var videoCalls: Set<UUID> = []
  private var notificationPluginsReady = false
  private var heldNotificationTap: (
    center: UNUserNotificationCenter, response: UNNotificationResponse, done: () -> Void
  )?
  private lazy var shareLinks = ShareLinks { [weak self] in self?.drainShareInbox() }
  private lazy var callProvider: CXProvider = {
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = false
    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    return provider
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    excludeMessageStoreFromBackup()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(shareInboxMayHaveChanged),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(privacyWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(privacyDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(privacyCaptureChanged),
      name: UIScreen.capturedDidChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(uiSceneDidDisconnect),
      name: UIScene.didDisconnectNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(uiSceneDidActivate),
      name: UIScene.didActivateNotification,
      object: nil
    )
    drainShareInbox()
    // Must happen before launch finishes, or BGTaskScheduler throws.
    registerBackgroundRefreshTask()
    if Self.ringEnabled() {
      startVoipRegistry()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    endHeadlessRefresh(headlessRun, .failed)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    releaseHeldNotificationTap()
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NymchatChannels") else { return }
    channelMessenger = registrar.messenger()
    shareListening = false
    registrar.addSceneDelegate(shareLinks)
    registerBackgroundConnectivityChannel()
    registerBackgroundRefreshChannel()
    registerHeartbeatChannel()
    registerAttestChannel()
    registerVaultKeyChannel()
    registerPasskeyBackupChannel()
    registerCloudKitBackupChannel()
    registerSecureChannel()
    registerBadgeChannel()
    registerPrivacyChannel()
    registerShareChannel()
    registerTranscribeChannel()
    registerCallChannel()
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard notificationPluginsReady else {
      heldNotificationTap?.done()
      heldNotificationTap = (center, response, completionHandler)
      return
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  private func releaseHeldNotificationTap() {
    notificationPluginsReady = true
    guard let held = heldNotificationTap else { return }
    heldNotificationTap = nil
    super.userNotificationCenter(
      held.center, didReceive: held.response, withCompletionHandler: held.done)
  }

  @objc private func uiSceneDidActivate(_ notification: Notification) {
    releaseHeldNotificationTap()
  }

  @objc private func uiSceneDidDisconnect(_ notification: Notification) {
    notificationPluginsReady = false
    channelMessenger = nil
    backgroundRefreshChannel = nil
    heartbeatChannel = nil
    shareChannel = nil
    shareListening = false
    privacyChannel = nil
    callChannel = nil
    hidePrivacyCover()
  }

  private var sceneWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
    }
    return scenes.first?.windows.first
  }

  /// The sqflite message store (and WAL/SHM) must not ride iCloud or device backups; re-applied every launch.
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

  private func registerVaultKeyChannel(on target: FlutterBinaryMessenger? = nil) {
    guard let messenger = target ?? channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/vault_key",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      VaultKey.handle(call, result: result)
    }
  }

  private func registerTranscribeChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/transcribe",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      Transcriber.handle(call, result: result)
    }
  }

  private func registerSecureChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/secure",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "copySecret" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let text = args["text"] as? String
      else {
        result(false)
        return
      }
      UIPasteboard.general.setItems(
        [[UTType.plainText.identifier: text]],
        options: [
          .localOnly: true,
          .expirationDate: Date().addingTimeInterval(60),
        ]
      )
      result(true)
    }
  }

  private func registerBadgeChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/badge",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "set" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      let count = max(0, (args?["count"] as? Int) ?? 0)
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
      } else {
        UIApplication.shared.applicationIconBadgeNumber = count
      }
      result(true)
    }
  }

  private func registerPrivacyChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/privacy",
      binaryMessenger: messenger
    )
    privacyChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "configure":
        let args = call.arguments as? [String: Any]
        self.privacyEnabled = (args?["secure"] as? Bool) ?? false
        if !self.privacyEnabled {
          self.hidePrivacyCover()
        } else if self.isScreenCaptured() {
          self.showPrivacyCover()
        }
        result(nil)
      case "isCaptured":
        result(self.isScreenCaptured())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func isScreenCaptured() -> Bool {
    if let screen = sceneWindow?.windowScene?.screen {
      return screen.isCaptured
    }
    return UIScreen.main.isCaptured
  }

  @objc private func privacyWillResignActive() {
    if privacyEnabled {
      showPrivacyCover()
    }
  }

  @objc private func privacyDidBecomeActive() {
    if !(privacyEnabled && isScreenCaptured()) {
      hidePrivacyCover()
    }
  }

  @objc private func privacyCaptureChanged() {
    let captured = isScreenCaptured()
    privacyChannel?.invokeMethod("captured", arguments: captured)
    if captured && privacyEnabled {
      showPrivacyCover()
    } else if !captured && UIApplication.shared.applicationState == .active {
      hidePrivacyCover()
    }
  }

  private func showPrivacyCover() {
    guard privacyCover == nil, let window = sceneWindow else { return }
    let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    cover.frame = window.bounds
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    let shade = UIView(frame: cover.bounds)
    shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    shade.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    cover.contentView.addSubview(shade)
    window.addSubview(cover)
    privacyCover = cover
  }

  private func hidePrivacyCover() {
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }

  private func registerShareChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/share",
      binaryMessenger: messenger
    )
    shareChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "initial" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result([Any]())
        return
      }
      self.drainShareInbox {
        let held = self.pendingShares
        self.pendingShares.removeAll()
        self.shareListening = true
        result(held)
      }
    }
  }

  @objc private func shareInboxMayHaveChanged() {
    drainShareInbox()
  }

  private func drainShareInbox(then done: (() -> Void)? = nil) {
    shareQueue.async { [weak self] in
      let payloads = ShareInbox.drain()
      DispatchQueue.main.async {
        guard let self = self else { return }
        for payload in payloads {
          self.deliverShare(payload)
        }
        done?()
      }
    }
  }

  private func deliverShare(_ payload: [String: Any]) {
    if shareListening, let channel = shareChannel {
      channel.invokeMethod("incoming", arguments: payload)
    } else {
      pendingShares.append(payload)
    }
  }

  private func registerCloudKitBackupChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/cloudkit_backup",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      CloudKitBackup.handle(call, result: result)
    }
  }

  private func registerPasskeyBackupChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/passkey_backup",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      PasskeyBackup.handle(call, result: result)
    }
  }

  /// App Attest key id and attestation for the server's challenge, or nil when the device can't attest.
  private func registerAttestChannel(on target: FlutterBinaryMessenger? = nil) {
    guard let messenger = target ?? channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/attest",
      binaryMessenger: messenger
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

  /// Holds a background task as long as iOS allows; the BLE mesh uses its own background modes.
  private func registerBackgroundConnectivityChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/background_connectivity",
      binaryMessenger: messenger
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
    // Replace any open task so identifiers never leak across transitions.
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

  /// BGAppRefresh catch-up window for Dart; APNs sends only a content-free heartbeat.
  private func registerBackgroundRefreshChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/background_refresh",
      binaryMessenger: messenger
    )
    backgroundRefreshChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleRefreshCall(call, result: result)
    }
  }

  private func handleRefreshCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "schedule":
      let args = call.arguments as? [String: Any]
      let earliest = (args?["earliestSeconds"] as? NSNumber)?.doubleValue ?? 15 * 60
      scheduleBackgroundRefresh(earliest: earliest)
      result(nil)
    case "cancel":
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
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
    // Queue the next window first, or an early return below would end the chain.
    scheduleBackgroundRefresh(earliest: Self.refreshInterval)

    let finish = runDartRefresh { outcome in
      task.setTaskCompleted(success: outcome != .failed)
    }
    // iOS kills an overrunning task, so both the deadline and a self-imposed cap end the window.
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
    if channelMessenger == nil {
      let end = startHeadlessRefresh(finish)
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshBudget) {
        end(.failed)
      }
      return end
    }
    if backgroundRefreshChannel == nil {
      registerBackgroundRefreshChannel()
    }
    guard let channel = backgroundRefreshChannel else {
      finish(.failed)
      return finish
    }
    channel.invokeMethod("runRefresh", arguments: nil) { result in
      finish(Self.refreshOutcome(result))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshBudget) {
      finish(.failed)
    }
    return finish
  }

  private static func refreshOutcome(_ result: Any?) -> UIBackgroundFetchResult {
    if result is FlutterError || (result as? NSObject) === FlutterMethodNotImplemented {
      return .failed
    }
    return (result as? Bool) == true ? .newData : .noData
  }

  private func startHeadlessRefresh(
    _ done: @escaping (UIBackgroundFetchResult) -> Void
  ) -> (UIBackgroundFetchResult) -> Void {
    headlessWaiters.append(done)
    if headlessEngine == nil {
      headlessRun += 1
    }
    let run = headlessRun
    let end: (UIBackgroundFetchResult) -> Void = { [weak self] outcome in
      DispatchQueue.main.async { self?.endHeadlessRefresh(run, outcome) }
    }
    guard headlessEngine == nil else { return end }
    let engine = FlutterEngine(name: "nym_background", project: nil, allowHeadlessExecution: true)
    headlessEngine = engine
    guard engine.run(withEntrypoint: "backgroundRefreshMain", libraryURI: nil) else {
      end(.failed)
      return end
    }
    GeneratedPluginRegistrant.register(with: engine)
    let messenger = engine.binaryMessenger
    registerVaultKeyChannel(on: messenger)
    registerAttestChannel(on: messenger)
    let channel = FlutterMethodChannel(
      name: "app.nymchat/background_refresh",
      binaryMessenger: messenger
    )
    headlessChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready" else {
        self?.handleRefreshCall(call, result: result)
        return
      }
      result(nil)
      self?.headlessChannel?.invokeMethod("runRefresh", arguments: nil) { reply in
        end(Self.refreshOutcome(reply))
      }
    }
    return end
  }

  private func endHeadlessRefresh(_ run: Int, _ outcome: UIBackgroundFetchResult) {
    guard run == headlessRun, let engine = headlessEngine else { return }
    let waiters = headlessWaiters
    headlessWaiters = []
    headlessChannel?.setMethodCallHandler(nil)
    headlessChannel = nil
    headlessEngine = nil
    engine.destroyContext()
    for waiter in waiters {
      waiter(outcome)
    }
  }

  private func scheduleBackgroundRefresh(earliest: TimeInterval) {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: max(earliest, 60))
    // Only one pending request per identifier is allowed; submitting over one throws.
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Background App Refresh is off or unavailable; the app catches up on resume.
      NSLog("[BackgroundRefresh] submit failed: \(error.localizedDescription)")
    }
  }

  private func registerHeartbeatChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(
      name: "app.nymchat/heartbeat",
      binaryMessenger: messenger
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

enum ShareInbox {
  private static let group = "group.com.nym.bar"
  private static let folder = "ShareInbox"
  private static let manifestName = "manifest.json"
  private static let maxFiles = 10
  private static let maxFileBytes = 16 * 1024 * 1024
  private static let maxTotalBytes = 64 * 1024 * 1024
  private static let staleAfter: TimeInterval = 60 * 60

  static func drain() -> [[String: Any]] {
    let manager = FileManager.default
    guard
      let root = manager.containerURL(forSecurityApplicationGroupIdentifier: group)?
        .appendingPathComponent(folder, isDirectory: true),
      let entries = try? manager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    var found: [(created: Double, payload: [String: Any])] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
      guard values?.isDirectory == true else {
        try? manager.removeItem(at: entry)
        continue
      }
      guard let data = try? Data(contentsOf: entry.appendingPathComponent(manifestName)) else {
        let created = values?.creationDate ?? .distantPast
        if created.timeIntervalSinceNow < -staleAfter {
          try? manager.removeItem(at: entry)
        }
        continue
      }
      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let payload = manifest.flatMap { decode($0, in: entry) }
      try? manager.removeItem(at: entry)
      if let payload = payload {
        let created = (manifest?["created"] as? NSNumber)?.doubleValue ?? 0
        found.append((created, payload))
      }
    }
    return found.sorted { $0.created < $1.created }.map { $0.payload }
  }

  private static func decode(_ manifest: [String: Any], in folder: URL) -> [String: Any]? {
    var payload: [String: Any] = [:]
    if let text = manifest["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      payload["text"] = text
    }
    var files: [[String: Any]] = []
    var total = 0
    for entry in (manifest["files"] as? [[String: Any]] ?? []).prefix(maxFiles) {
      guard let stored = entry["file"] as? String, isStoredName(stored) else { continue }
      let url = folder.appendingPathComponent(stored, isDirectory: false)
      guard
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true,
        let size = values.fileSize,
        size > 0,
        size <= maxFileBytes
      else { continue }
      if total + size > maxTotalBytes { break }
      guard let bytes = try? Data(contentsOf: url), bytes.count == size else { continue }
      total += size
      files.append([
        "name": safeName(entry["name"] as? String ?? ""),
        "mime": (entry["mime"] as? String).map { $0 as Any } ?? NSNull(),
        "bytes": FlutterStandardTypedData(bytes: bytes),
      ])
    }
    guard payload["text"] != nil || !files.isEmpty else { return nil }
    payload["files"] = files
    return payload
  }

  private static func isStoredName(_ name: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    return !name.isEmpty && name.count <= 64
      && name.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  private static func safeName(_ raw: String) -> String {
    let base = raw.replacingOccurrences(of: "\\", with: "/")
      .components(separatedBy: "/").last ?? ""
    let banned = CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)
    let underscore: Unicode.Scalar = "_"
    var scalars = String.UnicodeScalarView()
    for scalar in base.unicodeScalars {
      scalars.append(banned.contains(scalar) ? underscore : scalar)
    }
    var clean = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    while clean.hasPrefix(".") {
      clean.removeFirst()
    }
    if clean.isEmpty { return "shared" }
    return clean.count > 120 ? String(clean.suffix(120)) : clean
  }
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
    case "biometryType":
      result(biometryType())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func biometryType() -> String {
    let context = LAContext()
    var error: NSError?
    if !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
      error?.code == LAError.biometryNotEnrolled.rawValue
    {
      return "none"
    }
    if context.biometryType == .faceID { return "faceID" }
    if context.biometryType == .touchID { return "touchID" }
    if #available(iOS 17.0, *), context.biometryType == .opticID { return "opticID" }
    return "none"
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

enum Transcriber {
  private static var task: SFSpeechRecognitionTask?

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let lang = args["lang"] as? String ?? Locale.current.identifier
    switch call.method {
    case "availability":
      result(availability(lang))
    case "install":
      result(false)
    case "transcribe":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path missing", details: nil))
        return
      }
      authorize { granted in
        guard granted else {
          result(FlutterError(code: "denied", message: nil, details: nil))
          return
        }
        transcribe(path: path, lang: lang, result: result)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func availability(_ lang: String) -> [String: String] {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .denied || status == .restricted {
      return ["status": "unavailable", "reason": "denied"]
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)) else {
      return ["status": "unavailable", "reason": "no_model"]
    }
    if !recognizer.supportsOnDeviceRecognition {
      return ["status": "unavailable", "reason": "no_model"]
    }
    return ["status": "available"]
  }

  private static func authorize(_ done: @escaping (Bool) -> Void) {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .authorized {
      done(true)
      return
    }
    if status != .notDetermined {
      done(false)
      return
    }
    SFSpeechRecognizer.requestAuthorization { next in
      DispatchQueue.main.async { done(next == .authorized) }
    }
  }

  private static func transcribe(path: String, lang: String, result: @escaping FlutterResult) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)),
          recognizer.supportsOnDeviceRecognition else {
      result(FlutterError(code: "no_model", message: nil, details: nil))
      return
    }
    let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    task?.cancel()
    var finished = false
    func finish(_ value: Any?) {
      DispatchQueue.main.async {
        if finished { return }
        finished = true
        task = nil
        result(value)
      }
    }
    task = recognizer.recognitionTask(with: request) { res, error in
      if let res = res, res.isFinal {
        finish(res.bestTranscription.formattedString)
        return
      }
      if let error = error as NSError? {
        if error.domain == "kAFAssistantErrorDomain" && (error.code == 1110 || error.code == 203) {
          finish("")
        } else {
          finish(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

class SceneDelegate: FlutterSceneDelegate {}

final class ShareLinks: NSObject, FlutterSceneLifeCycleDelegate {
  private let onShare: () -> Void

  init(onShare: @escaping () -> Void) {
    self.onShare = onShare
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let options = connectionOptions else { return false }
    return take(options.urlContexts)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return take(URLContexts)
  }

  private func take(_ contexts: Set<UIOpenURLContext>) -> Bool {
    guard contexts.contains(where: { Self.isShare($0.url) }) else { return false }
    onShare()
    return true
  }

  static func isShare(_ url: URL) -> Bool {
    return url.scheme?.lowercased() == "nymchat" && url.host?.lowercased() == "share"
  }
}

extension AppDelegate: CXProviderDelegate, PKPushRegistryDelegate {
  private static let ringWakeKey = "flutter.nym_ring_wake"
  private static let ringCheckTimeout: TimeInterval = 25

  static func ringEnabled() -> Bool {
    guard let wake = UserDefaults.standard.string(forKey: ringWakeKey) else { return false }
    return !wake.isEmpty
  }

  private static var pushEnv: String {
    #if DEBUG
      return "sandbox"
    #else
      return "production"
    #endif
  }

  func registerCallChannel() {
    guard let messenger = channelMessenger else { return }
    let channel = FlutterMethodChannel(name: "app.nymchat/call", binaryMessenger: messenger)
    callChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleCallMethod(call, result: result, fromRingEngine: false)
    }
  }

  private func handleCallMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult, fromRingEngine: Bool) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ready":
      result(nil)
      runPendingRingChecks()
    case "showIncoming":
      let callId = args["callId"] as? String ?? ""
      let name = args["name"] as? String ?? ""
      let video = args["video"] as? Bool ?? false
      showIncoming(callId: callId, name: name, video: video, fromRingEngine: fromRingEngine)
      result(nil)
    case "endIncoming":
      let callId = args["callId"] as? String ?? ""
      let answered = args["answered"] as? Bool ?? false
      if let uuid = callUUIDs[callId], !(answered && answeredCalls.contains(uuid)) {
        endCall(uuid, reason: answered ? .answeredElsewhere : .unanswered)
      }
      result(nil)
    case "stopOngoing":
      for uuid in answeredCalls {
        endCall(uuid, reason: .remoteEnded)
      }
      result(nil)
    case "startOngoing":
      result(nil)
    case "ringSupported":
      result(true)
    case "ringEnable":
      startVoipRegistry()
      if let token = voipRegistry?.pushToken(for: .voIP) {
        sendVoipToken(token)
      }
      result(true)
    case "ringDisable":
      voipRegistry?.desiredPushTypes = []
      voipRegistry = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startVoipRegistry() {
    if voipRegistry != nil { return }
    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  private func sendVoipToken(_ token: Data) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    callChannel?.invokeMethod("ringToken", arguments: ["platform": "apns", "token": hex, "env": Self.pushEnv])
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    sendVoipToken(pushCredentials.token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    let uuid = UUID()
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: "Nymchat")
    update.localizedCallerName = "Nymchat"
    update.hasVideo = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false
    update.supportsDTMF = false
    if let pending = pushCallUUID {
      endCall(pending, reason: .failed)
    }
    pushCallUUID = uuid
    callProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      if error != nil {
        if self?.pushCallUUID == uuid { self?.pushCallUUID = nil }
      } else {
        self?.ringCheck(uuid)
      }
      completion()
    }
  }

  private func ringCheck(_ uuid: UUID) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringCheckTimeout) { [weak self] in
      guard let self = self, self.pushCallUUID == uuid else { return }
      self.endCall(uuid, reason: .failed)
    }
    if let channel = callChannel {
      channel.invokeMethod("ringCheck", arguments: nil) { [weak self] reply in
        self?.onRingCheck(uuid, reply: reply, fromRingEngine: false)
      }
      return
    }
    ringPendingChecks.append(uuid)
    startRingEngine()
  }

  private func startRingEngine() {
    if ringEngine != nil {
      runPendingRingChecks()
      return
    }
    let engine = FlutterEngine(name: "nym_ring", project: nil, allowHeadlessExecution: true)
    guard engine.run(withEntrypoint: "ringMain", libraryURI: nil) else {
      for uuid in ringPendingChecks { endCall(uuid, reason: .failed) }
      ringPendingChecks = []
      return
    }
    ringEngine = engine
    GeneratedPluginRegistrant.register(with: engine)
    let messenger = engine.binaryMessenger
    registerVaultKeyChannel(on: messenger)
    registerAttestChannel(on: messenger)
    let channel = FlutterMethodChannel(name: "app.nymchat/call", binaryMessenger: messenger)
    ringChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleCallMethod(call, result: result, fromRingEngine: true)
    }
  }

  private func runPendingRingChecks() {
    guard let channel = ringChannel else { return }
    let pending = ringPendingChecks
    ringPendingChecks = []
    for uuid in pending {
      channel.invokeMethod("ringCheck", arguments: nil) { [weak self] reply in
        self?.onRingCheck(uuid, reply: reply, fromRingEngine: true)
      }
    }
  }

  private func onRingCheck(_ uuid: UUID, reply: Any?, fromRingEngine: Bool) {
    guard let info = reply as? [String: Any], let callId = info["callId"] as? String, !callId.isEmpty else {
      if pushCallUUID == uuid { endCall(uuid, reason: .failed) }
      return
    }
    if callUUIDs[callId] == nil, pushCallUUID == uuid {
      showIncoming(
        callId: callId,
        name: info["name"] as? String ?? "",
        video: info["video"] as? Bool ?? false,
        fromRingEngine: fromRingEngine
      )
    }
  }

  private func showIncoming(callId: String, name: String, video: Bool, fromRingEngine: Bool) {
    guard !callId.isEmpty, callUUIDs[callId] == nil else { return }
    if !fromRingEngine && pushCallUUID == nil && UIApplication.shared.applicationState == .active {
      return
    }
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: name.isEmpty ? "Nymchat" : name)
    update.localizedCallerName = name.isEmpty ? "Nymchat" : name
    update.hasVideo = video
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false
    update.supportsDTMF = false
    if let pending = pushCallUUID {
      pushCallUUID = nil
      callUUIDs[callId] = pending
      if fromRingEngine { callOnRingEngine.insert(pending) }
      if video { videoCalls.insert(pending) }
      callProvider.reportCall(with: pending, updated: update)
      return
    }
    let uuid = UUID()
    callUUIDs[callId] = uuid
    if fromRingEngine { callOnRingEngine.insert(uuid) }
    if video { videoCalls.insert(uuid) }
    callProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      if error != nil { self?.forget(uuid) }
    }
  }

  private func callId(for uuid: UUID) -> String? {
    return callUUIDs.first(where: { $0.value == uuid })?.key
  }

  private func channel(for uuid: UUID) -> FlutterMethodChannel? {
    return callOnRingEngine.contains(uuid) ? ringChannel : callChannel
  }

  private func forget(_ uuid: UUID) {
    if let id = callId(for: uuid) { callUUIDs.removeValue(forKey: id) }
    answeredCalls.remove(uuid)
    callOnRingEngine.remove(uuid)
    videoCalls.remove(uuid)
    if pushCallUUID == uuid { pushCallUUID = nil }
    if callUUIDs.isEmpty && pushCallUUID == nil && ringPendingChecks.isEmpty {
      stopRingEngine()
    }
  }

  private func stopRingEngine() {
    guard let engine = ringEngine else { return }
    ringChannel?.setMethodCallHandler(nil)
    ringChannel = nil
    ringEngine = nil
    engine.destroyContext()
  }

  private func endCall(_ uuid: UUID, reason: CXCallEndedReason) {
    callProvider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    forget(uuid)
  }

  func providerDidReset(_ provider: CXProvider) {
    for uuid in Array(callUUIDs.values) { forget(uuid) }
    if let pending = pushCallUUID { forget(pending) }
    CallKitAudio.release()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    CallKitAudio.activate(audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    CallKitAudio.deactivate(audioSession)
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let id = callId(for: action.callUUID) else {
      action.fail()
      return
    }
    answeredCalls.insert(action.callUUID)
    CallKitAudio.prepare(video: videoCalls.contains(action.callUUID))
    channel(for: action.callUUID)?.invokeMethod("answer", arguments: ["callId": id])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let uuid = action.callUUID
    if let id = callId(for: uuid) {
      let method = answeredCalls.contains(uuid) ? "hangup" : "decline"
      channel(for: uuid)?.invokeMethod(method, arguments: ["callId": id])
    }
    forget(uuid)
    CallKitAudio.release()
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    channel(for: action.callUUID)?.invokeMethod("mute", arguments: ["muted": action.isMuted])
    action.fulfill()
  }
}

enum CallKitAudio {
  static func prepare(video: Bool) {
    let mode: AVAudioSession.Mode = video ? .videoChat : .voiceChat
    let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    #if canImport(WebRTC) && canImport(flutter_webrtc)
      let rtc = RTCAudioSession.sharedInstance()
      rtc.lockForConfiguration()
      try? rtc.setCategory(.playAndRecord, mode: mode, options: options)
      rtc.unlockForConfiguration()
      setEngine(available: false)
    #else
      try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: mode, options: options)
    #endif
  }

  static func activate(_ session: AVAudioSession) {
    #if canImport(WebRTC) && canImport(flutter_webrtc)
      let rtc = RTCAudioSession.sharedInstance()
      rtc.audioSessionDidActivate(session)
      rtc.isAudioEnabled = true
      if audioDeviceModule()?.isEngineRunning == true {
        setEngine(available: false)
      }
      setEngine(available: true)
    #endif
  }

  static func deactivate(_ session: AVAudioSession) {
    #if canImport(WebRTC) && canImport(flutter_webrtc)
      let rtc = RTCAudioSession.sharedInstance()
      rtc.audioSessionDidDeactivate(session)
      rtc.isAudioEnabled = false
    #endif
    release()
  }

  static func release() {
    #if canImport(WebRTC) && canImport(flutter_webrtc)
      setEngine(available: true)
    #endif
  }

  #if canImport(WebRTC) && canImport(flutter_webrtc)
    private static func audioDeviceModule() -> RTCAudioDeviceModule? {
      return FlutterWebRTCPlugin.sharedSingleton()?.peerConnectionFactory?.audioDeviceModule
    }

    private static func setEngine(available: Bool) {
      guard let adm = FlutterWebRTCPlugin.sharedSingleton()?.peerConnectionFactory?.audioDeviceModule else { return }
      let flag = ObjCBool(available)
      _ = adm.setEngineAvailability(RTCAudioEngineAvailability(isInputAvailable: flag, isOutputAvailable: flag))
    }
  #endif
}
