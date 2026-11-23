import SwiftUI
import UniformTypeIdentifiers

/// Day, week or month.
enum CalendarMode: String, CaseIterable {
    case day, week, month

    /// How wide the panel starts out for it.
    var standardWidth: CGFloat { self == .day ? 300 : 640 }
}

/// The days a week or a month view shows.
enum CalendarDays {
    /// Seven days from the week's first day (`start`: 0 sunday, 1 monday).
    static func week(of day: String, start: Int) -> [String] {
        guard let date = Day.date(day) else { return [day] }
        let weekday = Day.calendar.component(.weekday, from: date) - 1
        let back = (weekday - start + 7) % 7
        return (0..<7).compactMap { Day.adding($0 - back, to: day) }
    }

    /// Whole weeks covering the month `day` is in.
    static func month(of day: String, start: Int) -> [String] {
        guard let date = Day.date(day),
              let first = Day.calendar.date(from: Day.calendar.dateComponents([.year, .month], from: date)),
              let days = Day.calendar.range(of: .day, in: .month, for: date)?.count else { return [day] }
        let firstDay = Day.string(first)
        let lead = (Day.calendar.component(.weekday, from: first) - 1 - start + 7) % 7
        let cells = Int((Double(lead + days) / 7).rounded(.up)) * 7
        return (0..<cells).compactMap { Day.adding($0 - lead, to: firstDay) }
    }

    static func isSameMonth(_ a: String, _ b: String) -> Bool { a.prefix(7) == b.prefix(7) }
}

/// The calendar panel: Google Calendar beside your tasks, as a day, a week or a month.
/// - day: the week across the top, the day's all-day events, then its hours with your timed tasks
/// - week: seven days of hours side by side
/// - month: the month's days, a few things on each; click one to see it
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
            if !bridge.connected {
                Hairline()
                NotConnected(model: model)
            } else {
                switch model.calendarMode {
                case .day:
                    WeekStrip(model: model, day: day)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    Hairline()
                    AllDaySection(model: model, day: day, events: bridge.everything(on: day).filter(\.allDay),
                                  tasks: model.snap.tasks.filter { $0.due == day && $0.time == nil && !$0.done && !$0.isIdea })
                    Hairline()
                    HoursView(model: model, days: [day], width: width)
                case .week:
                    let days = model.shownDays
                    WeekHeader(model: model, days: days, width: width)
                    Hairline()
                    WeekAllDay(model: model, days: days, width: width)
                    Hairline()
                    HoursView(model: model, days: days, width: width)
                case .month:
                    MonthView(model: model, day: day, width: width)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.wantShown() }
    }
}

// MARK: - the top

private struct PanelHeading: View {
    @ObservedObject var model: AppModel
    let day: String

    var body: some View {
        let today = Day.today(model.timers.now)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Theme.font(21, bold: true)).lineLimit(1).contentTransition(.opacity)
                Spacer(minLength: 4)
                Quiet(label: "", symbol: "chevron.left", size: 14) { step(-1) }.help("earlier (⌥⌘[)")
                Quiet(label: "today", size: 13.5) {
                    withAnimation(.snappy(duration: 0.2)) { model.showDay(today) }
                }
                Quiet(label: "", symbol: "chevron.right", size: 14) { step(1) }.help("later (⌥⌘])")
                CalendarsMenu(model: model)
            }
            HStack(spacing: 14) {
                ForEach(CalendarMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { model.calendarMode = mode }
                    } label: {
                        Text(mode.rawValue)
                            .font(Theme.font(13.5, bold: model.calendarMode == mode))
                            .foregroundStyle(model.calendarMode == mode ? Theme.ink : Theme.faint)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 34)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private func step(_ steps: Int) { withAnimation(.snappy(duration: 0.2)) { model.stepDay(steps) } }

    /// "sun nov 22"; "nov 16-22"; "november".
    private var title: String {
        switch model.calendarMode {
        case .day:
            return Format.shortDay(day)
        case .week:
            let days = model.shownDays
            guard let first = days.first, let last = days.last else { return "" }
            let a = Format.monthDay(first), b = Format.monthDay(last)
            return CalendarDays.isSameMonth(first, last) ? a + "-" + (b.split(separator: " ").last.map(String.init) ?? b) : a + "-" + b
        case .month:
            guard let date = Day.date(day) else { return "" }
            let sameYear = Day.calendar.component(.year, from: date) == Day.calendar.component(.year, from: Date())
            return (sameYear ? Self.monthName : Self.monthYear).string(from: date).lowercased()
        }
    }

    private static let monthName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter
    }()

    private static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        return formatter
    }()
}

