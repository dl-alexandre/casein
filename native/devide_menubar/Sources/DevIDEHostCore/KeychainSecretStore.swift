import Foundation
import Security

public protocol HostSecretStore: Sendable {
    func load(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public struct KeychainSecretStore: HostSecretStore {
    public static let service = "com.onebackend.devide.desktop.secrets.v1"

    public init() {}

    public func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    public func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updates = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
