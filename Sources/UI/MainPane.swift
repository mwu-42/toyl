import SwiftUI

/// The middle: the place's name, quick add, then its tasks under their headings.
struct MainPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            // A timer that's just gone off: said at the top (nothing about timers sits at the bottom).
            if model.timers.ringing != nil { RingingBar(model: model).transition(.move(edge: .top).combined(with: .opacity)) }
            if model.place == .timers {
                TimersPage(model: model)
            } else {
                // Over what's under it: its slash menu hangs down over the list.
                QuickAdd(model: model).zIndex(1)
                if let trouble = model.store.trouble { Notice(text: trouble, tint: Theme.late) }
                if let note = model.calendar.note { Notice(text: note, tint: Theme.secondary) { model.calendar.note = nil } }
                if let said = model.mail.said { Notice(text: said, tint: Theme.secondary) { model.mail.said = nil } }
                if let said = model.canvas.said { Notice(text: said, tint: Theme.secondary) { model.canvas.said = nil } }
                if model.showAutosort { AutosortPanel(model: model) }
                TaskListView(model: model)
            }

        }
        .background(Theme.paper)
        .overlay(alignment: .topTrailing) {
            if let banner = model.banner {
                ActionNote(text: banner)
                    .padding(.top, 80)
                    .padding(.trailing, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onTapGesture { withAnimation(.easeOut(duration: 0.3)) { model.banner = nil } }
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.banner)
    }
}

/// The last thing done, in a few words, for a moment (top right, under the title).
struct ActionNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(13.5))
            .foregroundStyle(Theme.secondary)
            .lineLimit(2)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.field))
            .frame(maxWidth: 320, alignment: .trailing)
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

extension Header {
    /// The name the title shows, if it can be changed (a list of your own, a saved filter).
    var titleName: String? {
        switch model.place {
        case .list(let id): return model.snap.list(id).flatMap { $0.isSpecial ? nil : $0.name }
        case .filter(let id): return model.snap.filters.first { $0.id == id }?.name
        default: return nil
        }
    }

    func renameTitle(_ place: Place, to name: String) {
        switch place {
        case .list(let id): model.renameList(id, to: name)
        case .filter(let id): model.renameFilter(id, to: name)
        default: break
        }
    }
}

struct Header: View {
    @ObservedObject var model: AppModel
    @Local private var renaming = false
    /// The place whose name is being changed (kept, so leaving it saves to it, not the next).
    @Local private var renamingPlace: Place?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            // A list's or a filter's name: double-click to change it.
            Text(model.title(model.place))
                .font(Theme.title)
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    guard titleName != nil else { return }
                    renamingPlace = model.place
                    renaming = true
                }
                .changedInPlace(renaming && titleName != nil && renamingPlace != nil, room: 420) {
                    if let name = titleName, let place = renamingPlace {
                        RenameField(name: name, font: Theme.nsFont(30, bold: true)) { renameTitle(place, to: $0) } done: { renaming = false }
                    }
                }
            Spacer(minLength: 10)
            if model.place == .inbox || model.place == .anytime {
                // Autosort: a small wand that files everything in the inbox where it belongs.
                if model.sorting {
                    ProgressView().controlSize(.small).frame(width: 18)
                        .help("sorting the inbox…")
                } else {
                    Quiet(label: "", symbol: "wand.and.stars", size: 15) { model.autosortEverything() }
                        .help("autosort: file everything in the inbox where it belongs (⌥⌘A)")
                }
            }
            if model.place != .timers {
                FilterField(model: model)
                ViewMenu(model: model)
            }
            Quiet(label: "", symbol: "calendar", size: 15, tint: model.showCalendar ? Theme.ink : Theme.secondary) {
                model.setShown(.calendar, !model.showCalendar)
            }
            .help("calendar")
            Quiet(label: "", symbol: "sidebar.right", size: 15, tint: model.showInspector ? Theme.ink : Theme.secondary) {
                model.setShown(.details, !model.showInspector)
            }
            .help("description (⌥⌘I)")
        }
        // Another place: what was typed is kept (for the place it was typed for), and it's done.
        .onChange(of: model.place) { renaming = false }
        .padding(.top, 30)
        .padding(.leading, model.showSidebar || model.panelOrder.filter(model.isShown).first != .tasks ? 30 : 86)
        .padding(.trailing, 22)
        .padding(.bottom, 14)
    }
}

