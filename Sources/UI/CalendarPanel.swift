import SwiftUI
import UniformTypeIdentifiers

/// The calendar panel, on the right: a day of Google Calendar beside your tasks.
/// - the week across the top, a dot where something's on
/// - the day's all-day events, then its hours, with your timed tasks among the events
/// - drop a task on an hour to do it then, or on a day to move it there
/// - double-click an hour to put an event there (the rules' form)
struct CalendarPanel: View {
    @ObservedObject var model: AppModel
    let width: CGFloat

    var body: some View {
        let bridge = model.calendar
        let day = model.shownDay
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(model: model, day: day)
            WeekStrip(model: model, day: day)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            Hairline()
            if bridge.connected {
                DayView(model: model, day: day, width: width)
            } else {
                NotConnected(model: model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { bridge.want(day) }
    }
}

// MARK: - the top

private struct PanelHeading: View {
    @ObservedObject var model: AppModel
    let day: String

    var body: some View {
        let today = Day.today(model.timers.now)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name(today: today)).font(Theme.font(21, bold: true)).lineLimit(1)
                Text(Format.longDay(day)).font(Theme.meta).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .contentTransition(.opacity)
            Spacer(minLength: 4)
            Quiet(label: "", symbol: "chevron.left", size: 14) { step(-1) }.help("day before")
            if day != today {
                Quiet(label: "today", size: 13.5) { withAnimation(.snappy(duration: 0.2)) { model.showDay(today) } }
                    .transition(.opacity)
            }
            Quiet(label: "", symbol: "chevron.right", size: 14) { step(1) }.help("day after")
            CalendarsMenu(model: model)
        }
        .padding(.top, 34)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private func step(_ days: Int) { withAnimation(.snappy(duration: 0.2)) { model.stepDay(days) } }

    /// "today", "tomorrow", "yesterday", else "nov 30".
    private func name(today: String) -> String {
        switch Day.between(today, day) {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        default: return Format.monthDay(day)
        }
    }
}

/// Which calendars show, and the rest.
private struct CalendarsMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let bridge = model.calendar
        Menu {
            if bridge.connected {
                Section("calendars") {
                    ForEach(bridge.calendars) { calendar in
                        Toggle(calendar.title.lowercased(), isOn: Binding(get: { bridge.isShown(calendar) }, set: { bridge.setShown(calendar.id, $0) }))
                    }
                }
                Divider()
                Button("new event…") { model.newEvent(day: model.shownDay, time: nil) }
                Button("refresh") { bridge.reload() }
            }
            Button("calendar settings…") { bridge.openSettings() }
            Button("hide calendar") { model.showCalendar = false }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The week the day is in: a letter, the date, a dot if something's on. Click to go there; drop
/// a task on a day to move it there (its time kept).
private struct WeekStrip: View {
    @ObservedObject var model: AppModel
    let day: String

    var body: some View {
        let today = Day.today(model.timers.now)
        HStack(spacing: 0) {
            ForEach(week, id: \.self) { date in
                DayCell(model: model, day: date, selected: date == day, isToday: date == today)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Seven days from the week's first day (monday, unless the file says otherwise).
    private var week: [String] {
        guard let date = Day.date(day) else { return [day] }
        let weekday = Day.calendar.component(.weekday, from: date) - 1   // 0 is sunday
        let back = (weekday - model.snap.weekStart + 7) % 7
        return (0..<7).compactMap { Day.adding($0 - back, to: day) }
    }
}

private struct DayCell: View {
    @ObservedObject var model: AppModel
    let day: String
    let selected: Bool
    let isToday: Bool
    @Local private var targeted = false

    var body: some View {
        let date = Day.date(day) ?? Date()
        let weekday = Day.calendar.component(.weekday, from: date) - 1
        VStack(spacing: 3) {
            Text(["s", "m", "t", "w", "t", "f", "s"][weekday]).font(Theme.font(11.5)).foregroundStyle(Theme.faint)
            Text("\(Day.calendar.component(.day, from: date))")
                .font(Theme.font(14.5, bold: selected))
                .foregroundStyle(selected && isToday ? .white : isToday ? Theme.accent : Theme.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(selected ? (isToday ? Theme.accent : Theme.selectionFocused) : targeted ? Theme.selection : .clear))
            Circle().fill(model.calendar.hasEvents(on: day) ? Theme.faint : .clear).frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.showDay(day) } }
        .dropDestination(for: String.self) { items, _ in
            model.schedule(items, day: day, time: nil, keepTime: true)
            return true
        } isTargeted: { targeted = $0 }
        .help(Format.longDay(day))
    }
}

// MARK: - the day

private struct DayView: View {
    @ObservedObject var model: AppModel
    let day: String
    let width: CGFloat
    @Local private var marker: CGFloat?

    static let hour: CGFloat = 44
    static let gutter: CGFloat = 44

    /// Where the blocks go: right of the hours, short of the edge.
    private var area: CGFloat { max(width - Self.gutter - 10, 80) }

    var body: some View {
        let now = model.timers.now
        let today = Day.today(now)
        let events = model.calendar.everything(on: day)
        let timed = events.filter { !$0.allDay }
        let shownEvents = Set(timed.map(\.eventId))
        let dayTasks = model.snap.tasks.filter { $0.due == day && !$0.isIdea }
        let timedTasks = dayTasks.filter { $0.time != nil && !($0.event.map { shownEvents.contains($0.id) } ?? false) }
        let untimed = dayTasks.filter { $0.time == nil && !$0.done }
        let placed = Self.lay(timed.map(Placed.init(event:)) + timedTasks.compactMap(Placed.init(task:)), day: day)
        VStack(spacing: 0) {
            AllDaySection(model: model, day: day, events: events.filter(\.allDay), tasks: untimed)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        HourGrid()
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { location in
                                model.newEvent(day: day, time: Self.clock(Self.minutes(at: location.y, step: 30)))
                            }
                        ForEach(placed) { item in
                            let y = CGFloat(item.from) * Self.hour / 60
                            let height = max(CGFloat(item.to - item.from) * Self.hour / 60, 20) - 2
                            let column = area / CGFloat(item.columns)
                            block(item, height: height, now: now)
                                .frame(width: max(column - 2, 10), height: height)
                                .offset(x: Self.gutter + column * CGFloat(item.column), y: y + 1)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        if day == today { NowLine(width: area).offset(x: Self.gutter - 4, y: Self.y(now) - 4) }
                        if let marker {
                            DropMarker(time: Self.clock(Int(marker / Self.hour * 60)), width: area)
                                .offset(x: Self.gutter - 40, y: marker - 8)
                        }
                    }
                    .frame(width: width, height: 24 * Self.hour, alignment: .topLeading)
                    .onDrop(of: [.plainText], delegate: HourDrop(model: model, day: day, marker: $marker))
                    .padding(.vertical, 10)
                    .animation(.snappy(duration: 0.25), value: placed.map(\.id))
                }
                .scrollIndicators(.never)
                .onAppear { scroll(proxy, first: timed.first, today: today, now: now) }
                .onChange(of: day) { _, _ in scroll(proxy, first: model.calendar.everything(on: day).first { !$0.allDay }, today: today, now: now) }
            }
        }
    }

    @ViewBuilder private func block(_ item: Placed, height: CGFloat, now: Date) -> some View {
        switch item.kind {
        case .event(let event): EventBlock(model: model, event: event, height: height, past: event.end < now)
        case .task(let task): TaskBlock(model: model, task: task, height: height)
        }
    }

    /// To an hour before now (today), else an hour before the first event, else the morning.
    private func scroll(_ proxy: ScrollViewProxy, first: CalEvent?, today: String, now: Date) {
        let hour: Int
        if day == today { hour = Day.calendar.component(.hour, from: now) - 1 }
        else if let first { hour = Day.calendar.component(.hour, from: first.start) - 1 }
        else { hour = model.calendar.dayStart - 1 }
        DispatchQueue.main.async { proxy.scrollTo("h\(min(max(hour, 0), 23))", anchor: .top) }
    }

    // MARK: laying out

    /// An event or a timed task, in minutes from the day's start, side by side with what it overlaps.
    struct Placed: Identifiable {
        enum Kind {
            case event(CalEvent)
            case task(TaskModel)
        }
        let id: String
        let kind: Kind
        let start: Date
        let end: Date
        var from = 0
        var to = 0
        var column = 0
        var columns = 1

        init(event: CalEvent) {
            id = "e:" + event.id
            kind = .event(event)
            start = event.start
            end = event.end
        }

        init?(task: TaskModel) {
            guard let start = task.dueDate else { return nil }
            id = "t:" + task.id
            kind = .task(task)
            self.start = start
            end = start.addingTimeInterval(Double(task.duration ?? 0) * 60)
        }
    }

    /// Minutes into the day (cut to it), then columns: what overlaps shares the width.
    static func lay(_ items: [Placed], day: String) -> [Placed] {
        guard let dayStart = Day.date(day), let next = Day.calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        func minute(_ date: Date) -> Int {
            if date <= dayStart { return 0 }
            if date >= next { return 24 * 60 }
            let parts = Day.calendar.dateComponents([.hour, .minute], from: date)
            return parts.hour! * 60 + parts.minute!
        }
        let shortest = 27   // what 20 points shows
        var ready = items.map { item -> Placed in
            var item = item
            item.from = min(minute(item.start), 24 * 60 - 15)
            item.to = max(minute(item.end), item.from + 15)
            return item
        }
        ready.sort { $0.from == $1.from ? $0.to > $1.to : $0.from < $1.from }
        var result: [Placed] = []
        var cluster: [Int] = []
        var ends: [Int] = []
        var clusterEnd = 0
        func close() {
            for index in cluster { result[index].columns = max(ends.count, 1) }
            cluster = []
            ends = []
        }
        for var item in ready {
            let shownEnd = max(item.to, item.from + shortest)
            if item.from >= clusterEnd { close() }
            if let free = ends.firstIndex(where: { $0 <= item.from }) {
                item.column = free
                ends[free] = shownEnd
            } else {
                item.column = ends.count
                ends.append(shownEnd)
            }
            clusterEnd = cluster.isEmpty ? shownEnd : max(clusterEnd, shownEnd)
            result.append(item)
            cluster.append(result.count - 1)
        }
        close()
        return result
    }

    static func y(_ date: Date) -> CGFloat {
        let parts = Day.calendar.dateComponents([.hour, .minute], from: date)
        return CGFloat(parts.hour! * 60 + parts.minute!) * hour / 60
    }

    /// The quarter (or half) hour at a height.
    static func minutes(at y: CGFloat, step: Int = 15) -> Int {
        let raw = Int((y / hour * 60).rounded(.down))
        return min(max(raw / step * step, 0), 24 * 60 - step)
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// The hours down the side, a hairline at each.
private struct HourGrid: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(hour == 0 ? "" : Format.time(String(format: "%02d:00", hour)))
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.faint)
                        .frame(width: DayView.gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                .frame(height: DayView.hour, alignment: .top)
                .id("h\(hour)")
            }
        }
    }
}

