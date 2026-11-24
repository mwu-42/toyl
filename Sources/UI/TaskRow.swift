import SwiftUI

/// A task: its circle, its title (a click puts the caret in it, where the click was; or ⌘E), and
/// under it in gray what's known about it. Drag it anywhere; drop tasks on it to put them before it.
struct TaskRow: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    let group: TaskGroup
    let now: Date
    @Local private var hovering = false
    @Local private var targeted = false

    private var selected: Bool { model.selection.contains(task.id) }
    private var editing: Bool { model.editing == task.id }

    var body: some View {
        let timer = model.timers.timer(for: task.id)
        let done = model.isDone(task)
        HStack(alignment: .top, spacing: 11) {
            CheckCircle(done: done)
                .padding(.top, 2)
                .onTapGesture { model.complete([task.id]) }
                .help(task.done ? "uncheck" : "check off")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.display(task.title))
                    .font(Theme.body)
                    .foregroundStyle(done ? Theme.secondary : Theme.ink)
                    .strikethrough(done, color: Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.2), value: done)
                    .changedInPlace(editing) { TitleEditor(model: model, task: task) }
                if let meta = metaLine { meta.font(Theme.meta).lineLimit(1) }
                if !task.subtasks.isEmpty || (model.addingSublist == task.id && !done) {
                    Sublist(model: model, task: task, adding: model.addingSublist == task.id && !done)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 6)
            if let timer {
                TimerChip(model: model, timer: timer)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(targeted ? Theme.selectionFocused : selected ? Theme.selection : hovering ? Theme.hover : .clear))
        .modifier(SwipeOffset(swiping: model.swiping, id: task.id, inProgress: model.isInProgress(task), timed: timer != nil))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { model.hoveredTask = task.id } else if model.hoveredTask == task.id { model.hoveredTask = nil }
        }
        .onDisappear { if model.hoveredTask == task.id { model.hoveredTask = nil } }
        .onTapGesture(coordinateSpace: .global) { click(at: $0) }
        .contextMenu { TaskMenu(model: model, ids: menuTargets) }
        .toylDrag(model, { "toyl:" + dragTargets.joined(separator: ",") }) {
            TaskDragPreview(title: model.display(task.title), count: dragTargets.count)
        }
        // Tasks (or text) go above or below it, by the half the pointer's in; an event from the
        // calendar ties it to that event; a sublist item joins its sublist.
        .columnDrop(model, lit: $targeted, accepts: { ["tasks", "text", "event", "sub"].contains(Drag.kind($0)) },
                    reorders: { ["tasks", "text"].contains(Drag.kind($0)) }) { items, spot in
            dropped(items, spot)
        }
    }

    private func dropped(_ items: [String], _ spot: RowSpot) -> Bool {
        guard let first = items.first else { return false }
        switch Drag.kind(first) {
        case "event":
            return model.linkEvent(items, to: task.id)
        case "sub":
            guard let (source, item) = Drag.pair(first) else { return false }
            model.moveSubtask(item, from: source, to: task.id, before: nil)
            return true
        default:
            let ids = group.tasks.map(\.id)
            let next = ids.firstIndex(of: task.id).flatMap { $0 + 1 < ids.count ? ids[$0 + 1] : nil }
            let before = spot == .below ? next : task.id
            let tasks = items.filter { $0.hasPrefix("toyl:") }.flatMap { $0.dropFirst(5).split(separator: ",").map(String.init) }
            if !tasks.isEmpty {
                model.reorder(tasks, in: group, before: before)
                return true
            }
            return model.drop(items, list: group.listId ?? task.listId, section: group.sectionId ?? task.sectionId, before: before)
        }
    }

    /// The selection, if this is one of it; else just this.
    private var menuTargets: [String] { selected ? Array(model.selection) : [task.id] }
    private var dragTargets: [String] { selected ? model.visible.map(\.id).filter { model.selection.contains($0) } : [task.id] }

    /// A click puts the caret in its title, where the click was (⌘ or ⇧: it's selected, to
    /// take more, and nothing's typed).
    private func click(at point: CGPoint) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            model.select(task.id, command: flags.contains(.command), shift: flags.contains(.shift))
            // The list has the keys now (a field that had them lets go, keeping what was typed).
            model.leaveTyping()
            return
        }
        guard !editing else { return }
        model.select(task.id)
        model.editingAt = point
        model.editing = task.id
    }

    /// What's known about it, in a line: when, its aim, how it repeats, how long it takes, the
    /// list it's in (where that's not obvious), its tags, its notes. (Its sublist shows under it.)
    private var metaLine: Text? {
        var parts: [Text] = []
        let today = Day.today(now)
        if let when = Format.due(task, now: now) {
            let late = task.isLate(at: now)
            // Late is said quietly: a soft red on the date, nothing more.
            let color = late ? Theme.late.opacity(0.75) : (task.due == today ? Theme.ink : Theme.secondary)
            parts.append(Text(when).foregroundColor(color))
        }
        if model.isInProgress(task), group.sectionId != task.sectionId, model.place != .inProgress {
            parts.insert(Text(Image(systemName: "circle.lefthalf.filled")).foregroundColor(Theme.accent) + Text(" in progress").foregroundColor(Theme.accent), at: 0)
        }
        if let project = model.snap.list(task.listId)?.project(task.project), group.projectId != project.id {
            parts.append(Text(Image(systemName: "folder")) + Text(" " + model.display(project.name)))
        }
        if task.isFromEmail { parts.append(Text(Image(systemName: "envelope")) + Text(" email")) }
        if let repeats = task.repeats { parts.append(Text(Image(systemName: "arrow.2.squarepath")) + Text(" " + repeats.phrase)) }
        if task.spent >= 60 { parts.append(Text(Image(systemName: "timer")) + Text(" " + Format.spent(task.spent))) }
        if showsList, let list = model.snap.list(task.listId) {
            let color = Theme.color(hex: list.color)
            if let mark = list.mark, !list.isSpecial {
                parts.append((mark.isEmoji ? Text(mark.text) : Text(mark.text).foregroundColor(color)) + Text(" " + model.display(list.bareName)))
            } else {
                parts.append(Text("●").foregroundColor(color) + Text(" " + model.display(list.displayName)))
            }
        }
        if !task.tags.isEmpty { parts.append(Text(task.tags.map { "#" + model.display($0) }.joined(separator: " "))) }
        if !task.notes.isEmpty, NoteLinks.hasWords(task.notes) { parts.append(Text(Image(systemName: "text.alignleft"))) }
        if task.event != nil { parts.append(Text(Image(systemName: "calendar"))) }
        if task.pinned { parts.append(Text(Image(systemName: "pin.fill")).foregroundColor(Theme.accent)) }
        if task.someday, model.place != .ideas { parts.append(Text(Image(systemName: "lightbulb"))) }
        guard !parts.isEmpty else { return nil }
        var line = parts[0]
        for part in parts.dropFirst() { line = line + Text("  ·  ").foregroundColor(Theme.faint) + part }
        return line.foregroundColor(Theme.secondary)
    }

    private var showsList: Bool {
        switch model.place {
        case .list, .inbox, .ideas: return false
        default: return model.groupMode(model.place) != .list
        }
    }
}

