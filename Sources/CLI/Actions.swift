import AppKit
import Foundation

/// The changes the command line and the MCP server make, each saved straight away (under the
/// folder's lock, on the latest copy of the file). The app, if it's open, sees each one within
/// a moment.
enum Actions {
    static let disk = Disk()

    /// The list as it is now (made the first time, empty).
    static func snapshot() throws -> Snapshot {
        if Mirror.isEdited(folder: disk.folder) { disk.sync() }
        let read = disk.read()
        if let trouble = read.trouble { throw Ops.Failure(trouble) }
        if let doc = read.doc { return Snapshot(doc) }
        let made = disk.sync()
        if let trouble = made.trouble { throw Ops.Failure(trouble) }
        return Snapshot(made.doc ?? Doc.blank())
    }

    static func doc() throws -> Doc {
        if Mirror.isEdited(folder: disk.folder) { disk.sync() }
        let read = disk.read()
        if let trouble = read.trouble { throw Ops.Failure(trouble) }
        if let doc = read.doc { return doc }
        let made = disk.sync()
        if let trouble = made.trouble { throw Ops.Failure(trouble) }
        return made.doc ?? Doc.blank()
    }

    /// Saves `edit`; what's saved.
    @discardableResult
    static func save(_ edit: (inout Doc) -> Void) throws -> Snapshot {
        let outcome = disk.save(edit)
        if let trouble = outcome.trouble { throw Ops.Failure(trouble) }
        return Snapshot(outcome.doc ?? Doc.blank())
    }

    // MARK: - adding

    struct AddRequest {
        var text: String?
        var title: String?
        var notes: String?
        var list: String?
        var section: String?
        var tags: [String] = []
        var due: String?
        var time: String?
        var aim: String?
        var repeats: String?
        var duration: String?
        var pinned: Bool?
        var someday: Bool?
        var idea = false
        var subtasks: [String] = []
        var source: String
    }

