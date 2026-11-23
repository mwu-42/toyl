import SwiftUI

/// The middle: the place's name, quick add, then its tasks under their headings.
struct MainPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            if model.place == .timers {
                TimersPage(model: model)
            } else {
                QuickAdd(model: model)
                if let trouble = model.store.trouble { Notice(text: trouble, tint: Theme.late) }
                if let note = model.calendar.note { Notice(text: note, tint: Theme.secondary) { model.calendar.note = nil } }
                if let banner = model.banner { Notice(text: banner, tint: Theme.secondary) { model.banner = nil } }
                if model.showAutosort { AutosortPanel(model: model) }
                TaskListView(model: model)
            }
            if model.timers.ringing != nil { RingingBar(model: model) }
            if !model.timers.timers.isEmpty, model.place != .timers { TimerBar(model: model) }
        }
        .background(Theme.paper)
    }
}

struct Notice: View {
    let text: String
    var tint = Theme.secondary
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.meta).foregroundStyle(tint)
            Spacer()
            if let close { Quiet(label: "", symbol: "xmark", size: 12, action: close) }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 8)
    }
}

// MARK: - header

struct Header: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title(model.place))
                    .font(Theme.title)
                    .lineLimit(1)
                Text(subtitle).font(Theme.meta).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if model.place != .timers {
                FilterField(model: model)
                ViewMenu(model: model)
            }
            Quiet(label: "", symbol: "sidebar.right", size: 15) { model.showInspector.toggle() }
                .help("show or hide details (⌥⌘I)")
        }
        .padding(.top, 30)
        .padding(.leading, model.showSidebar ? 30 : 86)
        .padding(.trailing, 22)
        .padding(.bottom, 14)
        .overlay(alignment: .topLeading) {
            if !model.showSidebar {
                Quiet(label: "", symbol: "sidebar.left", size: 15) { model.showSidebar = true }
                    .padding(.leading, 84).padding(.top, 8)
            }
        }
    }

    private var subtitle: String {
        let snap = model.snap
        let now = Date()
        switch model.place {
        case .today:
            let n = Views.tasks(for: .today, in: snap, now: now).count
            let events = model.calendar.events(on: Day.today(now)).filter { $0.end > now && !$0.allDay }.count
            var parts = [Format.longDay(Day.today(now), now: now)]
            parts.append(n == 0 ? "nothing to do" : "\(n) to do")
            if events > 0 { parts.append("\(events) still to come") }
            return parts.joined(separator: " · ")
        case .list(let id):
            guard let list = snap.list(id) else { return "" }
            let open = snap.tasks.filter { $0.listId == id && !$0.done }.count
            let group = list.group.flatMap { g in snap.groups.first { $0.id == g }?.name }
            return ["\(open) open", group.map { "in " + model.display($0) }, list.archived ? "archived" : nil].compactMap { $0 }.joined(separator: " · ")
        case .inbox: return "what's not filed yet"
        case .upcoming: return "what's dated, day by day"
        case .anytime: return "everything open"
        case .logbook: return "what's done"
        case .ideas: return "loose ideas, and what's put off"
        case .timers: return "focus on a task, or time anything"
        case .tag(let tag): return "everything tagged #" + tag
        case .filter(let id): return snap.filters.first { $0.id == id }?.query ?? ""
        case .search: return "everything"
        }
    }
}

/// Filters what's shown: words, #tags, due:week, is:done and the rest (see `Query`).
struct FilterField: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
            PlainField(text: $model.filter, placeholder: "filter", font: Theme.nsFont(14.5), focus: model.focusFilter,
                       onSubmit: {}, onEscape: { model.filter = ""; model.focusList += 1 })
                .frame(height: 18)
            if !model.filter.isEmpty {
                Quiet(label: "", symbol: "xmark.circle.fill", size: 12) { model.filter = "" }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
        .help("words, #tag, -#tag, in:list, due:today|week|overdue|none, before:dec 1, is:done|all|pinned|late, has:notes|time")
    }
}

