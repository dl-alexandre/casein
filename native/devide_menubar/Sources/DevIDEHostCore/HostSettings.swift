import Darwin
import Foundation

public struct HostSettings: Sendable, Equatable, Codable {
    public var port: Int

    public init(port: Int) { self.port = port }

    public static func loadOrSelect(at url: URL) throws -> HostSettings {
        try SecurePersistence.withLock(for: url) {
            if let data = try? SecurePersistence.readSecurely(at: url),
               let saved = try? JSONDecoder().decode(HostSettings.self, from: data),
               (1024...65535).contains(saved.port), LoopbackPort.isAvailable(saved.port) {
                return saved
            }
            let settings = HostSettings(port: try LoopbackPort.select())
            try SecurePersistence.replace(JSONEncoder().encode(settings), at: url)
            return settings
        }
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
