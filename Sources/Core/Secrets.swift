import Foundation
import Security

/// The little toyl keeps that's secret (its Google sign-in): in the login keychain, not in the
/// folder agents read. A `TOYL_HOME` list keeps its own in that folder instead, so trying things
/// out never touches the real sign-in.
enum Secrets {
    static let service = "local.toyl"

    private static func file(_ name: String) -> URL { Paths.home.appendingPathComponent(".secret-\(name)") }

    static func read(_ name: String) -> Data? {
        guard Paths.isReal else { return try? Data(contentsOf: file(name)) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    @discardableResult
    static func write(_ data: Data, _ name: String) -> Bool {
        guard Paths.isReal else {
            try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            return (try? data.write(to: file(name), options: .atomic)) != nil
        }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        if SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var adding = item
        adding[kSecValueData as String] = data
        adding[kSecAttrLabel as String] = "toyl (\(name))"
        return SecItemAdd(adding as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) {
        guard Paths.isReal else { try? FileManager.default.removeItem(at: file(name)); return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name] as CFDictionary)
    }

    static func decode<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        read(name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func encode<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { write(data, name) }
    }
}
