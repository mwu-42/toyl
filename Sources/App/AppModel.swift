import AppKit
import Combine
import SwiftUI

/// What the window's showing and doing: the place picked in the sidebar, the tasks selected, the
/// filter, how each place is sorted and grouped, and every change made from it.
@MainActor
final class AppModel: ObservableObject {
    let store: Store
    let timers: TimerEngine
    let calendar: CalendarBridge
    let mail: MailBridge
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
    @Published var calendarWidth: CGFloat { didSet { defaults.set(Double(calendarWidth), forKey: "width.calendar") } }
    @Published var showDone = false
    /// A sidebar item being renamed: "list:id", "group:id" or "filter:id".
    @Published var renaming: String?
    /// Bumped to put the caret in the quick add field, or the filter.
    @Published var focusQuick = 0
    @Published var focusFilter = 0
    @Published var focusList = 0
    /// Shows what's typed in lower case too.
    @Published var lowercaseAll: Bool { didSet { defaults.set(lowercaseAll, forKey: "lowercaseAll") } }
    /// Autosort's guess for what's being typed into quick add.
    @Published var suggestWhileTyping: Bool { didSet { defaults.set(suggestWhileTyping, forKey: "suggest") } }
    @Published var collapsedGroups: Set<String> { didSet { defaults.set(Array(collapsedGroups), forKey: "collapsedGroups") } }
    @Published private var sorts: [String: String]
    @Published private var groupings: [String: String]
    /// Steps the on-device model is coming up with, for the task with this id.
    @Published var thinking: String?
    @Published var banner: String?
    /// Autosort's suggestions for the inbox, showing.
    @Published var showAutosort = false
    /// Something being put on Google Calendar.
    @Published var calendarForm: EventForm?
    /// The heading whose + was clicked: a line under it to add a task straight there.
    @Published var addingTo: String?

    private let defaults = UserDefaults.standard
    private var forwarding: [AnyCancellable] = []
    private var learned: (stamp: Int, classifier: Classifier)?

    init(store: Store, timers: TimerEngine, calendar: CalendarBridge) {
        self.store = store
        self.timers = timers
        self.calendar = calendar
        mail = MailBridge(store: store, calendar: calendar)
        // The window opens on all.
        place = .anytime
        showInspector = defaults.object(forKey: "inspector") as? Bool ?? true
        showSidebar = defaults.object(forKey: "sidebar") as? Bool ?? true
        showCalendar = defaults.bool(forKey: "calendarPanel")
        sidebarWidth = CGFloat(defaults.object(forKey: "width.sidebar") as? Double ?? 238)
        inspectorWidth = CGFloat(defaults.object(forKey: "width.details") as? Double ?? 322)
        calendarWidth = CGFloat(defaults.object(forKey: "width.calendar") as? Double ?? 300)
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
    func groupMode(_ place: Place) -> GroupMode { groupings[place.key].flatMap(GroupMode.init(rawValue:)) ?? Views.defaultGroup(place) }

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
        if let group, let list = group.listId, !chosen { draft.listId = list; draft.sectionId = group.sectionId }
        // Not filed anywhere: autosort's guess, if it's sure and that's wanted.
        if draft.listId == nil, draft.newListName == nil, suggestWhileTyping, let guess = suggestion(for: draft.title) { draft.listId = guess.list.id }
        var id = ""
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            id = store.add(draft)
            selection = [id]
            anchor = id
        }
        // "/timer" in it: a timer on it straight away.
        if let ask = q.timer, let task = snap.task(id) {
            timers.start(task: task, minutes: ask.minutes.map(Double.init), stopwatch: ask.stopwatch)
        }
        return id
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
        let current = anchor.flatMap { id in tasks.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), tasks.count - 1) } ?? (delta > 0 ? 0 : tasks.count - 1)
        let id = tasks[next].id
        if extend { selection.insert(id) } else { selection = [id] }
        anchor = id
        editing = nil
    }

    func selectAll() { selection = Set(visible.map(\.id)) }

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
            store.update(ids, put ? "to ideas" : "back from ideas") { _ in var p = TaskPatch(); p.someday = put; return p }
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
    func drop(_ items: [String], list: String, section: String?, before: String?) -> Bool {
        for item in items {
            if item.hasPrefix("toyl:") {
                let ids = item.dropFirst(5).split(separator: ",").map(String.init).filter { snap.task($0) != nil }
                guard !ids.isEmpty else { continue }
                store.place(ids, list: list, section: section, before: before)
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
    func newList(_ name: String = "new list", group: String? = nil) -> String {
        let id = UID.make()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.change("new list") { $0.addList(name: name, group: group, id: id) } }
        place = .list(id)
        renaming = "list:" + id
        return id
    }

    func renameList(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.change("rename list") { $0.updateList(id, name: name) }
    }

    func setColor(_ color: String, list id: String) { store.change("color") { $0.updateList(id, color: color) } }
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
    func newGroup(_ name: String = "new group") -> String {
        let id = UID.make()
        store.change("new group") { $0.addGroup(name: name, id: id) }
        renaming = "group:" + id
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

    /// Moves the panel a day (or a week) on or back.
    func stepDay(_ days: Int) {
        guard let day = Day.adding(days, to: shownDay) else { return }
        showDay(day)
    }

    func showDay(_ day: String) {
        calendarDay = day == Day.today() ? nil : day
        calendar.want(day)
    }

    /// Tasks dropped on the panel's hours: due that day at that time (and their events follow, if
    /// they're on the calendar). Text dropped there becomes a task at that time.
    func schedule(_ items: [String], day: String, time: String?, keepTime: Bool = false) {
        for item in items {
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
