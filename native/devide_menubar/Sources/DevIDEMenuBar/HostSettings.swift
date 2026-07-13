import Foundation

/// Host-side persistence. Non-secret settings live in UserDefaults; the
/// generated release secrets live in a 0600 file under the data dir (Keychain
/// is the follow-up — see README).
struct HostSettings {
    private static let releaseRootKey = "releaseRoot"

    /// Directory containing the release (`bin/dev_ide`, `bin/migrate`,
    /// `erts-*/`). Chosen by the operator via "Choose Release…".
    var releaseRoot: URL? {
        get {
            UserDefaults.standard.string(forKey: Self.releaseRootKey)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        nonmutating set {
            UserDefaults.standard.set(newValue?.path, forKey: Self.releaseRootKey)
        }
    }

    /// Mirrors `DevIDE.Desktop.Runtime.data_dir/0` on Darwin so host and
    /// release agree without configuration. The host still passes it
    /// explicitly as DEV_IDE_DESKTOP_DATA_DIR.
    var dataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevIDE", isDirectory: true)
    }

    var statusFile: URL { dataDir.appendingPathComponent("runtime.json") }
    var hostLogsDir: URL { dataDir.appendingPathComponent("host-logs", isDirectory: true) }
    var secretsFile: URL { dataDir.appendingPathComponent("host-secrets.json") }

    /// Distinct node name so a stale `dev_ide` epmd registration from another
    /// checkout/release on this machine can't cause "name in use".
    var releaseNode: String { "devide_desktop" }
}

/// SECRET_KEY_BASE and DEV_IDE_API_TOKEN, generated once and persisted —
/// boot refuses to start without the token.
struct HostSecrets: Codable {
    var secretKeyBase: String
    var apiToken: String

    enum CodingKeys: String, CodingKey {
        case secretKeyBase = "secret_key_base"
        case apiToken = "api_token"
    }

    static func loadOrCreate(at url: URL) throws -> HostSecrets {
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(HostSecrets.self, from: data) {
            return existing
        }

        let secrets = HostSecrets(
            secretKeyBase: randomToken(bytes: 48),
            apiToken: randomToken(bytes: 32)
        )

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(secrets)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return secrets
    }

    private static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
