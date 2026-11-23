import SwiftUI

/// The right: everything about the selected task, to change in place; or, with nothing selected,
/// the day at a glance.
struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let task = model.selectedTask {
            TaskDetail(model: model, task: task).id(task.id)
        } else if model.selection.count > 1 {
            ManyDetail(model: model)
        } else {
            DayGlance(model: model)
        }
    }
}

/// A label on the left (an icon and a word), what it is on the right.
struct DetailRow<Content: View>: View {
    let label: String
    var icon: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10.5)).frame(width: 13) }
                Text(label).font(Theme.font(13.5))
            }
            .foregroundStyle(Theme.faint)
            .frame(width: 78, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

struct TaskDetail: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    @Local private var title = ""
    @Local private var notes = ""
    @Local private var due = ""
    @Local private var newTag = ""
    @Local private var newItem = ""
    @Local private var timerText = ""
    /// Notes with links read as words and cards; this is on while they're being changed.
    @Local private var editingNotes = false
    @FocusState private var notesFocused: Bool

    /// One tap each.
    private var timerLengths: [Int] { TimerEngine.presets }

    private func startTyped() {
        guard let minutes = Ops.minutes(timerText).flatMap({ $0 }), minutes > 0 else { return }
        timerText = ""
        model.timer(task, minutes: Double(minutes))
    }

    var body: some View {
        let now = model.timers.now
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    CheckCircle(done: model.isDone(task), size: 20)
                        .padding(.top, 3)
                        .onTapGesture { model.complete([task.id]) }
                    PlainField(text: $title, placeholder: "title", font: Theme.nsFont(21, bold: true),
                               onSubmit: commitTitle, onEnd: commitTitle)
                        .frame(height: 26)
                }
                .padding(.top, 34)
                when(now: now)
                Hairline()
                place
                if let email = task.email { emailRow(email) }
                tags
                Hairline()
                sublist
                notesEditor
                Hairline()
                timer(now: now)
                calendar
                Hairline()
                footer
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.never)
        .onAppear(perform: fill)
        .onChange(of: task) { _, _ in refill() }
        .onChange(of: notesFocused) { _, focused in if !focused { commitNotes(); editingNotes = false } }
        .onDisappear { commitNotes() }
    }

    private func fill() {
        title = task.title
        notes = task.notes
        due = dueText
    }

    /// What's changed elsewhere (the command line, an agent, Oyl), shown unless it's being typed in.
    private func refill() {
        title = task.title
        if !notesFocused { notes = task.notes }
        due = dueText
    }

    private var dueText: String {
        guard let day = task.due else { return "" }
        return Format.day(day) + (task.time.map { " " + Format.time($0) } ?? "")
    }

    // MARK: when

    @ViewBuilder private func when(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            DetailRow(label: "due", icon: "calendar") {
                PlainField(text: $due, placeholder: "when", font: Theme.nsFont(15),
                           onSubmit: commitDue, onEnd: commitDue)
                    .frame(height: 19)
            }
            if let day = task.due {
                Text(Format.longDay(day) + (task.time.map { ", " + Format.time($0) } ?? "") + (task.isLate(at: now) ? " · late" : ""))
                    .font(Theme.font(12.5)).foregroundStyle(Theme.faint)
                    .padding(.leading, 88)
            }
            DetailRow(label: "repeats", icon: "arrow.2.squarepath") {
                Menu {
                    Button("never") { setRepeat(nil) }
                    ForEach(TodRepeat.allCases, id: \.self) { rule in Button(rule.phrase) { setRepeat(rule) } }
                } label: {
                    MenuLabel(text: task.repeats?.phrase ?? "never", faint: task.repeats == nil)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    // MARK: where

    private var place: some View {
        let list = model.snap.list(task.listId)
        return VStack(alignment: .leading, spacing: 9) {
            DetailRow(label: "list", icon: "list.bullet") {
                Menu {
                    ForEach(model.snap.sidebarOrder) { other in
                        Button(model.display(other.displayName)) { model.move([task.id], to: other.id) }
                    }
                } label: {
                    MenuLabel(text: list.map { model.display($0.displayName) } ?? "inbox")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let list, list.sections.count > 1 {
                DetailRow(label: "section", icon: "rectangle.split.1x2") {
                    Menu {
                        ForEach(list.sections) { section in Button(model.display(section.name)) { model.move([task.id], to: list.id, section: section.id) } }
                    } label: {
                        MenuLabel(text: list.sections.first { $0.id == task.sectionId }.map { model.display($0.name) } ?? "")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }

    /// Where it came from: the email's sender and subject, and a way back to it.
    private func emailRow(_ email: MailLink) -> some View {
        DetailRow(label: "email", icon: "envelope") {
            VStack(alignment: .leading, spacing: 3) {
                Text(email.from.lowercased()).font(Theme.font(15)).lineLimit(1)
                Text(email.subject).font(Theme.font(13)).foregroundStyle(Theme.secondary).lineLimit(2)
                if let link = email.link, let url = URL(string: link) {
                    Quiet(label: "open it", symbol: "arrow.up.right.square", size: 13) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var tags: some View {
        DetailRow(label: "tags", icon: "number") {
            VStack(alignment: .leading, spacing: 6) {
                if !task.tags.isEmpty {
                    FlowRow(task.tags) { tag in
                        HStack(spacing: 3) {
                            Text("#" + model.display(tag))
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint)
                        }
                        .font(Theme.font(13.5))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.field))
                        .onTapGesture { model.toggleTag(tag, for: [task.id]) }
                    }
                }
                PlainField(text: $newTag, placeholder: "tag", font: Theme.nsFont(14.5), onSubmit: addTag, onTab: completeTag)
                    .frame(height: 18)
                let matches = tagMatches
                if !matches.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(matches, id: \.self) { tag in
                            Chip(text: "#" + tag).onTapGesture { newTag = tag; addTag() }
                        }
                    }
                }
            }
        }
    }

    private var tagMatches: [String] {
        let typed = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard !typed.isEmpty else { return [] }
        return model.snap.tags.map(\.name).filter { $0.lowercased().hasPrefix(typed) && !task.hasTag($0) }.prefix(5).map { $0 }
    }

    private func completeTag() -> Bool {
        guard let first = tagMatches.first else { return false }
        newTag = first
        return true
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: " ", with: "-")
        newTag = ""
        guard !tag.isEmpty, !task.hasTag(tag) else { return }
        var p = TaskPatch()
        p.addTags = [tag]
        model.store.update(task.id, "tag", p)
    }

    // MARK: sublist and notes

    private var sublist: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("sublist", systemImage: "list.bullet.indent").font(Theme.font(13.5)).foregroundStyle(Theme.faint)
                Spacer()
                if OnDevice.isAvailable {
                    if model.thinking == task.id {
                        Text("thinking…").font(Theme.meta).foregroundStyle(Theme.faint)
                    } else {
                        Quiet(label: "break it down", symbol: "sparkles", size: 12.5) { model.breakDown(task) }
                            .help("apple intelligence makes a sublist, on the mac")
                    }
                }
            }
            ForEach(task.subtasks) { item in SublistRow(model: model, task: task, item: item) }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(Theme.faint).frame(width: 14)
                PlainField(text: $newItem, placeholder: "add", font: Theme.nsFont(15), onSubmit: addItem)
                    .frame(height: 19)
            }
        }
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        newItem = ""
        guard !text.isEmpty else { return }
        var p = TaskPatch()
        p.subtasks = task.subtasks + [Subtask(title: text)]
        model.store.update(task.id, "add to sublist", p)
    }

    /// The notes: with links in them (and not being changed), the words and a card for each
    /// link; otherwise a plain box to type in.
    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("notes", systemImage: "text.alignleft").font(Theme.font(13.5)).foregroundStyle(Theme.faint)
                Spacer()
                if !editingNotes, !NoteLinks.links(in: notes).isEmpty {
                    Quiet(label: "edit", symbol: "pencil", size: 12.5) { startEditingNotes() }
                }
            }
            if editingNotes || notesFocused || NoteLinks.links(in: notes).isEmpty {
                TextEditor(text: $notes)
                    .font(Theme.font(15))
                    .scrollContentBackground(.hidden)
                    .focused($notesFocused)
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            } else {
                RenderedNotes(text: notes) { startEditingNotes() }
                    .transition(.opacity)
            }
        }
    }

    private func startEditingNotes() {
        editingNotes = true
        DispatchQueue.main.async { notesFocused = true }
    }

    // MARK: time

    @ViewBuilder private func timer(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let running = model.timers.timer(for: task.id) {
                HStack(spacing: 10) {
                    if running.kind == .countdown {
                        Ring(fraction: running.fractionLeft(at: now), size: 26, line: 2.5, color: running.isRunning ? Theme.accent : Theme.faint)
                        Text(Format.clock(running.remaining(at: now))).font(Theme.font(24).monospacedDigit())
                    } else {
                        Image(systemName: "stopwatch").foregroundStyle(Theme.secondary)
                        Text(Format.clock(running.worked(at: now), roundingUp: false)).font(Theme.font(24).monospacedDigit())
                    }
                    Spacer()
                    Quiet(label: running.isRunning ? "pause" : "go on") { model.timers.togglePause(running.id) }
                    if running.kind == .countdown { Quiet(label: "+5") { model.timers.extend(running.id, minutes: 5) } }
                    Quiet(label: "stop", tint: Theme.ink) { model.timers.stop(running.id) }
                }
            } else if !task.done {
                Label("timer", systemImage: "timer").font(Theme.font(13.5)).foregroundStyle(Theme.faint)
                FlowRow(timerLengths) { minutes in
                    Button { model.timer(task, minutes: Double(minutes)) } label: {
                        Text(Format.minutes(minutes)).font(Theme.font(14)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(minutes == task.duration ? Theme.selectionFocused : Theme.field))
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                        PlainField(text: $timerText, placeholder: "minutes", font: Theme.nsFont(14.5), onSubmit: startTyped)
                            .frame(width: 110, height: 18)
                    }
                    Quiet(label: "stopwatch", symbol: "stopwatch") { model.timer(task, stopwatch: true) }
                }
            }
            if task.spent > 0 {
                Label(Format.spent(task.spent) + " timed" + (task.duration.map { " of ~" + Format.minutes($0) } ?? ""), systemImage: "clock.arrow.circlepath")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var calendar: some View {
        let bridge = model.calendar
        if !task.done {
            HStack(spacing: 14) {
                if let link = task.event, link.follows {
                    let event = (bridge.events + bridge.further).first { $0.eventId == link.id && $0.calendarId == link.calendar }
                    Label("follows " + (event?.title ?? "an event"), systemImage: "link").font(Theme.meta).foregroundStyle(Theme.secondary).lineLimit(1)
                    Quiet(label: "let go") { bridge.letGo(task) }.help("the event stays on your calendar")
                } else if let link = task.event {
                    let name = bridge.calendars.first { $0.id == link.calendar }?.title.lowercased() ?? "google calendar"
                    Text("on " + name).font(Theme.meta).foregroundStyle(Theme.secondary)
                    Quiet(label: "take it off") { bridge.unblock(task) }
                } else {
                    Quiet(label: "add to google calendar", symbol: "calendar.badge.plus") { model.addToCalendar(task) }
                    if bridge.connected, task.duration != nil { Quiet(label: "find time") { bridge.schedule(task) } }
                }
            }
        }
    }

    // MARK: the rest

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                Quiet(label: task.pinned ? "unpin" : "pin", symbol: task.pinned ? "pin.slash" : "pin") { model.togglePin([task.id]) }
                Quiet(label: task.someday ? "back from ideas" : "to ideas", symbol: "lightbulb") { model.toggleSomeday([task.id]) }
                Spacer()
                Quiet(label: "delete", symbol: "trash", tint: Theme.late) {
                    model.selection = [task.id]
                    model.deleteSelected()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("added " + Format.day(Day.string(task.createdAt)) + (task.source.map { " from \($0)" } ?? ""))
                if let doneAt = task.doneAt, task.done { Text("done " + Format.day(Day.string(doneAt))) }
                HStack(spacing: 4) {
                    Text("id")
                    Text(task.id).textSelection(.enabled).foregroundStyle(Theme.secondary)
                    Quiet(label: "", symbol: "doc.on.doc", size: 11) { model.copyForAgent([task.id]) }
                        .help("copy for an agent: “toyl task \(task.id): \(task.title)”")
                }
            }
            .font(Theme.font(12.5))
            .foregroundStyle(Theme.faint)
        }
    }

    // MARK: saving

    private func commitTitle() {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != task.title else { if text.isEmpty { title = task.title }; return }
        var p = TaskPatch()
        p.title = text
        model.store.update(task.id, "rename", p)
    }

    private func commitNotes() {
        guard notes != task.notes else { return }
        var p = TaskPatch()
        p.notes = notes
        model.store.update(task.id, "notes", p)
    }

    /// Read as quick add reads a day ("fri 5pm", "tomorrow", "none" to clear).
    private func commitDue() {
        let text = due.trimmingCharacters(in: .whitespaces)
        guard text != dueText else { return }
        var p = TaskPatch()
        if text.isEmpty || ["none", "no", "-"].contains(text.lowercased()) {
            p.due = .some(nil)
            p.time = .some(nil)
        } else {
            let read = TodQuick.read(text, now: Date(), weekStart: model.snap.weekStart)
            guard read.due != nil || read.time != nil else { due = dueText; return }
            p.due = .some(read.due ?? task.due ?? Day.today())
            p.time = .some(read.time)
            p.someday = false
        }
        model.store.update(task.id, "reschedule", p)
    }

    private func setRepeat(_ rule: TodRepeat?) {
        var p = TaskPatch()
        p.repeats = .some(rule)
        if rule != nil, task.due == nil { p.due = .some(Day.today()) }
        model.store.update(task.id, "repeat", p)
    }
}

