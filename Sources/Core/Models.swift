import Foundation

// What's in toyl.json, read into types. The file itself stays a plain dictionary (see `Doc`), so
// whatever toyl doesn't know about (tod's canvas layout, fields Oyl adds) is carried along as it
// was; these are views of it.

/// Days as toyl (and tod, and Oyl) write them: "2026-11-21", in the Mac's own time zone.
enum Day {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func today(_ now: Date = Date()) -> String { string(now) }

    /// The start of the day, if it's a real one.
    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    static func adding(_ days: Int, to day: String) -> String? {
        date(day).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }.map(string)
    }

    /// Whole days from `from` to `to` (negative if `to` is earlier).
    static func between(_ from: String, _ to: String) -> Int? {
        guard let a = date(from), let b = date(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// When something's due: at its time, or the very end of its day.
    static func moment(_ day: String?, _ time: String?) -> Date? {
        let parts = (day ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let clock = (time ?? "").split(separator: ":").compactMap { Int($0) }
        let (hour, minute, second) = clock.count == 2 ? (clock[0], clock[1], 0) : (23, 59, 59)
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: hour, minute: minute, second: second))
    }

    /// "HH:MM" for a moment.
    static func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }

    static func isValid(_ day: String?) -> Bool { day.flatMap(date) != nil }

    static func isValidTime(_ time: String?) -> Bool {
        guard let parts = time?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 else { return false }
        return (0...23).contains(parts[0]) && (0...59).contains(parts[1])
    }
}

/// Milliseconds since 1970, as tod keeps its moments.
enum Moment {
    static func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}

/// A new id, made the way tod makes them (seven random characters, then three from the clock).
enum UID {
    static func make() -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<7).map { _ in digits.randomElement()! }) + String(String(Moment.ms(Date()), radix: 36).suffix(3))
    }
}

struct Subtask: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var done: Bool

    init(id: String = UID.make(), title: String, done: Bool = false) {
        self.id = id
        self.title = title
        self.done = done
    }

    init?(entry: Any) {
        guard let entry = entry as? [String: Any] else { return nil }
        id = entry["id"] as? String ?? UID.make()
        title = entry["title"] as? String ?? entry["text"] as? String ?? ""
        done = entry["done"] as? Bool ?? false
    }

    var entry: [String: Any] { ["id": id, "title": title, "done": done] }
}

/// A task's event on google calendar, once it's been put there.
struct EventLink: Equatable, Hashable {
    let id: String          // the event's id in google calendar
    let calendar: String    // its google calendar's id
}

struct TaskModel: Identifiable, Equatable, Hashable {
    let id: String
    var listId: String
    var sectionId: String
    var title: String
    var notes: String
    var due: String?        // a deadline: "YYYY-MM-DD"
    var time: String?       // "HH:MM"
    var target: String?     // an aim, a day to have it done by roughly (can slip): "YYYY-MM-DD"
    var kept: Date?         // last looked over and kept (Oyl's)
    var subtasks: [Subtask]
    var done: Bool
    var doneAt: Date?
    var createdAt: Date
    var updatedAt: Date?
    var order: Double
    var repeats: TodRepeat?
    var tags: [String]
    var pinned: Bool
    var someday: Bool
    var duration: Int?      // minutes it should take
    var spent: Int          // seconds timed on it
    var event: EventLink?
    var source: String?
    /// The task this one came back from, if it's the next of a repeating one.
    var repeatOf: String?

    var isIdea: Bool { listId == ListModel.dump }
    var dueDate: Date? { Day.moment(due, time) }
    var targetDate: Date? { Day.moment(target, nil) }

    /// Past its deadline.
    func isLate(at now: Date) -> Bool { !done && (dueDate.map { $0 < now } ?? false) }

    /// Past the day it was aimed at.
    func hasSlipped(at now: Date) -> Bool {
        guard !done, let target else { return false }
        return target < Day.today(now)
    }

