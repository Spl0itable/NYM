import CryptoKit
import DeviceCheck
import Foundation

/// Apple App Attest: asks the Secure Enclave for a hardware-backed attestation
/// of this app, over a server-chosen challenge.
///
/// What comes back is a certificate chain Apple's own App Attest CA signs,
/// naming the app (Team ID + bundle ID) and carrying the challenge inside an
/// Apple-issued extension. The server checks the chain to Apple's root, so the
/// proof cannot be produced by a repackaged build, a simulator, or anything
/// that is not this app on genuine hardware.
///
/// The key id is persisted: Apple's attestation is a one-time ceremony per
/// generated key, and re-attesting a key already known to their service is
/// refused. A device that has attested before re-uses its key, and on the
/// rejections that mean "this key is no longer usable" it starts over with a
/// fresh one.
enum AppAttest {

  private static let keyIdDefaultsKey = "nym_app_attest_key_id"

  static var isSupported: Bool {
    DCAppAttestService.shared.isSupported
  }

  /// Produces `["keyId": …, "attestation": …]` for `challenge`, both base64url
  /// with no padding (the form the worker's `base64UrlDecode` expects).
  ///
  /// Calls back with nil when the device cannot attest — a simulator, an older
  /// OS, App Attest disabled for this app. Nil is "no proof": the Dart side
  /// enrolls nothing rather than sending a weaker claim.
  static func attest(challenge: String, completion: @escaping ([String: String]?) -> Void) {
    let service = DCAppAttestService.shared
    guard service.isSupported else {
      completion(nil)
      return
    }
    // Apple hashes whatever we hand it into the certificate's nonce extension;
    // the server recomputes sha256(challenge) and compares, which is what ties
    // this attestation to this enrollment.
    let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))

    withKeyId(service: service) { keyId in
      guard let keyId else {
        completion(nil)
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
        // A key Apple no longer accepts (revoked, or already attested on a
        // device that was since restored) is unusable forever. Drop it and
        // generate a fresh one, once, rather than failing every launch.
        if isInvalidKeyError(error) {
          UserDefaults.standard.removeObject(forKey: keyIdDefaultsKey)
          generateKey(service: service) { fresh in
            guard let fresh else {
              completion(nil)
              return
            }
            service.attestKey(fresh, clientDataHash: clientDataHash) { retryAttestation, _ in
              guard let retryAttestation else {
                completion(nil)
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
        completion(nil)
      }
    }
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

  /// The worker decodes both fields with a base64url decoder, so emit that
  /// alphabet and drop the padding.
  private static func base64Url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
