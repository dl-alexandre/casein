import Darwin
import Foundation

public struct HostSettings: Sendable, Equatable, Codable {
    public var port: Int
    public var lanEnabled: Bool

    public init(port: Int, lanEnabled: Bool = false) {
        self.port = port
        self.lanEnabled = lanEnabled
    }

    enum CodingKeys: String, CodingKey {
        case port
        case lanEnabled = "lan_enabled"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        port = try values.decode(Int.self, forKey: .port)
        lanEnabled = try values.decodeIfPresent(Bool.self, forKey: .lanEnabled) ?? false
    }

    public static func loadOrSelect(at url: URL) throws -> HostSettings {
        try SecurePersistence.withLock(for: url) {
            if let data = try? SecurePersistence.readSecurely(at: url),
               let saved = try? JSONDecoder().decode(HostSettings.self, from: data),
               (1024...65535).contains(saved.port), LoopbackPort.isAvailable(saved.port) {
                return saved
            }
            let previous = loadWithoutLock(at: url)
            let settings = HostSettings(
                port: try LoopbackPort.select(),
                lanEnabled: previous?.lanEnabled ?? false
            )
            try SecurePersistence.replace(JSONEncoder().encode(settings), at: url)
            return settings
        }
    }

    public static func load(at url: URL) -> HostSettings? {
        try? SecurePersistence.withLock(for: url) {
            loadWithoutLock(at: url)
        }
    }

    public static func setLANEnabled(_ enabled: Bool, at url: URL) throws {
        try SecurePersistence.withLock(for: url) {
            let existing = loadWithoutLock(at: url)
            let port: Int
            if let existing {
                port = existing.port
            } else {
                port = try LoopbackPort.select()
            }
            let settings = HostSettings(port: port, lanEnabled: enabled)
            try SecurePersistence.replace(JSONEncoder().encode(settings), at: url)
        }
    }

    private static func loadWithoutLock(at url: URL) -> HostSettings? {
        guard
            let data = try? SecurePersistence.readSecurely(at: url),
            let settings = try? JSONDecoder().decode(HostSettings.self, from: data),
            (1024...65535).contains(settings.port)
        else { return nil }
        return settings
    }
}

enum LoopbackPort {
    static func isAvailable(_ port: Int) -> Bool { (try? bind(port)) != nil }
    static func select() throws -> Int { try bind(0) }

    private static func bind(_ port: Int) throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &bound, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }) == 0 else { throw POSIXError(.EINVAL) }
        return Int(in_port_t(bigEndian: bound.sin_port))
    }
}