/// Now: a gold dot and line across.
private struct NowLine: View {
    let width: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
            Rectangle().fill(Theme.accent).frame(height: 1.2)
        }
        .frame(width: width + 4, height: 8)
        .allowsHitTesting(false)
    }
}

/// Where a dragged task would land, and when.
private struct DropMarker: View {
    let time: String
    let width: CGFloat
    var body: some View {
        HStack(spacing: 4) {
            Text(Format.time(time)).font(Theme.font(11.5, bold: true)).foregroundStyle(Theme.accent).frame(width: 34, alignment: .trailing)
            Rectangle().fill(Theme.accent).frame(width: width, height: 2)
        }
        .frame(height: 16)
        .allowsHitTesting(false)
    }
}

/// Dropping on the hours: tasks get that day and time (to the quarter hour); a line shows where.
private struct HourDrop: DropDelegate {
    let model: AppModel
    let day: String
    @Binding var marker: CGFloat?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        marker = CGFloat(DayView.minutes(at: info.location.y)) * DayView.hour / 60
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { marker = nil }

    func performDrop(info: DropInfo) -> Bool {
        let time = DayView.clock(DayView.minutes(at: info.location.y))
        marker = nil
        let providers = info.itemProviders(for: [.plainText])
        let model = model, day = day
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? NSString else { return }
                let item = text as String
                Task { @MainActor in model.schedule([item], day: day, time: time) }
            }
        }
        return !providers.isEmpty
    }
}

