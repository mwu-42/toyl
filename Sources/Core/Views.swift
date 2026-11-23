import Foundation

/// Everything in toyl.json, read into types once, for showing.
struct Snapshot {
    var lists: [ListModel] = []
    var tasks: [TaskModel] = []
    var byId: [String: TaskModel] = [:]
    var listsById: [String: ListModel] = [:]
    var groups: [GroupModel] = []
    var filters: [FilterModel] = []
    var timers: [TimerModel] = []
    var timerLog: [TimerEntry] = []
    var tags: [(name: String, count: Int)] = []
    var weekStart = 1

    init() {}

    init(_ doc: Doc) {
        lists = doc.lists
        tasks = doc.tasks
        byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        listsById = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        groups = doc.groups
        filters = doc.filters
        timers = doc.timers
        timerLog = doc.timerLog
        tags = Doc.tags(of: tasks)
        weekStart = doc.weekStart
    }

    func list(_ id: String) -> ListModel? { listsById[id] }
    func task(_ id: String) -> TaskModel? { byId[id] }

    /// Your own lists (not the inbox or ideas), in order.
    var ownLists: [ListModel] { lists.filter { !$0.isSpecial } }

    /// Lists in the order the sidebar shows them: the inbox, each group's, the ungrouped, ideas.
    var sidebarOrder: [ListModel] {
        let own = ownLists
        let grouped = groups.flatMap { group in own.filter { $0.group == group.id } }
        let groupIds = Set(groups.map(\.id))
        let loose = own.filter { $0.group.map { !groupIds.contains($0) } ?? true }
        return lists.filter(\.isInbox) + grouped + loose + lists.filter(\.isDump)
    }

    /// Which tasks have a timer going.
    var timedTasks: Set<String> { Set(timers.compactMap(\.taskId)) }
}

/// A place in the sidebar.
enum Place: Hashable {
    /// (Upcoming and logbook aren't in the window's sidebar; the command line and agents still ask for them.)
    case inbox, today, upcoming, anytime, logbook, ideas, timers
    case list(String), tag(String), filter(String), search

    var key: String {
        switch self {
        case .inbox: return "inbox"
        case .today: return "today"
        case .upcoming: return "upcoming"
        case .anytime: return "anytime"
        case .logbook: return "logbook"
        case .ideas: return "ideas"
        case .timers: return "timers"
        case .list(let id): return "list:" + id
        case .tag(let tag): return "tag:" + tag.lowercased()
        case .filter(let id): return "filter:" + id
        case .search: return "search"
        }
    }

    init?(key: String) {
        switch key {
        case "inbox": self = .inbox
        case "today": self = .today
        case "upcoming": self = .upcoming
        case "anytime", "all": self = .anytime
        case "logbook", "done": self = .logbook
        case "ideas", "idea", "someday": self = .ideas
        case "timers": self = .timers
        default:
            if key.hasPrefix("list:") { self = .list(String(key.dropFirst(5))) }
            else if key.hasPrefix("tag:") { self = .tag(String(key.dropFirst(4))) }
            else if key.hasPrefix("filter:") { self = .filter(String(key.dropFirst(7))) }
            else { return nil }
        }
    }

    /// The sidebar's: then ideas and timers.
    /// "all" (`anytime` inside) first: it's where the window opens.
    static let smart: [Place] = [.anytime, .inbox, .today]
}

enum SortMode: String, CaseIterable, Identifiable {
    case auto, due, created, title, manual
    var id: String { rawValue }
    var name: String {
        switch self {
        case .auto: return "auto (what's pressing first)"
        case .due: return "by date"
        case .created: return "newest first"
        case .title: return "a to z"
        case .manual: return "by hand"
        }
    }
}

enum GroupMode: String, CaseIterable, Identifiable {
    case none, section, list, day, tag, project
    var id: String { rawValue }
    /// What the window offers (sections aren't shown any more; projects are).
    static let offered: [GroupMode] = [.project, .none, .list, .day, .tag]
    var name: String {
        switch self {
        case .none: return "nothing"
        case .section: return "section"
        case .list: return "list"
        case .day: return "day"
        case .tag: return "tag"
        case .project: return "project"
        }
    }
}