/// How the place is sorted and grouped, and whether done tasks show.
struct ViewMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let place = model.place
        Menu {
            Picker("sort", selection: Binding(get: { model.sortMode(place) }, set: { model.setSort($0, for: place) })) {
                ForEach(SortMode.allCases) { Text($0.name).tag($0) }
            }
            Picker("group by", selection: Binding(get: { model.groupMode(place) }, set: { model.setGroup($0, for: place) })) {
                ForEach(GroupMode.allCases) { Text($0.name).tag($0) }
            }
            Toggle("show done", isOn: $model.showDone)
            Divider()
            if place == .inbox {
                Button("autosort the inbox…") { model.showAutosort = true }
            }
            if case .list(let id) = place {
                Button("add a section") { model.addSection(to: id) }
                Button("rename list") { model.renaming = "list:" + id }
            }
            if !model.filter.isEmpty { Button("save this filter as a list") { model.saveFilter() } }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.secondary)
        .fixedSize()
        .help("sort, group, show done")
    }
}

// MARK: - quick add

/// Type a task as you'd say it; what it's read as shows underneath as you go (and where autosort
/// would file it). Tab finishes a #name or ~list, or takes autosort's guess. Return adds it.
struct QuickAdd: View {
    @ObservedObject var model: AppModel
    @Local private var text = ""

    var body: some View {
        let parsed = text.isEmpty ? nil : Quick.parse(text, lists: model.snap.lists, weekStart: model.snap.weekStart)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
                PlainField(text: $text, placeholder: placeholder, focus: model.focusQuick,
                           onSubmit: submit, onEscape: { text = ""; model.focusList += 1 }, onTab: complete,
                           onDown: { model.focusList += 1; model.moveSelection(1); return true })
                    .frame(height: 21)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            if let parsed {
                let tokens = parsed.tokens(lists: model.snap.lists)
                let guess = suggestion(for: parsed)
                let finishing = completion()
                if !tokens.isEmpty || guess != nil || finishing != nil {
                    HStack(spacing: 6) {
                        ForEach(tokens, id: \.self) { token in Chip(text: token.text, tint: tint(token.kind), filled: true) }
                        if let guess { Chip(text: "→ \(model.display(guess.displayName))?  ⇥", tint: Theme.secondary) }
                        if let finishing { Chip(text: "⇥ " + finishing.shown, tint: Theme.secondary) }
                        Spacer()
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var placeholder: String {
        switch model.place {
        case .inbox: return "add a task   (essay fri 5pm #cs ~2h)"
        case .today: return "add for today"
        case .upcoming: return "add with a day"
        case .ideas: return "jot an idea"
        case .tag(let tag): return "add with #\(tag)"
        case .list(let id): return "add to " + (model.snap.list(id).map { model.display($0.displayName) } ?? "this list")
        default: return "add a task"
        }
    }

    private func tint(_ kind: Quick.Token.Kind) -> Color {
        switch kind {
        case .due: return Theme.ink
        case .list, .newList: return Theme.accent
        case .idea, .pinned, .timer: return Theme.accent
        default: return Theme.secondary
        }
    }

    private func submit() {
        guard model.quickAdd(text) != nil else { return }
        text = ""
    }

    /// Autosort's guess, when nothing's been said about a list and it's fairly sure.
    private func suggestion(for parsed: Quick) -> ListModel? {
        guard model.suggestWhileTyping, parsed.listId == nil, parsed.newList == nil, !parsed.idea else { return nil }
        switch model.place {
        case .inbox, .today, .upcoming, .anytime, .tag, .filter, .search: break
        default: return nil
        }
        return model.suggestion(for: parsed.title)?.list
    }

    /// The #name or ~list being typed at the end, and what it'd finish as.
    private func completion() -> (replace: Range<String.Index>, with: String, shown: String)? {
        guard let marker = text.lastIndex(where: { $0 == "#" || $0 == "~" }) else { return nil }
        let partial = String(text[text.index(after: marker)...])
        guard !partial.isEmpty, partial.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        if marker > text.startIndex, let before = text[..<marker].last, !before.isWhitespace { return nil }
        let key = TodQuick.words(partial).joined()
        let snap = model.snap
        let lists = snap.lists.filter { !$0.archived && !$0.handle.isEmpty }
        if let list = lists.first(where: { $0.handle.hasPrefix(key) && $0.handle != key }) ?? lists.first(where: { l in TodQuick.words(l.name).contains { $0.hasPrefix(key) } && l.handle != key }) {
            return (marker..<text.endIndex, String(text[marker]) + list.handle + " ", model.display(list.displayName))
        }
        if text[marker] == "#", let tag = snap.tags.first(where: { $0.name.lowercased().hasPrefix(partial.lowercased()) && $0.name.lowercased() != partial.lowercased() }) {
            return (marker..<text.endIndex, "#" + tag.name + " ", "#" + tag.name)
        }
        return nil
    }

    private func complete() -> Bool {
        if let finishing = completion() {
            text.replaceSubrange(finishing.replace, with: finishing.with)
            return true
        }
        if let parsed = text.isEmpty ? nil : Quick.parse(text, lists: model.snap.lists, weekStart: model.snap.weekStart),
           let guess = suggestion(for: parsed) {
            text = text.trimmingCharacters(in: .whitespaces) + " ~" + guess.handle + " "
            return true
        }
        return false
    }
}

// MARK: - the list

struct TaskListView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        let groups = model.groups
        let now = model.timers.now
        let today = Day.today(now)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.place == .today, model.calendar.showEvents {
                        EventsStrip(events: model.calendar.events(on: today), now: now)
                    }
                    ForEach(groups) { group in
                        if group.title != nil || group.day != nil && model.place == .upcoming {
                            GroupHeading(model: model, group: group)
                        }
                        if model.place == .upcoming, let day = group.day, model.calendar.showEvents {
                            EventsStrip(events: model.calendar.events(on: day), now: now, compact: true)
                        }
                        ForEach(group.tasks) { task in
                            TaskRow(model: model, task: task, group: group, now: now).id(task.id)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))))
                        }
                    }
                    if groups.allSatisfy({ $0.tasks.isEmpty }) { EmptyPlace(model: model) }
                    Color.clear.frame(height: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selection = []; model.editing = nil }
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handle(press) }
            .onChange(of: model.focusList) { focused = true }
            .onChange(of: model.anchor) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard model.editing == nil else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow: model.moveSelection(-1, extend: shift); return .handled
        case .downArrow: model.moveSelection(1, extend: shift); return .handled
        case .return:
            if let task = model.selectedTask { model.editing = task.id; return .handled }
            return .ignored
        case .space:
            if !model.selection.isEmpty { model.showInspector = true; return .handled }
            return .ignored
        case .delete, .deleteForward:
            if !model.selection.isEmpty { model.deleteSelected(); return .handled }
            return .ignored
        case .escape:
            model.selection = []
            return .handled
        default:
            return .ignored
        }
    }
}