/// A running timer on its task's row: its ring and time; click to pause or carry on.
struct TimerChip: View {
    @ObservedObject var model: AppModel
    let timer: TimerModel

    /// It ticks on its own (each second while it's going), not the whole list.
    var body: some View {
        TimelineView(.periodic(from: .now, by: timer.isRunning ? 1 : 3600)) { context in chip(now: context.date) }
    }

    private func chip(now: Date) -> some View {
        Button { model.timers.togglePause(timer.id) } label: {
            HStack(spacing: 5) {
                if timer.kind == .countdown {
                    Ring(fraction: timer.fractionLeft(at: now), size: 13, line: 1.8, color: timer.isRunning ? Theme.accent : Theme.faint)
                    Text(Format.clock(timer.remaining(at: now)))
                } else {
                    Image(systemName: "stopwatch").font(.system(size: 11))
                    Text(Format.clock(timer.worked(at: now), roundingUp: false))
                }
            }
            .font(Theme.font(13.5).monospacedDigit())
            .foregroundStyle(timer.isRunning ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.field))
        }
        .buttonStyle(.plain)
        .help(timer.isRunning ? "pause" : "carry on")
    }
}

/// What can be done to tasks (the selection, or the one right-clicked).
struct TaskMenu: View {
    @ObservedObject var model: AppModel
    let ids: [String]