/// Which calendars show (a list that stays open while you click through it), and the rest.
private struct CalendarsMenu: View {
    @ObservedObject var model: AppModel
    @Local private var open = false

    var body: some View {
        Quiet(label: "", symbol: "ellipsis.circle", size: 15) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) { CalendarsList(model: model, calendar: model.calendar, open: $open) }
            .help("calendars")
    }
}

private struct CalendarsList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarBridge
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if calendar.connected {
                Text("calendars").font(Theme.font(12.5)).foregroundStyle(Theme.faint).padding(.horizontal, 6).padding(.bottom, 2)
                ForEach(calendar.calendars) { info in
                    CalendarSwitch(calendar: calendar, info: info, name: info.title.lowercased())
                }
                Hairline().padding(.vertical, 6)
                Quiet(label: "new event", symbol: "plus") { open = false; model.newEvent(day: model.shownDay, time: nil) }.padding(.horizontal, 6)
                Quiet(label: "refresh", symbol: "arrow.clockwise") { calendar.reload() }.padding(.horizontal, 6)
            }
            Quiet(label: "calendar settings", symbol: "gearshape") { open = false; calendar.openSettings() }.padding(.horizontal, 6)
            if !model.showTasks {
                Quiet(label: "show page", symbol: "list.bullet") { open = false; model.setShown(.tasks, true) }.padding(.horizontal, 6)
            }
            Quiet(label: "hide calendar", symbol: "eye.slash") { open = false; model.setShown(.calendar, false) }.padding(.horizontal, 6)
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(Theme.paper)
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
            ForEach(CalendarDays.week(of: day, start: model.snap.weekStart), id: \.self) { date in
                DayCell(model: model, day: date, selected: date == day, isToday: date == today)
                    .frame(maxWidth: .infinity)
            }
        }
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
            Circle().fill(model.calendar.hasEvents(on: day) ? Theme.secondary : .clear).frame(width: 4, height: 4)
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

// MARK: - the week

/// The week's days across the top: click one to see that day; drop a task on one to move it there.
private struct WeekHeader: View {
    @ObservedObject var model: AppModel
    let days: [String]
    let width: CGFloat