/// Filters what's shown: words, #tags, due:week, is:done and the rest (see `Query`).
struct FilterField: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
            // Return goes down to what's found; Escape clears it and lets go.
            PlainField(text: $model.filter, placeholder: "filter", font: Theme.nsFont(14.5), focus: model.focusFilter,
                       onSubmit: { model.leaveTyping(); model.enterList() },
                       onEscape: { model.filter = ""; model.leaveTyping() },
                       onDown: { model.leaveTyping(); model.enterList(); return true })
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
                ForEach(GroupMode.offered) { Text($0.name).tag($0) }
            }
            Toggle("show done", isOn: $model.showDone)
            Divider()
            if place == .inbox {
                Button("autosort everything") { model.autosortEverything() }
                Button("look over autosort's guesses…") { model.showAutosort = true }
            }
            if case .list(let id) = place {
                Button("new project") { model.newProject(in: id) }
                Button("rename list") { model.renaming = "list:" + id }
            }
            if place == .inbox { Button("new project") { model.newProject(in: ListModel.inbox) } }
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
/// would file it). Tab finishes a #name or ~list, or takes autosort's guess. Return adds it and
/// stays for the next; Return with nothing typed, Escape (once to clear, again to leave) or ↓
/// go back to the list. Return anywhere in the window, or just typing, comes back here.
struct QuickAdd: View {
    @ObservedObject var model: AppModel
    @Local private var text = ""
    @Local private var slash = SlashPick()