/// A menu's label: what's chosen, in the theme's face, with a small chevron.
struct MenuLabel: View {
    let text: String
    var faint = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(Theme.font(15)).foregroundStyle(faint ? Theme.faint : Theme.ink)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.faint)
        }
    }
}

/// One line of a task's sublist, to change in place.
struct SublistRow: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    let item: Subtask
    @Local private var text = ""
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            CheckCircle(done: item.done, size: 14)
                .onTapGesture { change { $0.done.toggle() } }
            PlainField(text: $text, font: Theme.nsFont(15), color: item.done ? Theme.nsSecondary : Theme.nsInk,
                       onSubmit: save, onEnd: save)
                .frame(height: 19)
                .onAppear { text = item.title }
                .onChange(of: item.title) { _, title in text = title }
            if hovering {
                Quiet(label: "", symbol: "xmark", size: 10) {
                    var p = TaskPatch()
                    p.subtasks = task.subtasks.filter { $0.id != item.id }
                    model.store.update(task.id, "remove from sublist", p)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private func save() {
        let title = text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != item.title else { return }
        change { $0.title = title }
    }

    private func change(_ edit: (inout Subtask) -> Void) {
        var items = task.subtasks
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        edit(&items[index])
        var p = TaskPatch()
        p.subtasks = items
        model.store.update(task.id, "sublist", p)
    }
}

/// Several selected: what can be done to all of them at once.
struct ManyDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.selection.count) tasks").font(Theme.font(21, bold: true)).padding(.top, 34)
            VStack(alignment: .leading, spacing: 9) {
                Quiet(label: "check them off", symbol: "checkmark.circle", tint: Theme.ink) { model.toggleSelected() }
                Quiet(label: "today", symbol: "sun.max") { model.setDue(Day.today()) }
                Quiet(label: "tomorrow", symbol: "sunrise") { model.setDue(Day.adding(1, to: Day.today())) }
                Quiet(label: "no date", symbol: "calendar.badge.minus") { model.setDue(nil) }
                Quiet(label: "pin", symbol: "pin") { model.togglePin() }
                Quiet(label: "to ideas", symbol: "lightbulb") { model.toggleSomeday() }
                Quiet(label: "copy for an agent", symbol: "doc.on.doc") { model.copyForAgent() }
                Quiet(label: "delete them", symbol: "trash", tint: Theme.late) { model.deleteSelected() }
            }
            Label("right-click: move, tag", systemImage: "cursorarrow.click.2").font(Theme.meta).foregroundStyle(Theme.faint)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Nothing selected: today, in brief.