/// A heading over a run of tasks (a section, a list, a day). Tasks dropped on it go to its end.
struct GroupHeading: View {
    @ObservedObject var model: AppModel
    let group: TaskGroup
    @Local private var targeted = false
    @Local private var renaming = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if renaming, let list = group.listId, let section = group.sectionId {
                RenameField(name: group.title ?? "") { name in model.store.change("rename section") { $0.renameSection(section, in: list, to: name) } } done: { renaming = false }
            } else {
                Text(group.title.map(model.display) ?? "")
                    .font(Theme.font(15, bold: true))
                    .foregroundStyle(group.isLate ? Theme.late : Theme.ink)
                if let subtitle = group.subtitle {
                    Text(subtitle).font(Theme.meta).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            if group.isLate, !group.tasks.isEmpty { LateMenu(model: model, ids: group.tasks.map(\.id)) }
            Text("\(group.tasks.count)").font(Theme.font(12.5)).foregroundStyle(Theme.faint).opacity(group.tasks.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(targeted ? Theme.accent : Theme.rule).frame(height: targeted ? 2 : 1).padding(.horizontal, 10) }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let list = group.listId else { return false }
            return model.drop(items, list: list, section: group.sectionId, before: nil)
        } isTargeted: { targeted = $0 }
        .contextMenu {
            if let list = group.listId, let section = group.sectionId, model.snap.list(list)?.sections.count ?? 0 > 1 {
                Button("rename section") { renaming = true }
                Button("delete section (its tasks move up)") { model.store.change("delete section") { $0.deleteSection(section, in: list) } }
            }
            if let list = group.listId, list != ListModel.inbox || true { Button("add a section") { model.addSection(to: list) } }
        }
    }
}

