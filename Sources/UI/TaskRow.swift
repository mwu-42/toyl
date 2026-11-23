import SwiftUI

/// A task: its circle, its title (double-click, or Return, to change it), and under it in italics
/// what's known about it. Drag it anywhere; drop tasks on it to put them before it.
struct TaskRow: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    let group: TaskGroup
    let now: Date
    @Local private var hovering = false
    @Local private var draft = ""
    @Local private var targeted = false

    nonisolated(unsafe) private static var lastClick: (id: String, at: Date)?

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
                if editing {
                    PlainField(text: $draft, font: Theme.nsFont(16), focus: 1,
                               onSubmit: { commit() }, onEscape: { model.editing = nil; model.focusList += 1 }, onEnd: { commit() })
                        .frame(height: 20)
                        .onAppear { draft = task.title }
                } else {
                    Text(model.display(task.title))
                        .font(Theme.body)
                        .foregroundStyle(done ? Theme.secondary : Theme.ink)
                        .strikethrough(done, color: Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeOut(duration: 0.2), value: done)
                }
                if let meta = metaLine { meta.font(Theme.meta).lineLimit(1) }
                let links = NoteLinks.links(in: task.notes)
                if !links.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(links.prefix(3), id: \.self) { url in LinkCard(url: url, compact: true).frame(maxWidth: 240, alignment: .leading) }
                    }
                    .padding(.top, 3)
                }
                if !task.subtasks.isEmpty || (selected && model.selection.count == 1 && !done) {
                    Sublist(model: model, task: task, adding: selected && model.selection.count == 1 && !done)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 6)
            if let timer {
                TimerChip(model: model, timer: timer, now: now)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if hovering, !done {
                Quiet(label: "", symbol: "timer", size: 15) { model.timer(task) }
                    .help("start a timer: \(task.duration.map(Format.minutes) ?? Format.minutes(Int(model.timers.defaultMinutes))) (right-click for others)")
                    .contextMenu { TimerMenu(model: model, task: task) }
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selection : hovering ? Theme.hover : .clear))
        .overlay(alignment: .top) {
            if targeted { Rectangle().fill(Theme.accent).frame(height: 2).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { click() }
        .contextMenu { TaskMenu(model: model, ids: menuTargets) }
        .draggable("toyl:" + dragTargets.joined(separator: ","))
        .dropDestination(for: String.self) { items, _ in
            model.drop(items, list: group.listId ?? task.listId, section: group.sectionId ?? task.sectionId, before: task.id)
        } isTargeted: { targeted = $0 }
    }

    /// The selection, if this is one of it; else just this.
    private var menuTargets: [String] { selected ? Array(model.selection) : [task.id] }
    private var dragTargets: [String] { selected ? model.visible.map(\.id).filter { model.selection.contains($0) } : [task.id] }

    private func click() {
        let flags = NSEvent.modifierFlags
        let at = Date()
        if !flags.contains(.command), !flags.contains(.shift), model.selection == [task.id],
           let last = Self.lastClick, last.id == task.id, at.timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
            model.editing = task.id
        } else {
            model.select(task.id, command: flags.contains(.command), shift: flags.contains(.shift))
            model.focusList += 1
        }
        Self.lastClick = (task.id, at)
    }

    private func commit() {
        guard model.editing == task.id else { return }
        model.editing = nil
        let title = draft.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != task.title {
            var p = TaskPatch()
            p.title = title
            model.store.update(task.id, "rename", p)
        }
        model.focusList += 1
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
        if !NoteLinks.withoutLinks(task.notes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(Text(Image(systemName: "text.alignleft"))) }
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

/// The timers a task can have: its own length, the usual lengths, or a stopwatch.
struct TimerMenu: View {
    @ObservedObject var model: AppModel
    let task: TaskModel

    var body: some View {
        ForEach(TimerEngine.presets, id: \.self) { minutes in
            Button(Format.minutes(minutes)) { model.timer(task, minutes: Double(minutes)) }
        }
        Divider()
        Button("stopwatch") { model.timer(task, stopwatch: true) }
    }
}

/// A running timer on its task's row: its ring and time; click to pause or carry on.
struct TimerChip: View {
    @ObservedObject var model: AppModel
    let timer: TimerModel
    let now: Date

    var body: some View {
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

    var body: some View {
        let tasks = ids.compactMap { model.snap.task($0) }
        let today = Day.today()
        let one = tasks.count == 1 ? tasks[0] : nil
        Button(tasks.allSatisfy(\.done) ? "uncheck" : "check off") { model.complete(ids) }
        Divider()
        Button("today") { model.setDue(today, for: ids) }
        Button("tomorrow") { model.setDue(Day.adding(1, to: today), for: ids) }
        Button("this weekend") { model.setDue(TodQuick.read("sat", now: Date(), weekStart: model.snap.weekStart).due, for: ids) }
        Button("next week") { model.setDue(TodQuick.read("next week", now: Date(), weekStart: model.snap.weekStart).due, for: ids) }
        Button("no date") { model.setDue(nil, for: ids) }
        Divider()
        Button(tasks.allSatisfy(\.pinned) ? "unpin" : "pin to the top") { model.togglePin(ids) }
        Button(tasks.allSatisfy(\.someday) ? "back from ideas" : "to ideas (put off)") { model.toggleSomeday(ids) }
        Menu("move to") {
            ForEach(model.snap.sidebarOrder) { list in
                if list.sections.count > 1 {
                    Menu(model.display(list.displayName)) {
                        ForEach(list.sections) { section in Button(model.display(section.name)) { model.move(ids, to: list.id, section: section.id) } }
                    }
                } else {
                    Button(model.display(list.displayName)) { model.move(ids, to: list.id) }
                }
            }
        }
        if !model.snap.tags.isEmpty {
            Menu("tags") {
                ForEach(model.snap.tags.prefix(30), id: \.name) { tag in
                    Button((tasks.allSatisfy { $0.hasTag(tag.name) } ? "✓ #" : "#") + tag.name) { model.toggleTag(tag.name, for: ids) }
                }
            }
        }
        if let one {
            Divider()
            Menu("timer") { TimerMenu(model: model, task: one) }
            if one.event == nil {
                Button("add to google calendar…") { model.addToCalendar(one) }
            } else {
                Button("take it off google calendar") { model.calendar.unblock(one) }
            }
            if model.calendar.connected {
                Button(one.duration == nil ? "find time for it (set how long it takes first)" : "find time for it") { model.calendar.schedule(one) }
                    .disabled(one.duration == nil)
            }
            if OnDevice.isAvailable { Button("break it into a sublist") { model.breakDown(one) } }
        }
        Divider()
        Button("copy for an agent") { model.copyForAgent(ids) }
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
                }
                .contextMenu {
                    Button(item.done ? "uncheck" : "check off") { change(item.id) { $0.done.toggle() } }
                    Button("remove from the sublist") { remove(item.id) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if adding {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(Theme.faint).frame(width: 13)
                    PlainField(text: $text, placeholder: "add", font: Theme.nsFont(15), onSubmit: add,
                               onEscape: { text = ""; model.focusList += 1 })
                        .frame(height: 19)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: task.subtasks.map(\.id))
    }

    private func add() {
        let title = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !title.isEmpty, let current = model.snap.task(task.id) else { return }
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