    /// Adds a task: `text` read as quick add reads it, with anything given apart taking its place.
    static func add(_ r: AddRequest) throws -> TaskModel {
        let snap = try snapshot()
        let now = Date()
        var draft: TaskDraft
        var timer: Quick.TimerAsk?
        if let text = r.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = Quick.parse(text, lists: snap.lists, now: now, weekStart: snap.weekStart)
            draft = q.draft(source: r.source)
            timer = q.timer
            if let title = r.title, !title.isEmpty { draft.title = title }
        } else if let title = r.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            draft = TaskDraft(title: title)
            draft.source = r.source
        } else {
            throw Ops.Failure("nothing to add: give text (or a title)")
        }
        if let notes = r.notes { draft.notes = notes }
        if r.idea { draft.listId = ListModel.dump; draft.newListName = nil }
        if let ref = r.list?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            if let list = Ops.list(ref, in: snap) {
                draft.listId = list.id
                draft.newListName = nil
                if let sectionRef = r.section, let section = Ops.section(sectionRef, in: list) { draft.sectionId = section.id }
            } else {
                draft.listId = nil
                draft.newListName = ref
            }
        }
        draft.tags = TaskModel.tags(draft.tags + r.tags)
        if let due = r.due {
            guard let day = Ops.day(due, weekStart: snap.weekStart, now: now) else { throw Ops.Failure("“\(due)” isn't a day toyl can read") }
            draft.due = day
        }
        if let time = r.time {
            guard let clock = Ops.time(time, now: now) else { throw Ops.Failure("“\(time)” isn't a time toyl can read") }
            draft.time = clock
        }
        if let aim = r.aim {
            guard let day = Ops.aim(aim, weekStart: snap.weekStart, now: now) else { throw Ops.Failure("“\(aim)” isn't an aim toyl can read") }
            draft.target = day
        }
        if let repeats = r.repeats {
            guard let rule = Ops.repeats(repeats) else { throw Ops.Failure("“\(repeats)” isn't a repeat (daily, weekdays, weekly, biweekly, monthly, yearly)") }
            draft.repeats = rule
        }
        if let duration = r.duration {
            guard let minutes = Ops.minutes(duration) else { throw Ops.Failure("“\(duration)” isn't a length (like 30m or 1h30m)") }
            draft.duration = minutes
        }
        if let pinned = r.pinned { draft.pinned = pinned }
        if let someday = r.someday { draft.someday = someday }
        draft.subtasks += r.subtasks.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let id = UID.make()
        let saved = try save { $0.addTask(draft, id: id, now: now) }
        guard let task = saved.task(id) else { throw Ops.Failure("couldn't add it") }
        if let timer { _ = try startTimer(task: id, label: nil, minutes: timer.minutes.map(Double.init), stopwatch: timer.stopwatch) }
        return task
    }

    // MARK: - changing

    struct EditRequest {
        var title: String?
        var notes: String?
        var due: String?
        var time: String?
        var aim: String?
        var list: String?
        var section: String?
        var tags: [String]?
        var addTags: [String] = []
        var removeTags: [String] = []
        var pinned: Bool?
        var someday: Bool?
        var repeats: String?
        var duration: String?
        var addSubtasks: [String] = []
        var checkSubtasks: [String] = []
        var done: Bool?
    }

    static func edit(_ ref: String, _ r: EditRequest) throws -> TaskModel {
        let snap = try snapshot()
        let task = try Ops.task(ref, in: snap)
        let now = Date()
        var p = TaskPatch()
        p.title = r.title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        p.notes = r.notes
        if let due = r.due {
            guard let day = Ops.day(due, weekStart: snap.weekStart, now: now) else { throw Ops.Failure("“\(due)” isn't a day toyl can read") }
            p.due = day
            if day == nil { p.time = .some(nil) }
        }
        if let time = r.time {
            guard let clock = Ops.time(time, now: now) else { throw Ops.Failure("“\(time)” isn't a time toyl can read") }
            p.time = clock
        }
        if let aim = r.aim {
            guard let day = Ops.aim(aim, weekStart: snap.weekStart, now: now) else { throw Ops.Failure("“\(aim)” isn't an aim toyl can read") }
            p.target = day
        }
        if let ref = r.list {
            guard let list = Ops.list(ref, in: snap) else { throw Ops.Failure("no list called “\(ref)” (make it with new-list)") }
            p.listId = list.id
            if let sectionRef = r.section {
                guard let section = Ops.section(sectionRef, in: list) else { throw Ops.Failure("“\(list.displayName)” has no section “\(sectionRef)”") }
                p.sectionId = section.id
            }
        } else if let sectionRef = r.section, let list = snap.list(task.listId) {
            guard let section = Ops.section(sectionRef, in: list) else { throw Ops.Failure("“\(list.displayName)” has no section “\(sectionRef)”") }
            p.sectionId = section.id
        }
        p.tags = r.tags
        p.addTags = r.addTags
        p.removeTags = r.removeTags
        p.pinned = r.pinned
        p.someday = r.someday
        if let repeats = r.repeats {
            guard let rule = Ops.repeats(repeats) else { throw Ops.Failure("“\(repeats)” isn't a repeat (daily, weekdays, weekly, biweekly, monthly, yearly)") }
            p.repeats = rule
        }
        if let duration = r.duration {
            guard let minutes = Ops.minutes(duration) else { throw Ops.Failure("“\(duration)” isn't a length (like 30m or 1h30m)") }
            p.duration = minutes
        }
        if !r.addSubtasks.isEmpty || !r.checkSubtasks.isEmpty {
            var subtasks = task.subtasks
            for ref in r.checkSubtasks {
                if let index = subtasks.firstIndex(where: { $0.id == ref || $0.title.caseInsensitiveCompare(ref) == .orderedSame }) {
                    subtasks[index].done = true
                } else {
                    throw Ops.Failure("“\(task.title)” has no subtask “\(ref)”")
                }
            }
            subtasks += r.addSubtasks.filter { !$0.isEmpty }.map { Subtask(title: $0) }
            p.subtasks = subtasks
        }
        p.done = r.done
        let saved = try save { $0.updateTask(task.id, p, now: now) }
        return saved.task(task.id) ?? task
    }

    /// Checks a task off (or back on). What it is now, and the next of it if it repeats.
    static func complete(_ ref: String, done: Bool = true) throws -> (task: TaskModel, next: TaskModel?) {
        let snap = try snapshot()
        let task = try Ops.task(ref, in: snap, preferDone: !done)
        let saved = try save { $0.setDone(task.id, done) }
        let next = saved.tasks.first { $0.repeatOf == task.id }
        return (saved.task(task.id) ?? task, done ? next : nil)
    }

    static func delete(_ ref: String) throws -> TaskModel {
        let snap = try snapshot()
        let task = try Ops.task(ref, in: snap)
        try save { $0.deleteTask(task.id) }
        return task
    }

    static func newList(_ name: String, group: String?, color: String?, sections: [String]) throws -> ListModel {
        let snap = try snapshot()
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Ops.Failure("a list needs a name") }
        if let same = snap.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return same }
        let id = UID.make()
        let saved = try save { doc in
            var groupId: String?
            if let group = group?.trimmingCharacters(in: .whitespaces), !group.isEmpty {
                groupId = doc.groups.first { $0.name.caseInsensitiveCompare(group) == .orderedSame }?.id ?? doc.addGroup(name: group)
            }
            doc.addList(name: name, color: color, group: groupId, sections: sections.isEmpty ? ["to do"] : sections, id: id)
        }
        guard let list = saved.list(id) else { throw Ops.Failure("couldn't make it") }
        return list
    }

    // MARK: - timers

    static func startTimer(task ref: String?, label: String?, minutes: Double?, stopwatch: Bool) throws -> TimerModel {
        let snap = try snapshot()
        var task: TaskModel?
        if let ref, !ref.isEmpty { task = try Ops.task(ref, in: snap) }
        let length = (minutes ?? task?.duration.map(Double.init) ?? 25) * 60
        guard stopwatch || length > 0 else { throw Ops.Failure("a timer needs a length") }
        let timer = TimerModel(label: label ?? task?.title ?? "timer", taskId: task?.id, kind: stopwatch ? .stopwatch : .countdown,
                               duration: stopwatch ? 0 : min(length, 7 * 86400), pin: !stopwatch)
        try save { $0.putTimer(timer) }
        wakeApp()
        return timer
    }

    /// Stops a timer (by its id, or its task), or the latest one if none's named. What stopped.
    static func stopTimer(_ ref: String?) throws -> [TimerModel] {
        let snap = try snapshot()
        var stopping: [TimerModel]
        if let ref, !ref.isEmpty {
            stopping = snap.timers.filter { $0.id == ref || $0.id.hasPrefix(ref) }
            if stopping.isEmpty, let task = try? Ops.task(ref, in: snap) { stopping = snap.timers.filter { $0.taskId == task.id } }
            if stopping.isEmpty { stopping = snap.timers.filter { $0.label.localizedCaseInsensitiveContains(ref) } }
            if stopping.isEmpty { throw Ops.Failure("no timer matches “\(ref)”") }
        } else {
            stopping = Array(snap.timers.sorted { $0.startedAt > $1.startedAt }.prefix(1))
            if stopping.isEmpty { throw Ops.Failure("no timer's going") }
        }
        let now = Date()
        try save { doc in for timer in stopping { doc.finishTimer(timer.id, at: now) } }
        return stopping
    }

    /// Opens the app in the background, if it isn't open, so a timer started here rings.
    static func wakeApp() {
        guard Paths.isReal, NSRunningApplication.runningApplications(withBundleIdentifier: "local.toyl").isEmpty else { return }
        let app = Paths.installedApp
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", app.path]
        try? process.run()
    }

    // MARK: - autosort

    struct Suggestion {
        let task: TaskModel
        let list: ListModel?
        let confidence: Double
        let tags: [String]
    }

    /// Where each inbox task most likely belongs, learned from the rest of the list.
    static func autosort(_ snap: Snapshot) -> [Suggestion] {
        let classifier = Classifier(tasks: snap.tasks, lists: snap.lists)
        return snap.tasks.filter { $0.listId == ListModel.inbox && !$0.done }.compactMap { task in
            let text = task.title + " " + task.notes
            let guess = classifier.suggestList(for: text)
            let tags = classifier.suggestTags(for: text).filter { !task.hasTag($0) }
            guard guess != nil || !tags.isEmpty else { return nil }
            return Suggestion(task: task, list: guess.flatMap { snap.list($0.id) }, confidence: guess?.confidence ?? 0, tags: tags)
        }
    }

    static func applyAutosort(_ suggestions: [Suggestion]) throws -> Snapshot {
        try save { doc in
            for s in suggestions {
                var p = TaskPatch()
                if let list = s.list { p.listId = list.id }
                p.addTags = s.tags
                doc.updateTask(s.task.id, p)
            }
        }
    }

    // MARK: - the calendar, as the app last saw it

    struct Event {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let calendar: String
        let location: String?
    }

    static func events() -> (events: [Event], updated: Date?) {
        guard let data = try? Data(contentsOf: Paths.calendar),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        let events = (json["events"] as? [Any] ?? []).compactMap { item -> Event? in
            guard let e = item as? [String: Any], let start = Moment.date(e["start"]), let end = Moment.date(e["end"]) else { return nil }
            return Event(title: e["title"] as? String ?? "busy", start: start, end: end, allDay: e["allDay"] as? Bool ?? false,
                         calendar: e["calendar"] as? String ?? "", location: e["location"] as? String)
        }
        return (events, Moment.date(json["updated"]))
    }

    /// Day by day: what's due or aimed for each, and the calendar's events, from today.
    static func agenda(_ snap: Snapshot, days: Int, now: Date = Date()) -> [(day: String, tasks: [TaskModel], events: [Event])] {
        let today = Day.today(now)
        let events = self.events().events
        return (0..<max(days, 1)).compactMap { offset in
            guard let day = Day.adding(offset, to: today), let start = Day.date(day),
                  let end = Day.calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            var tasks = snap.tasks.filter { !$0.done && !$0.someday && $0.day == day }
            if offset == 0 { tasks = snap.tasks.filter { Views.isToday($0, today: today, now: now) } }
            let dayEvents = events.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
            return (day, Views.sorted(tasks, by: .auto, now: now), dayEvents)
        }
    }
}

