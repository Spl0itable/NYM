import CoreNFC
import Flutter
import UIKit

final class NfcShare: NSObject {
  private static let shared = NfcShare()
  private static let maxRecords = 16

  private enum Job {
    case write(NFCNDEFMessage, Int)
    case lock(Data)
  }

  private var channel: FlutterMethodChannel?
  private var session: NFCNDEFReaderSession?
  private var pending: FlutterResult?
  private var done: String?
  private var timeout: DispatchWorkItem?
  private var readDelegate: ReadDelegate?
  private var tagDelegate: TagDelegate?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.nymchat/nfc", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result: result)
    }
    shared.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let alert = args["alert"] as? String ?? ""
    switch call.method {
    case "caps":
      let ok = NFCNDEFReaderSession.readingAvailable
      result([
        "nfc": ok, "enabled": ok, "hce": false, "read": ok, "write": ok, "systemUi": true,
      ])
    case "read":
      startRead(alert: alert, result: result)
    case "write":
      guard let payload = (args["payload"] as? FlutterStandardTypedData)?.data,
        let uri = args["uri"] as? String,
        let size = args["size"] as? Int
      else {
        result(["status": "failed"])
        return
      }
      let message = NFCNDEFMessage(records: [NfcShare.uriRecord(uri: uri, payload: payload)])
      startTags(.write(message, size), alert: alert, done: args["done"] as? String, result: result)
    case "lock":
      guard let payload = (args["payload"] as? FlutterStandardTypedData)?.data else {
        result(["status": "failed"])
        return
      }
      startTags(.lock(payload), alert: alert, done: args["done"] as? String, result: result)
    case "cancel":
      finish(nil)
      result(nil)
    case "arm":
      result(false)
    case "disarm", "openSettings":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func uriRecord(uri: String, payload: Data) -> NFCNDEFPayload {
    if let url = URL(string: uri),
      let built = NFCNDEFPayload.wellKnownTypeURIPayload(url: url),
      built.payload == payload
    {
      return built
    }
    return NFCNDEFPayload(
      format: .nfcWellKnown, type: Data([0x55]), identifier: Data(), payload: payload)
  }

  private func begin(_ s: NFCNDEFReaderSession, alert: String, result: @escaping FlutterResult) {
    pending = result
    session = s
    s.alertMessage = alert
    s.begin()
    let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
  }

  private func startRead(alert: String, result: @escaping FlutterResult) {
    finish(nil)
    guard NFCNDEFReaderSession.readingAvailable else {
      result(nil)
      return
    }
    done = nil
    let d = ReadDelegate(owner: self)
    readDelegate = d
    tagDelegate = nil
    begin(
      NFCNDEFReaderSession(delegate: d, queue: nil, invalidateAfterFirstRead: true),
      alert: alert, result: result)
  }

  private func startTags(_ job: Job, alert: String, done: String?, result: @escaping FlutterResult)
  {
    finish(nil)
    guard NFCNDEFReaderSession.readingAvailable else {
      result(nil)
      return
    }
    self.done = done
    let d = TagDelegate(owner: self, job: job)
    tagDelegate = d
    readDelegate = nil
    begin(
      NFCNDEFReaderSession(delegate: d, queue: nil, invalidateAfterFirstRead: false),
      alert: alert, result: result)
  }

  fileprivate func finish(_ value: Any?, from s: NFCReaderSession? = nil) {
    if let s = s, s !== session { return }
    timeout?.cancel()
    timeout = nil
    let current = session
    session = nil
    readDelegate = nil
    tagDelegate = nil
    if let current = current {
      if let map = value as? [String: Any], map["status"] as? String == "ok", let done = done {
        current.alertMessage = done
      }
      current.invalidate()
    }
    let r = pending
    pending = nil
    r?(value)
  }

  fileprivate static func records(_ message: NFCNDEFMessage?) -> [[Any]] {
    guard let message = message else { return [] }
    return message.records.prefix(maxRecords).map {
      [
        Int($0.typeNameFormat.rawValue),
        FlutterStandardTypedData(bytes: $0.type),
        FlutterStandardTypedData(bytes: $0.identifier),
        FlutterStandardTypedData(bytes: $0.payload),
      ]
    }
  }

  private final class ReadDelegate: NSObject, NFCNDEFReaderSessionDelegate {
    weak var owner: NfcShare?

    init(owner: NfcShare) {
      self.owner = owner
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
      let records = NfcShare.records(messages.first)
      DispatchQueue.main.async { [weak self] in
        self?.owner?.finish(records, from: session)
      }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
      DispatchQueue.main.async { [weak self] in
        self?.owner?.finish(nil, from: session)
      }
    }
  }

  private final class TagDelegate: NSObject, NFCNDEFReaderSessionDelegate {
    weak var owner: NfcShare?
    let job: Job

    init(owner: NfcShare, job: Job) {
      self.owner = owner
      self.job = job
    }

    private func reply(_ session: NFCNDEFReaderSession, _ value: [String: Any]) {
      DispatchQueue.main.async { [weak self] in
        self?.owner?.finish(value, from: session)
      }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
      guard tags.count == 1, let tag = tags.first else {
        session.restartPolling()
        return
      }
      session.connect(to: tag) { [weak self] error in
        guard let self = self else { return }
        if error != nil {
          self.reply(session, ["status": "failed"])
          return
        }
        tag.queryNDEFStatus { status, capacity, error in
          if error != nil {
            self.reply(session, ["status": "failed"])
            return
          }
          switch status {
          case .notSupported:
            self.reply(session, ["status": "notNdef"])
          case .readOnly:
            self.reply(session, ["status": "readOnly"])
          case .readWrite:
            self.run(session, tag: tag, capacity: capacity)
          @unknown default:
            self.reply(session, ["status": "failed"])
          }
        }
      }
    }

    private func run(_ session: NFCNDEFReaderSession, tag: NFCNDEFTag, capacity: Int) {
      switch job {
      case .write(let message, let size):
        if capacity < size {
          reply(session, ["status": "tooSmall", "need": size, "have": capacity])
          return
        }
        tag.writeNDEF(message) { error in
          self.reply(session, ["status": error == nil ? "ok" : "failed"])
        }
      case .lock(let expected):
        tag.readNDEF { message, error in
          guard error == nil, let records = message?.records, records.count == 1,
            records[0].typeNameFormat == .nfcWellKnown, records[0].type == Data([0x55]),
            records[0].payload == expected
          else {
            self.reply(session, ["status": "mismatch"])
            return
          }
          tag.writeLock { error in
            self.reply(session, ["status": error == nil ? "ok" : "failed"])
          }
        }
      }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
      DispatchQueue.main.async { [weak self] in
        self?.owner?.finish(nil, from: session)
      }
    }
  }
}
