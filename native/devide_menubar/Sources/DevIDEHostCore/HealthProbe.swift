import Foundation

/// Response of `GET /desktop/health` — the published identity plus live
/// uptime. The route deliberately omits `pid`.
public struct HealthReport: Sendable, Equatable, Codable {
    public var status: String
    public var port: Int?
    public var baseURL: URL?
    public var version: String?
    public var revision: String?
    public var uptimeMs: Int?

    enum CodingKeys: String, CodingKey {
        case status, port, version, revision
        case baseURL = "base_url"
        case uptimeMs = "uptime_ms"
    }
}

public enum HealthProbe {
    /// Poll the loopback readiness route. Any transport error, non-200, or
    /// undecodable body reads as "not healthy" — the caller decides whether
    /// that means starting, unhealthy, or gone.
    public static func probe(baseURL: URL, timeout: TimeInterval = 3) async -> HealthReport? {
        var request = URLRequest(url: baseURL.appending(path: "desktop/health"))
        request.timeoutInterval = timeout
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(HealthReport.self, from: data)
    }
}