/// A run of tasks under one heading.
struct TaskGroup: Identifiable, Equatable {
    let id: String
    var title: String?
    var subtitle: String?
    var tasks: [TaskModel]
    /// Where a task dropped on it goes, if anywhere.
    var listId: String?
    var sectionId: String?
    /// The day it's for (upcoming), to show that day's events by it.
    var day: String?
    var isLate = false
    /// A project's tasks: dropped or added here, they join it; its heading is big.
    var projectId: String?
    var big: Bool { projectId != nil }
}

/// What each place holds, in what order, under what headings.
enum Views {
    static func defaultSort(_ place: Place) -> SortMode {
        switch place {
        case .list, .inbox, .ideas: return .auto
        case .logbook: return .created
        default: return .auto
        }
    }

    static func defaultGroup(_ place: Place) -> GroupMode {
        switch place {
        case .inbox, .list: return .project
        case .upcoming: return .day
        case .anytime, .ideas, .tag, .filter, .search: return .list
        case .today, .logbook, .timers: return .none
        }
    }

    /// The tasks a place holds (done ones only where asked, or in the logbook).
    static func tasks(for place: Place, in snap: Snapshot, query: Query? = nil, showDone: Bool = false, now: Date = Date()) -> [TaskModel] {
        let today = Day.today(now)
        let base: [TaskModel]
        switch place {
        case .inbox:
            base = snap.tasks.filter { $0.listId == ListModel.inbox && !$0.someday && (showDone || !$0.done) }
        case .today:
            base = snap.tasks.filter { isToday($0, today: today, now: now) || (showDone && $0.done && $0.doneAt.map { Day.string($0) == today } == true) }
        case .upcoming:
            base = snap.tasks.filter { !$0.done && !$0.someday && ($0.day.map { $0 > today } ?? false) }
        case .anytime:
            base = snap.tasks.filter { !$0.isIdea && !$0.someday && (showDone || !$0.done) && !(snap.list($0.listId)?.archived ?? false) }
        case .logbook:
            base = snap.tasks.filter(\.done)
        case .ideas:
            // Loose ideas, and anything put off (it keeps its list, to come back to).
            base = snap.tasks.filter { ($0.isIdea || $0.someday) && (showDone || !$0.done) }
        case .timers:
            base = []
        case .list(let id):
            base = snap.tasks.filter { $0.listId == id && (showDone || !$0.done) }
        case .tag(let tag):
            base = snap.tasks.filter { $0.hasTag(tag) && (showDone || !$0.done) }
        case .filter(let id):
            let filter = snap.filters.first { $0.id == id }
            let q = Query.parse(filter?.query ?? "", weekStart: snap.weekStart, now: now)
            base = snap.tasks.filter { q.matches($0, in: snap, now: now) }
        case .search:
            base = snap.tasks
        }
        guard let query, !query.isEmpty else { return base }
        return base.filter { query.matches($0, in: snap, now: now, statusDefault: place == .logbook ? .any : nil) }
    }

    /// Due today or before, aimed at today or before, or pinned.
    static func isToday(_ task: TaskModel, today: String, now: Date) -> Bool {
        guard !task.done, !task.someday else { return false }
        if let due = task.due, due <= today { return true }
        if let target = task.target, target <= today { return true }
        return task.pinned
    }

    // MARK: - order

    static func sorted(_ tasks: [TaskModel], by mode: SortMode, now: Date = Date()) -> [TaskModel] {
        let today = Day.today(now)
        switch mode {
        case .auto:
            let keyed: [(task: TaskModel, key: [Double])] = tasks.map { ($0, urgency($0, today: today, now: now)) }
            let ordered = keyed.sorted { a, b in
                if a.key != b.key { return a.key.lexicographicallyPrecedes(b.key) }
                return tiebreak(a.task, b.task)
            }
            return ordered.map(\.task)
        case .due:
            return tasks.sorted { a, b in
                let x = a.dueDate ?? a.targetDate ?? .distantFuture, y = b.dueDate ?? b.targetDate ?? .distantFuture
                return x != y ? x < y : tiebreak(a, b)
            }
        case .created:
            return tasks.sorted { a, b in
                let x = a.done ? (a.doneAt ?? a.createdAt) : a.createdAt, y = b.done ? (b.doneAt ?? b.createdAt) : b.createdAt
                return x != y ? x > y : a.id < b.id
            }
        case .title:
            return tasks.sorted { a, b in
                let order = a.title.localizedCaseInsensitiveCompare(b.title)
                return order != .orderedSame ? order == .orderedAscending : tiebreak(a, b)
            }
        case .manual:
            return tasks.sorted { a, b in a.done != b.done ? !a.done : tiebreak(a, b) }
        }
    }

