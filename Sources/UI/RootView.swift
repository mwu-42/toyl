import SwiftUI

/// The window: the sidebar, then the calendar, the to-dos and the selected task's details, side
/// by side on paper, in whatever order they've been dragged into (calendar first, at first).
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let shown = model.panelOrder.filter(model.isShown)
        HStack(spacing: 0) {
            if model.showSidebar {
                SidebarView(model: model)
                    .frame(width: model.sidebarWidth)
                    .background(Theme.sidebar)
                PanelDivider(width: $model.sidebarWidth, range: 180...380, grows: .right, standard: 238)
            }
            ForEach(Array(shown.enumerated()), id: \.element) { index, panel in
                if index > 0 { divider(between: shown[index - 1], and: panel, tasksRight: (model.fillingPanel.flatMap { shown.firstIndex(of: $0) } ?? 0) >= index) }
                view(of: panel)
                    .overlay(alignment: .top) { PanelGrip(model: model, panel: panel) }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if !model.showSidebar {
                Quiet(label: "", symbol: "sidebar.left", size: 15) { model.showSidebar = true }
                    .padding(.leading, 84).padding(.top, 8)
                    .help("show the sidebar")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .ignoresSafeArea()
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .sheet(item: $model.calendarForm) { form in AddToCalendarView(model: model, form: form) }
    }
}

extension RootView {
    @ViewBuilder func view(of panel: Panel) -> some View {
        let fills = model.fillingPanel == panel
        switch panel {
        case .tasks:
            MainPane(model: model)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        case .details:
            if fills {
                InspectorView(model: model)
                    .frame(minWidth: model.inspectorWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper)
            } else {
                InspectorView(model: model)
                    .frame(width: model.inspectorWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.paper)
            }
        case .calendar:
            if fills {
                // The page is hidden: the calendar takes the room.
                GeometryReader { space in CalendarPanel(model: model, width: space.size.width) }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper)
            } else {
                CalendarPanel(model: model, width: model.calendarWidth)
                    .frame(width: model.calendarWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.paper)
            }
        }
    }

    /// The line between two panels resizes the one on the far side of it from the panel taking
    /// the spare width (the page, usually): so the calendar's edge always resizes the calendar.
    @ViewBuilder func divider(between left: Panel, and right: Panel, tasksRight: Bool) -> some View {
        let sized = tasksRight ? left : right
        let grows: PanelDivider.Side = tasksRight ? .right : .left
        switch sized {
        case .details:
            PanelDivider(width: $model.inspectorWidth, range: 260...520, grows: grows, standard: 322)
        case .calendar:
            PanelDivider(width: Binding(get: { model.calendarWidth }, set: { model.calendarWidth = $0 }), range: 240...1000, grows: grows,
                         standard: model.calendarMode.standardWidth)
        case .tasks:
            Rectangle().fill(Theme.rule).frame(width: 1)
        }
    }
}

/// A panel's grip, at its top: drag it onto another panel's to swap places; right-click to move
/// it left or right.
struct PanelGrip: View {
    @ObservedObject var model: AppModel
    let panel: Panel
    @Local private var hovering = false
    @Local private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(targeted ? Theme.accent : hovering ? Theme.secondary : Theme.faint.opacity(0.55))
                .frame(width: 44, height: 18)
                .background(Capsule().fill(targeted ? Theme.selection : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .toylDrag(model, "toyl-panel:" + panel.rawValue) {
                    Text(panel.name).font(Theme.font(14)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.field))
                }
                .contextMenu {
                    Button("move \(panel.name) left") { model.nudgePanel(panel, -1) }
                    Button("move \(panel.name) right") { model.nudgePanel(panel, 1) }
                    Button("hide \(panel.name)") { model.setShown(panel, false) }
                    let hidden = Panel.allCases.filter { !model.isShown($0) && !($0 == .details && model.place == .timers) }
                    if !hidden.isEmpty {
                        Divider()
                        ForEach(hidden, id: \.self) { other in Button("show \(other.name)") { model.setShown(other, true) } }
                    }
                    Divider()
                    Button("page, description, calendar") { withAnimation(.snappy(duration: 0.25)) { model.panelOrder = Panel.standard } }
                }
                .help("drag to move \(panel.name)")
        }
        .frame(height: 22)
        .padding(.top, 4)
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first(where: { $0.hasPrefix("toyl-panel:") }), let moved = Panel(rawValue: String(item.dropFirst(11))) else { return false }
            model.movePanel(moved, to: panel)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// The line between two panels: drag it to make the panel wider or narrower; double-click it
/// for the usual width.
struct PanelDivider: View {
    enum Side { case left, right }
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// Which way dragging makes the panel wider: right for one on the left of the line.
    let grows: Side
    let standard: CGFloat
    @Local private var from: CGFloat?
    @Local private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || from != nil ? Theme.selectionFocused : Theme.rule)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = from ?? width
                                if from == nil { from = width }
                                let moved = grows == .right ? drag.translation.width : -drag.translation.width
                                width = min(max(start + moved, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in from = nil }
                    )
                    .onTapGesture(count: 2) { withAnimation(.snappy(duration: 0.2)) { width = standard } }
            }
            .zIndex(1)
    }
}