// MARK: - google calendar, for the command line and agents

extension Actions {
    /// Your Google calendars, with their labels.
    static func googleCalendars() throws -> [GCalendar] {
        guard GoogleAuth.isConnected else { throw Ops.Failure(GoogleAuth.client == nil ? GoogleAuth.Failure.noClient.description : GoogleAuth.Failure.signedOut.description) }
        return try waitFor { try await GoogleCalendarAPI.calendars() }
    }

    /// Plans an event the owner's way (CALENDAR.md) and, if nothing's missing and `apply`, adds
    /// it (taking any copy off m) and ties its task to it. What's still needed comes back as
    /// questions instead.
    /// Pulls important email from the inboxes that are on; adds them (unless `apply` is false).
    static func pullMail(apply: Bool) throws -> MailPull.Outcome {
        let snap = try snapshot()
        let settings = MailSettings.load()
        let useModel = settings.ask && OnDevice.isAvailable
        let outcome = try waitFor { () async -> MailPull.Outcome in
            if useModel { return await MailPull.fetch(snap: snap, ask: { message in await OnDevice.mailTask(message) }) }
            return await MailPull.fetch(snap: snap)
        }
        guard apply else { return outcome }
        let drafts = outcome.found.map(\.draft)
        if !drafts.isEmpty {
            let ids = drafts.map { _ in UID.make() }
            _ = try save { doc in for (draft, id) in zip(drafts, ids) { _ = doc.addTask(draft, id: id) } }
        }
        MailPull.finish(outcome)
        return outcome
    }

