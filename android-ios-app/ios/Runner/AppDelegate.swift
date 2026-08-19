import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    excludeMessageStoreFromBackup()
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
}
