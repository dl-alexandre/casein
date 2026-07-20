import Foundation
import Security

/// Boot-required secrets stored in the user's login Keychain. Legacy
/// mode-0600 JSON is migrated once and securely removed only after the
/// Keychain write succeeds.
public struct HostSecrets: Sendable, Equatable, Codable {
    public var secretKeyBase: String
    public var apiToken: String
    public var desktopLaunchToken: String

    enum CodingKeys: String, CodingKey {
        case secretKeyBase = "secret_key_base"
        case apiToken = "api_token"
        case desktopLaunchToken = "desktop_launch_token"
    }

    public init(secretKeyBase: String, apiToken: String, desktopLaunchToken: String) {
        self.secretKeyBase = secretKeyBase
        self.apiToken = apiToken
        self.desktopLaunchToken = desktopLaunchToken
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        secretKeyBase = try values.decode(String.self, forKey: .secretKeyBase)
        apiToken = try values.decode(String.self, forKey: .apiToken)
        desktopLaunchToken = try values.decodeIfPresent(String.self, forKey: .desktopLaunchToken)
            ?? HostSecrets.randomToken(bytes: 32)
    }

    public static func loadOrCreate(at url: URL) throws -> HostSecrets {
        try loadOrCreate(at: url, store: KeychainSecretStore())
    }

    public static func loadOrCreate(at url: URL, store: any HostSecretStore) throws -> HostSecrets {
        try SecurePersistence.withLock(for: url) {
            let account = keychainAccount(for: url)
            if let data = try store.load(account: account) {
                let existing = try JSONDecoder().decode(HostSecrets.self, from: data)
                try existing.validate()
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let launchValue = object?[CodingKeys.desktopLaunchToken.rawValue]
                if launchValue == nil || launchValue is NSNull {
                    try store.save(JSONEncoder().encode(existing), account: account)
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    try SecurePersistence.removeSecurely(at: url)
                }
                return existing
            }

            if FileManager.default.fileExists(atPath: url.path) {
                let data = try SecurePersistence.readSecurely(at: url)
                let existing = try JSONDecoder().decode(HostSecrets.self, from: data)
                try existing.validate()
                try store.save(JSONEncoder().encode(existing), account: account)
                try SecurePersistence.removeSecurely(at: url)
                return existing
            }

            let fresh = HostSecrets(
                secretKeyBase: try randomToken(bytes: 48),
                apiToken: try randomToken(bytes: 32),
                desktopLaunchToken: try randomToken(bytes: 32)
            )
            try store.save(JSONEncoder().encode(fresh), account: account)
            return fresh
        }
    }

    public static func deleteFromKeychain(at url: URL) throws {
        try KeychainSecretStore().delete(account: keychainAccount(for: url))
    }

    public static func keychainAccount(for url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func validate() throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let values = [(secretKeyBase, 64), (apiToken, 32), (desktopLaunchToken, 32)]
        guard values.allSatisfy({ value, minimum in
            value.count >= minimum && value.unicodeScalars.allSatisfy(allowed.contains)
        }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// base64url keeps full entropy (no modulo bias) and stays env-var safe.
    static func randomToken(bytes count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed: \(status)"])
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
