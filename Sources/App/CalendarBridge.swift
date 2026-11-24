import AppKit
import SwiftUI

/// One of the calendar's events, for showing.
struct CalEvent: Identifiable, Equatable {
    let id: String
    let eventId: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    /// Its label's color, else its calendar's.
    let color: String
    let calendarId: String
    let calendarTitle: String
    let label: String?
    let location: String?
    /// The task it's for, if toyl put it there.
    let taskId: String?
    /// Its description, as plain text.
    var notes = ""
    /// The event on calendar.google.com.
    var link: String?

    var day: String { Day.string(start) }
    /// "hinterland?": not settled yet.
    var tentative: Bool { title.hasSuffix("?") }
}

struct CalInfo: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let color: String
    let writable: Bool
    let primary: Bool
    let shownInGoogle: Bool
    let labels: [GLabel]
}

/// What's being added to the calendar, in the window: filled in from a task and the rules, and
/// changed till nothing's missing.
struct EventForm: Identifiable, Equatable {
    let id = UUID()
    var taskId: String?
    var title = ""
    var calendarId: String?
    /// A label's name, nil for none.
    var label: String?
    var day = ""
    var start = ""
    var end = ""
    var length = ""
    var allDay = false
    var location = ""
    var description = ""
    var tentative = false
    var margs = true
    var reason = ""
}

extension GEvent {
    /// Enough of an event, from how it's shown, to follow it.
    init?(_ shown: CalEvent) {
        let start: [String: Any] = shown.allDay ? ["date": Day.string(shown.start)] : ["dateTime": GoogleTime.string(shown.start)]
        let end: [String: Any] = shown.allDay ? ["date": Day.string(shown.end)] : ["dateTime": GoogleTime.string(shown.end)]
        self.init(entry: ["id": shown.eventId, "summary": shown.title, "start": start, "end": end], calendarId: shown.calendarId)
    }
}

/// Google Calendar, in the window: its events beside your tasks, things added to it the owner's
/// way (`CalendarRules`), tasks kept in step with their events both ways, and "todo: …" events
/// made into tasks, so Instinct, Claude or Muse can hand you something by putting it on your
/// calendar.
@MainActor
final class CalendarBridge: ObservableObject {
    enum State: Equatable {
        /// No OAuth client yet.
        case setUp
        case signedOut
        case signingIn
        case connected
    }

    @Published private(set) var state: State = .setUp
    /// Every calendar's events (shown or not, so switching one on is instant); `everything(on:)`
    /// and the rest give the shown ones'.
    @Published private(set) var events: [CalEvent] = []
    /// The calendars that show, by id.
    @Published private(set) var shownIds: Set<String> = []
    @Published private(set) var calendars: [CalInfo] = []
    @Published private(set) var rules: CalendarRules
    @Published var note: String?
    /// Events outside what's loaded (yesterday to a month ahead), for a day the calendar panel is
    /// looking at: a fortnight round it, fetched when it's asked for.
    @Published private(set) var further: [CalEvent] = []
    private var furtherRange: (from: Date, to: Date)?

    /// As Google has them: the calendars, and the shown ones' events (m's too, for keeping it
    /// deduplicated), the day before to a month ahead.
    private(set) var google: [GCalendar] = []
    private(set) var raw: [GEvent] = []
    private let store: Store
    private var refresh: Timer?
    private var soon: Timer?
    private var loading = false
    /// Asked to reload while it was: once more after.
    private var again = false
    private var syncing = false
    private var lastCalendars: Date?
    private var lastLoad: Date?
    private let defaults = UserDefaults.standard

    var connected: Bool { state == .connected }

