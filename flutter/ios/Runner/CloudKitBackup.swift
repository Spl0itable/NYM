import CloudKit
import Flutter

enum CloudKitBackup {
  private enum Failure: Error {
    case code(String)
  }

  private static let fields: [CKRecord.FieldKey] = ["payload", "format", "updatedAt"]
  private static let maxPages = 20

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let identifier = args["container"] as? String,
      !identifier.isEmpty
    else {
      result(FlutterError(code: "bad_args", message: nil, details: nil))
      return
    }
    let container = CKContainer(identifier: identifier)
    Task {
      let reply: Any?
      do {
        switch call.method {
        case "accountId":
          reply = try await accountId(container)
        case "list":
          reply = try await list(container.privateCloudDatabase, string(args, "recordType"))
        case "save":
          try await save(
            container.privateCloudDatabase,
            type: string(args, "recordType"),
            name: string(args, "recordName"),
            payload: string(args, "payload"),
            format: string(args, "format")
          )
          reply = nil
        case "delete":
          try await delete(container.privateCloudDatabase, name: string(args, "recordName"))
          reply = nil
        default:
          reply = FlutterMethodNotImplemented
        }
      } catch {
        reply = flutterError(error)
      }
      await MainActor.run { result(reply) }
    }
  }

  private static func string(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.isEmpty else { throw Failure.code("bad_args") }
    return value
  }

  private static func accountId(_ container: CKContainer) async throws -> String {
    switch try await container.accountStatus() {
    case .available:
      return try await container.userRecordID().recordName
    case .noAccount:
      throw Failure.code("no_account")
    case .restricted:
      throw Failure.code("restricted")
    default:
      throw Failure.code("unavailable")
    }
  }

  private static func list(_ db: CKDatabase, _ type: String) async throws -> [[String: Any]] {
    let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
    query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
    var out: [[String: Any]] = []
    var page = try await db.records(matching: query, desiredKeys: fields)
    var pages = 1
    while true {
      for (_, match) in page.matchResults {
        guard case .success(let record) = match, let payload = record["payload"] as? String else { continue }
        let at = (record["updatedAt"] as? Date) ?? record.modificationDate ?? Date(timeIntervalSince1970: 0)
        out.append([
          "recordName": record.recordID.recordName,
          "payload": payload,
          "updatedAt": Int(at.timeIntervalSince1970 * 1000),
        ])
      }
      guard let cursor = page.queryCursor, pages < maxPages else { break }
      page = try await db.records(continuingMatchFrom: cursor, desiredKeys: fields)
      pages += 1
    }
    return out
  }

  private static func save(
    _ db: CKDatabase, type: String, name: String, payload: String, format: String
  ) async throws {
    let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
    record["payload"] = payload as CKRecordValue
    record["format"] = format as CKRecordValue
    record["updatedAt"] = Date() as CKRecordValue
    _ = try await db.save(record)
  }

  private static func delete(_ db: CKDatabase, name: String) async throws {
    do {
      _ = try await db.deleteRecord(withID: CKRecord.ID(recordName: name))
    } catch let error as CKError where error.code == .unknownItem {
      return
    }
  }

  private static func flutterError(_ error: Error) -> FlutterError {
    if case Failure.code(let code) = error {
      return FlutterError(code: code, message: nil, details: nil)
    }
    guard let ck = error as? CKError else {
      return FlutterError(code: "cloudkit", message: error.localizedDescription, details: nil)
    }
    let code: String
    switch ck.code {
    case .notAuthenticated:
      code = "not_authenticated"
    case .quotaExceeded:
      code = "quota"
    case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
      code = "network"
    default:
      code = "cloudkit"
    }
    return FlutterError(code: code, message: ck.localizedDescription, details: ck.code.rawValue)
  }
}