    private static func tiebreak(_ a: TaskModel, _ b: TaskModel) -> Bool {
        (a.order, -a.createdAt.timeIntervalSince1970, a.id) < (b.order, -b.createdAt.timeIntervalSince1970, b.id)
    }

    /// How pressing a task is, smallest first: late deadlines (the latest first), today's (by
    /// time), pinned, due within three days, aims slipped or this week, later deadlines, later
    /// aims, then the rest by hand. Done ones last. There are no priorities: what's pressing is
    /// what's due.
    static func urgency(_ t: TaskModel, today: String, now: Date) -> [Double] {
        if t.done { return [9, -(t.doneAt ?? t.createdAt).timeIntervalSince1970] }
        if let due = t.due, let moment = t.dueDate {
            if moment < now || due < today { return [0, moment.timeIntervalSince1970] }
            if due == today { return [1, moment.timeIntervalSince1970] }
        }
        if t.pinned { return [2, 0] }
        if let due = t.due, let days = Day.between(today, due), days <= 3, let moment = t.dueDate { return [3, moment.timeIntervalSince1970] }
        if let target = t.target, let days = Day.between(today, target), days <= 6, let moment = t.targetDate { return [4, moment.timeIntervalSince1970] }
        if let moment = t.dueDate { return [5, moment.timeIntervalSince1970] }
        if let moment = t.targetDate { return [6, moment.timeIntervalSince1970] }
        return [7, 0]
    }

    // MARK: - headings

