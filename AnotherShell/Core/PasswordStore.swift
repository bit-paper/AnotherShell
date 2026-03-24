import Foundation
import Security

enum PasswordStoragePreference {
    static var useSystemKeychain: Bool {
        get {
            false
        }
        set {
            // Keep local-store-only mode to avoid Keychain dependency.
        }
    }
}

enum KeychainPasswordStore {
    private static let service = "com.anothershell.ssh.password"
    private static let localStoreFileName = "password_store.json"
    private static let localQueue = DispatchQueue(label: "com.anothershell.password.local-store")

    private struct LocalPasswordDatabase: Codable {
        var entries: [String: String] = [:]
    }

    static func save(_ password: String, for host: SSHHost) {
        let normalized = normalize(password)
        guard !normalized.isEmpty else {
            delete(for: host)
            return
        }

        let stableAccount = stableAccountKey(for: host)
        let legacyAccount = legacyAccountKey(for: host)

        if PasswordStoragePreference.useSystemKeychain {
            saveToKeychain(password: normalized, account: stableAccount)
            deleteFromKeychain(account: legacyAccount)
            removeFromLocalStore(account: stableAccount)
            removeFromLocalStore(account: legacyAccount)
        } else {
            saveToLocalStore(password: normalized, account: stableAccount)
            removeFromLocalStore(account: legacyAccount)
            deleteFromKeychain(account: stableAccount)
            deleteFromKeychain(account: legacyAccount)
        }
    }

    static func load(for host: SSHHost) -> String? {
        let stableAccount = stableAccountKey(for: host)
        let legacyAccount = legacyAccountKey(for: host)

        if PasswordStoragePreference.useSystemKeychain {
            if let value = loadFromKeychain(account: stableAccount) {
                return value
            }

            // Backward compatibility: migrate from legacy per-id account keys.
            guard let legacyValue = loadFromKeychain(account: legacyAccount) else {
                return nil
            }

            saveToKeychain(password: legacyValue, account: stableAccount)
            deleteFromKeychain(account: legacyAccount)
            return legacyValue
        }

        if let value = loadFromLocalStore(account: stableAccount) {
            return value
        }

        if let legacyValue = loadFromLocalStore(account: legacyAccount) {
            saveToLocalStore(password: legacyValue, account: stableAccount)
            removeFromLocalStore(account: legacyAccount)
            return legacyValue
        }

        return nil
    }

    static func delete(for host: SSHHost) {
        let stableAccount = stableAccountKey(for: host)
        let legacyAccount = legacyAccountKey(for: host)

        deleteFromKeychain(account: stableAccount)
        deleteFromKeychain(account: legacyAccount)
        removeFromLocalStore(account: stableAccount)
        removeFromLocalStore(account: legacyAccount)
    }

    static func hasPassword(for host: SSHHost) -> Bool {
        load(for: host) != nil
    }

    private static func saveToKeychain(password: String, account: String) {
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    private static func loadFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }

        return normalize(password)
    }

    private static func saveToLocalStore(password: String, account: String) {
        localQueue.sync {
            var database = loadLocalDatabase()
            database.entries[account] = password
            persistLocalDatabase(database)
        }
    }

    private static func loadFromLocalStore(account: String) -> String? {
        localQueue.sync {
            let database = loadLocalDatabase()
            guard let value = database.entries[account], !value.isEmpty else {
                return nil
            }
            return normalize(value)
        }
    }

    private static func removeFromLocalStore(account: String) {
        localQueue.sync {
            var database = loadLocalDatabase()
            database.entries.removeValue(forKey: account)
            persistLocalDatabase(database)
        }
    }

    private static func localStoreURL() -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("AnotherShell", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.appendingPathComponent(localStoreFileName)
    }

    private static func loadLocalDatabase() -> LocalPasswordDatabase {
        let url = localStoreURL()
        guard let data = try? Data(contentsOf: url),
              let database = try? JSONDecoder().decode(LocalPasswordDatabase.self, from: data) else {
            return LocalPasswordDatabase()
        }
        return database
    }

    private static func persistLocalDatabase(_ database: LocalPasswordDatabase) {
        let url = localStoreURL()
        guard let data = try? JSONEncoder().encode(database) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func normalize(_ password: String) -> String {
        password
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private static func stableAccountKey(for host: SSHHost) -> String {
        let normalizedHost = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUser = host.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "ssh.\(normalizedUser)@\(normalizedHost):\(host.port)"
    }

    private static func legacyAccountKey(for host: SSHHost) -> String {
        "host.\(host.id.uuidString)"
    }
}
