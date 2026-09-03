import Foundation

/// Protocol for key-value persistence (UserDefaults in production, in-memory for tests).
protocol StorageProvider: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
    func removeObject(forKey key: String)
}

/// UserDefaults-backed storage for production use.
final class UserDefaultsStorage: StorageProvider, @unchecked Sendable {
    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ value: Data?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory storage for tests — no side effects.
final class InMemoryStorage: StorageProvider, @unchecked Sendable {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? {
        store[key] as? String
    }

    func set(_ value: String?, forKey key: String) {
        store[key] = value
    }

    func data(forKey key: String) -> Data? {
        store[key] as? Data
    }

    func set(_ value: Data?, forKey key: String) {
        store[key] = value
    }

    func removeObject(forKey key: String) {
        store.removeValue(forKey: key)
    }
}