    /// The day that matters most for it: its deadline, else its aim.
    var day: String? { due ?? target }

    func hasTag(_ tag: String) -> Bool { tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    var subtaskProgress: (done: Int, total: Int) { (subtasks.filter(\.done).count, subtasks.count) }

    /// Read from one of toyl.json's tasks; `sections` is each list's section ids, to put a task
    /// whose list or section has gone where tod would (the inbox, its list's first section).
    init(id: String, entry e: [String: Any], sections: [String: [String]]) {
        self.id = id
        var listId = e["listId"] as? String ?? ListModel.inbox
        if sections[listId] == nil { listId = ListModel.inbox }
        self.listId = listId
        let column = e["columnId"] as? String ?? ""
        let lanes = sections[listId] ?? []
        sectionId = lanes.contains(column) ? column : lanes.first ?? column
        title = e["title"] as? String ?? ""
        notes = e["notes"] as? String ?? ""
        due = Self.text(e["due"])
        time = Self.text(e["time"])
        target = Self.text(e["target"])
        kept = Moment.date(e["kept"])
        subtasks = (e["subtasks"] as? [Any] ?? []).compactMap(Subtask.init(entry:))
        done = e["done"] as? Bool ?? false
        doneAt = Moment.date(e["doneAt"])
        createdAt = Moment.date(e["createdAt"]) ?? Date(timeIntervalSince1970: 0)
        updatedAt = Moment.date(e["updatedAt"])
        order = (e["order"] as? NSNumber)?.doubleValue ?? 0
        repeats = (e["repeat"] as? String).flatMap(TodRepeat.init(rawValue:))
        tags = Self.tags(e["tags"])
        pinned = e["pinned"] as? Bool ?? false
        someday = e["someday"] as? Bool ?? false
        duration = (e["duration"] as? NSNumber)?.intValue
        spent = (e["spent"] as? NSNumber)?.intValue ?? 0
        if let link = e["event"] as? [String: Any], let id = link["id"] as? String, let calendar = link["calendar"] as? String {
            event = EventLink(id: id, calendar: calendar)
        } else {
            event = nil
        }
        source = e["source"] as? String
        repeatOf = e["repeatOf"] as? String
    }

    static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// Tags as kept: unique (whatever their case), without "#".
    static func tags(_ value: Any?) -> [String] {
        var seen = Set<String>()
        return (value as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct SectionModel: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
}

struct ListModel: Identifiable, Equatable, Hashable {
    static let inbox = "inbox"
    /// tod's brain dump, which toyl calls ideas.
    static let dump = "dump"
    static let dumpUnsorted = "dump-ideas"

    let id: String
    var name: String
    var color: String
    var sections: [SectionModel]
    var group: String?
    var notes: String
    var archived: Bool
    var createdAt: Date?

    var isInbox: Bool { id == Self.inbox }
    var isDump: Bool { id == Self.dump }
    /// A smart place of its own in the sidebar, not one of your lists.
    var isSpecial: Bool { isInbox || isDump }
    var firstSection: String { sections.first?.id ?? "" }
    /// Its #name: its letters and digits, run together ("💻 cs 106b" is #cs106b).
    var handle: String { TodQuick.words(name).joined() }

    /// The mark its name starts with, shown in place of a dot: an emoji ("🌲 treehacks") as it is,
    /// a symbol ("♡", "✩ a") in the list's color.
    var mark: Mark? { Mark(name) }

    /// The emoji its name starts with, if it does.
    var emoji: String? { mark.flatMap { $0.isEmoji ? $0.text : nil } }

    /// Its name without the mark it starts with.
    var bareName: String {
        guard let mark, !isSpecial else { return displayName }
        return mark.rest.isEmpty ? name : mark.rest
    }

    /// What it's called in toyl: the inbox and the brain dump by their places' names.
    var displayName: String {
        if isInbox { return "inbox" }
        if isDump { return "ideas" }
        return name
    }

    init?(entry e: [String: Any]) {
        guard let id = e["id"] as? String else { return nil }
        self.id = id
        let isDump = id == Self.dump || e["kind"] as? String == "dump"
        name = e["name"] as? String ?? ""
        color = Self.hex(e["color"]) ?? (isDump ? "#8c8c8c" : "#5a5a5a")
        sections = (e["columns"] as? [Any] ?? []).compactMap { column in
            guard let column = column as? [String: Any], let id = column["id"] as? String else { return nil }
            return SectionModel(id: id, name: column["name"] as? String ?? "")
        }
        group = TaskModel.text(e["group"])
        notes = e["notes"] as? String ?? ""
        archived = e["archived"] as? Bool ?? false
        createdAt = Moment.date(e["createdAt"])
    }

    /// "#rrggbb", lowercased, if it is one.
    static func hex(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 7, text.hasPrefix("#"),
              text.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return text
    }

    /// tod's palette, for a new list's color.
    static let palette = ["#3b5bdb", "#2f9bd6", "#14958a", "#4c9a6a", "#7a9a2e", "#d19a1c",
                          "#e8772e", "#c8553d", "#d6457a", "#9b4dca", "#6c5ce7", "#5a5a5a"]
}

/// The mark a name starts with: an emoji, shown as it is, or a symbol (♡ ✩ ✶ ★), shown in its
/// list's (or calendar's) color.
struct Mark: Equatable, Hashable {
    let text: String
    let isEmoji: Bool
    /// The name after it.
    let rest: String

    init?(_ name: String) {
        guard let first = name.first, !first.isASCII, !first.isLetter, !first.isNumber else { return nil }
        let scalars = first.unicodeScalars
        let emoji = scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        let symbol = scalars.allSatisfy { [.otherSymbol, .mathSymbol, .dashPunctuation, .otherPunctuation].contains($0.properties.generalCategory) }
        guard emoji || symbol else { return nil }
        text = String(first)
        isEmoji = emoji
        rest = name.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

/// A heading in the sidebar that lists go under: school, work, clubs (an area, in Things' and
/// Oyl's word for it).
struct GroupModel: Identifiable, Equatable, Hashable {
    let id: String
    var name: String

    init?(entry e: [String: Any]) {
        guard let id = e["id"] as? String else { return nil }
        self.id = id
        name = e["name"] as? String ?? ""
    }
}

/// A saved filter: a smart list of its own, from a query ("#school due:week").
struct FilterModel: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var query: String

    init?(entry e: [String: Any]) {
        guard let id = e["id"] as? String else { return nil }
        self.id = id
        name = e["name"] as? String ?? ""
        query = e["query"] as? String ?? ""
    }
}

/// A timer: a countdown (a focus session on a task, or "10m tea"), or a stopwatch timing a task
/// for as long as it takes. Kept in toyl.json, so the command line, the MCP server and Oyl's
/// notch see the same ones.
struct TimerModel: Identifiable, Equatable, Hashable {
    enum Kind: String { case countdown, stopwatch }

    let id: String              // a UUID, as Oyl's timers have
    var label: String
    var taskId: String?
    var kind: Kind
    var duration: Double        // a countdown's length, in seconds
    var endsAt: Date?           // a running countdown's end
    var pausedLeft: Double?     // a paused countdown's time left
    var startedAt: Date
    var elapsed: Double         // a stopwatch's time before this run
    var runningSince: Date?     // a running stopwatch's start
    var pin: Bool               // held on Oyl's notch
    /// Oyl's notch is showing it (and rings it, while Oyl's open).
    var mirroredByOyl = false

    var isRunning: Bool { kind == .countdown ? endsAt != nil : runningSince != nil }

    func remaining(at now: Date) -> Double {
        if let endsAt { return max(endsAt.timeIntervalSince(now), 0) }
        return pausedLeft ?? duration
    }

    /// How long it's been worked on so far.
    func worked(at now: Date) -> Double {
        switch kind {
        case .countdown: return max(duration - remaining(at: now), 0)
        case .stopwatch: return elapsed + (runningSince.map { max(now.timeIntervalSince($0), 0) } ?? 0)
        }
    }

    func isFinished(at now: Date) -> Bool { kind == .countdown && (endsAt.map { $0 <= now } ?? false) }

    /// The countdown ring's fill, 1 → 0.
    func fractionLeft(at now: Date) -> Double { duration > 0 ? remaining(at: now) / duration : 0 }

    init(id: String = UUID().uuidString, label: String, taskId: String?, kind: Kind, duration: Double, now: Date = Date(), pin: Bool = false) {
        self.id = id
        self.label = label
        self.taskId = taskId
        self.kind = kind
        self.duration = duration
        endsAt = kind == .countdown ? now.addingTimeInterval(duration) : nil
        pausedLeft = nil
        startedAt = now
        elapsed = 0
        runningSince = kind == .stopwatch ? now : nil
        self.pin = pin
    }

    init?(entry e: [String: Any]) {
        guard let id = e["id"] as? String else { return nil }
        self.id = id
        label = e["label"] as? String ?? ""
        taskId = TaskModel.text(e["task"])
        kind = Kind(rawValue: e["kind"] as? String ?? "") ?? .countdown
        duration = (e["duration"] as? NSNumber)?.doubleValue ?? 0
        endsAt = Moment.date(e["endsAt"])
        pausedLeft = (e["pausedLeft"] as? NSNumber)?.doubleValue
        startedAt = Moment.date(e["startedAt"]) ?? Date()
        elapsed = (e["elapsed"] as? NSNumber)?.doubleValue ?? 0
        runningSince = Moment.date(e["runningSince"])
        pin = e["pin"] as? Bool ?? false
        mirroredByOyl = e["oyl"] as? Bool ?? false
    }

    /// The fields toyl writes (any others, like Oyl's "oyl", are left as they are).
    static let fields = ["id", "label", "task", "kind", "duration", "endsAt", "pausedLeft", "startedAt", "elapsed", "runningSince", "pin"]

    var entry: [String: Any] {
        var e: [String: Any] = ["id": id, "label": label, "kind": kind.rawValue, "duration": duration,
                                "startedAt": Moment.ms(startedAt), "elapsed": elapsed, "pin": pin]
        if let taskId { e["task"] = taskId }
        if let endsAt { e["endsAt"] = Moment.ms(endsAt) }
        if let pausedLeft { e["pausedLeft"] = pausedLeft }
        if let runningSince { e["runningSince"] = Moment.ms(runningSince) }
        return e
    }
}

/// A timer that's over: how long it ran, and what for.
struct TimerEntry: Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    let taskId: String?
    let seconds: Double
    let ended: Date
    let kind: TimerModel.Kind

    init(timer: TimerModel, seconds: Double, ended: Date) {
        id = timer.id
        label = timer.label
        taskId = timer.taskId
        self.seconds = seconds
        self.ended = ended
        kind = timer.kind
    }

    init?(entry e: [String: Any]) {
        guard let id = e["id"] as? String else { return nil }
        self.id = id
        label = e["label"] as? String ?? ""
        taskId = TaskModel.text(e["task"])
        seconds = (e["seconds"] as? NSNumber)?.doubleValue ?? 0
        ended = Moment.date(e["ended"]) ?? Date()
        kind = TimerModel.Kind(rawValue: e["kind"] as? String ?? "") ?? .countdown
    }

    var entry: [String: Any] {
        var e: [String: Any] = ["id": id, "label": label, "seconds": seconds.rounded(), "ended": Moment.ms(ended), "kind": kind.rawValue]
        if let taskId { e["task"] = taskId }
        return e
    }
}
