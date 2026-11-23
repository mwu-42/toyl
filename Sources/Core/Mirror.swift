import Foundation

/// toyl.md: the whole list as Markdown, written again whenever the list changes, for anything
/// that reads files (an agent, Obsidian, a person) to read it, and edit it: a box ticked, a
/// title or what's after its "—" changed, a line added under a list (read as quick add reads
/// it), a box marked [-] to delete, a heading added for a new list. The {t:…} ids tie each line
/// to its task. toyl takes edits in the next time anything saves (the app does within a moment
/// of the file changing). A line that goes missing isn't taken for a deletion, in case only part
/// of the file was written: deleting is always said, with [-].
enum Mirror {
    static let header = """
        <!-- toyl's list, kept up to date as it changes. edit it and toyl takes the changes in: tick a box \
        ([x]), change a title or what's after its —, add "- [ ] read ch 3 fri #reading" under a list (or a new \
        "## heading" for a new list), indent "- [ ]" under a task for a subtask, or write [-] in a box to delete. \
        keep the {t:…} {l:…} {c:…} ids as they are. dates are yyyy-mm-dd and times 24-hour: "due" is a deadline, \
        "by" an aim (a day to have it done by, roughly), "~30m" how long it takes, "!" pinned. -->
        """

    // MARK: - writing

