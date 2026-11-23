import Foundation

/// A task to add: what quick add, the command line or an AI asked for.
struct TaskDraft {
    enum Position { case top, bottom }

    var title: String
    var notes = ""
    var due: String?
    var time: String?
    var target: String?
    var listId: String?
    /// A list to make (or find by this name) when `listId` isn't given.
    var newListName: String?
    var sectionId: String?
    var tags: [String] = []
    var pinned = false
    var someday = false
    var repeats: TodRepeat?
    var duration: Int?
    var subtasks: [String] = []
    var source: String?
    /// The email it's from, when it's pulled from one.
    var email: MailLink?
    /// The Canvas assignment it's for.
    var canvas: CanvasLink?
    var position: Position = .top

    init(title: String) { self.title = title }
}

/// What to change about a task. A field left nil stays as it is; a double optional set to
/// `.some(nil)` takes it off.
struct TaskPatch {
    var title: String?
    var notes: String?
    var due: String??
    var time: String??
    var target: String??
    var kept: Date??
    var listId: String?
    var sectionId: String?
    var tags: [String]?
    var addTags: [String] = []
    var removeTags: [String] = []
    var pinned: Bool?
    var someday: Bool?
    var repeats: TodRepeat??
    var duration: Int??
    var subtasks: [Subtask]?
    var event: EventLink??
    var spentDelta: Int?
    var order: Double?
    var done: Bool?
    /// The id the next of it gets, if it repeats and this checks it off (made here, so a change
    /// made twice, on screen and then on the file, makes the same one).
    var nextId = UID.make()

    init() {}
}

/// toyl's saved data, all of it, as JSON. It's tod's format (lists with lanes, tasks keyed by
/// id), so Oyl reads and writes it just as it did tod's, grown with what toyl adds: tags, pins,
/// someday, durations, time spent, calendar links, groups, saved filters and timers. Whatever
/// toyl doesn't know about is carried along as it was read.
struct Doc {
    static let schema = 1
    static let defaultNames: Set<String> = ["Inbox", "Brain dump", "Unsorted", "To do", "In progress", "Done", "Next up", "Waiting on"]

    var json: [String: Any]

    init(json: [String: Any]) {
        self.json = json
        normalize()
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else { return nil }
        self.init(json: json)
    }

    static func blank() -> Doc {
        Doc(json: ["version": 3, "lists": [Any](), "tasks": [String: Any](), "settings": ["weekStart": 1]])
    }

