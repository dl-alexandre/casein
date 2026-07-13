import Foundation

/// The status contract published by the desktop-profile release.
/// See docs/desktop/platform_architecture.md "Status contract".
///
/// The host consumes only this contract: it reads `runtime.json`, probes
/// `GET /desktop/health`, and execs the release's `bin/` scripts. It holds
/// no product state and speaks no BEAM protocol.

/// `<data_dir>/runtime.json`, schema 1. Written atomically by
/// `DevIDE.Desktop.Status` when the endpoint is bound; removed on graceful
/// shutdown. A file whose `pid` is not alive is stale (crash leftover).
struct RuntimeStatus: Codable, Equatable {
    static let supportedSchema = 1

    var schema: Int
    var status: String
    var port: Int
    var baseUrl: String
    var pid: Int32
    var version: String
    var revision: String
    var startedAt: String

    enum CodingKeys: String, CodingKey {
        case schema, status, port, pid, version, revision
        case baseUrl = "base_url"
        case startedAt = "started_at"
    }

    var baseURL: URL? { URL(string: baseUrl) }

    /// Contract: hosts must treat a file whose pid is not alive as stale.
    var pidAlive: Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// `GET /desktop/health` response. Mirrors the published identity plus live
/// uptime; deliberately omits `pid`. 404 outside the desktop profile.
struct DesktopHealth: Codable, Equatable {
    var status: String
    var port: Int
    var baseUrl: String
    var version: String
    var revision: String
    var uptimeMs: Int64

    enum CodingKeys: String, CodingKey {
        case status, port, version, revision
        case baseUrl = "base_url"
        case uptimeMs = "uptime_ms"
    }
}

/// What the host concluded from the status file + health probe this tick.
enum RuntimeState: Equatable {
    /// No runtime.json (and no stale leftover).
    case stopped
    /// runtime.json exists but its pid is dead — crash leftover.
    case stale(RuntimeStatus)
    /// pid alive and the health route answered.
    case ready(RuntimeStatus, DesktopHealth)
    /// pid alive but the health route did not answer or disagreed.
    case unhealthy(RuntimeStatus, reason: String)
    /// runtime.json exists but the host doesn't understand it.
    case incompatible(schema: Int?)

    var symbolName: String {
        switch self {
        case .ready: return "terminal.fill"
        case .stopped, .stale: return "terminal"
        case .unhealthy, .incompatible: return "exclamationmark.triangle"
        }
    }

    var runtimeStatus: RuntimeStatus? {
        switch self {
        case .ready(let s, _), .unhealthy(let s, _), .stale(let s): return s
        case .stopped, .incompatible: return nil
        }
    }
}

enum StatusFile {
    /// Reads and interprets runtime.json. The writer renames atomically, so a
    /// plain read never observes a partial file.
    static func read(at url: URL) -> RuntimeState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .stopped
        }

        guard let status = try? JSONDecoder().decode(RuntimeStatus.self, from: data) else {
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .incompatible(schema: raw?["schema"] as? Int)
        }
        guard status.schema == RuntimeStatus.supportedSchema else {
            return .incompatible(schema: status.schema)
        }
        guard status.pidAlive else {
            return .stale(status)
        }
        return .unhealthy(status, reason: "not probed yet")
    }

    static func probeHealth(for status: RuntimeStatus) async -> RuntimeState {
        guard let base = status.baseURL,
              let url = URL(string: "/desktop/health", relativeTo: base)
        else {
            return .unhealthy(status, reason: "unparseable base_url")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .unhealthy(status, reason: "health route answered \(code)")
            }
            let health = try JSONDecoder().decode(DesktopHealth.self, from: data)
            return .ready(status, health)
        } catch {
            return .unhealthy(status, reason: "health probe failed: \(error.localizedDescription)")
        }
    }
}
