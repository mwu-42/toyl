import AppKit

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
    @Published private(set) var events: [CalEvent] = []
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
        objectWillChange.send()
        further = []
        furtherRange = nil
        reload()
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
        guard connected, !loading else { return }
        loading = true
        let wantCalendars = google.isEmpty || (lastCalendars.map { Date().timeIntervalSince($0) > 1800 } ?? true)
        Task { @MainActor in
            defer { loading = false }
            do {
                if wantCalendars {
                    google = try await GoogleCalendarAPI.calendars()
                    lastCalendars = Date()
                    calendars = google.map { CalInfo(id: $0.id, title: $0.name, color: $0.color, writable: $0.writable, primary: $0.primary,
                                                     shownInGoogle: $0.shownInGoogle, labels: $0.labels) }
                }
                let (from, to) = Self.loadedRange()
                let mKey = rules.calendars.first(where: \.dedupe).flatMap { rules.calendar(for: $0, in: google) }?.id
                let wanted = google.filter { calendar in calendars.first { $0.id == calendar.id }.map(isShown) == true || calendar.id == mKey }
                var found: [GEvent] = []
                for calendar in wanted {
                    if let some = try? await GoogleCalendarAPI.events(calendar.id, from: from, to: to) { found += some }
                }
                raw = found
                let shownIds = Set(calendars.filter(isShown).map(\.id))
                let fresh = found.filter { $0.status != "cancelled" && shownIds.contains($0.calendarId) }.map(show).sorted { $0.start < $1.start }
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
                        taskId: event.taskId ?? store.snap.tasks.first { $0.event?.id == event.id }?.id,
                        notes: Self.plain(event.description), link: event.link)
    }

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

    /// The panel's looking at `day`: if it's outside what's loaded, its fortnight is fetched.
    func want(_ day: String) {
        guard connected, let date = Day.date(day) else { return }
        let (from, to) = Self.loadedRange()
        if date >= from, date < to.addingTimeInterval(-86400) { return }
        if let range = furtherRange, date >= range.from.addingTimeInterval(86400), date < range.to.addingTimeInterval(-86400) { return }
        let range = (from: date.addingTimeInterval(-7 * 86400), to: date.addingTimeInterval(8 * 86400))
        furtherRange = range
        Task { @MainActor in await fetchFurther(range) }
    }

    private func fetchFurther(_ range: (from: Date, to: Date)) async {
        let shown = google.filter { calendar in calendars.first { $0.id == calendar.id }.map(isShown) == true }
        var found: [GEvent] = []
        for calendar in shown {
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
        return (events + further.filter { !loaded.contains($0.id) }).filter { $0.start < end && $0.end > start }
    }

    /// Whether a day has anything on (for the panel's week).
    func hasEvents(on day: String) -> Bool { !everything(on: day).isEmpty }

    func color(of calendarId: String) -> String { calendars.first { $0.id == calendarId }?.color ?? "#8c8c8c" }

    /// The fortnight ahead, for the command line and the MCP server, and your calendars with
    /// their labels.
    private func writeSnapshot() {
        let now = Date()
        let soon = events.filter { $0.end > now.addingTimeInterval(-86400) && $0.start < now.addingTimeInterval(15 * 86400) && !rules.skips($0.title) }
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
        for task in store.snap.tasks where task.event != nil {
            guard let link = task.event else { continue }
            let known = raw.first { $0.id == link.id && $0.calendarId == link.calendar }
            let event: GEvent?
            if let known { event = known } else { event = try? await GoogleCalendarAPI.event(link.calendar, link.id) }
            guard let event, event.status != "cancelled" else {
                var p = TaskPatch()
                p.event = .some(nil)
                store.change("calendar", undoable: false) { $0.updateTask(task.id, p) }
                continue
            }
            await reconcile(task, event)
        }
    }

    private func reconcile(_ task: TaskModel, _ event: GEvent) async {
        guard let due = task.due else { return }
        var title = CalendarStyle.title(task.title)
        if event.title.hasSuffix("?"), !title.hasSuffix("?") { title += "?" }
        let length = task.duration.map { Double($0) * 60 } ?? event.end.timeIntervalSince(event.start)
        let wantStart = event.allDay ? Day.date(due) : (task.time != nil ? task.dueDate : Day.moment(due, Day.clock(event.start)))
        guard let wantStart else { return }
        let datesDiffer = event.allDay ? event.day != due : abs(event.start.timeIntervalSince(wantStart)) > 30 || abs(event.end.timeIntervalSince(event.start) - length) > 30
        let titleDiffers = event.title != title
        guard datesDiffer || titleDiffers else { return }
        let eventIsNewer = (event.updated ?? .distantPast) > (task.updatedAt ?? .distantPast).addingTimeInterval(2)
        if eventIsNewer {
            var p = TaskPatch()
            if datesDiffer {
                p.due = .some(event.day)
                p.time = event.allDay ? .some(nil) : .some(Day.clock(event.start))
                if !event.allDay, task.duration != nil { p.duration = .some(Int(event.end.timeIntervalSince(event.start) / 60)) }
            }
            if titleDiffers, CalendarStyle.title(event.title) != CalendarStyle.title(task.title) { p.title = event.title }
            store.change("from the calendar", undoable: false) { $0.updateTask(task.id, p) }
        } else {
            var body: [String: Any] = [:]
            if titleDiffers { body["summary"] = title }
            if datesDiffer {
                let zone = TimeZone.autoupdatingCurrent.identifier
                if event.allDay {
                    body["start"] = ["date": due]
                    body["end"] = ["date": Day.adding(1, to: due) ?? due]
                } else {
                    body["start"] = ["dateTime": GoogleTime.string(wantStart), "timeZone": zone]
                    body["end"] = ["dateTime": GoogleTime.string(wantStart.addingTimeInterval(length)), "timeZone": zone]
                }
            }
            if (try? await GoogleCalendarAPI.patch(event.calendarId, event.id, body)) == nil {
                note = "couldn't update “\(title)” on google calendar"
            }
        }
    }

    /// Events called "todo: …" (or "toyl: …", "task: …") made into tasks: the words after it read
    /// as quick add reads them, due the event's day (at its time, for as long as it runs). The
    /// event's left as it is.
    private func importTodoEvents() async {
        guard importTodos else { return }
        var imported = Set(defaults.stringArray(forKey: "calendar.imported") ?? [])
        let snap = store.snap
        let linked = Set(snap.tasks.compactMap { $0.event?.id })
        var added = false
        for event in raw where event.status != "cancelled" && event.taskId == nil && !linked.contains(event.id) && !imported.contains(event.id) {
            let title = event.title
            guard let match = Self.todoPattern.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) else { continue }
            var draft = Quick.parse((title as NSString).substring(with: match.range(at: 1)), lists: snap.lists, weekStart: snap.weekStart).draft(source: "calendar")
            if draft.due == nil { draft.due = event.day }
            if !event.allDay, draft.time == nil {
                draft.time = Day.clock(event.start)
                let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
                if draft.duration == nil, (5...480).contains(minutes) { draft.duration = minutes }
            }
            let notes = event.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.notes.isEmpty, !notes.isEmpty { draft.notes = notes }
            let made = draft
            store.change("from the calendar", undoable: false) { $0.addTask(made) }
            imported.insert(event.id)
            added = true
        }
        if added { defaults.set(Array(imported.suffix(500)), forKey: "calendar.imported") }
    }

    // MARK: - free time

    /// The next spell of `minutes` free of events and timed tasks, within the day's hours, on
    /// `day` (or from now, over the coming week), on the quarter hour.
    func findTime(minutes: Int, on day: String? = nil) -> Date? {
        let now = Date()
        var busy = raw.filter { !$0.allDay && $0.status != "cancelled" }.map { ($0.start, $0.end) }
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