    static func addToCalendar(_ request: EventRequest, apply: Bool = true) throws -> (outcome: EventOutcome, added: [GEvent], calendars: [GCalendar]) {
        var request = request
        let snap = try snapshot()
        if let ref = request.taskId, !ref.isEmpty {
            let task = try Ops.task(ref, in: snap)
            request.taskId = task.id
            if request.title.trimmingCharacters(in: .whitespaces).isEmpty { request.title = task.title }
        }
        let rules = CalendarRules.load()
        let calendars = try googleCalendars()
        var existing: [GEvent] = []
        if let text = request.day, let day = Ops.day(text, weekStart: snap.weekStart).flatMap({ $0 }),
           let start = Day.date(day), let end = Day.calendar.date(byAdding: .day, value: 1, to: start) {
            let owned = calendars.filter(\.writable).map(\.id)
            existing = try waitFor {
                var all: [GEvent] = []
                for id in owned { if let some = try? await GoogleCalendarAPI.events(id, from: start, to: end) { all += some } }
                return all
            }
        }
        let outcome = CalendarPlanner.plan(request, rules: rules, calendars: calendars, existing: existing, snap: snap)
        guard apply, outcome.questions.isEmpty, let first = outcome.plans.first else { return (outcome, [], calendars) }
        let plans = outcome.plans
        let offM = outcome.offM
        let added = try waitFor {
            var made: [GEvent] = []
            for plan in plans { made.append(try await GoogleCalendarAPI.insert(plan)) }
            for copy in offM { try? await GoogleCalendarAPI.delete(copy.calendarId, copy.id) }
            return made
        }
        if let taskId = request.taskId, let event = added.first {
            var p = TaskPatch()
            p.event = .some(EventLink(id: event.id, calendar: first.calendarId))
            p.due = .some(first.day)
            p.time = .some(first.allDay ? nil : first.start)
            if !first.allDay, let from = first.startDate, let to = first.endDate, to > from { p.duration = .some(Int(to.timeIntervalSince(from) / 60)) }
            try save { $0.updateTask(taskId, p) }
        }
        return (outcome, added, calendars)
    }