// MARK: - sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let snap = model.snap
        VStack(spacing: 0) {
            Color.clear.frame(height: 46)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // The fixed places, in the order they've been dragged into: four, a gap, two.
                    ForEach(model.placeOrder.prefix(4), id: \.self) { place in SidebarRow(model: model, place: place) }
                    Spacer().frame(height: 10)
                    ForEach(model.placeOrder.dropFirst(4), id: \.self) { place in SidebarRow(model: model, place: place) }
                    if !snap.filters.isEmpty {
                        SidebarLabel(text: "filters")
                        ForEach(snap.filters) { filter in SidebarRow(model: model, place: .filter(filter.id)) }
                    }
                    ForEach(snap.groups) { group in
                        GroupHeader(model: model, group: group)
                        if !model.collapsedGroups.contains(group.id) {
                            ForEach(snap.ownLists.filter { $0.group == group.id && !$0.archived }) { list in
                                SidebarRow(model: model, place: .list(list.id), indent: 8)
                            }
                        }
                    }
                    let groupIds = Set(snap.groups.map(\.id))
                    let loose = snap.ownLists.filter { ($0.group.map { !groupIds.contains($0) } ?? true) && !$0.archived }
                    if !loose.isEmpty {
                        LooseListsLabel(model: model)
                        ForEach(loose) { list in SidebarRow(model: model, place: .list(list.id)) }
                    }
                    let archived = snap.ownLists.filter(\.archived)
                    if !archived.isEmpty {
                        SidebarLabel(text: "archived")
                        ForEach(archived) { list in SidebarRow(model: model, place: .list(list.id)) }
                    }
                    if !snap.tags.isEmpty {
                        SidebarLabel(text: "tags")
                        ForEach(snap.tags.prefix(40), id: \.name) { tag in SidebarRow(model: model, place: .tag(tag.name), count: tag.count) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            Hairline()
            HStack(spacing: 14) {
                Quiet(label: "new list", symbol: "plus") { model.newList() }
                Spacer()
                Menu {
                    Button("new list") { model.newList() }
                    Button("new group") { model.newGroup() }
                    Button("save the filter as a list") { model.saveFilter() }.disabled(model.filter.isEmpty)
                    Divider()
                    Button("settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }
}

/// "lists", over the lists in no group: a list dropped on it comes out of its group.
struct LooseListsLabel: View {
    @ObservedObject var model: AppModel
    @Local private var lit = false

    var body: some View {
        HStack {
            Text("lists").font(Theme.font(12.5)).foregroundStyle(lit ? Theme.accent : Theme.faint)
            Spacer()
        }
        .padding(.leading, 10)
        .padding(.top, 16)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .columnDrop(model, lit: $lit, accepts: { Drag.kind($0) == "list" }, reorders: { _ in false }) { items, _ in
            guard let item = items.first(where: { Drag.kind($0) == "list" }) else { return false }
            model.moveList(Drag.value(item), before: nil, group: .some(nil))
            return true
        }
    }
}

struct SidebarLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(12.5))
            .foregroundStyle(Theme.faint)
            .padding(.leading, 10)
            .padding(.top, 16)
            .padding(.bottom, 3)
    }
}

/// A group's heading: click to fold its lists away; double-click to rename it; right-click to
/// rename or take it away. Drag it to reorder the groups; drop a list on it to put the list in it.
struct GroupHeader: View {
    @ObservedObject var model: AppModel
    let group: GroupModel
    @Local private var hovering = false
    @Local private var lit = false

    var body: some View {
        let folded = model.collapsedGroups.contains(group.id)
        HStack(spacing: 5) {
            if model.renaming == "group:" + group.id {
                RenameField(name: group.name) { model.renameGroup(group.id, to: $0) } done: { model.renaming = nil }
            } else {
                Text(model.display(group.name))
                    .font(Theme.font(12.5))
                    .foregroundStyle(lit ? Theme.accent : Theme.faint)
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .opacity(hovering || folded ? 1 : 0)
            }
            Spacer()
        }
        .padding(.leading, 10)
        .padding(.top, 16)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { model.renaming = "group:" + group.id }
            .exclusively(before: TapGesture().onEnded {
                if folded { model.collapsedGroups.remove(group.id) } else { model.collapsedGroups.insert(group.id) }
            }))
        .toylDrag(model, "toyl-group:" + group.id) { SidebarDragPreview(text: model.display(group.name)) }
        .columnDrop(model, lit: $lit, inset: 10, accepts: { ["group", "list"].contains(Drag.kind($0)) },
                    reorders: { Drag.kind($0) == "group" }) { items, spot in
            guard let item = items.first else { return false }
            if Drag.kind(item) == "list" {
                model.moveList(Drag.value(item), before: nil, group: .some(group.id))
                model.collapsedGroups.remove(group.id)
                return true
            }
            let groups = model.snap.groups.map(\.id)
            let next = groups.firstIndex(of: group.id).flatMap { $0 + 1 < groups.count ? groups[$0 + 1] : nil }
            model.moveGroup(Drag.value(item), before: spot == .above ? group.id : next)
            return true
        }
        .contextMenu {
            Button("new list here") { model.newList(group: group.id) }
            Button("rename") { model.renaming = "group:" + group.id }
            Divider()
            Button("delete group (its lists stay)") { model.deleteGroup(group.id) }
        }
    }
}

/// One place in the sidebar: a smart list, a list, a tag or a saved filter. Tasks dropped on it
/// go there (on today: due today; on logbook: done). Lists, filters and the fixed places drag to
/// reorder; a double-click on a list, a filter or a tag renames it.
struct SidebarRow: View {
    @ObservedObject var model: AppModel
    let place: Place
    var indent: CGFloat = 0
    var count: Int?
    @Local private var hovering = false
    @Local private var targeted = false

    var body: some View {
        let selected = model.place == place
        let shown = count ?? model.count(place)
        HStack(spacing: 9) {
            icon.frame(width: 18)
            if case .list(let id) = place, model.renaming == "list:" + id {
                RenameField(name: model.snap.list(id)?.name ?? "") { model.renameList(id, to: $0) } done: { model.renaming = nil }
            } else if case .filter(let id) = place, model.renaming == "filter:" + id {
                RenameField(name: model.snap.filters.first { $0.id == id }?.name ?? "") { model.renameFilter(id, to: $0) } done: { model.renaming = nil }
            } else if case .tag(let tag) = place, model.renaming == "tag:" + tag {
                RenameField(name: tag) { model.renameTag(tag, to: $0) } done: { model.renaming = nil }
            } else {
                Text(name)
                    .font(Theme.sidebarItem)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if place == .timers, let first = model.timers.timers.first {
                TimelineView(.periodic(from: .now, by: first.isRunning ? 1 : 60)) { context in
                    Ring(fraction: first.kind == .countdown ? first.fractionLeft(at: context.date) : 1, size: 12, line: 1.6)
                }
            } else if shown > 0 {
                Text("\(shown)").font(Theme.font(13.5)).foregroundStyle(Theme.faint)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: shown)
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(targeted ? Theme.selectionFocused : selected ? Theme.selection : hovering ? Theme.hover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let again = DoubleClick.second("sidebar:" + place.key) && model.place == place
            model.place = place
            if again, let key = renameKey { model.renaming = key }
        }
        .modifier(SidebarDrag(model: model, payload: payload, name: name))
        .columnDrop(model, lit: $targeted, inset: 10, accepts: accepts, reorders: { payload != nil && Drag.kind($0) == Drag.kind(payload) }) { items, spot in
            if spot == .into { return drop(items) }
            return reorder(items, spot)
        }
        .contextMenu { menu }
    }

    /// What a double-click renames (lists, filters, tags; not the fixed places or the inbox).
    private var renameKey: String? {
        switch place {
        case .list(let id): return model.snap.list(id)?.isSpecial == false ? "list:" + id : nil
        case .filter(let id): return "filter:" + id
        case .tag(let tag): return "tag:" + tag
        default: return nil
        }
    }

    /// What it's dragged as, if it can be (tags are in their own order).
    private var payload: String? {
        switch place {
        case .list(let id): return "toyl-list:" + id
        case .filter(let id): return "toyl-filter:" + id
        default: return AppModel.places.contains(place) ? "toyl-place:" + place.key : nil
        }
    }

    /// What it takes: its own kind (to reorder), and tasks or text where they can go.
    private func accepts(_ dragging: String) -> Bool {
        let kind = Drag.kind(dragging)
        if let payload, kind == Drag.kind(payload) { return true }
        guard kind == "tasks" || kind == "text" else { return false }
        switch place {
        case .list, .inbox, .ideas: return true
        case .today, .inProgress, .tag: return kind == "tasks"
        default: return false
        }
    }

    /// One of its own kind dropped above or below it.
    private func reorder(_ items: [String], _ spot: RowSpot) -> Bool {
        guard let item = items.first else { return false }
        let snap = model.snap
        switch place {
        case .list(let id):
            guard Drag.kind(item) == "list", let list = snap.list(id) else { return false }
            // Its group as the sidebar shows it (one that's gone counts as none); archived ones are together.
            let groupIds = Set(snap.groups.map(\.id))
            func shownGroup(_ l: ListModel) -> String? { l.group.flatMap { groupIds.contains($0) ? $0 : nil } }
            let siblings = snap.ownLists.filter { list.archived ? $0.archived : !$0.archived && shownGroup($0) == shownGroup(list) }.map(\.id)
            let next = siblings.firstIndex(of: id).flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil }
            model.moveList(Drag.value(item), before: spot == .above ? id : next, group: list.archived ? nil : .some(shownGroup(list)))
        case .filter(let id):
            guard Drag.kind(item) == "filter" else { return false }
            let filters = snap.filters.map(\.id)
            let next = filters.firstIndex(of: id).flatMap { $0 + 1 < filters.count ? filters[$0 + 1] : nil }
            model.moveFilter(Drag.value(item), before: spot == .above ? id : next)
        default:
            guard Drag.kind(item) == "place", let moving = Place(key: Drag.value(item)) else { return false }
            let order = model.placeOrder
            let next = order.firstIndex(of: place).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
            model.movePlace(moving, before: spot == .above ? place : next)
        }
        return true
    }

    @ViewBuilder private var icon: some View {
        switch place {
        case .list(let id):
            let list = model.snap.list(id)
            ListMark(list: list).opacity(list?.archived == true ? 0.45 : 1)
        case .tag:
            Text("#").font(Theme.font(15)).foregroundStyle(Theme.faint)
        default:
            Image(systemName: model.icon(place))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(place == .today ? Theme.accent : Theme.secondary)
        }
    }

    @ViewBuilder private var menu: some View {
        switch place {
        case .list(let id):
            if let list = model.snap.list(id) {
                Button("rename") { model.renaming = "list:" + id }
                Button("new project") { model.newProject(in: id) }
                Menu("color") {
                    ForEach(ListModel.palette, id: \.self) { color in
                        Button(color == list.color ? "● " + colorName(color) : colorName(color)) { model.setColor(color, list: id) }
                    }
                }
                Menu("group") {
                    Button("none") { model.setGroup(nil, list: id) }
                    ForEach(model.snap.groups) { group in Button(group.name) { model.setGroup(group.id, list: id) } }
                    Divider()
                    Button("new group…") {
                        let group = model.newGroup()
                        model.setGroup(group, list: id)
                    }
                }
                Button(list.archived ? "unarchive" : "archive") { model.archive(id, !list.archived) }
                Divider()
                Button("delete list (its tasks go to the inbox)") { model.deleteList(id) }
            }
        case .filter(let id):
            Button("rename") { model.renaming = "filter:" + id }
            Button("delete filter") { model.deleteFilter(id) }
        case .inbox:
            Button("autosort everything") { model.place = .inbox; model.autosortEverything() }
            Button("look over autosort's guesses…") { model.place = .inbox; model.showAutosort = true }
        default:
            EmptyView()
        }
    }

    /// What the row says: a list without the emoji its icon shows, a tag without the "#" its
    /// icon shows.
    private var name: String {
        switch place {
        case .list(let id): return model.snap.list(id).map { model.display($0.bareName) } ?? ""
        case .tag(let tag): return model.display(tag)
        default: return model.title(place)
        }
    }

    private func colorName(_ hex: String) -> String {
        ["#3b5bdb": "blue", "#2f9bd6": "sky", "#14958a": "teal", "#4c9a6a": "green", "#7a9a2e": "olive", "#d19a1c": "mustard",
         "#e8772e": "orange", "#c8553d": "brick", "#d6457a": "pink", "#9b4dca": "violet", "#6c5ce7": "indigo", "#5a5a5a": "graphite"][hex] ?? hex
    }

    private func drop(_ items: [String]) -> Bool {
        let ids = items.filter { $0.hasPrefix("toyl:") }.flatMap { $0.dropFirst(5).split(separator: ",").map(String.init) }
        let snap = model.snap
        switch place {
        case .list(let id): return model.drop(items, list: id, section: nil, before: nil)
        case .inbox: return model.drop(items, list: ListModel.inbox, section: nil, before: nil)
        case .ideas:
            // A task dropped here is put off (it keeps its list); text becomes ideas.
            let text = items.filter { !$0.hasPrefix("toyl:") }
            if !text.isEmpty { _ = model.drop(text, list: ListModel.dump, section: ListModel.dumpUnsorted, before: nil) }
            let putOff = ids.filter { snap.task($0).map { !$0.isIdea && !$0.someday } ?? false }
            if !putOff.isEmpty { model.toggleSomeday(putOff) }
            return !text.isEmpty || !putOff.isEmpty
        case .today: model.setDue(Day.today(), for: ids)
        case .inProgress:
            for id in ids where snap.task(id).map({ !model.isInProgress($0) }) ?? false { model.toggleInProgress(id) }
        case .tag(let tag): model.store.update(ids, "tag") { _ in var p = TaskPatch(); p.addTags = [tag]; return p }
        default: return false
        }
        return !ids.isEmpty
    }
}

/// A list's mark: its emoji, its symbol in its color, or (with neither) a dot in its color.
struct ListMark: View {
    let list: ListModel?
    var size: CGFloat = 13

    var body: some View {
        let color = Theme.color(hex: list?.color ?? "#8c8c8c")
        if let mark = list?.mark, list?.isSpecial == false {
            Text(mark.text)
                .font(mark.isEmoji ? .system(size: size) : Theme.font(size + 3))
                .foregroundStyle(color)
        } else {
            Circle().fill(color).frame(width: size * 0.6, height: size * 0.6)
        }
    }
}

/// A calendar's mark: its symbol (♡, ✩, ✶) in its color, or a dot.
struct CalendarMark: View {
    let title: String
    let color: String
    var size: CGFloat = 13

    var body: some View {
        if let mark = Mark(title) {
            Text(mark.text)
                .font(mark.isEmoji ? .system(size: size) : Theme.font(size + 3))
                .foregroundStyle(Theme.color(hex: color))
        } else {
            Circle().fill(Theme.color(hex: color)).frame(width: size * 0.6, height: size * 0.6)
        }
    }
}

/// Renaming in place: it starts with the name in it, all selected. Return keeps it, Escape
/// doesn't, clicking away keeps it.
struct RenameField: View {
    let name: String
    var font = Theme.nsFont(15.5)
    let save: (String) -> Void
    let done: () -> Void
    @Local private var text: String
    @Local private var finished = false

    init(name: String, font: NSFont = Theme.nsFont(15.5), save: @escaping (String) -> Void, done: @escaping () -> Void) {
        self.name = name
        self.font = font
        self.save = save
        self.done = done
        _text = Local(initialValue: name)
    }

    var body: some View {
        PlainField(text: $text, font: font, name: "rename", autofocus: true, selectAll: true,
                   onSubmit: { finish(keep: true, leave: true) }, onEscape: { finish(keep: false, leave: true) },
                   onTab: { true }, onEnd: { finish(keep: true, leave: false) })
            .frame(height: ceil(font.pointSize * 1.3))
            .onDisappear { finish(keep: true, leave: false) }
    }

    private func finish(keep: Bool, leave: Bool) {
        guard !finished else { return }
        finished = true
        let typed = text.trimmingCharacters(in: .whitespaces)
        if keep, !typed.isEmpty, typed != name { save(typed) }
        if leave { Keys.letGo() }
        done()
    }
}

/// A sidebar row dragged: a small pill with its name, not the whole row.
struct SidebarDragPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(14))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.paper))
            .overlay(Capsule().strokeBorder(Theme.rule))
    }
}

/// Draggable, when it has a payload (tags don't).
struct SidebarDrag: ViewModifier {
    let model: AppModel
    let payload: String?
    let name: String

    func body(content: Content) -> some View {
        if let payload {
            content.toylDrag(model, payload) { SidebarDragPreview(text: name) }
        } else {
            content
        }
    }
}
