// Copied from Oyl (Sources/TodRepeat.swift) unchanged: Oyl brings a repeating task back the
// same way when it's checked off from the notch.

import Foundation

/// How often a to-do comes back once it's done: laundry every Sunday, rent every month. Kept on
/// tod's task as "repeat" (tod keeps fields it doesn't know); when one's checked off, in Oyl or in
/// tod, Oyl adds the next.
enum TodRepeat: String, CaseIterable {
    case daily, weekdays, weekly, biweekly, monthly, yearly

    /// "every day", "every week"… for showing.
    var phrase: String {
        switch self {
        case .daily: return "every day"
        case .weekdays: return "every weekday"
        case .weekly: return "every week"
        case .biweekly: return "every other week"
        case .monthly: return "every month"
        case .yearly: return "every year"
        }
    }

    /// The next due date after `due` ("YYYY-MM-DD"), and after `today` too if it's given: checked
    /// off late, it keeps its rhythm (Sundays stay Sundays) rather than coming back days early.
    /// A month on from the 31st is the last day of a shorter month, and a year on from Feb 29 is
    /// Feb 28.
    func next(after due: String, today: String? = nil) -> String {
        guard let start = Self.day(due) else { return due }
        let floor = today.flatMap(Self.day) ?? start
        var step = 1
        var next = advance(start, by: step)
        // Months and years count from the first date each time, so the 31st doesn't drift to
        // the 28th for good after February.
        while next <= floor {
            step += 1
            next = advance(start, by: step)
        }
        return Self.string(next)
    }

    /// `steps` repeats on from `start`.
    private func advance(_ start: Date, by steps: Int) -> Date {
        let calendar = Self.calendar
        switch self {
        case .daily: return calendar.date(byAdding: .day, value: steps, to: start)!
        case .weekly: return calendar.date(byAdding: .day, value: 7 * steps, to: start)!
        case .biweekly: return calendar.date(byAdding: .day, value: 14 * steps, to: start)!
        case .monthly: return calendar.date(byAdding: .month, value: steps, to: start)!
        case .yearly: return calendar.date(byAdding: .year, value: steps, to: start)!
        case .weekdays:
            var date = start
            var left = steps
            while left > 0 {
                date = calendar.date(byAdding: .day, value: 1, to: date)!
                let weekday = calendar.component(.weekday, from: date)
                if weekday != 1 && weekday != 7 { left -= 1 }
            }
            return date
        }
    }

    // Days at noon in a fixed zone, so daylight saving can't move a date.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        // Dates that don't exist (Feb 30) aren't quietly moved.
        guard let date, calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    private static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
