import Foundation

/// What the command line and the MCP server share: finding a task or list from what someone
/// called it, and saying a task back (as JSON for agents, a line of text for people).
enum Ops {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A task, from its id, the start of its id (four characters or more), or its title (the
    /// whole of it, or a part only one open task has).
    static func task(_ ref: String, in snap: Snapshot, preferDone: Bool = false) throws -> TaskModel {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { throw Failure("which task? give its id or title") }
        if let task = snap.task(ref) { return task }
        if ref.count >= 4 {
            let prefixed = snap.tasks.filter { $0.id.hasPrefix(ref) }
            if prefixed.count == 1 { return prefixed[0] }
        }
        let key = Query.fold(ref)
        let exact = snap.tasks.filter { Query.fold($0.title) == key }
        if let one = pick(exact, preferDone: preferDone) { return one }
        let partial = snap.tasks.filter { Query.fold($0.title).contains(key) }
        if let one = pick(partial, preferDone: preferDone) { return one }
        if partial.isEmpty && exact.isEmpty { throw Failure("no task matches “\(ref)”") }
        let names = (exact.isEmpty ? partial : exact).prefix(6).map { "\($0.id) “\($0.title)”\($0.done ? " (done)" : "")" }
        throw Failure("“\(ref)” could be: " + names.joined(separator: ", ") + ". use an id")
    }

    /// One of several: the only one, or the only open one (done one, when putting one back:
    /// the last checked off, if there are a few, as a repeating task leaves).
    private static func pick(_ found: [TaskModel], preferDone: Bool) -> TaskModel? {
        if found.count == 1 { return found[0] }
        let preferred = found.filter { $0.done == preferDone }
        if preferred.count == 1 { return preferred[0] }
        if preferDone, !preferred.isEmpty { return preferred.max { ($0.doneAt ?? .distantPast) < ($1.doneAt ?? .distantPast) } }
        return nil
    }

    /// A list, from its id or name ("inbox" and "ideas" too), or as a #name picks one ("cs" is
    /// "💻 cs 106b").
    static func list(_ ref: String, in snap: Snapshot) -> ListModel? {
        let ref = ref.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#~"))
        guard !ref.isEmpty else { return nil }
        if let list = snap.list(ref) { return list }
        if let named = snap.lists.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.displayName.caseInsensitiveCompare(ref) == .orderedSame }) {
            return named
        }
        if ["brain dump", "dump", "idea"].contains(ref.lowercased()) { return snap.list(ListModel.dump) }
        return Quick.list(for: ref, among: snap.lists).flatMap { snap.list($0) }
    }

    /// A section of a list, by id or name.
    static func section(_ ref: String, in list: ListModel) -> SectionModel? {
        list.sections.first { $0.id == ref } ?? list.sections.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    }

    // MARK: - saying it back

    /// A task as agents see it.
    static func json(_ t: TaskModel, in snap: Snapshot, now: Date = Date()) -> [String: Any] {
        let list = snap.list(t.listId)
        var out: [String: Any] = [
            "id": t.id, "title": t.title, "done": t.done, "list": list?.displayName ?? t.listId, "list_id": t.listId,
            "created": iso(t.createdAt),
        ]
        if let list, list.sections.count > 1, let section = list.sections.first(where: { $0.id == t.sectionId }) {
            out["section"] = section.name
        }
        if !t.notes.isEmpty { out["notes"] = t.notes }
        if let due = t.due { out["due"] = due }
        if let time = t.time { out["time"] = time }
        if let target = t.target { out["aim"] = target }
        if let when = Format.due(t, now: now) { out["when"] = when }
        if let target = t.target { out["aim_said"] = Format.aim(target, now: now) }
        if t.isLate(at: now) { out["late"] = true }
        if t.hasSlipped(at: now) { out["slipped"] = true }
        if !t.tags.isEmpty { out["tags"] = t.tags }
        if t.pinned { out["pinned"] = true }
        if t.someday { out["someday"] = true }
        if let repeats = t.repeats { out["repeat"] = repeats.rawValue }
        if let duration = t.duration { out["duration_minutes"] = duration }
        if t.spent > 0 { out["spent_minutes"] = (t.spent + 30) / 60 }
        if !t.subtasks.isEmpty { out["subtasks"] = t.subtasks.map { ["id": $0.id, "title": $0.title, "done": $0.done] as [String: Any] } }
        if let doneAt = t.doneAt, t.done { out["done_at"] = iso(doneAt) }
        if snap.timedTasks.contains(t.id) { out["timer_running"] = true }
        if t.event != nil { out["on_calendar"] = true }
        if let project = snap.list(t.listId)?.project(t.project) { out["project"] = project.name }
        if let email = t.email { out["from_email"] = ["account": email.account, "from": email.from, "subject": email.subject] }
        else if t.source == "email" { out["from_email"] = true }
        if t.isIdea { out["idea"] = true }
        return out
    }

    static func json(_ list: ListModel, in snap: Snapshot) -> [String: Any] {
        let open = snap.tasks.filter { $0.listId == list.id && !$0.done }
        var out: [String: Any] = ["id": list.id, "name": list.displayName, "open": open.count, "color": list.color]
        if list.sections.count > 1 { out["sections"] = list.sections.map { ["id": $0.id, "name": $0.name] } }
        if !list.projects.isEmpty {
            out["projects"] = list.projects.map { project in
                ["id": project.id, "name": project.name, "open": open.filter { $0.project == project.id }.count] as [String: Any]
            }
        }
        if let group = list.group.flatMap({ id in snap.groups.first { $0.id == id } }) { out["group"] = group.name }
        if list.archived { out["archived"] = true }
        if !list.notes.isEmpty { out["notes"] = list.notes }
        if list.isInbox { out["kind"] = "inbox" } else if list.isDump { out["kind"] = "ideas" }
        return out
    }

    static func json(_ timer: TimerModel, in snap: Snapshot, now: Date = Date()) -> [String: Any] {
        var out: [String: Any] = ["id": timer.id, "label": timer.label, "kind": timer.kind.rawValue, "running": timer.isRunning,
                                  "worked_seconds": Int(timer.worked(at: now))]
        if timer.kind == .countdown {
            out["remaining_seconds"] = Int(timer.remaining(at: now).rounded(.up))
            out["length_seconds"] = Int(timer.duration)
            if let end = timer.endsAt { out["ends"] = iso(end) }
        }
        if let task = timer.taskId { out["task_id"] = task; out["task"] = snap.task(task)?.title ?? "" }
        return out
    }

    /// A task as a line of text: "[ ] essay draft · today 5pm · #writing · cs 106b  (ab12cde)".
    /// A task's sublist, a line each, indented under it.
    static func sublist(_ t: TaskModel) -> [String] {
        t.subtasks.map { "      [\($0.done ? "x" : " ")] " + $0.title }
    }

    static func line(_ t: TaskModel, in snap: Snapshot, now: Date = Date(), showList: Bool = true) -> String {
        var parts = [(t.done ? "[x] " : "[ ] ") + t.title]
        if let when = Format.due(t, now: now) { parts.append(t.isLate(at: now) && !when.contains("late") && when != "yesterday" ? when + " (late)" : when) }
        if let target = t.target { parts.append(Format.aim(target, now: now)) }
        if let repeats = t.repeats { parts.append(repeats.phrase) }
        if let duration = t.duration { parts.append("~" + Format.minutes(duration)) }
        if t.pinned { parts.append("pinned") }
        if !t.tags.isEmpty { parts.append(t.tags.map { "#" + $0 }.joined(separator: " ")) }
        if showList, let list = snap.list(t.listId) { parts.append(list.displayName) }
        return parts.joined(separator: " · ") + "  (\(t.id))"
    }

    /// The day at a glance, for an agent getting its bearings.
    static func overview(_ snap: Snapshot, now: Date = Date()) -> [String: Any] {
        let today = Day.today(now)
        let open = snap.tasks.filter { !$0.done }
        return [
            "today": today,
            "weekday": Format.day(today, now: now) == "today" ? Format.longDay(today, now: now) : today,
            "due_today": open.filter { $0.due == today }.count,
            "late": open.filter { $0.isLate(at: now) }.count,
            "slipped_aims": open.filter { $0.hasSlipped(at: now) }.count,
            "inbox": open.filter { $0.listId == ListModel.inbox }.count,
            "ideas": open.filter(\.isIdea).count,
            "open": open.count,
            "done_today": snap.tasks.filter { $0.done && $0.doneAt.map { Day.string($0) == today } == true }.count,
            "lists": snap.ownLists.filter { !$0.archived }.map(\.displayName),
            "tags": snap.tags.prefix(30).map(\.name),
            "timers": snap.timers.map { json($0, in: snap, now: now) },
        ]
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// JSON text, laid out for reading.
    static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\(object)" }
        return text
    }

    // MARK: - changes from plain values

    /// A day from what someone wrote ("fri", "tomorrow", "2026-12-01", "none"): `.some(nil)` to
    /// take it off, nil if it doesn't read as a day.
    static func day(_ text: String, weekStart: Int, now: Date = Date()) -> String?? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if ["", "none", "null", "no", "clear", "-"].contains(text.lowercased()) { return .some(nil) }
        if Day.isValid(text) { return .some(text) }
        if let due = TodQuick.read(text, now: now, weekStart: weekStart).due { return .some(due) }
        return nil
    }

    /// A time from what someone wrote ("17:00", "5pm", "noon", "none").
    static func time(_ text: String, now: Date = Date()) -> String?? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if ["", "none", "null", "no", "clear", "-"].contains(text.lowercased()) { return .some(nil) }
        if Day.isValidTime(text) {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            return .some(String(format: "%02d:%02d", parts[0], parts[1]))
        }
        if let time = TodQuick.read("at " + text, now: now, weekStart: 1).time ?? TodQuick.read(text, now: now, weekStart: 1).time { return .some(time) }
        return nil
    }

    /// An aim from what someone wrote ("next week", "early dec", "2026-12-01").
    static func aim(_ text: String, weekStart: Int, now: Date = Date()) -> String?? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if ["", "none", "null", "no", "clear", "-"].contains(text.lowercased()) { return .some(nil) }
        if Day.isValid(text) { return .some(text) }
        var rest = "by " + text
        if let aim = IdeaQuick.takeAim(&rest, now: now, weekStart: weekStart) { return .some(aim) }
        rest = text
        if let aim = IdeaQuick.takeAim(&rest, now: now, weekStart: weekStart) { return .some(aim) }
        return day(text, weekStart: weekStart, now: now)
    }

    static func repeats(_ text: String) -> TodRepeat?? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["", "none", "null", "no", "never", "clear", "-"].contains(text) { return .some(nil) }
        if let exact = TodRepeat(rawValue: text) { return .some(exact) }
        if let found = Quick.parse("x " + text, lists: []).repeats { return .some(found) }
        return nil
    }

    /// Minutes from "30", "30m", "1h30m", "1.5h", "none".
    static func minutes(_ text: String) -> Int?? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["", "none", "null", "no", "clear", "-", "0"].contains(text) { return .some(nil) }
        if let n = Int(text) { return .some(n) }
        if let found = Quick.parse("x ~" + text, lists: []).duration { return .some(found) }
        return nil
    }
}
