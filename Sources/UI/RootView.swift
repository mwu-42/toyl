import SwiftUI

/// The window: the sidebar, the list, and the selected task's details, side by side on paper.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if model.showSidebar {
                SidebarView(model: model)
                    .frame(width: 238)
                    .background(Theme.sidebar)
                Rectangle().fill(Theme.rule).frame(width: 1)
            }
            MainPane(model: model)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            if model.showInspector, model.place != .timers {
                Rectangle().fill(Theme.rule).frame(width: 1)
                InspectorView(model: model)
                    .frame(width: 322)
                    .frame(maxHeight: .infinity)
                    .background(Theme.paper)
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

// MARK: - sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let snap = model.snap
        VStack(spacing: 0) {
            Color.clear.frame(height: 46)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Place.smart, id: \.self) { place in SidebarRow(model: model, place: place) }
                    Spacer().frame(height: 10)
                    SidebarRow(model: model, place: .ideas)
                    SidebarRow(model: model, place: .timers)
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
                        SidebarLabel(text: "lists")
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

/// A group's heading: click to fold its lists away; right-click to rename or take it away.
struct GroupHeader: View {
    @ObservedObject var model: AppModel
    let group: GroupModel
    @Local private var hovering = false

    var body: some View {
        let folded = model.collapsedGroups.contains(group.id)
        HStack(spacing: 5) {
            if model.renaming == "group:" + group.id {
                RenameField(name: group.name) { model.renameGroup(group.id, to: $0) } done: { model.renaming = nil }
            } else {
                Text(model.display(group.name))
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.faint)
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
        .onTapGesture {
            if folded { model.collapsedGroups.remove(group.id) } else { model.collapsedGroups.insert(group.id) }
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
/// go there (on today: due today; on logbook: done).
struct SidebarRow: View {
    @ObservedObject var model: AppModel
    let place: Place
    var indent: CGFloat = 0
    var count: Int?
    @Local private var hovering = false
    @Local private var targeted = false

    var body: some View {
        let selected = model.place == place
        let shown = place == .today ? max(model.count(.today) - model.lateCount, 0) : count ?? model.count(place)
        HStack(spacing: 9) {
            icon.frame(width: 18)
            if case .list(let id) = place, model.renaming == "list:" + id {
                RenameField(name: model.snap.list(id)?.name ?? "") { model.renameList(id, to: $0) } done: { model.renaming = nil }
            } else if case .filter(let id) = place, model.renaming == "filter:" + id {
                RenameField(name: model.snap.filters.first { $0.id == id }?.name ?? "") { model.renameFilter(id, to: $0) } done: { model.renaming = nil }
            } else {
                Text(name)
                    .font(Theme.sidebarItem)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if place == .today, model.lateCount > 0 {
                Text("\(model.lateCount)")
                    .font(Theme.font(12.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.late.opacity(0.85)))
            }
            if place == .timers, !model.timers.timers.isEmpty {
                Ring(fraction: model.timers.timers.first.map { $0.kind == .countdown ? $0.fractionLeft(at: model.timers.now) : 1 } ?? 0, size: 12, line: 1.6)
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
        .onTapGesture { model.place = place }
        .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { targeted = $0 }
        .contextMenu { menu }
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
                Button("add a section") { model.addSection(to: id) }
                Button(list.archived ? "unarchive" : "archive") { model.archive(id, !list.archived) }
                Divider()
                Button("delete list (its tasks go to the inbox)") { model.deleteList(id) }
            }
        case .filter(let id):
            Button("rename") { model.renaming = "filter:" + id }
            Button("delete filter") { model.deleteFilter(id) }
        case .inbox:
            Button("autosort the inbox…") { model.place = .inbox; model.showAutosort = true }
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

/// Renaming in place: Return keeps it, Escape doesn't, clicking away keeps it.
struct RenameField: View {
    let name: String
    let save: (String) -> Void
    let done: () -> Void
    @Local private var text = ""
    @Local private var finished = false

    var body: some View {
        PlainField(text: $text, font: Theme.nsFont(15.5), focus: 1,
                   onSubmit: { finish(keep: true) }, onEscape: { finish(keep: false) }, onEnd: { finish(keep: true) })
            .onAppear { text = name }
            .frame(height: 20)
    }

    private func finish(keep: Bool) {
        guard !finished else { return }
        finished = true
        if keep, text != name { save(text) }
        done()
    }
}
