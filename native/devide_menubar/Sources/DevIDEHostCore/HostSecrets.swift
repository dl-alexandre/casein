import Foundation
import Security

/// Boot-required secrets: the release refuses to start without
/// SECRET_KEY_BASE and DEV_IDE_API_TOKEN. Generated once, persisted with
/// 0600 permissions in the data directory.
///
/// TODO(phase-3): move to the Keychain; a file is acceptable for the spike
/// because the desktop profile is loopback-only and the directory is
/// per-user, but the token grants API access to anyone who can read it.
public struct HostSecrets: Sendable, Equatable, Codable {
    public var secretKeyBase: String
    public var apiToken: String

    enum CodingKeys: String, CodingKey {
        case secretKeyBase = "secret_key_base"
        case apiToken = "api_token"
    }

    public static func loadOrCreate(at url: URL) throws -> HostSecrets {
        if let data = try? Data(contentsOf: url),
            let existing = try? JSONDecoder().decode(HostSecrets.self, from: data)
        {
            return existing
        }

        let fresh = HostSecrets(
            secretKeyBase: randomToken(bytes: 48),
            apiToken: randomToken(bytes: 32)
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(fresh).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return fresh
    }

    /// base64url keeps full entropy (no modulo bias) and stays env-var safe.
    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
