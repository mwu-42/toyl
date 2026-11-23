import Foundation

/// How toyl says things: all in lower case (what you type is kept as you typed it), days said
/// as you'd say them, times the Mac's way.
enum Format {
    /// "30m", "1h", "1h30m".
    static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    /// Time spent, for showing: "25m", "1h 5m", or "40s" for under a minute.
    static func spent(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = (seconds + 30) / 60
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// A countdown or stopwatch: "4:05", "24:13", "1:02:03" (rounded up while counting down, as
    /// Oyl's are, so it shows 0:01 till it's really done).
    static func clock(_ seconds: Double, roundingUp: Bool = true) -> String {
        let total = max(Int(roundingUp ? (seconds - 0.001).rounded(.up) : seconds.rounded(.down)), 0)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "today", "tomorrow", "yesterday", "fri" within the week, else "nov 30" ("nov 30, 2027"
    /// in another year).
    static func day(_ day: String, now: Date = Date()) -> String {
        TodQuick.describe(due: day, now: now).lowercased()
    }

    /// "5pm", "5:30pm" (or "17:00", on a 24-hour clock).
    static func time(_ time: String) -> String {
        TodQuick.describe(time: time).lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// What a task's deadline says: "today 5pm", "fri", "nov 30"; or, once it's gone by,
    /// "yesterday" or "3 days late" ("late" alone for earlier today).
    static func due(_ task: TaskModel, now: Date = Date()) -> String? {
        guard let due = task.due else { return nil }
        let today = Day.today(now)
        if !task.done, let days = Day.between(due, today), days > 0 {
            return days == 1 ? "yesterday" : "\(days) days late"
        }
        let said = day(due, now: now)
        return task.time.map { said + " " + time($0) } ?? said
    }

    /// An aim, as loosely as it was meant: "by fri", "early dec"; or, once it's gone by,
    /// "slipped 3 days".
    static func aim(_ target: String, now: Date = Date()) -> String {
        if let days = Day.between(target, Day.today(now)), days > 0 {
            return days == 1 ? "slipped a day" : "slipped \(days) days"
        }
        return IdeaQuick.describe(target: target, now: now).lowercased()
    }

    /// "friday, november 21" (with the year if it isn't this one).
    static func longDay(_ day: String, now: Date = Date()) -> String {
        guard let date = Day.date(day) else { return day }
        let sameYear = Day.calendar.component(.year, from: date) == Day.calendar.component(.year, from: now)
        return (sameYear ? longFormatter : longYearFormatter).string(from: date).lowercased()
    }

    /// "nov 21".
    static func monthDay(_ day: String) -> String {
        guard let date = Day.date(day) else { return day }
        return monthDayFormatter.string(from: date).lowercased()
    }

    /// "fri nov 21".
    static func shortDay(_ day: String) -> String {
        guard let date = Day.date(day) else { return day }
        return shortFormatter.string(from: date).lowercased().replacingOccurrences(of: ",", with: "")
    }

    /// An event's time: "9-10:30am", "all day" (a plain hyphen, as the owner writes it).
    static func span(_ start: Date, _ end: Date, allDay: Bool) -> String {
        if allDay { return "all day" }
        let a = time(Day.clock(start)), b = time(Day.clock(end))
        // "9am–10am" reads as "9–10am".
        if a.hasSuffix("am") && b.hasSuffix("am") || a.hasSuffix("pm") && b.hasSuffix("pm") {
            return String(a.dropLast(2)) + "-" + b
        }
        return a + "-" + b
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = Day.calendar
        formatter.timeZone = Day.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let longFormatter = formatter("EEEEMMMMd")
    private static let longYearFormatter = formatter("EEEEMMMMdy")
    private static let shortFormatter = formatter("EEEMMMd")
    private static let monthDayFormatter = formatter("MMMd")
}