struct DayGlance: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let now = model.timers.now
        let today = Day.today(now)
        let snap = model.snap
        let open = snap.tasks.filter { !$0.done }
        let dueToday = open.filter { $0.due == today }.count
        let late = model.lateCount
        let inbox = open.filter { $0.listId == ListModel.inbox }.count
        let doneToday = snap.tasks.filter { $0.done && $0.doneAt.map { Day.string($0) == today } == true }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Format.longDay(today, now: now)).font(Theme.font(21, bold: true)).padding(.top, 34)
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(dueToday) due today", systemImage: "sun.max")
                    if late > 0 { Label("\(late) late", systemImage: "clock") }
                    Label("\(inbox) in the inbox", systemImage: "tray")
                    if doneToday > 0 { Label("\(doneToday) done today", systemImage: "checkmark.circle") }
                }
                .font(Theme.font(15))
                .foregroundStyle(Theme.secondary)
                if model.calendar.showEvents {
                    let events = model.calendar.events(on: today).filter { $0.end > now || $0.allDay }
                    if !events.isEmpty {
                        Hairline()
                        Label("still to come", systemImage: "clock").font(Theme.font(13.5)).foregroundStyle(Theme.faint)
                        EventsStrip(events: events, now: now, compact: true).padding(.horizontal, -12)
                    } else if !model.calendar.connected {
                        Hairline()
                        Quiet(label: "connect google calendar", symbol: "calendar") { model.calendar.openSettings() }
                    }
                }
                Hairline()
                VStack(alignment: .leading, spacing: 5) {
                    Tip(key: "⌘N", words: "new task")
                    Tip(key: "⌘⌥X", words: "add from anywhere")
                    Tip(key: "?", words: "an idea")
                    Tip(key: "#cs", words: "list or tag")
                    Tip(key: "/timer", words: "start a timer")
                    Tip(key: "!", words: "pin")
                }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

/// A shortcut and what it does, in two columns.
struct Tip: View {
    let key: String
    let words: String

    var body: some View {
        HStack(spacing: 10) {
            Text(key).font(Theme.font(13.5)).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .leading)
            Text(words).font(Theme.font(13.5)).foregroundStyle(Theme.faint)
        }
    }
}

/// Things laid out in a row, wrapping onto the next line as they run out of room.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        Flow(spacing: 5) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