    var body: some View {
        let command = Quick.command(text, lists: model.snap.lists, weekStart: model.snap.weekStart)
        let menu = slash.menu(text)
        let parsed = text.isEmpty || command != nil || menu != nil ? nil : Quick.parse(text, lists: model.snap.lists, weekStart: model.snap.weekStart)
        let tokens = parsed?.tokens(lists: model.snap.lists) ?? []
        let guess = parsed.flatMap(suggestion(for:))
        let finishing = parsed == nil ? nil : completion()
        let chips = command != nil || !tokens.isEmpty || guess != nil || finishing != nil
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
                PlainField(text: $text, placeholder: placeholder, name: "quick", focus: model.focusQuick,
                           onSubmit: submit,
                           onEscape: {
                               if slash.close(text) { return }
                               if text.isEmpty { model.leaveTyping() } else { text = "" }
                           },
                           onTab: { _ = complete(); return true },
                           onUp: { slash.move(-1, in: text) },
                           onDown: {
                               if slash.move(1, in: text) { return true }
                               model.leaveTyping()
                               model.enterList()
                               return true
                           },
                           marks: parsed.map { Quick.marks(in: text, read: $0) } ?? [])
                    .frame(height: 21)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            // "/": the words it could be, in a menu over what's under it.
            .overlay(alignment: .topLeading) {
                if let menu {
                    Floating(size: SlashMenu.size(menu.words.count)) {
                        SlashMenu(words: menu.words, picked: slash.picked(in: menu.words.count), pick: { slash.index = $0 }) { choice in
                            _ = slash.take(choice, in: &text)
                            model.focusQuick += 1
                        }
                    }
                    // Just under the field's box (21 tall, 9 above and below).
                    .offset(x: 26, y: 21 + 18 + 6)
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.14), value: menu == nil)
            .onChange(of: text) { _, now in slash.typed(now) }
            .onAppear { slash.weekStart = model.snap.weekStart }
            if chips {
                HStack(spacing: 6) {
                    // A slash word: what Return makes instead of a task.
                    if let command { Chip(text: "↩ " + model.describe(command), tint: Theme.accent, filled: true) }
                    ForEach(tokens, id: \.self) { token in Chip(text: token.text, tint: tint(token.kind), filled: true) }
                    if let guess { Chip(text: "→ \(model.display(guess.displayName))?  ⇥", tint: Theme.secondary) }
                    if let finishing { Chip(text: "⇥ " + finishing.shown, tint: Theme.secondary) }
                    Spacer()
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        // What it's read as slides in and out under it, rather than jolting the list.
        .animation(.snappy(duration: 0.18), value: chips)
    }

    private var placeholder: String {
        switch model.place {
        case .ideas: return "new idea"
        default: return "new task"
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
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return model.leaveTyping() }
        // The menu's open ("/pro" half typed): the picked word first.
        if slash.take(in: &text) { return }
        // "/list groceries", "/project essay #cs"…: that, not a task.
        if let command = Quick.command(text, lists: model.snap.lists, weekStart: model.snap.weekStart) {
            text = ""
            model.perform(command)
            return
        }
        let typed = text
        text = ""
        if model.quickAdd(typed) == nil { text = typed }
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
        if slash.take(in: &text) { return true }
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

/// The tasks under their headings. Its keys (Return, the arrows, space, delete) are the window's,
/// whenever nothing's being typed: see `AppModel.watchKeys`.
struct TaskListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let groups = model.groups
        let now = model.clock
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
                        if model.addingTo == group.id {
                            AddUnder(model: model, group: group)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                // Its slash menu hangs over the rows under it.
                                .zIndex(1)
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
                    if groups.allSatisfy({ $0.tasks.isEmpty }), !groups.contains(where: \.big) { EmptyPlace(model: model) }
                    if let list = listShown {
                        Quiet(label: "new project", symbol: "folder.badge.plus", size: 13.5) { model.newProject(in: list) }
                            .padding(.horizontal, 12)
                            .padding(.top, 24)
                    }
                    Color.clear.frame(height: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selection = []; model.editing = nil; model.leaveTyping() }
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.anchor) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
    }

    /// The list being looked at (for its "new project"), when it's one list grouped by project.
    private var listShown: String? {
        guard model.groupMode(model.place) == .project, model.filter.isEmpty else { return nil }
        switch model.place {
        case .list(let id): return id
        case .inbox: return ListModel.inbox
        default: return nil
        }
    }
}

/// A heading over a run of tasks (a list, a project, a day). Tasks dropped on it go to its end.
/// A list's or a project's heading drags to reorder them, and a double-click renames it.
struct GroupHeading: View {
    @ObservedObject var model: AppModel
    let group: TaskGroup
    @Local private var targeted = false
    @Local private var renaming = false
    @Local private var hovering = false

    /// The list it heads, when it's a list's heading (in all, grouped by list).
    private var headsList: String? { group.id.hasPrefix("list:") ? group.listId : nil }

    /// A click on the line adds a task under it (a list's, a project's, a section's).
    private var adds: Bool { group.listId != nil }

    /// Its name can be changed: a project's, or a list's that isn't one of toyl's own.
    private var renamable: Bool { group.big || headsList.flatMap({ model.snap.list($0) })?.isSpecial == false }

    private var renamingNow: Bool {
        if let project = group.projectId, group.listId != nil { return renaming || model.renaming == "project:" + project }
        return headsList != nil && renaming
    }

    var body: some View {
        let renamingNow = renamingNow
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if group.big { Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Theme.accent) }
            Text(group.title.map(model.display) ?? "")
                .font(Theme.font(group.big ? 21 : 15, bold: true))
                .foregroundStyle(Theme.ink)
                // A double-click on the name changes it; a single one adds, as anywhere on the line.
                .gesture(TapGesture(count: 2).onEnded { renaming = true }.exclusively(before: TapGesture().onEnded { add() }),
                         isEnabled: renamable && !renamingNow)
                .changedInPlace(renamingNow) { renameField }
            if let subtitle = group.subtitle {
                Text(subtitle).font(Theme.meta).foregroundStyle(Theme.secondary).opacity(renamingNow ? 0 : 1)
            }
            // What a click on the line does.
            if adds, hovering, !renamingNow, model.addingTo != group.id {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    .transition(.opacity)
            }
            Spacer()
            if group.isLate, !group.tasks.isEmpty { LateMenu(model: model, ids: group.tasks.map(\.id)) }
            Text("\(group.tasks.count)").font(Theme.font(12.5)).foregroundStyle(Theme.faint).opacity(group.tasks.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, group.big ? 30 : 20)
        .padding(.bottom, group.big ? 8 : 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(targeted ? Theme.accent : hovering && adds ? Theme.faint.opacity(0.6) : Theme.rule)
                .frame(height: targeted ? 2 : 1).padding(.horizontal, 10)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture { if !renamingNow { add() } }
        .help(adds ? "click to add a task here" : "")
        .modifier(HeadingDrag(model: model, payload: payload, title: group.title.map(model.display) ?? ""))
        .columnDrop(model, lit: $targeted, inset: 10, accepts: accepts, reorders: { payload != nil && Drag.kind($0) == Drag.kind(payload) }) { items, spot in
            if spot == .into {
                guard let list = group.listId else { return false }
                return model.drop(items, list: list, section: group.sectionId, before: nil, project: group.big ? .some(group.projectId) : nil)
            }
            return reorder(items, spot)
        }
        .contextMenu {
            if adds { Button("new task here") { withAnimation(.snappy(duration: 0.2)) { model.addingTo = group.id } } }
            if let project = group.projectId, let list = group.listId {
                Button("rename project") { renaming = true }
                Button("delete project (its tasks stay in the list)") { model.deleteProject(project, in: list) }
            } else if let list = headsList, model.snap.list(list)?.isSpecial == false {
                Button("rename list") { renaming = true }
            }
        }
    }

    /// The line under it to type a new task into (or, open already, put away).
    private func add() {
        guard adds else { return }
        withAnimation(.snappy(duration: 0.2)) { model.addingTo = model.addingTo == group.id ? nil : group.id }
    }

    @ViewBuilder private var renameField: some View {
        if let project = group.projectId, let list = group.listId {
            RenameField(name: group.title ?? "", font: Theme.nsFont(21, bold: true)) { name in model.renameProject(project, in: list, to: name) } done: {
                renaming = false
                if model.renaming == "project:" + project { model.renaming = nil }
            }
        } else if let list = headsList, let name = model.snap.list(list)?.name {
            RenameField(name: name, font: Theme.nsFont(15, bold: true)) { model.renameList(list, to: $0) } done: { renaming = false }
        }
    }

    /// What it's dragged as: a project's heading, or a list's (in all).
    private var payload: String? {
        if group.big, let project = group.projectId, let list = group.listId { return "toyl-project:\(list)|\(project)" }
        if let list = headsList { return "toyl-list:" + list }
        return nil
    }

    private func accepts(_ dragging: String) -> Bool {
        let kind = Drag.kind(dragging)
        if let payload, kind == Drag.kind(payload) {
            // A project only among its own list's.
            if kind == "project" { return Drag.pair(dragging)?.0 == group.listId }
            return true
        }
        return group.listId != nil && (kind == "tasks" || kind == "text")
    }

    /// A list's or a project's heading dropped above or below this one.
    private func reorder(_ items: [String], _ spot: RowSpot) -> Bool {
        guard let item = items.first else { return false }
        let snap = model.snap
        if Drag.kind(item) == "project", let (list, moving) = Drag.pair(item), let here = group.projectId, list == group.listId {
            let projects = snap.list(list)?.projects.map(\.id) ?? []
            let next = projects.firstIndex(of: here).flatMap { $0 + 1 < projects.count ? projects[$0 + 1] : nil }
            model.moveProject(moving, in: list, before: spot == .above ? here : next)
            return true
        }
        if Drag.kind(item) == "list", let here = headsList {
            // In the order all shows them (the sidebar's), into the group the heading's list is in.
            let shown = model.groups.compactMap { $0.id.hasPrefix("list:") ? $0.listId : nil }
            let next = shown.firstIndex(of: here).flatMap { $0 + 1 < shown.count ? shown[$0 + 1] : nil }
            let groupIds = Set(snap.groups.map(\.id))
            let group = snap.list(here)?.group.flatMap { groupIds.contains($0) ? $0 : nil }
            model.moveList(Drag.value(item), before: spot == .above ? here : next, group: .some(group))
            return true
        }
        return false
    }
}

/// A heading that can be dragged (a list's, a project's); others can't.
struct HeadingDrag: ViewModifier {
    let model: AppModel
    let payload: String?
    let title: String

    func body(content: Content) -> some View {
        if let payload {
            content.toylDrag(model, payload) { SidebarDragPreview(text: title) }
        } else {
            content
        }
    }
}

/// A line under a heading, from its +: what's typed goes straight into that list (or section),
/// read as quick add reads it. Return adds and stays for another; Return with nothing typed,
/// Escape, or clicking away with nothing typed, closes it.
struct AddUnder: View {
    @ObservedObject var model: AppModel
    let group: TaskGroup
    @Local private var text = ""
    @Local private var slash = SlashPick()
    @Local private var focus = 0

    var body: some View {
        let menu = slash.menu(text)
        HStack(spacing: 11) {
            Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.faint).frame(width: 17)
            PlainField(text: $text, placeholder: "new task", name: "under", autofocus: true, focus: focus, onSubmit: add,
                       onEscape: { if !slash.close(text) { close(leave: true) } },
                       onTab: { _ = slash.take(in: &text); return true },
                       onUp: { slash.move(-1, in: text) },
                       onDown: { slash.move(1, in: text) },
                       onEnd: { if text.trimmingCharacters(in: .whitespaces).isEmpty { close(leave: false) } },
                       marks: marks)
                .frame(height: 20)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        // "/": the words it could be, in a menu over the rows under it.
        .overlay(alignment: .topLeading) {
            if let menu {
                Floating(size: SlashMenu.size(menu.words.count)) {
                    SlashMenu(words: menu.words, picked: slash.picked(in: menu.words.count), pick: { slash.index = $0 }) { choice in
                        _ = slash.take(choice, in: &text)
                        focus += 1
                    }
                }
                // Just under the line (20 tall, 7 above and below).
                .offset(x: 34, y: 20 + 14 + 2)
            }
        }
        .onChange(of: text) { _, now in slash.typed(now) }
        .onAppear { slash.weekStart = model.snap.weekStart }
    }

    /// What quick add has read in what's typed, shaded.
    private var marks: [NSRange] {
        guard !text.isEmpty, !text.hasPrefix("/") else { return [] }
        return Quick.marks(in: text, read: Quick.parse(text, lists: model.snap.lists, weekStart: model.snap.weekStart))
    }

    private func add() {
        if slash.take(in: &text) { return }
        let typed = text
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return close(leave: true) }
        text = ""
        // "/project essay" under a list's heading: a project in that list.
        if let command = Quick.command(typed, lists: model.snap.lists, weekStart: model.snap.weekStart) {
            model.perform(command, under: group)
            close(leave: true)
            return
        }
        if model.quickAdd(typed, section: group) == nil { text = typed }
    }

    /// Closed by a key, it lets go of the keys too; closed by a click elsewhere, the keys are
    /// already where the click put them.
    private func close(leave: Bool) {
        if leave { model.leaveTyping() }
        withAnimation(.snappy(duration: 0.2)) { if model.addingTo == group.id { model.addingTo = nil } }
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
        .help("move everything late at once")
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
        case .inProgress: return "nothing in progress · swipe a task right"
        default: return "nothing here"
        }
    }

    private var symbol: String {
        if !model.filter.isEmpty { return "magnifyingglass" }
        switch model.place {
        case .inbox: return "tray"
        case .today: return "sun.max"
        case .ideas: return "lightbulb"
        case .inProgress: return "circle.lefthalf.filled"
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
