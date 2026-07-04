import Foundation
import Security

/// Named secrets held in the Keychain (invariant 5: never UserDefaults/files/logs).
/// Phase 1 stores provider API keys here; Phase 2 removes them from the client.
public enum SecretKey: String, Sendable, CaseIterable {
    case speechmaticsAPIKey
    case deepgramAPIKey
    case sonioxAPIKey
    case geminiAPIKey
    case awsAccessKeyID
    case awsSecretAccessKey
}

/// Storage seam for secrets so call sites and tests never touch the Keychain
/// API directly. Values are plain `String` (API keys); reads return nil when
/// absent.
public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) -> String?
    @discardableResult func write(_ value: String, for key: SecretKey) -> Bool
    @discardableResult func delete(_ key: SecretKey) -> Bool
}

/// Keychain-backed `SecretStore` (`kSecClassGenericPassword`, one item per key).
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "dev.newt.Koe") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    public func read(_ key: SecretKey) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    public func write(_ value: String, for key: SecretKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Upsert: delete then add keeps it simple and idempotent.
        SecItemDelete(baseQuery(key) as CFDictionary)
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(_ key: SecretKey) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// In-memory `SecretStore` for tests (and previews). Thread-safe.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [SecretKey: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    @discardableResult
    public func write(_ value: String, for key: SecretKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
        return true
    }

    @discardableResult
    public func delete(_ key: SecretKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
        return true
    }
}