    static func render(_ doc: Doc, now: Date = Date()) -> String {
        let snap = Snapshot(doc)
        let today = Day.today(now)
        let recent = now.addingTimeInterval(-3 * 86400)
        var lines = ["# toyl", "", header, ""]
        let late = snap.tasks.filter { $0.isLate(at: now) }.count
        let dueToday = snap.tasks.filter { !$0.done && $0.due == today }.count
        let inbox = snap.tasks.filter { !$0.done && $0.listId == ListModel.inbox }.count
        lines.append("> as of \(today): \(dueToday) due today, \(late) late, \(inbox) in the inbox.")
        lines.append("")
        for list in snap.sidebarOrder {
            lines.append("## \(list.displayName) {l:\(list.id)}")
            var about: [String] = []
            if let group = list.group.flatMap({ id in snap.groups.first { $0.id == id } }) { about.append("in " + group.name) }
            if list.archived { about.append("archived") }
            if !about.isEmpty { lines.append("> " + about.joined(separator: " · ")) }
            for line in list.notes.split(separator: "\n", omittingEmptySubsequences: false) where !list.notes.isEmpty {
                lines.append("> " + line)
            }
            let tasks = snap.tasks.filter { $0.listId == list.id && (!$0.done || ($0.doneAt ?? .distantPast) > recent) }
            for section in list.sections {
                let inSection = tasks.filter { $0.sectionId == section.id }
                    .sorted { a, b in a.done != b.done ? !a.done : (a.order, a.createdAt, a.id) < (b.order, b.createdAt, b.id) }
                if list.sections.count > 1 { lines.append("### \(section.name) {c:\(section.id)}") }
                for task in inSection {
                    lines.append("- [\(task.done ? "x" : " ")] \(body(task)) {t:\(task.id)}")
                    for subtask in task.subtasks {
                        lines.append("  - [\(subtask.done ? "x" : " ")] \(oneLine(subtask.title)) {s:\(subtask.id)}")
                    }
                    let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !notes.isEmpty {
                        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) { lines.append("  > " + line) }
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A task's line, between its box and its id: "title — due 2026-11-21 17:00 · #tag".
    static func body(_ task: TaskModel) -> String {
        let meta = self.meta(task)
        return oneLine(task.title) + (meta.isEmpty ? "" : " — " + meta)
    }

    /// What's known about a task, written so quick add reads it back the same.
    static func meta(_ task: TaskModel) -> String {
        var parts: [String] = []
        if let due = task.due { parts.append("due " + due + (task.time.map { " " + $0 } ?? "")) }
        if let target = task.target { parts.append("by " + target) }
        if let repeats = task.repeats { parts.append(repeats.phrase) }
        if let duration = task.duration { parts.append("~" + Format.minutes(duration)) }
        if task.pinned { parts.append("!") }
        if task.someday { parts.append("/idea") }
        if !task.tags.isEmpty { parts.append(task.tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "{t:", with: "{ t:")
    }

    /// Writes toyl.md again if it's behind the list (`rev` is the save it should show), or if
    /// it was edited (`force`, once the edit's been taken in), and notes what was written.
    static func refresh(_ doc: Doc, rev: String, folder: URL, force: Bool = false) {
        let file = folder.appendingPathComponent("toyl.md")
        let stamp = readStamp(folder)
        if !force, stamp?.rev == rev, let current = try? String(contentsOf: file, encoding: .utf8), Disk.hash(current) == stamp?.hash {
            return
        }
        let text = render(doc)
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        writeStamp(folder, hash: Disk.hash(text), rev: rev)
    }

    private static func readStamp(_ folder: URL) -> (hash: String, rev: String)? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(".toyl.md.stamp"), encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }

    private static func writeStamp(_ folder: URL, hash: String, rev: String) {
        try? "\(hash) \(rev)\n".write(to: folder.appendingPathComponent(".toyl.md.stamp"), atomically: true, encoding: .utf8)
    }

    /// Whether toyl.md's been changed since toyl wrote it.
    static func isEdited(folder: URL) -> Bool {
        guard let stamp = readStamp(folder),
              let text = try? String(contentsOf: folder.appendingPathComponent("toyl.md"), encoding: .utf8) else { return false }
        return Disk.hash(text) != stamp.hash
    }

    // MARK: - reading edits

    /// Takes in what's been changed in toyl.md since toyl wrote it, if anything has. Whether it
    /// changed the list.
    static func ingest(into doc: inout Doc, folder: URL, now: Date = Date()) -> Bool {
        guard isEdited(folder: folder),
              let text = try? String(contentsOf: folder.appendingPathComponent("toyl.md"), encoding: .utf8) else { return false }
        return apply(text, to: &doc, now: now)
    }

    static func apply(_ text: String, to doc: inout Doc, now: Date = Date()) -> Bool {
        let original = doc
        var snap = Snapshot(doc)
        var listId: String?
        var sectionId: String?
        var lastTask: String?
        var notes: [String: [String]] = [:]
        var subtasks: [String: [Subtask]] = [:]

        for raw in text.components(separatedBy: .newlines) {
            if let m = match(heading2, raw) {
                let name = m[0] ?? "", id = m[1]
                lastTask = nil
                if let id, let list = snap.list(id) {
                    listId = id
                    if !list.isSpecial, !name.isEmpty, name != list.name { doc.updateList(id, name: name) }
                } else if !name.isEmpty, name.lowercased() != "toyl" {
                    listId = doc.list(named: name)?.id ?? doc.addList(name: name, now: now)
                    snap = Snapshot(doc)
                } else {
                    listId = nil
                }
                sectionId = listId.flatMap { snap.list($0)?.firstSection }
                continue
            }
            if let m = match(heading3, raw), let current = listId, let list = snap.list(current) {
                let name = m[0] ?? "", id = m[1]
                lastTask = nil
                if let id, let section = list.sections.first(where: { $0.id == id }) {
                    sectionId = id
                    if !name.isEmpty, name != section.name { doc.renameSection(id, in: current, to: name) }
                } else if !name.isEmpty {
                    if let same = list.sections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        sectionId = same.id
                    } else {
                        sectionId = doc.addSection(to: current, name: name)
                        snap = Snapshot(doc)
                    }
                }
                continue
            }
            if let m = match(taskLine, raw) {
                let indent = (m[0] ?? "").count, box = m[1] ?? " ", body = (m[2] ?? "").trimmingCharacters(in: .whitespaces)
                let kind = m[3], id = m[4]
                let ticked = box.lowercased() == "x"
                if indent == 0 {
                    if kind == "t", let id, let task = snap.task(id) {
                        if box == "-" {
                            doc.deleteTask(id)
                            lastTask = nil
                            continue
                        }
                        doc.updateTask(id, patch(for: task, body: body, ticked: ticked, list: listId, section: sectionId, weekStart: doc.weekStart, now: now), now: now)
                        lastTask = id
                        subtasks[id] = subtasks[id] ?? task.subtasks
                    } else if id == nil, box != "-", !body.isEmpty {
                        let q = Quick.parse(body, lists: [], now: now, weekStart: doc.weekStart)
                        var draft = q.draft(source: "markdown")
                        if !q.idea { draft.listId = listId ?? ListModel.inbox }
                        draft.sectionId = q.idea ? nil : sectionId
                        draft.position = .bottom
                        let made = doc.addTask(draft, now: now)
                        if ticked { doc.setDone(made, true, now: now) }
                        lastTask = made
                        subtasks[made] = []
                    } else {
                        lastTask = nil
                    }
                } else if let parent = lastTask, var list = subtasks[parent] {
                    if kind == "s", let id, let index = list.firstIndex(where: { $0.id == id }) {
                        if box == "-" {
                            list.remove(at: index)
                        } else {
                            list[index].done = ticked
                            if !body.isEmpty { list[index].title = body }
                        }
                    } else if id == nil, box != "-", !body.isEmpty {
                        list.append(Subtask(title: body, done: ticked))
                    }
                    subtasks[parent] = list
                }
                continue
            }
            if let m = match(noteLine, raw), let lastTask {
                notes[lastTask, default: []].append(m[0] ?? "")
                continue
            }
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty { lastTask = nil }
        }

        for (id, list) in subtasks {
            guard let task = doc.task(id), task.subtasks != list else { continue }
            var p = TaskPatch()
            p.subtasks = list
            doc.updateTask(id, p, now: now)
        }
        for (id, lines) in notes where !lines.isEmpty {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let task = doc.task(id), task.notes.trimmingCharacters(in: .whitespacesAndNewlines) != text else { continue }
            var p = TaskPatch()
            p.notes = text
            doc.updateTask(id, p, now: now)
        }
        return !doc.isSame(as: original)
    }

    /// What a task's line says that's different from the task.
    private static func patch(for task: TaskModel, body: String, ticked: Bool, list: String?, section: String?, weekStart: Int, now: Date) -> TaskPatch {
        var p = TaskPatch()
        if ticked != task.done { p.done = ticked }
        if let list, list != task.listId || (section != nil && section != task.sectionId) {
            p.listId = list
            p.sectionId = section
        }
        guard body != self.body(task) else { return p }
        var title = body
        if let split = body.range(of: " — ", options: .backwards) {
            let meta = String(body[split.upperBound...])
            let q = Quick.parse(meta, lists: [], now: now, weekStart: weekStart)
            // What's after the dash is only what's known about it if that's all it is.
            if q.titleIsEmpty || q.title.allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                title = String(body[..<split.lowerBound])
                if q.due != task.due { p.due = .some(q.due) }
                if q.time != task.time { p.time = .some(q.time) }
                if q.target != task.target { p.target = .some(q.target) }
                if q.repeats != task.repeats { p.repeats = .some(q.repeats) }
                if q.duration != task.duration { p.duration = .some(q.duration) }
                if q.pinned != task.pinned { p.pinned = q.pinned }
                if q.someday != task.someday { p.someday = q.someday }
                if Set(q.tags.map { $0.lowercased() }) != Set(task.tags.map { $0.lowercased() }) { p.tags = q.tags }
            }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != task.title { p.title = title }
        return p
    }

    private static let heading2 = try! NSRegularExpression(pattern: #"^##\s+(.*?)\s*(?:\{l:([A-Za-z0-9_\-]+)\})?\s*$"#)
    private static let heading3 = try! NSRegularExpression(pattern: #"^###\s+(.*?)\s*(?:\{c:([A-Za-z0-9_\-]+)\})?\s*$"#)
    private static let taskLine = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+\[( |x|X|-)\]\s?(.*?)\s*(?:\{([ts]):([A-Za-z0-9_\-]+)\})?\s*$"#)
    private static let noteLine = try! NSRegularExpression(pattern: #"^\s+>\s?(.*)$"#)

    /// The groups a pattern caught (nil for one that caught nothing), if it matches.
    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String?]? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { index in
            let range = m.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }
}