    /// Just three: add a subtask (to one task, not done), duplicate, delete. The rest is in the
    /// menu bar, the description, and swipes.
    var body: some View {
        let tasks = ids.compactMap { model.snap.task($0) }
        if tasks.count == 1, let one = tasks.first, !one.done {
            Button("add subtask") {
                model.selection = [one.id]
                withAnimation(.snappy(duration: 0.2)) { model.addingSublist = one.id }
            }
        }
        Button(ids.count > 1 ? "duplicate \(ids.count)" : "duplicate") { model.duplicate(ids) }
        Button(ids.count > 1 ? "delete \(ids.count)" : "delete", role: .destructive) {
            model.selection = Set(ids)
            model.deleteSelected()
        }
    }
}

/// A task's sublist, right under it in the list: each one checked off on its own; with the task
/// selected, a line to add another.
struct Sublist: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    var adding = false
    @Local private var text = ""
    /// The item being changed in place (double-click it).
    @Local private var editing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(task.subtasks) { item in
                HStack(spacing: 8) {
                    CheckCircle(done: item.done, size: 13)
                        .onTapGesture { change(item.id) { $0.done.toggle() } }
                    Text(model.display(item.title))
                        .font(Theme.font(15))
                        .foregroundStyle(item.done ? Theme.secondary : Theme.ink)
                        .strikethrough(item.done, color: Theme.faint)
                        .animation(.easeOut(duration: 0.2), value: item.done)
                        // A click selects the task, as anywhere on it; a double-click changes the item.
                        .onTapGesture {
                            if DoubleClick.second("sub:" + item.id) {
                                editing = item.id
                            } else {
                                model.select(task.id)
                                model.leaveTyping()
                            }
                        }
                        .changedInPlace(editing == item.id) {
                            SubEditor(title: item.title) { title in
                                if let title { change(item.id) { $0.title = title } }
                                editing = nil
                            }
                        }
                }
                .contentShape(Rectangle())
                .toylDrag(model, "toyl-sub:\(task.id)|\(item.id)") { SidebarDragPreview(text: model.display(item.title)) }
                .columnDrop(model, inset: 0, accepts: { Drag.kind($0) == "sub" }, reorders: { _ in true }) { items, spot in
                    guard let first = items.first, let (source, moving) = Drag.pair(first) else { return false }
                    let ids = task.subtasks.map(\.id)
                    let next = ids.firstIndex(of: item.id).flatMap { $0 + 1 < ids.count ? ids[$0 + 1] : nil }
                    model.moveSubtask(moving, from: source, to: task.id, before: spot == .below ? next : item.id)
                    return true
                }
                .contextMenu {
                    Button(item.done ? "uncheck" : "check off") { change(item.id) { $0.done.toggle() } }
                    Button("change it") { editing = item.id }
                    Button("remove from the sublist") { remove(item.id) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if adding {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(Theme.faint).frame(width: 13)
                    PlainField(text: $text, placeholder: "add", font: Theme.nsFont(15), name: "sublist", autofocus: true, onSubmit: add,
                               onEscape: { close(leave: true) }, onTab: { true },
                               onEnd: { if text.trimmingCharacters(in: .whitespaces).isEmpty { close(leave: false) } })
                        .frame(height: 19)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: task.subtasks.map(\.id))
    }

    /// Closed by a key, it lets go of the keys too; closed by a click elsewhere, the keys are
    /// already where the click put them.
    private func close(leave: Bool) {
        text = ""
        if leave { model.leaveTyping() }
        withAnimation(.snappy(duration: 0.2)) { if model.addingSublist == task.id { model.addingSublist = nil } }
    }

    /// Return adds and stays for the next; Return with nothing typed closes it.
    private func add() {
        let title = text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return close(leave: true) }
        text = ""
        guard let current = model.snap.task(task.id) else { return }
        var p = TaskPatch()
        p.subtasks = current.subtasks + [Subtask(title: title)]
        model.store.update(task.id, "add to sublist", p)
    }

    private func change(_ id: String, _ edit: (inout Subtask) -> Void) {
        guard var items = model.snap.task(task.id)?.subtasks, let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
        var p = TaskPatch()
        p.subtasks = items
        withAnimation(.spring(response: 0.24, dampingFraction: 0.6)) { model.store.update(task.id, "sublist", p) }
    }

    private func remove(_ id: String) {
        guard let items = model.snap.task(task.id)?.subtasks else { return }
        var p = TaskPatch()
        p.subtasks = items.filter { $0.id != id }
        model.store.update(task.id, "remove from sublist", p)
    }
}

