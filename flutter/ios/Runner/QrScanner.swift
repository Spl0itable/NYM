import CoreImage
import Flutter
import UIKit
import Vision

final class QrScanner {
  static let channelName = "app.nymchat/qr"
  private static let queue = DispatchQueue(label: "app.nymchat.qr", qos: .userInitiated)
  private static let maxText = 8192

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "decodeFrame":
      guard let typed = args["bgra"] as? FlutterStandardTypedData,
        let width = args["width"] as? Int,
        let height = args["height"] as? Int,
        let bytesPerRow = args["bytesPerRow"] as? Int,
        width > 0, height > 0, bytesPerRow >= width * 4,
        typed.data.count >= bytesPerRow * height
      else {
        result(nil)
        return
      }
      let bytes = typed.data
      queue.async {
        let image = CIImage(
          bitmapData: bytes,
          bytesPerRow: bytesPerRow,
          size: CGSize(width: width, height: height),
          format: .BGRA8,
          colorSpace: CGColorSpaceCreateDeviceRGB())
        let text = detect(VNImageRequestHandler(ciImage: image, options: [:]))
        DispatchQueue.main.async { result(text) }
      }
    case "decodeFile":
      guard let path = args["path"] as? String else {
        result(nil)
        return
      }
      queue.async {
        let text = detect(VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]))
        DispatchQueue.main.async { result(text) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func detect(_ handler: VNImageRequestHandler) -> String? {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    do {
      try handler.perform([request])
    } catch {
      return nil
    }
    for observation in request.results ?? [] {
      if let text = observation.payloadStringValue, text.utf16.count <= maxText {
        return text
      }
    }
    return nil
  }
}
