import Flutter
import Foundation
import NearbyInteraction
import simd

final class NearbyShare: NSObject, FlutterStreamHandler {
  static let channelName = "app.nymchat/nearby_interaction"
  static let eventsName = "app.nymchat/nearby_interaction/events"
  private static let shared = NearbyShare()
  private static let maxPeers = 8
  private static let maxTokenBytes = 1024

  private var sessions: [String: NearbyPeerSession] = [:]
  private var sink: FlutterEventSink?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result: result)
    }
    let events = FlutterEventChannel(name: eventsName, binaryMessenger: messenger)
    events.setStreamHandler(shared)
  }

  static func isSupported() -> Bool {
    if #available(iOS 16.0, *) {
      return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }
    return NISession.isSupported
  }

  static func supportsDirection() -> Bool {
    if #available(iOS 16.0, *) {
      return NISession.deviceCapabilities.supportsDirectionMeasurement
    }
    return isSupported()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  fileprivate func emit(_ event: [String: Any]) {
    sink?(event)
  }

  fileprivate func drop(_ peerId: String, session: NearbyPeerSession) {
    if sessions[peerId] === session {
      sessions.removeValue(forKey: peerId)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let peerId = args["peerId"] as? String ?? ""
    switch call.method {
    case "isSupported":
      result(Self.isSupported())
    case "supportsDirection":
      result(Self.supportsDirection())
    case "prepare":
      guard Self.isSupported(), !peerId.isEmpty, let session = peerSession(for: peerId),
        let token = session.session.discoveryToken,
        let data = try? NSKeyedArchiver.archivedData(
          withRootObject: token, requiringSecureCoding: true),
        data.count <= Self.maxTokenBytes
      else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: data))
    case "run":
      guard Self.isSupported(), !peerId.isEmpty,
        let typed = args["token"] as? FlutterStandardTypedData,
        typed.data.count > 0, typed.data.count <= Self.maxTokenBytes,
        let token = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: NIDiscoveryToken.self, from: typed.data),
        let session = peerSession(for: peerId)
      else {
        result(false)
        return
      }
      session.session.run(NINearbyPeerConfiguration(peerToken: token))
      result(true)
    case "stop":
      if let session = sessions.removeValue(forKey: peerId) {
        session.session.invalidate()
      }
      result(nil)
    case "stopAll":
      let all = sessions.values
      sessions.removeAll()
      for session in all {
        session.session.invalidate()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func peerSession(for peerId: String) -> NearbyPeerSession? {
    if let existing = sessions[peerId] {
      return existing
    }
    guard sessions.count < Self.maxPeers else { return nil }
    let created = NearbyPeerSession(peerId: peerId, owner: self)
    sessions[peerId] = created
    return created
  }
}

private final class NearbyPeerSession: NSObject, NISessionDelegate {
  let peerId: String
  let session = NISession()
  weak var owner: NearbyShare?

  init(peerId: String, owner: NearbyShare) {
    self.peerId = peerId
    self.owner = owner
    super.init()
    session.delegateQueue = DispatchQueue.main
    session.delegate = self
  }

  func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
    guard let object = nearbyObjects.first else { return }
    var event: [String: Any] = ["peerId": peerId]
    if let distance = object.distance {
      event["distance"] = Double(distance)
    }
    if let direction = object.direction {
      event["x"] = Double(direction.x)
      event["y"] = Double(direction.y)
      event["z"] = Double(direction.z)
    }
    owner?.emit(event)
  }

  func session(
    _ session: NISession, didRemove nearbyObjects: [NINearbyObject],
    reason: NINearbyObject.RemovalReason
  ) {
    owner?.emit(["peerId": peerId, "event": "removed"])
  }

  func sessionWasSuspended(_ session: NISession) {
    owner?.emit(["peerId": peerId, "event": "suspended"])
  }

  func sessionSuspensionEnded(_ session: NISession) {
    if let configuration = session.configuration {
      session.run(configuration)
    }
  }

  func session(_ session: NISession, didInvalidateWith error: Error) {
    owner?.emit(["peerId": peerId, "event": "invalidated"])
    owner?.drop(peerId, session: self)
  }
}