    var body: some View {
        let today = Day.today(model.timers.now)
        let column = HoursView.column(width: width, days: days.count)
        HStack(spacing: 0) {
            Color.clear.frame(width: HoursView.gutter, height: 1)
            ForEach(days, id: \.self) { day in
                WeekDayTop(model: model, day: day, isToday: day == today).frame(width: column)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct WeekDayTop: View {
    @ObservedObject var model: AppModel
    let day: String
    let isToday: Bool
    @Local private var targeted = false

    var body: some View {
        let date = Day.date(day) ?? Date()
        let weekday = Day.calendar.component(.weekday, from: date) - 1
        VStack(spacing: 2) {
            Text(["sun", "mon", "tue", "wed", "thu", "fri", "sat"][weekday]).font(Theme.font(11.5)).foregroundStyle(Theme.faint)
            Text("\(Day.calendar.component(.day, from: date))")
                .font(Theme.font(15, bold: isToday))
                .foregroundStyle(isToday ? .white : Theme.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isToday ? Theme.accent : targeted ? Theme.selection : .clear))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) {
                model.calendarMode = .day
                model.showDay(day)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            model.schedule(items, day: day, time: nil, keepTime: true)
            return true
        } isTargeted: { targeted = $0 }
        .help(Format.longDay(day))
    }
}

/// The week's all-day events, a column a day: two each, then "n more", which opens the row to
/// show them all ("less" closes it).
private struct WeekAllDay: View {
    @ObservedObject var model: AppModel
    let days: [String]
    let width: CGFloat
    @Local private var open = false

    var body: some View {
        let column = HoursView.column(width: width, days: days.count)
        let most = days.map { day in model.calendar.everything(on: day).filter(\.allDay).count }.max() ?? 0
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 4) {
                Text("all day").font(Theme.font(11)).foregroundStyle(Theme.faint)
                if open, most > 2 {
                    Button { withAnimation(.snappy(duration: 0.2)) { open = false } } label: {
                        Text("less").font(Theme.font(10.5)).foregroundStyle(Theme.secondary).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: HoursView.gutter - 8, alignment: .trailing).padding(.trailing, 8)
            ForEach(days, id: \.self) { day in
                let events = model.calendar.everything(on: day).filter(\.allDay)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events.prefix(open ? events.count : 2)) { event in AllDayChip(model: model, event: event, compact: true) }
                    if !open, events.count > 2 {
                        Button { withAnimation(.snappy(duration: 0.2)) { open = true } } label: {
                            Text("\(events.count - 2) more").font(Theme.font(10.5)).foregroundStyle(Theme.secondary).underline()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("show them all")
                    }
                    if events.isEmpty { Color.clear.frame(height: 14) }
                }
                .padding(.horizontal, 1.5)
                .frame(width: column, alignment: .topLeading)
                .dropDestination(for: String.self) { items, _ in
                    model.schedule(items, day: day, time: nil)
                    return true
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - hours (a day, or a week)

/// The hours, for one day or several side by side: events tinted, your timed tasks dashed, now as
/// a gold line. Drop a task on an hour to do it then; double-click for a new event there.
private struct HoursView: View {
    @ObservedObject var model: AppModel
    let days: [String]
    let width: CGFloat
    @Local private var marker: DropSpot?
    /// The zoom a pinch started from, where it started (down the visible hours), and the hour
    /// (in hours from midnight) that was there: zooming keeps that hour under the fingers.
    @Local private var pinchFrom: CGFloat?
    @Local private var pinchAt: CGFloat?
    @Local private var pinchHour: CGFloat?
    /// Where the hours are scrolled to, how tall the visible part is, and where the pointer is in it.
    @Local private var scrolled = ScrollPosition(edge: .top)
    @Local private var offset: CGFloat = 0
    @Local private var visible: CGFloat = 0
    @Local private var pointer: CGFloat?

    /// An hour's height at no zoom.
    static let baseHour: CGFloat = 44
    static let gutter: CGFloat = 44
    /// An hour's height, zoomed.
    private var hour: CGFloat { Self.baseHour * model.calendarZoom }

    static func column(width: CGFloat, days: Int) -> CGFloat { max(width - gutter - 8, 80) / CGFloat(max(days, 1)) }
    private var column: CGFloat { Self.column(width: width, days: days.count) }
    private var compact: Bool { days.count > 1 }

    var body: some View {
        let now = model.timers.now
        let today = Day.today(now)
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    HourGrid(hour: hour)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { location in
                            let index = min(max(Int((location.x - Self.gutter) / column), 0), days.count - 1)
                            model.newEvent(day: days[index], time: Self.clock(Self.minutes(at: location.y, hour: hour, step: 30)))
                        }
                    if compact {
                        ForEach(1..<days.count, id: \.self) { index in
                            Rectangle().fill(Theme.rule).frame(width: 1, height: 24 * hour)
                                .offset(x: Self.gutter + column * CGFloat(index) - 1)
                                .allowsHitTesting(false)
                        }
                    }
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        ForEach(Self.items(on: day, model: model)) { item in
                            let y = CGFloat(item.from) * hour / 60
                            let height = max(CGFloat(item.to - item.from) * hour / 60, 20) - 2
                            let share = column / CGFloat(item.columns)
                            block(item, height: height, now: now)
                                .frame(width: max(share - 2, 6), height: height)
                                .offset(x: Self.gutter + column * CGFloat(index) + share * CGFloat(item.column) + 1, y: y + 1)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    if let index = days.firstIndex(of: today) {
                        NowLine(width: column).offset(x: Self.gutter + column * CGFloat(index) - 4, y: Self.y(now, hour: hour) - 4)
                    }
                    if let marker {
                        DropMarker(time: Self.clock(Int(marker.y / hour * 60)), width: column)
                            .offset(x: Self.gutter + column * CGFloat(marker.column) - 38, y: marker.y - 8)
                    }
                }
                .frame(width: width, height: 24 * hour, alignment: .topLeading)
                .onDrop(of: [.plainText], delegate: HourDrop(model: model, days: days, column: column, hour: hour, marker: $marker))
                .padding(.vertical, Self.pad)
            }
            .scrollIndicators(.never)
            .scrollPosition($scrolled)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.containerSize.height] } action: { _, now in
                offset = now[0]
                visible = now[1]
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): pointer = point.y
                case .ended: pointer = nil
                }
            }
            // Pinch to zoom the hours (⌘= and ⌘- too), about where the fingers are.
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchFrom == nil {
                            pinchFrom = model.calendarZoom
                            pinchAt = value.startLocation.y
                            pinchHour = (offset + value.startLocation.y - Self.pad) / hour
                        }
                        model.calendarZoom = min(max((pinchFrom ?? 1) * value.magnification, AppModel.zoomRange.lowerBound), AppModel.zoomRange.upperBound)
                    }
                    .onEnded { _ in
                        pinchFrom = nil
                        pinchAt = nil
                        pinchHour = nil
                    }
            )
            .onChange(of: model.calendarZoom) { old, new in keepInPlace(from: old, to: new) }
            .onAppear { scroll(proxy, today: today, now: now) }
            .onChange(of: days) { _, _ in scroll(proxy, today: today, now: now) }
        }
    }

    @ViewBuilder private func block(_ item: Placed, height: CGFloat, now: Date) -> some View {
        switch item.kind {
        case .event(let event): EventBlock(model: model, event: event, height: height, past: event.end < now, compact: compact)
        case .task(let task): TaskBlock(model: model, task: task, height: height, compact: compact)
        }
    }

    /// The space above and below the hours.
    static let pad: CGFloat = 10

    /// After a zoom: the hour that was under the fingers (or the pointer, or the middle) stays there.
    private func keepInPlace(from old: CGFloat, to new: CGFloat) {
        let at = pinchAt ?? pointer ?? visible / 2
        let hourThen = pinchHour ?? (offset + at - Self.pad) / (Self.baseHour * old)
        let top = hourThen * Self.baseHour * new + Self.pad - at
        scrolled.scrollTo(y: min(max(top, 0), max(24 * Self.baseHour * new + 2 * Self.pad - visible, 0)))
    }

    /// A day's timed events and tasks, laid out (a task on the calendar shows as its event).
    static func items(on day: String, model: AppModel) -> [Placed] {
        let timed = model.calendar.everything(on: day).filter { !$0.allDay }
        let shown = Set(timed.map(\.eventId))
        let tasks = model.snap.tasks.filter { $0.due == day && !$0.isIdea && $0.time != nil && !($0.event.map { shown.contains($0.id) } ?? false) }
        return lay(timed.map(Placed.init(event:)) + tasks.compactMap(Placed.init(task:)), day: day)
    }

    /// To an hour before now (when today's showing), else before the first event, else the morning.
    private func scroll(_ proxy: ScrollViewProxy, today: String, now: Date) {
        let firsts = days.compactMap { day in model.calendar.everything(on: day).filter { !$0.allDay }.map(\.start).min() }
        let hour: Int
        if days.contains(today) { hour = Day.calendar.component(.hour, from: now) - 1 }
        else if let first = firsts.map({ Day.calendar.component(.hour, from: $0) }).min() { hour = first - 1 }
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

    static func y(_ date: Date, hour: CGFloat) -> CGFloat {
        let parts = Day.calendar.dateComponents([.hour, .minute], from: date)
        return CGFloat(parts.hour! * 60 + parts.minute!) * hour / 60
    }

    /// The quarter (or half) hour at a height.
    static func minutes(at y: CGFloat, hour: CGFloat, step: Int = 15) -> Int {
        let raw = Int((y / hour * 60).rounded(.down))
        return min(max(raw / step * step, 0), 24 * 60 - step)
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// Where a dragged task would land: which day's column, and how far down.
private struct DropSpot: Equatable {
    var column: Int
    var y: CGFloat
}

/// The hours down the side, a hairline at each.
private struct HourGrid: View {
    let hour: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                HStack(alignment: .top, spacing: 6) {
                    Text(h == 0 ? "" : Format.time(String(format: "%02d:00", h)))
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: HoursView.gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                .frame(height: hour, alignment: .top)
                .id("h\(h)")
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
            Rectangle().fill(Theme.accent).frame(height: 1.5)
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
    let days: [String]
    let column: CGFloat
    let hour: CGFloat
    @Binding var marker: DropSpot?

    private func index(_ point: CGPoint) -> Int { min(max(Int((point.x - HoursView.gutter) / column), 0), days.count - 1) }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        marker = DropSpot(column: index(info.location), y: CGFloat(HoursView.minutes(at: info.location.y, hour: hour)) * hour / 60)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { marker = nil }

    func performDrop(info: DropInfo) -> Bool {
        let time = HoursView.clock(HoursView.minutes(at: info.location.y, hour: hour))
        let day = days[index(info.location)]
        marker = nil
        let providers = info.itemProviders(for: [.plainText])
        let model = model
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

// MARK: - the month

/// The month: its days in weeks, a few things on each (events, then what's due), and how many
/// more. Click a day to see it; drop a task on one to move it there.
private struct MonthView: View {
    @ObservedObject var model: AppModel
    let day: String
    let width: CGFloat

    var body: some View {
        let days = model.shownDays
        let rows = max(days.count / 7, 1)
        let column = (width - 12) / 7
        let today = Day.today(model.timers.now)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { date in
                    let weekday = Day.calendar.component(.weekday, from: Day.date(date) ?? Date()) - 1
                    Text(["sun", "mon", "tue", "wed", "thu", "fri", "sat"][weekday]).font(Theme.font(11.5)).foregroundStyle(Theme.faint)
                        .frame(width: column)
                }
            }
            .padding(.bottom, 6)
            Hairline()
            GeometryReader { space in
                let height = max((space.size.height - 4) / CGFloat(rows), 64)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { col in
                                    let date = days[row * 7 + col]
                                    MonthCell(model: model, day: date, inMonth: CalendarDays.isSameMonth(date, day), isToday: date == today)
                                        .frame(width: column, height: height)
                                        .overlay(alignment: .trailing) { if col < 6 { Rectangle().fill(Theme.rule).frame(width: 1) } }
                                }
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct MonthCell: View {
    @ObservedObject var model: AppModel
    let day: String
    let inMonth: Bool
    let isToday: Bool
    @Local private var targeted = false
    @Local private var hovering = false

    var body: some View {
        let events = model.calendar.everything(on: day).sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        let tasks = model.snap.tasks.filter { $0.due == day && !$0.done && !$0.isIdea && !($0.event.map { link in events.contains { $0.eventId == link.id } } ?? false) }
        let room = 3
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Day.calendar.component(.day, from: Day.date(day) ?? Date()))")
                .font(Theme.font(12.5, bold: isToday))
                .foregroundStyle(isToday ? .white : inMonth ? Theme.ink : Theme.faint)
                .frame(minWidth: 20, minHeight: 20)
                .background(Circle().fill(isToday ? Theme.accent : .clear))
            ForEach(events.prefix(room)) { event in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.color(hex: event.color)).frame(width: 2.5, height: 10)
                    Text(event.title).font(Theme.font(11)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            ForEach(tasks.prefix(max(room - events.count, 0))) { task in
                HStack(spacing: 3) {
                    Circle().strokeBorder(Theme.secondary, lineWidth: 1).frame(width: 7, height: 7)
                    Text(model.display(task.title)).font(Theme.font(11)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            let more = events.count + tasks.count - room
            if more > 0 { Text("\(more) more").font(Theme.font(10.5)).foregroundStyle(Theme.secondary) }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(targeted ? Theme.selection : hovering ? Theme.hover : .clear)
        .opacity(inMonth ? 1 : 0.6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) {
                model.calendarMode = .day
                model.showDay(day)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            model.schedule(items, day: day, time: nil, keepTime: true)
            return true
        } isTargeted: { targeted = $0 }
        .help(Format.longDay(day))
    }
}

// MARK: - what's on it

/// An event: a tint of its label's color (or its calendar's), its title, its time. Click for more.
private struct EventBlock: View {
    @ObservedObject var model: AppModel
    let event: CalEvent
    let height: CGFloat
    let past: Bool
    /// In a week: the title alone, small.
    var compact = false
    @Local private var showing = false
    @Local private var hovering = false

    var body: some View {
        let color = Theme.color(hex: event.color)
        let short = height < 30
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: compact ? 2.5 : 3)
            VStack(alignment: .leading, spacing: 0) {
                if compact {
                    Text(event.title).font(Theme.font(11)).foregroundStyle(Theme.ink)
                        .lineLimit(max(Int((height - 4) / 13), 1))
                } else if short {
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
            .padding(.leading, compact ? 3 : 5)
            .padding(.trailing, 2)
            .padding(.vertical, short || compact ? 2 : 3)
            Spacer(minLength: 0)
            if event.taskId != nil, !compact {
                Image(systemName: "checklist").font(.system(size: 9)).foregroundStyle(Theme.secondary).padding(4)
            }
        }
        .frame(height: height, alignment: .top)
        .background(color.opacity(hovering || showing ? 0.36 : 0.24))
        .overlay {
            if event.tentative { RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(past ? 0.82 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showing = true }
        .popover(isPresented: $showing, arrowEdge: .leading) { EventCard(model: model, event: event) }
        .draggable("toyl-event:" + event.calendarId + "|" + event.eventId) { EventDragPreview(event: event) }
        .help("drag onto a task to tie it to this event")
    }
}

/// What's dragged when an event is: its title on its color.
private struct EventDragPreview: View {
    let event: CalEvent
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.color(hex: event.color)).frame(width: 3, height: 13)
            Text(event.title).font(Theme.font(14)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.color(hex: event.color).opacity(0.25)))
    }
}

/// A task with a time: dashed (it's yours, not the calendar's), its circle to check it off.
/// Click to see it; drag it to another hour.
private struct TaskBlock: View {
    @ObservedObject var model: AppModel
    let task: TaskModel
    let height: CGFloat
    /// In a week: the title alone, small.
    var compact = false
    @Local private var hovering = false

    var body: some View {
        let done = model.isDone(task)
        let short = height < 30 || compact
        let selected = model.selection.contains(task.id)
        HStack(alignment: short ? .center : .top, spacing: compact ? 3 : 5) {
            if !compact {
                CheckCircle(done: done, late: false, size: 11)
                    .padding(.top, short ? 0 : 3)
                    .onTapGesture { model.complete([task.id]) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.display(task.title))
                    .font(Theme.font(compact ? 11 : 12.5))
                    .foregroundStyle(done ? Theme.secondary : Theme.ink)
                    .strikethrough(done, color: Theme.faint)
                    .lineLimit(short ? 1 : max(Int((height - 18) / 15), 1))
                if !short { Text(when).font(Theme.font(11.5)).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 3 : 5)
        .padding(.vertical, short ? 0 : 2)
        .frame(height: height, alignment: short ? .center : .top)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.selection : hovering ? Theme.hover : Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .opacity(done ? 0.8 : 1)
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
                .frame(width: HoursView.gutter - 8, alignment: .trailing)
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
    var compact = false
    @Local private var showing = false

    var body: some View {
        let color = Theme.color(hex: event.color)
        HStack(spacing: compact ? 3 : 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: compact ? 2.5 : 3, height: compact ? 10 : 12)
            Text(event.title).font(Theme.font(compact ? 11 : 12.5)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 1 : 2)
        .padding(.horizontal, compact ? 3 : 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(showing ? 0.34 : 0.22)))
        .contentShape(Rectangle())
        .onTapGesture { showing = true }
        .popover(isPresented: $showing, arrowEdge: .leading) { EventCard(model: model, event: event) }
        .draggable("toyl-event:" + event.calendarId + "|" + event.eventId) { EventDragPreview(event: event) }
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
                let words = NoteLinks.withoutLinks(event.notes)
                if !words.isEmpty {
                    Label(words, systemImage: "text.alignleft").lineLimit(8).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(NoteLinks.links(in: event.notes), id: \.self) { url in LinkCard(url: url) }
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