    /// `keepEmpty`: lists with nothing in them still get their heading (in all, unfiltered).
    static func groups(_ tasks: [TaskModel], place: Place, mode: GroupMode, sort: SortMode, snap: Snapshot, now: Date = Date(),
                       keepEmpty: Bool = false) -> [TaskGroup] {
        let today = Day.today(now)
        if place == .today {
            let sorted = Self.sorted(tasks, by: sort, now: now)
            let late = sorted.filter { !$0.done && ($0.isLate(at: now) && $0.due != today || $0.hasSlipped(at: now)) }
            let lateIds = Set(late.map(\.id))
            let rest = sorted.filter { !lateIds.contains($0.id) }
            var out: [TaskGroup] = []
            if !late.isEmpty { out.append(TaskGroup(id: "late", title: "late", tasks: late, isLate: true)) }
            out.append(TaskGroup(id: "today", title: late.isEmpty ? nil : "today", tasks: rest, day: today))
            return out
        }
        if place == .ideas, mode == .list {
            // The loose ideas first, then what's been put off, under the lists it's from.
            let loose = tasks.filter(\.isIdea)
            let putOff = tasks.filter { !$0.isIdea }
            var out = [TaskGroup(id: "ideas", title: putOff.isEmpty ? nil : "loose ideas", tasks: sorted(loose, by: sort, now: now),
                                 listId: ListModel.dump, sectionId: ListModel.dumpUnsorted)]
            for list in snap.sidebarOrder where !list.isDump {
                let fromList = putOff.filter { $0.listId == list.id }
                guard !fromList.isEmpty else { continue }
                out.append(TaskGroup(id: "off:" + list.id, title: list.displayName, tasks: sorted(fromList, by: sort, now: now)))
            }
            return out
        }
        switch mode {
        case .none:
            var group = TaskGroup(id: "all", tasks: sorted(tasks, by: sort, now: now))
            if case .list(let id) = place { group.listId = id; group.sectionId = snap.list(id)?.firstSection }
            if place == .inbox { group.listId = ListModel.inbox; group.sectionId = snap.list(ListModel.inbox)?.firstSection }
            if place == .ideas { group.listId = ListModel.dump; group.sectionId = ListModel.dumpUnsorted }
            return [group]
        case .section:
            let listId: String
            switch place {
            case .list(let id): listId = id
            case .inbox: listId = ListModel.inbox
            case .ideas: listId = ListModel.dump
            default: return groups(tasks, place: place, mode: .list, sort: sort, snap: snap, now: now)
            }
            guard let list = snap.list(listId) else { return [] }
            let showHeadings = list.sections.count > 1
            return list.sections.enumerated().map { index, section in
                TaskGroup(id: "section:" + section.id, title: showHeadings ? section.name : nil,
                          tasks: sorted(tasks.filter { $0.sectionId == section.id }, by: sort, now: now),
                          listId: list.id, sectionId: section.id)
            }
            .filter { !$0.tasks.isEmpty || showHeadings || $0.sectionId == list.firstSection }
        case .project:
            let listId: String
            switch place {
            case .list(let id): listId = id
            case .inbox: listId = ListModel.inbox
            default: return groups(tasks, place: place, mode: .list, sort: sort, snap: snap, now: now, keepEmpty: keepEmpty)
            }
            guard let list = snap.list(listId) else { return [] }
            let known = Set(list.projects.map(\.id))
            let loose = tasks.filter { $0.project.map { !known.contains($0) } ?? true }
            return [TaskGroup(id: "loose:" + listId, tasks: sorted(loose, by: sort, now: now), listId: listId, sectionId: list.firstSection)]
                + list.projects.map { project in
                    TaskGroup(id: "project:" + project.id, title: project.name, tasks: sorted(tasks.filter { $0.project == project.id }, by: sort, now: now),
                              listId: listId, sectionId: list.firstSection, projectId: project.id)
                }
        case .list:
            let order = snap.sidebarOrder
            return order.compactMap { list in
                let inList = tasks.filter { $0.listId == list.id }
                guard !inList.isEmpty || (keepEmpty && !list.isDump && !list.archived) else { return nil }
                return TaskGroup(id: "list:" + list.id, title: list.displayName, tasks: sorted(inList, by: sort, now: now),
                                 listId: list.id, sectionId: list.firstSection)
            }
        case .tag:
            var out: [TaskGroup] = []
            var used = Set<String>()
            for tag in snap.tags.map(\.name) {
                let tagged = tasks.filter { $0.hasTag(tag) && !used.contains($0.id) }
                guard !tagged.isEmpty else { continue }
                used.formUnion(tagged.map(\.id))
                out.append(TaskGroup(id: "tag:" + tag.lowercased(), title: "#" + tag, tasks: sorted(tagged, by: sort, now: now)))
            }
            let rest = tasks.filter { !used.contains($0.id) }
            if !rest.isEmpty { out.append(TaskGroup(id: "untagged", title: "no tags", tasks: sorted(rest, by: sort, now: now))) }
            return out
        case .day:
            if place == .logbook {
                let byDay = Dictionary(grouping: tasks) { Day.string($0.doneAt ?? $0.createdAt) }
                return byDay.keys.sorted(by: >).map { day in
                    TaskGroup(id: "done:" + day, title: Format.day(day, now: now), subtitle: day == today ? nil : Format.shortDay(day),
                              tasks: sorted(byDay[day]!, by: .created, now: now))
                }
            }
            return byDay(tasks, sort: sort, now: now)
        }
    }