    init(store: Store) {
        self.store = store
        rules = CalendarRules.load()
        CalendarGuide.write()
        updateState()
        // Nothing left over from reading the Mac's calendars.
        for key in ["calendar.hidden", "calendar.block", "calendar.blockAll", "calendar.blockMinutes"] { defaults.removeObject(forKey: key) }
        if !GoogleAuth.isConnected { try? FileManager.default.removeItem(at: Paths.calendar) }
        store.onChange.append { [weak self] _ in self?.syncSoon() }
        refresh = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, (self.lastLoad.map { Date().timeIntervalSince($0) > 60 } ?? true) else { return }
                self.reload()
            }
        }
        reload()
    }

    private func updateState() {
        if state == .signingIn { return }
        state = GoogleAuth.client == nil ? .setUp : GoogleAuth.isConnected ? .connected : .signedOut
    }

    // MARK: - settings

    var showEvents: Bool {
        get { defaults.object(forKey: "calendar.show") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "calendar.show"); objectWillChange.send() }
    }

    /// Shown here: as you've said, else as Google's own list shows it (the adopted treehacks and
    /// stanford feeds left out, since their events are on your own calendars too).
    func isShown(_ calendar: CalInfo) -> Bool {
        if let said = (defaults.dictionary(forKey: "calendar.shown") as? [String: Bool])?[calendar.id] { return said }
        let name = calendar.title.lowercased()
        return calendar.shownInGoogle && !name.contains("stanford") && !name.contains("treehacks")
    }

    func setShown(_ id: String, _ on: Bool) {
        var said = defaults.dictionary(forKey: "calendar.shown") as? [String: Bool] ?? [:]
        said[id] = on
        defaults.set(said, forKey: "calendar.shown")
        // Every calendar's events are here already: it shows (or goes) at once.
        withAnimation(.easeOut(duration: 0.2)) { shownIds = Set(calendars.filter(isShown).map(\.id)) }
        writeSnapshot()
    }

    /// Events called "todo: …" become tasks.
    var importTodos: Bool {
        get { defaults.object(forKey: "calendar.todos") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "calendar.todos"); objectWillChange.send() }
    }

    /// The hours "find time" looks in.
    var dayStart: Int { defaults.object(forKey: "calendar.dayStart") as? Int ?? 9 }
    var dayEnd: Int { defaults.object(forKey: "calendar.dayEnd") as? Int ?? 22 }

    // MARK: - connecting

    /// Keeps the OAuth client pasted in (its JSON, or ID and secret). Whether it read.
    func saveClient(_ text: String) -> Bool {
        guard let client = GoogleAuth.client(from: text) else { return false }
        GoogleAuth.setClient(client)
        updateState()
        return true
    }

    /// Signs in to Google, in the browser.
    func connect() {
        guard GoogleAuth.client != nil else { note = "paste your google oauth client in settings first"; return }
        state = .signingIn
        note = "finish signing in to google in your browser"
        Task { @MainActor in
            do {
                try await GoogleAuth.signIn { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                state = .connected
                note = nil
                lastCalendars = nil
                reload()
            } catch {
                state = GoogleAuth.isConnected ? .connected : .signedOut
                note = "\(error)"
            }
        }
    }

    func disconnect() {
        GoogleAuth.signOut()
        updateState()
        google = []
        raw = []
        events = []
        calendars = []
        further = []
        furtherRange = nil
        try? FileManager.default.removeItem(at: Paths.calendar)
    }

    func openSettings() { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }

    // MARK: - reading

    /// Google's calendars (now and then) and the shown ones' events, then keeps linked tasks in
    /// step and the command line's copy up to date.
    func reload() {
        updateState()
        guard connected else { return }
        guard !loading else { again = true; return }
        loading = true
        let wantCalendars = google.isEmpty || (lastCalendars.map { Date().timeIntervalSince($0) > 1800 } ?? true)
        Task { @MainActor in
            defer {
                loading = false
                if again {
                    again = false
                    reload()
                }
            }
            do {
                if wantCalendars {
                    google = try await GoogleCalendarAPI.calendars()
                    lastCalendars = Date()
                    calendars = google.map { CalInfo(id: $0.id, title: $0.name, color: $0.color, writable: $0.writable, primary: $0.primary,
                                                     shownInGoogle: $0.shownInGoogle, labels: $0.labels) }
                    shownIds = Set(calendars.filter(isShown).map(\.id))
                }
                let (from, to) = Self.loadedRange()
                var found: [GEvent] = []
                var missed = 0
                for calendar in google {
                    do {
                        found += try await GoogleCalendarAPI.events(calendar.id, from: from, to: to)
                    } catch GoogleAuth.Failure.expired {
                        throw GoogleAuth.Failure.expired
                    } catch {
                        // Couldn't read this one (offline, a feed that's down): what it had stays.
                        missed += 1
                        found += raw.filter { $0.calendarId == calendar.id }
                    }
                }
                // Nothing read at all (asleep, offline): keep everything as it was, and don't sync on nothing.
                if missed == google.count, !google.isEmpty { throw GoogleAuth.Failure.said("nothing came back") }
                raw = found
                let fresh = found.filter { $0.status != "cancelled" }.map(show).sorted { $0.start < $1.start }
                if fresh != events { events = fresh }
                lastLoad = Date()
                if note?.hasPrefix("couldn't reach") == true { note = nil }
                writeSnapshot()
                if let range = furtherRange { await fetchFurther(range) }
                await importTodoEvents()
                await sync()
            } catch GoogleAuth.Failure.expired {
                updateState()
                note = GoogleAuth.Failure.expired.description
            } catch {
                note = "couldn't reach google calendar: \(error)"
            }
        }
    }

    private func show(_ event: GEvent) -> CalEvent {
        let calendar = google.first { $0.id == event.calendarId }
        let label = event.labelId.flatMap { id in calendar?.labels.first { $0.id == id } }
        return CalEvent(id: event.id + "@" + event.calendarId + String(event.start.timeIntervalSince1970), eventId: event.id,
                        title: event.title.isEmpty ? "busy" : event.title, start: event.start, end: event.end, allDay: event.allDay,
                        color: label?.color ?? calendar?.color ?? "#8c8c8c", calendarId: event.calendarId,
                        calendarTitle: calendar?.name ?? "", label: label?.name, location: event.location.isEmpty ? nil : event.location,
                        taskId: event.taskId ?? linkedTask(event.id),
                        notes: Self.plain(event.description), link: event.link)
    }

    /// The task tied to an event, from an index made once for each version of the list (not a
    /// search of every task for every event).
    private func linkedTask(_ eventId: String) -> String? {
        if linkedIndex?.version != store.version {
            let pairs = store.snap.tasks.compactMap { task in task.event.map { ($0.id, task.id) } }
            linkedIndex = (store.version, Dictionary(pairs, uniquingKeysWith: { first, _ in first }))
        }
        return linkedIndex?.map[eventId]
    }
    private var linkedIndex: (version: Int, map: [String: String])?

    /// Google keeps descriptions as a little HTML: as plain lines.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `reload` reads: the day before today to a month ahead.
    static func loadedRange(now: Date = Date()) -> (Date, Date) {
        let from = Day.calendar.startOfDay(for: now).addingTimeInterval(-86400)
        return (from, from.addingTimeInterval(33 * 86400))
    }

    /// The panel's looking at `day`: if it's outside what's loaded, a fortnight round it is fetched.
    func want(_ day: String) { want(from: day, to: day) }

    /// The panel's looking at these days (a week, a month): if they're outside what's loaded,
    /// they're fetched, with a week either side.
    func want(from first: String, to last: String) {
        guard connected, let start = Day.date(first), let lastDay = Day.date(last) else { return }
        let end = lastDay.addingTimeInterval(86400)
        let (from, to) = Self.loadedRange()
        if start >= from, end <= to { return }
        if let range = furtherRange, start >= range.from, end <= range.to { return }
        let range = (from: start.addingTimeInterval(-7 * 86400), to: end.addingTimeInterval(7 * 86400))
        furtherRange = range
        Task { @MainActor in await fetchFurther(range) }
    }

    private func fetchFurther(_ range: (from: Date, to: Date)) async {
        var found: [GEvent] = []
        for calendar in google {
            if let some = try? await GoogleCalendarAPI.events(calendar.id, from: range.from, to: range.to) { found += some }
        }
        guard furtherRange.map({ $0.from == range.from }) == true else { return }
        let fresh = found.filter { $0.status != "cancelled" }.map(show).sorted { $0.start < $1.start }
        if fresh != further { further = fresh }
    }

    /// A day's events, for showing (floor meetings and the like left out of rundowns).
    func events(on day: String) -> [CalEvent] {
        guard showEvents else { return [] }
        return everything(on: day).filter { !rules.skips($0.title) }
    }

    /// Everything on the shown calendars that day, as Google has it: for the calendar panel,
    /// which is the calendar itself, not a rundown.
    func everything(on day: String) -> [CalEvent] {
        guard let start = Day.date(day), let end = Day.calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let loaded = Set(events.map(\.id))
        return (events + further.filter { !loaded.contains($0.id) }).filter { $0.start < end && $0.end > start && shownIds.contains($0.calendarId) }
    }

    /// Whether a day has anything on (for the panel's week).
    func hasEvents(on day: String) -> Bool { !everything(on: day).isEmpty }

    func color(of calendarId: String) -> String { calendars.first { $0.id == calendarId }?.color ?? "#8c8c8c" }

    /// The fortnight ahead, for the command line and the MCP server, and your calendars with
    /// their labels.
    private func writeSnapshot() {
        let now = Date()
        let soon = events.filter { shownIds.contains($0.calendarId) && $0.end > now.addingTimeInterval(-86400) && $0.start < now.addingTimeInterval(15 * 86400) && !rules.skips($0.title) }
        let json: [String: Any] = [
            "updated": Moment.ms(now),
            "calendars": google.map { calendar -> [String: Any] in
                var entry: [String: Any] = ["id": calendar.id, "name": calendar.name, "labels": calendar.labels.map(\.name).filter { !$0.isEmpty }]
                if let sub = rules.sub(for: calendar) { entry["key"] = sub.key; entry["about"] = sub.about }
                return entry
            },
            "events": soon.map { e -> [String: Any] in
                var event: [String: Any] = ["title": e.title, "start": Moment.ms(e.start), "end": Moment.ms(e.end), "allDay": e.allDay, "calendar": e.calendarTitle]
                if let label = e.label { event["label"] = label }
                if let location = e.location { event["location"] = location }
                if let task = e.taskId { event["task"] = task }
                return event
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        try? data.write(to: Paths.calendar, options: .atomic)
    }

    // MARK: - adding

    /// A form for putting a task on the calendar: its title and day, its time and length if it
    /// has them, and where the rules say it goes (only if they're sure).
    /// The form for an event typed into quick add (`/event lunch fri noon`): what was said, and
    /// where the rules would put it if they're sure. What's missing is asked for there.
    func form(title: String, due: String?, time: String?, minutes: Int?) -> EventForm {
        var form = EventForm()
        form.title = title
        if let due { form.day = Format.day(due) == "today" || Format.day(due) == "tomorrow" ? Format.day(due) : due }
        if let time {
            form.start = Format.time(time)
            if let minutes, let from = Day.moment(due ?? Day.today(), time) {
                form.end = Format.time(Day.clock(from.addingTimeInterval(Double(minutes) * 60)))
            }
        } else if let minutes {
            form.length = Format.minutes(minutes)
        }
        guard !title.isEmpty else { return form }
        let placement = rules.place(title, list: nil, tags: [])
        form.reason = placement.reason
        if placement.sure, let key = placement.key, let sub = rules.sub(key), let calendar = rules.calendar(for: sub, in: google) {
            form.calendarId = calendar.id
            form.label = placement.label
        }
        return form
    }

    func form(for task: TaskModel?) -> EventForm {
        var form = EventForm()
        guard let task else { return form }
        form.taskId = task.id
        form.title = task.title
        if let due = task.due ?? task.target { form.day = Format.day(due) == "today" || Format.day(due) == "tomorrow" ? Format.day(due) : due }
        if let time = task.time {
            form.start = Format.time(time)
            if let minutes = task.duration, let from = task.dueDate { form.end = Format.time(Day.clock(from.addingTimeInterval(Double(minutes) * 60))) }
        } else if let minutes = task.duration {
            form.length = Format.minutes(minutes)
        }
        let placement = rules.place(task.title, list: store.snap.list(task.listId), tags: task.tags)
        form.reason = placement.reason
        if placement.sure, let key = placement.key, let sub = rules.sub(key), let calendar = rules.calendar(for: sub, in: google) {
            form.calendarId = calendar.id
            form.label = placement.label
        }
        return form
    }

    func request(from form: EventForm) -> EventRequest {
        var request = EventRequest()
        request.title = form.title
        request.calendar = form.calendarId
        request.label = form.label ?? "none"
        request.day = form.day.isEmpty ? nil : form.day
        request.start = form.start.isEmpty ? nil : form.start
        request.end = form.end.isEmpty ? nil : form.end
        request.minutes = form.length.isEmpty ? nil : Ops.minutes(form.length).flatMap { $0 }
        request.allDay = form.allDay
        request.location = form.location
        request.description = form.description
        request.taskId = form.taskId
        request.tentative = form.tentative
        request.margs = form.margs
        return request
    }

    /// What adding it would do, or what's still missing.
    func outcome(for form: EventForm) -> EventOutcome {
        CalendarPlanner.plan(request(from: form), rules: rules, calendars: google, existing: raw, snap: store.snap)
    }

    /// Adds it (and takes any copy off m), and ties its task to it. An error to show, or nil.
    func add(_ form: EventForm) async -> String? {
        let outcome = self.outcome(for: form)
        guard outcome.questions.isEmpty, let first = outcome.plans.first else { return outcome.questions.joined(separator: " ") }
        do {
            var made: [GEvent] = []
            for plan in outcome.plans { made.append(try await GoogleCalendarAPI.insert(plan)) }
            for copy in outcome.offM { try? await GoogleCalendarAPI.delete(copy.calendarId, copy.id) }
            if let taskId = form.taskId, let event = made.first {
                var p = TaskPatch()
                p.event = .some(EventLink(id: event.id, calendar: first.calendarId))
                if store.snap.task(taskId)?.due != first.day { p.due = .some(first.day) }
                p.time = .some(first.allDay ? nil : first.start)
                if !first.allDay, let from = first.startDate, let to = first.endDate {
                    let minutes = Int(to.timeIntervalSince(from) / 60)
                    if minutes > 0 { p.duration = .some(minutes) }
                }
                store.change("on the calendar", undoable: false) { $0.updateTask(taskId, p) }
            }
            note = nil
            reload()
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Takes a task's event off the calendar (asked for), and lets go of it.
    func unblock(_ task: TaskModel) {
        guard let link = task.event else { return }
        if link.follows { return letGo(task) }
        Task { @MainActor in
            do {
                try await GoogleCalendarAPI.delete(link.calendar, link.id)
            } catch {
                note = "couldn't take it off google calendar: \(error)"
                return
            }
            var p = TaskPatch()
            p.event = .some(nil)
            store.change("off the calendar", undoable: false) { $0.updateTask(task.id, p) }
            reload()
        }
    }

    /// Gives a task a time in the next free spell (its length has to be known: nothing's
    /// assumed).
    func schedule(_ task: TaskModel) {
        guard let minutes = task.duration else {
            note = "how long will “\(task.title)” take? set its length first (no length is assumed)"
            return
        }
        guard let start = findTime(minutes: minutes, on: task.due) else {
            note = "no free time found this week for “\(task.title)”"
            return
        }
        var p = TaskPatch()
        p.due = .some(Day.string(start))
        p.time = .some(Day.clock(start))
        store.update(task.id, "find time", p)
    }

    // MARK: - keeping tasks and events in step

    func syncSoon() {
        soon?.invalidate()
        soon = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.connected else { return }
                Task { @MainActor in await self.sync() }
            }
        }
    }

    /// Each task tied to an event, made to agree with it: whichever changed last wins. Moved on
    /// the calendar (by you, Instinct, Claude…), the task follows; changed here, the event
    /// follows. An event that's gone lets go of its task. Its length is the event's own unless
    /// the task says.
    private func sync() async {
        guard connected, !syncing else { return }
        syncing = true
        defer { syncing = false }
        // Done ones are left as they are (and not asked about, which kept growing).
        let linked = store.snap.tasks.filter { $0.event != nil && !$0.done }.map(\.id)
        let known = Dictionary(raw.map { ($0.calendarId + "|" + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in linked {
            // As it is now (it may have changed while the last one was being sent).
            guard let task = store.snap.task(id), let link = task.event, !task.done else { continue }
            let event: GEvent?
            if let found = known[link.calendar + "|" + link.id] {
                event = found
            } else {
                do {
                    event = try await GoogleCalendarAPI.event(link.calendar, link.id)
                } catch {
                    // Couldn't ask (offline, signed out): every link stays as it is until next time.
                    return
                }
            }
            // Only an event Google says is gone (or cancelled) lets go of its task.
            guard let event, event.status != "cancelled" else {
                var p = TaskPatch()
                p.event = .some(nil)
                store.change("calendar", undoable: false) { $0.updateTask(id, p) }
                continue
            }
            await reconcile(task, event)
        }
    }

    /// Notes where a task and its event agree now (only if that's changed, so it doesn't loop).
    private func remember(_ taskId: String, event: GEvent) {
        guard let task = store.snap.task(taskId), var link = task.event else { return }
        let agreed = EventLink.signature(task)
        let seen = event.updated.map { $0.timeIntervalSince1970 * 1000 }
        guard link.agreed != agreed || link.seen != seen else { return }
        link.agreed = agreed
        link.seen = seen
        var p = TaskPatch()
        p.event = .some(link)
        store.change("calendar", undoable: false) { $0.updateTask(taskId, p) }
    }

    private func reconcile(_ task: TaskModel, _ event: GEvent) async {
        if task.event?.follows == true { return follow(task, event) }
        guard let due = task.due, let link = task.event else { return }
        var title = CalendarStyle.title(task.title)
        if event.title.hasSuffix("?"), !title.hasSuffix("?") { title += "?" }
        let length = task.duration.map { Double($0) * 60 } ?? event.end.timeIntervalSince(event.start)
        let wantStart = event.allDay ? Day.date(due) : (task.time != nil ? task.dueDate : Day.moment(due, Day.clock(event.start)))
        guard let wantStart else { return }
        let datesDiffer = event.allDay ? event.day != due : abs(event.start.timeIntervalSince(wantStart)) > 30 || abs(event.end.timeIntervalSince(event.start) - length) > 30
        let titleDiffers = event.title != title
        guard datesDiffer || titleDiffers else { return remember(task.id, event: event) }
        // Which moved since they last agreed. Only when that can't be told (both, or never
        // agreed yet), the one changed last wins.
        let taskMoved = link.agreed.map { $0 != EventLink.signature(task) }
        let eventMoved = link.seen.map { seen in (event.updated.map { $0.timeIntervalSince1970 * 1000 } ?? 0) > seen + 1 }
        let eventIsNewer: Bool
        switch (taskMoved, eventMoved) {
        case (false?, true?): eventIsNewer = true
        case (true?, false?): eventIsNewer = false
        default: eventIsNewer = (event.updated ?? .distantPast) > (task.updatedAt ?? .distantPast).addingTimeInterval(2)
        }
        if eventIsNewer {
            var p = TaskPatch()
            if datesDiffer {
                p.due = .some(event.day)
                p.time = event.allDay ? .some(nil) : .some(Day.clock(event.start))
                if !event.allDay, task.duration != nil { p.duration = .some(Int(event.end.timeIntervalSince(event.start) / 60)) }
            }
            if titleDiffers, CalendarStyle.title(event.title) != CalendarStyle.title(task.title) { p.title = event.title }
            store.change("from the calendar", undoable: false) { $0.updateTask(task.id, p) }
            remember(task.id, event: event)
        } else {
            var body: [String: Any] = [:]
            if titleDiffers { body["summary"] = title }
            if datesDiffer {
                let zone = TimeZone.autoupdatingCurrent.identifier
                if event.allDay {
                    // As long as it was (an event stretched over three days stays three days).
                    let days = max(Int((event.end.timeIntervalSince(event.start) / 86400).rounded()), 1)
                    body["start"] = ["date": due]
                    body["end"] = ["date": Day.adding(days, to: due) ?? due]
                } else {
                    body["start"] = ["dateTime": GoogleTime.string(wantStart), "timeZone": zone]
                    body["end"] = ["dateTime": GoogleTime.string(wantStart.addingTimeInterval(length)), "timeZone": zone]
                }
            }
            if let patched = try? await GoogleCalendarAPI.patch(event.calendarId, event.id, body) {
                // What it is now, so the next change doesn't send the same again.
                if let at = raw.firstIndex(where: { $0.id == patched.id && $0.calendarId == patched.calendarId }) { raw[at] = patched }
                remember(task.id, event: patched)
            } else {
                note = "couldn't update “\(title)” on google calendar"
            }
        }
    }

    /// A task that follows its event: the event's day, time and length, whenever they change.
    /// The event's never written to.
    private func follow(_ task: TaskModel, _ event: GEvent) {
        let p = Self.following(event, task: task)
        guard p.due != nil || p.time != nil || p.duration != nil else { return }
        store.change("from the calendar", undoable: false) { $0.updateTask(task.id, p) }
    }

    /// What a task takes from an event it follows (only what differs).
    static func following(_ event: GEvent, task: TaskModel) -> TaskPatch {
        var p = TaskPatch()
        let day = event.day
        let time = event.allDay ? nil : Day.clock(event.start)
        if task.due != day { p.due = .some(day) }
        if task.time != time { p.time = .some(time) }
        if !event.allDay {
            let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
            if minutes > 0, task.duration != minutes { p.duration = .some(minutes) }
        }
        return p
    }

    /// Ties a task to an event dropped on it: the task takes the event's day, time and length,
    /// and its list if one's named like the event's label or calendar; then follows it. The event
    /// isn't touched.
    func link(_ key: String, to taskId: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let task = store.snap.task(taskId),
              let shown = (events + further).first(where: { $0.calendarId == parts[0] && $0.eventId == parts[1] }),
              let event = raw.first(where: { $0.calendarId == parts[0] && $0.id == parts[1] }) ?? GEvent(shown) else { return false }
        var p = Self.following(event, task: task)
        p.event = .some(EventLink(id: event.id, calendar: event.calendarId, follows: true))
        p.someday = false
        let snap = store.snap
        let names = [shown.label, Mark(shown.calendarTitle)?.rest, shown.calendarTitle].compactMap { $0 }.filter { !$0.isEmpty }
        for name in names {
            if let list = snap.ownLists.first(where: { $0.bareName.lowercased() == name.lowercased() || $0.name.lowercased() == name.lowercased() }) {
                if list.id != task.listId { p.listId = list.id }
                break
            }
        }
        store.change("follow event") { $0.updateTask(taskId, p) }
        note = nil
        return true
    }

    /// Lets go of a task's event without touching the event.
    func letGo(_ task: TaskModel) {
        var p = TaskPatch()
        p.event = .some(nil)
        store.change("let go of the event") { $0.updateTask(task.id, p) }
    }

    /// Events called "todo: …" (or "toyl: …", "task: …") made into tasks: the words after it read
    /// as quick add reads them, due the event's day (at its time, for as long as it runs). The
    /// event's left as it is.
    private func importTodoEvents() async {
        guard importTodos else { return }
        // In the order they came in (oldest first), so trimming drops the oldest.
        var imported = defaults.stringArray(forKey: "calendar.imported") ?? []
        var done = Set(imported)
        let snap = store.snap
        let linked = Set(snap.tasks.compactMap { $0.event?.id })
        var added = false
        // Only the owner's own events: an invitation from anyone titled "todo: …" isn't a task.
        for event in raw where event.status != "cancelled" && event.mine && shownIds.contains(event.calendarId) && event.taskId == nil
            && !linked.contains(event.id) && !done.contains(event.id) && !(event.series.map(done.contains) ?? false) {
            let title = event.title
            guard let match = Self.todoPattern.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) else { continue }
            var draft = Quick.parse((title as NSString).substring(with: match.range(at: 1)), lists: snap.lists, weekStart: snap.weekStart).draft(source: "calendar")
            // A list that isn't there isn't made from the calendar.
            draft.newListName = nil
            if draft.due == nil { draft.due = event.day }
            if !event.allDay, draft.time == nil {
                draft.time = Day.clock(event.start)
                let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
                if draft.duration == nil, (5...480).contains(minutes) { draft.duration = minutes }
            }
            let notes = Self.plain(event.description)
            if draft.notes.isEmpty, !notes.isEmpty { draft.notes = notes }
            let made = draft
            store.change("from the calendar", undoable: false) { $0.addTask(made) }
            // A repeating one comes in once, not a task for every day of it.
            for key in [event.id, event.series].compactMap({ $0 }) where done.insert(key).inserted { imported.append(key) }
            added = true
        }
        if added {
            if imported.count > 500 {
                let current = Set(raw.map(\.id) + raw.compactMap(\.series))
                let spare = imported.count - 500
                var dropped = 0
                imported.removeAll { key in
                    guard dropped < spare, !current.contains(key) else { return false }
                    dropped += 1
                    return true
                }
            }
            defaults.set(imported, forKey: "calendar.imported")
        }
    }

    // MARK: - free time

    /// The next spell of `minutes` free of events and timed tasks, within the day's hours, on
    /// `day` (or from now, over the coming week), on the quarter hour.
    func findTime(minutes: Int, on day: String? = nil) -> Date? {
        let now = Date()
        var busy = raw.filter { !$0.allDay && $0.status != "cancelled" && shownIds.contains($0.calendarId) }.map { ($0.start, $0.end) }
        for task in store.snap.tasks where !task.done && task.time != nil && task.event == nil {
            if let start = task.dueDate, let length = task.duration { busy.append((start, start.addingTimeInterval(Double(length) * 60))) }
        }
        let firstDay = day.flatMap(Day.date).map { max($0, Day.calendar.startOfDay(for: now)) } ?? Day.calendar.startOfDay(for: now)
        let length = Double(max(minutes, 5)) * 60
        for offset in 0..<(day == nil ? 7 : 1) {
            guard let date = Day.calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let open = Day.calendar.date(bySettingHour: dayStart, minute: 0, second: 0, of: date),
                  let close = Day.calendar.date(bySettingHour: min(dayEnd, 23), minute: dayEnd >= 24 ? 59 : 0, second: 0, of: date) else { continue }
            var cursor = Self.quarter(max(open, now))
            while cursor.addingTimeInterval(length) <= close {
                let end = cursor.addingTimeInterval(length)
                if let clash = busy.filter({ $0.0 < end && $0.1 > cursor }).max(by: { $0.1 < $1.1 }) {
                    cursor = Self.quarter(clash.1)
                } else {
                    return cursor
                }
            }
        }
        return nil
    }

    private static func quarter(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900)
    }

    static let todoPattern = try! NSRegularExpression(pattern: #"^\s*(?:todo|to-do|toyl|task)\s*[:\-–]\s*(.+)$"#, options: [.caseInsensitive])
}
