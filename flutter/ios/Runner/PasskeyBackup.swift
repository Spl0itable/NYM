import AuthenticationServices
import CryptoKit
import Flutter
import UIKit

final class PasskeyBackup: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  static let shared = PasskeyBackup()

  private var pending: FlutterResult?
  private var controller: ASAuthorizationController?

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    shared.dispatch(call, result: result)
  }

  private func dispatch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      if #available(iOS 17.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "create":
      guard #available(iOS 17.0, *) else {
        result(FlutterError(code: "unsupported", message: nil, details: nil))
        return
      }
      create(call.arguments as? [String: Any] ?? [:], result: result)
    case "get":
      guard #available(iOS 17.0, *) else {
        result(FlutterError(code: "unsupported", message: nil, details: nil))
        return
      }
      authenticate(call.arguments as? [String: Any] ?? [:], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func data(_ value: Any?) -> Data? {
    if let typed = value as? FlutterStandardTypedData { return typed.data }
    return nil
  }

  @available(iOS 17.0, *)
  private func create(_ args: [String: Any], result: @escaping FlutterResult) {
    guard
      pending == nil,
      let rpId = args["rpId"] as? String,
      let userName = args["userName"] as? String,
      let userId = PasskeyBackup.data(args["userId"]),
      let challenge = PasskeyBackup.data(args["challenge"])
    else {
      result(FlutterError(code: "bad_args", message: nil, details: nil))
      return
    }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: rpId)
    let request = provider.createCredentialRegistrationRequest(
      challenge: challenge, name: userName, userID: userId)
    request.userVerificationPreference = .required
    request.largeBlob = .supportPreferred
    if #available(iOS 18.0, *), let salt = PasskeyBackup.data(args["prfSalt"]) {
      request.prf = .inputValues(
        ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(
          saltInput1: salt, saltInput2: nil))
    }
    perform(request, result: result)
  }

  @available(iOS 17.0, *)
  private func authenticate(_ args: [String: Any], result: @escaping FlutterResult) {
    guard
      pending == nil,
      let rpId = args["rpId"] as? String,
      let challenge = PasskeyBackup.data(args["challenge"])
    else {
      result(FlutterError(code: "bad_args", message: nil, details: nil))
      return
    }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: rpId)
    let request = provider.createCredentialAssertionRequest(challenge: challenge)
    request.userVerificationPreference = .required
    if let allowed = args["allowCredentials"] as? [Any] {
      request.allowedCredentials = allowed.compactMap { PasskeyBackup.data($0) }.map {
        ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
      }
    }
    if let blob = PasskeyBackup.data(args["largeBlobWrite"]) {
      request.largeBlob = .write(blob)
    } else if args["largeBlobRead"] as? Bool == true {
      request.largeBlob = .read
    }
    if #available(iOS 18.0, *), let salt = PasskeyBackup.data(args["prfSalt"]) {
      request.prf = .inputValues(
        ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(
          saltInput1: salt, saltInput2: nil))
    }
    perform(request, result: result)
  }

  private func perform(_ request: ASAuthorizationRequest, result: @escaping FlutterResult) {
    pending = result
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    controller.performRequests()
  }

  private func finish(_ value: Any?) {
    let result = pending
    pending = nil
    controller = nil
    DispatchQueue.main.async { result?(value) }
  }

  private static func bytes(_ key: SymmetricKey) -> FlutterStandardTypedData {
    key.withUnsafeBytes { FlutterStandardTypedData(bytes: Data($0)) }
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    var out: [String: Any] = [:]
    if let reg = authorization.credential
      as? ASAuthorizationPlatformPublicKeyCredentialRegistration
    {
      out["credentialId"] = FlutterStandardTypedData(bytes: reg.credentialID)
      if #available(iOS 17.0, *) {
        out["largeBlobSupported"] = reg.largeBlob?.isSupported ?? false
      }
      if #available(iOS 18.0, *), let prf = reg.prf {
        out["prfEnabled"] = prf.isSupported
        if let first = prf.first { out["prfFirst"] = PasskeyBackup.bytes(first) }
      }
    } else if let assertion = authorization.credential
      as? ASAuthorizationPlatformPublicKeyCredentialAssertion
    {
      out["credentialId"] = FlutterStandardTypedData(bytes: assertion.credentialID)
      if #available(iOS 17.0, *), let blob = assertion.largeBlob {
        switch blob.result {
        case .read(let data):
          if let data = data { out["largeBlob"] = FlutterStandardTypedData(bytes: data) }
        case .write(let success):
          out["largeBlobWritten"] = success
        @unknown default:
          break
        }
      }
      if #available(iOS 18.0, *), let prf = assertion.prf {
        out["prfFirst"] = PasskeyBackup.bytes(prf.first)
      }
    } else {
      finish(FlutterError(code: "other", message: "unexpected credential", details: nil))
      return
    }
    finish(out)
  }

  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: Error
  ) {
    let ns = error as NSError
    var code = "other"
    if ns.domain == ASAuthorizationError.errorDomain {
      switch ns.code {
      case ASAuthorizationError.canceled.rawValue:
        code = "canceled"
      default:
        let text = ns.localizedDescription.lowercased()
        if text.contains("associated") || text.contains("domain") { code = "rp" }
        if text.contains("excluded") || text.contains("already") { code = "exists" }
      }
    }
    finish(FlutterError(code: code, message: ns.localizedDescription, details: nil))
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
    }
    return scenes.first?.windows.first ?? ASPresentationAnchor()
  }
}