    /// The coming week a day at a time, then the rest of the month, then month by month; undated
    /// last.
    private static func byDay(_ tasks: [TaskModel], sort: SortMode, now: Date) -> [TaskGroup] {
        let today = Day.today(now)
        var buckets: [String: [TaskModel]] = [:]
        var titles: [String: (title: String, subtitle: String?, day: String?, rank: String)] = [:]
        for task in tasks {
            guard let day = task.day else {
                buckets["~none", default: []].append(task)
                titles["~none"] = ("no date", nil, nil, "~none")
                continue
            }
            let ahead = Day.between(today, day) ?? 0
            let key: String
            if day < today {
                key = "0late"
                titles[key] = ("late", nil, nil, key)
            } else if ahead <= 7 {
                key = "1" + day
                titles[key] = (Format.day(day, now: now), ahead <= 1 ? Format.shortDay(day) : Format.monthDay(day), day, key)
            } else {
                let month = String(day.prefix(7))
                key = "2" + month
                let first = Day.date(month + "-01") ?? now
                let sameYear = Day.calendar.component(.year, from: first) == Day.calendar.component(.year, from: now)
                titles[key] = ((sameYear ? monthFormatter : monthYearFormatter).string(from: first).lowercased(), nil, nil, key)
            }
            buckets[key, default: []].append(task)
        }
        return buckets.keys.sorted().map { key in
            let info = titles[key]!
            return TaskGroup(id: "day:" + key, title: info.title, subtitle: info.subtitle, tasks: sorted(buckets[key]!, by: sort, now: now),
                             day: info.day, isLate: key == "0late")
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        return formatter
    }()

    /// How many a place holds, for the sidebar (today's late ones apart).
    static func count(_ place: Place, in snap: Snapshot, now: Date = Date()) -> Int {
        tasks(for: place, in: snap, now: now).count
    }
}

/// A filter, as typed into the filter field or saved as a smart list. Words must all be there
/// (in the title, notes, tags or list); and, any of:
///
///     #tag  -#tag            has (or hasn't) the tag
///     in:cs  -in:misc  ~cs   in the list (by name, as #names match: "cs" is "💻 cs 106b")
///     due:today  due:tomorrow  due:week  due:month  due:overdue  due:soon  due:none  due:any
///     due:fri  due:2026-12-01   due that day
///     before:dec 1  after:fri    due before or after a day
///     is:open  is:done  is:all   is:pinned  is:someday  is:repeating  is:idea  is:late
///     is:slipped  is:stale       is:inbox
///     has:notes  has:subtasks  has:tags  has:time  has:date  has:aim  has:timer  has:event
///     -word  "two words"
struct Query: Equatable {
    enum Status { case open, done, any }
    enum Due: Equatable { case overdue, today, tomorrow, week, month, soon, none, any, on(String), before(String), after(String) }

    var words: [String] = []
    var notWords: [String] = []
    var tags: [String] = []
    var notTags: [String] = []
    var lists: [String] = []
    var notLists: [String] = []
    var due: [Due] = []
    var status: Status?
    var flags: [String: Bool] = [:]

    var isEmpty: Bool {
        words.isEmpty && notWords.isEmpty && tags.isEmpty && notTags.isEmpty && lists.isEmpty && notLists.isEmpty
            && due.isEmpty && status == nil && flags.isEmpty
    }

    static func parse(_ text: String, weekStart: Int = 1, now: Date = Date()) -> Query {
        var q = Query()
        let pieces = split(text)
        var index = 0
        while index < pieces.count {
            var piece = pieces[index]
            index += 1
            var negated = false
            if piece.hasPrefix("-"), piece.count > 1 {
                negated = true
                piece.removeFirst()
            }
            let lower = piece.lowercased()
            // "before:dec 1", "due:next fri": a day can take the word after it, when it needs it.
            func value(after prefix: String) -> String {
                var rest = String(piece.dropFirst(prefix.count))
                if index < pieces.count, !pieces[index].contains(":") {
                    let next = pieces[index]
                    if TodQuick.read(rest, now: now, weekStart: weekStart).due == nil,
                       TodQuick.read(rest + " " + next, now: now, weekStart: weekStart).due != nil {
                        rest += " " + next
                        index += 1
                    }
                }
                return rest
            }
            if lower.hasPrefix("#"), lower.count > 1 {
                negated ? q.notTags.append(String(piece.dropFirst())) : q.tags.append(String(piece.dropFirst()))
            } else if lower.hasPrefix("in:") || lower.hasPrefix("list:") || (lower.hasPrefix("~") && lower.count > 1) {
                let name = lower.hasPrefix("~") ? String(piece.dropFirst()) : String(piece.split(separator: ":", maxSplits: 1).last ?? "")
                negated ? q.notLists.append(name) : q.lists.append(name)
            } else if lower.hasPrefix("due:") {
                let v = value(after: "due:").lowercased()
                switch v {
                case "overdue", "late": q.due.append(.overdue)
                case "today": q.due.append(.today)
                case "tomorrow": q.due.append(.tomorrow)
                case "week", "7days": q.due.append(.week)
                case "month": q.due.append(.month)
                case "soon": q.due.append(.soon)
                case "none", "no": q.due.append(.none)
                case "any", "yes": q.due.append(.any)
                default:
                    if let day = TodQuick.read(v, now: now, weekStart: weekStart).due { q.due.append(.on(day)) }
                }
            } else if lower.hasPrefix("before:") {
                if let day = TodQuick.read(value(after: "before:"), now: now, weekStart: weekStart).due { q.due.append(.before(day)) }
            } else if lower.hasPrefix("after:") {
                if let day = TodQuick.read(value(after: "after:"), now: now, weekStart: weekStart).due { q.due.append(.after(day)) }
            } else if lower.hasPrefix("is:") {
                let v = String(lower.dropFirst(3))
                switch v {
                case "open": q.status = .open
                case "done", "completed": q.status = .done
                case "all", "any": q.status = .any
                default: q.flags[v] = !negated
                }
            } else if lower.hasPrefix("has:") {
                q.flags["has:" + lower.dropFirst(4)] = !negated
            } else if !piece.isEmpty {
                negated ? q.notWords.append(piece) : q.words.append(piece)
            }
        }
        return q
    }

