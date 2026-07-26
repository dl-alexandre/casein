import Foundation

/// Decoded `runtime.json` — schema 1 of the desktop status contract.
/// See `docs/desktop/platform_architecture.md`, "Status contract".
public struct RuntimeStatus: Sendable, Equatable, Codable {
    public static let supportedSchema = 1

    public var schema: Int
    /// `starting | ready | stopping | unhealthy | stopped`. v1 releases only
    /// ever write `ready`, but the contract reserves the full set.
    public var status: String
    public var port: Int
    public var baseURL: URL
    public var pid: Int32
    public var version: String
    public var revision: String
    /// ISO8601 with fractional seconds; kept as the raw string — live uptime
    /// comes from the health route, not this file.
    public var startedAt: String

    enum CodingKeys: String, CodingKey {
        case schema, status, port, pid, version, revision
        case baseURL = "base_url"
        case startedAt = "started_at"
    }

    public enum ReadError: Error, Equatable {
        /// The normal "server not running (or cleanly shut down)" signal.
        case missing
        case unreadable
        case invalidJSON
        case unsupportedSchema(Int)
    }

    /// Read and validate the status file. `.missing` is an expected state,
    /// not an exceptional condition.
    public static func read(at url: URL) -> Result<RuntimeStatus, ReadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.missing)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable)
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return .failure(.invalidJSON)
        }
        guard let schema = dictionary["schema"] as? Int, schema == supportedSchema else {
            return .failure(.unsupportedSchema(dictionary["schema"] as? Int ?? -1))
        }
        guard let status = try? JSONDecoder().decode(RuntimeStatus.self, from: data) else {
            return .failure(.invalidJSON)
        }
        return .success(status)
    }

    /// The contract's stale rule: crashes leave `runtime.json` behind, so a
    /// file whose pid is no longer alive must be treated as stale.
    public var isPidAlive: Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