    /// A calendar as agents see it: its key and what it's for (from the rules), its labels.
    static func json(_ calendar: GCalendar, rules: CalendarRules) -> [String: Any] {
        var out: [String: Any] = ["id": calendar.id, "name": calendar.name, "writable": calendar.writable,
                                  "labels": calendar.labels.map(\.name).filter { !$0.isEmpty }]
        if let sub = rules.sub(for: calendar) {
            out["key"] = sub.key
            out["for"] = sub.about
            if let none = sub.none { out["no_label_means"] = none }
            if sub.dedupe { out["note"] = "kept deduplicated: nothing here that's also on another calendar" }
        }
        if calendar.primary { out["primary"] = true }
        return out
    }

    static func json(_ event: GEvent, calendars: [GCalendar]) -> [String: Any] {
        let calendar = calendars.first { $0.id == event.calendarId }
        var out: [String: Any] = ["id": event.id, "title": event.title, "calendar": calendar?.name ?? event.calendarId, "day": event.day,
                                  "all_day": event.allDay]
        if !event.allDay { out["start"] = Ops.iso(event.start); out["end"] = Ops.iso(event.end) }
        if let label = event.labelId.flatMap({ id in calendar?.labels.first { $0.id == id } }) { out["label"] = label.name }
        if !event.location.isEmpty { out["location"] = event.location }
        if !event.description.isEmpty { out["description"] = event.description }
        return out
    }
}
