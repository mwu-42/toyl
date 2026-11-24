import CryptoKit
import Foundation

/// toyl.json on the disk, shared by everything that works on it: the app, the `toyl` command,
/// the MCP server and Oyl. Each change is made on the latest copy of the file, under a lock on
/// its folder (the same lock Oyl takes), and the file's replaced whole, so nobody's change is
/// lost and nobody ever reads half a file. toyl.md is kept in step on the way: edits made there
/// are taken in first, and it's written again from what's saved.
final class Disk: @unchecked Sendable {
    let folder: URL
    var file: URL { folder.appendingPathComponent("toyl.json") }
    var backup: URL { folder.appendingPathComponent("toyl.backup.json") }
    var backups: URL { folder.appendingPathComponent("backups", isDirectory: true) }
    let queue = DispatchQueue(label: "toyl.disk", qos: .userInitiated)
    /// Keeps toyl.md in step (on unless a test turns it off).
    var mirrors = true

    init(folder: URL = Paths.home) {
        self.folder = folder
    }

    struct Outcome {
        var doc: Doc?
        var rev = ""
        /// The file as it was before this save.
        var before: Doc?
        /// Whether what's saved is different (not just laid out differently).
        var changed = false
        var missing = false
        var trouble: String?
        /// The file's signature straight after this save, taken under the lock (so a write by
        /// Oyl a moment later still reads as a change).
        var signature: [Int] = []
    }

    /// Changes whenever the file does, whether it's replaced or written over.
    func signature() -> [Int] { Self.signature(of: file) }

    static func signature(of url: URL) -> [Int] {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return [] }
        return [Int(truncatingIfNeeded: info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }

    /// The file as it is (no lock: it's only ever replaced whole).
    func read() -> Outcome {
        guard FileManager.default.fileExists(atPath: file.path) else { return Outcome(missing: true) }
        guard let raw = try? Data(contentsOf: file) else { return Outcome(trouble: "toyl.json is there but can't be read") }
        guard let doc = Doc(data: raw) else { return Outcome(trouble: Self.unreadable) }
        return Outcome(doc: doc, rev: Self.rev(raw))
    }

    /// Makes `edit` on the file as it is now, and saves it if anything changed. The first time,
    /// the file's made: from tod's data if tod's here, else empty.
    @discardableResult
    func save(_ edit: (inout Doc) -> Void) -> Outcome {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return Outcome(trouble: "can't make toyl's folder: \(error.localizedDescription)")
        }
        let lock = Darwin.open(folder.path, O_RDONLY)
        guard lock >= 0 else { return Outcome(trouble: "can't open toyl's folder") }
        defer { close(lock) }    // which unlocks it
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { return Outcome(trouble: "can't lock toyl's folder") }
        }

        // Only a file that isn't there at all starts a new list: one that can't be read just now
        // (busy, no permission) is never written over.
        let raw: Data?
        if FileManager.default.fileExists(atPath: file.path) {
            guard let read = try? Data(contentsOf: file) else { return Outcome(trouble: "toyl.json is there but can't be read") }
            raw = read
        } else {
            raw = nil
        }
        let current: Doc
        if let raw {
            guard let doc = Doc(data: raw) else { return Outcome(trouble: Self.unreadable) }
            current = doc
        } else {
            current = Importer.seed()
        }
        var doc = current
        let now = Date()
        let ingested = mirrors && Mirror.ingest(into: &doc, folder: folder, now: now)
        edit(&doc)
        doc.normalize()
        guard let out = doc.data() else { return Outcome(trouble: "couldn't save toyl.json") }
        var rev = raw.map(Self.rev) ?? ""
        var changed = false
        if out != raw {
            do {
                try write(out, replacing: raw)
            } catch {
                return Outcome(doc: current, rev: rev, trouble: "couldn't save toyl.json: \(error.localizedDescription)")
            }
            rev = Self.rev(out)
            changed = !doc.isSame(as: current)
        }
        if mirrors { Mirror.refresh(doc, rev: rev, folder: folder, force: ingested) }
        return Outcome(doc: doc, rev: rev, before: current, changed: changed, signature: signature())
    }

    /// Takes in any edit made to toyl.md, and writes it again if it's behind (after Oyl's
    /// changed the list, say).
    @discardableResult
    func sync() -> Outcome { save { _ in } }

    /// Replaced whole. The old file goes to toyl.backup.json at most every ten minutes (as Oyl
    /// keeps tod's), and the first save of each day keeps a copy in backups/, a fortnight's worth.
    private func write(_ body: Data, replacing old: Data?) throws {
        let files = FileManager.default
        if let old {
            let backedUp = (try? files.attributesOfItem(atPath: backup.path))?[.modificationDate] as? Date
            if backedUp.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                try? old.write(to: backup, options: .atomic)
            }
            let today = backups.appendingPathComponent("toyl-\(Day.today()).json")
            if !files.fileExists(atPath: today.path) {
                try? files.createDirectory(at: backups, withIntermediateDirectories: true)
                try? old.write(to: today, options: .atomic)
                let kept = ((try? files.contentsOfDirectory(atPath: backups.path)) ?? [])
                    .filter { $0.hasPrefix("toyl-") && $0.hasSuffix(".json") }.sorted()
                for name in kept.dropLast(14) { try? files.removeItem(at: backups.appendingPathComponent(name)) }
            }
        }
        try body.write(to: file, options: .atomic)
    }

    static let unreadable = "toyl.json can't be read: it isn't valid json. fix it, or put toyl.backup.json back in its place"

    /// A save's name: the start of its SHA-256 (as tod and Oyl name them).
    static func rev(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ text: String) -> String { rev(Data(text.utf8)) }
}

/// Where a list starts: empty, the inbox and ideas ready.
enum Importer {
    static func seed() -> Doc { Doc.blank() }
}