    /// Words, with "quoted phrases" kept whole.
    private static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                if !quoted, !current.isEmpty { out.append(current); current = "" }
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    func matches(_ t: TaskModel, in snap: Snapshot, now: Date = Date(), statusDefault: Status? = nil) -> Bool {
        switch status ?? statusDefault ?? .open {
        case .open: if t.done { return false }
        case .done: if !t.done { return false }
        case .any: break
        }
        let list = snap.list(t.listId)
        if !words.isEmpty || !notWords.isEmpty {
            let haystack = Self.fold([t.title, t.notes, t.tags.joined(separator: " "), list?.displayName ?? "",
                                      t.subtasks.map(\.title).joined(separator: " ")].joined(separator: " "))
            if !words.allSatisfy({ haystack.contains(Self.fold($0)) }) { return false }
            if notWords.contains(where: { haystack.contains(Self.fold($0)) }) { return false }
        }
        if !tags.allSatisfy({ t.hasTag($0) }) { return false }
        if notTags.contains(where: { t.hasTag($0) }) { return false }
        if !lists.isEmpty, !lists.contains(where: { Self.isList($0, list) }) { return false }
        if notLists.contains(where: { Self.isList($0, list) }) { return false }
        let today = Day.today(now)
        for rule in due {
            let ok: Bool
            switch rule {
            case .overdue: ok = t.isLate(at: now)
            case .today: ok = t.due == today
            case .tomorrow: ok = t.due == Day.adding(1, to: today)
            case .week: ok = t.due.map { $0 >= today && $0 <= (Day.adding(6, to: today) ?? today) } ?? false
            case .month: ok = t.due.map { $0 >= today && $0 <= (Day.adding(30, to: today) ?? today) } ?? false
            case .soon: ok = t.isLate(at: now) || (t.due.map { $0 <= (Day.adding(3, to: today) ?? today) } ?? false)
            case .none: ok = t.due == nil
            case .any: ok = t.due != nil
            case .on(let day): ok = t.due == day
            case .before(let day): ok = t.due.map { $0 < day } ?? false
            case .after(let day): ok = t.due.map { $0 > day } ?? false
            }
            if !ok { return false }
        }
        for (flag, wanted) in flags {
            let has: Bool
            switch flag {
            case "pinned": has = t.pinned
            case "someday": has = t.someday
            case "repeating", "recurring": has = t.repeats != nil
            case "idea": has = t.isIdea
            case "inbox": has = t.listId == ListModel.inbox
            case "email", "mail": has = t.isFromEmail
            case "canvas": has = t.canvas != nil || t.source == "canvas"
            case "late", "overdue": has = t.isLate(at: now)
            case "slipped": has = t.hasSlipped(at: now)
            case "stale": has = t.day == nil && now.timeIntervalSince(t.kept ?? t.createdAt) > 30 * 86400
            case "has:notes": has = !t.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "has:subtasks": has = !t.subtasks.isEmpty
            case "has:tags": has = !t.tags.isEmpty
            case "has:time": has = t.time != nil
            case "has:date", "has:due": has = t.due != nil
            case "has:aim": has = t.target != nil
            case "has:timer": has = snap.timedTasks.contains(t.id)
            case "has:event": has = t.event != nil
            case "has:duration": has = t.duration != nil
            default: has = true
            }
            if has != wanted { return false }
        }
        return true
    }

    private static func isList(_ ref: String, _ list: ListModel?) -> Bool {
        guard let list else { return false }
        if list.id == ref { return true }
        let key = TodQuick.words(ref).joined()
        guard !key.isEmpty else { return false }
        let words = TodQuick.words(list.name) + TodQuick.words(list.displayName)
        return list.handle == key || words.contains { $0.hasPrefix(key) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