/// What to do with everything that's late at once: bring it to today or later, take the dates
/// off, or call it done.
struct LateMenu: View {
    @ObservedObject var model: AppModel
    let ids: [String]

    var body: some View {
        Menu {
            Button("all to today") { model.setDue(Day.today(), for: ids) }
            Button("all to tomorrow") { model.setDue(Day.adding(1, to: Day.today()), for: ids) }
            Button("all to next week") { model.setDue(TodQuick.read("next week", now: Date(), weekStart: model.snap.weekStart).due, for: ids) }
            Button("take the dates off") { model.setDue(nil, for: ids) }
            Divider()
            Button("check them all off") { model.store.toggle(ids) }
        } label: {
            Text("tidy up").font(Theme.font(13)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("move everything late at once (⌘z puts it back)")
    }
}

/// A day's events, as a quiet run of times and names, each in its calendar's color.
struct EventsStrip: View {
    let events: [CalEvent]
    let now: Date
    var compact = false

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                ForEach(events) { event in
                    let over = event.end < now && !event.allDay
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.color(hex: event.color)).frame(width: 3, height: 13)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text(Format.span(event.start, event.end, allDay: event.allDay))
                            .font(Theme.font(13.5))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(event.title.lowercased() == event.title ? event.title : event.title)
                            .font(Theme.font(compact ? 14.5 : 15))
                            .foregroundStyle(over ? Theme.faint : Theme.ink)
                            .lineLimit(1)
                        if event.taskId != nil {
                            Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, compact ? 4 : 2)
            .padding(.bottom, compact ? 6 : 14)
        }
    }
}

struct EmptyPlace: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.faint)
            Text(words).font(Theme.font(17)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .transition(.opacity)
    }

    private var words: String {
        if !model.filter.isEmpty { return "nothing matches “\(model.filter)”" }
        switch model.place {
        case .inbox: return "inbox empty"
        case .today: return "all clear"
        case .upcoming: return "nothing ahead"
        case .logbook: return "nothing done yet"
        case .ideas: return "no ideas yet"
        default: return "nothing here"
        }
    }

    private var symbol: String {
        if !model.filter.isEmpty { return "magnifyingglass" }
        switch model.place {
        case .inbox: return "tray"
        case .today: return "sun.max"
        case .ideas: return "lightbulb"
        default: return "circle.dashed"
        }
    }
}

/// Autosort for the inbox: where each task most likely belongs (learned from where your other
/// tasks are), to file in one go or one at a time.
struct AutosortPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let suggestions = model.autosortInbox()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                Text("autosort").font(Theme.font(15, bold: true))
                Text(suggestions.isEmpty ? "nothing to file yet" : "learned from your lists")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
                Spacer()
                Quiet(label: "close", action: { model.showAutosort = false })
            }
            ForEach(suggestions, id: \.task.id) { s in
                HStack(spacing: 8) {
                    Text(model.display(s.task.title)).lineLimit(1)
                    Text("→").foregroundStyle(Theme.faint)
                    if let list = s.list {
                        Circle().fill(Theme.color(hex: list.color)).frame(width: 7, height: 7)
                        Text(model.display(list.displayName)).foregroundStyle(Theme.secondary)
                        Text("\(Int(s.confidence * 100))%").font(Theme.meta).foregroundStyle(Theme.faint)
                    }
                    ForEach(s.tags, id: \.self) { Chip(text: "#" + $0) }
                    Spacer()
                    Quiet(label: "file") { model.applyAutosort([s]) }
                }
                .font(Theme.font(15))
            }
            HStack(spacing: 16) {
                if !suggestions.isEmpty { Quiet(label: "file all \(suggestions.count)", tint: Theme.ink) { model.applyAutosort(suggestions) } }
                if OnDevice.isAvailable { Quiet(label: "ask apple intelligence", symbol: "apple.intelligence") { model.autosortWithAppleIntelligence() } }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rule))
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }
}