// MARK: - what's on it

/// An event: a tint of its label's color (or its calendar's), its title, its time. Click for more.
private struct EventBlock: View {
    @ObservedObject var model: AppModel
    let event: CalEvent
    let height: CGFloat
    let past: Bool
    @Local private var showing = false
    @Local private var hovering = false

    var body: some View {
        let color = Theme.color(hex: event.color)
        let short = height < 30
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                if short {
                    HStack(spacing: 4) {
                        Text(event.title).foregroundStyle(Theme.ink)
                        Text(Format.time(Day.clock(event.start))).foregroundStyle(Theme.secondary)
                    }
                    .font(Theme.font(12))
                    .lineLimit(1)
                } else {
                    Text(event.title).font(Theme.font(12.5)).foregroundStyle(Theme.ink)
                        .lineLimit(max(Int((height - 18) / 15), 1))
                    Text(Format.span(event.start, event.end, allDay: false)).font(Theme.font(11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 2)
            .padding(.vertical, short ? 2 : 3)
            Spacer(minLength: 0)
            if event.taskId != nil {
                Image(systemName: "checklist").font(.system(size: 9)).foregroundStyle(Theme.secondary).padding(4)
            }
        }
        .frame(height: height, alignment: .top)
        .background(color.opacity(hovering || showing ? 0.24 : 0.14))
        .overlay {
            if event.tentative { RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(past ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showing = true }
        .popover(isPresented: $showing, arrowEdge: .leading) { EventCard(model: model, event: event) }
    }
}

/// A task with a time: dashed (it's yours, not the calendar's), its circle to check it off.
/// Click to see it; drag it to another hour.
private struct TaskBlock: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    let height: CGFloat
    @Local private var hovering = false

    var body: some View {
        let done = model.isDone(task)
        let short = height < 30
        let selected = model.selection.contains(task.id)
        HStack(alignment: short ? .center : .top, spacing: 5) {
            CheckCircle(done: done, late: false, size: 11)
                .padding(.top, short ? 0 : 3)
                .onTapGesture { model.complete([task.id]) }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.display(task.title))
                    .font(Theme.font(12.5))
                    .foregroundStyle(done ? Theme.secondary : Theme.ink)
                    .strikethrough(done, color: Theme.faint)
                    .lineLimit(short ? 1 : max(Int((height - 18) / 15), 1))
                if !short { Text(when).font(Theme.font(11.5)).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, short ? 0 : 2)
        .frame(height: height, alignment: short ? .center : .top)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.selection : hovering ? Theme.hover : Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .opacity(done ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(task: task.id) }
        .draggable("toyl:" + task.id)
        .contextMenu {
            Button("show task") { model.reveal(task: task.id) }
            Button("add to google calendar…") { model.addToCalendar(task) }
            Button("no time") { model.clearTime(task.id) }
        }
        .help(model.display(task.title) + " · " + when)
    }

    private var when: String {
        guard let time = task.time else { return "" }
        if let start = task.dueDate, let minutes = task.duration {
            return Format.span(start, start.addingTimeInterval(Double(minutes) * 60), allDay: false)
        }
        return Format.time(time)
    }
}

/// All day: the day's all-day events, then (folded) what's due that day with no time. Drop a task
/// here to take its time away.
private struct AllDaySection: View {
    @ObservedObject var model: AppModel
    let day: String
    let events: [CalEvent]
    let tasks: [TaskModel]
    @Local private var open = false
    @Local private var targeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("all day")
                .font(Theme.font(11))
                .foregroundStyle(Theme.faint)
                .frame(width: DayView.gutter - 8, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(events) { event in AllDayChip(model: model, event: event) }
                if !tasks.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { open.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist").font(.system(size: 10))
                            Text("\(tasks.count) due")
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 7, weight: .semibold))
                        }
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open {
                        ForEach(tasks) { task in
                            HStack(spacing: 6) {
                                CheckCircle(done: model.isDone(task), size: 11).onTapGesture { model.complete([task.id]) }
                                Text(model.display(task.title)).font(Theme.font(12.5)).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.reveal(task: task.id) }
                            .draggable("toyl:" + task.id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                if events.isEmpty && tasks.isEmpty {
                    Text(" ").font(Theme.font(12.5))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(targeted ? Theme.hover : .clear)
        .dropDestination(for: String.self) { items, _ in
            model.schedule(items, day: day, time: nil)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct AllDayChip: View {
    @ObservedObject var model: AppModel
    let event: CalEvent
    @Local private var showing = false

    var body: some View {
        let color = Theme.color(hex: event.color)
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 12)
            Text(event.title).font(Theme.font(12.5)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(showing ? 0.2 : 0.1)))
        .contentShape(Rectangle())
        .onTapGesture { showing = true }
        .popover(isPresented: $showing, arrowEdge: .leading) { EventCard(model: model, event: event) }
    }
}

/// An event, up close: when, which calendar and label, where, its note; open it in Google, or
/// see its task.
struct EventCard: View {
    @ObservedObject var model: AppModel
    let event: CalEvent

    var body: some View {
        let calendarColor = model.calendar.color(of: event.calendarId)
        let mark = Mark(event.calendarTitle)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.color(hex: event.color)).frame(width: 3, height: 14)
                Text(event.title).font(Theme.font(17, bold: true)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(Format.shortDay(event.day) + ", " + Format.span(event.start, event.end, allDay: event.allDay), systemImage: "clock")
                Label {
                    Text(((mark?.rest).flatMap { $0.isEmpty ? nil : $0 } ?? event.calendarTitle).lowercased() + (event.label.map { " › " + $0 } ?? ""))
                } icon: {
                    CalendarMark(title: event.calendarTitle, color: calendarColor, size: 11)
                }
                if let location = event.location { Label(location.lowercased(), systemImage: "mappin") }
                if event.tentative { Label("not settled", systemImage: "questionmark.circle") }
                if !event.notes.isEmpty {
                    Label(event.notes, systemImage: "text.alignleft").lineLimit(8).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Theme.font(14))
            .foregroundStyle(Theme.secondary)
            let task = event.taskId.flatMap { model.snap.task($0) }
            if task != nil || event.link != nil {
                Hairline()
                HStack(spacing: 14) {
                    if let task { Quiet(label: "show task", symbol: "checklist") { model.reveal(task: task.id) } }
                    if let link = event.link, let url = URL(string: link) {
                        Quiet(label: "open in google", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 270, alignment: .leading)
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
    }
}

/// Not connected: what to do, in a few words.
private struct NotConnected: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let bridge = model.calendar
        VStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.faint)
            switch bridge.state {
            case .signingIn:
                Text("finish in your browser").font(Theme.font(14.5)).foregroundStyle(Theme.secondary)
            case .signedOut:
                Text("signed out").font(Theme.font(14.5)).foregroundStyle(Theme.secondary)
                Quiet(label: "connect", symbol: "link", tint: Theme.ink) { bridge.connect() }
            default:
                Text("google calendar isn't set up").font(Theme.font(14.5)).foregroundStyle(Theme.secondary)
                Quiet(label: "set up", symbol: "gearshape", tint: Theme.ink) { bridge.openSettings() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