/// What a swipe uncovers: in progress (gold, on the left, swiping right) or delete (red, on the
/// right, swiping left), bolder once it's far enough to do it.
struct SwipeBehind: View {
    let offset: CGFloat
    let inProgress: Bool
    /// A timer's going on it: a soft left swipe stops it (rather than starting one).
    var timed = false

    var body: some View {
        let hard = abs(offset) >= AppModel.swipeHardReach
        let timing = offset > 0 && hard
        let soft = offset < 0 && !hard
        let reached = abs(offset) >= AppModel.swipeReach
        ZStack {
            if offset > 0 {
                HStack(spacing: 6) {
                    Image(systemName: timing ? "timer" : inProgress ? "circle" : "circle.lefthalf.filled")
                    Text(timing ? "in progress + timer" : inProgress ? "not in progress" : "in progress").font(Theme.font(14))
                }
                .foregroundStyle(.white)
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(timing ? Theme.ink.opacity(0.8) : Theme.accent.opacity(reached ? 1 : 0.6)))
            } else if offset < 0 {
                HStack(spacing: 6) {
                    Text(soft ? (timed ? "stop timer" : "timer") : "delete").font(Theme.font(14))
                    Image(systemName: soft ? (timed ? "stop.circle" : "timer") : "trash")
                }
                .foregroundStyle(.white)
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(RoundedRectangle(cornerRadius: 7).fill(soft ? (timed ? Theme.secondary : Theme.accent).opacity(reached ? 1 : 0.6) : Theme.late.opacity(0.95)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: reached)
        .animation(.easeOut(duration: 0.12), value: hard)
    }
}

/// What's dragged when a task is: a small pill (its circle and title, and how many more if
/// several go), not the whole wide row.
struct TaskDragPreview: View {
    let title: String
    var count = 1

    var body: some View {
        HStack(spacing: 7) {
            Circle().strokeBorder(Theme.secondary, lineWidth: 1.2).frame(width: 12, height: 12)
            Text(title).font(Theme.font(14.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if count > 1 {
                Text("+\(count - 1)").font(Theme.font(12.5, bold: true)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(8)
    }
}

/// A task's title being changed in its row. It starts with the title in it and the caret at the
/// end. Return keeps it, Escape doesn't; however else it ends (a click on another task, another
/// place, ↑ or ↓ to the next task), what was typed is kept.
struct TitleEditor: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    @Local private var draft: String
    @Local private var finished = false
    /// Where the click that opened it was, for the caret.
    @Local private var caret: CGPoint?
    /// "/" typed: days and what goes on a task, in a menu under it.
    @Local private var slash = SlashPick(editing: true)

    init(model: AppModel, task: TaskModel) {
        self.model = model
        self.task = task
        _draft = Local(initialValue: task.title)
        _caret = Local(initialValue: model.editingAt)
        _slash = Local(initialValue: SlashPick(weekStart: model.snap.weekStart, editing: true))
    }

    var body: some View {
        let menu = slash.menu(draft)
        PlainField(text: $draft, font: Theme.nsFont(16), name: "title", autofocus: true,
                   onSubmit: { if !slash.take(in: &draft) { finish(keep: true, leave: true) } },
                   onEscape: { if !slash.close(draft) { finish(keep: false, leave: true) } },
                   onTab: { _ = slash.take(in: &draft); return true },
                   onUp: {
                       if slash.move(-1, in: draft) { return true }
                       finish(keep: true, leave: true)
                       model.moveSelection(-1)
                       return true
                   },
                   onDown: {
                       if slash.move(1, in: draft) { return true }
                       finish(keep: true, leave: true)
                       model.moveSelection(1)
                       return true
                   },
                   onEnd: { finish(keep: true, leave: false) },
                   marks: Quick.edit(draft, weekStart: model.snap.weekStart).marks,
                   caretAt: caret)
            .overlay(alignment: .topLeading) {
                if let menu {
                    Floating(size: SlashMenu.size(menu.words.count)) {
                        SlashMenu(words: menu.words, picked: slash.picked(in: menu.words.count), pick: { slash.index = $0 }) { choice in
                            _ = slash.take(choice, in: &draft)
                            InkField.named("title")?.takeKeys()
                        }
                    }
                    // Just under the title.
                    .offset(y: 24)
                }
            }
            .onChange(of: draft) { _, now in slash.typed(now) }
            .onAppear { model.editingAt = nil }
            .onDisappear { finish(keep: true, leave: false) }
    }

    /// Keeps what was typed (unless it's Escape): the words, and what slash words in it say (a
    /// day, /pin, /idea, a timer), which come out of the title.
    private func finish(keep: Bool, leave: Bool) {
        guard !finished else { return }
        finished = true
        if keep { model.retitle(task.id, to: draft) }
        if leave { model.leaveTyping() }
        if model.editing == task.id { model.editing = nil }
    }
}

/// A sublist item's words being changed in place: Return (or clicking away) keeps them, Escape
/// doesn't. `done` gets the new words, or nil.
struct SubEditor: View {
    let title: String
    let done: (String?) -> Void
    @Local private var text: String
    @Local private var finished = false

    init(title: String, done: @escaping (String?) -> Void) {
        self.title = title
        self.done = done
        _text = Local(initialValue: title)
    }

    var body: some View {
        PlainField(text: $text, font: Theme.nsFont(15), name: "item", autofocus: true,
                   onSubmit: { finish(keep: true, leave: true) }, onEscape: { finish(keep: false, leave: true) },
                   onTab: { true }, onEnd: { finish(keep: true, leave: false) })
            .onDisappear { finish(keep: true, leave: false) }
    }

    private func finish(keep: Bool, leave: Bool) {
        guard !finished else { return }
        finished = true
        let typed = text.trimmingCharacters(in: .whitespaces)
        if leave { Keys.letGo() }
        done(keep && !typed.isEmpty && typed != title ? typed : nil)
    }
}

/// A row pulled sideways by a swipe, with what it'd do showing behind it. It watches the swipe
/// alone, so a swipe redraws this, not the list.
struct SwipeOffset: ViewModifier {
    @ObservedObject var swiping: Swiping
    let id: String
    let inProgress: Bool
    let timed: Bool

    func body(content: Content) -> some View {
        let offset = swiping.swipe?.id == id ? swiping.swipe?.offset ?? 0 : 0
        content
            .background(Theme.paper.opacity(offset != 0 ? 1 : 0))
            .offset(x: offset)
            .background { SwipeBehind(offset: offset, inProgress: inProgress, timed: timed) }
    }
}
