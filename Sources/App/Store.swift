import AppKit
import Combine
import SwiftUI

/// The list, for the window: each change shows at once, then is saved on the latest copy of the
/// file (so what Oyl, the command line or an agent saved meanwhile isn't lost), and what they
/// save shows up here within a moment. Changes can be undone (⌘Z) and redone.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var snap = Snapshot()
    /// What's wrong, if the list can't be read or a change couldn't be saved.
    @Published private(set) var trouble: String?
    let undoManager = UndoManager()
    let disk: Disk
    /// Told once each change (or one made elsewhere) has landed.
    var onChange: [(Snapshot) -> Void] = []

    private(set) var doc = Doc.blank()
    private var pending = 0
    private var seen: [Int] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var soon: Timer?
    private var markdownSoon: Timer?
    private var poll: Timer?

    init(disk: Disk = Disk()) {
        self.disk = disk
        undoManager.levelsOfUndo = 100
        let first = disk.sync()
        if let saved = first.doc {
            doc = saved
            seen = disk.signature()
        }
        trouble = first.trouble
        snap = Snapshot(doc)
        watch()
        // In case the folder's watch misses something.
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    // MARK: - changing

    /// Makes `edit` here at once and saves it. `name` is what Undo says ("undo check off").
    func change(_ name: String = "change", undoable: Bool = true, _ edit: @escaping (inout Doc) -> Void) {
        let before = doc
        var after = doc
        edit(&after)
        after.normalize()
        guard !after.isSame(as: before) else { return }
        doc = after
        snap = Snapshot(doc)
        if undoable { registerUndo(name, before: before, after: after) }
        pending += 1
        let disk = self.disk
        disk.queue.async { [weak self] in
            let outcome = disk.save(edit)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.saved(outcome) } }
        }
    }

    private func saved(_ outcome: Disk.Outcome) {
        pending -= 1
        if let trouble = outcome.trouble {
            self.trouble = trouble
            if pending == 0 { reload() }
            return
        }
        trouble = nil
        if pending == 0, let saved = outcome.doc {
            seen = disk.signature()
            if !saved.isSame(as: doc) {
                doc = saved
                snap = Snapshot(doc)
            }
        }
        for told in onChange { told(snap) }
    }

    /// Undo puts back just what the change changed (the tasks, lists, groups or filters it
    /// touched), on the list as it is by then, so what's changed elsewhere since stays.
    private func registerUndo(_ name: String, before: Doc, after: Doc) {
        let restore = Self.inverse(from: after, to: before)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.change(name, restore) }
        }
        undoManager.setActionName(name)
    }

    private static func inverse(from after: Doc, to before: Doc) -> (inout Doc) -> Void {
        let a = after.taskEntries, b = before.taskEntries
        var tasks: [String: [String: Any]?] = [:]
        for id in Set(a.keys).union(b.keys) {
            if let x = a[id], let y = b[id], NSDictionary(dictionary: x).isEqual(to: y) { continue }
            tasks.updateValue(b[id], forKey: id)
        }
        var parts: [String: Any?] = [:]
        for key in ["lists", "groups", "filters"] {
            let x = after.json[key] as? [Any] ?? [], y = before.json[key] as? [Any] ?? []
            if !NSArray(array: x).isEqual(to: y) { parts.updateValue(before.json[key], forKey: key) }
        }
        return { doc in
            for (id, entry) in tasks { doc[task: id] = entry }
            for (key, value) in parts { doc.json[key] = value }
        }
    }

    // MARK: - the usual changes

    @discardableResult
    func add(_ draft: TaskDraft) -> String {
        let id = UID.make()
        change("add") { $0.addTask(draft, id: id) }
        return id
    }

    func toggle(_ ids: [String]) {
        let tasks = ids.compactMap { snap.task($0) }
        guard !tasks.isEmpty else { return }
        // A mix: check them all off.
        let done = !tasks.allSatisfy(\.done)
        let next = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, UID.make()) })
        change(done ? "check off" : "uncheck") { doc in
            for task in tasks { doc.setDone(task.id, done, nextId: next[task.id]!) }
        }
    }

    func update(_ id: String, _ name: String = "change", _ patch: TaskPatch) {
        change(name) { $0.updateTask(id, patch) }
    }

    func update(_ ids: [String], _ name: String = "change", _ patch: (TaskModel) -> TaskPatch) {
        let patches = ids.compactMap { id in snap.task(id).map { (id, patch($0)) } }
        change(name) { doc in for (id, p) in patches { doc.updateTask(id, p) } }
    }

    func delete(_ ids: [String]) {
        change(ids.count == 1 ? "delete" : "delete \(ids.count)") { doc in for id in ids { doc.deleteTask(id) } }
    }

    func place(_ ids: [String], list: String, section: String?, before: String?) {
        let section = section ?? snap.list(list)?.firstSection ?? ""
        change("move") { $0.place(ids, list: list, section: section, before: before) }
    }

    // MARK: - changes made elsewhere

    /// Watches toyl's folder: each save replaces the file whole, which changes the folder.
    private func watch() {
        try? FileManager.default.createDirectory(at: disk.folder, withIntermediateDirectories: true)
        let folder = Darwin.open(disk.folder.path, O_EVTONLY)
        guard folder >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: [.write, .delete, .rename], queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let watcher = self.watcher else { return }
                if !watcher.data.isDisjoint(with: [.delete, .rename]) {
                    watcher.cancel()
                    self.watcher = nil
                }
                self.soon?.invalidate()
                self.soon = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                }
            }
        }
        watcher.setCancelHandler { close(folder) }
        watcher.resume()
        self.watcher = watcher
    }

    private func check() {
        if watcher == nil { watch() }
        if disk.signature() != seen { reload() }
        // toyl.md edited: taken in once it's settled (an editor may write it in a few goes).
        if pending == 0, markdownSoon == nil, Mirror.isEdited(folder: disk.folder) {
            markdownSoon = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.markdownSoon = nil
                    self.syncFile()
                }
            }
        }
    }

    /// Saves nothing, but takes in toyl.md and writes it again if it's behind.
    func syncFile() {
        pending += 1
        let disk = self.disk
        disk.queue.async { [weak self] in
            let outcome = disk.sync()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.saved(outcome) } }
        }
    }

    private func reload() {
        let disk = self.disk
        let signature = disk.signature()
        disk.queue.async { [weak self] in
            let read = disk.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pending == 0 else { return }
                    if let trouble = read.trouble {
                        self.trouble = trouble
                        return
                    }
                    guard let found = read.doc else { return }
                    self.seen = signature
                    self.trouble = nil
                    if !found.isSame(as: self.doc) {
                        self.doc = found
                        // What an agent, the command line or Oyl changed eases in.
                        withAnimation(.easeOut(duration: 0.22)) { self.snap = Snapshot(found) }
                        for told in self.onChange { told(self.snap) }
                        // Oyl saves straight to the file: toyl.md catches up.
                        if Mirror.isEdited(folder: disk.folder) == false { self.syncFile() }
                    }
                }
            }
        }
    }
}
