import Foundation

/// The little toyl keeps that's secret (its Google and Microsoft sign-ins): in files only your
/// account can read, in a folder of their own (`~/Library/Application Support/toyl-private/`), not
/// in toyl's folder, which agents read. Not the keychain: every new build of toyl looks like a new
/// app to it, so it asked for permission again each time. A `TOYL_HOME` list keeps its own in that
/// folder instead, so trying things out never touches the real sign-in.
enum Secrets {
    static var folder: URL {
        guard Paths.isReal else { return Paths.home }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("toyl-private", isDirectory: true)
    }

    private static func file(_ name: String) -> URL { folder.appendingPathComponent(".secret-\(name)") }

    static func read(_ name: String) -> Data? { try? Data(contentsOf: file(name)) }

    @discardableResult
    static func write(_ data: Data, _ name: String) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if Paths.isReal { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            try data.write(to: file(name), options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
            return true
        } catch {
            return false
        }
    }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: file(name)) }

    static func decode<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        read(name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func encode<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { write(data, name) }
    }
}
