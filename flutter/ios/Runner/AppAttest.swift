import CryptoKit
import DeviceCheck
import Foundation

/// App Attest over a server challenge; the key id persists because Apple won't re-attest a known key.
enum AppAttest {

  private static let keyIdDefaultsKey = "nym_app_attest_key_id"

  static var isSupported: Bool {
    DCAppAttestService.shared.isSupported
  }

  /// `["keyId", "attestation"]` as unpadded base64url, or `["reason": …]` when the device can't attest.
  static func attest(challenge: String, completion: @escaping ([String: String]?) -> Void) {
    let service = DCAppAttestService.shared
    guard service.isSupported else {
      completion(["reason": "app-attest-unsupported"])
      return
    }
    // The server recomputes sha256(challenge) against the certificate nonce, tying this attestation to the enrollment.
    let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))

    withKeyId(service: service) { keyId in
      guard let keyId else {
        completion(["reason": "app-attest-no-key"])
        return
      }
      service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
        if let attestation {
          completion([
            "keyId": base64Url(Data(base64Encoded: keyId) ?? Data(keyId.utf8)),
            "attestation": base64Url(attestation),
          ])
          return
        }
        // A key Apple no longer accepts is unusable forever; regenerate once rather than failing every launch.
        if isInvalidKeyError(error) {
          UserDefaults.standard.removeObject(forKey: keyIdDefaultsKey)
          generateKey(service: service) { fresh in
            guard let fresh else {
              completion(["reason": "app-attest-no-key"])
              return
            }
            service.attestKey(fresh, clientDataHash: clientDataHash) { retryAttestation, retryError in
              guard let retryAttestation else {
                completion(["reason": describe(retryError)])
                return
              }
              completion([
                "keyId": base64Url(Data(base64Encoded: fresh) ?? Data(fresh.utf8)),
                "attestation": base64Url(retryAttestation),
              ])
            }
          }
          return
        }
        completion(["reason": describe(error)])
      }
    }
  }

  private static func describe(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "app-attest-failed" }
    return "app-attest:\(error.domain)(\(error.code))"
  }

  private static func withKeyId(
    service: DCAppAttestService,
    completion: @escaping (String?) -> Void
  ) {
    if let stored = UserDefaults.standard.string(forKey: keyIdDefaultsKey), !stored.isEmpty {
      completion(stored)
      return
    }
    generateKey(service: service, completion: completion)
  }

  private static func generateKey(
    service: DCAppAttestService,
    completion: @escaping (String?) -> Void
  ) {
    service.generateKey { keyId, _ in
      guard let keyId else {
        completion(nil)
        return
      }
      UserDefaults.standard.set(keyId, forKey: keyIdDefaultsKey)
      completion(keyId)
    }
  }

  private static func isInvalidKeyError(_ error: Error?) -> Bool {
    guard let error = error as NSError?, error.domain == DCError.errorDomain else { return false }
    return error.code == DCError.invalidKey.rawValue
  }

  /// Unpadded base64url, as the worker decodes.
  private static func base64Url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
