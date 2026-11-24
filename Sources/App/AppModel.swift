import AppKit
import Combine
import SwiftUI

/// One of the window's panels, which can go in any order.
enum Panel: String, CaseIterable {
    case calendar, tasks, details

    static let standard: [Panel] = [.tasks, .details, .calendar]

    /// What the owner calls it.
    var name: String {
        switch self {
        case .calendar: return "calendar"
        case .tasks: return "page"
        case .details: return "description"
        }
    }
}

/// What the window's showing and doing: the place picked in the sidebar, the tasks selected, the
/// filter, how each place is sorted and grouped, and every change made from it.
@MainActor
final class AppModel: ObservableObject {
    let store: Store
    let timers: TimerEngine
    let calendar: CalendarBridge
    let mail: MailBridge
    let canvas: CanvasBridge
    /// toyl on your iPhone (see `PhoneLink`).
    private(set) var phone: PhoneLink!

    @Published var place: Place {
        didSet {
            guard place != oldValue else { return }
            selection = []
            anchor = nil
            editing = nil
            if place != .search { filter = "" }
            defaults.set(place.key, forKey: "place")
        }
    }
    @Published var selection: Set<String> = []
    @Published var anchor: String?
    /// The task whose title is being edited in its row.
    @Published var editing: String?
    @Published var filter = ""
    @Published var showInspector: Bool { didSet { defaults.set(showInspector, forKey: "inspector") } }
    @Published var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: "sidebar") } }
    /// The calendar panel, on the right.
    @Published var showCalendar: Bool { didSet { defaults.set(showCalendar, forKey: "calendarPanel") } }
    /// The day the calendar panel shows; nil for today (whichever day that is).
    @Published var calendarDay: String?
    /// How wide the panels are (drag the line between them).
    @Published var sidebarWidth: CGFloat { didSet { defaults.set(Double(sidebarWidth), forKey: "width.sidebar") } }
    @Published var inspectorWidth: CGFloat { didSet { defaults.set(Double(inspectorWidth), forKey: "width.details") } }
    /// The calendar's width, one for each of day, week and month.
    @Published private var calendarWidths: [String: Double] { didSet { defaults.set(calendarWidths, forKey: "width.calendars") } }
    var calendarWidth: CGFloat {
        get { CGFloat(calendarWidths[calendarMode.rawValue] ?? Double(calendarMode.standardWidth)) }
        set { calendarWidths[calendarMode.rawValue] = Double(newValue) }
    }
    /// Day, week or month.
    @Published var calendarMode: CalendarMode { didSet { defaults.set(calendarMode.rawValue, forKey: "calendarMode"); wantShown() } }
    /// The window's panels, left to right (each shown or not): drag one by its grip to move it.
    @Published var panelOrder: [Panel] { didSet { defaults.set(panelOrder.map(\.rawValue), forKey: "panels.2") } }
    /// How tall the calendar's hours are (pinch, or ⌘= and ⌘-): 1 is 44 points an hour.
    @Published var calendarZoom: CGFloat { didSet { defaults.set(Double(calendarZoom), forKey: "calendarZoom") } }
    /// The page (the to-dos) showing: it can be hidden, leaving the calendar or the description to fill the window.
    @Published var showTasks: Bool { didSet { defaults.set(showTasks, forKey: "pagePanel") } }
    @Published var showDone = false
    /// A sidebar item being renamed: "list:id", "group:id" or "filter:id".
    @Published var renaming: String?
    /// Bumped to put the caret in the quick add field, or the filter.
    @Published var focusQuick = 0
    @Published var focusFilter = 0
    /// Shows what's typed in lower case too.
    @Published var lowercaseAll: Bool { didSet { defaults.set(lowercaseAll, forKey: "lowercaseAll") } }
    /// Autosort's guess for what's being typed into quick add.
    @Published var suggestWhileTyping: Bool { didSet { defaults.set(suggestWhileTyping, forKey: "suggest") } }
    @Published var collapsedGroups: Set<String> { didSet { defaults.set(Array(collapsedGroups), forKey: "collapsedGroups") } }
    @Published private var sorts: [String: String]
    @Published private var groupings: [String: String]
    /// Steps the on-device model is coming up with, for the task with this id.
    @Published var thinking: String?
    /// The last thing done, said at the top right for a moment, then faded out.
    @Published var banner: String? {
        didSet {
            fadeBanner?.cancel()
            guard banner != nil else { return }
            let fade = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.6)) { self?.banner = nil } }
            fadeBanner = fade
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: fade)
        }
    }
    private var fadeBanner: DispatchWorkItem?
    /// Autosort's suggestions for the inbox, showing.
    @Published var showAutosort = false
    /// Something being put on Google Calendar.
    @Published var calendarForm: EventForm?
    /// The heading whose + was clicked: a line under it to add a task straight there.
    @Published var addingTo: String?
    /// The task whose sublist is being added to, in its row (asked for: it isn't shown otherwise).
    @Published var addingSublist: String?
    /// The task the pointer's over (for swiping it), and the swipe going on, if one is.
    var hoveredTask: String?
    @Published var swipe: Swipe?
    private var swipeTrack: (id: String, dx: CGFloat, dy: CGFloat, sideways: Bool?)?
    private var swallowMomentum = false
    private var swipeWatch: Any?

    struct Swipe: Equatable {
        var id: String
        var offset: CGFloat
    }

    /// How far a swipe goes before it does something: a soft swipe, then a hard one.
    /// - right, soft: in progress (or out of it) · hard: in progress with a timer going
    /// - left, soft: a timer on it (or its timer stopped) · hard: delete
    static let swipeReach: CGFloat = 110
    static let swipeHardReach: CGFloat = 240

    /// A rubber band, as iOS pulls: free for the first `free` points, then harder and harder,
    /// never past `free + give`.
    static func rubber(_ x: CGFloat, free: CGFloat = 200, give: CGFloat = 160) -> CGFloat {
        let size = abs(x)
        guard size > free else { return x }
        let pulled = free + (1 - 1 / ((size - free) * 0.55 / give + 1)) * give
        return x < 0 ? -pulled : pulled
    }

    private let defaults = UserDefaults.standard
    private var forwarding: [AnyCancellable] = []
    private var learned: (stamp: Int, classifier: Classifier)?

    init(store: Store, timers: TimerEngine, calendar: CalendarBridge) {
        self.store = store
        self.timers = timers
        self.calendar = calendar
        mail = MailBridge(store: store, calendar: calendar)
        canvas = CanvasBridge(store: store)
        // The window opens on all.
        place = .anytime
        showInspector = defaults.object(forKey: "inspector") as? Bool ?? true
        showSidebar = defaults.object(forKey: "sidebar") as? Bool ?? true
        showCalendar = defaults.object(forKey: "calendarPanel") as? Bool ?? true
        sidebarWidth = CGFloat(defaults.object(forKey: "width.sidebar") as? Double ?? 238)
        inspectorWidth = CGFloat(defaults.object(forKey: "width.details") as? Double ?? 322)
        var widths = defaults.dictionary(forKey: "width.calendars") as? [String: Double] ?? [:]
        if widths.isEmpty, let old = defaults.object(forKey: "width.calendar") as? Double { widths["day"] = old }
        calendarWidths = widths
        calendarMode = CalendarMode(rawValue: defaults.string(forKey: "calendarMode") ?? "") ?? .day
        let saved = (defaults.stringArray(forKey: "panels.2") ?? []).compactMap(Panel.init(rawValue:))
        calendarZoom = CGFloat(defaults.object(forKey: "calendarZoom") as? Double ?? 1)
        showTasks = defaults.object(forKey: "pagePanel") as? Bool ?? true
        panelOrder = Set(saved) == Set(Panel.allCases) && saved.count == Panel.allCases.count ? saved : Panel.standard
        lowercaseAll = defaults.bool(forKey: "lowercaseAll")
        suggestWhileTyping = defaults.object(forKey: "suggest") as? Bool ?? true
        collapsedGroups = Set(defaults.stringArray(forKey: "collapsedGroups") ?? [])
        sorts = defaults.dictionary(forKey: "sorts") as? [String: String] ?? [:]
        groupings = defaults.dictionary(forKey: "groupings") as? [String: String] ?? [:]
        // What's shown follows the list, the timers and the calendar.
        forwarding = [
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            timers.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            calendar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            mail.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            canvas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
        ]
        if case .list(let id) = place, store.snap.list(id) == nil { place = .today }
        // Upcoming and logbook aren't places in the window any more.
        if place == .upcoming || place == .logbook { place = .today }
        phone = PhoneLink(model: self, testing: Self.phoneTesting)
    }

    var snap: Snapshot { store.snap }

    /// `toyl __phone` sets this: a fixed code and port, for trying the phone page out.
    nonisolated(unsafe) static var phoneTesting: (code: String, port: UInt16)?

    // MARK: - what's shown

    func sortMode(_ place: Place) -> SortMode { sorts[place.key].flatMap(SortMode.init(rawValue:)) ?? Views.defaultSort(place) }
    func groupMode(_ place: Place) -> GroupMode {
        let said = groupings[place.key].flatMap(GroupMode.init(rawValue:))
        return said == .section ? .none : said ?? Views.defaultGroup(place)
    }

    func setSort(_ mode: SortMode, for place: Place) {
        sorts[place.key] = mode.rawValue
        defaults.set(sorts, forKey: "sorts")
    }

    func setGroup(_ mode: GroupMode, for place: Place) {
        groupings[place.key] = mode.rawValue
        defaults.set(groupings, forKey: "groupings")
    }

    var query: Query? {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Query.parse(text, weekStart: snap.weekStart)
    }

    var groups: [TaskGroup] {
        let now = Date()
        let tasks = Views.tasks(for: place, in: snap, query: query, showDone: showDone, now: now)
        return Views.groups(tasks, place: place, mode: groupMode(place), sort: sortMode(place), snap: snap, now: now,
                            keepEmpty: place == .anytime && query == nil)
    }

    var visible: [TaskModel] { groups.flatMap(\.tasks) }

    var selectedTasks: [TaskModel] { selection.compactMap { snap.task($0) } }
    var selectedTask: TaskModel? { selection.count == 1 ? snap.task(selection.first!) : nil }

    func title(_ place: Place) -> String {
        switch place {
        case .inbox: return "inbox"
        case .today: return "today"
        case .upcoming: return "upcoming"
        case .anytime: return "all"
        case .logbook: return "logbook"
        case .ideas: return "ideas"
        case .timers: return "timers"
        case .inProgress: return "in progress"
        case .search: return "everything"
        case .list(let id): return snap.list(id).map { display($0.displayName) } ?? "list"
        case .tag(let tag): return "#" + tag
        case .filter(let id): return snap.filters.first { $0.id == id }.map { display($0.name) } ?? "filter"
        }
    }

    func icon(_ place: Place) -> String {
        switch place {
        case .inbox: return "tray"
        case .today: return "sun.max"
        case .upcoming: return "calendar"
        case .anytime: return "square.stack"
        case .logbook: return "checkmark.circle"
        case .ideas: return "lightbulb"
        case .timers: return "timer"
        case .inProgress: return "circle.lefthalf.filled"
        case .search: return "magnifyingglass"
        case .list: return "circle.fill"
        case .tag: return "number"
        case .filter: return "line.3.horizontal.decrease"
        }
    }

    func count(_ place: Place) -> Int {
        switch place {
        case .logbook, .timers, .search: return 0
        default: return Views.count(place, in: snap)
        }
    }

    var lateCount: Int { snap.tasks.filter { $0.isLate(at: Date()) && $0.due != Day.today() }.count }

    /// What's typed, shown as typed (or in lower case, if that's asked for).
    func display(_ text: String) -> String { lowercaseAll ? text.lowercased() : text }

    // MARK: - adding

    /// Adds what's typed into quick add, filed by where you are: in a list, into it (into a
    /// section, if one's given); in today, due today; in someday, put off; in a tag, tagged; in
    /// ideas, an idea. What's typed wins over all of that. The new task's id.
    @discardableResult
    func quickAdd(_ text: String, section group: TaskGroup? = nil) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let q = Quick.parse(text, lists: snap.lists, weekStart: snap.weekStart)
        var draft = q.draft(source: "toyl")
        let chosen = q.listId != nil || q.newList != nil || q.idea
        switch place {
        case .list(let id) where !chosen:
            draft.listId = id
        case .inbox where !chosen:
            draft.listId = ListModel.inbox
        case .ideas where !chosen:
            draft.listId = ListModel.dump
        case .today where draft.due == nil && draft.target == nil:
            draft.due = Day.today()
        case .tag(let tag):
            draft.tags = TaskModel.tags(draft.tags + [tag])
        default:
            break
        }
        if let group, let list = group.listId, !chosen {
            draft.listId = list
            draft.sectionId = group.sectionId
            draft.project = group.projectId
        }
        // Not filed anywhere: autosort's guess, if it's sure and that's wanted.
        if draft.listId == nil, draft.newListName == nil, suggestWhileTyping, let guess = suggestion(for: draft.title) { draft.listId = guess.list.id }
        var id = ""
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            id = store.add(draft)
            selection = [id]
            anchor = id
            editing = nil
        }
        // Added on the in progress page: in progress.
        if place == .inProgress, snap.task(id) != nil { toggleInProgress(id) }
        // "/timer" in it: a timer on it straight away.
        if let ask = q.timer, let task = snap.task(id) {
            timers.start(task: task, minutes: ask.minutes.map(Double.init), stopwatch: ask.stopwatch)
        }
        return id
    }

    // MARK: - making something else (a slash word at the start of quick add)

    /// Where a new project goes when no list's named: the + line's list, else the list you're in,
    /// else the inbox.
    func projectHome(under group: TaskGroup?) -> String {
        if let list = group?.listId { return list }
        if case .list(let id) = place { return id }
        return ListModel.inbox
    }

    /// What a command will make, said under the field as it's typed.
    func describe(_ command: Quick.Command, under group: TaskGroup? = nil) -> String {
        switch command {
        case .list(let name):
            return name.isEmpty ? "new list" : "new list “\(display(name))”"
        case .project(let name, let listId, let newList):
            let home = listId.flatMap { snap.list($0)?.displayName } ?? newList.map { "new list “\($0)”" }
                ?? snap.list(projectHome(under: group))?.displayName ?? "inbox"
            return (name.isEmpty ? "new project" : "new project “\(display(name))”") + " in " + display(home)
        case .group(let name):
            return name.isEmpty ? "new group of lists" : "new group “\(display(name))”"
        case .filter(let query):
            return query.isEmpty ? "the filter" : "saved filter “\(query)”"
        case .event(let title, let due, let time, let minutes):
            var parts = ["google calendar"]
            if !title.isEmpty { parts.append(display(title)) }
            if let due { parts.append(Format.day(due) + (time.map { " " + Format.time($0) } ?? "")) } else if let time { parts.append(Format.time(time)) }
            if let minutes { parts.append(Format.minutes(minutes)) }
            return parts.joined(separator: " · ")
        case .timer(let minutes, let stopwatch):
            return stopwatch ? "a stopwatch" : minutes.map { Format.minutes($0) + " timer" } ?? "a timer"
        }
    }

    /// Makes what a command says. `quiet` (from the phone): nothing on the Mac moves or waits for
    /// a name. Whether the window's wanted for it (a name to type, the calendar's form, the filter).
    @discardableResult
    func perform(_ command: Quick.Command, under group: TaskGroup? = nil, quiet: Bool = false) -> Bool {
        let back = place
        defer { if quiet { place = back; renaming = nil } }
        switch command {
        case .list(let name):
            newList(name.isEmpty ? "new list" : name, rename: name.isEmpty && !quiet)
            if !name.isEmpty || quiet { banner = "new list “\(display(name.isEmpty ? "new list" : name))”" }
            return name.isEmpty && !quiet
        case .project(let name, let listId, let newListName):
            var list = listId ?? projectHome(under: group)
            if listId == nil, let newListName {
                let id = UID.make()
                store.change("new list") { $0.addList(name: newListName, id: id) }
                list = id
            }
            newProject(in: list, name: name.isEmpty ? "new project" : name, rename: name.isEmpty && !quiet)
            if !name.isEmpty || quiet { banner = "new project “\(display(name.isEmpty ? "new project" : name))”" }
            return name.isEmpty && !quiet
        case .group(let name):
            newGroup(name.isEmpty ? "new group" : name, rename: name.isEmpty && !quiet)
            if !name.isEmpty || quiet { banner = "new group “\(display(name.isEmpty ? "new group" : name))”" }
            return name.isEmpty && !quiet
        case .filter(let query):
            guard !quiet else { return false }
            if query.isEmpty {
                focusFilter += 1
                return true
            }
            let id = UID.make()
            store.change("save filter") { $0.addFilter(name: query, query: query, id: id) }
            place = .filter(id)
            banner = "saved filter “\(query)”"
            return false
        case .event(let title, let due, let time, let minutes):
            guard !quiet else { return false }
            guard calendar.connected else {
                calendar.note = "connect google calendar first (settings › google calendar)"
                calendar.openSettings()
                return true
            }
            calendarForm = calendar.form(title: title, due: due, time: time, minutes: minutes)
            return true
        case .timer(let minutes, let stopwatch):
            timers.start(task: nil, minutes: minutes.map(Double.init), stopwatch: stopwatch, label: stopwatch ? "stopwatch" : "timer")
            banner = stopwatch ? "stopwatch going" : (minutes.map { Format.minutes($0) + " timer going" } ?? "timer going")
            return false
        }
    }

    // MARK: - autosort

    func classifier() -> Classifier {
        let stamp = snap.tasks.count &+ snap.tasks.reduce(0) { $0 &+ $1.listId.hashValue &+ $1.title.count }
        if let learned, learned.stamp == stamp { return learned.classifier }
        let made = Classifier(tasks: snap.tasks, lists: snap.lists)
        learned = (stamp, made)
        return made
    }

    /// Where autosort would put a task with this title, if it's fairly sure.
    func suggestion(for title: String) -> (list: ListModel, confidence: Double)? {
        guard title.count >= 3, let guess = classifier().suggestList(for: title, threshold: 0.7), let list = snap.list(guess.id) else { return nil }
        return (list, guess.confidence)
    }

    func autosortInbox() -> [Actions.Suggestion] { Actions.autosort(snap) }

    func applyAutosort(_ suggestions: [Actions.Suggestion]) {
        store.change(suggestions.count == 1 ? "file" : "autosort") { doc in
            for s in suggestions {
                var p = TaskPatch()
                if let list = s.list { p.listId = list.id }
                p.addTags = s.tags
                doc.updateTask(s.task.id, p)
            }
        }
    }

    /// Sorting everything in the inbox, now.
    @Published var sorting = false

    /// One click: every inbox task filed where it belongs (autosort, then Apple's on-device model
    /// for the rest; what no list clearly fits stays). One change, so ⌘z undoes it all.
    func autosortEverything() {
        guard !sorting else { return }
        let snap = self.snap
        let count = snap.tasks.filter { $0.listId == ListModel.inbox && !$0.done && !$0.isIdea }.count
        guard count > 0 else { banner = "the inbox is empty"; return }
        sorting = true
        let ask: ((TaskModel, [ListModel], [String: [String]]) async -> String?)? = OnDevice.isAvailable
            ? { task, lists, examples in await OnDevice.list(for: task.title, among: lists, examples: examples) } : nil
        Task { @MainActor in
            let sorted = await Actions.sortInbox(snap, ask: ask)
            sorting = false
            let moves = sorted.suggestions.filter { $0.list != nil }
            if !moves.isEmpty { withAnimation(.easeInOut(duration: 0.3)) { applyAutosort(sorted.suggestions) } }
            banner = moves.isEmpty ? "no list fits these yet" : "sorted \(moves.count)" + (sorted.left.isEmpty ? "" : " · \(sorted.left.count) left")
        }
    }

    /// Asks Apple's on-device model where the inbox tasks autosort couldn't place belong.
    func autosortWithAppleIntelligence() {
        guard OnDevice.isAvailable else { banner = "apple intelligence isn't on, so autosort used what it learned alone"; return }
        let lists = snap.ownLists.filter { !$0.archived }
        let examples = Dictionary(grouping: snap.tasks.filter { !$0.isIdea }, by: \.listId).mapValues { $0.prefix(8).map(\.title) }
        let placed = Set(autosortInbox().compactMap { $0.list == nil ? nil : $0.task.id })
        let leftover = snap.tasks.filter { $0.listId == ListModel.inbox && !$0.done && !placed.contains($0.id) }
        guard !leftover.isEmpty else { banner = "nothing left in the inbox to sort"; return }
        banner = "asking apple intelligence about \(leftover.count)…"
        Task { @MainActor in
            var moves: [(String, String)] = []
            for task in leftover {
                if let list = await OnDevice.list(for: task.title, among: lists, examples: examples) { moves.append((task.id, list)) }
            }
            if !moves.isEmpty {
                store.change("autosort") { doc in for (task, list) in moves { var p = TaskPatch(); p.listId = list; doc.updateTask(task, p) } }
            }
            banner = moves.isEmpty ? "apple intelligence wasn't sure about any of them" : "filed \(moves.count) with apple intelligence"
        }
    }

    /// Breaks the task into a sublist (`subtasks` in the file) with Apple's on-device model.
    func breakDown(_ task: TaskModel) {
        guard OnDevice.isAvailable else { banner = "a sublist from apple intelligence needs it on"; return }
        thinking = task.id
        Task { @MainActor in
            let steps = await OnDevice.steps(for: task.title, notes: task.notes)
            thinking = nil
            guard !steps.isEmpty, let current = snap.task(task.id) else { banner = "couldn't make a sublist for that one"; return }
            var p = TaskPatch()
            p.subtasks = current.subtasks + steps.map { Subtask(title: $0) }
            store.update(task.id, "break down", p)
        }
    }

    // MARK: - selecting

    /// A click: on its own, just this one; with ⌘, this one in or out; with ⇧, everything from
    /// the last one clicked.
    func select(_ id: String, command: Bool = false, shift: Bool = false) {
        if shift, let anchor, let from = visible.firstIndex(where: { $0.id == anchor }), let to = visible.firstIndex(where: { $0.id == id }) {
            selection = Set(visible[min(from, to)...max(from, to)].map(\.id))
            return
        }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
            if editing != id { editing = nil }
        }
        anchor = id
    }

    func moveSelection(_ delta: Int, extend: Bool = false) {
        let tasks = visible
        guard !tasks.isEmpty else { return }
        // Nothing selected (Escape let go of it): from the top (or the foot), not where it was.
        let current = selection.isEmpty ? nil : anchor.flatMap { id in tasks.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), tasks.count - 1) } ?? (delta > 0 ? 0 : tasks.count - 1)
        let id = tasks[next].id
        if extend { selection.insert(id) } else { selection = [id] }
        anchor = id
        editing = nil
    }

    func selectAll() { selection = Set(visible.map(\.id)) }

    /// Coming down into the list (from quick add or the filter): what's selected, if it shows;
    /// else the first task.
    func enterList() {
        let shown = visible
        guard !shown.contains(where: { selection.contains($0.id) }) else { return }
        selection = []
        anchor = nil
        moveSelection(1)
    }

    // MARK: - changing what's selected

    var targets: [String] { Array(selection) }

    /// Tasks being checked off: ticked at once, and gone a moment later (a second click in that
    /// moment changes its mind).
    @Published var completing: Set<String> = []

    func toggleSelected() { complete(targets) }

    /// Checks tasks off (or back on), with a quick tick and a fade.
    func complete(_ ids: [String]) {
        let tasks = ids.compactMap { snap.task($0) }
        guard !tasks.isEmpty else { return }
        let changingMind = ids.filter { completing.contains($0) }
        if !changingMind.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { completing.subtract(changingMind) }
            return
        }
        if tasks.allSatisfy(\.done) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.toggle(ids) }
            return
        }
        let checking = tasks.filter { !$0.done }.map(\.id)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { completing.formUnion(checking) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            guard let self else { return }
            let still = checking.filter { self.completing.contains($0) }
            guard !still.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                self.store.toggle(still)
                self.completing.subtract(still)
            }
        }
    }

    /// Done, or on its way to being.
    func isDone(_ task: TaskModel) -> Bool { task.done || completing.contains(task.id) }

    func deleteSelected() {
        let ids = targets
        guard !ids.isEmpty else { return }
        let after = visible.drop { !ids.contains($0.id) }.first { !ids.contains($0.id) }?.id
        withAnimation(.easeInOut(duration: 0.22)) {
            store.delete(ids)
            selection = after.map { [$0] } ?? []
            anchor = after
        }
    }

    func setDue(_ day: String?, for ids: [String]? = nil) {
        let ids = ids ?? targets
        store.update(ids, day == nil ? "no date" : "reschedule") { task in
            var p = TaskPatch()
            p.due = .some(day)
            if day == nil { p.time = .some(nil) }
            if day != nil { p.someday = false }
            return p
        }
    }

    func setAim(_ day: String?, for ids: [String]? = nil) {
        store.update(ids ?? targets, "aim") { _ in var p = TaskPatch(); p.target = .some(day); return p }
    }

    func togglePin(_ ids: [String]? = nil) {
        let ids = ids ?? targets
        let pin = !ids.compactMap { snap.task($0) }.allSatisfy(\.pinned)
        store.update(ids, pin ? "pin" : "unpin") { _ in var p = TaskPatch(); p.pinned = pin; return p }
    }

    /// Puts tasks off into ideas (they keep their list, to come back to), or brings them back.
    func toggleSomeday(_ ids: [String]? = nil) {
        let ids = ids ?? targets
        let put = !ids.compactMap { snap.task($0) }.allSatisfy(\.someday)
        withAnimation(.easeInOut(duration: 0.22)) {
            store.update(ids, put ? "to ideas" : "out of ideas") { _ in var p = TaskPatch(); p.someday = put; return p }
        }
    }

    /// Starts a timer on a task: a countdown of `minutes` (its own length, else the usual), or a stopwatch.
    func timer(_ task: TaskModel, minutes: Double? = nil, stopwatch: Bool = false) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { timers.start(task: task, minutes: minutes, stopwatch: stopwatch) }
    }

    func move(_ ids: [String]? = nil, to list: String, section: String? = nil) {
        let ids = ids ?? targets
        store.update(ids, "move") { _ in var p = TaskPatch(); p.listId = list; p.sectionId = section; return p }
    }

    func toggleTag(_ tag: String, for ids: [String]? = nil) {
        let ids = ids ?? targets
        let has = ids.compactMap { snap.task($0) }.allSatisfy { $0.hasTag(tag) }
        store.update(ids, has ? "untag" : "tag") { _ in
            var p = TaskPatch()
            if has { p.removeTags = [tag] } else { p.addTags = [tag] }
            return p
        }
    }

    func startTimer(minutes: Double? = nil, stopwatch: Bool = false) {
        guard let task = selectedTask ?? selectedTasks.first else { return }
        timers.start(task: task, minutes: minutes, stopwatch: stopwatch)
    }

    /// Copies a task as an agent would want it: its id and title, to paste into a chat.
    func copyForAgent(_ ids: [String]? = nil) {
        let lines = (ids ?? targets).compactMap { snap.task($0) }.map { "toyl task \($0.id): \($0.title)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Drops: tasks dragged here (as "toyl:id,id"), or text from anywhere (a task a line).
    func drop(_ items: [String], list: String, section: String?, before: String?, project: String?? = nil) -> Bool {
        for item in items where !item.hasPrefix("toyl-panel:") && !item.hasPrefix("toyl-event:") {
            if item.hasPrefix("toyl:") {
                let ids = item.dropFirst(5).split(separator: ",").map(String.init).filter { snap.task($0) != nil }
                guard !ids.isEmpty else { continue }
                store.place(ids, list: list, section: section, before: before)
                if let project { store.update(ids, "project") { _ in var p = TaskPatch(); p.project = .some(project); return p } }
            } else {
                for line in item.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                    var draft = Quick.parse(line, lists: snap.lists, weekStart: snap.weekStart).draft(source: "drop")
                    if draft.listId == nil && draft.newListName == nil { draft.listId = list; draft.sectionId = section }
                    store.add(draft)
                }
            }
        }
        return true
    }

    // MARK: - lists, groups, filters

    @discardableResult
    func newList(_ name: String = "new list", group: String? = nil, rename: Bool = true) -> String {
        let id = UID.make()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.change("new list") { $0.addList(name: name, group: group, id: id) } }
        place = .list(id)
        if rename { renaming = "list:" + id }
        return id
    }

    func renameList(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.change("rename list") { $0.updateList(id, name: name) }
    }

    func setColor(_ color: String, list id: String) { store.change("color") { $0.updateList(id, color: color) } }

    // MARK: - projects

    /// A new project in a list, its name ready to type.
    @discardableResult
    func newProject(in list: String, name: String = "new project", rename: Bool = true) -> String {
        let id = UID.make()
        withAnimation(.snappy(duration: 0.25)) { store.change("new project") { $0.addProject(to: list, name: name, id: id) } }
        if place != .list(list), list != ListModel.inbox || place != .inbox { place = list == ListModel.inbox ? .inbox : .list(list) }
        setGroup(.project, for: place)
        if rename { renaming = "project:" + id }
        return id
    }

    /// Turns a task (with a sublist) into a project: its items become the project's tasks.
    func makeProject(from taskId: String) {
        guard let task = snap.task(taskId) else { return }
        let project = UID.make()
        let ids = task.subtasks.map { _ in UID.make() }
        let list = task.listId
        withAnimation(.snappy(duration: 0.3)) {
            store.change("into a project") { $0.makeProject(from: taskId, id: project, taskIds: ids) }
            place = list == ListModel.inbox ? .inbox : .list(list)
            setGroup(.project, for: place)
            selection = []
        }
        banner = "“\(task.title)” is a project now"
    }

    func renameProject(_ id: String, in list: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.change("rename project") { $0.renameProject(id, in: list, to: name) }
    }

    func deleteProject(_ id: String, in list: String) {
        withAnimation(.snappy(duration: 0.25)) { store.change("delete project") { $0.deleteProject(id, in: list) } }
    }

    /// Puts tasks in a project (nil: in none). They're moved into its list if they aren't in it.
    func setProject(_ project: String?, list: String, for ids: [String]? = nil) {
        let ids = ids ?? targets
        withAnimation(.snappy(duration: 0.25)) {
            store.update(ids, project == nil ? "no project" : "project") { _ in
                var p = TaskPatch()
                p.listId = list
                p.project = .some(project)
                return p
            }
        }
    }
    func setGroup(_ group: String?, list id: String) { store.change("move list") { $0.updateList(id, group: .some(group)) } }
    func archive(_ id: String, _ on: Bool) { store.change(on ? "archive" : "unarchive") { $0.updateList(id, archived: on) } }

    func deleteList(_ id: String) {
        if place == .list(id) { place = .inbox }
        store.change("delete list") { $0.deleteList(id, keepTasks: true) }
    }

    func moveList(_ id: String, before: String?) { store.change("move list") { $0.moveList(id, before: before) } }

    func addSection(to list: String) {
        let id = UID.make()
        store.change("new section") { $0.addSection(to: list, name: "new section", id: id) }
    }

    @discardableResult
    func newGroup(_ name: String = "new group", rename: Bool = true) -> String {
        let id = UID.make()
        store.change("new group") { $0.addGroup(name: name, id: id) }
        if rename { renaming = "group:" + id }
        return id
    }

    func renameGroup(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.change("rename group") { $0.renameGroup(id, to: name) }
    }

    func deleteGroup(_ id: String) { store.change("delete group") { $0.deleteGroup(id) } }

    /// Saves what's in the filter field as a smart list of its own.
    func saveFilter() {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let id = UID.make()
        store.change("save filter") { $0.addFilter(name: query, query: query, id: id) }
        filter = ""
        place = .filter(id)
        renaming = "filter:" + id
    }

    func renameFilter(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.change("rename filter") { $0.updateFilter(id, name: name) }
    }

    func deleteFilter(_ id: String) {
        if place == .filter(id) { place = .today }
        store.change("delete filter") { $0.deleteFilter(id) }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: - the calendar panel

    var shownDay: String { calendarDay ?? Day.today(timers.now) }

    /// Moves the calendar on or back: a day, a week or a month, as it's showing.
    func stepDay(_ steps: Int) {
        let day: String?
        switch calendarMode {
        case .day: day = Day.adding(steps, to: shownDay)
        case .week: day = Day.adding(steps * 7, to: shownDay)
        case .month: day = Day.date(shownDay).flatMap { Day.calendar.date(byAdding: .month, value: steps, to: $0) }.map(Day.string)
        }
        if let day { showDay(day) }
    }

    func showDay(_ day: String) {
        calendarDay = day == Day.today() ? nil : day
        wantShown()
    }

    /// The days the calendar's showing, first to last.
    var shownDays: [String] {
        switch calendarMode {
        case .day: return [shownDay]
        case .week: return CalendarDays.week(of: shownDay, start: snap.weekStart)
        case .month: return CalendarDays.month(of: shownDay, start: snap.weekStart)
        }
    }

    /// Fetches what's on those days, if they're outside what's loaded.
    func wantShown() {
        let days = shownDays
        guard let first = days.first, let last = days.last else { return }
        calendar.want(from: first, to: last)
    }

    // MARK: - panels

    /// Puts `panel` where `target` is (dragged onto it).
    func movePanel(_ panel: Panel, to target: Panel) {
        guard panel != target, let to = panelOrder.firstIndex(of: target) else { return }
        var order = panelOrder.filter { $0 != panel }
        order.insert(panel, at: min(to, order.count))
        withAnimation(.snappy(duration: 0.25)) { panelOrder = order }
    }

    /// Moves `panel` one place left (-1) or right (+1).
    func nudgePanel(_ panel: Panel, _ by: Int) {
        guard let from = panelOrder.firstIndex(of: panel) else { return }
        let to = min(max(from + by, 0), panelOrder.count - 1)
        guard to != from else { return }
        var order = panelOrder
        order.swapAt(from, to)
        withAnimation(.snappy(duration: 0.25)) { panelOrder = order }
    }

    /// Zooms the calendar's hours in (+1) or out (-1), or back to the usual (0).
    func zoomCalendar(_ way: Int) {
        let steps: [CGFloat] = [0.5, 0.65, 0.8, 1, 1.25, 1.5, 1.8, 2.2, 2.6]
        if way == 0 { calendarZoom = 1; return }
        let next = way > 0 ? steps.first { $0 > calendarZoom + 0.01 } : steps.last { $0 < calendarZoom - 0.01 }
        calendarZoom = next ?? calendarZoom
    }

    static let zoomRange: ClosedRange<CGFloat> = 0.5...2.6

    /// Whether a panel's showing now.
    func isShown(_ panel: Panel) -> Bool {
        switch panel {
        case .tasks: return showTasks
        case .calendar: return showCalendar
        case .details: return showInspector && place != .timers
        }
    }

    /// Shows or hides a panel (the page, the description, the calendar). The last one showing
    /// can't go: hiding it brings the page back.
    func setShown(_ panel: Panel, _ on: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            switch panel {
            case .tasks: showTasks = on
            case .calendar: showCalendar = on
            case .details: showInspector = on
            }
            if !Panel.allCases.contains(where: isShown) { showTasks = true }
        }
    }

    /// The panel that takes the window's spare width: the page, else the calendar, else the description.
    var fillingPanel: Panel? { [Panel.tasks, .calendar, .details].first(where: isShown) }

    /// Tasks dropped on the panel's hours: due that day at that time (and their events follow, if
    /// they're on the calendar). Text dropped there becomes a task at that time.
    func schedule(_ items: [String], day: String, time: String?, keepTime: Bool = false) {
        for item in items where !item.hasPrefix("toyl-panel:") && !item.hasPrefix("toyl-event:") {
            if item.hasPrefix("toyl:") {
                let ids = item.dropFirst(5).split(separator: ",").map(String.init).filter { snap.task($0) != nil }
                guard !ids.isEmpty else { continue }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    store.update(ids, time == nil ? "reschedule" : "time") { _ in
                        var p = TaskPatch()
                        p.due = .some(day)
                        if !keepTime { p.time = .some(time) }
                        p.someday = false
                        return p
                    }
                }
            } else {
                for line in item.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                    var draft = Quick.parse(line, lists: snap.lists, weekStart: snap.weekStart).draft(source: "drop")
                    draft.due = day
                    draft.time = time
                    store.add(draft)
                }
            }
        }
    }

    /// An event dragged from the calendar onto a task: the task follows it (its day, time, length
    /// and list) and the event stays as it is.
    @discardableResult
    func linkEvent(_ items: [String], to taskId: String) -> Bool {
        guard let item = items.first(where: { $0.hasPrefix("toyl-event:") }) else { return false }
        let linked = withAnimation(.snappy(duration: 0.25)) { calendar.link(String(item.dropFirst(11)), to: taskId) }
        if linked {
            selection = [taskId]
            anchor = taskId
            banner = nil
        }
        return linked
    }

    // MARK: - the keys

    /// The field the window's Return and typing go to: quick add, or the timers page's field.
    private var quickName: String { place == .timers ? "timer" : "quick" }

    /// Lets go of the keys from whatever field has them, so the list has them.
    func leaveTyping() { Keys.letGo() }

    /// Puts the caret in quick add (or the timers page's field), at the end of what's there.
    /// Whether there was one on screen.
    @discardableResult
    func focusQuickAdd() -> Bool {
        guard let field = InkField.named(quickName) else { return false }
        field.takeKeys()
        return true
    }

    private var keyWatch: Any?

    /// The list's keys, for the whole window whenever nothing's being typed (not only when the
    /// list happens to have focus):
    /// - Return: a new task (the caret in quick add; with the page hidden, quick entry)
    /// - a letter: the start of a new task, typed into quick add
    /// - ↑ ↓ (⇧ to extend): move the selection; ↑ from the first task goes up into quick add
    /// - space: the description, shown or hidden · ⌫: delete · Escape: let go of what's selected
    func watchKeys(in window: NSWindow, quickEntry: @escaping () -> Void) {
        Keys.window = window
        guard keyWatch == nil else { return }
        keyWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window else { return event }
            let taken = MainActor.assumeIsolated { self.listKey(event, in: window, quickEntry: quickEntry) }
            return taken ? nil : event
        }
    }

    /// Whether the key was the list's (and so goes no further).
    func listKey(_ event: NSEvent, in window: NSWindow, quickEntry: () -> Void, requireKey: Bool = true) -> Bool {
        guard event.window === window, window.isKeyWindow || !requireKey, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSText) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }
        let shift = flags.contains(.shift)
        let list = showTasks && place != .timers
        switch event.keyCode {
        case 36, 76: // return, enter
            editing = nil
            if !showTasks || !focusQuickAdd() { quickEntry() }
            return true
        case 126 where list: // up
            if !shift, let anchor, !selection.isEmpty, visible.first?.id == anchor {
                selection = []
                focusQuickAdd()
            } else {
                moveSelection(-1, extend: shift)
            }
            return true
        case 125 where list: // down
            moveSelection(1, extend: shift)
            return true
        case 49 where list && !selection.isEmpty: // space
            setShown(.details, !showInspector)
            return true
        case 51 where list && !selection.isEmpty, 117 where list && !selection.isEmpty: // delete
            deleteSelected()
            return true
        case 53: // escape
            if addingTo != nil || addingSublist != nil {
                withAnimation(.snappy(duration: 0.2)) { addingTo = nil; addingSublist = nil }
            } else if !selection.isEmpty {
                selection = []
            } else if !filter.isEmpty {
                filter = ""
            }
            return true
        default:
            break
        }
        // A letter with nothing to type it into: the start of a new task. The field takes the keys
        // and the letter carries on to it (so accents and other input methods still work).
        guard showTasks, let typed = event.characters, let first = typed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(first), !(0xF700...0xF8FF).contains(first.value),
              !typed.trimmingCharacters(in: .whitespaces).isEmpty,
              let field = InkField.named(quickName) else { return false }
        field.takeKeys()
        return !field.hasKeys
    }

    // MARK: - swiping (as Mail does, two fingers on the trackpad)

    /// Watches the trackpad for sideways swipes over a task: right moves it to in progress, left
    /// deletes it (as Mail's left swipe does).
    func watchSwipes() {
        guard swipeWatch == nil else { return }
        swipeWatch = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.swiped(event) ? nil : event }
        }
    }

    /// A scroll from the trackpad: whether it was a swipe on a task (and so not a scroll).
    private func swiped(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase.isEmpty, !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { defer { swallowMomentum = false }; return swallowMomentum }
            return swallowMomentum
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swallowMomentum = false
            if let id = hoveredTask, editing == nil { swipeTrack = (id, 0, 0, nil) } else { swipeTrack = nil }
            return false
        }
        if event.phase.contains(.changed) {
            guard var track = swipeTrack else { return false }
            // The way the fingers went (natural scrolling or not).
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            track.dx += dx
            track.dy += abs(event.scrollingDeltaY)
            if track.sideways == nil {
                if abs(track.dx) > 10, abs(track.dx) > track.dy * 1.5 { track.sideways = true } else if track.dy > 10 { track.sideways = false }
            }
            swipeTrack = track
            guard track.sideways == true else { return false }
            swipe = Swipe(id: track.id, offset: Self.rubber(track.dx))
            return true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            guard let track = swipeTrack else { return false }
            swipeTrack = nil
            guard track.sideways == true else { return false }
            swallowMomentum = true
            let offset = swipe?.offset ?? track.dx
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { swipe = nil }
            let running = timers.timer(for: track.id)
            if offset >= Self.swipeHardReach {
                startInProgress(track.id)
            } else if offset >= Self.swipeReach {
                toggleInProgress(track.id)
            } else if offset > -Self.swipeHardReach {
                if offset <= -Self.swipeReach {
                    if let running {
                        withAnimation(.snappy(duration: 0.2)) { timers.stop(running.id) }
                    } else if let task = snap.task(track.id), !task.done {
                        timer(task)
                    }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.22)) { store.delete([track.id]) }
                selection.remove(track.id)
                banner = "deleted"
            }
            return true
        }
        return false
    }

    /// Moves a task into its list's "in progress" section (made if the list hasn't one), or back
    /// out to the first section if it's there already.
    func toggleInProgress(_ id: String) {
        guard let task = snap.task(id), let list = snap.list(task.listId) else { return }
        let progress = list.sections.first { $0.name.lowercased() == "in progress" }
        withAnimation(.snappy(duration: 0.25)) {
            if let progress, task.sectionId == progress.id {
                let back = list.sections.first { $0.id != progress.id }?.id ?? list.firstSection
                store.update(id, "out of in progress", { var p = TaskPatch(); p.listId = list.id; p.sectionId = back; return p }())
            } else if let progress {
                store.update(id, "in progress", { var p = TaskPatch(); p.listId = list.id; p.sectionId = progress.id; return p }())
            } else {
                let section = UID.make()
                store.change("in progress") { doc in
                    _ = doc.addSection(to: list.id, name: "in progress", id: section)
                    var p = TaskPatch()
                    p.listId = list.id
                    p.sectionId = section
                    doc.updateTask(id, p)
                }
            }
        }
    }

    /// In progress, with a timer going on it (a long swipe right).
    func startInProgress(_ id: String) {
        if let task = snap.task(id), !isInProgress(task) { toggleInProgress(id) }
        if let task = snap.task(id), timers.timer(for: id) == nil { timer(task) }
    }

    /// Whether a task's in its list's "in progress" section.
    func isInProgress(_ task: TaskModel) -> Bool {
        snap.list(task.listId)?.sections.first { $0.id == task.sectionId }?.name.lowercased() == "in progress"
    }

    /// Clears a task's time (it stays due that day).
    func clearTime(_ id: String) {
        store.update([id], "no time") { _ in var p = TaskPatch(); p.time = .some(nil); return p }
    }

    /// Shows a task: in its list if it isn't where you are, selected, with its details.
    func reveal(task id: String) {
        guard let task = snap.task(id) else { return }
        if !visible.contains(where: { $0.id == id }) {
            place = task.isIdea ? .ideas : task.listId == ListModel.inbox ? .inbox : .list(task.listId)
        }
        selection = [id]
        anchor = id
        showInspector = true
    }

    /// A new event at a time on the panel: the add-to-calendar form, with the day and start filled in.
    func newEvent(day: String, time: String?) {
        guard calendar.connected else { calendar.openSettings(); return }
        var form = EventForm()
        let said = Format.day(day)
        form.day = said == "today" || said == "tomorrow" ? said : day
        if let time { form.start = Format.time(time) }
        calendarForm = form
    }

    /// Puts a task (or nothing yet) on Google Calendar: the form, filled in the rules' way.
    func addToCalendar(_ task: TaskModel? = nil) {
        guard calendar.connected else {
            calendar.note = "connect google calendar first (settings › google calendar)"
            calendar.openSettings()
            return
        }
        calendarForm = calendar.form(for: task)
    }
}
