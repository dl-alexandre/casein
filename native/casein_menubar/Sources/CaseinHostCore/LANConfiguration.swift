import Darwin
import Foundation

public struct LANConfiguration: Sendable, Equatable {
    public var host: String
    public var ip: String
    public var ips: [String]

    public init(host: String, ip: String, ips: [String] = []) {
        self.host = host
        self.ip = ip
        self.ips = ([ip] + ips).reduce(into: []) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }

    public static func detect() -> LANConfiguration? {
        let addresses = privateIPv4Addresses()
        guard let preferred = addresses.first else { return nil }
        let rawHost = ProcessInfo.processInfo.hostName
        let host = rawHost.contains(".") ? rawHost : "\(rawHost).local"
        return LANConfiguration(
            host: host,
            ip: preferred.address,
            ips: addresses.map(\.address)
        )
    }

    public func url(port: Int) -> URL? {
        guard (1024...65535).contains(port) else { return nil }
        // Older Android releases do not consistently resolve Bonjour `.local`
        // names. Advertise the preferred private address while still allowing
        // the hostname and every active private address at the endpoint.
        return URL(string: "http://\(ip):\(port)")
    }

    private struct InterfaceAddress {
        var name: String
        var address: String
    }

    private static func privateIPv4Addresses() -> [InterfaceAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        return sequence(first: first, next: { $0.pointee.ifa_next })
            .compactMap { interface -> InterfaceAddress? in
                let flags = Int32(interface.pointee.ifa_flags)
                guard
                    flags & IFF_UP != 0,
                    flags & IFF_LOOPBACK == 0,
                    let address = interface.pointee.ifa_addr,
                    address.pointee.sa_family == UInt8(AF_INET)
                else { return nil }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard result == 0 else { return nil }
                let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let value = String(decoding: bytes, as: UTF8.self)
                guard privateIPv4(value) else { return nil }
                return InterfaceAddress(
                    name: String(cString: interface.pointee.ifa_name),
                    address: value
                )
            }
            .sorted { lhs, rhs in
                let lhsRank = interfaceRank(lhs.name)
                let rhsRank = interfaceRank(rhs.name)
                return lhsRank == rhsRank ? lhs.name < rhs.name : lhsRank < rhsRank
            }
    }

    // Built-in Wi-Fi is normally en0 (occasionally en1). Prefer it over USB,
    // Thunderbolt, VPN, and bridge interfaces so the copied URL is useful to
    // phones and tablets on the same wireless network.
    private static func interfaceRank(_ name: String) -> Int {
        switch name {
        case "en0": 0
        case "en1": 1
        default: name.hasPrefix("en") ? 2 : 3
        }
    }

    private static func privateIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
