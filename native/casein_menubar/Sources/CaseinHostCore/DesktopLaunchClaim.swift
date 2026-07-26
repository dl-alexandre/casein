import CryptoKit
import Foundation

/// A browser-safe, short-lived proof derived from the per-install launch
/// secret. The root secret remains in the host and release environments.
enum DesktopLaunchClaim {
    static func queryItems(
        secret: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: String? = nil
    ) throws -> [URLQueryItem] {
        let encodedNonce = try nonce ?? HostSecrets.randomToken(bytes: 16)
        let message = Data("v1.\(timestamp).\(encodedNonce)".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let proof = Data(authenticationCode).base64URLEncodedString()

        return [
            URLQueryItem(name: "desktop_nonce", value: encodedNonce),
            URLQueryItem(name: "desktop_timestamp", value: String(timestamp)),
            URLQueryItem(name: "desktop_proof", value: proof),
        ]
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