    /// Laid out for reading, keys sorted, so each save of the same thing is the same file (and a
    /// diff of two saves shows just what changed).
    func data() -> Data? {
        try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func isSame(as other: Doc) -> Bool { NSDictionary(dictionary: json).isEqual(to: other.json) }

    /// What toyl and Oyl count on being there: the inbox, the brain dump (its first folder
    /// "Unsorted"), a section in every list, a tasks table and the week's first day.
    mutating func normalize() {
        if json["version"] == nil { json["version"] = 3 }
        if (json["toyl"] as? NSNumber)?.intValue != Self.schema { json["toyl"] = Self.schema }
        if json["importedFrom"] != nil { json["importedFrom"] = nil }
        var lists = (json["lists"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        if !lists.contains(where: { $0["id"] as? String == ListModel.inbox }) {
            lists.insert(["id": ListModel.inbox, "name": "inbox", "color": "#5a5a5a",
                          "columns": [["id": "inbox-main", "name": "inbox"]]], at: 0)
        }
        if let index = lists.firstIndex(where: { $0["id"] as? String == ListModel.dump }) {
            var dump = lists[index]
            if dump["kind"] as? String != "dump" { dump["kind"] = "dump" }
            var columns = (dump["columns"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            if columns.first?["id"] as? String != ListModel.dumpUnsorted {
                columns.removeAll { $0["id"] as? String == ListModel.dumpUnsorted }
                columns.insert(["id": ListModel.dumpUnsorted, "name": "unsorted"], at: 0)
                dump["columns"] = columns
            }
            lists[index] = dump
        } else {
            lists.insert(["id": ListModel.dump, "kind": "dump", "name": "brain dump", "color": "#8c8c8c",
                          "columns": [["id": ListModel.dumpUnsorted, "name": "unsorted"]]], at: 0)
        }
        for index in lists.indices {
            let columns = (lists[index]["columns"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            if !columns.contains(where: { $0["id"] is String }) {
                let id = lists[index]["id"] as? String ?? "list"
                let main: [String: Any] = ["id": "\(id)-main", "name": "to do"]
                lists[index]["columns"] = [main] + columns
            }
        }
        // tod's and Oyl's own names for things, which tod always showed in lower case: lower
        // case here too (what you named yourself is left as you typed it).
        for index in lists.indices {
            if let name = lists[index]["name"] as? String, Self.defaultNames.contains(name) { lists[index]["name"] = name.lowercased() }
            guard let columns = lists[index]["columns"] as? [Any],
                  columns.contains(where: { Self.defaultNames.contains(($0 as? [String: Any])?["name"] as? String ?? "") }) else { continue }
            lists[index]["columns"] = columns.map { column -> Any in
                guard var column = column as? [String: Any], let name = column["name"] as? String, Self.defaultNames.contains(name) else { return column }
                column["name"] = name.lowercased()
                return column
            }
        }
        json["lists"] = lists
        if !(json["tasks"] is [String: Any]) { json["tasks"] = [String: Any]() }
        var settings = json["settings"] as? [String: Any] ?? [:]
        if settings["weekStart"] == nil {
            settings["weekStart"] = 1
            json["settings"] = settings
        }
    }

    // MARK: - reading

    var listEntries: [[String: Any]] { (json["lists"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    var taskEntries: [String: [String: Any]] {
        (json["tasks"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    /// Each list's section ids, in order (the first list with an id, if two share one, as tod
    /// has it).
    var sectionIds: [String: [String]] {
        var found: [String: [String]] = [:]
        for list in listEntries {
            guard let id = list["id"] as? String, found[id] == nil else { continue }
            found[id] = (list["columns"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["id"] as? String }
        }
        return found
    }

    var lists: [ListModel] {
        var seen = Set<String>()
        return listEntries.compactMap(ListModel.init(entry:)).filter { seen.insert($0.id).inserted }
    }

    var tasks: [TaskModel] {
        let sections = sectionIds
        return taskEntries.map { TaskModel(id: $0.key, entry: $0.value, sections: sections) }
    }

    func task(_ id: String) -> TaskModel? {
        taskEntries[id].map { TaskModel(id: id, entry: $0, sections: sectionIds) }
    }

    func list(_ id: String) -> ListModel? { lists.first { $0.id == id } }

    var groups: [GroupModel] { (json["groups"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(GroupModel.init(entry:)) } }
    var filters: [FilterModel] { (json["filters"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(FilterModel.init(entry:)) } }
    var timers: [TimerModel] { (json["timers"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(TimerModel.init(entry:)) } }
    var timerLog: [TimerEntry] { (json["timerLog"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(TimerEntry.init(entry:)) } }

    /// The week's first day (0 Sunday, 1 Monday), for "next week" and "next fri".
    var weekStart: Int { ((json["settings"] as? [String: Any])?["weekStart"] as? NSNumber)?.intValue ?? 1 }

    /// Every tag on an open task, with how many, most used first.
    var tags: [(name: String, count: Int)] { Self.tags(of: tasks) }

    static func tags(of tasks: [TaskModel]) -> [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for task in tasks where !task.done {
            for tag in task.tags {
                let key = tag.lowercased()
                counts[key] = (counts[key]?.name ?? tag, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.lowercased() < $1.name.lowercased() }
    }

    /// A list called `name` (any case), if there is one.
    func list(named name: String) -> ListModel? {
        let name = name.trimmingCharacters(in: .whitespaces)
        return lists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - tasks

    subscript(task id: String) -> [String: Any]? {
        get { (json["tasks"] as? [String: Any])?[id] as? [String: Any] }
        set {
            var tasks = json["tasks"] as? [String: Any] ?? [:]
            tasks[id] = newValue
            json["tasks"] = tasks
        }
    }

    /// Adds a task (at the top of its section, unless asked for the bottom), in its list, a list
    /// made for `newListName`, or the inbox. A time with no day is today, as in tod. Its id.
    @discardableResult
    mutating func addTask(_ draft: TaskDraft, id: String = UID.make(), now: Date = Date()) -> String {
        let ms = Moment.ms(now)
        var listId = draft.listId.flatMap { sectionIds[$0] != nil ? $0 : nil }
        if listId == nil, let name = draft.newListName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            listId = list(named: name)?.id ?? addList(name: name, now: now)
        }
        let list = listId ?? ListModel.inbox
        let sections = sectionIds[list] ?? []
        let section = draft.sectionId.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first ?? ""
        let due = draft.due ?? (draft.time == nil ? nil : Day.today(now))
        var entry: [String: Any] = [
            "id": id, "listId": list, "columnId": section, "title": draft.title, "notes": draft.notes,
            "due": due ?? NSNull(), "time": draft.time ?? NSNull(), "subtasks": draft.subtasks.map { Subtask(title: $0).entry },
            "done": false, "doneAt": NSNull(), "createdAt": ms, "updatedAt": ms,
            "order": Self.number(draft.position == .top ? topOrder(in: section) : bottomOrder(in: section)),
        ]
        if let target = draft.target { entry["target"] = target }
        if !draft.tags.isEmpty { entry["tags"] = TaskModel.tags(draft.tags) }
        if draft.pinned { entry["pinned"] = true }
        if draft.someday { entry["someday"] = true }
        if let repeats = draft.repeats { entry["repeat"] = repeats.rawValue }
        if let duration = draft.duration, duration > 0 { entry["duration"] = duration }
        if let source = draft.source { entry["source"] = source }
        if let email = draft.email { entry["email"] = email.entry }
        if let canvas = draft.canvas { entry["canvas"] = canvas.entry }
        self[task: id] = entry
        return id
    }

    mutating func updateTask(_ id: String, _ p: TaskPatch, now: Date = Date()) {
        guard var e = self[task: id] else { return }
        let before = e
        if let title = p.title { e["title"] = title }
        if let notes = p.notes { e["notes"] = notes }
        if let due = p.due { e["due"] = due ?? NSNull() }
        if let time = p.time {
            e["time"] = time ?? NSNull()
            if time != nil, TaskModel.text(e["due"]) == nil { e["due"] = Day.today(now) }
        }
        if let target = p.target { e["target"] = target }
        if let kept = p.kept { e["kept"] = kept.map(Moment.ms) }
        if p.tags != nil || !p.addTags.isEmpty || !p.removeTags.isEmpty {
            var tags = p.tags ?? TaskModel.tags(e["tags"])
            tags += p.addTags
            let removed = Set(p.removeTags.map { $0.lowercased() })
            tags = TaskModel.tags(tags).filter { !removed.contains($0.lowercased()) }
            e["tags"] = tags.isEmpty ? nil : tags
        }
        if let pinned = p.pinned { e["pinned"] = pinned ? true : nil }
        if let someday = p.someday { e["someday"] = someday ? true : nil }
        if let repeats = p.repeats { e["repeat"] = repeats?.rawValue }
        if let duration = p.duration { e["duration"] = duration.flatMap { $0 > 0 ? $0 : nil } }
        if let subtasks = p.subtasks { e["subtasks"] = subtasks.map(\.entry) }
        if let event = p.event { e["event"] = event.map(\.entry) }
        if let delta = p.spentDelta, delta != 0 { e["spent"] = max(((e["spent"] as? NSNumber)?.intValue ?? 0) + delta, 0) }
        if let order = p.order { e["order"] = Self.number(order) }
        if p.listId != nil || p.sectionId != nil {
            let current = e["listId"] as? String ?? ListModel.inbox
            let list = p.listId.flatMap { sectionIds[$0] != nil ? $0 : nil } ?? current
            let sections = sectionIds[list] ?? []
            let currentSection = e["columnId"] as? String ?? ""
            let section = p.sectionId.flatMap { sections.contains($0) ? $0 : nil }
                ?? (list == current && sections.contains(currentSection) ? currentSection : sections.first ?? "")
            if list != current || section != currentSection {
                e["listId"] = list
                e["columnId"] = section
                if p.order == nil { e["order"] = Self.number(topOrder(in: section, except: id)) }
            }
        }
        if !NSDictionary(dictionary: e).isEqual(to: before) { e["updatedAt"] = Moment.ms(now) }
        self[task: id] = e
        if let done = p.done { setDone(id, done, now: now, nextId: p.nextId) }
    }

    /// Checks a task off (or back on). A repeating one comes back, due its next time, as Oyl
    /// brings it back.
    mutating func setDone(_ id: String, _ done: Bool, now: Date = Date(), nextId: String = UID.make()) {
        guard var e = self[task: id], e["done"] as? Bool ?? false != done else { return }
        let ms = Moment.ms(now)
        e["done"] = done
        e["doneAt"] = done ? ms : NSNull()
        e["updatedAt"] = ms
        self[task: id] = e
        if done {
            repeatNext(after: id, as: nextId, today: Day.today(now), at: ms)
        } else if e["repeated"] as? Bool == true {
            // Put back: the next of it goes too, if it's not been touched since it came, so
            // checking it off again brings it back once, not twice.
            if let found = taskEntries.first(where: { $0.value["repeatOf"] as? String == id }),
               found.value["done"] as? Bool != true, (found.value["updatedAt"] as? NSNumber) == (found.value["createdAt"] as? NSNumber) {
                self[task: found.key] = nil
                var back = self[task: id]!
                back["repeated"] = nil
                self[task: id] = back
            }
        }
    }

    mutating func deleteTask(_ id: String) {
        self[task: id] = nil
        // Its timers carry on, as plain timers.
        if var timers = json["timers"] as? [Any] {
            for index in timers.indices {
                if var timer = timers[index] as? [String: Any], timer["task"] as? String == id {
                    timer["task"] = nil
                    timers[index] = timer
                }
            }
            json["timers"] = timers
        }
    }

    /// Puts tasks in a section (in order, before `before`, or at its end), numbering the
    /// section's tasks afresh.
    mutating func place(_ ids: [String], list listId: String, section sectionId: String, before: String?, now: Date = Date()) {
        guard let sections = sectionIds[listId] else { return }
        let section = sections.contains(sectionId) ? sectionId : sections.first ?? ""
        let moving = ids.filter { self[task: $0] != nil }
        guard !moving.isEmpty else { return }
        let movingSet = Set(moving)
        var rest = tasks.filter { $0.listId == listId && $0.sectionId == section && !movingSet.contains($0.id) }
            .sorted { ($0.order, $0.createdAt, $0.id) < ($1.order, $1.createdAt, $1.id) }
            .map(\.id)
        let at = before.flatMap { rest.firstIndex(of: $0) } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        let ms = Moment.ms(now)
        for (index, id) in rest.enumerated() {
            guard var e = self[task: id] else { continue }
            let moved = movingSet.contains(id)
            if moved {
                e["listId"] = listId
                e["columnId"] = section
                e["updatedAt"] = ms
            }
            if (e["order"] as? NSNumber)?.doubleValue != Double(index) || moved {
                e["order"] = index
                self[task: id] = e
            }
        }
    }

    /// Once a repeating task's done, the next of it: due its next time, the same otherwise
    /// (subtasks unticked), at the top of its section, or its list's first if it was in one
    /// called Done. The done one's marked "repeated" in the same save, so it only comes back once,
    /// whether toyl or Oyl sees it first. (As Oyl's `repeatNext`, so the two agree.)
    mutating func repeatNext(after id: String, as newId: String, today: String, at ms: Int) {
        guard var task = self[task: id], task["done"] as? Bool == true, task["repeated"] as? Bool != true,
              let repeats = (task["repeat"] as? String).flatMap(TodRepeat.init(rawValue:)) else { return }
        task["repeated"] = true
        self[task: id] = task
        guard !taskEntries.values.contains(where: { $0["repeatOf"] as? String == id }), self[task: newId] == nil else { return }
        let sections = sectionIds
        var list = task["listId"] as? String ?? ""
        if sections[list] == nil { list = ListModel.inbox }
        var lane = task["columnId"] as? String ?? ""
        let laneName = lists.first { $0.id == list }?.sections.first { $0.id == lane }?.name
        if laneName == nil || laneName!.trimmingCharacters(in: .whitespaces).lowercased() == "done" { lane = sections[list]?.first ?? "" }
        let due = TaskModel.text(task["due"])
        var next = repeats.next(after: due ?? today, today: today)
        if next == due { next = repeats.next(after: today, today: today) }
        let subtasks = (task["subtasks"] as? [Any] ?? []).map { item -> Any in
            guard var subtask = item as? [String: Any] else { return item }
            subtask["id"] = UID.make()
            subtask["done"] = false
            return subtask
        }
        var fresh: [String: Any] = [
            "id": newId, "listId": list, "columnId": lane, "title": task["title"] ?? "", "notes": task["notes"] ?? "",
            "due": next, "time": task["time"] ?? NSNull(), "subtasks": subtasks, "done": false, "doneAt": NSNull(),
            "createdAt": ms, "updatedAt": ms, "order": Self.number(topOrder(in: lane)), "repeat": repeats.rawValue, "repeatOf": id,
        ]
        for key in ["tags", "pinned", "duration", "target"] where task[key] != nil {
            fresh[key] = task[key]
        }
        // An aim moves on as far as the deadline did.
        if let target = TaskModel.text(task["target"]), let due, let shift = Day.between(due, next) {
            fresh["target"] = Day.adding(shift, to: target) ?? target
        }
        self[task: newId] = fresh
    }

    // MARK: - lists and sections

    private mutating func editList(_ id: String, _ change: (inout [String: Any]) -> Void) {
        var lists = json["lists"] as? [Any] ?? []
        guard let index = lists.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == id }),
              var list = lists[index] as? [String: Any] else { return }
        change(&list)
        lists[index] = list
        json["lists"] = lists
    }

    /// A new list (after the others), its color the first of tod's not used yet. Its id.
    @discardableResult
    mutating func addList(name: String, color: String? = nil, group: String? = nil, sections: [String] = ["to do"],
                          id: String = UID.make(), now: Date = Date()) -> String {
        let used = Set(listEntries.compactMap { ListModel.hex($0["color"]) })
        let color = color.flatMap { ListModel.hex($0) }
            ?? ListModel.palette.first { !used.contains($0) } ?? ListModel.palette[listEntries.count % ListModel.palette.count]
        let columns = (sections.isEmpty ? ["to do"] : sections).map { ["id": UID.make(), "name": $0] }
        var entry: [String: Any] = ["id": id, "name": name, "color": color, "columns": columns, "createdAt": Moment.ms(now)]
        if let group, groups.contains(where: { $0.id == group }) { entry["group"] = group }
        var all = json["lists"] as? [Any] ?? []
        all.append(entry)
        json["lists"] = all
        if let order = json["order"] as? [Any] { json["order"] = order + [id] }
        return id
    }

    mutating func updateList(_ id: String, name: String? = nil, color: String? = nil, group: String?? = nil,
                             notes: String? = nil, archived: Bool? = nil) {
        editList(id) { list in
            if let name { list["name"] = name }
            if let color = color.flatMap({ ListModel.hex($0) }) { list["color"] = color }
            if let group { list["group"] = group }
            if let notes { list["notes"] = notes.isEmpty ? nil : notes }
            if let archived { list["archived"] = archived ? true : nil }
        }
    }

    /// Takes a list away, its tasks to the inbox (or with it). The inbox and ideas stay.
    mutating func deleteList(_ id: String, keepTasks: Bool = true, now: Date = Date()) {
        guard id != ListModel.inbox, id != ListModel.dump else { return }
        let inboxSection = sectionIds[ListModel.inbox]?.first ?? ""
        for task in tasks where task.listId == id {
            if keepTasks {
                var e = self[task: task.id]!
                e["listId"] = ListModel.inbox
                e["columnId"] = inboxSection
                e["updatedAt"] = Moment.ms(now)
                self[task: task.id] = e
            } else {
                deleteTask(task.id)
            }
        }
        json["lists"] = (json["lists"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? String != id }
        if let order = json["order"] as? [Any] { json["order"] = order.filter { $0 as? String != id } }
        if var layout = json["layout"] as? [String: Any] {
            layout[id] = nil
            json["layout"] = layout
        }
    }

    /// Folds one list into another: its tasks (done ones too) go to the other's first section, and
    /// the list goes.
    mutating func mergeList(_ id: String, into target: String, now: Date = Date()) {
        guard id != target, id != ListModel.inbox, id != ListModel.dump, let section = sectionIds[target]?.first else { return }
        for task in tasks where task.listId == id {
            var e = self[task: task.id]!
            e["listId"] = target
            e["columnId"] = section
            e["updatedAt"] = Moment.ms(now)
            self[task: task.id] = e
        }
        deleteList(id, keepTasks: true, now: now)
    }

    /// Moves a list to come before `before` (or last), among all of them.
    mutating func moveList(_ id: String, before: String?) {
        var lists = json["lists"] as? [Any] ?? []
        guard let from = lists.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == id }) else { return }
        let moving = lists.remove(at: from)
        let to = before.flatMap { b in lists.firstIndex { ($0 as? [String: Any])?["id"] as? String == b } } ?? lists.count
        lists.insert(moving, at: to)
        json["lists"] = lists
    }

    @discardableResult
    mutating func addSection(to listId: String, name: String, id: String = UID.make()) -> String {
        editList(listId) { list in
            var columns = list["columns"] as? [Any] ?? []
            columns.append(["id": id, "name": name] as [String: Any])
            list["columns"] = columns
        }
        return id
    }

    mutating func renameSection(_ id: String, in listId: String, to name: String) {
        editList(listId) { list in
            list["columns"] = (list["columns"] as? [Any] ?? []).map { column in
                guard var column = column as? [String: Any], column["id"] as? String == id else { return column }
                column["name"] = name
                return column
            }
        }
    }

    /// Takes a section away, its tasks into the list's first (or the one before it, if it was first).
    mutating func deleteSection(_ id: String, in listId: String, now: Date = Date()) {
        guard let sections = sectionIds[listId], sections.count > 1, let index = sections.firstIndex(of: id),
              !(listId == ListModel.dump && id == ListModel.dumpUnsorted) else { return }
        let into = index == 0 ? sections[1] : sections[0]
        let ms = Moment.ms(now)
        for task in tasks where task.listId == listId && task.sectionId == id {
            var e = self[task: task.id]!
            e["columnId"] = into
            e["updatedAt"] = ms
            self[task: task.id] = e
        }
        editList(listId) { list in
            list["columns"] = (list["columns"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? String != id }
        }
    }

    // MARK: - groups and filters

    @discardableResult
    mutating func addGroup(name: String, id: String = UID.make()) -> String {
        var groups = json["groups"] as? [Any] ?? []
        groups.append(["id": id, "name": name] as [String: Any])
        json["groups"] = groups
        return id
    }

    mutating func renameGroup(_ id: String, to name: String) {
        json["groups"] = (json["groups"] as? [Any] ?? []).map { group in
            guard var group = group as? [String: Any], group["id"] as? String == id else { return group }
            group["name"] = name
            return group
        }
    }

    /// Takes a group away; its lists stay, ungrouped.
    mutating func deleteGroup(_ id: String) {
        json["groups"] = (json["groups"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? String != id }
        for list in lists where list.group == id { updateList(list.id, group: .some(nil)) }
    }

    @discardableResult
    mutating func addFilter(name: String, query: String, id: String = UID.make()) -> String {
        var filters = json["filters"] as? [Any] ?? []
        filters.append(["id": id, "name": name, "query": query] as [String: Any])
        json["filters"] = filters
        return id
    }

    mutating func updateFilter(_ id: String, name: String? = nil, query: String? = nil) {
        json["filters"] = (json["filters"] as? [Any] ?? []).map { filter in
            guard var filter = filter as? [String: Any], filter["id"] as? String == id else { return filter }
            if let name { filter["name"] = name }
            if let query { filter["query"] = query }
            return filter
        }
    }

    mutating func deleteFilter(_ id: String) {
        json["filters"] = (json["filters"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? String != id }
    }

    // MARK: - timers

    /// Adds a timer, or puts it in place of the one with its id.
    mutating func putTimer(_ timer: TimerModel) {
        var timers = json["timers"] as? [Any] ?? []
        if let index = timers.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == timer.id }) {
            var merged = (timers[index] as? [String: Any] ?? [:]).filter { !TimerModel.fields.contains($0.key) }
            for (key, value) in timer.entry { merged[key] = value }
            timers[index] = merged
        } else {
            timers.append(timer.entry)
        }
        json["timers"] = timers
    }

    mutating func removeTimer(_ id: String) {
        json["timers"] = (json["timers"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? String != id }
    }

    /// Ends a timer: the time it ran goes on its task (if it ran half a minute or more) and into
    /// the log, the latest fifty kept.
    mutating func finishTimer(_ id: String, at now: Date = Date(), seconds: Double? = nil) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        let worked = seconds ?? timer.worked(at: now)
        removeTimer(id)
        if worked >= 30, let task = timer.taskId, self[task: task] != nil {
            var patch = TaskPatch()
            patch.spentDelta = Int(worked.rounded())
            updateTask(task, patch, now: now)
        }
        guard worked >= 1 else { return }
        let entry = TimerEntry(timer: timer, seconds: worked, ended: now)
        var log = json["timerLog"] as? [Any] ?? []
        log.insert(entry.entry, at: 0)
        json["timerLog"] = Array(log.prefix(50))
    }

    // MARK: - order

    func topOrder(in section: String, except id: String? = nil) -> Double {
        let orders = taskEntries.filter { $0.key != id && $0.value["columnId"] as? String == section }
            .map { ($0.value["order"] as? NSNumber)?.doubleValue ?? 0 }
        return orders.isEmpty ? 0 : orders.min()! - 1
    }

    func bottomOrder(in section: String) -> Double {
        let orders = taskEntries.filter { $0.value["columnId"] as? String == section }
            .map { ($0.value["order"] as? NSNumber)?.doubleValue ?? 0 }
        return orders.isEmpty ? 0 : orders.max()! + 1
    }

    /// Whole numbers as whole numbers, as tod writes them.
    static func number(_ value: Double) -> Any {
        value == value.rounded() && abs(value) < 1e15 ? Int(value) : value
    }
}
